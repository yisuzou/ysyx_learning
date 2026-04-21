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

#include <common.h>
#include <ctype.h>
#include <errno.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

void init_monitor(int, char *[]);
void am_init_monitor();
void engine_start();
int is_exit_status_bad();
word_t expr(char *e, bool *success);
int run_expr_test(const char *path);

int main(int argc, char *argv[]) {
  /* Initialize the monitor. */

#ifdef CONFIG_TARGET_AM
  am_init_monitor();
#else
  init_monitor(argc, argv);
#endif

#ifdef CONFIG_EXPR_TEST
  char *path = "/home/zys/ysyx-workbench/nemu/tools/gen-expr/build/input";
  run_expr_test(path);
#endif
  /* Start engine. */
  engine_start();
  return is_exit_status_bad();
}

int run_expr_test(const char *path) {
  FILE *fp = fopen(path, "r");
  if (!fp) {
    perror("open expr input");
    return 1;
  }

  char line[65536 + 64];
  int total = 0, pass = 0; // 初始化总数和通过数

  while (fgets(line, sizeof(line), fp)) { // fgets可以读取1行内容

    char *p = line;
    /* 似乎没有需要需要如此处理得，没有空行和注释
    while (isspace((unsigned char)*p)) p++;
    if (*p == '\0' || *p == '#') continue;
     */
    errno = 0;
    // 读取第一个数字，strtoull会在遇到第一个非数字字符的时候停止，end指向空格
    char *end = NULL;
    unsigned long long expected = strtoull(p, &end, 10);
    if (errno != 0 || end == p)
      continue;

    p = end;
    while (isspace((unsigned char)*p))
      p++; // 如果当前指向的是空格，p+1
    if (*p == '\0')
      continue;
    // 现在P指向表达式的起始位置了，首先找到表达式的结尾，也就是换行符，替换为终止符；
    char *nl = strchr(p, '\n');
    if (nl)
      *nl = '\0';

    bool ok = true;
    word_t got = expr(p, &ok);
    total++;

    if (ok && got == (word_t)expected) {
      pass++;
    } else {
      printf("Mismatch: expect=%llu, got=" FMT_WORD ", expr=%s\n", expected,
             got, p);
    }
  }

  fclose(fp);
  printf("expr test: %d/%d passed\n", pass, total);
  return (pass == total) ? 0 : 1; // 全部通过返回0，否则返回1
}
