#!/usr/bin/env python3
"""校验仿真/STA 两份独立证据，归档并自动追加 NPC 性能台账。"""
import argparse
import datetime
import fcntl
import hashlib
import importlib.util
import json
import math
from pathlib import Path
import re
import shutil
import sys

NPC = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("npc_sta_flow", NPC / "scripts/sta/flow.py")
sta = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sta)


def simulation_stats(path):
    """周期、指令、IPC 只读本次仿真日志；未正常跑完的计数不入台账。"""
    text = sta.ANSI.sub("", path.read_text(errors="replace"))
    if ("npc: HIT GOOD TRAP" not in text or "MicroBench PASS" not in text
            or re.search(r"npc: (?:HIT BAD TRAP|ABORT)", text)):
        raise RuntimeError(f"simulation did not pass MicroBench/GOOD TRAP: {path}")
    matches = re.findall(r"PERF: inst=\s*(\d+)\s+cycles=\s*(\d+)\s+IPC=\s*(\d+\.\d+)", text)
    if not matches:
        raise RuntimeError(f"PERF counters missing: {path}")
    inst, cycles, ipc = matches[-1]
    if int(inst) <= 0 or int(cycles) <= 0:
        raise RuntimeError("simulation counters must be positive")
    if abs(float(ipc) - int(inst) / int(cycles)) > 0.001:
        raise RuntimeError("reported IPC is inconsistent with instructions/cycles")
    return {"instructions": int(inst), "cycles": int(cycles), "ipc": ipc}


def sta_result(path):
    """只接受完整 make sta 的结果，并核对当前源文件、网表和原始报告。

    不从旧台账、仿真日志或预设频率补综合数据；旧结果与当前输入不符就报错。
    """
    result = json.loads(path.read_text())
    if result.get("schema_version") != 1:
        raise RuntimeError("STA result is incomplete; run make sta")
    if result["source_sha256"] != sta.source_hashes():
        raise RuntimeError("STA result is stale: RTL/configuration/scripts changed")
    for artifact, key in ((sta.NETLIST, "netlist_sha256"),
                          (sta.LIBERTY, "liberty_sha256"),
                          (sta.FLOW / "top.sdc", "sdc_sha256")):
        if sta.digest(artifact) != result[key]:
            raise RuntimeError(f"STA result is stale: {artifact} changed")
    passing = sta.report_summary(Path(result["passing_report"]).parent)
    if not passing["setup_met"] or passing["model_issues"]:
        raise RuntimeError("STA passing report failed setup/electrical validation")
    if any(trial["model_issues"] for trial in result["trials"]):
        raise RuntimeError("STA search contains invalid electrical/model results")
    lower, upper = result["fmax_lower_mhz"], result["fmax_upper_mhz"]
    if not (math.isfinite(lower) and math.isfinite(upper) and 0 < lower <= upper):
        raise RuntimeError("invalid STA frequency interval")
    if (not math.isclose(lower, 1000 / result["passing_period_ns"])
            or not math.isclose(upper, 1000 / result["failing_period_ns"])):
        raise RuntimeError("STA frequency does not match measured period bounds")
    measured_area = sta.area_from_report(Path(result["area_report"]))
    if not math.isclose(result["cell_area_um2"], measured_area, abs_tol=1e-6):
        raise RuntimeError("STA area does not match the analyzed netlist's area report")
    return result


def configuration(arch, result):
    """仿真配置和综合配置分列在同一字段中，明确 128 MiB 与 4 KiB 的差别。"""
    config = (NPC / ".config").read_text()
    flag = lambda name: "y" if re.search(rf"^{name}=y$", config, re.M) else "n"
    profile = result["profile"]
    return (f"arch={arch},rdelay={flag('CONFIG_RANDOM_DELAY')},"
            f"difftest={flag('CONFIG_DIFFTEST')},rve={flag('CONFIG_RVE')},"
            f"sta_mem={profile['mem_bytes']}B,sta_rdelay=n,"
            f"sta_target={profile['synthesis_target_ns']:g}ns,"
            f"sta_fo={profile['max_fanout_target']},"
            f"sta_tol={result['tolerance_ns']:g}ns,"
            f"sta_lib={result['liberty_sha256'][:12]},sta_sdc={result['sdc_sha256'][:12]},"
            f"sta_hold={'y' if result['hold_met_in_all_trials'] else 'n'}")


def cell(value):
    """说明文字中的竖线/换行不能破坏 Markdown 表格结构。"""
    return " ".join(str(value).split()).replace("|", "&#124;")


def ledger_update(text, fields):
    """保留历史行和表后说明；同 commit/同口径不重复，也不静默覆盖不同数字。"""
    lines = text.splitlines(keepends=True)
    header = next((i for i, line in enumerate(lines)
                   if line.startswith("| commit |")), None)
    if header is None:
        raise RuntimeError("perf ledger table header is missing")
    end = header + 2  # 跳过标题行和 Markdown 分隔行。
    while end < len(lines) and lines[end].startswith("|"):
        existing = [field.strip() for field in lines[end].strip().split("|")[1:-1]]
        if len(existing) >= 9 and existing[0] == fields[0] and existing[8] == fields[8]:
            if any(existing[i] != fields[i] for i in (2, 3, 4, 6, 7)):
                raise RuntimeError("same commit/configuration produced different metrics; investigate before recording")
            return text, lines[end].rstrip(), False
        end += 1
    row = "| " + " | ".join(fields) + " |"
    lines.insert(end, row + "\n")
    return "".join(lines), row, True


def record(args):
    stats = simulation_stats(args.simulation_log)
    result = sta_result(args.sta_result)
    if sta.digest(NPC / ".config") != args.config_sha256:
        raise RuntimeError("simulation configuration changed during perf; rerun")
    cfg = configuration(args.arch, result)
    frequency = f"{result['fmax_lower_mhz']:.3f}..{result['fmax_upper_mhz']:.3f} MHz"
    # 不含日期/描述的内容身份，使相同测量重复运行时仍对应同一证据目录。
    identity = json.dumps({"commit": args.commit, "configuration": cfg, "simulation": stats,
                           "netlist": result["netlist_sha256"], "frequency": frequency,
                           "area": result["cell_area_um2"], "tools": result["tools"]}, sort_keys=True)
    tag = hashlib.sha256(identity.encode()).hexdigest()[:12]
    archive = NPC / "build/perf" / f"{args.commit[:12]}-{tag}"
    evidence = f"[JSON](../build/perf/{archive.name}/measurement.json)"
    fields = list(map(cell, [args.commit[:12], args.desc or "（补说明）", stats["cycles"],
                            stats["instructions"], stats["ipc"], datetime.date.today().isoformat(),
                            frequency, f"{result['cell_area_um2']:.3f}", cfg, evidence]))
    ledger = NPC / "docs/perf-log.md"
    # perf.sh 还持有整轮测量锁；这里的锁也保护直接调用记录器的情况。
    with (NPC / "build/perf-record.lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        updated, row, added = ledger_update(ledger.read_text(), fields)
        # make clean 后重跑相同测量，也恢复这行已经链接的本地证据。
        if not added:
            linked = re.search(r"\[JSON\]\(\.\./build/perf/([\w-]+)/measurement.json\)", row)
            if linked:
                archive = NPC / "build/perf" / linked.group(1)
        if added or not (archive / "measurement.json").is_file():
            archive.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(args.simulation_log, archive / "simulation.log")
            shutil.copyfile(NPC / ".config", archive / "npc.config")
            build_log = NPC / "build/perf-build.log"
            if build_log.is_file():
                shutil.copyfile(build_log, archive / "simulation-build.log")
            shutil.copyfile(result["area_report"], archive / "area.txt")
            source = Path(result["passing_report"])
            for suffix in (".rpt", ".cap", ".trans"):
                shutil.copyfile(source.with_suffix(suffix), archive / f"top{suffix}")
            # 自动追踪文件也随本轮测量保存，避免下一次 sta 覆盖默认输出。
            for name, suffix in (("markdown", ".md"), ("json", ".json")):
                trace_file = result.get("critical_paths", {}).get(name)
                if trace_file:
                    shutil.copyfile(trace_file, archive / f"critical_paths{suffix}")
            # 保存完整 STA 结果，避免下一次 make sta 覆盖 result.json 后丢失本行证据。
            sta.write_json(archive / "measurement.json", {
                "commit": args.commit, "description": args.desc, "configuration": cfg,
                "simulation": stats, "simulation_log_sha256": sta.digest(args.simulation_log),
                "sta": result})
        if added:
            temporary = ledger.with_suffix(".md.tmp")
            temporary.write_text(updated)
            temporary.replace(ledger)
    print(row)
    print(f"perf: {'已追加' if added else '已有相同测量，未重复追加'} {ledger}", file=sys.stderr)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    check = commands.add_parser("check", help="only validate the simulation before expensive STA")
    check.add_argument("simulation_log", type=Path)
    append = commands.add_parser("record", help="validate both sources, archive, append once")
    append.add_argument("--simulation-log", type=Path, required=True)
    append.add_argument("--sta-result", type=Path, required=True)
    append.add_argument("--commit", required=True)
    append.add_argument("--config-sha256", required=True)
    append.add_argument("--arch", required=True)
    append.add_argument("--desc", default="")
    args = parser.parse_args()
    if args.command == "check":
        print(json.dumps(simulation_stats(args.simulation_log)))
    else:
        record(args)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, ValueError, KeyError) as error:
        print(f"perf: {error}", file=sys.stderr)
        sys.exit(1)
