`timescale 1ns/1ps
module msg_slot_tb;
  reg clk;
  reg rst_n;
  reg in_valid;
  reg [7:0] in_data;
  wire in_ready;
  wire out_valid;
  reg out_ready;
  wire [7:0] out_data;
  integer received;
  integer sent;

  msg_slot #(.W(8)) dut (
    .clk(clk), .rst_n(rst_n),
    .in_valid(in_valid), .in_ready(in_ready), .in_data(in_data),
    .out_valid(out_valid), .out_ready(out_ready), .out_data(out_data)
  );

  initial begin
    clk = 1'b0;
    forever #5 clk = ~clk;
  end

  always @(posedge clk) begin
    if (!rst_n) begin
      received = 0;
      sent = 0;
    end else begin
      if (in_valid && in_ready) received = received + 1;
      if (out_valid && out_ready) sent = sent + 1;
    end
  end

  task check;
    input ok;
    input [8*96-1:0] reason;
    begin
      if (ok !== 1'b1) begin
        $display("FAIL: %0s at %0t", reason, $time);
        $finish;
      end
    end
  endtask

  initial begin
    rst_n = 1'b0;
    in_valid = 1'b0;
    in_data = 8'b0;
    out_ready = 1'b0;
    repeat (2) @(negedge clk);
    rst_n = 1'b1;
    in_valid = 1'b1;
    in_data = 8'hA5;
    @(posedge clk);
    check(in_ready, "empty slot must accept A");
    #1;
    check(out_valid && out_data == 8'hA5, "A must be stored");

    @(negedge clk);
    in_valid = 1'b0;
    in_data = 8'h3C;
    repeat (5) begin
      @(posedge clk);
      #1;
      check(out_valid && out_data == 8'hA5, "A must survive backpressure");
      check(!in_ready, "full slot must reject new input");
    end

    // 合法地提供 B，但当前满，必须等待 A 被取走后才接收。
    @(negedge clk);
    in_valid = 1'b1;
    in_data = 8'h3C;
    out_ready = 1'b1;
    @(posedge clk);
    check(out_valid && out_data == 8'hA5, "consume A once");
    check(!in_ready, "no same-edge refill in this design");
    #1;
    check(!out_valid && in_ready, "slot becomes empty after A");
    @(posedge clk);
    check(in_ready, "accept pending B on next edge");
    #1;
    check(out_valid && out_data == 8'h3C, "B must be stored");
    @(negedge clk);
    in_valid = 1'b0;
    @(posedge clk);
    check(out_valid && out_data == 8'h3C, "consume B once");
    #1;
    check(!out_valid, "B must not repeat");
    check(received == 2 && sent == 2, "two inputs and two outputs");

    // 在持有 C 时复位，复位后不得输出幽灵消息。
    @(negedge clk);
    out_ready = 1'b0;
    in_valid = 1'b1;
    in_data = 8'h55;
    @(posedge clk);
    #1;
    check(out_valid, "C is pending before reset");
    @(negedge clk);
    in_valid = 1'b0;
    rst_n = 1'b0;
    #1;
    check(!out_valid && !in_ready, "reset suppresses handshakes");
    @(negedge clk);
    rst_n = 1'b1;
    out_ready = 1'b1;
    @(posedge clk);
    #1;
    check(!out_valid, "reset discarded C");
    $display("PASS: msg_slot acceptance, stall, refill, reset");
    $finish;
  end

  initial begin
    #2000;
    $display("FAIL: timeout");
    $finish;
  end
endmodule
