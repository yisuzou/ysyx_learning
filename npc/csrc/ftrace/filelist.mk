ifdef CONFIG_FTRACE
INC_PATH += $(NPC_HOME)/csrc/ftrace
endif
SRCS-$(CONFIG_FTRACE) += csrc/ftrace/ftrace.cpp
