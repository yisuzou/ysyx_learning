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
instruction/function/memory/device tracing, watchpoints, difftest, waveform
generation, and serial/RTC devices and addresses.

The former `ITRACE=`, `FTRACE=`, `MTRACE=`, and `TRACE_FLAGS=` Make variables
are rejected instead of being silently ignored; select their Kconfig
equivalents.

Run an image in batch mode:

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

Pass an empty `ARGS` value to enter SDB, or use the NEMU-compatible command-line
options `-b`, `-l FILE`, `-d REF_SO`, and `-p PORT` directly:

```sh
make -C npc sim IMG=/path/to/image.bin ARGS=
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

Instruction fetch uses `pmem_ifetch()` and cannot access devices. The
single-cycle LSU performs each data read once on the falling edge and commits on
the rising edge, so MMIO callbacks no longer depend on a host-side
`side_effect` switch.

## RV32E compatibility

The current 32-register RTL can run and diff-test legal RV32E programs, but it
is not yet a strict RV32E implementation. After the RTL restricts the register
file and rejects references to `x16`-`x31`, the single-cycle host framework
needs no structural change. Keep `CPUState::gpr[32]` as the DUT observation
format: the unused slots remain zero. A regular RV32 NEMU reference is
recommended because RV32E is an instruction/register subset and its 33-word
difftest ABI already matches NPC.

When the RTL becomes strict RV32E, it must reject encodings that name
`x16`-`x31` and expose only committed architectural writes through DPI. If a
NEMU reference is configured with `CONFIG_RVE=y`, its difftest ABI changes to
`16 GPRs + PC`; NPC then needs a small 17-word register-copy adapter instead of
passing `CPUState` directly.

For a later multi-cycle or pipelined core, replace the assumption that one
`sim_exec_once()` retires one instruction with an explicit commit interface
(`valid`, `pc`, `next_pc`, register writeback, and trap information). Difftest,
watchpoints, statistics, and `device_update()` should run only on commit.
