module ooo_decode_pipe (
    input logic clk, resetn, flush,
    input logic [1:0] fetch_count,
    input ooo_pkg::fetch_t fetch0, fetch1,
    output logic [1:0] fetch_pop,
    output logic [1:0] count,
    output ooo_pkg::fetch_t first, second,
    output ooo_pkg::decode_t first_decoded, second_decoded,
    input logic [1:0] pop
);
    import ooo_pkg::*;
    wire [1:0] remaining = count - pop;
    wire [1:0] space = 2'd2 - remaining;
    assign fetch_pop = flush ? 2'd0 : fetch_count < space ? fetch_count : space;
    function automatic decode_t decode_packet(input fetch_t f);
        decode_t d;
        logic long_branch;
        logic [16:0] target_low;
        logic [13:0] displacement_high, high_base, target_high;
        logic [31:0] target;
        // The low half of the branch displacement has the same encoding in
        // both formats. Compute the target in parallel with general decode.
        long_branch = f.insn[31:27] == 5'b01010;
        displacement_high = long_branch ? {{4{f.insn[9]}}, f.insn[9:0]} : {14{f.insn[25]}};
        target_low = {1'b0, f.pc[17:2]} + {1'b0, f.insn[25:10]};
        high_base = f.pc[31:18] + displacement_high;
        target_high = target_low[16] ? high_base + 1'b1 : high_base;
        target = {target_high, target_low[15:0], f.pc[1:0]};
        d = decode(f.insn);
        d.sequential_pc = f.pc + 32'd4;
        d.predicted_seq = f.next_pc == d.sequential_pc;
        if (d.fu == FU_BRANCH && d.op != OP_JIRL) begin
            d.imm = target;
            d.predicted_target = f.next_pc == target;
        end
        return d;
    endfunction
    wire decode_t d0 = decode_packet(fetch0);
    wire decode_t d1 = decode_packet(fetch1);

    always_ff @(posedge clk) begin
        if (!resetn || flush) count <= 0;
        else begin
            count <= remaining + fetch_pop;
            if (pop == 1) begin
                first <= second;
                first_decoded <= second_decoded;
            end
            if (fetch_pop != 0) begin
                if (remaining == 0) begin
                    first <= fetch0;
                    first_decoded <= d0;
                end else begin
                    second <= fetch0;
                    second_decoded <= d0;
                end
            end
            if (fetch_pop == 2) begin
                second <= fetch1;
                second_decoded <= d1;
            end
        end
    end
endmodule
