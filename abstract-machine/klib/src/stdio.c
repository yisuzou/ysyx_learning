#include <am.h>
#include <klib-macros.h>
#include <klib.h>
#include <stdarg.h>

#if !defined(__ISA_NATIVE__) || defined(__NATIVE_USE_KLIB__)

int printf(const char *fmt, ...) { panic("Not implemented"); }

int vsprintf(char *out, const char *fmt, va_list ap) {
  panic("Not implemented");
}

int sprintf(char *out, const char *fmt, ...) {
  // 本质上就是拼接好格式和变参，然后拷贝到out；
  va_list args;
  va_start(args, fmt);
  // 初始化变参列表
  // 接下来要遍历fmt，找到%，依据后面的内容替换；

  char *dst = out; // 定义目标地址
  const char *src; // 定义源地址
  // 如此定义是为了将字符一个个的从fmt中取出，然后一个个的写入，遇到占位符执行替换
  for (src = fmt; *src != '\0'; src++) {
    if (*src == '%') {
      src++;
      if (*src == 's') {
        char *tmpc = va_arg(args, char *);
        while (*tmpc != '\0') {
          *dst++ = *tmpc++;
        }
      } else if (*src == 'd') {
        int tmpi = va_arg(args, int);
        if (tmpi == 0) {
          *dst++ = '0';
        } else {

          if (tmpi < 0) {
            *dst++ = '-';
            tmpi = -tmpi;
          }

          int i = 1, j = 0;
          char num[12];

          while (i <= tmpi) {
            num[j++] = '0' + tmpi / i % 10;
            i *= 10;
          }

          while (j > 0) {
            *dst++ = num[--j];
          }
        }
      }
    } else {
      *dst = *src;
      dst++;
    }
  }
  *dst = '\0';
  va_end(args);
  return dst - out;
}

int snprintf(char *out, size_t n, const char *fmt, ...) {
  panic("Not implemented");
}

int vsnprintf(char *out, size_t n, const char *fmt, va_list ap) {
  panic("Not implemented");
}

#endif
