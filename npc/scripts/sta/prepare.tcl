# 第 3 阶段：保持映射后的电路连接，整理成旧版 iSTA 能读取的结构网表。
# 这不是重新综合；频率二分过程中也不会再次执行此步骤。
yosys -import
set npc_dir [file normalize [file join [file dirname [info script]] ../..]]
cd $npc_dir
file mkdir build/sta
verilog_defaults -clear
read_liberty -lib build/synth/nangate45.lib
read_verilog build/synth/top_nangate45.v
hierarchy -check -top top
# 清掉无用的公开别名，例如函数展开后留下的 signed 临时线；避免解析器缺陷。
opt_clean -purge
# 总线拆成标量、清理转义标识符。顶层总线端口名称随之改变，clk/rst_n 保留。
splitnets -format __v -ports
yosys rename -unescape
opt_clean -purge
# iSTA 的旧链接器不能处理部分 assign ... = 1'b0/1。
# 改用真实常量单元，不用 setundef -zero 擅自定义原 RTL 未定义的行为。
hilomap -singleton -hicell LOGIC1_X1 Z -locell LOGIC0_X1 Z
check -mapped -assert
# perf 使用此处面积，保证面积与实际分析的网表一致（含新增的常量单元）。
tee -o build/sta/netlist_stat.txt stat -liberty build/synth/nangate45.lib
write_verilog -noattr -noexpr -nohex -nodec build/sta/top_nangate45_sta.v
