#include <am.h>
#include <inttypes.h>
#include <klib.h>
#include <riscv/riscv.h>
#include <stdint.h>

static Context *(*user_handler)(Event, Context *) = NULL;

__attribute__((used)) Context *__am_irq_handle(Context *c) {
  // printf("mcause: %#" PRIxPTR ", mepc: %#" PRIxPTR ", mstatus: %#" PRIxPTR
  //        " \n",
  //        c->mcause, c->mepc, c->mstatus);
  // int j = 0;
  // for (int i = 0; i < 32; i++) {
  //
  //   printf("gpr[%d]: %#" PRIxPTR " ", i, c->gpr[i]);
  //   j++;
  //   if (j % 4 == 0) {
  //     printf("\n");
  //   } else {
  //     printf("\t");
  //   }
  // }
  if (user_handler) {
    Event ev = {0};
    switch (c->mcause) {
    case 0xb:              // 11
      if (c->GPR1 == -1) { // a7 == -1
        ev.event = EVENT_YIELD;
        c->mepc += 4; // skip the ecall instruction
      } else {
        ev.event = EVENT_SYSCALL;
        c->mepc += 4; // skip the ecall instruction
      }
      break;
    default:
      ev.event = EVENT_ERROR;
      break;
    }

    c = user_handler(ev, c);
    assert(c != NULL);
  }

  return c;
}

extern void __am_asm_trap(
    void); // 没错，它在trap.S中定义，trap.S是汇编文件，里面有一个__am_asm_trap函数，
// 它是异常处理的入口点。这个函数会保存上下文，调用C语言的__am_irq_handle函数，然后恢复上下文。

bool cte_init(Context *(*handler)(Event, Context *)) {
  // initialize exception entry
  asm volatile("csrw mtvec, %0"
               :
               : "r"(__am_asm_trap)); // csrw 伪指令，本质上是csrrw

  // register event handler
  user_handler = handler;

  return true;
}

Context *kcontext(Area kstack, void (*entry)(void *), void *arg) {

  Context *c = (Context *)kstack.end - 1; // 空出一个Context的空间
  c->mstatus = 0x1800;                    // MPP = 11, MIE = 0
  c->mepc = (uintptr_t)entry;
  c->gpr[10] = (uintptr_t)arg; // a0 = arg
  return c;
}

void yield() {
#ifdef __riscv_e
  asm volatile("li a5, -1; ecall");
#else
  asm volatile("li a7, -1; ecall");
#endif
}

bool ienabled() { return false; }

void iset(bool enable) {}
