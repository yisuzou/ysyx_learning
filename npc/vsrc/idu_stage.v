// idu_stage: instruction decode stage with a one-entry message slot.
// Wraps the original combinational IDU, latches the decode result plus
// register/CSR read values, and delivers them to EXU through a ready/valid
// handshake.  GPR/CSR register files live in npc_core; this stage only drives
// their read addresses and consumes the read data.
module idu_stage (
    input clk,
    input rst_n,

    // Input message from IFU.
    input        in_valid,
    output       in_ready,
    input [31:0] in_pc,
    input [31:0] in_inst,

    // Output message to EXU.
    output        out_valid,
    input         out_ready,
    output reg [31:0] out_pc,
    output reg [31:0] out_inst,
    output reg        out_illegal,
    output reg [ 4:0] out_rd,
    output reg [ 4:0] out_rs1,
    output reg [ 4:0] out_rs2,
    output reg [31:0] out_rs1_value,
    output reg [31:0] out_rs2_value,
    output reg [31:0] out_imm,
    output reg [31:0] out_csr_old,
    output reg [31:0] out_mtvec,
    output reg [31:0] out_a0,
    output reg [ 1:0] out_src_sel,
    output reg [ 3:0] out_exu_op,
    output reg        out_pc_we,
    output reg [ 1:0] out_pc_wsel,
    output reg        out_branch_en,
    output reg [ 2:0] out_branch_op,
    output reg        out_gpr_we,
    output reg [ 2:0] out_gpr_wsel,
    output reg        out_mem_valid,
    output reg        out_mem_wen,
    output reg [ 1:0] out_mem_rbhw,
    output reg [ 1:0] out_mem_wbhw,
    output reg        out_isign,
    output reg        out_csr_we,
    output reg [ 1:0] out_csr_wsel,
    output reg [11:0] out_csr_addr,
    output reg        out_imm2csr,
    output reg        out_is_ecall,
    output reg        out_is_ebreak,

    // GPR read ports.
    output [ 4:0] gpr_raddr1,
    output [ 4:0] gpr_raddr2,
    input  [31:0] gpr_rdata1,
    input  [31:0] gpr_rdata2,
    input  [31:0] gpr_a0,

    // CSR read ports.
    output [11:0] csr_raddr1,
    input  [31:0] csr_rdata1,
    input  [31:0] csr_mtvec,
    input         csr_invalid_addr
);

  // -------------------------------------------------------------------------
  // Original IDU instance: it produces the combinational decode signals.
  // All outputs are prefixed with d_ to keep them distinct from the latched
  // out_ signals that travel to EXU.
  // -------------------------------------------------------------------------
  wire [ 4:0] d_rs1;
  wire [ 4:0] d_rs2;
  wire [ 4:0] d_rd;
  wire [31:0] d_imm;
  wire        d_illegal;
  wire [ 1:0] d_src_sel;
  wire [ 3:0] d_exu_op;
  wire        d_pc_we;
  wire [ 1:0] d_pc_wsel;
  wire        d_branch_en;
  wire [ 2:0] d_branch_op;
  wire        d_gpr_we;
  wire [ 2:0] d_gpr_wsel;
  wire        d_mem_we;
  wire [ 1:0] d_mem_rbhw;
  wire [ 1:0] d_mem_wbhw;
  wire        d_isign;
  wire        d_mem_valid;
  wire        d_is_ebreak;
  wire        d_csr_we;
  wire [ 1:0] d_csr_wsel;
  wire [11:0] d_csr_addr;
  wire        d_imm2csr;
  wire        d_is_ecall;

  IDU idu1 (
      .inst(in_inst),
      .rs1(d_rs1),
      .rs2(d_rs2),
      .rd(d_rd),
      .imm(d_imm),
      .invalid_inst(d_illegal),
      .src_sel(d_src_sel),
      .exu_op(d_exu_op),
      .pc_we(d_pc_we),
      .pc_wsel(d_pc_wsel),
      .branch_en(d_branch_en),
      .branch_op(d_branch_op),
      .gpr_we(d_gpr_we),
      .mem_we(d_mem_we),
      .mem_rbhw(d_mem_rbhw),
      .mem_wbhw(d_mem_wbhw),
      .isign(d_isign),
      .is_ebreak(d_is_ebreak),
      .mem_valid(d_mem_valid),
      .gpr_wsel(d_gpr_wsel),
      .csr_we(d_csr_we),
      .csr_wsel(d_csr_wsel),
      .csr_wraddr(d_csr_addr),
      .imm2csr(d_imm2csr),
      .is_ecall(d_is_ecall)
  );

  // Read addresses are driven straight from the decode result.  The register
  // files live in npc_core and return combinational read data.
  assign gpr_raddr1 = d_rs1;
  assign gpr_raddr2 = d_rs2;
  assign csr_raddr1 = d_csr_addr;

  // -------------------------------------------------------------------------
  // CSR access check.  invalid_csr_access comes from the CSR module and is
  // only relevant when this instruction really needs to read a CSR.
  // -------------------------------------------------------------------------
  wire is_csr_op;
  wire uses_csr_read;
  wire csr_write_intent;
  wire csr_access_bad;
  wire bad_csr_gpr;
  wire decoded_illegal;

  assign is_csr_op = (in_inst[6:0] == 7'b1110011) &&
                     ((in_inst[14:12] == 3'b001) ||
                      (in_inst[14:12] == 3'b010));
  assign uses_csr_read = is_csr_op || (in_inst == 32'h30200073);  // mret
  // 当前支持 CSRRW、CSRRS；CSRRS rs1=x0 不写。
  assign csr_write_intent = d_csr_we &&
      !((in_inst[14:12] == 3'b010) && (d_rs1 == 5'd0));
  assign csr_access_bad = (uses_csr_read && csr_invalid_addr) ||
      (is_csr_op && csr_write_intent && (d_csr_addr[11:10] == 2'b11));
`ifdef CONFIG_RVE
  assign bad_csr_gpr = is_csr_op && (d_rs1[4] || d_rd[4]);
`else
  assign bad_csr_gpr = 1'b0;
`endif
  assign decoded_illegal = d_illegal || csr_access_bad || bad_csr_gpr;

  // -------------------------------------------------------------------------
  // One-entry message slot.
  // -------------------------------------------------------------------------
  reg full;
  wire in_fire;
  wire out_fire;

  assign in_ready  = rst_n && !full;
  assign out_valid = rst_n && full;
  assign in_fire   = in_valid && in_ready;
  assign out_fire  = out_valid && out_ready;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      full <= 1'b0;
    end else if (in_fire) begin
      full <= 1'b1;
    end else if (out_fire) begin
      full <= 1'b0;
    end
  end

  // -------------------------------------------------------------------------
  // Latch the complete decode message on in_fire.
  // Register/CSR read values are sampled at the same edge, so they are
  // stable for the lifetime of this message.
  // -------------------------------------------------------------------------
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      out_pc        <= 32'b0;
      out_inst      <= 32'b0;
      out_illegal   <= 1'b0;
      out_rd        <= 5'b0;
      out_rs1       <= 5'b0;
      out_rs2       <= 5'b0;
      out_rs1_value <= 32'b0;
      out_rs2_value <= 32'b0;
      out_imm       <= 32'b0;
      out_csr_old   <= 32'b0;
      out_mtvec     <= 32'b0;
      out_a0        <= 32'b0;
      out_src_sel   <= 2'b0;
      out_exu_op    <= 4'b0;
      out_pc_we     <= 1'b0;
      out_pc_wsel   <= 2'b0;
      out_branch_en <= 1'b0;
      out_branch_op <= 3'b0;
      out_gpr_we    <= 1'b0;
      out_gpr_wsel  <= 3'b0;
      out_mem_valid <= 1'b0;
      out_mem_wen   <= 1'b0;
      out_mem_rbhw  <= 2'b0;
      out_mem_wbhw  <= 2'b0;
      out_isign     <= 1'b0;
      out_csr_we    <= 1'b0;
      out_csr_wsel  <= 2'b0;
      out_csr_addr  <= 12'b0;
      out_imm2csr   <= 1'b0;
      out_is_ecall  <= 1'b0;
      out_is_ebreak <= 1'b0;
    end else if (in_fire) begin
      out_pc        <= in_pc;
      out_inst      <= in_inst;
      out_illegal   <= decoded_illegal;
      out_rd        <= d_rd;
      out_rs1       <= d_rs1;
      out_rs2       <= d_rs2;
      out_rs1_value <= gpr_rdata1;
      out_rs2_value <= gpr_rdata2;
      out_imm       <= d_imm;
      out_csr_old   <= csr_rdata1;
      out_mtvec     <= csr_mtvec;
      out_a0        <= gpr_a0;
      out_src_sel   <= d_src_sel;
      out_exu_op    <= d_exu_op;
      out_pc_we     <= d_pc_we;
      out_pc_wsel   <= d_pc_wsel;
      out_branch_en <= d_branch_en;
      out_branch_op <= d_branch_op;
      out_gpr_we    <= d_gpr_we;
      out_gpr_wsel  <= d_gpr_wsel;
      out_mem_valid <= d_mem_valid;
      out_mem_wen   <= d_mem_we;
      out_mem_rbhw  <= d_mem_rbhw;
      out_mem_wbhw  <= d_mem_wbhw;
      out_isign     <= d_isign;
      out_csr_we    <= csr_write_intent;
      out_csr_wsel  <= d_csr_wsel;
      out_csr_addr  <= d_csr_addr;
      out_imm2csr   <= d_imm2csr;
      out_is_ecall  <= d_is_ecall;
      out_is_ebreak <= d_is_ebreak;
    end
  end

endmodule
