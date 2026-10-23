# 第 4 阶段：用 iEDA 内的 iSTA 分析一次指定时钟周期。
# 各工具的 Tcl 命令并不通用：本文件不是 Yosys/OpenSTA 脚本。
set flow_dir [file normalize [file dirname [info script]]]
set npc_dir [file normalize [file join $flow_dir ../..]]
set period_ns $::env(STA_PERIOD_NS)
if {![string is double -strict $period_ns] || $period_ns <= 0} {
    error "STA_PERIOD_NS must be positive"
}
# Python 调度器每次传入一个新目录，避免旧报告被误认为本次分析结果。
set out_dir "$npc_dir/build/sta/T${period_ns}ns"
if {[info exists ::env(STA_OUT_DIR)]} { set out_dir $::env(STA_OUT_DIR) }
file mkdir $out_dir
set_design_workspace $out_dir
puts "Period: $period_ns ns; frequency: [expr {1000.0 / $period_ns}] MHz"
# 网表给连接，Liberty 给各门延迟/时序检查，SDC 给时钟和分析边界。
read_netlist "$npc_dir/build/sta/top_nangate45_sta.v"
read_liberty "$npc_dir/build/synth/nangate45.lib"
link_design top
read_sdc [file join $flow_dir top.sdc]
# 当前只有一个时钟组；报告包括最差的 5 条 max/setup 和 5 条 min/hold 路径。
# top.rpt 保存逐级延迟，top.cap/top.trans 用于检查电容和转换时间违例。
report_timing -max_path 5
exit
