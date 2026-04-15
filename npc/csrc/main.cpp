#include <Vtop.h>
#include <chrono> // 必须包含
#include <nvboard.h>
#include <thread> // 必须包含
#include <verilated.h>
#include <verilated_fst_c.h>
static TOP_NAME dut;
static VerilatedFstC tfp;
static vluint64_t sim_time = 0;

void nvboard_bind_all_pins(TOP_NAME *top);

static void single_cycle() {
  dut.clk = 0;
  dut.eval();
  tfp.dump(sim_time++);
  // std::this_thread::sleep_for(std::chrono::milliseconds(500));
  dut.clk = 1;
  dut.eval();
  tfp.dump(sim_time++);
  // std::this_thread::sleep_for(std::chrono::milliseconds(500));
}

void reset(int n) {
  dut.rst = 0;
  while (n-- > 0)
    single_cycle();
  dut.rst = 1;
}

int main() {
  Verilated::traceEverOn(true);
  dut.trace(&tfp, 99);
  tfp.open("build/wave.fst");

  nvboard_bind_all_pins(&dut);
  nvboard_init();

  reset(10);

  while (1) {
    nvboard_update();
    // dut.eval();
    single_cycle();
  }

  tfp.close();
}
