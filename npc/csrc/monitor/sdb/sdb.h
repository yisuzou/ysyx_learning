#ifndef NPC_SDB_H
#define NPC_SDB_H

#include <common.h>

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

#endif
