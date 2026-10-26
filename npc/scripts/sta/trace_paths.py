#!/usr/bin/env python3
"""把本流程的 iSTA top.rpt 关联到 Yosys 网表，输出可读的关键路径与 JSON。

只解析 Yosys write_verilog -noexpr 生成的标量标准单元实例，不实现通用 Verilog
前端。逐级连接必须同时在原始网表和 STA 网表中连续；不支持的格式直接报错。
RTL 声明位置取自综合 JSON 的 netnames/src，不根据门名猜测对应的 RTL 运算。
"""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import sys

NPC = Path(os.environ.get("NPC_HOME", Path(__file__).resolve().parents[2])).resolve()
POINT = re.compile(r"^(.+):([^:\s]+) \(([^()]+)\)$")
INSTANCE = re.compile(r"^\s{2}(\S+)\s+(\S+)\s*\(\s*$")
PIN = re.compile(r"^\s*\.([^\s(]+)\((.*)\),?\s*$")
SIGNAL = re.compile(r"^(\\[^\s]+|[a-zA-Z_$][\w$]*)(?:\s*\[\s*(-?\d+)\s*\])?\s*$")


def digest(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def number(text):
    match = re.match(r"[-+]?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?", text)
    if not match or not math.isfinite(value := float(match[0])):
        raise ValueError(f"invalid timing number: {text!r}")
    return value


def signal(expression):
    """保留转义标识符内部的方括号：\\rf[3] [31] 是 rf[3] 的第 31 位。"""
    match = SIGNAL.fullmatch(expression.strip())
    if not match:
        raise ValueError(f"expected a scalar net or bus bit, got {expression!r}")
    name, bit = match.groups()
    name = name.removeprefix("\\")
    return name, int(bit) if bit is not None else None


def display(expression):
    name, bit = signal(expression)
    return name if bit is None else f"{name}[{bit}]"


def read_report(path):
    """用汇总表的 max/min 区分 setup/hold，按原报告顺序配对逐级表。

    不用 endpoint 作字典键：同一终点可能同时出现 rise/fall 或多条不同路径。
    空白行后的捕获时钟/required time 不属于数据路径。
    """
    summaries, blocks, block = [], [], None
    for line_no, line in enumerate(path.read_text().splitlines(), 1):
        fields = [part.strip() for part in line.split("|")[1:-1]]
        if len(fields) == 8 and fields[2] in ("max", "min"):
            summaries.append({"endpoint": fields[0], "clock_group": fields[1],
                              "kind": "setup" if fields[2] == "max" else "hold",
                              "slack_ns": number(fields[6]), "arrival_ns": number(fields[3]),
                              "required_ns": number(fields[4]), "summary_line": line_no})
        if len(fields) != 8:
            continue
        if fields[0] == "Point":
            block = []
            blocks.append(block)
        elif block is not None:
            block.append((line_no, fields))
    if not summaries or len(summaries) != len(blocks):
        raise ValueError("report needs matching iSTA summary and detailed path tables")
    paths = []
    for summary, rows in zip(summaries, blocks):
        checks = [fields for _, fields in rows if fields[0].startswith("slack (")]
        timing_check = f"library {summary['kind']} time"
        if (len(checks) != 1 or not any(f[0] == timing_check for _, f in rows)
                or abs(number(checks[0][7]) - summary["slack_ns"]) > 0.0011):
            raise ValueError("detailed path does not match its setup/hold summary")
        points = []
        for line_no, fields in rows:
            if not fields[0]:
                break  # 到此数据已经到达终点 D；后面的 CK/setup 是另一段。
            match = POINT.fullmatch(fields[0])
            if match:
                instance, pin, cell_type = match.groups()
                points.append({"instance": instance, "pin": pin, "cell_type": cell_type,
                               "increment_ns": number(fields[6]), "arrival_ns": number(fields[7]),
                               "transition_ns": number(fields[4]), "report_line": line_no})
            elif fields[0].endswith(" (net)") and points:
                points[-1]["reported_net"] = fields[0][:-6]
                points[-1]["fanout"] = int(fields[1])
        if not points or f"{points[-1]['instance']}:{points[-1]['pin']}" != summary["endpoint"]:
            raise ValueError("detailed endpoint does not match summary")
        paths.append(dict(summary, points=points))
    return paths


def read_cells(path, wanted):
    """单次流式扫描约百万行网表，只保留本次路径涉及的实例和原网表行号。"""
    cells, active = {}, None
    with path.open() as stream:
        for line_no, line in enumerate(stream, 1):
            if active is None:
                header = INSTANCE.fullmatch(line.rstrip("\n"))
                if header and header[2] in wanted:
                    name = header[2]
                    if name in cells:
                        raise ValueError(f"duplicate instance {name} in {path}")
                    active = {"type": header[1], "line": line_no, "pins": {}}
                    cells[name] = active
            elif line.strip() == ");":
                active = None
            else:
                pin = PIN.fullmatch(line.rstrip("\n"))
                if not pin or pin[1] in active["pins"]:
                    raise ValueError(f"unsupported/duplicate named port at {path}:{line_no}")
                active["pins"][pin[1]] = pin[2].strip()
    if active is not None or wanted - cells.keys():
        raise ValueError(f"missing/incomplete instances in {path}: {sorted(wanted - cells.keys())[:5]}")
    return cells


def source_locations(expression, netnames, root, hashes):
    name, _ = signal(expression)
    src = netnames.get(name, {}).get("attributes", {}).get("src", "")
    locations = []
    for part in src.split("|"):
        match = re.match(r"(.+?):(\d+)\.\d+", part)
        if match:
            file_name, line = match.groups()
            file = root / file_name
            expected = hashes.get(file_name)
            verified = bool(expected and file.is_file() and digest(file) == expected)
            locations.append({"file": file_name, "line": int(line), "src": part,
                              "verified": verified})
    return locations


def trace_path(path, cells, sta_cells, modules, netnames, root, source_hashes):
    """沿报告选定的时序弧前进；不把该门所有扇入/扇出都当成关键路径。"""
    def direction(point):
        try:
            return modules[point["cell_type"]]["ports"][point["pin"]]["direction"]
        except KeyError:
            raise ValueError(f"unknown library pin: {point['cell_type']}/{point['pin']}") from None

    points = path["points"]
    first = next((i for i, point in enumerate(points) if direction(point) == "output"), None)
    if first is None:
        raise ValueError("only register-to-register data paths are supported")
    points = points[first:]
    for point in points:
        for label, index in (("mapped", cells), ("STA", sta_cells)):
            cell = index[point["instance"]]
            if cell["type"] != point["cell_type"] or point["pin"] not in cell["pins"]:
                raise ValueError(f"{label} netlist disagrees with report: {point['instance']}:{point['pin']}")
    for point in (points[0], points[-1]):
        if "CK" not in cells[point["instance"]]["pins"]:
            raise ValueError("only CK-clocked register endpoints are supported")

    def register(point):
        cell = cells[point["instance"]]
        if "Q" not in cell["pins"]:
            raise ValueError(f"register without Q: {point['instance']}")
        q = cell["pins"]["Q"]
        return {"instance": point["instance"], "pin": point["pin"], "q_signal": display(q),
                "path_signal": display(cell["pins"][point["pin"]]), "netlist_line": cell["line"],
                "rtl_declarations": source_locations(q, netnames, root, source_hashes)}

    def connected(previous, following):
        for label, index in (("mapped", cells), ("STA", sta_cells)):
            left = index[previous["instance"]]["pins"][previous["pin"]]
            right = index[following["instance"]]["pins"][following["pin"]]
            if signal(left) != signal(right):
                raise ValueError(f"disconnected {label} path: {previous['instance']}:{previous['pin']} -> "
                                 f"{following['instance']}:{following['pin']}")
        reported = previous.get("reported_net")
        if reported is not None:
            actual = sta_cells[previous["instance"]]["pins"][previous["pin"]]
            if signal(actual) != signal(reported):
                raise ValueError(f"reported net {reported} disagrees with STA netlist")

    def stage(output, input_pin, kind):
        cell = cells[output["instance"]]
        return dict(output, input_pin=input_pin, output_pin=output["pin"], kind=kind,
                    input_signal=display(cell["pins"][input_pin]),
                    output_signal=display(cell["pins"][output["pin"]]), netlist_line=cell["line"],
                    connections=dict(cell["pins"]),
                    mux_select=output["cell_type"].startswith("MUX") and input_pin == "S")

    stages = [stage(points[0], "CK", "clock_to_q")]
    previous, i = points[0], 1
    while i < len(points):
        entry = points[i]
        if direction(entry) != "input":
            raise ValueError("expected a cell input after the previous cell output")
        connected(previous, entry)
        if i == len(points) - 1:
            if entry["pin"] != "D":
                raise ValueError("register endpoint must be D")
            break
        output = points[i + 1]
        if output["instance"] != entry["instance"] or direction(output) != "output":
            raise ValueError("expected one cell input/output timing arc")
        stages.append(stage(output, entry["pin"], "combinational"))
        previous, i = output, i + 2
    result = {key: value for key, value in path.items() if key != "points"}
    result.update(startpoint=register(points[0]), endpoint=register(points[-1]), stages=stages,
                  combinational_stages=len(stages) - 1,
                  clock_to_q_ns=stages[0]["increment_ns"],
                  combinational_delay_ns=points[-1]["arrival_ns"] - points[0]["arrival_ns"],
                  largest_cell_delays=sorted(stages[1:], key=lambda stage: stage["increment_ns"], reverse=True)[:5])
    return result


def markdown(result, root):
    def code(value):
        return "`" + str(value).replace("|", "&#124;") + "`"

    def link(file, line):
        return f"[{file.name}:{line}](<{file.resolve()}:{line}>)"

    lines = ["# NPC 关键路径追踪", "", f"原报告：{result['report']}", "",
             "延迟单位：ns。RTL 位置是信号声明，组合门与 RTL 运算不保证一一对应。", ""]
    for warning in result["notes"]:
        lines.extend([f"- {warning}", ""])
    for rank, path in enumerate(result["paths"], 1):
        start, end = path["startpoint"], path["endpoint"]
        lines.extend([f"## {rank}. {path['kind']}：{start['q_signal']} → {end['q_signal']}", "",
                      f"Slack **{path['slack_ns']:+.3f}**；到达 {path['arrival_ns']:.3f}；"
                      f"要求 {path['required_ns']:.3f}；组合级数 **{path['combinational_stages']}**（含缓冲）。", ""])
        for label, reg in (("起点", start), ("终点", end)):
            lines.append(f"- {label}：{code(reg['instance'] + ':' + reg['pin'])}，Q 保存 "
                         f"{code(reg['q_signal'])}；网表 {link(Path(result['mapped_netlist']), reg['netlist_line'])}。")
            for src in reg["rtl_declarations"]:
                ref = link(root / src["file"], src["line"]) if src["verified"] else code(src["src"])
                lines.append(f"  - RTL 声明：{ref}" + ("。" if src["verified"] else "（源码身份未验证，仅供旧版本参考）。"))
        lines.extend(["", f"clock-to-Q：{path['clock_to_q_ns']:.3f}；组合段（含网络）："
                      f"{path['combinational_delay_ns']:.3f}。", "",
                      "逐级数据路径（不包含终点后的捕获时钟和 setup/hold 检查行）：", "",
                      "| 级 | 实例 / 单元 | 时序弧 | 输出网线（整理前） | Incr | Path | 扇出 | 网表 |",
                      "|---:|---|---|---|---:|---:|---:|---|"])
        for i, stage in enumerate(path["stages"]):
            arc = stage["input_pin"] + " → " + stage["output_pin"]
            if stage["mux_select"]:
                arc += "（选择控制）"
            lines.append(f"| {i} | {code(stage['instance'])} / {stage['cell_type']} | {arc} | "
                         f"{code(stage['output_signal'])} | {stage['increment_ns']:.3f} | "
                         f"{stage['arrival_ns']:.3f} | {stage.get('fanout', '')} | "
                         f"{link(Path(result['mapped_netlist']), stage['netlist_line'])} |")
        lines.extend(["", "组合单元延迟较大的位置：", ""])
        for stage in path["largest_cell_delays"]:
            lines.append(f"- {code(stage['instance'])} ({stage['cell_type']})："
                         f"{stage['increment_ns']:.3f}，弧 {code(stage['input_pin'] + ' → ' + stage['output_pin'])}。")
        lines.append("")
    return "\n".join(lines)


def generate(metadata, report, mapped_netlist, sta_netlist, source_map, output, root=NPC,
             kind="setup", limit=5):
    """可供完整 STA 流程直接调用；先核对身份和连线，全部通过后才写输出。"""
    if kind not in ("setup", "hold", "all") or limit < 1:
        raise ValueError("kind must be setup/hold/all and limit must be positive")
    notes = []
    identities = {"netlist_sha256": digest(sta_netlist),
                  "mapped_netlist_sha256": digest(mapped_netlist), "source_map_sha256": digest(source_map)}
    if identities["netlist_sha256"] != metadata["netlist_sha256"]:
        raise ValueError("STA netlist does not match report metadata; use the matching synthesis artifacts")
    profile = metadata.get("profile", {})
    for path, key in ((mapped_netlist, "mapped_netlist_sha256"), (source_map, "source_map_sha256")):
        expected = profile.get(key) or metadata.get(key)
        if expected:
            if identities[key] != expected:
                raise ValueError(f"{key} mismatch: {path}")
        else:
            notes.append(f"旧结果未保存 {key}；本次以两份网表的逐级单元/引脚/连线核对补充验证。")
    paths = read_report(report)
    kinds = ("setup", "hold") if kind == "all" else (kind,)
    selected = [path for check in kinds for path in sorted(
        (path for path in paths if path["kind"] == check),
        key=lambda path: (path["slack_ns"], path["summary_line"]))[:limit]]
    if not selected:
        raise ValueError(f"no {kind} paths in report")
    wanted = {point["instance"] for path in selected for point in path["points"]}
    cells, sta_cells = read_cells(mapped_netlist, wanted), read_cells(sta_netlist, wanted)
    design = json.loads(source_map.read_text())["modules"]
    # JSON 的匿名 cell 名与 write_verilog 的编号不同，所以只用它的库端口和命名线源位置。
    design["top"].pop("cells", None)
    result = {"schema_version": 1, "report": str(report.resolve()),
              "mapped_netlist": str(mapped_netlist.resolve()), "sta_netlist": str(sta_netlist.resolve()),
              "report_sha256": digest(report), **identities,
              "notes": notes, "paths": [trace_path(path, cells, sta_cells, design,
                  design["top"]["netnames"], root, metadata.get("source_sha256", {})) for path in selected]}
    for path, key in ((sta_netlist, "netlist_sha256"), (mapped_netlist, "mapped_netlist_sha256"),
                      (source_map, "source_map_sha256"), (report, "report_sha256")):
        if digest(path) != result[key]:
            raise ValueError(f"trace input changed during processing: {path}")
    # 生成 JSON 保存全部门端口连接；Markdown 用于浏览和跳回网表/源码。
    output.parent.mkdir(parents=True, exist_ok=True)
    json_file, md_file = Path(str(output) + ".json"), Path(str(output) + ".md")
    json_file.write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n")
    md_file.write_text(markdown(result, root))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--result", type=Path, default=NPC / "build/sta/result.json")
    parser.add_argument("--report", type=Path, help="top.rpt or its run directory; needs adjacent summary.json")
    parser.add_argument("--kind", choices=("setup", "hold", "all"), default="setup")
    parser.add_argument("--limit", type=int, default=5, help="maximum paths per check type, from those already reported")
    parser.add_argument("--netlist", type=Path, default=NPC / "build/synth/top_nangate45.v")
    parser.add_argument("--sta-netlist", type=Path, default=NPC / "build/sta/top_nangate45_sta.v")
    parser.add_argument("--source-map", type=Path, default=NPC / "build/synth/top_nangate45.json")
    parser.add_argument("--output", type=Path, help="output prefix, without .md/.json")
    args = parser.parse_args()
    metadata = json.loads(args.result.read_text()) if args.result.is_file() else {}
    metadata = metadata.get("sta", metadata)  # 也接受 perf 归档的 measurement.json。
    if not args.report and not metadata:
        raise ValueError("no completed STA result; run make sta or specify --report")
    report = args.report or Path(metadata["passing_report"])
    if report.is_dir():
        report /= "top.rpt"
    if args.report:
        summary = json.loads((report.parent / "summary.json").read_text())
        # 历史报告的身份只从自己的 summary 获取；不能拿最新 result 的身份替代。
        if summary["netlist_sha256"] != metadata.get("netlist_sha256"):
            metadata = summary
        else:
            metadata = dict(metadata, **summary)
    output = args.output or NPC / "build/sta" / ("critical_paths" if args.kind == "setup" else f"{args.kind}_paths")
    result = generate(metadata, report, args.netlist, args.sta_netlist, args.source_map,
                      output, kind=args.kind, limit=args.limit)
    for path in result["paths"]:
        print(f"{path['kind']} {path['slack_ns']:+.3f} ns: {path['startpoint']['q_signal']} -> "
              f"{path['endpoint']['q_signal']} ({path['combinational_stages']} combinational stages)")
    print(f"Trace: {output}.md; {output}.json")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError) as error:
        print(f"sta-trace: {error}", file=sys.stderr)
        sys.exit(1)
