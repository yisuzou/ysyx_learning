#include <am.h>
#include <nemu.h>
#include <stdint.h>

void __am_timer_init() {}

void __am_timer_uptime(AM_TIMER_UPTIME_T *uptime) {
  // nemu作为模拟器，本身已经实现了时钟和相关设备，am
  // 要做的只是去访问相关地址就可以！
  uint64_t us0 = (uint64_t)inl(RTC_ADDR);
  uint64_t us1 = (uint64_t)inl(RTC_ADDR + 4) << 32;

  uptime->us = us1 | us0;
}

void __am_timer_rtc(AM_TIMER_RTC_T *rtc) {
  rtc->second = 0;
  rtc->minute = 0;
  rtc->hour = 0;
  rtc->day = 0;
  rtc->month = 0;
  rtc->year = 1900;
}
