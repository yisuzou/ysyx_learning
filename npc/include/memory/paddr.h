#ifndef NPC_MEMORY_PADDR_H
#define NPC_MEMORY_PADDR_H

#include <common.h>

constexpr paddr_t RESET_VECTOR = CONFIG_MBASE;
constexpr paddr_t PMEM_LEFT = CONFIG_MBASE;
constexpr paddr_t PMEM_RIGHT = CONFIG_MBASE + CONFIG_MSIZE - 1;

void init_mem();
uint8_t *guest_to_host(paddr_t addr);
bool in_pmem(paddr_t addr);
word_t paddr_read(paddr_t addr, int len);
void paddr_write(paddr_t addr, int len, word_t data);

#endif
