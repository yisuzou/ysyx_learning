#ifndef NPC_UTILS_H
#define NPC_UTILS_H

#include <common.h>

enum { NPC_RUNNING, NPC_STOP, NPC_END, NPC_ABORT, NPC_QUIT };

struct NPCState {
  int state;
  vaddr_t halt_pc;
  uint32_t halt_ret;
};

extern NPCState npc_state;
extern FILE *log_fp;

uint64_t get_time();
void init_log(const char *log_file);
int is_exit_status_bad();
void log_write(const char *format, ...);

#define ANSI_FG_RED "\33[1;31m"
#define ANSI_FG_GREEN "\33[1;32m"
#define ANSI_FG_YELLOW "\33[1;33m"
#define ANSI_BG_RED "\33[1;41m"
#define ANSI_NONE "\33[0m"
#define ANSI_FMT(str, fmt) fmt str ANSI_NONE

#define Log(format, ...)                                                        \
  do {                                                                          \
    std::fprintf(log_fp, "[%s:%d] " format "\n", __FILE__, __LINE__,            \
                 ##__VA_ARGS__);                                                \
    std::fflush(log_fp);                                                        \
  } while (0)

#endif
