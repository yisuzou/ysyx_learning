#include <klib-macros.h>
#include <klib.h>
#include <stdint.h>

#if !defined(__ISA_NATIVE__) || defined(__NATIVE_USE_KLIB__)

size_t strlen(const char *s) {
  assert(s != NULL);
  size_t i = 0;
  while (s[i] != '\0') {
    i++;
  }
  return i;
}

char *strcpy(char *dst, const char *src) {
  int i = 0;
  while ((dst[i] = src[i]) != '\0') {
    i++;
  }
  return dst;
}

char *strncpy(char *dst, const char *src, size_t n) {
  size_t i = 0;
  // i从0开始，n从1开始，所以小于可以覆盖0-（n-1），也就是n个元素
  while (i < n && src[i] != '\0') {
    dst[i] = src[i];
    i++;
  }

  while (i < n) {
    dst[i] = '\0';
    i++;
  }
  // i>=n的情况，就会跳出while。
  return dst;
}

char *strcat(char *dst, const char *src) { // 字符串追加
  size_t i = 0, j = 0;
  i = strlen(dst);
  // 先计算目标字符串长度
  // 下一步续写原字符
  while ((dst[i] = src[j]) != '\0') {
    i++;
    j++;
  }
  return dst;
}

int strcmp(const char *s1, const char *s2) {
  while (*s1 && (*s1 == *s2)) {
    s1++;
    s2++;
  }
  // 首先判断s1不是空字符，s1 =
  // s2，逐个比较，直到第一次不相同，或者s1='\0'也就是空；
  return (unsigned char)*s1 - (unsigned char)*s2; // 返回两个终止字符的差；
}

int strncmp(const char *s1, const char *s2, size_t n) {
  size_t i = 0;
  if (n == 0) {
    return 0;
  } else {
    while (*s1 && (*s1 == *s2)) {
      s1++;
      s2++;
      i++;
      if (i >= n) {
        return 0;
      }
    }
    return (unsigned char)*s1 - (unsigned char)*s2;
  }
}

void *memset(void *s, int c, size_t n) {
  size_t i = 0;
  unsigned char *p = (unsigned char *)s;
  while (i < n) {
    p[i] = (unsigned char)c;
    i++;
  }
  return s;
}

void *memmove(void *dst, const void *src, size_t n) {
  // memmove实现的是这样一个功能：
  // 从当前地址将内容移动到另一个地址，如果两个地址之间不干涉，
  // 例如12345678，存储了aa——————；要把aa移动到78
  // 此时正常移动即可；
  // 当干涉时，例如abcd----移动到3开头，就需要从后往前移动，先讲34移动到56，
  // 再将12移到34，如果顺序移动，就会发生覆盖
  unsigned char *d = (unsigned char *)dst;
  const unsigned char *s = (const unsigned char *)src;

  if (d == s || n == 0) {
    return dst;
  }

  if (d < s) {
    for (size_t i = 0; i < n; i++) {
      d[i] = s[i];
    }
  } else {
    for (size_t i = n; i > 0; i--) {
      d[i - 1] = s[i - 1];
    }
  }

  return dst;
}

void *memcpy(void *out, const void *in, size_t n) {
  unsigned char *d = (unsigned char *)out;
  const unsigned char *s = (const unsigned char *)in;

  for (size_t i = 0; i < n; i++) {
    d[i] = s[i];
  }

  return out;
}

int memcmp(const void *s1, const void *s2, size_t n) {
  // void *不允许直接访问下标
  const unsigned char *p1 = (const unsigned char *)s1;
  const unsigned char *p2 = (const unsigned char *)s2;

  for (size_t i = 0; i < n; i++) {
    if (p1[i] != p2[i]) {
      return p1[i] - p2[i];
    }
  }

  return 0;
}

#endif
