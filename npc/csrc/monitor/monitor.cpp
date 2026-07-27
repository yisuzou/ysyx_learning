#include <cpu/difftest.h>
#include <device/device.h>
#include <memory/paddr.h>
#include <sim.h>
#include <utils.h>
#ifdef CONFIG_FTRACE
#include "ftrace.h"
#endif

#include <cerrno>
#include <getopt.h>

void init_sdb();
void sdb_set_batch_mode();
void sdb_mainloop();
#ifdef CONFIG_ITRACE
void init_disasm();
#endif
static const char *log_file = nullptr;
static const char *diff_so_file = nullptr;
static const char *img_file = nullptr;
static const char *elf_file = nullptr;
static int difftest_port = 1234;

static void usage(const char *program) {
  std::printf("Usage: %s [OPTION...] IMAGE\n\n", program);
  std::printf("\t-b,--batch              run with batch mode\n");
  std::printf("\t-l,--log=FILE           output log to FILE\n");
  std::printf("\t-d,--diff=REF_SO        run DiffTest with reference REF_SO\n");
  std::printf("\t-p,--port=PORT          run DiffTest with port PORT\n");
  std::printf("\t-e,--elf=FILE           load function symbols from ELF FILE\n");
  std::printf("\t-h,--help               display this help and exit\n");
}

static void parse_args(int argc, char **argv) {
  const option table[] = {{"batch", no_argument, nullptr, 'b'},
                          {"log", required_argument, nullptr, 'l'},
                          {"diff", required_argument, nullptr, 'd'},
                          {"port", required_argument, nullptr, 'p'},
                          {"elf", required_argument, nullptr, 'e'},
                          {"help", no_argument, nullptr, 'h'},
                          {nullptr, 0, nullptr, 0}};
  int option;
  while ((option = getopt_long(argc, argv, "-bhl:d:p:e:", table, nullptr)) !=
         -1) {
    switch (option) {
    case 'b':
      sdb_set_batch_mode();
      break;
    case 'l':
      log_file = optarg;
      break;
    case 'd':
      diff_so_file = optarg;
      break;
    case 'e':
      elf_file = optarg;
      break;
    case 'p': {
      char *end = nullptr;
      long port = std::strtol(optarg, &end, 10);
      if (*optarg == '\0' || *end != '\0' || port <= 0 || port > 65535) {
        std::fprintf(stderr, "invalid difftest port: %s\n", optarg);
        std::exit(EXIT_FAILURE);
      }
      difftest_port = static_cast<int>(port);
      break;
    }
    case 1:
      if (img_file != nullptr) {
        std::fprintf(stderr, "only one image may be specified\n");
        std::exit(EXIT_FAILURE);
      }
      img_file = optarg;
      break;
    default:
      usage(argv[0]);
      std::exit(option == 'h' ? EXIT_SUCCESS : EXIT_FAILURE);
    }
  }
}

static long load_img() {
  if (img_file == nullptr) {
    Log("No image is given. Use the zero-filled built-in image.");
    return 4096;
  }
  FILE *fp = std::fopen(img_file, "rb");
  if (fp == nullptr) {
    std::fprintf(stderr, "cannot open '%s': %s\n", img_file,
                 std::strerror(errno));
    std::exit(EXIT_FAILURE);
  }
  std::fseek(fp, 0, SEEK_END);
  long size = std::ftell(fp);
  if (size < 0 || static_cast<unsigned long>(size) > CONFIG_MSIZE) {
    std::fprintf(stderr, "image '%s' is too large\n", img_file);
    std::fclose(fp);
    std::exit(EXIT_FAILURE);
  }
  std::rewind(fp);
  if (size > 0 && std::fread(guest_to_host(RESET_VECTOR), size, 1, fp) != 1) {
    std::fprintf(stderr, "cannot read image '%s'\n", img_file);
    std::fclose(fp);
    std::exit(EXIT_FAILURE);
  }
  std::fclose(fp);
  Log("The image is %s, size = %ld", img_file, size);
  return size;
}

void init_monitor(int argc, char **argv) {
  parse_args(argc, argv);
  init_log(log_file);
  init_mem();
#ifdef CONFIG_DEVICE
  init_device();
#endif
  long img_size = load_img();
  sim_set_args(argc, argv);
  sim_init();
  sim_reset(10);
  init_difftest(diff_so_file, img_size, difftest_port);
  init_sdb();
#ifdef CONFIG_ITRACE
  init_disasm();
#endif

#ifdef CONFIG_FTRACE
  init_ftrace(elf_file);
#endif
  Log("Differential testing: %s", difftest_enabled()
                                      ? ANSI_FMT("ON", ANSI_FG_GREEN)
                                      : ANSI_FMT("OFF", ANSI_FG_RED));
  std::printf("Welcome to %s-NPC!\n",
              ANSI_FMT("minirv", ANSI_FG_YELLOW ANSI_BG_RED));
  std::printf("For help, type \"help\"\n");
}

void engine_start() {
  sdb_mainloop();
  sim_finish();
}
