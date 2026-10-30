# NPC：用 Verilog 逐步实现消息控制的分布式多周期处理器

修订日期：2026-10-30。阅读对象：已经能读当前 NPC 的 Verilog，但还没有独立设计过带背压的多阶段处理器。

本讲义指导你亲手修改工程。本文新增的 RTL、测试代码均使用 Verilog-2005 可表达的语法：`wire/reg`、`always @(*)`、`always @(posedge clk ...)`、`localparam`、显式端口；不使用 struct、package、logic、always_ff 或 SVA。项目已有 DPI 仿真边界和已有 `.sv` 测试不必因此重写，它们是原有工具接口。

先理解每步的输入、输出、状态和退出条件，再写代码。带完整 `module ... endmodule` 的代码块可以单独编译；标为“模块内片段”的代码必须根据字段表补声明、端口和接线，不能当成完整 CPU 直接粘贴运行。完成讲义不等于已经验证处理器；通过最后的集成验收才算完成重构。

建议按顺序分次完成，每次只跨过一个验收点：

| 学习段 | 对应步骤 | 本段结束时应拿出的证据 |
|---|---|---|
| 理解交接 | 0～4、附录 A | 缓冲实验 PASS，能解释每个握手沿 |
| 建立前端消息 | 5～6 | IFU 背压保持、IDU 操作数快照测试 |
| 建立执行事务 | 7～8 | LSU 一次请求一次响应、EXU 阻塞测试 |
| 闭合提交链 | 9～11 | ADD/LOAD/branch 逐拍记录与正确提交 |
| 完成验收 | 12～13 | 故障、协议、ISA 回归与统计语义的检查记录 |

本次讲义校验：从文档抽出的 msg_slot、稳定性检查器和 TB 已通过 `iverilog -g2005` 编译；附录 A 的缓冲实验输出 PASS。全核实现片段尚未集成验证，不能把这个 PASS 当成重构后 CPU 的通过记录。

## 0. 先明确最终要造什么

最终 CPU 同一时钟域、全核最多一条在途指令。每条指令先由 IFU 持有，再由 IDU、EXU、WBU 依次持有；普通指令在 WBU 提交时把下一 PC 作为新消息交给 IFU。EXU 的访存通过 LSU 请求/响应完成。

这是分布式多周期处理器：每个阶段只用自己的状态和接口事件决定下一步，没有一个顶层 `FETCH/DECODE/EXECUTE/WRITEBACK` 大状态机调度所有单元。各阶段可以独立等待任意拍。局部状态机并不违背“消息控制”，恰恰是消息生命周期的实现。

这是单指令执行，不做多指令重叠。分布式不要求多条指令同时运行。将来流水化要另外处理数据冒险、错误路径、冲刷和多笔事务，不能简单提前下一次取指就宣称完成。

你最终应能指出：

| 接口 | 生产者 | 消费者 | 消息的意义 |
|---|---|---|---|
| `pc_valid/pc_ready/pc_data` | WBU | IFU | 授权从该 PC 取下一条指令 |
| `fi_valid/fi_ready/fi_pc/fi_inst` | IFU | IDU | 一条已经取得的指令 |
| `de_valid/de_ready/de_*` | IDU | EXU | 译码结果、操作数和该指令上下文 |
| `req_valid/req_ready/req_*` | EXU | LSU | 一次逻辑 load/store 请求 |
| `rsp_valid/rsp_ready/rsp_rdata` | LSU | EXU | 一次成功访存的结果 |
| `ew_valid/ew_ready/ew_*` | EXU | WBU | 已完成执行、等待提交的结果 |

一个逻辑访存可以拆成两个 AXI beat；它仍只对应一个 req 和一个成功 rsp。总线错误保留当前 sticky fatal 输出，进入终止状态，不伪装成成功 rsp。非法指令随阶段消息送到 WBU 报告，无寄存器写入或 LSU 请求。

### 思考题 0

**问：顶层集中连接所有模块，是否就不算分布式？**

**参考答案：** 接线集中不等于控制集中。顶层可以接线、放 GPR/CSR 实例、汇总 debug。关键是它不能通过窥探各模块内部 state 决定谁进入哪个阶段。应由每个模块按本地 `valid && ready`、AXI 响应和自己的状态推进。

**问：全核只有一条指令，为什么还需要 ready？**

**参考答案：** “现在不会拥塞”是全局调度性质；“接口什么时候可以交接”是局部契约。显式 ready 使每个阶段可以独立测试、人工阻塞、替换成不同延迟的实现，避免把这种全局假设隐藏进模块。

## 1. 第一步：记录基线，圈出旧控制链

先读 `vsrc/npc_core.v`、`IFU.v`、`IDU.v`、`EXU.v`、`WBU.v`、`LSU.v`。用以下锚点定位，避免依赖会变化的行号：

| 文件 | 搜索词 | 当前行为 |
|---|---|---|
| `npc_core.v` | `wire commit` | 由 ifu_valid、lsu_done、合法性组合出提交 |
| `IFU.v` | `execute_done` | IFU 知道是否访存，并一直等后端执行完成 |
| `IDU.v` | `module IDU` | 组合译码，输入变输出就变 |
| `EXU.v` | `module EXU` | 组合 ALU，不能保存一条执行任务 |
| `WBU.v` | `GPR gpr1`、`CSR csr1` | GPR、CSR、PC 和写回选择混在一起 |
| `LSU.v` | `DONE: if` | 结果直到全局 commit 才释放 |
| `csrc/cpu/cpu-exec.cpp` | `static bool exec_once` | 沿前读当前指令，沿后读下一 PC |

现在已经有多周期 AXI 取指和访存。要重构的是：后端依靠 IFU 长期保存 inst，组合信号贯穿各模块，再由全局 commit 同时收尾。这条隐含链必须拆开。

在仓库根目录记录当前配置和已有测试结果：

```sh
export NEMU_HOME="$PWD/nemu"
export AM_HOME="$PWD/abstract-machine"
export NPC_HOME="$PWD/npc"
export NAVY_HOME="$PWD/navy-apps"
export ISA=riscv32
make -C npc lint
make -C npc/tests
make -C am-kernels/tests/cpu-tests ARCH=riscv32e-npc ALL=add run
make -C am-kernels/tests/cpu-tests ARCH=riscv32e-npc ALL=dummy run
make -C am-kernels/tests/cpu-tests ARCH=riscv32e-npc ALL=unalign run
```

失败也要记录：重构前已有的问题与新增回归必须区分。不要运行 defconfig 覆盖配置。build/run 会触发项目自己的 tracer 自动提交，不删除该机制，不手动提交 tracer-ysyx。波形和随机延迟通过 menuconfig，不传 ITRACE/MTRACE/FTRACE/TRACE_FLAGS。

本轮改动的文件安排固定为：

| 文件 | 动作 |
|---|---|
| `IDU.v`、`EXU.v`、`BranchUnit.v` | 保留组合计算；ISA 修复单独记录 |
| `idu_stage.v` | 新增，内部实例化 IDU，增加接收/保存/发送 |
| `exu_stage.v` | 新增，内部实例化 EXU 和 BranchUnit，协调 LSU |
| `IFU.v` | 改为接收 PC 消息、发送指令消息 |
| `LSU.v` | 仅改 CPU 侧请求/响应生命周期 |
| `WBU.v` | 改为接收完整结果、统一提交 |
| `npc_core.v` | 搬入 GPR/CSR，接各通道及 debug/DPI |
| `vsrc/filelist.mk` | 显式增加两个新的 `.v` 文件 |

“内部实例化”是普通 Verilog 模块连接：`idu_stage` 使用原 IDU 算译码，再将结果锁存。原 IDU 回答“怎么算”，新阶段回答“何时接收和释放”。新增文件不是架构必需，而是本教程采用的明确实施方式，可减少同时改错译码表的风险。

在接口改完、顶层尚未接完的中间步骤，旧顶层可能暂时不能编译。此时用阶段独立 TB 验收，最后统一集成；不要用常量乱接新接口来掩盖问题。

### 思考题 1

**问：IFU 发出指令后就改 inst，原设计为什么可能出错？**

**参考答案：** IDU 会立刻重新译码，GPR 读地址、ALU 操作和写回控制都可能变化。原来正确依赖 IFU 把指令保持到 commit；新设计要把所有还会使用的上下文交给下游并锁存。

## 2. 第二步：把握手契约写下来

消息就是一组普通信号，分两部分：payload 是内容，valid/ready 是交接规则。`fi_pc` 和 `fi_inst` 是两组导线，不需要特殊语言类型。

```verilog
wire fi_fire;
assign fi_fire = fi_valid && fi_ready;
```

`fi_fire` 在周期内是组合条件；只有时钟上升沿采到它为 1，才发生一次交接。约定：

1. 生产者持有完整消息时拉高 valid，不能等 ready 才拉高。
2. valid=1 且 ready=0 时，valid 和全部 payload 必须保持到下一拍。
3. ready=1 是接收方对容量的承诺；握手后必须真正保存消息或完成接收。
4. 只有 fire 才消耗一条消息。单看 valid 或 ready 均不够。
5. 连续两个沿都 valid=ready=1，就是两次消息交接。
6. valid=0 时 payload 没有语义；不能看 inst 是否 NOP 来推断占用。
7. reset 清空阶段有效性；本文要求核、互连、从设备一起复位，不能只复位核后将旧响应当新响应。
8. 下游最终 ready、总线最终响应是活性前提；接口本身不保证环境公平。

这里采用与 [Arm AXI 握手规则](https://developer.arm.com/-/media/Arm%20Developer%20Community/PDF/IHI0022H_amba_axi_protocol_spec.pdf)相同的稳定性原则；内部指令消息不是完整 AXI 协议。

观察下面这张“上升沿采样值”表：

| 沿 | valid | ready | 内容 | 结果 |
|---|---|---|---|---|
| T0 | 1 | 0 | A | 未传输，发送方继续保存 A |
| T1 | 1 | 0 | A | 未传输，不能偷偷换成 B |
| T2 | 1 | 1 | A | 交接 A；沿后接收方负责保存 |
| T3 | 0 | 1 | 任意 | 没有交接 |

“所有权”指谁负责保证这条消息不丢失，并有权推进它。物理寄存器里可以残留多个 A 的副本，只有 valid 所表示的那份具有执行意义。

### 思考题 2

**问：valid 高三拍，是否执行三次？**

**参考答案：** 看三个上升沿的 ready。都低则零次；只有最后一拍高则一次；三拍都高则三次。需要一次性处理就必须在第一次握手后清除/推进发送状态。

**问：能否写 `valid = have_data && ready`？**

**参考答案：** 不应这样设计。接收方若等待 valid 才 ready，就可能双方互等；且生产者把“有消息”与“对方能接”混为一谈。valid 应由本地保存的消息/状态产生。

## 3. 第三步：先练习一格消息寄存器

先写 `npc/tests/msg_slot.v`（这是练习模块，不必加入 CPU filelist）。下面是完整模块：

```verilog
`timescale 1ns/1ps
module msg_slot #(parameter W = 64) (
    input clk,
    input rst_n,
    input in_valid,
    output in_ready,
    input [W-1:0] in_data,
    output out_valid,
    input out_ready,
    output [W-1:0] out_data
);
  reg full;
  reg [W-1:0] data_q;
  wire in_fire;
  wire out_fire;
  assign in_ready = rst_n && !full;
  assign out_valid = rst_n && full;
  assign out_data = data_q;
  assign in_fire = in_valid && in_ready;
  assign out_fire = out_valid && out_ready;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      full <= 1'b0;
      data_q <= {W{1'b0}};
    end else if (in_fire) begin
      full <= 1'b1;
      data_q <= in_data;
    end else if (out_fire) begin
      full <= 1'b0;
    end
  end
endmodule
```

逐句理解：`full` 是本模块是否持有消息，不是“这条指令已经执行完”。`in_ready=!full` 保证不会覆盖尚未被接走的数据；`out_valid=full` 声明一份有效结果；没有 fire 时不写 data_q，天然实现背压稳定。

这一版有一个刻意保留的气泡：full=1 时即使输出即将接走，也不接新输入。同一沿不能进出。这样容易证明，不需要组合 ready 向上传播，也足够用于本次单指令核。

可把 `{pc, inst}` 接到 64 位 in_data。但正式阶段接口仍用两个显式端口，避免一开始就维护大量位切片。

附录 A 有完整 Verilog TB 和运行命令。先让它 PASS，再推进下一步。

### 思考题 3

**问：输出握手后，为什么可以只清 full，不清 data_q？**

**参考答案：** valid=0 后旧 payload 无效，不会被消费。清数据不是正确性的条件；下游必须只在握手时接收，不能一直监听旧值来执行。

**问：为什么不能在 `if (in_valid)` 时无条件更新 data_q？**

**参考答案：** 当前槽可能满，in_ready=0；这时上游尚未获准交付，更新会覆盖旧消息。

**问：以后能改成 `in_ready = !full || out_ready` 吗？**

**参考答案：** 可以，但要处理同拍出旧入新，确保新数据和 full 被正确更新；还要检查组合 ready 长链/环路。这是性能优化，不是本次正确性前提。

## 4. 第四步：列出每条通道的全部字段

命名规则：顶层连线用 `fi_/de_/ew_`；阶段输入用 `in_`，输出用 `out_`；内部保存输入用 `_q`；组合计算结果用 `_calc`。同一个通道的所有字段共享一次握手，不能各字段单独更新。

IFU→IDU：`pc[31:0]`、`inst[31:0]`。

IDU→EXU 的完整字段表如下。这是后续写端口和寄存器声明的清单：

| 字段 | 位宽 | 来源/含义 |
|---|---:|---|
| pc、inst | 各 32 | 接收的 IFU 消息 |
| illegal | 1 | 译码或访问检查失败 |
| rd | 5 | 目标寄存器编号 |
| rs1_value、rs2_value | 各 32 | 当前指令源寄存器值 |
| imm | 32 | 原译码立即数，尚未替换为 CSR 值 |
| csr_old、mtvec、a0 | 各 32 | CSR 读值、trap 目标、EBREAK 参数快照 |
| src_sel | 2 | 原 IDU 输出 |
| exu_op | 4 | 原 IDU 输出 |
| pc_we、pc_wsel | 1、2 | 原 IDU 输出 |
| branch_en、branch_op | 1、3 | 原 IDU 输出 |
| gpr_we、gpr_wsel | 1、3 | 原 IDU 输出 |
| mem_valid、mem_wen | 各 1 | 指令是否访存、是否写 |
| mem_rbhw、mem_wbhw、isign | 2、2、1 | 宽度和符号扩展 |
| csr_we、csr_wsel、csr_addr | 1、2、12 | CSR 写控制；we 要经过语义检查 |
| imm2csr、is_ecall、is_ebreak | 各 1 | 原 IDU 输出 |

rs1/rs2 的编号在 IDU 完成读口选择及合法性检查后不再必需；这里只传操作数值。若你需要提交 trace 显示源编号，可以增加字段，但两端必须一起修改。

EXU→WBU 的完整字段表：

| 字段 | 位宽 | 含义 |
|---|---:|---|
| pc、inst、next_pc | 各 32 | 指令身份和提交后 PC |
| illegal | 1 | 非法指令标志 |
| rd_we、rd、rd_data | 1、5、32 | 最终 GPR 写入 |
| csr_we、csr_addr、csr_data | 1、12、32 | 最终 CSR 写入 |
| is_ecall、is_ebreak、a0 | 1、1、32 | 特殊提交动作与参数 |
| skip_ref | 1 | 该指令访问 MMIO，提交时跳过参考执行 |
| perf_class | 10 | 性能分类，定义见第 12 步 |

不把一堆 ALU 选择信号留给 WBU 重新计算。EXU 产生最终结果，WBU 只负责提交和发下一 PC。访存有效地址若仅用于 skip_ref，可以在 EXU 算出 skip_ref 后不再传；错误地址仍由 LSU 提供。

EXU→LSU：`req_addr[31:0]`、`req_write`、`req_rsize[1:0]`、`req_wsize[1:0]`、`req_wdata[31:0]`、`req_sign`。LSU→EXU：`rsp_rdata[31:0]`；store 的 rsp 表示完成，rdata 无需使用。

### 思考题 4

**问：把 pc 一直从顶层拉过来，少传一个字段，行不行？**

**参考答案：** 这会重新要求各单元共享某个实时 PC 的生命周期。把消息自己的 PC 带上，才能保证 AUIPC、branch、link、ECALL 使用同一条指令的上下文。即使当前单指令时实时 PC 恰好稳定，也不应把依赖隐藏起来。

## 5. 第五步：改造 IFU，只理解取指消息

### 5.1 改端口

从 IFU 的 CPU 侧删除 `pc`、`mem_valid`、`memfinish`、旧 `inst/ifu_valid` 端口，换成：

```verilog
input pc_valid,
output pc_ready,
input [31:0] pc_data,
output out_valid,
input out_ready,
output [31:0] out_pc,
output [31:0] out_inst,
```

保留 clk/rst_n、所有 AXI 端口和 ifu_error 系列输出。现有 `output reg m_axi_araddr` 改成 `output [31:0] m_axi_araddr`，由锁存 PC 连续赋值。

删除 IFU 的 `RANDOM_DELAY` 参数及整个 random_delay generate、`fetch_delay_req/fetch_delay_done` 连线。相应地，npc_core 中 `IFU #(.RANDOM_DELAY(RANDOM_DELAY)) ifu1 (...)` 改成 `IFU ifu1 (...)`。其他模块仍使用的 RANDOM_DELAY 参数和 random_delay.v 文件保留；独立 IFU TB 若有参数覆盖，也一起删除。

理由：IFU 已有合法取指任务且请求槽可用时，就应提供 AR 请求。此前发起前的随机等待是测试激励，不是执行该任务的必要步骤。模拟访存延迟应在互连/从设备一侧延迟 ARREADY 或 RVALID；当前 MEM.v 已支持请求接收和响应的随机延迟。IFU 必须正确等待这些外部条件，而不需要自己先随机睡几拍。

### 5.2 替换状态机

删除旧 `state/next_state`、`fetch_state/fetch_next_state` 及相关时序块。不要把新旧状态机叠加到同一批寄存器上。使用下列模块内片段：

```verilog
localparam [2:0] WAIT_PC = 3'd0,
                 SEND_AR = 3'd1,
                 WAIT_R  = 3'd2,
                 SEND_ID = 3'd3,
                 FAULT   = 3'd4;
reg [2:0] state;
reg [31:0] fetch_pc_q;
reg [31:0] inst_q;
wire pc_fire;
wire out_fire;
wire ar_fire;
wire r_fire;

assign pc_ready = rst_n && (state == WAIT_PC);
assign out_valid = rst_n && (state == SEND_ID);
assign out_pc = fetch_pc_q;
assign out_inst = inst_q;
assign pc_fire = pc_valid && pc_ready;
assign out_fire = out_valid && out_ready;
assign m_axi_araddr = fetch_pc_q;
assign m_axi_arvalid = rst_n && (state == SEND_AR);
assign m_axi_rready = rst_n && (state == WAIT_R);
assign ar_fire = m_axi_arvalid && m_axi_arready;
assign r_fire = m_axi_rvalid && m_axi_rready;
assign ifu_error_addr = fetch_pc_q;

always @(posedge clk or negedge rst_n) begin
  if (!rst_n) begin
    state <= SEND_AR;
    fetch_pc_q <= 32'h80000000;
    inst_q <= 32'h00000013;
    ifu_error <= 1'b0;
    ifu_error_resp <= 2'b00;
  end else begin
    case (state)
      WAIT_PC: if (pc_fire) begin
        fetch_pc_q <= pc_data;
        state <= SEND_AR;
      end
      SEND_AR: if (ar_fire) state <= WAIT_R;
      WAIT_R: if (r_fire) begin
        if (m_axi_rresp == 2'b00) begin
          inst_q <= m_axi_rdata;
          state <= SEND_ID;
        end else begin
          ifu_error <= 1'b1;
          ifu_error_resp <= m_axi_rresp;
          state <= FAULT;
        end
      end
      SEND_ID: if (out_fire) state <= WAIT_PC;
      FAULT: begin end
      default: state <= FAULT;
    endcase
  end
end
```

保留 ARPROT 和不用的 AW/W/B 端口 tie-off。上述替换不改变这些 AXI 属性。删除人工等待不等于删除 SEND_AR 和 WAIT_R：前者保存尚未被接收的地址请求，后者等待该请求的响应，两者都有协议职责。

复位把状态设为 SEND_AR，并初始化 fetch_pc_q 为 reset vector，相当于 IFU 自动收到一份启动取指许可。rst_n=0 时 ARVALID 仍被门控为零；复位释放后才提供请求。WBU **不能再发第二份启动许可**。

正常运行时，在 pc_fire 的上升沿同时锁存新 PC、转入 SEND_AR；沿后新地址与 ARVALID 一起可见，下一个上升沿最早完成 AR 握手。这不需要额外 DELAY 拍，也不需要从实时 pc_data 组合穿透到 AXI。地址寄存器的采样时机必须保留，不能只删除原状态却忘记迁移旧 fetch_launch 的锁存动作。

SEND_ID 只等 IDU 接收。一旦交出去，IFU 留在 WAIT_PC，等待 WBU 新 PC；它不看后端是否访存，也不自己加 4。至此应完全删除 `execute_done` 和 `fetch_launch` 的旧依赖。

### 5.3 验收

独立 TB 中给一次成功取指响应，把 out_ready 拉低 20 拍，检查 out_valid 和 pc/inst 稳定。接走后观察至少 20 拍，不能出现新 AR；再提供 pc_valid 和新 pc_data，直到 pc_fire，验证只取一次新地址。检查 pc_fire 沿后 ARVALID 已拉高、ARADDR 为刚接收的 PC，并在随后 AR 背压期间保持。复位释放后也应直接提供 reset vector 请求。

分别测试 ARREADY 多拍为零、AR 接收后 RVALID 多拍为零、最早可用响应和 RRESP 错误；RVALID 已拉高后，从设备必须保持响应直到 R 握手。删除或更新依赖固定取指周期数、IFU 发起延迟和旧 PREP 统计的测试预期，不改掉地址正确、请求一次性和背压稳定等功能要求。

### 思考题 5

**问：为什么 SEND_ID 交付后不能直接回 SEND_AR？**

**参考答案：** 这会重复取旧地址，或必须猜下一个地址。当前指令可能跳转，正确 next_pc 尚未产生。WAIT_PC 表示 IFU 空闲但没有新工作授权。

**问：为什么进入 SEND_AR 前就锁存 PC？**

**参考答案：** ARVALID 等待 ARREADY 时地址必须稳定。上游在 pc_fire 后可以改 pc_data，因此不能直接把它接到 ARADDR。

**问：CPU 先等五拍再发请求，与内存接收请求后等五拍才响应，是否一样？**

**参考答案：** 即使总耗时碰巧相同，协议状态也不同。前者没有在途请求，不能验证等待响应时的事务保持；后者已经存在未完成事务，要求 IFU 保存其归属并正确接收响应。验证 AR 背压还应让 IFU 已经提供 ARVALID、从设备暂不接收。因此模拟访存等待应放在对应外部接口，而不是用 CPU 发起前等待代替。

**问：移除 IFU DELAY 是否意味着处理器只支持立即返回的内存？**

**参考答案：** 不意味着。SEND_AR 等 ar_fire，WAIT_R 等 r_fire，都可以保持任意多拍。删除的是人为拖延开始的状态，保留的是应对实际请求背压和响应延迟的能力。

## 6. 第六步：把架构状态读写口分开，建立 IDU 阶段

### 6.1 搬出 GPR 和 CSR，不改变寄存器本身

将原 WBU 中的 `GPR gpr1` 和 `CSR csr1` 实例移至 npc_core。保留它们的实现和 debug 输出，调整端口来源：

| 实例端口 | 新来源 |
|---|---|
| GPR.raddr1/raddr2 | idu_stage 输出的读地址 |
| GPR.rdata1/rdata2/rdata_a0 | 接回 idu_stage |
| GPR.wen/waddr/wdata | WBU 的提交写口 |
| CSR.raddr1 | idu_stage 的 CSR 读地址 |
| CSR.rdata1/mtvec_data/invalid_csr_access | 接回 idu_stage |
| CSR.wen/waddr/wdata | WBU 的提交写口 |
| CSR.is_ecall/mepc_data/mcause_data | WBU 的 ECALL 提交口 |

CSR 的 raddr1 不再绑 waddr：译码读地址属于当前读请求，写地址属于待提交消息。一个物理寄存器只有一个时序驱动；不要既保留 WBU 内的 GPR 又在顶层放第二份。

组合读口不要求再做一套 ready/valid。本次约定 GPR/CSR 是同步核内可组合读取的状态存储，阶段消息在读取值被锁存后才向 EXU 提供。若以后用同步读 SRAM 实现 GPR，就要给 IDU 增加等待读结果的局部状态。

### 6.2 在 idu_stage.v 内实例化原 IDU

新增端口：clk/rst_n；输入 in_valid/in_pc/in_inst，输出 in_ready；输出 out_valid 和第 4 步全部 `out_*` 字段，输入 out_ready；另有上述 GPR/CSR 读口。

实例化原 `IDU`，`.inst(in_inst)`。每个原输出接本模块的组合线 `d_字段名`，位宽沿用原定义。明确这些改名：

| 原 IDU 输出 | 新组合线 |
|---|---|
| invalid_inst | d_illegal |
| mem_we | d_mem_wen |
| csr_wraddr | d_csr_addr |
| rs1、rs2 | d_rs1、d_rs2（接 GPR 读地址） |
| 其余 | 原名字前加 d_ |

例如 `.imm(d_imm), .exu_op(d_exu_op), .rd(d_rd)`。把原 IDU 的所有输出端口逐项接完，不要漏掉 branch、CSR、ECALL。顶层原先的 IDU 实例删除，只有 idu_stage 内保留一份。

### 6.3 在接收前完成检查

模块内片段：

```verilog
wire is_csr_op;
wire uses_csr_read;
wire csr_write_intent;
wire csr_access_bad;
wire bad_csr_gpr;
wire decoded_illegal;

assign is_csr_op = (in_inst[6:0] == 7'b1110011) &&
                  ((in_inst[14:12] == 3'b001) ||
                   (in_inst[14:12] == 3'b010));
assign uses_csr_read = is_csr_op || (in_inst == 32'h30200073);
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
```

这里 `csr_invalid_addr` 连接当前 CSR 的 invalid_csr_access。普通指令不使用 CSR，就不应该被无关 CSR 地址的状态误杀。

上面额外补了当前代码的 CSRRS x0 写抑制、只读 CSR 写入检查和 CSR 指令 RV32E 编号检查，应作为可单独验证的 ISA 修正记录。CSRRS 判断的是 **rs1 编号**，不是 rs1_value 是否为零；依据见 [RISC-V Zicsr](https://docs.riscv.org/reference/isa/unpriv/zicsr.html)。CSRRW rd=x0 的读副作用抑制在当前无读副作用的 CSR 实现下不影响结果；扩展有副作用 CSR 时必须另行实现读使能。本讲义不宣称实现完整特权 ISA。

### 6.4 把整个译码结果存进一格输出寄存器

第 4 步的全部 `out_*` 声明为 `output reg`，位宽按表填写；out_valid/in_ready 仍为 wire 输出。下面是模块内完整的占用与字段更新逻辑：

```verilog
reg full;
wire in_fire;
wire out_fire;
assign in_ready = rst_n && !full;
assign out_valid = rst_n && full;
assign in_fire = in_valid && in_ready;
assign out_fire = out_valid && out_ready;

always @(posedge clk or negedge rst_n) begin
  if (!rst_n) begin
    full <= 1'b0;
    out_pc <= 32'b0;
    out_inst <= 32'b0;
    out_illegal <= 1'b0;
    out_rd <= 5'b0;
    out_rs1_value <= 32'b0;
    out_rs2_value <= 32'b0;
    out_imm <= 32'b0;
    out_csr_old <= 32'b0;
    out_mtvec <= 32'b0;
    out_a0 <= 32'b0;
    out_src_sel <= 2'b0;
    out_exu_op <= 4'b0;
    out_pc_we <= 1'b0;
    out_pc_wsel <= 2'b0;
    out_branch_en <= 1'b0;
    out_branch_op <= 3'b0;
    out_gpr_we <= 1'b0;
    out_gpr_wsel <= 3'b0;
    out_mem_valid <= 1'b0;
    out_mem_wen <= 1'b0;
    out_mem_rbhw <= 2'b0;
    out_mem_wbhw <= 2'b0;
    out_isign <= 1'b0;
    out_csr_we <= 1'b0;
    out_csr_wsel <= 2'b0;
    out_csr_addr <= 12'b0;
    out_imm2csr <= 1'b0;
    out_is_ecall <= 1'b0;
    out_is_ebreak <= 1'b0;
  end else if (in_fire) begin
    full <= 1'b1;
    out_pc <= in_pc;
    out_inst <= in_inst;
    out_illegal <= decoded_illegal;
    out_rd <= d_rd;
    out_rs1_value <= gpr_rdata1;
    out_rs2_value <= gpr_rdata2;
    out_imm <= d_imm;
    out_csr_old <= csr_rdata;
    out_mtvec <= csr_mtvec;
    out_a0 <= gpr_a0;
    out_src_sel <= d_src_sel;
    out_exu_op <= d_exu_op;
    out_pc_we <= d_pc_we;
    out_pc_wsel <= d_pc_wsel;
    out_branch_en <= d_branch_en;
    out_branch_op <= d_branch_op;
    out_gpr_we <= d_gpr_we;
    out_gpr_wsel <= d_gpr_wsel;
    out_mem_valid <= d_mem_valid;
    out_mem_wen <= d_mem_wen;
    out_mem_rbhw <= d_mem_rbhw;
    out_mem_wbhw <= d_mem_wbhw;
    out_isign <= d_isign;
    out_csr_we <= csr_write_intent;
    out_csr_wsel <= d_csr_wsel;
    out_csr_addr <= d_csr_addr;
    out_imm2csr <= d_imm2csr;
    out_is_ecall <= d_is_ecall;
    out_is_ebreak <= d_is_ebreak;
  end else if (out_fire) begin
    full <= 1'b0;
  end
end
```

非法指令也成为一条有效消息，但 illegal=1。EXU 和 WBU 必须禁止它的副作用。不能以“非法”为由直接丢掉 valid，否则 CPU 永远等不到一个明确终止事件。

`mcycle` 每拍变化，所以 csr_old 的采样沿必须明确：本教程固定在 IDU 的 in_fire 沿。CSRRS 的返回旧值和计算新值都用这一份快照。后续不能在 WBU 再重新读取 CSR。

### 6.5 验收与思考题

验收：IFU 输入握手后立即改变 in_inst/in_pc；同时让 GPR 模拟读值和 csr_rdata 改变。out_ready=0 时，全部 out_* 必须维持接收时的值。然后接走一次，out_valid 应清零。分别送 ADD、LW、branch、CSR、非法编码，检查字段来源。

**问：IDU 内没有单独 DECODE 状态，算多周期吗？**

**参考答案：** 算。这里在接收沿锁存组合译码结果，之后通过寄存器向 EXU 交付，已经建立独立的时序边界。多周期不要求人为把每一次组合计算再拆一个状态。

**问：只有一条指令，csr_old 为什么还会不稳定？**

**参考答案：** mcycle 不依赖其他指令也会自增。单指令约束只消除了指令间冒险，没消除时间变化输入。

**问：能把寄存器编号改成 4 位来支持 RV32E 吗？**

**参考答案：** 不能先截断再检查。x16 的编码会被截成 x0。保持 5 位，检查该指令真正使用的寄存器是否合法后再访问。

## 7. 第七步：让 LSU 成为独立请求/响应服务

先改 LSU，再写 EXU 的协调逻辑。保留 AXI 端口、内部 split 算法、符号扩展、aw_sent/w_sent、delay 和错误保持逻辑。本轮按已确定的修改移除 IFU 人工发起延迟；LSU 的同类 delay 可另作一次明确清理，不是消息协议的必需部分，也不应用它代替从设备延迟测试。

CPU 侧按下表改名，并新增 ready：

| 原名 | 新名/处理 |
|---|---|
| mem_valid | req_valid |
| 无 | 新增 output req_ready |
| mem_addr | req_addr |
| wen | req_write |
| mem_rbhw、mem_wbhw | req_rsize、req_wsize |
| mem_wdata_raw、isign | req_wdata、req_sign |
| lsu_done | rsp_valid |
| lsu_finish | rsp_ready |
| mem_rdata_r | rsp_rdata（仍为 output reg） |

新增或替换：

```verilog
wire req_fire;
wire rsp_fire;
assign req_ready = rst_n && (state == IDLE);
assign rsp_valid = rst_n && (state == DONE);
assign req_fire = req_valid && req_ready;
assign rsp_fire = rsp_valid && rsp_ready;
```

状态转移中的 `IDLE: if (mem_valid)` 改成 `IDLE: if (req_fire)`；`DONE: if (lsu_finish)` 改成 `DONE: if (rsp_fire)`。payload 时序块里的 `(state == IDLE) && mem_valid` 改成 req_fire。所有输入字段引用按表改名；例如 incoming_size 变成 `req_write ? req_wsize : req_rsize`，incoming_shift 使用 req_addr。

保留检查阶段的约束：错误宽度、非法跨字范围、MMIO 跨字仍走原错误路径。FAULT 保持到 reset，rsp_valid=0。成功请求产生一条响应；失败请求进入 fatal，由 host 中止，不承诺同时给普通 rsp。

要删除的是“LSU DONE 等 CPU 提交”的意义；不是删除 DONE。DONE 是 LSU 保存结果、等待 EXU 真正接收的缓冲状态。

### 7.1 必须保留的 AXI 细节

AW 和 W 可以先后到达，分别用 aw_sent/w_sent 记录。只有两者均接收才进入等 B；store 要等最后一笔 B 成功才产生 rsp。load 要等最后一笔 R 成功且拼接/扩展完成才产生 rsp。

随机延迟只能影响尚未发起的请求；不能让已经拉高、尚未握手的 AXI VALID 随机消失。不能把一次 CPU split 请求的两个 beat 当两条 CPU 指令。

### 7.2 验收与思考题

更新 `tests/axi_lsu_tb.sv` 原有接口连接和请求任务：保持 req_valid/字段直到 req_fire；等 rsp_valid 后可故意延迟 rsp_ready。现有测试文件使用 SV 不影响新 RTL 使用 Verilog；新的教学 TB 使用附录的 Verilog 写法即可。

覆盖：AW先、W先、同拍接受；R/B 多拍延迟；rsp_ready 背压；非对齐 RAM 两拍拼接；第二拍错误；MMIO 请求只出现一次。

**问：EXU 收到 load 响应后，WBU 还忙，LSU 可以回 IDLE 吗？**

**参考答案：** 可以，因为 rsp_fire 的沿已把数据保存进 EXU 的结果寄存器。结果所有权已经转移，LSU 不应知道 WBU 的忙闲。

**问：WBU 没提交，store 是否一定没有修改内存？**

**参考答案：** 不是。外部从设备可能在 B 返回前已经写入。两拍 store 第一拍成功、第二拍失败，内存可能部分更新。当前 fatal 机制阻止继续执行，但没有回滚能力。不要承诺所有副作用都发生在 WBU；集中提交的是指令导致的 GPR、软件 CSR 和架构 PC 更新。

## 8. 第八步：实现 EXU 的局部生命周期

### 8.1 声明输入快照与输出结果

新增 `exu_stage.v`。输入为第 4 步 de 字段，加 in_valid/in_ready；输出为 ew 字段，加 out_valid/out_ready；另有 LSU 请求输出和响应输入。模块参数保留 PMEM_BASE/PMEM_SIZE，用来计算 skip_ref。

对第 4 步每个 de 字段声明同位宽的 `reg 字段_q`。只在 in_fire 时从 `in_字段` 锁存，复位赋同位宽零。输出 ew 字段全部声明为 `output reg`，在 EXEC 或响应接收沿更新，复位为零。禁止漏掉 pc、illegal、CSR 控制和特殊指令信息。

可以用下面的完整字段顺序做整组赋值，避免写出宽度易错的数字切片。这只是普通 Verilog 拼接，不是结构体：

```verilog
// 模块内片段：这些 _q 都按第 4 步声明为 reg。
// 放在唯一管理输入快照的 always 块的 if (in_fire) 分支中。
{pc_q, inst_q, illegal_q, rd_q, rs1_value_q, rs2_value_q,
 imm_q, csr_old_q, mtvec_q, a0_q, src_sel_q, exu_op_q,
 pc_we_q, pc_wsel_q, branch_en_q, branch_op_q,
 gpr_we_q, gpr_wsel_q, mem_valid_q, mem_wen_q,
 mem_rbhw_q, mem_wbhw_q, isign_q, csr_we_q, csr_wsel_q,
 csr_addr_q, imm2csr_q, is_ecall_q, is_ebreak_q} <=
{in_pc, in_inst, in_illegal, in_rd, in_rs1_value, in_rs2_value,
 in_imm, in_csr_old, in_mtvec, in_a0, in_src_sel, in_exu_op,
 in_pc_we, in_pc_wsel, in_branch_en, in_branch_op,
 in_gpr_we, in_gpr_wsel, in_mem_valid, in_mem_wen,
 in_mem_rbhw, in_mem_wbhw, in_isign, in_csr_we, in_csr_wsel,
 in_csr_addr, in_imm2csr, in_is_ecall, in_is_ebreak};
```

这组字段共 304 位。复位可对左侧同一拼接赋 `304'b0`；手动增减字段后必须同步改宽度。更容易审查的方式是像 IDU 一样逐字段赋零，两种写法选定一种。

### 8.2 局部状态和握手

```verilog
localparam [2:0] IDLE = 3'd0, EXEC = 3'd1,
                 MEM_REQ = 3'd2, MEM_WAIT = 3'd3, SEND_WB = 3'd4;
reg [2:0] state;
reg [2:0] next_state;
wire in_fire;
wire out_fire;
wire req_fire;
wire rsp_fire;

assign in_ready = rst_n && (state == IDLE);
assign out_valid = rst_n && (state == SEND_WB);
assign req_valid = rst_n && (state == MEM_REQ);
assign rsp_ready = rst_n && (state == MEM_WAIT);
assign in_fire = in_valid && in_ready;
assign out_fire = out_valid && out_ready;
assign req_fire = req_valid && req_ready;
assign rsp_fire = rsp_valid && rsp_ready;

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
```

状态顺序保证：输入握手后进入 EXEC，EXEC 的下一个沿才捕获计算结果。非阻塞赋值不会让你在接收沿凭空读到新 `_q`；这个额外 EXEC 周期明确了计算与采样边界。

### 8.3 连接原 ALU 与分支单元

```verilog
wire [31:0] execute_imm;
wire [31:0] alu_result;
wire alu_zero;
wire alu_signed_lt;
wire alu_unsigned_lt;
wire branch_taken;
assign execute_imm = imm2csr_q ? csr_old_q : imm_q;

EXU alu (
    .rs1(rs1_value_q), .rs2(rs2_value_q), .imm(execute_imm),
    .pc(pc_q), .src_sel(src_sel_q), .exu_op(exu_op_q),
    .result(alu_result), .zero(alu_zero),
    .signed_lt(alu_signed_lt), .unsigned_lt(alu_unsigned_lt)
);
BranchUnit branch_unit (
    .branch_en(branch_en_q), .branch_op(branch_op_q),
    .zero(alu_zero), .signed_lt(alu_signed_lt),
    .unsigned_lt(alu_unsigned_lt), .branch_taken(branch_taken)
);
```

这就是“保留组合模块”的具体含义：组合 ALU 不知道 valid/ready，exu_stage 负责保证输入快照稳定并在正确时刻保存结果。

### 8.4 从旧 WBU 搬来最终结果选择

把原 WBU 的 `PC_*`、`GPR_*`、`CSR_*` localparam 原值复制到 exu_stage。声明 `reg [31:0] next_pc_calc, rd_data_calc, csr_data_calc`：

```verilog
always @(*) begin
  next_pc_calc = pc_q + 32'd4;
  if (branch_en_q && branch_taken)
    next_pc_calc = pc_q + imm_q;
  if (pc_we_q) begin
    case (pc_wsel_q)
      PC_EXU_RESULT: next_pc_calc = alu_result & 32'hfffffffe;
      PC_BRANCH: next_pc_calc = pc_q + imm_q;
      PC_TO_MTVEC: next_pc_calc = mtvec_q;
      PC_TO_MEPC: next_pc_calc = csr_old_q;
      default: next_pc_calc = pc_q + 32'd4;
    endcase
  end

  case (gpr_wsel_q)
    GPR_EXU_RESULT: rd_data_calc = alu_result;
    GPR_PC_PLUS4: rd_data_calc = pc_q + 32'd4;
    GPR_IMMEDIATE: rd_data_calc = execute_imm;
    GPR_PC_IMM: rd_data_calc = pc_q + imm_q;
    GPR_MEM_DATA: rd_data_calc = 32'b0;
    default: rd_data_calc = 32'b0;
  endcase

  case (csr_wsel_q)
    CSR_EXU_RESULT: csr_data_calc = alu_result;
    CSR_REG: csr_data_calc = rs1_value_q;
    default: csr_data_calc = csr_old_q;
  endcase
end
```

load 的真实 rd_data 尚未返回，所以这里置零，MEM_WAIT 收到 rsp 后覆盖。在结果完整前 out_valid 始终为零，不会提交临时值。

保留现有目标地址选择语义：JALR 清 bit0。没有实现的取指对齐异常、完整 mstatus trap/mret 行为，不能因为控制重构而宣称已经支持，应单独增加 ISA 任务和测试。

### 8.5 形成 LSU 请求，锁存最终结果

请求字段可直接由稳定的输入快照和纯组合 ALU 驱动，无需再多复制一份。因为 MEM_REQ/MEM_WAIT 期间 `_q` 从不更新，所有请求字段稳定：

```verilog
assign req_addr = alu_result;
assign req_write = mem_wen_q;
assign req_rsize = mem_rbhw_q;
assign req_wsize = mem_wbhw_q;
assign req_wdata = rs2_value_q;
assign req_sign = isign_q;
```

这里 req_valid 只在 MEM_REQ 高。req_fire 后进入 MEM_WAIT，即使 LSU 之后回 IDLE，也不会重复接到同一请求。

结果寄存器的唯一时序块中，复位按第 4 步全部 ew 字段赋零；非复位分支为：

```verilog
if (state == EXEC) begin
  out_pc <= pc_q;
  out_inst <= inst_q;
  out_next_pc <= next_pc_calc;
  out_illegal <= illegal_q;
  out_rd_we <= gpr_we_q && !illegal_q;
  out_rd <= rd_q;
  out_rd_data <= rd_data_calc;
  out_csr_we <= csr_we_q && !illegal_q;
  out_csr_addr <= csr_addr_q;
  out_csr_data <= csr_data_calc;
  out_is_ecall <= is_ecall_q && !illegal_q;
  out_is_ebreak <= is_ebreak_q && !illegal_q;
  out_a0 <= a0_q;
  out_skip_ref <= !illegal_q && mem_valid_q &&
                 ((alu_result - PMEM_BASE) >= PMEM_SIZE);
  out_perf_class <= perf_class_calc;
end else if (rsp_fire) begin
  if (!mem_wen_q) out_rd_data <= rsp_rdata;
end
```

`perf_class_calc[9:0]` 按第 12 步定义，所有来源都是 `_q`。SEND_WB 期间以上条件均不成立，所以全部结果保持。EXU 发给 WBU 后即可回 IDLE，不等待 commit。

LSU fatal 时没有 rsp，EXU 停在 MEM_WAIT，由平台错误监视终止。本设计不靠伪造成功响应解除错误。全核只有一个在途执行权，不会同时启动无关新请求。

### 8.6 验收与思考题

用假 LSU：接受请求后随机等 1～20 拍再给 rsp；用假 WBU：随机阻塞 out_ready。记录请求握手次数。每条 load/store 必须一次 req_fire、一次成功 rsp_fire、一次 out_fire。普通 ALU/branch/illegal 必须零次 req_fire。

**问：为什么请求字段不用每个再锁存一份，而结果却保存？**

**参考答案：** 请求字段已经完全由不变的输入快照决定，因此天然稳定；结果包含可能只在响应期间出现的 LSU 数据，必须在 rsp_fire 捕获。原则是确保依赖的生命周期覆盖使用期，不是机械地每条线都加寄存器。

**问：为什么 rsp_valid 高就立即转 SEND_WB 不够？**

**参考答案：** 接收必须由 rsp_valid && rsp_ready 决定。否则 LSU 可能认为未交付，EXU 却认为交付，双方所有权账目不一致。

**问：这时谁还依赖 IFU 原来的 inst？**

**参考答案：** EXU/WBU 不依赖。每级使用自己的寄存器快照。IFU 交付后即使清掉旧 inst，执行仍正确。

## 9. 第九步：重写 WBU，集中提交而非集中调度

### 9.1 接收结果和保存

旧 WBU 的组合结果选择已经移至 EXU，GPR/CSR 已搬到顶层。删除旧相关代码及原 PC 更新逻辑。

新 WBU 输入第 4 步所有 ew 字段，输出 in_ready；内部每个字段各有 `reg wb_字段`，还有 `reg full, halted`。输出 pc_valid/pc_data 给 IFU，输入 pc_ready。另有架构写口和 debug 元数据输出。

```verilog
wire in_fire;
wire ordinary_commit;
wire halt_commit;
wire commit_fire;
assign in_ready = rst_n && !full && !halted;
assign in_fire = in_valid && in_ready;
assign pc_valid = rst_n && full && !wb_illegal && !wb_is_ebreak;
assign pc_data = wb_next_pc;
assign ordinary_commit = pc_valid && pc_ready;
assign halt_commit = rst_n && full && !wb_illegal && wb_is_ebreak;
assign commit_fire = ordinary_commit || halt_commit;
```

当前单指令模型中，总线错误不会与另一条待提交结果并存：总线错误发生时结果尚未进入 WBU。若以后允许多个在途指令，必须重新设计 fatal/flush 契约，不能用随意撤销 valid 来“取消”已经提供的消息。

唯一管理 full/halted 的时序块：

```verilog
always @(posedge clk or negedge rst_n) begin
  if (!rst_n) begin
    full <= 1'b0;
    halted <= 1'b0;
  end else if (in_fire) begin
    full <= 1'b1;
  end else if (commit_fire) begin
    full <= 1'b0;
    if (halt_commit) halted <= 1'b1;
  end
end
```

独立 payload 时序块，在 reset 时各字段赋同位宽零，在 in_fire 时锁存完整结果。字段拼接如下，共 225 位，复位可给同一左侧拼接赋 `225'b0`：

```verilog
{wb_pc, wb_inst, wb_next_pc, wb_illegal,
 wb_rd_we, wb_rd, wb_rd_data,
 wb_csr_we, wb_csr_addr, wb_csr_data,
 wb_is_ecall, wb_is_ebreak, wb_a0, wb_skip_ref, wb_perf_class} <=
{in_pc, in_inst, in_next_pc, in_illegal,
 in_rd_we, in_rd, in_rd_data,
 in_csr_we, in_csr_addr, in_csr_data,
 in_is_ecall, in_is_ebreak, in_a0, in_skip_ref, in_perf_class};
```

非法指令 full 保持为 1、illegal 保持为 1，不发新 PC；host 会看到并终止。EBREAK 是合法的仿真终止指令，提交一次后 halted=1，不再接收/取指。

### 9.2 生成架构写口

```verilog
assign gpr_wen = commit_fire && wb_rd_we && (wb_rd != 5'd0);
assign gpr_waddr = wb_rd;
assign gpr_wdata = wb_rd_data;
assign csr_wen = commit_fire && wb_csr_we;
assign csr_waddr = wb_csr_addr;
assign csr_wdata = wb_csr_data;
assign csr_ecall = commit_fire && wb_is_ecall;
assign csr_mepc_data = wb_pc;
assign csr_mcause_data = 32'd11;

always @(posedge clk or negedge rst_n) begin
  if (!rst_n) arch_pc <= 32'h80000000;
  else if (commit_fire) arch_pc <= wb_next_pc;
end
```

`arch_pc` 声明为 `output reg [31:0]`，这是唯一架构 PC。IFU 的 fetch_pc_q 是当前请求地址副本，不是另一个独立推进的架构 PC。

上述普通提交在同一上升沿完成三件事：GPR/CSR 写入、arch_pc 更新、IFU 接收新 PC。WBU 不需要查看 IFU 内部状态，只看 pc_ready；IFU 不需要查看 commit，只按 pc_fire 接收。

为什么不会死锁？IFU 在把指令交给 IDU 后就进入 WAIT_PC，所以健康指令执行到 WBU 时，IFU 已能接收。若你把 IFU 改成“等 commit 才进入 WAIT_PC”，就会形成 WBU 等 ready、IFU 等 commit 的环。

软件 CSR 写入由 commit 控制；mcycle 自增保持 CSR 内部每周期运行，不用 commit 门控。总线 store 的外部可见性也不等同于此提交沿。

### 9.3 对外提供提交观察端口

WBU 新增以下普通输出，顶层用它们做 debug 和 DPI，不跨模块引用 `wbu1.wb_pc` 等私有寄存器：

```verilog
assign commit_valid = commit_fire;
assign retire_illegal = rst_n && full && wb_illegal;
assign retire_pc = wb_pc;
assign retire_inst = wb_inst;
assign retire_ebreak = wb_is_ebreak;
assign retire_a0 = wb_a0;
assign retire_skip_ref = wb_skip_ref;
assign retire_perf_class = wb_perf_class;
assign retire_pending = rst_n && full;
```

retire_pc/inst 等仅在 retire_pending 时表示待处理指令；合法架构提交事件是 commit_valid，非法报告是 retire_illegal，不能混用。

### 9.4 验收与思考题

独立 TB 接收一个 ADD 结果后将 pc_ready 拉低 10 拍：pc_valid 和 pc_data 必须稳定；gpr_wen/csr_wen/commit_valid 始终为零；接收 PC 的沿才写一次。再分别测试 ECALL、EBREAK、illegal。

**问：能写 `gpr_wen = full && wb_rd_we` 吗？**

**参考答案：** 不能。full 可能保持多拍，且不代表 PC 命令已经交付。这样会在等待时重复写入，也会让 DPI 重复报告提交。写使能必须对应唯一 commit_fire。

**问：WBU 为什么算分布式的一部分，而不是中央控制器？**

**参考答案：** 它只处理自己接收的结果，不命令 IDU/EXU 跳到哪个状态。下一 PC 是它生产的一条工作消息；其他单元按局部握手推进。

## 10. 第十步：接通顶层，同时修正 host 观察边界

### 10.1 顶层只按通道接线

按第 4 步逐字段连接；以下是握手和关键数据示例，其余字段照同名一一接通：

| 通道 | 生产者端口 | 顶层 wire | 消费者端口 |
|---|---|---|---|
| IFU→IDU | IFU.out_valid | fi_valid | idu_stage.in_valid |
| 返回容量 | IFU.out_ready | fi_ready | idu_stage.in_ready |
| 指令字段 | IFU.out_pc/out_inst | fi_pc/fi_inst | idu_stage.in_pc/in_inst |
| IDU→EXU | IDU阶段.out_valid/out_* | de_valid/de_* | EXU阶段.in_valid/in_* |
| 返回容量 | IDU阶段.out_ready | de_ready | EXU阶段.in_ready |
| EXU→WBU | EXU阶段.out_valid/out_* | ew_valid/ew_* | WBU.in_valid/in_* |
| 返回容量 | EXU阶段.out_ready | ew_ready | WBU.in_ready |
| WBU→IFU | WBU.pc_valid/pc_data | pc_valid/pc_data | IFU.pc_valid/pc_data |
| 返回容量 | WBU.pc_ready | pc_ready | IFU.pc_ready |
| EXU→LSU | EXU.req_valid/req_* | req_valid/req_* | LSU.req_valid/req_* |
| 返回容量 | EXU.req_ready | req_ready | LSU.req_ready |
| LSU→EXU | LSU.rsp_valid/rsp_rdata | rsp_valid/rsp_rdata | EXU.rsp_valid/rsp_rdata |
| 返回容量 | LSU.rsp_ready | rsp_ready | EXU.rsp_ready |

每根 ready 只有消费方驱动，每根 valid/payload 只有生产方驱动。AXIArbiter、XBAR、MEM、UART、CLINT 连接保持原有平台结构。

从 npc_core 删除旧顶层 IDU/EXU/BranchUnit 实例（它们已在阶段内），删除实时 imm2csr 替换、旧全局 lsu_request、旧 commit 计算和 `lsu_finish(commit)`。不要让同一个 commit 既清 IFU 又清 LSU。

`vsrc/filelist.mk` 加：

```makefile
VSRCS-y += vsrc/idu_stage.v vsrc/exu_stage.v
```

原 IDU.v/EXU.v/BranchUnit.v 仍被使用，不能从 filelist 删除。此时无须 package，也无新增语言编译选项。

### 10.2 host 当前如何采样

当前 `csrc/cpu/cpu-exec.cpp` 的顺序是：先查总线错误；若 sim_debug_commit 为 0 就推进一周期；若为 1，先取 PC/inst，检查非法，读取 skip_ref，然后推进提交沿，最后再取 PC 做 difftest。

因此顶层兼容连线如下：

```verilog
assign debug_pc = arch_pc;
assign debug_inst = retire_inst;
assign invalid_inst = retire_illegal;
assign diff_ifu_valid = !debug_bus_error &&
                        (commit_valid || retire_illegal);
assign debug_skip_ref = commit_valid && retire_skip_ref;
```

保留 `debug_bus_error = ifu_error || lsu_error` 以及原 error_addr/resp/op 选择。发生总线错误时 arch_pc 还没有更新，仍标识当前故障指令；LSU error_addr 可能指向 split 的第二个 beat，不能用原请求地址覆盖掉它。

为什么 diff_ifu_valid 包含 illegal？这是历史命名，它实际是“host 现在应处理这条指令”。若只连合法 commit，host 永远进不了检查 invalid_inst 的分支，最后只会超时报死锁。非法指令不进行 GPR/CSR/PC 提交，不能因为把报告信号拉高就驱动写使能。

### 10.3 DPI 同步使用提交结果

保留 npc_core 的原 DPI import 和综合保护，只替换调用来源。下面两条放入原 `ifndef SYNTHESIS` 的上升沿块：

```verilog
if (gpr_wen) npc_reg_write({27'b0, gpr_waddr}, gpr_wdata);
if (commit_valid && retire_ebreak)
  npc_ebreak(retire_a0, retire_pc);
```

这两行使用项目现有 DPI 接口，不是新引入 SV 数据结构。GPR 硬件写和 host 镜像写用同一个 gpr_wen；EBREAK 不能使用 IFU 此刻的 pc/inst。

对普通指令，提交沿前 debug_pc=当前指令 PC，提交沿后 arch_pc=next_pc，满足现有 host。新增检查：retire_pending 时 retire_pc 必须等于 arch_pc；这是单指令模型下的重要不变量。流水化之后不能继续假定成立，需要独立的提交 PC/next_pc 接口和 host 修改。

EBREAK 不发新 PC；host 的 sim_finish 即使再走两拍，也不会误取下一条。非法指令保持报告。总线错误由 host 优先报告，不计正常提交。

### 思考题 10

**问：为什么 debug_inst 来自 WBU，debug_pc 却来自 arch_pc？**

**参考答案：** host 在提交前取该指令字，在提交后重新读 PC。单指令模型下 arch_pc 沿前等于 WBU 消息 PC，沿后变成 next_pc，兼容原采样方式。如果 debug_pc 永远连 wb_pc，沿后就可能读到旧 PC。

**问：把 invalid 视为“没有有效指令”为什么不够？**

**参考答案：** 错误也是一个必须被观察到的处理结果。丢掉消息只会让系统永远等完成，失去故障原因与指令身份。

## 11. 第十一步：逐拍走通 ADD、LOAD 和分支

以下表中“沿前状态”决定该沿发生的动作，非阻塞赋值在沿后更新。不要把沿后新状态的行为算到同一个沿。

### 11.1 普通 ADD 的阶段交接

假设 IFU 已取得指令，所有相邻接收方有容量：

| 上升沿 | 沿前条件 | 本沿动作 | 沿后所有者 |
|---|---|---|---|
| T0 | IFU SEND_ID，IDU 空 | fi_fire；IDU 锁存译码和读值 | IDU |
| T1 | IDU full，EXU IDLE | de_fire；EXU 锁存上下文 | EXU，状态 EXEC |
| T2 | EXU EXEC | 锁存 ALU/next_pc 等结果 | EXU，状态 SEND_WB |
| T3 | EXU SEND_WB，WBU 空 | ew_fire；WBU 锁存结果 | WBU |
| T4 | WBU full，IFU WAIT_PC | commit；GPR 写入、PC 交接 | IFU，开始下一次取指 |

T0 后 IFU 已空闲等待 PC。T1 后 IDU 已空闲。没有必要让它们等到 T4 才清空。

### 11.2 LOAD 的额外等待

T2 产生地址和结果元数据，EXU 转 MEM_REQ。之后某个沿 req_fire，LSU 取得请求，EXU 转 MEM_WAIT。LSU 自己完成 CHECK/DELAY/AR/R，必要时两个 beat，最终进入 DONE。rsp_fire 的沿 EXU 锁存 load 数据并转 SEND_WB；随后走 ew_fire 和 commit。

EXU 在 MEM_WAIT 时仍拥有这条指令。LSU 的请求是其子事务，不是第二条指令；统计“全核在途指令数”时不能把它再加一。

### 11.3 taken branch

branch 不发 LSU 请求。EXU 用快照源操作数比较，根据该指令的 pc 和立即数形成 next_pc。直到 WBU pc_fire，IFU 才接收目标地址，所以不会出现错误路径取指，不需要 flush。

### 思考题 11

**问：把 IFU 改成 T0 后直接预取 pc+4，会怎样？**

**参考答案：** 全核可能同时有两条指令，原单指令证明失效；taken branch 要丢弃错误路径结果，后继指令可能读到旧 GPR，MMIO 更不能随意推测。需要新的冒险、冲刷、事务归属设计，不是一个局部小优化。

**问：几条指令 PC 相同，是否说明重复提交？**

**参考答案：** 不一定，循环会重复 PC。测试应给每次接受的消息编号并检查消费次数，不能仅靠 PC 唯一性。

## 12. 第十二步：更新性能统计，并验证契约

### 12.1 性能分类随指令走

当前 npc_core 的性能统计大量读取实时译码信号，搬走这些信号后不能留下旧逻辑。先在 EXU 定义完整 `perf_class_calc`，带入 ew 消息，WBU 在 commit_valid 时计数。

以下常量名字沿用从原 IDU/WBU 复制的定义。`CSR_EXU_RESULT` 是原 CSR 写选择值；这里性能分类描述实际执行类别，CSRRS 只读也归 CSR。

```verilog
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
```

把原 perf_events 的指令分类位 9～18 对应接到 `retire_perf_class[0]`～`[9]`，每一项都与 commit_valid 相与；bit8 提交事件接 commit_valid。非法指令不提交，自然不增加这些计数。

原 bit3/4 LSU 完成事件不能用 rsp_valid 电平直接计数，改 rsp_fire 与当前请求写方向分类。为此 EXU 输出监视信号 `lsu_rsp_is_write = mem_wen_q`，或在顶层 req_fire 锁存 req_write，rsp_fire 时使用。不要跨层偷看 LSU 的内部状态。

取指 AR/R 事件继续按总线 fire 统计。旧 `!ifu_valid` 不再代表 CPU 等取指；旧“执行周期”“IFU 等 LSU”语义也失效。移除 IFU DELAY 后，不再统计原“准备/人工发起延迟”PREP；不能将 IFU 等待下一 PC 的时间误算成准备取指。给 IFU/EXU 增加只读状态观察端口，例如 IFU 等 PC、IFU 总线等待、EXU 等响应、WBU 等 PC ready，明确其定义后同步修改 `csrc/sim/perf.cpp`、CSV/绘图和 `docs/performance-counters.md`。不要只换 RTL 位的含义却保留旧标签。

### 12.2 用普通 Verilog 写稳定性检查

下面是完整的仿真检查模块，使用 `!==` 同时发现未知值。检查器只观察，不参与功能控制。综合时不要加入该模块。

```verilog
`timescale 1ns/1ps
module rv_stability_check #(parameter W = 64) (
    input clk, input rst_n,
    input valid, input ready,
    input [W-1:0] payload
);
  reg was_stalled;
  reg [W-1:0] saved;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      was_stalled <= 1'b0;
      saved <= {W{1'b0}};
    end else begin
      if (was_stalled) begin
        if ((valid !== 1'b1) || (payload !== saved)) begin
          $display("FAIL: message changed while stalled at %0t", $time);
          $finish;
        end
      end
      was_stalled <= valid && !ready;
      saved <= payload;
    end
  end
endmodule
```

连接 IFU 消息时 W=64，payload=`{fi_pc,fi_inst}`；连接 de 时 W=304，按第 8 步顺序拼接全部字段；ew 时 W=225。注意必须包含控制字段，不能只检查 data。不要求 `$stable` 或 SVA。

`$finish` 可能让仿真进程以零退出，自动脚本必须额外检查 FAIL 标记和唯一 PASS 标记，不能只看进程返回码。生产测试可按工具约定采用其他报错退出方式。

### 12.3 验证不丢、不重、顺序正确

每个阶段建立输入/输出计数：正常运行区间内 `接收数 - 发送数 = 当前占用数`，只能是 0 或 1。EXU 的 EXEC/MEM_REQ/MEM_WAIT/SEND_WB 都算占用；非法指令在 WBU 终止，需要在完整生命周期统计里单列“终止”而不是正常提交。reset 清零统计或开始新一轮，不能把复位前消息误算丢失。

全核 TB 在 fi_fire 记录 pc/inst 和递增序号，合法 commit 时逐个比较身份并出队；非法/fatal 单列终止原因。只比较 GPR 最终值不够：重复写同一个值可能完全看不出来。还要统计 LSU 逻辑请求次数、各 beat 次数、UART 实际写次数。

安全性是“不丢、不重、不错配”；活性是“最终能完成”。只有环境保证有限等待时，才能要求有限周期提交。给总线和接收方随机有限延迟，并设足够大的超时；永久拉低 ready 测的是保持能力，不应该要求提交。

人为背压要保持双方对握手认识一致，例如测试闸门必须同时约束通过的 valid 和反向 ready；只强制改消费方看到的 valid、却让生产方仍看到 ready=1，会制造协议错误。完整缓冲或在独立 TB 控制接收端更容易做对。

### 12.4 完整验收表

| 测试 | 必须观察的结果 |
|---|---|
| ADD/ADDI/LUI/AUIPC | 正确 rd_data；AUIPC 使用消息 PC |
| 连续数据依赖 | 下一条读到上一条提交结果；无需 forwarding |
| 六类 branch taken/not-taken | signed/unsigned 边界、正确目标、无错误路径 AR |
| JAL/JALR，含 rd=rs1 | link=当前指令 PC+4；JALR 清 bit0 |
| LB/LBU/LH/LHU/LW | 对齐/偏移、符号扩展、一次逻辑响应 |
| SB/SH/SW | 写掩码、数据移位、最后 B 后才完成 |
| 跨字 RAM 访问 | 两 beat 一个逻辑结果；第二拍错误不正常提交 |
| CSR/CSRRS x0/只读 CSR | 快照一致、无不应发生的写入、非法访问有报告 |
| ECALL/MRET | mepc 与调用 PC 一致，目标正确；按现有特权支持范围验收 |
| EBREAK | 一次结束回调，a0/PC 正确，之后无取指 |
| 非法编码/RV32E 编号 | 无 LSU 和架构写副作用，明确报告，不等超时 |
| IFU/LSU 错误 | 地址/resp/op 正确，sticky 保持，无正常提交 |
| 每条消息背压 | valid 和所有字段稳定、没有重复处理 |
| 整个平台各状态 reset | 清除在途有效性、只注入一个启动许可 |

在已有定向测试基础上运行：

```sh
make -C npc lint
make -C npc/tests
make -C am-kernels/tests/cpu-tests ARCH=riscv32e-npc ALL=add run
make -C am-kernels/tests/cpu-tests ARCH=riscv32e-npc ALL=unalign run
npc/scripts/regress.sh
```

再通过 menuconfig 开启随机延迟，运行相同用例。IFU 已不再使用该参数，但 MEM.v 仍可延迟请求接收和响应，LSU 暂保留的发起延迟也仍受其控制。MEM 的随机机制不能代替对边界时序的定向覆盖；TB 仍需独立控制五个 AXI 通道的延迟与背压。

确认 DIFFTEST 开启且参考库可用。检查本工程实际比较哪些寄存器；GPR/PC 相等不能证明 CSR 和协议正确。mcycle/RTC 读数会随新周期数改变，使用专门预期或明确的时间相关跳过策略；不能为了通过测试把所有 CSR 都 skip。

reset 不能回滚已经对外生效的 store。核心单独复位而平台不复位的恢复协议不在本轮范围内。当前总线错误保持 fatal，不把它包装成完整精确异常实现。

### 思考题 12

**问：CPI 变大，说明重构失败了吗？**

**参考答案：** 不一定。本次明确增加了阶段寄存器和交接周期。正确性目标是局部控制和清晰契约；性能需结合周期数和关键路径/频率评估，不能只看 CPI 或只看最高频率。

**问：只跑 add 通过，为什么还远远不够？**

**参考答案：** ADD 不会覆盖 AXI 写通道独立握手、load 响应保持、CSR 自变化、分支目标、非法终止和 MMIO 一次性副作用。错误往往只在等待和异常路径出现。

## 13. 完成标准：可以按证据逐项打勾

- [ ] IFU 不再有 mem_valid/memfinish/execute_done 后端语义。
- [ ] IFU 不再有人工 DELAY；PC 接收后直接提供 AR，仍正确处理请求背压和延迟响应。
- [ ] IDU/EXU/WBU 都有自己的消息保存和有效状态。
- [ ] IDU/EXU 的输出不再依赖上游交付后的实时输入。
- [ ] LSU req/rsp 独立握手，不再等全局 commit 释放结果。
- [ ] 顶层没有全局执行阶段 FSM，也不读子模块私有 state。
- [ ] 合法指令的 GPR/软件 CSR/架构 PC/DPI 使用同一提交事件。
- [ ] 普通提交与下一 PC 消息交接是同一个沿；启动许可只有一份。
- [ ] 非法/总线错误都有明确终止路径，不冒充空闲或成功。
- [ ] 背压稳定性、守恒计数、定向 ISA/AXI 测试、回归分别有证据。
- [ ] 性能计数和 host 观察语义已经同步更新。

这时你可以用一句完整的话描述任一接口契约：

> 生产者保存一条含有哪些字段的消息，在有完整消息时置 valid；接收者有容量时置 ready；同一上升沿两者为 1 时转移所有权；等待期间全部字段稳定；成功/失败分别怎样结束；reset 对在途任务怎样处理；前进依赖哪些环境条件。

可以迁移的方法：先规定容量和所有权；把“接受任务、完成工作、产生不可撤销效果”分开；为跨等待周期的数据保存上下文；用计数守恒发现丢失和重复；把失败作为有身份的结果处理。迁移到 DMA、cache、加速器或软件队列时，先重新检查并发数、时钟域、副作用与错误恢复，不能照搬本核“只有一条在途”的假设。

### 最后一组推导题与参考答案

**问：如果取消单指令约束，最先失效的三条推理是什么？**

**参考答案：** 下一条读寄存器前上一条已提交不再成立；所有响应天然属于唯一当前指令不再成立；跳转前没有错误路径工作不再成立。因此需要处理数据相关、事务标识和冲刷；若允许乱序完成，还要保证按要求提交和精确恢复。

**问：什么叫模块“真正解耦”？**

**参考答案：** 在遵守协议的前提下改变一个模块的延迟，其他模块无需知道其内部状态或固定拍数，仍然正确。模块不依赖上游在交付后继续保存内容，也不要求无关下游事件替自己清理状态。解耦不代表完全没有架构约束；本设计仍明确依赖单指令、同一时钟域和整体复位。

**问：这个教程的第一项实际作业是什么？**

**参考答案：** 记录基线后，运行附录 A；手工画出 slot 在阻塞与释放时 full/data_q 的值，并解释为什么接收沿后的输入变化不会污染已保存消息。通过后才改 IFU。

## 附录 A：纯 Verilog 的首个可运行实验

把第 3 步完整 msg_slot 模块保存为 `npc/tests/msg_slot.v`，下面保存为 `npc/tests/msg_slot_tb.v`。在负沿驱动输入，正沿检查握手，`#1` 后观察寄存器更新，避免 testbench 与 DUT 在同一时间槽争用。

```verilog
`timescale 1ns/1ps
module msg_slot_tb;
  reg clk;
  reg rst_n;
  reg in_valid;
  reg [7:0] in_data;
  wire in_ready;
  wire out_valid;
  reg out_ready;
  wire [7:0] out_data;
  integer received;
  integer sent;

  msg_slot #(.W(8)) dut (
    .clk(clk), .rst_n(rst_n),
    .in_valid(in_valid), .in_ready(in_ready), .in_data(in_data),
    .out_valid(out_valid), .out_ready(out_ready), .out_data(out_data)
  );

  initial begin
    clk = 1'b0;
    forever #5 clk = ~clk;
  end

  always @(posedge clk) begin
    if (!rst_n) begin
      received = 0;
      sent = 0;
    end else begin
      if (in_valid && in_ready) received = received + 1;
      if (out_valid && out_ready) sent = sent + 1;
    end
  end

  task check;
    input ok;
    input [8*96-1:0] reason;
    begin
      if (ok !== 1'b1) begin
        $display("FAIL: %0s at %0t", reason, $time);
        $finish;
      end
    end
  endtask

  initial begin
    rst_n = 1'b0;
    in_valid = 1'b0;
    in_data = 8'b0;
    out_ready = 1'b0;
    repeat (2) @(negedge clk);
    rst_n = 1'b1;
    in_valid = 1'b1;
    in_data = 8'hA5;
    @(posedge clk);
    check(in_ready, "empty slot must accept A");
    #1;
    check(out_valid && out_data == 8'hA5, "A must be stored");

    @(negedge clk);
    in_valid = 1'b0;
    in_data = 8'h3C;
    repeat (5) begin
      @(posedge clk);
      #1;
      check(out_valid && out_data == 8'hA5, "A must survive backpressure");
      check(!in_ready, "full slot must reject new input");
    end

    // 合法地提供 B，但当前满，必须等待 A 被取走后才接收。
    @(negedge clk);
    in_valid = 1'b1;
    in_data = 8'h3C;
    out_ready = 1'b1;
    @(posedge clk);
    check(out_valid && out_data == 8'hA5, "consume A once");
    check(!in_ready, "no same-edge refill in this design");
    #1;
    check(!out_valid && in_ready, "slot becomes empty after A");
    @(posedge clk);
    check(in_ready, "accept pending B on next edge");
    #1;
    check(out_valid && out_data == 8'h3C, "B must be stored");
    @(negedge clk);
    in_valid = 1'b0;
    @(posedge clk);
    check(out_valid && out_data == 8'h3C, "consume B once");
    #1;
    check(!out_valid, "B must not repeat");
    check(received == 2 && sent == 2, "two inputs and two outputs");

    // 在持有 C 时复位，复位后不得输出幽灵消息。
    @(negedge clk);
    out_ready = 1'b0;
    in_valid = 1'b1;
    in_data = 8'h55;
    @(posedge clk);
    #1;
    check(out_valid, "C is pending before reset");
    @(negedge clk);
    in_valid = 1'b0;
    rst_n = 1'b0;
    #1;
    check(!out_valid && !in_ready, "reset suppresses handshakes");
    @(negedge clk);
    rst_n = 1'b1;
    out_ready = 1'b1;
    @(posedge clk);
    #1;
    check(!out_valid, "reset discarded C");
    $display("PASS: msg_slot acceptance, stall, refill, reset");
    $finish;
  end

  initial begin
    #2000;
    $display("FAIL: timeout");
    $finish;
  end
endmodule
```

从仓库根目录运行：

```sh
iverilog -g2005 -Wall -s msg_slot_tb -o /tmp/npc-msg-slot.vvp \
  npc/tests/msg_slot.v npc/tests/msg_slot_tb.v
vvp /tmp/npc-msg-slot.vvp
```

期望出现且只出现一次 `PASS: msg_slot acceptance, stall, refill, reset`，不出现 FAIL。这个实验只证明缓冲的基础行为，不代替 CPU 集成验证。
