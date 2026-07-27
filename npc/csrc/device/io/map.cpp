#include <cpu/cpu.h>
#include <device/map.h>
#include <isa.h>
#include <utils.h>

#include <array>

static constexpr size_t IO_SPACE_MAX = 32u * 1024u * 1024u;
static constexpr size_t PAGE_SIZE = 4096;
static std::array<uint8_t, IO_SPACE_MAX> io_space{};
static size_t io_space_used = 0;

uint8_t *new_space(int size) {
  assert(size > 0);
  size_t aligned =
      (static_cast<size_t>(size) + PAGE_SIZE - 1) & ~(PAGE_SIZE - 1);
  assert(io_space_used + aligned <= io_space.size());
  uint8_t *space = io_space.data() + io_space_used;
  io_space_used += aligned;
  return space;
}

void init_map() {
  io_space.fill(0);
  io_space_used = 0;
}

static bool check_bound(IOMap *map, paddr_t addr, int len) {
  if (map != nullptr && len > 0 && len <= 4 && addr >= map->low &&
      addr + static_cast<paddr_t>(len) - 1 <= map->high) {
    return true;
  }
  std::fprintf(stderr, "device address " FMT_PADDR
                       " is out of bound at pc = " FMT_WORD "\n",
               addr, cpu.pc);
  set_npc_state(NPC_ABORT, cpu.pc, -1);
  return false;
}

word_t map_read(paddr_t addr, int len, IOMap *map) {
  if (!check_bound(map, addr, len)) {
    return 0;
  }
  paddr_t offset = addr - map->low;
  if (map->callback != nullptr) {
    map->callback(offset, len, false);
  }
  word_t data = 0;
  std::memcpy(&data, static_cast<uint8_t *>(map->space) + offset, len);
#ifdef CONFIG_DTRACE
  Log("dtrace: read  " FMT_PADDR " at %s, len = %d, data = " FMT_WORD,
      addr, map->name, len, data);
#endif
  return data;
}

void map_write(paddr_t addr, int len, word_t data, IOMap *map) {
  if (!check_bound(map, addr, len)) {
    return;
  }
  paddr_t offset = addr - map->low;
  std::memcpy(static_cast<uint8_t *>(map->space) + offset, &data, len);
#ifdef CONFIG_DTRACE
  Log("dtrace: write " FMT_PADDR " at %s, len = %d, data = " FMT_WORD,
      addr, map->name, len, data);
#endif
  if (map->callback != nullptr) {
    map->callback(offset, len, true);
  }
}
