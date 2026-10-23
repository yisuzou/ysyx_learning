# NPC Nangate45 synthesis and iSTA

## 一条命令与性能台账

沿用 shell 中已有的 `NPC_HOME`；下面的命令均可在 fish 中执行：

```sh
make -C "$NPC_HOME" sta
make -C "$NPC_HOME" perf DESC="本轮修改的说明"
```

`sta` 是 PHONY 规则，每次从 RTL 重新综合，然后固定这份网表做时序二分。
成功后生成 `build/sta/result.json`：Fmax 区间、实际分析网表的单元面积、
通过边界报告路径、全部输入哈希和工具版本都在其中。启动时撤下旧 `result.json`，
任一阶段失败都不会发布一个看似成功的总结果。旧逐次报告保留在 `runs/`。

`perf` 先运行 microbench train，再实际调用 `make sta`，最后验证两份数据来源并
自动追加 [perf-log.md](perf-log.md)。仿真周期/指令/IPC 只能来自仿真日志；
综合面积和频率只能来自该完整 STA 结果，不从历史台账或旧 `fmax.json` 补值。
正式测量仍要求源码工作区干净，本台账自动产生的修改除外。

| Make 参数 | 默认值 | 含义 |
|---|---|---|
| `STA_MEM_BYTES` | `4096` | 综合 MEM 容量（字节，4 的倍数） |
| `STA_TARGET_NS` | `2.0` | ABC 映射目标周期；改变它会重新生成不同网表 |
| `STA_MAX_FANOUT` | `8` | ABC 缓冲扇出目标 |
| `STA_START_NS` | `2.0` | STA 二分的初始试探周期 |
| `STA_TOLERANCE_NS` | `0.01` | 通过/失败周期区间的最大宽度 |
| `STA_LIBERTY` | 留空 | 可指定 Nangate45 typical `.lib`；复制到固定构建路径 |
| `YOSYS` | `yosys` | Yosys 可执行文件 |
| `IEDA` | `~/software/yosys-sta/bin/iEDA` | 本机 iSTA 引擎 |
| `PYTHON` | `python3` | Python 解释器（需支持 `hashlib.file_digest`） |

```sh
make -C "$NPC_HOME" sta STA_MEM_BYTES=8192 STA_TOLERANCE_NS=0.005
```

参数也可传给 `perf`，其递归调用的 `make sta` 会继承。首次运行需要已配置的
`npc/.config` 及本机工具/Liberty；删除 `build/` 后无需手工重建 `.ys` 文件。
维护入口是 `scripts/sta.mk` 和 `scripts/sta/`，完整教学笔记见
[2026-10-23-synthesis-sta-notes.md](2026-10-23-synthesis-sta-notes.md)。

## 分阶段操作

The maintained scripts are in `npc/scripts/sta/`; reports and generated files
are in `npc/build/synth/` and `npc/build/sta/`. Commands below work in fish,
Bash, or other shells and can be run from any directory.

```sh
python3 npc/scripts/sta/flow.py synth
python3 npc/scripts/sta/flow.py run 2.000
python3 npc/scripts/sta/flow.py bisect --start-ns 2 --tolerance-ns 0.01
```

Paths above assume the workspace root. Synthesis defaults to **4096 bytes** of
flip-flop memory, a **2 ns** mapping target, and **8** as ABC's fanout target.
The original 128 MiB simulation window would require about one billion storage
bits when implemented as flip-flops. Override intentionally, for example:

```sh
python3 npc/scripts/sta/flow.py synth --mem-bytes 4096 --target-ns 2 --max-fanout 8
```

`CONFIG_RVE=y` in `npc/.config` selects both the RV32E GPR and decoder define;
otherwise synthesis selects RV32I. `SYNTHESIS` is explicitly defined. The whole
`top` hierarchy, including MEM, UART and CLINT, is elaborated with random delays
disabled. Verilog frontend options are scoped so that `-defer` cannot leak into
the internal technology mapping templates.

The existing `build/synth/nangate45.lib` is used; when absent, the driver copies
`~/software/yosys-sta/pdk/nangate45/lib/Nangate45_typ.lib`. `YOSYS` overrides the
Yosys executable. `IEDA` or the global `--ieda PATH` option overrides iEDA.

## Mapping and export

`synth.tcl` performs generic synthesis without ABC, removes `$scopeinfo`, and
maps flip-flops. The constrained ABC script includes `buffer -p -N 8 -S 100`,
upsizing, downsizing, and another buffering pass after downsizing. The 100 ps
slew target leaves margin to the library's approximately 199 ps limit. A fanout
target of 24 still left capacitance/slew violations in this design. The `-p`
flag matters: mapped register outputs are primary inputs
of the combinational network seen by ABC. Without it, the MEM address registers
can still directly drive thousands of loads. `set_load 1.6` is in **fF**, as
specified by the installed Yosys `help abc`; it is an ABC boundary assumption,
not a replacement for internal pin capacitances or an STA output constraint.
The weak `NOR4_X1` variant is excluded from mapping because its approximately
10 fF maximum load was still exceeded after fanout/slew buffering; stronger
variants remain available.

`prepare.tcl` splits buses, simplifies escaped identifiers, purges unused public
wires, and maps constants to `LOGIC0_X1`/`LOGIC1_X1`. This avoids older iSTA parser
and linker limitations without changing the RTL. Exported bus port names become
scalar names; `clk` and `rst_n` retain their names. The array has no added reset
or initialization. `setundef -zero` is deliberately not used.

## Analysis and Fmax

Each `run` creates a fresh timestamped directory under `build/sta/runs/`, with
`sta.log`, `top.rpt`, electrical reports and `summary.json`. `build/sta/latest.json`
points to the latest analysis via its `directory` field. Prior manual reports
such as `build/sta/T2.000ns/` are preserved.

The SDC uses one ideal `core_clock`, 50 ps clock transition, and a false path
from asynchronous reset. This experiment covers internal register-to-register
setup timing at the typical Liberty corner. External output timing, reset
release recovery/removal, extracted wire parasitics and clock-tree insertion
are outside this experiment. This is a **netlist-level setup Fmax estimate**.
The installed iEDA build reports 0.000 ns at ideal register clock pins despite
the 0.050 ns input-clock transition setting, and emits below-table-range warnings
for those zero values. Retain this tool/model qualification when quoting results;
an independent engine or a propagated-clock analysis is needed to cross-check
clock-slew behavior before using the estimate for physical timing closure.

`bisect` brackets passing/failing periods and bisects period, never resynthesizes,
and verifies that the netlist, Liberty and SDC hashes stay fixed. A pass requires
at least 1 ps of reported setup slack to avoid accepting rounded `-0.000`.
The bound and trial reports are saved in `build/sta/fmax.json`. Hold results are
reported separately: slowing the clock does not normally repair hold violations.

The search stops on reported capacitance/slew violations or negative
data arrival times, instead of reporting a misleading Fmax for an invalid delay
model. `run` still saves these diagnostics for investigation. Inspect an older
report without rerunning the tool:

```sh
python3 npc/scripts/sta/flow.py report npc/build/sta/T2.000ns
```

Optional fish convenience function (no changes to shell configuration):

```fish
source npc/scripts/sta/run_sta.fish
run_sta 2.000
```

The files under `build/` are compatibility entry points for the commands used
during the walkthrough. The maintained sources survive cleaning `build/`.
