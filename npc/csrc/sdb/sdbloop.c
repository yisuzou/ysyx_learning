#include "sdb.h"

#include <readline/history.h>
#include <readline/readline.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>

#define ARRLEN(arr) (int)(sizeof(arr) / sizeof(arr[0]))

uint64_t cpu_exec(uint64_t n);
extern "C" bool npc_simulation_active();
extern "C" void npc_notify_execution_finished();

static char *rl_gets() {
  static char *line_read = nullptr;
  if (line_read != nullptr) {
    free(line_read);
    line_read = nullptr;
  }
  line_read = readline("(npc) ");
  if (line_read != nullptr && *line_read != '\0') {
    add_history(line_read);
  }
  return line_read;
}

static int cmd_c(char *args) {
  cpu_exec(UINT64_MAX);
  if (!npc_simulation_active()) {
    npc_notify_execution_finished();
  }
  return 0;
}

static int cmd_q(char *args) { return -1; }

static int cmd_si(char *args) {
  uint64_t count = 1;
  if (args != nullptr) {
    char *end = nullptr;
    long value = std::strtol(args, &end, 10);
    if (*args == '\0' || *end != '\0' || value <= 0) {
      std::printf("si expects a positive decimal number\n");
      return 0;
    }
    count = static_cast<uint64_t>(value);
  }
  cpu_exec(count);
  if (!npc_simulation_active()) {
    npc_notify_execution_finished();
  }
  return 0;
}

static int cmd_info(char *args);
static int cmd_x(char *args);
static int cmd_p(char *args);
static int cmd_w(char *args);
static int cmd_d(char *args);
static int cmd_help(char *args);

static struct {
  const char *name;
  const char *description;
  int (*handler)(char *);
} cmd_table[] = {
    {"help", "Display information about all supported commands", cmd_help},
    {"c", "Continue the execution of the program", cmd_c},
    {"q", "Exit NPC debug mode", cmd_q},
    {"si", "Single-step execution", cmd_si},
    {"info", "Display registers or watchpoints", cmd_info},
    {"x", "Scan memory: x N EXPR", cmd_x},
    {"p", "Calculate an expression", cmd_p},
    {"w", "Set a watchpoint: w EXPR", cmd_w},
    {"d", "Delete a watchpoint: d N", cmd_d},
};

#define NR_CMD ARRLEN(cmd_table)

static int cmd_help(char *args) {
  char *arg = std::strtok(args, " \t");
  if (arg == nullptr) {
    for (int i = 0; i < NR_CMD; i++) {
      std::printf("%s - %s\n", cmd_table[i].name, cmd_table[i].description);
    }
    return 0;
  }
  for (int i = 0; i < NR_CMD; i++) {
    if (std::strcmp(arg, cmd_table[i].name) == 0) {
      std::printf("%s - %s\n", cmd_table[i].name, cmd_table[i].description);
      return 0;
    }
  }
  std::printf("Unknown command '%s'\n", arg);
  return 0;
}

static int cmd_info(char *args) {
  char *arg = std::strtok(args, " \t");
  if (arg == nullptr) {
    std::printf(
        "argument is missing: use 'r' for registers or 'w' for watchpoints\n");
    return 0;
  }
  if (std::strcmp(arg, "r") == 0) {
    for (int i = 0; i < 32; i++) {
      std::printf("%-4s: 0x%08x%s", npc_reg_name(i), npc_reg_read(i),
                  (i % 4 == 3) ? "\n" : "  ");
    }
    std::printf("pc  : 0x%08x\n", npc_get_pc());
    return 0;
  }
  if (std::strcmp(arg, "w") == 0) {
    bool empty = false;
    std::printf("%-5s %-24s %-12s\n", "NO", "EXPR", "VALUE");
    for (uint32_t i = 0; i < 32; i++) {
      WP *wp = find_wp(i, &empty);
      if (empty) {
        std::printf("No watchpoints in use.\n");
        return 0;
      }
      if (wp != nullptr) {
        std::printf("%-5d %-24s 0x%08x\n", wp->NO, wp->expr, wp->tar_val);
      }
    }
    return 0;
  }
  std::printf("invalid info argument: %s\n", arg);
  return 0;
}

static int cmd_x(char *args) {
  if (args == nullptr) {
    std::printf("usage: x N EXPR\n");
    return 0;
  }
  char *count_text = std::strtok(args, " \t");
  char *address_text = std::strtok(nullptr, "\n");
  if (count_text == nullptr || address_text == nullptr) {
    std::printf("usage: x N EXPR\n");
    return 0;
  }
  while (*address_text == ' ' || *address_text == '\t') {
    address_text++;
  }

  char *end = nullptr;
  unsigned long count = std::strtoul(count_text, &end, 10);
  if (*count_text == '\0' || *end != '\0' || count == 0) {
    std::printf("N must be a positive decimal number\n");
    return 0;
  }
  bool success = true;
  word_t address = expr(address_text, &success);
  if (!success) {
    std::printf("invalid address expression\n");
    return 0;
  }
  for (unsigned long i = 0; i < count; i++) {
    uint32_t value = 0;
    uint32_t current = address + static_cast<uint32_t>(i * 4);
    if (!npc_mem_read(current, &value)) {
      std::printf("memory scan stopped at 0x%08x\n", current);
      return 0;
    }
    std::printf("0x%08x: 0x%08x%s", current, value,
                (i % 4 == 3) ? "\n" : "  ");
  }
  if (count % 4 != 0) {
    std::printf("\n");
  }
  return 0;
}

static int cmd_p(char *args) {
  if (args == nullptr || *args == '\0') {
    std::printf("usage: p EXPR\n");
    return 0;
  }
  bool success = true;
  word_t result = expr(args, &success);
  if (success) {
    std::printf("decimal: %u\nhex: 0x%08x\n", result, result);
  } else {
    std::printf("failed to evaluate expression\n");
  }
  return 0;
}

static int cmd_w(char *args) {
  if (args == nullptr || *args == '\0') {
    std::printf("usage: w EXPR\n");
    return 0;
  }
  if (std::strlen(args) >= sizeof(((WP *)nullptr)->expr)) {
    std::printf("watchpoint expression is too long\n");
    return 0;
  }
  WP *wp = new_wp();
  if (wp == nullptr) {
    return 0;
  }
  std::strcpy(wp->expr, args);
  bool success = true;
  wp->tar_val = expr(wp->expr, &success);
  if (!success) {
    free_wp(wp);
    std::printf("failed to set watchpoint\n");
    return 0;
  }
  std::printf("watchpoint %d set: %s = 0x%08x\n", wp->NO, wp->expr,
              wp->tar_val);
  return 0;
}

static int cmd_d(char *args) {
  if (args == nullptr) {
    std::printf("usage: d N\n");
    return 0;
  }
  char *end = nullptr;
  unsigned long number = std::strtoul(args, &end, 10);
  if (*args == '\0' || *end != '\0' || number >= 32) {
    std::printf("watchpoint number must be between 0 and 31\n");
    return 0;
  }
  bool empty = false;
  WP *wp = find_wp(number, &empty);
  if (empty) {
    std::printf("No watchpoints in use.\n");
  } else if (wp == nullptr) {
    std::printf("No such watchpoint: %lu\n", number);
  } else {
    free_wp(wp);
    std::printf("watchpoint %lu deleted\n", number);
  }
  return 0;
}

void init_sdb() {
  init_regex();
  init_wp_pool();
}

void sdb_mainloop() {
  init_sdb();
  for (char *str; (str = rl_gets()) != nullptr;) {
    char *str_end = str + std::strlen(str);
    char *cmd = std::strtok(str, " \t");
    if (cmd == nullptr) {
      continue;
    }
    char *args = cmd + std::strlen(cmd) + 1;
    if (args >= str_end) {
      args = nullptr;
    }

    int i;
    for (i = 0; i < NR_CMD; i++) {
      if (std::strcmp(cmd, cmd_table[i].name) == 0) {
        if (cmd_table[i].handler(args) < 0) {
          return;
        }
        break;
      }
    }
    if (i == NR_CMD) {
      std::printf("Unknown command '%s'\n", cmd);
    }
  }
}
