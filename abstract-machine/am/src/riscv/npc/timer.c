#include <am.h>

#define RTC_ADDR 0x10000048

void __am_timer_init() {
}

void __am_timer_uptime(AM_TIMER_UPTIME_T *uptime) {
  uint64_t us_lo = *(volatile uint32_t *)RTC_ADDR;
  uint64_t us_hi = *(volatile uint32_t *)(RTC_ADDR + 4);
  uptime->us = (us_hi << 32) | us_lo;
}

void __am_timer_rtc(AM_TIMER_RTC_T *rtc) {
  rtc->second = 0;
  rtc->minute = 0;
  rtc->hour   = 0;
  rtc->day    = 0;
  rtc->month  = 0;
  rtc->year   = 1900;
}
