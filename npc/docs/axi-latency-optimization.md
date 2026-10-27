# MEM 与 AXI 互连延迟优化（2026-10-27）

在性能计数器的多周期基线上，分别测量仅修改 MEM、再修改 XBAR/仲裁器的收益。
两项合并后，无随机延迟的 microbench test 从 5,967,797 周期降至 3,439,614 周期，
减少 42.364%；相同综合口径下，Fmax 搜索区间没有变化。

以上记录保留前一轮两层 XBAR 的结果。随后完成的 CLINT 外置与单层 XBAR 迁移见末节，
该次迁移的完整平台时序和面积发生了回退。

这是工作区改动的测量记录，未向要求已提交源码和 microbench train 的正式性能台账追加行。

## MEM：在 AR 握手沿读取并寄存响应

`vsrc/MEM.v` 删除 `RD_ACCESS`，读状态变为：

```text
RD_IDLE --AR 握手并锁存读结果--> RD_DELAY --延迟结束--> RD_RESP --R 握手--> RD_IDLE
```

仅在 `ar_fire` 那一沿使用有效的 ARADDR/ARPROT：检查对齐字的范围，根据 ARPROT[2]
调用 pmem_ifetch/pmem_read 或读取综合阵列，寄存 RDATA/RRESP。
后续响应不再需要单独保存 AR 地址/属性，主机握手后改变它们不会影响已锁存结果。
RREADY 反压期间不重复调用 DPI，RVALID 和载荷持续保持。

保留已有 `RD_DELAY` 及随机延迟机制，所以关闭随机延迟时，恰好省去一个固定周期。
AR 握手后进入 RD_DELAY，下一沿进入 RD_RESP 并使 RVALID 有效。

同地址并发读写明确采用 read-first：当 AR 握手与 WR_ACCESS 重合时，
读返回更新前的值。DPI 的读、写副作用放在同一个时序块中按读后写顺序执行，
与综合阵列的非阻塞写入一致。独立测试同时验证两种后端。

这个实现验证的是当前同步读阵列和 DPI 后端；不能由此保证任意 SRAM/SDRAM
行为模型都可以直接替换。若后端改为变延迟的请求/完成接口，仍需等待后端完成，
AXI 外部端口可以继续保持。

## XBAR：组合译码，握手后保存路由

`vsrc/XBAR.v` 的读方向在 RD_IDLE 组合译码并转发 AR，AR 握手时锁存响应路由，
直到 R 握手后才接收下一笔读。删除独立 RD_ADDR 状态。

写方向删除独立的译码等待状态。AW、W 可独立握手：

- AW 尚未接受时，用有效 AWADDR 的组合译码结果转发请求。
- AW 接受后，保存其路由；即使上游 AWADDR 已变成另一从机的下一笔请求，W 仍走保存的路由。
- 每个已接受的通道停止转发，防止 AW/W 重复；两者完成后等待 B。
- W 先于 AW 到达时可以等待，直到 AWVALID 提供可用地址。
- 未映射、禁用或不可执行规则仍由默认从机返回 DECERR。

CPU 内和平台层各实例化一层 XBAR，因此本项使每次无反压读少两拍地址译码，
普通写也少两拍。

## 仲裁器：首拍直通，反压时锁住

`vsrc/AXIArbiter.v` 保留 IDLE/ADDR/RESP 三个状态，但不再强制先进入 ADDR：

- IDLE 时组合选出请求者并立即转发；下游就绪则当拍完成 AR 握手并进入 RESP。
- 若当拍出现反压，则保存选中者并进入 ADDR，后续不得被晚到的高优先级请求替换。
- AR 完成后继续保存 owner，响应只送给该主机；R 完成才更新轮询优先级并释放。

所以省掉的是固定的“等待 owner 锁存”周期，owner 的保存和锁定仍然存在。
即使后续流水线使 IFU/LSU 同时请求，也需要遵守这一约束。

## 协议边界

“禁止 READY 依赖 VALID”不是 AXI 的规定：接收方允许等待 VALID 后再提供 READY，
发送方不能等待 READY 才发 VALID。标准也规定接口输入、输出之间不能有组合路径，
因此单凭依赖方向或“没有组合环”不足以证明任意独立 AXI IP 合规。
参见 [Arm IHI 0022H，A3.1–A3.3](https://developer.arm.com/-/media/Arm%20Developer%20Community/PDF/IHI0022H_amba_axi_protocol_spec.pdf#page=40)。

本次组合译码/仲裁作为当前寄存主从端点之间的内部互连使用，端到端组合链已通过
Verilator lint 和综合检查。如果将这些模块独立封装成需要严格寄存隔离的 AXI IP，
需要在相应边界加入寄存切片，不能直接套用本次内部互连的零周期假设。

## microbench test 逐项测量

RV32E，Difftest 开启，所有阶段使用同一份镜像。
原始输出与结构化数据见 [comparison.json](../build/axi-opt/comparison.json)。
镜像、配置的 SHA256 均保存在该文件中。

| 改动 | 随机延迟 | 动态指令数 | 仿真周期数 | CPI |
|---|---|---:|---:|---:|
| 基线 | 关 | 540004 | 5967797 | 11.051394 |
| 仅 MEM | 关 | 540047 | 5362401 | 9.929508 |
| MEM + XBAR + 仲裁 | 关 | 539020 | 3439614 | 6.381236 |
| 基线 | 开 | 540321 | 10728697 | 19.856154 |
| 仅 MEM | 开 | 539914 | 9842729 | 18.230179 |
| MEM + XBAR + 仲裁 | 开 | 540331 | 9758767 | 18.060720 |

各阶段均 MicroBench PASS、GOOD TRAP，指令数和周期自洽检查全部 OK。
动态指令数略有变化，是因为程序读取模拟时钟并格式化输出计时结果；因此同时记录 CPI，
不把三次执行说成完全相同的动态指令流。

无随机延迟的取指逐拍分解：

| 阶段 | 请求准备 | 地址等待 | 地址接受 | 响应等待 | 响应接受 | 总计 |
|---|---:|---:|---:|---:|---:|---:|
| 基线 | 1 | 3 | 1 | 2 | 1 | 8 |
| 仅 MEM | 1 | 3 | 1 | 1 | 1 | 7 |
| 两项合并 | 1 | 0 | 1 | 1 | 1 | 4 |

合并后 microbench 的 LSU 平均延迟为 6.427 拍（原为 9.562 拍），
load 的平均执行时间约 7 拍，store 约 7.989 拍；RAM、UART、CLINT 等路径不同，
总体均值可以不是整数。

随机延迟开启时总周期减少 9.041%。各 LFSR 实例的延迟采样受执行相位影响，
减少固定周期会改变之后采到的延迟，所以随机模式的差值不能直接解释成省掉的固定拍数。
本次用无随机延迟测固定开销，用随机延迟施加反压并验证正确性。

## 综合与时序对照

两次均对冻结的源码快照完整重新综合、映射和二分搜索；未复用旧网表。
口径：RV32E、4 KiB 触发器 MEM、RANDOM_DELAY=0、Nangate45 typical、2 ns 映射目标、
扇出目标 8、周期搜索精度 0.01 ns。结果是理想时钟、无提取线寄生的网表估计。

| 指标 | 基线 | 两项合并 |
|---|---:|---:|
| Setup Fmax 区间 | 410.256–411.576 MHz | 410.256–411.576 MHz |
| 标准单元面积 | 306721.674 µm² | 297504.774 µm² |
| 各次试验 hold 检查 | 通过 | 通过 |

在该搜索精度下未观察到 Fmax 回退，面积减少 3.005%。同频周期收益约 1.73 倍，
不能把它直接当成布局布线后频率或真实 SRAM 宏的测量结果。

归档证据：[基线结果](../build/axi-opt/sta-baseline/result.json)、
[优化结果](../build/axi-opt/sta-final/result.json)。同目录保留原始时序/电气报告、
网表、综合输出、RTL 和配置快照；JSON 中的绝对路径保留原始测量位置。

## 验证和复现

```sh
make -C npc lint
make -C npc/tests test
make -C npc/tests perf-test PERF_TEST_ARGS="--diff $NEMU_HOME/build/riscv32-nemu-interpreter-so"
make -C am-kernels/tests/cpu-tests ARCH=riscv32e-npc ARGS=-b run
```

验证结果：

- 35 项 CPU 测试在随机延迟、Difftest 开启时全部 PASS，无计数 MISMATCH。
- LSU 两种延迟模式、仲裁器轮询/反压、XBAR 路由/错误/读写并行、UART 单元测试通过。
- 新增仲裁器首拍握手与“晚到的高优先级主机不得抢占停住地址”用例。
- XBAR 检查读首拍转发，以及 AW2 改指另一从机时 W1/B1 的路由保持。
- 新增持久化 MEM 测试：全部 16 种 WSTRB，AW/W 三种先后次序，AR 地址/属性切换，
  R/B 长反压，错误地址，零 strobe，同址 read-first，响应中复位；
  DPI 随机延迟开/关和 SYNTHESIS 阵列三种构建均通过。
- 性能计数器专项在两种延迟配置下均通过。关闭延迟时，精确验证取指 4 拍、
  对齐 load/store 执行 7/8 拍、跨字 load/store 执行 11/13 拍。

无随机延迟的独立程序可用以下命令构建（不会修改 .config）：

```sh
make -C npc CONFIG_RANDOM_DELAY= OBJ_DIR=/tmp/npc-opt-fixed-obj BINARY=/tmp/npc-opt-fixed
python3 npc/tests/perf_counters.py --npc /tmp/npc-opt-fixed --expect-no-delay \
  --diff "$NEMU_HOME/build/riscv32-nemu-interpreter-so"
make -C am-kernels/benchmarks/microbench ARCH=riscv32e-npc mainargs=test insert-arg
/tmp/npc-opt-fixed -b --diff="$NEMU_HOME/build/riscv32-nemu-interpreter-so" \
  am-kernels/benchmarks/microbench/build/microbench-riscv32e-npc.bin
```

完整单元与 CPU 回归日志分别保存在 `build/axi-opt/unit-tests.log`、`build/axi-opt/cpu-tests.log`。

## 后续：CLINT 外置，平台统一路由

将 CLINT 移到 `vsrc/top.v`，平台只实例化一个三路 XBAR，目标为 MEM、UART、CLINT。
删除 `npc_core.v` 内的 XBAR、CLINT 及设备地址/使能参数，仲裁器直接连接外部 AXI 主端口。
设备窗口统一由平台决定，只有 MEM 可执行；未命中或访问禁用设备时返回 DECERR。

core 仍保留 PMEM_BASE/SIZE，用于 LSU 跨字访问检查及 difftest 的 MMIO 分类。
`test/sta_cpu/top.v` 已同步删除设备参数，只包装核与仲裁器，排除所有平台外设。
该包装通过独立 lint 和 Yosys hierarchy/proc/check 检查。
其寄存器间时序与包含外设的完整 `top` 是两种口径，独立核的 AXI 接口时序还需边界约束。

CLINT 的时钟、复位及 mtime 快照逻辑沿用原实现。集成测试补齐并验证：

- 启用 CLINT 时，先读 HI 再读 LO；重复 LO 保持快照，下一次 HI 刷新后的时间递增。
- CLINT 写入返回 SLVERR，对 CLINT 取指返回 DECERR。
- 通过完整 Kconfig 禁用 HAS_TIMER 后，对该窗口的读写返回 DECERR。
- UART、ecall/mret、未映射访问、非法访问宽度、跨界写等原有检查继续通过。

`tests/axi_soc_smoke.py` 已修正 CLINT 接入前遗留的“RTC 未映射”预期，
增加 `--diff` 和 `--timer-disabled`；Makefile 的 `SOC_TEST_ARGS` 可传递这些参数。
启用/禁用各 12 个用例均通过。

当前正式配置关闭随机延迟和 Difftest，迁移未修改这些用户设置。
回归使用独立配置副本启用随机延迟、Difftest，35 项 CPU 测试全部 PASS，
日志逐项确认 Differential testing: ON，所有性能计数检查无 MISMATCH。
无随机延迟的精确取指和 LSU 周期断言也通过。

同一 microbench test 镜像的迁移前后结果完全一致：

| 配置 | 动态指令数（前后相同） | 周期数（前后相同） |
|---|---:|---:|
| 无随机延迟 | 539020 | 3439614 |
| 有随机延迟 | 540331 | 9758767 |

这次删除的 XBAR 已经是组合译码，因此没有再省固定周期。

完整 `top` 在相同综合口径下复测：

| 指标 | CLINT 外置前 | CLINT 外置后 |
|---|---:|---:|
| Setup Fmax 区间 | 410.256–411.576 MHz | 400.000–401.254 MHz |
| 标准单元面积 | 297504.774 µm² | 302285.592 µm² |
| 各次试验 hold 检查 | 通过 | 通过 |

按通过边界比较，Fmax 下界下降 2.5%，面积增加 1.607%。互连拓扑和映射发生变化，
本次外置并未取得完整系统的时序/面积收益。此表仍包含 4 KiB 触发器 MEM、UART、CLINT，
不能当作纯 CPU 核的指标，也没有通过排除 CLINT 来制造面积下降。

基线复用上节已完成的 STA：迁移前核对了 RTL 和流程 SHA256，均未改变；
用户仅修改了仿真调试配置。该 STA 流程只读取 RVE 选择并强制 RANDOM_DELAY=0，
两次的综合口径均为 RV32E、4 KiB MEM、Nangate45 typical、2 ns 映射目标、
扇出 8、周期搜索精度 0.01 ns。新一轮对冻结源码重新综合和二分，
结果的输入哈希已与迁移后的工作区核对。

数据和证据：[comparison.json](../build/clint-platform/comparison.json)、
[迁移前 STA](../build/clint-platform/sta-before.json)、
[迁移后 STA](../build/clint-platform/sta-after/result.json)。
`build/clint-platform/` 另有两种负载日志、启用/禁用设备的用例输出、CPU 回归日志和独立核综合检查日志。

```sh
make -C npc/tests soc-test
make -C npc/tests soc-test SOC_TEST_ARGS="--diff $NEMU_HOME/build/riscv32-nemu-interpreter-so"
# 使用 HAS_TIMER 关闭且已经构建好的验证程序：
python3 npc/tests/axi_soc_smoke.py --npc /path/to/no-timer-npc --timer-disabled
```

传入 `--diff` 的程序需要在构建时启用 CONFIG_DIFFTEST；默认测试不强制更改用户配置。
