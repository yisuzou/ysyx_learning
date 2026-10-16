// Two read masters (IFU/LSU) share one AXI4-Lite slave. Read ownership is
// locked before forwarding AR and held through the final R handshake.
// LSU is the only writer, so AW/W/B remain independent pass-through channels.
// AXI4 bursts/IDs and additional writers require extending this boundary.
module AXIArbiter (
    input         clk,
    input         rst_n,
    // Read-only IFU slave-facing port
    input  [31:0] ifu_araddr,
    input  [2:0]  ifu_arprot,
    input         ifu_arvalid,
    output        ifu_arready,
    output [31:0] ifu_rdata,
    output [1:0]  ifu_rresp,
    output        ifu_rvalid,
    input         ifu_rready,
    // LSU slave-facing port
    input  [31:0] lsu_araddr,
    input  [2:0]  lsu_arprot,
    input         lsu_arvalid,
    output        lsu_arready,
    output [31:0] lsu_rdata,
    output [1:0]  lsu_rresp,
    output        lsu_rvalid,
    input         lsu_rready,
    input  [31:0] lsu_awaddr,
    input  [2:0]  lsu_awprot,
    input         lsu_awvalid,
    output        lsu_awready,
    input  [31:0] lsu_wdata,
    input  [3:0]  lsu_wstrb,
    input         lsu_wvalid,
    output        lsu_wready,
    output [1:0]  lsu_bresp,
    output        lsu_bvalid,
    input         lsu_bready,
    // MEM master-facing port
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
  localparam [1:0] ARB_IDLE = 2'd0;
  localparam [1:0] ARB_ADDR = 2'd1;
  localparam [1:0] ARB_RESP = 2'd2;
  localparam OWNER_IFU = 1'b0;
  localparam OWNER_LSU = 1'b1;

  // State     Action                          Transition
  // ARB_IDLE  Choose/latch owner (round robin) any ARVALID -> ARB_ADDR
  // ARB_ADDR  Route selected AR, hold owner    ar_fire -> ARB_RESP
  // ARB_RESP  Route R only to selected owner   r_fire -> ARB_IDLE
  // Round-robin priority advances after R completion, never during a stall.
  // Reset removes ownership; IFU wins the first simultaneous request.
  reg [1:0] state, next_state;
  reg owner_r, prefer_r;
  wire choose_owner = ifu_arvalid && lsu_arvalid ? prefer_r :
                      (lsu_arvalid ? OWNER_LSU : OWNER_IFU);
  wire addr_active = rst_n && (state == ARB_ADDR);
  wire resp_active = rst_n && (state == ARB_RESP);

  assign m_axi_araddr = owner_r == OWNER_IFU ? ifu_araddr : lsu_araddr;
  assign m_axi_arprot = owner_r == OWNER_IFU ? ifu_arprot : lsu_arprot;
  assign m_axi_arvalid = addr_active &&
                        (owner_r == OWNER_IFU ? ifu_arvalid : lsu_arvalid);
  assign ifu_arready = addr_active && (owner_r == OWNER_IFU) && m_axi_arready;
  assign lsu_arready = addr_active && (owner_r == OWNER_LSU) && m_axi_arready;
  assign ifu_rdata = m_axi_rdata;
  assign lsu_rdata = m_axi_rdata;
  assign ifu_rresp = m_axi_rresp;
  assign lsu_rresp = m_axi_rresp;
  assign ifu_rvalid = resp_active && (owner_r == OWNER_IFU) && m_axi_rvalid;
  assign lsu_rvalid = resp_active && (owner_r == OWNER_LSU) && m_axi_rvalid;
  assign m_axi_rready = resp_active &&
                       (owner_r == OWNER_IFU ? ifu_rready : lsu_rready);

  // Only LSU can write. Never couple AWREADY to WREADY or their VALID inputs.
  assign m_axi_awaddr = lsu_awaddr;
  assign m_axi_awprot = lsu_awprot;
  assign m_axi_awvalid = rst_n && lsu_awvalid;
  assign lsu_awready = rst_n && m_axi_awready;
  assign m_axi_wdata = lsu_wdata;
  assign m_axi_wstrb = lsu_wstrb;
  assign m_axi_wvalid = rst_n && lsu_wvalid;
  assign lsu_wready = rst_n && m_axi_wready;
  assign lsu_bresp = m_axi_bresp;
  assign lsu_bvalid = rst_n && m_axi_bvalid;
  assign m_axi_bready = rst_n && lsu_bready;

  wire ar_fire = m_axi_arvalid && m_axi_arready;
  wire r_fire = m_axi_rvalid && m_axi_rready;

  // State register.
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) state <= ARB_IDLE;
    else state <= next_state;
  end

  // Next-state logic.
  always @(*) begin
    next_state = state;
    case (state)
      ARB_IDLE: if (ifu_arvalid || lsu_arvalid) next_state = ARB_ADDR;
      ARB_ADDR: if (ar_fire) next_state = ARB_RESP;
      ARB_RESP: if (r_fire) next_state = ARB_IDLE;
      default: next_state = ARB_IDLE;
    endcase
  end

  // Ownership/priority registers. Selected master keeps its payload stable
  // until its AR handshake, which is the same edge as the downstream AR.
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      owner_r <= OWNER_IFU;
      prefer_r <= OWNER_IFU;
    end else begin
      if ((state == ARB_IDLE) && (ifu_arvalid || lsu_arvalid))
        owner_r <= choose_owner;
      if (r_fire) prefer_r <= !owner_r;
    end
  end
endmodule
