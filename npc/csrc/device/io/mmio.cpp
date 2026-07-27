#include <cpu/cpu.h>
#include <cpu/difftest.h>
#include <device/map.h>
#include <device/mmio.h>
#include <isa.h>
#include <memory/paddr.h>
#include <utils.h>

#include <array>

static constexpr int NR_MAP = 16;
static std::array<IOMap, NR_MAP> maps{};
static int nr_map = 0;

static bool overlaps(paddr_t left1, paddr_t right1, paddr_t left2,
                     paddr_t right2) {
  return left1 <= right2 && right1 >= left2;
}

static IOMap *fetch_mmio_map(paddr_t addr) {
  for (int i = 0; i < nr_map; i++) {
    if (addr >= maps[i].low && addr <= maps[i].high) {
      difftest_skip_ref();
      return &maps[i];
    }
  }
  return nullptr;
}

void add_mmio_map(const char *name, paddr_t addr, void *space, uint32_t len,
                  io_callback_t callback) {
  assert(name != nullptr && space != nullptr && len > 0 && nr_map < NR_MAP);
  paddr_t right = addr + len - 1;
  if (right < addr || overlaps(addr, right, PMEM_LEFT, PMEM_RIGHT)) {
    std::fprintf(stderr, "MMIO region %s overlaps physical memory\n", name);
    std::exit(EXIT_FAILURE);
  }
  for (int i = 0; i < nr_map; i++) {
    if (overlaps(addr, right, maps[i].low, maps[i].high)) {
      std::fprintf(stderr, "MMIO region %s overlaps %s\n", name, maps[i].name);
      std::exit(EXIT_FAILURE);
    }
  }

  maps[nr_map] = {
      .name = name,
      .low = addr,
      .high = right,
      .space = space,
      .callback = callback,
  };
  Log("Add mmio map '%s' at [" FMT_PADDR ", " FMT_PADDR "]", name, addr,
      right);
  nr_map++;
}

word_t mmio_read(paddr_t addr, int len) {
  return map_read(addr, len, fetch_mmio_map(addr));
}

void mmio_write(paddr_t addr, int len, word_t data) {
  map_write(addr, len, data, fetch_mmio_map(addr));
}
