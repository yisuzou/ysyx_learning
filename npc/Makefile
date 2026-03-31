# Makefile
VERILAOR = verilator
TOP = top_module

all:
	@echo "Write this Makefile by your self."
	run
sim:
	$(call git_commit, "sim RTL") # DO NOT REMOVE THIS LINE!!!
	@echo "Write this Makefile by your self."
	$(VERILAOR) -Wall --cc --trace-fst $(TOP).v --exe -j 8 sim_main.cpp
	make -C obj_dir -f V$(TOP).mk
	./obj_dir/V$(TOP)
include ../Makefile
