module GPR #(
    ADDR_WIDTH = 5,
    DATA_WIDTH = 32
) (
    input                   clk,
    input                   rst_n,
    input  [DATA_WIDTH-1:0] wdata,
    input  [ADDR_WIDTH-1:0] waddr,
    input                   wen,
    input  [ADDR_WIDTH-1:0] raddr1,
    input  [ADDR_WIDTH-1:0] raddr2,
    output [DATA_WIDTH-1:0] rdata1,
    output [DATA_WIDTH-1:0] rdata2,
    output [DATA_WIDTH-1:0] rdata_a0
);
  localparam E_ADDR_WIDTH = ADDR_WIDTH - 1;
  localparam NR_GPR = 1 << E_ADDR_WIDTH;

  reg [DATA_WIDTH-1:0] rf[NR_GPR-1:0];
  integer i;

  wire [E_ADDR_WIDTH-1:0] raddr1e = raddr1[E_ADDR_WIDTH-1:0];
  wire [E_ADDR_WIDTH-1:0] raddr2e = raddr2[E_ADDR_WIDTH-1:0];
  wire [E_ADDR_WIDTH-1:0] waddr_e = waddr[E_ADDR_WIDTH-1:0];
  wire raddr1_valid = !raddr1[ADDR_WIDTH-1];
  wire raddr2_valid = !raddr2[ADDR_WIDTH-1];
  wire waddr_valid = !waddr[ADDR_WIDTH-1];

  assign rdata1 = (!rst_n || !raddr1_valid || raddr1e == 0) ?
                  {DATA_WIDTH{1'b0}} : rf[raddr1e];
  assign rdata2 = (!rst_n || !raddr2_valid || raddr2e == 0) ?
                  {DATA_WIDTH{1'b0}} : rf[raddr2e];
  assign rdata_a0 = !rst_n ? {DATA_WIDTH{1'b0}} : rf[10];

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (i = 0; i < NR_GPR; i = i + 1) begin
        rf[i] <= {DATA_WIDTH{1'b0}};
      end
    end else if (wen && waddr_valid && waddr_e != 0) begin
      rf[waddr_e] <= wdata;
    end
  end
endmodule
