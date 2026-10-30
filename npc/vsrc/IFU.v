// Read-only 32-bit AXI4-Lite master, with one outstanding fetch.
// IDLE completes the entire AR/R transaction; WAIT holds the executing inst.
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

  // Preserve the current execution contract: non-memory instructions execute
  // in one WAIT cycle, whereas memory instructions wait for completion.
  //wire execute_done = !mem_valid || memfinish;
  //wire fetch_launch = fetch_delay_req && fetch_delay_done;

  // State registers only.
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= SEND_AR;
      fetch_pc_q <= 32'h80000000;
      inst_q <= INST_NOP;
      ifu_error <= 1'b0;
      ifu_error_resp <= 2'b00;
    end else begin
      //sate <= next_state;
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
            //inst_q <= INST_NOP; 不必要的寄存器开销
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

  // Combinational next-state logic.
  // always @(*) begin
  //   next_state = state;
  //   case (state)
  //     WAIT_PC : begin
  //       next_state = pc_fire ? SEND_AR : WAIT_PC;
  //     end
  //     SEND_AR : begin
  //       next_state = ar_fire ? WAIT_R : SEND_AR;
  //     end
  //     wait_R : begin
  //       if (r_fire) begin
  //         next_state = (m_axi_rresp == RESP_OKAY) ? SEND_ID : FAULT;
  //       end else begin
  //         next_state = WAIT_R;
  //       end
  //     end
  //
  //   endcase
  // end
  //
  // // Payload registers only. PC is sampled before ARVALID rises; neither live
  // // PC nor slave RDATA can change an already issued request/executing inst.
  // always @(posedge clk or negedge rst_n) begin
  //   if (!rst_n) begin
  //     m_axi_araddr <= 32'b0;
  //     inst <= INST_NOP;
  //     ifu_error <= 1'b0;
  //     ifu_error_resp <= RESP_OKAY;
  //   end else begin
  //     if (fetch_launch) m_axi_araddr <= pc; //延迟完毕且处于IDLE状态时，发起新的AR请求，锁存PC地址
  //     if (r_fire) begin
  //       if (m_axi_rresp == RESP_OKAY) begin
  //         inst <= m_axi_rdata;
  //       end else begin
  //         inst <= INST_NOP;
  //         ifu_error <= 1'b1;
  //         ifu_error_resp <= m_axi_rresp;
  //       end
  //     end
  //     if ((state == WAIT) && execute_done) inst <= INST_NOP;
  //   end
  // end
endmodule
