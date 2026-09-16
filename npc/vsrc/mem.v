import "DPI-C" function int pmem_ifetch(input int raddr);
import "DPI-C" function int pmem_read(
    input int raddr,
    input byte rlen
);
import "DPI-C" function void pmem_write(
    input int  waddr,
    input int  wdata,
    input byte wlen
);

module MEM (
    input         clk,
    // IFU bus (read-only)
    input  [31:0] ifu_raddr,
    input         ifu_reqValid,
    output reg    ifu_respValid,
    output reg [31:0] ifu_rdata,
    // LSU bus (read/write)
    input  [31:0] lsu_addr,
    input         lsu_wen,
    input  [31:0] lsu_wdata,
    input  [7:0]  lsu_wmask,
    input  [7:0]  lsu_rlen,
    input         lsu_reqValid,
    output reg    lsu_respValid,
    output reg [31:0] lsu_rdata
);

  wire mem_rflag = |lsu_rlen;

  // IFU 取指
  always @(posedge clk) begin
    if (ifu_reqValid) begin
      ifu_rdata <= pmem_ifetch(ifu_raddr);
    end
    ifu_respValid <= ifu_reqValid;
  end

  // LSU 读写
  always @(posedge clk) begin
    lsu_rdata <= (!lsu_wen && lsu_reqValid && mem_rflag) ? pmem_read(lsu_addr, lsu_rlen) : 32'b0;
    if (lsu_wen && lsu_reqValid) begin
      pmem_write(lsu_addr, lsu_wdata, lsu_wmask);
    end
    lsu_respValid <= lsu_reqValid;
  end

endmodule
