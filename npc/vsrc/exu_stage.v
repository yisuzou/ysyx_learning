// exu_stage: execute stage with its own local lifecycle.
// Snapshots the IDU message on in_fire, runs the combinational ALU/branch unit
// in EXEC, optionally issues one LSU request and waits for its response, then
// holds the completed result in SEND_WB until WBU accepts it.  Final result
// selection for PC, GPR and CSR moved here from WBU; WBU only commits.
module exu_stage #(
    parameter [31:0] PMEM_BASE = 32'h80000000,
    parameter [31:0] PMEM_SIZE = 32'h08000000
) (
    input         clk,
    input         rst_n,

    // Input message from IDU.
    input         in_valid,
    output        in_ready,
    input  [31:0] in_pc,
    input  [31:0] in_inst,
    input         in_illegal,
    input  [ 4:0] in_rd,
    input  [31:0] in_rs1_value,
    input  [31:0] in_rs2_value,
    input  [31:0] in_imm,
    input  [31:0] in_csr_old,
    input  [31:0] in_mtvec,
    input  [31:0] in_a0,
    input  [ 1:0] in_src_sel,
    input  [ 3:0] in_exu_op,
    input         in_pc_we,
    input  [ 1:0] in_pc_wsel,
    input         in_branch_en,
    input  [ 2:0] in_branch_op,
    input         in_gpr_we,
    input  [ 2:0] in_gpr_wsel,
    input         in_mem_valid,
    input         in_mem_wen,
    input  [ 1:0] in_mem_rbhw,
    input  [ 1:0] in_mem_wbhw,
    input         in_isign,
    input         in_csr_we,
    input  [ 1:0] in_csr_wsel,
    input  [11:0] in_csr_addr,
    input         in_imm2csr,
    input         in_is_ecall,
    input         in_is_ebreak,

    // Output message to WBU.
    output        out_valid,
    input         out_ready,
    output reg [31:0] out_pc,
    output reg [31:0] out_inst,
    output reg [31:0] out_next_pc,
    output reg        out_illegal,
    output reg        out_rd_we,
    output reg [ 4:0] out_rd,
    output reg [31:0] out_rd_data,
    output reg        out_csr_we,
    output reg [11:0] out_csr_addr,
    output reg [31:0] out_csr_data,
    output reg        out_is_ecall,
    output reg        out_is_ebreak,
    output reg [31:0] out_a0,
    output reg        out_skip_ref,
    output reg [ 9:0] out_perf_class,

    // Read-only state observation for performance counters.
    output        dbg_busy,
    output        dbg_mem_wait,
    output        dbg_wait_wb,

    // LSU request/response.
    output        req_valid,
    input         req_ready,
    output [31:0] req_addr,
    output        req_write,
    output [ 1:0] req_rsize,
    output [ 1:0] req_wsize,
    output [31:0] req_wdata,
    output        req_sign,
    input         rsp_valid,
    output        rsp_ready,
    input  [31:0] rsp_rdata
);

  localparam [2:0] IDLE    = 3'd0,
                   EXEC    = 3'd1,
                   MEM_REQ = 3'd2,
                   MEM_WAIT= 3'd3,
                   SEND_WB = 3'd4;

  localparam [1:0] PC_EXU_RESULT = 2'h0;
  localparam [1:0] PC_BRANCH     = 2'h1;
  localparam [1:0] PC_TO_MTVEC   = 2'h2;
  localparam [1:0] PC_TO_MEPC    = 2'h3;

  localparam [2:0] GPR_EXU_RESULT = 3'd0;
  localparam [2:0] GPR_PC_PLUS4   = 3'd1;
  localparam [2:0] GPR_IMMEDIATE  = 3'd2;
  localparam [2:0] GPR_PC_IMM     = 3'd3;
  localparam [2:0] GPR_MEM_DATA   = 3'd4;

  localparam [1:0] CSR_EXU_RESULT = 2'd0;
  localparam [1:0] CSR_REG        = 2'd2;

  // -------------------------------------------------------------------------
  // Input snapshot.  Every de field is latched on in_fire only, so the whole
  // message stays stable for as long as this stage owns it.
  // -------------------------------------------------------------------------
  reg [31:0] pc_q;
  reg [31:0] inst_q;
  reg        illegal_q;
  reg [ 4:0] rd_q;
  reg [31:0] rs1_value_q;
  reg [31:0] rs2_value_q;
  reg [31:0] imm_q;
  reg [31:0] csr_old_q;
  reg [31:0] mtvec_q;
  reg [31:0] a0_q;
  reg [ 1:0] src_sel_q;
  reg [ 3:0] exu_op_q;
  reg        pc_we_q;
  reg [ 1:0] pc_wsel_q;
  reg        branch_en_q;
  reg [ 2:0] branch_op_q;
  reg        gpr_we_q;
  reg [ 2:0] gpr_wsel_q;
  reg        mem_valid_q;
  reg        mem_wen_q;
  reg [ 1:0] mem_rbhw_q;
  reg [ 1:0] mem_wbhw_q;
  reg        isign_q;
  reg        csr_we_q;
  reg [ 1:0] csr_wsel_q;
  reg [11:0] csr_addr_q;
  reg        imm2csr_q;
  reg        is_ecall_q;
  reg        is_ebreak_q;

  // -------------------------------------------------------------------------
  // Local lifecycle and handshakes.
  // -------------------------------------------------------------------------
  reg [2:0] state;
  reg [2:0] next_state;
  wire in_fire;
  wire out_fire;
  wire req_fire;
  wire rsp_fire;

  assign in_ready  = rst_n && (state == IDLE);
  assign out_valid = rst_n && (state == SEND_WB);
  assign req_valid = rst_n && (state == MEM_REQ);
  assign rsp_ready = rst_n && (state == MEM_WAIT);
  assign in_fire   = in_valid && in_ready;
  assign out_fire  = out_valid && out_ready;
  assign req_fire  = req_valid && req_ready;
  assign rsp_fire  = rsp_valid && rsp_ready;

  assign dbg_busy     = (state != IDLE);
  assign dbg_mem_wait = (state == MEM_REQ) || (state == MEM_WAIT);
  assign dbg_wait_wb  = (state == SEND_WB) && !out_ready;

  always @(*) begin
    next_state = state;
    case (state)
      IDLE: if (in_fire) next_state = EXEC;
      EXEC: begin
        if (illegal_q) next_state = SEND_WB;
        else if (mem_valid_q) next_state = MEM_REQ;
        else next_state = SEND_WB;
      end
      MEM_REQ: if (req_fire) next_state = MEM_WAIT;
      MEM_WAIT: if (rsp_fire) next_state = SEND_WB;
      SEND_WB: if (out_fire) next_state = IDLE;
      default: next_state = IDLE;
    endcase
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) state <= IDLE;
    else state <= next_state;
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pc_q        <= 32'b0;
      inst_q      <= 32'b0;
      illegal_q   <= 1'b0;
      rd_q        <= 5'b0;
      rs1_value_q <= 32'b0;
      rs2_value_q <= 32'b0;
      imm_q       <= 32'b0;
      csr_old_q   <= 32'b0;
      mtvec_q     <= 32'b0;
      a0_q        <= 32'b0;
      src_sel_q   <= 2'b0;
      exu_op_q    <= 4'b0;
      pc_we_q     <= 1'b0;
      pc_wsel_q   <= 2'b0;
      branch_en_q <= 1'b0;
      branch_op_q <= 3'b0;
      gpr_we_q    <= 1'b0;
      gpr_wsel_q  <= 3'b0;
      mem_valid_q <= 1'b0;
      mem_wen_q   <= 1'b0;
      mem_rbhw_q  <= 2'b0;
      mem_wbhw_q  <= 2'b0;
      isign_q     <= 1'b0;
      csr_we_q    <= 1'b0;
      csr_wsel_q  <= 2'b0;
      csr_addr_q  <= 12'b0;
      imm2csr_q   <= 1'b0;
      is_ecall_q  <= 1'b0;
      is_ebreak_q <= 1'b0;
    end else if (in_fire) begin
      pc_q        <= in_pc;
      inst_q      <= in_inst;
      illegal_q   <= in_illegal;
      rd_q        <= in_rd;
      rs1_value_q <= in_rs1_value;
      rs2_value_q <= in_rs2_value;
      imm_q       <= in_imm;
      csr_old_q   <= in_csr_old;
      mtvec_q     <= in_mtvec;
      a0_q        <= in_a0;
      src_sel_q   <= in_src_sel;
      exu_op_q    <= in_exu_op;
      pc_we_q     <= in_pc_we;
      pc_wsel_q   <= in_pc_wsel;
      branch_en_q <= in_branch_en;
      branch_op_q <= in_branch_op;
      gpr_we_q    <= in_gpr_we;
      gpr_wsel_q  <= in_gpr_wsel;
      mem_valid_q <= in_mem_valid;
      mem_wen_q   <= in_mem_wen;
      mem_rbhw_q  <= in_mem_rbhw;
      mem_wbhw_q  <= in_mem_wbhw;
      isign_q     <= in_isign;
      csr_we_q    <= in_csr_we;
      csr_wsel_q  <= in_csr_wsel;
      csr_addr_q  <= in_csr_addr;
      imm2csr_q   <= in_imm2csr;
      is_ecall_q  <= in_is_ecall;
      is_ebreak_q <= in_is_ebreak;
    end
  end

  // -------------------------------------------------------------------------
  // Combinational ALU and branch unit on the stable snapshot.
  // -------------------------------------------------------------------------
  wire [31:0] execute_imm;
  wire [31:0] alu_result;
  wire        alu_zero;
  wire        alu_signed_lt;
  wire        alu_unsigned_lt;
  wire        branch_taken;

  assign execute_imm = imm2csr_q ? csr_old_q : imm_q;

  EXU alu (
      .rs1(rs1_value_q),
      .rs2(rs2_value_q),
      .imm(execute_imm),
      .pc(pc_q),
      .src_sel(src_sel_q),
      .exu_op(exu_op_q),
      .result(alu_result),
      .zero(alu_zero),
      .signed_lt(alu_signed_lt),
      .unsigned_lt(alu_unsigned_lt)
  );

  BranchUnit branch_unit (
      .branch_en(branch_en_q),
      .branch_op(branch_op_q),
      .zero(alu_zero),
      .signed_lt(alu_signed_lt),
      .unsigned_lt(alu_unsigned_lt),
      .branch_taken(branch_taken)
  );

  // -------------------------------------------------------------------------
  // Final result selection, moved from WBU.
  // -------------------------------------------------------------------------
  reg [31:0] next_pc_calc;
  reg [31:0] rd_data_calc;
  reg [31:0] csr_data_calc;

  always @(*) begin
    next_pc_calc = pc_q + 32'd4;
    if (branch_en_q && branch_taken)
      next_pc_calc = pc_q + imm_q;
    if (pc_we_q) begin
      case (pc_wsel_q)
        PC_EXU_RESULT: next_pc_calc = alu_result & 32'hfffffffe;
        PC_BRANCH:     next_pc_calc = pc_q + imm_q;
        PC_TO_MTVEC:   next_pc_calc = mtvec_q;
        PC_TO_MEPC:    next_pc_calc = csr_old_q;
        default:       next_pc_calc = pc_q + 32'd4;
      endcase
    end

    case (gpr_wsel_q)
      GPR_EXU_RESULT: rd_data_calc = alu_result;
      GPR_PC_PLUS4:   rd_data_calc = pc_q + 32'd4;
      GPR_IMMEDIATE:  rd_data_calc = execute_imm;
      GPR_PC_IMM:     rd_data_calc = pc_q + imm_q;
      GPR_MEM_DATA:   rd_data_calc = 32'b0;
      default:        rd_data_calc = 32'b0;
    endcase

    case (csr_wsel_q)
      CSR_EXU_RESULT: csr_data_calc = alu_result;
      CSR_REG:        csr_data_calc = rs1_value_q;
      default:        csr_data_calc = csr_old_q;
    endcase
  end

  // -------------------------------------------------------------------------
  // LSU request: fields are pure functions of the stable snapshot, so no
  // second copy of them is needed.
  // -------------------------------------------------------------------------
  assign req_addr  = alu_result;
  assign req_write = mem_wen_q;
  assign req_rsize = mem_rbhw_q;
  assign req_wsize = mem_wbhw_q;
  assign req_wdata = rs2_value_q;
  assign req_sign  = isign_q;

  // -------------------------------------------------------------------------
  // Performance class, carried with the message for step 12 counting.
  // -------------------------------------------------------------------------
  wire is_csr_calc;
  wire [9:0] perf_class_calc;

  assign is_csr_calc = (inst_q[6:0] == 7'b1110011) &&
                       ((inst_q[14:12] == 3'b001) ||
                        (inst_q[14:12] == 3'b010));
  assign perf_class_calc[0] = gpr_we_q && (gpr_wsel_q == GPR_EXU_RESULT);
  assign perf_class_calc[1] = mem_valid_q && !mem_wen_q;
  assign perf_class_calc[2] = mem_valid_q && mem_wen_q;
  assign perf_class_calc[3] = branch_en_q;
  assign perf_class_calc[4] = pc_we_q && (pc_wsel_q == PC_EXU_RESULT);
  assign perf_class_calc[5] = is_csr_calc;
  assign perf_class_calc[6] = is_ecall_q || is_ebreak_q ||
                              (pc_we_q && (pc_wsel_q == PC_TO_MEPC));
  assign perf_class_calc[7] = gpr_we_q &&
                              (gpr_wsel_q == GPR_IMMEDIATE) && !is_csr_calc;
  assign perf_class_calc[8] = gpr_we_q && (gpr_wsel_q == GPR_PC_IMM);
  assign perf_class_calc[9] = perf_class_calc[0] || perf_class_calc[1] ||
                              perf_class_calc[2] || perf_class_calc[3] ||
                              perf_class_calc[4] || perf_class_calc[8] ||
                              (is_csr_calc && (csr_wsel_q == CSR_EXU_RESULT));

  // -------------------------------------------------------------------------
  // Output message registers: loaded in EXEC, load data patched on rsp_fire,
  // held unchanged in SEND_WB until WBU accepts the message.
  // -------------------------------------------------------------------------
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      out_pc         <= 32'b0;
      out_inst       <= 32'b0;
      out_next_pc    <= 32'b0;
      out_illegal    <= 1'b0;
      out_rd_we      <= 1'b0;
      out_rd         <= 5'b0;
      out_rd_data    <= 32'b0;
      out_csr_we     <= 1'b0;
      out_csr_addr   <= 12'b0;
      out_csr_data   <= 32'b0;
      out_is_ecall   <= 1'b0;
      out_is_ebreak  <= 1'b0;
      out_a0         <= 32'b0;
      out_skip_ref   <= 1'b0;
      out_perf_class <= 10'b0;
    end else if (state == EXEC) begin
      out_pc         <= pc_q;
      out_inst       <= inst_q;
      out_next_pc    <= next_pc_calc;
      out_illegal    <= illegal_q;
      out_rd_we      <= gpr_we_q && !illegal_q;
      out_rd         <= rd_q;
      out_rd_data    <= rd_data_calc;
      out_csr_we     <= csr_we_q && !illegal_q;
      out_csr_addr   <= csr_addr_q;
      out_csr_data   <= csr_data_calc;
      out_is_ecall   <= is_ecall_q && !illegal_q;
      out_is_ebreak  <= is_ebreak_q && !illegal_q;
      out_a0         <= a0_q;
      out_skip_ref   <= !illegal_q && mem_valid_q &&
                        ((alu_result - PMEM_BASE) >= PMEM_SIZE);
      out_perf_class <= perf_class_calc;
    end else if (rsp_fire) begin
      if (!mem_wen_q) out_rd_data <= rsp_rdata;
    end
  end

endmodule
