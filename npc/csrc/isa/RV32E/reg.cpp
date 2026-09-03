#include <cpu/difftest.h>
#include <isa.h>
#include <sim.h>
#include <utils.h>

CPUState cpu{};

static const char *regs[] = {
    "$0", "ra", "sp",  "gp",  "tp", "t0", "t1", "t2", "s0", "s1", "a0",
    "a1", "a2", "a3", "a4",  "a5", "a6", "a7", "s2", "s3", "s4", "s5",
    "s6", "s7", "s8", "s9",  "s10", "s11", "t3", "t4", "t5", "t6"};

struct CSRInfo {
  const char *name;
  int id;
};

static const CSRInfo csrs[] = {
    {"mstatus", SIM_CSR_MSTATUS},   {"mtvec", SIM_CSR_MTVEC},
    {"mepc", SIM_CSR_MEPC},         {"mcause", SIM_CSR_MCAUSE},
    {"mcycle", SIM_CSR_MCYCLE},     {"mcycleh", SIM_CSR_MCYCLEH},
    {"mvendorid", SIM_CSR_MVENDORID}, {"marchid", SIM_CSR_MARCHID},
};

constexpr int NR_CSR = sizeof(csrs) / sizeof(csrs[0]);

const char *reg_name(int index) {
  return index >= 0 && index < NR_GPR ? regs[index] : nullptr;
}

void isa_reg_display() {
  for (int i = 0; i < NR_GPR; i++) {
    std::printf("%-4s: " FMT_WORD "%s", regs[i], cpu.gpr[i],
                i % 4 == 3 ? "\n" : "  ");
  }
  std::printf("pc  : " FMT_WORD "\n", cpu.pc);
  for (int i = 0; i < NR_CSR; i++) {
    std::printf("%-9s: " FMT_WORD "%s", csrs[i].name, sim_csr(csrs[i].id),
                i % 3 == 2 ? "\n" : "  ");
  }
  if (NR_CSR % 3 != 0) {
    std::printf("\n");
  }
}

word_t isa_csr_str2val(const char *name, bool *success) {
  if (name == nullptr) {
    *success = false;
    return 0;
  }
  if (name[0] == '$') {
    name++;
  }
  for (int i = 0; i < NR_CSR; i++) {
    if (std::strcmp(name, csrs[i].name) == 0) {
      return sim_csr(csrs[i].id);
    }
  }
  *success = false;
  return 0;
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
  for (int i = 0; i < NR_GPR; i++) {
    if (std::strcmp(name, regs[i]) == 0) {
      return cpu.gpr[i];
    }
  }
  return isa_csr_str2val(name, success);
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
  for (int i = 0; i < NR_GPR; i++) {
    if (!check_reg(regs[i], pc, ref->gpr[i], cpu.gpr[i])) {
      return false;
    }
  }
  return true;
}
