.DEFAULT_GOAL := sta

NPC_HOME ?= $(abspath ../..)
RTL_DIR := $(NPC_HOME)/vsrc

-include $(NPC_HOME)/.config

ifeq ($(CONFIG_RVE),y)
  GPR_ISA := rv32e
  export SYNTH_DEFINES := CONFIG_RVE
else
  GPR_ISA := rv32i
  export SYNTH_DEFINES :=
endif

CPU_RTL := npc_core.v IFU.v IDU.v EXU.v BranchUnit.v \
           LSU.v WBU.v CSR.v random_delay.v \
           AXIArbiter.v XBAR.v CLINT.v

SYNTH_TOP := top
SYNTH_RTL := $(abspath top.v) \
             $(addprefix $(RTL_DIR)/,$(CPU_RTL)) \
             $(RTL_DIR)/gpr/$(GPR_ISA)/GPR.v

SDC := $(abspath constr.sdc)
BUILD_DIR := $(abspath build/$(GPR_ISA))

include ../sta_common/Makefile.common
