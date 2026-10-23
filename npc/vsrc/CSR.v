module CSR #(
    ADDR_WIDTH = 12,
    DATA_WIDTH = 32
) (
    input clk,
    input rst_n,
    input [DATA_WIDTH-1:0] wdata,
    input [ADDR_WIDTH-1:0] waddr,
    input wen,
    input is_ecall,
    input [31:0]mepc_data,
    input [31:0]mcause_data,
  input [ADDR_WIDTH-1:0] raddr1,
  //input [ADDR_WIDTH-1:0] raddr2,
  output reg [DATA_WIDTH-1:0] rdata1,
  output     [DATA_WIDTH-1:0] mtvec_data,
  //output [DATA_WIDTH-1:0] rdata2,
  output reg invalid_csr_access,
  output     [DATA_WIDTH-1:0] dbg_mstatus,
  output     [DATA_WIDTH-1:0] dbg_mtvec,
  output     [DATA_WIDTH-1:0] dbg_mepc,
  output     [DATA_WIDTH-1:0] dbg_mcause,
  output     [DATA_WIDTH-1:0] dbg_mcycle,
  output     [DATA_WIDTH-1:0] dbg_mcycleh,
  output     [DATA_WIDTH-1:0] dbg_mvendorid,
  output     [DATA_WIDTH-1:0] dbg_marchid
);
  //reg [DATA_WIDTH-1:0] rf[2**ADDR_WIDTH-1:0];
  //只需要实现几个CSR寄存器，分别是mstatus、mtvec、mepc、mcause、mcycle...
  reg [DATA_WIDTH-1:0] mstatus;//0x300
  reg [DATA_WIDTH-1:0] mtvec;  //0x305
  reg [DATA_WIDTH-1:0] mepc;   //0x341
  reg [DATA_WIDTH-1:0] mcause; //0x342
  reg [DATA_WIDTH-1:0] mcycle; //0xb00
  reg [DATA_WIDTH-1:0] mcycleh;//0xb80
  reg [DATA_WIDTH-1:0] mvendorid; //0xf11
  reg [DATA_WIDTH-1:0] marchid;   //0xf12
  //decode the read address to select the correct CSR register
  localparam CSR_MSTATUS = 12'h300;
  localparam CSR_MTVEC   = 12'h305;
  localparam CSR_MEPC    = 12'h341;
  localparam CSR_MCAUSE  = 12'h342;
  localparam CSR_MCYCLE  = 12'hb00;
  localparam CSR_MCYCLEH = 12'hb80;
  localparam CSR_MVENDORID = 12'hf11;
  localparam CSR_MARCHID   = 12'hf12;
//地址译码，判断是否是有效的CSR寄存器访问

  assign mtvec_data = mtvec; //mtvec寄存器的值作为pc跳转地址

  //调试输出：通过端口暴露内部CSR，避免跨模块层次引用
  assign dbg_mstatus   = mstatus;
  assign dbg_mtvec     = mtvec;
  assign dbg_mepc      = mepc;
  assign dbg_mcause    = mcause;
  assign dbg_mcycle    = mcycle;
  assign dbg_mcycleh   = mcycleh;
  assign dbg_mvendorid = mvendorid;
  assign dbg_marchid   = marchid;

  always @(*) begin //组合逻辑，寄存器读
    invalid_csr_access = 1'b0; //默认有效访问
    rdata1 = {DATA_WIDTH{1'b0}}; //默认读出内容
    case (raddr1)
      CSR_MSTATUS: rdata1 = mstatus;
      CSR_MTVEC:   rdata1 = mtvec;
      CSR_MEPC:    rdata1 = mepc;
      CSR_MCAUSE:  rdata1 = mcause;
      CSR_MCYCLE:  rdata1 = mcycle;
      CSR_MCYCLEH: rdata1 = mcycleh;
      CSR_MVENDORID: rdata1 = mvendorid;
      CSR_MARCHID:   rdata1 = marchid;
      default:     invalid_csr_access = 1'b1; //无效寄存器访问
    endcase
    //写地址检测
    // case(waddr)
    //   CSR_MSTATUS, CSR_MTVEC, CSR_MEPC, CSR_MCAUSE, CSR_MCYCLE, CSR_MCYCLEH:  ; //有效寄存器访问
    //   default: invalid_csr_access = 1; //无效寄存器访问
    // endcase
  end
 
  wire mcycle_carry = (mcycle == 32'hffffffff); //mcycle溢出标志

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin//初始化
      mstatus <= 32'h00001800; //默认mstatus寄存器值
      mtvec   <= 32'h00000000; //默认mtvec寄存器值
      mepc    <= 32'h00000000; //默认mepc寄存器值
      mcause  <= 32'h00000000; //默认mcause寄存器值
      mcycle  <= 32'h00000000; //默认mcycle寄存器值
      mcycleh <= 32'h00000000; //默认mcycleh寄存器值
      mvendorid <= 32'h79737978; //默认mvendorid寄存器值 ysyx
      marchid   <= 32'h18d5749; //默认marchid寄存器值 26040137
    end
    else begin
      if (wen) begin //写入CSR寄存器
        case(waddr)
          CSR_MSTATUS: mstatus <= wdata;
          CSR_MTVEC:   mtvec   <= wdata;
          CSR_MEPC:    mepc    <= wdata;
          CSR_MCAUSE:  mcause  <= wdata;
          // CSR_MCYCLE:  mcycle  <= wdata;
          // CSR_MCYCLEH: mcycleh <= wdata;
          default:     ; // do nothing
        endcase
      end
      if (is_ecall) begin //ecall异常处理
        mepc   <= mepc_data;
        mcause <= mcause_data;
      end
      if (wen && waddr == CSR_MCYCLE)
        mcycle  <= wdata;
      else
        mcycle  <= mcycle + 32'h1;
      if (wen && waddr == CSR_MCYCLEH)
        mcycleh <= wdata;
      else if (mcycle_carry)
        mcycleh <= mcycleh + 32'h1;
    end
  end
endmodule
