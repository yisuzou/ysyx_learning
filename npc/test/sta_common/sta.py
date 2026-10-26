#!/usr/bin/env python3
"""轻量 STA 调度器：为独立小实验做综合 + iSTA 单次分析 + Fmax 二分。

用法：
    sta.py all     --top TOP --rtl "f1.v f2.v" --sdc top.sdc --build-dir build
    sta.py synth   --top TOP --rtl "f1.v f2.v" --build-dir build
    sta.py run     --period-ns 2.0 --build-dir build
    sta.py bisect  --sdc top.sdc --build-dir build
"""
import argparse
import datetime
import json
import math
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

NUMBER = re.compile(r"[-+]?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?")
ANSI = re.compile(r"\x1b\[[0-9;]*m")


def positive(value):
    result = float(value)
    if not math.isfinite(result) or result <= 0:
        raise argparse.ArgumentTypeError("must be a finite positive number")
    return result


def run(cmd, log, cwd=None, env=None, timeout=1800):
    log = Path(log)
    log.parent.mkdir(parents=True, exist_ok=True)
    print(f"  -> {' '.join(str(c) for c in cmd)}  (log: {log})", flush=True)
    with log.open("w") as fh:
        result = subprocess.run(cmd, cwd=cwd, env=env, stdout=fh,
                                stderr=subprocess.STDOUT, timeout=timeout)
    text = ANSI.sub("", log.read_text(errors="replace"))
    if result.returncode:
        raise RuntimeError(f"command exited {result.returncode}; see {log}\n{text[:500]}")
    if re.search(r"(^|\n)(?:ERROR:|.*(?:FATAL|Check failed|invalid command name))", text):
        raise RuntimeError(f"tool reported an error; see {log}\n{text[:500]}")
    return text


def report_summary(directory):
    """分别提取 setup/hold 最差裕量，并检查该延迟模型的电气有效性.

    top.rpt 的第一张表同时有 max/setup 和 min/hold，不能把两类 Slack 混取。
    top.cap / top.trans 的裕量为负时，二分时钟周期不能修复这些电气违例。
    """
    directory = Path(directory)
    report = (directory / "top.rpt").read_text()
    rows = {"max": [], "min": []}
    for line in report.splitlines():
        fields = [field.strip() for field in line.split("|")[1:-1]]
        if len(fields) == 8 and fields[1] == "core_clock" and fields[2] in rows:
            delay = float(fields[3].rstrip("rf"))
            slack = float(fields[6])
            if not all(math.isfinite(value) for value in (delay, slack)):
                raise RuntimeError("non-finite timing result")
            rows[fields[2]].append((slack, delay, fields[0]))
    if not rows["max"] or not rows["min"]:
        raise RuntimeError(f"missing constrained setup/hold paths in {directory / 'top.rpt'}")
    setup, hold = min(rows["max"]), min(rows["min"])
    problems = []
    electrical = {}
    for suffix in ("cap", "trans"):
        slacks = []
        for line in (directory / f"top.{suffix}").read_text().splitlines():
            fields = [field.strip() for field in line.split("|")[1:-1]]
            if len(fields) >= 4 and re.match(r"[-+]?\d", fields[1]):
                slacks.extend(float(value) for value in NUMBER.findall(fields[3]))
        if not slacks:
            raise RuntimeError(f"missing electrical checks in {directory / f'top.{suffix}'}")
        electrical[suffix] = min(slacks) if slacks else None
        if slacks and min(slacks) < 0:
            problems.append(f"{suffix} violation: worst reported slack {min(slacks):.3f}")
    if any(delay < -0.05 for _, delay, _ in rows["min"]):
        problems.append("negative data arrival time: delay model needs investigation")
    return {"setup_slack_ns": setup[0], "hold_slack_ns": hold[0],
            "setup_endpoint": setup[2], "hold_endpoint": hold[2],
            "electrical_slacks": electrical, "model_issues": problems,
            "setup_met": setup[0] >= 0.001, "hold_met": hold[0] >= 0,
            "directory": str(directory)}


def synthesize(args):
    build = Path(args.build_dir)
    synth_dir = build / "synth"
    synth_dir.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ,
               SYNTH_TOP=args.top,
               SYNTH_RTL=args.rtl,
               SYNTH_BUILD_DIR=str(build.resolve()),
               SYNTH_PERIOD_NS=str(args.target_ns),
               SYNTH_MAX_FANOUT=str(args.max_fanout))
    yosys = os.environ.get("YOSYS", "yosys")
    common = Path(args.common_dir)
    run([yosys, "-Q", "-T", "-p", f"tcl {common / 'synth.tcl'}"],
        synth_dir / "synth.log", cwd=str(build.parent), env=env)
    run([yosys, "-Q", "-T", "-p", f"tcl {common / 'prepare.tcl'}"],
        build / "sta" / "prepare.log", cwd=str(build.parent), env=env)
    print(f"Synthesis complete; netlist: {build / 'sta' / 'top_nangate45_sta.v'}")


def analyze(period, args):
    build = Path(args.build_dir)
    sta_dir = build / "sta"
    tag = datetime.datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    out_dir = sta_dir / "runs" / f"{tag}-T{period:.6f}ns"
    env = dict(os.environ,
               STA_BUILD_DIR=str(build.resolve()),
               SYNTH_TOP=args.top,
               STA_PERIOD_NS=f"{period:.9f}",
               STA_SDC=args.sdc,
               STA_OUT_DIR=str(out_dir))
    ieda = os.environ.get("IEDA", args.ieda)
    common = Path(args.common_dir)
    run([ieda, "-script", str(common / "run.tcl")], out_dir / "sta.log",
        cwd=str(build.parent), env=env)
    summary = report_summary(out_dir)
    summary.update(period_ns=period, frequency_mhz=1000 / period,
                   netlist=str(build / "sta" / "top_nangate45_sta.v"))
    (out_dir / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    (sta_dir / "latest.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(f"  period={period:.4f}ns  setup={summary['setup_slack_ns']:.4f}ns  "
          f"hold={summary['hold_slack_ns']:.4f}ns  freq={summary['frequency_mhz']:.2f}MHz")
    return summary


def bisect(args):
    build = Path(args.build_dir)
    trials = []

    def trial(period):
        result = analyze(period, args)
        trials.append(result)

        if result["model_issues"]:
            raise RuntimeError(
                "electrical/model checks failed; stop Fmax search"
            )

        return result["setup_met"]

    period = args.start_ns
    if trial(period):
        upper = period
        for _ in range(20):
            period /= 2
            if not trial(period):
                lower = period
                break
            upper = period
        else:
            raise RuntimeError("could not find a failing period")
    else:
        lower = period
        for _ in range(20):
            period *= 2
            if trial(period):
                upper = period
                break
            lower = period
        else:
            raise RuntimeError("could not find a passing period")
    for _ in range(32):
        if upper - lower <= args.tolerance_ns:
            break
        middle = (lower + upper) / 2
        if trial(middle):
            upper = middle
        else:
            lower = middle
    else:
        raise RuntimeError("bisection did not converge")
    result = {
        "failing_period_ns": lower,
        "passing_period_ns": upper,
        "fmax_lower_mhz": 1000 / upper,
        "fmax_upper_mhz": 1000 / lower,
        "start_period_ns": args.start_ns,
        "tolerance_ns": args.tolerance_ns,
        "hold_met_in_all_trials": all(t["hold_met"] for t in trials),
        "trials": trials,
    }
    path = build / "sta" / "fmax.json"
    path.write_text(json.dumps(result, indent=2) + "\n")
    print(f"Fmax: {result['fmax_lower_mhz']:.3f} .. {result['fmax_upper_mhz']:.3f} MHz; {path}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--common-dir", default=os.environ.get("STA_COMMON_DIR", "."),
                        help="directory containing synth.tcl/prepare.tcl/run.tcl")
    parser.add_argument("--build-dir", required=True)
    parser.add_argument("--top")
    parser.add_argument("--rtl")
    parser.add_argument("--sdc")
    parser.add_argument("--ieda", default=os.environ.get("IEDA",
                        str(Path.home() / "software/yosys-sta/bin/iEDA")))
    parser.add_argument("--target-ns", type=positive, default=2.0)
    parser.add_argument("--max-fanout", type=int, default=8)
    parser.add_argument("--start-ns", type=positive, default=2.0)
    parser.add_argument("--tolerance-ns", type=positive, default=0.01)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("synth", help="synthesize and prepare netlist")
    sub.add_parser("all", help="synth + bisect Fmax")
    runp = sub.add_parser("run", help="single STA at fixed period")
    runp.add_argument("--period-ns", type=positive, required=True)
    sub.add_parser("bisect", help="bisect Fmax on existing netlist")
    args = parser.parse_args()

    if args.command in ("synth", "all", "bisect") and not (args.top and args.rtl and args.sdc):
        parser.error("--top/--rtl/--sdc required")
    if args.command == "run" and not args.sdc:
        parser.error("--sdc required for run")

    if args.command == "synth":
        synthesize(args)
    elif args.command == "run":
        analyze(args.period_ns, args)
    elif args.command in ("all", "bisect"):
        if args.command == "all":
            synthesize(args)
        bisect(args)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, ValueError, subprocess.SubprocessError) as e:
        print(f"sta.py: {e}", file=sys.stderr)
        sys.exit(1)
