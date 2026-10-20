`ifndef SYNTHESIS
import "DPI-C" function void npc_ebreak(input int halt_code, input int pc);
import "DPI-C" function void npc_reg_write(input int index, input int data);
`endif
module top #(
    parameter RANDOM_DELAY = 1,
    parameter [31:0] PMEM_BASE = 32'h80000000,
    parameter [31:0] PMEM_SIZE = 32'h08000000,
    parameter HAS_SERIAL = 1,
    parameter HAS_TIMER = 1,
    parameter [31:0] SERIAL_MMIO = 32'h10000000,
    parameter [31:0] RTC_MMIO = 32'h10000048
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
    // UART transmit byte stream (one-cycle tx_valid pulse per byte).
    output uart_tx_valid,
    output [7:0] uart_tx_data
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

  // IFU and LSU masters -> round-robin read arbiter -> XBAR -> device slaves.
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
  // Arbiter -> XBAR upstream bus.
  wire [31:0] axi_araddr;
  wire [2:0] axi_arprot;
  wire axi_arvalid;
  wire axi_arready;
  wire [31:0] axi_rdata;
  wire [1:0] axi_rresp;
  wire axi_rvalid;
  wire axi_rready;
  wire [31:0] axi_awaddr;
  wire [2:0] axi_awprot;
  wire axi_awvalid;
  wire axi_awready;
  wire [31:0] axi_wdata;
  wire [3:0] axi_wstrb;
  wire axi_wvalid;
  wire axi_wready;
  wire [1:0] axi_bresp;
  wire axi_bvalid;
  wire axi_bready;

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
      .m_axi_araddr(axi_araddr),
      .m_axi_arprot(axi_arprot),
      .m_axi_arvalid(axi_arvalid),
      .m_axi_arready(axi_arready),
      .m_axi_rdata(axi_rdata),
      .m_axi_rresp(axi_rresp),
      .m_axi_rvalid(axi_rvalid),
      .m_axi_rready(axi_rready),
      .m_axi_awaddr(axi_awaddr),
      .m_axi_awprot(axi_awprot),
      .m_axi_awvalid(axi_awvalid),
      .m_axi_awready(axi_awready),
      .m_axi_wdata(axi_wdata),
      .m_axi_wstrb(axi_wstrb),
      .m_axi_wvalid(axi_wvalid),
      .m_axi_wready(axi_wready),
      .m_axi_bresp(axi_bresp),
      .m_axi_bvalid(axi_bvalid),
      .m_axi_bready(axi_bready)
  );
  // ---------------------------------------------------------------------
  // Address map (first matching rule wins; miss -> DECERR from XBAR):
  //   rule 0  [PMEM_BASE,   +PMEM_SIZE) -> port 0 SRAM (MEM), executable
  //   rule 1  [SERIAL_MMIO, +8)         -> port 1 UART
  //   rule 2  [RTC_MMIO,    +8)         -> disabled until CLINT is added
  // To add CLINT: bump XBAR_SLAVES, add PORT_CLINT, point rule 2 at it,
  // enable it with HAS_TIMER and instantiate CLINT on the matching slice.
  // ---------------------------------------------------------------------
  localparam XBAR_SLAVES = 3;
  localparam XBAR_RULES = 3;
  localparam PORT_SRAM = 0;
  localparam PORT_UART = 1;
  localparam PORT_CLINT = 2;
  localparam [XBAR_RULES*32-1:0] XBAR_RULE_BASE = {RTC_MMIO, SERIAL_MMIO, PMEM_BASE};
  localparam [XBAR_RULES*32-1:0] XBAR_RULE_SIZE = {32'd8, 32'd8, PMEM_SIZE};
  localparam [XBAR_RULES*8-1:0]  XBAR_RULE_PORT = {8'(PORT_CLINT), 8'(PORT_UART), 8'(PORT_SRAM)};
  localparam HAS_CLINT = 1;  // set to 1 when CLINT is instantiated
  localparam [XBAR_RULES-1:0]    XBAR_RULE_EN   = {(HAS_TIMER != 0) && (HAS_CLINT != 0),
                                                   HAS_SERIAL != 0, 1'b1};
  localparam [XBAR_RULES-1:0]    XBAR_RULE_EXEC = {1'b0, 1'b0, 1'b1};

  wire [XBAR_SLAVES*32-1:0] xbar_araddr;
  wire [XBAR_SLAVES*3-1:0]  xbar_arprot;
  wire [XBAR_SLAVES-1:0]    xbar_arvalid;
  wire [XBAR_SLAVES-1:0]    xbar_arready;
  wire [XBAR_SLAVES*32-1:0] xbar_rdata;
  wire [XBAR_SLAVES*2-1:0]  xbar_rresp;
  wire [XBAR_SLAVES-1:0]    xbar_rvalid;
  wire [XBAR_SLAVES-1:0]    xbar_rready;
  wire [XBAR_SLAVES*32-1:0] xbar_awaddr;
  wire [XBAR_SLAVES*3-1:0]  xbar_awprot;
  wire [XBAR_SLAVES-1:0]    xbar_awvalid;
  wire [XBAR_SLAVES-1:0]    xbar_awready;
  wire [XBAR_SLAVES*32-1:0] xbar_wdata;
  wire [XBAR_SLAVES*4-1:0]  xbar_wstrb;
  wire [XBAR_SLAVES-1:0]    xbar_wvalid;
  wire [XBAR_SLAVES-1:0]    xbar_wready;
  wire [XBAR_SLAVES*2-1:0]  xbar_bresp;
  wire [XBAR_SLAVES-1:0]    xbar_bvalid;
  wire [XBAR_SLAVES-1:0]    xbar_bready;

  XBAR #(
      .NUM_SLAVES(XBAR_SLAVES),
      .NUM_RULES(XBAR_RULES),
      .RULE_BASE(XBAR_RULE_BASE),
      .RULE_SIZE(XBAR_RULE_SIZE),
      .RULE_PORT(XBAR_RULE_PORT),
      .RULE_EN(XBAR_RULE_EN),
      .RULE_EXEC(XBAR_RULE_EXEC)
  ) xbar1 (
      .clk(clk),
      .rst_n(rst_n),
      .s_axi_araddr(axi_araddr),
      .s_axi_arprot(axi_arprot),
      .s_axi_arvalid(axi_arvalid),
      .s_axi_arready(axi_arready),
      .s_axi_rdata(axi_rdata),
      .s_axi_rresp(axi_rresp),
      .s_axi_rvalid(axi_rvalid),
      .s_axi_rready(axi_rready),
      .s_axi_awaddr(axi_awaddr),
      .s_axi_awprot(axi_awprot),
      .s_axi_awvalid(axi_awvalid),
      .s_axi_awready(axi_awready),
      .s_axi_wdata(axi_wdata),
      .s_axi_wstrb(axi_wstrb),
      .s_axi_wvalid(axi_wvalid),
      .s_axi_wready(axi_wready),
      .s_axi_bresp(axi_bresp),
      .s_axi_bvalid(axi_bvalid),
      .s_axi_bready(axi_bready),
      .m_axi_araddr(xbar_araddr),
      .m_axi_arprot(xbar_arprot),
      .m_axi_arvalid(xbar_arvalid),
      .m_axi_arready(xbar_arready),
      .m_axi_rdata(xbar_rdata),
      .m_axi_rresp(xbar_rresp),
      .m_axi_rvalid(xbar_rvalid),
      .m_axi_rready(xbar_rready),
      .m_axi_awaddr(xbar_awaddr),
      .m_axi_awprot(xbar_awprot),
      .m_axi_awvalid(xbar_awvalid),
      .m_axi_awready(xbar_awready),
      .m_axi_wdata(xbar_wdata),
      .m_axi_wstrb(xbar_wstrb),
      .m_axi_wvalid(xbar_wvalid),
      .m_axi_wready(xbar_wready),
      .m_axi_bresp(xbar_bresp),
      .m_axi_bvalid(xbar_bvalid),
      .m_axi_bready(xbar_bready)
  );

  MEM #(
      .RANDOM_DELAY(RANDOM_DELAY),
      .BASE(PMEM_BASE),
      .SIZE(PMEM_SIZE)
  ) mem1 (
      .clk(clk),
      .rst_n(rst_n),
      .s_axi_araddr(xbar_araddr[PORT_SRAM*32 +: 32]),
      .s_axi_arprot(xbar_arprot[PORT_SRAM*3 +: 3]),
      .s_axi_arvalid(xbar_arvalid[PORT_SRAM]),
      .s_axi_arready(xbar_arready[PORT_SRAM]),
      .s_axi_rdata(xbar_rdata[PORT_SRAM*32 +: 32]),
      .s_axi_rresp(xbar_rresp[PORT_SRAM*2 +: 2]),
      .s_axi_rvalid(xbar_rvalid[PORT_SRAM]),
      .s_axi_rready(xbar_rready[PORT_SRAM]),
      .s_axi_awaddr(xbar_awaddr[PORT_SRAM*32 +: 32]),
      .s_axi_awprot(xbar_awprot[PORT_SRAM*3 +: 3]),
      .s_axi_awvalid(xbar_awvalid[PORT_SRAM]),
      .s_axi_awready(xbar_awready[PORT_SRAM]),
      .s_axi_wdata(xbar_wdata[PORT_SRAM*32 +: 32]),
      .s_axi_wstrb(xbar_wstrb[PORT_SRAM*4 +: 4]),
      .s_axi_wvalid(xbar_wvalid[PORT_SRAM]),
      .s_axi_wready(xbar_wready[PORT_SRAM]),
      .s_axi_bresp(xbar_bresp[PORT_SRAM*2 +: 2]),
      .s_axi_bvalid(xbar_bvalid[PORT_SRAM]),
      .s_axi_bready(xbar_bready[PORT_SRAM])
  );

  UART uart1 (
      .clk(clk),
      .rst_n(rst_n),
      .s_axi_araddr(xbar_araddr[PORT_UART*32 +: 32]),
      .s_axi_arprot(xbar_arprot[PORT_UART*3 +: 3]),
      .s_axi_arvalid(xbar_arvalid[PORT_UART]),
      .s_axi_arready(xbar_arready[PORT_UART]),
      .s_axi_rdata(xbar_rdata[PORT_UART*32 +: 32]),
      .s_axi_rresp(xbar_rresp[PORT_UART*2 +: 2]),
      .s_axi_rvalid(xbar_rvalid[PORT_UART]),
      .s_axi_rready(xbar_rready[PORT_UART]),
      .s_axi_awaddr(xbar_awaddr[PORT_UART*32 +: 32]),
      .s_axi_awprot(xbar_awprot[PORT_UART*3 +: 3]),
      .s_axi_awvalid(xbar_awvalid[PORT_UART]),
      .s_axi_awready(xbar_awready[PORT_UART]),
      .s_axi_wdata(xbar_wdata[PORT_UART*32 +: 32]),
      .s_axi_wstrb(xbar_wstrb[PORT_UART*4 +: 4]),
      .s_axi_wvalid(xbar_wvalid[PORT_UART]),
      .s_axi_wready(xbar_wready[PORT_UART]),
      .s_axi_bresp(xbar_bresp[PORT_UART*2 +: 2]),
      .s_axi_bvalid(xbar_bvalid[PORT_UART]),
      .s_axi_bready(xbar_bready[PORT_UART]),
      .tx_valid(uart_tx_valid),
      .tx_data(uart_tx_data)
  );

  // CLINT 按窗口内偏移译码，无需传入基址；地址窗口由 XBAR rule 2 决定。
  CLINT clint1 (
      .clk(clk),
      .rst_n(rst_n),
      .s_axi_araddr(xbar_araddr[PORT_CLINT*32 +: 32]),
      .s_axi_arprot(xbar_arprot[PORT_CLINT*3 +: 3]),
      .s_axi_arvalid(xbar_arvalid[PORT_CLINT]),
      .s_axi_arready(xbar_arready[PORT_CLINT]),
      .s_axi_rdata(xbar_rdata[PORT_CLINT*32 +: 32]),
      .s_axi_rresp(xbar_rresp[PORT_CLINT*2 +: 2]),
      .s_axi_rvalid(xbar_rvalid[PORT_CLINT]),
      .s_axi_rready(xbar_rready[PORT_CLINT]),
      .s_axi_awaddr(xbar_awaddr[PORT_CLINT*32 +: 32]),
      .s_axi_awprot(xbar_awprot[PORT_CLINT*3 +: 3]),
      .s_axi_awvalid(xbar_awvalid[PORT_CLINT]),
      .s_axi_awready(xbar_awready[PORT_CLINT]),
      .s_axi_wdata(xbar_wdata[PORT_CLINT*32 +: 32]),
      .s_axi_wstrb(xbar_wstrb[PORT_CLINT*4 +: 4]),
      .s_axi_wvalid(xbar_wvalid[PORT_CLINT]),
      .s_axi_wready(xbar_wready[PORT_CLINT]),
      .s_axi_bresp(xbar_bresp[PORT_CLINT*2 +: 2]),
      .s_axi_bvalid(xbar_bvalid[PORT_CLINT]),
      .s_axi_bready(xbar_bready[PORT_CLINT])
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
`endif
endmodule
