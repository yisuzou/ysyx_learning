#include <sim.h>
#include <utils.h>

#include <cinttypes>
#include <cstdint>

// Bit layout must match perf_events in npc_core.v. Bits 5-7 are never set by
// RTL: those abort-path events are counted by the host at detection time.
enum PerfEvent : int {
  PERF_IFU_AR = 0,
  PERF_IFU_FETCH,
  PERF_IFU_IDLE,
  PERF_LSU_LOAD,
  PERF_LSU_STORE,
  PERF_LSU_FAULT,
  PERF_IFU_FAULT,
  PERF_INVALID,
  PERF_COMMIT,
  PERF_ALU,
  PERF_LOAD,
  PERF_STORE,
  PERF_BRANCH,
  PERF_JUMP,
  PERF_CSR,
  PERF_SYSTEM,
  PERF_LUI,
  PERF_AUIPC,
  PERF_EXU_USED,
  PERF_NR,
};

static uint64_t perf_counts[PERF_NR];

void sim_perf_reset() {
  for (auto &count : perf_counts) {
    count = 0;
  }
}

extern "C" void npc_perf_event(unsigned event_mask) {
  while (event_mask != 0) {
    // __builtin_ctz 返回最低位 1 的下标
    perf_counts[__builtin_ctz(event_mask)]++;
    event_mask &= event_mask - 1; // 清除最低位 1
  }
}

void sim_perf_note_invalid() { perf_counts[PERF_INVALID]++; }

void sim_perf_note_fault(unsigned op) {
  // op: 0 fetch, 1 load, 2 store (npc_core debug_bus_error_op)
  perf_counts[op == 0 ? PERF_IFU_FAULT : PERF_LSU_FAULT]++;
}

static double per_inst(uint64_t value, uint64_t inst) {
  return inst == 0 ? 0.0
                   : static_cast<double>(value) / static_cast<double>(inst);
}

static const char *check(bool ok) { return ok ? "OK" : "MISMATCH"; }

void sim_perf_report(uint64_t retired) {
  uint64_t commit = perf_counts[PERF_COMMIT];
  uint64_t fetched = perf_counts[PERF_IFU_FETCH];
  uint64_t lsu_fault = perf_counts[PERF_LSU_FAULT];
  uint64_t category_sum = perf_counts[PERF_ALU] + perf_counts[PERF_LOAD] +
                          perf_counts[PERF_STORE] + perf_counts[PERF_BRANCH] +
                          perf_counts[PERF_JUMP] + perf_counts[PERF_CSR] +
                          perf_counts[PERF_SYSTEM] + perf_counts[PERF_LUI] +
                          perf_counts[PERF_AUIPC];
  uint64_t fetched_expected = commit + perf_counts[PERF_INVALID] + lsu_fault;

  if (commit == 0 && retired == 0) {
    return;
  }

  Log("PERF: fetch   ar=%" PRIu64 " fetched=%" PRIu64 " fault=%" PRIu64
      " idle_cycles=%" PRIu64 " (%.2f/inst)",
      perf_counts[PERF_IFU_AR], fetched, perf_counts[PERF_IFU_FAULT],
      perf_counts[PERF_IFU_IDLE], per_inst(perf_counts[PERF_IFU_IDLE], commit));

  Log("PERF: memory  lsu_load=%" PRIu64 " lsu_store=%" PRIu64 " fault=%" PRIu64,
      perf_counts[PERF_LSU_LOAD], perf_counts[PERF_LSU_STORE], lsu_fault);

  Log("PERF: retire  commit=%" PRIu64 " invalid=%" PRIu64 " exu_used=%" PRIu64
      " (%.2f/inst)",
      commit, perf_counts[PERF_INVALID], perf_counts[PERF_EXU_USED],
      per_inst(perf_counts[PERF_EXU_USED], commit));

  Log("PERF: inst mix alu=%" PRIu64 " load=%" PRIu64 " store=%" PRIu64
      " branch=%" PRIu64 " jump=%" PRIu64 " csr=%" PRIu64 " system=%" PRIu64
      " lui=%" PRIu64 " auipc=%" PRIu64,
      perf_counts[PERF_ALU], perf_counts[PERF_LOAD], perf_counts[PERF_STORE],
      perf_counts[PERF_BRANCH], perf_counts[PERF_JUMP], perf_counts[PERF_CSR],
      perf_counts[PERF_SYSTEM], perf_counts[PERF_LUI], perf_counts[PERF_AUIPC]);

  Log("PERF: check   category_sum=%" PRIu64 " vs commit=%" PRIu64 " (%s), "
      "fetched=%" PRIu64 " vs commit+invalid+lsu_fault=%" PRIu64 " (%s), "
      "retired=%" PRIu64 " (%s)",
      category_sum, commit, check(category_sum == commit), fetched,
      fetched_expected, check(fetched == fetched_expected), retired,
      check(retired == commit));
}
