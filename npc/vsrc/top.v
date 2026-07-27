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
  wire gpr_we;
  wire is_ebreak;

  reg [31:0] mem_rdata;
  reg mem_wen;
  reg [1:0] mem_rbhw;
  reg [1:0] mem_wbhw;
  reg [31:0] mem_raddr;
  reg [31:0] mem_waddr;
  reg [31:0] mem_wdata;
  reg [7:0] mem_mask;
  wire isign;
  wire valid;
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
      .gpr_we(gpr_we),
      .mem_we(mem_wen),
      .mem_rbhw(mem_rbhw),
      .mem_wbhw(mem_wbhw),
      .isign(isign),
      .is_ebreak(is_ebreak),
      .valid(valid),
      .gpr_wsel(gpr_wsel)
  );
  wire [31:0] exu_result;
  wire [31:0] Rrs1;
  wire [31:0] Rrs2;
  wire [31:0] gpr_a0;
  EXU exu1 (
      .rs1(Rrs1),
      .rs2(Rrs2),
      .imm(imm),
      .src_sel(src_sel),
      .exu_op(exu_op),
      .result(exu_result)
  );

  reg  [31:0] gpr_wdata;  //允许写入的数据包括pc及其运算，运算结果，立即数
  wire [ 2:0] gpr_wsel;
  always @(*) begin
    case (gpr_wsel)
      3'd0: begin
        gpr_wdata = exu_result;
      end
      3'd1: begin
        gpr_wdata = pc + 32'h4;
      end
      3'd2: begin
        gpr_wdata = imm;  //lui
      end
      3'd3: begin
        gpr_wdata = pc + imm;  //auipc
      end
      3'd4: begin
        gpr_wdata = mem_rdata;
      end
      default: begin
        gpr_wdata = 32'h0;
      end
    endcase
  end
  WBU wbu1 (
      .clk(clk),
      .rst_n(rst_n),
      .pc_we(pc_we),
      .pc_wdata(exu_result & (~32'h1)),
      .gpr_we(gpr_we),
      .gpr_wdata(gpr_wdata),
      .rs1(rs1),
      .rs2(rs2),
      .rd(rd),
      .gpr_rdata1(Rrs1),
      .gpr_rdata2(Rrs2),
      .gpr_a0(gpr_a0),
      .pc(pc)
  );
  //访存单元
  assign mem_raddr = exu_result;
  always @(*) begin
    mem_waddr = exu_result;
    case (mem_wbhw)
      2'd1: begin
        mem_mask = 8'b00000001 << mem_waddr[1:0];
      end
      2'd2: begin
        mem_mask = 8'b00000011 << mem_waddr[1:0];
      end
      2'd3: begin
        mem_mask = 8'b00001111;
      end
      default: mem_mask = 8'hf;
    endcase
    mem_wdata = Rrs2 << (8 * mem_waddr[1:0]);
  end
  LSU lsu1 (
      .clk(clk),
      .rst_n(rst_n),
      .mem_rbhw(mem_rbhw),  //由译码IDU给出
      .mem_raddr(mem_raddr),  //由EXU给出
      .valid(valid),  //IDU给出
      .wen(mem_wen),  //IDU给出
      .mem_waddr(mem_waddr),  //exu
      .mem_wdata(mem_wdata),  //wbu
      .mem_wmask(mem_mask),  //idu
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
