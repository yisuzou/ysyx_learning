# GPR 实验约束：真实时钟约束内部寄存器，读地址/读数据端口用 0 延迟
# 约束成虚拟寄存器到寄存器路径，从而分析 raddr -> rdata 的组合读延迟。
set period_ns $::env(STA_PERIOD_NS)

create_clock -name core_clock -period $period_ns [get_ports clk]
set_clock_transition 0.05 [get_clocks core_clock]
set_false_path -from [get_ports rst_n]

# 经过 prepare.tcl 的 splitnets 后，总线端口展开为 raddr1_4_ .. raddr1_0_ 等
set raddr1_ports {}
set raddr2_ports {}
set rdata1_ports {}
set rdata2_ports {}
set rdata_a0_ports {}
for {set i 0} {$i < 5} {incr i} {
    lappend raddr1_ports "raddr1_${i}_"
    lappend raddr2_ports "raddr2_${i}_"
}
for {set i 0} {$i < 32} {incr i} {
    lappend rdata1_ports "rdata1_${i}_"
    lappend rdata2_ports "rdata2_${i}_"
    lappend rdata_a0_ports "rdata_a0_${i}_"
}

# 给读地址端口一个转换时间，使内部组合路径延迟可计算
set_input_transition 0.05 [get_ports $raddr1_ports]
set_input_transition 0.05 [get_ports $raddr2_ports]

# 读地址作为虚拟触发器输出
set_input_delay  0.0 -clock core_clock [get_ports $raddr1_ports]
set_input_delay  0.0 -clock core_clock [get_ports $raddr2_ports]
# 读数据作为虚拟触发器输入
set_output_delay 0.0 -clock core_clock [get_ports $rdata1_ports]
set_output_delay 0.0 -clock core_clock [get_ports $rdata2_ports]
set_output_delay 0.0 -clock core_clock [get_ports $rdata_a0_ports]
