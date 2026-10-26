module top (
    input  [31:0] a,
    input  [31:0] b,
    input         cin,
    output [31:0] sum,
    output        cout
);
  adder_lookahead #(
    .WIDTH(32),
    .BLOCK(4)
  ) u_adder (
    .a(a),
    .b(b),
    .cin(cin),
    .sum(sum),
    .cout(cout)
  );
endmodule
