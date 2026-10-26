# 参数化网表整理：把 synth.tcl 输出的门级网表处理成旧版 iSTA 可读的格式。
# 环境变量：SYNTH_BUILD_DIR, SYNTH_TOP
yosys -import

set build_dir $::env(SYNTH_BUILD_DIR)
set top       $::env(SYNTH_TOP)

cd [file dirname $build_dir]
file mkdir $build_dir/sta

verilog_defaults -clear
read_liberty -lib $build_dir/synth/nangate45.lib
read_verilog $build_dir/synth/top_nangate45.v
hierarchy -check -top $top
opt_clean -purge
splitnets -format __v -ports
yosys rename -unescape
opt_clean -purge
hilomap -singleton -hicell LOGIC1_X1 Z -locell LOGIC0_X1 Z
check -mapped -assert
tee -o $build_dir/sta/netlist_stat.txt stat -liberty $build_dir/synth/nangate45.lib
write_verilog -noattr -noexpr -nohex -nodec $build_dir/sta/top_nangate45_sta.v
puts "Prepared STA netlist: $build_dir/sta/top_nangate45_sta.v"
