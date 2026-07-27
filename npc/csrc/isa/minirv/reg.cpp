#include <cpu/difftest.h>
#include <isa.h>
#include <utils.h>

CPUState cpu{};

static const char *regs[] = {
    "$0", "ra", "sp",  "gp",  "tp", "t0", "t1", "t2", "s0", "s1", "a0",
    "a1", "a2", "a3", "a4",  "a5", "a6", "a7", "s2", "s3", "s4", "s5",
    "s6", "s7", "s8", "s9",  "s10", "s11", "t3", "t4", "t5", "t6"};

const char *reg_name(int index) {
  return index >= 0 && index < ARRLEN(regs) ? regs[index] : nullptr;
}

void isa_reg_display() {
  for (int i = 0; i < ARRLEN(regs); i++) {
    std::printf("%-4s: " FMT_WORD "%s", regs[i], cpu.gpr[i],
                i % 4 == 3 ? "\n" : "  ");
  }
  std::printf("pc  : " FMT_WORD "\n", cpu.pc);
}

word_t isa_reg_str2val(const char *name, bool *success) {
  if (name == nullptr) {
    *success = false;
    return 0;
  }
  if (std::strcmp(name, "pc") == 0 || std::strcmp(name, "$pc") == 0) {
    return cpu.pc;
  }
  if (name[0] == '$' && name[1] != '0') {
    name++;
  }
  for (int i = 0; i < ARRLEN(regs); i++) {
    if (std::strcmp(name, regs[i]) == 0) {
      return cpu.gpr[i];
    }
  }
  *success = false;
  return 0;
}

static bool check_reg(const char *name, vaddr_t pc, word_t ref, word_t dut) {
  if (ref == dut) {
    return true;
  }
  Log("%s is different after executing instruction at pc = " FMT_WORD
      ", right = " FMT_WORD ", wrong = " FMT_WORD ", diff = " FMT_WORD,
      name, pc, ref, dut, ref ^ dut);
  return false;
}

bool isa_difftest_checkregs(const CPUState *ref, vaddr_t pc) {
  if (!check_reg("pc", pc, ref->pc, cpu.pc)) {
    return false;
  }
  for (int i = 0; i < ARRLEN(regs); i++) {
    if (!check_reg(regs[i], pc, ref->gpr[i], cpu.gpr[i])) {
      return false;
    }
  }
  return true;
}
