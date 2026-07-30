//依据总线设计规范，不论是存还是取，都应该一次性传入/读出32位数据
//完整传入，依据不同指令设置不同mask
//完整读出，外部依据不同指令的控制信号控制写入寄存器的内容
import "DPI-C" function int pmem_read(input int raddr);
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
  reg [ 7:0] mem_byte_rdata;
  reg [15:0] mem_half_rdata;
  reg [31:0] mem_wdata;
  reg [7:0] mem_wmask;

  always @(*) begin
    case (mem_wbhw)
      MEM_BYTE: mem_wmask = 8'b00000001 << mem_addr[1:0];
      MEM_HALF: mem_wmask = 8'b00000011 << mem_addr[1:0];
      MEM_WORD: mem_wmask = 8'b00001111;
      default:  mem_wmask = 8'h00;
    endcase
    mem_wdata = mem_wdata_raw << (8 * mem_addr[1:0]);
  end

  always @(*) begin
    mem_rdata = 32'b0;
    if (rst_n && mem_valid && mem_rbhw != MEM_NONE) begin
      mem_rdata = pmem_read(mem_addr);
    end
  end

  always @(*) begin
    mem_byte_rdata = 8'b0;
    mem_half_rdata = 16'b0;
    if (rst_n && mem_valid) begin  // 有读写请求时
      case (mem_rbhw)
        MEM_BYTE: begin
          case (mem_addr[1:0])
            2'b00:   mem_byte_rdata = mem_rdata[7:0];
            2'b01:   mem_byte_rdata = mem_rdata[15:8];
            2'b10:   mem_byte_rdata = mem_rdata[23:16];
            2'b11:   mem_byte_rdata = mem_rdata[31:24];
            default: mem_byte_rdata = 8'b0;
          endcase
          mem_rdata_r = {{24{mem_byte_rdata[7] & isign}}, mem_byte_rdata};
        end
        MEM_HALF: begin
          case (mem_addr[1])
            1'b0:    mem_half_rdata = mem_rdata[15:0];
            1'b1:    mem_half_rdata = mem_rdata[31:16];
            default: mem_half_rdata = 16'b0;
          endcase
          mem_rdata_r = {{16{mem_half_rdata[15] & isign}}, mem_half_rdata};
        end
        MEM_WORD: mem_rdata_r = mem_rdata;
        default: mem_rdata_r = 32'b0;
      endcase
    end else begin
      mem_rdata_r = 0;
    end
  end

  always @(posedge clk) begin
    if (rst_n && mem_valid && wen) begin
      pmem_write(mem_addr, mem_wdata, mem_wmask);
    end
  end
endmodule
