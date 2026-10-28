#include <sim.h>

#ifdef CONFIG_PERF_COUNTERS
#include <utils.h>

#include <cinttypes>
#include <cstdint>
#ifdef CONFIG_PERF_TRACE
#include <cerrno>
#endif

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
  PERF_CYCLE,
  PERF_IFU_PREP,
  PERF_IFU_AR_WAIT,
  PERF_IFU_R_WAIT,
  PERF_EXECUTE_CYCLE,
  PERF_LSU_WAIT,
  PERF_IFU_FAULT_HOLD,
  PERF_IFU_R_ERROR,
  PERF_IFU_HOLD_LSU,
  PERF_NR,
};

static uint64_t perf_counts[PERF_NR];
static constexpr const char *category_names[] = {
    "alu", "load", "store", "branch", "jump", "csr", "system", "lui", "auipc",
};
static constexpr unsigned NR_CATEGORIES = ARRLEN(category_names);
static_assert(PERF_AUIPC - PERF_ALU + 1 == NR_CATEGORIES);
static_assert(PERF_NR <= 32);

struct InstructionCycles {
  uint64_t total;
  uint64_t execute;
};
static InstructionCycles category_cycles[NR_CATEGORIES];
// This core executes one instruction at a time. Attribute its entire fetch
// and execution interval at commit, when the existing category bits are valid.
// Keep unfinished work separate on a fault or a stopped simulation.
static uint64_t pending_cycles;
static uint64_t pending_execute_cycles;
static uint64_t pending_lsu_cycles;
static uint64_t lsu_load_cycles;
static uint64_t lsu_store_cycles;

static bool event(unsigned mask, PerfEvent id) { return mask & (1u << id); }

#ifdef CONFIG_PERF_TRACE
static const char *trace_path = "build/perf.csv";
static FILE *trace_file;
static char trace_buffer[1024 * 1024];
// Keep the column order identical to PerfEvent. Cycle is the first column.
static constexpr const char *event_names[] = {
    "ar_accept", "fetched", "idle", "lsu_load", "lsu_store", "lsu_fault",
    "ifu_fault", "invalid", "commit", "alu", "load", "store", "branch",
    "jump", "csr", "system", "lui", "auipc", "exu_used", "cycle",
    "prepare", "ar_wait", "r_wait", "execute", "lsu_wait", "fault_hold",
    "r_error", "lsu_hold",
};
static_assert(ARRLEN(event_names) == PERF_NR);

static void trace_error() {
  std::fprintf(stderr, "cannot write performance trace '%s': %s\n", trace_path,
               std::strerror(errno));
  std::exit(EXIT_FAILURE);
}

bool sim_perf_trace_set_path(const char *path) {
  if (path == nullptr || *path == '\0' || trace_file != nullptr) return false;
  trace_path = path;
  return true;
}

static void trace_snapshot() {
  if (trace_file == nullptr) return;
  std::fprintf(trace_file, "%" PRIu64, perf_counts[PERF_CYCLE]);
  for (unsigned i = 0; i < PERF_NR; ++i) {
    if (i != PERF_CYCLE) std::fprintf(trace_file, ",%" PRIu64, perf_counts[i]);
  }
  for (const auto &cycles : category_cycles) {
    std::fprintf(trace_file, ",%" PRIu64 ",%" PRIu64, cycles.total, cycles.execute);
  }
  std::fprintf(trace_file, ",%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%" PRIu64
               ",%" PRIu64 "\n", pending_cycles, pending_execute_cycles,
               pending_lsu_cycles, lsu_load_cycles, lsu_store_cycles);
  if (std::ferror(trace_file)) trace_error();
}

void sim_perf_trace_close() {
  if (trace_file == nullptr) return;
  // The last active edge has no following edge to emit its snapshot. Host
  // fault/invalid detection may have updated its counters in the meantime.
  trace_snapshot();
  FILE *file = trace_file;
  trace_file = nullptr;
  if (std::fclose(file) != 0) trace_error();
}

static void trace_open() {
  trace_file = std::fopen(trace_path, "w");
  if (trace_file == nullptr) trace_error();
  std::setvbuf(trace_file, trace_buffer, _IOFBF, sizeof(trace_buffer));
  std::fputs("cycle", trace_file);
  for (unsigned i = 0; i < PERF_NR; ++i) {
    if (i != PERF_CYCLE) std::fprintf(trace_file, ",%s", event_names[i]);
  }
  for (const auto *name : category_names) {
    std::fprintf(trace_file, ",%s_total_cycles,%s_exec_cycles", name, name);
  }
  std::fputs(",pending,pending_exec,pending_lsu,lsu_load_cycles,lsu_store_cycles\n",
             trace_file);
  if (std::ferror(trace_file)) trace_error();
}
#endif

void sim_perf_reset() {
#ifdef CONFIG_PERF_TRACE
  sim_perf_trace_close();
#endif
  for (auto &count : perf_counts) {
    count = 0;
  }
  for (auto &cycles : category_cycles) {
    cycles = {};
  }
  pending_cycles = pending_execute_cycles = pending_lsu_cycles = 0;
  lsu_load_cycles = lsu_store_cycles = 0;
#ifdef CONFIG_PERF_TRACE
  trace_open();
#endif
}

extern "C" void npc_perf_event(unsigned event_mask) {
#ifdef CONFIG_PERF_TRACE
  // Emit the previous cycle before changing it. This starts with cycle zero
  // and lets host-side fault detection join the most recent edge's snapshot.
  // close() writes the final row before the simulator's shutdown clocks.
  trace_snapshot();
#endif
  const unsigned events = event_mask;
  while (event_mask != 0) {
    // __builtin_ctz 返回最低位 1 的下标
    perf_counts[__builtin_ctz(event_mask)]++;
    event_mask &= event_mask - 1; // 清除最低位 1
  }
  pending_cycles += event(events, PERF_CYCLE);
  pending_execute_cycles += event(events, PERF_EXECUTE_CYCLE);
  pending_lsu_cycles += event(events, PERF_LSU_WAIT);

  if (event(events, PERF_LSU_LOAD) || event(events, PERF_LSU_STORE)) {
    auto &cycles = event(events, PERF_LSU_STORE) ? lsu_store_cycles
                                               : lsu_load_cycles;
    cycles += pending_lsu_cycles;
    pending_lsu_cycles = 0;
  }
  if (event(events, PERF_COMMIT)) {
    for (unsigned i = 0; i < NR_CATEGORIES; ++i) {
      if (event(events, static_cast<PerfEvent>(PERF_ALU + i))) {
        category_cycles[i].total += pending_cycles;
        category_cycles[i].execute += pending_execute_cycles;
      }
    }
    pending_cycles = pending_execute_cycles = 0;
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

static void report_cycles(uint64_t commit, uint64_t fetched) {
  const uint64_t cycles = perf_counts[PERF_CYCLE];
  const uint64_t execute = perf_counts[PERF_EXECUTE_CYCLE];
  const uint64_t no_fetch = cycles - fetched;
  uint64_t category_total = 0, category_execute = 0;
  Log("PERF: class averages: total=fetch+execute; execute includes commit cycle");
  for (unsigned i = 0; i < NR_CATEGORIES; ++i) {
    const uint64_t count = perf_counts[PERF_ALU + i];
    const auto &spent = category_cycles[i];
    category_total += spent.total;
    category_execute += spent.execute;
    Log("PERF: class %s count=%" PRIu64 " share=%.3f%% total_cycles=%" PRIu64
        " exec_cycles=%" PRIu64 " avg_total=%.3f avg_exec=%.3f avg_fetch=%.3f",
        category_names[i], count, 100.0 * per_inst(count, commit), spent.total,
        spent.execute, per_inst(spent.total, count), per_inst(spent.execute, count),
        per_inst(spent.total - spent.execute, count));
  }

  struct Reason {
    const char *name;
    uint64_t cycles;
  };
  const Reason reasons[] = {
      {"prepare", perf_counts[PERF_IFU_PREP]},
      {"ar_wait", perf_counts[PERF_IFU_AR_WAIT]},
      {"ar_accept", perf_counts[PERF_IFU_AR]},
      {"r_wait", perf_counts[PERF_IFU_R_WAIT]},
      {"r_error", perf_counts[PERF_IFU_R_ERROR]},
      {"fault_hold", perf_counts[PERF_IFU_FAULT_HOLD]},
      {"execute", execute - perf_counts[PERF_IFU_HOLD_LSU]},
      {"lsu_hold", perf_counts[PERF_IFU_HOLD_LSU]},
  };
  uint64_t reason_sum = 0;
  Log("PERF: no-fetch cycles=%" PRIu64 " sampled_cycles=%" PRIu64,
      no_fetch, cycles);
  for (const auto &reason : reasons) {
    reason_sum += reason.cycles;
    Log("PERF: no-fetch %s cycles=%" PRIu64 " share_no_fetch=%.3f%% share_all=%.3f%%",
        reason.name, reason.cycles, 100.0 * per_inst(reason.cycles, no_fetch),
        100.0 * per_inst(reason.cycles, cycles));
  }

  const uint64_t loads = perf_counts[PERF_LSU_LOAD];
  const uint64_t stores = perf_counts[PERF_LSU_STORE];
  Log("PERF: lsu latency: CPU request-valid -> result-ready (acceptance cycle included; DONE excluded)");
  Log("PERF: lsu load count=%" PRIu64 " latency_cycles=%" PRIu64 " avg_latency=%.3f",
      loads, lsu_load_cycles, per_inst(lsu_load_cycles, loads));
  Log("PERF: lsu store count=%" PRIu64 " latency_cycles=%" PRIu64 " avg_latency=%.3f",
      stores, lsu_store_cycles, per_inst(lsu_store_cycles, stores));
  Log("PERF: lsu all count=%" PRIu64 " latency_cycles=%" PRIu64 " avg_latency=%.3f",
      loads + stores, lsu_load_cycles + lsu_store_cycles,
      per_inst(lsu_load_cycles + lsu_store_cycles, loads + stores));

  const uint64_t fetch_phase = perf_counts[PERF_IFU_PREP] +
      perf_counts[PERF_IFU_AR_WAIT] + perf_counts[PERF_IFU_AR] +
      perf_counts[PERF_IFU_R_WAIT] + fetched + perf_counts[PERF_IFU_R_ERROR] +
      perf_counts[PERF_IFU_FAULT_HOLD];
  Log("PERF: cycle check sampled=%" PRIu64 " vs sim=%" PRIu64 " (%s), "
      "fetch_phase=%" PRIu64 " vs idle=%" PRIu64 " (%s), "
      "idle+execute=%" PRIu64 " vs sampled=%" PRIu64 " (%s)",
      cycles, sim_cycle_count(), check(cycles == sim_cycle_count()),
      fetch_phase, perf_counts[PERF_IFU_IDLE],
      check(fetch_phase == perf_counts[PERF_IFU_IDLE]),
      perf_counts[PERF_IFU_IDLE] + execute, cycles,
      check(perf_counts[PERF_IFU_IDLE] + execute == cycles));
  Log("PERF: cycle check no_fetch_reasons=%" PRIu64 " vs no_fetch=%" PRIu64
      " (%s), class_total=%" PRIu64 " + pending=%" PRIu64
      " vs sampled=%" PRIu64 " (%s), class_exec=%" PRIu64
      " + pending_exec=%" PRIu64 " vs execute=%" PRIu64 " (%s)",
      reason_sum, no_fetch, check(reason_sum == no_fetch),
      category_total, pending_cycles, cycles,
      check(category_total + pending_cycles == cycles),
      category_execute, pending_execute_cycles, execute,
      check(category_execute + pending_execute_cycles == execute));
  const uint64_t memory_cycles = lsu_load_cycles + lsu_store_cycles + pending_lsu_cycles;
  Log("PERF: cycle check lsu_latency=%" PRIu64 " + pending_lsu=%" PRIu64
      " vs lsu_wait=%" PRIu64 " (%s), lsu_wait+done=%" PRIu64
      " vs lsu_hold=%" PRIu64 " (%s)",
      lsu_load_cycles + lsu_store_cycles, pending_lsu_cycles,
      perf_counts[PERF_LSU_WAIT], check(memory_cycles == perf_counts[PERF_LSU_WAIT]),
      perf_counts[PERF_LSU_WAIT] + loads + stores, perf_counts[PERF_IFU_HOLD_LSU],
      check(perf_counts[PERF_LSU_WAIT] + loads + stores == perf_counts[PERF_IFU_HOLD_LSU]));
}

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

  if (perf_counts[PERF_CYCLE] == 0 && retired == 0) {
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

  report_cycles(commit, fetched);
}
#endif
