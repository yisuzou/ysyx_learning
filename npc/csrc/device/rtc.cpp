#include <device/map.h>
#include <utils.h>

static uint32_t *rtc_port_base = nullptr;

static void rtc_io_handler(uint32_t offset, int len, bool is_write) {
  assert((offset == 0 || offset == 4) && len == 4 && !is_write);
  if (offset == 4) {
    uint64_t now = get_time();
    rtc_port_base[0] = static_cast<uint32_t>(now);
    rtc_port_base[1] = static_cast<uint32_t>(now >> 32);
  }
}

void init_timer() {
  rtc_port_base = reinterpret_cast<uint32_t *>(new_space(8));
  add_mmio_map("rtc", CONFIG_RTC_MMIO, rtc_port_base, 8, rtc_io_handler);
}
