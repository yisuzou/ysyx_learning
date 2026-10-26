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

## 自动追踪关键路径

完整 `make sta` 成功后，自动为最终通过周期报告中最差的 5 条 setup 路径生成：

- `build/sta/critical_paths.md`：便于阅读，可点击回到原网表和 RTL 声明位置。
- `build/sta/critical_paths.json`：包含逐级单元的所有端口连接，便于进一步分析。

已有综合/STA 结果时，无需重新运行工具：

```fish
make -C "$NPC_HOME" sta-trace
make -C "$NPC_HOME" sta-trace STA_TRACE_KIND=hold STA_TRACE_LIMIT=3
make -C "$NPC_HOME" sta-trace STA_TRACE_KIND=all
```

默认读 `result.json` 中的 `passing_report`。也可以选择某次试探的报告，比如查看
2 ns 下负 slack 的路径：

```fish
make -C "$NPC_HOME" sta-trace STA_TRACE_REPORT="$NPC_HOME/build/sta/runs/<本次2ns目录>/top.rpt"
```

`STA_TRACE_KIND` 为 `setup`、`hold` 或 `all`；`STA_TRACE_LIMIT` 表示每种检查最多输出
多少条。脚本只分析报告中已有的路径，不会重新搜索未报告的路径。hold 输出为
`hold_paths.md/.json`，all 输出为 `all_paths.md/.json`。

每条路径提供起止实例/引脚、Q 保存的 RTL 信号、已验证的 RTL 声明位置、
clock-to-Q、组合段延迟、组合级数（含缓冲）、逐级 Incr/Path、扇出、较大单元延迟
及网表行号。进入 MUX 的 S 端会标注“选择控制”。捕获时钟/setup/hold 行不计入数据路径。

这只是对现有时序报告的解释：ABC 重构后的组合门不一定能一一对应到 RTL 运算。
源码 SHA256 不符时，声明位置只显示为未验证参考，不给出看似可靠的当前源码链接。

脚本先核对报告的 STA 网表 SHA256，再验证原始网表/综合 JSON 的 SHA256，
并检查每条路径在两份网表中的单元类型、引脚和连线。旧报告缺少后两个哈希时会
明确说明验证范围；历史报告对应的网表已被新综合覆盖时直接报错，不按编号硬套。

独立 Python 入口支持指定配套的历史文件及输出前缀：

```fish
python3 "$NPC_HOME/scripts/sta/trace_paths.py" --help
```

该脚本目前支持本流程的 iSTA 文本报告、Yosys `write_verilog -noexpr` 多行命名端口格式，
以及 CK 时钟寄存器间路径；不支持的格式会报错。Python 标准库即可运行，不额外调用
综合或 STA 工具。`make perf` 也会将自动生成的 setup 追踪文件保存到本轮测量证据目录。
