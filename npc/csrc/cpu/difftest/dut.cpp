#include <cpu/cpu.h>
#include <cpu/difftest.h>
#include <dlfcn.h>
#include <isa.h>
#include <memory/paddr.h>
#include <utils.h>

#ifdef CONFIG_DIFFTEST
using RefMemcpy = void (*)(paddr_t, void *, size_t, bool);
using RefRegcpy = void (*)(void *, bool);
using RefExec = void (*)(uint64_t);
using RefInit = void (*)(int);

static RefMemcpy ref_difftest_memcpy = nullptr;
static RefRegcpy ref_difftest_regcpy = nullptr;
static RefExec ref_difftest_exec = nullptr;
static bool skip_ref = false;
static bool enabled = false;

static void *load_symbol(void *handle, const char *name) {
  dlerror();
  void *symbol = dlsym(handle, name);
  const char *error = dlerror();
  if (error != nullptr) {
    std::fprintf(stderr, "cannot load difftest symbol '%s': %s\n", name, error);
    std::exit(EXIT_FAILURE);
  }
  return symbol;
}

bool difftest_enabled() { return enabled; }

void init_difftest(
    const char *ref_so_file, long img_size,
    int port) { // port在这里没有使用，主要是为了和nemu保持接口一致性
  if (ref_so_file == nullptr) {
    return;
  }
  void *handle = dlopen(ref_so_file, RTLD_LAZY);
  if (handle == nullptr) {
    std::fprintf(stderr, "cannot open difftest reference '%s': %s\n",
                 ref_so_file, dlerror());
    std::exit(EXIT_FAILURE);
  }
  // 在打开的动态库中查找符号，并将其转换为函数指针类型
  ref_difftest_memcpy =
      reinterpret_cast<RefMemcpy>(load_symbol(handle, "difftest_memcpy"));
  ref_difftest_regcpy =
      reinterpret_cast<RefRegcpy>(load_symbol(handle, "difftest_regcpy"));
  ref_difftest_exec =
      reinterpret_cast<RefExec>(load_symbol(handle, "difftest_exec"));
  RefInit ref_difftest_init =
      reinterpret_cast<RefInit>(load_symbol(handle, "difftest_init"));

  ref_difftest_init(port);
  ref_difftest_memcpy(RESET_VECTOR, guest_to_host(RESET_VECTOR), img_size,
                      DIFFTEST_TO_REF);
  ref_difftest_regcpy(&cpu, DIFFTEST_TO_REF);
  enabled = true;
  Log("Differential testing is enabled with %s", ref_so_file);
}

void difftest_skip_ref() { skip_ref = true; }

void difftest_step(vaddr_t pc, vaddr_t npc) {
  if (!enabled) {
    return;
  }
  if (skip_ref) { // 如果需要跳过参考模型的执行，则将当前 CPU
                  // 状态复制到参考模型中，并将 skip_ref 标志重置为 false
    ref_difftest_regcpy(&cpu, DIFFTEST_TO_REF);
    skip_ref = false;
    return;
  }

  ref_difftest_exec(1);
  CPUState ref{}; // 和nemu保持一致的CPU状态结构体，gpr和pc
  ref_difftest_regcpy(&ref, DIFFTEST_TO_DUT);
  if (!isa_difftest_checkregs(&ref, pc)) {
    set_npc_state(NPC_ABORT, pc, -1);
    isa_reg_display();
  }
  (void)
      npc; // 和nemu保持接口一致性，实际上这里没有使用npc参数，没有dut需要追上ref的情况
}
#else
bool difftest_enabled() { return false; }

void init_difftest(const char *ref_so_file, long, int) {
  if (ref_so_file != nullptr) {
    std::fprintf(stderr,
                 "difftest reference specified while CONFIG_DIFFTEST is off\n");
    std::exit(EXIT_FAILURE);
  }
}

void difftest_skip_ref() {}

void difftest_step(vaddr_t, vaddr_t) {}
#endif
