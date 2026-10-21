#!/usr/bin/env bash
# Run AM correctness tests through the normal NPC build/run targets.
set -euo pipefail
export LC_ALL=C

usage() {
  cat <<'EOF'
Usage: npc/scripts/regress.sh [OPTIONS]

Run every cpu-test and MicroBench/train on ARCH=riscv32e-npc. Print PASS/FAIL and
simulated cycles for each image, save logs and summary.tsv, and exit nonzero
if any build, run, timeout, or result check fails.

Options:
  --cpu-tests LIST    Space-separated cpu-test names (default: all)
  --timeout SECONDS  Time limit for each build/run (default: 1800)
  --log-dir DIR      Output directory (default: new npc/build/regress-* dir)
  -h, --help         Show this help

Examples:
  npc/scripts/regress.sh
  npc/scripts/regress.sh --cpu-tests 'add dummy unalign'
  npc/scripts/regress.sh --timeout 3600

AM_HOME, NPC_HOME, NEMU_HOME, and AM_KERNELS_HOME default to workspace paths.
Cycles exclude reset and simulator shutdown; unavailable counts show '-'.
EOF
}

die() {
  printf 'regress: %s\n' "$*" >&2
  exit 2
}

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
export NPC_HOME=${NPC_HOME:-"$repo_root/npc"}
export NEMU_HOME=${NEMU_HOME:-"$repo_root/nemu"}
export AM_HOME=${AM_HOME:-"$repo_root/abstract-machine"}
kernel_dir=${AM_KERNELS_HOME:-"$repo_root/am-kernels"}
cpu_dir=$kernel_dir/tests/cpu-tests
micro_dir=$kernel_dir/benchmarks/microbench
cpu_selection=all
case_timeout=1800
log_dir=

while (( $# > 0 )); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --cpu-tests|--timeout|--log-dir)
      (( $# >= 2 )) && [[ -n $2 ]] || die "$1 requires a value"
      case "$1" in
        --cpu-tests) cpu_selection=$2 ;;
        --timeout) case_timeout=$2 ;;
        --log-dir) log_dir=$2 ;;
      esac
      shift 2
      ;;
    *) die "unknown option: $1 (use --help)" ;;
  esac
done

[[ $case_timeout =~ ^[1-9][0-9]*$ ]] || die '--timeout must be a positive integer'
for tool in make timeout awk; do
  command -v "$tool" >/dev/null || die "required command not found: $tool"
done
[[ -f $NPC_HOME/.config ]] || die "missing $NPC_HOME/.config; run make -C npc defconfig first"
[[ -f $AM_HOME/scripts/riscv32e-npc.mk ]] || die "invalid AM_HOME: $AM_HOME"
[[ -f $cpu_dir/Makefile && -f $micro_dir/Makefile ]] || die "cpu-tests/microbench not found in $kernel_dir"

cpu_tests=()
if [[ $cpu_selection == all ]]; then
  shopt -s nullglob
  for source in "$cpu_dir"/tests/*.c; do
    name=${source##*/}
    cpu_tests+=("${name%.c}")
  done
else
  read -r -a cpu_tests <<< "$cpu_selection"
fi
(( ${#cpu_tests[@]} > 0 )) || die 'no cpu-tests selected/found'
for name in "${cpu_tests[@]}"; do
  [[ $name =~ ^[a-zA-Z0-9_-]+$ && -f $cpu_dir/tests/$name.c ]] || die "unknown cpu-test: $name"
done

if [[ -z $log_dir ]]; then
  mkdir -p -- "$NPC_HOME/build"
  log_dir=$(mktemp -d "$NPC_HOME/build/regress-XXXXXXXX")
else
  mkdir -p -- "$log_dir"
  log_dir=$(cd -- "$log_dir" && pwd)
fi
summary=$log_dir/summary.tsv
printf 'case\tstatus\tcycles\n' > "$summary"
printf 'ARCH=riscv32e-npc  MicroBench=train  timeout=%ss\nLogs: %s\n\n' \
  "$case_timeout" "$log_dir"
trap 'exit 130' INT
trap 'exit 143' TERM

# Build once up front; individual AM run targets still use NPC's normal sim
# target, including its configured difftest/FTRACE and git_commit tracer.
if timeout --kill-after=5s "${case_timeout}s" \
    make -s --no-print-directory -C "$NPC_HOME" \
    > "$log_dir/npc-build.log" 2>&1 < /dev/null; then
  :
else
  rc=$?
  printf 'npc-build FAIL (exit=%s); see %s\n' "$rc" "$log_dir/npc-build.log" >&2
  printf 'npc-build\tFAIL\t-\n' >> "$summary"
  exit 1
fi

passed=0
failed=0
printf '%-30s %-6s %16s\n' CASE RESULT CYCLES

run_case() {
  local label=$1 log_name=$2
  shift 2
  local log=$log_dir/$log_name.log rc=0 cycles good bad micro_pass status reason
  if timeout --kill-after=5s "${case_timeout}s" "$@" > "$log" 2>&1 < /dev/null; then
    :
  else
    rc=$?
  fi
  # The cpu-tests aggregator returns success even when its recursive make
  # fails. Require both a successful process and NPC's actual GOOD TRAP.
  read -r cycles good bad micro_pass < <(awk '
    { gsub(/\033\[[0-9;]*m/, "") }
    /npc: HIT GOOD TRAP/ { good = 1 }
    /npc: (HIT BAD TRAP|ABORT)/ { bad = 1 }
    /MicroBench PASS/ { micro_pass = 1 }
    /total guest cycles = [0-9]+/ {
      sub(/^.*total guest cycles = /, "")
      sub(/[^0-9].*$/, "")
      cycles = $0
    }
    END { printf "%s %d %d %d\n", cycles == "" ? "-" : cycles, good, bad, micro_pass }
  ' "$log")

  status=FAIL
  reason=
  if (( rc == 124 || rc == 137 )); then
    reason="timeout after ${case_timeout}s"
  elif (( rc != 0 )); then
    reason="exit=$rc"
  elif (( good == 0 || bad != 0 )); then
    reason='missing GOOD TRAP or observed BAD TRAP/ABORT'
  elif [[ $cycles == - ]]; then
    reason='missing cycle count'
  elif [[ $log_name == microbench && $micro_pass == 0 ]]; then
    reason='missing MicroBench PASS'
  else
    status=PASS
  fi
  printf '%-30s %-6s %16s\n' "$label" "$status" "$cycles"
  printf '%s\t%s\t%s\n' "$label" "$status" "$cycles" >> "$summary"
  if [[ $status == PASS ]]; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
    printf '  %s; log: %s\n' "$reason" "$log"
  fi
}

for name in "${cpu_tests[@]}"; do
  run_case "cpu-tests/$name" "cpu-$name" \
    make -s --no-print-directory -C "$cpu_dir" ARCH=riscv32e-npc \
    "ALL=$name" ARGS=-b run
done
run_case microbench/train microbench \
  make -s --no-print-directory -C "$micro_dir" ARCH=riscv32e-npc \
  mainargs=train ARGS=-b run

printf '\nPASS: %d  FAIL: %d  TOTAL: %d\nSummary: %s\n' \
  "$passed" "$failed" "$((passed + failed))" "$summary"
(( failed == 0 ))
