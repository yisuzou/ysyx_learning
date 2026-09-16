module IFU (
    input clk,
    input memfinish,
    input mem_valid,
    input rst_n,
    input [31:0] pc,
    input [31:0] ifu_rdata, //inst_form_mem
    input ifu_respValid, //确认收到指令，访存完成
    output ifu_reqValid, //上一条已执行完毕，可以发出下一条指令请求
    output [31:0] ifu_raddr, //pc
    output reg [31:0] inst, //实际执行指令
    output reg ifu_valid//从状态机视角出发，这个也就是state
);
  localparam IDLE = 1'b0; //发出地址请求
  localparam WAIT = 1'b1; //等待后级消费返回数据
//内部信号声明
reg next_state;

//当前状态转移条件，仅依赖时序，一周期取指，一周期等待后级消费返回数据
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ifu_valid <= IDLE;
    end else begin
      ifu_valid <= next_state;
    end
  end
//预留组合跳转

assign ifu_raddr = pc; //当前周期发出地址请求，下一周期等待后级消费返回数据
assign ifu_reqValid = ifu_respValid ? 1'b0 : rst_n && (ifu_valid == IDLE);
//状态机下的输出逻辑，组合逻辑，当前状态决定下一状态和输出
always @(*) begin
    case (ifu_valid)
      IDLE: begin
        if(ifu_respValid)begin
          inst = ifu_rdata; //后级消费返回数据
          next_state = WAIT; //正在访问内存，继续等待
        end
        else begin
          inst = 32'h13; //当前周期没有数据返回
          next_state = WAIT; //下一周期进入等待状态
        end
      end
      WAIT: begin
        inst = ifu_rdata; //后级消费返回数据
        if(mem_valid)begin
          next_state = memfinish ? IDLE : WAIT ; //正在访问内存，继续等待
        end
        else begin
        next_state = IDLE; //下一周期进入空闲状态，准备发出下一个地址请求
        end
      end
      default: begin
        inst = 32'b0;
        next_state = IDLE;
      end
    endcase
  end
endmodule
