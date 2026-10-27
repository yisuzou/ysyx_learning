# NPC 多周期性能计数器

事件检测在 `vsrc/npc_core.v`，通过 DPI-C 的 32 位事件掩码交给
`csrc/sim/perf.cpp`。操作完成事件按次累计，状态事件每周期累计一次。
所有 RTL 检测逻辑都在 `ifndef SYNTHESIS` 内。

后续 MEM 与互连优化的逐项测量、时序对照见
[AXI 延迟优化记录](axi-latency-optimization.md)。本页下方的首轮实测表保留优化前数据。

## 运行与读取

运行 `make -C npc menuconfig`，在 `Testing and Debugging` 中切换
`Enable performance counters`（`CONFIG_PERF_COUNTERS`，默认开启），保存后重新构建。
关闭后，RTL 不生成性能事件或调用相应 DPI-C，C++ 不编译计数器实现，也不输出详细统计。
基础指令数、总周期数和单行 IPC 摘要仍然输出。

在仓库根目录、环境变量按 `AGENTS.md` 设置后运行：

```sh
make -C npc
make -C am-kernels/benchmarks/microbench ARCH=riscv32e-npc mainargs=test ARGS=-b run
```

开启性能计数器时，仿真结束自动输出：

- `PERF: class`：各类已提交指令的数量、比例和平均周期。
- `PERF: no-fetch`：没有成功接收到新指令的周期，及其原因分布。
- `PERF: lsu`：完成的 CPU 访存操作的平均延迟，分别统计 load/store。
- `PERF: check` / `PERF: cycle check`：指令数和周期数的自洽性检查。

统计排除复位和仿真退出时的额外时钟。没有样本的类别输出数量 0、平均值 0，
后者只是占位值。比例保留三位小数，极少量的 CSR/system 指令可能显示为 0.000%。

## 指令类别与周期口径

沿用原有九类：`alu/load/store/branch/jump/csr/system/lui/auipc`。
类别在成功提交时确定，避免同一条访存指令在等待期间被重复计数。

| 字段 | 定义 |
|---|---|
| `count` | 该类别成功提交的指令数 |
| `share` | `count / 全部成功提交的指令数` |
| `total_cycles` | 该类指令从开始取指到提交所占用的周期之和 |
| `exec_cycles` | 该类指令取到后，到提交所占用的周期之和；包括提交拍 |
| `avg_total` | `total_cycles / count`，包括取指 |
| `avg_exec` | `exec_cycles / count`，排除取指；访存指令包括等待 LSU |
| `avg_fetch` | `(total_cycles - exec_cycles) / count` |

当前 CPU 串行执行，一条指令占用的总周期就是从前一条提交后到本条提交的周期；
首条指令从复位释放后开始计数。C++ 先累积当前指令的周期，在提交时归入对应类别。
异常或中止前尚未提交的工作保留在 `pending` / `pending_exec`，不进入完成样本的平均值。
这种归属方式依赖当前的串行结构，流水线化时需要按指令携带或关联时间戳。

## IFU 的负事件

本报告的 `no-fetch` 定义是**本周期没有成功的取指 R 握手**，
即活跃周期内 `!(ifu_rvalid && ifu_rready && ifu_rresp == OKAY)`。
它包含正在执行当前指令的周期。

原有 `idle_cycles` 则是 `!ifu_valid`，仅覆盖当前指令尚未可用的取指阶段。
取指 R 握手成功的采样拍仍属于这个阶段，下一拍才进入 `WAIT`。
两者的区别由下面的分解明确表示：

| 原因 | 检测条件 / 含义 |
|---|---|
| `prepare` | 没有有效当前指令、没有 ARVALID/RREADY、也没有取指故障；请求准备及可能的人工延迟 |
| `ar_wait` | `ifu_arvalid && !ifu_arready`，地址尚未被下游接受 |
| `ar_accept` | AR 握手成功；本拍还没返回指令，但已取得进展 |
| `r_wait` | `ifu_rready && !ifu_rvalid`，正在期待响应 |
| `r_error` | 接收到了错误的 R 响应，未得到可执行指令 |
| `fault_hold` | IFU 保持取指故障；主机通常会在下一拍之前中止，因此可能为 0 |
| `execute` | 持有并执行非访存指令，串行结构未启动下一次取指 |
| `lsu_hold` | 持有访存指令，包括等待 LSU 及最后的 DONE 提交拍 |

上述原因互斥并覆盖所有 `no-fetch` 周期。
`share_no_fetch` 的分母是所有无新指令周期，`share_all` 的分母是所有活跃周期。
这些是周期占比，不是每条指令遭遇某事件的概率。

`prepare` 即使关闭随机延迟也有固定的请求准备拍。
`ar_wait` 包含总线状态机、仲裁、译码和下游 READY 等因素，不能仅凭它就断言有主机争用；
`r_wait` 也不能直接等同于内存芯片本身的访问时间。
`ar_accept`、正常执行和 DONE 都不是可以直接删除的“浪费”。

## LSU 延迟

延迟定义为 CPU 请求有效到 LSU 结果就绪所覆盖的周期数：
在 `lsu_request && !lsu_done` 的每个周期加一，**包括 LSU 的 IDLE 接受请求拍，
排除最后的 DONE 提交拍**。它是 CPU 侧等待时间，不是仅从 AR 握手到 R 握手的总线响应时间。

一次 CPU load/store 即一个样本，包含地址检查、发起准备、AXI 握手与响应，
也包含跨字访问拆成两笔 AXI 事务的全部时间。C++ 到 `lsu_done` 才把累计值归入
load/store 的完成样本，发生故障的未完成访问保留为 `pending_lsu`。

在当前串行结构下，成功访存指令满足：

```text
该类 exec_cycles = 该类 LSU latency_cycles + 该类完成指令数
```

其中每条指令多出来的一拍是 DONE 提交拍。

## 周期自洽性

除原有指令类别总数、取指数、提交数检查外，新增检查：

```text
采样周期数 = sim_cycle_count()
取指阶段分解之和（包括成功响应拍）= idle_cycles
idle_cycles + execute_cycles = 采样周期数
所有 no-fetch 原因之和 = 采样周期数 - 成功取指数
所有类别 total_cycles 之和 + pending = 采样周期数
所有类别 exec_cycles 之和 + pending_exec = execute_cycles
已完成 LSU 延迟之和 + pending_lsu = lsu_wait_cycles
lsu_wait_cycles + LSU 完成数 = lsu_hold_cycles
```

## 2026-10-27：microbench test 实测

这是基于 `7278cbb6cb58` 加本次工作区改动的功能与计数验证，未追加正式 STA 性能台账。
负载为 `microbench test`，RV32E、GCC 13.3.0、Verilator 5.048、Difftest 开启。
默认配置开启随机延迟，`.config` SHA256 前 12 位为 `8cf6ed9072c1`；
镜像 SHA256 为 `3d5bae785708bbc9649d8bd1ee3fa41f51ea511e36e3ca4c14b9b140b1b5d99b`。

### 指令比例与周期

默认配置：540,321 条指令，10,728,697 周期，CPI 19.856。
增加计数器前后的这两个数字完全一致，`MicroBench PASS`，所有自洽性检查均为 `OK`。
原始输出：[增加前](../build/perf-before.output)、[增加后](../build/perf-after.output)。

| 类别 | 指令数 | 占比 | 平均总周期（含取指） | 平均执行周期（不含取指） |
|---|---:|---:|---:|---:|
| ALU | 284897 | 52.727% | 16.037 | 1.000 |
| load | 65787 | 12.176% | 34.915 | 19.420 |
| store | 50072 | 9.267% | 31.626 | 16.726 |
| branch | 106334 | 19.680% | 16.188 | 1.000 |
| jump | 24081 | 4.457% | 17.160 | 1.000 |
| CSR | 2 | <0.001% | 15.000 | 1.000 |
| system | 1 | <0.001% | 15.000 | 1.000 |
| LUI | 1804 | 0.334% | 18.059 | 1.000 |
| AUIPC | 7343 | 1.359% | 15.251 | 1.000 |

非访存指令的执行阶段都是 1 拍。不同类别的平均取指周期并不相同，
因为采到的随机延迟序列与指令所在时间有关；不能据此认为某种 opcode 天生取指更慢。

### IFU 无新指令的原因

无新指令共 10,188,376 周期。下表第一种比例以这些周期为分母：

| 原因 | 周期数 | 占无新指令周期 | 占全部周期 |
|---|---:|---:|---:|
| 请求准备 / 人工发起延迟 | 2517630 | 24.711% | 23.466% |
| 等待地址被接受 | 1620963 | 15.910% | 15.109% |
| 地址接受拍 | 540321 | 5.303% | 5.036% |
| 等待指令响应 | 2969931 | 29.150% | 27.682% |
| 错误响应 / 故障保持 | 0 | 0% | 0% |
| 执行非访存指令 | 424462 | 4.166% | 3.956% |
| 访存指令占用（含 DONE） | 2115069 | 20.760% | 19.714% |

如果只问“正在取指却还没拿到”的原因，排除后两行，将分母改成
`idle_cycles - fetched = 7,648,845`：准备占 32.915%，地址等待占 21.192%，
地址接受拍占 7.064%，响应等待占 38.828%。
成功接收指令那一拍不属于负事件，但属于 `idle_cycles` 的取指阶段。

### LSU 平均访存延迟

| 类型 | 完成数（随机延迟开） | 延迟周期之和 | 平均延迟（随机延迟开） | 平均延迟（随机延迟关） |
|---|---:|---:|---:|---:|
| load | 65787 | 1211794 | 18.420 | 9.999 |
| store | 50072 | 787416 | 15.726 | 8.989 |
| 合计 | 115859 | 1999210 | 17.256 | 9.562 |

关闭随机延迟的同一镜像结果：[完整输出](../build/perf-no-delay.output)。
540,004 条指令，5,967,797 周期，CPI 11.051，取指阶段占总周期 72.389%；
随机延迟开启时取指阶段占 76.330%。两次指令数略有差异，因为 microbench 会读取
模拟时钟并格式化输出计时结果，周期数变化会影响这部分运行路径。

无随机延迟时，每条指令固定花 8 拍取指：准备 1、地址等待 3、地址接受 1、
响应等待 2、响应接受 1。其中地址等待的 3 拍来自仲裁器选择、CPU 内部 XBAR 译码、
平台 XBAR 译码，没有 IFU/LSU 同时发读请求。因此当前优化应优先关注取指路径：
即使移除人工延迟，固定的取指状态机开销仍然占大头。缓存可减少这条路径上的访问，
实际收益仍需后续缓存实现和计数验证。

无随机延迟的独立构建和复现方法（保留默认配置与默认可执行文件）：

```sh
make -C npc CONFIG_RANDOM_DELAY= OBJ_DIR=/tmp/npc-perf-no-delay-obj BINARY=/tmp/npc-perf-no-delay
/tmp/npc-perf-no-delay -b --diff="$NEMU_HOME/build/riscv32-nemu-interpreter-so" \
  am-kernels/benchmarks/microbench/build/microbench-riscv32e-npc.bin
```

## 专项回归

以下专项测试需要开启 `CONFIG_PERF_COUNTERS`。

```sh
make -C npc/tests perf-test PERF_TEST_ARGS="--diff $NEMU_HOME/build/riscv32-nemu-interpreter-so"
make -C npc/tests perf-test PERF_TEST_ARGS="--npc /tmp/npc-perf-no-delay --expect-no-delay --diff $NEMU_HOME/build/riscv32-nemu-interpreter-so --build-dir $NPC_HOME/build/perf-tests-no-delay"
```

`tests/perf_counters.py` 编译已知 RV32E 指令序列，校验全部九类的确切次数、
非访存指令执行 1 拍，以及 LSU 延迟与执行时间的边界。
首轮无随机延迟基线曾校验：取指 8 拍、对齐 load/store 执行 11/10 拍、跨字执行 19/17 拍。
后续优化后的当前断言为：取指 4 拍、对齐 load/store 执行 7/8 拍、跨字执行 11/13 拍。
另覆盖 load 故障、store 故障、取指故障和非法指令，验证未完成工作不污染平均值。
两种延迟配置均通过；35 项 cpu-tests 在随机延迟和 Difftest 开启下全部 PASS，
所有运行的计数器检查均无 `MISMATCH`。
