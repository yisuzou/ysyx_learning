#ifndef NPC_ISA_H
#define NPC_ISA_H

#include <common.h>

struct CPUState {
  word_t gpr[32];
  vaddr_t pc;
};

extern CPUState cpu;

void isa_reg_display();
word_t isa_reg_str2val(const char *name, bool *success);
const char *reg_name(int index);
bool isa_difftest_checkregs(const CPUState *ref, vaddr_t pc);

#endif
