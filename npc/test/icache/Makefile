IVERILOG ?= iverilog
VERILATOR ?= verilator
# vvp must come from the same install as iverilog: mixing oss-cad-suite's iverilog
# with a system vvp fails on the .vvp version tag, so resolve both together and
# always recompile (the build is ~1 s).
IV_PATH := $(shell command -v $(IVERILOG) 2>/dev/null)
VVP     ?= $(if $(IV_PATH),$(patsubst %/,%,$(dir $(IV_PATH)))/vvp,vvp)
PYTHON  ?= python3
BUILD_DIR ?= /tmp/npc-icache-tests
IVFLAGS := -g2012 -Wall -Wno-timescale
RTL     := icache_ref.v
TB      := icache_tb.sv
# Read-only input for the offline hit-rate estimate: the ITRACE log of a real
# NPC run. Override with ITRACE_LOG=<file> to point at another run.
ITRACE_LOG ?= $(HOME)/ysyx_learning/npc/build/npc-log.txt

.PHONY: all test lint dump refsim estimate sta clean compile
all: test

$(BUILD_DIR):
	mkdir -p $@

compile: | $(BUILD_DIR)
	$(IVERILOG) $(IVFLAGS) -s icache_tb -o $(BUILD_DIR)/icache.vvp $(TB) $(RTL)

test: compile
	$(VVP) $(BUILD_DIR)/icache.vvp

# Same run, writing one line per transaction for the software model.
dump: compile
	$(VVP) $(BUILD_DIR)/icache.vvp +PCTRACE

# Cross-check the RTL against an independent Python implementation of the
# cache policy, on exactly the transaction stream the RTL just executed.
refsim: dump
	$(PYTHON) refsim.py selftest $(BUILD_DIR)/pctrace.txt

# 估算: replay a real instruction stream (retired PCs) through the model.
estimate:
	$(PYTHON) refsim.py replay $(ITRACE_LOG) -v

lint:
	$(VERILATOR) --lint-only -Wall -Wno-SYNCASYNCNET --top-module icache_ref $(RTL)

sta:
	$(MAKE) -C sta sta

clean:
	rm -rf $(BUILD_DIR) sta/build
