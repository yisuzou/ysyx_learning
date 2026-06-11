#include <am.h>
#include <nemu.h>

#define SYNC_ADDR (VGACTL_ADDR + 4)

void __am_gpu_init() {}

void __am_gpu_config(AM_GPU_CONFIG_T *cfg) {
  uint32_t v = inl(VGACTL_ADDR);
  *cfg = (AM_GPU_CONFIG_T){.present = true,
                           .has_accel = false,
                           .width = v >> 16,
                           .height = v & 0xFFFF,
                           .vmemsz = 240000};
}

void __am_gpu_fbdraw(AM_GPU_FBDRAW_T *ctl) {
  uint32_t *fb = (uint32_t *)(uintptr_t)FB_ADDR;
  uint32_t screen_w = inl(VGACTL_ADDR) >> 16;

  for (int i = 0; i < ctl->h; i++) {
    for (int j = 0; j < ctl->w; j++) {
      int offset = (ctl->y + i) * screen_w + ctl->x + j;
      fb[offset] = ((uint32_t *)ctl->pixels)[i * ctl->w + j];
    }
  }

  if (ctl->sync) {
    outl(SYNC_ADDR, 1);
  }
}

void __am_gpu_status(AM_GPU_STATUS_T *status) { status->ready = true; }
