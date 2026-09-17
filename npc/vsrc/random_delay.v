module random_delay (
    input  clk,
    input  rst_n,
    input  req,        // 请求有效（电平信号，保持到 ready 返回）
    output reg start,  // 脉冲：接受请求，开始倒计时（触发实际访存）
    output reg ready   // 脉冲：延迟结束，响应有效
);

  // 4-bit Fibonacci LFSR, 多项式 x^4 + x^3 + 1, 周期 15
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
      start <= 1'b0;
      ready <= 1'b0;
    end else begin
      start <= 1'b0;
      ready <= 1'b0;
      case (state)
        S_IDLE: begin
          if (req) begin
            cnt   <= lfsr[2:0] | 3'b001;  // 1-7, 避免 0
            state <= S_BUSY;
            start <= 1'b1;
          end
        end
        S_BUSY: begin
          if (cnt == 3'b000) begin
            ready <= 1'b1;
            state <= S_IDLE;
          end else begin
            cnt <= cnt - 3'b001;
          end
        end
        default: state <= S_IDLE;
      endcase
    end
  end

endmodule
