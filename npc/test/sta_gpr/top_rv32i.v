module top (
    input        clk,
    input        rst_n,
    input  [31:0] wdata,
    input  [4:0]  waddr,
    input         wen,
    input  [4:0]  raddr1,
    input  [4:0]  raddr2,
    output [31:0] rdata1,
    output [31:0] rdata2,
    output [31:0] rdata_a0
);
  GPR #(
    .ADDR_WIDTH(5),
    .DATA_WIDTH(32)
  ) u_gpr (
    .clk(clk),
    .rst_n(rst_n),
    .wdata(wdata),
    .waddr(waddr),
    .wen(wen),
    .raddr1(raddr1),
    .raddr2(raddr2),
    .rdata1(rdata1),
    .rdata2(rdata2),
    .rdata_a0(rdata_a0)
  );
endmodule
