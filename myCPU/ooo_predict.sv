module ooo_predict (
    input logic clk, resetn,
    input logic [31:0] fetch_pc,
    input logic fetch_accept, redirect_valid,
    output logic [31:0] next_pc,
    output logic [2:0] word_count,
    output logic [9:0] pht_index,
    output logic sequential,
    output logic [3:0] tag_hit, direction_taken,

    input logic train_valid, train_control, train_taken, train_conditional,
    input logic train_call, train_return,
    input logic [31:0] train_pc, train_target, train_link,
    input logic [9:0] train_index
);
    localparam int TARGETS = 256, COUNTERS = 1024, HISTORY = 12;
    typedef struct packed {
        logic [19:0] tag;
        logic [31:0] target;
        logic conditional, call, returns, valid;
    } target_t;
    typedef struct packed {
        logic valid, control, taken, conditional, call, returns;
        logic [31:0] pc, target;
        logic [9:0] index;
    } update_t;
    update_t update;
    always_ff @(posedge clk) begin
        if (!resetn) update.valid <= 0;
        else update <= {train_valid, train_control, train_taken, train_conditional,
                        train_call, train_return, train_pc, train_target, train_index};
    end

    logic [HISTORY-1:0] history, committed_history;
    logic initialized;
    logic [9:0] init_index;
    always_ff @(posedge clk) begin
        if (!resetn) begin
            initialized <= 0;
            init_index <= 0;
        end else if (!initialized) begin
            init_index <= init_index + 1'b1;
            initialized <= &init_index;
        end
    end
    (* ram_style = "distributed" *) logic [31:0] ras [8], committed_ras [8];
    logic [7:0] ras_override;
    logic committed_write;
    logic [2:0] committed_slot;
    logic [31:0] committed_link;
    logic [2:0] ras_ptr, committed_ptr;
    logic [8:0] ras_depth, committed_depth;
    wire retire_call = train_valid && train_call;
    wire retire_return = train_valid && train_return && !committed_depth[0];
    wire [HISTORY-1:0] retire_history = train_valid && train_conditional ?
        {committed_history[HISTORY-2:0], train_taken} : committed_history;
    wire [2:0] retire_ptr = retire_call ? committed_ptr + 1'b1 :
                            retire_return ? committed_ptr - 1'b1 : committed_ptr;
    wire [8:0] retire_depth = retire_call && !committed_depth[8] ? committed_depth << 1 :
                             retire_return ? committed_depth >> 1 : committed_depth;
    wire [2:0] ras_top = ras_ptr - 1'b1;
    wire [7:0] block_index = fetch_pc[11:4];
    wire [1:0] start_word = fetch_pc[3:2];
    wire [1:0] train_lane = update.pc[3:2];
    wire [7:0] train_block = update.pc[11:4];
    assign pht_index = fetch_pc[13:4] ^ history[9:0] ^ {8'b0, history[11:10]};

    target_t target [4];
    logic [3:0] recognized, predicted_taken;
    for (genvar lane = 0; lane < 4; lane++) begin : predictor_bank
        (* ram_style = "distributed" *) logic [$bits(target_t)-1:0] btb [TARGETS];
        (* ram_style = "distributed" *) logic [1:0] pht [COUNTERS];
        // Keep a branch-local direction counter and a two-bit preference
        // between that counter and the global history counter.
        (* ram_style = "distributed" *) logic [3:0] direction [TARGETS];
        wire train_here = update.valid && train_lane == 2'(lane);
        wire [1:0] old_counter = pht[update.index];
        wire [3:0] old_direction = direction[train_block];
        wire [3:0] prediction = direction[block_index];
        wire global_direction = pht[pht_index][1];
        wire local_direction = prediction[1];
        wire taken = prediction[3] ? global_direction : local_direction;
        wire [1:0] preference = old_counter[1] == old_direction[1] ? old_direction[3:2] :
                                adjust(old_direction[3:2], old_counter[1] == update.taken);
        wire clear_targets = !initialized && init_index[9:8] == 0;
        wire [7:0] btb_write_index = initialized ? train_block : init_index[7:0];
        wire [9:0] pht_write_index = initialized ? update.index : init_index;
        wire [$bits(target_t)-1:0] new_target =
            {update.pc[31:12], update.target, update.conditional, update.call, update.returns, update.control};
        assign target[lane] = target_t'(btb[block_index]);
        assign recognized[lane] = initialized && target[lane].valid && target[lane].tag == fetch_pc[31:12] &&
                                  start_word <= 2'(lane);
        assign tag_hit[lane] = recognized[lane];
        assign direction_taken[lane] = taken;
        assign predicted_taken[lane] = recognized[lane] && (!target[lane].conditional || taken);
        always_ff @(posedge clk) begin
            if (resetn && (clear_targets || (initialized && train_here)))
                btb[btb_write_index] <= initialized ? new_target : '0;
            if (resetn && (!initialized || (train_here && update.conditional)))
                pht[pht_write_index] <= !initialized ? 2'd1 : adjust(old_counter, update.taken);
            if (resetn && (clear_targets || (initialized && train_here && update.conditional)))
                direction[btb_write_index] <= !initialized ? 4'b1001 :
                    {preference, adjust(old_direction[1:0], update.taken)};
        end
    end

    function automatic logic [1:0] adjust(input logic [1:0] counter, input logic increase);
        if (increase) return counter == 3 ? counter : counter + 1'b1;
        return counter == 0 ? counter : counter - 1'b1;
    endfunction

    logic [3:0] choose, shift_history;
    logic [31:0] selected_target;
    logic do_call, do_return;
    for (genvar lane = 0; lane < 4; lane++) begin : select_lane
        localparam logic [3:0] EARLIER = (4'b0001 << lane) - 1'b1;
        wire first_taken = (predicted_taken & EARLIER) == 0;
        assign choose[lane] = first_taken && predicted_taken[lane];
        assign shift_history[lane] = first_taken && recognized[lane] && target[lane].conditional;
    end
    assign sequential = predicted_taken == 0;
    wire [1:0] stop_word = {sequential || choose[2] || choose[3], sequential || choose[1] || choose[3]};
    assign word_count = {1'b0, stop_word} - {1'b0, start_word} + 1'b1;
    wire [2:0] history_bits = (3'(shift_history[0]) + 3'(shift_history[1])) +
                              (3'(shift_history[2]) + 3'(shift_history[3]));
    // All recognized conditionals before the selected taken branch add a
    // zero. Only the last new history bit can be one.
    wire [HISTORY-1:0] predicted_history = (history << history_bits) |
                                         HISTORY'(|(shift_history & choose));
    always_comb begin
        selected_target = 0;
        do_call = 0;
        do_return = 0;
        for (int lane = 0; lane < 4; lane++) begin
            selected_target |= target[lane].target & {32{choose[lane]}};
            do_call |= choose[lane] && target[lane].call;
            do_return |= choose[lane] && target[lane].returns;
        end
    end
    wire [31:0] next_block = {fetch_pc[31:4] + 28'd1, 4'b0};
    // A speculative push shadows the committed slot. Recovery clears the
    // shadow mask, so it does not need eight simultaneous RAM writes.
    wire [31:0] committed_top = committed_write && committed_slot == ras_top ?
                                committed_link : committed_ras[ras_top];
    wire [31:0] return_target = ras_override[ras_top] ? ras[ras_top] : committed_top;
    wire use_stack = do_return && !ras_depth[0];
    assign next_pc = (next_block & {32{sequential}}) | (return_target & {32{use_stack}}) |
                     (selected_target & {32{!use_stack}});

    wire new_call = fetch_accept && do_call;
    wire new_return = fetch_accept && use_stack;
    wire [31:0] fetched_link = stop_word == 3 ? next_block : {fetch_pc[31:4], stop_word + 2'd1, 2'b00};
    always_ff @(posedge clk) begin
        if (!resetn) begin
            history <= 0;
            committed_history <= 0;
            ras_ptr <= 0;
            ras_depth <= 1;
            ras_override <= 0;
            committed_ptr <= 0;
            committed_depth <= 1;
            committed_write <= 0;
        end else begin
            committed_history <= retire_history;
            committed_ptr <= retire_ptr;
            committed_depth <= retire_depth;
            committed_write <= retire_call;
            committed_slot <= committed_ptr;
            committed_link <= train_link;
            if (committed_write) committed_ras[committed_slot] <= committed_link;
            // Restore history and stack pointers at the same edge that
            // redirects the PC. Prediction reads only the registered state.
            if (redirect_valid) begin
                history <= retire_history;
                ras_ptr <= retire_ptr;
                ras_depth <= retire_depth;
                ras_override <= 0;
            end else if (fetch_accept) begin
                history <= predicted_history;
                if (new_call) begin
                    ras[ras_ptr] <= fetched_link;
                    ras_override[ras_ptr] <= 1;
                    ras_ptr <= ras_ptr + 1'b1;
                    if (!ras_depth[8]) ras_depth <= ras_depth << 1;
                end else if (new_return) begin
                    ras_ptr <= ras_ptr - 1'b1;
                    ras_depth <= ras_depth >> 1;
                end
            end
        end
    end
endmodule
