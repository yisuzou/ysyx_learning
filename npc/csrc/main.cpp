#include <Vtop.h>
#include <cerrno>
#include <csignal>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <stdint.h>
#include <algorithm>
#include <stdio.h>
#include <sys/time.h>
#include <verilated.h>
#if VM_TRACE_FST
#include <verilated_fst_c.h>
#endif

static TOP_NAME dut;
static uint32_t cpu_gpr[32] = {};
#if VM_TRACE_FST
static VerilatedFstC *tfp = nullptr;
static bool trace_opened = false;
#endif
static vluint64_t sim_time = 0;
static volatile sig_atomic_t sim_running = 1;
static int debug_mode = 0;
static constexpr uint32_t RESET_VECTOR = 0x80000000;
static constexpr uint32_t PMEM_SIZE = 128 * 1024 * 1024;
// static constexpr uint32_t MAX_CYCLES = 9000000;

static constexpr uint32_t SER_ADDR = 0x10000000;
static constexpr uint32_t RTC_ADDR = 0x10000048;

static uint8_t pmem[PMEM_SIZE] = {};

static int halt_code = -1;
static uint32_t halt_cycle = 0;

static uint64_t boot_time = 0;

static uint64_t get_elapsed_us() {
  struct timeval now;
  gettimeofday(&now, NULL);
  uint64_t us = static_cast<uint64_t>(now.tv_sec) * 1000000 + now.tv_usec;
  if (boot_time == 0)
    boot_time = us;
  return us - boot_time;
}

static void close_trace() {
#if VM_TRACE_FST
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
#endif
}
void sdb_mainloop();
bool check_watchpoints();
static void request_exit(int) { sim_running = 0; }

extern "C" bool npc_simulation_active() {
  return sim_running && !Verilated::gotFinish();
}

extern "C" void npc_notify_execution_finished() {
  std::printf("npc: program execution has ended; "
              "please exit and reload the image to run again\n");
}

extern "C" int pmem_read(uint32_t addr);

extern "C" void npc_reg_write(int index, int data) {
  if (index > 0 && index < 32) {
    cpu_gpr[index] = static_cast<uint32_t>(data);
  }
}

extern "C" uint32_t npc_reg_read(int index) {
  if (index < 0 || index >= 32) {
    return 0;
  }
  return index == 0 ? 0 : cpu_gpr[index];
}

extern "C" uint32_t npc_get_pc() { return dut.debug_pc; }

extern "C" void npc_ebreak(int code, int pc) {
  uint32_t prev_inst = pmem_read(pc - 4);
  if ((prev_inst & 0xfe00707f) == 0x00000013) {
    halt_code = code;
  }
  sim_running = 0;
}
// extern "C" int pmem_read(int raddr);
static bool check_pmem_range(uint32_t addr, uint32_t len) {
  if (len > PMEM_SIZE || addr < RESET_VECTOR ||
      addr - RESET_VECTOR > PMEM_SIZE - len) {
    std::fprintf(stderr, "pmem out of range: addr = 0x%08x, len = %u\n", addr,
                 len);
    sim_running = 0;
    return false;
  }

  return true;
}

extern "C" bool npc_mem_read(uint32_t addr, uint32_t *value) {
  uint32_t aligned = addr & ~0x3u;
  if (aligned < RESET_VECTOR || aligned - RESET_VECTOR > PMEM_SIZE - 4) {
    return false;
  }
  *value = static_cast<uint32_t>(pmem_read(addr));
  return true;
}

static bool load_img(const char *img_file) {
  std::FILE *fp = std::fopen(img_file, "rb");
  if (fp == nullptr) {
    std::fprintf(stderr, "failed to open image '%s': %s\n", img_file,
                 std::strerror(errno));
    return false;
  }

  std::size_t loaded = std::fread(pmem, 1, PMEM_SIZE, fp);
  if (std::ferror(fp)) {
    std::fprintf(stderr, "failed to read image '%s'\n", img_file);
    std::fclose(fp);
    return false;
  }

  int extra = std::fgetc(fp);
  if (extra != EOF) {
    std::fprintf(stderr, "image '%s' is larger than pmem size %u\n", img_file,
                 PMEM_SIZE);
    std::fclose(fp);
    return false;
  }

  std::fclose(fp);
  std::printf("loaded image '%s', size = %zu bytes\n", img_file, loaded);
  return true;
}

// 将risc-v地址转化为数组地址
extern "C" int
pmem_read(uint32_t addr) { // 总是读取地址为`addr & ~0x3u`的4字节返回
  if (addr == RTC_ADDR || addr == RTC_ADDR + 4) {
    uint64_t us = get_elapsed_us();
    if (addr == RTC_ADDR)
      return static_cast<uint32_t>(us);
    else
      return static_cast<uint32_t>(us >> 32);
  } // 模拟RTC寄存器，返回自仿真开始以来的微秒数，低32位在RTC_ADDR，高32位在RTC_ADDR+4
  uint32_t aligned = addr & (~0x3u);
  if (!check_pmem_range(aligned, 4)) {
    return 0;
  }
  uint32_t idx = aligned - RESET_VECTOR;
  return static_cast<uint32_t>(pmem[idx]) |
         (static_cast<uint32_t>(pmem[idx + 1]) << 8) |
         (static_cast<uint32_t>(pmem[idx + 2]) << 16) |
         (static_cast<uint32_t>(pmem[idx + 3]) << 24);
}
extern "C" void pmem_write(int waddr, int wdata, char wmask) {
  // 总是往地址为`waddr & ~0x3u`的4字节按写掩码`wmask`写入`wdata`
  // `wmask`中每比特表示`wdata`中1个字节的掩码,
  // 如`wmask = 0x3`代表只写入最低2个字节, 内存中的其它字节保持不变

  if (waddr == SER_ADDR) {
    // 串口，输出单个字符，只有低8位是有效数据；
    uint8_t ch = wdata & 0xff;
    putc(ch, stderr);
    return;
  } else {
    uint32_t aligned = waddr & (~0x3u);
    if (!check_pmem_range(aligned, 4)) {
      return;
    }
    uint32_t idx = aligned - RESET_VECTOR;
    if (wmask == 0x1) {
      pmem[idx] = static_cast<uint8_t>(wdata & 0xff);
    } else if (wmask == 0x2) {
      pmem[idx + 1] = static_cast<uint8_t>((wdata >> 8) & 0xff);
    } else if (wmask == 0x4) {
      pmem[idx + 2] = static_cast<uint8_t>((wdata >> 16) & 0xff);
    } else if (wmask == 0x8) {
      pmem[idx + 3] = static_cast<uint8_t>((wdata >> 24) & 0xff);
    } else if (wmask == 0x3) {
      pmem[idx] = static_cast<uint8_t>(wdata & 0xff);
      pmem[idx + 1] = static_cast<uint8_t>((wdata >> 8) & 0xff);
    } else if (wmask == 0xc) {
      pmem[idx + 2] = static_cast<uint8_t>((wdata >> 16) & 0xff);
      pmem[idx + 3] = static_cast<uint8_t>((wdata >> 24) & 0xff);
    } else if (wmask == 0xf) {
      pmem[idx] = static_cast<uint8_t>(wdata & 0xff);
      pmem[idx + 1] = static_cast<uint8_t>((wdata >> 8) & 0xff);
      pmem[idx + 2] = static_cast<uint8_t>((wdata >> 16) & 0xff);
      pmem[idx + 3] = static_cast<uint8_t>((wdata >> 24) & 0xff);
    } else {
      std::fprintf(stderr, "error in wmask: 0x%x\n", wmask);

      sim_running = 0;
    }
  }
}
static void eval_once() { // 实现DPI-C之前，由这里加载指令
  dut.eval();
  /*
    if (dut.rst_n && dut.invalid_inst) {
      std::fprintf(stderr, "invalid instruction: pc = 0x%08x, inst = 0x%08x\n",
                   dut.pc, dut.inst);
      sim_running = 0;
    }
    */
}
// 仿真的单步执行
static void single_cycle() {
  dut.clk = 0;
  eval_once();
#if VM_TRACE_FST
  tfp->dump(sim_time++);
#else
  sim_time++;
#endif

  dut.clk = 1;
  eval_once();
#if VM_TRACE_FST
  tfp->dump(sim_time++);
#else
  sim_time++;
#endif
}

void reset(int n) {
  std::fill(cpu_gpr, cpu_gpr + 32, 0);
  dut.rst_n = 0;
  while (n-- > 0)
    single_cycle();
  dut.rst_n = 1;
}

int parse_args(int argc, char **argv) {
  if (argc < 2) {
    std::fprintf(stderr, "usage: %s <image>\n", argv[0]);
    return 1;
  }
  if (!load_img(argv[1])) {
    return 1;
  }
  if (argv[2] == nullptr) {
    std::printf("npc: \033[1;33mRUNNING_MODE\033[0m\n");
    return 0;
  } // 上面说明没有额外参数，直接返回0
  else if (strcmp(argv[2], "-d") == 0) {
    std::printf("npc: \033[1;33mDEBUG_MODE\033[0m\n");
    debug_mode = 1;
  } else {
    std::fprintf(stderr, "unknown option: %s\n", argv[2]);
    return 1;
  }
  return 0;
}

uint64_t cpu_exec(uint64_t n) {
  uint64_t i = 0;
  for (; i < n && sim_running && !Verilated::gotFinish(); i++) {
    single_cycle();
    if (check_watchpoints()) {
      break;
    }
  }
  return i;
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  if (parse_args(argc, argv) != 0) {
    return 1;
  }
  // mem.bin ebrak;
  //  pmem[0x1218] = 0x73;
  //  pmem[0x1219] = 0x00;
  //  pmem[0x121a] = 0x10;
  //  pmem[0x121b] = 0x00;
  // sum.bin
  // pmem[0x224] = 0x73;
  // pmem[0x225] = 0x00;
  // pmem[0x226] = 0x10;
  // pmem[0x227] = 0x00;
  std::atexit(close_trace);
  std::signal(SIGINT, request_exit);
  std::signal(SIGTERM, request_exit);
  std::signal(SIGQUIT, request_exit);

  Verilated::traceEverOn(true);
#if VM_TRACE_FST
  tfp = new VerilatedFstC;
  dut.trace(tfp, 99);
  tfp->open("build/wave.fst");
  trace_opened = true;
#endif

  reset(10);
  uint64_t cycle = 0;
  if (!debug_mode) {
    cycle = cpu_exec(-1);
  } else {
    sdb_mainloop();
    cycle = sim_time / 2;
  }
  halt_cycle = cycle;

  close_trace();

  if (halt_code == 0) {
    std::printf("npc: \033[1;32mHIT GOOD TRAP\033[0m at cycle %u\n",
                halt_cycle);
    return 0;
  } else if (halt_code != -1) {
    std::printf("npc: \033[1;31mHIT BAD TRAP\033[0m (code = %d) at cycle %u\n",
                halt_code, halt_cycle);
    return 1;
  } else {
    std::printf("npc: \033[1;31mSIM END\033[0m at cycle %u (no trap)\n",
                halt_cycle);
    return 1;
  }
}
