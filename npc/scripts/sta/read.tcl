# 第 1 阶段：读取 RTL 并展开完整 top 实例树。此文件由 Yosys 的 Tcl 解释器执行。
# 单独观察展开结果：yosys -p 'tcl scripts/sta/read.tcl'（在 NPC_HOME 下执行）。
yosys -import
set npc_dir [file normalize [file join [file dirname [info script]] ../..]]
cd $npc_dir
file mkdir build/synth

# PMEM_SIZE 的单位是字节；MEM 按 32 位字组织，所以必须是 4 的整数倍。
# 仅缩小综合模型，不修改 .config 中仿真使用的 128 MiB 内存窗口。
set mem_bytes 4096
if {[info exists ::env(SYNTH_MEM_BYTES)]} {
    set mem_bytes $::env(SYNTH_MEM_BYTES)
}
if {![string is integer -strict $mem_bytes] || $mem_bytes < 4 || $mem_bytes % 4 != 0} {
    error "SYNTH_MEM_BYTES must be a positive multiple of four"
}

# CONFIG_ISA 只是名字；CONFIG_RVE 才决定寄存器组/解码器，二者必须同步选择。
set cfg_fd [open .config r]
set config [read $cfg_fd]
close $cfg_fd
set rve [regexp -line {^CONFIG_RVE=y$} $config]
set isa [expr {$rve ? "rv32e" : "rv32i"}]
# 显式定义 SYNTHESIS，让 `ifndef SYNTHESIS 内的 DPI-C 声明/调用被预处理排除。
set defines [list -D SYNTHESIS]
if {$rve} { lappend defines -D CONFIG_RVE }

# 不把 MEM/UART/CLINT 当黑盒；完整读取所有可能实例化的模块。
set rtl [list vsrc/top.v vsrc/npc_core.v vsrc/IFU.v vsrc/IDU.v vsrc/EXU.v \
    vsrc/BranchUnit.v vsrc/LSU.v vsrc/WBU.v vsrc/CSR.v vsrc/MEM.v \
    vsrc/random_delay.v vsrc/AXIArbiter.v vsrc/XBAR.v vsrc/UART.v vsrc/CLINT.v \
    vsrc/gpr/$isa/GPR.v]

# -defer 延迟生成 RTLIL，hierarchy 再按实例参数生成 $paramod 专用模块。
# 保存/清空/恢复前端默认参数，防止 -defer 泄漏到后续 techmap 的内部模板读取。
verilog_defaults -push
verilog_defaults -clear
read_verilog -sv -defer -ppdump {*}$defines {*}$rtl
hierarchy -simcheck -top top -chparam PMEM_SIZE $mem_bytes -chparam RANDOM_DELAY 0
verilog_defaults -pop

# 此时可检查参数、完整实例树和 DPI 排除情况，但还不能读 Nangate45 单元面积。
tee -o build/synth/hierarchy.txt stat
write_rtlil build/synth/elaborated.il
puts "NPC synthesis profile: ISA=$isa, PMEM_SIZE=$mem_bytes bytes, RANDOM_DELAY=0"
