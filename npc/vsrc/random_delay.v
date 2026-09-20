module random_delay (
    input         clk,
    input         rst_n,
    input         req,      // 电平输入
    output        gated     // 电平输出（组合）：倒数到 0 且 req 高时拉高，req 下降时即时下降
);

  // 4-bit Fibonacci LFSR, x^4 + x^3 + 1, 周期 15
  reg [3:0] lfsr;
  wire lfsr_fb = lfsr[3] ^ lfsr[2];
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) lfsr <= 4'h1;
    else        lfsr <= {lfsr[2:0], lfsr_fb};
  end

  localparam S_IDLE = 1'b0;
  localparam S_BUSY = 1'b1;
  reg state;
  reg [2:0] cnt;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= S_IDLE;
      cnt   <= 3'b0;
    end else begin
      case (state)
        S_IDLE: begin
          if (req) begin
            // 预减 1：合并 IDLE→BUSY 转移与首次倒数，消除 1 拍开销
            cnt   <= (lfsr[2:0] | 3'b001) - 3'b001;  // 0-6, 总延迟 = LFSR 值 1-7
            state <= S_BUSY;
          end
        end
        S_BUSY: begin
          if (!req) begin
            state <= S_IDLE;
          end else if (cnt != 3'b000) begin
            cnt <= cnt - 3'b001;
          end
        end
        default: state <= S_IDLE;
      endcase
    end
  end

  // 组合输出：cnt 到 0 当周期即拉高，消除寄存器 1 拍开销
  // req 下降时即时下降（不经过寄存器）
  assign gated = (state == S_BUSY) && (cnt == 3'b000) && req;

endmodule
