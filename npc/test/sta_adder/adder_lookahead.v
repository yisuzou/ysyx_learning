// 可参数化的超前进位加法器：块内用 g/p 公式级联进位，块间行波。
module adder_lookahead #(
    parameter WIDTH = 32,
    parameter BLOCK = 4
) (
    input  [WIDTH-1:0] a,
    input  [WIDTH-1:0] b,
    input              cin,
    output [WIDTH-1:0] sum,
    output             cout
);
  localparam N = WIDTH / BLOCK;
  wire [N:0] c;
  assign c[0] = cin;

  genvar i, j;
  generate
    for (i = 0; i < N; i = i + 1) begin : blk
      wire [BLOCK-1:0] g = a[i*BLOCK +: BLOCK] & b[i*BLOCK +: BLOCK];
      wire [BLOCK-1:0] p = a[i*BLOCK +: BLOCK] ^ b[i*BLOCK +: BLOCK];
      wire [BLOCK:0]   ci;
      assign ci[0] = c[i];

      for (j = 0; j < BLOCK; j = j + 1) begin : cla
        assign ci[j+1] = g[j] | (p[j] & ci[j]);
      end

      assign c[i+1] = ci[BLOCK];
      assign sum[i*BLOCK +: BLOCK] = p ^ ci[BLOCK-1:0];
    end
  endgenerate

  assign cout = c[N];
endmodule
