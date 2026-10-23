# 2026-10-23：NPC 从 RTL 综合到关键路径分析

这次练习的目标是：把 `top.v` 下的完整 NPC（包括用触发器实现的 MEM）映射到
Nangate45 标准单元，再分析时序、估计 setup Fmax、把综合指标与仿真指标配对记录。
本机 `yosys-sta` 实际调用 iEDA 的 iSTA；它与 OpenSTA 的 Tcl 命令不能直接混用。

## 1. 现在如何复现

已经有 `NPC_HOME` 环境变量，默认 shell 为 fish：

```sh
make -C "$NPC_HOME" sta
make -C "$NPC_HOME" perf DESC="本轮结构变化及预期影响"
```

第一条只测综合/时序；第二条先仿真，再自动调用第一条，全部成功才追加
`npc/docs/perf-log.md`。正式 `perf` 保留源码工作区检查，当前改动须由使用者提交后测量。

默认综合参数：4096 B MEM、随机延迟关闭、2 ns 映射目标、ABC 扇出目标 8，
时序搜索从 2 ns 开始，周期区间收敛到 0.01 ns 以内。

```sh
make -C "$NPC_HOME" sta STA_MEM_BYTES=8192 STA_TOLERANCE_NS=0.005
```

`STA_TARGET_NS` 改变综合时的选门/尺寸优化目标；`STA_START_NS` 只改变搜索起点。
二分过程中保持网表固定，不能每改一次时钟周期就重新综合，否则测到的是不同电路。

## 2. 综合前先明确硬件到底是什么

Verilog 参数是硬件规模/行为的配置入口。例如顶层的 `PMEM_SIZE` 通过实例参数传给
MEM，并不意味着仿真默认的整个内存窗口都必须在这次综合中实现。

MEM 的 32 位存储阵列深度为 `PMEM_SIZE / 4`：

| 容量 | 32 位字数 | 存储位数 |
|---|---:|---:|
| 4096 B | 1024 | 32768 |
| 128 MiB | 33554432 | 1073741824 |

触发器实现除了存储位，还需要读地址选择和写使能逻辑，因此容量对面积、扇出和运行
时间影响很大。4 KiB 是本轮教学综合口径；仿真仍使用 `.config` 配置的内存窗口。
MEM 阵列没有为综合额外增加整块复位或初始化。

GPR 的 16/32 个寄存器由 `CONFIG_RVE` 决定；不能仅看 `CONFIG_ISA="RV32E"` 这个名字。
综合时寄存器组实现与 IDU 的 `CONFIG_RVE` 宏要一起选择，避免两部分不一致。

## 3. SYNTHESIS 与 DPI-C 排除

DPI-C 是仿真器调用 C/C++ 的接口，不会变成标准单元。综合输入必须排除相关声明和调用：

```verilog
`ifndef SYNTHESIS
  // import "DPI-C" ...;
  // pmem_read(...); pmem_write(...);
`endif
```

综合脚本显式传入 `-D SYNTHESIS`。只屏蔽 DPI 后让 MEM 读零、写入无效，虽可能综合通过，
却并没有实现存储器，所以 SYNTHESIS 分支需要真正的存储阵列和读写逻辑。
`read_verilog -ppdump` 把预处理结果写到日志，驱动脚本检查其中没有 DPI-C 或 `pmem_*` 调用。

另一个综合问题是跨模块访问，例如 `csr1.mstatus`。调试输出改成 CSR 的显式端口连接，
让综合工具能够沿正常模块接口分析信号。

## 4. 读取与 hierarchy 展开：先把设计看完整

维护脚本：`scripts/sta/read.tcl`。

1. 读取 `.config`，选择 GPR 和宏。
2. `read_verilog -sv -defer -D SYNTHESIS ...` 读取全部 RTL。
3. `hierarchy -simcheck -top top -chparam PMEM_SIZE ... -chparam RANDOM_DELAY 0`，
   从 top 展开实例和参数，检查缺失模块。
4. 保存 `build/synth/hierarchy.txt` 与 `elaborated.il`，供检查展开后的结构。

日志中的 `Used module` 与 `Removing unused module` 要看完整名字：

- `$abstract\MEM` 是延迟处理的模块模板。
- `$paramod$...\MEM` 是按某组参数生成的具体实现。
- 实际实例引用了具体实现后，原模板没有实例使用，被删除是正常现象。

因此，同一个模块后缀同时出现在“使用”和“删除”列表，不代表电路被错误删除。

`verilog_defaults` 的作用域也很关键。之前的 `-defer` 泄漏到 techmap 的内部模板读取，
导致 `$alu`、`$shl`、`$shr`、`$sshr` 没有分解。现在保存、清空、恢复前端默认参数，
避免影响内部技术映射。

## 5. 通用综合与 Nangate45 映射

维护脚本：`scripts/sta/synth.tcl`。

```yosys
read_liberty -lib build/synth/nangate45.lib
synth -top top -flatten -noabc
dfflibmap -liberty build/synth/nangate45.lib
abc -liberty build/synth/nangate45.lib ...
clean
hierarchy -check -top top
check -mapped -assert
stat -liberty build/synth/nangate45.lib
```

- Liberty 描述标准单元的逻辑、面积和时序；`read_liberty -lib` 先载入这些库单元定义。
- `synth` 把行为描述变成通用电路，其中 `memory_map` 将存储阵列展开成触发器和选择逻辑。
- `-flatten` 合并整个模块层次到 top；`-noabc` 把组合映射留给后续显式配置的 ABC。
- `dfflibmap` 选择库中的触发器；ABC 映射触发器之间的组合网络。
- `$scopeinfo` 是展开前层次的元数据，本流程只删除该类元数据，不删除未映射的真实电路。
- `check -mapped -assert` 拦住残留内部单元和连接问题。

库文件默认使用 `build/synth/nangate45.lib`；首次缺失时从
`~/software/yosys-sta/pdk/nangate45/lib/Nangate45_typ.lib` 复制。也可以通过
`STA_LIBERTY=/完整路径/库.lib` 明确指定。必须保证网表单元与分析使用的库一致。

### 为什么加缓冲、调整驱动强度

最初 MEM 地址寄存器的扇出达到数千甚至上万，导致负载和转换时间远超库表范围。
出现过一个反相器延迟约 1601 ns、hold 到达时间为巨大负值的结果。
这些异常首先指向负载和延迟模型外推，不能直接解释为“CPU 只能运行几百 kHz”。

当前 ABC 脚本使用 `buffer -p -N 8 -S 100`，以及 upsize/dnsize 后的再次缓冲：

- `-p` 让 ABC 对主输入也插入缓冲。寄存器已映射后，其 Q 就是 ABC 组合网络的主输入，
  所以这个选项会影响 MEM 地址寄存器能否得到缓冲。
- `-N 8` 是扇出目标，`-S 100` 是 100 ps 转换时间目标。
- 缩小单元可能重新引入电气违例，因此之后再缓冲。
- 弱驱动 `NOR4_X1` 的最大负载约 10 fF，实验中仍有违例，故只禁用该型号。
- ABC 的 `-D` 使用 ps；脚本将 ns 映射周期乘 1000。
- 本机 `help abc` 规定边界 `set_load 1.6` 单位为 fF，不能照搬旧注释误读成 pF。

## 6. 哪一步看面积

完成 `dfflibmap` 和 ABC 之后，查看 `build/synth/stat.txt` 的 `Chip area`。
这是 Liberty 中标准单元面积的总和，不能用映射前的抽象逻辑数量来代替。

为了兼容旧 iSTA，后续整理网表时增加了 LOGIC0/LOGIC1 常量单元：

- `build/synth/stat.txt`：整理前标准单元面积。
- `build/sta/netlist_stat.txt`：实际送入 STA 的网表面积，性能台账采用此值。

今天对话中的网表两者分别为 **313061.784 µm²** 和 **313062.848 µm²**，差值
1.064 µm² 来自两个常量单元。它们是课堂测量参考，不能回填到其他 commit 的历史行。
这不是包含布局留白、布线及物理实现开销的最终芯片面积。

## 7. 旧 iSTA 为什么读不进 Yosys 的合法网表

维护脚本：`scripts/sta/prepare.tcl`。

遇到过两类报错：

1. `wire signed [31:0] \xbar1.decode$func$...` 触发旧 Verilog 解析器 panic。
2. `assign debug_marchid_31_ = 1'b0 is not processed` 触发链接器中止。

处理方式是对已映射网表进行结构整理：

```yosys
opt_clean -purge
splitnets -format __v -ports
rename -unescape
opt_clean -purge
hilomap -singleton -hicell LOGIC1_X1 Z -locell LOGIC0_X1 Z
```

清理无用别名、把总线拆成标量、整理标识符、把字面常量变成库单元。
输出为 `build/sta/top_nangate45_sta.v`。这里不需要修改 RTL 的算法，
也不使用 `setundef -zero` 改写未定义行为。

## 8. STA 输入各自负责什么

维护脚本：`scripts/sta/run.tcl` 和 `top.sdc`。

| 输入 | 作用 |
|---|---|
| 映射后网表 | 哪些单元、哪些引脚相连 |
| Nangate45 Liberty | 单元延迟、setup/hold、电容和转换时间限制 |
| SDC | 时钟周期、时钟转换时间和路径例外 |

当前约束：一个 `core_clock`，时钟口 `clk`，50 ps 时钟转换时间，排除 `rst_n` 路径。
没有 SPEF、布局或时钟树；外部输入/输出预算和复位释放检查不在本次口径内。

本机 iSTA 在理想时钟下仍把寄存器 CK 转换时间显示为 0，存在低于表下限的警告，
所以结果需保留“当前工具、理想时钟、typical 角、无 SPEF”的限定。

## 9. 从 500 MHz 二分到 Fmax

频率与周期的换算：`f(MHz) = 1000 / T(ns)`，所以 500 MHz 对应 2 ns。

同一时钟、单周期寄存器路径可近似写为：

```text
Tclk >= Tclock-to-Q + Tcomb + Tsetup
setup slack = required time - arrival time
```

先用 2 ns 看负 slack，再增大周期直到通过，最后在失败与通过周期间二分。
短周期失败边界给出频率上界，长周期通过边界给出频率下界。

报告有舍入，`-0.000` 不能当作可靠通过。本流程要求 setup slack 至少 +0.001 ns。
hold 单独检查，放慢时钟通常不能修复 hold；电容/转换时间违例则会直接终止搜索。
搜索前后校验网表、Liberty、SDC 的 SHA256，防止混用不同输入。

今天用户得到的参考区间是 **358.543..359.551 MHz**：

| 边界 | 周期 | 报告 setup slack |
|---|---:|---:|
| 通过 | 2.7890625 ns | +0.008 ns |
| 失败 | 2.78125 ns | 显示 -0.000 ns，不满足 +1 ps 规则 |

因此它是有精度范围的 setup Fmax 估计，不是一个无限精确的频率值。

## 10. 报告在哪里，怎样读

每次分析都生成 `build/sta/runs/<时间>-T<周期>ns/`：

| 文件 | 内容 |
|---|---|
| `top.rpt` | setup/hold 汇总、逐级路径延迟、时序要求与 slack |
| `top.cap` / `top.trans` | 电容 / 转换时间检查 |
| `sta.log` | 读取、链接、约束和分析日志 |
| `summary.json` | 便于程序读取的本次结果 |
| `build/sta/fmax.json` | 完整二分边界和试探历史 |
| `build/sta/result.json` | 本次完整流程成功结果：频率、面积、输入身份和报告路径 |

`top.rpt` 第一张表的 `max` 是 setup、`min` 是 hold。在 max 中找最小 Slack，
即 setup WNS；如果所有路径都通过，最小正裕量路径仍是关键路径。
当前报告只列出工具选出的少量最差路径，并没有枚举全设计所有路径。

逐级表的 `Incr` 是本级增量延迟，`Path` 是累计到达时间；单位是 ns。
同一个单元的输入行和输出行属于同一门的时序弧，不应当作两级门。
数据到达终点 D 后，表格还会列捕获时钟、setup 和 required time，不能把这些行继续
加进数据组合路径的延迟。

## 11. 从报告追到 NPC 的 RTL

今天参考报告的第一条路径为 `_254079_:Q` 到 `_252635_:D`。冒号前是实例名，
冒号后是引脚名。先在整理前网表中找实例，更容易看到原始层次信号名：

```fish
cd "$NPC_HOME"
set net build/synth/top_nangate45.v
rg -n -A 7 'DFFR_X1 (_254079_|_252635_) ' "$net"
```

起点 Q 接 `\ifu1.inst [25]`；终点 D 接 `_001695_`，其 Q 接 `\wbu1.pc [25]`。
于是已确认：指令寄存器 inst[25] 经组合逻辑影响下一拍 PC[25]。
识别终点保存什么值要看该寄存器的 Q；D 是新值输入，未必保留 RTL 名称。

接着按报告指定的引脚逐门追：

```fish
rg -n -A 7 'OR4_X1 (_127275_|_127278_) ' "$net"
rg -n -F '_001695_' "$net"
rg -n -A 6 'MUX2_X1 (_173404_|_173405_) ' "$net"
```

第一个门 `_127275_` 的 A4 接 inst[25]，输出 `_062761_` 接下一个门 `_127278_` 的 A2。
一个网线可以有多个负载，沿报告里的下一门追踪，就能跟住这条路径。
末端经过 `_173404_` 的选择端 S，再到 `_173405_` 的数据端 B，最后到 PC 寄存器 D，
说明此路径末段涉及 PC 更新选择控制。对应阅读 WBU 的 `pc_wsel`、`pc_we`、
`diff_ifu_valid`，再沿 top 的端口连接追上游来源。

本条路径到达时间约 2.740 ns，其中 clock-to-Q 约 0.100 ns、组合约 2.640 ns，
setup 约 0.041 ns，与约 2.781 ns 的周期边界相符。
ABC 会合并、重构逻辑，门与 RTL 行不一定一一对应，不能仅凭两端名字断定中间经过哪种运算。
重新综合后实例编号可能改变，必须使用与报告配套的网表，不能照抄今天的编号。

## 12. 自动台账为什么要分别取数

仿真回答“执行这个工作负载花了多少周期”，综合/STA 回答“这一硬件在指定模型下
可以达到多高频率、用了多少标准单元面积”。两者不能互相替代。

`make perf` 的顺序是：源码检查、构建仿真器、重建/运行 train、检查完成状态、
`make sta`、核对当前输入与两份证据、归档、自动追加台账。
同 commit/同口径的重复测量不重复追加；不同结果会报错，避免把不可解释的漂移悄悄写入表。
历史参考行没有配套综合证据，面积/频率继续留空。

要维护这个流程，先看 `scripts/sta.mk` 的参数，再看 `flow.py` 的调度与校验，
最后按四个 Tcl 文件阅读各阶段；`perf_record.py` 负责数据来源、归档和台账写入。

参考：[Yosys 存储器处理](https://yosyshq.readthedocs.io/projects/yosys/en/stable/using_yosys/synthesis/memory.html)、
[Yosys 工艺映射命令](https://yosyshq.readthedocs.io/projects/yosys/en/stable/cmd/index_passes_techmap.html)。
具体命令以本机 `yosys -p 'help <命令>'`、ABC 帮助和实际工具版本为准。
