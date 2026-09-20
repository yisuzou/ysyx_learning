// Pass the original byte address and access size to DPI so an access may span
// two aligned words.
module LSU (
    input clk,
    input rst_n,
    input [1:0] mem_rbhw,
    input [31:0] mem_addr,
    input mem_valid,
    input wen,
    input [1:0] mem_wbhw,
    input [31:0] mem_wdata_raw,
    input isign,
    output reg [31:0] mem_rdata_r,
    //simple bus
    input         lsu_respValid,
    input         lsu_reqReady,
    output [31:0] lsu_addr,
    output        lsu_wen,
    output [31:0] lsu_wdata,
    output [ 7:0] lsu_wmask,
    output [ 7:0] lsu_rlen,
    output        lsu_reqValid,
    output    reg lsu_respReady,
    input  [31:0] lsu_rdata
);
  //localparam MEM_NONE = 2'd0;
  localparam MEM_BYTE = 2'd1;
  localparam MEM_HALF = 2'd2;
  localparam MEM_WORD = 2'd3;

  assign lsu_addr = mem_addr;
 // assign lsu_wen = rst_n && mem_valid && wen;
  assign lsu_wen = lsu_handshake_success ? wen : 1'b0; //握手成功才发出写请求
  assign lsu_wdata = mem_wdata_raw;
  assign lsu_wmask = mem_wlen;
  assign mem_rdata = lsu_rdata;
  assign lsu_rlen = mem_rlen;

  reg [31:0] mem_rdata;
  wire [7:0] mem_rlen;
  wire [7:0] mem_wlen;

  function [7:0] mem_len;
    input [1:0] bhw;
    begin
      case (bhw)
        MEM_BYTE: mem_len = 8'd1;
        MEM_HALF: mem_len = 8'd2;
        MEM_WORD: mem_len = 8'd4;
        default:  mem_len = 8'd0;
      endcase
    end
  endfunction

  assign mem_rlen = mem_len(mem_rbhw);
  assign mem_wlen = mem_len(mem_wbhw);

  // LFSR 驱动的随机延迟：有访存请求且未收到响应时产生延迟后的 lsu_reqValid（电平）
  wire delayed_req;
  wire lsu_req_raw; //原始请求
  assign lsu_req_raw = rst_n && mem_valid ;
  random_delay lsu_delay (
      .clk(clk), .rst_n(rst_n),
      .req(lsu_req_raw),
      .gated(delayed_req)
  );
  reg lsu_handshake_success;

  assign lsu_reqValid = lsu_handshake_success ? 1'b0 : delayed_req;//握手成功之前一直请求
  always @(*) begin
    mem_rdata_r = 32'b0;
    if (rst_n && lsu_respValid && lsu_respReady) begin
      case (mem_rbhw)
        MEM_BYTE: mem_rdata_r = {{24{mem_rdata[7] & isign}}, mem_rdata[7:0]};
        MEM_HALF: mem_rdata_r = {{16{mem_rdata[15] & isign}}, mem_rdata[15:0]};
        MEM_WORD: mem_rdata_r = mem_rdata;
        default: mem_rdata_r = 32'b0;
      endcase
    end
  end

  // LSU_FSM 本质这里没有明显划分状态，其实就是握手前后
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      lsu_handshake_success <= 1'b0;
    end
    else begin
      lsu_respReady <= lsu_respReady ? 1'b0 : lsu_respValid;
      if (lsu_reqValid && lsu_reqReady) begin
        lsu_handshake_success <= 1'b1;//握手成功
      end
      if (lsu_respReady && lsu_respValid) begin
        lsu_handshake_success <= 1'b0;//释放握手信号
      end
    end
  end
endmodule
