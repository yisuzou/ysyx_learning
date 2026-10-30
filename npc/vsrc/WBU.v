// WBU: commit stage. It owns the ew message until the architectural writes and
// the next-PC message have been issued, but it does not command other stages.
// Result selection now lives in exu_stage; WBU only commits what it receives.
module WBU (
    input         clk,
    input         rst_n,

    // Result message from EXU.
    input         in_valid,
    output        in_ready,
    input  [31:0] in_pc,
    input  [31:0] in_inst,
    input  [31:0] in_next_pc,
    input         in_illegal,
    input         in_rd_we,
    input  [ 4:0] in_rd,
    input  [31:0] in_rd_data,
    input         in_csr_we,
    input  [11:0] in_csr_addr,
    input  [31:0] in_csr_data,
    input         in_is_ecall,
    input         in_is_ebreak,
    input  [31:0] in_a0,
    input         in_skip_ref,
    input  [ 9:0] in_perf_class,

    // Next-PC message to the IFU.
    output        pc_valid,
    input         pc_ready,
    output [31:0] pc_data,

    // Architectural write ports.
    output        gpr_wen,
    output [ 4:0] gpr_waddr,
    output [31:0] gpr_wdata,
    output        csr_wen,
    output [11:0] csr_waddr,
    output [31:0] csr_wdata,
    output        csr_ecall,
    output [31:0] csr_mepc_data,
    output [31:0] csr_mcause_data,
    output reg [31:0] arch_pc,

    // Commit observation ports (debug/DPI/perf; no hierarchical pokes).
    output        commit_valid,
    output        retire_illegal,
    output [31:0] retire_pc,
    output [31:0] retire_inst,
    output        retire_ebreak,
    output [31:0] retire_a0,
    output        retire_skip_ref,
    output [ 9:0] retire_perf_class,
    output        retire_pending
);

  // Saved ew message.
  reg [31:0] wb_pc;
  reg [31:0] wb_inst;
  reg [31:0] wb_next_pc;
  reg        wb_illegal;
  reg        wb_rd_we;
  reg [ 4:0] wb_rd;
  reg [31:0] wb_rd_data;
  reg        wb_csr_we;
  reg [11:0] wb_csr_addr;
  reg [31:0] wb_csr_data;
  reg        wb_is_ecall;
  reg        wb_is_ebreak;
  reg [31:0] wb_a0;
  reg        wb_skip_ref;
  reg [ 9:0] wb_perf_class;

  reg full;
  reg halted;

  wire in_fire;
  wire ordinary_commit;
  wire halt_commit;
  wire commit_fire;

  // A halt message is absorbed without waiting for IFU capacity: EBREAK is a
  // legal end of simulation and does not need the next fetch to be ready.
  assign in_ready        = rst_n && !full && !halted;
  assign in_fire         = in_valid && in_ready;
  assign pc_valid        = rst_n && full && !wb_illegal && !wb_is_ebreak;
  assign pc_data         = wb_next_pc;
  assign ordinary_commit = pc_valid && pc_ready;
  assign halt_commit     = rst_n && full && !wb_illegal && wb_is_ebreak;
  assign commit_fire     = ordinary_commit || halt_commit;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      full   <= 1'b0;
      halted <= 1'b0;
    end else if (in_fire) begin
      full <= 1'b1;
    end else if (commit_fire) begin
      full <= 1'b0;
      if (halt_commit) halted <= 1'b1;
    end
  end

  // Payload registers: loaded as one message on in_fire and held until the
  // commit edge.  Illegal messages keep full set; no next PC is issued.
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wb_pc         <= 32'b0;
      wb_inst       <= 32'b0;
      wb_next_pc    <= 32'b0;
      wb_illegal    <= 1'b0;
      wb_rd_we      <= 1'b0;
      wb_rd         <= 5'b0;
      wb_rd_data    <= 32'b0;
      wb_csr_we     <= 1'b0;
      wb_csr_addr   <= 12'b0;
      wb_csr_data   <= 32'b0;
      wb_is_ecall   <= 1'b0;
      wb_is_ebreak  <= 1'b0;
      wb_a0         <= 32'b0;
      wb_skip_ref   <= 1'b0;
      wb_perf_class <= 10'b0;
    end else if (in_fire) begin
      wb_pc         <= in_pc;
      wb_inst       <= in_inst;
      wb_next_pc    <= in_next_pc;
      wb_illegal    <= in_illegal;
      wb_rd_we      <= in_rd_we;
      wb_rd         <= in_rd;
      wb_rd_data    <= in_rd_data;
      wb_csr_we     <= in_csr_we;
      wb_csr_addr   <= in_csr_addr;
      wb_csr_data   <= in_csr_data;
      wb_is_ecall   <= in_is_ecall;
      wb_is_ebreak  <= in_is_ebreak;
      wb_a0         <= in_a0;
      wb_skip_ref   <= in_skip_ref;
      wb_perf_class <= in_perf_class;
    end
  end

  // Architectural write ports: one write per instruction, on commit_fire only.
  assign gpr_wen         = commit_fire && wb_rd_we && (wb_rd != 5'd0);
  assign gpr_waddr       = wb_rd;
  assign gpr_wdata       = wb_rd_data;
  assign csr_wen         = commit_fire && wb_csr_we;
  assign csr_waddr       = wb_csr_addr;
  assign csr_wdata       = wb_csr_data;
  assign csr_ecall       = commit_fire && wb_is_ecall;
  assign csr_mepc_data   = wb_pc;
  assign csr_mcause_data = 32'd11;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) arch_pc <= 32'h80000000;
    else if (commit_fire) arch_pc <= wb_next_pc;
  end

  // Commit observation.  retire_pc/inst describe the message held in WBU;
  // the architectural commit event is commit_valid.
  assign commit_valid      = commit_fire;
  assign retire_illegal    = rst_n && full && wb_illegal;
  assign retire_pc         = wb_pc;
  assign retire_inst       = wb_inst;
  assign retire_ebreak     = wb_is_ebreak;
  assign retire_a0         = wb_a0;
  assign retire_skip_ref   = wb_skip_ref;
  assign retire_perf_class = wb_perf_class;
  assign retire_pending    = rst_n && full;

endmodule
