// 32-bit AXI4-Lite load/store master. One CPU request may become two aligned
// single-beat RAM transactions; MMIO reads always use the full bus width.
// No DPI calls belong here. Future AXI4 IDs/bursts extend this master boundary.
module LSU #(
    parameter RANDOM_DELAY = 1,
    parameter [31:0] PMEM_BASE = 32'h80000000,
    parameter [31:0] PMEM_SIZE = 32'h08000000
) (
    input         clk,
    input         rst_n,
    input  [1:0]  mem_rbhw,
    input  [31:0] mem_addr,
    input         mem_valid,
    input         wen,
    input  [1:0]  mem_wbhw,
    input  [31:0] mem_wdata_raw,
    input         isign,
    input         lsu_finish,
    output reg [31:0] mem_rdata_r,
    output        lsu_done,
    output reg        lsu_error,
    output reg [1:0]  lsu_error_resp,
    output reg [31:0] lsu_error_addr,
    output            lsu_error_write,
    // Read address/data channels
    output [31:0] m_axi_araddr,
    output [2:0]  m_axi_arprot,
    output        m_axi_arvalid,
    input         m_axi_arready,
    input  [31:0] m_axi_rdata,
    input  [1:0]  m_axi_rresp,
    input         m_axi_rvalid,
    output        m_axi_rready,
    // Write address/data/response channels
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
  localparam [1:0] MEM_BYTE = 2'd1;
  localparam [1:0] MEM_HALF = 2'd2;
  localparam [1:0] MEM_WORD = 2'd3;
  localparam [1:0] RESP_OKAY = 2'b00;
  localparam [1:0] RESP_SLVERR = 2'b10;
  localparam [1:0] RESP_DECERR = 2'b11;
  localparam [3:0] IDLE    = 4'd0;
  localparam [3:0] CHECK   = 4'd1;
  localparam [3:0] DELAY   = 4'd2;
  localparam [3:0] RD_ADDR = 4'd3;
  localparam [3:0] RD_DATA = 4'd4;
  localparam [3:0] WR_SEND = 4'd5;
  localparam [3:0] WR_RESP = 4'd6;
  localparam [3:0] DONE    = 4'd7;
  localparam [3:0] FAULT   = 4'd8;

  // State    Action                            Transition
  // IDLE     Latch a valid CPU request          mem_valid -> CHECK
  // CHECK    Validate width/cross-word span     valid -> DELAY; error -> FAULT
  // DELAY    Delay launch, not an active VALID  delay_done -> RD_ADDR/WR_SEND
  // RD_ADDR  Hold ARVALID/ARADDR                ar_fire -> RD_DATA
  // RD_DATA  Receive one aligned word          error -> FAULT; final -> DONE
  //                                            first of two -> DELAY
  // WR_SEND  Independent AW/W handshakes        both accepted -> WR_RESP
  // WR_RESP  Receive write acknowledgement      error -> FAULT; final -> DONE
  //                                            first of two -> DELAY
  // DONE     Hold result and completion        lsu_finish -> IDLE
  // FAULT    Hold fault, no further requests    reset only
  // All other conditions hold state; reset discards requests/responses.
  reg [3:0] state, next_state;
  reg [31:0] req_addr_r, word_addr_r, first_read_r;
  reg [1:0] size_r;
  reg sign_r, write_r, second_r;
  reg [63:0] write_data_r;
  reg [7:0] write_strb_r;
  reg aw_sent, w_sent;

  function [2:0] access_bytes;
    input [1:0] size;
    begin
      case (size)
        MEM_BYTE: access_bytes = 3'd1;
        MEM_HALF: access_bytes = 3'd2;
        MEM_WORD: access_bytes = 3'd4;
        default:  access_bytes = 3'd0;
      endcase
    end
  endfunction

  function [7:0] access_mask;
    input [1:0] size;
    begin
      case (size)
        MEM_BYTE: access_mask = 8'h01;
        MEM_HALF: access_mask = 8'h03;
        MEM_WORD: access_mask = 8'h0f;
        default:  access_mask = 8'h00;
      endcase
    end
  endfunction

  function in_ram_span;
    input [31:0] addr;
    input [2:0] bytes;
    begin
      in_ram_span = (bytes != 3'd0) && (PMEM_SIZE >= {29'b0, bytes}) &&
                    (addr >= PMEM_BASE) &&
                    ((addr - PMEM_BASE) <= (PMEM_SIZE - {29'b0, bytes}));
    end
  endfunction

  function [31:0] extend_load;
    input [31:0] data;
    input [1:0] size;
    input sign_extend;
    begin
      case (size)
        MEM_BYTE: extend_load = {{24{data[7] & sign_extend}}, data[7:0]};
        MEM_HALF: extend_load = {{16{data[15] & sign_extend}}, data[15:0]};
        MEM_WORD: extend_load = data;
        default:  extend_load = 32'b0;
      endcase
    end
  endfunction

  wire [2:0] bytes = access_bytes(size_r);
  wire [3:0] end_offset = {2'b0, req_addr_r[1:0]} + {1'b0, bytes};
  wire split_access = end_offset > 4'd4;
  wire original_in_ram = (req_addr_r >= PMEM_BASE) &&
                         ((req_addr_r - PMEM_BASE) < PMEM_SIZE);
  wire invalid_request = (bytes == 3'd0) ||
                         (split_access && !in_ram_span(req_addr_r, bytes));
  wire [1:0] check_resp = (split_access && original_in_ram) ?
                          RESP_DECERR : RESP_SLVERR;
  wire [1:0] incoming_size = wen ? mem_wbhw : mem_rbhw;
  wire [4:0] incoming_shift = {mem_addr[1:0], 3'b000};
  wire [4:0] read_shift = {req_addr_r[1:0], 3'b000};
  wire [63:0] read_words = second_r ? {m_axi_rdata, first_read_r} :
                                    {32'b0, m_axi_rdata};
  wire [63:0] shifted_read = read_words >> read_shift;
  wire unused_read_high = &{1'b0, shifted_read[63:32]};

  wire delay_done;
  generate
    if (RANDOM_DELAY != 0) begin : g_random_delay
      random_delay lsu_delay (
          .clk(clk), .rst_n(rst_n), .req(state == DELAY), .gated(delay_done)
      );
    end else begin : g_no_delay
      assign delay_done = 1'b1;
    end
  endgenerate

  assign m_axi_araddr = word_addr_r;
  assign m_axi_arprot = 3'b001; // Secure, privileged data access.
  assign m_axi_arvalid = rst_n && (state == RD_ADDR);
  assign m_axi_rready = rst_n && (state == RD_DATA);
  assign m_axi_awaddr = word_addr_r;
  assign m_axi_awprot = 3'b001;
  assign m_axi_awvalid = rst_n && (state == WR_SEND) && !aw_sent;
  assign m_axi_wdata = second_r ? write_data_r[63:32] : write_data_r[31:0];
  assign m_axi_wstrb = second_r ? write_strb_r[7:4] : write_strb_r[3:0];
  assign m_axi_wvalid = rst_n && (state == WR_SEND) && !w_sent;
  assign m_axi_bready = rst_n && (state == WR_RESP);
  assign lsu_done = rst_n && (state == DONE);
  assign lsu_error_write = write_r;

  wire ar_fire = m_axi_arvalid && m_axi_arready;
  wire r_fire = m_axi_rvalid && m_axi_rready;
  wire aw_fire = m_axi_awvalid && m_axi_awready;
  wire w_fire = m_axi_wvalid && m_axi_wready;
  wire b_fire = m_axi_bvalid && m_axi_bready;
  wire next_beat = split_access && !second_r &&
                   ((r_fire && (m_axi_rresp == RESP_OKAY)) ||
                    (b_fire && (m_axi_bresp == RESP_OKAY)));

  // State register.
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) state <= IDLE;
    else state <= next_state;
  end

  // Next-state logic; active AXI VALID never depends on the random gate.
  always @(*) begin
    next_state = state;
    case (state)
      IDLE: if (mem_valid) next_state = CHECK;
      CHECK: next_state = invalid_request ? FAULT : DELAY;
      DELAY: if (delay_done) next_state = write_r ? WR_SEND : RD_ADDR;
      RD_ADDR: if (ar_fire) next_state = RD_DATA;
      RD_DATA: begin
        if (r_fire) begin
          if (m_axi_rresp != RESP_OKAY) next_state = FAULT;
          else next_state = next_beat ? DELAY : DONE;
        end
      end
      WR_SEND: begin
        if ((aw_sent || aw_fire) && (w_sent || w_fire)) next_state = WR_RESP;
      end
      WR_RESP: begin
        if (b_fire) begin
          if (m_axi_bresp != RESP_OKAY) next_state = FAULT;
          else next_state = next_beat ? DELAY : DONE;
        end
      end
      DONE: if (lsu_finish) next_state = IDLE;
      FAULT: begin end
      default: next_state = IDLE;
    endcase
  end

  // Request/result registers. CPU inputs are used only at request acceptance.
  // AW and W acceptance flags are separate and reset for every split beat.
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      req_addr_r <= 32'b0;
      word_addr_r <= 32'b0;
      size_r <= 2'b0;
      sign_r <= 1'b0;
      write_r <= 1'b0;
      second_r <= 1'b0;
      write_data_r <= 64'b0;
      write_strb_r <= 8'b0;
      first_read_r <= 32'b0;
      aw_sent <= 1'b0;
      w_sent <= 1'b0;
      mem_rdata_r <= 32'b0;
      lsu_error <= 1'b0;
      lsu_error_resp <= RESP_OKAY;
      lsu_error_addr <= 32'b0;
    end else begin
      if ((state == IDLE) && mem_valid) begin
        req_addr_r <= mem_addr;
        word_addr_r <= {mem_addr[31:2], 2'b00};
        size_r <= incoming_size;
        sign_r <= isign;
        write_r <= wen;
        second_r <= 1'b0;
        write_data_r <= {32'b0, mem_wdata_raw} << incoming_shift;
        write_strb_r <= access_mask(incoming_size) << mem_addr[1:0];
        first_read_r <= 32'b0;
        aw_sent <= 1'b0;
        w_sent <= 1'b0;
        mem_rdata_r <= 32'b0;
      end
      if (aw_fire) aw_sent <= 1'b1;
      if (w_fire) w_sent <= 1'b1;
      if (next_beat) begin
        word_addr_r <= word_addr_r + 32'd4;
        second_r <= 1'b1;
        aw_sent <= 1'b0;
        w_sent <= 1'b0;
      end
      if (r_fire && (m_axi_rresp == RESP_OKAY)) begin
        if (next_beat) first_read_r <= m_axi_rdata;
        else mem_rdata_r <= extend_load(shifted_read[31:0], size_r, sign_r);
      end
      if ((state == CHECK) && invalid_request) begin
        lsu_error <= 1'b1;
        lsu_error_resp <= check_resp;
        lsu_error_addr <= req_addr_r;
      end
      if (r_fire && (m_axi_rresp != RESP_OKAY)) begin
        lsu_error <= 1'b1;
        lsu_error_resp <= m_axi_rresp;
        lsu_error_addr <= word_addr_r;
      end
      if (b_fire && (m_axi_bresp != RESP_OKAY)) begin
        lsu_error <= 1'b1;
        lsu_error_resp <= m_axi_bresp;
        lsu_error_addr <= word_addr_r;
      end
    end
  end
endmodule
