# 单时钟、内部寄存器到寄存器的 setup 实验；周期单位为 ns。
# 不设置外部输入/输出延迟，因此不要把结果当作芯片接口时序已经收敛。
create_clock -name core_clock -period $::env(STA_PERIOD_NS) [get_ports clk]
# 50 ps 时钟转换时间。当前 iSTA 的理想时钟 CK 仍显示 0，限制详见维护文档。
set_clock_transition 0.05 [get_clocks core_clock]
# 这里排除异步复位路径；复位释放的 recovery/removal 不属于本轮 Fmax 口径。
set_false_path -from [get_ports rst_n]
