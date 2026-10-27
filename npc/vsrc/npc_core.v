`ifndef SYNTHESIS
import "DPI-C" function void npc_ebreak(input int halt_code, input int pc);
import "DPI-C" function void npc_reg_write(input int index, input int data);
`ifdef CONFIG_PERF_COUNTERS
import "DPI-C" function void npc_perf_event(input int unsigned event_mask);
`endif
`endif
module npc_core #(
    parameter RANDOM_DELAY = 0,
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
  wire [31:0] pc, ifu_inst;
  wire ifu_valid, lsu_done;
  wire ifu_error, lsu_error, lsu_error_write;
  wire [31:0] ifu_error_addr, lsu_error_addr;
  wire [1:0] ifu_error_resp, lsu_error_resp;
  assign debug_pc = pc;
  assign debug_inst = ifu_inst;
  assign debug_bus_error = ifu_error || lsu_error;
  assign debug_bus_error_addr = ifu_error ? ifu_error_addr : lsu_error_addr;
  assign debug_bus_error_resp = ifu_error ? ifu_error_resp : lsu_error_resp;
  assign debug_bus_error_op = ifu_error ? 2'd0 : (lsu_error_write ? 2'd2 : 2'd1);

  // Completion is sampled by the host before the committing rising edge.
  // Every architectural/DPI write is gated by the same successful commit.
  assign diff_ifu_valid = rst_n && ifu_valid && !debug_bus_error &&
                          (!mem_valid || lsu_done);
  wire commit = diff_ifu_valid && !invalid_inst;
  // Device accesses are decided by the LSU address, like NEMU's mmio skip.
  // exu_result is stable for the whole instruction, so this is valid at commit.
  assign debug_skip_ref = mem_valid &&
                          ((exu_result - PMEM_BASE) >= PMEM_SIZE);
  wire lsu_request = rst_n && ifu_valid && mem_valid && !invalid_inst &&
                     !debug_bus_error;

  // IFU and LSU masters -> round-robin read arbiter -> external AXI.
  // Device address decoding belongs to the platform.
  wire [31:0] ifu_araddr;
  wire [2:0] ifu_arprot;
  wire ifu_arvalid;
  wire ifu_arready;
  wire [31:0] ifu_rdata;
  wire [1:0] ifu_rresp;
  wire ifu_rvalid;
  wire ifu_rready;
  wire [31:0] unused_ifu_awaddr;
  wire [2:0] unused_ifu_awprot;
  wire unused_ifu_awvalid;
  wire [31:0] unused_ifu_wdata;
  wire [3:0] unused_ifu_wstrb;
  wire unused_ifu_wvalid;
  wire unused_ifu_bready;
  wire [31:0] lsu_araddr;
  wire [2:0] lsu_arprot;
  wire lsu_arvalid;
  wire lsu_arready;
  wire [31:0] lsu_rdata;
  wire [1:0] lsu_rresp;
  wire lsu_rvalid;
  wire lsu_rready;
  wire [31:0] lsu_awaddr;
  wire [2:0] lsu_awprot;
  wire lsu_awvalid;
  wire lsu_awready;
  wire [31:0] lsu_wdata;
  wire [3:0] lsu_wstrb;
  wire lsu_wvalid;
  wire lsu_wready;
  wire [1:0] lsu_bresp;
  wire lsu_bvalid;
  wire lsu_bready;
  IFU #(
      .RANDOM_DELAY(RANDOM_DELAY)
  ) ifu1 (
      .clk(clk),
      .rst_n(rst_n),
      .pc(pc),
      .mem_valid(mem_valid),
      .memfinish(commit),
      .inst(ifu_inst),
      .ifu_valid(ifu_valid),
      .ifu_error(ifu_error),
      .ifu_error_resp(ifu_error_resp),
      .ifu_error_addr(ifu_error_addr),
      .m_axi_araddr(ifu_araddr),
      .m_axi_arprot(ifu_arprot),
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

  wire [4:0] rs1;
  wire [4:0] rs2;
  wire [4:0] rd;
  wire [31:0] imm;
  wire [31:0] imm_raw;
  wire [1:0] src_sel;
  wire [3:0] exu_op;
  wire pc_we;
  wire [1:0] pc_wsel;
  wire branch_en;
  wire [2:0] branch_op;
  wire gpr_we;
  wire [2:0] gpr_wsel;
  wire is_ebreak;
  wire is_ecall;
  wire [31:0] mem_rdata;
  wire mem_wen;
  wire [1:0] mem_rbhw;
  wire [1:0] mem_wbhw;
  wire isign;
  wire mem_valid;
  wire csr_we;
  wire [1:0]csr_wsel;
  wire [11:0] csr_wraddr;
  wire [31:0] csr_rdata;
  wire imm2csr;

  wire [31:0] tmp_csr = csr_rdata;

  assign imm = imm2csr ? tmp_csr : imm_raw;//csr指令的立即数语义为csr寄存器的值，而不是指令中的立即数
  wire invalid_inst_idu;
  IDU idu1 (
      .inst(ifu_inst),
      .rs1(rs1),
      .rs2(rs2),
      .rd(rd),
      .imm(imm_raw),
      .invalid_inst(invalid_inst_idu),
      .src_sel(src_sel),
      .exu_op(exu_op),
      .pc_we(pc_we),
      .pc_wsel(pc_wsel),
      .branch_en(branch_en),
      .branch_op(branch_op),
      .gpr_we(gpr_we),
      .mem_we(mem_wen),
      .mem_rbhw(mem_rbhw),
      .mem_wbhw(mem_wbhw),
      .isign(isign),
      .is_ebreak(is_ebreak),
      .mem_valid(mem_valid),
      .gpr_wsel(gpr_wsel),
      .csr_we(csr_we),
      .csr_wsel(csr_wsel),
      .csr_wraddr(csr_wraddr),
      .imm2csr(imm2csr),
      .is_ecall(is_ecall)
  );
  wire [31:0] exu_result;
  wire exu_zero;
  wire exu_signed_lt;
  wire exu_unsigned_lt;
  wire [31:0] Rrs1;
  wire [31:0] Rrs2;
  wire [31:0] gpr_a0;
  EXU exu1 (
      .rs1(Rrs1),
      .rs2(Rrs2),
      .imm(imm),
      .pc(pc),
      .src_sel(src_sel),
      .exu_op(exu_op),
      .result(exu_result),
      .zero(exu_zero),
      .signed_lt(exu_signed_lt),
      .unsigned_lt(exu_unsigned_lt)
  );
  wire [31:0] gpr_wdata;
  wire branch_taken;
  BranchUnit branch_unit1 (
      .branch_en(branch_en),
      .branch_op(branch_op),
      .zero(exu_zero),
      .signed_lt(exu_signed_lt),
      .unsigned_lt(exu_unsigned_lt),
      .branch_taken(branch_taken)
  );
  wire pc_write_en = (pc_we || branch_taken);
  wire invalid_csr_access;
  WBU wbu1 (
      .clk(clk),
      .rst_n(rst_n),
      .pc_we(pc_write_en && commit),
      .diff_ifu_valid(commit),
      .pc_wsel(pc_wsel),
      .exu_result(exu_result),
      .imm(imm),
      .gpr_we(gpr_we && commit),
      .gpr_wsel(gpr_wsel),
      .mem_rdata(mem_rdata),
      .rs1(rs1),
      .rs2(rs2),
      .rd(rd),
      .is_ecall(is_ecall && commit),
      .gpr_rdata1(Rrs1),
      .gpr_rdata2(Rrs2),
      .gpr_a0(gpr_a0),
      .gpr_wdata(gpr_wdata),
      .pc(pc),
      .csr_we(csr_we && commit),
      .csr_wsel(csr_wsel),
      .csr_wraddr(csr_wraddr),
      .csr_rdata1(csr_rdata),
      .invalid_csr_access(invalid_csr_access),
      .dbg_mstatus(debug_mstatus),
      .dbg_mtvec(debug_mtvec),
      .dbg_mepc(debug_mepc),
      .dbg_mcause(debug_mcause),
      .dbg_mcycle(debug_mcycle),
      .dbg_mcycleh(debug_mcycleh),
      .dbg_mvendorid(debug_mvendorid),
      .dbg_marchid(debug_marchid)
  );

  LSU #(
      .RANDOM_DELAY(RANDOM_DELAY),
      .PMEM_BASE(PMEM_BASE),
      .PMEM_SIZE(PMEM_SIZE)
  ) lsu1 (
      .clk(clk),
      .rst_n(rst_n),
      .mem_rbhw(mem_rbhw),
      .mem_addr(exu_result),
      .mem_valid(lsu_request),
      .wen(mem_wen),
      .mem_wbhw(mem_wbhw),
      .mem_wdata_raw(Rrs2),
      .isign(isign),
      .lsu_finish(commit),
      .mem_rdata_r(mem_rdata),
      .lsu_done(lsu_done),
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
  AXIArbiter axi_arbiter1 (
      .clk(clk),
      .rst_n(rst_n),
      .ifu_araddr(ifu_araddr),
      .ifu_arprot(ifu_arprot),
      .ifu_arvalid(ifu_arvalid),
      .ifu_arready(ifu_arready),
      .ifu_rdata(ifu_rdata),
      .ifu_rresp(ifu_rresp),
      .ifu_rvalid(ifu_rvalid),
      .ifu_rready(ifu_rready),
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
  assign invalid_inst = invalid_inst_idu || invalid_csr_access;

`ifdef SYNTHESIS
  wire unused_dpi_debug = &{1'b0, is_ebreak, gpr_a0, gpr_wdata};
`endif
`ifndef SYNTHESIS
  always @(posedge clk) begin
    if (commit && gpr_we) npc_reg_write({27'b0, rd}, gpr_wdata);
    if (commit && is_ebreak) npc_ebreak(gpr_a0, pc);
  end

`ifdef CONFIG_PERF_COUNTERS
  // Simulation-only performance events, sampled once per active rising edge.
  // Completion events count operations; level events count occupied cycles.
  // The host accumulates the mask through DPI-C and prints it in statistic().
  // Bits 5-7 stay clear here: bus faults and invalid decodes abort the host
  // before another clock edge, so the host counts them at detection time.
  localparam [2:0] PERF_GPR_EXU_RESULT = 3'd0;
  localparam [2:0] PERF_GPR_IMMEDIATE  = 3'd2;
  localparam [2:0] PERF_GPR_PC_IMM     = 3'd3;
  localparam [1:0] PERF_PC_DIRECT      = 2'd0;
  localparam [1:0] PERF_PC_TO_MEPC     = 2'd3;
  localparam [1:0] PERF_CSR_EXU_RESULT = 2'd0;

  wire perf_ifu_ar    = ifu_arvalid && ifu_arready;
  wire perf_ifu_fetch = ifu_rvalid && ifu_rready && (ifu_rresp == 2'b00);
  // Cycle-level: no fetched instruction is available (fetch latency/stall).
  wire perf_ifu_idle  = rst_n && !ifu_valid;

  // Partition the fetch phase without reaching into the IFU's private FSM.
  // PREP includes the mandatory request-launch cycle even with RANDOM_DELAY=0.
  // AR acceptance and successful R reception use the existing event bits.
  wire perf_ifu_prep = !ifu_valid && !ifu_arvalid && !ifu_rready && !ifu_error;
  wire perf_ifu_ar_wait = ifu_arvalid && !ifu_arready;
  wire perf_ifu_r_wait = ifu_rready && !ifu_rvalid;
  wire perf_ifu_r_error = ifu_rready && ifu_rvalid && (ifu_rresp != 2'b00);
  wire perf_execute_cycle = ifu_valid;
  wire perf_ifu_hold_lsu = ifu_valid && mem_valid;
  // CPU request-valid until result-ready: include the acceptance cycle,
  // exclude the DONE cycle. This is the CPU-visible waiting time.
  // Counts the complete CPU access, including both beats of a split access.
  wire perf_lsu_wait = lsu_request && !lsu_done;

  wire perf_lsu_load  = lsu_done && !lsu_error_write;
  wire perf_lsu_store = lsu_done && lsu_error_write;

  wire perf_alu    = commit && gpr_we && (gpr_wsel == PERF_GPR_EXU_RESULT);
  wire perf_load   = commit && mem_valid && !mem_wen;
  wire perf_store  = commit && mem_valid && mem_wen;
  wire perf_branch = commit && branch_en;
  wire perf_jump   = commit && pc_we && (pc_wsel == PERF_PC_DIRECT);
  wire perf_csr    = commit && csr_we;
  wire perf_system = commit && (is_ecall || is_ebreak ||
                                (pc_we && (pc_wsel == PERF_PC_TO_MEPC)));
  wire perf_lui    = commit && gpr_we &&
                     (gpr_wsel == PERF_GPR_IMMEDIATE) && !csr_we;
  wire perf_auipc  = commit && gpr_we && (gpr_wsel == PERF_GPR_PC_IMM);
  // Instructions that actually consume an EXU result: ALU, address
  // generation, comparison, pc+imm, and the csrrs read-modify-write.
  wire perf_exu    = perf_alu || perf_load || perf_store || perf_branch ||
                     perf_jump || perf_auipc ||
                     (commit && csr_we && (csr_wsel == PERF_CSR_EXU_RESULT));

  wire [31:0] perf_events = {
      4'b0,
      perf_ifu_hold_lsu, // 27: executing a memory instruction (including DONE)
      perf_ifu_r_error,  // 26: consumed an unsuccessful fetch response
      ifu_error,        // 25: sticky fetch-fault hold
      perf_lsu_wait,    // 24: CPU-visible memory latency
      perf_execute_cycle, // 23: fetched instruction occupies the backend
      perf_ifu_r_wait,  // 22: expecting R but no response is valid
      perf_ifu_ar_wait, // 21: offering AR but address not accepted
      perf_ifu_prep,    // 20: request preparation / artificial launch delay
      1'b1,            // 19: every non-reset cycle
      perf_exu,        // 18
      perf_auipc,      // 17
      perf_lui,        // 16
      perf_system,     // 15
      perf_csr,        // 14
      perf_jump,       // 13
      perf_branch,     // 12
      perf_store,      // 11
      perf_load,       // 10
      perf_alu,        // 9
      commit,          // 8
      1'b0,            // 7 invalid instruction (host)
      1'b0,            // 6 fetch bus fault (host)
      1'b0,            // 5 data bus fault (host)
      perf_lsu_store,  // 4
      perf_lsu_load,   // 3
      perf_ifu_idle,   // 2
      perf_ifu_fetch,  // 1
      perf_ifu_ar      // 0
  };

  always @(posedge clk) begin
    if (rst_n && (|perf_events)) npc_perf_event(perf_events);
  end
`endif
`endif
endmodule
