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
uint64_t sim_cycle_count();
void sim_finish();
vaddr_t sim_pc();
word_t sim_inst();
bool sim_invalid_inst();
bool sim_finished();
word_t sim_csr(int id);
bool sim_debug_commit();
bool sim_bus_error();
bool sim_skip_ref();
paddr_t sim_bus_error_addr();
unsigned sim_bus_error_resp();
unsigned sim_bus_error_op();
void sim_perf_reset();
void sim_perf_report(uint64_t retired);
void sim_perf_note_invalid();
void sim_perf_note_fault(unsigned op);
#endif
