module ooo_icache (
    input logic clk, resetn,
    input logic cancel,
    input logic req_valid,
    input logic [31:0] req_pa,
    input logic req_cached, req_prefetch,
    output logic req_ready,
    output logic resp_valid,
    input logic resp_ready,
    output logic [127:0] resp_line,
    output logic resp_error,

    input logic invalidate_valid,
    input logic [1:0] invalidate_mode,
    input logic [31:0] invalidate_addr,
    output logic invalidate_ready,

    output logic read_valid,
    output ooo_pkg::read_req_t read_request,
    input logic read_accept, beat_valid,
    input ooo_pkg::read_beat_t beat,
    output logic miss_event
);
    import ooo_pkg::*;
    localparam int SETS = 256;
    typedef enum logic [2:0] { LOOKUP, READ_ADDRESS, REFILL, PREFETCH, RESPOND } state_t;
    state_t state;

    (* ram_style = "distributed" *) logic replace_way [SETS];
    logic [20:0] lookup_tag [2], maintenance_tag [2];
    logic [127:0] way_data [2];
    logic initialized;
    logic [7:0] init_set;

    logic lookup_valid, cached, fetch_next;
    logic [31:0] pa;
    wire [7:0] set_index = pa[11:4];
    wire [7:0] request_set = req_pa[11:4];
    wire [7:0] inv_set = invalidate_addr[11:4];
    wire hit0 = lookup_tag[0] == {1'b1, pa[31:12]};
    wire hit1 = lookup_tag[1] == {1'b1, pa[31:12]};
    logic prefetched_valid, next_line_error, demand_pending;
    logic [27:0] prefetched_tag;
    logic [127:0] prefetched_data, next_line_data;
    wire prefetch_hit = lookup_valid && cached && prefetched_valid && prefetched_tag == pa[31:4];
    wire lookup_hit = lookup_valid && cached && (hit0 || hit1 || prefetch_hit);
    wire victim = lookup_tag[0][20] && (!lookup_tag[1][20] || replace_way[set_index]);

    logic refill_way, refill_error;
    logic [1:0] fill_word;
    logic [127:0] fill_data;
    logic [127:0] line_with_beat;
    logic [127:0] next_line_with_beat;
    always_comb begin
        line_with_beat = fill_data;
        line_with_beat[fill_word * 32 +: 32] = beat.data;
        next_line_with_beat = next_line_data;
        next_line_with_beat[fill_word * 32 +: 32] = beat.data;
    end
    wire demand_complete = state == REFILL && beat_valid && (beat.last || fill_word == 3);
    wire line_install = demand_complete && cached &&
                        !refill_error && !beat.error;
    // The AXI arbiter owns a read only after accepting it. An older lookup
    // can be discarded at redirect before that handshake.
    wire abort_lookup = cancel && lookup_valid && (state == LOOKUP || state == READ_ADDRESS);
    // The prefetch buffer avoids polluting L1 until the line is demanded.
    // Keep its copy through promotion to cover simultaneous BRAM reads.
    wire promote = !abort_lookup && state == LOOKUP && prefetch_hit && !hit0 && !hit1 && resp_ready;
    wire install_way = promote ? victim : refill_way;
    wire [127:0] install_data = promote ? prefetched_data : line_with_beat;

    assign invalidate_ready = initialized && state == LOOKUP && !lookup_valid;
    assign req_ready = initialized && !invalidate_valid && (abort_lookup ||
                       (state == LOOKUP && (!lookup_valid || (lookup_hit && resp_ready))));
    wire refill_response = state == RESPOND || (state == PREFETCH && demand_pending);
    assign resp_valid = abort_lookup || (state == LOOKUP && lookup_hit) || refill_response;
    assign resp_line = refill_response ? fill_data : prefetch_hit ? prefetched_data :
                       hit1 ? way_data[1] : way_data[0];
    assign resp_error = refill_response && refill_error;
    assign read_valid = state == READ_ADDRESS && !abort_lookup;
    assign read_request.addr = cached ? {pa[31:4], 4'b0} : pa;
    assign read_request.len = cached ? (fetch_next ? 4'd7 : 4'd3) : 4'd0;
    assign read_request.size = 2'd2;
    assign miss_event = !abort_lookup && state == LOOKUP && lookup_valid && cached && !lookup_hit;
    wire accept_request = req_valid && req_ready;

    for (genvar way = 0; way < 2; way++) begin : way_ram
        (* ram_style = "block" *) logic [127:0] data [SETS];
        (* ram_style = "distributed" *) logic [20:0] tags [SETS];
        assign maintenance_tag[way] = tags[inv_set];
        wire invalidate_way = invalidate_mode == 2 ?
            maintenance_tag[way] == {1'b1, invalidate_addr[31:12]} : invalidate_addr[0] == (way != 0);
        wire write_line = (line_install || promote) && install_way == (way != 0);
        always_ff @(posedge clk) begin
            if (write_line) data[set_index] <= install_data;
            if (resetn && !initialized) tags[init_set] <= 0;
            else if (invalidate_valid && invalidate_ready && invalidate_way) tags[inv_set] <= 0;
            else if (write_line) tags[set_index] <= {1'b1, pa[31:12]};
            if (accept_request) begin
                way_data[way] <= data[request_set];
                // The data RAM can still return the displaced row on a
                // simultaneous promotion. The prefetch buffer supplies the
                // promoted data, and the bypassed tag hides the old row.
                lookup_tag[way] <= write_line && request_set == set_index ?
                                   {1'b1, pa[31:12]} : tags[request_set];
            end
        end
    end

    always_ff @(posedge clk) begin
        if (!resetn) begin
            initialized <= 0;
            init_set <= 0;
        end else if (!initialized) begin
            initialized <= &init_set;
            init_set <= init_set + 1'b1;
        end
        // The first fill of either way sets replacement state before it
        // can be used to choose between two valid lines.
        if (line_install || promote) replace_way[set_index] <= !install_way;
        else if (!abort_lookup && state == LOOKUP && lookup_hit && resp_ready && (hit0 || hit1))
            replace_way[set_index] <= hit0;
    end

    always_ff @(posedge clk) begin
        if (!resetn) begin
            state <= LOOKUP;
            lookup_valid <= 0;
            cached <= 0;
            fetch_next <= 0;
            pa <= 0;
            refill_way <= 0;
            refill_error <= 0;
            fill_word <= 0;
            prefetched_valid <= 0;
            demand_pending <= 0;
            next_line_error <= 0;
        end else begin
            if (abort_lookup) begin
                state <= LOOKUP;
                lookup_valid <= 0;
            end else case (state)
                LOOKUP: begin
                    if (lookup_hit && resp_ready) begin
                        lookup_valid <= 0;
                    end
                    if (lookup_valid && !lookup_hit) begin
                        refill_way <= victim;
                        refill_error <= 0;
                        fill_word <= cached ? 2'b0 : pa[3:2];
                        fill_data <= 0;
                        state <= READ_ADDRESS;
                    end
                    if (invalidate_valid && invalidate_ready) begin
                        prefetched_valid <= 0;
                    end
                end
                READ_ADDRESS: if (read_accept) state <= REFILL;
                REFILL: if (beat_valid) begin
                    fill_data <= line_with_beat;
                    refill_error <= refill_error || beat.error;
                    fill_word <= fill_word + 1'b1;
                    if (demand_complete) begin
                        if (beat.last) state <= RESPOND;
                        else begin
                            state <= PREFETCH;
                            demand_pending <= 1;
                            next_line_error <= 0;
                            next_line_data <= 0;
                        end
                    end
                end
                PREFETCH: begin
                    if (resp_ready) demand_pending <= 0;
                    if (beat_valid) begin
                        next_line_data <= next_line_with_beat;
                        next_line_error <= next_line_error || beat.error;
                        fill_word <= fill_word + 1'b1;
                        if (beat.last) begin
                            prefetched_valid <= !next_line_error && !beat.error;
                            prefetched_tag <= pa[31:4] + 1'b1;
                            prefetched_data <= next_line_with_beat;
                            if (demand_pending && !resp_ready) state <= RESPOND;
                            else begin
                                lookup_valid <= 0;
                                state <= LOOKUP;
                            end
                        end
                    end
                end
                RESPOND: if (resp_ready) begin
                    lookup_valid <= 0;
                    state <= LOOKUP;
                end
                default: state <= LOOKUP;
            endcase
            if (accept_request) begin
                lookup_valid <= 1;
                pa <= req_pa;
                cached <= req_cached;
                fetch_next <= req_prefetch && req_pa[11:4] != 8'hff;
            end
        end
    end
endmodule
