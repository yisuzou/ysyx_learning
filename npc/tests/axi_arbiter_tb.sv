`timescale 1ns/1ps
module axi_arbiter_tb;
  reg clk = 0, rst_n = 0;
  reg [31:0] ifu_araddr = 32'h80000000, lsu_araddr = 32'h80001000;
  reg [2:0] ifu_arprot = 5, lsu_arprot = 1;
  reg ifu_arvalid = 0, lsu_arvalid = 0, ifu_rready = 0, lsu_rready = 0;
  wire ifu_arready, lsu_arready, ifu_rvalid, lsu_rvalid;
  wire [31:0] ifu_rdata, lsu_rdata;
  wire [1:0] ifu_rresp, lsu_rresp;
  reg [31:0] lsu_awaddr = 32'h80002000, lsu_wdata = 32'hdeadbeef;
  reg [2:0] lsu_awprot = 1;
  reg [3:0] lsu_wstrb = 5;
  reg lsu_awvalid = 0, lsu_wvalid = 0, lsu_bready = 0;
  wire lsu_awready, lsu_wready, lsu_bvalid;
  wire [1:0] lsu_bresp;
  wire [31:0] araddr, awaddr, wdata;
  wire [2:0] arprot, awprot;
  wire [3:0] wstrb;
  wire arvalid, rready, awvalid, wvalid, bready;
  reg arready = 0, awready = 0, wready = 0, rvalid = 0, bvalid = 0;
  reg [31:0] rdata = 0;
  reg [1:0] rresp = 0, bresp = 0;
  integer cycles = 0, completed = 0, i, j;

  AXIArbiter dut (
      .clk(clk), .rst_n(rst_n),
      .ifu_araddr(ifu_araddr), .ifu_arprot(ifu_arprot),
      .ifu_arvalid(ifu_arvalid), .ifu_arready(ifu_arready),
      .ifu_rdata(ifu_rdata), .ifu_rresp(ifu_rresp),
      .ifu_rvalid(ifu_rvalid), .ifu_rready(ifu_rready),
      .lsu_araddr(lsu_araddr), .lsu_arprot(lsu_arprot),
      .lsu_arvalid(lsu_arvalid), .lsu_arready(lsu_arready),
      .lsu_rdata(lsu_rdata), .lsu_rresp(lsu_rresp),
      .lsu_rvalid(lsu_rvalid), .lsu_rready(lsu_rready),
      .lsu_awaddr(lsu_awaddr), .lsu_awprot(lsu_awprot),
      .lsu_awvalid(lsu_awvalid), .lsu_awready(lsu_awready),
      .lsu_wdata(lsu_wdata), .lsu_wstrb(lsu_wstrb),
      .lsu_wvalid(lsu_wvalid), .lsu_wready(lsu_wready),
      .lsu_bresp(lsu_bresp), .lsu_bvalid(lsu_bvalid), .lsu_bready(lsu_bready),
      .m_axi_araddr(araddr), .m_axi_arprot(arprot),
      .m_axi_arvalid(arvalid), .m_axi_arready(arready),
      .m_axi_rdata(rdata), .m_axi_rresp(rresp),
      .m_axi_rvalid(rvalid), .m_axi_rready(rready),
      .m_axi_awaddr(awaddr), .m_axi_awprot(awprot),
      .m_axi_awvalid(awvalid), .m_axi_awready(awready),
      .m_axi_wdata(wdata), .m_axi_wstrb(wstrb),
      .m_axi_wvalid(wvalid), .m_axi_wready(wready),
      .m_axi_bresp(bresp), .m_axi_bvalid(bvalid), .m_axi_bready(bready)
  );
  task tick;
    begin
      #4 clk = 1;
      #4 clk = 0;
      #2;
      cycles = cycles + 1;
    end
  endtask
  task reset;
    begin
      rst_n = 0;
      ifu_arvalid = 0; lsu_arvalid = 0;
      ifu_rready = 0; lsu_rready = 0;
      lsu_awvalid = 0; lsu_wvalid = 0; lsu_bready = 0;
      arready = 0; rvalid = 0; bvalid = 0; awready = 0; wready = 0;
      tick;
      if (arvalid || rready || ifu_arready || lsu_arready || ifu_rvalid || lsu_rvalid ||
          awvalid || wvalid || bready || lsu_awready || lsu_wready || lsu_bvalid)
        $fatal(1, "reset must clear all handshake routes");
      rst_n = 1;
      #1;
    end
  endtask
  task wait_address(input bit owner_lsu);
    integer n;
    reg [31:0] expected_addr;
    reg [2:0] expected_prot;
    begin
      expected_addr = owner_lsu ? lsu_araddr : ifu_araddr;
      expected_prot = owner_lsu ? lsu_arprot : ifu_arprot;
      for (n = 0; !arvalid && n < 30; n = n + 1) tick;
      if (!arvalid || araddr !== expected_addr || arprot !== expected_prot)
        $fatal(1, "wrong selected master/round-robin priority");
      for (n = 0; n < 5; n = n + 1) begin
        tick;
        if (!arvalid || araddr !== expected_addr || arprot !== expected_prot ||
            ifu_arready || lsu_arready)
          $fatal(1, "AR owner/payload changed while downstream stalled");
      end
      arready = 1;
      #1;
      if (ifu_arready !== !owner_lsu || lsu_arready !== owner_lsu)
        $fatal(1, "ARREADY must only reach the selected master");
      tick;
      arready = 0;
      // Selected master may now issue its next address; the other is pending.
      if (owner_lsu) lsu_araddr = lsu_araddr + 4;
      else ifu_araddr = ifu_araddr + 4;
      if (arvalid || ifu_arready || lsu_arready)
        $fatal(1, "new AR cannot pass before the previous R completes");
    end
  endtask
  task hold_response(input bit owner_lsu);
    integer n;
    begin
      rvalid = 1;
      rdata = 32'h12340000 + completed;
      rresp = completed % 4;
      ifu_rready = owner_lsu;
      lsu_rready = !owner_lsu;
      #1;
      for (n = 0; n < 6; n = n + 1) begin
        if (ifu_rvalid !== !owner_lsu || lsu_rvalid !== owner_lsu || rready || arvalid)
          $fatal(1, "response ownership changed or wrong READY was used");
        if (owner_lsu) begin
          if (lsu_rdata !== rdata || lsu_rresp !== rresp) $fatal(1, "LSU response corrupted");
        end else begin
          if (ifu_rdata !== rdata || ifu_rresp !== rresp) $fatal(1, "IFU response corrupted");
        end
        tick;
      end
    end
  endtask
  task finish_response(input bit owner_lsu);
    begin
      if (owner_lsu) lsu_rready = 1;
      else ifu_rready = 1;
      #1;
      if (!rready) $fatal(1, "selected response READY did not reach the slave");
      tick;
      rvalid = 0;
      ifu_rready = 0; lsu_rready = 0;
      completed = completed + 1;
      if (ifu_rvalid || lsu_rvalid || rready)
        $fatal(1, "response route remained active after handshake");
    end
  endtask
  task write_while_read_stalled;
    integer n;
    begin
      lsu_awvalid = 1; lsu_wvalid = 1;
      wready = 1; awready = 0;
      #1;
      if (!awvalid || !wvalid || lsu_awready || !lsu_wready ||
          awaddr !== lsu_awaddr || awprot !== lsu_awprot ||
          wdata !== lsu_wdata || wstrb !== lsu_wstrb)
        $fatal(1, "write channels must remain independent of read arbitration");
      tick;
      lsu_wvalid = 0; wready = 0; awready = 1;
      #1;
      if (!awvalid || !lsu_awready || wvalid) $fatal(1, "AW must proceed after W independently");
      tick;
      lsu_awvalid = 0; awready = 0;
      bvalid = 1; bresp = 2;
      #1;
      for (n = 0; n < 4; n = n + 1) begin
        if (!lsu_bvalid || lsu_bresp !== 2 || bready || rready)
          $fatal(1, "B backpressure must be independent of held R");
        tick;
      end
      lsu_bready = 1;
      #1;
      if (!bready) $fatal(1, "LSU BREADY must reach the slave");
      tick;
      bvalid = 0; lsu_bready = 0;
    end
  endtask
  initial begin
    reset;
    // A ready slave must accept the first offered AR without a grant bubble.
    arready = 1;
    ifu_arvalid = 1;
    #1;
    if (!arvalid || !ifu_arready || lsu_arready || araddr !== ifu_araddr)
      $fatal(1, "idle arbiter added an AR grant cycle");
    tick;
    arready = 0;
    ifu_arvalid = 0;
    hold_response(0);
    finish_response(0);

    reset;
    // IFU has priority, but arrives after LSU's AR was already offered.
    // A stateless mux based on live VALIDs would illegally replace LSU.
    lsu_arvalid = 1;
    #1;
    if (!arvalid || araddr !== lsu_araddr)
      $fatal(1, "idle LSU request was not forwarded immediately");
    tick;
    ifu_arvalid = 1;
    wait_address(1);
    hold_response(1);
    finish_response(1);

    reset;
    // Grant IFU alone; a later LSU request cannot steal a stalled address.
    ifu_arvalid = 1;
    tick;
    lsu_arvalid = 1;
    wait_address(0);
    hold_response(0);
    write_while_read_stalled;
    finish_response(0);
    // Both masters continuously request; ownership must alternate without starvation.
    for (i = 0; i < 32; i = i + 1) begin
      wait_address((i % 2) == 0);
      hold_response((i % 2) == 0);
      finish_response((i % 2) == 0);
    end
    // Reset during AR backpressure, then during an outstanding read response.
    tick;
    reset;
    lsu_arvalid = 1;
    wait_address(1);
    hold_response(1);
    reset;
    ifu_arvalid = 1;
    wait_address(0);
    hold_response(0);
    finish_response(0);
    if (completed != 36) $fatal(1, "missing/duplicate read completion");
    $display("PASS: AXIArbiter (%0d completed reads, %0d cycles)", completed, cycles);
    $finish;
  end
  initial begin
    #50000;
    $fatal(1, "arbiter watchdog timeout");
  end
endmodule
