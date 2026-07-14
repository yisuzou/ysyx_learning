#include "sdb.h"

#include <regex.h>

#include <cstdio>
#include <cstring>

enum {
  TK_NOTYPE = 256,
  TK_EQ,
  TK_NEQ,
  TK_AND,
  TK_NUM,
  TK_HEX,
  TK_REG,
  TK_REGNAME,
  TK_PTR,
  TK_NEG,
};

struct Rule {
  const char *regex;
  int type;
};

static Rule rules[] = {
    {" +", TK_NOTYPE},
    {"==", TK_EQ},
    {"!=", TK_NEQ},
    {"&&", TK_AND},
    {"\\+", '+'},
    {"\\-", '-'},
    {"\\*", '*'},
    {"/", '/'},
    {"0[xX][0-9a-fA-F]+", TK_HEX},
    {"[0-9]+", TK_NUM},
    {"\\(", '('},
    {"\\)", ')'},
    {"\\$(ra|sp|gp|tp|t[0-6]|a[0-7]|s([0-9]|1[01])|pc)", TK_REGNAME},
    {"\\$[0-9]+", TK_REGNAME},
    {"(ra|sp|gp|tp|t[0-6]|a[0-7]|s([0-9]|1[01])|pc)", TK_REGNAME},
    {"\\$", TK_REG},
};

static constexpr int MAX_TK = 512;
static constexpr int NR_REGEX = sizeof(rules) / sizeof(rules[0]);
static regex_t regexes[NR_REGEX] = {};

struct Token {
  int type;
  char str[32];
};

static Token tokens[MAX_TK] = {};
static int nr_token = 0;

void init_regex() {
  char error_msg[128];
  for (int i = 0; i < NR_REGEX; i++) {
    int ret = regcomp(&regexes[i], rules[i].regex, REG_EXTENDED);
    if (ret != 0) {
      regerror(ret, &regexes[i], error_msg, sizeof(error_msg));
      std::fprintf(stderr, "regex compilation failed: %s (%s)\n", error_msg,
                   rules[i].regex);
    }
  }
}

static bool make_token(const char *input) {
  nr_token = 0;
  int position = 0;
  while (input[position] != '\0') {
    bool matched = false;
    for (int i = 0; i < NR_REGEX; i++) {
      regmatch_t match;
      if (regexec(&regexes[i], input + position, 1, &match, 0) != 0 ||
          match.rm_so != 0) {
        continue;
      }

      matched = true;
      int length = match.rm_eo;
      position += length;
      if (rules[i].type == TK_NOTYPE) {
        break;
      }
      if (nr_token >= MAX_TK) {
        std::printf("too many tokens (maximum %d)\n", MAX_TK);
        return false;
      }

      tokens[nr_token].type = rules[i].type;
      if (rules[i].type == TK_NUM || rules[i].type == TK_HEX ||
          rules[i].type == TK_REGNAME) {
        if (length >= static_cast<int>(sizeof(tokens[nr_token].str))) {
          std::printf("token is too long\n");
          return false;
        }
        std::memcpy(tokens[nr_token].str, input + position - length, length);
        tokens[nr_token].str[length] = '\0';
      }
      nr_token++;
      break;
    }
    if (!matched) {
      std::printf("no match at position %d in expression: %s\n", position,
                  input);
      return false;
    }
  }
  return nr_token > 0;
}

static bool is_unary_context(int index) {
  if (index == 0) {
    return true;
  }
  int previous = tokens[index - 1].type;
  return previous == '(' || previous == '+' || previous == '-' ||
         previous == '*' || previous == '/' || previous == TK_EQ ||
         previous == TK_NEQ || previous == TK_AND;
}

static bool register_value(const char *name, word_t *value) {
  static const char *names[] = {
      "$0", "ra", "sp", "gp", "tp", "t0", "t1", "t2", "s0", "s1", "a0",
      "a1", "a2", "a3", "a4", "a5", "a6", "a7", "s2", "s3", "s4", "s5",
      "s6", "s7", "s8", "s9", "s10", "s11", "t3", "t4", "t5", "t6"};
  const char *normalized = name;
  if (name[0] == '$' && name[1] != '\0' && name[1] != '0') {
    normalized = name + 1;
  }
  if (!std::strcmp(normalized, "pc")) {
    *value = npc_get_pc();
    return true;
  }
  for (int i = 0; i < 32; i++) {
    if (!std::strcmp(normalized, names[i])) {
      *value = npc_reg_read(i);
      return true;
    }
  }
  return false;
}

static bool surrounded_by_parentheses(int left, int right) {
  if (tokens[left].type != '(' || tokens[right].type != ')') {
    return false;
  }
  int depth = 0;
  for (int i = left; i <= right; i++) {
    if (tokens[i].type == '(') {
      depth++;
    } else if (tokens[i].type == ')') {
      depth--;
    }
    if (depth == 0 && i != right) {
      return false;
    }
    if (depth < 0) {
      return false;
    }
  }
  return depth == 0;
}

static int precedence(int type) {
  if (type == TK_AND) {
    return 1;
  }
  if (type == TK_EQ || type == TK_NEQ) {
    return 2;
  }
  if (type == '+' || type == '-') {
    return 3;
  }
  if (type == '*' || type == '/') {
    return 4;
  }
  return 100;
}

static word_t eval(int left, int right, bool *success) {
  if (left > right) {
    *success = false;
    return 0;
  }
  if (surrounded_by_parentheses(left, right)) {
    return eval(left + 1, right - 1, success);
  }
  if (left == right) {
    word_t value = 0;
    if (tokens[left].type == TK_NUM) {
      if (std::sscanf(tokens[left].str, "%u", &value) != 1) {
        *success = false;
      }
      return value;
    }
    if (tokens[left].type == TK_HEX) {
      if (std::sscanf(tokens[left].str, "%x", &value) != 1) {
        *success = false;
      }
      return value;
    }
    if (tokens[left].type == TK_REGNAME &&
        register_value(tokens[left].str, &value)) {
      return value;
    }
    *success = false;
    std::printf("expected a number or register, got '%s'\n",
                tokens[left].str);
    return 0;
  }
  if (tokens[left].type == TK_PTR || tokens[left].type == TK_NEG) {
    word_t address = eval(left + 1, right, success);
    if (!*success) {
      return 0;
    }
    if (tokens[left].type == TK_NEG) {
      return 0 - address;
    }
    word_t value = 0;
    if (!npc_mem_read(address, &value)) {
      *success = false;
      return 0;
    }
    return value;
  }
  if (tokens[left].type == TK_REG) {
    word_t value = 0;
    if (left + 1 != right || tokens[left + 1].type != TK_REGNAME ||
        !register_value(tokens[left + 1].str, &value)) {
      *success = false;
      std::printf("invalid register expression\n");
      return 0;
    }
    return value;
  }

  int depth = 0;
  int operator_index = -1;
  int operator_precedence = 100;
  for (int i = left; i <= right; i++) {
    if (tokens[i].type == '(') {
      depth++;
    } else if (tokens[i].type == ')') {
      depth--;
    } else if (depth == 0) {
      int current_precedence = precedence(tokens[i].type);
      if (current_precedence < operator_precedence) {
        operator_precedence = current_precedence;
        operator_index = i;
      } else if (current_precedence == operator_precedence &&
                 current_precedence < 100) {
        operator_index = i;
      }
    }
  }
  if (operator_index < 0) {
    *success = false;
    std::printf("no valid operator found\n");
    return 0;
  }

  word_t value1 = eval(left, operator_index - 1, success);
  word_t value2 = eval(operator_index + 1, right, success);
  if (!*success) {
    return 0;
  }
  switch (tokens[operator_index].type) {
  case '+':
    return value1 + value2;
  case '-':
    return value1 - value2;
  case '*':
    return value1 * value2;
  case '/':
    if (value2 == 0) {
      std::printf("division by zero\n");
      *success = false;
      return 0;
    }
    return value1 / value2;
  case TK_EQ:
    return value1 == value2;
  case TK_NEQ:
    return value1 != value2;
  case TK_AND:
    return value1 && value2;
  default:
    *success = false;
    return 0;
  }
}

word_t expr(char *input, bool *success) {
  *success = input != nullptr && make_token(input);
  if (!*success) {
    return 0;
  }
  for (int i = 0; i < nr_token; i++) {
    if (tokens[i].type == '*' && is_unary_context(i)) {
      tokens[i].type = TK_PTR;
    } else if (tokens[i].type == '-' && is_unary_context(i)) {
      tokens[i].type = TK_NEG;
    }
  }
  return eval(0, nr_token - 1, success);
}
