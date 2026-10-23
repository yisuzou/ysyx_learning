# 第 2 阶段：通用综合 -> 触发器映射 -> 组合逻辑映射 -> 面积统计。
# 这里运行于 Yosys Tcl，不能直接用 iEDA 或 OpenSTA 执行。
yosys -import
set flow_dir [file dirname [info script]]
set npc_dir [file normalize [file join $flow_dir ../..]]
cd $npc_dir
file mkdir build/synth
verilog_defaults -clear
source [file join $flow_dir read.tcl]

set target_ns 2.0
if {[info exists ::env(SYNTH_PERIOD_NS)]} { set target_ns $::env(SYNTH_PERIOD_NS) }
if {![string is double -strict $target_ns] || $target_ns <= 0} {
    error "SYNTH_PERIOD_NS must be positive"
}
# SDC/命令行周期使用 ns；Yosys ABC -D 使用 ps，必须显式换算。
set target_ps [expr {1000.0 * $target_ns}]
set max_fanout 8
if {[info exists ::env(SYNTH_MAX_FANOUT)]} { set max_fanout $::env(SYNTH_MAX_FANOUT) }
if {![string is integer -strict $max_fanout] || $max_fanout < 2} {
    error "SYNTH_MAX_FANOUT must be an integer >= 2"
}

# ABC 的边界驱动/负载假设；本机 help abc 规定 set_load 单位为 fF。
# 它不替代 STA 中根据真实连接计算的内部引脚负载。
set fd [open build/synth/abc.constr w]
puts $fd "set_driving_cell BUF_X8"
puts $fd "set_load 1.6"
close $fd

# 参考 yosys-sta 的 buffer/upsize/dnsize 流程，并增加寄存器输出端缓冲。
# -p 很关键：ABC 只看到组合网络，已经映射的寄存器 Q 被视为其主输入。
# 缺少 -p 时，MEM 地址寄存器仍可能直接驱动数千个负载。
set fd [open build/synth/abc.script w]
puts $fd {strash; &get -n; &fraig -x; &put; scorr; dc2; strash; &get -n; &dch -f}
puts $fd "&nf -D $target_ps; &put"
puts $fd "buffer -p -N $max_fanout -S 100; topo"
puts $fd "upsize -D $target_ps; dnsize -D $target_ps"
# 缩小单元尺寸后可能重新出现电气违例，再缓冲一次。-S 100 是 100 ps slew 目标。
puts $fd "buffer -p -N $max_fanout -S 100; topo; stime -p"
close $fd

read_liberty -lib build/synth/nangate45.lib
# synth 内含 memory_map：存储阵列展开为触发器、读选择器和写使能逻辑。
# -flatten 合并实例层次；-noabc 留待下面使用真正的 Nangate45 库映射。
synth -top top -flatten -noabc
# $scopeinfo 只保存展开前层次信息，不是电路；只删除这类元数据。
delete {t:$scopeinfo}
# memory/算术/移位高级单元必须已被分解，不能带着它们冒充完成标准单元映射。
select -assert-none m:* {t:$mem*} {t:$alu} {t:$shl} {t:$shr} {t:$sshr}
# 先映射时序单元，再把其间组合网络交给 ABC。
dfflibmap -liberty build/synth/nangate45.lib
# NOR4_X1 最大负载约 10 fF，实验中缓冲后仍有电容违例；禁用该弱驱动型号。
abc -liberty build/synth/nangate45.lib -dont_use NOR4_X1 -constr build/synth/abc.constr \
    -D $target_ps -script build/synth/abc.script
clean
hierarchy -check -top top
check -mapped -assert
# stat 使用 Liberty 的单元面积，不能用映射前的抽象单元数量估算面积。
tee -o build/synth/stat.txt stat -liberty build/synth/nangate45.lib
write_verilog -noattr -noexpr build/synth/top_nangate45.v
write_json build/synth/top_nangate45.json
