package ooo_pkg;
    localparam logic [31:0] RESET_PC = 32'h1c00_0000;

    typedef enum logic [5:0] {
        OP_INVALID, OP_ADD, OP_SUB, OP_SLT, OP_SLTU, OP_NOR,
        OP_AND, OP_OR, OP_XOR, OP_SLL, OP_SRL, OP_SRA,
        OP_B, OP_BL, OP_JIRL, OP_BEQ, OP_BNE, OP_BLT, OP_BGE, OP_BLTU, OP_BGEU,
        OP_LD, OP_ST, OP_MUL, OP_MULH, OP_MULHU, OP_DIV, OP_DIVU, OP_MOD, OP_MODU,
        OP_CSR, OP_CACOP, OP_TLBSRCH, OP_TLBRD, OP_TLBWR, OP_TLBFILL, OP_INVTLB,
        OP_ERTN, OP_IDLE, OP_LL, OP_SC, OP_DBAR, OP_IBAR, OP_BREAK, OP_SYSCALL,
        OP_CNTID, OP_CNTLO, OP_CNTHI, OP_CPUCFG, OP_PRELD
    } op_t;

    typedef enum logic [2:0] { FU_ALU, FU_BRANCH, FU_MEMORY, FU_MUL, FU_DIV, FU_SYSTEM } fu_t;

    typedef struct packed {
        op_t op;
        fu_t fu;
        logic [4:0] a, b, rd;
        logic a_pc, b_imm;
        logic [31:0] imm;
        logic [1:0] size;
        logic unsigned_load;
        logic [31:0] sequential_pc;
        logic predicted_seq, predicted_target;
    } decode_t;

    localparam logic [5:0] E_INT  = 6'h00;
    localparam logic [5:0] E_PIL  = 6'h01;
    localparam logic [5:0] E_PIS  = 6'h02;
    localparam logic [5:0] E_PIF  = 6'h03;
    localparam logic [5:0] E_PME  = 6'h04;
    localparam logic [5:0] E_PPI  = 6'h07;
    localparam logic [5:0] E_ADE  = 6'h08;
    localparam logic [5:0] E_ALE  = 6'h09;
    localparam logic [5:0] E_SYS  = 6'h0b;
    localparam logic [5:0] E_BRK  = 6'h0c;
    localparam logic [5:0] E_INE  = 6'h0d;
    localparam logic [5:0] E_IPE  = 6'h0e;
    localparam logic [5:0] E_TLBR = 6'h3f;

    typedef struct packed {
        logic valid;
        logic [5:0] code;
        logic data_address;
        logic [31:0] badv;
    } fault_t;

    typedef struct packed {
        logic [31:0] pa;
        logic cached;
        fault_t fault;
    } translation_t;

    typedef struct packed {
        logic [31:0] pc, insn, next_pc;
        logic [9:0] pht_index;
        logic predicted_tag, predicted_direction;
        fault_t fault;
    } fetch_t;

    typedef struct packed {
        logic [31:0] addr;
        logic [3:0] len;
        logic [1:0] size;
    } read_req_t;

    typedef struct packed {
        logic [31:0] data;
        logic last, error;
    } read_beat_t;

    typedef struct packed {
        read_req_t address;
        logic [511:0] data;
        logic [3:0] single_mask;
    } write_req_t;

    typedef struct packed {
        logic [31:0] addr, data;
        logic [3:0] mask;
        logic [1:0] size;
        logic cached;
    } store_t;

    typedef struct packed {
        store_t access;
        logic write, maintenance, zero_extend;
        logic [1:0] mode;
        logic [6:0] token;
    } data_req_t;

    typedef struct packed {
        logic [6:0] token;
        logic [31:0] data;
        logic error;
    } data_resp_t;

    localparam int ROB_SIZE = 16;
    typedef logic [$clog2(ROB_SIZE)-1:0] rob_id_t;

    typedef struct packed {
        logic valid;
        rob_id_t id;
        logic [31:0] data;
        fault_t fault;
    } writeback_t;

    typedef struct packed {
        logic [31:0] va, store_data;
        decode_t dec;
        rob_id_t id;
    } agu_t;

    typedef struct packed {
        logic valid;
        logic [31:0] pc, data;
        logic [4:0] rd;
    } retire_t;

    function automatic op_t alu_register(input logic [16:0] opcode);
        case (opcode)
            17'h020: alu_register = OP_ADD;
            17'h022: alu_register = OP_SUB;
            17'h024: alu_register = OP_SLT;
            17'h025: alu_register = OP_SLTU;
            17'h028: alu_register = OP_NOR;
            17'h029: alu_register = OP_AND;
            17'h02a: alu_register = OP_OR;
            17'h02b: alu_register = OP_XOR;
            17'h02e: alu_register = OP_SLL;
            17'h02f: alu_register = OP_SRL;
            17'h030: alu_register = OP_SRA;
            default: alu_register = OP_INVALID;
        endcase
    endfunction

    function automatic decode_t decode(input logic [31:0] word);
        decode_t d;
        logic [4:0] rd, rj, rk;
        rd = word[4:0];
        rj = word[9:5];
        rk = word[14:10];
        d = '0;
        d.fu = FU_SYSTEM;
        d.op = OP_INVALID;

        case (word[31:26])
            6'h13, 6'h14, 6'h15, 6'h16, 6'h17, 6'h18, 6'h19, 6'h1a, 6'h1b: begin
                d.fu = FU_BRANCH;
                d.a = rj;
                d.b = rd;
                d.imm = {{14{word[25]}}, word[25:10], 2'b00};
                case (word[31:26])
                    6'h13: begin d.op = OP_JIRL; d.b = 0; d.rd = rd; end
                    6'h14, 6'h15: begin
                        d.op = word[26] ? OP_BL : OP_B;
                        d.a = 0;
                        d.b = 0;
                        d.rd = {4'b0, word[26]};
                        d.imm = {{4{word[9]}}, word[9:0], word[25:10], 2'b00};
                    end
                    6'h16: d.op = OP_BEQ;
                    6'h17: d.op = OP_BNE;
                    6'h18: d.op = OP_BLT;
                    6'h19: d.op = OP_BGE;
                    6'h1a: d.op = OP_BLTU;
                    6'h1b: d.op = OP_BGEU;
                    default: ;
                endcase
            end
            default: ;
        endcase

        case (word[31:22])
            10'h008, 10'h009, 10'h00a, 10'h00d, 10'h00e, 10'h00f: begin
                d.fu = FU_ALU;
                d.a = rj;
                d.rd = rd;
                d.b_imm = 1;
                d.imm = {{20{word[21] && !word[24]}}, word[21:10]};
                case (word[31:22])
                    10'h008: d.op = OP_SLT;
                    10'h009: d.op = OP_SLTU;
                    10'h00a: d.op = OP_ADD;
                    10'h00d: d.op = OP_AND;
                    10'h00e: d.op = OP_OR;
                    10'h00f: d.op = OP_XOR;
                    default: ;
                endcase
            end
            10'h0a0, 10'h0a1, 10'h0a2, 10'h0a8, 10'h0a9: begin
                d.fu = FU_MEMORY;
                d.op = OP_LD;
                d.a = rj;
                d.rd = rd;
                d.size = word[23:22];
                d.unsigned_load = word[25];
                d.imm = {{20{word[21]}}, word[21:10]};
            end
            10'h0a4, 10'h0a5, 10'h0a6: begin
                d.fu = FU_MEMORY;
                d.op = OP_ST;
                d.a = rj;
                d.b = rd;
                d.size = word[23:22];
                d.imm = {{20{word[21]}}, word[21:10]};
            end
            10'h0ab: begin
                d.fu = rd == 0 || rd == 8 ? FU_MEMORY : FU_ALU;
                d.op = OP_PRELD;
                d.a = rj;
                d.size = 2;
                d.imm = {{20{word[21]}}, word[21:10]};
            end
            10'h018: begin
                d.op = OP_CACOP;
                d.a = rj;
                d.imm = {{20{word[21]}}, word[21:10]};
            end
            default: ;
        endcase

        case (word[31:25])
            7'h0a, 7'h0e: begin
                d.fu = FU_ALU;
                d.op = OP_ADD;
                d.rd = rd;
                d.a_pc = word[27];
                d.b_imm = 1;
                d.imm = {word[24:5], 12'b0};
            end
            default: ;
        endcase

        case (word[31:24])
            8'h04: begin
                d.op = OP_CSR;
                d.rd = rd;
                d.a = rj > 1 ? rj : 5'b0;
                d.b = rj == 0 ? 5'b0 : rd;
            end
            8'h20, 8'h21: begin
                d.op = word[24] ? OP_SC : OP_LL;
                d.a = rj;
                d.b = word[24] ? rd : 5'b0;
                d.rd = rd;
                d.size = 2;
                d.imm = {{16{word[23]}}, word[23:10], 2'b00};
            end
            default: ;
        endcase

        case (word[31:15])
            17'h020, 17'h022, 17'h024, 17'h025, 17'h028, 17'h029,
            17'h02a, 17'h02b, 17'h02e, 17'h02f, 17'h030: begin
                d.op = alu_register(word[31:15]);
                d.fu = FU_ALU;
                d.a = rj;
                d.b = rk;
                d.rd = rd;
            end
            17'h081, 17'h089, 17'h091: begin
                d.fu = FU_ALU;
                case (word[31:15])
                    17'h081: d.op = OP_SLL;
                    17'h089: d.op = OP_SRL;
                    default: d.op = OP_SRA;
                endcase
                d.a = rj;
                d.rd = rd;
                d.b_imm = 1;
                d.imm = {27'b0, rk};
            end
            17'h038, 17'h039, 17'h03a: begin
                d.fu = FU_MUL;
                d.op = word[16] ? OP_MULHU : word[15] ? OP_MULH : OP_MUL;
                d.a = rj;
                d.b = rk;
                d.rd = rd;
            end
            17'h040, 17'h041, 17'h042, 17'h043: begin
                d.fu = FU_DIV;
                case (word[16:15])
                    2'd0: d.op = OP_DIV;
                    2'd1: d.op = OP_MOD;
                    2'd2: d.op = OP_DIVU;
                    2'd3: d.op = OP_MODU;
                endcase
                d.a = rj;
                d.b = rk;
                d.rd = rd;
            end
            17'h054: d.op = OP_BREAK;
            17'h056: d.op = OP_SYSCALL;
            17'h70e4: d.op = OP_DBAR;
            17'h70e5: d.op = OP_IBAR;
            17'h0c91: d.op = OP_IDLE;
            17'h0c93: begin
                if (rd < 7) begin
                    d.op = OP_INVTLB;
                    d.a = rj;
                    d.b = rk;
                end
            end
            default: ;
        endcase

        case (word)
            32'h0648_2800: d.op = OP_TLBSRCH;
            32'h0648_2c00: d.op = OP_TLBRD;
            32'h0648_3000: d.op = OP_TLBWR;
            32'h0648_3400: d.op = OP_TLBFILL;
            32'h0648_3800: d.op = OP_ERTN;
            default: ;
        endcase
        if (word[31:10] == 22'h18 && rd == 0 && rj != 0) begin
            d.op = OP_CNTID;
            d.rd = rj;
        end
        if (word[31:5] == 27'h300 || word[31:5] == 27'h320) begin
            d.op = word[10] ? OP_CNTHI : OP_CNTLO;
            d.rd = rd;
        end
        if (word[31:10] == 22'h1b) begin
            d.op = OP_CPUCFG;
            d.a = rj;
            d.rd = rd;
        end
        return d;
    endfunction

    function automatic logic [31:0] alu(
        input op_t op, input logic [31:0] a, b
    );
        case (op)
            OP_ADD:  alu = a + b;
            OP_SUB:  alu = a - b;
            OP_SLT:  alu = {31'b0, $signed(a) < $signed(b)};
            OP_SLTU: alu = {31'b0, a < b};
            OP_NOR:  alu = ~(a | b);
            OP_AND:  alu = a & b;
            OP_OR:   alu = a | b;
            OP_XOR:  alu = a ^ b;
            OP_SLL:  alu = a << b[4:0];
            OP_SRL:  alu = a >> b[4:0];
            OP_SRA:  alu = $unsigned($signed(a) >>> b[4:0]);
            default: alu = 0;
        endcase
    endfunction

    function automatic logic branch_taken(input op_t op, input logic [31:0] a, b);
        case (op)
            OP_B, OP_BL, OP_JIRL: branch_taken = 1'b1;
            OP_BEQ:  branch_taken = a == b;
            OP_BNE:  branch_taken = a != b;
            OP_BLT:  branch_taken = $signed(a) < $signed(b);
            OP_BGE:  branch_taken = $signed(a) >= $signed(b);
            OP_BLTU: branch_taken = a < b;
            OP_BGEU: branch_taken = a >= b;
            default: branch_taken = 1'b0;
        endcase
    endfunction

    function automatic logic [31:0] load_value(
        input logic [31:0] word, input logic [1:0] offset, size,
        input logic zero_extend
    );
        logic [31:0] aligned;
        aligned = word >> (8 * offset);
        case (size)
            2'd0: load_value = {{24{!zero_extend && aligned[7]}}, aligned[7:0]};
            2'd1: load_value = {{16{!zero_extend && aligned[15]}}, aligned[15:0]};
            default: load_value = word;
        endcase
    endfunction

    function automatic logic [3:0] byte_mask(input logic [1:0] offset, size);
        case (size)
            2'd0: byte_mask = 4'b0001 << offset;
            2'd1: byte_mask = 4'b0011 << offset;
            default: byte_mask = 4'b1111;
        endcase
    endfunction
endpackage
