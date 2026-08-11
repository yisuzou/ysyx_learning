// Pass the original byte address and access size to DPI so an access may span
// two aligned words.
import "DPI-C" function int pmem_read(
    input int raddr,
    input byte rlen
);
import "DPI-C" function void pmem_write(
    input int  waddr,
    input int  wdata,
    input byte wlen
);
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
    output reg [31:0] mem_rdata_r
);
  localparam MEM_NONE = 2'd0;
  localparam MEM_BYTE = 2'd1;
  localparam MEM_HALF = 2'd2;
  localparam MEM_WORD = 2'd3;

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

  always @(*) begin
    mem_rdata = 32'b0;
    if (rst_n && mem_valid && mem_rbhw != MEM_NONE) begin
      mem_rdata = pmem_read(mem_addr, mem_rlen);
    end
  end

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

  always @(posedge clk) begin
    if (rst_n && mem_valid && wen) begin
      pmem_write(mem_addr, mem_wdata_raw, mem_wlen);
    end
  end
endmodule
