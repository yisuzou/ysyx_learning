#ifndef NPC_SDB_H
#define NPC_SDB_H

#include <stdbool.h>
#include <stdint.h>

typedef uint32_t word_t;

word_t expr(char *input, bool *success);
void init_regex();

typedef struct watchpoint {
  int NO;
  struct watchpoint *next;
  word_t tar_val;
  char expr[256];
} WP;

void init_wp_pool();
WP *new_wp();
void free_wp(WP *wp);
WP *find_wp(uint32_t number, bool *empty);
bool check_watchpoints();

#ifdef __cplusplus
extern "C" {
#endif
const char *npc_reg_name(int index);
bool npc_reg_str2val(const char *name, word_t *value);
uint32_t npc_reg_read(int index);
uint32_t npc_get_pc();
bool npc_mem_read(uint32_t addr, uint32_t *value);
#ifdef __cplusplus
}
#endif

#endif
