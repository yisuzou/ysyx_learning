#!/usr/bin/env python3
"""Compile independent debugging exercises and keep logs/waves for inspection."""
import argparse
import subprocess
from pathlib import Path

NPC = Path(__file__).resolve().parents[1]
SOURCES = {
    "case1": ["LSU.v", "random_delay.v"],
    "case2": ["exu_stage.v", "EXU.v", "BranchUnit.v"],
    "case3": ["WBU.v"],
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("case", choices=["all", *SOURCES], nargs="?", default="all")
    parser.add_argument("--rtl-dir", type=Path, default=NPC / "vsrc")
    parser.add_argument("--out-dir", type=Path, default=NPC / "build/debug-lab")
    args = parser.parse_args()
    rtl = args.rtl_dir.resolve()
    output = args.out_dir.resolve()
    cases = list(SOURCES) if args.case == "all" else [args.case]
    failed = False
    for case in cases:
        work = output / case
        work.mkdir(parents=True, exist_ok=True)
        image = work / "sim.vvp"
        wave = work / f"{case}.vcd"
        # Never let an old successful waveform masquerade as this run's output.
        wave.unlink(missing_ok=True)
        command = ["iverilog", "-g2005", "-Wall", "-Wno-timescale",
                   "-s", f"debug_lab_{case}", "-o", str(image),
                   str(NPC / f"tests/debug_lab_{case}.v")]
        command.extend(str(rtl / name) for name in SOURCES[case])
        try:
            build = subprocess.run(command, cwd=work, capture_output=True,
                                   text=True, timeout=30)
            (work / "build.log").write_text(build.stdout + build.stderr)
            if build.returncode:
                print(f"{case}: BUILD ERROR — {work / 'build.log'}")
                failed = True
                continue
            run = subprocess.run(["vvp", str(image)], cwd=work,
                                 capture_output=True, text=True, timeout=15)
            log = run.stdout + run.stderr
            (work / "run.log").write_text(log)
            passed = (run.returncode == 0 and "FAIL:" not in log and
                      log.splitlines().count(f"PASS: {case}") == 1)
            failed |= not passed
            print(f"{case}: {'PASS' if passed else 'FAIL'}")
            print(log.strip())
            print(f"Wave: {wave}")
        except (OSError, subprocess.TimeoutExpired) as error:
            (work / "error.log").write_text(str(error))
            print(f"{case}: TOOL ERROR — {work / 'error.log'}")
            failed = True
    return int(failed)


if __name__ == "__main__":
    raise SystemExit(main())
