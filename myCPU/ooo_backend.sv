module ooo_backend (
    input logic clk, resetn,
    input logic [1:0] available,
    input ooo_pkg::fetch_t first, second,
    input ooo_pkg::decode_t dec0, dec1,
    output logic [1:0] pop_count,
    output logic flush, idle, drain_fetch,
    output logic redirect_valid,
    output logic [31:0] redirect_pc,
    output ooo_pkg::retire_t retire0, retire1,

    output logic train_valid, train_control, train_taken, train_conditional,
    output logic train_call, train_return,
    output logic train_slot1, train_indirect,
    output logic train_tag_miss, train_direction_correct,
    output logic [31:0] train_pc, train_target, train_link,
    output logic [9:0] train_index,
    output logic branch_miss,
    output logic data0, data1,

    input logic [1:0] plv,
    input logic interrupt_pending,
    output logic system_commit,
    output ooo_pkg::op_t system_op,
    output logic [31:0] system_insn, system_a, system_b,
    input logic [31:0] system_result, ertn_pc,
    output logic trap,
    output ooo_pkg::fault_t trap_fault,
    output logic [31:0] trap_pc,
    input logic [31:0] trap_target,

    output logic reserve, clear_reservation,
    output logic [31:0] atomic_pa,
    input logic reservation_matches,
    output logic invalidate_valid,
    output logic [1:0] invalidate_mode,
    output logic [31:0] invalidate_addr,
    input logic invalidate_ready,

    output logic agu_valid,
    output ooo_pkg::agu_t agu_request,
    output logic [2:0] agu_segment,
    output logic agu_same_segment,
    input logic agu_ready,
    input ooo_pkg::writeback_t agu_result, load_result,
    input logic load_hint,
    input ooo_pkg::rob_id_t load_hint_id,
    output ooo_pkg::rob_id_t rob_head,
    output logic retire_store, retire_io_load,
    output logic allow_uncached_load,
    input logic stores_drained, io_load_busy,
    output logic system_select,
    output logic [31:0] system_va,
    output logic system_write,
    input ooo_pkg::translation_t data_translation,
    output logic system_cache_valid,
    output ooo_pkg::data_req_t system_cache_request,
    input logic system_cache_accept, system_cache_done,
    input ooo_pkg::data_resp_t cache_response
);
    import ooo_pkg::*;
    localparam int PTR = $bits(rob_id_t);
    typedef struct packed {
        logic waiting;
        rob_id_t producer;
        logic [31:0] value;
    } operand_t;
    typedef struct packed {
        decode_t dec;
        logic [31:0] a, b, pc;
        rob_id_t id;
        logic [2:0] bypass_a, bypass_b;
    } execute_t;

    rob_id_t head, tail;
    logic [ROB_SIZE-1:0] older_than [ROB_SIZE];
    logic [PTR:0] used;
    logic serial_inflight;
    logic [31:0] committed_pc;
    logic [ROB_SIZE-1:0] occupied, issued, complete;
    logic [ROB_SIZE-1:0] prefer_second_alu;
    fetch_t fetched [ROB_SIZE];
    decode_t decoded [ROB_SIZE];
    operand_t src_a [ROB_SIZE], src_b [ROB_SIZE];
    fault_t faults [ROB_SIZE];
    logic [31:0] result [ROB_SIZE];
    logic [31:0] indirect_target [ROB_SIZE];
    logic [ROB_SIZE-1:0] taken, branch_resolved, wrong_next;
    logic [31:0] architectural [32];
    logic [31:0] speculative [32];
    logic [31:0] pending_writer;
    logic writer_ready [32];
    rob_id_t writer [32];
    assign rob_head = head;

    execute_t x, y, m;
    logic x_valid, y_valid, m_valid, x_early, x_div_busy;
    logic x_replay, y_replay, m_replay;
    wire x_branch = x.dec.fu == FU_BRANCH;
    wire x_direct_branch = x_valid && !x_replay && x_branch && x.dec.op != OP_JIRL;
    writeback_t registered_x, registered_y, registered_agu, registered_load;
    logic load_prediction_hit;
    always_ff @(posedge clk) begin
        if (!resetn || flush) load_prediction_hit <= 0;
        else load_prediction_hit <= load_hint && load_result.valid && !load_result.fault.valid &&
                                    load_result.id == load_hint_id;
    end
    wire [2:0] missed_bypass = {!load_prediction_hit, !registered_y.valid, !registered_x.valid};
    assign x_replay = x_valid && |((x.bypass_a | x.bypass_b) & missed_bypass);
    assign y_replay = y_valid && |((y.bypass_a | y.bypass_b) & missed_bypass);
    assign m_replay = m_valid && |((m.bypass_a | m.bypass_b) & missed_bypass);
    function automatic logic [31:0] execution_operand(
        input logic [31:0] value, input logic [2:0] bypass
    );
        return (registered_x.data & {32{bypass[0]}}) |
               (registered_y.data & {32{bypass[1]}}) |
               (registered_load.data & {32{bypass[2]}}) |
               (value & {32{bypass == 0}});
    endfunction
    wire [31:0] x_source_a = execution_operand(x.a, x.bypass_a);
    wire [31:0] x_source_b = execution_operand(x.b, x.bypass_b);
    wire [31:0] y_source_a = execution_operand(y.a, y.bypass_a);
    wire [31:0] y_source_b = execution_operand(y.b, y.bypass_b);
    wire [31:0] m_source_a = execution_operand(m.a, m.bypass_a);
    wire [31:0] m_source_b = execution_operand(m.b, m.bypass_b);
    wire [31:0] x_a = x.dec.a_pc ? x.pc : x_source_a;
    wire [31:0] x_b = x.dec.b_imm ? x.dec.imm : x_source_b;
    wire [31:0] y_a = y.dec.a_pc ? y.pc : y_source_a;
    wire [31:0] y_b = y.dec.b_imm ? y.dec.imm : y_source_b;
    wire branch_taken_x = branch_taken(x.dec.op, x_source_a, x_source_b);
    wire [31:0] indirect_target_x = x_source_a + x.dec.imm;
    wire [31:0] x_data = x_branch ? x.dec.sequential_pc : alu(x.dec.op, x_a, x_b);
    wire [31:0] y_data = alu(y.dec.op, y_a, y_b);
    assign agu_valid = m_valid && !m_replay;
    assign agu_request = {m_source_a + m.dec.imm, m_source_b, m.dec, m.id};
    // The signed 12-bit memory offset cannot cross a 512 MiB boundary
    // unless the base lies within its first or last 4 KiB page.
    assign agu_segment = m_source_a[31:29];
    assign agu_same_segment = m.dec.imm[31] ? (|m_source_a[28:12]) : !(&m_source_a[28:12]);
    wire m_can_advance = !m_valid || agu_ready;

    typedef struct packed {
        logic valid;
        rob_id_t id;
        logic [31:0] target, predicted;
    } branch_result_t;
    branch_result_t branch_result;
    always_ff @(posedge clk) begin
        if (!resetn || flush) branch_result.valid <= 0;
        else begin
            branch_result.valid <= x_valid && !x_replay && x.dec.op == OP_JIRL;
            if (x_valid && !x_replay && x.dec.op == OP_JIRL) begin
                branch_result.id <= x.id;
                branch_result.target <= indirect_target_x;
                branch_result.predicted <= fetched[x.id].next_pc;
            end
        end
    end

    localparam int BUSES = 6;
    writeback_t wb [BUSES];
    wire result_x_next = x_early && !x_replay;
    wire result_y_next = y_valid && !y_replay;
    assign wb[0] = registered_x;
    assign wb[1] = registered_y;
    assign wb[4] = registered_agu;
    assign wb[5] = registered_load;
    always_ff @(posedge clk) begin
        if (!resetn || flush) begin
            registered_x.valid <= 0;
            registered_y.valid <= 0;
            registered_agu.valid <= 0;
            registered_load.valid <= 0;
        end else begin
            registered_x <= {result_x_next, x.id, x_data, fault_t'('0)};
            registered_y <= {result_y_next, y.id, y_data, fault_t'('0)};
            registered_agu <= agu_result;
            registered_load <= load_result;
        end
    end
    logic div_ready;
    wire div_start = x_div_busy && !x_replay;
    ooo_mdu mdu (
        .clk, .resetn, .flush, .mul_valid(x_valid && !x_replay && x.dec.fu == FU_MUL), .div_valid(div_start),
        .op(x.dec.op), .id(x.id), .a(x_source_a), .b(x_source_b), .div_ready,
        .mul_result(wb[2]), .div_result(wb[3])
    );

    function automatic operand_t wake(input operand_t source);
        operand_t next_source;
        logic [BUSES-1:0] matching;
        logic [31:0] bypassed;
        bypassed = 0;
        for (int bus = 0; bus < BUSES; bus++) begin
            matching[bus] = source.waiting && wb[bus].valid &&
                            !wb[bus].fault.valid && wb[bus].id == source.producer;
            bypassed |= wb[bus].data & {32{matching[bus]}};
        end
        next_source = source;
        if (|matching) begin
            next_source.waiting = 0;
            next_source.value = bypassed;
        end
        return next_source;
    endfunction

    function automatic operand_t rename(input logic [4:0] regno);
        operand_t source;
        rob_id_t producer;
        producer = writer[regno];
        source = '0;
        if (regno != 0) begin
            if (!pending_writer[regno]) source.value = architectural[regno];
            else if (writer_ready[regno]) source.value = speculative[regno];
            else begin
                source.waiting = 1;
                source.producer = producer;
            end
        end
        return wake(source);
    endfunction

    // Keep the newest unretired value beside its architectural register.
    // Rename reads one register index, avoiding a second ROB data lookup.
    for (genvar regno = 1; regno < 32; regno++) begin : latest_value
        logic [BUSES-1:0] matching;
        logic [31:0] value;
        always_comb begin
            value = 0;
            for (int bus = 0; bus < BUSES; bus++) begin
                matching[bus] = wb[bus].valid && !wb[bus].fault.valid && wb[bus].id == writer[regno];
                value |= wb[bus].data & {32{matching[bus]}};
            end
        end
        wire replace_writer = (dispatch0 && dec0.rd == 5'(regno)) || (dispatch1 && dec1.rd == 5'(regno));
        always_ff @(posedge clk) begin
            if (!resetn || replace_writer) writer_ready[regno] <= 0;
            else if (|matching) writer_ready[regno] <= 1;
            if (|matching) speculative[regno] <= value;
        end
    end
    assign writer_ready[0] = 0;
    assign speculative[0] = 0;

    // A producer in execute announces its destination before its data is
    // available. The consumer carries a one-hot bypass selection into execute.
    function automatic logic [2:0] next_bypass(input operand_t source);
        return {source.waiting && load_hint && source.producer == load_hint_id,
                source.waiting && y_valid && source.producer == y.id,
                source.waiting && x_early && source.producer == x.id};
    endfunction

    function automatic logic [ROB_SIZE-1:0] oldest(input logic [ROB_SIZE-1:0] candidates);
        logic [ROB_SIZE-1:0] grant;
        for (int i = 0; i < ROB_SIZE; i++)
            grant[i] = candidates[i] && (candidates & older_than[i]) == 0;
        return grant;
    endfunction

    operand_t awake_a [ROB_SIZE], awake_b [ROB_SIZE];
    logic [2:0] bypass_a [ROB_SIZE], bypass_b [ROB_SIZE];
    logic [ROB_SIZE-1:0] waiting_mem, request_x, request_y, ready_mem, retry, x_forwardable, divide;
    wire [ROB_SIZE-1:0] oldest_mem = oldest(waiting_mem);
    wire [ROB_SIZE-1:0] grant_x = oldest(request_x);
    wire [ROB_SIZE-1:0] grant_y = oldest(request_y);
    wire [ROB_SIZE-1:0] grant_m = ready_mem & oldest_mem & {ROB_SIZE{m_can_advance && !m_replay}};
    execute_t selected_x, selected_y, selected_m;
    for (genvar i = 0; i < ROB_SIZE; i++) begin : reservation
        assign awake_a[i] = wake(src_a[i]);
        assign awake_b[i] = wake(src_b[i]);
        assign bypass_a[i] = next_bypass(src_a[i]);
        assign bypass_b[i] = next_bypass(src_b[i]);
        assign retry[i] = (x_replay && x.id == rob_id_t'(i)) || (y_replay && y.id == rob_id_t'(i)) ||
                          (m_replay && m.id == rob_id_t'(i));
        wire waiting_issue = occupied[i] && !issued[i];
        wire ready = waiting_issue && (!src_a[i].waiting || |bypass_a[i]) &&
                     (!src_b[i].waiting || |bypass_b[i]);
        wire simple = decoded[i].fu == FU_ALU;
        assign x_forwardable[i] = simple || decoded[i].fu == FU_BRANCH;
        assign divide[i] = decoded[i].fu == FU_DIV;
        assign waiting_mem[i] = waiting_issue && decoded[i].fu == FU_MEMORY;
        assign request_x[i] = ready && ((simple && !prefer_second_alu[i]) || decoded[i].fu == FU_BRANCH ||
            decoded[i].fu == FU_MUL || (divide[i] && div_ready && !x_div_busy));
        assign ready_mem[i] = ready;
        assign request_y[i] = ready && simple && prefer_second_alu[i];
    end
    execute_t payload_x [ROB_SIZE/4], payload_y [ROB_SIZE/4], payload_m [ROB_SIZE/4];
    for (genvar bank = 0; bank < ROB_SIZE/4; bank++) begin : issue_payload
        execute_t from_x [4], from_y [4], from_m [4];
        for (genvar row = 0; row < 4; row++) begin : entry
            localparam int I = bank * 4 + row;
            wire execute_t uop = {decoded[I], src_a[I].value, src_b[I].value, fetched[I].pc,
                                  rob_id_t'(I), bypass_a[I], bypass_b[I]};
            assign from_x[row] = uop & {$bits(execute_t){grant_x[I]}};
            assign from_y[row] = uop & {$bits(execute_t){grant_y[I]}};
            assign from_m[row] = uop & {$bits(execute_t){grant_m[I]}};
        end
        assign payload_x[bank] = from_x[0] | from_x[1] | from_x[2] | from_x[3];
        assign payload_y[bank] = from_y[0] | from_y[1] | from_y[2] | from_y[3];
        assign payload_m[bank] = from_m[0] | from_m[1] | from_m[2] | from_m[3];
    end
    always_comb begin
        selected_x = '0;
        selected_y = '0;
        selected_m = '0;
        for (int bank = 0; bank < ROB_SIZE/4; bank++) begin
            selected_x |= payload_x[bank];
            selected_y |= payload_y[bank];
            selected_m |= payload_m[bank];
        end
    end

    wire rob_id_t tail1 = tail + 1'b1;
    wire dispatch0 = !flush && !serial_inflight && available != 0 && used < (PTR+1)'(ROB_SIZE);
    wire dispatch1 = dispatch0 && dec0.fu != FU_SYSTEM && !first.fault.valid &&
                     available == 2 && used < (PTR+1)'(ROB_SIZE - 1);
    assign pop_count = {1'b0, dispatch0} + {1'b0, dispatch1};
    wire operand_t same_pair = {1'b1, tail, 32'b0};
    wire operand_t second_a = dec0.rd != 0 && dec1.a == dec0.rd ? same_pair : rename(dec1.a);
    wire operand_t second_b = dec0.rd != 0 && dec1.b == dec0.rd ? same_pair : rename(dec1.b);
    wire first_prefers_y = !dispatch1 ? tail[0] : dec1.fu == FU_MEMORY ? tail[1] : dec1.fu != FU_ALU;
    wire second_prefers_y = dec0.fu == FU_MEMORY ? tail[1] : 1'b1;

    // Serial operations enter alone or as the last member of a dispatch
    // pair. No younger instruction can enter the ROB until they commit.
    wire has_head = used != 0;
    wire rob_id_t head1 = head + 1'b1;
    wire system_head = has_head && decoded[head].fu == FU_SYSTEM;
    wire operands_ready = !src_a[head].waiting && !src_b[head].waiting;
    wire system_ready = system_head && operands_ready && stores_drained && !faults[head].valid;
    function automatic logic refetch(input op_t op, input logic [4:0] csr_reg);
        case (op)
            OP_CSR: refetch = csr_reg != 0;
            OP_CACOP, OP_TLBRD, OP_TLBWR, OP_TLBFILL, OP_INVTLB, OP_ERTN, OP_IDLE, OP_IBAR: refetch = 1;
            default: refetch = 0;
        endcase
    endfunction

    logic system_active, system_done, atomic_store_succeeded;
    logic [31:0] serial_data;
    fault_t system_fault;
    wire interrupt_now = !flush && interrupt_pending && stores_drained && !io_load_busy && !system_active;
    assign allow_uncached_load = !interrupt_now;
    ooo_serial serial_exec (
        .clk, .resetn, .start(system_ready && !interrupt_now && !flush), .finish(system_commit || trap),
        .instruction(decoded[head]), .word(fetched[head].insn), .a(src_a[head].value), .b(src_b[head].value), .plv,
        .active(system_active), .done(system_done), .fault(system_fault), .value(serial_data),
        .op(system_op), .saved_word(system_insn), .saved_a(system_a), .saved_b(system_b), .csr_value(system_result),
        .translate(system_select), .va(system_va), .pa(atomic_pa), .translation_store(system_write),
        .translation(data_translation), .reservation_matches, .store_succeeded(atomic_store_succeeded),
        .drain_fetch, .invalidate_valid, .invalidate_mode, .invalidate_addr, .invalidate_ready,
        .cache_valid(system_cache_valid), .cache_request(system_cache_request),
        .cache_accept(system_cache_accept), .cache_done(system_cache_done), .cache_response
    );
    wire take_fault = has_head && stores_drained &&
        ((complete[head] && faults[head].valid) || (system_done && system_fault.valid));
    assign trap = interrupt_now || (!flush && take_fault);
    assign trap_fault = interrupt_now ? fault_t'({1'b1, E_INT, 1'b0, 32'b0}) :
                        faults[head].valid ? faults[head] : system_fault;
    assign trap_pc = has_head ? fetched[head].pc : committed_pc;

    wire branch0 = decoded[head].fu == FU_BRANCH;
    wire branch1 = decoded[head1].fu == FU_BRANCH;
    // Direct targets and fall-through PCs are immutable after dispatch.
    // Execution writes only the branch decision to the ROB. JIRL keeps
    // its separately calculated target in its own result field.
    function automatic logic [31:0] next_pc(input rob_id_t id);
        if (!taken[id]) return decoded[id].sequential_pc;
        return decoded[id].op == OP_JIRL ? indirect_target[id] : decoded[id].imm;
    endfunction
    wire [31:0] actual0 = system_op == OP_ERTN ? ertn_pc : next_pc(head);
    wire [31:0] actual1 = next_pc(head1);
    wire miss0 = wrong_next[head];
    wire miss1 = wrong_next[head1];
    wire store0 = decoded[head].op == OP_ST;
    wire store1 = decoded[head1].op == OP_ST;
    wire retires0 = has_head && !flush && !trap &&
        (system_head ? system_done : complete[head] && branch_resolved[head] && !faults[head].valid);
    wire retires1 = retires0 && !miss0 && !system_head && used >= 2 &&
                    complete[head1] && branch_resolved[head1] && !faults[head1].valid && decoded[head1].fu != FU_SYSTEM &&
                    !(branch0 && (branch1 || miss1)) && !(store0 && store1);
    assign retire0 = {retires0, fetched[head].pc, system_head ? serial_data : result[head], decoded[head].rd};
    assign retire1 = {retires1, fetched[head1].pc, result[head1], decoded[head1].rd};
    assign retire_store = (retires0 && store0) || (retires1 && store1);
    assign retire_io_load = retires0 && decoded[head].op == OP_LD && io_load_busy;
    assign system_commit = retires0 && system_head;
    assign reserve = system_commit && system_op == OP_LL;
    assign clear_reservation = system_commit && system_op == OP_SC;

    wire train_first = retires0 && (branch0 || miss0);
    wire train_second = retires1 && (branch1 || miss1);
    wire rob_id_t train_id = train_first ? head : head1;
    wire op_t train_op = decoded[train_id].op;
    assign train_valid = train_first || train_second;
    assign train_slot1 = train_second;
    assign train_control = decoded[train_id].fu == FU_BRANCH;
    assign train_indirect = train_op == OP_JIRL;
    assign train_taken = train_control && taken[train_id];
    assign train_conditional = train_control && train_op != OP_B && train_op != OP_BL && train_op != OP_JIRL;
    assign train_call = train_op == OP_BL || (train_op == OP_JIRL && decoded[train_id].rd == 1);
    assign train_return = train_op == OP_JIRL && decoded[train_id].rd == 0 &&
                          decoded[train_id].a == 1 && decoded[train_id].imm == 0;
    assign train_pc = fetched[train_id].pc;
    assign train_target = train_indirect ? indirect_target[train_id] : decoded[train_id].imm;
    assign train_link = decoded[train_id].sequential_pc;
    assign train_index = fetched[train_id].pht_index;
    assign train_tag_miss = !fetched[train_id].predicted_tag;
    assign train_direction_correct = train_taken ==
        (train_conditional ? fetched[train_id].predicted_direction : 1'b1);
    assign branch_miss = (retires0 && miss0) || (retires1 && miss1);
    assign data0 = retires0 && (decoded[head].fu == FU_MEMORY || system_op == OP_LL ||
                                 (system_op == OP_SC && atomic_store_succeeded));
    assign data1 = retires1 && decoded[head1].fu == FU_MEMORY;
    wire kill = trap || branch_miss || (system_commit && refetch(system_op, system_insn[9:5]));
    wire [31:0] committed_next = trap ? trap_target : retires1 ? actual1 : actual0;
    assign redirect_valid = kill;
    assign redirect_pc = committed_next;

    always_ff @(posedge clk) begin
        if (!resetn) begin
            idle <= 0;
            flush <= 0;
        end
        else begin
            flush <= kill;
            if (trap) idle <= 0;
            if (system_commit && system_op == OP_IDLE) idle <= 1;
        end
    end

    wire [1:0] retire_count = {1'b0, retires0} + {1'b0, retires1};
    wire rob_id_t head_next = head + rob_id_t'(retire_count);
    wire [ROB_SIZE-1:0] next_age_region = {ROB_SIZE{1'b1}} << head_next;
    for (genvar i = 0; i < ROB_SIZE; i++) begin : age_masks
        localparam logic [ROB_SIZE-1:0] LOWER_SLOTS = (ROB_SIZE'(1) << i) - ROB_SIZE'(1);
        always_ff @(posedge clk) begin
            if (!resetn || kill || flush) older_than[i] <= LOWER_SLOTS;
            else older_than[i] <= next_age_region[i] ? next_age_region & LOWER_SLOTS :
                                                     next_age_region | LOWER_SLOTS;
        end
    end
    always_ff @(posedge clk) begin
        if (!resetn) begin
            for (int i = 0; i < 32; i++) architectural[i] <= 0;
            committed_pc <= RESET_PC;
            head <= 0;
            tail <= 0;
            used <= 0;
            serial_inflight <= 0;
            occupied <= 0;
            issued <= 0;
            complete <= 0;
            pending_writer <= 0;
            x_valid <= 0;
            x_early <= 0;
            x_div_busy <= 0;
            y_valid <= 0;
            m_valid <= 0;
        end else begin
            if (retires0 && retire0.rd != 0) architectural[retire0.rd] <= retire0.data;
            if (retires1 && retire1.rd != 0) architectural[retire1.rd] <= retire1.data;
            if (retires0 || trap) committed_pc <= committed_next;
            if (kill || flush) begin
                head <= 0;
                tail <= 0;
                used <= 0;
                serial_inflight <= 0;
                occupied <= 0;
                issued <= 0;
                complete <= 0;
                pending_writer <= 0;
                x_valid <= 0;
                x_early <= 0;
                x_div_busy <= 0;
                y_valid <= 0;
                m_valid <= 0;
            end else begin
                used <= used + (PTR+1)'(pop_count) - (PTR+1)'(retire_count);
                head <= head_next;
                tail <= tail + rob_id_t'(pop_count);
                x_valid <= |grant_x;
                x_early <= |(grant_x & x_forwardable);
                x_div_busy <= |(grant_x & divide);
                y_valid <= |grant_y;
                if (m_can_advance || m_replay) m_valid <= |grant_m;
                issued <= (issued & ~retry) | grant_x | grant_y | grant_m;
                for (int bus = 0; bus < BUSES; bus++)
                    if (wb[bus].valid) complete[wb[bus].id] <= 1;
                if (x_direct_branch) complete[x.id] <= 1;
                if (retires0) begin
                    occupied[head] <= 0;
                    if (system_head) serial_inflight <= 0;
                    if (retire0.rd != 0 && writer[retire0.rd] == head) pending_writer[retire0.rd] <= 0;
                end
                if (retires1) begin
                    occupied[head1] <= 0;
                    if (retire1.rd != 0 && writer[retire1.rd] == head1) pending_writer[retire1.rd] <= 0;
                end
                if (dispatch0) begin
                    occupied[tail] <= 1;
                    issued[tail] <= first.fault.valid;
                    complete[tail] <= first.fault.valid;
                    if (dec0.fu == FU_SYSTEM || first.fault.valid) serial_inflight <= 1;
                    if (dec0.rd != 0) begin
                        writer[dec0.rd] <= tail;
                        pending_writer[dec0.rd] <= 1;
                    end
                end
                if (dispatch1) begin
                    occupied[tail1] <= 1;
                    issued[tail1] <= second.fault.valid;
                    complete[tail1] <= second.fault.valid;
                    if (dec1.fu == FU_SYSTEM || second.fault.valid) serial_inflight <= 1;
                    if (dec1.rd != 0) begin
                        writer[dec1.rd] <= tail1;
                        pending_writer[dec1.rd] <= 1;
                    end
                end
            end
        end
    end

    // Recovery clears validity and tags. Unreferenced payloads do not need a
    // reset or the global kill signal on their write enables.
    always_ff @(posedge clk) begin
        x <= selected_x;
        y <= selected_y;
        if (m_can_advance) m <= selected_m;
        else begin
            m.a <= m_source_a;
            m.b <= m_source_b;
            m.bypass_a <= 0;
            m.bypass_b <= 0;
        end
        for (int i = 0; i < ROB_SIZE; i++)
            if (occupied[i] && (!issued[i] || retry[i])) begin
                src_a[i] <= awake_a[i];
                src_b[i] <= awake_b[i];
            end
        for (int bus = 0; bus < BUSES; bus++)
            if (wb[bus].valid) begin
                result[wb[bus].id] <= wb[bus].data;
                faults[wb[bus].id] <= wb[bus].fault;
            end
        if (branch_result.valid) begin
            indirect_target[branch_result.id] <= branch_result.target;
            taken[branch_result.id] <= 1;
            wrong_next[branch_result.id] <= branch_result.predicted != branch_result.target;
            branch_resolved[branch_result.id] <= 1;
        end
        if (x_direct_branch) begin
            taken[x.id] <= branch_taken_x;
            wrong_next[x.id] <= branch_taken_x ? !x.dec.predicted_target : !x.dec.predicted_seq;
            branch_resolved[x.id] <= 1;
        end
        if (dispatch0) begin
            fetched[tail] <= first;
            decoded[tail] <= dec0;
            prefer_second_alu[tail] <= first_prefers_y;
            src_a[tail] <= rename(dec0.a);
            src_b[tail] <= rename(dec0.b);
            faults[tail] <= first.fault;
            taken[tail] <= 0;
            wrong_next[tail] <= !dec0.predicted_seq;
            branch_resolved[tail] <= dec0.fu != FU_BRANCH;
            if (dec0.fu == FU_BRANCH) result[tail] <= dec0.sequential_pc;
        end
        if (dispatch1) begin
            fetched[tail1] <= second;
            decoded[tail1] <= dec1;
            prefer_second_alu[tail1] <= second_prefers_y;
            src_a[tail1] <= second_a;
            src_b[tail1] <= second_b;
            faults[tail1] <= second.fault;
            taken[tail1] <= 0;
            wrong_next[tail1] <= !dec1.predicted_seq;
            branch_resolved[tail1] <= dec1.fu != FU_BRANCH;
            if (dec1.fu == FU_BRANCH) result[tail1] <= dec1.sequential_pc;
        end
    end
endmodule
