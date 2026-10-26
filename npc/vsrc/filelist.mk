VSRCS-y += vsrc/top.v vsrc/npc_core.v
VSRCS-y += vsrc/IFU.v vsrc/IDU.v vsrc/EXU.v vsrc/BranchUnit.v
VSRCS-y += vsrc/LSU.v vsrc/WBU.v vsrc/CSR.v vsrc/MEM.v vsrc/random_delay.v
VSRCS-y += vsrc/AXIArbiter.v vsrc/XBAR.v vsrc/UART.v vsrc/CLINT.v
ifeq ($(CONFIG_RVE),y)
VSRCS-y += vsrc/gpr/rv32e/GPR.v
else
VSRCS-y += vsrc/gpr/rv32i/GPR.v
endif
