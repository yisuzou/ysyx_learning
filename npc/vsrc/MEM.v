`ifndef SYNTHESIS
import "DPI-C" function int pmem_ifetch(input int raddr);
import "DPI-C" function int pmem_read(input int raddr, input byte rlen);
import "DPI-C" function void pmem_write(
    input int waddr, input int wdata, input byte wlen
);
`endif

// 32-bit AXI4-Lite SRAM slave: one outstanding read and one outstanding write.
// Pure memory device: no MMIO knowledge. XBAR routes only the SRAM window
// here; the local range check is a defensive guard for the DPI backend.
// AXI control is synthesizable; DPI supplies the simulation-only storage.
// Future AXI4 bursts/IDs belong at this slave boundary, not in the DPI API.
module MEM #(
    parameter RANDOM_DELAY = 1,
    parameter [31:0] BASE = 32'h80000000,
    parameter [31:0] SIZE = 32'h08000000
) (
    input         clk,
    input         rst_n,
    // Read address channel
    input  [31:0] s_axi_araddr,
    input  [ 2:0] s_axi_arprot,
    input         s_axi_arvalid,
    output        s_axi_arready,
    // Read data channel
    output reg [31:0] s_axi_rdata,
    output reg [ 1:0] s_axi_rresp,
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
    input         s_axi_bready
);
  localparam [1:0] RESP_OKAY   = 2'b00;
  localparam [1:0] RESP_DECERR = 2'b11;

  // Read FSM (AR/R):
  // State      Action                         Next state
  // RD_IDLE    Accept and latch AR             ar_fire -> RD_ACCESS
  // RD_ACCESS  Read DPI once; latch RDATA/RESP  RD_DELAY
  // RD_DELAY   Wait for response delay         r_delay_done -> RD_RESP
  // RD_RESP    Hold RVALID/RDATA/RRESP          r_fire -> RD_IDLE
  // Write FSM (AW/W/B):
  // State      Action                         Next state
  // WR_COLLECT Cache AW and W independently    both cached -> WR_ACCESS
  // WR_ACCESS  Write DPI once; latch BRESP      WR_DELAY
  // WR_DELAY   Wait for response delay         b_delay_done -> WR_RESP
  // WR_RESP    Hold BVALID/BRESP                b_fire -> WR_COLLECT
  // All unlisted conditions hold the current state. Reset discards requests
  // and responses, but cannot undo a write already performed in WR_ACCESS.
  localparam [1:0] RD_IDLE   = 2'd0;
  localparam [1:0] RD_ACCESS = 2'd1;
  localparam [1:0] RD_DELAY  = 2'd2;
  localparam [1:0] RD_RESP   = 2'd3;
  localparam [1:0] WR_COLLECT = 2'd0;
  localparam [1:0] WR_ACCESS  = 2'd1;
  localparam [1:0] WR_DELAY   = 2'd2;
  localparam [1:0] WR_RESP    = 2'd3;

  reg [1:0] rd_state, rd_next_state;
  reg [1:0] wr_state, wr_next_state;
  reg [31:0] araddr_r, awaddr_r, wdata_r;
  reg [2:0] arprot_r, awprot_r;
  reg [3:0] wstrb_r;
  reg aw_pending, w_pending;

  // Full-width AXI-Lite reads return the addressed, aligned 32-bit word.
  // WSTRB selects lanes relative to the same aligned word for writes.
  wire [31:0] rd_word_addr = {araddr_r[31:2], 2'b00};
  wire [31:0] wr_word_addr = {awaddr_r[31:2], 2'b00};
  // This backend distinguishes instruction/data accesses via ARPROT[2].
  // Privilege/security checks and AWPROT policy are not implemented.
  wire unused_attributes = &{1'b0, arprot_r[1:0], awprot_r,
                            araddr_r[1:0], awaddr_r[1:0]};
`ifdef SYNTHESIS
  // No hardware storage backend is supplied by this simulation MEM module.
  wire unused_write_data = &{1'b0, wdata_r, arprot_r[2]};
`endif

  wire ar_delay_done, aw_delay_done, w_delay_done;
  wire r_delay_done, b_delay_done;
  wire ar_slot_free = (rd_state == RD_IDLE);
  wire aw_slot_free = (wr_state == WR_COLLECT) && !aw_pending;
  wire w_slot_free = (wr_state == WR_COLLECT) && !w_pending;

  // Delay READY before acceptance, and delay responses before asserting VALID.
  // Once a response becomes valid, delay logic can no longer withdraw it.
  generate
    if (RANDOM_DELAY != 0) begin : g_random_delay
      random_delay ar_delay (
          .clk(clk), .rst_n(rst_n), .req(ar_slot_free), .gated(ar_delay_done)
      );
      random_delay aw_delay (
          .clk(clk), .rst_n(rst_n), .req(aw_slot_free), .gated(aw_delay_done)
      );
      random_delay w_delay (
          .clk(clk), .rst_n(rst_n), .req(w_slot_free), .gated(w_delay_done)
      );
      random_delay r_delay (
          .clk(clk), .rst_n(rst_n),
          .req(rd_state == RD_DELAY), .gated(r_delay_done)
      );
      random_delay b_delay (
          .clk(clk), .rst_n(rst_n),
          .req(wr_state == WR_DELAY), .gated(b_delay_done)
      );
    end else begin : g_no_delay
      assign ar_delay_done = 1'b1;
      assign aw_delay_done = 1'b1;
      assign w_delay_done = 1'b1;
      assign r_delay_done = 1'b1;
      assign b_delay_done = 1'b1;
    end
  endgenerate

  // No combinational dependency on master VALID/READY inputs.
  assign s_axi_arready = rst_n && ar_slot_free && ar_delay_done;
  assign s_axi_awready = rst_n && aw_slot_free && aw_delay_done;
  assign s_axi_wready  = rst_n && w_slot_free && w_delay_done;
  assign s_axi_rvalid  = rst_n && (rd_state == RD_RESP);
  assign s_axi_bvalid  = rst_n && (wr_state == WR_RESP);

  wire ar_fire = s_axi_arvalid && s_axi_arready;
  wire aw_fire = s_axi_awvalid && s_axi_awready;
  wire w_fire  = s_axi_wvalid  && s_axi_wready;
  wire r_fire  = s_axi_rvalid  && s_axi_rready;
  wire b_fire  = s_axi_bvalid  && s_axi_bready;

  // SRAM has no device rules: any in-range word is readable/writable.
  function in_ram_word;
    input [31:0] addr;
    begin
      in_ram_word = (SIZE >= 32'd4) && (addr >= BASE) &&
                    ((addr - BASE) <= (SIZE - 32'd4));
    end
  endfunction

  wire [1:0] rd_access_resp = in_ram_word(rd_word_addr) ? RESP_OKAY : RESP_DECERR;
  // A zero-strobe write is a no-op and always succeeds.
  wire [1:0] wr_access_resp = ((wstrb_r == 4'b0000) || in_ram_word(wr_word_addr)) ?
                              RESP_OKAY : RESP_DECERR;

`ifndef SYNTHESIS
  // Preserve the existing DPI API (length, not strobes). Common contiguous
  // masks use one call; other masks use a fixed lane loop. This task executes
  // once per AXI write, regardless of response delay or BREADY backpressure.
  task dpi_write_word;
    input [31:0] addr;
    input [31:0] data;
    input [3:0] strb;
    integer lane;
    begin
      case (strb)
        4'b0000: begin end
        4'b1111: pmem_write(addr, data, 8'd4);
        4'b0011: pmem_write(addr, data, 8'd2);
        4'b0110: pmem_write(addr + 32'd1, data >> 8, 8'd2);
        4'b1100: pmem_write(addr + 32'd2, data >> 16, 8'd2);
        default: begin
          for (lane = 0; lane < 4; lane = lane + 1) begin
            if (strb[lane])
              pmem_write(addr + lane, data >> (lane * 8), 8'd1);
          end
        end
      endcase
    end
  endtask
`endif

  // Next-state logic. AW/W completeness includes handshakes on this edge;
  // WR_ACCESS starts only after both payload registers have been updated.
  always @(*) begin
    rd_next_state = rd_state;
    case (rd_state)
      RD_IDLE:   if (ar_fire) rd_next_state = RD_ACCESS;
      RD_ACCESS: rd_next_state = RD_DELAY;
      RD_DELAY:  if (r_delay_done) rd_next_state = RD_RESP;
      RD_RESP:   if (r_fire) rd_next_state = RD_IDLE;
      default:   rd_next_state = RD_IDLE;
    endcase

    wr_next_state = wr_state;
    case (wr_state)
      WR_COLLECT: begin
        if ((aw_pending || aw_fire) && (w_pending || w_fire))
          wr_next_state = WR_ACCESS;
      end
      WR_ACCESS: wr_next_state = WR_DELAY;
      WR_DELAY:  if (b_delay_done) wr_next_state = WR_RESP;
      WR_RESP:   if (b_fire) wr_next_state = WR_COLLECT;
      default:   wr_next_state = WR_COLLECT;
    endcase
  end

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

  // Read request registers and response registers have separate enables.
  // RDATA/RRESP are written only in RD_ACCESS, never during RD_RESP.
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      araddr_r <= 32'b0;
      arprot_r <= 3'b0;
      s_axi_rdata <= 32'b0;
      s_axi_rresp <= RESP_OKAY;
    end else begin
      if (ar_fire) begin // 锁存 AR 通道的地址和保护属性，供后续读访问使用
        araddr_r <= s_axi_araddr;
        arprot_r <= s_axi_arprot;
      end
      if (rd_state == RD_ACCESS) begin
        s_axi_rdata <= 32'b0;
        s_axi_rresp <= rd_access_resp;
`ifndef SYNTHESIS
        if (rd_access_resp == RESP_OKAY) begin
          if (arprot_r[2])
            s_axi_rdata <= pmem_ifetch(rd_word_addr);
          else
            s_axi_rdata <= pmem_read(rd_word_addr, 8'd4);
        end
`endif
      end
    end
  end

  // AW and W are independent one-entry buffers, released together after B.
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      aw_pending <= 1'b0;
      w_pending <= 1'b0;
      awaddr_r <= 32'b0;
      awprot_r <= 3'b0;
      wdata_r <= 32'b0;
      wstrb_r <= 4'b0;
      s_axi_bresp <= RESP_OKAY;
    end else begin
      if (aw_fire) begin
        awaddr_r <= s_axi_awaddr;
        awprot_r <= s_axi_awprot;
        aw_pending <= 1'b1;
      end
      if (w_fire) begin
        wdata_r <= s_axi_wdata;
        wstrb_r <= s_axi_wstrb;
        w_pending <= 1'b1;
      end
      if (wr_state == WR_ACCESS) begin
        s_axi_bresp <= wr_access_resp;
`ifndef SYNTHESIS
        if (wr_access_resp == RESP_OKAY)
          dpi_write_word(wr_word_addr, wdata_r, wstrb_r);
`endif
      end
      if (b_fire) begin
        aw_pending <= 1'b0;
        w_pending <= 1'b0;
      end
    end
  end
endmodule
