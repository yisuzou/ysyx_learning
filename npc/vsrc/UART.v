// 32-bit AXI4-Lite UART (transmit-only) slave.
// One outstanding read and one outstanding write; directions are independent.
//
// Register map (offset inside the 8-byte window routed by XBAR):
//   0x0  TXDATA  W   byte lane 0 only (WSTRB == 4'b0001): transmit one byte
//   0x4  -           reserved
// Response rules:
//   any read                          -> SLVERR (device is write-only)
//   WSTRB == 0                        -> OKAY, no side effect
//   offset 0x0 with WSTRB == 4'b0001  -> OKAY, byte transmitted
//   any other write                   -> SLVERR, no side effect
// Decoding uses the low address bits, so the window base must be 8-aligned.
//
// Transmit interface: tx_valid pulses for one cycle with tx_data stable.
// Simulation also prints the byte on stderr (same stream as the old host
// serial model). A real line-side serializer can be attached to tx_* later.
module UART (
    input         clk,
    input         rst_n,
    // Read address channel
    input  [31:0] s_axi_araddr,
    input  [ 2:0] s_axi_arprot,
    input         s_axi_arvalid,
    output        s_axi_arready,
    // Read data channel
    output [31:0] s_axi_rdata,
    output [ 1:0] s_axi_rresp,
    output        s_axi_rvalid,
    input         s_axi_rready,
    // Write address channel
    input  [31:0] s_axi_awaddr,
    input  [ 2:0] s_axi_awprot,
    input         s_axi_awvalid,
    output        s_axi_awready,
    // Write data channel
    input  [31:0] s_axi_wdata,
    input  [ 3:0] s_axi_wstrb,
    input         s_axi_wvalid,
    output        s_axi_wready,
    // Write response channel
    output reg [ 1:0] s_axi_bresp,
    output        s_axi_bvalid,
    input         s_axi_bready,
    // Transmit byte stream
    output reg        tx_valid,
    output reg [ 7:0] tx_data
);
  localparam [1:0] RESP_OKAY   = 2'b00;
  localparam [1:0] RESP_SLVERR = 2'b10;

  // Read FSM (AR/R):
  // State      Action                              Next state
  // RD_IDLE    ARREADY=1                           ar_fire -> RD_RESP
  // RD_RESP    RVALID=1, RDATA=0, RRESP=SLVERR      r_fire  -> RD_IDLE
  // Write FSM (AW/W/B):
  // State      Action                              Next state
  // WR_COLLECT Cache AW and W independently         both cached -> WR_ACCESS
  // WR_ACCESS  Check rules; transmit once; BRESP    WR_RESP
  // WR_RESP    Hold BVALID/BRESP                    b_fire -> WR_COLLECT
  // All unlisted conditions hold the current state. Reset discards requests
  // and responses, but cannot recall a byte already transmitted.
  localparam RD_IDLE = 1'b0;
  localparam RD_RESP = 1'b1;
  localparam [1:0] WR_COLLECT = 2'd0;
  localparam [1:0] WR_ACCESS  = 2'd1;
  localparam [1:0] WR_RESP    = 2'd2;

  reg rd_state, rd_next_state;
  reg [1:0] wr_state, wr_next_state;
  reg aw_pending, w_pending;
  reg [2:0] awoff_r;
  reg [7:0] wbyte_r;
  reg [3:0] wstrb_r;

  // Reads carry no information; only the write offset and lane 0 matter.
  wire unused_inputs = &{1'b0, s_axi_araddr, s_axi_arprot, s_axi_awaddr[31:3],
                        s_axi_awprot, s_axi_wdata[31:8]};

  // No combinational dependency on master VALID/READY inputs.
  assign s_axi_arready = rst_n && (rd_state == RD_IDLE);
  assign s_axi_rvalid  = rst_n && (rd_state == RD_RESP);
  assign s_axi_rdata   = 32'b0;
  assign s_axi_rresp   = RESP_SLVERR;
  assign s_axi_awready = rst_n && (wr_state == WR_COLLECT) && !aw_pending;
  assign s_axi_wready  = rst_n && (wr_state == WR_COLLECT) && !w_pending;
  assign s_axi_bvalid  = rst_n && (wr_state == WR_RESP);

  wire ar_fire = s_axi_arvalid && s_axi_arready;
  wire r_fire  = s_axi_rvalid  && s_axi_rready;
  wire aw_fire = s_axi_awvalid && s_axi_awready;
  wire w_fire  = s_axi_wvalid  && s_axi_wready;
  wire b_fire  = s_axi_bvalid  && s_axi_bready;

  wire tx_hit = (awoff_r == 3'd0) && (wstrb_r == 4'b0001);
  wire [1:0] wr_access_resp = ((wstrb_r == 4'b0000) || tx_hit) ?
                              RESP_OKAY : RESP_SLVERR;
  wire tx_fire = (wr_state == WR_ACCESS) && tx_hit;

  // State registers.
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rd_state <= RD_IDLE;
      wr_state <= WR_COLLECT;
    end else begin
      rd_state <= rd_next_state;
      wr_state <= wr_next_state;
    end
  end

  // Next-state logic. AW/W completeness includes handshakes on this edge.
  always @(*) begin
    rd_next_state = rd_state;
    case (rd_state)
      RD_IDLE: if (ar_fire) rd_next_state = RD_RESP;
      RD_RESP: if (r_fire)  rd_next_state = RD_IDLE;
      default:              rd_next_state = RD_IDLE;
    endcase

    wr_next_state = wr_state;
    case (wr_state)
      WR_COLLECT: if ((aw_pending || aw_fire) && (w_pending || w_fire))
                    wr_next_state = WR_ACCESS;
      WR_ACCESS:    wr_next_state = WR_RESP;
      WR_RESP:    if (b_fire) wr_next_state = WR_COLLECT;
      default:      wr_next_state = WR_COLLECT;
    endcase
  end

  // Write request buffers: AW and W are independent one-entry buffers,
  // released together after B.
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      aw_pending <= 1'b0;
      w_pending  <= 1'b0;
      awoff_r    <= 3'b0;
      wbyte_r    <= 8'b0;
      wstrb_r    <= 4'b0;
    end else begin
      if (aw_fire) begin
        awoff_r    <= s_axi_awaddr[2:0];
        aw_pending <= 1'b1;
      end
      if (w_fire) begin
        wbyte_r   <= s_axi_wdata[7:0];
        wstrb_r   <= s_axi_wstrb;
        w_pending <= 1'b1;
      end
      if (b_fire) begin
        aw_pending <= 1'b0;
        w_pending  <= 1'b0;
      end
    end
  end

  // Write response and transmit registers: updated only in WR_ACCESS, so a
  // byte is sent exactly once regardless of BREADY backpressure.
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s_axi_bresp <= RESP_OKAY;
      tx_valid    <= 1'b0;
      tx_data     <= 8'b0;
    end else begin
      tx_valid <= tx_fire;
      if (wr_state == WR_ACCESS) s_axi_bresp <= wr_access_resp;
      if (tx_fire) tx_data <= wbyte_r;
    end
  end

`ifndef SYNTHESIS
  always @(posedge clk) begin
    if (rst_n && tx_valid) $fwrite(32'h80000002, "%c", tx_data);
  end
`endif
endmodule
