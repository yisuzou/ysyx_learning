VERILATOR ?= verilator
unexport VERILATOR_ROOT

TOP ?= top
BUILD_DIR = $(NPC_HOME)/build
CONFIG_HASH := $(shell test -f $(NPC_HOME)/.config && \
	sha256sum $(NPC_HOME)/.config | cut -c1-12 || printf noconfig)
OBJ_DIR = $(BUILD_DIR)/obj_dir-$(CONFIG_HASH)
BINARY = $(BUILD_DIR)/$(TOP)

CONFIG_DEPS = $(NPC_HOME)/.config \
	$(NPC_HOME)/include/config/auto.conf \
	$(NPC_HOME)/include/generated/autoconf.h
BUILD_DEPS = $(NPC_HOME)/Makefile $(FILELIST_MK) \
	$(NPC_HOME)/scripts/build.mk $(NPC_HOME)/scripts/native.mk

INC_PATH := $(NPC_HOME)/include $(INC_PATH)
CXXFLAGS += -std=c++17 -Wall -Werror $(addprefix -I,$(INC_PATH))
LDFLAGS += -lreadline -ldl
VERILATOR_TRACE_FLAGS = $(if $(CONFIG_WAVE_TRACE),--trace-fst,)
VERILATOR_RTL_FLAGS = $(if $(CONFIG_RVE),-DCONFIG_RVE,)
VERILATOR_RTL_FLAGS += $(if $(CONFIG_PERF_COUNTERS),-DCONFIG_PERF_COUNTERS,)
ifeq ($(TOP),top)
VERILATOR_RTL_FLAGS += -GRANDOM_DELAY=$(if $(CONFIG_RANDOM_DELAY),1,0)
# Keep the RTL XBAR address map and device rules in step with the host Kconfig configuration.
VERILATOR_RTL_FLAGS += -GPMEM_BASE=$(CONFIG_MBASE) -GPMEM_SIZE=$(CONFIG_MSIZE)
VERILATOR_RTL_FLAGS += -GHAS_SERIAL=$(if $(and $(CONFIG_DEVICE),$(CONFIG_HAS_SERIAL)),1,0)
VERILATOR_RTL_FLAGS += -GHAS_TIMER=$(if $(and $(CONFIG_DEVICE),$(CONFIG_HAS_TIMER)),1,0)
VERILATOR_RTL_FLAGS += -GSERIAL_MMIO=$(if $(CONFIG_SERIAL_MMIO),$(CONFIG_SERIAL_MMIO),0x10000000)
VERILATOR_RTL_FLAGS += -GRTC_MMIO=$(if $(CONFIG_RTC_MMIO),$(CONFIG_RTC_MMIO),0x10000048)
endif
VERILATOR_INPUTS = $(VSRCS) $(SRCS)

$(shell mkdir -p $(BUILD_DIR))

default: $(BINARY)
all: default

$(BINARY): $(VERILATOR_INPUTS) $(CONFIG_DEPS) $(BUILD_DEPS)
	$(VERILATOR) $(VERILATOR_CFLAGS) --cc --assert \
		--top-module $(TOP) $(VERILATOR_INPUTS) \
		$(addprefix -CFLAGS ,$(CXXFLAGS)) \
		$(addprefix -LDFLAGS ,$(LDFLAGS)) \
		$(VERILATOR_TRACE_FLAGS) $(VERILATOR_RTL_FLAGS) \
		--Mdir $(OBJ_DIR) --exe -o $(abspath $(BINARY)) --build

LINT_FLAGS ?= -Wall -Wno-SYNCASYNCNET
lint:
	$(VERILATOR) --lint-only $(LINT_FLAGS) $(VERILATOR_RTL_FLAGS) \
		--top-module $(TOP) $(VSRCS)

clean:
	rm -rf $(BUILD_DIR)

.PHONY: default all lint clean
