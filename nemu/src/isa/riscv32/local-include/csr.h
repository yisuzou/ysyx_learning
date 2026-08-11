#ifndef __RISCV_CSR_H__
#define __RISCV_CSR_H__

#include <common.h>

enum {
  CSR_IDX_MSTATUS = 0,
  CSR_IDX_MEPC = 1,
  CSR_IDX_MCAUSE = 2,
  CSR_IDX_MTVAL = 3,
  CSR_IDX_MIE = 4,
  CSR_IDX_MTVEC = 5,
  CSR_IDX_MCYCLE = 6,
  CSR_IDX_MCYCLEH = 7,
  CSR_IDX_MVENDORID = 8,
  CSR_IDX_MARCHID = 9,
};

typedef struct {
  word_t addr;
  const char *name;
  int idx;
} CSR_Entry;

static const CSR_Entry csr_map[] = {
    {0x300, "mstatus", CSR_IDX_MSTATUS},
    {0x341, "mepc", CSR_IDX_MEPC},
    {0x342, "mcause", CSR_IDX_MCAUSE},
    {0x343, "mtval", CSR_IDX_MTVAL},
    {0x304, "mie", CSR_IDX_MIE},
    {0x305, "mtvec", CSR_IDX_MTVEC},
    {0xb00, "mcyle", CSR_IDX_MCYCLE},
    {0xb80, "mcyleh", CSR_IDX_MCYCLEH},
    {0xf11, "mvendorid", CSR_IDX_MVENDORID},
    {0xf12, "marchid", CSR_IDX_MARCHID},
};

#define CSR_NUM (sizeof(csr_map) / sizeof(csr_map[0]))

static inline int check_csr_idx(word_t addr) {
  for (int i = 0; i < CSR_NUM; i++) {
    if (csr_map[i].addr == (addr & 0xfff)) {
      return csr_map[i].idx;
    }
  }
  panic("Undefined CSR! addr = 0x%x\n", addr);
  return -1;
}

static inline const char *csr_name(word_t addr) {
  for (int i = 0; i < CSR_NUM; i++) {
    if (csr_map[i].addr == addr) {
      return csr_map[i].name;
    }
  }
  return "unknown";
}

#define csr(i) (cpu.csr[check_csr_idx(i)])

#endif
