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
    input         rst_n,
    // IFU bus (read-only)
    input  [31:0] ifu_raddr,
    input         ifu_reqValid,
    input         ifu_respReady,
    output    reg ifu_reqReady,
    output        ifu_respValid,
    output [31:0] ifu_rdata,
    // LSU bus (read/write)
    input  [31:0] lsu_addr,
    input         lsu_wen,
    input  [31:0] lsu_wdata,
    input  [7:0]  lsu_wmask,
    input  [7:0]  lsu_rlen,
    input         lsu_reqValid,
    input         lsu_respReady,
    output    reg lsu_reqReady,
    output        lsu_respValid,
    output [31:0] lsu_rdata
);

  wire mem_rflag = |lsu_rlen;

  // IFU 通道：电平延迟
  wire ifu_gated;
  random_delay ifu_delay (
    .clk(clk), .rst_n(rst_n),
    .req(ifu_access_done),
    .gated(ifu_gated)
  );
  assign ifu_respValid = ifu_gated;

  // IFU 取指：请求到达后执行一次，access_done 保证不重复
  reg ifu_access_done;
  reg ifu_handshake_success;
  reg [31:0] ifu_rdata_r;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ifu_access_done <= 1'b0;
      ifu_rdata_r     <= 32'b0;
      ifu_reqReady    <= 1'b0;
      ifu_handshake_success <= 1'b0;
    end
    else begin
      if (ifu_reqValid) begin
        ifu_reqReady <= ifu_reqReady ? 1'b0 : 1'b1;
        if (ifu_reqReady) begin
          ifu_handshake_success <= 1'b1;
        end
      end
      if (ifu_handshake_success && !ifu_access_done) begin
          ifu_rdata_r     <= pmem_ifetch(ifu_raddr);
          ifu_access_done <= 1'b1; //代表访存完成，这个信号决定了respValid的输出
      end
      if (ifu_respValid && ifu_respReady) begin
        ifu_handshake_success <= 1'b0; //握手信号释放
        ifu_access_done <= 1'b0;
      end
    end
  end

  assign ifu_rdata = ifu_rdata_r;

  // LSU 通道：电平延迟
  wire lsu_gated;
  random_delay lsu_delay (
    .clk(clk), .rst_n(rst_n),
    .req(lsu_access_done),
    .gated(lsu_gated)
  );
  assign lsu_respValid = lsu_gated;

  // LSU 读写：请求到达后执行一次，access_done 保证不重复
  reg lsu_access_done;
  reg lsu_handshake_success;
  reg [31:0] lsu_rdata_r;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      lsu_access_done <= 1'b0;
      lsu_rdata_r     <= 32'b0;
      lsu_reqReady    <= 1'b0;
      lsu_handshake_success <= 1'b0;
    end else begin
      if (lsu_reqValid) begin
        lsu_reqReady <= lsu_reqReady ? 1'b0 : 1'b1; //如果要引入延迟，将1‘b1修改为延迟后信号；
        if (lsu_reqReady) begin
          lsu_handshake_success <= 1'b1;
        end
      end
      if ( lsu_handshake_success && !lsu_access_done) begin
        lsu_rdata_r <= (!lsu_wen && mem_rflag) ? pmem_read(lsu_addr, lsu_rlen) : 32'b0;
        if (lsu_wen)
          pmem_write(lsu_addr, lsu_wdata, lsu_wmask);
        lsu_access_done <= 1'b1;
      end
      if (lsu_respValid && lsu_respReady) begin
        lsu_handshake_success <=1'b0; //访存结束
        lsu_access_done <= 1'b0; //此次访问完毕
      end
    end
  end
  assign lsu_rdata = lsu_rdata_r;

endmodule
