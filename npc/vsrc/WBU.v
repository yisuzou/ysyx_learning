//维护PC, 默认+4；
//实现正确的跳转；
module WBU (
    input clk,
    input rst_n,  //低有效复位信号
    input pc_we,  //pc写使能，沿用了logisim设计思路
    input [31:0] pc_wdata,
    //pc输出二选一，顺序自加和跳转输入；
    input gpr_we,
    input [31:0] gpr_wdata,
    input [4:0] rs1,
    input [4:0] rs2,
    input [4:0] rd,
    output [31:0] gpr_rdata1,
    output [31:0] gpr_rdata2,
    output [31:0] gpr_a0,
    output reg [31:0] pc
);

  GPR gpr1 (
      .clk(clk),
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

