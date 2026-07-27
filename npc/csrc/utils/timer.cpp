#include <utils.h>

#include <chrono>

uint64_t get_time() {
  using Clock = std::chrono::steady_clock;
  static const auto boot_time = Clock::now();
  return std::chrono::duration_cast<std::chrono::microseconds>(Clock::now() -
                                                               boot_time)
      .count();
}
