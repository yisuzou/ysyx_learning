#ifndef NPC_COMMON_H
#define NPC_COMMON_H

#include <cassert>
#include <cinttypes>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include <generated/autoconf.h>

using word_t = uint32_t;
using vaddr_t = uint32_t;
using paddr_t = uint32_t;

#define FMT_WORD "0x%08" PRIx32
#define FMT_PADDR "0x%08" PRIx32
#define ARRLEN(arr) (int)(sizeof(arr) / sizeof((arr)[0]))

#endif
