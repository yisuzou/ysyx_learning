`timescale 1ns/1ps
module debug_lab_case2;
  reg  clk;
  reg  rst_n;
  reg  in_valid;
  wire  in_ready;
  reg [31:0] in_pc;
  reg [31:0] in_inst;
  reg  in_illegal;
  reg [ 4:0] in_rd;
  reg [31:0] in_rs1_value;
  reg [31:0] in_rs2_value;
  reg [31:0] in_imm;
  reg [31:0] in_csr_old;
  reg [31:0] in_mtvec;
  reg [31:0] in_a0;
  reg [ 1:0] in_src_sel;
  reg [ 3:0] in_exu_op;
  reg  in_pc_we;
  reg [ 1:0] in_pc_wsel;
  reg  in_branch_en;
  reg [ 2:0] in_branch_op;
  reg  in_gpr_we;
  reg [ 2:0] in_gpr_wsel;
  reg  in_mem_valid;
  reg  in_mem_wen;
  reg [ 1:0] in_mem_rbhw;
  reg [ 1:0] in_mem_wbhw;
  reg  in_isign;
  reg  in_csr_we;
  reg [ 1:0] in_csr_wsel;
  reg [11:0] in_csr_addr;
  reg  in_imm2csr;
  reg  in_is_ecall;
  reg  in_is_ebreak;
  wire  out_valid;
  reg  out_ready;
  wire [31:0] out_pc;
  wire [31:0] out_inst;
  wire [31:0] out_next_pc;
  wire  out_illegal;
  wire  out_rd_we;
  wire [ 4:0] out_rd;
  wire [31:0] out_rd_data;
  wire  out_csr_we;
  wire [11:0] out_csr_addr;
  wire [31:0] out_csr_data;
  wire  out_is_ecall;
  wire  out_is_ebreak;
  wire [31:0] out_a0;
  wire  out_skip_ref;
  wire [ 9:0] out_perf_class;
  wire  dbg_busy;
  wire  dbg_mem_wait;
  wire  dbg_wait_wb;
  wire  req_valid;
  reg  req_ready;
  wire [31:0] req_addr;
  wire  req_write;
  wire [ 1:0] req_rsize;
  wire [ 1:0] req_wsize;
  wire [31:0] req_wdata;
  wire  req_sign;
  reg  rsp_valid;
  wire  rsp_ready;
  reg [31:0] rsp_rdata;
  exu_stage  dut (
    .clk(clk),
    .rst_n(rst_n),
    .in_valid(in_valid),
    .in_ready(in_ready),
    .in_pc(in_pc),
    .in_inst(in_inst),
    .in_illegal(in_illegal),
    .in_rd(in_rd),
    .in_rs1_value(in_rs1_value),
    .in_rs2_value(in_rs2_value),
    .in_imm(in_imm),
    .in_csr_old(in_csr_old),
    .in_mtvec(in_mtvec),
    .in_a0(in_a0),
    .in_src_sel(in_src_sel),
    .in_exu_op(in_exu_op),
    .in_pc_we(in_pc_we),
    .in_pc_wsel(in_pc_wsel),
    .in_branch_en(in_branch_en),
    .in_branch_op(in_branch_op),
    .in_gpr_we(in_gpr_we),
    .in_gpr_wsel(in_gpr_wsel),
    .in_mem_valid(in_mem_valid),
    .in_mem_wen(in_mem_wen),
    .in_mem_rbhw(in_mem_rbhw),
    .in_mem_wbhw(in_mem_wbhw),
    .in_isign(in_isign),
    .in_csr_we(in_csr_we),
    .in_csr_wsel(in_csr_wsel),
    .in_csr_addr(in_csr_addr),
    .in_imm2csr(in_imm2csr),
    .in_is_ecall(in_is_ecall),
    .in_is_ebreak(in_is_ebreak),
    .out_valid(out_valid),
    .out_ready(out_ready),
    .out_pc(out_pc),
    .out_inst(out_inst),
    .out_next_pc(out_next_pc),
    .out_illegal(out_illegal),
    .out_rd_we(out_rd_we),
    .out_rd(out_rd),
    .out_rd_data(out_rd_data),
    .out_csr_we(out_csr_we),
    .out_csr_addr(out_csr_addr),
    .out_csr_data(out_csr_data),
    .out_is_ecall(out_is_ecall),
    .out_is_ebreak(out_is_ebreak),
    .out_a0(out_a0),
    .out_skip_ref(out_skip_ref),
    .out_perf_class(out_perf_class),
    .dbg_busy(dbg_busy),
    .dbg_mem_wait(dbg_mem_wait),
    .dbg_wait_wb(dbg_wait_wb),
    .req_valid(req_valid),
    .req_ready(req_ready),
    .req_addr(req_addr),
    .req_write(req_write),
    .req_rsize(req_rsize),
    .req_wsize(req_wsize),
    .req_wdata(req_wdata),
    .req_sign(req_sign),
    .rsp_valid(rsp_valid),
    .rsp_ready(rsp_ready),
    .rsp_rdata(rsp_rdata)
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

  integer requests;
  integer responses;
  integer outputs;
  always @(posedge clk) begin
    if (!rst_n) begin
      requests = 0;
      responses = 0;
      outputs = 0;
    end else begin
      if (req_valid && req_ready) requests = requests + 1;
      if (rsp_valid && rsp_ready) responses = responses + 1;
      if (out_valid && out_ready) outputs = outputs + 1;
    end
  end
  task load_transaction;
    input block_output;
    input [31:0] value;
    integer old_requests;
    integer old_responses;
    integer old_outputs;
    begin
      old_requests = requests;
      old_responses = responses;
      old_outputs = outputs;
      @(negedge clk);
      out_ready = !block_output;
      in_pc = 32'h80000000;
      in_inst = 32'h00412283;
      in_rd = 5;
      in_rs1_value = 32'h80000100;
      in_imm = 4;
      in_src_sel = 1;
      in_exu_op = 0;
      in_gpr_we = 1;
      in_gpr_wsel = 4;
      in_mem_valid = 1;
      in_mem_rbhw = 3;
      in_valid = 1;
      req_ready = 0;
      @(posedge clk);
      while (!in_ready) @(posedge clk);
      @(negedge clk);
      in_valid = 0;
      // 输入已交付，之后的实时输入不属于这条指令。
      in_rs1_value = 32'hbad00000;
      while (!req_valid) @(negedge clk);
      repeat (3) begin
        @(negedge clk);
        check(req_valid && req_addr == 32'h80000104 && !req_write,
              "request must remain stable until accepted");
      end
      req_ready = 1;
      @(posedge clk);
      @(negedge clk);
      req_ready = 0;
      repeat (4) @(negedge clk);
      rsp_rdata = value;
      rsp_valid = 1;
      @(posedge clk);
      while (!rsp_ready) @(posedge clk);
      @(negedge clk);
      rsp_valid = 0;
      rsp_rdata = 32'hbad0bad0;
      while (!out_valid) @(negedge clk);
      $display("RESULT blocked=%0d got=%08h expected=%08h", block_output, out_rd_data, value);
      check(out_rd_data === value, "completed load result is incorrect");
      check(out_pc == 32'h80000000 && out_rd == 5 && out_rd_we && !out_illegal,
            "output instruction metadata is incorrect");
      if (block_output) begin
        repeat (5) begin
          @(negedge clk);
          check(out_valid && out_rd_data === value, "result lost while receiver waits");
        end
        out_ready = 1;
      end
      @(posedge clk);
      @(negedge clk);
      check(requests == old_requests+1 && responses == old_responses+1 && outputs == old_outputs+1,
            "expected exactly one request, response and result");
    end
  endtask

  initial begin
    clk = 0;
    rst_n = 0;
    in_valid = 0;
    in_pc = 0;
    in_inst = 0;
    in_illegal = 0;
    in_rd = 0;
    in_rs1_value = 0;
    in_rs2_value = 0;
    in_imm = 0;
    in_csr_old = 0;
    in_mtvec = 0;
    in_a0 = 0;
    in_src_sel = 0;
    in_exu_op = 0;
    in_pc_we = 0;
    in_pc_wsel = 0;
    in_branch_en = 0;
    in_branch_op = 0;
    in_gpr_we = 0;
    in_gpr_wsel = 0;
    in_mem_valid = 0;
    in_mem_wen = 0;
    in_mem_rbhw = 0;
    in_mem_wbhw = 0;
    in_isign = 0;
    in_csr_we = 0;
    in_csr_wsel = 0;
    in_csr_addr = 0;
    in_imm2csr = 0;
    in_is_ecall = 0;
    in_is_ebreak = 0;
    out_ready = 0;
    req_ready = 0;
    rsp_valid = 0;
    rsp_rdata = 0;
    $dumpfile("case2.vcd");
    $dumpvars(0, debug_lab_case2);
    repeat (2) @(negedge clk);
    rst_n = 1;
    load_transaction(0, 32'h11223344);
    load_transaction(1, 32'h89abcdef);

    $display("PASS: case2");
    $finish;
  end
endmodule
