//维护PC, 默认+4；
//实现正确的跳转；
module IFU (
    input clk,
    input rst_n,  //低有效复位信号
    input pc_we,  //pc写使能，沿用了logisim设计思路
    input [31:0] pc_wdata,
    //pc输出二选一，顺序自家和跳转输入；
    output [31:0] pc
);

  reg [31:0] pc;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pc <= 32'h80000000;
    end else begin
      if (pc_we) begin
        pc <= pc_wdata;
      end else begin
        pc <= pc + 32'h4;
      end
    end
  end


endmodule

