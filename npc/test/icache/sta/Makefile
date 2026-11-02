# ICache 综合/时序评估：复用 npc/test/sta_common 的 yosys + Nangate45 + iEDA iSTA 流程。
SYNTH_TOP := top
SYNTH_RTL := $(abspath top.v) $(abspath ../icache_ref.v)
SDC       := $(abspath constr.sdc)
BUILD_DIR := $(abspath $(CURDIR)/build)

# 触发器阵列口径（2448 个缓存位 + 控制寄存器），非 SRAM 宏：面积偏大属预期。
STA_TARGET_NS    ?= 2.0
STA_START_NS     ?= 2.0
STA_TOLERANCE_NS ?= 0.01

include ../../sta_common/Makefile.common
