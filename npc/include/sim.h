#ifndef NPC_SIM_H
#define NPC_SIM_H

#include <common.h>

void sim_init();
void sim_set_args(int argc, char **argv);
void sim_reset(int cycles);
void sim_exec_once();
void sim_finish();
vaddr_t sim_pc();
word_t sim_inst();
bool sim_invalid_inst();
bool sim_finished();

#endif
