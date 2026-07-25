# Makefile
VERILATOR = verilator
unexport VERILATOR_ROOT
TOP ?= top
TESTBENCH ?= main
NXDC_FILES =constr/top.nxdc

BUILD_DIR = ./build
OBJ_DIR = $(BUILD_DIR)/obj_dir
BIN = $(BUILD_DIR)/$(TOP)
TRACE_CONFIG = $(BUILD_DIR)/trace-config
IMG ?=
ARGS ?=
ITRACE ?= 0
MTRACE ?= 0
FTRACE ?= 0

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
# 检查相关功能是否开启
ifeq ($(ITRACE),1)
CXXFLAGS += -DNPC_ITRACE -I$(abspath ./csrc/trace/capstone/include)
endif

ifeq ($(MTRACE),1)
CXXFLAGS += -DNPC_MTRACE
endif

ifeq ($(FTRACE),1)
CXXFLAGS += -DNPC_FTRACE
endif
# -D 会将宏定义传递给 Verilator，Verilator 会在编译时将这些宏定义传递给 C++ 编译器，如此一来，C++ 代码中就可以使用这些宏定义来进行条件编译，从而实现不同的功能或行为。
LINT_FLAGS ?= -Wall
TRACE_FLAGS ?=
LDFLAGS += -lreadline
LDFLAGS += -lcapstone
VERILATOR_INPUTS = $(VSRCS) $(CSRCS) $(NVBOARD_ARCHIVE)

$(TRACE_CONFIG): FORCE
	@printf 'ITRACE=%s\nMTRACE=%s\nFTRACE=%s\nTRACE_FLAGS=%s\n' \
		'$(ITRACE)' '$(MTRACE)' '$(FTRACE)' '$(TRACE_FLAGS)' > $@.tmp
	@if ! cmp -s $@.tmp $@ 2>/dev/null; then mv $@.tmp $@; else rm -f $@.tmp; fi

$(BIN): $(VERILATOR_INPUTS) $(TRACE_CONFIG)
	@rm -rf $(OBJ_DIR)
	$(VERILATOR) $(VERILATOR_CFLAGS) --cc \
		--top-module $(TOP) $(VERILATOR_INPUTS) \
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

.PHONY: default all clean run sim lint FORCE
FORCE:
