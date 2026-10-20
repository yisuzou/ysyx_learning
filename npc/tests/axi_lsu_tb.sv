`timescale 1ns/1ps
module axi_lsu_tb #(parameter RANDOM_DELAY = 1);
  localparam [31:0] BASE = 32'h80000000;
  reg clk = 0, rst_n = 0;
  reg [1:0] mem_rbhw = 0, mem_wbhw = 0;
  reg [31:0] mem_addr = BASE, mem_wdata_raw = 0;
  reg mem_valid = 0, wen = 0, isign = 0, lsu_finish = 0;
  wire [31:0] mem_rdata_r, lsu_error_addr;
  wire lsu_done, lsu_error, lsu_error_write;
  wire [1:0] lsu_error_resp;
  wire [31:0] araddr, awaddr, wdata;
  wire [2:0] arprot, awprot;
  wire [3:0] wstrb;
  wire arvalid, arready, rready, awvalid, awready, wvalid, wready, bready;
  reg [31:0] rdata = 0;
  reg [1:0] rresp = 0, bresp = 0;
  reg rvalid = 0, bvalid = 0;
  reg [7:0] ram [0:1023];
  reg rd_pending = 0, aw_have = 0, w_have = 0, b_pending = 0;
  reg [31:0] saved_awaddr, saved_wdata;
  reg [3:0] saved_wstrb;
  reg [31:0] pending_rdata;
  reg [1:0] pending_rresp;
  integer rd_timer, b_timer, cycle = 0, cases = 0;
  integer ar_count = 0, aw_count = 0, w_count = 0, write_count = 0;
  integer write_order = 0;
  reg allow_w = 1, allow_r_response = 1;
  reg [31:0] error_addr = 32'hffffffff;
  reg [1:0] read_error_resp = 0, write_error_resp = 0;
  reg ar_stalled = 0, aw_stalled = 0, w_stalled = 0;
  reg [31:0] held_araddr, held_awaddr, held_wdata;
  reg [3:0] held_wstrb;
  integer lane, index;

  LSU #(.RANDOM_DELAY(RANDOM_DELAY), .PMEM_BASE(BASE), .PMEM_SIZE(32'd1024)) dut (
      .clk(clk), .rst_n(rst_n), .mem_rbhw(mem_rbhw), .mem_addr(mem_addr),
      .mem_valid(mem_valid), .wen(wen), .mem_wbhw(mem_wbhw),
      .mem_wdata_raw(mem_wdata_raw), .isign(isign), .lsu_finish(lsu_finish),
      .mem_rdata_r(mem_rdata_r), .lsu_done(lsu_done), .lsu_error(lsu_error),
      .lsu_error_resp(lsu_error_resp), .lsu_error_addr(lsu_error_addr),
      .lsu_error_write(lsu_error_write),
      .m_axi_araddr(araddr), .m_axi_arprot(arprot), .m_axi_arvalid(arvalid),
      .m_axi_arready(arready), .m_axi_rdata(rdata), .m_axi_rresp(rresp),
      .m_axi_rvalid(rvalid), .m_axi_rready(rready),
      .m_axi_awaddr(awaddr), .m_axi_awprot(awprot), .m_axi_awvalid(awvalid),
      .m_axi_awready(awready), .m_axi_wdata(wdata), .m_axi_wstrb(wstrb),
      .m_axi_wvalid(wvalid), .m_axi_wready(wready), .m_axi_bresp(bresp),
      .m_axi_bvalid(bvalid), .m_axi_bready(bready)
  );

  // Adversarial slave: stagger AW/W in either direction; delay AR/R/B.
  assign arready = rst_n && !rd_pending && !rvalid && (cycle % 4 == 1);
  assign awready = rst_n && !aw_have && !b_pending && !bvalid &&
                   (write_order != 1 || w_have) && (cycle % 4 == 1);
  assign wready = rst_n && allow_w && !w_have && !b_pending && !bvalid &&
                  (write_order != 0 || aw_have) && (cycle % 4 == 1);
  function [31:0] read_word;
    input [31:0] addr;
    begin
      if (addr >= BASE && addr - BASE <= 1020)
        read_word = {ram[addr-BASE+3], ram[addr-BASE+2],
                     ram[addr-BASE+1], ram[addr-BASE]};
      else read_word = 0;
    end
  endfunction

  always @(posedge clk) begin
    if (!rst_n) begin
      rd_pending <= 0;
      rvalid <= 0;
      aw_have <= 0;
      w_have <= 0;
      b_pending <= 0;
      bvalid <= 0;
      ar_stalled <= 0;
      aw_stalled <= 0;
      w_stalled <= 0;
    end else begin
      if (ar_stalled && (!arvalid || araddr !== held_araddr || arprot !== 3'b001))
        $fatal(1, "AR payload/VALID changed during backpressure");
      if (aw_stalled && (!awvalid || awaddr !== held_awaddr || awprot !== 3'b001))
        $fatal(1, "AW payload/VALID changed during backpressure");
      if (w_stalled && (!wvalid || wdata !== held_wdata || wstrb !== held_wstrb))
        $fatal(1, "W payload/VALID changed during backpressure");
      ar_stalled <= arvalid && !arready;
      aw_stalled <= awvalid && !awready;
      w_stalled <= wvalid && !wready;
      held_araddr <= araddr;
      held_awaddr <= awaddr;
      held_wdata <= wdata;
      held_wstrb <= wstrb;
      if (arvalid && arready) begin
        ar_count <= ar_count + 1;
        rd_pending <= 1;
        rd_timer <= 3;
        pending_rdata <= read_word(araddr);
        pending_rresp <= araddr == error_addr ? read_error_resp : 0;
      end
      if (rd_pending && allow_r_response) begin
        if (rd_timer == 0) begin
          rdata <= pending_rdata;
          rresp <= pending_rresp;
          rvalid <= 1;
          rd_pending <= 0;
        end else rd_timer <= rd_timer - 1;
      end
      if (rvalid && rready) rvalid <= 0;
      if (awvalid && awready) begin
        aw_count <= aw_count + 1;
        aw_have <= 1;
        saved_awaddr <= awaddr;
      end
      if (wvalid && wready) begin
        w_count <= w_count + 1;
        w_have <= 1;
        saved_wdata <= wdata;
        saved_wstrb <= wstrb;
      end
      if (aw_have && w_have && !b_pending && !bvalid) begin
        write_count <= write_count + 1;
        bresp <= saved_awaddr == error_addr ? write_error_resp : 0;
        if (saved_awaddr != error_addr || write_error_resp == 0) begin
          for (lane = 0; lane < 4; lane = lane + 1) begin
            if (saved_wstrb[lane]) begin
              if (saved_awaddr < BASE || saved_awaddr-BASE+lane >= 1024)
                $fatal(1, "unexpected write outside RAM model");
              ram[saved_awaddr-BASE+lane] <= saved_wdata[lane*8 +: 8];
            end
          end
        end
        aw_have <= 0;
        w_have <= 0;
        b_pending <= 1;
        b_timer <= 4;
      end
      if (b_pending) begin
        if (b_timer == 0) begin
          b_pending <= 0;
          bvalid <= 1;
        end else b_timer <= b_timer - 1;
      end
      if (bvalid && bready) bvalid <= 0;
    end
  end

  task tick;
    begin
      #4 clk = 1;
      #4 clk = 0;
      cycle = cycle + 1;
      #2;
    end
  endtask
  task reset;
    begin
      rst_n = 0;
      mem_valid = 0;
      lsu_finish = 0;
      allow_w = 1;
      allow_r_response = 1;
      error_addr = 32'hffffffff;
      read_error_resp = 0;
      write_error_resp = 0;
      tick;
      if (arvalid || awvalid || wvalid || rready || bready || lsu_done || lsu_error)
        $fatal(1, "reset did not clear active transaction/fault");
      rst_n = 1;
      #1;
    end
  endtask
  task launch(input bit write_access, input [31:0] addr, input [1:0] size,
              input [31:0] data, input bit signed_access);
    begin
      mem_valid = 1;
      mem_addr = addr;
      mem_rbhw = size;
      mem_wbhw = size;
      mem_wdata_raw = data;
      wen = write_access;
      isign = signed_access;
      tick;
      // Changing live CPU inputs after acceptance must not alter the request.
      mem_addr = 32'hdeadbeef;
      mem_rbhw = 0;
      mem_wbhw = 0;
      mem_wdata_raw = ~data;
      wen = !write_access;
      isign = !signed_access;
    end
  endtask
  task wait_result;
    integer n;
    begin
      for (n = 0; !lsu_done && !lsu_error && n < 300; n = n + 1) tick;
      if (!lsu_done && !lsu_error) $fatal(1, "LSU transaction timeout");
      cases = cases + 1;
    end
  endtask
  task complete(input [31:0] expected);
    integer n, old_ar, old_aw, old_w, old_write;
    begin
      if (!lsu_done || lsu_error || mem_rdata_r !== expected)
        $fatal(1, "wrong result: got %h expected %h", mem_rdata_r, expected);
      old_ar = ar_count;
      old_aw = aw_count;
      old_w = w_count;
      old_write = write_count;
      for (n = 0; n < 8; n = n + 1) begin
        tick;
        if (!lsu_done || mem_rdata_r !== expected || arvalid || awvalid || wvalid)
          $fatal(1, "DONE must hold result without issuing duplicate requests");
      end
      if (ar_count != old_ar || aw_count != old_aw || w_count != old_w || write_count != old_write)
        $fatal(1, "completed request repeated a transfer");
      mem_valid = 0;
      lsu_finish = 1;
      tick;
      lsu_finish = 0;
      if (lsu_done) $fatal(1, "completion acknowledgement did not release DONE");
    end
  endtask
  task check_fault(input [31:0] addr, input [1:0] resp, input bit is_write);
    integer n;
    begin
      if (lsu_done || !lsu_error || lsu_error_addr !== addr ||
          lsu_error_resp !== resp || lsu_error_write !== is_write)
        $fatal(1, "wrong fault metadata");
      lsu_finish = 1;
      for (n = 0; n < 10; n = n + 1) begin
        tick;
        if (!lsu_error || lsu_done || arvalid || awvalid || wvalid || rready || bready)
          $fatal(1, "fault must stop traffic and remain sticky until reset");
      end
    end
  endtask

  integer size, offset, order, sign_mode, nbytes, k, beats, old_ar, old_aw, old_w, old_write;
  reg [31:0] expected, test_data = 32'ha1b2c3d4;
  initial begin
    reset;
    for (size = 1; size <= 3; size = size + 1) begin
      nbytes = size == 1 ? 1 : (size == 2 ? 2 : 4);
      for (offset = 0; offset < 4; offset = offset + 1) begin
        beats = offset + nbytes > 4 ? 2 : 1;
        for (order = 0; order < 3; order = order + 1) begin
          write_order = order;
          for (k = 0; k < 1024; k = k + 1) ram[k] = (k ^ 8'h55) & 8'hff;
          old_aw = aw_count; old_w = w_count; old_write = write_count;
          launch(1, BASE+32+offset, size[1:0], test_data, 0);
          wait_result;
          complete(0);
          if (aw_count-old_aw != beats || w_count-old_w != beats || write_count-old_write != beats)
            $fatal(1, "wrong number of AW/W/write operations for split store");
          for (k = 0; k < 1024; k = k + 1) begin
            if (k >= 32+offset && k < 32+offset+nbytes) begin
              if (ram[k] !== ((test_data >> (8*(k-32-offset))) & 8'hff))
                $fatal(1, "wrong stored byte");
            end else if (ram[k] !== ((k ^ 8'h55) & 8'hff))
              $fatal(1, "store modified an unselected byte");
          end
          for (sign_mode = 0; sign_mode < 2; sign_mode = sign_mode + 1) begin
            expected = 0;
            for (k = 0; k < nbytes; k = k + 1)
              expected = expected | (32'(ram[32+offset+k]) << (8*k));
            if (sign_mode && nbytes < 4 && (expected & (32'h1 << (8*nbytes-1))))
              expected = expected | (32'hffffffff << (8*nbytes));
            old_ar = ar_count;
            launch(0, BASE+32+offset, size[1:0], 0, sign_mode != 0);
            wait_result;
            complete(expected);
            if (ar_count-old_ar != beats) $fatal(1, "wrong AR count for split load");
          end
        end
      end
    end

    old_ar = ar_count; old_aw = aw_count; old_w = w_count;
    launch(1, 32'h10000003, 3, test_data, 0);
    wait_result;
    check_fault(32'h10000003, 2, 1);
    if (ar_count != old_ar || aw_count != old_aw || w_count != old_w)
      $fatal(1, "cross-word MMIO must be rejected before any transaction");
    reset;
    launch(1, BASE+1023, 3, test_data, 0);
    wait_result;
    check_fault(BASE+1023, 3, 1);
    if (ar_count != old_ar || aw_count != old_aw || w_count != old_w)
      $fatal(1, "out-of-bounds split store must have no side effects");
    reset;
    launch(0, BASE, 0, 0, 0);
    wait_result;
    check_fault(BASE, 2, 0);
    reset;
    error_addr = BASE+64; read_error_resp = 3;
    launch(0, BASE+64, 3, 0, 0);
    wait_result;
    check_fault(BASE+64, 3, 0);
    reset;
    error_addr = BASE+68; read_error_resp = 2;
    launch(0, BASE+67, 3, 0, 0);
    wait_result;
    check_fault(BASE+68, 2, 0);
    if (mem_rdata_r !== 0) $fatal(1, "partial split load must not publish a result");
    reset;
    ram[512+3] = 8'h55; ram[512+4] = 8'h66; ram[512+5] = 8'h77; ram[512+6] = 8'h88;
    error_addr = BASE+516; write_error_resp = 2;
    launch(1, BASE+515, 3, test_data, 0);
    wait_result;
    check_fault(BASE+516, 2, 1);
    if (ram[515] !== 8'hd4 || ram[516] !== 8'h66 || ram[517] !== 8'h77 || ram[518] !== 8'h88)
      $fatal(1, "second-beat failure must preserve first committed beat only");

    reset;
    allow_w = 0;
    launch(1, BASE+896, 3, test_data, 0);
    while (!aw_have) tick;
    old_write = write_count;
    reset;
    launch(1, BASE+900, 3, test_data, 0);
    wait_result;
    complete(0);
    if (write_count != old_write+1) $fatal(1, "reset left an orphan AW request");
    allow_r_response = 0;
    launch(0, BASE+900, 3, 0, 0);
    while (!rd_pending) tick;
    reset;
    launch(0, BASE+900, 3, 0, 0);
    wait_result;
    complete(test_data);
    $display("PASS: LSU RANDOM_DELAY=%0d, %0d cases, AR=%0d AW=%0d W=%0d", RANDOM_DELAY, cases, ar_count, aw_count, w_count);
    $finish;
  end
  initial begin
    #200000;
    $fatal(1, "LSU test watchdog timeout");
  end
endmodule
