`timescale 1ns/1ps

// Exercise the actual npc_core wiring through a synthesizable MEM slave.
// Bus counts distinguish cache hits from uncached LSU accesses. Both delay
// configurations must execute the same loop, conflict and fault sequences.
module icache_core_tb;
  parameter RANDOM_DELAY = 0;
  localparam [31:0] BASE = 32'h80000000;
  localparam [31:0] NOP = 32'h00000013;
  localparam [31:0] EBREAK = 32'h00100073;

  reg clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  reg block_ar = 0;
  reg [1:0] injected_resp = 0;
  wire invalid_inst, retired, bus_error;
  wire [31:0] pc, inst, error_addr;
  wire [1:0] error_resp, error_op;
  wire [31:0] araddr, awaddr, wdata, rdata;
  wire [2:0] arprot, awprot;
  wire [3:0] wstrb;
  wire arvalid, arready, mem_arready, rvalid, rready;
  wire awvalid, awready, wvalid, wready, bvalid, bready;
  wire [1:0] mem_rresp, bresp;
  wire [1:0] rresp = injected_resp != 0 ? injected_resp : mem_rresp;
  assign arready = mem_arready && !block_ar;

  npc_core #(.RANDOM_DELAY(RANDOM_DELAY), .PMEM_SIZE(1024)) dut (
      .clk(clk), .rst_n(rst_n),
      .invalid_inst(invalid_inst), .diff_ifu_valid(retired),
      .debug_pc(pc), .debug_inst(inst),
      .debug_bus_error(bus_error), .debug_bus_error_addr(error_addr),
      .debug_bus_error_resp(error_resp), .debug_bus_error_op(error_op),
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

  MEM #(.RANDOM_DELAY(RANDOM_DELAY), .SIZE(1024)) mem (
      .clk(clk), .rst_n(rst_n),
      .s_axi_araddr(araddr), .s_axi_arprot(arprot),
      .s_axi_arvalid(arvalid && !block_ar), .s_axi_arready(mem_arready),
      .s_axi_rdata(rdata), .s_axi_rresp(mem_rresp),
      .s_axi_rvalid(rvalid), .s_axi_rready(rready),
      .s_axi_awaddr(awaddr), .s_axi_awprot(awprot),
      .s_axi_awvalid(awvalid), .s_axi_awready(awready),
      .s_axi_wdata(wdata), .s_axi_wstrb(wstrb),
      .s_axi_wvalid(wvalid), .s_axi_wready(wready),
      .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready)
  );

  integer fetch_reads = 0, data_reads = 0, writes = 0;
  integer fetch_requests = 0, commits = 0, cycles = 0;
  reg held_ar = 0;
  reg [34:0] held_payload;
  always @(posedge clk) begin
    if (!rst_n) begin
      fetch_reads = 0; data_reads = 0; writes = 0;
      fetch_requests = 0; commits = 0; cycles = 0;
      held_ar = 0;
    end else begin
      cycles = cycles + 1;
      if (invalid_inst) $fatal(1, "unexpected illegal instruction at %h", pc);
      if (arvalid && arready) begin
        if (arprot[2]) fetch_reads = fetch_reads + 1;
        else data_reads = data_reads + 1;
      end
      if (wvalid && wready) writes = writes + 1;
      if (dut.ifu_arvalid && dut.ifu_arready) fetch_requests = fetch_requests + 1;
      if (retired) commits = commits + 1;
      if (held_ar && (!arvalid || {araddr, arprot} !== held_payload))
        $fatal(1, "external AR changed under backpressure");
      held_ar = arvalid && !arready;
      held_payload = {araddr, arprot};
    end
  end

  function automatic [31:0] itype(input integer imm, input [4:0] rs1,
      input [2:0] funct3, input [4:0] rd, input [6:0] opcode);
    itype = {imm[11:0], rs1, funct3, rd, opcode};
  endfunction
  function automatic [31:0] branch(input integer offset, input [4:0] rs1);
    branch = {offset[12], offset[10:5], 5'd0, rs1, 3'b001,
              offset[4:1], offset[11], 7'b1100011}; // bne rs1, x0, offset
  endfunction
  function automatic [31:0] jump(input integer offset);
    jump = {offset[20], offset[10:1], offset[11], offset[19:12],
            5'd0, 7'b1101111}; // jal x0, offset
  endfunction

  task automatic check(input bit ok, input string message);
    if (!ok) $fatal(1, "%s (delay=%0d, PC=%h)", message, RANDOM_DELAY, pc);
  endtask
  task automatic step;
    @(posedge clk); #1; @(negedge clk); #1;
  endtask
  task automatic prepare;
    integer k;
    rst_n = 0; block_ar = 0; injected_resp = 0;
    repeat (3) step();
    check(!arvalid && !rready && !awvalid && !wvalid && !bready,
          "reset must quiesce the external bus");
    for (k = 0; k < 256; k = k + 1) mem.mem[k] = NOP;
  endtask
  task automatic run_to_ebreak(input [31:0] halt_pc);
    while (!(retired && inst == EBREAK) && !bus_error && cycles < 10000) step();
    check(!bus_error && retired && inst == EBREAK && pc == halt_pc,
          "program failed to reach expected EBREAK");
    step(); // consume the final commit
  endtask

  task automatic load_loop;
    // Five iterations over four cached instructions, with an LSU load each
    // iteration and an LSU store of the final sum. No code writes occur.
    mem.mem[0] = 32'h80000437;                        // lui s0, 0x80000
    mem.mem[1] = itype(768, 8, 0, 8, 7'b0010011);   // addi s0, s0, 0x300
    mem.mem[2] = itype(5, 0, 0, 5, 7'b0010011);     // addi t0, x0, 5
    mem.mem[3] = itype(0, 0, 0, 6, 7'b0010011);     // addi t1, x0, 0
    mem.mem[4] = itype(0, 8, 2, 7, 7'b0000011);     // lw t2, 0(s0)
    mem.mem[5] = {7'b0, 5'd7, 5'd6, 3'b0, 5'd6, 7'b0110011}; // add t1,t1,t2
    mem.mem[6] = itype(-1, 5, 0, 5, 7'b0010011);    // addi t0, t0, -1
    mem.mem[7] = branch(-12, 5);                    // bne t0, x0, loop
    mem.mem[8] = {7'b0, 5'd6, 5'd8, 3'b010, 5'd4, 7'b0100011}; // sw t1,4(s0)
    mem.mem[9] = EBREAK;
    mem.mem[192] = 7;
    mem.mem[193] = 0;
  endtask
  task automatic check_loop;
    run_to_ebreak(BASE + 36);
    check(mem.mem[193] === 32'd35, "wrong load/add/store result");
    check(fetch_requests == 26 && commits == 26, "lost/duplicated loop instruction");
    check(fetch_reads == 10, "loop must miss once for each of ten unique words");
    check(data_reads == 5 && writes == 1, "LSU traffic must bypass I-cache");
  endtask

  integer code;
  initial begin
    @(negedge clk); #1;
    prepare(); load_loop(); rst_n = 1;
    check_loop();
    $display("PASS: loop: 26 fetches, 10 external instruction reads, 5 loads, 1 store");

    prepare();
    mem.mem[0] = itype(4, 0, 0, 5, 7'b0010011); // counter = 4
    mem.mem[1] = jump(64);                     // PC 0x04 -> 0x44
    mem.mem[17] = itype(-1, 5, 0, 5, 7'b0010011);
    mem.mem[18] = branch(-68, 5);              // PC 0x48 -> 0x04
    mem.mem[19] = EBREAK;
    rst_n = 1;
    run_to_ebreak(BASE + 76);
    check(fetch_requests == 14 && commits == 14 && fetch_reads == 11,
          "64-byte conflict replacement produced wrong bus counts");
    check(data_reads == 0 && writes == 0, "unexpected data access in conflict loop");
    $display("PASS: conflicts: 14 fetches, 11 external instruction reads");

    for (code = 2; code <= 3; code = code + 1) begin
      prepare(); mem.mem[0] = EBREAK; injected_resp = code[1:0]; rst_n = 1;
      while (!bus_error && cycles < 1000) step();
      check(bus_error && error_op == 0 && error_addr == BASE && error_resp == code[1:0],
            "fetch error did not propagate through cache to IFU");
      check(commits == 0 && fetch_reads == 1 && fetch_requests == 1,
            "faulting fetch must not retire");
      repeat (10) begin
        step();
        check(bus_error && !retired && !arvalid && !rready,
              "IFU fault must hold without further traffic");
      end
    end
    $display("PASS: SLVERR/DECERR reach sticky IFU fault without retiring data");

    prepare(); load_loop(); block_ar = 1; rst_n = 1;
    while (!arvalid && cycles < 100) step();
    check(arvalid && araddr == BASE, "reset fetch must reach cache miss channel");
    repeat (5) step();
    check(fetch_requests == 1 && fetch_reads == 0, "stalled miss accepted unexpectedly");
    prepare(); load_loop(); rst_n = 1;
    check_loop();
    $display("PASS: reset during stalled miss restarts from reset PC with empty cache");
    $display("ICACHE_CORE_TB: ALL PASS (RANDOM_DELAY=%0d)", RANDOM_DELAY);
    $finish;
  end
  initial begin
    #2000000;
    $fatal(1, "I-cache integration watchdog timeout");
  end
endmodule
