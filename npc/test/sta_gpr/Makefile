# 寄存器堆 STA 实验：默认 RV32I，可用 VARIANT=rv32e 切换。
VARIANT ?= rv32i

ifeq ($(VARIANT),rv32e)
  SYNTH_RTL := $(abspath top_rv32e.v ../../vsrc/gpr/rv32e/GPR.v)
else ifeq ($(VARIANT),rv32i)
  SYNTH_RTL := $(abspath top_rv32i.v ../../vsrc/gpr/rv32i/GPR.v)
else
  $(error Unknown VARIANT=$(VARIANT); use rv32i or rv32e)
endif

SYNTH_TOP := top
SDC       := $(abspath constr.sdc)
BUILD_DIR := $(abspath $(CURDIR)/build/$(VARIANT))

include ../sta_common/Makefile.common
