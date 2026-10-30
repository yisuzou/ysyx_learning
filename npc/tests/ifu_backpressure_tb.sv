`timescale 1ns/1ps

// Stand-alone IFU testbench for the current decoupled interface.
// Checks:
//   1) AR backpressure: ARVALID/ARADDR stay stable while ARREADY is low.
//   2) After a successful response, out_valid/out_inst/out_pc stay stable
//      while out_ready is low, and no new AR is issued.
//   3) After the result is consumed, no new AR appears until pc_valid/pc_data
//      is presented, and only one AR is issued for that new PC.
//   4) R-channel delay and non-OKAY RRESP are handled correctly.
module ifu_backpressure_tb;
  localparam CLK_PERIOD = 10;

  reg clk = 1'b0;
  reg rst_n;

  reg pc_valid;
  wire pc_ready;
  reg [31:0] pc_data;

  reg out_ready;
  wire out_valid;
  wire [31:0] out_inst;
  wire [31:0] out_pc;

  wire ifu_error;
  wire [1:0] ifu_error_resp;
  wire [31:0] ifu_error_addr;

  wire [31:0] m_axi_araddr;
  wire m_axi_arvalid;
  reg m_axi_arready;

  reg [31:0] m_axi_rdata;
  reg [1:0] m_axi_rresp;
  reg m_axi_rvalid;
  wire m_axi_rready;

  IFU dut (
      .clk(clk),
      .rst_n(rst_n),
      .pc_valid(pc_valid),
      .pc_ready(pc_ready),
      .pc_data(pc_data),
      .out_valid(out_valid),
      .out_ready(out_ready),
      .out_inst(out_inst),
      .out_pc(out_pc),
      .ifu_error(ifu_error),
      .ifu_error_resp(ifu_error_resp),
      .ifu_error_addr(ifu_error_addr),
      .m_axi_araddr(m_axi_araddr),
      .m_axi_arprot(),
      .m_axi_arvalid(m_axi_arvalid),
      .m_axi_arready(m_axi_arready),
      .m_axi_rdata(m_axi_rdata),
      .m_axi_rresp(m_axi_rresp),
      .m_axi_rvalid(m_axi_rvalid),
      .m_axi_rready(m_axi_rready),
      .m_axi_awaddr(),
      .m_axi_awprot(),
      .m_axi_awvalid(),
      .m_axi_awready(1'b0),
      .m_axi_wdata(),
      .m_axi_wstrb(),
      .m_axi_wvalid(),
      .m_axi_wready(1'b0),
      .m_axi_bresp(2'b00),
      .m_axi_bvalid(1'b0),
      .m_axi_bready()
  );

  always #(CLK_PERIOD / 2) clk = ~clk;

  task check(input condition, input string msg);
    if (!condition) begin
      $display("FAIL at %0t: %s", $time, msg);
      $error("IFU backpressure test failed");
      $finish;
    end
  endtask

  task step();
    begin
      @(posedge clk);
      #1;
    end
  endtask

  task run_ar_backpressure_test();
    begin
      $display("[TEST] AR backpressure and out_ready hold");

      // After reset the IFU immediately fetches the reset PC.
      check(m_axi_arvalid && m_axi_araddr == 32'h80000000,
            "reset should start AR for 0x80000000");

      // Hold ARREADY low for several cycles and check stability.
      m_axi_arready = 1'b0;
      repeat (5) step();
      check(m_axi_arvalid && m_axi_araddr == 32'h80000000,
            "ARVALID/ARADDR must stay stable under AR backpressure");

      // Accept AR, then move to WAIT_R.
      m_axi_arready = 1'b1;
      step();
      m_axi_arready = 1'b0;
      check(!m_axi_arvalid && m_axi_rready,
            "after AR fire IFU must enter WAIT_R with no new AR");

      // Return a successful read response.
      m_axi_rvalid = 1'b1;
      m_axi_rresp  = 2'b00;
      m_axi_rdata  = 32'hdeadbeef;
      step();
      m_axi_rvalid = 1'b0;
      check(out_valid && out_inst == 32'hdeadbeef && out_pc == 32'h80000000 && !ifu_error,
            "successful response must present instruction and PC");

      // Keep out_ready low for 20 cycles: outputs must remain stable and
      // no new AR/R activity may start.
      out_ready = 1'b0;
      repeat (20) begin
        step();
        check(out_valid && out_inst == 32'hdeadbeef && out_pc == 32'h80000000,
              "out_valid/out_inst/out_pc must be stable while out_ready=0");
        check(!m_axi_arvalid,
              "no new AR must be issued while the current result is held");
      end

      // Accept the result. IFU returns to WAIT_PC and must stay quiet.
      out_ready = 1'b1;
      step();
      out_ready = 1'b0;
      check(!out_valid && pc_ready,
            "after out_fire IFU must be in WAIT_PC");

      repeat (20) begin
        step();
        check(!m_axi_arvalid,
              "no AR must be issued while waiting for next pc_valid");
      end

      // Provide the next PC. Exactly one new AR must be launched.
      pc_valid = 1'b1;
      pc_data  = 32'h80000004;
      step();
      pc_valid = 1'b0;
      check(m_axi_arvalid && m_axi_araddr == 32'h80000004,
            "a single new AR must be issued for the supplied PC");

      // With ARREADY high the AR is consumed immediately; only one AR cycle.
      m_axi_arready = 1'b1;
      step();
      m_axi_arready = 1'b0;
      check(!m_axi_arvalid && m_axi_rready,
            "only one AR must have been issued for the new PC");

      // Clean up with a good response so later tests start from WAIT_PC.
      m_axi_rvalid = 1'b1;
      m_axi_rdata  = 32'h11223344;
      m_axi_rresp  = 2'b00;
      step();
      m_axi_rvalid = 1'b0;
      check(out_valid && out_inst == 32'h11223344 && out_pc == 32'h80000004,
            "second fetch must return the expected instruction");
      out_ready = 1'b1;
      step();
      out_ready = 1'b0;
      check(!out_valid && pc_ready,
            "IFU must return to WAIT_PC after consuming second result");
    end
  endtask

  task run_r_delay_test();
    begin
      $display("[TEST] R-channel delay");

      pc_valid = 1'b1;
      pc_data  = 32'h80000008;
      step();
      pc_valid = 1'b0;
      check(m_axi_arvalid && m_axi_araddr == 32'h80000008,
            "AR must be issued for delayed-R PC");

      m_axi_arready = 1'b1;
      step();
      m_axi_arready = 1'b0;
      check(!out_valid && m_axi_rready && !m_axi_arvalid,
            "IFU must wait in WAIT_R before delayed R");

      // Delay the R response.
      m_axi_rvalid = 1'b0;
      repeat (10) begin
        step();
        check(!out_valid && m_axi_rready && !m_axi_arvalid,
              "IFU must keep RREADY asserted and not start a new AR during R delay");
      end

      m_axi_rvalid = 1'b1;
      m_axi_rdata  = 32'h55667788;
      m_axi_rresp  = 2'b00;
      step();
      m_axi_rvalid = 1'b0;
      check(out_valid && out_inst == 32'h55667788 && out_pc == 32'h80000008,
            "delayed OK response must produce the correct instruction");

      out_ready = 1'b1;
      step();
      out_ready = 1'b0;
      check(!out_valid && pc_ready,
            "IFU must return to WAIT_PC after delayed R is consumed");
    end
  endtask

  task run_rresp_error_test();
    begin
      $display("[TEST] RRESP error");

      pc_valid = 1'b1;
      pc_data  = 32'h8000000c;
      step();
      pc_valid = 1'b0;
      check(m_axi_arvalid && m_axi_araddr == 32'h8000000c,
            "AR must be issued for error-case PC");

      m_axi_arready = 1'b1;
      step();
      m_axi_arready = 1'b0;
      check(m_axi_rready && !m_axi_arvalid,
            "IFU must reach WAIT_R for error case");

      m_axi_rvalid = 1'b1;
      m_axi_rresp  = 2'b10;  // DECERR / non-OKAY
      m_axi_rdata  = 32'haabbccdd;
      step();
      m_axi_rvalid = 1'b0;
      check(ifu_error && ifu_error_resp == 2'b10 && ifu_error_addr == 32'h8000000c,
            "non-OKAY RRESP must latch sticky fault with address");
      check(!out_valid && !pc_ready && !m_axi_arvalid && !m_axi_rready,
            "FAULT state must not drive out_valid/pc_ready or AXI traffic");

      repeat (10) begin
        step();
        check(ifu_error && !m_axi_arvalid && !m_axi_rready && !out_valid && !pc_ready,
              "FAULT state must remain sticky with no traffic");
      end
    end
  endtask

  initial begin
    rst_n = 1'b0;
    pc_valid = 1'b0;
    pc_data  = 32'b0;
    out_ready = 1'b0;
    m_axi_arready = 1'b0;
    m_axi_rvalid  = 1'b0;
    m_axi_rresp   = 2'b00;
    m_axi_rdata   = 32'b0;

    repeat (3) step();
    rst_n = 1'b1;
    step();

    run_ar_backpressure_test();
    run_r_delay_test();
    run_rresp_error_test();

    $display("PASS: IFU backpressure, R delay, and RRESP error tests");
    $finish;
  end
endmodule
