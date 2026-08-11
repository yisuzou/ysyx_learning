VSRCS-y += vsrc/top.v
VSRCS-y += vsrc/IFU.v vsrc/IDU.v vsrc/EXU.v vsrc/BranchUnit.v
VSRCS-y += vsrc/LSU.v vsrc/WBU.v vsrc/CSR.v
ifeq ($(CONFIG_RVE),y)
VSRCS-y += vsrc/gpr/rv32e/GPR.v
else
VSRCS-y += vsrc/gpr/rv32i/GPR.v
endif
