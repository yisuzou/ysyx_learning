`timescale 1ns/1ps
// UART unit test: response rules, exactly-once transmit under AW/W ordering
// and B backpressure, read SLVERR, reset.
module axi_uart_tb;
  reg clk = 0, rst_n = 0;
  reg [31:0] araddr = 0, awaddr = 0, wdata = 0;
  reg [3:0] wstrb = 0;
  reg arvalid = 0, rready = 0, awvalid = 0, wvalid = 0, bready = 0;
  wire arready, rvalid, awready, wready, bvalid, tx_valid;
  wire [31:0] rdata;
  wire [1:0] rresp, bresp;
  wire [7:0] tx_data;

  UART dut (
      .clk(clk), .rst_n(rst_n),
      .s_axi_araddr(araddr), .s_axi_arprot(3'b001), .s_axi_arvalid(arvalid),
      .s_axi_arready(arready), .s_axi_rdata(rdata), .s_axi_rresp(rresp),
      .s_axi_rvalid(rvalid), .s_axi_rready(rready),
      .s_axi_awaddr(awaddr), .s_axi_awprot(3'b001), .s_axi_awvalid(awvalid),
      .s_axi_awready(awready), .s_axi_wdata(wdata), .s_axi_wstrb(wstrb),
      .s_axi_wvalid(wvalid), .s_axi_wready(wready),
      .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
      .tx_valid(tx_valid), .tx_data(tx_data)
  );
  always #5 clk = ~clk;

  integer tx_count = 0, writes = 0, reads = 0;
  reg [7:0] tx_last;
  always @(posedge clk) if (rst_n && tx_valid) begin
    tx_count = tx_count + 1;
    tx_last = tx_data;
  end

  task automatic do_write(input [31:0] a, input [31:0] d, input [3:0] s,
                          input integer order, input [1:0] exp_resp,
                          input bit exp_tx);
    integer n, lag, aw_start, w_start, tx0;
    bit aw_ok, w_ok;
    begin
      tx0 = tx_count;
      lag = $urandom_range(1, 4);
      aw_start = (order == 1) ? lag : 0;
      w_start  = (order == 0) ? lag : 0;
      aw_ok = 0; w_ok = 0;
      @(posedge clk);
      for (n = 0; !(aw_ok && w_ok); n++) begin
        if (n > 50) $fatal(1, "AW/W timeout");
        #1;
        awvalid = !aw_ok && (n >= aw_start); awaddr = a;
        wvalid  = !w_ok && (n >= w_start);   wdata = d; wstrb = s;
        @(posedge clk);
        if (awvalid && awready) aw_ok = 1;
        if (wvalid && wready) w_ok = 1;
      end
      #1 awvalid = 0; wvalid = 0;
      repeat ($urandom_range(0, 6)) @(posedge clk);  // B backpressure
      #1 bready = 1;
      n = 0;
      do begin
        @(posedge clk);
        n = n + 1;
        if (n > 50) $fatal(1, "B timeout");
      end while (!bvalid);
      if (bresp !== exp_resp)
        $fatal(1, "write %h strb %b: bresp %b, want %b", a, s, bresp, exp_resp);
      #1 bready = 0;
      repeat (2) @(posedge clk);
      if (tx_count != tx0 + (exp_tx ? 1 : 0))
        $fatal(1, "write %h strb %b: %0d bytes sent", a, s, tx_count - tx0);
      if (exp_tx && tx_last !== d[7:0]) $fatal(1, "tx byte %h want %h", tx_last, d[7:0]);
      writes++;
    end
  endtask

  task automatic do_read(input [31:0] a);
    integer n;
    begin
      @(posedge clk); #1 araddr = a; arvalid = 1;
      n = 0;
      do begin @(posedge clk); n = n + 1; if (n > 50) $fatal(1, "AR timeout"); end
      while (!arready);
      #1 arvalid = 0;
      repeat ($urandom_range(0, 3)) @(posedge clk);
      #1 rready = 1;
      n = 0;
      do begin @(posedge clk); n = n + 1; if (n > 50) $fatal(1, "R timeout"); end
      while (!rvalid);
      if (rresp !== 2'b10 || rdata !== 0) $fatal(1, "read %h: want SLVERR", a);
      #1 rready = 0;
      reads++;
    end
  endtask

  integer i, ord;
  reg [3:0] s;
  reg [31:0] a;
  initial begin
    repeat (2) @(posedge clk);
    #1;
    if (arready || awready || wready || rvalid || bvalid || tx_valid)
      $fatal(1, "reset must clear handshakes");
    rst_n = 1;

    do_write(32'h10000000, 32'h41, 4'b0001, 0, 2'b00, 1);
    do_write(32'h10000000, 32'h42, 4'b0001, 1, 2'b00, 1);
    do_write(32'h10000000, 32'h43, 4'b0001, 2, 2'b00, 1);
    do_write(32'h10000000, 32'h44, 4'b0000, 2, 2'b00, 0);  // zero strobe
    do_write(32'h10000000, 32'h4500, 4'b0010, 0, 2'b10, 0); // lane 1
    do_write(32'h10000000, 32'h46, 4'b0011, 1, 2'b10, 0);   // halfword
    do_write(32'h10000000, 32'h47, 4'b1111, 2, 2'b10, 0);   // word
    do_write(32'h10000004, 32'h48, 4'b0001, 0, 2'b10, 0);   // reserved word
    do_read(32'h10000000);
    do_read(32'h10000004);

    // Random mix, reads concurrent with writes.
    fork
      for (int k = 0; k < 200; k++) do_read(32'h10000000 + {$urandom_range(0, 1), 2'b00});
      for (i = 0; i < 300; i++) begin
        a = 32'h10000000 + {$urandom_range(0, 1), 2'b00};
        s = ($urandom_range(0, 1)) ? 4'b0001 : $urandom;
        ord = $urandom_range(0, 2);
        do_write(a, $urandom_range(32, 126), s, ord,
                 (s == 0 || (a[2] == 0 && s == 4'b0001)) ? 2'b00 : 2'b10,
                 a[2] == 0 && s == 4'b0001);
      end
    join

    $display("PASS: UART (%0d writes, %0d reads, %0d bytes transmitted)",
             writes, reads, tx_count);
    $finish;
  end
endmodule
