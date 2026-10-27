#!/usr/bin/env python3
"""Check performance accounting against known RV32E instruction sequences.

Run against either a random-delay or a no-delay NPC. The latter also permits
exact comparisons between aligned and split accesses. Logs stay in build/.
"""
import argparse
from pathlib import Path
import re
import subprocess

NPC = Path(__file__).resolve().parents[1]
SOURCE = r"""
  .section .text
  .globl _start
_start:
#if FAULT_CASE == 1
  lui s0, 0x40000
  lw t0, 0(s0)
#elif FAULT_CASE == 2
  lui t0, 0x40000
  jalr zero, 0(t0)
#elif FAULT_CASE == 3
  .word 0xffffffff
#elif FAULT_CASE == 4
  lui s0, 0x40000
  sw zero, 0(s0)
#else
  auipc t0, 0
  lui s0, 0x80000
  addi s0, s0, 0x400
  addi t0, zero, 7
  sw t0, 0(s0)
  lw t1, 0(s0)
#if SPLIT
  sw t0, 1(s0)
  lw t1, 1(s0)
#endif
  bne t0, t1, failed
  jal ra, passed
failed:
  addi a0, zero, 1
  ebreak
passed:
  csrrs t1, mstatus, zero
  addi a0, zero, 0
  ebreak
#endif
"""


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def run_case(args, name, *, split=0, fault=0):
    elf = args.build_dir / f"{name}.elf"
    image = elf.with_suffix(".bin")
    subprocess.run([
        "riscv64-unknown-elf-gcc", "-march=rv32e_zicsr", "-mabi=ilp32e",
        "-nostdlib", "-nostartfiles", "-Wl,-Ttext=0x80000000",
        "-Wl,-e,_start", "-Wl,--build-id=none", f"-DSPLIT={split}",
        f"-DFAULT_CASE={fault}", "-x", "assembler-with-cpp", "-", "-o", str(elf),
    ], input=SOURCE, text=True, check=True, capture_output=True)
    subprocess.run(["riscv64-unknown-elf-objcopy", "-O", "binary", str(elf),
                    str(image)], check=True)
    command = [str(args.npc.resolve()), "-b", f"--log={args.build_dir / (name + '.log')}"]
    if args.diff:
        command.append(f"--diff={args.diff.resolve()}")
    result = subprocess.run(command + [str(image)], text=True,
                            capture_output=True, timeout=15)
    output = re.sub(r"\x1b\[[0-9;]*m", "", result.stdout + result.stderr)
    (args.build_dir / f"{name}.output").write_text(output)
    require("PERF: cycle check" in output, f"{name}: missing cycle accounting")
    require("(MISMATCH)" not in output, f"{name}: inconsistent counters\n{output}")
    if fault:
        require(result.returncode != 0 and "npc: ABORT" in output,
                f"{name}: expected abort\n{output}")
        return output
    require(result.returncode == 0 and "npc: HIT GOOD TRAP" in output,
            f"{name}: expected successful execution\n{output}")
    classes = {}
    for match in re.finditer(
            r"PERF: class (\w+) count=(\d+) share=[\d.]+% total_cycles=(\d+) "
            r"exec_cycles=(\d+) avg_total=[\d.]+ avg_exec=[\d.]+ avg_fetch=[\d.]+", output):
        classes[match[1]] = tuple(map(int, match.groups()[1:]))
    expected = dict(alu=3, load=1 + split, store=1 + split, branch=1, jump=1,
                    csr=1, system=1, lui=1, auipc=1)
    require(set(classes) == set(expected), f"{name}: missing category rows")
    for category, count in expected.items():
        actual, total, execute = classes[category]
        require(actual == count, f"{name}: {category} count {actual} != {count}")
        require(total > execute >= count, f"{name}: invalid {category} interval")
        if category not in ("load", "store"):
            require(execute == count, f"{name}: non-memory execution must take one cycle")
        else:
            latency = re.search(rf"PERF: lsu {category} count=(\d+) latency_cycles=(\d+)", output)
            require(latency and int(latency[1]) == count and int(latency[2]) == execute - count,
                    f"{name}: {category} latency must exclude the final DONE cycle")
    if args.expect_no_delay:
        fetch_intervals = {(total - execute) / count for count, total, execute in classes.values()}
        # Preparation (1), immediate AR (1), response delay/receive (2).
        require(fetch_intervals == {4}, f"{name}: no-delay RAM fetch must take four cycles")
        # Aligned load/store occupy 7/8 execution cycles. A second beat adds
        # four read cycles or five write cycles, without repeating IDLE/CHECK.
        require(classes["load"][2] == 7 + 11 * split,
                f"{name}: unexpected load execution cycles")
        require(classes["store"][2] == 8 + 13 * split,
                f"{name}: unexpected store execution cycles")
    print(f"PASS: {name}: exact instruction mix, execution/latency accounting, all consistency checks")
    return classes


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--npc", type=Path, default=NPC / "build/top")
    parser.add_argument("--build-dir", type=Path, default=NPC / "build/perf-tests")
    parser.add_argument("--diff", type=Path, help="optional NEMU reference shared library")
    parser.add_argument("--expect-no-delay", action="store_true")
    args = parser.parse_args()
    args.build_dir = args.build_dir.resolve()
    args.build_dir.mkdir(parents=True, exist_ok=True)
    aligned = run_case(args, "aligned")
    split = run_case(args, "split", split=1)
    if args.expect_no_delay:
        for category in ("load", "store"):
            require(split[category][2] > 2 * aligned[category][2],
                    f"{category}: a split operation must take longer than an aligned one")
        print("PASS: split accesses count as one CPU operation with additional latency")
    for fault, name in enumerate(("load-fault", "fetch-fault", "invalid", "store-fault"), 1):
        output = run_case(args, name, fault=fault)
        require(re.search(r"class_total=\d+ \+ pending=[1-9]\d* ", output),
                f"{name}: unfinished instruction must remain outside class averages")
        if fault in (1, 4):
            require("PERF: lsu all count=0 latency_cycles=0 " in output,
                    "failed LSU request must not contribute to completed-access averages")
            require(re.search(r"pending_lsu=[1-9]\d* ", output),
                    "failed LSU request must retain its unfinished latency")
        print(f"PASS: {name}: unfinished work retained, completed averages unaffected")


if __name__ == "__main__":
    main()
