module ooo_dcache (
    input logic clk, resetn,
    input logic req_valid,
    input ooo_pkg::data_req_t request,
    output logic req_ready, resp_valid,
    output ooo_pkg::data_resp_t response,
    output logic load_hint,
    output ooo_pkg::rob_id_t load_hint_id,

    output logic read_valid,
    output ooo_pkg::read_req_t read_request,
    input logic read_accept, beat_valid,
    input ooo_pkg::read_beat_t beat,
    output logic write_valid,
    output ooo_pkg::write_req_t write_request,
    input logic write_accept, write_done, write_error,
    output logic miss_event
);
    import ooo_pkg::*;
    localparam int SETS = 128, WORDS = 16, BANKS = 4;
    typedef enum logic [2:0] {
        LOOKUP, COLLECT, WRITE_ADDRESS, WRITE_RESPONSE, READ_ADDRESS, REFILL, RESPOND
    } state_t;
    state_t state;

    (* ram_style = "distributed" *) logic replace_way [SETS];
    logic [19:0] lookup_tag [2];
    logic [1:0] lookup_dirty;
    logic initialized;
    logic [6:0] init_set;
    logic [31:0] bank_data [2][BANKS];
    logic lookup_valid;
    data_req_t lookup;
    wire [31:0] pa = lookup.access.addr;
    wire [6:0] set_index = pa[12:6];
    wire [6:0] request_set = request.access.addr[12:6];
    wire [3:0] word_index = pa[5:2];
    wire hit0 = lookup_tag[0] == {1'b1, pa[31:13]};
    wire hit1 = lookup_tag[1] == {1'b1, pa[31:13]};
    wire hit = hit0 || hit1;
    wire hit_way = hit1;
    wire victim = lookup_tag[0][19] && (!lookup_tag[1][19] || replace_way[set_index]);
    wire maintenance_way = lookup.mode == 2 ? hit_way : pa[0];
    wire maintenance_hit = lookup.mode == 2 ? hit : lookup_tag[maintenance_way][19];
    wire selected_way = lookup.maintenance ? maintenance_way : victim;
    wire wb_needed = lookup_tag[selected_way][19] && lookup_dirty[selected_way];
    wire maintenance_wb = lookup.mode != 0 && maintenance_hit && wb_needed;
    wire quick_response = lookup_valid && (lookup.maintenance ? !maintenance_wb
                                        : lookup.access.cached && hit);
    wire store_hit = state == LOOKUP && lookup_valid && !lookup.maintenance &&
                     lookup.access.cached && hit && lookup.write;

    logic refill_way, eviction, transaction_error, early_responded;
    logic [18:0] victim_tag;
    logic [3:0] refill_word;
    logic [2:0] collect_sent;
    logic [511:0] writeback_data;
    logic [31:0] returned_data;

    assign req_ready = initialized && state == LOOKUP && (!lookup_valid || quick_response);
    wire early_load = state == REFILL && beat_valid && lookup.access.cached &&
                      !lookup.write && refill_word == word_index && !transaction_error && !beat.error;
    assign resp_valid = (state == LOOKUP && quick_response) || state == RESPOND || early_load;
    assign response.token = lookup.token;
    wire [31:0] response_word = early_load ? beat.data : state == RESPOND ? returned_data :
                                bank_data[hit_way][word_index[1:0]];
    // The lookup already has the byte offset and extension mode. Format
    // here so the ROB tag does not select metadata on the load-use path.
    assign response.data = load_value(response_word, pa[1:0], lookup.access.size, lookup.zero_extend);
    assign response.error = state == RESPOND && transaction_error;
    assign miss_event = state == LOOKUP && lookup_valid && lookup.access.cached &&
                        !lookup.maintenance && !hit;

    // This pulse predicts a hit before the tag check. It carries only the
    // accepted load's token, with no path from tag RAM into the scheduler.
    always_ff @(posedge clk) begin
        if (!resetn) begin
            load_hint <= 0;
            load_hint_id <= 0;
        end else begin
            load_hint <= req_valid && req_ready && request.access.cached &&
                         !request.write && !request.maintenance && request.token[6:5] == 0;
            if (req_valid && req_ready) load_hint_id <= rob_id_t'(request.token);
        end
    end

    assign read_valid = state == READ_ADDRESS;
    assign read_request.addr = lookup.access.cached ? {pa[31:6], 6'b0} : pa;
    assign read_request.len = lookup.access.cached ? 4'd15 : 4'd0;
    assign read_request.size = lookup.access.cached ? 2'd2 : lookup.access.size;
    assign write_valid = state == WRITE_ADDRESS;
    assign write_request.address.addr = eviction ? {victim_tag, set_index, 6'b0} : pa;
    assign write_request.address.len = eviction ? 4'd15 : 4'd0;
    assign write_request.address.size = eviction ? 2'd2 : lookup.access.size;
    assign write_request.data = eviction ? writeback_data : {480'b0, lookup.access.data};
    assign write_request.single_mask = lookup.access.mask;

    wire cache_refill = state == REFILL && beat_valid && lookup.access.cached;
    wire refill_complete = cache_refill && beat.last && !transaction_error && !beat.error;
    wire clear_at_lookup = state == LOOKUP && lookup_valid &&
        (quick_response ? lookup.maintenance && maintenance_hit :
                          (lookup.maintenance || lookup.access.cached) && !wb_needed);
    wire clear_after_write = state == WRITE_RESPONSE && write_done && eviction && !write_error;
    logic [31:0] refill_data;
    always_comb begin
        refill_data = beat.data;
        if (lookup.write && refill_word == word_index)
            for (int i = 0; i < 4; i++)
                if (lookup.access.mask[i]) refill_data[i*8 +: 8] = lookup.access.data[i*8 +: 8];
    end

    wire collect_read = state == COLLECT && collect_sent < 3'd4;
    wire [1:0] collect_previous = collect_sent[1:0] - 1'b1;
    wire [8:0] ram_read_index = collect_read ? {set_index, collect_sent[1:0]} : request.access.addr[12:4];
    wire [10:0] ram_write_index = {set_index, cache_refill ? refill_word : word_index};
    wire [31:0] ram_write_data = cache_refill ? refill_data : lookup.access.data;
    wire [3:0] ram_write_mask = cache_refill ? 4'b1111 : lookup.access.mask;

    for (genvar way = 0; way < 2; way++) begin : way_ram
        (* ram_style = "distributed" *) logic [19:0] tags [SETS];
        (* ram_style = "distributed" *) logic dirty [SETS];
        assign lookup_dirty[way] = dirty[set_index];
        wire install = refill_complete && refill_way == (way != 0);
        wire clear = (clear_at_lookup && selected_way == (way != 0)) ||
                     (clear_after_write && refill_way == (way != 0));
        wire write_way = (cache_refill && refill_way == (way != 0)) ||
                         (store_hit && hit_way == (way != 0));
        for (genvar bank = 0; bank < BANKS; bank++) begin : word_bank
            (* ram_style = "block" *) logic [31:0] data [SETS * WORDS / BANKS];
            always_ff @(posedge clk) begin
                if (write_way && ram_write_index[1:0] == 2'(bank))
                    for (int i = 0; i < 4; i++)
                        if (ram_write_mask[i])
                            data[ram_write_index[10:2]][i*8 +: 8] <= ram_write_data[i*8 +: 8];
                // A lookup uses the value only in the cycle after acceptance.
                // Reading unconditionally keeps address arbitration off the BRAM enable.
                bank_data[way][bank] <= data[ram_read_index];
            end
        end
        always_ff @(posedge clk) begin
            if (resetn && !initialized) tags[init_set] <= 0;
            else if (install || clear) tags[set_index] <= install ? {1'b1, pa[31:13]} : 20'b0;
            if (req_ready)
                lookup_tag[way] <= clear && request_set == set_index ? 20'b0 : tags[request_set];
            if (install || (store_hit && hit_way == (way != 0)))
                dirty[set_index] <= !install || lookup.write;
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
        if (refill_complete) replace_way[set_index] <= !refill_way;
        else if (state == LOOKUP && quick_response && !lookup.maintenance)
            replace_way[set_index] <= !hit_way;
    end

    always_ff @(posedge clk) begin
        if (!resetn) begin
            state <= LOOKUP;
            lookup_valid <= 0;
            lookup <= '0;
            refill_way <= 0;
            eviction <= 0;
            transaction_error <= 0;
            early_responded <= 0;
            victim_tag <= 0;
            refill_word <= 0;
            collect_sent <= 0;
            returned_data <= 0;
        end else begin
            if (req_ready) lookup <= request;
            case (state)
                LOOKUP: begin
                    if (quick_response) begin
                        lookup_valid <= 0;
                    end
                    if (req_valid && req_ready) begin
                        lookup_valid <= 1;
                    end
                    if (lookup_valid && !quick_response) begin
                        transaction_error <= 0;
                        early_responded <= 0;
                        returned_data <= 0;
                        if (lookup.maintenance || lookup.access.cached) begin
                            refill_way <= selected_way;
                            if (wb_needed) begin
                                victim_tag <= lookup_tag[selected_way][18:0];
                                collect_sent <= 0;
                                eviction <= 1;
                                state <= COLLECT;
                            end else state <= READ_ADDRESS;
                        end else begin
                            eviction <= 0;
                            state <= lookup.write ? WRITE_ADDRESS : READ_ADDRESS;
                        end
                    end
                end
                COLLECT: begin
                    if (collect_read) collect_sent <= collect_sent + 1'b1;
                    if (collect_sent != 0)
                        for (int i = 0; i < BANKS; i++)
                            writeback_data[collect_previous*128 + i*32 +: 32] <= bank_data[refill_way][i];
                    if (collect_sent == 3'd4) state <= WRITE_ADDRESS;
                end
                WRITE_ADDRESS: if (write_accept) state <= WRITE_RESPONSE;
                WRITE_RESPONSE: if (write_done) begin
                    transaction_error <= write_error;
                    state <= eviction && !lookup.maintenance && !write_error ? READ_ADDRESS : RESPOND;
                end
                READ_ADDRESS: if (read_accept) begin
                    refill_word <= 0;
                    state <= REFILL;
                end
                REFILL: if (beat_valid) begin
                    refill_word <= refill_word + 1'b1;
                    transaction_error <= transaction_error || beat.error;
                    if (early_load) early_responded <= 1;
                    if (!lookup.access.cached || refill_word == word_index) returned_data <= beat.data;
                    if (beat.last) begin
                        if (early_load || early_responded) begin
                            state <= LOOKUP;
                            lookup_valid <= 0;
                        end else state <= RESPOND;
                    end
                end
                RESPOND: begin
                    lookup_valid <= 0;
                    state <= LOOKUP;
                end
                default: state <= LOOKUP;
            endcase
        end
    end
endmodule
