`timescale 1ns/1ps
module debug_lab_case3;
  reg  clk;
  reg  rst_n;
  reg  in_valid;
  wire  in_ready;
  reg [31:0] in_pc;
  reg [31:0] in_inst;
  reg [31:0] in_next_pc;
  reg  in_illegal;
  reg  in_rd_we;
  reg [ 4:0] in_rd;
  reg [31:0] in_rd_data;
  reg  in_csr_we;
  reg [11:0] in_csr_addr;
  reg [31:0] in_csr_data;
  reg  in_is_ecall;
  reg  in_is_ebreak;
  reg [31:0] in_a0;
  reg  in_skip_ref;
  reg [ 9:0] in_perf_class;
  wire  pc_valid;
  reg  pc_ready;
  wire [31:0] pc_data;
  wire  gpr_wen;
  wire [ 4:0] gpr_waddr;
  wire [31:0] gpr_wdata;
  wire  csr_wen;
  wire [11:0] csr_waddr;
  wire [31:0] csr_wdata;
  wire  csr_ecall;
  wire [31:0] csr_mepc_data;
  wire [31:0] csr_mcause_data;
  wire [31:0] arch_pc;
  wire  commit_valid;
  wire  retire_illegal;
  wire [31:0] retire_pc;
  wire [31:0] retire_inst;
  wire  retire_ebreak;
  wire [31:0] retire_a0;
  wire  retire_skip_ref;
  wire [ 9:0] retire_perf_class;
  wire  retire_pending;
  WBU  dut (
    .clk(clk),
    .rst_n(rst_n),
    .in_valid(in_valid),
    .in_ready(in_ready),
    .in_pc(in_pc),
    .in_inst(in_inst),
    .in_next_pc(in_next_pc),
    .in_illegal(in_illegal),
    .in_rd_we(in_rd_we),
    .in_rd(in_rd),
    .in_rd_data(in_rd_data),
    .in_csr_we(in_csr_we),
    .in_csr_addr(in_csr_addr),
    .in_csr_data(in_csr_data),
    .in_is_ecall(in_is_ecall),
    .in_is_ebreak(in_is_ebreak),
    .in_a0(in_a0),
    .in_skip_ref(in_skip_ref),
    .in_perf_class(in_perf_class),
    .pc_valid(pc_valid),
    .pc_ready(pc_ready),
    .pc_data(pc_data),
    .gpr_wen(gpr_wen),
    .gpr_waddr(gpr_waddr),
    .gpr_wdata(gpr_wdata),
    .csr_wen(csr_wen),
    .csr_waddr(csr_waddr),
    .csr_wdata(csr_wdata),
    .csr_ecall(csr_ecall),
    .csr_mepc_data(csr_mepc_data),
    .csr_mcause_data(csr_mcause_data),
    .arch_pc(arch_pc),
    .commit_valid(commit_valid),
    .retire_illegal(retire_illegal),
    .retire_pc(retire_pc),
    .retire_inst(retire_inst),
    .retire_ebreak(retire_ebreak),
    .retire_a0(retire_a0),
    .retire_skip_ref(retire_skip_ref),
    .retire_perf_class(retire_perf_class),
    .retire_pending(retire_pending)
  );

  always #5 clk = ~clk;
  task check;
    input ok;
    input [8*160-1:0] message;
    begin
      if (ok !== 1'b1) begin
        $display("FAIL: %0s at %0t", message, $time);
        $finish;
      end
    end
  endtask
  initial begin
    #20000;
    $display("FAIL: timeout; a transaction did not complete");
    $finish;
  end

  integer commits;
  integer writes;
  always @(posedge clk) begin
    if (!rst_n) begin
      commits = 0;
      writes = 0;
    end else begin
      if (commit_valid) commits = commits + 1;
      if (gpr_wen) writes = writes + 1;
    end
  end
  task submit_result;
    input blocked;
    input [31:0] pc;
    integer old_commits;
    integer old_writes;
    begin
      old_commits = commits;
      old_writes = writes;
      @(negedge clk);
      pc_ready = !blocked;
      in_pc = pc;
      in_inst = 32'h00700293;
      in_next_pc = pc + 4;
      in_rd_we = 1;
      in_rd = 5;
      in_rd_data = 7;
      in_valid = 1;
      @(posedge clk);
      while (!in_ready) @(posedge clk);
      @(negedge clk);
      in_valid = 0;
      check(retire_pending && retire_pc == pc, "accepted result must be retained");
      if (blocked) begin
        repeat (5) begin
          check(!commit_valid && !gpr_wen && arch_pc == pc,
                "must not commit before next-PC acceptance");
          @(negedge clk);
          check(retire_pending && pc_valid && pc_data == pc+4,
                "pending instruction disappeared while next-PC receiver was blocked");
        end
        pc_ready = 1;
      end
      @(posedge clk);
      check(commit_valid && gpr_wen && gpr_waddr == 5 && gpr_wdata == 7,
            "commit must include the correct architectural write");
      @(negedge clk);
      check(arch_pc == pc+4 && !retire_pending, "commit must advance PC and release result");
      check(commits == old_commits+1 && writes == old_writes+1,
            "one instruction must commit and write exactly once");
    end
  endtask

  initial begin
    clk = 0;
    rst_n = 0;
    in_valid = 0;
    in_pc = 0;
    in_inst = 0;
    in_next_pc = 0;
    in_illegal = 0;
    in_rd_we = 0;
    in_rd = 0;
    in_rd_data = 0;
    in_csr_we = 0;
    in_csr_addr = 0;
    in_csr_data = 0;
    in_is_ecall = 0;
    in_is_ebreak = 0;
    in_a0 = 0;
    in_skip_ref = 0;
    in_perf_class = 0;
    pc_ready = 0;
    $dumpfile("case3.vcd");
    $dumpvars(0, debug_lab_case3);
    repeat (2) @(negedge clk);
    rst_n = 1;
    submit_result(0, 32'h80000000);
    submit_result(1, 32'h80000004);

    $display("PASS: case3");
    $finish;
  end
endmodule
