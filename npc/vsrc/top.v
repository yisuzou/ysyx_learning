import "DPI-C" function void npc_ebreak(input int halt_code, input int pc);
import "DPI-C" function void npc_reg_write(input int index, input int data);
import "DPI-C" function void pmem_write(
  input int  waddr,
  input int  wdata,
  input byte wmask
);
module top (
    input  clk,
    input  rst_n,
    //input [31:0] inst,
    //input [31:0] mem_rdata, //由于使用了DPI-C机制，通过内部信号访问即可
    output invalid_inst,
    output [31:0] debug_pc,
    output [31:0] debug_inst
    //output [31:0] pc
    //output mem_we,
    //output [31:0] mem_addr,
    //output [31:0] mem_wdata
);
  //IFU start
  wire [31:0] inst;
  wire [31:0] pc;
  IFU ifu1 (
      .rst_n(rst_n),
      .pc(pc),
      .inst(inst),
      .debug_pc(debug_pc),
      .debug_inst(debug_inst)
  );
  //IFU end
  wire [4:0] rs1;
  wire [4:0] rs2;
  wire [4:0] rd;
  wire [31:0] imm;
  wire [1:0] src_sel;
  wire [3:0] exu_op;
  wire pc_we;
  wire [1:0] pc_wsel;
  wire branch_en;
  wire [2:0] branch_op;
  wire gpr_we;
  wire [2:0] gpr_wsel;
  wire is_ebreak;

  wire [31:0] mem_rdata;
  wire mem_wen;
  wire [1:0] mem_rbhw;
  wire [1:0] mem_wbhw;
  wire isign;
  wire mem_valid;
  IDU idu1 (
      .inst(inst),
      .rs1(rs1),
      .rs2(rs2),
      .rd(rd),
      .imm(imm),
      .invalid_inst(invalid_inst),
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
      .gpr_wsel(gpr_wsel)
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
  wire pc_write_en = pc_we || branch_taken;
  WBU wbu1 (
      .clk(clk),
      .rst_n(rst_n),
      .pc_we(pc_write_en),
      .pc_wsel(pc_wsel),
      .exu_result(exu_result),
      .imm(imm),
      .gpr_we(gpr_we),
      .gpr_wsel(gpr_wsel),
      .mem_rdata(mem_rdata),
      .rs1(rs1),
      .rs2(rs2),
      .rd(rd),
      .gpr_rdata1(Rrs1),
      .gpr_rdata2(Rrs2),
      .gpr_a0(gpr_a0),
      .gpr_wdata(gpr_wdata),
      .pc(pc)
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
      .mem_rdata_r(mem_rdata)
  );


  always @(posedge clk) begin
    if (rst_n && gpr_we) begin
      npc_reg_write({27'b0, rd}, gpr_wdata);
    end
    if (rst_n && is_ebreak) begin
      npc_ebreak(gpr_a0, pc);
    end
  end

endmodule
