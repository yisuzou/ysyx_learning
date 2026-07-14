# Copilot instructions for this repository

## Project overview

This is a ysyx learning workspace that vendors several teaching subprojects into one Git repository:

- `nemu/`: C-based full-system emulator. It is configured by Kconfig (`nemu/.config`) and built through `nemu/Makefile`.
- `abstract-machine/`: AbstractMachine runtime and build system. Programs provide `NAME`, `SRCS`, and `ARCH`, then include `$(AM_HOME)/Makefile`.
- `am-kernels/`: AM programs, tests, and benchmarks used to validate NEMU/NPC behavior.
- `npc/`: Verilator-based RTL simulator. Verilog lives in `npc/vsrc/`; the C++ harness and DPI memory/trap logic live in `npc/csrc/main.cpp`.
- `nvboard/` and `fceux-am/`: external support projects initialized by `init.sh`; they may be ignored by Git.

The top-level `Makefile` is not a build entry point; it only provides ysyx tracer commit helpers. Run `make` from subprojects.

## Environment setup

Most commands rely on ysyx environment variables. From the repository root:

```sh
export NEMU_HOME=$PWD/nemu
export AM_HOME=$PWD/abstract-machine
export NPC_HOME=$PWD/npc
export NVBOARD_HOME=$PWD/nvboard
```

`init.sh` initializes subprojects and appends these variables to `~/.bashrc`, but future sessions should prefer explicit exports in commands rather than assuming shell state.

## Build, run, test, and lint commands

Use these from the repository root unless noted otherwise.

```sh
# Configure NEMU before building if .config is missing or stale
make -C nemu menuconfig

# Build NEMU with the current nemu/.config
make -C nemu

# Run NEMU on an AM-generated image
make -C nemu run IMG=/path/to/image.bin ARGS="-b"

# Build the NPC Verilator simulator
make -C npc

# Lint NPC RTL
make -C npc lint

# Run NPC on an AM-generated image
make -C npc sim IMG=/path/to/image.bin

# Run all AM CPU tests on NEMU
make -C am-kernels/tests/cpu-tests ARCH=riscv32-nemu run

# Run a single AM CPU test on NEMU
make -C am-kernels/tests/cpu-tests ARCH=riscv32-nemu ALL=add run

# Run all AM CPU tests on NPC
make -C am-kernels/tests/cpu-tests ARCH=riscv32e-npc run

# Run a single AM CPU test on NPC
make -C am-kernels/tests/cpu-tests ARCH=riscv32e-npc ALL=add run

# Run AM tests or microbench directly
make -C am-kernels/tests/am-tests ARCH=riscv32-nemu run
make -C am-kernels/benchmarks/microbench ARCH=riscv32-nemu run

# Clean common generated outputs
make -C nemu clean
make -C npc clean
make -C am-kernels/tests/cpu-tests clean
```

AM uses `ARCH=<isa>-<platform>` to select both ISA and backend. For example, `riscv32-nemu` builds a RISC-V AM image and runs it through NEMU; `riscv32e-npc` builds for the NPC platform and invokes `make -C $(NPC_HOME) sim IMG=...`.

## Architecture notes

NEMU startup flows through `nemu/src/nemu-main.c`: `init_monitor()` parses CLI arguments, initializes memory/devices/ISA/difftest/SDB, loads an image at the reset vector, then `engine_start()` enters the SDB loop or runs directly for `CONFIG_TARGET_AM`.

NEMU source selection is configuration-driven. `nemu/Makefile` includes `nemu/src/filelist.mk` and every nested `filelist.mk`; those files add sources and include paths through `SRCS-y`, `DIRS-y`, and `DIRS-$(CONFIG_...)`. Check Kconfig options and filelists before assuming a source file is compiled.

The current RISC-V interpreter implementation is centered in `nemu/src/isa/riscv32/inst.c`. Instruction patterns use `INSTPAT(...)`, operand helpers fill `rd/src1/src2/imm`, and every instruction must leave `R(0) = 0`. Execution goes through `cpu_exec()` in `nemu/src/cpu/cpu-exec.c`, which handles itrace, difftest, watchpoints, device updates, and final statistics.

NEMU monitor commands are registered in `nemu/src/monitor/sdb/sdb.c`. Expression evaluation and watchpoints are separate SDB subsystems; commands should report parse/runtime failures to the monitor instead of silently continuing.

AbstractMachine is the bridge between tests and simulators. `abstract-machine/Makefile` compiles `SRCS` into `build/<NAME>-<ARCH>.elf` and platform scripts convert it to `.bin`. `abstract-machine/scripts/platform/nemu.mk` runs NEMU in batch mode with the generated image; `abstract-machine/scripts/platform/npc.mk` runs NPC with the generated image.

NPC's `npc/vsrc/top.v` wires the current single-cycle datapath: DPI instruction fetch from `pmem_read`, `IDU` decode/control, `EXU` execution, `WBU` PC/register writeback, and `LSU` DPI memory access. `npc/csrc/main.cpp` owns physical memory, MMIO for serial/RTC, reset at `0x80000000`, `npc_ebreak`, signal handling, and optional FST tracing to `npc/build/wave.fst`.

## Repository-specific conventions

- Build files use `-Wall -Werror`; warnings are treated as failures in NEMU, AM, and generated tests.
- NEMU and NPC build/run targets call the top-level `git_commit` tracer helper. Do not remove existing `$(call git_commit, ...)` lines, and expect some ysyx commands to touch tracer state.
- NEMU behavior is controlled by `nemu/.config`; features such as trace, watchpoints, devices, target mode, and difftest may be compiled out.
- Prefer adding NEMU sources through the appropriate `filelist.mk` rather than hard-coding them in `nemu/Makefile`.
- AM test aggregators such as `am-kernels/tests/cpu-tests/Makefile` generate temporary `Makefile.<test>` files. Use `ALL=<test> run` for one test instead of invoking generated files directly.
- NPC RTL top module defaults to `top` through `TOP ?= top`; pass `TOP=<module>` only when intentionally changing the Verilator top.
