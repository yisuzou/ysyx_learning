#ifndef __FTRACE_H__
#define __FTRACE_H__

#include <common.h>

// Parse the ELF file's symbol table and build the function symbol table.
// Safe to call with elf_file == NULL (ftrace stays disabled in that case).
void init_ftrace(const char *elf_file);

// Look up the function that contains address `pc`.
// Returns the function name, or NULL if no matching function symbol is found.
const char *ftrace_find_func(paddr_t pc);

#endif
