// Thin synthesis wrapper for the CPU core only.
// No MEM, no UART, no platform XBAR: the CPU's external AXI4-Lite master
// becomes the top-level interface so the synthesis/STA result reflects only
// the CPU (reg-to-reg) timing and area.
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
    output [1:0] debug_bus_error_op,
    output [31:0] debug_mstatus,
    output [31:0] debug_mtvec,
    output [31:0] debug_mepc,
    output [31:0] debug_mcause,
    output [31:0] debug_mcycle,
    output [31:0] debug_mcycleh,
    output [31:0] debug_mvendorid,
    output [31:0] debug_marchid,
    output debug_skip_ref,

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

  npc_core #(
      .RANDOM_DELAY(0),
      .PMEM_BASE(PMEM_BASE),
      .PMEM_SIZE(PMEM_SIZE),
      .HAS_SERIAL(HAS_SERIAL),
      .HAS_TIMER(HAS_TIMER),
      .SERIAL_MMIO(SERIAL_MMIO),
      .RTC_MMIO(RTC_MMIO)
  ) u_cpu (
      .*
  );

endmodule
