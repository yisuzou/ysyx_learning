#ifndef NPC_CPU_DIFFTEST_H
#define NPC_CPU_DIFFTEST_H

#include <common.h>

enum { DIFFTEST_TO_DUT, DIFFTEST_TO_REF };

void init_difftest(const char *ref_so_file, long img_size, int port);
void difftest_step(vaddr_t pc, vaddr_t npc);
void difftest_skip_ref();
bool difftest_enabled();

#endif
