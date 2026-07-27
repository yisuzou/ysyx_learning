#ifndef NPC_CPU_H
#define NPC_CPU_H

#include <common.h>

void cpu_exec(uint64_t n);
void set_npc_state(int state, vaddr_t pc, int halt_ret);

#endif
