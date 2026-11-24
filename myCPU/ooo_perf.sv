`ifdef ARENA_ACX_PERF
module ooo_perf (
    input logic clk, resetn,
    input ooo_pkg::retire_t retire0, retire1,
    input logic data0, data1,
    input logic branch, branch_slot1, branch_indirect, branch_taken, branch_miss,
    input logic branch_tag_miss, direction_correct,
    input logic trap,
    input logic ic_miss, ic_accept, ic_cached, ic_resp_valid,
    input logic dc_miss, dc_accept, dc_cached, dc_resp_valid,
    input logic store_bus_error
);
    localparam int N = 18;
    logic [31:0] counter [N];
    logic [N*32-1:0] snapshot, offset0;
    logic ic_wait, dc_wait, ic_uncached_wait, dc_uncached_wait;
    logic [N-1:0] count0, count1, by_cycle;
    logic [N-1:0] next0, next1, next_cycle;
    logic [31:0] pc0, pc1;
    logic monitor_active;
    wire direct_branch = branch && !branch_indirect;

    always_comb begin
        next0 = 0;
        next1 = 0;
        next_cycle = 0;
        next_cycle[0] = 1;
        next0[1] = retire0.valid;
        next1[1] = retire1.valid;
        next_cycle[2] = ic_miss;
        next_cycle[3] = ic_wait && !ic_resp_valid;
        next0[4] = data0;
        next1[4] = data1;
        next_cycle[5] = dc_miss;
        next_cycle[6] = dc_wait && !dc_resp_valid;
        next0[7] = direct_branch && !branch_slot1;
        next1[7] = direct_branch && branch_slot1;
        next0[8] = next0[7] && !branch_miss;
        next1[8] = next1[7] && !branch_miss;
        next0[9] = next0[7] && branch_tag_miss;
        next1[9] = next1[7] && branch_tag_miss;
        next0[10] = branch && branch_indirect && !branch_slot1;
        next1[10] = branch && branch_indirect && branch_slot1;
        next0[11] = next0[7] && direction_correct;
        next1[11] = next1[7] && direction_correct;
        next0[12] = next0[7] && branch_taken;
        next1[12] = next1[7] && branch_taken;
        next_cycle[13] = trap || store_bus_error;
        next_cycle[14] = ic_accept && !ic_cached;
        next_cycle[15] = ic_uncached_wait && !ic_resp_valid;
        next_cycle[16] = dc_accept && !dc_cached;
        next_cycle[17] = dc_uncached_wait && !dc_resp_valid;
    end

    // Delay the marker PCs, events and start of measurement together. The
    // recorded cycle numbers remain aligned with the retirement boundary.
    always_ff @(posedge clk) begin
        monitor_active <= resetn;
        count0 <= next0;
        count1 <= next1;
        by_cycle <= next_cycle;
        pc0 <= retire0.pc;
        pc1 <= retire1.pc;
    end

    for (genvar i = 0; i < N; i++) begin : counts
        wire [1:0] increment = 2'(count0[i]) + 2'(count1[i]) + 2'(by_cycle[i]);
        assign snapshot[32*i +: 32] = counter[i];
        assign offset0[32*i +: 32] = {31'b0, count0[i]};
        always_ff @(posedge clk) begin
            if (!monitor_active) counter[i] <= 0;
            else counter[i] <= counter[i] + 32'(increment);
        end
    end

    always_ff @(posedge clk) begin
        if (!resetn) begin
            ic_wait <= 0;
            dc_wait <= 0;
            ic_uncached_wait <= 0;
            dc_uncached_wait <= 0;
        end else begin
            if (ic_resp_valid) begin
                ic_wait <= 0;
                ic_uncached_wait <= 0;
            end
            if (dc_resp_valid) begin
                dc_wait <= 0;
                dc_uncached_wait <= 0;
            end
            if (ic_miss) ic_wait <= 1;
            if (dc_miss) dc_wait <= 1;
            if (ic_accept && !ic_cached) ic_uncached_wait <= 1;
            if (dc_accept && !dc_cached) dc_uncached_wait <= 1;
        end
    end

    acx_perf_monitor #(.N(N)) board_perf (
        .clk, .rst_n(monitor_active), .valid_instr(count0[1]), .valid_instr1(count1[1]),
        .retire_pc(pc0), .retire_pc1(pc1), .counters(snapshot), .slot0_increments(offset0)
    );
endmodule
`endif
