`ifndef SYNTHESIS
import "DPI-C" function void npc_ebreak(input int halt_code, input int pc);
import "DPI-C" function void npc_reg_write(input int index, input int data);
`ifdef CONFIG_PERF_COUNTERS
import "DPI-C" function void npc_perf_event(input int unsigned event_mask);
`endif
`endif
module npc_core #(
    parameter RANDOM_DELAY = 0,
    parameter integer ICACHE_LINES = 16,
    parameter integer ICACHE_BLOCK_BYTES = 4,
    parameter [31:0] PMEM_BASE = 32'h80000000,
    parameter [31:0] PMEM_SIZE = 32'h08000000
) (
    input clk,
    input rst_n,
    output invalid_inst,
    output diff_ifu_valid,
    output [31:0] debug_pc,
    output [31:0] debug_inst,
    output debug_bus_error,
    output [31:0] debug_bus_error_addr,
    output [1:0] debug_bus_error_resp,
    output [1:0] debug_bus_error_op, // 0: fetch, 1: load, 2: store
    output [31:0] debug_mstatus,
    output [31:0] debug_mtvec,
    output [31:0] debug_mepc,
    output [31:0] debug_mcause,
    output [31:0] debug_mcycle,
    output [31:0] debug_mcycleh,
    output [31:0] debug_mvendorid,
    output [31:0] debug_marchid,
    // Committing instruction accesses a device (not SRAM): host must not
    // replay it on the difftest reference, only copy the DUT state over.
    output debug_skip_ref,

    // External AXI4-Lite master interface (CPU -> platform interconnect).
    output [31:0] m_axi_araddr,
    output [2:0]  m_axi_arprot,
    output        m_axi_arvalid,
    input         m_axi_arready,
    input  [31:0] m_axi_rdata,
    input  [1:0]  m_axi_rresp,
    input         m_axi_rvalid,
    output        m_axi_rready,
    output [31:0] m_axi_awaddr,
    output [2:0]  m_axi_awprot,
    output        m_axi_awvalid,
    input         m_axi_awready,
    output [31:0] m_axi_wdata,
    output [3:0]  m_axi_wstrb,
    output        m_axi_wvalid,
    input         m_axi_wready,
    input  [1:0]  m_axi_bresp,
    input         m_axi_bvalid,
    output        m_axi_bready
);
  // ===========================================================================
  // Stage-to-stage messages.  Each valid/payload has exactly one producer;
  // each ready has exactly one consumer.
  // ===========================================================================
  // IFU -> IDU.
  wire        fi_valid;
  wire        fi_ready;
  wire [31:0] fi_pc;
  wire [31:0] fi_inst;

  // IFU sticky fault.
  wire        ifu_error;
  wire [1:0]  ifu_error_resp;
  wire [31:0] ifu_error_addr;

  // IDU -> EXU (de = decode).
  wire        de_valid;
  wire        de_ready;
  wire [31:0] de_pc;
  wire [31:0] de_inst;
  wire        de_illegal;
  wire [ 4:0] de_rd;
  wire [ 4:0] de_rs1;
  wire [ 4:0] de_rs2;
  wire [31:0] de_rs1_value;
  wire [31:0] de_rs2_value;
  wire [31:0] de_a0;
  wire [31:0] de_imm;
  wire [31:0] de_csr_old;
  wire [31:0] de_mtvec;
  wire [ 1:0] de_src_sel;
  wire [ 3:0] de_exu_op;
  wire        de_pc_we;
  wire [ 1:0] de_pc_wsel;
  wire        de_branch_en;
  wire [ 2:0] de_branch_op;
  wire        de_gpr_we;
  wire [ 2:0] de_gpr_wsel;
  wire        de_mem_valid;
  wire        de_mem_wen;
  wire [ 1:0] de_mem_rbhw;
  wire [ 1:0] de_mem_wbhw;
  wire        de_isign;
  wire        de_csr_we;
  wire [ 1:0] de_csr_wsel;
  wire [11:0] de_csr_addr;
  wire        de_imm2csr;
  wire        de_is_ecall;
  wire        de_is_ebreak;

  // GPR/CSR read ports driven by the IDU stage.
  wire [ 4:0] gpr_raddr1;
  wire [ 4:0] gpr_raddr2;
  wire [31:0] gpr_rdata1;
  wire [31:0] gpr_rdata2;
  wire [31:0] gpr_a0;
  wire [11:0] csr_raddr1;
  wire [31:0] csr_rdata1;
  wire [31:0] csr_mtvec;
  wire        csr_invalid_addr;

  // Commit write ports driven by WBU into the register files.
  wire        gpr_wen;
  wire [ 4:0] gpr_waddr;
  wire [31:0] gpr_wdata;
  wire        csr_wen;
  wire [11:0] csr_waddr;
  wire [31:0] csr_wdata;
  wire        csr_ecall;
  wire [31:0] csr_mepc_data;
  wire [31:0] csr_mcause_data;

  // EXU -> WBU (ew = execute/write-back).
  wire        ew_valid;
  wire        ew_ready;
  wire [31:0] ew_pc;
  wire [31:0] ew_inst;
  wire [31:0] ew_next_pc;
  wire        ew_illegal;
  wire        ew_rd_we;
  wire [ 4:0] ew_rd;
  wire [31:0] ew_rd_data;
  wire        ew_csr_we;
  wire [11:0] ew_csr_addr;
  wire [31:0] ew_csr_data;
  wire        ew_is_ecall;
  wire        ew_is_ebreak;
  wire [31:0] ew_a0;
  wire        ew_skip_ref;
  wire [ 9:0] ew_perf_class;

  // WBU -> IFU next-PC message.
  wire        pc_valid;
  wire        pc_ready;
  wire [31:0] pc_data;

  // Architectural PC and commit observation ports.
  wire [31:0] arch_pc;
  wire        commit_valid;
  wire        retire_illegal;
  wire [31:0] retire_pc;
  wire [31:0] retire_inst;
  wire        retire_ebreak;
  wire [31:0] retire_a0;
  wire        retire_skip_ref;
  wire [ 9:0] retire_perf_class;
  wire        retire_pending;

  // EXU <-> LSU request/response.
  wire        req_valid;
  wire        req_ready;
  wire [31:0] req_addr;
  wire        req_write;
  wire [ 1:0] req_rsize;
  wire [ 1:0] req_wsize;
  wire [31:0] req_wdata;
  wire        req_sign;
  wire        rsp_valid;
  wire        rsp_ready;
  wire [31:0] rsp_rdata;

  // LSU fault.
  wire        lsu_error;
  wire        lsu_error_write;
  wire [31:0] lsu_error_addr;
  wire [1:0]  lsu_error_resp;

  // Read-only stage-state observations used by performance counters.
  wire        ifu_dbg_wait_pc;
  wire        exu_dbg_busy;
  wire        exu_dbg_mem_wait;
  wire        exu_dbg_wait_wb;

  // ===========================================================================
  // Host observation boundary.
  // ===========================================================================
  assign debug_bus_error = ifu_error || lsu_error;
  assign debug_bus_error_addr = ifu_error ? ifu_error_addr : lsu_error_addr;
  assign debug_bus_error_resp = ifu_error ? ifu_error_resp : lsu_error_resp;
  assign debug_bus_error_op = ifu_error ? 2'd0 : (lsu_error_write ? 2'd2 : 2'd1);

  // The host samples PC/inst before the commit edge and reads PC again after
  // it.  arch_pc is the only architectural PC and moves exactly on commit.
  // Illegal instructions never commit, but must still be reported to the host;
  // otherwise the host would never take its invalid-instruction branch.
  assign diff_ifu_valid = !debug_bus_error && (commit_valid || retire_illegal);
  assign invalid_inst = retire_illegal;
  assign debug_pc = arch_pc;
  assign debug_inst = retire_inst;
  assign debug_skip_ref = commit_valid && retire_skip_ref;

  // ===========================================================================
  // IFU -> I-cache -> AXIArbiter; LSU remains a separate read/write master.
  // ===========================================================================
  wire [31:0] ifu_araddr;
  wire [2:0]  unused_ifu_arprot;
  wire        ifu_arvalid;
  wire        ifu_arready;
  wire [31:0] ifu_rdata;
  wire [1:0]  ifu_rresp;
  wire        ifu_rvalid;
  wire        ifu_rready;
  wire [31:0] unused_ifu_awaddr;
  wire [2:0]  unused_ifu_awprot;
  wire        unused_ifu_awvalid;
  wire [31:0] unused_ifu_wdata;
  wire [3:0]  unused_ifu_wstrb;
  wire        unused_ifu_wvalid;
  wire        unused_ifu_bready;

  wire [31:0] icache_araddr;
  wire [2:0]  icache_arprot;
  wire        icache_arvalid;
  wire        icache_arready;
  wire [31:0] icache_rdata;
  wire [1:0]  icache_rresp;
  wire        icache_rvalid;
  wire        icache_rready;
  wire [31:0] unused_icache_awaddr;
  wire [2:0]  unused_icache_awprot;
  wire        unused_icache_awvalid;
  wire [31:0] unused_icache_wdata;
  wire [3:0]  unused_icache_wstrb;
  wire        unused_icache_wvalid;
  wire        unused_icache_bready;

  wire [31:0] lsu_araddr;
  wire [2:0]  lsu_arprot;
  wire        lsu_arvalid;
  wire        lsu_arready;
  wire [31:0] lsu_rdata;
  wire [1:0]  lsu_rresp;
  wire        lsu_rvalid;
  wire        lsu_rready;
  wire [31:0] lsu_awaddr;
  wire [2:0]  lsu_awprot;
  wire        lsu_awvalid;
  wire        lsu_awready;
  wire [31:0] lsu_wdata;
  wire [3:0]  lsu_wstrb;
  wire        lsu_wvalid;
  wire        lsu_wready;
  wire [1:0]  lsu_bresp;
  wire        lsu_bvalid;
  wire        lsu_bready;

  // ===========================================================================
  // IFU: message-based fetch engine.
  // ===========================================================================
  IFU ifu1 (
      .clk(clk),
      .rst_n(rst_n),
      .pc_valid(pc_valid),
      .pc_ready(pc_ready),
      .pc_data(pc_data),
      .out_valid(fi_valid),
      .out_ready(fi_ready),
      .out_pc(fi_pc),
      .out_inst(fi_inst),
      .dbg_wait_pc(ifu_dbg_wait_pc),
      .ifu_error(ifu_error),
      .ifu_error_resp(ifu_error_resp),
      .ifu_error_addr(ifu_error_addr),
      .m_axi_araddr(ifu_araddr),
      .m_axi_arprot(unused_ifu_arprot),
      .m_axi_arvalid(ifu_arvalid),
      .m_axi_arready(ifu_arready),
      .m_axi_rdata(ifu_rdata),
      .m_axi_rresp(ifu_rresp),
      .m_axi_rvalid(ifu_rvalid),
      .m_axi_rready(ifu_rready),
      .m_axi_awaddr(unused_ifu_awaddr),
      .m_axi_awprot(unused_ifu_awprot),
      .m_axi_awvalid(unused_ifu_awvalid),
      .m_axi_awready(1'b0),
      .m_axi_wdata(unused_ifu_wdata),
      .m_axi_wstrb(unused_ifu_wstrb),
      .m_axi_wvalid(unused_ifu_wvalid),
      .m_axi_wready(1'b0),
      .m_axi_bresp(2'b0),
      .m_axi_bvalid(1'b0),
      .m_axi_bready(unused_ifu_bready)
  );

  // IFU's read-only AR/R handshakes map to the cache's PC/instruction ports.
  // Both modules use the fixed instruction attribute ARPROT=3'b101.
  // Cache hits are answered locally; only misses reach the read arbiter.
  icache #(
      .LINE_COUNT(ICACHE_LINES),
      .BLOCK_BYTES(ICACHE_BLOCK_BYTES)
  ) icache1 (
      .clk(clk),
      .rst_n(rst_n),
      .if_pc_valid(ifu_arvalid),
      .if_pc_ready(ifu_arready),
      .if_pc(ifu_araddr),
      .if_inst(ifu_rdata),
      .if_inst_resp(ifu_rresp),
      .if_inst_valid(ifu_rvalid),
      .if_inst_ready(ifu_rready),
      .m_axi_araddr(icache_araddr),
      .m_axi_arprot(icache_arprot),
      .m_axi_arvalid(icache_arvalid),
      .m_axi_arready(icache_arready),
      .m_axi_rdata(icache_rdata),
      .m_axi_rresp(icache_rresp),
      .m_axi_rvalid(icache_rvalid),
      .m_axi_rready(icache_rready),
      .m_axi_awaddr(unused_icache_awaddr),
      .m_axi_awprot(unused_icache_awprot),
      .m_axi_awvalid(unused_icache_awvalid),
      .m_axi_awready(1'b0),
      .m_axi_wdata(unused_icache_wdata),
      .m_axi_wstrb(unused_icache_wstrb),
      .m_axi_wvalid(unused_icache_wvalid),
      .m_axi_wready(1'b0),
      .m_axi_bresp(2'b0),
      .m_axi_bvalid(1'b0),
      .m_axi_bready(unused_icache_bready)
  );

  // ===========================================================================
  // IDU stage: original IDU wrapped in a one-entry message slot, plus the
  // combinational register-file read ports.
  // ===========================================================================
  idu_stage idu_stage1 (
      .clk(clk),
      .rst_n(rst_n),
      .in_valid(fi_valid),
      .in_ready(fi_ready),
      .in_pc(fi_pc),
      .in_inst(fi_inst),
      .out_valid(de_valid),
      .out_ready(de_ready),
      .out_pc(de_pc),
      .out_inst(de_inst),
      .out_illegal(de_illegal),
      .out_rd(de_rd),
      .out_rs1(de_rs1),
      .out_rs2(de_rs2),
      .out_rs1_value(de_rs1_value),
      .out_rs2_value(de_rs2_value),
      .out_imm(de_imm),
      .out_csr_old(de_csr_old),
      .out_mtvec(de_mtvec),
      .out_a0(de_a0),
      .out_src_sel(de_src_sel),
      .out_exu_op(de_exu_op),
      .out_pc_we(de_pc_we),
      .out_pc_wsel(de_pc_wsel),
      .out_branch_en(de_branch_en),
      .out_branch_op(de_branch_op),
      .out_gpr_we(de_gpr_we),
      .out_gpr_wsel(de_gpr_wsel),
      .out_mem_valid(de_mem_valid),
      .out_mem_wen(de_mem_wen),
      .out_mem_rbhw(de_mem_rbhw),
      .out_mem_wbhw(de_mem_wbhw),
      .out_isign(de_isign),
      .out_csr_we(de_csr_we),
      .out_csr_wsel(de_csr_wsel),
      .out_csr_addr(de_csr_addr),
      .out_imm2csr(de_imm2csr),
      .out_is_ecall(de_is_ecall),
      .out_is_ebreak(de_is_ebreak),
      .gpr_raddr1(gpr_raddr1),
      .gpr_raddr2(gpr_raddr2),
      .gpr_rdata1(gpr_rdata1),
      .gpr_rdata2(gpr_rdata2),
      .gpr_a0(gpr_a0),
      .csr_raddr1(csr_raddr1),
      .csr_rdata1(csr_rdata1),
      .csr_mtvec(csr_mtvec),
      .csr_invalid_addr(csr_invalid_addr)
  );

  // ===========================================================================
  // Architecture register files (moved out of WBU).
  // ===========================================================================
  GPR gpr1 (
      .clk(clk),
      .rst_n(rst_n),
      .wdata(gpr_wdata),
      .waddr(gpr_waddr),
      .wen(gpr_wen),
      .raddr1(gpr_raddr1),
      .raddr2(gpr_raddr2),
      .rdata1(gpr_rdata1),
      .rdata2(gpr_rdata2),
      .rdata_a0(gpr_a0)
  );

  CSR csr1 (
      .clk(clk),
      .rst_n(rst_n),
      .wdata(csr_wdata),
      .waddr(csr_waddr),
      .wen(csr_wen),
      .raddr1(csr_raddr1),
      .rdata1(csr_rdata1),
      .is_ecall(csr_ecall),
      .mepc_data(csr_mepc_data),
      .mcause_data(csr_mcause_data),
      .mtvec_data(csr_mtvec),
      .invalid_csr_access(csr_invalid_addr),
      .dbg_mstatus(debug_mstatus),
      .dbg_mtvec(debug_mtvec),
      .dbg_mepc(debug_mepc),
      .dbg_mcause(debug_mcause),
      .dbg_mcycle(debug_mcycle),
      .dbg_mcycleh(debug_mcycleh),
      .dbg_mvendorid(debug_mvendorid),
      .dbg_marchid(debug_marchid)
  );

  // ===========================================================================
  // EXU stage: snapshot, ALU/branch, optional LSU request, result selection.
  // ===========================================================================
  exu_stage #(
      .PMEM_BASE(PMEM_BASE),
      .PMEM_SIZE(PMEM_SIZE)
  ) exu_stage1 (
      .clk(clk),
      .rst_n(rst_n),
      .in_valid(de_valid),
      .in_ready(de_ready),
      .in_pc(de_pc),
      .in_inst(de_inst),
      .in_illegal(de_illegal),
      .in_rd(de_rd),
      .in_rs1_value(de_rs1_value),
      .in_rs2_value(de_rs2_value),
      .in_imm(de_imm),
      .in_csr_old(de_csr_old),
      .in_mtvec(de_mtvec),
      .in_a0(de_a0),
      .in_src_sel(de_src_sel),
      .in_exu_op(de_exu_op),
      .in_pc_we(de_pc_we),
      .in_pc_wsel(de_pc_wsel),
      .in_branch_en(de_branch_en),
      .in_branch_op(de_branch_op),
      .in_gpr_we(de_gpr_we),
      .in_gpr_wsel(de_gpr_wsel),
      .in_mem_valid(de_mem_valid),
      .in_mem_wen(de_mem_wen),
      .in_mem_rbhw(de_mem_rbhw),
      .in_mem_wbhw(de_mem_wbhw),
      .in_isign(de_isign),
      .in_csr_we(de_csr_we),
      .in_csr_wsel(de_csr_wsel),
      .in_csr_addr(de_csr_addr),
      .in_imm2csr(de_imm2csr),
      .in_is_ecall(de_is_ecall),
      .in_is_ebreak(de_is_ebreak),
      .out_valid(ew_valid),
      .out_ready(ew_ready),
      .out_pc(ew_pc),
      .out_inst(ew_inst),
      .out_next_pc(ew_next_pc),
      .out_illegal(ew_illegal),
      .out_rd_we(ew_rd_we),
      .out_rd(ew_rd),
      .out_rd_data(ew_rd_data),
      .out_csr_we(ew_csr_we),
      .out_csr_addr(ew_csr_addr),
      .out_csr_data(ew_csr_data),
      .out_is_ecall(ew_is_ecall),
      .out_is_ebreak(ew_is_ebreak),
      .out_a0(ew_a0),
      .out_skip_ref(ew_skip_ref),
      .out_perf_class(ew_perf_class),
      .dbg_busy(exu_dbg_busy),
      .dbg_mem_wait(exu_dbg_mem_wait),
      .dbg_wait_wb(exu_dbg_wait_wb),
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

  // ===========================================================================
  // WBU: commit stage.  Consumes the ew message, issues the next-PC message
  // and drives the architectural write ports exactly once per instruction.
  // ===========================================================================
  WBU wbu1 (
      .clk(clk),
      .rst_n(rst_n),
      .in_valid(ew_valid),
      .in_ready(ew_ready),
      .in_pc(ew_pc),
      .in_inst(ew_inst),
      .in_next_pc(ew_next_pc),
      .in_illegal(ew_illegal),
      .in_rd_we(ew_rd_we),
      .in_rd(ew_rd),
      .in_rd_data(ew_rd_data),
      .in_csr_we(ew_csr_we),
      .in_csr_addr(ew_csr_addr),
      .in_csr_data(ew_csr_data),
      .in_is_ecall(ew_is_ecall),
      .in_is_ebreak(ew_is_ebreak),
      .in_a0(ew_a0),
      .in_skip_ref(ew_skip_ref),
      .in_perf_class(ew_perf_class),
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

  // ===========================================================================
  // LSU.
  // ===========================================================================
  LSU #(
      .RANDOM_DELAY(RANDOM_DELAY),
      .PMEM_BASE(PMEM_BASE),
      .PMEM_SIZE(PMEM_SIZE)
  ) lsu1 (
      .clk(clk),
      .rst_n(rst_n),
      .req_rsize(req_rsize),
      .req_addr(req_addr),
      .req_valid(req_valid),
      .req_ready(req_ready),
      .req_write(req_write),
      .req_wsize(req_wsize),
      .req_wdata(req_wdata),
      .req_sign(req_sign),
      .rsp_ready(rsp_ready),
      .rsp_rdata(rsp_rdata),
      .rsp_valid(rsp_valid),
      .lsu_error(lsu_error),
      .lsu_error_resp(lsu_error_resp),
      .lsu_error_addr(lsu_error_addr),
      .lsu_error_write(lsu_error_write),
      .m_axi_araddr(lsu_araddr),
      .m_axi_arprot(lsu_arprot),
      .m_axi_arvalid(lsu_arvalid),
      .m_axi_arready(lsu_arready),
      .m_axi_rdata(lsu_rdata),
      .m_axi_rresp(lsu_rresp),
      .m_axi_rvalid(lsu_rvalid),
      .m_axi_rready(lsu_rready),
      .m_axi_awaddr(lsu_awaddr),
      .m_axi_awprot(lsu_awprot),
      .m_axi_awvalid(lsu_awvalid),
      .m_axi_awready(lsu_awready),
      .m_axi_wdata(lsu_wdata),
      .m_axi_wstrb(lsu_wstrb),
      .m_axi_wvalid(lsu_wvalid),
      .m_axi_wready(lsu_wready),
      .m_axi_bresp(lsu_bresp),
      .m_axi_bvalid(lsu_bvalid),
      .m_axi_bready(lsu_bready)
  );

  // ===========================================================================
  // Read arbiter: I-cache misses and LSU share the external read channel.
  // ===========================================================================
  AXIArbiter axi_arbiter1 (
      .clk(clk),
      .rst_n(rst_n),
      .ifu_araddr(icache_araddr),
      .ifu_arprot(icache_arprot),
      .ifu_arvalid(icache_arvalid),
      .ifu_arready(icache_arready),
      .ifu_rdata(icache_rdata),
      .ifu_rresp(icache_rresp),
      .ifu_rvalid(icache_rvalid),
      .ifu_rready(icache_rready),
      .lsu_araddr(lsu_araddr),
      .lsu_arprot(lsu_arprot),
      .lsu_arvalid(lsu_arvalid),
      .lsu_arready(lsu_arready),
      .lsu_rdata(lsu_rdata),
      .lsu_rresp(lsu_rresp),
      .lsu_rvalid(lsu_rvalid),
      .lsu_rready(lsu_rready),
      .lsu_awaddr(lsu_awaddr),
      .lsu_awprot(lsu_awprot),
      .lsu_awvalid(lsu_awvalid),
      .lsu_awready(lsu_awready),
      .lsu_wdata(lsu_wdata),
      .lsu_wstrb(lsu_wstrb),
      .lsu_wvalid(lsu_wvalid),
      .lsu_wready(lsu_wready),
      .lsu_bresp(lsu_bresp),
      .lsu_bvalid(lsu_bvalid),
      .lsu_bready(lsu_bready),
      .m_axi_araddr(m_axi_araddr),
      .m_axi_arprot(m_axi_arprot),
      .m_axi_arvalid(m_axi_arvalid),
      .m_axi_arready(m_axi_arready),
      .m_axi_rdata(m_axi_rdata),
      .m_axi_rresp(m_axi_rresp),
      .m_axi_rvalid(m_axi_rvalid),
      .m_axi_rready(m_axi_rready),
      .m_axi_awaddr(m_axi_awaddr),
      .m_axi_awprot(m_axi_awprot),
      .m_axi_awvalid(m_axi_awvalid),
      .m_axi_awready(m_axi_awready),
      .m_axi_wdata(m_axi_wdata),
      .m_axi_wstrb(m_axi_wstrb),
      .m_axi_wvalid(m_axi_wvalid),
      .m_axi_wready(m_axi_wready),
      .m_axi_bresp(m_axi_bresp),
      .m_axi_bvalid(m_axi_bvalid),
      .m_axi_bready(m_axi_bready)
  );

`ifdef SYNTHESIS
  wire unused_synth = &{1'b0, de_rs1, de_rs2, ew_perf_class, retire_perf_class,
                        retire_pc, retire_a0, retire_ebreak, retire_pending,
                        ifu_dbg_wait_pc, exu_dbg_busy, exu_dbg_mem_wait,
                        exu_dbg_wait_wb};
`endif
`ifndef SYNTHESIS
  // rs1/rs2 indexes travel with the decode message for tracing; the operands
  // themselves are already latched as de_rs1_value/de_rs2_value.
  wire unused_nc = &{1'b0, de_rs1, de_rs2, retire_perf_class, retire_pending,
                     ifu_dbg_wait_pc, exu_dbg_busy, exu_dbg_mem_wait,
                     exu_dbg_wait_wb};

  // Message-stability checkers: observation only, never functional control.
  // Payloads follow the channel field order of the guide (de = 304 bits,
  // ew = 225 bits); control fields are included on purpose.
  wire [ 63:0] fi_msg = {fi_pc, fi_inst};
  wire [303:0] de_msg = {de_pc, de_inst, de_illegal, de_rd,
                         de_rs1_value, de_rs2_value, de_imm, de_csr_old,
                         de_mtvec, de_a0, de_src_sel, de_exu_op,
                         de_pc_we, de_pc_wsel, de_branch_en, de_branch_op,
                         de_gpr_we, de_gpr_wsel, de_mem_valid, de_mem_wen,
                         de_mem_rbhw, de_mem_wbhw, de_isign,
                         de_csr_we, de_csr_wsel, de_csr_addr,
                         de_imm2csr, de_is_ecall, de_is_ebreak};
  wire [224:0] ew_msg = {ew_pc, ew_inst, ew_next_pc, ew_illegal,
                         ew_rd_we, ew_rd, ew_rd_data,
                         ew_csr_we, ew_csr_addr, ew_csr_data,
                         ew_is_ecall, ew_is_ebreak, ew_a0,
                         ew_skip_ref, ew_perf_class};

  rv_stability_check #(.W(64)) fi_stability (
      .clk(clk),
      .rst_n(rst_n),
      .valid(fi_valid),
      .ready(fi_ready),
      .payload(fi_msg)
  );
  rv_stability_check #(.W(304)) de_stability (
      .clk(clk),
      .rst_n(rst_n),
      .valid(de_valid),
      .ready(de_ready),
      .payload(de_msg)
  );
  rv_stability_check #(.W(225)) ew_stability (
      .clk(clk),
      .rst_n(rst_n),
      .valid(ew_valid),
      .ready(ew_ready),
      .payload(ew_msg)
  );

  always @(posedge clk) begin
    if (gpr_wen) npc_reg_write({27'b0, gpr_waddr}, gpr_wdata);
    if (commit_valid && retire_ebreak) npc_ebreak(retire_a0, retire_pc);
  end

`ifdef CONFIG_PERF_COUNTERS
  // Simulation-only performance events, sampled once per active rising edge.
  // Instruction classification travels with the committed message, so it is
  // no longer recomputed from live decode outputs.
  // IFU AR/R count logical cache requests/responses, including cache hits.
  // The response wait includes cache lookup, arbitration and memory latency.
  wire perf_ifu_ar      = ifu_arvalid && ifu_arready;
  wire perf_ifu_fetch   = ifu_rvalid && ifu_rready && (ifu_rresp == 2'b00);
  wire perf_ifu_r_error = ifu_rready && ifu_rvalid && (ifu_rresp != 2'b00);
  wire perf_ifu_deliver = fi_valid && fi_ready;

  // Frontend: the IFU is in exactly one state each cycle, so these levels
  // plus perf_ifu_deliver partition all active cycles.
  wire perf_ifu_wait_pc = ifu_dbg_wait_pc;
  wire perf_ifu_ar_wait = ifu_arvalid && !ifu_arready;
  wire perf_ifu_r_wait  = ifu_rready && !ifu_rvalid;
  wire perf_id_hold     = fi_valid && !fi_ready;
  wire perf_ifu_fault   = ifu_error;

  // Backend: an instruction lives in IDU, EXU or WBU.
  wire perf_execute_cycle = de_valid || exu_dbg_busy || retire_pending;
  wire perf_backend_idle  = !perf_execute_cycle;

  // Explicit wait states replacing the old prepare/execute/lsu_hold
  // meanings of the previous architecture.
  wire perf_lsu_wait    = exu_dbg_mem_wait;
  wire perf_wb_wait_pc  = pc_valid && !pc_ready;
  wire perf_exu_wait_wb = exu_dbg_wait_wb;

  // The request direction must survive until the response retires.
  reg perf_req_write_q;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) perf_req_write_q <= 1'b0;
    else if (req_valid && req_ready) perf_req_write_q <= req_write;
  end

  wire perf_lsu_rsp   = rsp_valid && rsp_ready;
  wire perf_lsu_load  = perf_lsu_rsp && !perf_req_write_q;
  wire perf_lsu_store = perf_lsu_rsp && perf_req_write_q;

  wire perf_alu    = commit_valid && retire_perf_class[0];
  wire perf_load   = commit_valid && retire_perf_class[1];
  wire perf_store  = commit_valid && retire_perf_class[2];
  wire perf_branch = commit_valid && retire_perf_class[3];
  wire perf_jump   = commit_valid && retire_perf_class[4];
  wire perf_csr    = commit_valid && retire_perf_class[5];
  wire perf_system = commit_valid && retire_perf_class[6];
  wire perf_lui    = commit_valid && retire_perf_class[7];
  wire perf_auipc  = commit_valid && retire_perf_class[8];
  wire perf_exu    = commit_valid && retire_perf_class[9];

  wire [31:0] perf_events = {
      1'b0,               // 31 reserved
      perf_ifu_deliver,   // 30: IFU message accepted by IDU
      perf_exu_wait_wb,   // 29: result ready, WBU not accepting
      perf_id_hold,       // 28: IFU offering, IDU/EXU not accepting
      perf_wb_wait_pc,    // 27: WBU full, IFU cannot take the next PC
      perf_ifu_r_error,   // 26: consumed an unsuccessful fetch response
      perf_ifu_fault,     // 25: sticky fetch-fault hold
      perf_lsu_wait,      // 24: EXU waiting for LSU accept/response
      perf_execute_cycle, // 23: backend occupied
      perf_ifu_r_wait,    // 22: expecting R but no response is valid
      perf_ifu_ar_wait,   // 21: offering AR but address not accepted
      perf_ifu_wait_pc,   // 20: waiting for the next-PC message
      1'b1,               // 19: every non-reset cycle
      perf_exu,           // 18
      perf_auipc,         // 17
      perf_lui,           // 16
      perf_system,        // 15
      perf_csr,           // 14
      perf_jump,          // 13
      perf_branch,        // 12
      perf_store,         // 11
      perf_load,          // 10
      perf_alu,           // 9
      commit_valid,       // 8
      1'b0,               // 7 invalid instruction (host)
      1'b0,               // 6 fetch bus fault (host)
      1'b0,               // 5 data bus fault (host)
      perf_lsu_store,     // 4
      perf_lsu_load,      // 3
      perf_backend_idle,  // 2
      perf_ifu_fetch,     // 1
      perf_ifu_ar         // 0
  };

  always @(posedge clk) begin
    if (rst_n && (|perf_events)) npc_perf_event(perf_events);
  end
`endif
`endif
endmodule
