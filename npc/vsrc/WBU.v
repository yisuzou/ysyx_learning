//维护PC, 默认+4；
//实现正确的跳转；
module WBU (
    input clk,
    input rst_n,  //低有效复位信号
    input pc_we,  //pc写使能，沿用了logisim设计思路
    input [1:0] pc_wsel,
    input diff_ifu_valid,
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
   // output reg [31:0] csr_wdata,
    output reg [31:0] pc,
    output invalid_csr_access,
    output [31:0] dbg_mstatus,
    output [31:0] dbg_mtvec,
    output [31:0] dbg_mepc,
    output [31:0] dbg_mcause,
    output [31:0] dbg_mcycle,
    output [31:0] dbg_mcycleh,
    output [31:0] dbg_mvendorid,
    output [31:0] dbg_marchid
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
  //localparam CSR_IMMEDIATE  = 2'd1;
  localparam CSR_REG   = 2'd2;
  //localparam CSR_XXX2   = 2'd3;
  //
  localparam MCAUSE_ECALL_FROM_M = 32'h0000000b;
  reg [31:0] csr_wdata;
  reg [31:0] pc_wdata;
  wire [31:0] mepc_data = pc;
  wire [31:0] mtvec_data;//由CSR模块提供
  wire [31:0] mcause_data = MCAUSE_ECALL_FROM_M;

  // Parallel PC/write-data candidates: compute all, then select.
  wire [31:0] pc_plus4          = pc + 32'h4;
  wire [31:0] pc_plus_imm       = pc + imm;
  wire [31:0] exu_result_masked = exu_result & ~32'h1;

  wire [31:0] gpr_wdata_pc_plus4 = pc_plus4;
  wire [31:0] gpr_wdata_pc_imm   = pc_plus_imm;

  wire [31:0] csr_wdata_exu = exu_result;
  wire [31:0] csr_wdata_reg = gpr_rdata1;
  wire [31:0] csr_wdata_csr = csr_rdata1;

  always @(*) begin
    case (gpr_wsel)
      GPR_EXU_RESULT: gpr_wdata = exu_result;
      GPR_PC_PLUS4:   gpr_wdata = gpr_wdata_pc_plus4;
      GPR_IMMEDIATE:  gpr_wdata = imm;
      GPR_PC_IMM:     gpr_wdata = gpr_wdata_pc_imm;
      GPR_MEM_DATA:   gpr_wdata = mem_rdata;
      default:        gpr_wdata = 32'h0;
    endcase
    case (csr_wsel)
      CSR_EXU_RESULT: csr_wdata = csr_wdata_exu;
      CSR_REG:        csr_wdata = csr_wdata_reg;
      default:        csr_wdata = csr_wdata_csr;
    endcase
  end

  always @(*) begin
    case (pc_wsel)
      PC_EXU_RESULT: pc_wdata = exu_result_masked;
      PC_BRANCH:     pc_wdata = pc_plus_imm;
      PC_TO_MTVEC:   pc_wdata = mtvec_data;
      PC_TO_MEPC:    pc_wdata = csr_rdata1;
      default:       pc_wdata = pc_plus4;
    endcase
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
      .invalid_csr_access(invalid_csr_access),
      .dbg_mstatus(dbg_mstatus),
      .dbg_mtvec(dbg_mtvec),
      .dbg_mepc(dbg_mepc),
      .dbg_mcause(dbg_mcause),
      .dbg_mcycle(dbg_mcycle),
      .dbg_mcycleh(dbg_mcycleh),
      .dbg_mvendorid(dbg_mvendorid),
      .dbg_marchid(dbg_marchid)
  );

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pc <= 32'h80000000;
    end else if (pc_we) begin
      pc <= pc_wdata;
    end else if (diff_ifu_valid) begin
      pc <= pc_plus4;
    end
  end


endmodule
