-include $(NPC_HOME)/../Makefile
include $(NPC_HOME)/scripts/build.mk

IMG ?=
ELF ?=
ARGS ?= -b --log=$(BUILD_DIR)/npc-log.txt
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

run: sim

.PHONY: sim run
