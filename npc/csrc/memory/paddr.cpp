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

static bool valid_dpi_access_len(uint8_t len) {
  return len == 1 || len == 2 || len == 4;
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
    std::fprintf(stderr,
                 "physical address " FMT_PADDR
                 " is out of bound at pc = " FMT_WORD "\n",
                 addr, cpu.pc);
    set_npc_state(NPC_ABORT, cpu.pc, -1);
    return 0;
  }

  word_t data = 0;
  std::memcpy(&data, guest_to_host(addr), len);
#ifdef CONFIG_MTRACE
  Log("paddr_read: addr = " FMT_PADDR ", len = %d, data = " FMT_WORD, addr, len,
      data);
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
    std::fprintf(stderr,
                 "physical address " FMT_PADDR
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

// DPI backend of the RTL SRAM slave (MEM.v): physical memory only.
// Devices are RTL slaves behind the XBAR and never reach these functions.
static bool check_dpi_access(paddr_t addr, uint8_t len, bool is_write) {
  if (!valid_dpi_access_len(len)) {
    std::fprintf(stderr, "unsupported %s length: %u\n",
                 is_write ? "write" : "read", static_cast<unsigned>(len));
  } else if (valid_access(addr, len)) {
    return true;
  } else {
    std::fprintf(stderr, "pmem %s at " FMT_PADDR " is outside SRAM\n",
                 is_write ? "write" : "read", addr);
  }
  set_npc_state(NPC_ABORT, cpu.pc, -1);
  return false;
}

extern "C" int pmem_read(int raddr, char rlen) {
  paddr_t addr = static_cast<paddr_t>(raddr);
  uint8_t len = static_cast<uint8_t>(rlen);
  if (!check_dpi_access(addr, len, false)) {
    return 0;
  }
  return static_cast<int>(paddr_read(addr, len));
}

extern "C" void pmem_write(int waddr, int wdata, char wlen) {
  paddr_t addr = static_cast<paddr_t>(waddr);
  uint8_t len = static_cast<uint8_t>(wlen);
  if (!check_dpi_access(addr, len, true)) {
    return;
  }
  paddr_write(addr, len, static_cast<word_t>(wdata));
}
