# NPC

NPC uses a NEMU-style host framework around the minirv RTL:

```text
csrc/
  cpu/              execution loop and difftest DUT
  device/           NEMU-style device maps, MMIO, serial, and RTC
  isa/minirv/       architectural register interface
  memory/           physical memory and MMIO
  monitor/          argument parsing and SDB
  sim/              Verilator clock/reset adapter
  utils/            state, timer, and logging
include/             shared interfaces
vsrc/                minirv RTL
scripts/             Kconfig, Verilator build, and native run rules
```

The top-level Makefile follows NEMU's source-selection flow. It includes every
`filelist.mk`, resolves `SRCS-y`/`DIRS-y` and their blacklists, then passes the
result to `scripts/build.mk`. Common host modules are declared in
`csrc/filelist.mk`, configured devices in `csrc/device/filelist.mk`, and RTL in
`vsrc/filelist.mk`. Add new modules through the nearest filelist rather than
editing the top-level build rules.

Set the project environment before building:

```sh
export NEMU_HOME=$PWD/nemu
export AM_HOME=$PWD/abstract-machine
export NPC_HOME=$PWD/npc
make -C npc defconfig
make -C npc
```

Use `make -C npc menuconfig` to change the configuration. It generates the
same `.config`, `include/config/auto.conf`, and
`include/generated/autoconf.h` interfaces as NEMU. The menu controls memory,
instruction/function/memory/device tracing, random AXI delays, watchpoints,
difftest, waveform generation, and serial/RTC devices and addresses.

The former `ITRACE=`, `FTRACE=`, `MTRACE=`, and `TRACE_FLAGS=` Make variables
are rejected instead of being silently ignored; select their Kconfig
equivalents.

The **Run in batch mode by default** Kconfig option controls whether the
default simulator arguments include `-b`. With the default configuration,
running an image immediately enters batch execution:

```sh
make -C npc sim IMG=/path/to/image.bin
```

When `FTRACE` is enabled in `menuconfig`, pass the matching unstripped ELF file:

```sh
make -C npc sim IMG=/path/to/image.bin ELF=/path/to/image.elf
```

AM `ARCH=minirv-npc run` targets pass their generated ELF automatically when
NPC's current `.config` enables `FTRACE`. NPC also accepts the NEMU-compatible
`-e FILE` or `--elf=FILE` command-line option.

Disable that option to enter interactive SDB by default. An explicit `ARGS`
value overrides the configured default for one invocation, so `ARGS=` enters
SDB even when batch mode is configured, while `ARGS=-b` requests batch mode
when it is not. NPC accepts the NEMU-compatible command-line options `-b`,
`-l FILE`, `-d REF_SO`, and `-p PORT` directly:

```sh
make -C npc sim IMG=/path/to/image.bin ARGS=
```

## Regression tests

Run all AM cpu-tests followed by MicroBench's `train` workload:

```sh
npc/scripts/regress.sh
npc/scripts/regress.sh --cpu-tests 'add dummy unalign'
npc/scripts/regress.sh --timeout 3600
```

The script uses `ARCH=riscv32e-npc`, forces batch execution, and prints each
image's PASS/FAIL status and simulated cycle count (excluding reset and
shutdown). It continues after failures and exits nonzero if any case fails,
times out, or lacks a GOOD TRAP/cycle count. Each run saves build/test logs and
`summary.tsv` in a new `npc/build/regress-*` directory; use `--log-dir DIR` to
choose a directory. The default timeout is 1800 seconds per build/run.
`--help` lists the options and environment overrides.

Run other MicroBench workloads directly from their directory, for example:

```sh
cd am-kernels/benchmarks/microbench
make ARCH=riscv32e-npc run mainargs=test
```

## Differential testing

Build NEMU once with its reference configuration, then restore the desired NEMU
configuration if NEMU is also used as a standalone DUT:

```sh
make -C nemu riscv32-ref_defconfig
make -C nemu clean
make -C nemu
```

Run NPC against the resulting reference:

```sh
make -C npc sim IMG=/path/to/image.bin \
  DIFF=$NEMU_HOME/build/riscv32-nemu-interpreter-so
```

Enable `ITRACE`, `FTRACE`, `MTRACE`, or `WAVE_TRACE` under **Testing and
Debugging** in `menuconfig`. Itrace records every committed PC and instruction
byte sequence in `build/npc-log.txt`; with `ARGS=` it also prints single-step
instructions to the terminal. Configuration changes select a content-addressed
Verilator object directory and rebuild `build/top` automatically, so no
`make clean` is needed.

Enable `DIFFTEST` in the same menu to use the configured NEMU reference and
port by default. `DIFF=...` and `DIFF_PORT=...` remain available as per-run
overrides when difftest support is compiled in.

## Devices

Devices use the same layering as NEMU:

```text
paddr_read/write -> mmio_read/write -> map_read/write -> device callback
```

`init_device()` initializes the map allocator and each device. `device_update()`
is called after every committed instruction. To add VGA, follow NEMU's pattern:
allocate control/framebuffer storage with `new_space()`, register it with
`add_mmio_map()`, call `init_vga()` from `init_device()`, and call
`vga_update_screen()` from `device_update()`.

Instruction fetch uses `pmem_ifetch()` and cannot access devices. MEM executes
accepted AXI transactions once and holds responses until handshake; stalls do
not repeat MMIO callbacks. Serial writes remain byte accesses and RTC reads
remain aligned 32-bit accesses.

## AXI4-Lite

IFU and LSU are 32-bit AXI4-Lite masters connected through `AXIArbiter` to a
single MEM slave. The read arbiter selects a master before forwarding AR and
holds ownership until the R handshake. Simultaneous requests use round-robin
priority, initially favoring IFU. LSU is the only writer, so AW/W/B pass through
independently of read arbitration. All interfaces currently use single beats;
IDs, bursts, and multiple outstanding transactions are future extensions.

IFU completes AR/R in IDLE, latches the instruction, then enters WAIT for
execution. It issues no new fetch while executing; its AWVALID, WVALID, and
BREADY outputs are zero. LSU latches a CPU request once, completes independent
AW/W handshakes for stores, and holds its result and `lsu_done` until the CPU
commits. MEM independently caches AW and W and writes only after both arrive.
R/B responses remain valid and stable under backpressure.

AXI-Lite reads return an aligned 32-bit word. LSU extracts byte/halfword loads
and applies sign extension; cross-word RAM accesses use two ordered single-beat
transactions. Stores shift data into byte lanes and generate 4-bit WSTRB.
Cross-word MMIO accesses and out-of-bounds split RAM accesses are rejected before
the first transaction. A failed second write beat does not roll back an already
completed first beat.

PC, GPR, CSR, DPI register mirroring, and ebreak use a common commit gate.
`debug_bus_error`, `debug_bus_error_addr`, `debug_bus_error_resp`, and
`debug_bus_error_op` report sticky IFU/LSU faults; operation values 0/1/2 mean
fetch/load/store. The host checks faults before commit, reports PC/address/RESP,
and aborts without retiring the failing instruction. Fault recovery requires
reset; RISC-V access-fault traps are not implemented.

RAM and current serial/RTC decode parameters are passed from Kconfig by the
Verilator build rules. To control random AXI delays, run `make -C npc menuconfig`
and select **Testing and Debugging -> Enable random AXI delays**
(`CONFIG_RANDOM_DELAY`). It is disabled by default for faster software tests;
enable it to exercise AXI handshakes and backpressure. The build passes the
setting to `top.RANDOM_DELAY`, which controls IFU, LSU, and MEM together.
After saving, the next build automatically selects the matching configuration
object directory and rebuilds `build/top`; no `make clean` is needed.
The synthesizable state machines contain no DPI calls; MEM's storage backend
and top's debug callbacks are simulation-only and excluded under `SYNTHESIS`.

Run protocol tests with Icarus Verilog, including delayed/undelayed LSU requests,
all access sizes/offsets, AW/W ordering, split faults, resets, round-robin reads,
and response backpressure:

```sh
make -C npc/tests
```

After building NPC, run integrated serial/RTC/CSR/trap and bus-error checks
with the default RAM/MMIO configuration and `riscv64-unknown-elf` tools:

```sh
make -C npc/tests soc-test
make -C am-kernels/tests/cpu-tests ARCH=riscv32e-npc run
```

The standalone test artifacts go to `/tmp/npc-axi-tests` and
`/tmp/npc-axi-soc`, outside the production source lists.

## RV32E compatibility

`CONFIG_RVE=y` makes the host state match NEMU's RV32E representation:
`16 GPRs + PC`. Register display, expression lookup, difftest comparison, and
DPI writeback bounds all use the same `NR_GPR=16`. The default
`riscv32-ref_defconfig` also enables `CONFIG_RVE`, so the NPC and NEMU
`difftest_regcpy()` layouts match exactly.

The RTL also follows `CONFIG_RVE`. RV32E builds select a 16-entry register file
and reject instruction encodings that name `x16`-`x31` in an operand field
actually used by that instruction format. Non-RV32E builds select the separate
32-entry implementation. The host reports an out-of-range DPI writeback as an
abort rather than corrupting `CPUState`.

If `CONFIG_RVE` is disabled, NPC returns to the `32 GPRs + PC` layout. NPC and
the selected reference must always use the same setting; mixing the 17-word and
33-word ABIs misplaces `pc` and can overrun the smaller state object.

`sim_exec_once()` advances one clock cycle. The host samples `diff_ifu_valid`
before the committing edge, and runs difftest, watchpoints, statistics, and
`device_update()` only for completed instructions. A future pipelined core
should extend this interface with explicit committed PC, next PC, register
writeback, and trap information.
