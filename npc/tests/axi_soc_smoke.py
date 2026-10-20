#!/usr/bin/env python3
"""Build small RV32E images and check the integrated AXI fault/commit path."""
import argparse
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--npc", type=Path,
                        default=Path(__file__).resolve().parents[1] / "build/top")
    parser.add_argument("--build-dir", type=Path, default=Path("/tmp/npc-axi-soc"))
    args = parser.parse_args()
    args.build_dir.mkdir(parents=True, exist_ok=True)
    source = Path(__file__).with_suffix(".S")
    faults = {
        1: ("load", "0x40000000", 3),
        2: ("store", "0x40000000", 3),
        3: ("store", "0x10000003", 2),
        4: ("store", "0x10000048", 3),  # RTC unmapped until CLINT

        5: ("instruction fetch", "0x40000000", 3),
        6: ("store", "0x87ffffff", 3),
        7: ("load", "0x10000000", 2),
        8: ("instruction fetch", "0x10000048", 3),
        9: ("store", "0x10000000", 2),    # sb @+1: lane 1 rejected (word addr)
        10: ("store", "0x10000000", 2),   # UART: halfword rejected
        11: ("load", "0x10000048", 3),    # RTC unmapped until CLINT
    }
    for case in range(len(faults) + 1):
        elf = args.build_dir / f"case-{case}.elf"
        image = elf.with_suffix(".bin")
        subprocess.run([
            "riscv64-unknown-elf-gcc", "-march=rv32e_zicsr", "-mabi=ilp32e",
            "-nostdlib", "-nostartfiles", "-Wl,-Ttext=0x80000000",
            "-Wl,-e,_start", "-Wl,--build-id=none", f"-DFAULT_CASE={case}",
            str(source), "-o", str(elf),
        ], check=True)
        subprocess.run(["riscv64-unknown-elf-objcopy", "-O", "binary",
                        str(elf), str(image)], check=True)
        result = subprocess.run([
            str(args.npc.resolve()), "-b",
            f"--log={args.build_dir / f'case-{case}.log'}", str(image),
        ], text=True, capture_output=True, timeout=10)
        output = result.stdout + result.stderr
        (args.build_dir / f"case-{case}.output").write_text(output)
        if case == 0:
            valid = (result.returncode == 0 and "HIT GOOD TRAP" in output
                     and result.stderr == "AXI\n")
            label = "UART/CSR/ecall/mret"
        else:
            op, addr, resp = faults[case]
            valid = (result.returncode != 0 and "ABORT" in output
                     and f"AXI4-Lite {op} error:" in output
                     and f"addr = {addr}, resp = {resp}" in output
                     and "possible bus deadlock" not in output
                     and "HIT GOOD TRAP" not in output)
            label = f"{op} fault at {addr}, response {resp}"
        if not valid:
            raise SystemExit(f"FAIL: {label}\n{output}")
        print(f"PASS: {label}")


if __name__ == "__main__":
    main()
