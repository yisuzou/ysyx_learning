#include <VMEM.h>
#include <verilated.h>

#include <array>
#include <cstdint>
#include <cstdio>
#include <cstdlib>

static constexpr uint32_t BASE = 0x80000000;
static std::array<uint8_t, 1024> memory{};
static unsigned reads, fetches, writes;
static VMEM dut;

static void require(bool ok, const char *message) {
  if (!ok) {
    std::fprintf(stderr, "FAIL: %s\n", message);
    std::exit(1);
  }
}

static uint32_t read_word(uint32_t addr) {
  require(addr >= BASE && addr - BASE <= memory.size() - 4,
          "DPI read outside RAM");
  uint32_t value = 0;
  for (unsigned i = 0; i < 4; ++i) value |= uint32_t(memory[addr - BASE + i]) << (8 * i);
  return value;
}

extern "C" int pmem_ifetch(int addr) {
  ++fetches;
  return read_word(static_cast<uint32_t>(addr));
}
extern "C" int pmem_read(int addr, char len) {
  require(len == 4, "MEM must read one aligned word");
  ++reads;
  return read_word(static_cast<uint32_t>(addr));
}
extern "C" void pmem_write(int addr, int data, char len) {
  uint32_t a = static_cast<uint32_t>(addr);
  require(a >= BASE && a - BASE <= memory.size() - static_cast<unsigned>(len),
          "DPI write outside RAM");
  ++writes;
  for (unsigned i = 0; i < static_cast<unsigned>(len); ++i)
    memory[a - BASE + i] = static_cast<uint32_t>(data) >> (8 * i);
}

static void tick() {
  dut.clk = 0; dut.eval();
  dut.clk = 1; dut.eval();
  dut.clk = 0; dut.eval();
}

template <typename Predicate>
static void until(Predicate ready, const char *message) {
  dut.eval();
  for (unsigned n = 0; !ready(); ++n) {
    require(n < 100, message);
    tick();
  }
}

static void reset() {
  dut.rst_n = 0;
  dut.s_axi_arvalid = dut.s_axi_awvalid = dut.s_axi_wvalid = 0;
  dut.s_axi_rready = dut.s_axi_bready = 0;
  tick(); tick();
  require(!dut.s_axi_arready && !dut.s_axi_rvalid && !dut.s_axi_bvalid,
          "reset must suppress handshakes");
  dut.rst_n = 1;
  dut.eval();
}

static void start_read(uint32_t addr, bool fetch = false) {
  unsigned before_reads = reads, before_fetches = fetches;
  dut.s_axi_araddr = addr;
  dut.s_axi_arprot = fetch ? 5 : 1;
  dut.s_axi_arvalid = 1;
  until([] { return dut.s_axi_arready; }, "AR timeout");
  tick();
  // Upstream is free to change address/protection immediately after AR.
  dut.s_axi_arvalid = 0;
  dut.s_axi_araddr = 0x40000000;
  dut.s_axi_arprot = fetch ? 1 : 5;
  dut.eval();
#ifndef TEST_SYNTHESIS
  bool valid = addr >= BASE && (addr & ~3u) - BASE <= memory.size() - 4;
  require(reads == before_reads + (valid && !fetch) &&
          fetches == before_fetches + (valid && fetch),
          "AR handshake must call the correct read DPI exactly once");
#else
  (void)before_reads;
  (void)before_fetches;
#endif
#if TEST_RANDOM_DELAY == 0
  require(!dut.s_axi_rvalid, "response delay state was unexpectedly bypassed");
  tick();
  require(dut.s_axi_rvalid, "extra read-access cycle before RVALID");
#endif
}

static void finish_read(uint32_t expected, unsigned response = 0) {
  until([] { return dut.s_axi_rvalid; }, "R timeout");
  unsigned before = reads + fetches;
  for (unsigned n = 0; n < 12; ++n) {
    require(dut.s_axi_rvalid && dut.s_axi_rdata == expected &&
            dut.s_axi_rresp == response && !dut.s_axi_arready,
            "R payload/VALID changed under backpressure");
    tick();
  }
  require(reads + fetches == before, "R backpressure repeated a read DPI call");
  dut.s_axi_rready = 1;
  tick();
  dut.s_axi_rready = 0;
  dut.eval();
  require(!dut.s_axi_rvalid, "R response repeated after completion");
}

static void finish_write(unsigned response = 0) {
  until([] { return dut.s_axi_bvalid; }, "B timeout");
  unsigned before = writes;
  for (unsigned n = 0; n < 9; ++n) {
    require(dut.s_axi_bvalid && dut.s_axi_bresp == response,
            "B payload/VALID changed under backpressure");
    tick();
  }
  require(writes == before, "B backpressure repeated a write DPI call");
  dut.s_axi_bready = 1;
  tick();
  dut.s_axi_bready = 0;
  dut.eval();
}

static void send_write(uint32_t addr, uint32_t data, unsigned strb, unsigned order) {
  bool aw = false, w = false;
  for (unsigned n = 0; !aw || !w; ++n) {
    require(n < 100, "AW/W timeout");
    dut.s_axi_awaddr = addr;
    dut.s_axi_awprot = 1;
    dut.s_axi_wdata = data;
    dut.s_axi_wstrb = strb;
    dut.s_axi_awvalid = !aw && (order != 1 || n >= 3);
    dut.s_axi_wvalid = !w && (order != 0 || n >= 3);
    dut.eval();
    bool a = dut.s_axi_awvalid && dut.s_axi_awready;
    bool d = dut.s_axi_wvalid && dut.s_axi_wready;
    tick();
    aw |= a;
    w |= d;
  }
  dut.s_axi_awvalid = dut.s_axi_wvalid = 0;
  dut.s_axi_awaddr = 0x40000000;
  dut.s_axi_wdata = 0xbad0bad0;
  dut.eval();
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  reset();
  // All strobes and all three AW/W arrival orders, including zero strobes.
  for (unsigned mask = 0; mask < 16; ++mask) {
    uint32_t addr = BASE + 4 * mask;
    send_write(addr, 0, 15, mask % 3);
    finish_write();
    send_write(addr, 0x76543210, mask, mask % 3);
    finish_write();
    uint32_t expected = 0;
    for (unsigned lane = 0; lane < 4; ++lane)
      if (mask & (1u << lane)) expected |= 0x76543210u & (0xffu << (8 * lane));
    start_read(addr + (mask % 4), mask & 1);
    finish_read(expected);
  }
  start_read(0x40000000);
  finish_read(0, 3);
  start_read(BASE + 1024, true);
  finish_read(0, 3);
  send_write(0x40000000, 1, 15, 0);
  finish_write(3);
  unsigned before = writes;
  send_write(0x40000000, 1, 0, 1);
  finish_write();
  require(writes == before, "zero strobe must not access the backend");

  // Overlap AR with WR_ACCESS on the same word. Both the DPI backend and
  // synthesized storage must return the old value, then expose the new one.
  send_write(BASE + 256, 0x11223344, 15, 2);
  finish_write();
  until([] { return dut.s_axi_arready; }, "idle ARREADY timeout");
  send_write(BASE + 256, 0x55667788, 15, 2);
  start_read(BASE + 256);
  finish_read(0x11223344);
  finish_write();
  start_read(BASE + 256);
  finish_read(0x55667788);

  // Reset drops a pending response; an accepted read must not be replayed.
  start_read(BASE + 256);
  until([] { return dut.s_axi_rvalid; }, "pre-reset R timeout");
  before = reads + fetches;
  reset();
  for (unsigned n = 0; n < 10; ++n) tick();
  require(!dut.s_axi_rvalid && reads + fetches == before, "reset replayed a read");
  start_read(BASE + 256, true);
  finish_read(0x55667788);
  std::printf("PASS: MEM (delay=%d, strobes, AW/W order, R/B stalls, read-first, reset)\n",
              TEST_RANDOM_DELAY);
}
