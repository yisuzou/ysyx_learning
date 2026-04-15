module ex7 (
    input clk,
    input rst,
    input ps2_clk,
    input ps2_data,
    output [6:0] hex0,
    output [6:0] hex1,
    output [6:0] hex2,
    output [6:0] hex3,
    output [6:0] hex4,
    output [6:0] hex5
);
  reg [7:0] cnt = 8'h0;
  reg [9:0] buffer;  // ps2_data bits
  reg [3:0] count;  // count ps2_data bits
  reg [2:0] ps2_clk_sync;
  reg key_down;  //按键状态寄存器
  reg release_pending;  // 已收到F0，等待后续释放键码
  //下降沿采样逻辑
  always @(posedge clk) begin
    ps2_clk_sync <= {ps2_clk_sync[1:0], ps2_clk};
  end

  wire sampling = ps2_clk_sync[2] & ~ps2_clk_sync[1];
  //
  wire display = (buffer[0] == 0) &&  // start bit
  (ps2_data)       &&  // stop bit一帧有11bits，但只设计10bits，真是因为停止位再这里直接使用了；
  (^buffer[9:1]);  //odd parity
  always @(posedge clk) begin
    if (rst == 0) begin  // reset
      count <= 0;
      key_down <= 0;
      release_pending <= 0;
    end else begin
      if (sampling) begin
        if (count == 4'd10) begin
          if (display) begin
            if (buffer[8:1] == 8'hf0) begin
              //key_down <= 0;
              release_pending <= 1;
            end else if (release_pending) begin
              key_down <= 0;
              release_pending <= 0;
            end else begin
              if (!key_down) cnt <= cnt + 1;
              key_down <= 1;
            end
          end
          count <= 0;  // for next
        end else begin
          buffer[count] <= ps2_data;  // store ps2_data
          count <= count + 3'b001;
        end
      end
    end
  end
  wire [6:0] h0o, h1o, h2o, h3o;
  hex2seg h0 (
      buffer[4:1],
      h0o
  );
  hex2seg h1 (
      buffer[8:5],
      h1o
  );
  wire [7:0] code;
  ps2_to_ascii m0 (
      buffer[8:1],
      code
  );
  hex2seg h2 (
      code[3:0],
      h2o
  );
  hex2seg h3 (
      code[7:4],
      h3o
  );

  //没有按键按下时默认不显示，也就是disp信号无效的时候；
  assign hex0 = key_down ? h0o : 7'b1111111;
  assign hex1 = key_down ? h1o : 7'b1111111;
  assign hex2 = key_down ? h2o : 7'b1111111;
  assign hex3 = key_down ? h3o : 7'b1111111;
  //处理按键次数显示，要求，按下不松开只算1次按下
  hex2seg h4 (
      cnt[3:0],
      hex4
  );
  hex2seg h5 (
      cnt[7:4],
      hex5
  );

endmodule

module ps2_to_ascii (
    input  wire [7:0] scan_code,  // 输入：来自 PS/2 接收模块的 8 位扫描码
    output reg  [7:0] ascii_code  // 输出：对应的 8 位 ASCII 码
);

  // 使用纯组合逻辑（查表法）进行映射
  always @(*) begin
    case (scan_code)
      // ========== 26个英文字母 (默认映射为小写) ==========
      8'h1C: ascii_code = 8'h61;  // 'a'
      8'h32: ascii_code = 8'h62;  // 'b'
      8'h21: ascii_code = 8'h63;  // 'c'
      8'h23: ascii_code = 8'h64;  // 'd'
      8'h24: ascii_code = 8'h65;  // 'e'
      8'h2B: ascii_code = 8'h66;  // 'f'
      8'h34: ascii_code = 8'h67;  // 'g'
      8'h33: ascii_code = 8'h68;  // 'h'
      8'h43: ascii_code = 8'h69;  // 'i'
      8'h3B: ascii_code = 8'h6A;  // 'j'
      8'h42: ascii_code = 8'h6B;  // 'k'
      8'h4B: ascii_code = 8'h6C;  // 'l'
      8'h3A: ascii_code = 8'h6D;  // 'm'
      8'h31: ascii_code = 8'h6E;  // 'n'
      8'h44: ascii_code = 8'h6F;  // 'o'
      8'h4D: ascii_code = 8'h70;  // 'p'
      8'h15: ascii_code = 8'h71;  // 'q'
      8'h2D: ascii_code = 8'h72;  // 'r'
      8'h1B: ascii_code = 8'h73;  // 's'
      8'h2C: ascii_code = 8'h74;  // 't'
      8'h3C: ascii_code = 8'h75;  // 'u'
      8'h2A: ascii_code = 8'h76;  // 'v'
      8'h1D: ascii_code = 8'h77;  // 'w'
      8'h22: ascii_code = 8'h78;  // 'x'
      8'h35: ascii_code = 8'h79;  // 'y'
      8'h1A: ascii_code = 8'h7A;  // 'z'

      // ========== 键盘主键盘区的数字 0-9 ==========
      8'h45: ascii_code = 8'h30;  // '0'
      8'h16: ascii_code = 8'h31;  // '1'
      8'h1E: ascii_code = 8'h32;  // '2'
      8'h26: ascii_code = 8'h33;  // '3'
      8'h25: ascii_code = 8'h34;  // '4'
      8'h2E: ascii_code = 8'h35;  // '5'
      8'h36: ascii_code = 8'h36;  // '6'
      8'h3D: ascii_code = 8'h37;  // '7'
      8'h3E: ascii_code = 8'h38;  // '8'
      8'h46: ascii_code = 8'h39;  // '9'

      // ========== 特殊控制按键 ==========
      8'h29: ascii_code = 8'h20;  // 空格 (Space)
      8'h5A: ascii_code = 8'h0D;  // 回车 (Enter / CR)
      8'h66: ascii_code = 8'h08;  // 退格 (Backspace)
      8'h76: ascii_code = 8'h1B;  // 退出 (ESC)

      // ========== 未知或未定义的按键 ==========
      default: ascii_code = 8'h00;  // 遇到不认识的码，输出 NULL 字符
    endcase
  end

endmodule
