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
    output [31:0] lsu_addr,
    output        lsu_wen,
    output [31:0] lsu_wdata,
    output [ 7:0] lsu_wmask,
    output [ 7:0] lsu_rlen,
    output        lsu_reqValid,
    input  [31:0] lsu_rdata
);
  //localparam MEM_NONE = 2'd0;
  localparam MEM_BYTE = 2'd1;
  localparam MEM_HALF = 2'd2;
  localparam MEM_WORD = 2'd3;

  assign lsu_addr = mem_addr;
  assign lsu_wen = rst_n && mem_valid && wen;
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

  // LFSR 驱动的随机延迟：有访存请求时持续运行，ready 脉冲触发 lsu_reqValid
  wire delay_start;
  wire delay_ready;
  random_delay lsu_delay (
      .clk(clk), .rst_n(rst_n),
      .req(rst_n && mem_valid && !lsu_respValid),
      .start(delay_start),
      .ready(delay_ready)
  );

  assign lsu_reqValid = lsu_respValid ? 1'b0 : rst_n && mem_valid && delay_ready;
  always @(*) begin
    mem_rdata_r = 32'b0;
    if (rst_n && mem_valid) begin
      case (mem_rbhw)
        MEM_BYTE: mem_rdata_r = {{24{mem_rdata[7] & isign}}, mem_rdata[7:0]};
        MEM_HALF: mem_rdata_r = {{16{mem_rdata[15] & isign}}, mem_rdata[15:0]};
        MEM_WORD: mem_rdata_r = mem_rdata;
        default: mem_rdata_r = 32'b0;
      endcase
    end
  end

endmodule
