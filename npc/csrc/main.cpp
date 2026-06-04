#include <Vtop.h>
#include <cerrno>
#include <csignal>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <verilated.h>
#include <verilated_fst_c.h>

static TOP_NAME dut;
static VerilatedFstC *tfp = nullptr;
static vluint64_t sim_time = 0;
static volatile sig_atomic_t sim_running = 1;
static bool trace_opened = false;

static constexpr uint32_t RESET_VECTOR = 0x80000000;
static constexpr uint32_t PMEM_SIZE = 128 * 1024 * 1024;
static constexpr uint32_t MAX_CYCLES = 9000000;

static uint8_t pmem[PMEM_SIZE] = {};

static int halt_code = -1;
static uint32_t halt_cycle = 0;

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

extern "C" int pmem_read(uint32_t addr);

extern "C" void npc_ebreak(int code, int pc) {
  uint32_t prev_inst = pmem_read(pc - 4);
  if ((prev_inst & 0xfe00707f) == 0x00000013) {
    halt_code = code;
  }
  sim_running = 0;
}
// extern "C" int pmem_read(int raddr);
static uint32_t normalize_paddr(uint32_t addr) {
  return (addr >= RESET_VECTOR) ? (addr - RESET_VECTOR) : addr;
}

static bool check_pmem_range(uint32_t addr, uint32_t len) {
  uint32_t offset = normalize_paddr(addr);
  if (offset > PMEM_SIZE || len > PMEM_SIZE - offset) {
    std::fprintf(stderr, "pmem out of range: addr = 0x%08x, len = %u\n", addr,
                 len);
    sim_running = 0;
    return false;
  }
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

// 将risc-v地址转化到数组地址
extern "C" int
pmem_read(uint32_t addr) { // 总是读取地址为`raddr & ~0x3u`的4字节返回
  uint32_t offset = normalize_paddr(addr);
  offset = offset & (~0x3u);
  if (!check_pmem_range(offset + RESET_VECTOR, 4)) {
    return 0;
  }
  return static_cast<uint32_t>(pmem[offset]) |
         (static_cast<uint32_t>(pmem[offset + 1]) << 8) |
         (static_cast<uint32_t>(pmem[offset + 2]) << 16) |
         (static_cast<uint32_t>(pmem[offset + 3]) << 24);
}
extern "C" void pmem_write(int waddr, int wdata, char wmask) {
  // 总是往地址为`waddr & ~0x3u`的4字节按写掩码`wmask`写入`wdata`
  // `wmask`中每比特表示`wdata`中1个字节的掩码,
  // 如`wmask = 0x3`代表只写入最低2个字节, 内存中的其它字节保持不变
  uint32_t offset = normalize_paddr(waddr);
  offset = offset & (~0x3u);
  if (!check_pmem_range(offset + RESET_VECTOR, 4)) {
    return;
  }
  if (wmask == 0x1) {
    pmem[offset] = static_cast<uint8_t>(wdata & 0xff);
  } else if (wmask == 0x2) {
    pmem[offset + 1] = static_cast<uint8_t>((wdata >> 8) & 0xff);
  } else if (wmask == 0x4) {
    pmem[offset + 2] = static_cast<uint8_t>((wdata >> 16) & 0xff);
  } else if (wmask == 0x8) {
    pmem[offset + 3] = static_cast<uint8_t>((wdata >> 24) & 0xff);
  } else if (wmask == 0x3) {
    pmem[offset] = static_cast<uint8_t>(wdata & 0xff);
    pmem[offset + 1] = static_cast<uint8_t>((wdata >> 8) & 0xff);
  } else if (wmask == 0xc) {
    pmem[offset + 2] = static_cast<uint8_t>((wdata >> 16) & 0xff);
    pmem[offset + 3] = static_cast<uint8_t>((wdata >> 24) & 0xff);
  } else if (wmask == 0xf) {
    pmem[offset] = static_cast<uint8_t>(wdata & 0xff);
    pmem[offset + 1] = static_cast<uint8_t>((wdata >> 8) & 0xff);
    pmem[offset + 2] = static_cast<uint8_t>((wdata >> 16) & 0xff);
    pmem[offset + 3] = static_cast<uint8_t>((wdata >> 24) & 0xff);
  } else {
    std::fprintf(stderr, "error in wmask: 0x%x\n", wmask);

    sim_running = 0;
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

static void single_cycle() {
  dut.clk = 0;
  eval_once();
  tfp->dump(sim_time++);

  dut.clk = 1;
  eval_once();
  tfp->dump(sim_time++);
}

void reset(int n) {
  dut.rst_n = 0;
  while (n-- > 0)
    single_cycle();
  dut.rst_n = 1;
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  if (argc < 2) {
    std::fprintf(stderr, "usage: %s <image>\n", argv[0]);
    return 1;
  }
  if (!load_img(argv[1])) {
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
  tfp = new VerilatedFstC;
  dut.trace(tfp, 99);
  tfp->open("build/wave.fst");
  trace_opened = true;

  reset(10);

  uint32_t cycle = 0;
  for (; sim_running && !Verilated::gotFinish() && cycle < MAX_CYCLES;
       cycle++) {
    single_cycle();
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
