`timescale 1ns/1ps
module msg_slot #(parameter W = 64) (
    input clk,
    input rst_n,
    input in_valid,
    output in_ready,
    input [W-1:0] in_data,
    output out_valid,
    input out_ready,
    output [W-1:0] out_data
);
  reg full;
  reg [W-1:0] data_q;
  wire in_fire;
  wire out_fire;
  assign in_ready = rst_n && !full;
  assign out_valid = rst_n && full;
  assign out_data = data_q;
  assign in_fire = in_valid && in_ready;
  assign out_fire = out_valid && out_ready;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      full <= 1'b0;
      data_q <= {W{1'b0}};
    end else if (in_fire) begin
      full <= 1'b1;
      data_q <= in_data;
    end else if (out_fire) begin
      full <= 1'b0;
    end
  end
endmodule
