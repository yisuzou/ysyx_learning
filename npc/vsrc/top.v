module top #(
    parameter RANDOM_DELAY = 0,
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
  // CPU core exposes all debug signals and an external AXI4-Lite master port.
  wire [31:0] cpu_araddr;
  wire [2:0]  cpu_arprot;
  wire        cpu_arvalid;
  wire        cpu_arready;
  wire [31:0] cpu_rdata;
  wire [1:0]  cpu_rresp;
  wire        cpu_rvalid;
  wire        cpu_rready;
  wire [31:0] cpu_awaddr;
  wire [2:0]  cpu_awprot;
  wire        cpu_awvalid;
  wire        cpu_awready;
  wire [31:0] cpu_wdata;
  wire [3:0]  cpu_wstrb;
  wire        cpu_wvalid;
  wire        cpu_wready;
  wire [1:0]  cpu_bresp;
  wire        cpu_bvalid;
  wire        cpu_bready;

  npc_core #(
      .RANDOM_DELAY(RANDOM_DELAY),
      .PMEM_BASE(PMEM_BASE),
      .PMEM_SIZE(PMEM_SIZE)
  ) u_cpu (
      .clk(clk),
      .rst_n(rst_n),
      .invalid_inst(invalid_inst),
      .diff_ifu_valid(diff_ifu_valid),
      .debug_pc(debug_pc),
      .debug_inst(debug_inst),
      .debug_bus_error(debug_bus_error),
      .debug_bus_error_addr(debug_bus_error_addr),
      .debug_bus_error_resp(debug_bus_error_resp),
      .debug_bus_error_op(debug_bus_error_op),
      .debug_mstatus(debug_mstatus),
      .debug_mtvec(debug_mtvec),
      .debug_mepc(debug_mepc),
      .debug_mcause(debug_mcause),
      .debug_mcycle(debug_mcycle),
      .debug_mcycleh(debug_mcycleh),
      .debug_mvendorid(debug_mvendorid),
      .debug_marchid(debug_marchid),
      .debug_skip_ref(debug_skip_ref),
      .m_axi_araddr(cpu_araddr),
      .m_axi_arprot(cpu_arprot),
      .m_axi_arvalid(cpu_arvalid),
      .m_axi_arready(cpu_arready),
      .m_axi_rdata(cpu_rdata),
      .m_axi_rresp(cpu_rresp),
      .m_axi_rvalid(cpu_rvalid),
      .m_axi_rready(cpu_rready),
      .m_axi_awaddr(cpu_awaddr),
      .m_axi_awprot(cpu_awprot),
      .m_axi_awvalid(cpu_awvalid),
      .m_axi_awready(cpu_awready),
      .m_axi_wdata(cpu_wdata),
      .m_axi_wstrb(cpu_wstrb),
      .m_axi_wvalid(cpu_wvalid),
      .m_axi_wready(cpu_wready),
      .m_axi_bresp(cpu_bresp),
      .m_axi_bvalid(cpu_bvalid),
      .m_axi_bready(cpu_bready)
  );

  // ---------------------------------------------------------------------------
  // Platform XBAR: CPU external AXI -> MEM (executable), UART, and CLINT.
  // The core exposes a bus master; all device routing lives in the platform.
  // ---------------------------------------------------------------------------
  localparam PLAT_SLAVES = 3;
  localparam PLAT_RULES  = 3;
  localparam PLAT_PORT_MEM  = 0;
  localparam PLAT_PORT_UART = 1;
  localparam PLAT_PORT_CLINT = 2;

  localparam [PLAT_RULES*32-1:0] PLAT_RULE_BASE = {RTC_MMIO, SERIAL_MMIO, PMEM_BASE};
  localparam [PLAT_RULES*32-1:0] PLAT_RULE_SIZE = {32'd8, 32'd8, PMEM_SIZE};
  localparam [PLAT_RULES*8-1:0]  PLAT_RULE_PORT =
      {8'(PLAT_PORT_CLINT), 8'(PLAT_PORT_UART), 8'(PLAT_PORT_MEM)};
  localparam [PLAT_RULES-1:0]    PLAT_RULE_EN   = {HAS_TIMER != 0, HAS_SERIAL != 0, 1'b1};
  localparam [PLAT_RULES-1:0]    PLAT_RULE_EXEC = 3'b001;

  wire [PLAT_SLAVES*32-1:0] plat_araddr;
  wire [PLAT_SLAVES*3-1:0]  plat_arprot;
  wire [PLAT_SLAVES-1:0]    plat_arvalid;
  wire [PLAT_SLAVES-1:0]    plat_arready;
  wire [PLAT_SLAVES*32-1:0] plat_rdata;
  wire [PLAT_SLAVES*2-1:0]  plat_rresp;
  wire [PLAT_SLAVES-1:0]    plat_rvalid;
  wire [PLAT_SLAVES-1:0]    plat_rready;
  wire [PLAT_SLAVES*32-1:0] plat_awaddr;
  wire [PLAT_SLAVES*3-1:0]  plat_awprot;
  wire [PLAT_SLAVES-1:0]    plat_awvalid;
  wire [PLAT_SLAVES-1:0]    plat_awready;
  wire [PLAT_SLAVES*32-1:0] plat_wdata;
  wire [PLAT_SLAVES*4-1:0]  plat_wstrb;
  wire [PLAT_SLAVES-1:0]    plat_wvalid;
  wire [PLAT_SLAVES-1:0]    plat_wready;
  wire [PLAT_SLAVES*2-1:0]  plat_bresp;
  wire [PLAT_SLAVES-1:0]    plat_bvalid;
  wire [PLAT_SLAVES-1:0]    plat_bready;

  XBAR #(
      .NUM_SLAVES(PLAT_SLAVES),
      .NUM_RULES(PLAT_RULES),
      .RULE_BASE(PLAT_RULE_BASE),
      .RULE_SIZE(PLAT_RULE_SIZE),
      .RULE_PORT(PLAT_RULE_PORT),
      .RULE_EN(PLAT_RULE_EN),
      .RULE_EXEC(PLAT_RULE_EXEC)
  ) u_plat_xbar (
      .clk(clk),
      .rst_n(rst_n),
      .s_axi_araddr(cpu_araddr),
      .s_axi_arprot(cpu_arprot),
      .s_axi_arvalid(cpu_arvalid),
      .s_axi_arready(cpu_arready),
      .s_axi_rdata(cpu_rdata),
      .s_axi_rresp(cpu_rresp),
      .s_axi_rvalid(cpu_rvalid),
      .s_axi_rready(cpu_rready),
      .s_axi_awaddr(cpu_awaddr),
      .s_axi_awprot(cpu_awprot),
      .s_axi_awvalid(cpu_awvalid),
      .s_axi_awready(cpu_awready),
      .s_axi_wdata(cpu_wdata),
      .s_axi_wstrb(cpu_wstrb),
      .s_axi_wvalid(cpu_wvalid),
      .s_axi_wready(cpu_wready),
      .s_axi_bresp(cpu_bresp),
      .s_axi_bvalid(cpu_bvalid),
      .s_axi_bready(cpu_bready),
      .m_axi_araddr(plat_araddr),
      .m_axi_arprot(plat_arprot),
      .m_axi_arvalid(plat_arvalid),
      .m_axi_arready(plat_arready),
      .m_axi_rdata(plat_rdata),
      .m_axi_rresp(plat_rresp),
      .m_axi_rvalid(plat_rvalid),
      .m_axi_rready(plat_rready),
      .m_axi_awaddr(plat_awaddr),
      .m_axi_awprot(plat_awprot),
      .m_axi_awvalid(plat_awvalid),
      .m_axi_awready(plat_awready),
      .m_axi_wdata(plat_wdata),
      .m_axi_wstrb(plat_wstrb),
      .m_axi_wvalid(plat_wvalid),
      .m_axi_wready(plat_wready),
      .m_axi_bresp(plat_bresp),
      .m_axi_bvalid(plat_bvalid),
      .m_axi_bready(plat_bready)
  );

  MEM #(
      .RANDOM_DELAY(RANDOM_DELAY),
      .BASE(PMEM_BASE),
      .SIZE(PMEM_SIZE)
  ) mem1 (
      .clk(clk),
      .rst_n(rst_n),
      .s_axi_araddr(plat_araddr[PLAT_PORT_MEM*32 +: 32]),
      .s_axi_arprot(plat_arprot[PLAT_PORT_MEM*3 +: 3]),
      .s_axi_arvalid(plat_arvalid[PLAT_PORT_MEM]),
      .s_axi_arready(plat_arready[PLAT_PORT_MEM]),
      .s_axi_rdata(plat_rdata[PLAT_PORT_MEM*32 +: 32]),
      .s_axi_rresp(plat_rresp[PLAT_PORT_MEM*2 +: 2]),
      .s_axi_rvalid(plat_rvalid[PLAT_PORT_MEM]),
      .s_axi_rready(plat_rready[PLAT_PORT_MEM]),
      .s_axi_awaddr(plat_awaddr[PLAT_PORT_MEM*32 +: 32]),
      .s_axi_awprot(plat_awprot[PLAT_PORT_MEM*3 +: 3]),
      .s_axi_awvalid(plat_awvalid[PLAT_PORT_MEM]),
      .s_axi_awready(plat_awready[PLAT_PORT_MEM]),
      .s_axi_wdata(plat_wdata[PLAT_PORT_MEM*32 +: 32]),
      .s_axi_wstrb(plat_wstrb[PLAT_PORT_MEM*4 +: 4]),
      .s_axi_wvalid(plat_wvalid[PLAT_PORT_MEM]),
      .s_axi_wready(plat_wready[PLAT_PORT_MEM]),
      .s_axi_bresp(plat_bresp[PLAT_PORT_MEM*2 +: 2]),
      .s_axi_bvalid(plat_bvalid[PLAT_PORT_MEM]),
      .s_axi_bready(plat_bready[PLAT_PORT_MEM])
  );

  CLINT clint1 (
      .clk(clk),
      .rst_n(rst_n),
      .s_axi_araddr(plat_araddr[PLAT_PORT_CLINT*32 +: 32]),
      .s_axi_arprot(plat_arprot[PLAT_PORT_CLINT*3 +: 3]),
      .s_axi_arvalid(plat_arvalid[PLAT_PORT_CLINT]),
      .s_axi_arready(plat_arready[PLAT_PORT_CLINT]),
      .s_axi_rdata(plat_rdata[PLAT_PORT_CLINT*32 +: 32]),
      .s_axi_rresp(plat_rresp[PLAT_PORT_CLINT*2 +: 2]),
      .s_axi_rvalid(plat_rvalid[PLAT_PORT_CLINT]),
      .s_axi_rready(plat_rready[PLAT_PORT_CLINT]),
      .s_axi_awaddr(plat_awaddr[PLAT_PORT_CLINT*32 +: 32]),
      .s_axi_awprot(plat_awprot[PLAT_PORT_CLINT*3 +: 3]),
      .s_axi_awvalid(plat_awvalid[PLAT_PORT_CLINT]),
      .s_axi_awready(plat_awready[PLAT_PORT_CLINT]),
      .s_axi_wdata(plat_wdata[PLAT_PORT_CLINT*32 +: 32]),
      .s_axi_wstrb(plat_wstrb[PLAT_PORT_CLINT*4 +: 4]),
      .s_axi_wvalid(plat_wvalid[PLAT_PORT_CLINT]),
      .s_axi_wready(plat_wready[PLAT_PORT_CLINT]),
      .s_axi_bresp(plat_bresp[PLAT_PORT_CLINT*2 +: 2]),
      .s_axi_bvalid(plat_bvalid[PLAT_PORT_CLINT]),
      .s_axi_bready(plat_bready[PLAT_PORT_CLINT])
  );

  UART uart1 (
      .clk(clk),
      .rst_n(rst_n),
      .s_axi_araddr(plat_araddr[PLAT_PORT_UART*32 +: 32]),
      .s_axi_arprot(plat_arprot[PLAT_PORT_UART*3 +: 3]),
      .s_axi_arvalid(plat_arvalid[PLAT_PORT_UART]),
      .s_axi_arready(plat_arready[PLAT_PORT_UART]),
      .s_axi_rdata(plat_rdata[PLAT_PORT_UART*32 +: 32]),
      .s_axi_rresp(plat_rresp[PLAT_PORT_UART*2 +: 2]),
      .s_axi_rvalid(plat_rvalid[PLAT_PORT_UART]),
      .s_axi_rready(plat_rready[PLAT_PORT_UART]),
      .s_axi_awaddr(plat_awaddr[PLAT_PORT_UART*32 +: 32]),
      .s_axi_awprot(plat_awprot[PLAT_PORT_UART*3 +: 3]),
      .s_axi_awvalid(plat_awvalid[PLAT_PORT_UART]),
      .s_axi_awready(plat_awready[PLAT_PORT_UART]),
      .s_axi_wdata(plat_wdata[PLAT_PORT_UART*32 +: 32]),
      .s_axi_wstrb(plat_wstrb[PLAT_PORT_UART*4 +: 4]),
      .s_axi_wvalid(plat_wvalid[PLAT_PORT_UART]),
      .s_axi_wready(plat_wready[PLAT_PORT_UART]),
      .s_axi_bresp(plat_bresp[PLAT_PORT_UART*2 +: 2]),
      .s_axi_bvalid(plat_bvalid[PLAT_PORT_UART]),
      .s_axi_bready(plat_bready[PLAT_PORT_UART]),
      .tx_valid(uart_tx_valid),
      .tx_data(uart_tx_data)
  );
endmodule
