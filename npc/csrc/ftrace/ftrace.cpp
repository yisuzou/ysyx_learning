#include "ftrace.h"

#include <algorithm>
#include <climits>
#include <cstdarg>
#include <elf.h>
#include <vector>
#include <utils.h>

struct FuncSym {
  const char *name;
  paddr_t addr;
  paddr_t size;
};

static std::vector<FuncSym> func_table;
static std::vector<char> strtab;
static int call_depth = 0;

[[noreturn]] static void elf_error(const char *format, ...) {
  std::fprintf(stderr, "ftrace: ");
  va_list args;
  va_start(args, format);
  std::vfprintf(stderr, format, args);
  va_end(args);
  std::fputc('\n', stderr);
  std::exit(EXIT_FAILURE);
}

static void read_at(FILE *fp, long file_size, uint64_t offset, void *data,
                    size_t size, const char *elf_file) {
  if (offset > static_cast<uint64_t>(file_size) ||
      size > static_cast<uint64_t>(file_size) - offset ||
      offset > static_cast<uint64_t>(LONG_MAX) ||
      std::fseek(fp, static_cast<long>(offset), SEEK_SET) != 0 ||
      (size > 0 && std::fread(data, size, 1, fp) != 1)) {
    elf_error("cannot read ELF data from '%s'", elf_file);
  }
}

static void parse_elf(const char *elf_file) {
  FILE *fp = std::fopen(elf_file, "rb");
  if (fp == nullptr) {
    elf_error("cannot open '%s'", elf_file);
  }
  if (std::fseek(fp, 0, SEEK_END) != 0) {
    elf_error("cannot seek '%s'", elf_file);
  }
  long file_size = std::ftell(fp);
  if (file_size < static_cast<long>(sizeof(Elf32_Ehdr))) {
    elf_error("'%s' is not a valid ELF32 file", elf_file);
  }

  Elf32_Ehdr ehdr;
  read_at(fp, file_size, 0, &ehdr, sizeof(ehdr), elf_file);
  if (std::memcmp(ehdr.e_ident, ELFMAG, SELFMAG) != 0 ||
      ehdr.e_ident[EI_CLASS] != ELFCLASS32 ||
      ehdr.e_ident[EI_DATA] != ELFDATA2LSB || ehdr.e_machine != EM_RISCV ||
      ehdr.e_shentsize != sizeof(Elf32_Shdr) || ehdr.e_shnum == 0) {
    elf_error("'%s' is not a little-endian RISC-V ELF32 file", elf_file);
  }

  std::vector<Elf32_Shdr> sections(ehdr.e_shnum);
  read_at(fp, file_size, ehdr.e_shoff, sections.data(),
          sections.size() * sizeof(Elf32_Shdr), elf_file);

  const Elf32_Shdr *sym_section = nullptr;
  for (const Elf32_Shdr &section : sections) {
    if (section.sh_type == SHT_SYMTAB) {
      sym_section = &section;
      break;
    }
  }
  if (sym_section == nullptr || sym_section->sh_entsize != sizeof(Elf32_Sym) ||
      sym_section->sh_link >= sections.size()) {
    elf_error("no valid symbol table in '%s'", elf_file);
  }

  const Elf32_Shdr &str_section = sections[sym_section->sh_link];
  if (str_section.sh_type != SHT_STRTAB) {
    elf_error("invalid symbol string table in '%s'", elf_file);
  }
  strtab.resize(str_section.sh_size);
  read_at(fp, file_size, str_section.sh_offset, strtab.data(), strtab.size(),
          elf_file);

  std::vector<Elf32_Sym> symbols(sym_section->sh_size /
                                 sizeof(Elf32_Sym));
  read_at(fp, file_size, sym_section->sh_offset, symbols.data(),
          symbols.size() * sizeof(Elf32_Sym), elf_file);
  std::fclose(fp);

  for (const Elf32_Sym &symbol : symbols) {
    if (ELF32_ST_TYPE(symbol.st_info) != STT_FUNC ||
        symbol.st_shndx == SHN_UNDEF || symbol.st_name >= strtab.size()) {
      continue;
    }
    const char *name = strtab.data() + symbol.st_name;
    if (*name == '\0' ||
        std::memchr(name, '\0', strtab.size() - symbol.st_name) == nullptr) {
      continue;
    }
    func_table.push_back({name, symbol.st_value, symbol.st_size});
  }
  std::sort(func_table.begin(), func_table.end(),
            [](const FuncSym &lhs, const FuncSym &rhs) {
              return lhs.addr < rhs.addr;
            });
}

void init_ftrace(const char *elf_file) {
  func_table.clear();
  strtab.clear();
  call_depth = 0;
  if (elf_file == NULL) {
    Log("No elf file is given for ftrace. Function tracing is disabled.");
    return;
  }
  parse_elf(elf_file);
  Log("ftrace: loaded %zu function symbols from '%s'", func_table.size(),
      elf_file);
}

const char *ftrace_find_func(paddr_t pc) {
  for (size_t i = 0; i < func_table.size(); i++) {
    const FuncSym &func = func_table[i];
    if (pc < func.addr) {
      break;
    }
    uint64_t end = static_cast<uint64_t>(func.addr) + func.size;
    if (func.size == 0) {
      end = static_cast<uint64_t>(func.addr) + 1;
      for (size_t next = i + 1; next < func_table.size(); next++) {
        if (func_table[next].addr > func.addr) {
          end = func_table[next].addr;
          break;
        }
      }
    }
    if (pc < end) {
      return func.name;
    }
  }
  return NULL;
}

void ftrace_trace(vaddr_t pc, vaddr_t next_pc, word_t inst) {
  uint32_t opcode = inst & 0x7f;
  uint32_t rd = (inst >> 7) & 0x1f;
  uint32_t rs1 = (inst >> 15) & 0x1f;
  uint32_t imm = inst >> 20;
  bool is_return =
      opcode == 0x67 && rd == 0 && (rs1 == 1 || rs1 == 5) && imm == 0;

  if (is_return) {
    const char *name = ftrace_find_func(pc);
    if (name == nullptr) {
      return;
    }
    if (call_depth > 0) {
      call_depth--;
    }
    std::printf(FMT_WORD ": %*sret  [%s]\n", pc, call_depth * 2, "", name);
    return;
  }

  bool is_call = (opcode == 0x6f || opcode == 0x67) && (rd == 1 || rd == 5);
  if (is_call) {
    const char *name = ftrace_find_func(next_pc);
    if (name != nullptr) {
      std::printf(FMT_WORD ": %*scall [%s@" FMT_WORD "]\n", pc,
                  call_depth * 2, "", name, next_pc);
      call_depth++;
    }
  }
}
