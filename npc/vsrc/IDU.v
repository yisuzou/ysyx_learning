//负责对当前指令进行译码, 准备执行阶段需要使用的数据和控制信号
module IDU (
    input [31:0] inst,
    output [4:0] rs1,
    output [4:0] rs2,
    output [31:0] imm,
    output invalid_inst,
    output [3:0] src_sel,
    output [3:0] exu_op
);
  //输出应该包含imm，rs1，rs2，rd，
  wire [6:0] opcode = inst[6:0];
  wire [4:0] rd_immSB = inst[11:7];
  wire [2:0] funct3_immUJ = inst[14:12];
  wire [4:0] rs1_immUJ = inst[19:15];
  wire [4:0] rs2_immIUJ = inst[24:20];
  wire [6:0] funct7_immISBUJ = inst[31:25];
  reg invalid_inst;
  always @(*) begin
    //R是寄存器型，将要涉及到寄存器的操作
    //基本流程为，读取两个源寄存器内容，运算（EXU负责），写到目标寄存器（WBU负责，需要给信
    //号，给寄存器地址）
    invalid_inst = 1'b1;
    case (opcode)
      7'b0110011: begin  //R指令识别
        rs1 = rs1_immUJ;
        rs2 = rs2_immIUJ;
        case ({
          funct3_immUJ, funct3_immUJ
        })
          {
            7'h0, 3'h0
          } : begin
            src_sel = 4'h0;  //寄存器1和2
            exu_op  = 4'h0;  //add
          end
          default: begin
            invalid_inst = 1'b0;
          end
        endcase
      end
      7'b0010011: begin
        imm = {{20{funct7_immISBUJ[6]}}, funct7_immISBUJ, rs2_immIUJ};
        case (funct3_immUJ)
          3'h0: begin
            src_sel = 4'h1;  //寄存器1和imm
            exu_op  = 4'h0;  //addi
          end
          default: begin
            invalid_inst = 1'b0;
          end
        endcase
      end
      default: begin
        invalid_inst = 1'b0;
      end
    endcase
  end

endmodule
