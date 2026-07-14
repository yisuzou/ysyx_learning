//EXU(EXecution Unit): 负责根据控制信号控制ALU, 对数据进行计算
module EXU (
    input [31:0] rs1,
    input [31:0] rs2,
    input [31:0] imm,
    input [1:0] src_sel,
    input [3:0] exu_op,
    output reg [31:0] result
);
  reg [31:0] src1;
  reg [31:0] src2;
  always @(*) begin
    case (src_sel)
      2'h0: begin
        src1 = rs1;
        src2 = rs2;
      end
      2'h1: begin
        src1 = rs1;
        src2 = imm;
      end

      default: begin
        src1 = rs1;
        src2 = rs2;
      end
    endcase
    //上面分配了运算参与源 下面进行计算
    case (exu_op)
      4'h0: begin
        result = src1 + src2;
      end
      default: begin
        result = 32'b0;

      end
    endcase

  end






endmodule
