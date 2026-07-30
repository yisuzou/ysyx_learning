module GPR #(
    ADDR_WIDTH = 5,
    DATA_WIDTH = 32
) (
    input clk,
    input rst_n,
    input [DATA_WIDTH-1:0] wdata,
    input [ADDR_WIDTH-1:0] waddr,
    input wen,
  input [ADDR_WIDTH-1:0] raddr1,
  input [ADDR_WIDTH-1:0] raddr2,
  output [DATA_WIDTH-1:0] rdata1,
  output [DATA_WIDTH-1:0] rdata2,
  output [DATA_WIDTH-1:0] rdata_a0
);
  reg [DATA_WIDTH-1:0] rf[2**ADDR_WIDTH-1:0];
  integer i;

  assign rdata1 = (!rst_n || raddr1 == 5'b0) ? 32'b0 : rf[raddr1];
  assign rdata2 = (!rst_n || raddr2 == 5'b0) ? 32'b0 : rf[raddr2];
  assign rdata_a0 = !rst_n ? 32'b0 : rf[5'd10];

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (i = 0; i < (1 << ADDR_WIDTH); i = i + 1) begin
        rf[i] <= {DATA_WIDTH{1'b0}};
      end
    end else if (wen && waddr != 5'b0) begin
      rf[waddr] <= wdata;
    end
  end
endmodule
