#ifndef NPC_DEVICE_MAP_H
#define NPC_DEVICE_MAP_H

#include <common.h>

using io_callback_t = void (*)(uint32_t offset, int len, bool is_write);

struct IOMap {
  const char *name;
  paddr_t low;
  paddr_t high;
  void *space;
  io_callback_t callback;
};

uint8_t *new_space(int size);
void init_map();
void add_mmio_map(const char *name, paddr_t addr, void *space, uint32_t len,
                  io_callback_t callback);
word_t map_read(paddr_t addr, int len, IOMap *map);
void map_write(paddr_t addr, int len, word_t data, IOMap *map);

#endif
