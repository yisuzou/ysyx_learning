// Simulation-only protocol checker: a message must stay valid and unchanged
// while it is stalled (valid && !ready).  It observes traffic only and never
// participates in functional control; do not synthesise this module.
module rv_stability_check #(parameter W = 64) (
    input clk,
    input rst_n,
    input valid,
    input ready,
    input [W-1:0] payload
);
  reg was_stalled;
  reg [W-1:0] saved;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      was_stalled <= 1'b0;
      saved <= {W{1'b0}};
    end else begin
      if (was_stalled) begin
        if ((valid !== 1'b1) || (payload !== saved)) begin
          $display("FAIL: message changed while stalled at %0t", $time);
          $finish;
        end
      end
      was_stalled <= valid && !ready;
      saved <= payload;
    end
  end
endmodule
