//EXU(EXecution Unit): 负责根据控制信号控制ALU, 对数据进行计算
module EXU (
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

  reg [31:0] src1;
  reg [31:0] src2;
  always @(*) begin
    case (src_sel)
      SRC_REG_REG: begin
        src1 = rs1;
        src2 = rs2;
      end
      SRC_REG_IMM: begin
        src1 = rs1;
        src2 = imm;
      end
      SRC_PC_IMM: begin
        src1 = imm;
        src2 = pc;  //pc是外部传入的，exu不负责pc的计算
      end
      default: begin
        src1 = rs1;
        src2 = rs2;
      end
    endcase
    //上面分配了运算参与源 下面进行计算
    case (exu_op)
      EXU_ADD: begin
        result = src1 + src2;
      end
      EXU_SUB: begin
        result = src1 - src2;
      end
      EXU_SLTU: begin
        result = src1 < src2 ? 32'h1 : 32'h0;
      end
      EXU_SLL: begin
        result = src1 << src2[4:0];//左移 任意位数的桶型移位器，本质多级mux；
      end
      EXU_SRL: begin
        result = src1 >> src2[4:0];//逻辑右移
      end
      EXU_SRA: begin
        result = $signed(src1) >>> src2[4:0];//算术右移
      end
      EXU_AND: begin
        result = src1 & src2;
      end
      EXU_OR: begin
        result = src1 | src2;
      end
      EXU_XOR: begin
        result = src1 ^ src2;
      end
      EXU_SLT: begin
        result = $signed(src1) < $signed(src2) ? 32'h1 : 32'h0;
      end
      default: begin
        result = 32'b0;

      end
    endcase
    zero = result == 32'h0;
    signed_lt = (src1[31] != src2[31]) ?
                src1[31] : (src1[30:0] < src2[30:0]);
    unsigned_lt = src1 < src2;
  end






endmodule
