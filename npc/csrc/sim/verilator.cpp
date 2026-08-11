#include <cpu/cpu.h>
#include <isa.h>
#include <sim.h>
#include <utils.h>

#include <Vtop.h>
#include <verilated.h>
#if VM_TRACE_FST
#include <verilated_fst_c.h>
#endif

static Vtop dut;
static vluint64_t sim_time = 0;
#if VM_TRACE_FST
static VerilatedFstC *trace = nullptr;
#endif

void sim_set_args(int argc, char **argv) { Verilated::commandArgs(argc, argv); }

static void eval_once() {
  dut.eval();
#if VM_TRACE_FST
  if (trace != nullptr) {
    trace->dump(sim_time);
  }
#endif
  sim_time++;
}

void sim_init() {
  Verilated::traceEverOn(true);
#if VM_TRACE_FST
  trace = new VerilatedFstC;
  dut.trace(trace, 99);
  trace->open("build/wave.fst");
#endif
}

void sim_reset(int cycles) {
  std::memset(&cpu, 0, sizeof(cpu));
  dut.clk = 0;
  dut.rst_n = 0;
  while (cycles-- > 0) {
    dut.clk = 0;
    eval_once();
    dut.clk = 1;
    eval_once();
  }
  dut.rst_n = 1;
  eval_once();
  cpu.pc = sim_pc();
}

void sim_exec_once() {
  dut.clk = 0;
  eval_once();
  dut.clk = 1;
  eval_once();
}

void sim_finish() {
  sim_exec_once();
  sim_exec_once();
  dut.final();
#if VM_TRACE_FST
  if (trace != nullptr) {
    trace->close();
    delete trace;
    trace = nullptr;
  }
#endif
}

vaddr_t sim_pc() { return dut.debug_pc; }
word_t sim_inst() { return dut.debug_inst; }
bool sim_invalid_inst() { return dut.invalid_inst; }
bool sim_finished() { return Verilated::gotFinish(); }

extern "C" void npc_reg_write(int index, int data) {
  if (index < 0 || index >= NR_GPR) {
    std::fprintf(stderr, "invalid GPR write x%d at pc = " FMT_WORD "\n", index,
                 sim_pc());
    set_npc_state(NPC_ABORT, sim_pc(), -1);
    return;
  }
  if (index > 0) {
    cpu.gpr[index] = static_cast<word_t>(data);
  }
  cpu.gpr[0] = 0;
}

extern "C" void npc_ebreak(int halt_code, int pc) {
  set_npc_state(NPC_END, static_cast<vaddr_t>(pc),
                static_cast<uint32_t>(halt_code));
}
