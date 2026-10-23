#!/usr/bin/env python3
"""Nangate45 综合、iSTA 分析及 Fmax 搜索；make sta 调用 all 子命令。

数据流：RTL -> synth.tcl -> prepare.tcl -> run.tcl/SDC -> 二分 -> result.json。
仿真计数不在这里产生；perf 只能从 result.json 取得综合面积和频率。
"""
import argparse
import datetime
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

FLOW = Path(__file__).resolve().parent
NPC = FLOW.parent.parent
SYNTH = NPC / "build/synth"
STA = NPC / "build/sta"
NETLIST = STA / "top_nangate45_sta.v"
LIBERTY = SYNTH / "nangate45.lib"
ANSI = re.compile(r"\x1b\[[0-9;]*m")
NUMBER = re.compile(r"[-+]?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?")


def positive(value):
    result = float(value)
    if not math.isfinite(result) or result <= 0:
        raise argparse.ArgumentTypeError("must be a finite positive number")
    return result


def digest(path):
    """用内容而非文件时间判断输入是否改变，避免长时间搜索混用不同设计。"""
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def execute(command, log, env):
    """完整日志写文件；工具报错时中止，不让旧报告掩盖本次失败。"""
    print(f"Running {command[0]} -> {log}", flush=True)
    log.parent.mkdir(parents=True, exist_ok=True)
    with log.open("w") as output:
        result = subprocess.run(command, cwd=NPC, env=env, stdout=output,
                                stderr=subprocess.STDOUT, timeout=1800)
    if result.returncode:
        raise RuntimeError(f"command exited {result.returncode}; see {log}")
    text = ANSI.sub("", log.read_text(errors="replace"))
    # iEDA may catch a Tcl failure yet still exit successfully.
    if re.search(r"(^|\n)(?:ERROR:|.*(?:FATAL|Check failed|invalid command name))", text):
        raise RuntimeError(f"tool reported an error; see {log}")


def report_summary(directory):
    """分别提取 setup/hold 最差裕量，并检查该延迟模型的电气有效性。

top.rpt 的第一张表同时有 max/setup 和 min/hold，不能把两类 Slack 混取。
top.cap / top.trans 的裕量为负时，二分时钟周期不能修复这些电气违例。
"""
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


def print_summary(summary):
    print(f"setup slack={summary['setup_slack_ns']:.3f} ns, "
          f"hold slack={summary['hold_slack_ns']:.3f} ns")
    for issue in summary["model_issues"]:
        print(f"Model check: {issue}")
    print(f"Reports: {summary['directory']}", flush=True)


def synthesize(args):
    """每次从 RTL 重新综合，随后仅整理结构格式供旧版 iSTA 读取。"""
    if args.mem_bytes < 4 or args.mem_bytes % 4:
        raise RuntimeError("--mem-bytes must be a positive multiple of four")
    if args.max_fanout < 2:
        raise RuntimeError("--max-fanout must be >= 2")
    SYNTH.mkdir(parents=True, exist_ok=True)
    source = getattr(args, "liberty", None)
    if source is not None:
        source = source.expanduser().resolve()
        if not source.is_file():
            raise RuntimeError(f"Liberty not found: {source}")
        if source != LIBERTY.resolve():
            shutil.copyfile(source, LIBERTY)
    if not LIBERTY.is_file():
        source = Path.home() / "software/yosys-sta/pdk/nangate45/lib/Nangate45_typ.lib"
        if not source.is_file():
            raise RuntimeError(f"place the Nangate45 typical Liberty at {LIBERTY}")
        shutil.copyfile(source, LIBERTY)
    env = dict(os.environ, SYNTH_MEM_BYTES=str(args.mem_bytes),
               SYNTH_PERIOD_NS=str(args.target_ns), SYNTH_MAX_FANOUT=str(args.max_fanout))
    yosys = os.environ.get("YOSYS", "yosys")
    execute([yosys, "-Q", "-T", "-p", f"tcl {FLOW / 'synth.tcl'}"],
            SYNTH / "synth.log", env)
    text = (SYNTH / "synth.log").read_text()
    if re.search(r'DPI-C|\b(?:pmem_\w+|npc_ebreak|npc_reg_write)\s*\(', text):
        raise RuntimeError("DPI call found in synthesis input; inspect synth.log")
    execute([yosys, "-Q", "-T", "-p", f"tcl {FLOW / 'prepare.tcl'}"],
            STA / "prepare_netlist.log", env)
    netlist = NETLIST.read_text()
    if re.search(r"\bassign\s+[^;]*?=\s*1'b[01xz]", netlist):
        raise RuntimeError("literal constant assignment remains in iSTA netlist")
    profile = {"mem_bytes": args.mem_bytes, "synthesis_target_ns": args.target_ns,
               "max_fanout_target": args.max_fanout, "abc_buffer_primary_inputs": True,
               "abc_dont_use": ["NOR4_X1"], "abc_slew_target_ps": 100,
               "netlist_sha256": digest(NETLIST), "liberty_sha256": digest(LIBERTY)}
    (SYNTH / "profile.json").write_text(json.dumps(profile, indent=2) + "\n")
    print(f"Synthesis complete; iSTA netlist: {NETLIST}")


def analyze(period, ieda):
    """只改时钟周期，不改门网表；每次使用新目录，保留所有试探报告。"""
    if not NETLIST.is_file() or not LIBERTY.is_file():
        raise RuntimeError("netlist/Liberty missing; run the synth subcommand first")
    tag = datetime.datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    directory = STA / "runs" / f"{tag}-T{period:.6f}ns"
    env = dict(os.environ, STA_PERIOD_NS=f"{period:.9f}", STA_OUT_DIR=str(directory))
    execute([ieda, "-script", str(FLOW / "run.tcl")], directory / "sta.log", env)
    log = (directory / "sta.log").read_text(errors="replace")
    if re.search(r"liberty cell .* is not exist|port is not found|constant net need TODO", log):
        raise RuntimeError(f"incomplete netlist linking; see {directory / 'sta.log'}")
    summary = report_summary(directory)
    summary.update(period_ns=period, frequency_mhz=1000 / period,
                   netlist_sha256=digest(NETLIST), liberty_sha256=digest(LIBERTY),
                   analysis="reg-to-reg setup; ideal clock; no SPEF; typical corner")
    (directory / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    (STA / "latest.json").write_text(json.dumps(summary, indent=2) + "\n")
    print_summary(summary)
    return summary


def bisect_period(args):
    """先找失败/通过区间，再二分周期；整个搜索固定网表、库和 SDC。

周期越长越容易满足 setup。因此通过周期给出 Fmax 下界，失败周期给出上界。
hold 单独记录，不能靠放慢时钟解决；至少 1 ps 裕量才接受为 setup 通过。
"""
    identity = (digest(NETLIST), digest(LIBERTY), digest(FLOW / "top.sdc"))
    trials = []

    def trial(period):
        if identity != (digest(NETLIST), digest(LIBERTY), digest(FLOW / "top.sdc")):
            raise RuntimeError("netlist, Liberty or SDC changed during bisection")
        result = analyze(period, args.ieda)
        if identity != (digest(NETLIST), digest(LIBERTY), digest(FLOW / "top.sdc")):
            raise RuntimeError("netlist, Liberty or SDC changed during analysis")
        trials.append(result)
        if result["model_issues"]:
            raise RuntimeError("electrical/model checks failed; Fmax search stopped")
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
        raise RuntimeError("bisection did not converge within 32 iterations")
    result = {"failing_period_ns": lower, "passing_period_ns": upper,
              "fmax_lower_mhz": 1000 / upper, "fmax_upper_mhz": 1000 / lower,
              "start_period_ns": args.start_ns, "tolerance_ns": args.tolerance_ns,
              "setup_pass_margin_ns": 0.001, "hold_met_in_all_trials": all(t["hold_met"] for t in trials),
              "netlist_sha256": identity[0], "trials": trials}
    path = STA / "fmax.json"
    path.write_text(json.dumps(result, indent=2) + "\n")
    print(f"Setup Fmax: {1000 / upper:.3f} .. {1000 / lower:.3f} MHz; {path}")
    if not result["hold_met_in_all_trials"]:
        print("Hold violations remain; this is a setup-only frequency bound.")
    return result


def source_hashes():
    """保存综合口径的源文件身份；build/ 中的生成物不参与这个快照。"""
    rtl = sorted(path for path in (NPC / "vsrc").rglob("*")
                 if path.suffix in (".v", ".vh", ".sv", ".svh"))
    paths = [NPC / ".config", *rtl,
             *sorted(FLOW.glob("*.tcl")), FLOW / "top.sdc", FLOW / "flow.py"]
    return {str(path.relative_to(NPC)): digest(path) for path in paths}


def area_from_report(path):
    """从完整精度的 Chip area 行取面积，不累加表格中已舍入的单元面积。"""
    values = re.findall(r"Chip area for (?:top )?module .*?:\s*(\S+)", path.read_text())
    if len(values) != 1:
        raise RuntimeError(f"expected one flattened top area in {path}")
    area = float(values[0])
    if not math.isfinite(area) or area <= 0:
        raise RuntimeError(f"invalid cell area in {path}")
    return area


def write_json(path, value):
    """同目录原子替换，使 perf 读到的总是完整 JSON。"""
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n")
    temporary.replace(path)


def complete_flow(args):
    """make sta 的唯一完整入口；只有全部成功才发布可供 perf 消费的结果。

使用文件锁串行化完整流程，防止两个 make sta 互相覆盖中间网表。
旧的 fmax/逐次报告保留作学习证据，但启动时撤下旧 result.json，失败不回退。
"""
    STA.mkdir(parents=True, exist_ok=True)
    with (STA / "flow.lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        output = STA / "result.json"
        output.unlink(missing_ok=True)
        for executable in (os.environ.get("YOSYS", "yosys"), args.ieda):
            if shutil.which(executable) is None:
                raise RuntimeError(f"tool not found: {executable}")
        sources = source_hashes()
        synthesize(args)
        bound = bisect_period(args)
        if source_hashes() != sources:
            raise RuntimeError("RTL, configuration or STA scripts changed during make sta; rerun")
        profile = json.loads((SYNTH / "profile.json").read_text())
        if (digest(NETLIST), digest(LIBERTY)) != (
                profile["netlist_sha256"], profile["liberty_sha256"]):
            raise RuntimeError("synthesis profile does not match analyzed netlist/Liberty")
        passing = next(trial for trial in bound["trials"]
                       if trial["period_ns"] == bound["passing_period_ns"])
        report = Path(passing["directory"]) / "top.rpt"
        # 面积来自实际送入 STA 的网表：包括 prepare.tcl 添加的两个常量单元。
        # 同时保留整理前面积，便于与 build/synth/stat.txt 逐项核对。
        area_report = STA / "netlist_stat.txt"
        yosys = os.environ.get("YOSYS", "yosys")
        version = subprocess.run([yosys, "-V"], check=True, text=True,
                                 capture_output=True, timeout=30).stdout.strip()
        ista_version = re.search(r"GitVersion:\s*([^\s.]+)", report.read_text())
        result = dict(bound, schema_version=1,
                      completed_at=datetime.datetime.now().astimezone().isoformat(),
                      analysis=passing["analysis"], profile=profile,
                      source_sha256=sources, sdc_sha256=digest(FLOW / "top.sdc"),
                      liberty_sha256=digest(LIBERTY),
                      cell_area_um2=area_from_report(area_report),
                      mapped_area_um2=area_from_report(SYNTH / "stat.txt"),
                      area_report=str(area_report), passing_report=str(report),
                      fmax_report=str(STA / "fmax.json"),
                      tools={"yosys": version, "ieda": shutil.which(args.ieda),
                             "ista_git": ista_version.group(1) if ista_version else "unknown"})
        write_json(output, result)
        print(f"Cell area: {result['cell_area_um2']:.3f} um^2; complete result: {output}")
        return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ieda", default=os.environ.get("IEDA", str(
        Path.home() / "software/yosys-sta/bin/iEDA")))
    commands = parser.add_subparsers(dest="command", required=True)
    synthesis = commands.add_parser("synth", help="synthesize and export an iSTA-compatible netlist")
    complete = commands.add_parser("all", help="fresh synthesis + Fmax search + area/result.json")
    for command in (synthesis, complete):
        command.add_argument("--mem-bytes", type=int, default=4096)
        command.add_argument("--target-ns", type=positive, default=2.0)
        command.add_argument("--max-fanout", type=int, default=8)
        command.add_argument("--liberty", type=Path, help="copy this Nangate45 typical Liberty")
    run = commands.add_parser("run", help="analyze a fixed netlist at one period")
    run.add_argument("period_ns", type=positive)
    search = commands.add_parser("bisect", help="bracket and bisect setup Fmax without resynthesis")
    for command in (search, complete):
        command.add_argument("--start-ns", type=positive, default=2.0)
        command.add_argument("--tolerance-ns", type=positive, default=0.01)
    inspect = commands.add_parser("report", help="inspect an existing iSTA report directory")
    inspect.add_argument("directory", type=Path)
    args = parser.parse_args()
    if args.command == "synth":
        synthesize(args)
    elif args.command == "run":
        analyze(args.period_ns, args.ieda)
    elif args.command == "bisect":
        bisect_period(args)
    elif args.command == "all":
        complete_flow(args)
    else:
        print_summary(report_summary(args.directory.resolve()))


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"sta: {error}", file=sys.stderr)
        sys.exit(1)
