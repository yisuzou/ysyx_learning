//负责对当前指令进行译码, 准备执行阶段需要使用的数据和控制信号
module IDU (
    input [31:0] inst,
    output reg [4:0] rs1,
    output reg [4:0] rs2,
    output reg [4:0] rd,
    output reg [31:0] imm,
    output reg invalid_inst,
    // 0:valid 1: invalid;
    output reg [1:0] src_sel,
    // 2'b00: rs1, rs2
    // 2'b01: rs1, imm
    // 2'b10: pc, imm
    // 2'b11: pc, 4
    output reg [3:0] exu_op,
    //0:+
    //1:-
    //2:*
    //3:/
    //...
    //寄存器相关，PC和gpr
    output reg pc_we,
    output reg gpr_we,
    output reg [2:0] gpr_wsel,
    //访存相关
    output reg mem_we,
    output reg [1:0] mem_rbhw,  //0:no_read,1: byte, 2:half 3:word
    output reg [1:0] mem_wbhw,
    output reg isign,  //表示扩展时是否视为有符号数；
    output reg valid,
    //ebreak信号
    output reg is_ebreak
);
  //输出应该包含imm，rs1，rs2，rd，
  wire [ 6:0] opcode = inst[6:0];
  wire [ 4:0] rd_immSB = inst[11:7];
  wire [ 2:0] funct3_immUJ = inst[14:12];
  wire [ 4:0] rs1_immUJ = inst[19:15];
  wire [ 4:0] rs2_immIUJ = inst[24:20];
  wire [ 6:0] funct7_immISBUJ = inst[31:25];
  //imm类型处理
  wire [31:0] immI = {{20{funct7_immISBUJ[6]}}, funct7_immISBUJ, rs2_immIUJ};
  wire [31:0] immU = {funct7_immISBUJ, rs2_immIUJ, rs1_immUJ, funct3_immUJ, 12'b0};
  wire [31:0] immS = {{20{funct7_immISBUJ[6]}}, funct7_immISBUJ, rd_immSB};
  always @(*) begin
    //初始值决定
    invalid_inst = 1'b0;
    pc_we = 1'b0;
    gpr_we = 1'b0;
    gpr_wsel = 3'd0;
    mem_we = 1'b0;
    mem_rbhw = 2'd0;
    mem_wbhw = 2'd0;
    isign = 1'b0;
    is_ebreak = 1'b0;
    exu_op = 4'h0;
    imm = 32'h0;
    src_sel = 2'h0;
    valid = 1'b0;
    //R是寄存器型，将要涉及到寄存器的操作
    //基本流程为，读取两个源寄存器内容，运算（EXU负责），写到目标寄存器（WBU负责，需要给信
    //号，给寄存器地址）
    rs1 = rs1_immUJ;
    rs2 = rs2_immIUJ;
    rd = rd_immSB;

    case (opcode)
      7'b0110011: begin  //R指令识别
        case ({
          funct7_immISBUJ, funct3_immUJ
        })
          {
            7'h0, 3'h0
          } : begin
            src_sel  = 2'h0;  //寄存器1和2
            exu_op   = 4'h0;  //add
            gpr_we   = 1'b1;
            gpr_wsel = 3'd0;
          end
          default: begin
            invalid_inst = 1'b1;
          end
        endcase
      end
      //I型指令
      7'b0010011: begin
        imm = immI;
        case (funct3_immUJ)
          3'h0: begin
            src_sel  = 2'h1;  //寄存器1和imm
            exu_op   = 4'h0;  //addi
            gpr_we   = 1'b1;
            gpr_wsel = 3'd0;
          end
          default: begin
            invalid_inst = 1'b1;
          end
        endcase
      end
      7'b0000011: begin
        imm = immI;
        case (funct3_immUJ)
          3'h2: begin  //lw
            src_sel = 2'h1;
            exu_op = 4'h0;
            gpr_we = 1'b1;
            gpr_wsel = 3'd4;
            mem_rbhw = 2'd3;
            valid = 1'b1;
          end
          3'h4: begin  //lbu
            src_sel = 2'h1;  //寄存器1和imm
            exu_op = 4'h0;
            gpr_we = 1'b1;
            gpr_wsel = 3'd4;
            mem_rbhw = 2'd1;
            valid = 1'b1;
          end
          default: invalid_inst = 1'b1;
        endcase
      end

      //跳转指令
      7'b1100111: begin
        imm = immI;
        case (funct3_immUJ)
          3'h0: begin
            src_sel = 2'h1;
            exu_op = 4'h0;
            gpr_we = 1'b1;
            gpr_wsel = 3'd1;
            pc_we = 1'b1;
          end
          default: invalid_inst = 1'b1;
        endcase
      end
      //U型指令
      7'b0110111: begin
        imm = immU;
        //将立即数存入rd
        gpr_we = 1'b1;
        gpr_wsel = 3'd2;
      end
      //S型指令
      7'b0100011: begin
        imm = immS;
        case (funct3_immUJ)
          3'h0: begin  //sb
            src_sel = 2'h1;
            exu_op = 4'h0;
            mem_we = 1'b1;
            mem_wbhw = 2'd1;
            valid = 1'b1;
          end
          3'h2: begin  //sw
            src_sel = 2'h1;
            exu_op = 4'h0;
            mem_we = 1'b1;
            mem_wbhw = 2'd3;
            valid = 1'b1;
          end
          default: invalid_inst = 1'b1;
        endcase

      end
      //ebreak指令
      7'b1110011: begin
        case (inst)
          32'h00100073: begin
            is_ebreak = 1'b1;
          end
          default: begin
            invalid_inst = 1'b1;
          end
        endcase
      end
      default: begin
        invalid_inst = 1'b1;
      end
    endcase
  end
endmodule
