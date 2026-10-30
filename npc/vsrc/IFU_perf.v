// Read-only 32-bit AXI4-Lite master, with one outstanding fetch.
// IDLE completes the entire AR/R transaction; WAIT holds the executing inst.
// Memory/DPI access belongs to the slave (MEM), not to this master.
// Future AXI4 IDs/bursts belong at this master boundary; none are used here.
module IFU #(
    parameter RANDOM_DELAY = 1
) (
    input         clk,
    input         rst_n,
    input  [31:0] pc,
    input         mem_valid,
    input         memfinish,
    output reg [31:0] inst,
    output        ifu_valid,
    // Sticky fetch fault: consumed response is not an executable instruction.
    // These outputs remain valid until reset when ifu_error is asserted.
    output reg        ifu_error,
    output reg [ 1:0] ifu_error_resp,
    output     [31:0] ifu_error_addr,
    // Read address channel
    output reg [31:0] m_axi_araddr,
    output     [ 2:0] m_axi_arprot,
    output            m_axi_arvalid,
    input             m_axi_arready,
    // Read data channel
    input  [31:0] m_axi_rdata,
    input  [ 1:0] m_axi_rresp,
    input         m_axi_rvalid,
    output        m_axi_rready,
    // Unused write address channel
    output [31:0] m_axi_awaddr,
    output [ 2:0] m_axi_awprot,
    output        m_axi_awvalid,
    input         m_axi_awready,
    // Unused write data channel
    output [31:0] m_axi_wdata,
    output [ 3:0] m_axi_wstrb,
    output        m_axi_wvalid,
    input         m_axi_wready,
    // Unused write response channel
    input  [ 1:0] m_axi_bresp,
    input         m_axi_bvalid,
    output        m_axi_bready
);
  localparam IDLE = 1'b0;
  localparam WAIT = 1'b1;
  localparam [1:0] FETCH_DELAY = 2'd0;
  localparam [1:0] FETCH_AR    = 2'd1;
  localparam [1:0] FETCH_R     = 2'd2;
  localparam [1:0] FETCH_FAULT = 2'd3;
  localparam [1:0] RESP_OKAY = 2'b00;
  localparam [31:0] INST_NOP = 32'h00000013;

  // Main/phase state    Action                       Transition
  // IDLE/FETCH_DELAY    Delay request launch          delay_done -> FETCH_AR
  //                    Latch PC on launch
  // IDLE/FETCH_AR       Hold ARVALID and ARADDR        ar_fire -> FETCH_R
  // IDLE/FETCH_R        Assert RREADY                 r_fire, OKAY -> WAIT
  //                    Latch returned instruction    r_fire, error -> FETCH_FAULT
  // IDLE/FETCH_FAULT    Hold sticky fault; no traffic  reset only
  // WAIT               Hold inst and ifu_valid        !mem_valid || memfinish
  //                    No AR/R activity               -> IDLE/FETCH_DELAY
  // AW/W/B have no FSM: this master never writes or accepts write responses.
  // Unlisted conditions hold state. Reset discards any pending fetch/inst.
  reg state, next_state;
  reg [1:0] fetch_state, fetch_next_state;

  wire fetch_delay_req = (state == IDLE) && (fetch_state == FETCH_DELAY);
  wire fetch_delay_done;
  generate
    if (RANDOM_DELAY != 0) begin : g_random_delay
      random_delay ifu_delay (
          .clk(clk), .rst_n(rst_n),
          .req(fetch_delay_req), .gated(fetch_delay_done)
      );
    end else begin : g_no_delay
      assign fetch_delay_done = 1'b1;
    end
  endgenerate

  // ARPROT[2:0] = instruction / secure / privileged (M-mode).
  assign m_axi_arprot = 3'b101;
  // VALID depends only on registered state, never on ARREADY or delay gating.
  // Once launched, ARVALID and its latched payload persist until handshake.
  assign m_axi_arvalid = rst_n && (state == IDLE) && (fetch_state == FETCH_AR);
  // RREADY is asserted while expecting a response, independently of RVALID.
  assign m_axi_rready = rst_n && (state == IDLE) && (fetch_state == FETCH_R);
  assign ifu_valid = rst_n && (state == WAIT);
  assign ifu_error_addr = m_axi_araddr;
  // IFU does not write, so tie off unused write channels to avoid Xs in simulation.
  assign m_axi_awaddr  = 32'b0;
  assign m_axi_awprot  = 3'b0;
  assign m_axi_awvalid = 1'b0;
  assign m_axi_wdata   = 32'b0;
  assign m_axi_wstrb   = 4'b0;
  assign m_axi_wvalid  = 1'b0;
  assign m_axi_bready  = 1'b0;
  wire unused_write_inputs = &{1'b0, m_axi_awready, m_axi_wready,
                               m_axi_bvalid, m_axi_bresp};

  wire ar_fire = m_axi_arvalid && m_axi_arready; // AR handshake
  wire r_fire = m_axi_rvalid && m_axi_rready;  // R handshake
  // Preserve the current execution contract: non-memory instructions execute
  // in one WAIT cycle, whereas memory instructions wait for completion.
  wire execute_done = !mem_valid || memfinish;
  wire fetch_launch = fetch_delay_req && fetch_delay_done;

  // State registers only.
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= IDLE;
      fetch_state <= FETCH_DELAY;
    end else begin
      state <= next_state;
      fetch_state <= fetch_next_state;
    end
  end

  // Combinational next-state logic.
  always @(*) begin
    next_state = state;
    fetch_next_state = fetch_state;
    case (state)
      IDLE: begin
        case (fetch_state)
          FETCH_DELAY: begin
            if (fetch_delay_done) fetch_next_state = FETCH_AR;
          end
          FETCH_AR: begin
            if (ar_fire) fetch_next_state = FETCH_R;
          end
          FETCH_R: begin
            if (r_fire) begin
              if (m_axi_rresp == RESP_OKAY) begin
                next_state = WAIT;
                fetch_next_state = FETCH_DELAY;
              end else begin
                fetch_next_state = FETCH_FAULT;
              end
            end
          end
          FETCH_FAULT: begin end
          default: fetch_next_state = FETCH_DELAY;
        endcase
      end
      WAIT: begin
        fetch_next_state = FETCH_DELAY;
        if (execute_done) next_state = IDLE;
      end
      default: begin
        next_state = IDLE;
        fetch_next_state = FETCH_DELAY;
      end
    endcase
  end

  // Payload registers only. PC is sampled before ARVALID rises; neither live
  // PC nor slave RDATA can change an already issued request/executing inst.
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      m_axi_araddr <= 32'b0;
      inst <= INST_NOP;
      ifu_error <= 1'b0;
      ifu_error_resp <= RESP_OKAY;
    end else begin
      if (fetch_launch) m_axi_araddr <= pc; //延迟完毕且处于IDLE状态时，发起新的AR请求，锁存PC地址
      if (r_fire) begin
        if (m_axi_rresp == RESP_OKAY) begin
          inst <= m_axi_rdata;
        end else begin
          inst <= INST_NOP;
          ifu_error <= 1'b1;
          ifu_error_resp <= m_axi_rresp;
        end
      end
      if ((state == WAIT) && execute_done) inst <= INST_NOP;
    end
  end
endmodule
