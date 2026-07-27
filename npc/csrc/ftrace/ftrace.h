#ifndef __FTRACE_H__
#define __FTRACE_H__

#include <common.h>

void init_ftrace(const char *elf_file);
const char *ftrace_find_func(paddr_t pc);
void ftrace_trace(vaddr_t pc, vaddr_t next_pc, word_t inst);

#endif
