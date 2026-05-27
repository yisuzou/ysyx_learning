module GPR #(
    ADDR_WIDTH = 5,
    DATA_WIDTH = 32
) (
    input clk,
    input [DATA_WIDTH-1:0] wdata,
    input [ADDR_WIDTH-1:0] waddr,
    input wen,
    input [ADDR_WIDTH-1:0] raddr1,
    input [ADDR_WIDTH-1:0] raddr2,
    output [DATA_WIDTH-1:0] rdata1,
    output [DATA_WIDTH-1:0] rdata2
);
  reg [DATA_WIDTH-1:0] rf[2**ADDR_WIDTH-1:0];


  assign rdata1 = (raddr1 == 5'b0) ? 32'b0 : rf[raddr1];
  assign rdata2 = (raddr2 == 5'b0) ? 32'b0 : rf[raddr2];
  //assign we = wen && (|waddr);
  always @(posedge clk) begin
    if (wen) rf[waddr] <= wdata;
  end
endmodule
