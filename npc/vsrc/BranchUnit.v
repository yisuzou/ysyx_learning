module BranchUnit (
    input        branch_en,
    input  [2:0] branch_op,
    input        zero,
    input        signed_lt,
    input        unsigned_lt,
    output reg   branch_taken
);
  localparam BR_BEQ  = 3'h0;
  localparam BR_BNE  = 3'h1;
  localparam BR_BLT  = 3'h4;
  localparam BR_BGE  = 3'h5;
  localparam BR_BLTU = 3'h6;
  localparam BR_BGEU = 3'h7;

  always @(*) begin
    branch_taken = 1'b0;
    if (branch_en) begin
      case (branch_op)
        BR_BEQ:  branch_taken = zero;
        BR_BNE:  branch_taken = !zero;
        BR_BLT:  branch_taken = signed_lt;
        BR_BGE:  branch_taken = !signed_lt;
        BR_BLTU: branch_taken = unsigned_lt;
        BR_BGEU: branch_taken = !unsigned_lt;
        default: branch_taken = 1'b0;
      endcase
    end
  end
endmodule
