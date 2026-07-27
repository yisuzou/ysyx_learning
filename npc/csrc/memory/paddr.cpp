#include <cpu/cpu.h>
#include <device/mmio.h>
#include <isa.h>
#include <memory/paddr.h>
#include <utils.h>

#include <array>

static std::array<uint8_t, CONFIG_MSIZE> pmem{};

void init_mem() {
  pmem.fill(0);
  Log("physical memory area [" FMT_PADDR ", " FMT_PADDR "]", PMEM_LEFT,
      PMEM_RIGHT);
}

bool in_pmem(paddr_t addr) { return addr - CONFIG_MBASE < CONFIG_MSIZE; }

uint8_t *guest_to_host(paddr_t addr) {
  assert(in_pmem(addr));
  return pmem.data() + addr - CONFIG_MBASE;
}

static bool valid_access(paddr_t addr, int len) {
  return len > 0 && len <= 4 && in_pmem(addr) &&
         addr - CONFIG_MBASE <= CONFIG_MSIZE - static_cast<uint32_t>(len);
}

word_t paddr_read(paddr_t addr, int len) {
  if (!in_pmem(addr)) {
#ifdef CONFIG_DEVICE
    return mmio_read(addr, len);
#else
    std::fprintf(stderr, "device access while CONFIG_DEVICE is disabled\n");
    set_npc_state(NPC_ABORT, cpu.pc, -1);
    return 0;
#endif
  }
  if (!valid_access(addr, len)) {
    std::fprintf(stderr, "physical address " FMT_PADDR
                         " is out of bound at pc = " FMT_WORD "\n",
                 addr, cpu.pc);
    set_npc_state(NPC_ABORT, cpu.pc, -1);
    return 0;
  }

  word_t data = 0;
  std::memcpy(&data, guest_to_host(addr), len);
#ifdef CONFIG_MTRACE
  Log("paddr_read: addr = " FMT_PADDR ", len = %d, data = " FMT_WORD, addr,
      len, data);
#endif
  return data;
}

void paddr_write(paddr_t addr, int len, word_t data) {
  if (!in_pmem(addr)) {
#ifdef CONFIG_DEVICE
    mmio_write(addr, len, data);
#else
    std::fprintf(stderr, "device access while CONFIG_DEVICE is disabled\n");
    set_npc_state(NPC_ABORT, cpu.pc, -1);
#endif
    return;
  }
  if (!valid_access(addr, len)) {
    std::fprintf(stderr, "physical address " FMT_PADDR
                         " is out of bound at pc = " FMT_WORD "\n",
                 addr, cpu.pc);
    set_npc_state(NPC_ABORT, cpu.pc, -1);
    return;
  }
#ifdef CONFIG_MTRACE
  Log("paddr_write: addr = " FMT_PADDR ", len = %d, data = " FMT_WORD, addr,
      len, data);
#endif
  std::memcpy(guest_to_host(addr), &data, len);
}

extern "C" int pmem_ifetch(int raddr) {
  paddr_t addr = static_cast<paddr_t>(raddr) & ~0x3u;
  if (!valid_access(addr, 4)) {
    return 0;
  }
  word_t data = 0;
  std::memcpy(&data, guest_to_host(addr), sizeof(data));
  return static_cast<int>(data);
}

extern "C" int pmem_read(int raddr) {
  paddr_t addr = static_cast<paddr_t>(raddr) & ~0x3u;
  return static_cast<int>(paddr_read(addr, 4));
}

extern "C" void pmem_write(int waddr, int wdata, char wmask) {
  paddr_t addr = static_cast<paddr_t>(waddr) & ~0x3u;
  word_t data = static_cast<word_t>(wdata);
  uint8_t mask = static_cast<uint8_t>(wmask);
  int first = 0;
  while (first < 4 && (mask & (1u << first)) == 0) {
    first++;
  }
  int len = 0;
  while (first + len < 4 && (mask & (1u << (first + len))) != 0) {
    len++;
  }
  uint8_t expected = len == 0 ? 0 : ((1u << len) - 1) << first;
  if (mask != expected || (len != 1 && len != 2 && len != 4)) {
    std::fprintf(stderr, "unsupported write mask: 0x%02x\n", mask);
    set_npc_state(NPC_ABORT, cpu.pc, -1);
    return;
  }
  paddr_write(addr + first, len, data >> (first * 8));
}
