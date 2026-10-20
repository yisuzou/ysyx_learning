`timescale 1ns/1ps
// XBAR unit test: one random-timing upstream master, two random-timing
// downstream slave models. Checks routing, DECERR (unmapped / disabled rule /
// fetch from non-executable window), AW/W ordering freedom, independent
// read/write directions, VALID stability and reset.
module axi_xbar_tb;
  localparam N = 2;
  // rule 0: RAM   0x8000_0000 + 0x1000 -> port 0, exec
  // rule 1: DEV   0x1000_0000 + 8      -> port 1
  // rule 2: DEV   0x1000_0048 + 8      -> port 1
  // rule 3: OFF   0x2000_0000 + 0x100  -> port 1, disabled
  localparam [4*32-1:0] BASE = {32'h20000000, 32'h10000048, 32'h10000000, 32'h80000000};
  localparam [4*32-1:0] SIZE = {32'h100, 32'd8, 32'd8, 32'h1000};
  localparam [4*8-1:0]  PORT = {8'd1, 8'd1, 8'd1, 8'd0};
  localparam [3:0]      EN   = 4'b0111;
  localparam [3:0]      EXEC = 4'b0001;

  reg clk = 0, rst_n = 0;
  reg [31:0] araddr = 0, awaddr = 0, wdata = 0;
  reg [2:0] arprot = 0, awprot = 0;
  reg [3:0] wstrb = 0;
  reg arvalid = 0, rready = 0, awvalid = 0, wvalid = 0, bready = 0;
  wire arready, rvalid, awready, wready, bvalid;
  wire [31:0] rdata;
  wire [1:0] rresp, bresp;

  wire [N*32-1:0] m_araddr, m_awaddr, m_wdata;
  wire [N*3-1:0] m_arprot, m_awprot;
  wire [N*4-1:0] m_wstrb;
  wire [N-1:0] m_arvalid, m_rready, m_awvalid, m_wvalid, m_bready;
  reg  [N-1:0] m_arready = 0, m_rvalid = 0, m_awready = 0, m_wready = 0, m_bvalid = 0;
  reg  [N*32-1:0] m_rdata = 0;
  reg  [N*2-1:0] m_rresp = 0, m_bresp = 0;

  XBAR #(
      .NUM_SLAVES(N), .NUM_RULES(4), .RULE_BASE(BASE), .RULE_SIZE(SIZE),
      .RULE_PORT(PORT), .RULE_EN(EN), .RULE_EXEC(EXEC)
  ) dut (
      .clk(clk), .rst_n(rst_n),
      .s_axi_araddr(araddr), .s_axi_arprot(arprot), .s_axi_arvalid(arvalid),
      .s_axi_arready(arready), .s_axi_rdata(rdata), .s_axi_rresp(rresp),
      .s_axi_rvalid(rvalid), .s_axi_rready(rready),
      .s_axi_awaddr(awaddr), .s_axi_awprot(awprot), .s_axi_awvalid(awvalid),
      .s_axi_awready(awready), .s_axi_wdata(wdata), .s_axi_wstrb(wstrb),
      .s_axi_wvalid(wvalid), .s_axi_wready(wready),
      .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
      .m_axi_araddr(m_araddr), .m_axi_arprot(m_arprot), .m_axi_arvalid(m_arvalid),
      .m_axi_arready(m_arready), .m_axi_rdata(m_rdata), .m_axi_rresp(m_rresp),
      .m_axi_rvalid(m_rvalid), .m_axi_rready(m_rready),
      .m_axi_awaddr(m_awaddr), .m_axi_awprot(m_awprot), .m_axi_awvalid(m_awvalid),
      .m_axi_awready(m_awready), .m_axi_wdata(m_wdata), .m_axi_wstrb(m_wstrb),
      .m_axi_wvalid(m_wvalid), .m_axi_wready(m_wready),
      .m_axi_bresp(m_bresp), .m_axi_bvalid(m_bvalid), .m_axi_bready(m_bready)
  );

  always #5 clk = ~clk;

  // ---------------- reference model ----------------
  // Expected port (-1 = DECERR) for an address/fetch.
  function integer ref_port(input [31:0] a, input bit fetch);
    integer r;
    begin
      ref_port = -1;
      for (r = 3; r >= 0; r = r - 1)  // reverse so lowest index wins
        if (EN[r] && (a - BASE[r*32 +: 32]) < SIZE[r*32 +: 32])
          ref_port = (fetch && !EXEC[r]) ? -1 : PORT[r*8 +: 8];
    end
  endfunction
  function [31:0] slave_data(input integer p, input [31:0] a);
    slave_data = a ^ (32'h5a5a0000 + p);
  endfunction
  function [1:0] slave_resp(input integer p, input [31:0] a);
    slave_resp = (p == 1 && a[2]) ? 2'b10 : 2'b00;  // port 1 upper word: SLVERR
  endfunction

  // ---------------- slave models (random timing, one txn at a time) -------
  integer rd_seen [0:N-1];
  integer wr_seen [0:N-1];
  reg [31:0] s_ar_addr [0:N-1];
  reg [31:0] s_aw_addr [0:N-1];
  reg [31:0] s_w_data [0:N-1];
  reg [3:0]  s_w_strb [0:N-1];
  reg s_aw_got [0:N-1];
  reg s_w_got [0:N-1];
  reg [31:0] last_wdata [0:N-1];
  reg [31:0] last_waddr [0:N-1];

  genvar gp;
  generate
    for (gp = 0; gp < N; gp = gp + 1) begin : g_slave
      // Read side: random ARREADY, R after random delay.
      always @(posedge clk) begin
        if (!rst_n) begin
          m_arready[gp] <= 0; m_rvalid[gp] <= 0;
        end else begin
          if (m_rvalid[gp]) begin
            if (m_rready[gp]) m_rvalid[gp] <= 0;
          end else if (m_arvalid[gp] && m_arready[gp]) begin
            s_ar_addr[gp] = m_araddr[gp*32 +: 32];
            m_arready[gp] <= 0;
            repeat ($urandom_range(0, 3)) @(posedge clk);
            m_rdata[gp*32 +: 32] <= slave_data(gp, s_ar_addr[gp]);
            m_rresp[gp*2 +: 2] <= slave_resp(gp, s_ar_addr[gp]);
            m_rvalid[gp] <= 1;
            rd_seen[gp] = rd_seen[gp] + 1;
          end else begin
            m_arready[gp] <= ($urandom_range(0, 2) == 0);
          end
        end
      end
      // Write side: AW and W accepted independently, B after both.
      always @(posedge clk) begin
        if (!rst_n) begin
          m_awready[gp] <= 0; m_wready[gp] <= 0; m_bvalid[gp] <= 0;
          s_aw_got[gp] = 0; s_w_got[gp] = 0;
        end else begin
          if (m_awvalid[gp] && m_awready[gp]) begin
            if (s_aw_got[gp]) $fatal(1, "port %0d: second AW before B", gp);
            s_aw_addr[gp] = m_awaddr[gp*32 +: 32]; s_aw_got[gp] = 1;
          end
          if (m_wvalid[gp] && m_wready[gp]) begin
            if (s_w_got[gp]) $fatal(1, "port %0d: second W before B", gp);
            s_w_data[gp] = m_wdata[gp*32 +: 32]; s_w_strb[gp] = m_wstrb[gp*4 +: 4];
            s_w_got[gp] = 1;
          end
          if (m_bvalid[gp] && m_bready[gp]) begin
            m_bvalid[gp] <= 0; s_aw_got[gp] = 0; s_w_got[gp] = 0;
          end
          m_awready[gp] <= !s_aw_got[gp] && ($urandom_range(0, 2) == 0);
          m_wready[gp]  <= !s_w_got[gp]  && ($urandom_range(0, 2) == 0);
          if (s_aw_got[gp] && s_w_got[gp] && !m_bvalid[gp] &&
              ($urandom_range(0, 2) == 0)) begin
            m_bvalid[gp] <= 1;
            m_bresp[gp*2 +: 2] <= slave_resp(gp, s_aw_addr[gp]);
            last_waddr[gp] = s_aw_addr[gp];
            last_wdata[gp] = s_w_data[gp] ^ {28'b0, s_w_strb[gp]};
            wr_seen[gp] = wr_seen[gp] + 1;
          end
        end
      end
      // Downstream VALID must stay asserted with stable payload until READY.
      reg prev_arv, prev_awv, prev_wv;
      reg [31:0] prev_ara, prev_awa, prev_wd;
      always @(posedge clk) begin
        if (rst_n) begin
          if (prev_arv && !(m_arvalid[gp] && m_araddr[gp*32 +: 32] == prev_ara))
            $fatal(1, "port %0d: ARVALID/ARADDR changed before ARREADY", gp);
          if (prev_awv && !(m_awvalid[gp] && m_awaddr[gp*32 +: 32] == prev_awa))
            $fatal(1, "port %0d: AWVALID/AWADDR changed before AWREADY", gp);
          if (prev_wv && !(m_wvalid[gp] && m_wdata[gp*32 +: 32] == prev_wd))
            $fatal(1, "port %0d: WVALID/WDATA changed before WREADY", gp);
        end
        prev_arv = rst_n && m_arvalid[gp] && !m_arready[gp];
        prev_awv = rst_n && m_awvalid[gp] && !m_awready[gp];
        prev_wv  = rst_n && m_wvalid[gp]  && !m_wready[gp];
        prev_ara = m_araddr[gp*32 +: 32];
        prev_awa = m_awaddr[gp*32 +: 32];
        prev_wd  = m_wdata[gp*32 +: 32];
      end
    end
  endgenerate

  // Only the decoded port may ever see a downstream VALID.
  always @(posedge clk) if (rst_n) begin
    if ((m_arvalid & (m_arvalid - 1'b1)) != 0 ||
        (m_awvalid & (m_awvalid - 1'b1)) != 0 ||
        (m_wvalid & (m_wvalid - 1'b1)) != 0)
      $fatal(1, "more than one downstream VALID asserted");
  end

  // ---------------- upstream master ----------------
  integer reads = 0, writes = 0, decerr_r = 0, decerr_w = 0;

  // Handshakes are sampled at the rising edge (pre-NBA values); stimulus
  // changes #1 after the edge.
  task automatic do_read(input [31:0] a, input bit fetch);
    integer exp_port, k, n;
    integer seen0 [0:N-1];
    begin
      exp_port = ref_port(a, fetch);
      for (k = 0; k < N; k++) seen0[k] = rd_seen[k];
      @(posedge clk); #1;
      araddr = a; arprot = fetch ? 3'b101 : 3'b001; arvalid = 1;
      n = 0;
      do begin
        @(posedge clk);
        n = n + 1;
        if (n > 100) $fatal(1, "AR timeout %h", a);
      end while (!arready);
      #1 arvalid = 0; araddr = 32'hxxxxxxxx;
      repeat ($urandom_range(0, 2)) @(posedge clk);
      #1 rready = 1;
      n = 0;
      do begin
        @(posedge clk);
        n = n + 1;
        if (n > 100) $fatal(1, "R timeout %h", a);
      end while (!rvalid);
      if (exp_port < 0) begin
        if (rresp !== 2'b11 || rdata !== 0) $fatal(1, "read %h: want DECERR got %b", a, rresp);
        decerr_r++;
      end else begin
        if (rdata !== slave_data(exp_port, a)) $fatal(1, "read %h: rdata %h", a, rdata);
        if (rresp !== slave_resp(exp_port, a)) $fatal(1, "read %h: rresp %b", a, rresp);
      end
      #1 rready = 0;
      for (k = 0; k < N; k++)
        if (rd_seen[k] != seen0[k] + ((k == exp_port) ? 1 : 0))
          $fatal(1, "read %h routed to wrong port (port %0d count)", a, k);
      reads++;
    end
  endtask

  // order: 0 = AW first, 1 = W first, 2 = together
  task automatic do_write(input [31:0] a, input [31:0] d, input [3:0] s, input integer order);
    integer exp_port, k, n, lag, aw_start, w_start;
    integer seen0 [0:N-1];
    bit aw_ok, w_ok;
    begin
      exp_port = ref_port(a, 0);
      for (k = 0; k < N; k++) seen0[k] = wr_seen[k];
      lag = $urandom_range(1, 4);
      aw_start = (order == 1) ? lag : 0;
      w_start  = (order == 0) ? lag : 0;
      aw_ok = 0; w_ok = 0;
      @(posedge clk);
      for (n = 0; !(aw_ok && w_ok); n++) begin
        if (n > 200) $fatal(1, "AW/W timeout %h", a);
        #1;
        awvalid = !aw_ok && (n >= aw_start);
        awaddr  = awvalid ? a : 32'hxxxxxxxx; awprot = 3'b001;
        wvalid  = !w_ok && (n >= w_start);
        wdata   = wvalid ? d : 32'hxxxxxxxx;  wstrb = s;
        @(posedge clk);
        if (awvalid && awready) aw_ok = 1;
        if (wvalid && wready) w_ok = 1;
      end
      #1 awvalid = 0; wvalid = 0;
      repeat ($urandom_range(0, 2)) @(posedge clk);
      #1 bready = 1;
      n = 0;
      do begin
        @(posedge clk);
        n = n + 1;
        if (n > 100) $fatal(1, "B timeout %h", a);
      end while (!bvalid);
      if (exp_port < 0) begin
        if (bresp !== 2'b11) $fatal(1, "write %h: want DECERR got %b", a, bresp);
        decerr_w++;
      end else begin
        if (bresp !== slave_resp(exp_port, a)) $fatal(1, "write %h: bresp %b", a, bresp);
        if (last_waddr[exp_port] !== a || last_wdata[exp_port] !== (d ^ {28'b0, s}))
          $fatal(1, "write %h: payload mismatch at port %0d", a, exp_port);
      end
      #1 bready = 0;
      for (k = 0; k < N; k++)
        if (wr_seen[k] != seen0[k] + ((k == exp_port) ? 1 : 0))
          $fatal(1, "write %h routed to wrong port (port %0d count)", a, k);
      writes++;
    end
  endtask

  function [31:0] pick_addr();
    case ($urandom_range(0, 7))
      0, 1, 2: pick_addr = 32'h80000000 + {$urandom_range(0, 1023), 2'b00};
      3:       pick_addr = 32'h10000000 + {$urandom_range(0, 1), 2'b00};
      4:       pick_addr = 32'h10000048 + {$urandom_range(0, 1), 2'b00};
      5:       pick_addr = 32'h20000000 + {$urandom_range(0, 63), 2'b00}; // disabled
      6:       pick_addr = 32'h80001000;                                   // just past RAM
      default: pick_addr = $urandom & 32'hfffffffc;
    endcase
  endfunction

  integer t;
  initial begin
    for (t = 0; t < N; t++) begin rd_seen[t] = 0; wr_seen[t] = 0; end
    repeat (3) @(posedge clk);
    #1;
    if (|{m_arvalid, m_awvalid, m_wvalid, m_rready, m_bready, arready, awready,
          wready, rvalid, bvalid})
      $fatal(1, "reset must clear all handshake routes");
    rst_n = 1;

    // Directed cases.
    do_read(32'h80000004, 0);
    do_read(32'h80000008, 1);         // fetch from RAM: ok
    do_read(32'h10000048, 0);         // MMIO read
    do_read(32'h1000004c, 0);         // port 1 SLVERR passthrough
    do_read(32'h10000048, 1);         // fetch from MMIO: DECERR
    do_read(32'h20000000, 0);         // disabled rule: DECERR
    do_read(32'h40000000, 0);         // unmapped: DECERR
    do_write(32'h80000010, 32'h11223344, 4'hf, 0);
    do_write(32'h80000014, 32'h55667788, 4'h3, 1);
    do_write(32'h10000000, 32'h41, 4'h1, 2);
    do_write(32'h40000000, 32'h0, 4'hf, 1);   // unmapped, W before AW
    do_write(32'h20000004, 32'h0, 4'hf, 0);   // disabled rule

    // Pipelined master: the next AW is presented right after the first AW
    // handshake, before B. XBAR must not forward it until the first B is done.
    begin : b2b
      integer base, n;
      reg aw1, w1, aw2, w2;
      base = wr_seen[0];
      @(posedge clk); #1;
      awaddr = 32'h80000100; awprot = 3'b001; awvalid = 1;
      wdata = 32'h1; wstrb = 4'hf; wvalid = 0;
      aw1 = 0; w1 = 0;
      // W1 lags AW1 by several cycles, so the XBAR sits in WR_DATA with the
      // next AW already valid upstream.
      for (n = 0; !(aw1 && w1); n = n + 1) begin
        if (n > 200) $fatal(1, "b2b AW1/W1 timeout");
        @(posedge clk);
        if (awvalid && awready) aw1 = 1;
        if (wvalid && wready) w1 = 1;
        #1;
        if (aw1) awaddr = 32'h80000104;  // AWVALID stays high: next request
        wvalid = aw1 && !w1 && (n >= 8);
      end
      repeat (5) @(posedge clk);  // slave model fatals if AW2 leaks through
      #1 bready = 1;
      n = 0;
      do begin
        @(posedge clk);
        n = n + 1;
        if (n > 200) $fatal(1, "b2b B1 timeout");
      end while (!bvalid);
      #1 bready = 0;
      if (wr_seen[0] != base + 1 || last_waddr[0] !== 32'h80000100)
        $fatal(1, "b2b: first write wrong");
      wdata = 32'h2; wvalid = 1;
      aw2 = 0; w2 = 0;
      for (n = 0; !(aw2 && w2); n = n + 1) begin
        if (n > 200) $fatal(1, "b2b AW2/W2 timeout");
        @(posedge clk);
        if (awvalid && awready) aw2 = 1;
        if (wvalid && wready) w2 = 1;
        #1;
        if (aw2) awvalid = 0;
        if (w2) wvalid = 0;
      end
      #1 bready = 1;
      n = 0;
      do begin
        @(posedge clk);
        n = n + 1;
        if (n > 200) $fatal(1, "b2b B2 timeout");
      end while (!bvalid);
      #1 bready = 0;
      if (wr_seen[0] != base + 2 || last_waddr[0] !== 32'h80000104)
        $fatal(1, "b2b: second write wrong");
    end

    // Random reads and writes running concurrently.
    fork
      for (int i = 0; i < 400; i++) do_read(pick_addr(), $urandom_range(0, 3) == 0);
      for (int i = 0; i < 400; i++) do_write(pick_addr(), $urandom, $urandom, $urandom_range(0, 2));
    join

    // Reset in the middle of a transaction must drop all routes.
    @(negedge clk);
    araddr = 32'h80000000; arprot = 1; arvalid = 1;
    awaddr = 32'h10000000; awvalid = 1;
    repeat (2) @(posedge clk);
    #1 rst_n = 0; arvalid = 0; awvalid = 0;
    #1;
    if (|{m_arvalid, m_awvalid, m_wvalid, m_rready, m_bready, arready, awready,
          wready, rvalid, bvalid})
      $fatal(1, "async reset must clear all handshake routes");
    @(posedge clk); #1 rst_n = 1;
    do_read(32'h80000020, 0);
    do_write(32'h80000024, 32'hcafef00d, 4'hf, 2);

    $display("PASS: XBAR (%0d reads, %0d writes, DECERR r/w = %0d/%0d, port reads %0d/%0d, port writes %0d/%0d)",
             reads, writes, decerr_r, decerr_w, rd_seen[0], rd_seen[1], wr_seen[0], wr_seen[1]);
    $finish;
  end
endmodule
