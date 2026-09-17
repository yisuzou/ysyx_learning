import "DPI-C" function void npc_ebreak(input int halt_code, input int pc);
import "DPI-C" function void npc_reg_write(input int index, input int data);
module top (
    input  clk,
    input  rst_n,
    //input [31:0] inst,
    //input [31:0] mem_rdata, //由于使用了DPI-C机制，通过内部信号访问即可
    output invalid_inst,
    output diff_ifu_valid,//视作一条指令的最终提交
    output [31:0] debug_pc,
    output [31:0] debug_inst,
    //output [31:0] pc
    //output mem_we,
    //output [31:0] mem_addr,
    //output [31:0] mem_wdata
    output [31:0] debug_mstatus,
    output [31:0] debug_mtvec,
    output [31:0] debug_mepc,
    output [31:0] debug_mcause,
    output [31:0] debug_mcycle,
    output [31:0] debug_mcycleh,
    output [31:0] debug_mvendorid,
    output [31:0] debug_marchid
);
  //IFU start
  wire [31:0] inst;
  reg [31:0] pc;
  assign debug_pc = pc;
  assign debug_inst = ifu_inst;
  IFU ifu1 (
    .clk(clk),
    .rst_n(rst_n),
    //.mem_ready(mem_ready^mem_rflag),
    .mem_valid(mem_valid),
    .memfinish(lsu_respValid),
    //.lsu_reqValid(lsu_reqValid),
    .pc(pc),
    .ifu_rdata(inst),
    .ifu_raddr(ifu_raddr),
    .inst(ifu_inst),
    .ifu_valid(ifu_valid),
    .ifu_reqValid(ifu_reqValid),
    .ifu_respValid(ifu_respValid)
  );
  wire [31:0] ifu_raddr;
  wire [31:0] ifu_inst;
  wire ifu_valid;
  wire ifu_reqValid;
  wire ifu_respValid;
  assign diff_ifu_valid = mem_valid ? ifu_valid && lsu_respValid : ifu_valid;
  //IFU end
  wire [4:0] rs1;
  wire [4:0] rs2;
  wire [4:0] rd;
  wire [31:0] imm;
  wire [31:0] imm_raw;
  wire [1:0] src_sel;
  wire [3:0] exu_op;
  wire pc_we;
  wire [1:0] pc_wsel;
  wire branch_en;
  wire [2:0] branch_op;
  wire gpr_we;
  wire [2:0] gpr_wsel;
  wire is_ebreak;
  wire is_ecall;
  wire [31:0] mem_rdata;
  wire mem_wen;
  wire [1:0] mem_rbhw;
  wire [1:0] mem_wbhw;
  wire isign;
  wire mem_valid;
  wire csr_we;
  wire [1:0]csr_wsel;
  wire [11:0] csr_wraddr;
  //wire [31:0] csr_wdata;
  wire [31:0] csr_rdata;
  wire imm2csr;

  wire [31:0] tmp_csr = csr_rdata;

  assign imm = imm2csr ? tmp_csr : imm_raw;//csr指令的立即数语义为csr寄存器的值，而不是指令中的立即数
  wire invalid_inst_idu;
  IDU idu1 (
      .inst(ifu_inst),
      .rs1(rs1),
      .rs2(rs2),
      .rd(rd),
      .imm(imm_raw),
      .invalid_inst(invalid_inst_idu),
      .src_sel(src_sel),
      .exu_op(exu_op),
      .pc_we(pc_we),
      .pc_wsel(pc_wsel),
      .branch_en(branch_en),
      .branch_op(branch_op),
      .gpr_we(gpr_we),
      .mem_we(mem_wen),
      .mem_rbhw(mem_rbhw),
      .mem_wbhw(mem_wbhw),
      .isign(isign),
      .is_ebreak(is_ebreak),
      .mem_valid(mem_valid),
      .gpr_wsel(gpr_wsel),
      .csr_we(csr_we),
      .csr_wsel(csr_wsel),
      .csr_wraddr(csr_wraddr),
      .imm2csr(imm2csr),
      .is_ecall(is_ecall)
  );
  wire [31:0] exu_result;
  wire exu_zero;
  wire exu_signed_lt;
  wire exu_unsigned_lt;
  wire [31:0] Rrs1;
  wire [31:0] Rrs2;
  wire [31:0] gpr_a0;
  EXU exu1 (
      .rs1(Rrs1),
      .rs2(Rrs2),
      .imm(imm),
      .pc(pc),
      .src_sel(src_sel),
      .exu_op(exu_op),
      .result(exu_result),
      .zero(exu_zero),
      .signed_lt(exu_signed_lt),
      .unsigned_lt(exu_unsigned_lt)
  );
  wire [31:0] gpr_wdata;
  wire branch_taken;
  BranchUnit branch_unit1 (
      .branch_en(branch_en),
      .branch_op(branch_op),
      .zero(exu_zero),
      .signed_lt(exu_signed_lt),
      .unsigned_lt(exu_unsigned_lt),
      .branch_taken(branch_taken)
  );
  wire pc_write_en = (pc_we || branch_taken);
  wire invalid_csr_access;
  WBU wbu1 (
      .clk(clk),
      .rst_n(rst_n),
      .pc_we(pc_write_en&&(diff_ifu_valid)),
      .diff_ifu_valid(diff_ifu_valid),
      //.no_mem(no_mem),
      .pc_wsel(pc_wsel),
      .exu_result(exu_result),
      .imm(imm),
      .gpr_we(gpr_we&&diff_ifu_valid),
      .gpr_wsel(gpr_wsel),
      .mem_rdata(mem_rdata),
      .rs1(rs1),
      .rs2(rs2),
      .rd(rd),
      .is_ecall(is_ecall),
      .gpr_rdata1(Rrs1),
      .gpr_rdata2(Rrs2),
      .gpr_a0(gpr_a0),
      .gpr_wdata(gpr_wdata),
      .pc(pc),
      .csr_we(csr_we&&diff_ifu_valid),
      .csr_wsel(csr_wsel),
      .csr_wraddr(csr_wraddr),
      //.csr_wdata(csr_wdata),
      .csr_rdata1(csr_rdata),
      .invalid_csr_access(invalid_csr_access),
      .dbg_mstatus(debug_mstatus),
      .dbg_mtvec(debug_mtvec),
      .dbg_mepc(debug_mepc),
      .dbg_mcause(debug_mcause),
      .dbg_mcycle(debug_mcycle),
      .dbg_mcycleh(debug_mcycleh),
      .dbg_mvendorid(debug_mvendorid),
      .dbg_marchid(debug_marchid)
  );
  LSU lsu1 (
      .clk(clk),
      .rst_n(rst_n),
      .mem_rbhw(mem_rbhw),  //由译码IDU给出
      .mem_addr(exu_result),  //由EXU给出
      .mem_valid(mem_valid),  //IDU给出
      .wen(mem_wen),  //IDU给出
      .mem_wbhw(mem_wbhw),  //由译码IDU给出
      .mem_wdata_raw(Rrs2),  //由GPR给出
      .isign(isign),  //idu
      .mem_rdata_r(mem_rdata),
      //simple bus
      .lsu_addr(lsu_addr),
      .lsu_wen(lsu_wen),
      .lsu_wdata(lsu_wdata),
      .lsu_wmask(lsu_wmask),
      .lsu_rlen(lsu_rlen),
      .lsu_respValid(lsu_respValid),
      .lsu_reqValid(lsu_reqValid),
      .lsu_rdata(lsu_rdata)
  );
//将LSU内部与pmem交互的逻辑移到顶层，方便DPI-C调用,总线交互逻辑如下：
  wire [31:0] lsu_rdata;
  wire [31:0] lsu_addr ;
  wire [31:0] lsu_wdata;
  wire [7:0] lsu_wmask;
  wire [7:0] lsu_rlen;
  wire lsu_reqValid;
  wire lsu_respValid;
  wire lsu_wen;

  MEM mem1 (
      .clk(clk),
      .rst_n(rst_n),
      // IFU bus
      .ifu_raddr(ifu_raddr),
      .ifu_reqValid(ifu_reqValid),
      .ifu_respValid(ifu_respValid),
      .ifu_rdata(inst),
      // LSU bus
      .lsu_addr(lsu_addr),
      .lsu_wen(lsu_wen),
      .lsu_wdata(lsu_wdata),
      .lsu_wmask(lsu_wmask),
      .lsu_rlen(lsu_rlen),
      .lsu_reqValid(lsu_reqValid),
      .lsu_respValid(lsu_respValid),
      .lsu_rdata(lsu_rdata)
  );

  assign invalid_inst = invalid_inst_idu || invalid_csr_access;

  always @(posedge clk) begin
    if (rst_n && gpr_we && ifu_valid) begin
      npc_reg_write({27'b0, rd}, gpr_wdata);
    end
    if (rst_n && is_ebreak && ifu_valid) begin
      npc_ebreak(gpr_a0, pc);
    end
  end

endmodule
