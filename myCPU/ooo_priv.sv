module ooo_priv (
    input logic clk, resetn,
    input logic [7:0] ext_int,
    input logic [31:0] fetch_va, data_va, lookup_va,
    input logic [2:0] fast_segment,
    input logic fetch_lookup, data_lookup, lookup_store,
    output ooo_pkg::translation_t fetch_direct, fetch_translation, data_direct, data_translation,
    output logic fetch_direct_valid, data_direct_valid,
    output logic [2:0] fast_pa_segment,
    output logic fast_cached,
    output logic [1:0] plv,
    output logic interrupt_pending,

    input logic system_commit,
    input ooo_pkg::op_t system_op,
    input logic [31:0] system_insn, system_a, system_b,
    output logic [31:0] system_result, ertn_pc,

    input logic trap,
    input ooo_pkg::fault_t trap_fault,
    input logic [31:0] trap_pc,
    output logic [31:0] trap_target,

    input logic reserve, clear_reservation, ordinary_store,
    input logic [31:0] atomic_pa, store_pa,
    output logic reservation_matches
);
    import ooo_pkg::*;

    localparam int TLB_ENTRIES = 16;
    typedef struct packed {
        logic big_page;
        logic global_page;
        logic [9:0] asid;
        logic [18:0] vppn;
        logic [27:0] even_page, odd_page;
    } tlb_entry_t;

    logic [8:0] crmd;
    logic [2:0] prmd;
    logic euen;
    logic [12:0] ecfg;
    logic [1:0] soft_interrupts;
    logic [7:0] interrupt_sync, interrupt_sample;
    logic timer_interrupt;
    logic [5:0] ecode;
    logic esubcode;
    logic [31:0] era, badv, eentry, save [4];
    logic [31:0] pgdl, pgdh, tlbrentry, dmw0, dmw1, ctag;
    logic [31:0] tid, tcfg, tval;
    logic [63:0] ticks;
    logic timer_running, keep_ll, llbit;
    logic [29:0] ll_word;

    logic [3:0] tlb_index, fill_index;
    logic [5:0] tlb_ps;
    logic tlb_ne;
    logic [18:0] tlb_vppn;
    logic [27:0] tlb_elo0, tlb_elo1;
    logic [9:0] asid;
    logic [TLB_ENTRIES-1:0] tlb_exists;
    tlb_entry_t tlb [TLB_ENTRIES];

    wire [12:0] interrupt_state = {1'b0, timer_interrupt, 1'b0, interrupt_sample, soft_interrupts};
    wire [13:0] csr_index = system_insn[23:10];
    wire [4:0] csr_rj = system_insn[9:5];
    wire csr_write = system_commit && system_op == OP_CSR && csr_rj != 0;
    wire [31:0] csr_mask = csr_rj == 1 ? '1 : system_a;
    logic [31:0] csr_read;
    wire [31:0] csr_new = (csr_read & ~csr_mask) | (system_b & csr_mask);

    assign plv = crmd[1:0];
    // CSR writes and exception entry flush the backend for one cycle. In
    // that cycle retirement ignores the previous interrupt-mask sample.
    always_ff @(posedge clk) begin
        if (!resetn) interrupt_pending <= 0;
        else interrupt_pending <= crmd[2] && |(ecfg & interrupt_state);
    end
    assign ertn_pc = era;
    assign trap_target = trap_fault.code == E_TLBR ? tlbrentry : eentry;
    assign reservation_matches = llbit && atomic_pa[31:2] == ll_word;

    function automatic logic vpn_match(input tlb_entry_t e, input logic [31:0] va);
        return e.vppn[18:9] == va[31:22] && (e.big_page || e.vppn[8:0] == va[21:13]);
    endfunction

    function automatic logic [TLB_ENTRIES-1:0] tlb_match(input logic [31:0] va);
        logic [TLB_ENTRIES-1:0] found;
        for (int i = 0; i < TLB_ENTRIES; i++)
            found[i] = tlb_exists[i] && (tlb[i].global_page || tlb[i].asid == asid)
                       && vpn_match(tlb[i], va);
        return found;
    endfunction

    function automatic logic dmw_match(input logic [31:0] dmw, va);
        return dmw[31:29] == va[31:29] && ((plv == 0 && dmw[0]) || (plv == 3 && dmw[3]));
    endfunction

    function automatic logic direct_mapping(input logic [31:0] va);
        return (crmd[3] && !crmd[4]) || dmw_match(dmw0, va) || dmw_match(dmw1, va);
    endfunction

    function automatic translation_t direct_translate(input logic [31:0] va, input logic instruction);
        translation_t t;
        t = '0;
        if (crmd[3] && !crmd[4]) begin
            t.pa = va;
            t.cached = (instruction ? crmd[6:5] : crmd[8:7]) == 2'b01;
        end else if (dmw_match(dmw0, va)) begin
            t.pa = {dmw0[27:25], va[28:0]};
            t.cached = dmw0[5:4] == 2'b01;
        end else begin
            t.pa = {dmw1[27:25], va[28:0]};
            t.cached = dmw1[5:4] == 2'b01;
        end
        return t;
    endfunction

    function automatic translation_t translate(
        input logic [31:0] va,
        input logic instruction, store,
        input logic [TLB_ENTRIES-1:0] match_bits
    );
        translation_t t;
        logic [27:0] page;
        logic big_page;
        logic odd_page;
        page = 0;
        big_page = 0;
        for (int i = 0; i < TLB_ENTRIES; i++) begin
            odd_page = tlb[i].big_page ? va[21] : va[12];
            page |= (odd_page ? tlb[i].odd_page : tlb[i].even_page) & {28{match_bits[i]}};
            big_page |= tlb[i].big_page && match_bits[i];
        end
        t = '0;
        t.fault.badv = va;
        t.fault.data_address = !instruction;
        if (instruction && va[1:0] != 0) begin
            t.fault.valid = 1;
            t.fault.code = E_ADE;
        end else if (direct_mapping(va)) begin
            t = direct_translate(va, instruction);
        end else if (match_bits == 0) begin
            t.fault.valid = 1;
            t.fault.code = E_TLBR;
        end else if (!page[0]) begin
            t.fault.valid = 1;
            t.fault.code = instruction ? E_PIF : store ? E_PIS : E_PIL;
        end else if (plv > page[3:2]) begin
            t.fault.valid = 1;
            t.fault.code = E_PPI;
        end else if (store && !page[1]) begin
            t.fault.valid = 1;
            t.fault.code = E_PME;
        end else begin
            t.pa = big_page ? {page[27:17], va[20:0]} : {page[27:8], va[11:0]};
            t.cached = page[5:4] == 2'b01;
        end
        return t;
    endfunction

    wire search = system_op == OP_TLBSRCH;
    wire [31:0] data_search_va = search ? {tlb_vppn, 13'b0} : lookup_va;
    wire [TLB_ENTRIES-1:0] data_match = tlb_match(data_search_va);
    logic [3:0] search_index;
    always_comb begin
        search_index = 0;
        for (int i = 0; i < TLB_ENTRIES; i++)
            search_index |= 4'(i) & {4{data_match[i]}};
    end
    assign fetch_direct_valid = direct_mapping(fetch_va) || fetch_va[1:0] != 0;
    always_comb begin
        fetch_direct = direct_translate(fetch_va, 1'b1);
        if (fetch_va[1:0] != 0)
            fetch_direct.fault = {1'b1, E_ADE, 1'b0, fetch_va};
    end
    assign data_direct_valid = direct_mapping(data_va);
    assign data_direct = direct_translate(data_va, 1'b0);
    wire [31:0] fast_segment_va = {fast_segment, 29'b0};
    wire translation_t fast_mapping = direct_translate(fast_segment_va, 1'b0);
    assign fast_pa_segment = fast_mapping.pa[31:29];
    assign fast_cached = direct_mapping(fast_segment_va) && fast_mapping.cached;
    always_ff @(posedge clk)
        if (fetch_lookup) fetch_translation <= translate(fetch_va, 1'b1, 1'b0, tlb_match(fetch_va));
    always_ff @(posedge clk)
        if (data_lookup) data_translation <= translate(lookup_va, 1'b0, lookup_store, data_match);

    function automatic logic invalidate(
        input tlb_entry_t entry, input logic [4:0] op,
        input logic [9:0] search_asid, input logic [31:0] va
    );
        case (op)
            0, 1: invalidate = 1;
            2: invalidate = entry.global_page;
            3: invalidate = !entry.global_page;
            4: invalidate = !entry.global_page && entry.asid == search_asid;
            5: invalidate = !entry.global_page && entry.asid == search_asid && vpn_match(entry, va);
            6: invalidate = (entry.global_page || entry.asid == search_asid) && vpn_match(entry, va);
            default: invalidate = 0;
        endcase
    endfunction

    always_comb begin
        case (csr_index)
            14'h000: csr_read = {23'b0, crmd};
            14'h001: csr_read = {29'b0, prmd};
            14'h002: csr_read = {31'b0, euen};
            14'h004: csr_read = {19'b0, ecfg};
            14'h005: csr_read = {9'b0, esubcode, ecode, 3'b0, interrupt_state};
            14'h006: csr_read = era;
            14'h007: csr_read = badv;
            14'h00c: csr_read = eentry;
            14'h010: csr_read = {tlb_ne, 1'b0, tlb_ps, 20'b0, tlb_index};
            14'h011: csr_read = {tlb_vppn, 13'b0};
            14'h012: csr_read = {4'b0, tlb_elo0};
            14'h013: csr_read = {4'b0, tlb_elo1};
            14'h018: csr_read = {8'b0, 8'd10, 6'b0, asid};
            14'h019: csr_read = pgdl;
            14'h01a: csr_read = pgdh;
            14'h01b: csr_read = badv[31] ? pgdh : pgdl;
            14'h030, 14'h031, 14'h032, 14'h033: csr_read = save[csr_index[1:0]];
            14'h040: csr_read = tid;
            14'h041: csr_read = tcfg;
            14'h042: csr_read = tval;
            14'h060: csr_read = {29'b0, keep_ll, 1'b0, llbit};
            14'h088: csr_read = tlbrentry;
            14'h098: csr_read = ctag;
            14'h180: csr_read = dmw0;
            14'h181: csr_read = dmw1;
            default: csr_read = 0;
        endcase
        case (system_op)
            OP_CSR: system_result = csr_read;
            OP_CNTID: system_result = tid;
            OP_CNTLO: system_result = ticks[31:0];
            OP_CNTHI: system_result = ticks[63:32];
            OP_CPUCFG: begin
                case (system_a)
                    32'h10: system_result = 32'h0000_0005;
                    32'h11: system_result = 32'h0408_0001;
                    32'h12: system_result = 32'h0606_0001;
                    default: system_result = 0;
                endcase
            end
            default: system_result = 0;
        endcase
    end

    wire [3:0] write_index = system_op == OP_TLBFILL ? fill_index : tlb_index;
    wire tlb_write = system_commit && (system_op == OP_TLBWR || system_op == OP_TLBFILL);
    wire tlb_read = system_commit && system_op == OP_TLBRD;
    wire exception_updates_vppn = trap_fault.code == E_TLBR || trap_fault.code == E_PIF ||
        trap_fault.code == E_PIL || trap_fault.code == E_PIS ||
        trap_fault.code == E_PPI || trap_fault.code == E_PME;
    wire exception_updates_badv = exception_updates_vppn || trap_fault.code == E_ALE || trap_fault.code == E_ADE;

    always_ff @(posedge clk) begin
        if (!resetn) begin
            crmd <= 9'h008;
            prmd <= 0;
            euen <= 0;
            ecfg <= 0;
            soft_interrupts <= 0;
            interrupt_sync <= 0;
            interrupt_sample <= 0;
            timer_interrupt <= 0;
            ecode <= 0;
            esubcode <= 0;
            era <= 0;
            badv <= 0;
            eentry <= 0;
            pgdl <= 0;
            pgdh <= 0;
            tlbrentry <= 0;
            dmw0 <= 0;
            dmw1 <= 0;
            ctag <= 0;
            for (int i = 0; i < 4; i++) save[i] <= 0;
            tid <= 0;
            tcfg <= 0;
            tval <= '1;
            timer_running <= 0;
            ticks <= 0;
            keep_ll <= 0;
            llbit <= 0;
            ll_word <= 0;
            tlb_index <= 0;
            fill_index <= 0;
            tlb_ps <= 0;
            tlb_ne <= 0;
            tlb_vppn <= 0;
            tlb_elo0 <= 0;
            tlb_elo1 <= 0;
            asid <= 0;
            tlb_exists <= 0;
        end else begin
            ticks <= ticks + 1'b1;
            fill_index <= fill_index + 1'b1;
            interrupt_sync <= ext_int;
            interrupt_sample <= interrupt_sync;
            if (reserve) begin
                llbit <= 1;
                ll_word <= atomic_pa[31:2];
            end
            if (clear_reservation || (ordinary_store && store_pa[31:6] == ll_word[29:4]))
                llbit <= 0;
            if (timer_running) begin
                if (tval > 1) tval <= tval - 1'b1;
                else begin
                    timer_interrupt <= 1;
                    timer_running <= tcfg[1];
                    tval <= tcfg[1] ? {tcfg[31:2], 2'b00} : 32'hffff_ffff;
                end
            end
            if (csr_write) begin
                case (csr_index)
                    14'h000: crmd <= csr_new[8:0];
                    14'h001: prmd <= csr_new[2:0];
                    14'h002: euen <= csr_new[0];
                    14'h004: ecfg <= csr_new[12:0] & 13'h1bff;
                    14'h005: soft_interrupts <= csr_new[1:0];
                    14'h006: era <= csr_new;
                    14'h007: badv <= csr_new;
                    14'h00c: eentry <= {csr_new[31:6], 6'b0};
                    14'h010: begin
                        tlb_ne <= csr_new[31];
                        tlb_ps <= csr_new[29:24];
                        tlb_index <= csr_new[3:0];
                    end
                    14'h011: tlb_vppn <= csr_new[31:13];
                    14'h012: tlb_elo0 <= csr_new[27:0] & 28'hfff_ff7f;
                    14'h013: tlb_elo1 <= csr_new[27:0] & 28'hfff_ff7f;
                    14'h018: asid <= csr_new[9:0];
                    14'h019: pgdl <= {csr_new[31:12], 12'b0};
                    14'h01a: pgdh <= {csr_new[31:12], 12'b0};
                    14'h030, 14'h031, 14'h032, 14'h033: save[csr_index[1:0]] <= csr_new;
                    14'h040: tid <= csr_new;
                    14'h041: begin
                        tcfg <= csr_new;
                        timer_running <= csr_new[0];
                        if (csr_new[0]) tval <= {csr_new[31:2], 2'b0};
                    end
                    14'h044: if (csr_mask[0] && system_b[0]) timer_interrupt <= 0;
                    14'h060: begin
                        keep_ll <= csr_new[2];
                        if (csr_mask[1] && system_b[1]) llbit <= 0;
                    end
                    14'h088: tlbrentry <= {csr_new[31:6], 6'b0};
                    14'h098: ctag <= csr_new;
                    14'h180: dmw0 <= csr_new & 32'hee00_0039;
                    14'h181: dmw1 <= csr_new & 32'hee00_0039;
                    default: ;
                endcase
            end
            if (tlb_write) begin
                tlb[write_index] <= {tlb_ps == 21, tlb_elo0[6] && tlb_elo1[6],
                                     asid, tlb_vppn, tlb_elo0, tlb_elo1};
                tlb_exists[write_index] <= ecode == E_TLBR || !tlb_ne;
            end
            if (tlb_read) begin
                tlb_ne <= !tlb_exists[tlb_index];
                tlb_ps <= 0;
                tlb_vppn <= 0;
                tlb_elo0 <= 0;
                tlb_elo1 <= 0;
                asid <= 0;
                if (tlb_exists[tlb_index]) begin
                    tlb_ps <= tlb[tlb_index].big_page ? 6'd21 : 6'd12;
                    tlb_vppn <= tlb[tlb_index].vppn;
                    tlb_elo0 <= {tlb[tlb_index].even_page[27:7], tlb[tlb_index].global_page,
                                 tlb[tlb_index].even_page[5:0]};
                    tlb_elo1 <= {tlb[tlb_index].odd_page[27:7], tlb[tlb_index].global_page,
                                 tlb[tlb_index].odd_page[5:0]};
                    asid <= tlb[tlb_index].asid;
                end
            end
            if (system_commit && system_op == OP_TLBSRCH) begin
                tlb_ne <= data_match == 0;
                if (data_match != 0) tlb_index <= search_index;
            end
            if (system_commit && system_op == OP_INVTLB)
                for (int i = 0; i < TLB_ENTRIES; i++)
                    if (invalidate(tlb[i], system_insn[4:0], system_a[9:0], system_b))
                        tlb_exists[i] <= 0;
            if (system_commit && system_op == OP_ERTN) begin
                crmd[2:0] <= prmd;
                if (ecode == E_TLBR) crmd[4:3] <= 2'b10;
                if (!keep_ll) llbit <= 0;
                keep_ll <= 0;
            end
            if (trap) begin
                prmd <= crmd[2:0];
                crmd[2:0] <= 0;
                if (trap_fault.code == E_TLBR) crmd[4:3] <= 2'b01;
                era <= trap_pc;
                ecode <= trap_fault.code;
                esubcode <= trap_fault.code == E_ADE && trap_fault.data_address;
                if (exception_updates_badv) badv <= trap_fault.badv;
                if (exception_updates_vppn) tlb_vppn <= trap_fault.badv[31:13];
            end
        end
    end
endmodule
