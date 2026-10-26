# Nangate45 全流程入口。沿用环境中的 NPC_HOME；不依赖用户使用 fish 还是 Bash。
PYTHON ?= python3
YOSYS ?= yosys
IEDA ?= $(HOME)/software/yosys-sta/bin/iEDA

# 这是独立于仿真内存窗口的综合口径：4 KiB 会展开为 32768 个存储触发器。
STA_MEM_BYTES ?= 4096
STA_TARGET_NS ?= 2.0
STA_MAX_FANOUT ?= 8
STA_START_NS ?= 2.0
STA_TOLERANCE_NS ?= 0.01
# 留空时沿用 build/synth/nangate45.lib，首次运行从本机 yosys-sta PDK 复制。
STA_LIBERTY ?=
# 已有报告的离线追踪入口：不重新综合或运行 STA。留空时使用 result.json 的通过边界。
STA_TRACE_REPORT ?=
STA_TRACE_KIND ?= setup
STA_TRACE_LIMIT ?= 5

# 每次都重新综合，再对同一份网表二分；不把上一次结果当成当前设计的结果。
sta:
	@YOSYS="$(YOSYS)" $(PYTHON) "$(NPC_HOME)/scripts/sta/flow.py" --ieda "$(IEDA)" all \
		--mem-bytes "$(STA_MEM_BYTES)" --target-ns "$(STA_TARGET_NS)" \
		--max-fanout "$(STA_MAX_FANOUT)" --start-ns "$(STA_START_NS)" \
		--tolerance-ns "$(STA_TOLERANCE_NS)" $(if $(STA_LIBERTY),--liberty "$(STA_LIBERTY)")

sta-trace:
	@$(PYTHON) "$(NPC_HOME)/scripts/sta/trace_paths.py" \
		--kind "$(STA_TRACE_KIND)" --limit "$(STA_TRACE_LIMIT)" \
		$(if $(STA_TRACE_REPORT),--report "$(STA_TRACE_REPORT)")

.PHONY: sta sta-trace
