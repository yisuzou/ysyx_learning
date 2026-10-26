# 32 位加法器 STA 实验：对比 ripple / select / lookahead 三种结构。
VARIANT ?= ripple

ifeq ($(VARIANT),ripple)
  SYNTH_RTL := $(abspath top_ripple.v)
else ifeq ($(VARIANT),select)
  SYNTH_RTL := $(abspath top_select.v adder_select.v)
else ifeq ($(VARIANT),lookahead)
  SYNTH_RTL := $(abspath top_lookahead.v adder_lookahead.v)
else
  $(error Unknown VARIANT=$(VARIANT); use ripple, select, or lookahead)
endif

SYNTH_TOP := top
SDC       := $(abspath constr.sdc)
BUILD_DIR := $(abspath $(CURDIR)/build/$(VARIANT))

include ../sta_common/Makefile.common
