module ex3 (
    input [10:0] sw,  //sw10,9,8
    output [6:0] hexA0,  //A + B = result,操作数已经是补码
    output [6:0] hexA1,
    output [6:0] hexB0,
    output [6:0] hexB1,
    output [6:0] hexC0,
    output [6:0] hexC1,
    output overflow,
    carry,
    zero
);
  wire [2:0] mode;
  wire [3:0] A;
  wire [3:0] B;
  assign mode = sw[10:8];
  assign A = sw[7:4];
  assign B = sw[3:0];
  wire [3:0] result;
  assign {carry,result} = (mode == 3'b000) ? A + B :
                  (mode == 3'b001) ? A - B :
                  (mode == 3'b010) ? {1'b0,~A} :
                  (mode == 3'b011) ? {1'b0,A & B}:
                  (mode == 3'b100) ? {1'b0,A | B}:
                  (mode == 3'b101) ? {1'b0,A ^ B}:
                  (mode == 3'b110) ? (A<B ? 5'b00001:5'b0):
                  (A == B ? 5'b00001:5'b0);
  assign hexA0 = A[3] ? 7'b0111111 : 7'b1111111;
  assign hexB0 = B[3] ? 7'b0111111 : 7'b1111111;
  assign hexC0 = result[3] ? 7'b0111111 : 7'b1111111;
  bcd2seg ha (
      A,
      hexA1
  );
  bcd2seg hb (
      B,
      hexB1
  );
  bcd2seg hc (
      result,
      hexC1
  );
  assign overflow = (A[3] == B[3]) && (result[3] != A[3]);
  assign zero = ~(|result);// |result的含义是，将result的每一位都或起来，这样只要有1就会输出1，全0输出0，再取反实现ZERO FLAG的设计

endmodule

module bcd2seg (
    input [3:0] bcd,
    output reg [6:0] seg
);
  always @(*) begin
    if (!bcd[3]) begin
      case (bcd[2:0])
        3'd0: seg = 7'b1000000;
        3'd1: seg = 7'b1111001;
        3'd2: seg = 7'b0100100;
        3'd3: seg = 7'b0110000;
        3'd4: seg = 7'b0011001;
        3'd5: seg = 7'b0010010;
        3'd6: seg = 7'b0000010;
        3'd7: seg = 7'b1111000;
        default: seg = 7'b1111111;
      endcase
    end else begin
      case (bcd[2:0])
        3'd0: seg = 7'b0000000;
        3'd1: seg = 7'b1111000;
        3'd2: seg = 7'b0000010;
        3'd3: seg = 7'b0010010;
        3'd4: seg = 7'b0011001;
        3'd5: seg = 7'b0110000;
        3'd6: seg = 7'b0100100;
        3'd7: seg = 7'b1111001;
        default: seg = 7'b1111111;
      endcase
    end
  end
endmodule
