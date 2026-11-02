`timescale 1ns/1ps

// Geometry-independent reference model. The memory changes between requests
// so a hit must return the cached snapshot, while a miss fills the whole line.
module icache_param_tb;
  parameter integer LINES = 16;
  parameter integer BLOCK_BYTES = 4;
  localparam integer WORDS = BLOCK_BYTES / 4;
  localparam integer CAPACITY = LINES * BLOCK_BYTES;
  localparam [31:0] BASE = 32'h80000000;

  reg clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  reg pc_valid = 0, inst_ready = 0;
  reg [31:0] pc = 0;
  wire pc_ready, inst_valid;
  wire [31:0] inst, araddr;
  wire [1:0] inst_resp;
  wire [2:0] arprot;
  wire arvalid, arready, rready;
  reg [31:0] rdata = 0;
  reg [1:0] rresp = 0;
  reg rvalid = 0;
  reg error_en = 0;
  reg [31:0] error_addr = 0, epoch = 0;
  reg [1:0] error_code = 2'b10;

  icache #(.LINE_COUNT(LINES), .BLOCK_BYTES(BLOCK_BYTES)) dut (
      .clk(clk), .rst_n(rst_n),
      .if_pc_valid(pc_valid), .if_pc_ready(pc_ready), .if_pc(pc),
      .if_inst(inst), .if_inst_resp(inst_resp),
      .if_inst_valid(inst_valid), .if_inst_ready(inst_ready),
      .m_axi_araddr(araddr), .m_axi_arprot(arprot),
      .m_axi_arvalid(arvalid), .m_axi_arready(arready),
      .m_axi_rdata(rdata), .m_axi_rresp(rresp),
      .m_axi_rvalid(rvalid), .m_axi_rready(rready),
      .m_axi_awaddr(), .m_axi_awprot(), .m_axi_awvalid(), .m_axi_awready(1'b0),
      .m_axi_wdata(), .m_axi_wstrb(), .m_axi_wvalid(), .m_axi_wready(1'b0),
      .m_axi_bresp(2'b00), .m_axi_bvalid(1'b0), .m_axi_bready()
  );

  function automatic [31:0] memory_word(input [31:0] addr, input [31:0] version);
    memory_word = ((addr >> 2) * 32'h9e3779b9) ^ (version * 32'h01424a57);
  endfunction

  reg pending = 0;
  reg [31:0] pending_addr, pending_epoch;
  reg [1:0] pending_resp;
  integer delay_left = 0, cycles = 0;
  integer reads = 0, beats = 0, requests = 0, responses = 0;
  reg held_ar = 0;
  reg [31:0] held_addr;
  assign arready = rst_n && !pending && !rvalid && ((cycles % 4) != 0);
  always @(posedge clk) begin
    if (!rst_n) begin
      pending <= 0; rvalid <= 0;
      cycles = 0; held_ar = 0;
    end else begin
      cycles = cycles + 1;
      if (pc_valid && pc_ready) requests = requests + 1;
      if (inst_valid && inst_ready) responses = responses + 1;
      if (held_ar && (!arvalid || araddr !== held_addr))
        $fatal(1, "AR address/valid changed before handshake");
      held_ar = arvalid && !arready;
      held_addr = araddr;
      if (arvalid && arready) begin
        if (araddr[1:0] != 0 || arprot != 3'b101)
          $fatal(1, "bad refill address/attribute");
        reads = reads + 1;
        pending <= 1;
        pending_addr <= araddr;
        pending_epoch <= epoch;
        pending_resp <= (error_en && araddr == error_addr) ? error_code : 2'b00;
        delay_left <= (araddr >> 2) % 3;
      end
      if (pending) begin
        if (delay_left != 0) delay_left <= delay_left - 1;
        else begin
          pending <= 0;
          rvalid <= 1;
          rdata <= memory_word(pending_addr, pending_epoch);
          rresp <= pending_resp;
        end
      end
      if (rvalid && rready) begin
        beats = beats + 1;
        rvalid <= 0;
      end
    end
  end

  reg [LINES-1:0] ref_valid = 0;
  reg [31:0] ref_base [0:LINES-1];
  reg [31:0] ref_epoch [0:LINES-1];
  task automatic check(input bit ok, input string message);
    if (!ok) $fatal(1, "%s (lines=%0d, block=%0d, pc=%h)", message, LINES, BLOCK_BYTES, pc);
  endtask
  task automatic step;
    @(posedge clk); #1; @(negedge clk); #1;
  endtask
  task automatic reset_cache;
    rst_n = 0; pc_valid = 0; inst_ready = 0; error_en = 0;
    #1;
    check({pc_ready, inst_valid, arvalid, rready} === 4'b0, "reset interface active");
    repeat (3) step();
    ref_valid = 0;
    rst_n = 1;
    step();
  endtask

  task automatic fetch(input [31:0] addr, input integer stalls);
    integer idx, old_reads, old_beats, old_requests, old_responses, timeout;
    reg expected_hit, bad_fill;
    reg [31:0] block_base, expected_word;
    reg [1:0] expected_resp;
    begin
      idx = (addr / BLOCK_BYTES) % LINES;
      block_base = (addr / BLOCK_BYTES) * BLOCK_BYTES;
      expected_hit = ref_valid[idx] && ref_base[idx] == block_base;
      bad_fill = error_en && error_addr >= block_base &&
                 (error_addr - block_base) < BLOCK_BYTES;
      expected_resp = (!expected_hit && bad_fill) ? error_code : 2'b00;
      expected_word = memory_word(addr, expected_hit ? ref_epoch[idx] : epoch);
      old_reads = reads; old_beats = beats;
      old_requests = requests; old_responses = responses;
      check(pc_ready === 1'b1, "request interface not idle");
      pc = addr; pc_valid = 1; inst_ready = (stalls == 0);
      step();
      pc = ~addr; // accepted PC must survive changes at the input
      timeout = 0;
      while (!inst_valid && timeout < 2000) begin
        check(!pc_ready, "accepted another PC during refill");
        step(); timeout = timeout + 1;
      end
      check(inst_valid === 1'b1, "fetch timed out");
      check(inst === expected_word && inst_resp === expected_resp, "wrong word/response");
      check(reads - old_reads == (expected_hit ? 0 : WORDS), "wrong refill read count");
      check(beats - old_beats == (expected_hit ? 0 : WORDS), "wrong refill response count");
      repeat (stalls) begin
        step();
        check(inst_valid && inst === expected_word && inst_resp === expected_resp,
              "instruction/response changed under backpressure");
        check(!pc_ready && !arvalid && !rready, "traffic while response stalled");
      end
      inst_ready = 1;
      step(); pc_valid = 0; inst_ready = 0;
      check(requests == old_requests + 1 && responses == old_responses + 1,
            "lost or duplicated request/response");
      if (!expected_hit && !bad_fill) begin
        ref_valid[idx] = 1;
        ref_base[idx] = block_base;
        ref_epoch[idx] = epoch;
      end
    end
  endtask

  integer i, w, old_beats;
  reg [31:0] addr;
  initial begin
    @(negedge clk); #1;
    reset_cache();
    // All indices and all words in each line, including one-line/one-word cases.
    for (i = 0; i < LINES; i = i + 1) fetch(BASE + i*BLOCK_BYTES, i%4);
    epoch = epoch + 1;
    for (i = 0; i < LINES; i = i + 1)
      for (w = 0; w < WORDS; w = w + 1) fetch(BASE + i*BLOCK_BYTES + w*4, w%3);
    fetch(BASE + CAPACITY, 3);
    fetch(BASE, 1);

    // An error in any beat must preserve the conflicting old line.
    // Include errors outside the requested word, and both response codes.
    for (w = 0; w < WORDS; w = w + 1) begin
      error_en = 1;
      error_addr = BASE + 2*CAPACITY + w*4;
      error_code = w%2 ? 2'b11 : 2'b10;
      fetch(BASE + 2*CAPACITY + (WORDS-1)*4, 3);
      error_en = 0;
      fetch(BASE, 0);
    end
    epoch = epoch + 1;
    fetch(BASE + 2*CAPACITY, 0);
    for (w = 0; w < WORDS; w = w + 1) fetch(BASE + 2*CAPACITY + w*4, 0);

    // Reset after the first transferred word, before the response is consumed.
    old_beats = beats;
    pc = BASE + 3*CAPACITY; pc_valid = 1; inst_ready = 0;
    step(); pc_valid = 0;
    while (beats == old_beats) step();
    reset_cache(); epoch = epoch + 1;
    fetch(BASE + 3*CAPACITY, 1);

    // Random index/tag/word combinations and changing backing contents.
    for (i = 0; i < 300; i = i + 1) begin
      epoch = epoch + 1;
      addr = BASE + $urandom_range(0, LINES*2-1)*BLOCK_BYTES +
             $urandom_range(0, WORDS-1)*4;
      error_en = (i%13 == 0);
      error_addr = (addr / BLOCK_BYTES)*BLOCK_BYTES + (i%WORDS)*4;
      fetch(addr, i%4);
    end
    $display("ICACHE_PARAM_TB: ALL PASS (lines=%0d, block=%0d B)", LINES, BLOCK_BYTES);
    $finish;
  end
  initial begin
    #20000000;
    $fatal(1, "parameterized cache watchdog timeout");
  end
endmodule
