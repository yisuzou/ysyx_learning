AM_SRCS := platform/nemu/trm.c \
           platform/nemu/ioe/ioe.c \
           platform/nemu/ioe/timer.c \
           platform/nemu/ioe/input.c \
           platform/nemu/ioe/gpu.c \
           platform/nemu/ioe/audio.c \
           platform/nemu/ioe/disk.c \
           platform/nemu/mpe.c

CFLAGS    += -fdata-sections -ffunction-sections
CFLAGS    += -I$(AM_HOME)/am/src/platform/nemu/include
CFLAGS    += -g
LDSCRIPTS += $(AM_HOME)/scripts/linker.ld
LDFLAGS   += --defsym=_pmem_start=0x80000000 --defsym=_entry_offset=0x0
LDFLAGS   += --gc-sections -e _start
NEMUFLAGS += -l $(shell dirname $(IMAGE).elf)/nemu-log.txt
NM ?= $(CROSS_COMPILE)nm
#添加编译选项。自动化打字游戏。
ifeq ($(AUTOPLAY),1)
AUTOPLAY_CHARS_ADDR = 0x$(shell $(NM) $(IMAGE).elf | awk '$$3 == "chars" { print $$1; exit }')
#上面通过 nm 工具获取 chars 符号的地址，传给 NEMU 作为环境变量 NEMU_AUTOPLAY_CHARS。
NEMU_AUTOPLAY_ENV = NEMU_AUTOPLAY_CHARS=$(AUTOPLAY_CHARS_ADDR)
NEMU_AUTOPLAY_MAKE = AUTOPLAY=1
endif

# NEMU 的 nemu/.config 里若已经开启 CONFIG_FTRACE（编译期开关），
# 这里直接读取该文件、自动把本次构建生成的 elf 通过 -e 传给 NEMU.
ifeq ($(shell grep -qs '^CONFIG_FTRACE=y' $(NEMU_HOME)/.config && echo y),y)
NEMUFLAGS += -e $(IMAGE).elf
endif

MAINARGS_MAX_LEN = 64
MAINARGS_PLACEHOLDER = the_insert-arg_rule_in_Makefile_will_insert_mainargs_here
CFLAGS += -DMAINARGS_MAX_LEN=$(MAINARGS_MAX_LEN) -DMAINARGS_PLACEHOLDER=$(MAINARGS_PLACEHOLDER)

insert-arg: image
	@python $(AM_HOME)/tools/insert-arg.py $(IMAGE).bin $(MAINARGS_MAX_LEN) $(MAINARGS_PLACEHOLDER) "$(mainargs)"

image: image-dep
	@$(OBJDUMP) -S -d $(IMAGE).elf > $(IMAGE).txt
	@echo + OBJCOPY "->" $(IMAGE_REL).bin
	@$(OBJCOPY) -S --set-section-flags .bss=alloc,contents -O binary $(IMAGE).elf $(IMAGE).bin

run: insert-arg
	$(NEMU_AUTOPLAY_ENV) $(MAKE) -C $(NEMU_HOME) ISA=$(ISA) $(NEMU_AUTOPLAY_MAKE) run ARGS="$(NEMUFLAGS) " IMG=$(IMAGE).bin

gdb: insert-arg
	$(MAKE) -C $(NEMU_HOME) ISA=$(ISA) gdb ARGS="$(NEMUFLAGS)" IMG=$(IMAGE).bin

.PHONY: insert-arg
