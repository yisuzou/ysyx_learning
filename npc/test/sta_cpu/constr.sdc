set period_ns $::env(STA_PERIOD_NS)

create_clock -name core_clock \
    -period $period_ns [get_ports clk]

set_clock_transition 0.05 [get_clocks core_clock]
set_false_path -from [get_ports rst_n]
