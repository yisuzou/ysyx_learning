// Default case validates RTL UART output and commit-gated CSR/ecall/mret.
// RTC is unmapped until CLINT is added (case 4 expects DECERR).
// Fault cases must abort in the host before retiring the failing instruction.
#ifndef FAULT_CASE
#define FAULT_CASE 0
#endif
  .section .text
  .globl _start
  .option norvc
  .option norelax
_start:
#if FAULT_CASE == 1
  li t0, 0x40000000
  lw a1, 0(t0)
#elif FAULT_CASE == 2
  li t0, 0x40000000
  sw zero, 0(t0)
#elif FAULT_CASE == 3
  li t0, 0x10000003
  sw zero, 0(t0)
#elif FAULT_CASE == 4
  li t0, 0x10000048
  sw zero, 0(t0)
#elif FAULT_CASE == 5
  li t0, 0x40000000
  jr t0
#elif FAULT_CASE == 6
  li t0, 0x87ffffff
  sw zero, 0(t0)
#elif FAULT_CASE == 7
  li t0, 0x10000000
  lw a1, 0(t0)
#elif FAULT_CASE == 8
  li t0, 0x10000048
  jr t0
#elif FAULT_CASE == 9
  li t0, 0x10000001
  sb zero, 0(t0)
#elif FAULT_CASE == 10
  li t0, 0x10000000
  sh zero, 0(t0)
#elif FAULT_CASE == 11
  li t0, 0x10000048
  lw a1, 0(t0)
#else
  la t0, trap_handler
  csrw mtvec, t0
ecall_insn:
  ecall
  li t0, 0x10000000
  li t1, 'A'
  sb t1, 0(t0)
  li t1, 'X'
  sb t1, 0(t0)
  li t1, 'I'
  sb t1, 0(t0)
  li t1, 10
  sb t1, 0(t0)
#endif
success:
  li a0, 0
  ebreak
fail:
  li a0, 1
  ebreak
#if FAULT_CASE == 0
trap_handler:
  csrr t1, mcause
  li t2, 11
  bne t1, t2, fail
  csrr t1, mepc
  la t2, ecall_insn
  bne t1, t2, fail
  addi t1, t1, 4
  csrw mepc, t1
  mret
#endif
