// 让 yosys/ABC 自由综合的 32 位加法器；工具可能映射出比教科书行波更快的结构。
module top (
    input  [31:0] a,
    input  [31:0] b,
    input         cin,
    output [31:0] sum,
    output        cout
);
  assign {cout, sum} = a + b + cin;
endmodule
