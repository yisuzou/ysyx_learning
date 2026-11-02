// 直接映射、阻塞式只读 cache，默认 16 块 x 4 B。
// 块数和块大小均为 2 的幂；块大小至少为 4 B，取指按 4 B 对齐。
// 一次只处理一个 PC；多字块通过 AXI4-Lite 顺序单字读完整回填。
module icache #(
  parameter integer LINE_COUNT = 16,
  parameter integer BLOCK_BYTES = 4
)(
  input clk,
  input rst_n,
  //communicate with ifu
  input if_pc_valid,
  output if_pc_ready,
  input [31:0] if_pc,
  //to ifu
  output [31:0] if_inst,
  output [1:0] if_inst_resp,
  output if_inst_valid,
  input if_inst_ready,
  //communicate with memory
  //axi4-lite interface
  // Read address channel
  output     [31:0] m_axi_araddr,
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
  localparam [2:0] WAIT_PC = 3'd0, //等待pc输入
                   CHECK = 3'd1, //检查cache命中或未命中
                   AXI_AR = 3'd2, //发送AXI读请求
                   AXI_R = 3'd3, //等待AXI读响应
                   RESP = 3'd4, //返回指令给ifu
                   COMMIT = 3'd5; //多字块收齐后统一提交
  localparam [1:0] RESP_OKAY = 2'b00;
  localparam integer OFFSET_BITS = $clog2(BLOCK_BYTES);
  localparam integer INDEX_BITS = $clog2(LINE_COUNT);
  localparam integer INDEX_WIDTH = (INDEX_BITS > 0) ? INDEX_BITS : 1;
  localparam integer TAG_BITS = 32 - OFFSET_BITS - INDEX_BITS;
  localparam integer WORDS_PER_BLOCK = BLOCK_BYTES / 4;
  localparam integer WORD_BITS = $clog2(WORDS_PER_BLOCK);
  localparam integer WORD_WIDTH = (WORD_BITS > 0) ? WORD_BITS : 1;
  localparam integer LINE_BITS = BLOCK_BYTES * 8;
  localparam [WORD_WIDTH-1:0] LAST_WORD = WORD_WIDTH'(WORDS_PER_BLOCK - 1);

  initial begin
    if (LINE_COUNT < 1 || (LINE_COUNT & (LINE_COUNT - 1)) != 0)
      $fatal(1, "icache LINE_COUNT must be a positive power of two");
    if (BLOCK_BYTES < 4 || (BLOCK_BYTES & (BLOCK_BYTES - 1)) != 0)
      $fatal(1, "icache BLOCK_BYTES must be a power of two >= 4");
    if (TAG_BITS < 1)
      $fatal(1, "icache geometry must leave at least one tag bit");
  end

  reg [2:0] state;
  reg [LINE_BITS-1:0] cache [0:LINE_COUNT-1];
  reg [TAG_BITS-1:0] tag [0:LINE_COUNT-1];
  reg [LINE_COUNT-1:0] valid;
  reg [31:0] pc_q;
  reg [31:0] inst_q;
  reg [1:0] resp_q;
  reg [WORD_WIDTH-1:0] beat_q;

  wire [INDEX_WIDTH-1:0] index;
  wire [WORD_WIDTH-1:0] req_word;
  wire [TAG_BITS-1:0] req_tag = pc_q[31:OFFSET_BITS+INDEX_BITS];
  generate
    if (LINE_COUNT == 1) begin : g_single_line
      assign index = {INDEX_WIDTH{1'b0}};
    end else begin : g_multi_line
      assign index = pc_q[OFFSET_BITS+INDEX_BITS-1:OFFSET_BITS];
    end
    if (WORDS_PER_BLOCK == 1) begin : g_single_word_select
      assign req_word = {WORD_WIDTH{1'b0}};
    end else begin : g_multi_word_select
      assign req_word = pc_q[OFFSET_BITS-1:2];
    end
  endgenerate
  wire hit = valid[index] && (tag[index] == req_tag);
  wire [31:0] line_base = {pc_q[31:OFFSET_BITS], {OFFSET_BITS{1'b0}}};

  wire if_pc_fire;
  wire if_inst_fire;
  wire ar_fire;
  wire r_fire;

  assign if_pc_ready = rst_n && (state == WAIT_PC);
  assign if_pc_fire = if_pc_valid && if_pc_ready;
  assign if_inst = inst_q;
  assign if_inst_resp = resp_q;
  assign if_inst_valid = rst_n && (state == RESP);
  assign if_inst_fire = if_inst_valid && if_inst_ready;

  // beat 仅在 R 握手后推进，因此 AR 背压期间地址保持不变。
  assign m_axi_araddr = line_base | ({{(32-WORD_WIDTH){1'b0}}, beat_q} << 2);
  assign m_axi_arvalid = rst_n && (state == AXI_AR);
  assign m_axi_rready = rst_n && (state == AXI_R);
  assign ar_fire = m_axi_arvalid && m_axi_arready;
  assign r_fire = m_axi_rvalid && m_axi_rready;

  // ARPROT[2:0] = instruction / secure / privileged (M-mode).
  assign m_axi_arprot = 3'b101;
  // I-cache does not write, so tie off unused write channels.
  assign m_axi_awaddr  = 32'b0;
  assign m_axi_awprot  = 3'b0;
  assign m_axi_awvalid = 1'b0;
  assign m_axi_wdata   = 32'b0;
  assign m_axi_wstrb   = 4'b0;
  assign m_axi_wvalid  = 1'b0;
  assign m_axi_bready  = 1'b0;
  wire unused_write_inputs = &{1'b0, m_axi_awready, m_axi_wready,
                               m_axi_bvalid, m_axi_bresp, pc_q[1:0]};

  // 单字 miss: AXI_AR -> AXI_R -> RESP，与默认配置原有时序一致。
  // 多字 miss: (AXI_AR -> AXI_R) x WORDS_PER_BLOCK -> COMMIT -> RESP。
  // RESP 始终保持指令和 valid，直到 IFU 接收后才允许下一个 PC。
  always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        state <= WAIT_PC;
        pc_q <= 32'b0;
        inst_q <= 32'b0;
        resp_q <= RESP_OKAY;
        beat_q <= {WORD_WIDTH{1'b0}};
        valid <= {LINE_COUNT{1'b0}};
    end else begin
        case(state)
            WAIT_PC: begin
                if(if_pc_fire) begin
                    pc_q <= if_pc;
                    beat_q <= {WORD_WIDTH{1'b0}};
                    resp_q <= RESP_OKAY;
                    state <= CHECK;
                end
            end
            CHECK: begin
                //check cache hit or miss
                if(hit) begin
                    //cache hit
                    inst_q <= cache[index][req_word*32 +: 32];
                    resp_q <= RESP_OKAY;
                    state <= RESP;
                end else begin
                    //cache miss, send AXI read request
                    state <= AXI_AR;
                end
            end
            AXI_AR: begin
                if(ar_fire) begin
                    state <= AXI_R;
                end
            end
            AXI_R: begin
                if(r_fire) begin
                    if (beat_q == req_word)
                        inst_q <= m_axi_rdata;
                    // 保留整块回填遇到的首个错误，错误块不得发布。
                    if ((resp_q == RESP_OKAY) && (m_axi_rresp != RESP_OKAY))
                        resp_q <= m_axi_rresp;
                    if (beat_q == LAST_WORD) begin
                        if (WORDS_PER_BLOCK == 1) begin
                            if (m_axi_rresp == RESP_OKAY)
                                valid[index] <= 1'b1;
                            state <= RESP;
                        end else begin
                            state <= COMMIT;
                        end
                    end else begin
                        beat_q <= beat_q + 1'b1;
                        state <= AXI_AR;
                    end
                end
            end
            COMMIT: begin
                if (resp_q == RESP_OKAY)
                    valid[index] <= 1'b1;
                state <= RESP;
            end
            RESP: begin
                if(if_inst_fire) begin
                    state <= WAIT_PC;
                end
            end
            default: state <= WAIT_PC;
        endcase
    end
  end

  wire fill_write;
  wire [LINE_BITS-1:0] fill_data;
  generate
    if (WORDS_PER_BLOCK == 1) begin : g_single_word_fill
      assign fill_write = r_fire && (m_axi_rresp == RESP_OKAY);
      assign fill_data = m_axi_rdata;
    end else begin : g_multi_word_fill
      reg [LINE_BITS-1:0] line_buf;
      // 不重置暂存阵列；成功提交前，每个字都必须已通过 R 握手写入。
      always @(posedge clk) begin
        if (rst_n && r_fire)
          line_buf[beat_q*32 +: 32] <= m_axi_rdata;
      end
      assign fill_write = (state == COMMIT) && (resp_q == RESP_OKAY);
      assign fill_data = line_buf;
    end
  endgenerate

  // 数据和 tag 阵列不复位；多字块原子替换，出错时保留原来的块。
  always @(posedge clk) begin
    if (rst_n && fill_write) begin
      cache[index] <= fill_data;
      tag[index] <= req_tag;
    end
  end

endmodule
