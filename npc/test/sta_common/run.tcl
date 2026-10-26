# 参数化 iSTA 运行脚本。
# 环境变量：STA_BUILD_DIR, SYNTH_TOP, STA_PERIOD_NS, STA_SDC, STA_OUT_DIR
set build_dir [file normalize $::env(STA_BUILD_DIR)]
set top       $::env(SYNTH_TOP)
set period_ns $::env(STA_PERIOD_NS)
set sdc       $::env(STA_SDC)

if {![string is double -strict $period_ns] || $period_ns <= 0} {
    error "STA_PERIOD_NS must be positive"
}

set out_dir "$build_dir/sta/T${period_ns}ns"
if {[info exists ::env(STA_OUT_DIR)]} { set out_dir $::env(STA_OUT_DIR) }
file mkdir $out_dir
set_design_workspace $out_dir

puts "Period: $period_ns ns; frequency: [expr {1000.0 / $period_ns}] MHz"
read_netlist "$build_dir/sta/top_nangate45_sta.v"
read_liberty "$build_dir/synth/nangate45.lib"
link_design $top
read_sdc $sdc
report_timing -max_path 5
exit
