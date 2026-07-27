#include <device/map.h>

static uint8_t *serial_base = nullptr;

static void serial_io_handler(uint32_t offset, int len, bool is_write) {
  assert(offset == 0 && len == 1);
  if (!is_write) {
    std::fprintf(stderr, "serial does not support reads\n");
    return;
  }
  std::fputc(serial_base[0], stderr);
}

void init_serial() {
  serial_base = new_space(8);
  add_mmio_map("serial", CONFIG_SERIAL_MMIO, serial_base, 8,
               serial_io_handler);
}
