.DEFAULT_GOAL := test
IVERILOG ?= iverilog
VVP ?= vvp
VERILATOR ?= verilator
PYTHON ?= python3
BUILD_DIR ?= /tmp/npc-axi-tests
RTL_DIR := $(abspath ../vsrc)
IVFLAGS := -g2012 -Wall -Wno-timescale
ICACHE_CORE_RTL := $(addprefix $(RTL_DIR)/,npc_core.v IFU.v icache.v \
    idu_stage.v IDU.v exu_stage.v EXU.v BranchUnit.v LSU.v WBU.v CSR.v \
    random_delay.v AXIArbiter.v MEM.v gpr/rv32i/GPR.v)

$(BUILD_DIR):
	@mkdir -p $@

$(BUILD_DIR)/lsu-delay.vvp: axi_lsu_tb.sv $(RTL_DIR)/LSU.v $(RTL_DIR)/random_delay.v | $(BUILD_DIR)
	$(IVERILOG) $(IVFLAGS) -s axi_lsu_tb -o $@ $^

$(BUILD_DIR)/lsu-no-delay.vvp: axi_lsu_tb.sv $(RTL_DIR)/LSU.v $(RTL_DIR)/random_delay.v | $(BUILD_DIR)
	$(IVERILOG) $(IVFLAGS) -s axi_lsu_tb -Paxi_lsu_tb.RANDOM_DELAY=0 -o $@ $^

$(BUILD_DIR)/arbiter.vvp: axi_arbiter_tb.sv $(RTL_DIR)/AXIArbiter.v | $(BUILD_DIR)
	$(IVERILOG) $(IVFLAGS) -s axi_arbiter_tb -o $@ $^

$(BUILD_DIR)/xbar.vvp: axi_xbar_tb.sv $(RTL_DIR)/XBAR.v | $(BUILD_DIR)
	$(IVERILOG) $(IVFLAGS) -s axi_xbar_tb -o $@ $^

$(BUILD_DIR)/uart.vvp: axi_uart_tb.sv $(RTL_DIR)/UART.v | $(BUILD_DIR)
	$(IVERILOG) $(IVFLAGS) -s axi_uart_tb -o $@ $^

$(BUILD_DIR)/ifu-backpressure.vvp: ifu_backpressure_tb.sv $(RTL_DIR)/IFU.v | $(BUILD_DIR)
	$(IVERILOG) $(IVFLAGS) -s ifu_backpressure_tb -o $@ $^

$(BUILD_DIR)/icache-core.vvp: icache_core_tb.sv $(ICACHE_CORE_RTL) | $(BUILD_DIR)
	$(IVERILOG) $(IVFLAGS) -DSYNTHESIS -s icache_core_tb -o $@ $^

$(BUILD_DIR)/icache-core-delay.vvp: icache_core_tb.sv $(ICACHE_CORE_RTL) | $(BUILD_DIR)
	$(IVERILOG) $(IVFLAGS) -DSYNTHESIS -s icache_core_tb \
		-Picache_core_tb.RANDOM_DELAY=1 -o $@ $^

$(BUILD_DIR)/mem-no-delay: axi_mem_tb.cpp $(RTL_DIR)/MEM.v $(RTL_DIR)/random_delay.v | $(BUILD_DIR)
	$(VERILATOR) --cc --exe --build --assert -Wall --top-module MEM \
		-GRANDOM_DELAY=0 -GSIZE=1024 --Mdir $(BUILD_DIR)/mem-no-delay-obj \
		-CFLAGS "-std=c++17 -Wall -Werror -DTEST_RANDOM_DELAY=0" -o $(abspath $@) $(abspath $^)

$(BUILD_DIR)/mem-delay: axi_mem_tb.cpp $(RTL_DIR)/MEM.v $(RTL_DIR)/random_delay.v | $(BUILD_DIR)
	$(VERILATOR) --cc --exe --build --assert -Wall --top-module MEM \
		-GRANDOM_DELAY=1 -GSIZE=1024 --Mdir $(BUILD_DIR)/mem-delay-obj \
		-CFLAGS "-std=c++17 -Wall -Werror -DTEST_RANDOM_DELAY=1" -o $(abspath $@) $(abspath $^)

$(BUILD_DIR)/mem-synthesis: axi_mem_tb.cpp $(RTL_DIR)/MEM.v $(RTL_DIR)/random_delay.v | $(BUILD_DIR)
	$(VERILATOR) --cc --exe --build --assert -Wall -Wno-SYNCASYNCNET --top-module MEM -DSYNTHESIS \
		-GRANDOM_DELAY=0 -GSIZE=1024 --Mdir $(BUILD_DIR)/mem-synthesis-obj \
		-CFLAGS "-std=c++17 -Wall -Werror -DTEST_RANDOM_DELAY=0 -DTEST_SYNTHESIS" -o $(abspath $@) $(abspath $^)

test: $(BUILD_DIR)/uart.vvp $(BUILD_DIR)/lsu-delay.vvp $(BUILD_DIR)/lsu-no-delay.vvp $(BUILD_DIR)/arbiter.vvp $(BUILD_DIR)/xbar.vvp $(BUILD_DIR)/ifu-backpressure.vvp $(BUILD_DIR)/mem-no-delay $(BUILD_DIR)/mem-delay $(BUILD_DIR)/mem-synthesis icache-test
	$(VVP) $(BUILD_DIR)/lsu-delay.vvp
	$(VVP) $(BUILD_DIR)/lsu-no-delay.vvp
	$(VVP) $(BUILD_DIR)/arbiter.vvp
	$(VVP) $(BUILD_DIR)/xbar.vvp
	$(VVP) $(BUILD_DIR)/uart.vvp
	$(VVP) $(BUILD_DIR)/ifu-backpressure.vvp
	$(BUILD_DIR)/mem-no-delay
	$(BUILD_DIR)/mem-delay
	$(BUILD_DIR)/mem-synthesis

soc-test:
	$(PYTHON) axi_soc_smoke.py $(SOC_TEST_ARGS)

perf-test:
	$(PYTHON) perf_counters.py $(PERF_TEST_ARGS)

perf-trace-test:
	$(PYTHON) perf_counters.py --trace $(PERF_TEST_ARGS)

perf-run-test:
	$(PYTHON) -m unittest -v test_perf_run.py

ifu-test: $(BUILD_DIR)/ifu-backpressure.vvp
	$(VVP) $(BUILD_DIR)/ifu-backpressure.vvp

icache-test: $(BUILD_DIR)/icache-core.vvp $(BUILD_DIR)/icache-core-delay.vvp icache-param-test
	$(VVP) $(BUILD_DIR)/icache-core.vvp
	$(VVP) $(BUILD_DIR)/icache-core-delay.vvp

icache-param-test: | $(BUILD_DIR)
	@set -e; for geometry in 1:4 1:16 16:4 16:16 32:8 8:64 4:256; do \
		cache_lines=$${geometry%:*}; cache_bytes=$${geometry#*:}; \
		output=$(BUILD_DIR)/icache-param-$$cache_lines-$$cache_bytes.vvp; \
		$(IVERILOG) $(IVFLAGS) -s icache_param_tb \
			-Picache_param_tb.LINES=$$cache_lines -Picache_param_tb.BLOCK_BYTES=$$cache_bytes \
			-o $$output icache_param_tb.sv $(RTL_DIR)/icache.v; \
		$(VVP) $$output; \
	done

.PHONY: test soc-test perf-test perf-trace-test perf-run-test ifu-test icache-test icache-param-test
