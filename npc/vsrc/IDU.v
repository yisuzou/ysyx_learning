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
    //4:< less than
    //5: << shift left
    //6: >> shift right
    //7: >>_a algebraic shift right
    //8: and
    //9: or
    //10: xor
    //11: signed less than
    //...
    //寄存器相关，PC和gpr
    output reg pc_we,
    output reg [1:0] pc_wsel,
    output reg branch_en,
    output reg [2:0] branch_op,
    output reg gpr_we,
    output reg [2:0] gpr_wsel,
    //访存相关
    output reg mem_we,
    output reg [1:0] mem_rbhw,  //0:no_read,1: byte, 2:half 3:word
    output reg [1:0] mem_wbhw,
    output reg isign,  //表示扩展时是否视为有符号数；
    output reg mem_valid,  //表示访存操作是否有效，防止在访存阶段出现无效的访存操作
    //ebreak信号
    output reg is_ebreak
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

  localparam PC_EXU_RESULT = 2'h0;
  localparam PC_BRANCH     = 2'h1;

  localparam GPR_EXU_RESULT = 3'd0;
  localparam GPR_PC_PLUS4   = 3'd1;
  localparam GPR_IMMEDIATE  = 3'd2;
  localparam GPR_PC_IMM     = 3'd3;
  localparam GPR_MEM_DATA   = 3'd4;

  localparam MEM_NONE = 2'd0;
  localparam MEM_BYTE = 2'd1;
  localparam MEM_HALF = 2'd2;
  localparam MEM_WORD = 2'd3;

  localparam BR_BEQ  = 3'h0;
  localparam BR_BNE  = 3'h1;
  localparam BR_BLT  = 3'h4;
  localparam BR_BGE  = 3'h5;
  localparam BR_BLTU = 3'h6;
  localparam BR_BGEU = 3'h7;

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
  wire [31:0] immB = {{20{inst[31]}}, inst[7], inst[30:25], inst[11:8], 1'b0};
  wire [31:0] immJ = {{11{inst[31]}}, inst[31], inst[19:12], inst[20], inst[30:21], 1'b0};
`ifdef CONFIG_RVE
  reg invalid_gpr;
`endif
  always @(*) begin
    //初始值设定
    invalid_inst = 1'b0;
    pc_we = 1'b0;
    pc_wsel = PC_EXU_RESULT;
    branch_en = 1'b0;
    branch_op = BR_BEQ;
    gpr_we = 1'b0;
    gpr_wsel = GPR_EXU_RESULT;
    mem_we = 1'b0;
    mem_rbhw = MEM_NONE;
    mem_wbhw = MEM_NONE;
    isign = 1'b0;
    is_ebreak = 1'b0;
    exu_op = EXU_ADD;
    imm = 32'h0;
    src_sel = SRC_REG_REG;
    mem_valid = 1'b0;
    //R是寄存器型，将要涉及到寄存器的操作
    //基本流程为，读取两个源寄存器内容，运算（EXU负责），写到目标寄存器（WBU负责，需要给信
    //号，给寄存器地址）
    rs1 = rs1_immUJ;
    rs2 = rs2_immIUJ;
    rd = rd_immSB;
`ifdef CONFIG_RVE
    invalid_gpr = 1'b0;
`endif

    case (opcode)
      7'b0110011: begin  //R指令识别
`ifdef CONFIG_RVE
        invalid_gpr = rs1_immUJ[4] || rs2_immIUJ[4] || rd_immSB[4];
`endif
        case ({
          funct7_immISBUJ, funct3_immUJ
        })
          {
            7'h0, 3'h0 //add
          } : begin
            src_sel  = SRC_REG_REG;  //寄存器1和2
            exu_op   = EXU_ADD;  //add
            gpr_we   = 1'b1;
            gpr_wsel = GPR_EXU_RESULT;
          end
          {
            7'h20, 3'h0  //sub
          } : begin
            src_sel  = SRC_REG_REG;  //寄存器1和2
            exu_op   = EXU_SUB;  //sub
            gpr_we   = 1'b1;
            gpr_wsel = GPR_EXU_RESULT;
          end
          {
            7'h0,3'h3  //sltu
          } : begin
            src_sel  = SRC_REG_REG;  //寄存器1和2
            exu_op   = EXU_SLTU;  //sltu
            gpr_we   = 1'b1;
            gpr_wsel = GPR_EXU_RESULT;
          end
          {
            7'h0,3'h2  //slt
          } : begin
            src_sel  = SRC_REG_REG;  //寄存器1和2
            exu_op   = EXU_SLT;  //slt
            gpr_we   = 1'b1;
            gpr_wsel = GPR_EXU_RESULT;
          end
          {
            7'h0,3'h6  //or
          } : begin
            src_sel  = SRC_REG_REG;  //寄存器1和2
            exu_op   = EXU_OR;  //or
            gpr_we   = 1'b1;
            gpr_wsel = GPR_EXU_RESULT;
          end
          {
            7'h0,3'h7  //and
          } : begin
            src_sel  = SRC_REG_REG;  //寄存器1和2
            exu_op   = EXU_AND;  //and
            gpr_we   = 1'b1;
            gpr_wsel = GPR_EXU_RESULT;
          end
          {
            7'h0,3'h4  //xor
          } : begin
            src_sel  = SRC_REG_REG;  //寄存器1和2
            exu_op   = EXU_XOR;  //xor
            gpr_we   = 1'b1;
            gpr_wsel = GPR_EXU_RESULT;
          end
          {
            7'h0,3'h5  //srl
          } : begin
            src_sel  = SRC_REG_REG;  //寄存器1和2
            exu_op   = EXU_SRL;  //srl
            gpr_we   = 1'b1;
            gpr_wsel = GPR_EXU_RESULT;
          end
          {
            7'h0,3'h1  //sll
          } : begin
            src_sel  = SRC_REG_REG;  //寄存器1和2
            exu_op   = EXU_SLL;  //sll
            gpr_we   = 1'b1;
            gpr_wsel = GPR_EXU_RESULT;
          end
          {
            7'h20,3'h5 //sra
          } : begin
            src_sel  = SRC_REG_REG;  //寄存器1和2
            exu_op   = EXU_SRA;  //sra
            gpr_we   = 1'b1;
            gpr_wsel = GPR_EXU_RESULT;
          end
          default: begin
            invalid_inst = 1'b1;
          end
        endcase
      end
      //I型指令
      7'b0010011: begin
        imm = immI;
`ifdef CONFIG_RVE
        invalid_gpr = rs1_immUJ[4] || rd_immSB[4];
`endif
        case (funct3_immUJ)
          3'h0: begin
            src_sel  = SRC_REG_IMM;  //寄存器1和imm
            exu_op   = EXU_ADD;  //addi
            gpr_we   = 1'b1;
            gpr_wsel = GPR_EXU_RESULT;
          end
          3'h1: begin
            case(imm[11:5])
              7'h00: begin  //slli
                src_sel  = SRC_REG_IMM;  //寄存器1和imm
                exu_op   = EXU_SLL;  //slli
                gpr_we   = 1'b1;
                gpr_wsel = GPR_EXU_RESULT;  //exu_result写入rd
              end
              default: begin
                invalid_inst = 1'b1;
              end
            endcase
          end
          3'h2: begin //slti
            src_sel  = SRC_REG_IMM;  //寄存器1和imm
            exu_op   = EXU_SLT;  //slti
            gpr_we   = 1'b1;
            gpr_wsel = GPR_EXU_RESULT;
          end
          3'h3: begin //sltiu
            src_sel  = SRC_REG_IMM;  //寄存器1和imm
            exu_op   = EXU_SLTU;
            gpr_we   = 1'b1;
            gpr_wsel = GPR_EXU_RESULT;
          end
          3'h4: begin //xori
            src_sel  = SRC_REG_IMM;  //寄存器1和imm
            exu_op   = EXU_XOR;  //xori
            gpr_we   = 1'b1;
            gpr_wsel = GPR_EXU_RESULT;
          end
          3'h5: begin
            case(imm[11:5])
              7'h00: begin  //srli
                src_sel  = SRC_REG_IMM;  //寄存器1和imm
                exu_op   = EXU_SRL;  //srli
                gpr_we   = 1'b1;
                gpr_wsel = GPR_EXU_RESULT;
              end
              7'h20: begin  //srai
                src_sel  = SRC_REG_IMM;  //寄存器1和imm
                exu_op   = EXU_SRA;  //srai
                gpr_we   = 1'b1;
                gpr_wsel = GPR_EXU_RESULT;
              end
              default: begin
                invalid_inst = 1'b1;
              end
            endcase
          end
          3'h6: begin  //ori
            src_sel  = SRC_REG_IMM;  //寄存器1和imm
            exu_op   = EXU_OR;  //ori
            gpr_we   = 1'b1;
            gpr_wsel = GPR_EXU_RESULT;
          end
          3'h7: begin  //andi
            src_sel  = SRC_REG_IMM;  //寄存器1和imm
            exu_op   = EXU_AND;  //andi
            gpr_we   = 1'b1;
            gpr_wsel = GPR_EXU_RESULT;
          end
          default: begin
            invalid_inst = 1'b1;
          end
        endcase
      end
      //I型load指令
      7'b0000011: begin
        imm = immI;
`ifdef CONFIG_RVE
        invalid_gpr = rs1_immUJ[4] || rd_immSB[4];
`endif
        case (funct3_immUJ)
          3'h0: begin  //lb
            src_sel = SRC_REG_IMM;
            exu_op = EXU_ADD;
            gpr_we = 1'b1;
            gpr_wsel = GPR_MEM_DATA;
            mem_rbhw = MEM_BYTE;
            isign = 1'b1;
            mem_valid = 1'b1;
          end
          3'h1: begin  //lh
            src_sel = SRC_REG_IMM;
            exu_op = EXU_ADD;
            gpr_we = 1'b1;
            gpr_wsel = GPR_MEM_DATA;
            mem_rbhw = MEM_HALF;
            isign = 1'b1;
            mem_valid = 1'b1;
          end
          3'h2: begin  //lw
            src_sel = SRC_REG_IMM;
            exu_op = EXU_ADD;
            gpr_we = 1'b1;
            gpr_wsel = GPR_MEM_DATA;
            mem_rbhw = MEM_WORD;
            mem_valid = 1'b1;
          end
          3'h4: begin  //lbu
            src_sel = SRC_REG_IMM;  //寄存器1和imm
            exu_op = EXU_ADD;
            gpr_we = 1'b1;
            gpr_wsel = GPR_MEM_DATA;
            mem_rbhw = MEM_BYTE;
            mem_valid = 1'b1;
          end
          3'h5: begin  //lhu
            src_sel = SRC_REG_IMM;  //寄存器1和imm
            exu_op = EXU_ADD;
            gpr_we = 1'b1;
            gpr_wsel = GPR_MEM_DATA;
            mem_rbhw = MEM_HALF;
            mem_valid = 1'b1;
          end
          default: invalid_inst = 1'b1;
        endcase
      end

      //跳转指令
      7'b1100111: begin //jalr指令
        imm = immI;
`ifdef CONFIG_RVE
        invalid_gpr = rs1_immUJ[4] || rd_immSB[4];
`endif
        case (funct3_immUJ)
          3'h0: begin
            src_sel = SRC_REG_IMM;
            exu_op = EXU_ADD;
            gpr_we = 1'b1;
            gpr_wsel = GPR_PC_PLUS4;
            pc_we = 1'b1;
          end
          default: invalid_inst = 1'b1;
        endcase
      end

      //B型条件分支指令
      7'b1100011: begin
        imm = immB;
`ifdef CONFIG_RVE
        invalid_gpr = rs1_immUJ[4] || rs2_immIUJ[4];
`endif
        src_sel = SRC_REG_REG;
        exu_op = EXU_SUB;
        pc_wsel = PC_BRANCH;
        branch_op = funct3_immUJ;
        case (funct3_immUJ)
          BR_BEQ,   //beq
          BR_BNE,   //bne
          BR_BLT,   //blt
          BR_BGE,   //bge
          BR_BLTU,  //bltu
          BR_BGEU:  //bgeu
          branch_en = 1'b1;
          default: invalid_inst = 1'b1;
        endcase
      end

      7'b1101111: begin  //jal指令
        imm = immJ;
`ifdef CONFIG_RVE
        invalid_gpr = rd_immSB[4];
`endif
        src_sel = SRC_PC_IMM;  //pc和imm
        exu_op = EXU_ADD;  //add
        pc_we = 1'b1;
        gpr_we = 1'b1;
        gpr_wsel = GPR_PC_PLUS4;  //将pc+4写入rd
      end

      //U型指令-lui
      7'b0110111: begin
        imm = immU;
`ifdef CONFIG_RVE
        invalid_gpr = rd_immSB[4];
`endif
        //将立即数存入rd
        gpr_we = 1'b1;
        gpr_wsel = GPR_IMMEDIATE;
      end

      //U型指令-auipc
      7'b0010111: begin
        imm = immU;
`ifdef CONFIG_RVE
        invalid_gpr = rd_immSB[4];
`endif
        src_sel = SRC_PC_IMM;  //pc和imm
        exu_op = EXU_ADD;  //add
        gpr_we = 1'b1;
        gpr_wsel = GPR_PC_IMM;
      end
      //S型指令
      7'b0100011: begin
        imm = immS;
`ifdef CONFIG_RVE
        invalid_gpr = rs1_immUJ[4] || rs2_immIUJ[4];
`endif
        case (funct3_immUJ)
          3'h0: begin  //sb
            src_sel = SRC_REG_IMM;
            exu_op = EXU_ADD;
            mem_we = 1'b1;
            mem_wbhw = MEM_BYTE;
            mem_valid = 1'b1;
          end
          3'h1: begin  //sh
            src_sel = SRC_REG_IMM;
            exu_op = EXU_ADD;
            mem_we = 1'b1;
            mem_wbhw = MEM_HALF;
            mem_valid = 1'b1;
          end
          3'h2: begin  //sw
            src_sel = SRC_REG_IMM;
            exu_op = EXU_ADD;
            mem_we = 1'b1;
            mem_wbhw = MEM_WORD;
            mem_valid = 1'b1;
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
`ifdef CONFIG_RVE
    if (invalid_gpr) begin
      invalid_inst = 1'b1;
      pc_we = 1'b0;
      branch_en = 1'b0;
      gpr_we = 1'b0;
      mem_we = 1'b0;
      mem_valid = 1'b0;
      is_ebreak = 1'b0;
    end
`endif
  end
endmodule
