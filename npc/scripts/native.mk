-include $(NPC_HOME)/../Makefile
include $(NPC_HOME)/scripts/build.mk

IMG ?=
ELF ?=
DEFAULT_ARGS := --log=$(BUILD_DIR)/npc-log.txt
DEFAULT_ARGS += $(if $(CONFIG_BATCH_MODE),-b)
ARGS ?= $(DEFAULT_ARGS)
DIFF ?= $(if $(CONFIG_DIFFTEST),$(call remove_quote,$(CONFIG_DIFFTEST_REF_PATH)),)
DIFF_PORT ?= $(if $(CONFIG_DIFFTEST_PORT),$(CONFIG_DIFFTEST_PORT),1234)
NPC_EXEC := $(BINARY) $(ARGS) \
	$(if $(DIFF),--diff=$(DIFF) --port=$(DIFF_PORT)) \
	$(if $(ELF),--elf=$(ELF)) $(IMG)

sim: $(BINARY)
	$(call git_commit, "sim RTL") # DO NOT REMOVE THIS LINE!!!
	@test -n "$(IMG)" || \
		(echo "Usage: make sim IMG=<image> [ELF=<elf>] [ARGS=...]" && exit 1)
	$(NPC_EXEC)

wave:
	gtkwave -7 build/wave.fst config.gtkw
onekey:
	$(NPC_HOME)/scripts/regress.sh
run: sim

# 仿真 + make sta 全部成功后，自动追加 perf-log.md；详见 npc/docs/perf-log.md。
# Usage: make perf DESC="说明" [PERF_ARCH=riscv32e-npc]
# 说明通过环境传递，避免其中的引号、$ 或反引号被 recipe 的 shell 再次解释。
export PERF_DESC = $(DESC)
export PERF_ARCH
export PYTHON ?= python3
perf:
	@"$(NPC_HOME)/scripts/perf.sh" "$$PERF_DESC" "$$PERF_ARCH"

.PHONY: sim run perf
