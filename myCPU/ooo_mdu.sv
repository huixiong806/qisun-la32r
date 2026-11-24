module ooo_mdu (
    input logic clk, resetn, flush,
    input logic mul_valid, div_valid,
    input ooo_pkg::op_t op,
    input ooo_pkg::rob_id_t id,
    input logic [31:0] a, b,
    output logic div_ready,
    output ooo_pkg::writeback_t mul_result, div_result
);
    import ooo_pkg::*;

    logic mul_partial_valid, mul_sum_valid, mul_out_valid;
    rob_id_t mul_partial_id, mul_sum_id, mul_out_id;
    logic mul_partial_hi, mul_sum_hi;
    wire signed [16:0] a_lo = $signed({1'b0, a[15:0]});
    wire signed [16:0] b_lo = $signed({1'b0, b[15:0]});
    wire signed [16:0] a_hi = $signed({op == OP_MULH && a[31], a[31:16]});
    wire signed [16:0] b_hi = $signed({op == OP_MULH && b[31], b[31:16]});
    (* use_dsp = "yes" *) logic signed [33:0] lo_lo, lo_hi, hi_lo, hi_hi;
    logic signed [34:0] middle;
    logic [31:0] upper;
    logic [15:0] bottom;
    logic [31:0] mul_out;
    assign mul_result = {mul_out_valid, mul_out_id, mul_out, fault_t'('0)};

    always_ff @(posedge clk) begin
        if (!resetn || flush) begin
            mul_partial_valid <= 0;
            mul_sum_valid <= 0;
            mul_out_valid <= 0;
        end else begin
            mul_partial_valid <= mul_valid;
            mul_sum_valid <= mul_partial_valid;
            mul_out_valid <= mul_sum_valid;
            if (mul_valid) begin
                lo_lo <= a_lo * b_lo;
                lo_hi <= a_lo * b_hi;
                hi_lo <= a_hi * b_lo;
                hi_hi <= a_hi * b_hi;
                mul_partial_id <= id;
                mul_partial_hi <= op != OP_MUL;
            end
            if (mul_partial_valid) begin
                middle <= 35'(lo_hi) + 35'(hi_lo) + $signed({19'b0, lo_lo[31:16]});
                upper <= hi_hi[31:0];
                bottom <= lo_lo[15:0];
                mul_sum_id <= mul_partial_id;
                mul_sum_hi <= mul_partial_hi;
            end
            if (mul_sum_valid) begin
                mul_out <= mul_sum_hi ? upper + {{13{middle[34]}}, middle[34:16]} : {middle[15:0], bottom};
                mul_out_id <= mul_sum_id;
            end
        end
    end

    logic div_setup, dividing, div_finish, div_out_valid;
    logic [5:0] steps_left;
    rob_id_t div_id;
    logic [31:0] dividend, divisor, remainder, quotient, div_out, original_a, magnitude;
    logic negate, want_remainder;
    wire signed_op = op == OP_DIV || op == OP_MOD;
    wire [31:0] abs_a = signed_op && a[31] ? -a : a;
    wire [31:0] abs_b = signed_op && b[31] ? -b : b;
    wire rem_op = op == OP_MOD || op == OP_MODU;
    wire [32:0] shifted_rem = {remainder, dividend[31]};
    wire [32:0] difference = shifted_rem - {1'b0, divisor};
    wire quotient_bit = !difference[32];
    wire [31:0] next_rem = quotient_bit ? difference[31:0] : shifted_rem[31:0];
    wire [31:0] next_quotient = {quotient[30:0], quotient_bit};
    wire [31:0] div_magnitude = want_remainder ? next_rem : next_quotient;
    assign div_ready = !div_setup && !dividing && !div_finish;
    assign div_result = {div_out_valid, div_id, div_out, fault_t'('0)};

    always_ff @(posedge clk) begin
        if (!resetn || flush) begin
            dividing <= 0;
            div_setup <= 0;
            div_finish <= 0;
            div_out_valid <= 0;
            steps_left <= 0;
        end else begin
            div_out_valid <= 0;
            if (div_valid && div_ready) begin
                div_id <= id;
                div_setup <= 1;
                dividend <= abs_a;
                divisor <= abs_b;
                original_a <= a;
                quotient <= 0;
                remainder <= 0;
                negate <= signed_op && (rem_op ? a[31] : a[31] ^ b[31]);
                want_remainder <= rem_op;
            end else if (div_setup) begin
                div_setup <= 0;
                if (divisor == 0 || dividend < divisor) begin
                    div_out <= want_remainder ? original_a : divisor == 0 ? 32'hffff_ffff : 32'b0;
                    div_out_valid <= 1;
                end else begin
                    dividing <= 1;
                    steps_left <= 32;
                end
            end else if (dividing) begin
                dividend <= {dividend[30:0], 1'b0};
                quotient <= next_quotient;
                remainder <= next_rem;
                steps_left <= steps_left - 1'b1;
                if (steps_left == 1) begin
                    magnitude <= div_magnitude;
                    div_finish <= 1;
                    dividing <= 0;
                end
            end else if (div_finish) begin
                div_out <= negate ? -magnitude : magnitude;
                div_out_valid <= 1;
                div_finish <= 0;
            end
        end
    end
endmodule
