#include <cpu/cpu.h>
#include <cpu/difftest.h>
#include <cstdint>
#include <device/device.h>
#include <isa.h>
#include <sim.h>
#include <utils.h>
#ifdef CONFIG_FTRACE
#include "ftrace.h"
#endif

bool check_watchpoints();

static constexpr uint64_t MAX_INST_TO_PRINT = 10;
#define MAX_INST_IN_RINGBUF 16
#define INST_LOG_SIZE 128
static constexpr uint64_t MAX_IDLE_CYCLES = 100000;
uint64_t g_nr_guest_inst = 0;
static uint64_t g_timer = 0;
#ifdef CONFIG_ITRACE
static bool g_print_step = false;
static char iringbuf[MAX_INST_IN_RINGBUF][INST_LOG_SIZE];
static int iringbuf_next = 0;
static int iringbuf_count = 0;

static void iringbuf_record(const char *logbuf) {
  snprintf(iringbuf[iringbuf_next], sizeof(iringbuf[iringbuf_next]), "%s",
           logbuf);
  iringbuf_next = (iringbuf_next + 1) % MAX_INST_IN_RINGBUF;
  if (iringbuf_count < MAX_INST_IN_RINGBUF) {
    iringbuf_count++; // 维护有效记录数
  }
}

static void iringbuf_display() {
  if (iringbuf_count == 0) {
    return;
  }

  printf("Recent instruction trace:\n");
  int start = (iringbuf_next - iringbuf_count + MAX_INST_IN_RINGBUF) %
              MAX_INST_IN_RINGBUF;
  int current = (iringbuf_next - 1 + MAX_INST_IN_RINGBUF) % MAX_INST_IN_RINGBUF;

  for (int i = 0; i < iringbuf_count; i++) {
    int idx = (start + i) % MAX_INST_IN_RINGBUF;
    printf("%s%s\n", idx == current ? "--> " : "    ", iringbuf[idx]);
  }
}

#endif

void set_npc_state(int state, vaddr_t pc, int halt_ret) {
  npc_state.state = state;
  npc_state.halt_pc = pc;
  npc_state.halt_ret = static_cast<uint32_t>(halt_ret);
}

#ifdef CONFIG_ITRACE
static void trace_instruction(vaddr_t pc, word_t inst) {
  char line[128];
  char *p = line;

  p += std::snprintf(p, sizeof(line), FMT_WORD ": %02x %02x %02x %02x  ", pc,
                     inst >> 24, (inst >> 16) & 0xff, (inst >> 8) & 0xff,
                     inst & 0xff);
  void disassemble(char *str, int size, uint64_t pc, uint8_t *code, int nbyte);
  disassemble(p, line + sizeof(line) - p, pc, (uint8_t *)&inst, 4);
  log_write("%s\n", line);
  iringbuf_record(line);
  if (g_print_step && log_fp != stdout) {
    std::puts(line);
  }
}
#endif

static bool exec_once() {
  if (sim_bus_error()) {
    static const char *const operations[] = {"instruction fetch", "load",
                                             "store"};
    unsigned op = sim_bus_error_op();
    const char *operation = op < static_cast<unsigned>(ARRLEN(operations))
                                ? operations[op]
                                : "unknown";
    std::fprintf(stderr,
                 "AXI4-Lite %s error: pc = " FMT_WORD ", addr = " FMT_PADDR
                 ", resp = %u\n",
                 operation, sim_pc(), sim_bus_error_addr(),
                 sim_bus_error_resp());
    set_npc_state(NPC_ABORT, sim_pc(), -1);
    return false;
  }
  if (!sim_debug_commit()) {
    sim_exec_once();
    return false;
  } else {
    vaddr_t pc = sim_pc();
    word_t inst = sim_inst();
#ifdef CONFIG_ITRACE
    trace_instruction(pc, inst);
#endif
    if (sim_invalid_inst()) {
      std::fprintf(stderr,
                   "invalid instruction at pc = " FMT_WORD ", inst = " FMT_WORD
                   "\n",
                   pc, inst);
      set_npc_state(NPC_ABORT, pc, -1);
      return true;
    }

    // Device accesses are served by RTL slaves; sample before the commit edge.
    if (sim_skip_ref()) {
      difftest_skip_ref();
    }
    sim_exec_once();
    cpu.pc = sim_pc();
    cpu.gpr[0] = 0;
    g_nr_guest_inst++;

#ifndef CONFIG_FTRACE
    (void)inst;
#endif
#ifdef CONFIG_FTRACE
    ftrace_trace(pc, cpu.pc, inst);
#endif
    difftest_step(pc, cpu.pc);
#ifdef CONFIG_WATCHPOINT
    if (npc_state.state == NPC_RUNNING && check_watchpoints()) {
      npc_state.state = NPC_STOP;
    }
#endif
    if (npc_state.state == NPC_RUNNING) {
#ifdef CONFIG_DEVICE
      device_update();
#endif
    }
    return true;
  }
}

static void execute(uint64_t n) {
  uint64_t idle_cycles = 0;
  while (n > 0 && npc_state.state == NPC_RUNNING && !sim_finished()) {
    if (exec_once()) {
      n--;
      idle_cycles = 0;
    } else if (++idle_cycles > MAX_IDLE_CYCLES) {
      std::fprintf(stderr,
                   "no instruction committed in %" PRIu64
                   " cycles, possible bus deadlock at pc = " FMT_WORD "\n",
                   idle_cycles, cpu.pc);
      set_npc_state(NPC_ABORT, cpu.pc, -1);
      return;
    }
  }
  if (sim_finished() && npc_state.state == NPC_RUNNING) {
    set_npc_state(NPC_ABORT, cpu.pc, -1);
  }
}

static void statistic() {
  uint64_t cycles = sim_cycle_count();
  Log("host time spent = %" PRIu64 " us", g_timer);
  Log("total guest instructions = %" PRIu64, g_nr_guest_inst);
  Log("total guest cycles = %" PRIu64, cycles);
  if (g_nr_guest_inst > 0 && cycles > 0) {
    Log("PERF: inst= %" PRIu64 " cycles= %" PRIu64 " IPC= %.3f",
        g_nr_guest_inst, cycles, (double)g_nr_guest_inst / (double)cycles);
  }
  if (g_timer > 0) {
    Log("simulation frequency = %" PRIu64 " inst/s",
        g_nr_guest_inst * 1000000 / g_timer);
  }
}

void cpu_exec(uint64_t n) {
#ifdef CONFIG_ITRACE
  g_print_step = n < MAX_INST_TO_PRINT;
#else
  (void)MAX_INST_TO_PRINT;
#endif
  switch (npc_state.state) {
  case NPC_END:
  case NPC_ABORT:
  case NPC_QUIT:
    std::printf("Program execution has ended. To restart, exit NPC and run "
                "again.\n");
    return;
  default:
    npc_state.state = NPC_RUNNING;
  }

  uint64_t start = get_time();
  execute(n);
  g_timer += get_time() - start;

  switch (npc_state.state) {
  case NPC_RUNNING:
    npc_state.state = NPC_STOP;
    break;
  case NPC_END:
  case NPC_ABORT:
    Log("npc: %s at pc = " FMT_WORD,
        npc_state.state == NPC_ABORT
            ? ANSI_FMT("ABORT", ANSI_FG_PINK)
            : (npc_state.halt_ret == 0
                   ? ANSI_FMT("HIT GOOD TRAP", ANSI_FG_GREEN)
                   : ANSI_FMT("HIT BAD TRAP", ANSI_FG_PINK)),
        npc_state.halt_pc);
#ifdef CONFIG_ITRACE
    if (npc_state.state == NPC_ABORT || npc_state.halt_ret != 0) {
      iringbuf_display();
    }
#endif

  case NPC_QUIT:
    statistic();
    break;
  }
}
