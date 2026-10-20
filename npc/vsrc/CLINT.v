// 32-bit AXI4-Lite CLINT (Core Local INTerrupt controller) slave.
// 当前阶段只实现时钟功能：一个只读的 64 位计数器 mtime，不产生中断。
// 读、写两个方向相互独立，各自最多一笔未完成事务。
//
// ============================================================================
// 设计规格
// ============================================================================
// 1. mtime
//    - 64 位，复位清零，每周期加 MTIME_STEP（默认 1）。
//    - 硬件只提供计数值，不做时间换算：时间 = mtime / 系数，由软件完成。
//      系数在真实芯片上取 CLINT 时钟频率；仿真中取仿真速率（周期/秒）。
//
// 2. 寄存器映射（XBAR 路由给本设备的 8 字节窗口内偏移，窗口基址须 8 字节对齐）
//    - 0x0  MTIME_LO   R   最近一次读 MTIME_HI 时锁存的 mtime[31:0]
//    - 0x4  MTIME_HI   R   当前 mtime[63:32]，同时锁存当前 mtime[31:0]
//    窗口基址沿用旧仿真 RTC 地址（top.v 中的 RTC_MMIO）。
//
// 3. 响应规则
//    - 读偏移 0x0 / 0x4                 -> OKAY
//    - 其余读（越界、未对齐）           -> SLVERR，RDATA = 0，无副作用
//    - 任何写                           -> SLVERR，无副作用（寄存器只读）
//    取指保护由 XBAR 负责（该规则 RULE_EXEC = 0），本设备不检查 ARPROT。
//
// 4. 64 位读取协议（硬件快照）
//    - 软件必须先读 MTIME_HI，再读 MTIME_LO。
//      读 HI 的那一拍把 mtime[31:0] 存入快照，随后读 LO 返回该快照，
//      两半来自同一时刻，不会因低位进位而错 2^32。
//    - 单独读 LO 得到的是上一次读 HI 时的旧值，不是当前值。
//    - 限制：快照只有一份。若 HI 与 LO 之间插入了另一次读 HI
//      （例如将来中断处理程序也读时钟），快照会被覆盖。
//      届时需关中断读取，或改用软件侧 hi-lo-hi 重读方案。
//
// ============================================================================
// 后续任务
// ============================================================================
// 5. 接入系统
//    - vsrc/filelist.mk：加入本文件。
//    - vsrc/top.v：增加 XBAR 端口、把 RTC 规则指向它、打开 HAS_CLINT、例化。
//    - csrc：旧的软件 RTC 设备与新硬件地址冲突，需要决定如何处理。
//    - AM 的 IOE（timer.c）：按第 4 条协议读取，按第 1 条系数换算，
//      使 AM_TIMER_UPTIME 接近真实时间。
//
// 6. 验证建议
//    - make -C npc lint 无警告。
//    - am-kernels 中的 timer 相关测试 / 打印秒数的程序，对比墙上时钟。
//    - 打开 WAVE_TRACE 观察 AR/R 握手和 mtime 递增。
//    - 想一想：怎样不等 2^32 个周期就能测到低位进位的情况？
//
// ============================================================================
module CLINT #(
    parameter MTIME_STEP = 1
) (
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
    output [ 1:0] s_axi_bresp,
    output        s_axi_bvalid,
    input         s_axi_bready
);
  localparam [1:0] RESP_OKAY   = 2'b00;
  localparam [1:0] RESP_SLVERR = 2'b10;

  localparam [2:0] OFF_MTIME_LO = 3'h0;
  localparam [2:0] OFF_MTIME_HI = 3'h4;

  // --------------------------------------------------------------------------
  // mtime 计数器
  // --------------------------------------------------------------------------
  reg [63:0] mtime;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      mtime <= 64'b0;
    end else begin
      mtime <= mtime + MTIME_STEP;
    end
  end

  // --------------------------------------------------------------------------
  // 读通道 (AR/R)
  // --------------------------------------------------------------------------
  // 状态       动作                                         次态
  // RD_IDLE    ARREADY=1；握手时锁存地址偏移                ar_fire -> RD_ACCESS
  // RD_ACCESS  按偏移判定响应，锁存 RDATA/RRESP；           RD_RESP（下一拍）
  //            读 HI 时同时锁存 mtime[31:0] 快照
  // RD_RESP    RVALID=1，保持 RDATA/RRESP                   r_fire  -> RD_IDLE
  // 未列出的条件保持当前状态。
  // mtime 的采样时刻在 RD_ACCESS，与之后多少拍回复无关，不影响精度。
  localparam [1:0] RD_IDLE   = 2'd0;
  localparam [1:0] RD_ACCESS = 2'd1;
  localparam [1:0] RD_RESP   = 2'd2;

  reg [1:0]  rd_state, rd_next_state;
  reg [2:0]  aroff_r;      // 只需窗口内偏移
  reg [31:0] rdata_r;
  reg [1:0]  rresp_r;
  reg [31:0] mtime_lo_r;   // 读 HI 时锁存的低 32 位（高 32 位当拍直接返回，无需保存）

  assign s_axi_arready = rst_n && (rd_state == RD_IDLE);
  assign s_axi_rvalid  = rst_n && (rd_state == RD_RESP);
  assign s_axi_rdata   = rdata_r;
  assign s_axi_rresp   = rresp_r;

  wire ar_fire = s_axi_arvalid && s_axi_arready;
  wire r_fire  = s_axi_rvalid  && s_axi_rready;

  // 判定只依赖已锁存的 aroff_r，与 rdata/rresp 在同一拍使用，不存在新旧错位。
  wire rd_hit_lo = (aroff_r == OFF_MTIME_LO);
  wire rd_hit_hi = (aroff_r == OFF_MTIME_HI);

  always @(*) begin
    rd_next_state = rd_state;
    case (rd_state)
      RD_IDLE:   if (ar_fire) rd_next_state = RD_ACCESS;
      RD_ACCESS:              rd_next_state = RD_RESP;
      RD_RESP:   if (r_fire)  rd_next_state = RD_IDLE;
      default:                rd_next_state = RD_IDLE;
    endcase
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rd_state <= RD_IDLE;
    end else begin
      rd_state <= rd_next_state;
    end
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      aroff_r    <= 3'b0;
      rdata_r    <= 32'b0;
      rresp_r    <= RESP_OKAY;
      mtime_lo_r <= 32'b0;
    end else begin
      if (ar_fire) aroff_r <= s_axi_araddr[2:0];
      if (rd_state == RD_ACCESS) begin
        rresp_r <= (rd_hit_lo || rd_hit_hi) ? RESP_OKAY : RESP_SLVERR;
        rdata_r <= rd_hit_hi ? mtime[63:32] :
                   rd_hit_lo ? mtime_lo_r   : 32'b0;
        // 快照只由读 HI 更新；同一拍采样，与返回的 mtime[63:32] 一致。
        if (rd_hit_hi) mtime_lo_r <= mtime[31:0];
      end
    end
  end

  // --------------------------------------------------------------------------
  // 写通道 (AW/W/B)
  // --------------------------------------------------------------------------
  // 状态        动作                                        次态
  // WR_COLLECT  AW、W 各自独立握手，记录是否已收到          两者都收到 -> WR_RESP
  // WR_RESP     BVALID=1，BRESP=SLVERR；AWREADY/WREADY=0    b_fire -> WR_COLLECT
  // 未列出的条件保持当前状态。
  // 寄存器只读、写无副作用，因此无需缓存 AW/W 的内容，只需记录“到没到”。
  localparam WR_COLLECT = 1'b0;
  localparam WR_RESP    = 1'b1;

  reg wr_state, wr_next_state;
  reg aw_pending, w_pending;

  assign s_axi_awready = rst_n && (wr_state == WR_COLLECT) && !aw_pending;
  assign s_axi_wready  = rst_n && (wr_state == WR_COLLECT) && !w_pending;
  assign s_axi_bvalid  = rst_n && (wr_state == WR_RESP);
  assign s_axi_bresp   = RESP_SLVERR;

  wire aw_fire = s_axi_awvalid && s_axi_awready;
  wire w_fire  = s_axi_wvalid  && s_axi_wready;
  wire b_fire  = s_axi_bvalid  && s_axi_bready;

  // 完整性判定包含本拍的握手（AW、W 可同拍到达）。
  always @(*) begin
    wr_next_state = wr_state;
    case (wr_state)
      WR_COLLECT: if ((aw_pending || aw_fire) && (w_pending || w_fire))
                    wr_next_state = WR_RESP;
      WR_RESP:    if (b_fire) wr_next_state = WR_COLLECT;
      default:      wr_next_state = WR_COLLECT;
    endcase
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wr_state   <= WR_COLLECT;
      aw_pending <= 1'b0;
      w_pending  <= 1'b0;
    end else begin
      wr_state <= wr_next_state;
      if (aw_fire) aw_pending <= 1'b1;
      if (w_fire)  w_pending  <= 1'b1;
      if (b_fire) begin
        aw_pending <= 1'b0;
        w_pending  <= 1'b0;
      end
    end
  end

  // --------------------------------------------------------------------------
  // 未使用信号
  // --------------------------------------------------------------------------
  // 读只看偏移；写内容一律丢弃；ARPROT/AWPROT 不参与判定。
  wire unused_inputs = &{1'b0, s_axi_araddr[31:3], s_axi_arprot,
                        s_axi_awaddr, s_axi_awprot, s_axi_wdata, s_axi_wstrb};
endmodule
