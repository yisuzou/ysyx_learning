# fish 可选快捷函数：source "$NPC_HOME/scripts/sta/run_sta.fish"
# 只分析已经综合好的网表；完整重建请用 make -C "$NPC_HOME" sta。
set -l sta_flow_dir (dirname (status filename))
set -l sta_flow_py (path resolve "$sta_flow_dir/flow.py")
function run_sta --inherit-variable sta_flow_py --description 'Analyze NPC at a period in ns'
    python3 "$sta_flow_py" run $argv
end
