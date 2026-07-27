#include <device/device.h>
#include <device/map.h>

void init_serial();
void init_timer();

void init_device() {
  init_map();
#ifdef CONFIG_HAS_SERIAL
  init_serial();
#endif
#ifdef CONFIG_HAS_TIMER
  init_timer();
#endif
}

void device_update() {}
