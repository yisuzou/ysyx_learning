ifeq ($(CONFIG_ITRACE)$(CONFIG_IQUEUE),)
SRCS-BLACKLIST-y += csrc/utils/disasm.c
else
LIBCAPSTONE = csrc/tools/capstone/repo/libcapstone.so.5
CXXFLAGS += -I $(NPC_HOME)/csrc/tools/capstone/repo/include
csrc/utils/disasm.c: $(LIBCAPSTONE)
$(LIBCAPSTONE):
	$(MAKE) -C csrc/tools/capstone
endif
