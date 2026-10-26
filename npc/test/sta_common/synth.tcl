# 参数化综合脚本：为独立 STA 小实验生成 Nangate45 网表。
# 调用前需设置环境变量：SYNTH_TOP, SYNTH_RTL, SYNTH_BUILD_DIR,
#                       SYNTH_PERIOD_NS, SYNTH_MAX_FANOUT
yosys -import

set top       $::env(SYNTH_TOP)
set rtl_files [split $::env(SYNTH_RTL) " "]
set build_dir $::env(SYNTH_BUILD_DIR)

set target_ns  2.0
if {[info exists ::env(SYNTH_PERIOD_NS)]}  { set target_ns  $::env(SYNTH_PERIOD_NS) }
set max_fanout 8
if {[info exists ::env(SYNTH_MAX_FANOUT)]} { set max_fanout $::env(SYNTH_MAX_FANOUT) }

if {![string is double -strict $target_ns] || $target_ns <= 0} {
    error "SYNTH_PERIOD_NS must be positive"
}
if {![string is integer -strict $max_fanout] || $max_fanout < 2} {
    error "SYNTH_MAX_FANOUT must be an integer >= 2"
}
set target_ps [expr {1000.0 * $target_ns}]

# 以 build 目录的父目录作为项目根目录（即实验目录）
cd [file dirname $build_dir]
file mkdir $build_dir/synth

# ABC 边界假设
set fd [open $build_dir/synth/abc.constr w]
puts $fd "set_driving_cell BUF_X8"
puts $fd "set_load 1.6"
close $fd

set fd [open $build_dir/synth/abc.script w]
puts $fd {strash; &get -n; &fraig -x; &put; scorr; dc2; strash; &get -n; &dch -f}
puts $fd "&nf -D $target_ps; &put"
puts $fd "buffer -p -N $max_fanout -S 100; topo"
puts $fd "upsize -D $target_ps; dnsize -D $target_ps"
puts $fd "buffer -p -N $max_fanout -S 100; topo; stime -p"
close $fd

read_liberty -lib $build_dir/synth/nangate45.lib

set defines [list -D SYNTHESIS]

if {[info exists ::env(SYNTH_DEFINES)]} {
    foreach name [split $::env(SYNTH_DEFINES)] {
        if {$name ne ""} {
            lappend defines -D $name
        }
    }
}

verilog_defaults -push
verilog_defaults -clear
read_verilog -sv -defer -ppdump {*}$defines {*}$rtl_files
verilog_defaults -pop

hierarchy -check -top $top
tee -o $build_dir/synth/hierarchy.txt stat
synth -top $top -flatten -noabc
delete {t:$scopeinfo}
select -assert-none m:* {t:$mem*} {t:$alu} {t:$shl} {t:$shr} {t:$sshr}
dfflibmap -liberty $build_dir/synth/nangate45.lib
abc -liberty $build_dir/synth/nangate45.lib -dont_use NOR4_X1 \
    -constr $build_dir/synth/abc.constr \
    -D $target_ps -script $build_dir/synth/abc.script
clean
hierarchy -check -top $top
check -mapped -assert
tee -o $build_dir/synth/stat.txt stat -liberty $build_dir/synth/nangate45.lib
write_verilog -noattr -noexpr $build_dir/synth/top_nangate45.v
write_json $build_dir/synth/top_nangate45.json
puts "Synthesis complete for $top -> $build_dir/synth/top_nangate45.v"
