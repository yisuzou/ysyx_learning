# Makefile
VERILATOR = verilator
TOP ?= top
TESTBENCH ?= main
NXDC_FILES =constr/top.nxdc

BUILD_DIR = ./build
OBJ_DIR = $(BUILD_DIR)/obj_dir
BIN = $(BUILD_DIR)/$(TOP)
IMG ?=
ARGS ?=

default: $(BIN)

$(shell mkdir -p $(BUILD_DIR))

# 约束文件
SRC_AUTO_BIND = $(abspath $(BUILD_DIR)/auto_bind.cpp)
$(SRC_AUTO_BIND): $(NXDC_FILES)
	python3 $(NVBOARD_HOME)/scripts/auto_pin_bind.py $^ $@
# project source
VSRCS = $(shell find $(abspath ./vsrc) -name "*.v")
CSRCS = $(shell find $(abspath ./csrc) -name "*.c" -or -name "*.cc" -or -name "*.cpp")
CSRCS += $(SRC_AUTO_BIND)
# rules for NVBoard
include $(NVBOARD_HOME)/scripts/nvboard.mk

# rules for verilator
INCFLAGS = $(addprefix -I, $(INC_PATH))
CXXFLAGS += $(INCFLAGS) -DTOP_NAME="\"V$(TOP)\""
LINT_FLAGS ?= -Wall
TRACE_FLAGS ?= --trace-fst

$(BIN): $(VSRCS) $(CSRCS) $(NVBOARD_ARCHIVE)
	@rm -rf $(OBJ_DIR)
	$(VERILATOR) $(VERILATOR_CFLAGS) --cc \
		--top-module $(TOP) $^ \
		$(addprefix -CFLAGS , $(CXXFLAGS)) $(addprefix -LDFLAGS , $(LDFLAGS)) \
		$(TRACE_FLAGS) \
		--Mdir $(OBJ_DIR) --exe -o $(abspath $(BIN)) --build


all: default
	#@echo "Write this Makefile by your self."
lint:
	$(VERILATOR) --lint-only $(LINT_FLAGS) --top-module $(TOP) $(VSRCS)
sim: $(BIN)
	$(call git_commit, "sim RTL") # DO NOT REMOVE THIS LINE!!!
	@test -n "$(IMG)" || (echo "Usage: make sim IMG=<image> [ARGS=...]" && exit 1)
	$(BIN) $(IMG) $(ARGS)
run: sim

clean:
	rm -rf $(BUILD_DIR)

.PHONY: default all clean run sim lint
