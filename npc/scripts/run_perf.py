#!/usr/bin/env python3
"""Run a trace-enabled NPC and plot its new CSV, preserving simulation failures."""
import argparse
from pathlib import Path
import subprocess
import sys


def effective_trace(command, default):
    """Match getopt's last explicit path, including the --option FILE form."""
    path = default
    for index, argument in enumerate(command[1:], 1):
        if argument == "--":
            break
        if argument.startswith("--perf-trace="):
            path = argument.partition("=")[2]
        elif argument == "--perf-trace" and index + 1 < len(command):
            path = command[index + 1]
    # Leave an empty explicit argument to NPC's own option validation.
    return Path(path).absolute() if str(path) else None


def signature(path):
    try:
        info = path.stat()
        return info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns
    except FileNotFoundError:
        return None


def run(args):
    command = args.command
    if command and command[0] == "--":
        command = command[1:]
    if not command:
        raise ValueError("NPC command is required after --")
    if args.end < 0:
        raise ValueError("--end must be nonnegative")
    trace = effective_trace(command, args.trace)
    before = None
    if trace is not None:
        trace.parent.mkdir(parents=True, exist_ok=True)
        before = signature(trace)
    # Explicit arguments follow the default, so NPC and the plotter agree on
    # the last override. subprocess receives argv directly, without a shell.
    result = subprocess.run([command[0], f"--perf-trace={args.trace}", *command[1:]])
    status = result.returncode if result.returncode >= 0 else 128 - result.returncode
    if trace is None or signature(trace) in (None, before):
        # --help and errors before reset must not plot an old run's CSV.
        return status
    print(f"perf: CSV saved to {trace}", flush=True)
    plotter = Path(__file__).with_name("plot_perf.py")
    image = trace.with_suffix(".png")
    if image == trace:
        image = Path(str(trace) + ".png")
    try:
        # A fresh CSV supersedes the old preview even if this plot fails.
        image.unlink(missing_ok=True)
        plot = subprocess.run([str(args.plot_python), str(plotter), str(trace),
                               "--end", str(args.end), "--output", str(image)])
        plot_status = plot.returncode if plot.returncode >= 0 else 128 - plot.returncode
    except OSError as error:
        print(f"perf: CSV saved, but plotting with {args.plot_python} failed: {error}\n"
              "Create npc/.venv-perf and install matplotlib once; "
              "see npc/docs/performance-counters.md.", file=sys.stderr)
        plot_status = 1
    # A failed guest remains failed even if its partial trace plots correctly.
    return status or plot_status


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--trace", required=True, help="default CSV path")
    parser.add_argument("--plot-python", type=Path, required=True)
    parser.add_argument("--end", type=int, default=200)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    try:
        return run(args)
    except (OSError, ValueError) as error:
        parser.exit(1, f"perf: {error}\n")


if __name__ == "__main__":
    sys.exit(main())
