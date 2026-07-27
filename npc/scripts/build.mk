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
VERILATOR_INPUTS = $(VSRCS) $(SRCS)

$(shell mkdir -p $(BUILD_DIR))

default: $(BINARY)
all: default

$(BINARY): $(VERILATOR_INPUTS) $(CONFIG_DEPS) $(BUILD_DEPS)
	$(VERILATOR) $(VERILATOR_CFLAGS) --cc --assert \
		--top-module $(TOP) $(VERILATOR_INPUTS) \
		$(addprefix -CFLAGS ,$(CXXFLAGS)) \
		$(addprefix -LDFLAGS ,$(LDFLAGS)) \
		$(VERILATOR_TRACE_FLAGS) \
		--Mdir $(OBJ_DIR) --exe -o $(abspath $(BINARY)) --build

LINT_FLAGS ?= -Wall -Wno-SYNCASYNCNET
lint:
	$(VERILATOR) --lint-only $(LINT_FLAGS) --top-module $(TOP) $(VSRCS)

clean:
	rm -rf $(BUILD_DIR)

.PHONY: default all lint clean
