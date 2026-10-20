.DEFAULT_GOAL := test
IVERILOG ?= iverilog
VVP ?= vvp
PYTHON ?= python3
BUILD_DIR ?= /tmp/npc-axi-tests
RTL_DIR := $(abspath ../vsrc)
IVFLAGS := -g2012 -Wall -Wno-timescale

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

test: $(BUILD_DIR)/uart.vvp $(BUILD_DIR)/lsu-delay.vvp $(BUILD_DIR)/lsu-no-delay.vvp $(BUILD_DIR)/arbiter.vvp $(BUILD_DIR)/xbar.vvp
	$(VVP) $(BUILD_DIR)/lsu-delay.vvp
	$(VVP) $(BUILD_DIR)/lsu-no-delay.vvp
	$(VVP) $(BUILD_DIR)/arbiter.vvp
	$(VVP) $(BUILD_DIR)/xbar.vvp
	$(VVP) $(BUILD_DIR)/uart.vvp

soc-test:
	$(PYTHON) axi_soc_smoke.py

.PHONY: test soc-test
