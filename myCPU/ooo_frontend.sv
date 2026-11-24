module ooo_frontend (
    input logic clk, resetn,
    input logic flush, idle, drain,
    input logic redirect_valid,
    input logic [31:0] redirect_pc,
    output logic [31:0] fetch_va,
    input logic direct_valid,
    input ooo_pkg::translation_t direct_translation, tlb_translation,
    output logic fetch_lookup,
    input logic [31:0] predicted_next,
    input logic [2:0] predicted_count,
    input logic [9:0] predicted_index,
    input logic [3:0] predicted_tag_hit, predicted_direction,
    input logic predicted_sequential,
    output logic predictor_accept,

    output logic cache_valid,
    output logic [31:0] cache_pa,
    output logic cache_cached, cache_prefetch,
    input logic cache_ready, cache_response,
    output logic cache_response_ready,
    input logic [127:0] cache_line,
    input logic cache_error,

    output logic [1:0] available,
    output ooo_pkg::fetch_t first, second,
    input logic [1:0] pop_count
);
    import ooo_pkg::*;

    localparam int DEPTH = 8, PTR = $clog2(DEPTH);
    fetch_t fifo [4][DEPTH/4];
    logic [DEPTH-1:0] read_slot;
    logic [PTR-1:0] write_ptr;
    logic [PTR:0] used;
    logic inflight, discard, fault_block;
    logic [31:0] current_pc, request_pc, request_next;
    logic [2:0] request_count;
    logic [9:0] request_pht;
    logic [3:0] request_tag_hit, request_direction;
    typedef struct packed {
        logic [31:0] pc, next_pc, pa;
        logic [2:0] count;
        logic [9:0] pht;
        logic [3:0] tag_hit, direction_taken;
        logic cached, prefetch;
    } request_t;
    request_t request0, request1;
    logic [1:0] queued;
    logic req_read, req_write;
    wire request_t oldest_request = req_read ? request1 : request0;
    logic tlb_pending, page_valid, page_cached;
    logic [19:0] page_va, page_pa;
    // Retirement puts the redirect in the PC register at the same edge
    // that starts recovery. The predictor always reads a registered PC.
    assign fetch_va = current_pc;
    wire page_hit = !flush && page_valid && page_va == fetch_va[31:12];
    wire translation_ready = direct_valid || page_hit || (!flush && tlb_pending);
    wire translation_t saved_translation = {{page_pa, fetch_va[11:0]}, page_cached, fault_t'('0)};
    wire translation_t translation = direct_valid ? direct_translation :
                                     page_hit ? saved_translation : tlb_translation;
    wire [2:0] response_count = cache_error ? 3'd1 : request_count;
    wire [PTR:0] space = (PTR+1)'(DEPTH) - used;
    assign cache_response_ready = inflight && (discard || flush || drain || space >= (PTR+1)'(response_count));
    wire response_accept = cache_response && cache_response_ready;
    wire push_response = response_accept && !discard && !flush && !drain;
    wire can_fetch = !idle && !drain && (flush || !fault_block);
    assign fetch_lookup = can_fetch && !translation_ready;
    wire push_fault = !flush && !inflight && queued == 0 && can_fetch && translation_ready &&
                      translation.fault.valid && space != 0;
    // Registered space keeps tag hits and response backpressure out of
    // the PC/history feedback loop. Two entries sustain one packet per cycle.
    wire queue_push = can_fetch && translation_ready && !translation.fault.valid &&
                      (flush || queued < 2);
    assign predictor_accept = queue_push && translation.cached;
    wire [31:0] next_va = translation.cached ? predicted_next : fetch_va + 32'd4;
    wire request_t new_request = {fetch_va, next_va, translation.pa,
        translation.cached ? predicted_count : 3'd1, predicted_index,
        predicted_tag_hit & {4{translation.cached}}, predicted_direction & {4{translation.cached}},
        translation.cached, predicted_sequential && translation.cached};
    // On recovery the new packet can bypass the queue. Prediction advances
    // either way; the cache only determines whether the packet stays queued.
    wire request_t offered = flush ? new_request : oldest_request;
    assign cache_valid = !drain && !idle && (flush ? queue_push : queued != 0) &&
                         (!inflight || response_accept) && !(push_response && cache_error);
    assign cache_pa = offered.pa;
    assign cache_cached = offered.cached;
    assign cache_prefetch = offered.prefetch;
    wire launch = cache_valid && cache_ready;
    // Register the read address in one-hot form. The adjacent port uses
    // the same selects rotated by one slot, with no carry or bank decode.
    always_comb begin
        first = '0;
        second = '0;
        for (int entry = 0; entry < DEPTH; entry++) begin
            first |= fifo[entry % 4][entry / 4] & {$bits(fetch_t){read_slot[entry]}};
            second |= fifo[entry % 4][entry / 4] &
                      {$bits(fetch_t){read_slot[(entry + DEPTH - 1) % DEPTH]}};
        end
    end
    assign available = used >= 2 ? 2'd2 : {1'b0, used[0]};
    wire [2:0] push_count = push_response ? response_count : push_fault ? 3'd1 : 3'd0;

    fetch_t payload [4];
    for (genvar slot = 0; slot < 4; slot++) begin : packet
        wire [1:0] word = request_pc[3:2] + 2'(slot);
        wire [31:0] pc = request_pc + 32'(4*slot);
        wire [31:0] next_pc = request_count == 3'(slot + 1) ? request_next : pc + 32'd4;
        wire fault_t fetch_fault = {cache_error, E_ADE, 1'b0, pc};
        assign payload[slot] = {pc, cache_line[32*word +: 32], next_pc, request_pht,
                                request_tag_hit[word], request_direction[word], fetch_fault};
    end

    wire fetch_t fault_packet = {fetch_va, 32'b0, fetch_va + 32'd4, 12'b0, translation.fault};
    // A contiguous packet writes each modulo-four bank at most once.
    for (genvar bank = 0; bank < 4; bank++) begin : fifo_bank
        wire [1:0] slot = 2'(bank) - write_ptr[1:0];
        wire wrap_bank = 2'(bank) < write_ptr[1:0];
        wire [PTR-3:0] row_index = write_ptr[PTR-1:2] + (PTR-2)'(wrap_bank);
        wire write_fault = push_fault && slot == 0;
        wire write_packet = push_response && 3'(slot) < request_count && (!cache_error || slot == 0);
        wire fetch_t entry = write_fault ? fault_packet : payload[slot];
        for (genvar row = 0; row < DEPTH/4; row++) begin : fifo_row
            always_ff @(posedge clk)
                if (row_index == (PTR-2)'(row) && (write_packet || write_fault))
                    fifo[bank][row] <= entry;
        end
    end

    always_ff @(posedge clk) begin
        if (!resetn) begin
            current_pc <= RESET_PC;
            read_slot <= DEPTH'(1);
            write_ptr <= 0;
            used <= 0;
            inflight <= 0;
            discard <= 0;
            fault_block <= 0;
            request_pc <= 0;
            request_next <= 0;
            request_count <= 0;
            request_pht <= 0;
            request_tag_hit <= 0;
            request_direction <= 0;
            queued <= 0;
            req_read <= 0;
            req_write <= 0;
            tlb_pending <= 0;
            page_valid <= 0;
        end else begin
            if (response_accept) begin
                inflight <= 0;
                discard <= 0;
            end
            if (flush) begin
                read_slot <= DEPTH'(1);
                write_ptr <= 0;
                used <= 0;
                fault_block <= 0;
                tlb_pending <= fetch_lookup;
                page_valid <= 0;
                queued <= 2'(queue_push && !launch);
                req_read <= 0;
                req_write <= queue_push && !launch;
                if (inflight && !response_accept) discard <= 1;
            end else begin
                used <= used + (PTR+1)'(push_count) - (PTR+1)'(pop_count);
                case (pop_count)
                    2'd1: read_slot <= {read_slot[DEPTH-2:0], read_slot[DEPTH-1]};
                    2'd2: read_slot <= {read_slot[DEPTH-3:0], read_slot[DEPTH-1:DEPTH-2]};
                    default: ;
                endcase
                write_ptr <= write_ptr + PTR'(push_count);
                if (push_fault) fault_block <= 1;
                if (push_response && cache_error) begin
                    fault_block <= 1;
                    queued <= 0;
                end else queued <= queued + 2'(queue_push) - 2'(launch);
                if (queue_push) req_write <= !req_write;
                if (launch) req_read <= !req_read;
                if (fetch_lookup) tlb_pending <= 1;
                if (tlb_pending && !tlb_translation.fault.valid) begin
                    page_valid <= 1;
                    page_va <= fetch_va[31:12];
                    page_pa <= tlb_translation.pa[31:12];
                    page_cached <= tlb_translation.cached;
                    tlb_pending <= 0;
                end
                if (push_fault) tlb_pending <= 0;
            end
            if (queue_push) begin
                if (flush || !req_write) request0 <= new_request;
                else request1 <= new_request;
            end
            if (redirect_valid) current_pc <= redirect_pc;
            else if (queue_push) current_pc <= next_va;
            if (launch) begin
                request_pc <= offered.pc;
                request_next <= offered.next_pc;
                request_count <= offered.count;
                request_pht <= offered.pht;
                request_tag_hit <= offered.tag_hit;
                request_direction <= offered.direction_taken;
                inflight <= 1;
                discard <= 0;
            end
        end
    end
endmodule
