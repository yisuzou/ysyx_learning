import "DPI-C" function int pmem_read(input int raddr);
import "DPI-C" function void pmem_write(
  input int  waddr,
  input int  wdata,
  input byte wmask
);
//依据总线设计规范，不论是存还是取，都应该一次性传入/读出32位数据
//完整传入，依据不同指令设置不同mask
//完整读出，外部依据不同指令的控制信号控制写入寄存器的内容
module LSU (
    input [1:0] mem_rbhw,
    input [31:0] mem_raddr,
    input valid,
    input wen,
    input [31:0] mem_waddr,
    input [31:0] mem_wdata,
    input [7:0] mem_wmask,
    input isign,
    output reg [31:0] mem_rdata_r
);
  reg [31:0] mem_rdata;
  reg [ 7:0] mem_byte_rdata;
  reg [15:0] mem_half_rdata;
  always @(*) begin
    mem_byte_rdata = 8'b0;
    mem_half_rdata = 16'b0;
    if (valid) begin  // 有读写请求时
      mem_rdata = pmem_read(mem_raddr);
      if (wen) begin  // 有写请求时
        pmem_write(mem_waddr, mem_wdata, mem_wmask);
      end
      case (mem_rbhw)
        2'b01: begin
          case (mem_raddr[1:0])
            2'b00:   mem_byte_rdata = mem_rdata[7:0];
            2'b01:   mem_byte_rdata = mem_rdata[15:8];
            2'b10:   mem_byte_rdata = mem_rdata[23:16];
            2'b11:   mem_byte_rdata = mem_rdata[31:24];
            default: mem_byte_rdata = 8'b0;
          endcase
          mem_rdata_r = {{24{mem_byte_rdata[7] & isign}}, mem_byte_rdata};
        end
        2'b10: begin
          case (mem_raddr[1])
            1'b0:    mem_half_rdata = mem_rdata[15:0];
            1'b1:    mem_half_rdata = mem_rdata[31:16];
            default: mem_half_rdata = 16'b0;
          endcase
          mem_rdata_r = {{16{mem_half_rdata[15] & isign}}, mem_half_rdata};
        end
        2'b11:   mem_rdata_r = mem_rdata;
        default: mem_rdata_r = 32'b0;
      endcase
    end else begin
      mem_rdata_r = 0;
    end
  end
endmodule
