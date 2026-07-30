#ifndef NPC_ISA_H
#define NPC_ISA_H

#include <common.h>

#ifdef CONFIG_RVE
constexpr int NR_GPR = 16;
#else
constexpr int NR_GPR = 32;
#endif

struct CPUState {
  word_t gpr[NR_GPR];
  vaddr_t pc;
};

static_assert(offsetof(CPUState, pc) == sizeof(word_t) * NR_GPR);
static_assert(sizeof(CPUState) == sizeof(word_t) * (NR_GPR + 1));

extern CPUState cpu;

void isa_reg_display();
word_t isa_reg_str2val(const char *name, bool *success);
const char *reg_name(int index);
bool isa_difftest_checkregs(const CPUState *ref, vaddr_t pc);

#endif
