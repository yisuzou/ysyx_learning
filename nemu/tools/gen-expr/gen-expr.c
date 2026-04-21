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

// #include "common.h"
#include <assert.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <wait.h>
// this should be enough
static size_t pos =
    0; // 创建一个变量用来记录当前写入的位置，防止递归深度太深溢出
static char buf[65536] = {};
static char code_buf[65536 + 128] = {}; // a little larger than `buf`
static char *code_format = "#include <stdio.h>\n"
                           "int main() { "
                           "  unsigned result = %s; "
                           "  printf(\"%%u\", result); "
                           "  return 0; "
                           "}";

static int choose(int x) { return rand() % x; }

int gen_num(void) {
  int n = rand() % 1000;
  int m = snprintf(buf + pos, sizeof(buf) - pos, "%uu", n);
  if (m < 0) {
    return 1;
  }
  if ((size_t)m >= (sizeof(buf) - pos)) {
    return 1;
  }
  pos += m;
  return 0;
}

int gen(char p) {
  int m = snprintf(buf + pos, sizeof(buf) - pos, "%c", p);
  if (m < 0) {
    return 1;
  }
  if ((size_t)m >= (sizeof(buf) - pos)) {
    return 1;
  }
  pos += m;
  return 0;
}

int gen_rand_op() {
  int x = rand() % 4;
  char op;
  switch (x) {
  case 0:
    op = '+';
    break;
  case 1:
    op = '-';
    break;
  case 2:
    op = '*';
    break;
  default:
    op = '/';
  }
  int m = snprintf(buf + pos, sizeof(buf) - pos, "%c", op);
  if (m < 0) {
    return 1;
  }
  if ((size_t)m >= (sizeof(buf) - pos)) {
    return 1;
  }
  pos += m;
  return 0;
}

int gen_space() {
  int n = rand() % 2;
  switch (n) {
  case 0:
    gen(' ');
    break;
  default:
    break;
  }
  return 0;
}
// 该函数递归调用，只有掉进gennum才会结束；
static void gen_rand_expr(
    int depth) { // 第一，要约束除0行为；第二，要防止递归深度过深，导致长度溢出；
  // buf[0] = '\0';
  if (depth > 8 ||
      (sizeof(buf) - pos) <
          64) { // 画二叉树可以知道，递归深度为8时最多要为10个表达式赋数字，n+2,最多的余量是3*（n+2）（0-999）；
    gen_num();
    return;
  }
  switch (choose(4)) {
  case 0:
    gen_num();
    gen_space();
    break; // 单次生成数值不妨定义在0-999
  case 1:
    gen('(');
    gen_space();
    gen_rand_expr(depth + 1);
    gen_space();
    gen(')');
    break;
  // case 2: gen(' ');//gen space
  default:
    gen_rand_expr(depth + 1);
    gen_space();
    gen_rand_op();
    gen_space();
    gen_rand_expr(depth + 1);
    break;
  }
}

int main(int argc, char *argv[]) {
  int seed = time(0);
  srand(seed);
  int loop = 1;
  if (argc > 1) {
    sscanf(argv[1], "%d", &loop);
  }
  // 这里传入的参数主要用来设定循环次数, 1次循环就代表一次表达式生成和求值；
  int i;
  for (i = 0; i < loop; i++) {
    while (1) {
      pos = 0;
      buf[0] = '\0';
      gen_rand_expr(0);

      sprintf(code_buf, code_format, buf);
      // sprintf意思是输出到字符串缓冲区而不是屏幕，第一个是目标缓存区，第二个参数是编码格式，第三个内容；
      // 所以这里是将buf中的内容填充到上面的代码模板当中，codebuf为什么要比buf大一点呢？

      FILE *fp = fopen("/tmp/.code.c", "w");
      assert(fp != NULL);
      fputs(code_buf, fp);
      fclose(fp);
      // 创建并写入该文件
      int ret =
          system("gcc -O2 -Werror=div-by-zero /tmp/.code.c -o /tmp/.expr");
      // gcc -O2 -Werror=div-by-zero
      if (ret != 0)
        continue;
      // 调用系统命令编译该文件，将生成的表达式求值
      fp = popen("/tmp/.expr", "r");
      assert(fp != NULL);
      // popen，管道通信，运行编译结果，读取内容通过管道发送
      //
      int result;
      ret = fscanf(fp, "%u", &result);
      // 过滤除0行为的一个方法，如果返回是失败的，那么将重新生成一个表达式，重复上面的步骤；

      int exstatus = pclose(fp);
      // 读取运算结果，存入result；
      // 关闭一定要记得使用pclose；
      if (exstatus == -1) {
        continue;
      }

      if (WIFEXITED(exstatus)) {
        if (WEXITSTATUS(exstatus) == 0) {
          printf("%u %s\n", result, buf);
          break;
        } else {
          continue;
        }
      } else if (WIFSIGNALED(exstatus)) {
        continue;
      }
    }
  }
  return 0;
}
