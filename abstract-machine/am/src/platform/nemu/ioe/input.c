#include <am.h>
#include <nemu.h>

#define KEYDOWN_MASK 0x8000

void __am_input_keybrd(AM_INPUT_KEYBRD_T *kbd) {
  uint32_t buf = inl(KBD_ADDR);
  kbd->keydown = (buf & KEYDOWN_MASK) >> 15;
  kbd->keycode = (buf == 0x0) ? AM_KEY_NONE : (buf & ~KEYDOWN_MASK);
}
