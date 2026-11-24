module ooo_serial (
    input logic clk, resetn, start, finish,
    input ooo_pkg::decode_t instruction,
    input logic [31:0] word, a, b,
    input logic [1:0] plv,
    output logic active, done,
    output ooo_pkg::fault_t fault,
    output logic [31:0] value,

    output ooo_pkg::op_t op,
    output logic [31:0] saved_word, saved_a, saved_b,
    input logic [31:0] csr_value,

    output logic translate,
    output logic [31:0] va, pa,
    output logic translation_store,
    input ooo_pkg::translation_t translation,
    input logic reservation_matches,
    output logic store_succeeded,

    output logic drain_fetch,
    output logic invalidate_valid,
    output logic [1:0] invalidate_mode,
    output logic [31:0] invalidate_addr,
    input logic invalidate_ready,
    output logic cache_valid,
    output ooo_pkg::data_req_t cache_request,
    input logic cache_accept, cache_done,
    input ooo_pkg::data_resp_t cache_response
);
    import ooo_pkg::*;
    typedef enum logic [2:0] { EMPTY, ADDRESS, TRANSLATE, CHECK, ACCESS, WAIT_DATA, DONE } state_t;
    state_t state;
    logic [31:0] offset;
    logic cached;
    logic is_privileged;

    function automatic logic privileged(input op_t opcode, input logic [1:0] cache_mode);
        case (opcode)
            OP_CACOP: privileged = cache_mode != 2;
            OP_CSR, OP_TLBSRCH, OP_TLBRD, OP_TLBWR, OP_TLBFILL,
            OP_INVTLB, OP_ERTN, OP_IDLE: privileged = 1;
            default: privileged = 0;
        endcase
    endfunction

    wire i_cache = op == OP_CACOP && saved_word[2:0] == 0 && saved_word[4:3] != 3;
    wire d_cache = op == OP_CACOP && saved_word[2:0] == 1 && saved_word[4:3] != 3;
    wire atomic = op == OP_LL || op == OP_SC;
    wire needs_mapping = atomic || ((i_cache || d_cache) && saved_word[4:3] == 2);
    wire failed_sc = op == OP_SC && !reservation_matches;
    assign active = state != EMPTY;
    assign done = state == DONE;
    assign translate = state == TRANSLATE;
    assign translation_store = op == OP_SC;
    assign drain_fetch = active && i_cache;
    assign invalidate_valid = state == ACCESS && i_cache;
    assign invalidate_mode = saved_word[4:3];
    assign invalidate_addr = pa;
    assign cache_valid = state == ACCESS && (d_cache || (atomic && !failed_sc));
    assign cache_request = {{pa, saved_b, 4'b1111, 2'd2, cached}, op == OP_SC, d_cache,
                            1'b0, saved_word[4:3], 7'b0};

    fault_t check_fault;
    always_comb begin
        check_fault = '0;
        if (is_privileged && plv != 0) check_fault = {1'b1, E_IPE, 1'b0, 32'b0};
        else if (op == OP_INVALID) check_fault = {1'b1, E_INE, 1'b0, 32'b0};
        else if (op == OP_BREAK) check_fault = {1'b1, E_BRK, 1'b0, 32'b0};
        else if (op == OP_SYSCALL) check_fault = {1'b1, E_SYS, 1'b0, 32'b0};
        else if (atomic && va[1:0] != 0) check_fault = {1'b1, E_ALE, 1'b1, va};
        else if (needs_mapping) check_fault = translation.fault;
    end

    always_ff @(posedge clk) begin
        if (!resetn) begin
            state <= EMPTY;
            op <= OP_INVALID;
            fault <= '0;
            store_succeeded <= 0;
        end else if (finish) begin
            state <= EMPTY;
            op <= OP_INVALID;
        end else begin
            case (state)
                EMPTY: if (start) begin
                    op <= instruction.op;
                    saved_word <= word;
                    saved_a <= a;
                    saved_b <= b;
                    offset <= instruction.imm;
                    is_privileged <= privileged(instruction.op, word[4:3]);
                    state <= ADDRESS;
                end
                ADDRESS: begin
                    va <= saved_a + offset;
                    state <= needs_mapping ? TRANSLATE : CHECK;
                end
                TRANSLATE: state <= CHECK;
                CHECK: begin
                    value <= csr_value;
                    fault <= check_fault;
                    pa <= needs_mapping ? translation.pa : va;
                    cached <= translation.cached;
                    store_succeeded <= 0;
                    state <= !check_fault.valid && (i_cache || d_cache || atomic) ? ACCESS : DONE;
                end
                ACCESS: begin
                    if (i_cache && invalidate_ready) state <= DONE;
                    if (failed_sc) begin
                        value <= 0;
                        state <= DONE;
                    end
                    if (cache_accept) state <= WAIT_DATA;
                end
                WAIT_DATA: if (cache_done) begin
                    fault <= {cache_response.error, E_ADE, 1'b1, va};
                    value <= op == OP_SC ? 32'd1 : cache_response.data;
                    store_succeeded <= op == OP_SC && !cache_response.error;
                    state <= DONE;
                end
                default: ;
            endcase
        end
    end
endmodule
