ifdef CONFIG_FTRACE
INC_PATH += $(NEMU_HOME)/src/ftrace
endif
SRCS-$(CONFIG_FTRACE) += src/ftrace/ftrace.c
