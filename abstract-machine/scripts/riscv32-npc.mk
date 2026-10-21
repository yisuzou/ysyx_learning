include $(AM_HOME)/scripts/isa/riscv.mk
include $(AM_HOME)/scripts/platform/npc.mk
# RV32I (32 GPRs), no M extension: gcc emits __mulsi3/__udivsi3/... calls,
# resolved by the vendored soft routines below plus the ELF toolchain libgcc.
COMMON_CFLAGS += -march=rv32i_zicsr -mabi=ilp32  # overwrite
LDFLAGS       += -melf32lriscv                    # overwrite
LINKAGE       += $(shell riscv64-unknown-elf-gcc -march=rv32i_zicsr -mabi=ilp32 -print-libgcc-file-name)

AM_SRCS += riscv/npc/libgcc/div.S \
           riscv/npc/libgcc/muldi3.S \
           riscv/npc/libgcc/multi3.c \
           riscv/npc/libgcc/ashldi3.c \
           riscv/npc/libgcc/unused.c
