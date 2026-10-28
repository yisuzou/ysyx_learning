#!/usr/bin/env python3
"""Plot NPC's per-cycle performance-counter CSV, with optional cycle bounds."""
import argparse
import csv
from pathlib import Path

DEFAULT_COUNTERS = ("commit", "fetched", "prepare", "ar_wait", "r_wait", "lsu_wait")


def read_trace(path, counters, start, end):
    """Read only the requested columns/range; preserve every selected cycle."""
    cycles = []
    values = {name: [] for name in counters}
    with path.open(newline="") as source:
        reader = csv.DictReader(source)
        fields = reader.fieldnames or []
        if len(fields) != len(set(fields)):
            raise ValueError("duplicate CSV column names")
        missing = {"cycle", *counters} - set(fields)
        if missing:
            raise ValueError(f"missing CSV columns: {', '.join(sorted(missing))}")
        previous_cycle = None
        for line, row in enumerate(reader, 2):
            try:
                cycle = int(row["cycle"])
                if cycle < 0 or (previous_cycle is not None and cycle != previous_cycle + 1):
                    raise ValueError("cycles must be nonnegative and consecutive")
                previous_cycle = cycle
                if end is not None and cycle > end:
                    break
                if cycle < start:
                    continue
                sample = [int(row[name]) for name in counters]
                if None in row or any(value < 0 for value in sample):
                    raise ValueError("expected nonnegative integer counters")
            except (ValueError, TypeError) as error:
                raise ValueError(f"invalid CSV row {line}: {error}") from error
            cycles.append(cycle)
            for name, value in zip(counters, sample):
                values[name].append(value)
    if not cycles:
        raise ValueError("no samples in the selected cycle range")
    return cycles, values


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("trace", type=Path)
    parser.add_argument("--output", type=Path, help="default: TRACE with .png suffix")
    parser.add_argument("--start", type=int, default=0, help="first guest cycle, inclusive")
    parser.add_argument("--end", type=int, help="last guest cycle, inclusive")
    parser.add_argument("--counters", nargs="+", default=DEFAULT_COUNTERS,
                        help="CSV columns to plot")
    parser.add_argument("--mode", choices=("cumulative", "delta", "both"), default="both")
    args = parser.parse_args()
    if args.start < 0 or (args.end is not None and args.end < args.start):
        parser.error("require 0 <= start <= end")
    if len(set(args.counters)) != len(args.counters) or "cycle" in args.counters:
        parser.error("choose distinct counter names other than cycle")
    output = args.output or args.trace.with_suffix(".png")
    if output.resolve() == args.trace.resolve():
        parser.error("output must differ from the input CSV")
    try:
        cycles, values = read_trace(args.trace, args.counters, args.start, args.end)
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        parser.exit(1, "matplotlib is required; install it in a virtual environment with pip install matplotlib\n")
    except (OSError, ValueError) as error:
        parser.exit(1, f"perf plot: {error}\n")

    modes = ("cumulative", "delta") if args.mode == "both" else (args.mode,)
    fig, axes = plt.subplots(len(modes), 1, sharex=True, squeeze=False,
                             figsize=(12, 3.5 * len(modes)))
    for ax, mode in zip(axes[:, 0], modes):
        for name, samples in values.items():
            x, y = cycles, samples
            if mode == "delta":
                x = cycles[1:]
                y = [right - left for left, right in zip(samples, samples[1:])]
            ax.step(x, y, where="post", label=name)
        ax.set_ylabel("Cumulative count" if mode == "cumulative" else "Increment per cycle")
        ax.grid(True, alpha=0.3)
        ax.legend(loc="best")
    axes[-1, 0].set_xlabel("Guest cycle (reset/shutdown excluded)")
    fig.suptitle(args.trace.name)
    fig.tight_layout()
    try:
        fig.savefig(output, dpi=160)
    except (OSError, ValueError) as error:
        parser.exit(1, f"perf plot: {error}\n")
    finally:
        plt.close(fig)
    print(f"Saved {output} ({len(cycles)} samples, cycles {cycles[0]}..{cycles[-1]})")


if __name__ == "__main__":
    main()
