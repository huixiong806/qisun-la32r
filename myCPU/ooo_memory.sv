module ooo_memory (
    input logic clk, resetn, flush,
    input logic agu_valid,
    input ooo_pkg::agu_t agu_request,
    output logic agu_ready,
    output ooo_pkg::writeback_t agu_result, load_result,
    input ooo_pkg::rob_id_t rob_head,
    input logic retire_store, retire_io_load, allow_uncached_load,
    output logic [31:0] retiring_store_pa,
    output logic stores_drained, io_load_busy,

    input logic system_select,
    input logic [31:0] system_va,
    input logic system_write,
    output logic [31:0] data_va, lookup_va,
    output logic data_lookup, lookup_store,
    input logic data_direct_valid,
    input ooo_pkg::translation_t data_direct, lookup_translation,
    input logic [31:0] fast_pa,
    input logic fast_cached,
    input logic system_cache_valid,
    input ooo_pkg::data_req_t system_cache_request,
    output logic system_cache_accept, system_cache_done,

    output logic cache_valid,
    output ooo_pkg::data_req_t cache_request,
    input logic cache_ready, cache_response_valid,
    input ooo_pkg::data_resp_t cache_response,
    output logic store_bus_error
);
    import ooo_pkg::*;
    localparam int SQ_SIZE = 4, SQ_PTR = $clog2(SQ_SIZE);
    typedef logic [SQ_PTR:0] sq_index_t;
    store_t store_queue [SQ_SIZE];
    // All four pointers advance in program order. Only the interval from
    // pop to commit survives a branch recovery or exception.
    sq_index_t sq_pop, sq_issue, sq_commit, sq_push;
    logic [SQ_SIZE-1:0] store_live, store_committed;
    wire sq_index_t commit_next = sq_commit + sq_index_t'(retire_store);
    assign stores_drained = sq_pop == sq_commit;
    assign retiring_store_pa = store_queue[sq_commit[SQ_PTR-1:0]].addr;

    agu_t agu, skid;
    logic [1:0] agu_count;
    wire agu_pending = agu_count != 0;
    wire store = agu.dec.op == OP_ST;
    wire prefetch = agu.dec.op == OP_PRELD;
    wire [1:0] offset = agu.va[1:0];
    wire [3:0] mask = byte_mask(offset, agu.dec.size);
    wire [31:0] shifted_data = agu.store_data << (8 * offset);
    wire misaligned = (agu.dec.size == 1 && offset[0]) || (agu.dec.size == 2 && offset != 0);
    logic translated;
    wire translation_t translation = data_direct_valid ? data_direct : lookup_translation;
    fault_t mem_fault;
    always_comb begin
        mem_fault = translation.fault;
        if (misaligned) mem_fault = {1'b1, E_ALE, 1'b1, agu.va};
        if (prefetch) mem_fault = '0;
    end
    assign data_va = agu.va;
    assign lookup_va = system_select ? system_va : agu.va;
    assign lookup_store = system_select ? system_write : store;
    wire translate_normal = agu_pending && !data_direct_valid && !translated && !system_select && !flush;
    assign data_lookup = system_select || translate_normal;

    logic [3:0] coverage;
    logic [31:0] forwarded_data;
    logic [SQ_SIZE-1:0] uncached, same_word;
    for (genvar n = 0; n < SQ_SIZE; n++) begin : compare_store
        wire same_offset = store_queue[n].addr[11:2] == agu.va[11:2];
        wire direct_page = store_queue[n].addr[31:12] == data_direct.pa[31:12];
        wire translated_page = store_queue[n].addr[31:12] == lookup_translation.pa[31:12];
        assign uncached[n] = store_live[n] && !store_queue[n].cached;
        assign same_word[n] = store_live[n] && same_offset &&
                              (data_direct_valid ? direct_page : translated_page);
    end
    wire uncached_store_pending = |uncached;
    wire [SQ_SIZE-1:0] before_tail = ~({SQ_SIZE{1'b1}} << sq_push[SQ_PTR-1:0]);
    always_comb begin
        coverage = 0;
        forwarded_data = 0;
        for (int b = 0; b < 4; b++) begin
            logic [3:0] match_byte, selected;
            for (int n = 0; n < SQ_SIZE; n++) match_byte[n] = same_word[n] && store_queue[n].mask[b];
            selected = |(match_byte & before_tail) ? match_byte & before_tail : match_byte;
            coverage[b] = |match_byte;
            casez (selected)
                4'b1???: forwarded_data[b*8 +: 8] = store_queue[3].data[b*8 +: 8];
                4'b01??: forwarded_data[b*8 +: 8] = store_queue[2].data[b*8 +: 8];
                4'b001?: forwarded_data[b*8 +: 8] = store_queue[1].data[b*8 +: 8];
                4'b0001: forwarded_data[b*8 +: 8] = store_queue[0].data[b*8 +: 8];
                default: ;
            endcase
        end
    end
    wire store_pending = sq_issue != sq_commit;
    wire uncached_load_allowed = agu.id == rob_head && stores_drained && allow_uncached_load;
    wire load_unblocked = !uncached_store_pending && (translation.cached || uncached_load_allowed);
    wire forward_full = translation.cached && ((coverage & mask) == mask);
    wire forward_partial = |(coverage & mask) && !forward_full;
    wire normal_valid = agu_pending && (data_direct_valid || translated) && !flush && !system_select;
    wire new_store = normal_valid && store && !mem_fault.valid && !(&store_live);
    wire forward_load = normal_valid && !store && !prefetch && !mem_fault.valid && load_unblocked && forward_full;
    wire normal_cache_valid = normal_valid && !store && !prefetch && !mem_fault.valid && load_unblocked &&
                              !forward_full && !forward_partial;
    wire prefetch_valid = normal_valid && prefetch && translation.cached &&
                          !translation.fault.valid && !uncached_store_pending && coverage == 0;
    logic request_queued;
    data_req_t queued_request, incoming_request;
    wire ingress_ready = !request_queued;
    // Permit a short burst of unrelated cached loads ahead of a
    // committed store. Bound the delay even in a continuous load stream.
    logic [1:0] loads_ahead_of_store;
    wire [SQ_PTR:0] stores_live = sq_push - sq_pop;
    wire prioritize_load = normal_cache_valid && translation.cached &&
                           stores_live < 3 && !(&loads_ahead_of_store);
    wire issue_store = store_pending && !prioritize_load;
    wire ordinary_cache = !system_cache_valid && !issue_store;
    wire load_accept = ordinary_cache && normal_cache_valid && ingress_ready;
    // A cached direct-mapped load may skip the address queue when it cannot
    // encounter an older store. It falls into the queue under backpressure.
    wire fast_aligned = !(agu_request.dec.size == 1 && agu_request.va[0]) &&
                        !(agu_request.dec.size == 2 && agu_request.va[1:0] != 0);
    wire fast_valid = agu_valid && !agu_pending && store_live == 0 && agu_request.dec.op == OP_LD &&
                      fast_cached && fast_aligned && !system_select && !flush;
    wire fast_accept = ordinary_cache && fast_valid && ingress_ready;
    wire store_accept = !system_cache_valid && issue_store && ingress_ready;
    assign system_cache_accept = system_cache_valid && ingress_ready;

    always_ff @(posedge clk) begin
        if (!resetn || store_accept || !store_pending) loads_ahead_of_store <= 0;
        else if (load_accept) loads_ahead_of_store <= loads_ahead_of_store + 1'b1;
    end
    wire incoming_valid = system_cache_valid || issue_store || normal_cache_valid || prefetch_valid || fast_valid;
    // Keep the normal hit path combinational, but absorb one request when
    // the cache blocks. The AGU sees only registered ingress backpressure.
    wire queued_live = request_queued && (!flush || queued_request.token[6]);
    assign cache_valid = queued_live || (ingress_ready && incoming_valid);
    assign cache_request = request_queued ? queued_request : incoming_request;
    wire sent_to_cache = cache_valid && cache_ready;
    always_comb begin
        incoming_request = '0;
        if (system_cache_valid) begin
            incoming_request = system_cache_request;
            incoming_request.token = 7'b1100000;
        end else if (issue_store) begin
            incoming_request.access = store_queue[sq_issue[SQ_PTR-1:0]];
            incoming_request.write = 1;
            incoming_request.token = 7'b1000000;
        end else if (fast_valid) begin
            incoming_request.access.addr = fast_pa;
            incoming_request.access.size = agu_request.dec.size;
            incoming_request.access.cached = 1;
            incoming_request.zero_extend = agu_request.dec.unsigned_load;
            incoming_request.token = 7'(agu_request.id);
        end else begin
            incoming_request.access.addr = translation.pa;
            incoming_request.access.size = agu.dec.size;
            incoming_request.access.cached = translation.cached;
            incoming_request.zero_extend = agu.dec.unsigned_load;
            incoming_request.token = prefetch ? 7'b0100000 : 7'(agu.id);
        end
    end

    wire agu_complete = normal_valid && (mem_fault.valid || new_store || forward_load || prefetch);
    wire agu_advance = agu_complete || load_accept;
    assign agu_ready = agu_count != 2;
    wire accept_agu = agu_valid && agu_ready && !fast_accept;
    assign agu_result = {agu_complete, agu.id,
        load_value(forwarded_data, offset, agu.dec.size, agu.dec.unsigned_load), mem_fault};

    logic [31:0] load_va [ROB_SIZE];
    logic [ROB_SIZE-1:0] load_live;
    wire rob_id_t load_id = cache_response.token[$bits(rob_id_t)-1:0];
    wire load_response = cache_response_valid && cache_response.token[6:5] == 0 && load_live[load_id];
    wire store_response = cache_response_valid && cache_response.token[6:5] == 2;
    wire [SQ_SIZE-1:0] store_pop_mask = SQ_SIZE'(store_response) << sq_pop[SQ_PTR-1:0];
    wire [SQ_SIZE-1:0] store_commit_mask = SQ_SIZE'(retire_store) << sq_commit[SQ_PTR-1:0];
    wire [SQ_SIZE-1:0] store_push_mask = SQ_SIZE'(new_store) << sq_push[SQ_PTR-1:0];
    wire [SQ_SIZE-1:0] committed_next = (store_committed & ~store_pop_mask) | store_commit_mask;
    assign system_cache_done = cache_response_valid && cache_response.token[6:5] == 3;
    assign store_bus_error = store_response && cache_response.error;
    assign load_result = {load_response, load_id, cache_response.data,
        fault_t'({cache_response.error, E_ADE, 1'b1, load_va[load_id]})};

    always_ff @(posedge clk) begin
        if (!resetn) begin
            agu_count <= 0;
            sq_pop <= 0;
            sq_issue <= 0;
            sq_commit <= 0;
            sq_push <= 0;
            store_live <= 0;
            store_committed <= 0;
            request_queued <= 0;
            load_live <= 0;
            io_load_busy <= 0;
            translated <= 0;
        end else begin
            if (ingress_ready) queued_request <= incoming_request;
            if (request_queued) begin
                if (!queued_live || cache_ready) request_queued <= 0;
            end else if (incoming_valid && !cache_ready && incoming_request.token[6:5] != 1) begin
                request_queued <= 1;
            end
            if (store_response) sq_pop <= sq_pop + 1'b1;
            if (store_accept) sq_issue <= sq_issue + 1'b1;
            sq_commit <= commit_next;
            store_committed <= committed_next;
            store_live <= flush ? committed_next : (store_live & ~store_pop_mask) | store_push_mask;
            if (flush) begin
                agu_count <= 0;
                sq_push <= commit_next;
                load_live <= 0;
                io_load_busy <= 0;
                translated <= 0;
            end else begin
                if (translate_normal) translated <= 1;
                if (agu_advance) translated <= 0;
                agu_count <= agu_count + 2'(accept_agu) - 2'(agu_advance);
                if (agu_advance && agu_count == 2) agu <= skid;
                if (accept_agu) begin
                    if (!agu_pending || agu_advance) agu <= agu_request;
                    else skid <= agu_request;
                end
                if (new_store) begin
                    store_queue[sq_push[SQ_PTR-1:0]] <=
                        {translation.pa, shifted_data, mask, agu.dec.size, translation.cached};
                    sq_push <= sq_push + 1'b1;
                end
                if (load_response) begin
                    load_live[load_id] <= 0;
                end
                // Record the ROB tag only after the cache takes the packet.
                // A stale response after a flush cannot match a queued load.
                if (sent_to_cache && cache_request.token[6:5] == 0)
                    load_live[rob_id_t'(cache_request.token)] <= 1;
                if (retire_io_load) io_load_busy <= 0;
                if (load_accept && !translation.cached) io_load_busy <= 1;
                if (load_accept || fast_accept)
                    load_va[fast_accept ? agu_request.id : agu.id] <= fast_accept ? agu_request.va : agu.va;
            end
        end
    end
endmodule
