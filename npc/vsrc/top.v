module top (  //scpu
    input clk,
    input rst,
    output [6:0] hex0,
    output [6:0] hex1,
    output [6:0] pcnt
);
  reg  [3:0] PC;
  reg  [7:0] GPR  [4];
  wire [7:0] inst;
  rom r1 (
      PC,
      inst
  );  //取指
  //解码
  wire [1:0] opcode = inst[7:6];
  wire [1:0] rd = inst[5:4];
  wire [1:0] rs1 = inst[3:2];
  wire [1:0] rs2 = inst[1:0];
  wire [3:0] imm = inst[3:0];
  wire [3:0] addr_b = inst[5:2];

  //指令实现
  //结果其实早就被计算好，指令控制数据流向；
  wire [7:0] alu_result = GPR[rs1] + GPR[rs2];//读寄存器
  wire [7:0] imm_ext    = {4'b0, imm};
  // 选择要写回寄存器的数据 (MUX)
  wire [7:0] write_data = (opcode == 2'b00) ? alu_result : imm_ext;
  // 寄存器写使能信号 (只有 ADD 和 LI 需要写寄存器)
  wire reg_write_en = (opcode == 2'b00) || (opcode == 2'b10);




  wire [6:0] hex_0, hex_1;
  hex2seg h0 (
      GPR[rs2][3:0],
      hex_0
  );
  hex2seg h1 (
      GPR[rs2][7:4],
      hex_1
  );
  assign hex0 = (opcode == 2'b01) ? hex_0 : 7'b1111111;
  assign hex1 = (opcode == 2'b01) ? hex_1 : 7'b1111111;
  //显示程序计数器
  hex2seg h3 (
      PC,
      pcnt
  );

  always @(posedge clk) begin
    if (!rst) begin
      PC <= 0;
      GPR[0] <= 0;
      GPR[1] <= 0;
      GPR[2] <= 0;
      GPR[3] <= 0;
    end else begin
      // GPR[rd] <= (opcode == 2'b0) ? (GPR[rs1] + GPR[rs2]) : {4'b0, imm}; BUG
      if ((opcode == 2'b11) & (GPR[0] != GPR[rs2])) begin
        PC <= addr_b;
      end else begin
        PC <= PC + 1;
      end
      if (reg_write_en) begin
        GPR[rd] <= write_data;
      end
    end
  end
endmodule

module rom (
    input  [3:0] addr,
    output [7:0] inst
);
  //reg [7:0]mem[8:0];
  assign instr = (addr == 4'd0 ) ? 8'b10001010 :
               (addr == 4'd1 ) ? 8'b10010000 :
               (addr == 4'd2 ) ? 8'b10100000 :
               (addr == 4'd3 ) ? 8'b10110001 :
               (addr == 4'd4 ) ? 8'b00010111 :
               (addr == 4'd5 ) ? 8'b00101001 :
               (addr == 4'd6 ) ? 8'b11010001 :
               (addr == 4'd7 ) ? 8'b01000010 :
               (addr == 4'd8 ) ? 8'b11011111 : 8'b11100011;

endmodule
