#include <am.h>
#include <klib-macros.h>
#include <klib.h>
#include <stdarg.h>

#if !defined(__ISA_NATIVE__) || defined(__NATIVE_USE_KLIB__)

/*
 * printf/vsprintf/sprintf 格式化输出族
 *
 * 架构设计：以 vsprintf 为核心格式化引擎，接收 va_list 参数；
 * printf 和 sprintf 各自处理可变参数后委托给 vsprintf。
 * 这是标准 C 库的经典设计模式（printf → vprintf, sprintf → vsprintf）。
 */

int printf(const char *fmt, ...) {
  char buf[4096]; // 栈上固定缓冲区，klib 面向裸机/嵌入式环境，4096
                  // 字节足够覆盖大多数输出
  va_list args;
  va_start(args, fmt);
  int n = vsprintf(
      buf, fmt, args); // va_list 不可直接传递给 sprintf，必须通过 vsprintf 中转
  va_end(args);
  for (int i = 0; i < n; i++) {
    putch(buf[i]);
  }
  return n;
}

/*
 * format_int: 将 int 转为十进制字符串写入 dst，返回写入字符数
 *
 * 数字提取算法：反复 %10 取最低位存入临时数组，再逆序写出。
 * 原实现用 i*=10 从高位逼近，当 i 超过 INT_MAX 时溢出导致死循环，此法无此风险。
 *
 * INT_MIN 特殊处理：
 * 对 INT_MIN 直接取反 (-(-2147483648)) 是有符号溢出（UB）。
 * 技巧：先 val+1（合法，得 INT_MAX 的相反数），转 unsigned，再加 1，全程无 UB。
 */
static int format_int(char *dst, int val) {
  char *start = dst;
  unsigned int uval;
  if (val < 0) {
    *dst++ = '-';
    uval =
        (unsigned int)(-(val + 1)) + 1; // 避免对 INT_MIN 直接取反导致有符号溢出
  } else {
    uval = (unsigned int)val;
  }
  char num[12]; // 11 位十进制数字 + 余量，足够容纳 UINT_MAX
  int idx = 0;
  do {
    num[idx++] = '0' + uval % 10;
    uval /= 10;
  } while (uval > 0);
  while (idx > 0) { // 逆序写出，高位在前
    *dst++ = num[--idx];
  }
  return dst - start;
}

/* format_str: 将字符串拷贝到 dst，返回写入字符数 */
static int format_str(char *dst, const char *s) {
  char *start = dst;
  while (*s != '\0') {
    *dst++ = *s++;
  }
  return dst - start;
}

/*
 * vsprintf: 核心格式化引擎，接受 va_list
 * 遍历 fmt，遇到 % 根据后续字符（s/d/%）做替换，否则原样拷贝
 */
int vsprintf(char *out, const char *fmt, va_list ap) {
  char *dst = out;
  for (const char *src = fmt; *src != '\0'; src++) {
    if (*src == '%') {
      src++;
      if (*src == 's') {
        dst += format_str(dst, va_arg(ap, char *));
      } else if (*src == 'd') {
        dst += format_int(dst, va_arg(ap, int));
      } else if (*src == 'c') {
        *dst++ = (char)va_arg(ap, int);
      } else if (*src == '%') { // %% → 输出字面量 '%'
        *dst++ = '%';
      }
    } else {
      *dst++ = *src;
    }
  }
  *dst = '\0';
  return dst - out;
}

/* sprintf: 可变参数包装，委托给 vsprintf 完成实际格式化 */
int sprintf(char *out, const char *fmt, ...) {
  va_list args;
  va_start(args, fmt);
  int n = vsprintf(out, fmt, args);
  va_end(args);
  return n;
}

int snprintf(char *out, size_t n, const char *fmt, ...) {
  panic("Not implemented");
}

int vsnprintf(char *out, size_t n, const char *fmt, va_list ap) {
  panic("Not implemented");
}

#endif
