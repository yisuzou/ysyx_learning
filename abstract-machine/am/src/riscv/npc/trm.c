#include <am.h>
#include <klib-macros.h>

extern char _heap_start;
int main(const char *args);

extern char _pmem_start;
#define PMEM_SIZE (128 * 1024 * 1024)
#define PMEM_END ((uintptr_t)&_pmem_start + PMEM_SIZE)

Area heap = RANGE(&_heap_start, PMEM_END);
static const char mainargs[MAINARGS_MAX_LEN] =
    TOSTRING(MAINARGS_PLACEHOLDER); // defined in CFLAGS

void putch(char ch) {}

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
  int ret = main(mainargs);
  halt(ret);
}
