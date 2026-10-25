//EXU(EXecution Unit): 负责根据控制信号控制ALU, 对数据进行计算
module EXU (
    // input clk,
    // input idu_valid,
    input [31:0] rs1,
    input [31:0] rs2,
    input [31:0] imm,
    input [31:0] pc,
    input [1:0] src_sel,
    input [3:0] exu_op,
    output reg [31:0] result,
    output reg zero,
    output reg signed_lt,
    output reg unsigned_lt
);
  localparam SRC_REG_REG = 2'h0;
  localparam SRC_REG_IMM = 2'h1;
  localparam SRC_PC_IMM  = 2'h2;

  localparam EXU_ADD  = 4'h0;
  localparam EXU_SUB  = 4'h1;
  localparam EXU_SLTU = 4'h4;
  localparam EXU_SLL  = 4'h5;
  localparam EXU_SRL  = 4'h6;
  localparam EXU_SRA  = 4'h7;
  localparam EXU_AND  = 4'h8;
  localparam EXU_OR   = 4'h9;
  localparam EXU_XOR  = 4'ha;
  localparam EXU_SLT  = 4'hb;

  // Source operand final mux.
  reg [31:0] src1;
  reg [31:0] src2;
  always @(*) begin
    case (src_sel)
      SRC_REG_REG: begin src1 = rs1; src2 = rs2; end
      SRC_REG_IMM: begin src1 = rs1; src2 = imm; end
      SRC_PC_IMM:  begin src1 = imm; src2 = pc;  end
      default:     begin src1 = rs1; src2 = rs2; end
    endcase
  end

  // Compute all ALU results in parallel; the exu_op mux only selects among
  // precomputed candidates, so the critical path is max(ALU delay) + mux.
  wire [31:0] add_result  = src1 + src2;
  wire [31:0] sub_result  = src1 - src2;
  wire [31:0] sltu_result = (src1 < src2) ? 32'h1 : 32'h0;
  wire [31:0] sll_result  = src1 << src2[4:0];
  wire [31:0] srl_result  = src1 >> src2[4:0];
  wire [31:0] sra_result  = $signed(src1) >>> src2[4:0];
  wire [31:0] and_result  = src1 & src2;
  wire [31:0] or_result   = src1 | src2;
  wire [31:0] xor_result  = src1 ^ src2;
  wire [31:0] slt_result  = ($signed(src1) < $signed(src2)) ? 32'h1 : 32'h0;

  // Branch flags are produced in parallel with the ALU result.  zero is
  // derived from the dedicated subtractor because BEQ/BNE always use EXU_SUB.
  wire zero_wire        = (sub_result == 32'h0);
  wire signed_lt_wire   = (src1[31] != src2[31]) ?
                          src1[31] : (src1[30:0] < src2[30:0]);
  wire unsigned_lt_wire = src1 < src2;

  // Final result/flag muxes.
  always @(*) begin
    case (exu_op)
      EXU_ADD:  result = add_result;
      EXU_SUB:  result = sub_result;
      EXU_SLTU: result = sltu_result;
      EXU_SLL:  result = sll_result;
      EXU_SRL:  result = srl_result;
      EXU_SRA:  result = sra_result;
      EXU_AND:  result = and_result;
      EXU_OR:   result = or_result;
      EXU_XOR:  result = xor_result;
      EXU_SLT:  result = slt_result;
      default:  result = 32'b0;
    endcase
    zero        = zero_wire;
    signed_lt   = signed_lt_wire;
    unsigned_lt = unsigned_lt_wire;
  end






endmodule
