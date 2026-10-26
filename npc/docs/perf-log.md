# NPC 性能台账

> B4 讲义要求的性能记录（`commit 说明 仿真周期数 指令数 IPC 综合频率 综合面积 …`）。
> **每一行对应一个 commit 的一次测量。**
> 复现方法：检出对应 commit、恢复相同配置和工具版本，再执行 `make -C "$NPC_HOME" perf DESC="说明"`。
> 仿真计数应一致；综合结果按表内精度和 Fmax 搜索区间核对。综合口径不同的行不能直接比较。
> 讲义原文：*复现情况与记录严重不符且无法说明的，可能被判定为违反学术诚信。*

---

## 使用与维护指南

### 1. 记一行数据的流程

```sh
make -C "$NPC_HOME" sta                    # 可选：只测综合/时序，不写台账
make -C "$NPC_HOME" perf DESC="一句话说明本轮改动"
```

- 正式 `perf` 要求源码已经提交；脚本保留工作区检查。自动改动的本台账和 am-kernels 子模块脏状态不阻塞后续运行。
- `perf` 先构建并运行 **microbench train**，验证 PASS/GOOD TRAP；然后自动执行 `make sta`，重新综合并二分搜索 Fmax。全部成功后自动追加一行，不再手动粘贴。
- 仿真计数只读 `npc/build/perf-run.log`；频率和面积只读本次 `make sta` 成功发布的 `npc/build/sta/result.json`，并核对输入哈希及原始报告。任一阶段失败都不追加，也不拿历史值补空。
- 工具链：`npc/scripts/perf.sh`、`perf_record.py`、`scripts/sta/flow.py`；构建日志 `npc/build/perf-build.log`，运行日志 `npc/build/perf-run.log`；
- 负载固定为 **microbench train**，默认 `PERF_ARCH=riscv32-npc`；要记 E 行用 `make perf PERF_ARCH=riscv32e-npc DESC="..."`（说明列写明）；
- 超时默认 3600s，可 `make perf PERF_TIMEOUT=7200 ...` 调整；
- 每行的“证据”链接指向 `build/perf/<commit>-<内容标识>/measurement.json`，其中归档本次仿真计数、完整 STA 结果、配置、工具版本和哈希；同目录保存仿真日志、面积报告及通过边界的时序/电气报告。`build/` 被清理后需重新测量来恢复这些本地证据。
- 说明列（DESC）用于记录数字变化的原因和对应的讲义任务。

### 2. 何时记行

- **每个结构性改动记一行**：一轮时序优化、加 icache、突发传输、流水线化、转发、分支预测……
- 同一 commit、同口径、同数字反复跑不产生新行；同 commit/口径测出不同数字时脚本拒绝静默覆盖，需调查原因；
- 改配置（如开随机延迟、切 difftest、切 RVE）= 换口径 = 新行，说明列注明切换原因。

### 3. 口径铁律

只有“配置”列完全相同的行才可直接对比。仿真基线：**-O2 / rdelay=n / difftest=n / rve=n**。
综合默认口径：**Nangate45 typical / 4096 B 触发器 MEM / RANDOM_DELAY=0 / 2 ns 映射目标 / 扇出目标 8 / 周期二分精度 0.01 ns**。仿真仍使用 `.config` 的内存窗口，不能把 4 KiB 综合面积称为 128 MiB 存储器面积。

覆盖示例（参数会由 `perf` 传给它调用的 `make sta`）：

```sh
make -C "$NPC_HOME" perf DESC="8 KiB 存储器对照" STA_MEM_BYTES=8192
```
历史教训：2026-08-11 起 Makefile 被误改为 -O0（搭车提交），两个月内所有数据都在错误口径上——构建系统的改动必须单独提交、单独说明。

### 4. 复现验证（定期做）

抽查旧行：`git checkout <commit> && make -C npc perf`，逐位比对。
数字不符说明：RTL 出现非确定行为、配置漂移、或负载源码变了——必须查清才允许继续记行。

### 5. 列的维护

- **综合频率**：本次 STA 的 setup Fmax 区间，单位 MHz，下界来自最后通过的周期；是理想时钟、无 SPEF、typical 角的网表估计。hold 是否通过另记在配置 `sta_hold` 中。
- **综合面积(µm²)**：实际送入 STA 的网表标准单元面积总和，来自 `build/sta/netlist_stat.txt`，包括常量单元；整理前面积另见 `build/synth/stat.txt`。不是布局布线后的核心/芯片面积。
- 历史参考行缺少配套 STA 证据，保留 `-`；不得把今天的新网表结果回填给旧设计。
- **性能计数器列**：B4 添加计数器后在表尾追加（如 `icache缺失`、`RAW阻塞`……）；
- **只允许追加列，不允许中途改列含义**；
- 流片面积约束参考值：≤25000 µm² 硬上限，建议 ≤23000（给流水线留余量）。

### 6. 已知副作用

- `make sim` 会向 `tracer-ysyx` 分支自动提交（ysyx 惯例，勿删那行 `git_commit`）；跑完 perf 后 `git status` 有变动属正常，不影响 HEAD；
- am-kernels 子模块的脏状态不阻塞 perf（镜像由源码确定性重建），但跨机器复现时注意子模块版本；
- 配置列字段含义：`arch`（AM 构建目标）/ `rdelay`（仿真 LFSR 随机延迟）/ `difftest` / `rve`（NPC 寄存器数 16/32）；`sta_mem`、`sta_rdelay`、`sta_target`、`sta_fo`、`sta_tol` 分别记录综合内存、随机延迟、映射目标、扇出目标、搜索精度，`sta_lib`/`sta_sdc` 为输入 SHA256 前 12 位。
- 完整用法和模型限制见 [Nangate45 STA 维护说明](nangate45-sta.md)，过程解释见 [2026-10-23 学习笔记](2026-10-23-synthesis-sta-notes.md)。

---

## 数据表

| commit | 说明 | 仿真周期数 | 指令数 | IPC | 日期 | 综合频率 | 综合面积(µm²) | 配置 | 证据 |
|---|---|---|---|---|---|---|---|---|---|
| - | 【参考】E+-O0（Makefile 误为 -O0 期间的口径，10-21 已修正，无法复现仅存档） | 5099815611 | 499175406 | 0.098 | 10-20 | - | - | arch=riscv32e-npc,rdelay=n,difftest=n,rve=y | - |
| - | 【参考】E+-O2 基线，寄存器=16，E-vs-I 对照组 | 1769047163 | 196059824 | 0.111 | 10-21 | - | - | arch=riscv32e-npc,rdelay=n,difftest=n,rve=n | - |
| - | 【参考】I+-O2，寄存器=32；inst 比 E 少 5.1%、周期少 8.7%（A 阶段任务4.2 数据） | 1627559571 | 186533979 | 0.115 | 10-21 | - | - | arch=riscv32-npc,rdelay=n,difftest=n,rve=n | - |
| 72cc4c45bede | （补说明） | 1627559571 | 186533979 | 0.115 | 2026-10-26 | 407.643..408.946 MHz | 311680.180 | arch=riscv32-npc,rdelay=n,difftest=n,rve=n,sta_mem=4096B,sta_rdelay=n,sta_target=2ns,sta_fo=8,sta_tol=0.01ns,sta_lib=8d540a4d4cf6,sta_sdc=56989109b341,sta_hold=y | [JSON](../build/perf/72cc4c45bede-fb59d72cddc9/measurement.json) |

> 上面三行是**参考行**：测量当晚 Makefile 的 -O2 修改尚未提交，无法挂到 commit，故不能用
> `git checkout && make perf` 严格复现，仅作对照留档。
> **正式第一行**：待当前改动提交后，运行 `make -C "$NPC_HOME" perf DESC="..."` 自动生成
> （预期复现 I+-O2 参考行：inst=186533979，可顺带验证可复现性）。
