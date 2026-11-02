#!/usr/bin/env python3
"""Software reference model for the icache_ref RTL (direct-mapped, blocking).

Independent second implementation: it shares no code with icache_tb.sv, so the
two must agree on every transaction for the cache policy to be considered
specified rather than "whatever the RTL happened to do".

  selftest <pctrace.txt>  replay the TB dump, compare with the RTL's behaviour
  replay <npc-log>        feed a real ITRACE stream, report hit statistics
"""

import argparse
import re
import sys

LINE_BYTES = 16
LINES = 16
LINE_SHIFT = 4           # log2(LINE_BYTES)
IDX_MASK = LINES - 1     # index = line_addr & IDX_MASK (tag beyond bit 8)


class ICache:
    """Strictly follows the RTL: one line per index, fill on complete burst only."""

    def __init__(self, lines=LINES):
        self.lines = lines
        self.valid = [False] * lines
        self.tag = [None] * lines
        self.reset_count = 0

    def reset(self):
        self.__init__(self.lines)
        self.reset_count += 1

    def access(self, addr):
        """Return (hit, index, tag). The model never fetches: it only predicts."""
        line_addr = addr >> LINE_SHIFT
        index = line_addr & (self.lines - 1)
        tag = line_addr >> (self.lines - 1).bit_length()
        hit = self.valid[index] and self.tag[index] == tag
        return hit, index, tag

    def refill(self, index, tag):
        self.valid[index] = True
        self.tag[index] = tag


class CapacityModel:
    """Every line kept: separates compulsory misses from conflict/capacity misses."""

    def __init__(self):
        self.seen = set()

    def access(self, addr):
        line = addr >> LINE_SHIFT
        hit = line in self.seen
        self.seen.add(line)
        return hit


def split_case_name(line):
    return line.split("# case", 1)[1].strip()


def cmd_selftest(path, verbose):
    cache = ICache()
    n = mism = skipped = 0
    bad = []
    case = "<prologue>"
    skip_cases = ("10-", "15-")   # mid-burst reset / invalidate: not expressible
    with open(path) as f:
        for raw in f:
            tok = raw.strip()
            if not tok:
                continue
            if tok.startswith("# case"):
                case = split_case_name(raw)
                cache.reset()
                continue
            if tok.startswith("#"):
                continue
            if case.startswith(skip_cases):
                skipped += 1
                continue
            addr_s, hit_s, bursts_s, beats_s, _lat, code_s = tok.split()
            addr = int(addr_s, 16)
            dut_hit = hit_s == "1"
            dut_bursts, dut_beats = int(bursts_s), int(beats_s)
            hit, index, tag = cache.access(addr)
            # A refill only happens for a clean full burst with OKAY on every
            # beat; partial or errored bursts leave the line invalid (the RTL
            # commit rule).
            if (not hit and dut_bursts == 1
                    and dut_beats == LINE_BYTES // 4 and code_s == "0"):
                cache.refill(index, tag)
            n += 1
            if hit != dut_hit or (0 if hit else 1) != dut_bursts:
                mism += 1
                if len(bad) < 20:
                    bad.append(f"  case {case} addr 0x{addr:08x}: "
                               f"model hit={int(hit)} bursts={0 if hit else 1}, "
                               f"rtl hit={int(dut_hit)} bursts={dut_bursts}")
    print(f"selftest: {n} transactions compared, {mism} mismatches, "
          f"{skipped} skipped (reset/invalidate cases)")
    for line in bad:
        print(line)
    print(f"final model state: valid lines "
          f"{sum(1 for v in cache.valid if v)}/{cache.lines}")
    return 1 if mism else 0


PC_RE = re.compile(r"^0x([0-9a-fA-F]+):(?: [0-9a-fA-F]{2}){4}")


def cmd_replay(path, lines, verbose):
    cache = ICache(lines)
    cap = CapacityModel()
    total = hits = misses = compulsory = conflict = unaligned = 0
    per_line = {}
    with open(path, errors="replace") as f:
        for raw in f:
            m = PC_RE.match(raw)
            if not m:
                continue
            addr = int(m.group(1), 16)
            total += 1
            if addr & 3:
                unaligned += 1
                continue
            hit, index, tag = cache.access(addr)
            if hit:
                hits += 1
            else:
                misses += 1
                if not cap.access(addr):
                    compulsory += 1
                else:
                    conflict += 1
                cache.refill(index, tag)
            if verbose:
                key = addr >> LINE_SHIFT
                per_line[key] = per_line.get(key, 0) + 1
    if total == 0:
        print("replay: no instruction trace lines found (expected '0xPC: xx xx xx xx ...')")
        return 1
    beats = misses * (LINE_BYTES // 4)
    print(f"replay: {total} fetches from {path}")
    print(f"  lines in model         : {lines} x {LINE_BYTES}B "
          f"({lines * LINE_BYTES} B, direct-mapped)")
    print(f"  hits                   : {hits} ({100.0 * hits / total:.2f}%)")
    print(f"  misses                 : {misses} ({100.0 * misses / total:.2f}%)")
    print(f"    compulsory           : {compulsory}")
    print(f"    conflict/capacity    : {conflict}")
    print(f"  unaligned (ignored)    : {unaligned}")
    print(f"  AXI beats fetched      : {beats} words -> "
          f"{beats / total:.3f} words/fetch (no cache would be 1.000)")
    if verbose and per_line:
        top = sorted(per_line.items(), key=lambda kv: -kv[1])[:10]
        print("  hottest lines:")
        for key, cnt in top:
            print(f"    0x{key << LINE_SHIFT:08x} : {cnt} fetches")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("selftest", help="compare against the TB dump")
    a.add_argument("trace")
    a.add_argument("-v", action="store_true")
    b = sub.add_parser("replay", help="estimate on a real ITRACE stream")
    b.add_argument("trace")
    b.add_argument("--lines", type=int, default=LINES)
    b.add_argument("-v", action="store_true")
    ns = ap.parse_args()
    if ns.cmd == "selftest":
        sys.exit(cmd_selftest(ns.trace, ns.v))
    sys.exit(cmd_replay(ns.trace, ns.lines, ns.v))


if __name__ == "__main__":
    main()
