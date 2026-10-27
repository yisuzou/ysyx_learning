// 1-to-N AXI4-Lite crossbar: one upstream master port, NUM_SLAVES downstream
// slave ports. The address map is a rule table; each rule maps one window
// [BASE, BASE+SIZE) to one downstream port. Several rules may share a port.
// An address that hits no rule (or an instruction fetch that hits a
// non-executable rule) is answered by the internal default slave with DECERR.
//
// Capacity: one outstanding read and one outstanding write, matching the
// upstream masters. Read and write directions are independent.
// Downstream payloads are broadcast to every port; only VALID/READY are
// routed, so adding a slave costs one AND-OR mux leg per response field.
//
// Flattened port i occupies bits [i*W +: W] of each m_axi_* bus.
module XBAR #(
    parameter NUM_SLAVES = 2,
    parameter NUM_RULES  = 1,
    // Rule r occupies bits [r*32 +: 32] / [r*8 +: 8] / bit r.
    parameter [NUM_RULES*32-1:0] RULE_BASE = {32'h80000000},
    parameter [NUM_RULES*32-1:0] RULE_SIZE = {32'h08000000},
    parameter [NUM_RULES*8-1:0]  RULE_PORT = {8'd0},
    parameter [NUM_RULES-1:0]    RULE_EN   = {1'b1},
    parameter [NUM_RULES-1:0]    RULE_EXEC = {1'b1}  // instruction fetch allowed
) (
    input         clk,
    input         rst_n,
    // Upstream slave-facing port (from the arbiter)
    input  [31:0] s_axi_araddr,
    input  [ 2:0] s_axi_arprot,
    input         s_axi_arvalid,
    output        s_axi_arready,
    output reg [31:0] s_axi_rdata,
    output reg [ 1:0] s_axi_rresp,
    output        s_axi_rvalid,
    input         s_axi_rready,
    input  [31:0] s_axi_awaddr,
    input  [ 2:0] s_axi_awprot,
    input         s_axi_awvalid,
    output        s_axi_awready,
    input  [31:0] s_axi_wdata,
    input  [ 3:0] s_axi_wstrb,
    input         s_axi_wvalid,
    output        s_axi_wready,
    output reg [ 1:0] s_axi_bresp,
    output        s_axi_bvalid,
    input         s_axi_bready,
    // Downstream master-facing ports (to devices), flattened
    output [NUM_SLAVES*32-1:0] m_axi_araddr,
    output [NUM_SLAVES*3-1:0]  m_axi_arprot,
    output [NUM_SLAVES-1:0]    m_axi_arvalid,
    input  [NUM_SLAVES-1:0]    m_axi_arready,
    input  [NUM_SLAVES*32-1:0] m_axi_rdata,
    input  [NUM_SLAVES*2-1:0]  m_axi_rresp,
    input  [NUM_SLAVES-1:0]    m_axi_rvalid,
    output [NUM_SLAVES-1:0]    m_axi_rready,
    output [NUM_SLAVES*32-1:0] m_axi_awaddr,
    output [NUM_SLAVES*3-1:0]  m_axi_awprot,
    output [NUM_SLAVES-1:0]    m_axi_awvalid,
    input  [NUM_SLAVES-1:0]    m_axi_awready,
    output [NUM_SLAVES*32-1:0] m_axi_wdata,
    output [NUM_SLAVES*4-1:0]  m_axi_wstrb,
    output [NUM_SLAVES-1:0]    m_axi_wvalid,
    input  [NUM_SLAVES-1:0]    m_axi_wready,
    input  [NUM_SLAVES*2-1:0]  m_axi_bresp,
    input  [NUM_SLAVES-1:0]    m_axi_bvalid,
    output [NUM_SLAVES-1:0]    m_axi_bready
);
  localparam [1:0] RESP_DECERR = 2'b11;

  // Read FSM (AR/R):
  // State    Action                                    Next state
  // RD_IDLE  Decode/forward live AR; latch route        ar_fire -> RD_RESP
  // RD_RESP  Route R from rd_sel_r (or drive DECERR)     r_fire -> RD_IDLE
  // Write FSM (AW/W/B):
  // State    Action                                    Next state
  // WR_DATA  Decode/forward AW and W independently      both done -> WR_RESP
  //          Latch AW route; stop each accepted channel
  // WR_RESP  Route B from wr_sel_r (or drive DECERR)     b_fire -> WR_DATA
  // All unlisted conditions hold the current state.
  // Decoding uses the payload held stable by the master while VALID is high
  // (AXI A3.2.1). This internal interconnect adds a combinational decode
  // path between registered endpoints; no separate decode cycle is needed.
  // W waits for a valid AW address or the route of an already accepted AW.
  localparam RD_IDLE = 1'b0;
  localparam RD_RESP = 1'b1;
  localparam WR_DATA = 1'b0;
  localparam WR_RESP = 1'b1;

  reg rd_state, rd_next_state;
  reg wr_state, wr_next_state;
  // One-hot target port; all-zero selects the internal DECERR slave.
  reg [NUM_SLAVES-1:0] rd_sel_r, wr_sel_r;
  reg aw_done, w_done;

  // ---------------------------------------------------------------------
  // Address decoder: first matching enabled rule wins. Returns one-hot port.
  // ---------------------------------------------------------------------
  function [NUM_SLAVES-1:0] decode;
    input [31:0] addr;
    input        instruction;
    integer r, p;
    reg found;
    begin
      decode = {NUM_SLAVES{1'b0}};
      found = 1'b0;
      for (r = 0; r < NUM_RULES; r = r + 1) begin
        if (!found && RULE_EN[r] &&
            ((addr - RULE_BASE[r*32 +: 32]) < RULE_SIZE[r*32 +: 32])) begin
          found = 1'b1;
          for (p = 0; p < NUM_SLAVES; p = p + 1) begin
            if ((RULE_PORT[r*8 +: 8] == p[7:0]) &&
                (!instruction || RULE_EXEC[r]))
              decode[p] = 1'b1;
          end
        end
      end
    end
  endfunction

  wire [NUM_SLAVES-1:0] rd_decode = decode(s_axi_araddr, s_axi_arprot[2]);
  wire [NUM_SLAVES-1:0] wr_decode = decode(s_axi_awaddr, 1'b0);
  // AW may already have completed while W is still pending. Live AWADDR
  // can then describe another transaction, so W must use the saved route.
  wire [NUM_SLAVES-1:0] wr_request_sel = aw_done ? wr_sel_r : wr_decode;
  wire wr_target_valid = aw_done || s_axi_awvalid;
  wire wr_request_hit = |wr_request_sel;
  wire wr_address_hit = |wr_decode;
  wire rd_request_hit = |rd_decode;
  wire rd_hit = |rd_sel_r;
  wire wr_hit = |wr_sel_r;
  // AWPROT is forwarded only; no decode policy depends on it today.

  wire rd_addr_phase = rst_n && (rd_state == RD_IDLE);
  wire rd_resp_phase = rst_n && (rd_state == RD_RESP);
  wire wr_data_phase = rst_n && (wr_state == WR_DATA);
  wire wr_resp_phase = rst_n && (wr_state == WR_RESP);

  // ---------------------------------------------------------------------
  // Downstream request routing: payload broadcast, VALID one-hot.
  // ---------------------------------------------------------------------
  assign m_axi_araddr  = {NUM_SLAVES{s_axi_araddr}};
  assign m_axi_arprot  = {NUM_SLAVES{s_axi_arprot}};
  assign m_axi_arvalid = {NUM_SLAVES{rd_addr_phase && s_axi_arvalid}} & rd_decode;
  assign m_axi_rready  = {NUM_SLAVES{rd_resp_phase && s_axi_rready}} & rd_sel_r;

  assign m_axi_awaddr  = {NUM_SLAVES{s_axi_awaddr}};
  assign m_axi_awprot  = {NUM_SLAVES{s_axi_awprot}};
  assign m_axi_awvalid = {NUM_SLAVES{wr_data_phase && !aw_done && s_axi_awvalid}} &
                         wr_decode;
  assign m_axi_wdata   = {NUM_SLAVES{s_axi_wdata}};
  assign m_axi_wstrb   = {NUM_SLAVES{s_axi_wstrb}};
  assign m_axi_wvalid  = {NUM_SLAVES{wr_data_phase && !w_done && s_axi_wvalid &&
                                   wr_target_valid}} & wr_request_sel;
  assign m_axi_bready  = {NUM_SLAVES{wr_resp_phase && s_axi_bready}} & wr_sel_r;

  // ---------------------------------------------------------------------
  // Upstream response muxes (AND-OR with the one-hot select).
  // A miss is answered locally: accept the request, return DECERR.
  // ---------------------------------------------------------------------
  wire sel_arready = |(m_axi_arready & rd_decode);
  wire sel_rvalid  = |(m_axi_rvalid  & rd_sel_r);
  wire sel_awready = |(m_axi_awready & wr_decode);
  wire sel_wready  = |(m_axi_wready  & wr_request_sel);
  wire sel_bvalid  = |(m_axi_bvalid  & wr_sel_r);

  assign s_axi_arready = rd_addr_phase && (rd_request_hit ? sel_arready : 1'b1);
  assign s_axi_rvalid  = rd_resp_phase && (rd_hit ? sel_rvalid  : 1'b1);
  assign s_axi_awready = wr_data_phase && !aw_done &&
                         (wr_address_hit ? sel_awready : 1'b1);
  assign s_axi_wready  = wr_data_phase && !w_done && wr_target_valid &&
                         (wr_request_hit ? sel_wready : 1'b1);
  assign s_axi_bvalid  = wr_resp_phase && (wr_hit ? sel_bvalid  : 1'b1);

  integer i;
  always @(*) begin
    s_axi_rdata = 32'b0;
    s_axi_rresp = rd_hit ? 2'b00 : RESP_DECERR;
    s_axi_bresp = wr_hit ? 2'b00 : RESP_DECERR;
    for (i = 0; i < NUM_SLAVES; i = i + 1) begin
      s_axi_rdata = s_axi_rdata | (m_axi_rdata[i*32 +: 32] & {32{rd_sel_r[i]}});
      s_axi_rresp = s_axi_rresp | (m_axi_rresp[i*2 +: 2]   & {2{rd_sel_r[i]}});
      s_axi_bresp = s_axi_bresp | (m_axi_bresp[i*2 +: 2]   & {2{wr_sel_r[i]}});
    end
  end

  wire ar_fire = s_axi_arvalid && s_axi_arready;
  wire r_fire  = s_axi_rvalid  && s_axi_rready;
  wire aw_fire = s_axi_awvalid && s_axi_awready;
  wire w_fire  = s_axi_wvalid  && s_axi_wready;
  wire b_fire  = s_axi_bvalid  && s_axi_bready;

  // ---------------------------------------------------------------------
  // State registers
  // ---------------------------------------------------------------------
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rd_state <= RD_IDLE;
      wr_state <= WR_DATA;
    end else begin
      rd_state <= rd_next_state;
      wr_state <= wr_next_state;
    end
  end

  // ---------------------------------------------------------------------
  // Next-state logic
  // ---------------------------------------------------------------------
  always @(*) begin
    rd_next_state = rd_state;
    case (rd_state)
      RD_IDLE: if (ar_fire)       rd_next_state = RD_RESP;
      RD_RESP: if (r_fire)        rd_next_state = RD_IDLE;
      default:                    rd_next_state = RD_IDLE;
    endcase

    wr_next_state = wr_state;
    case (wr_state)
      WR_DATA: if ((aw_done || aw_fire) && (w_done || w_fire))
                                  wr_next_state = WR_RESP;
      WR_RESP: if (b_fire)        wr_next_state = WR_DATA;
      default:                    wr_next_state = WR_DATA;
    endcase
  end

  // ---------------------------------------------------------------------
  // Data registers: route selection and per-channel completion flags
  // ---------------------------------------------------------------------
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rd_sel_r <= {NUM_SLAVES{1'b0}};
    end else if (ar_fire) begin
      rd_sel_r <= rd_decode;
    end
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wr_sel_r <= {NUM_SLAVES{1'b0}};
      aw_done  <= 1'b0;
      w_done   <= 1'b0;
    end else begin
      if (b_fire) begin
        aw_done <= 1'b0;
        w_done  <= 1'b0;
      end else begin
        if (aw_fire) begin
          wr_sel_r <= wr_decode;
          aw_done <= 1'b1;
        end
        if (w_fire)  w_done  <= 1'b1;
      end
    end
  end
endmodule
