/***************************************************************************************
 * Copyright (c) 2014-2024 Zihao Yu, Nanjing University
 *
 * NEMU is licensed under Mulan PSL v2.
 * You can use this software according to the terms and conditions of the Mulan
 * PSL v2. You may obtain a copy of Mulan PSL v2 at:
 *          http://license.coscl.org.cn/MulanPSL2
 *
 * THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY
 * KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO
 * NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
 *
 * See the Mulan PSL v2 for more details.
 ***************************************************************************************/

#include "common.h"
#include <assert.h>
#include <isa.h>

#include <memory/vaddr.h>
/* We use the POSIX regex functions to process regular expressions.
 * Type 'man regex' for more information about POSIX regex functions.
 */
#include <readline/readline.h>
#include <regex.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define MAX_TK 512

enum {
  TK_NOTYPE = 256,
  TK_EQ,
  TK_NUM,

  /* TODO: Add more token types */
  TK_HEX,
  TK_REG,
  TK_NEQ,
  TK_AND,
  TK_REGNAME,
  TK_PTR,
  // TK_PC
};

static struct rule {
  const char *regex;
  int token_type;
} rules[] = {

    /* TODO: Add more rules.
     * Pay attention to the precedence level of different rules.
     */

    {" +", TK_NOTYPE}, // spaces
    {"\\+", '+'},      // plus,需要双\，第一次在正则中转义，第二次为反斜杠转义
    {"==", TK_EQ},     // equal
    {"\\-", '-'},      // minus
    {"\\*", '*'},      // multi
    {"/", '/'},        // div
    {"0x[0-9A-Fa-f]+", TK_HEX}, // int base16
    {"[0-9]+u?", TK_NUM},       // int base10
    {"\\(", '('}, //(,),本身在正则表达式中就有组合的含义，所以也需要转义来识别
    {"\\)", ')'},
    // 新增十六进制数输入，寄存器访问，等于，不等于，逻辑与，解引用
    {"((\\$0)|ra|sp|gp|tp|t[0-6]|a[0-7]|s([0-9]|1[01])|pc)", TK_REGNAME},
    //    {"(\\$0)", TK_REGNAME}, // 寄存器名匹配
    //    {"pc", TK_PC},
    {"\\$", TK_REG}, // 当作单目运算符
    {"!=", TK_NEQ},
    {"&&", TK_AND}};

#define NR_REGEX ARRLEN(rules) // 正则规则的数量；

static regex_t re[NR_REGEX] = {}; // 创建一个表达式寄存器/缓存；

/* Rules are used for many times.
 * Therefore we compile them only once before any usage.
 */
void init_regex() {
  int i;
  char error_msg[128];
  int ret;

  for (i = 0; i < NR_REGEX; i++) {
    ret = regcomp(&re[i], rules[i].regex, REG_EXTENDED);
    if (ret != 0) {
      regerror(ret, &re[i], error_msg, 128);
      panic("regex compilation failed: %s\n%s", error_msg, rules[i].regex);
    }
  }
}

typedef struct token {
  int type;
  char str[32];
} Token;

static Token tokens[MAX_TK] __attribute__((used)) = {};
static int nr_token __attribute__((used)) = 0;
word_t eval(int p, int q, bool *success);

static bool make_token(char *e) {
  int position = 0;
  int i;
  regmatch_t
      pmatch; // 定义匹配位置，是一个结构体，包含了字符串开始位置和字串的开始结尾
  nr_token = 0; // 进入函数要清0
  while (e[position] != '\0') {
    /* Try all rules one by one. */
    for (i = 0; i < NR_REGEX; i++) {
      if (regexec(&re[i], e + position, 1, &pmatch, 0) == 0 &&
          pmatch.rm_so == 0) {
        char *substr_start = e + position;
        int substr_len = pmatch.rm_eo;

        // Log("match rules[%d] = \"%s\" at position %d with len %d: %.*s", i,
        //     rules[i].regex, position, substr_len, substr_len, substr_start);

        position += substr_len;

        /* TODO: Now a new token is recognized with rules[i]. Add codes
         * to record the token in the array `tokens'. For certain types
         * of tokens, some extra actions should be performed.
         */

        switch (rules[i].token_type) {
        case TK_NOTYPE:
          break;
        case TK_HEX:
        case TK_REGNAME:
        case TK_NUM:
          tokens[nr_token].type = rules[i].token_type;
          if (substr_len <= 31) {
            for (int s = 0; s < substr_len; s++) {
              tokens[nr_token].str[s] = substr_start[s];
            } // 30是写入的最后一位
            tokens[nr_token].str[substr_len] = '\0'; // 补充字符串结尾符号
          } else {
            printf("The number is too big to store. \n");
            return false;
          }
          nr_token = nr_token + 1;
          break;
        case '+':
          tokens[nr_token].type = rules[i].token_type;
          nr_token = nr_token + 1;
          break;
        case '-':
          tokens[nr_token].type = rules[i].token_type;
          nr_token = nr_token + 1;
          break;
        case '*':
          tokens[nr_token].type = rules[i].token_type;
          nr_token = nr_token + 1;
          break;
        case '/':
          tokens[nr_token].type = rules[i].token_type;
          nr_token = nr_token + 1;
          break;
        case '(':
          tokens[nr_token].type = rules[i].token_type;
          nr_token = nr_token + 1;
          break;
        case ')':
          tokens[nr_token].type = rules[i].token_type;
          nr_token = nr_token + 1;
          break;
        case TK_AND:
        case TK_NEQ:
        case TK_REG:
        case TK_EQ:
          tokens[nr_token].type = rules[i].token_type;
          nr_token = nr_token + 1;
          break;
        default:
          // TODO();
          printf("unsupported token!\n");
          return false;
        }
        break;
      }
    }
    if (nr_token >= MAX_TK) {
      printf("too much tokens!more than %d!\n", MAX_TK);
      return false;
    }
    if (i == NR_REGEX) {
      printf("no match at position %d\n%s\n%*.s^\n", position, e, position, "");
      return false;
    }
    /*
    if (tokens[0] == '+' || tokens[0] == '-') {
      printf("bad expression! can't start a expression with +- / * !");
    }
    */
  }
  // printf("There are %d tokens.\n", nr_token);
  return true;
}

word_t expr(char *e, bool *success) {
  if (!make_token(e)) {
    *success = false;
    return 0;
  }
  // make_token如果失败了则返回false；不会结束程序。
  /* TODO: Insert codes to evaluate the expression. */
  // TODO();
  for (int i = 0; i < nr_token; i++) {
    if (tokens[i].type == '*' &&
        (i == 0 || tokens[i - 1].type == '+' || tokens[i - 1].type == '-' ||
         tokens[i - 1].type == '*' ||
         tokens[i - 1].type ==
             '/')) { // 其实不太严谨，理论上存在要连续解引用的行为比如*x，x里也是一个地址？**x
      tokens[i].type = TK_PTR;
    }
  }
  word_t result = eval(0, nr_token - 1, success);
  // printf("%d \n", result);
  return result;
}

bool check_parentheses(int p, int q, bool *success);

word_t eval(int p, int q, bool *success) {
  // tokbuff nonumexpr[] = {};
  // printf("nr_token is %d \n", nr_token);
  /*改用int后，会自动识别向下越界，此段代码失效
  if (p > 31 || q > 31) {
    printf("bad expression!p,q too large!please check if the expression start "
           "with + - * / !\n");
    *success = false;
    return 0;
  }
  */
  word_t op =
      -1; // 选取一个远大于token数的数字用来防御，如果没找到主运算符应该指示；
  if (p > q) {
    printf("bad expression! happened in function eval, p>q!\n");
    *success = false;
    return 0;
  } else if (p == q) {
    /* Single token.
     * For now this token should be a number.
     * Return the value of the number.
     */
    word_t a;
    if (tokens[p].type == TK_HEX) {
      sscanf(tokens[p].str, "%x", &a);
      return a;
    } else if (tokens[p].type == TK_NUM) {
      sscanf(tokens[p].str, "%d", &a);
      return a;
    } else {
      *success = false;
      printf("It seems that not a NUM/HEX type.\n");
      return 0;
    }
    // printf("number is : %d \n", a);
  } else if (check_parentheses(p, q, success) == true) {
    /* The expression is surrounded by a matched pair of parentheses.
     * If that is the case, just throw away the parentheses.
     */
    // printf("() processing! \n");
    return eval(p + 1, q - 1, success);
  } else if (p + 1 == q) {
    // 处理单目运算符号
    if (tokens[p].type == TK_PTR) {
      int vaddr = eval(p + 1, q, success);
      if (vaddr < 0x80000000 || vaddr > 0x87ffffff) {
        printf("this address may out of bound. retry.\n");
        *success = false;
        return 0;
      } else {
        return vaddr_read(vaddr, 4);
      }
    }
    if (tokens[p].type == TK_REG) {
      if (tokens[p + 1].type != TK_REGNAME) {
        printf("Bad expression! $[REGNAME] to get the content in regs!\n");
        *success = false;
        return 0;
      } else {
        // printf("reg name %s\n", tokens[p + 1].str);
        if (!strcmp("pc", tokens[p + 1].str)) {
          return cpu.pc;
        } else {
          return isa_reg_str2val(tokens[p + 1].str, success);
        }
      }
    }
    printf("Something get wrong! Check the unary operator!\n");
    *success = false;
    return 0;
  } else {
    // 这里应该写出optype的判断代码，上面是处理几个特殊情况；
    // 循环检查type，只看+—*/这些
    // int j = 0;
    // printf("come in else block.\n");
    if (*success == false) {
      return 0;
    }
    int validflag = 0;
    int pmflag = 0;
    int eqaflag = 0; // 等式，非等式，逻辑表达式优先级最高
    for (int i = p; i <= q; i++) {
      // 上面这个循环已经提取出了只含符号的token，接下来循环判断，但是这里有数字的情况下其实也可以判断
      // 维护一个op就可以
      if (tokens[i].type == '(') {
        validflag++;
      } else {
        if (tokens[i].type == ')') {
          validflag--;
        }
        // 循环过程中不可以小于0
        if (validflag <
            0) { // validflag<0 means that there are ) who is  bad expression
          printf("bad expression, check '(' and ')'(more)!\n");
          *success = false;
          return 0;
        }
      }
      // all the case validflag eq 0 means out of the ();
      if (validflag == 0) {
        if (tokens[i].type == TK_AND || tokens[i].type == TK_EQ ||
            tokens[i].type == TK_NEQ) {
          op = i;
          eqaflag = 1;
        }
        if (eqaflag == 0) {
          if (tokens[i].type == '+' || tokens[i].type == '-') {
            op = i;
            pmflag = 1;
          }
        }
        if (pmflag == 0) {
          if (tokens[i].type == '*' || tokens[i].type == '/') {
            op = i;
          }
        }
      }
    }
    if (validflag > 0) {
      printf("bad expression!check if '(' is more than ')'!\n");
      *success = false;
      return 0;
    }
    // 这个循环找到了主运算符,并保存在了op中, 没找到的情况下呢？
    // 上面只会处理异常的括号，遇到（合法表达式）（合法表达式）的情况会留下隐患；
    // 所以要检查op是否被找到，初始的op应该是不可访问tokens的一个数，由于
    // tokens只允许0-31访问，所以可以设置一个较大的数；重点在于截断不合法的访问，防止越界；
    // 更新：0-31这个说法确实是睁眼说瞎话，合法的运算符首先要有两个操作数；
    if (op < p || op > q) {
      printf("No op found!\n");
      *success = false;
      return 0;
    } else {
      // printf("op tracer: op is %d \n", op);
    }
    word_t val1 = eval(p, op - 1, success);
    if (*success == false) {
      return 0;
    }
    word_t val2 = eval(op + 1, q, success);
    if (*success == false) {
      return 0;
    }
    // 每次递归调用后都要检查是否false，递归调用的函数return只会返回它所在层的函数，而不是所有函数；
    switch (tokens[op].type) {
    case '+':
      return val1 + val2;
    case '-': /* ... */
      return val1 - val2;
    case '*': /* ... */
      return val1 * val2;
    case '/': /* ... */
      if (val2 == 0) {
        printf("divide 0 error!\n");
        *success = false;
        return 0;
      } else {
        return val1 / val2;
      }
    case TK_AND:
      return val1 && val2;
    case TK_NEQ:
      return val1 != val2;
    case TK_EQ:
      return val1 == val2;
    default:
      printf("No op found!\n");
      *success = false;
      return 0;
    }
  }
}

bool check_parentheses(int p, int q, bool *success) {
  int cpflag =
      0; // 使用cpfalg指示是否配对成功,遇到一个右括号就加1，遇到一个左括号就减1
         // 首先要检查是不是被括号包围的子表达式
  if ((tokens[p].type == '(') && (tokens[q].type == ')')) {

    for (int i = p; i < q + 1; i++) {
      if (tokens[i].type == '(') {
        cpflag = cpflag + 1;
      } else if (tokens[i].type == ')') {
        cpflag = cpflag - 1;
      }
      // 循环记录括号的过程中cpflag=0说明提前完成了配对，不止一对括号
      if (cpflag == 0 && i < q) {
        printf("more than one couples in expression!\n");
        return false;
      }
      // 循环记录括号的过程中cpflag<0说明左括号数量小于右括号，匹配失败；
      if (cpflag < 0) {
        printf("error expression, () no match!\n");
        *success = false;
        return false;
      }
    }
    // 循环结束后说明所有括号都已处理完毕，如果cpflag>0说明左括号多了
    if (cpflag > 0) {
      printf("error expression, () no match! \n");
      *success = false;
      return false;
    } else { // 循环结束后，正常完成所有配对，说明括号是最小配对的；
      if (cpflag == 0) {
        return true;
      }
    }
  }
  return false;
}
