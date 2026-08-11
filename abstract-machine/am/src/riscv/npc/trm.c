#include <am.h>
#include <klib-macros.h>
#include <klib.h>

extern char _heap_start;
int main(const char *args);

extern char _pmem_start;
#define PMEM_SIZE (128 * 1024 * 1024)
#define PMEM_END ((uintptr_t)&_pmem_start + PMEM_SIZE)

Area heap = RANGE(&_heap_start, PMEM_END);
static const char mainargs[MAINARGS_MAX_LEN] =
    TOSTRING(MAINARGS_PLACEHOLDER); // defined in CFLAGS

void putch(char ch) { *(volatile char *)0x10000000 = ch; }

void halt(int code) {
  // code承载了主函数的返回值
  // 需要更改a0寄存器
  // 需要调用一次ebreak
  asm volatile("mv a0, %0; ebreak" : : "r"(code));
  // 检查code和npc运行状态即可判定HIT GOOD/BAD TRAP
  // 关键在于如何将npc运行状态simruning传过来
  while (1)
    ;
}

void _trm_init() {
  uint32_t vendor_id;
  uint32_t arch_id;
  char vendor[5];

  asm volatile("csrr %0, mvendorid" : "=r"(vendor_id));
  asm volatile("csrr %0, marchid" : "=r"(arch_id));
  vendor[0] = (char)(vendor_id >> 24);
  vendor[1] = (char)(vendor_id >> 16);
  vendor[2] = (char)(vendor_id >> 8);
  vendor[3] = (char)vendor_id;
  vendor[4] = '\0';
  printf("Designed by %s-%d!\n", vendor, (int)arch_id);
  int ret = main(mainargs);
  halt(ret);
}
