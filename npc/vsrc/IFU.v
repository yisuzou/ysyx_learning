// Read-only 32-bit AXI4-Lite master, with one outstanding fetch.
// Fetches a latched PC through SEND_AR/WAIT_R, then holds the instruction in
// SEND_ID until IDU accepts it. WAIT_PC accepts the next PC message from WBU.
// Memory/DPI access belongs to the slave (MEM), not to this master.
// Future AXI4 IDs/bursts belong at this master boundary; none are used here.
module IFU (
    input         clk,
    input         rst_n,
    //input  [31:0] pc,
    //input         mem_valid,
    //input         memfinish,
    //output reg [31:0] inst,
    //output        ifu_valid,
    input  pc_valid,
    output pc_ready,
    input  [31:0] pc_data,
    //to idu
    output out_valid,
    input  out_ready,

    output reg [31:0] out_inst,
    output reg [31:0] out_pc,

    // Read-only state observation for performance counters.  High while the
    // IFU holds no instruction and waits for the next PC message.
    output            dbg_wait_pc,

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
  localparam [2:0] WAIT_PC = 3'd0,
                   SEND_AR = 3'd1,
                   WAIT_R = 3'd2,
                   SEND_ID = 3'd3,
                   FAULT = 3'd4;

  localparam [1:0] RESP_OKAY = 2'b00;
  localparam [31:0] INST_NOP = 32'h00000013;

  // State    Action                                 Transition
  // WAIT_PC  Assert pc_ready; latch pc_data          pc_fire -> SEND_AR
  // SEND_AR  Hold ARVALID and the latched PC         ar_fire -> WAIT_R
  // WAIT_R   Assert RREADY; latch instruction/fault  r_fire, OKAY -> SEND_ID
  //                                                 r_fire, error -> FAULT
  // SEND_ID  Hold out_valid, out_inst and out_pc     out_fire -> WAIT_PC
  // FAULT    No traffic; preserve any latched fault  reset only
  // An invalid state enters FAULT without setting ifu_error.
  // AW/W/B have no FSM: this master never writes or accepts write responses.
  // Unlisted conditions hold state. Reset sets inst_q to NOP, clears the fault,
  // and seeds SEND_AR with PC 0x80000000; the first fetch needs no PC handshake.
  reg [2:0] state;
  reg [31:0] fetch_pc_q;
  reg [31:0] inst_q;
  wire pc_fire;
  wire out_fire;
  wire ar_fire;
  wire r_fire;

  assign pc_ready = rst_n && (state == WAIT_PC);
  assign dbg_wait_pc = (state == WAIT_PC);
  assign out_valid = rst_n && (state == SEND_ID);
  assign out_pc = fetch_pc_q;
  assign out_inst = inst_q;
  assign pc_fire = pc_valid && pc_ready;
  assign out_fire = out_valid && out_ready;
  assign m_axi_araddr = fetch_pc_q;
  assign m_axi_arvalid = rst_n && (state == SEND_AR);
  assign m_axi_rready = rst_n && (state == WAIT_R);
  assign ar_fire = m_axi_arvalid && m_axi_arready;
  assign r_fire = m_axi_rvalid && m_axi_rready;
  assign ifu_error_addr = fetch_pc_q;

  // ARPROT[2:0] = instruction / secure / privileged (M-mode).
  assign m_axi_arprot = 3'b101;
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

  // FSM state, fetched PC/instruction, and sticky fault registers.
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= SEND_AR;
      fetch_pc_q <= 32'h80000000;
      inst_q <= INST_NOP;
      ifu_error <= 1'b0;
      ifu_error_resp <= 2'b00;
    end else begin
      case (state)
        WAIT_PC : begin
          if (pc_fire) begin
            state <= SEND_AR;
            fetch_pc_q <= pc_data;
          end
        end
        SEND_AR : begin
          if (ar_fire) begin
            state <= WAIT_R;
          end
        end
        WAIT_R : begin
          if (r_fire) begin
            if (m_axi_rresp == RESP_OKAY) begin
              state <= SEND_ID;
              inst_q <= m_axi_rdata;
            end else begin
              state <= FAULT;
              inst_q <= INST_NOP;
              ifu_error <= 1'b1;
              ifu_error_resp <= m_axi_rresp;
            end
          end
        end
        SEND_ID : begin
          if (out_fire) begin
            state <= WAIT_PC;
            // Keep inst_q; out_valid is low after leaving SEND_ID.
          end
        end
        FAULT : begin
          // Remain in FAULT until reset.
        end
        default : begin
          state <= FAULT;
        end
      endcase
    end
  end

endmodule
