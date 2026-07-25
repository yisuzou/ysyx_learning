#include "sdb.h"

#include <cstring>

static const char *register_names[] = {
    "$0", "ra", "sp", "gp", "tp", "t0", "t1", "t2", "s0", "s1", "a0",
    "a1", "a2", "a3", "a4", "a5", "a6", "a7", "s2", "s3", "s4", "s5",
    "s6", "s7", "s8", "s9", "s10", "s11", "t3", "t4", "t5", "t6"};

static constexpr int REGISTER_COUNT =
    sizeof(register_names) / sizeof(register_names[0]);

extern "C" const char *npc_reg_name(int index) {
  if (index < 0 || index >= REGISTER_COUNT) {
    return nullptr;
  }
  return register_names[index];
}

extern "C" bool npc_reg_str2val(const char *name, word_t *value) {
  if (name == nullptr || value == nullptr) {
    return false;
  }

  if (std::strcmp(name, "pc") == 0 || std::strcmp(name, "$pc") == 0) {
    *value = npc_get_pc();
    return true;
  }

  const char *normalized = name;
  if (name[0] == '$' && name[1] != '\0' && name[1] != '0') {
    normalized = name + 1;
  }
  for (int i = 0; i < REGISTER_COUNT; i++) {
    if (std::strcmp(normalized, register_names[i]) == 0) {
      *value = npc_reg_read(i);
      return true;
    }
  }
  return false;
}
