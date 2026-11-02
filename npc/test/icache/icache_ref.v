// RV32I direct-mapped blocking instruction cache, independent reference.
// Upstream: AXI4-Lite read-only slave (replaces IFU view of the bus).
// Downstream: AXI4 full read master, one INCR burst per line fill.
// Geometry: 16 lines x 16 B, 32-bit words => tag addr[31:8], index addr[7:4],
// word select addr[3:2]. Fetch addresses are assumed 4-byte aligned (RV32I).
module icache_ref (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        s_invalidate,

    input  wire [31:0] s_axi_araddr,
    input  wire [2:0]  s_axi_arprot,
    input  wire        s_axi_arvalid,
    output wire        s_axi_arready,
    output wire [31:0] s_axi_rdata,
    output wire [1:0]  s_axi_rresp,
    output wire        s_axi_rvalid,
    input  wire        s_axi_rready,

    output wire [31:0] m_axi_araddr,
    output wire [2:0]  m_axi_arprot,
    output wire [3:0]  m_axi_arlen,
    output wire [2:0]  m_axi_arsize,
    output wire [1:0]  m_axi_arburst,
    output wire        m_axi_arvalid,
    input  wire        m_axi_arready,
    input  wire [31:0] m_axi_rdata,
    input  wire [1:0]  m_axi_rresp,
    input  wire        m_axi_rlast,
    input  wire        m_axi_rvalid,
    output wire        m_axi_rready
);

    localparam LINES = 16;
    localparam IDX_W = 4;
    localparam TAG_W = 24;
    localparam BEATS = 4;

    localparam [3:0] ARLEN_V   = BEATS - 1;
    localparam [2:0] ARSIZE_V  = 3'd2;
    localparam [1:0] ARBURST_V = 2'b01;

    localparam [1:0] RESP_OKAY   = 2'b00;
    localparam [1:0] RESP_SLVERR = 2'b10;

    localparam [2:0] ST_IDLE   = 3'd0;
    localparam [2:0] ST_CHECK  = 3'd1;
    localparam [2:0] ST_AXI_AR = 3'd2;
    localparam [2:0] ST_AXI_R  = 3'd3;
    localparam [2:0] ST_OVER   = 3'd4;
    localparam [2:0] ST_COMMIT = 3'd5;
    localparam [2:0] ST_RESP   = 3'd6;

    reg [2:0]           state;
    reg [31:0]          addr_q;
    reg [IDX_W-1:0]     beat_q;
    reg [128-1:0]       line_buf;
    reg                 err_q;
    reg [1:0]           err_resp_q;
    reg                 inval_pend;
    reg [31:0]          rdata_q;
    reg [1:0]           rresp_q;
    reg [LINES-1:0]     valid_arr;
    reg [TAG_W-1:0]     tag_arr   [0:LINES-1];
    reg [128-1:0]       data_arr  [0:LINES-1];

    wire s_ar_fire = s_axi_arvalid && s_axi_arready;
    wire s_r_fire  = s_axi_rvalid  && s_axi_rready;
    wire m_ar_fire = m_axi_arvalid && m_axi_arready;
    wire m_r_fire  = m_axi_rvalid  && m_axi_rready;

    wire [TAG_W-1:0] req_tag = addr_q[31:8];
    wire [IDX_W-1:0] req_idx = addr_q[7:4];
    wire [1:0]       req_sel = addr_q[3:2];

    wire hit      = valid_arr[req_idx] && (tag_arr[req_idx] == req_tag);
    wire [31:0]   hit_word   = data_arr[req_idx][req_sel*32 +: 32];
    wire [31:0]   miss_word  = line_buf[req_sel*32 +: 32];

    wire refilling  = (state == ST_AXI_AR) || (state == ST_AXI_R) || (state == ST_OVER);
    // RLAST shorter or longer than ARLEN+1 violates the burst contract; the
    // partially transferred line must never be published.
    wire last_short = (state == ST_AXI_R) && m_r_fire && m_axi_rlast && (beat_q != BEATS-1);
    wire last_long  = (state == ST_AXI_R) && m_r_fire && !m_axi_rlast && (beat_q == BEATS-1);
    wire rresp_bad  = ((state == ST_AXI_R) || (state == ST_OVER)) && m_r_fire
                      && (m_axi_rresp != RESP_OKAY);
    wire anomaly    = last_short || last_long;
    wire commit_ok  = !err_q && !inval_pend && !s_invalidate;

    reg [2:0] next_state;
    always @(*) begin
        next_state = state;
        case (state)
            ST_IDLE:   if (s_ar_fire)                        next_state = ST_CHECK;
            ST_CHECK:  next_state = hit ? ST_RESP : ST_AXI_AR;
            ST_AXI_AR: if (m_ar_fire)                        next_state = ST_AXI_R;
            ST_AXI_R:  if (m_r_fire && (m_axi_rlast || beat_q == BEATS-1))
                                                            next_state = last_long ? ST_OVER : ST_COMMIT;
            ST_OVER:   if (m_r_fire && m_axi_rlast)          next_state = ST_COMMIT;
            ST_COMMIT:                                       next_state = ST_RESP;
            ST_RESP:   if (s_r_fire)                         next_state = ST_IDLE;
            default:                                         next_state = ST_IDLE;
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= ST_IDLE;
            addr_q     <= 32'h0;
            beat_q     <= 'd0;
            line_buf   <= 128'h0;
            err_q      <= 1'b0;
            err_resp_q <= RESP_OKAY;
            inval_pend <= 1'b0;
            rdata_q    <= 32'h0;
            rresp_q    <= RESP_OKAY;
            valid_arr  <= {LINES{1'b0}};
        end else begin
            state <= next_state;

            if (s_ar_fire)
                addr_q <= s_axi_araddr;

            if (next_state == ST_AXI_AR) begin
                beat_q     <= 'd0;
                err_q      <= 1'b0;
                err_resp_q <= RESP_OKAY;
            end else if ((state == ST_AXI_R) && m_r_fire && (beat_q < BEATS-1)) begin
                beat_q <= beat_q + 1'b1;
            end

            if ((state == ST_AXI_R) && m_r_fire)
                line_buf[beat_q*32 +: 32] <= m_axi_rdata;

            if (rresp_bad && !err_q) begin
                err_q      <= 1'b1;
                err_resp_q <= m_axi_rresp;
            end else if (anomaly && !err_q) begin
                err_q      <= 1'b1;
                err_resp_q <= RESP_SLVERR;
            end

            if (s_invalidate) begin
                valid_arr  <= {LINES{1'b0}};
                inval_pend <= refilling;
            end else begin
                if ((state == ST_COMMIT) && commit_ok)
                    valid_arr[req_idx] <= 1'b1;
                if (state == ST_RESP)
                    inval_pend <= 1'b0;
            end

            if (state == ST_CHECK && hit) begin
                rdata_q <= hit_word;
                rresp_q <= RESP_OKAY;
            end else if (state == ST_COMMIT) begin
                rdata_q <= miss_word;
                rresp_q <= err_q ? err_resp_q : RESP_OKAY;
            end
        end
    end

    // Big arrays are never reset; writes are disabled while reset is asserted.
    always @(posedge clk) begin
        if (rst_n && (state == ST_COMMIT) && commit_ok) begin
            data_arr[req_idx] <= line_buf;
            tag_arr[req_idx]  <= req_tag;
        end
    end

    assign s_axi_arready = rst_n && (state == ST_IDLE);
    assign s_axi_rvalid  = rst_n && (state == ST_RESP);
    assign s_axi_rdata   = rdata_q;
    assign s_axi_rresp   = rresp_q;

    assign m_axi_arvalid = rst_n && (state == ST_AXI_AR);
    assign m_axi_araddr  = {addr_q[31:4], 4'b0};
    assign m_axi_arprot  = 3'b101;
    assign m_axi_arlen   = ARLEN_V;
    assign m_axi_arsize  = ARSIZE_V;
    assign m_axi_arburst = ARBURST_V;
    assign m_axi_rready  = rst_n && ((state == ST_AXI_R) || (state == ST_OVER));

    // ARPROT policy (instruction access, secure, privileged) is enforced by
    // the interconnect; the refill re-drives the fixed fetch attribute.
    // addr_q[1:0]: fetches are word aligned, byte offset carries no meaning.
    wire unused_inputs = &{1'b0, s_axi_arprot, addr_q[1:0], 1'b0};

endmodule
