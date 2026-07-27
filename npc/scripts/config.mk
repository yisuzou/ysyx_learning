COLOR_RED := $(shell printf '\033[1;31m')
COLOR_END := $(shell printf '\033[0m')

ifeq ($(wildcard $(NPC_HOME)/.config),)
$(warning $(COLOR_RED)Warning: npc/.config does not exist!$(COLOR_END))
$(warning Run 'make -C npc defconfig' or 'make -C npc menuconfig' first.)
endif

Q ?= @
KCONFIG_PATH := $(NEMU_HOME)/tools/kconfig
FIXDEP_PATH := $(NEMU_HOME)/tools/fixdep
Kconfig := $(NPC_HOME)/Kconfig
rm-distclean += $(NPC_HOME)/include/generated $(NPC_HOME)/include/config \
	$(NPC_HOME)/.config $(NPC_HOME)/.config.old
silent := -s

CONF := $(KCONFIG_PATH)/build/conf
MCONF := $(KCONFIG_PATH)/build/mconf
FIXDEP := $(FIXDEP_PATH)/build/fixdep

$(CONF):
	$(Q)$(MAKE) $(silent) -C $(KCONFIG_PATH) NAME=conf

$(MCONF):
	$(Q)$(MAKE) $(silent) -C $(KCONFIG_PATH) NAME=mconf

$(FIXDEP):
	$(Q)$(MAKE) $(silent) -C $(FIXDEP_PATH)

menuconfig: $(MCONF) $(CONF) $(FIXDEP)
	$(Q)cd $(NPC_HOME) && $(MCONF) $(Kconfig)
	$(Q)cd $(NPC_HOME) && $(CONF) $(silent) --syncconfig $(Kconfig)

savedefconfig: $(CONF)
	$(Q)cd $(NPC_HOME) && $(CONF) $(silent) \
		--savedefconfig=configs/defconfig $(Kconfig)

%defconfig: $(CONF) $(FIXDEP)
	$(Q)cd $(NPC_HOME) && $(CONF) $(silent) \
		--defconfig=configs/$@ $(Kconfig)
	$(Q)cd $(NPC_HOME) && $(CONF) $(silent) --syncconfig $(Kconfig)

defconfig: $(CONF) $(FIXDEP)
	$(Q)cd $(NPC_HOME) && $(CONF) $(silent) \
		--defconfig=configs/defconfig $(Kconfig)
	$(Q)cd $(NPC_HOME) && $(CONF) $(silent) --syncconfig $(Kconfig)

distclean: clean
	$(Q)rm -rf $(rm-distclean)

.PHONY: menuconfig savedefconfig defconfig distclean
