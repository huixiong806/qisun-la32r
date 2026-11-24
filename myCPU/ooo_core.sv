module ooo_core (
    input logic clk, resetn,
    input logic [7:0] ext_int,
    output logic [3:0] arid,
    output logic [31:0] araddr,
    output logic [7:0] arlen,
    output logic [2:0] arsize,
    output logic arvalid,
    input logic arready,
    input logic [3:0] rid,
    input logic [31:0] rdata,
    input logic [1:0] rresp,
    input logic rlast, rvalid,
    output logic rready,
    output logic [31:0] awaddr,
    output logic [7:0] awlen,
    output logic [2:0] awsize,
    output logic awvalid,
    input logic awready,
    output logic [31:0] wdata,
    output logic [3:0] wstrb,
    output logic wlast, wvalid,
    input logic wready,
    input logic [1:0] bresp,
    input logic bvalid,
    output logic bready,
    output logic debug_valid, debug1_valid, debug_exception,
    output logic [31:0] debug_wb_pc, debug1_wb_pc, debug_wb_rf_wdata, debug1_wb_rf_wdata,
    output logic [3:0] debug_wb_rf_we, debug1_wb_rf_we,
    output logic [4:0] debug_wb_rf_wnum, debug1_wb_rf_wnum
);
    import ooo_pkg::*;

    logic flush, idle, drain_fetch, redirect_valid;
    logic [31:0] fetch_va, data_va, lookup_va, redirect_pc;
    translation_t fetch_direct, fetch_translation, data_direct, data_translation;
    logic lookup_store, fetch_lookup, data_lookup, fetch_direct_valid, data_direct_valid;
    logic [2:0] agu_segment, fast_pa_segment;
    logic agu_same_segment, fast_cached;
    logic [1:0] plv;
    logic interrupt_pending;

    logic system_commit, trap, reserve, clear_reservation, reservation_matches;
    op_t system_op;
    logic [31:0] system_insn, system_a, system_b, system_result, ertn_pc;
    logic [31:0] trap_pc, trap_target, atomic_pa, retiring_store_pa;
    fault_t trap_fault;
    logic retire_store;
    ooo_priv privileged_state (
        .clk, .resetn, .ext_int, .fetch_va, .data_va, .fast_segment(agu_segment), .lookup_va, .lookup_store, .fetch_lookup, .data_lookup,
        .fetch_direct, .fetch_direct_valid, .fetch_translation,
        .data_direct, .data_direct_valid, .data_translation, .plv, .interrupt_pending,
        .fast_pa_segment, .fast_cached,
        .system_commit, .system_op, .system_insn, .system_a, .system_b, .system_result, .ertn_pc,
        .trap, .trap_fault, .trap_pc, .trap_target, .reserve, .clear_reservation,
        .ordinary_store(retire_store), .atomic_pa, .store_pa(retiring_store_pa), .reservation_matches
    );

    logic train_valid, train_control, train_taken, train_conditional, train_call, train_return;
    logic train_slot1, train_indirect, data0, data1;
    logic train_tag_miss, train_direction_correct;
    logic [31:0] train_pc, train_target, train_link, predicted_next;
    logic [9:0] train_index, predicted_index;
    logic [2:0] predicted_count;
    logic [3:0] predicted_tag_hit, predicted_direction;
    logic predictor_accept, predicted_sequential, branch_miss;
    ooo_predict predictor (
        .clk, .resetn, .fetch_pc(fetch_va),
        .fetch_accept(predictor_accept), .redirect_valid, .next_pc(predicted_next),
        .word_count(predicted_count), .pht_index(predicted_index), .sequential(predicted_sequential),
        .tag_hit(predicted_tag_hit), .direction_taken(predicted_direction),
        .train_valid, .train_control, .train_taken, .train_conditional, .train_call, .train_return,
        .train_pc, .train_target, .train_link, .train_index
    );

    logic ic_valid, ic_ready, ic_cached, ic_prefetch, ic_resp_valid, ic_resp_ready, ic_error;
    logic [31:0] ic_pa;
    logic [127:0] ic_line;
    logic [1:0] available, pop_count, fetch_available, fetch_pop;
    fetch_t first, second, fetch0, fetch1;
    decode_t dec0, dec1;
    ooo_frontend frontend (
        .clk, .resetn, .flush, .idle, .drain(drain_fetch), .redirect_valid, .redirect_pc, .fetch_va,
        .direct_valid(fetch_direct_valid), .direct_translation(fetch_direct), .tlb_translation(fetch_translation),
        .fetch_lookup, .predicted_next, .predicted_count, .predicted_index, .predicted_tag_hit, .predicted_direction,
        .predicted_sequential, .predictor_accept,
        .cache_valid(ic_valid), .cache_pa(ic_pa), .cache_cached(ic_cached), .cache_prefetch(ic_prefetch),
        .cache_ready(ic_ready),
        .cache_response(ic_resp_valid), .cache_response_ready(ic_resp_ready),
        .cache_line(ic_line), .cache_error(ic_error), .available(fetch_available),
        .first(fetch0), .second(fetch1), .pop_count(fetch_pop)
    );
    ooo_decode_pipe decode_pipe (
        .clk, .resetn, .flush, .fetch_count(fetch_available), .fetch0, .fetch1, .fetch_pop,
        .count(available), .first, .second, .first_decoded(dec0), .second_decoded(dec1), .pop(pop_count)
    );

    logic agu_valid, agu_ready, stores_drained, io_load_busy, retire_io_load, allow_uncached_load;
    agu_t agu_request;
    wire [31:0] fast_pa = {fast_pa_segment, agu_request.va[28:0]};
    writeback_t agu_result, load_result;
    rob_id_t rob_head;
    logic system_select, system_write, system_cache_valid, system_cache_accept, system_cache_done;
    logic system_cache_done_d;
    logic [31:0] system_va;
    data_req_t system_cache_request;
    logic dc_valid, dc_ready, dc_resp_valid, store_bus_error;
    logic load_hint;
    rob_id_t load_hint_id;
    data_req_t dc_request;
    data_resp_t dc_response, system_cache_response;
    always_ff @(posedge clk) begin
        if (!resetn) system_cache_done_d <= 0;
        else system_cache_done_d <= system_cache_done;
        system_cache_response <= dc_response;
    end
    ooo_memory memory_order (
        .clk, .resetn, .flush, .agu_valid, .agu_request, .agu_ready, .agu_result, .load_result,
        .rob_head, .retire_store, .retire_io_load, .allow_uncached_load,
        .retiring_store_pa, .stores_drained, .io_load_busy,
        .system_select, .system_va, .system_write, .data_va, .lookup_va, .lookup_store, .data_lookup,
        .data_direct_valid, .data_direct, .lookup_translation(data_translation),
        .fast_pa, .fast_cached(fast_cached && agu_same_segment),
        .system_cache_valid, .system_cache_request, .system_cache_accept, .system_cache_done,
        .cache_valid(dc_valid), .cache_request(dc_request), .cache_ready(dc_ready),
        .cache_response_valid(dc_resp_valid), .cache_response(dc_response), .store_bus_error
    );

    logic invalidate_valid, invalidate_ready;
    logic [1:0] invalidate_mode;
    logic [31:0] invalidate_addr;
    retire_t retire0, retire1;
    ooo_backend backend (
        .clk, .resetn, .available, .first, .second, .dec0, .dec1, .pop_count, .flush, .idle, .drain_fetch,
        .redirect_valid, .redirect_pc, .retire0, .retire1,
        .train_valid, .train_control, .train_taken, .train_conditional, .train_call, .train_return,
        .train_slot1, .train_indirect, .train_pc, .train_target, .train_link, .train_index, .branch_miss, .data0, .data1,
        .train_tag_miss, .train_direction_correct,
        .plv, .interrupt_pending, .system_commit, .system_op, .system_insn, .system_a, .system_b,
        .system_result, .ertn_pc, .trap, .trap_fault, .trap_pc, .trap_target,
        .reserve, .clear_reservation, .atomic_pa, .reservation_matches,
        .invalidate_valid, .invalidate_mode, .invalidate_addr, .invalidate_ready,
        .agu_valid, .agu_request, .agu_segment, .agu_same_segment,
        .agu_ready, .agu_result, .load_result, .load_hint, .load_hint_id, .rob_head,
        .retire_store, .retire_io_load, .allow_uncached_load, .stores_drained, .io_load_busy,
        .system_select, .system_va, .system_write, .data_translation,
        .system_cache_valid, .system_cache_request, .system_cache_accept, .system_cache_done(system_cache_done_d),
        .cache_response(system_cache_response)
    );

    logic i_read_valid, d_read_valid, i_read_accept, d_read_accept, i_beat_valid, d_beat_valid;
    logic write_valid, write_accept, write_done, write_error;
    logic ic_miss, dc_miss;
    read_req_t i_read, d_read;
    read_beat_t beat;
    write_req_t write_request;
    ooo_icache icache (
        .clk, .resetn, .cancel(flush), .req_valid(ic_valid), .req_pa(ic_pa), .req_cached(ic_cached),
        .req_prefetch(ic_prefetch), .req_ready(ic_ready),
        .resp_valid(ic_resp_valid), .resp_ready(ic_resp_ready), .resp_line(ic_line), .resp_error(ic_error),
        .invalidate_valid, .invalidate_mode, .invalidate_addr, .invalidate_ready,
        .read_valid(i_read_valid), .read_request(i_read), .read_accept(i_read_accept),
        .beat_valid(i_beat_valid), .beat, .miss_event(ic_miss)
    );
    ooo_dcache dcache (
        .clk, .resetn, .req_valid(dc_valid), .request(dc_request), .req_ready(dc_ready),
        .resp_valid(dc_resp_valid), .response(dc_response), .load_hint, .load_hint_id,
        .read_valid(d_read_valid), .read_request(d_read), .read_accept(d_read_accept),
        .beat_valid(d_beat_valid), .beat, .write_valid, .write_request, .write_accept, .write_done,
        .write_error, .miss_event(dc_miss)
    );
    ooo_axi bus (
        .clk, .resetn, .i_valid(i_read_valid), .d_valid(d_read_valid), .i_request(i_read), .d_request(d_read),
        .i_accept(i_read_accept), .d_accept(d_read_accept), .i_beat_valid, .d_beat_valid, .read_beat(beat),
        .write_valid, .write_request, .write_accept, .write_done, .write_error,
        .arid, .araddr, .arlen, .arsize, .arvalid, .arready, .rid, .rdata, .rresp, .rlast, .rvalid, .rready,
        .awaddr, .awlen, .awsize, .awvalid, .awready, .wdata, .wstrb, .wlast, .wvalid, .wready,
        .bresp, .bvalid, .bready
    );

    assign debug_valid = retire0.valid;
    assign debug_wb_pc = retire0.pc;
    assign debug_wb_rf_we = {4{retire0.valid && retire0.rd != 0}};
    assign debug_wb_rf_wnum = retire0.rd;
    assign debug_wb_rf_wdata = retire0.data;
    assign debug1_valid = retire1.valid;
    assign debug1_wb_pc = retire1.pc;
    assign debug1_wb_rf_we = {4{retire1.valid && retire1.rd != 0}};
    assign debug1_wb_rf_wnum = retire1.rd;
    assign debug1_wb_rf_wdata = retire1.data;
    assign debug_exception = trap;

`ifdef ARENA_ACX_PERF
    ooo_perf perf (
        .clk, .resetn, .retire0, .retire1, .data0, .data1,
        .branch(train_valid && train_control), .branch_slot1(train_slot1),
        .branch_indirect(train_indirect), .branch_taken(train_taken), .branch_miss,
        .branch_tag_miss(train_tag_miss), .direction_correct(train_direction_correct),
        .trap, .ic_miss, .ic_accept(ic_valid && ic_ready), .ic_cached, .ic_resp_valid,
        .dc_miss, .dc_accept(dc_valid && dc_ready && !dc_request.maintenance),
        .dc_cached(dc_request.access.cached), .dc_resp_valid, .store_bus_error
    );
`endif
endmodule
