#ifndef NPC_SIM_H
#define NPC_SIM_H

#include <common.h>

enum {
  SIM_CSR_MSTATUS,
  SIM_CSR_MTVEC,
  SIM_CSR_MEPC,
  SIM_CSR_MCAUSE,
  SIM_CSR_MCYCLE,
  SIM_CSR_MCYCLEH,
  SIM_CSR_MVENDORID,
  SIM_CSR_MARCHID,
  SIM_CSR_NR,
};

void sim_init();
void sim_set_args(int argc, char **argv);
void sim_reset(int cycles);
void sim_exec_once();
void sim_finish();
vaddr_t sim_pc();
word_t sim_inst();
bool sim_invalid_inst();
bool sim_finished();
word_t sim_csr(int id);

#endif
