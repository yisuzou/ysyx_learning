// 可参数化的进位选择加法器：块内并行计算 cin=0/1 两种结果，块间用 MUX 选进位。
module adder_select #(
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

  genvar i;
  generate
    for (i = 0; i < N; i = i + 1) begin : blk
      wire [BLOCK-1:0] s0, s1;
      wire             c0, c1;

      // cin = 0 的块内行波加法
      assign {c0, s0} = a[i*BLOCK +: BLOCK] + b[i*BLOCK +: BLOCK] + 1'b0;
      // cin = 1 的块内行波加法
      assign {c1, s1} = a[i*BLOCK +: BLOCK] + b[i*BLOCK +: BLOCK] + 1'b1;

      assign c[i+1] = c[i] ? c1 : c0;
      assign sum[i*BLOCK +: BLOCK] = c[i] ? s1 : s0;
    end
  endgenerate

  assign cout = c[N];
endmodule
