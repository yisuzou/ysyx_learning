//维护PC, 默认+4；
//实现正确的跳转；
module WBU (
    input clk,
    input rst_n,  //低有效复位信号
    input pc_we,  //pc写使能，沿用了logisim设计思路
    input [1:0] pc_wsel,
    input [31:0] exu_result,
    input [31:0] imm,
    //pc输出二选一，顺序自加和跳转输入；
    input gpr_we,
    input [2:0] gpr_wsel,
    input [31:0] mem_rdata,
    input [4:0] rs1,
    input [4:0] rs2,
    input [4:0] rd,
    input [11:0] csr_wraddr,
    input csr_we,
    input [1:0] csr_wsel,
    //异常处理相关信号
    input is_ecall,//环境调用异常
    output [31:0] csr_rdata1,
    output [31:0] gpr_rdata1,
    output [31:0] gpr_rdata2,
    output [31:0] gpr_a0,
    output reg [31:0] gpr_wdata,
    output reg [31:0] csr_wdata,
    output reg [31:0] pc,
    output invalid_csr_access
);
  localparam PC_EXU_RESULT = 2'h0;
  localparam PC_BRANCH     = 2'h1;
  localparam PC_TO_MTVEC   = 2'h2;
  localparam PC_TO_MEPC    = 2'h3;

  localparam GPR_EXU_RESULT = 3'd0;
  localparam GPR_PC_PLUS4   = 3'd1;
  localparam GPR_IMMEDIATE  = 3'd2;
  localparam GPR_PC_IMM     = 3'd3;
  localparam GPR_MEM_DATA   = 3'd4;
 
  localparam CSR_EXU_RESULT = 2'd0;
  localparam CSR_IMMEDIATE  = 2'd1;
  localparam CSR_REG   = 2'd2;
  localparam CSR_XXX2   = 2'd3;

  reg [31:0] pc_wdata;
  reg [31:0] mepc_data;
  wire [31:0] mtvec_data;//由CSR模块提供
  reg [31:0] mcause_data;

  always @(*) begin
    case (gpr_wsel)
      GPR_EXU_RESULT: gpr_wdata = exu_result;
      GPR_PC_PLUS4:   gpr_wdata = pc + 32'h4;
      GPR_IMMEDIATE:  gpr_wdata = imm;
      GPR_PC_IMM:     gpr_wdata = pc + imm;
      GPR_MEM_DATA:   gpr_wdata = mem_rdata;
      default:        gpr_wdata = 32'h0;
    endcase
    case (csr_wsel)
      CSR_EXU_RESULT: csr_wdata = exu_result;
      CSR_REG: csr_wdata = gpr_rdata1;
      default: csr_wdata = csr_rdata1;
    endcase
  end

  always @(*) begin
    case (pc_wsel)
      PC_EXU_RESULT: pc_wdata = exu_result & ~32'h1;
      PC_BRANCH:     pc_wdata = pc + imm;
      PC_TO_MTVEC:    pc_wdata = mtvec_data;
      PC_TO_MEPC:     pc_wdata = csr_rdata1;
      default:       pc_wdata = pc + 32'h4;
    endcase
  end
  //异常处理逻辑
  always @(posedge is_ecall) begin
    mepc_data <= pc; //默认mepc为当前pc
    mcause_data <= 32'hb;//m模式环境调用
  end

  GPR gpr1 (
      .clk(clk),
      .rst_n(rst_n),
      .wdata(gpr_wdata),
      .waddr(rd),
      .wen(gpr_we),
      .raddr1(rs1),
      .raddr2(rs2),
      .rdata1(gpr_rdata1),
      .rdata2(gpr_rdata2),
      .rdata_a0(gpr_a0)
  );
 
  CSR csr1 (
      .clk(clk),
      .rst_n(rst_n),
      .wdata(csr_wdata),
      .waddr(csr_wraddr),
      .wen(csr_we),
      .raddr1(csr_wraddr),
      .rdata1(csr_rdata1),
      .is_ecall(is_ecall),
      .mepc_data(mepc_data),
      .mcause_data(mcause_data),
      .mtvec_data(mtvec_data),
      .invalid_csr_access(invalid_csr_access)
  );
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pc <= 32'h80000000;
    end else begin
      if (pc_we) begin
        pc <= pc_wdata;
      end else begin
        pc <= pc + 32'h4;
      end
    end
  end


endmodule
