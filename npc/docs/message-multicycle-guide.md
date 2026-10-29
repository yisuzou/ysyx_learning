# NPC 消息驱动分布式多周期重构：代码与推理手册

本文基于 2026-10-29 工作区实际 RTL 和 host 代码。它是实施指导，不是已经集成、测试通过的 CPU 补丁。代码块分别标注为可复用模块或集成骨架；骨架省略的端口和字段必须补齐后才能编译。

目标：IFU、IDU、EXU、WBU 各自管理消息生命周期，只有握手才转移指令所有权；全核最多一条在途指令。EXU 管理一次 LSU 请求及其结果。无预取、无推测、无多指令重叠。这里的“分布式”指控制分散到局部状态机，仍然是同一时钟域。

先完成这个版本，再讨论流水化。解耦允许独立停顿；流水化允许多条指令重叠，两者是不同目标。

## 1. 先认识正在拆除的隐含契约

阅读顺序与定位锚点（用 `rg -n '锚点' 文件` 定位）：

| 文件 | 锚点 | 当前职责与耦合 |
|---|---|---|
| `vsrc/npc_core.v` | `wire commit`、`lsu_request` | 从 IFU 有效、LSU 完成、译码合法性组合出全局提交 |
| `vsrc/IFU.v` | `execute_done` | `!mem_valid || memfinish` 决定何时丢弃指令；IFU 必须理解后端是否访存 |
| `vsrc/IDU.v` | `module IDU` | 纯组合译码，无接收、持有、发送生命周期 |
| `vsrc/EXU.v` | `module EXU` | 纯组合 ALU；PC、源操作数、控制均来自实时连线 |
| `vsrc/WBU.v` | `GPR gpr1`、`CSR csr1` | 包含 GPR、CSR、PC，同时做写回选择和跳转选择 |
| `vsrc/LSU.v` | `IDLE: if`、`DONE: if` | 已锁存 CPU 请求，但没有显式 req_ready；DONE 等全局提交 |
| `csrc/cpu/cpu-exec.cpp` | `static bool exec_once` | 沿前取 PC/inst，沿后取下一 PC，按指令驱动 difftest |
| `csrc/sim/verilator.cpp` | `sim_exec_once` | 一次调用先上升沿再下降沿，返回时已完成组合求值 |

`CLAUDE.md` 的整体地图有用，但“NPC single-cycle”描述落后于实际代码：现在已有 AXI 多周期取指/访存，后端仍是由 IFU 持有指令的组合执行链。
重构的关键不在于给每个模块添加 clk，而在于取消以下假设：

1. IFU 必须一直保存指令直到整条指令执行完。
2. 后端随时读取活的 `pc/inst/Rrs1/Rrs2/csr_rdata` 都不会出错。
3. 一根 `commit` 可以同时表示取指消费、LSU 结果消费、架构提交。

**思考题：** IFU 把指令交给 IDU 后立即清空 inst，哪些现有模块会算错？沿着连线逐一列举。能列出来，才知道要锁存哪些数据。

## 2. 先冻结边界，再设计消息

第一版约束如下。每项都是正确性证明的前提，不是性能建议。

| 约束 | 直接收益 | 失效后要补什么 |
|---|---|---|
| 同步单时钟，复位整个核及互连/从设备 | 普通 ready/valid 即可 | 跨时钟 FIFO、复位同步与事务排空 |
| 全核最多一条指令在途 | 无 RAW/WAR/WAW 冒险，无乱序提交 | forwarding、阻塞、scoreboard 等 |
| 下一次取指由当前指令提交授权 | 分支无错误路径，无 flush | epoch/tag、冲刷和响应丢弃 |
| 每级一条消息容量 | 容量和所有权易证明 | 队列容量与信用计数 |
| EXU 一次只发一个逻辑 LSU 请求 | 响应天然配对 | transaction ID 与结果匹配 |
| 每个 LSU 逻辑请求可含两个 AXI beat | 保留现有非对齐 RAM 支持 | 不能把 beat 完成当指令完成 |
| 保持当前总线错误 fatal、复位恢复 | 不引入新的异常恢复机制 | 精确异常、trap 路由与部分写处理 |

非法指令沿正常消息路径送到 WBU 报告；不发 LSU 请求、不写状态。总线错误保持现有 sticky sideband，host 优先中止。第一版不把所有错误改成架构异常。

ECALL/MRET 保留现有实现范围，不宣称完成完整特权架构；当前 CSR 对 mstatus 的 trap/mret 更新并不完整，应另设 ISA 修正任务。

## 3. 接口契约到底是什么

接口契约不只是“输入输出位宽”。每条通道必须回答：谁产生、谁消费、何时接收、阻塞时谁保存、何时释放、怎样报告失败、复位是否取消、多久能完成。

本项目统一约定：

```systemverilog
wire fire = valid && ready;  // 只在上升沿发生实际转移
```

- 生产者有完整消息就拉高 valid，不等待 ready。
- valid=1 且 ready=0 时，valid 和所有 payload 字段保持不变。
- 接收者拉高 ready 就承诺该上升沿能接收，不能先握手后发现没地方存。
- 握手沿前属于发送者，沿后属于接收者；发送者从此不再依赖旧消息。
- valid 连续两拍为 1、ready 连续两拍为 1，表示两次传输，不是一次长脉冲。
- valid=0 时 payload 没有协议意义；推荐复位清零方便观察，但不能用 payload 值判有效。
- reset 清除 valid、状态和在途请求。对已经送到外部的写入，reset 不等于撤销。
- 活性依赖环境：下游最终接收、总线最终响应。ready/valid 本身不保证这些条件。

这些稳定性规则与 [Arm AXI 握手规则](https://developer.arm.com/-/media/Arm%20Developer%20Community/PDF/IHI0022H_amba_axi_protocol_spec.pdf)一致。内部通道采用同类握手，但不是完整 AXI 总线。

**思考题：** 若生产者写 `valid = have_data && ready`，接收者写 `ready = can_accept && valid`，为何可能永远不传输？若把 valid 改成单拍 done，下游当拍不 ready 会怎样？

## 4. 消息字段：数据与解释它的上下文一起走

建议新增 `vsrc/core_msg_pkg.sv`，给四个阶段定义 packed struct。保留原 `IDU.v` 和 `EXU.v` 作为组合 helper，新增 `idu_stage.sv`、`exu_stage.sv` 包装它们，第一轮不用重写译码表和 ALU。

以下是消息字段清单，不是完整 package；现有控制编码先原样保留，后续再统一命名。

| 消息 | 字段 |
|---|---|
| WBU→IFU `fetch_cmd` | `pc[31:0]` |
| IFU→IDU `if_id` | `pc[31:0], inst[31:0]` |
| IDU→EXU `id_ex` | pc、inst、illegal；rs1/rs2/rd 的 5 位编号；rs1_value、rs2_value、imm_raw、csr_old、mtvec_snapshot、a0_snapshot；src_sel、exu_op、pc_we、pc_wsel、branch_en、branch_op、gpr_we、gpr_wsel、mem_valid、mem_wen、mem_rbhw、mem_wbhw、isign、csr_we、csr_wsel、csr_addr、imm2csr、is_ecall、is_ebreak |
| EXU→WBU `ex_wb` | pc、inst、illegal；next_pc；rd_we、rd、rd_data；csr_we、csr_addr、csr_data；is_ecall、is_ebreak、a0_snapshot；mem_valid、mem_wen、mem_addr、skip_ref；性能分类字段 |
| EXU→LSU `lsu_req` | addr、write、rsize、wsize、wdata、sign |
| LSU→EXU `lsu_rsp` | load_data；第一版成功响应走此通道，错误仍走 sticky sideband |

注意区分 `mem_valid`（这条指令是访存）和 `req_valid`（本拍在提供请求），不要复用同名信号表达两个含义。

通用元数据可以先这样写：

```systemverilog
package core_msg_pkg;
  typedef struct packed {
    logic [31:0] pc;
    logic [31:0] inst;
  } if_id_t;
  // 按上表补 id_ex_t、ex_wb_t、lsu_req_t。
endpackage
```

`pc` 必须是这条消息的 PC；不允许 EXU 用“当前 IFU PC”计算 AUIPC、JAL link 或分支目标。

用两个问题审查每个字段：下游还会用吗？若不传它，下游是否必须反向偷看上游内部状态？第二个答案为“是”时，多半还没有真正解耦。

构建时在 `vsrc/filelist.mk` 显式列出 `.sv`，package 排在所有使用者之前。当前目录扫描只搜 `*.v`，不会自动发现 `.sv`。检查 `make -C npc -n lint` 最终顺序；STA 脚本的 SystemVerilog/package 支持另行核实，不能因 Verilator 支持就假定综合链也支持。

## 5. 关卡一：独立掌握一格消息缓冲

下面是完整、可独立使用的保守实现。第一版不支持同拍取走旧消息并接收新消息；这个气泡有助于消除组合 ready 长链，在单指令核中也不是吞吐瓶颈。

```systemverilog
module msg_slot #(parameter int W = 1) (
  input  logic clk, rst_n,
  input  logic in_valid,
  output logic in_ready,
  input  logic [W-1:0] in_bits,
  output logic out_valid,
  input  logic out_ready,
  output logic [W-1:0] out_bits
);
  logic full;
  logic [W-1:0] data_q;
  assign in_ready  = rst_n && !full;
  assign out_valid = rst_n && full;
  assign out_bits  = data_q;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      full   <= 1'b0;
      data_q <= '0;
    end else if (in_valid && in_ready) begin
      data_q <= in_bits;
      full   <= 1'b1;
    end else if (out_valid && out_ready) begin
      full <= 1'b0;
    end
  end
endmodule
```

packed struct 可通过 `$bits(type_name)` 作为 W 使用。这个模块只是消息寄存器；EXU 的长事务状态机不能仅靠套一个 slot 就完成。

验证：输入握手后立即改变输入 bits，输出保持旧值；让 out_ready 连续低 20 拍；只允许一次输出握手；复位后不能输出复位前的消息。testbench 必须先保持 valid 到握手，不能用不遵守协议的激励误判 DUT。

**思考题：** `in_ready = !full || out_ready` 可以优化什么？改后为什么必须处理同拍 pop/push 优先级？为什么这也可能产生跨模块的组合 ready 路径？先不做这个优化。

## 6. 关卡二：把 IFU 的“执行等待”改为“消息交接”

修改 `IFU.v`：移除 `mem_valid/memfinish`，新增 fetch_cmd 和 if_id 通道。保留 AXI AR/R 握手、地址锁存、random_delay 和 sticky fault 的实现。

状态职责：

| 状态 | 输出/动作 | 离开条件 |
|---|---|---|
| WAIT_PC | fetch_cmd_ready=1 | cmd_fire：锁存 PC，转 DELAY |
| DELAY | 等人工延迟结束 | 转 AR |
| AR | ARVALID=1，地址为锁存 PC | ar_fire → R |
| R | RREADY=1 | r_fire 成功锁存 inst → OUT；失败 → FAULT |
| OUT | if_id_valid=1，输出锁存 pc/inst | if_id_fire → WAIT_PC |
| FAULT | sticky 错误，不发请求 | 整体 reset |

复位时 `fetch_pc_q=32'h80000000`、状态为 DELAY，等价于注入唯一的启动取指许可。WBU 不再额外注入一个启动消息，否则会出现两条在途指令。

关键替换骨架：

```systemverilog
assign fetch_cmd_ready = rst_n && (state == WAIT_PC);
assign if_id_valid    = rst_n && (state == OUT);
assign if_id_bits.pc  = fetch_pc_q;
assign if_id_bits.inst = inst_q;
// OUT 仅在 if_id_valid && if_id_ready 时离开。
// WAIT_PC 仅在 fetch_cmd_valid && fetch_cmd_ready 时更新 fetch_pc_q。
// m_axi_araddr 由 fetch_pc_q 或专用 AR 寄存器驱动，不能读实时 cmd.pc。
```

最重要的删改：原来的 `execute_done = !mem_valid || memfinish` 应消失。IFU 的完成是 IDU 接收了取指结果，不再是整条指令提交。

OUT 发出去后 IFU 留在 WAIT_PC，即使 IDU/EXU 慢一千拍，也不会自行 PC+4 预取。只有 WBU 的新 PC 消息让它继续。

验证：阻塞 IDU 时 inst 和 pc 不变；交接后没有新 AR；发新的 fetch_cmd 后只出现一次新的 AR；ARREADY 低时地址不变；RRESP 错误不能产生 if_id_valid。

**思考题：** 为什么“IDU 已经收到指令”不能同时代表“IFU 可以取下一条顺序指令”？用一条 taken branch 举例。

## 7. 关卡三：IDU 锁存完整执行上下文

第一步将 GPR/CSR 实例从旧 WBU 搬到 `npc_core.v`（也可建立 `arch_state` 模块）。组合读口供 IDU 使用，写口仅由 WBU 提交控制。这不是多写者共享状态：每个寄存器仍只有一个时序驱动。

IDU 接收 IFU 消息时完成：组合译码、组合读寄存器、捕获 CSR 旧值和所有控制，存入 id_ex 输出槽。只有输入 fire 时锁存，不是 valid 高就每拍重采样。

```systemverilog
// 集成骨架：decoded 由原 IDU + 读口组成；msg_slot 存 decoded。
always_comb begin
  decoded = '0;
  decoded.pc        = if_id_bits.pc;
  decoded.inst      = if_id_bits.inst;
  decoded.rs1_value = gpr_rdata1;
  decoded.rs2_value = gpr_rdata2;
  decoded.csr_old   = csr_rdata;
  decoded.mtvec_snapshot = mtvec_data;
  decoded.a0_snapshot = gpr_a0;
  decoded.illegal = invalid_decode || (uses_csr_read && invalid_csr_addr);
  // 复制第 4 节列出的其余字段；不能遗漏控制。
end
```

`uses_csr_read` 应由译码类别显式决定，包含所支持 CSR 指令及 MRET 对 mepc 的读取；普通 ADD 不应该因闲置 CSR 地址无效而报错。不要再直接用裸 `invalid_csr_access` 作为全核 invalid。

原 `imm2csr` 不要在顶层从实时 CSR 值替换 imm：

```systemverilog
wire [31:0] execute_imm = ctx.imm2csr ? ctx.csr_old : ctx.imm_raw;
```

由 EXU 内部对已经锁存的 ctx 产生它。

原因尤其体现在 mcycle：当前 `CSR.v` 每拍递增。若 id_ex 被阻塞时 csr_old 仍来自实时读口，payload 每拍变化；同一条 CSRRS 的“返回旧值”和“用于写回的旧值”甚至可能不相同。契约规定在 IDU 接收沿取样，并且整条指令只用这份旧值。增加周期后 mcycle 读数可以与旧核不同，不能按固定计数值做新旧核等价比较。

RV32E 依旧保留 5 位寄存器编号，检查实际使用的 rs/rd 是否超出 x15，不能直接截断成 4 位，否则 x16 会别名到 x0。现有 IDU 的 CSR 分支还需要补查 RV32E 的 rs1/rd 合法性。

另一个应独立修正并测试的问题：当前 CSRRS 无条件 csr_we。规范要求 **rs1 编号为 x0 时不写 CSR**，不是“rs1 的数值为零时不写”。见 [RISC-V Zicsr](https://docs.riscv.org/reference/isa/unpriv/zicsr.html)。同时明确只读 CSR 写入的处理；当前 CSR 模块会忽略某些写，不等价于完整的非法访问检测。不要把这些 ISA 修复混成消息接口问题。

验收：在 id_ex 出口人为阻塞时，让 CSR 计数器继续运行，id_ex 所有字段仍稳定；顺序运行 `addi x1,x0,7; add x2,x1,x1`，第二条读到 7。因为第二条取指在第一条提交之后，当前设计不需要旁路。

**思考题：** “当前只有一条指令”为什么没有自动保证所有读口稳定？列出一个即使没有其他指令也会变化的输入。

## 8. 关卡四：EXU 包含 ALU、分支决策和 LSU 协调

保留原 `EXU.v` 为组合 ALU，保留 BranchUnit。新增 exu_stage；它锁存 id_ex，再驱动这些 helper。建议第一版使用清晰的五态：

| 状态 | 职责 |
|---|---|
| IDLE | id_ex_ready=1；输入 fire 时锁存 ctx → EXEC |
| EXEC | illegal 直接生成错误结果；普通指令生成 ex_wb → OUT；访存生成并锁存 req → MEM_REQ |
| MEM_REQ | 持续 lsu_req_valid；req_fire → MEM_WAIT |
| MEM_WAIT | lsu_rsp_ready=1；rsp_fire 时锁存最终结果 → OUT |
| OUT | 持续 ex_wb_valid；ex_wb_fire → IDLE |

EXEC 生成的 next_pc 和所有待提交效果必须保存到结果寄存器。OUT 期间不能再从实时 IDU/GPR/LSU 总线重算输出。

数据选择的迁移规则：

```systemverilog
// 组合计算骨架，所有右值来自锁存 ctx。
next_pc = ctx.pc + 32'd4;
if (ctx.branch_en && branch_taken) next_pc = ctx.pc + ctx.imm_raw;
if (ctx.pc_we) begin
  case (ctx.pc_wsel)
    PC_EXU_RESULT: next_pc = alu_result & 32'hffff_fffe;
    PC_BRANCH:    next_pc = ctx.pc + ctx.imm_raw;
    PC_TO_MTVEC:  next_pc = ctx.mtvec_snapshot;
    PC_TO_MEPC:   next_pc = ctx.csr_old;
    default:     next_pc = ctx.pc + 32'd4;
  endcase
end
// rd_data 选择沿用原 WBU 的 GPR_* 编码：
// EXU_RESULT -> alu_result; PC_PLUS4 -> ctx.pc+4;
// IMMEDIATE -> execute_imm; PC_IMM -> ctx.pc+ctx.imm_raw;
// MEM_DATA -> 在 rsp_fire 时从 lsu_rsp.load_data 锁存。
// csr_data: CSR_REG -> ctx.rs1_value; CSR_EXU_RESULT -> alu_result。
```

这个 PC 选择保留当前实现。JALR 清 bit0；JAL/branch 的目标对齐是否合法是独立 ISA 检查，不要把清 bit0 当成完整对齐检查。

ECALL 的 mepc 必须来自 `ctx.pc`，不是旁边 IFU 的地址。CSRRS 写入用锁存旧值 OR 锁存 rs1，返回 rd 的也是同一旧值。

**思考题：** 若 load 的 R 响应到达，但 WBU 停顿 50 拍，load 数据应该由谁保存？为什么让 LSU 永远等 WBU commit 会重新引入跨层耦合？

## 9. 关卡五：LSU 从“等待全局提交”变成请求/响应服务

这是接口重构，不应同时重写已存在的 AXI、拆分访问、符号扩展算法。

将 CPU 侧改为 req_valid/req_ready 与 rsp_valid/rsp_ready。保留参数、AXI 端口和错误输出。

```systemverilog
assign req_ready = rst_n && (state == IDLE);
assign rsp_valid = rst_n && (state == DONE);
wire req_fire = req_valid && req_ready;
wire rsp_fire = rsp_valid && rsp_ready;
// 原 IDLE: if (mem_valid)       -> IDLE: if (req_fire)
// 原请求锁存条件               -> if (req_fire)
// 原 DONE: if (lsu_finish)      -> DONE: if (rsp_fire)
// mem_addr/size/sign/wdata 等取 req_bits，且仅在 req_fire 时使用。
```

把 `lsu_finish(commit)` 连线删掉，EXU 消费响应后 LSU 就可以回 IDLE，哪怕 WBU 尚未提交。响应数据已由 EXU 接管，所以不会丢失。

FAULT 仍保留直到复位。EXU 可留在 MEM_WAIT；这是 fatal 路径，由现有 host 观察 debug_bus_error 中止，不应声称失败请求一定会有普通 rsp。独立硬件 testbench 也要监控 fatal，否则只能等超时。

必须保持：

- AW 与 W 分别握手，分别记住 aw_sent/w_sent；不能要求两者同拍 ready。
- store 最终成功响应是最后一个 beat 的 B 握手，不是 AW、W 已送出。
- split load/store 的第一拍完成不产生逻辑 rsp；一个逻辑请求恰好一个成功 rsp，或进入 fatal。
- MMIO 不因 EXU/WBU 背压重复发请求；不投机读 MMIO，因为读也可能有副作用。
- 已发出的 AXI VALID 不能被 random_delay 随意拉低；延迟只影响开始发起的时刻。

**不能承诺的原子性：** store 的数据可能在 B 响应前就对外可见。跨字 store 第一拍成功、第二拍失败，内存可能部分更新。保持 fatal 语义能阻止继续执行，但无法回滚内存。WBU 集中的是 GPR/软件 CSR/架构 PC 的指令提交，不是所有外设副作用。mcycle 自主递增也是明确的例外。

验证除普通 load/store 外，必须包含 AW 先/W 先/同拍、响应延迟、跨字、第二拍错误、MMIO 一次性访问。现有 `tests/axi_lsu_tb.sv` 需要适配 CPU 侧握手，不能仅让新核编译通过。

## 10. 关卡六：WBU 是唯一指令提交点

WBU 一格 ex_wb 输入缓冲，锁存后等待提交条件。将 EXU 结果变成 GPR/CSR/PC 写入和下一次取指许可。

第一版选择 **普通指令提交与 WBU→IFU PC 消息握手发生在同一沿**。这是清晰、可验证的原子契约；没有必要先提交再额外缓存 PC 命令。

```systemverilog
// 集成骨架。wb_full/wb_q 为 WBU 的寄存器。
assign fetch_cmd_valid = rst_n && wb_full && !wb_q.illegal &&
                         !wb_q.is_ebreak && !fatal;
assign fetch_cmd_pc = wb_q.next_pc;
wire ordinary_commit = fetch_cmd_valid && fetch_cmd_ready;
wire halt_commit = rst_n && wb_full && !wb_q.illegal &&
                   wb_q.is_ebreak && !fatal;
wire commit_fire = ordinary_commit || halt_commit;

assign gpr_wen = commit_fire && wb_q.rd_we && (wb_q.rd != 0);
assign csr_wen = commit_fire && wb_q.csr_we;
assign csr_ecall = commit_fire && wb_q.is_ecall;
// 同一个上升沿：
// GPR/CSR 接收写使能；arch_pc <= wb_q.next_pc；WBU 清 wb_full。
// ordinary_commit 时 IFU 同时锁存 next_pc；ebreak 不发下一条取指。
```

`fetch_cmd_valid` 不依赖 ready。IFU 在交给 IDU 后早已处于 WAIT_PC，所以健康单指令链中 WBU 不会等一个由自身提交才能产生的 ready。

若 WBU 等 IFU ready，而 IFU 却等 WBU commit 才进入 WAIT_PC，就形成死锁。应从状态转移消除这个环，不要用“偶尔拉高 ready”掩盖。

EBREAK 仍在 commit_fire 上调用一次 `npc_ebreak(a0_snapshot, wb_q.pc)`，不启动后续取指。即使 `sim_finish()` 再走两拍也不会执行下一条。非法指令不清空错误记录、不发命令、不写寄存器，交由 host 中止。

WBU 的 arch_pc 复位到 0x80000000，只在合法 commit_fire 更新。IFU 的 fetch_pc_q 是请求副本，不是第二个架构 PC 写者。

**思考题：** 为什么不能 `gpr_wen = wb_full && wb_q.rd_we`？假设 IFU ready 低三拍，GPR、DPI 和 EBREAK 各会发生什么？

## 11. 不能漏掉 host 的观察契约

现有 `exec_once()` 并非“valid 后再等下一周期处理”。它先看组合 debug 信号，然后调用 sim_exec_once 产生提交沿，再读取 PC。

保留现有 host 接口的最小方案：

```systemverilog
assign debug_pc = arch_pc;
assign debug_inst = wb_q.inst;
assign invalid_inst = rst_n && wb_full && wb_q.illegal;
// 这个历史名称表示 host 的指令处理事件，包含非法指令报告。
assign diff_ifu_valid = !fatal && (commit_fire || invalid_inst);
assign debug_skip_ref = commit_fire && wb_q.skip_ref;
```

非法指令必须使 host 进入检查 invalid_inst 的分支。若只令 diff_ifu_valid=合法 commit，host 永远不会检查非法指令，最后表现为“可能总线死锁”。

debug_pc 在沿前是当前指令 PC，沿后是 next_pc，恰好满足现有 host；在本单指令模型下添加断言：WBU 有效时 `wb_q.pc == arch_pc`。总线出错时 arch_pc 仍指向出错指令，debug_bus_error_addr 保留真正失败的地址（split 第二拍可能不同于原始地址）。

`npc_reg_write` 必须用 wb_q.rd/rd_data 和同一个 commit_fire，不再读实时译码；`npc_ebreak` 必须用 wb_q.pc。GPR 硬件写和 host 镜像写使用一致的有效条件。

若以后做流水线，这种复用 debug_pc 的技巧不再足够，应显式提供 commit_pc、commit_inst、commit_next_pc、commit_rd/data 等，修改 host 沿前一起采样。不要在第一版把 debug_pc 直接换成随流水活动变化的 IFU PC。

skip_ref 在 EXU 根据锁存访问地址和当前 PMEM 参数计算，随 ex_wb 保存；WBU 提交前提供给 host。原有 MMIO DPI 的跳过机制也应审查，确保不会错配到下一条指令。

## 12. 守恒关系比状态名更重要

给每个有效消息一个概念上的“令牌”。物理上 PC/inst 可以复制多份，但只有声明有效的阶段拥有执行权。

对每级（忽略 reset/fatal 截断区间）：

```text
累计输入握手数 - 累计输出握手数 = 当前占用数（0 或 1）
```

EXU 在 MEM_WAIT 时仍拥有指令，LSU 只是它派生的子事务，不能在全核指令数里再算一条。WBU 普通提交在同一沿把执行权交给 IFU 的下一次 fetch；EBREAK/fatal 终止链。

对 LSU 成功路径：接受请求数 - 消费响应数 = 在途逻辑请求数。FAULT 时要额外计失败/终止项，不能套成功路径等式。

可用断言模板（SystemVerilog，构建已有 `--assert`；独立 TB 也必须打开）：

```systemverilog
assert property (@(posedge clk) disable iff (!rst_n)
  out_valid && !out_ready |=> out_valid && $stable(out_bits));

assert property (@(posedge clk) disable iff (!rst_n)
  gpr_wen |-> commit_fire);

assert property (@(posedge clk) disable iff (!rst_n)
  lsu_req_valid |-> exu_has_instruction && !ctx.illegal);
```

断言模板里的命名需映射到实际信号；不要直接放入工程后以为覆盖已完成。

再加 TB scoreboard：每个 if_id_fire 记录 pc/inst，检查下一次终止事件匹配它且只出现一次；接受 lsu_req 时记 addr/write/data，检查 CPU 请求不会重复、beat 数正确。相同 PC 可能来自循环，不能用“PC 不重复”判一次性；使用 TB 递增序号。

安全性与活性分开验证：稳定、不重发、不乱配属于安全性；最终提交属于活性。用有界随机延迟才能合理断言 N 拍内完成，不能要求任意外设无限停顿时 CPU 仍能提交。

## 13. 按这个顺序实施，每步有退出条件

| 步骤 | 修改范围 | 必须达到的退出条件 |
|---|---|---|
| 0 | 不改 RTL，记录当前配置/基线 | lint、现有 AXI 测试、add/dummy/unalign 的实际结果与已知失败 |
| 1 | msg_slot + 独立 TB | 随机背压下不丢、不重复、payload 稳定 |
| 2 | package、IFU 新接口 + IFU TB | 不再引用 mem_valid/memfinish，单个命令单个输出 |
| 3 | IDU wrapper + GPR/CSR 读快照 TB | id_ex 阻塞时 CSR 快照稳定，RV32E 非法编号检测 |
| 4 | LSU 新接口 + 更新原 LSU TB | AW/W 独立、split、故障和延迟测试仍成立 |
| 5 | EXU wrapper + mock LSU/WBU | 请求只发一次，响应锁存，ALU/分支 next_pc 正确 |
| 6 | 新 WBU、npc_core 接线、debug/DPI | add/dummy 通过；一条指令只有一个 commit |
| 7 | 全核压力与回归 | 下表覆盖；difftest、CSR 定向与性能计数分别验收 |

步骤 2—5 可用新文件和独立 TB 并行保留旧集成，待步骤 6 一次切换 filelist/接线。若直接改原模块接口，中间提交可能无法构建旧顶层，必须明确这一点。不要把半套新端口临时接常量后当作集成完成。

仓库现成入口（从仓库根目录运行）：

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
npc/scripts/regress.sh
```

构建/运行会触发项目自带 tracer 自动提交；保留其机制，不手动提交 tracer-ysyx。不要执行 defconfig 覆盖当前配置。随机延迟/波形通过 menuconfig 配置，不传 ITRACE/MTRACE/FTRACE/TRACE_FLAGS 变量。

本次阅读时 `.config` 开启 RVE、DIFFTEST、WAVE_TRACE、PERF_COUNTERS，未开启 RANDOM_DELAY。参考库是否存在、程序是否通过，必须运行后记录；本文没有宣称已经运行过这些回归。

### 全核必测矩阵

| 场景 | 观察内容 |
|---|---|
| add/addi/lui/auipc | rd 数据及消息 PC 一致 |
| 连续相关指令 | 下一条读取前一条提交结果 |
| 六类 branch taken/not-taken | signed/unsigned 边界、正确 next_pc、无错误路径 AR |
| JAL/JALR | link=该指令 PC+4，JALR 清 bit0，rd=rs1 场景 |
| LB/LBU/LH/LHU/LW，SB/SH/SW | 偏移/符号扩展、地址、字节掩码 |
| 跨字 load/store | 两 beat 一个结果，第二 beat 失败时无正常提交 |
| EXU/WBU 出口阻塞 | 结果稳定，LSU 和 MMIO 不重复访问 |
| CSR 读写及 CSRRS rs1=x0 | 同一旧值、无意外写回，计数器照常运行 |
| ECALL/MRET | mepc 是调用指令 PC，目标来自正确快照；按现有支持范围验收 |
| EBREAK | 只一次结束回调，正确 a0/PC，后续无取指 |
| 非法 opcode/CSR/RV32E 编号 | 无 GPR/CSR/LSU 副作用，host 明确报告而非超时 |
| IFU/LSU 总线错误 | 错误地址/op/resp 正确，禁止正常提交 |
| 各阶段 reset | 无幽灵 valid，整体平台复位后重启；不承诺撤销旧 store |

当前 random_delay 主要延迟发起，不足以覆盖所有通道的独立背压。TB 需要独立控制 ARREADY、RVALID、AWREADY、WREADY、BVALID，并保证自身响应遵守协议。插入阶段背压时同时阻断双方握手或使用合法缓冲，不能只改接收方 ready 而让发送方以为已交付。

不要只靠 difftest：检查实际参考适配器比较的字段；GPR/PC 比较不能替代 CSR、握手、一次性 MMIO 的定向验证。mcycle/RTC 等时间相关读值需要单独预期或明确 skip 策略，不能因周期数改变就盲目认定重构错误，也不能把所有 CSR 都 skip 掩盖错误。

## 14. 性能与维护也要同步迁移

`npc_core.v` 当前性能事件大量依赖 ifu_valid、lsu_done、实时译码。解耦后原含义不成立：

- `lsu_done` 可能保持多拍，事件计数改为 rsp_fire；占用周期单独统计。
- `!ifu_valid` 不再等于“全核等待取指”，因为指令可能已在 EXU。
- ALU/load/store/branch 分类从 wb_q 元数据在 commit_fire 上统计。
- IFU 等下一 PC、IFU 总线等待、IDU 出口阻塞、EXU 访存等待、WBU 等待分别定义。
- `csrc/sim/perf.cpp`、CSV/绘图和性能文档同步更新，不能只改 RTL 位语义。

增加阶段寄存器通常增加 CPI，可能缩短关键路径；是否改善实际时间应结合周期数和综合时序判断。不能用“模块更解耦”直接推出更快。

工作区已有对 `docs/performance-counters.md` 的修改和未跟踪的 `vsrc/IFU_perf.v`；本指南没有覆盖它们，集成时先审阅其用途。

## 15. 最终自测：不用看代码解释这些问题

1. 一条消息在握手前后分别属于谁？副本与所有权有什么区别？
2. 为什么 valid 不可以等 ready？背压时哪些字段必须保持？
3. IFU 交付完成、LSU 操作完成、指令提交分别是哪一个 fire？
4. 哪条约束使你暂时不需要 forwarding、flush 和 transaction ID？
5. CSR 为什么需要快照？快照在哪个沿确定？
6. 为什么 store 已写入与 WBU 提交不是同一个时刻？失败能回滚吗？
7. 为什么非法指令不能简单令所有 valid 变成 0？
8. 谁拥有架构 PC？谁保存 fetch PC？为什么允许两份数值副本？
9. 一个响应早已收到、下游迟迟不接收，结果保存在哪里？
10. 什么条件能证明系统最终前进？哪些属于外部环境假设？
11. 为什么相同 PC 的两次提交不一定是重复执行？
12. 把下一次 fetch 提前到上一条提交之前，会破坏本文哪几条证明？

能迁移到 DMA、缓存、加速器和软件任务队列的核心方法是：先规定所有权与容量；再规定接收/完成/提交；显式保存跨等待周期的上下文；用计数守恒证明不丢不重；把错误终止与成功完成分开；最后在不破坏契约的前提下优化重叠和吞吐。

第一项动手作业：写出 IFU→IDU 的八项契约并实现 msg_slot 的背压测试。解释清楚“输出 valid 已经高了三拍，为什么可能还没有传输过一次”，再开始改 IFU。
