#include "ftrace.h"
#include <debug.h>
#include <elf.h>
#include <stdio.h>
#include <stdlib.h>

typedef struct {
  char name[64];
  paddr_t addr;
  paddr_t size;
} FuncSym;

#define MAX_FUNC_SYM 1024

static FuncSym func_table[MAX_FUNC_SYM];
static int nr_func = 0;

// Read `nmemb` records of `size` bytes from `fp` into `ptr`, aborting on
// short reads. This keeps every fread() call's return value checked, which
// is required to build cleanly under -Wall -Werror.
static void checked_fread(void *ptr, size_t size, size_t nmemb, FILE *fp) {
  size_t ret = fread(ptr, size, nmemb, fp);
  Assert(ret == nmemb, "fread() expected %zu records, got %zu", nmemb, ret);
}

static void parse_elf(const char *elf_file) {
  FILE *fp = fopen(elf_file, "rb");
  Assert(fp, "Can not open '%s'", elf_file);

  Elf32_Ehdr ehdr;
  checked_fread(&ehdr, sizeof(ehdr), 1, fp);

  int nr_shdr = ehdr.e_shnum;
  Elf32_Shdr *shdr = malloc(nr_shdr * sizeof(Elf32_Shdr));
  Elf32_Sym *symtab = NULL;
  char *strtab = NULL;
  int num_symbols = 0;
  int strtab_index = -1;

  for (int i = 0; i < nr_shdr; i++) {
    fseek(fp, ehdr.e_shoff + i * sizeof(Elf32_Shdr), SEEK_SET);
    checked_fread(&shdr[i], sizeof(Elf32_Shdr), 1, fp);

    if (shdr[i].sh_type == SHT_SYMTAB) {
      num_symbols = shdr[i].sh_size / shdr[i].sh_entsize;
      symtab = malloc(shdr[i].sh_size);
      fseek(fp, shdr[i].sh_offset, SEEK_SET);
      checked_fread(symtab, shdr[i].sh_size, 1, fp);
      strtab_index = shdr[i].sh_link;
    }
  }

  Assert(strtab_index >= 0 && strtab_index < nr_shdr,
         "No symbol table found in '%s'", elf_file);

  strtab = malloc(shdr[strtab_index].sh_size);
  fseek(fp, shdr[strtab_index].sh_offset, SEEK_SET);
  checked_fread(strtab, shdr[strtab_index].sh_size, 1, fp);

  for (int j = 0; j < num_symbols; j++) {
    if (ELF32_ST_TYPE(symtab[j].st_info) == STT_FUNC) {
      Assert(nr_func < MAX_FUNC_SYM, "Too many function symbols (> %d)",
             MAX_FUNC_SYM);
      FuncSym *f = &func_table[nr_func++];
      snprintf(f->name, sizeof(f->name), "%s", &strtab[symtab[j].st_name]);
      f->addr = symtab[j].st_value;
      f->size = symtab[j].st_size;
    }
  }

  free(shdr);
  free(symtab);
  free(strtab);
  fclose(fp);
}

void init_ftrace(const char *elf_file) {
  if (elf_file == NULL) {
    Log("No elf file is given for ftrace. Function tracing is disabled.");
    return;
  }
  parse_elf(elf_file);
  Log("ftrace: loaded %d function symbols from '%s'", nr_func, elf_file);
}

const char *ftrace_find_func(paddr_t pc) {
  for (int i = 0; i < nr_func; i++) {
    if (pc >= func_table[i].addr &&
        pc < func_table[i].addr + func_table[i].size) {
      return func_table[i].name;
    }
  }
  return NULL;
}
