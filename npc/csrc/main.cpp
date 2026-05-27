#include <Vtop.h>
#include <chrono> // 必须包含
#include <csignal>
#include <cstdlib>
#include <nvboard.h>
#include <thread> // 必须包含
#include <verilated.h>
#include <verilated_fst_c.h>
static TOP_NAME dut;
static VerilatedFstC *tfp = nullptr;
static vluint64_t sim_time = 0;
static volatile sig_atomic_t sim_running = 1;
static bool trace_opened = false;

void nvboard_bind_all_pins(TOP_NAME *top);

static void close_trace() {
  if (tfp != nullptr) {
    if (trace_opened) {
      tfp->close();
      trace_opened = false;
    }
    delete tfp;
    tfp = nullptr;
  } else {
    trace_opened = false;
  }
}

static void request_exit(int) { sim_running = 0; }

static void single_cycle() {
  dut.clk = 0;
  dut.eval();
  tfp->dump(sim_time++);
  // std::this_thread::sleep_for(std::chrono::milliseconds(500));
  dut.clk = 1;
  dut.eval();
  tfp->dump(sim_time++);
  // std::this_thread::sleep_for(std::chrono::milliseconds(500));
}

void reset(int n) {
  dut.rst = 0;
  while (n-- > 0)
    single_cycle();
  dut.rst = 1;
}

int main() {
  std::atexit(close_trace);
  std::signal(SIGINT, request_exit);
  std::signal(SIGTERM, request_exit);
  std::signal(SIGQUIT, request_exit);

  Verilated::traceEverOn(true);
  tfp = new VerilatedFstC;
  dut.trace(tfp, 99);
  tfp->open("build/wave.fst");
  trace_opened = true;
  nvboard_bind_all_pins(&dut);
  nvboard_init();

  reset(10);

  while (sim_running && !Verilated::gotFinish()) {
    nvboard_update();
    // dut.eval();
    single_cycle();
  }

  close_trace();
  nvboard_quit();
  return 0;
}
