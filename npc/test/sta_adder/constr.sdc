# 加法器实验约束：纯组合 top，用虚拟时钟 + 0 输入输出延迟约束输入到输出组合路径。
set period_ns $::env(STA_PERIOD_NS)

create_clock -name core_clock -period $period_ns
set_input_transition 0.05 [all_inputs]
set_input_delay  0.0 -clock core_clock [all_inputs]
set_output_delay 0.0 -clock core_clock [all_outputs]
