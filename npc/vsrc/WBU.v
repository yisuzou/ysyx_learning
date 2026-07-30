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
    output [31:0] gpr_rdata1,
    output [31:0] gpr_rdata2,
    output [31:0] gpr_a0,
    output reg [31:0] gpr_wdata,
    output reg [31:0] pc
);
  localparam PC_EXU_RESULT = 2'h0;
  localparam PC_BRANCH     = 2'h1;

  localparam GPR_EXU_RESULT = 3'd0;
  localparam GPR_PC_PLUS4   = 3'd1;
  localparam GPR_IMMEDIATE  = 3'd2;
  localparam GPR_PC_IMM     = 3'd3;
  localparam GPR_MEM_DATA   = 3'd4;

  reg [31:0] pc_wdata;

  always @(*) begin
    case (gpr_wsel)
      GPR_EXU_RESULT: gpr_wdata = exu_result;
      GPR_PC_PLUS4:   gpr_wdata = pc + 32'h4;
      GPR_IMMEDIATE:  gpr_wdata = imm;
      GPR_PC_IMM:     gpr_wdata = pc + imm;
      GPR_MEM_DATA:   gpr_wdata = mem_rdata;
      default:        gpr_wdata = 32'h0;
    endcase
  end

  always @(*) begin
    case (pc_wsel)
      PC_EXU_RESULT: pc_wdata = exu_result & ~32'h1;
      PC_BRANCH:     pc_wdata = pc + imm;
      default:       pc_wdata = pc + 32'h4;
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
