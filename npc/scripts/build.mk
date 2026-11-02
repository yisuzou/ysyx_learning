VERILATOR ?= verilator
unexport VERILATOR_ROOT

TOP ?= top
include $(NPC_HOME)/scripts/icache.mk
BUILD_DIR = $(NPC_HOME)/build
CONFIG_HASH := $(shell test -f $(NPC_HOME)/.config && \
	sha256sum $(NPC_HOME)/.config | cut -c1-12 || printf noconfig)
OBJ_DIR = $(BUILD_DIR)/obj_dir-$(CONFIG_HASH)-i$(ICACHE_LINES)-b$(ICACHE_BLOCK_BYTES)
CONFIG_BINARY = $(OBJ_DIR)/$(TOP)
BINARY = $(BUILD_DIR)/$(TOP)
ICACHE_CONFIG_FILE = $(BUILD_DIR)/icache-config

CONFIG_DEPS = $(NPC_HOME)/.config \
	$(NPC_HOME)/include/config/auto.conf \
	$(NPC_HOME)/include/generated/autoconf.h
BUILD_DEPS = $(NPC_HOME)/Makefile $(FILELIST_MK) \
	$(NPC_HOME)/scripts/build.mk $(NPC_HOME)/scripts/native.mk \
	$(NPC_HOME)/scripts/icache.mk

INC_PATH := $(NPC_HOME)/include $(INC_PATH)
CXXFLAGS += -std=c++17 -Wall -Werror $(addprefix -I,$(INC_PATH))
LDFLAGS += -lreadline -ldl
VERILATOR_TRACE_FLAGS = $(if $(CONFIG_WAVE_TRACE),--trace-fst,)
VERILATOR_RTL_FLAGS = $(if $(CONFIG_RVE),-DCONFIG_RVE,)
VERILATOR_RTL_FLAGS += $(if $(CONFIG_PERF_COUNTERS),-DCONFIG_PERF_COUNTERS,)
ifeq ($(TOP),top)
VERILATOR_RTL_FLAGS += -GRANDOM_DELAY=$(if $(CONFIG_RANDOM_DELAY),1,0)
VERILATOR_RTL_FLAGS += -GICACHE_LINES=$(ICACHE_LINES) -GICACHE_BLOCK_BYTES=$(ICACHE_BLOCK_BYTES)
# Keep the RTL XBAR address map and device rules in step with the host Kconfig configuration.
VERILATOR_RTL_FLAGS += -GPMEM_BASE=$(CONFIG_MBASE) -GPMEM_SIZE=$(CONFIG_MSIZE)
VERILATOR_RTL_FLAGS += -GHAS_SERIAL=$(if $(and $(CONFIG_DEVICE),$(CONFIG_HAS_SERIAL)),1,0)
VERILATOR_RTL_FLAGS += -GHAS_TIMER=$(if $(and $(CONFIG_DEVICE),$(CONFIG_HAS_TIMER)),1,0)
VERILATOR_RTL_FLAGS += -GSERIAL_MMIO=$(if $(CONFIG_SERIAL_MMIO),$(CONFIG_SERIAL_MMIO),0x10000000)
VERILATOR_RTL_FLAGS += -GRTC_MMIO=$(if $(CONFIG_RTC_MMIO),$(CONFIG_RTC_MMIO),0x10000048)
endif
VERILATOR_INPUTS = $(VSRCS) $(SRCS)

$(shell mkdir -p $(BUILD_DIR))

# Track the selected configuration even when its object tree and executable
# were built earlier, so switching back refreshes the shared build/top.
$(ICACHE_CONFIG_FILE): FORCE_ICACHE_CONFIG
	@printf '%s\n' '$(ICACHE_LINES) $(ICACHE_BLOCK_BYTES)' | cmp -s - $@ || \
		printf '%s\n' '$(ICACHE_LINES) $(ICACHE_BLOCK_BYTES)' > $@

default: $(BINARY)
all: default

$(BINARY): $(CONFIG_BINARY) $(ICACHE_CONFIG_FILE)
	cp $(CONFIG_BINARY) $@

# Each object tree also owns its executable. Reusing a cached configuration
# must copy that executable, not rely on relinking a newer shared build/top.
$(CONFIG_BINARY): $(VERILATOR_INPUTS) $(CONFIG_DEPS) $(BUILD_DEPS)
	$(VERILATOR) $(VERILATOR_CFLAGS) --cc --assert \
		--top-module $(TOP) $(VERILATOR_INPUTS) \
		$(addprefix -CFLAGS ,$(CXXFLAGS)) \
		$(addprefix -LDFLAGS ,$(LDFLAGS)) \
		$(VERILATOR_TRACE_FLAGS) $(VERILATOR_RTL_FLAGS) \
		--Mdir $(OBJ_DIR) --exe -o $(abspath $@) --build
	@touch $@

LINT_FLAGS ?= -Wall -Wno-SYNCASYNCNET
lint:
	$(VERILATOR) --lint-only $(LINT_FLAGS) $(VERILATOR_RTL_FLAGS) \
		--top-module $(TOP) $(VSRCS)

clean:
	rm -rf $(BUILD_DIR)

.PHONY: default all lint clean FORCE_ICACHE_CONFIG
