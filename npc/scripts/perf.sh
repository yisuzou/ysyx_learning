#!/usr/bin/env bash
# 仿真得到周期/指令/IPC，make sta 得到频率/面积，全部成功才自动追加台账。
# 用法：make -C "$NPC_HOME" perf DESC="一句话说明" [PERF_ARCH=riscv32e-npc]
# 正式记录必须对应已提交的源码；仅台账改动和 am-kernels 子模块脏状态例外。
set -euo pipefail
export LC_ALL=C

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
export NPC_HOME=${NPC_HOME:-"$repo_root/npc"}
export NEMU_HOME=${NEMU_HOME:-"$repo_root/nemu"}
export AM_HOME=${AM_HOME:-"$repo_root/abstract-machine"}
micro_dir=${AM_KERNELS_HOME:-"$repo_root/am-kernels"}/benchmarks/microbench

desc=${1:-}
arch=${2:-riscv32-npc}
timeout_s=${PERF_TIMEOUT:-3600}
python=${PYTHON:-python3}

for tool in make timeout git flock sha256sum "$python"; do
  command -v "$tool" >/dev/null || { echo "perf: missing command: $tool" >&2; exit 2; }
done
[[ -f $micro_dir/Makefile ]] || { echo "perf: microbench not found: $micro_dir" >&2; exit 2; }
[[ -f $NPC_HOME/.config ]] || { echo "perf: missing $NPC_HOME/.config (run menuconfig first)" >&2; exit 2; }
[[ -f $AM_HOME/scripts/$arch.mk ]] || { echo "perf: unknown AM arch: $arch" >&2; exit 2; }

mkdir -p "$NPC_HOME/build"
# 序列化整轮 perf，避免两次运行覆盖同名仿真日志后错误配对。
exec 9> "$NPC_HOME/build/perf.lock"
flock 9
check_clean() {
  local dirty
  dirty=$(git -C "$repo_root" status --porcelain --untracked-files=normal -- . \
    ':!am-kernels' ':!npc/docs/perf-log.md')
  if [[ -n $dirty ]]; then
    echo "perf: 工作区源码不干净，正式数据无法对应 commit；先提交或 stash：" >&2
    printf '%s\n' "$dirty" >&2
    exit 1
  fi
}
check_clean
commit=$(git -C "$NPC_HOME" rev-parse HEAD)
config_sha256=$(sha256sum "$NPC_HOME/.config")
config_sha256=${config_sha256%% *}
log=$NPC_HOME/build/perf-run.log

echo "perf: commit=$commit  workload=microbench/$arch train  (logs in npc/build/)" >&2
# 仿真器按依赖构建；工作负载单独强制重建，避免旧镜像或编译选项缓存。
make -s --no-print-directory -C "$NPC_HOME" \
  > "$NPC_HOME/build/perf-build.log" 2>&1 || {
  echo "perf: NPC build failed; log: $NPC_HOME/build/perf-build.log" >&2
  exit 1
}
make -B -s --no-print-directory -C "$micro_dir" ARCH="$arch" mainargs=train image \
  >> "$NPC_HOME/build/perf-build.log" 2>&1 || {
  echo "perf: MicroBench build failed; log: $NPC_HOME/build/perf-build.log" >&2
  exit 1
}

rc=0
timeout --kill-after=5s "${timeout_s}s" \
  make -s --no-print-directory -C "$micro_dir" ARCH="$arch" \
  mainargs=train ARGS=-b run > "$log" 2>&1 < /dev/null || rc=$?

fail() { echo "perf: $1; log: $log" >&2; exit 1; }
if (( rc == 124 || rc == 137 )); then
  fail "run timed out after ${timeout_s}s"
fi
(( rc == 0 ))                || fail "run failed (exit=$rc)"
"$python" "$NPC_HOME/scripts/perf_record.py" check "$log"

# 必须实际调用 make sta；命令行上的 STA_* / YOSYS / IEDA 由递归 Make 继承。
# set -e 保证综合/STA 失败时立即退出，不能拿上一轮 fmax.json 回填。
make --no-print-directory -C "$NPC_HOME" sta
check_clean
[[ $(git -C "$NPC_HOME" rev-parse HEAD) == "$commit" ]] || fail "HEAD changed during perf"
"$python" "$NPC_HOME/scripts/perf_record.py" record \
  --simulation-log "$log" --sta-result "$NPC_HOME/build/sta/result.json" \
  --commit "$commit" --config-sha256 "$config_sha256" --arch "$arch" --desc "$desc"
