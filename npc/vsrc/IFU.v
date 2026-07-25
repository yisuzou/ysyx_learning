module IFU (
    input rst_n,
    input [31:0] pc,
    output reg [31:0] inst,
    output [31:0] debug_pc,
    output [31:0] debug_inst
);

  assign debug_pc = pc;
  assign debug_inst = inst;
  always @(*) begin
    if (rst_n) begin
      inst = pmem_read(pc);
    end else begin
      inst = 32'h00000013;
    end
  end

endmodule
