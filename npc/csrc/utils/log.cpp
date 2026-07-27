#include <utils.h>

#include <cstdarg>

FILE *log_fp = stdout;

void init_log(const char *log_file) {
  if (log_file != nullptr) {
    log_fp = std::fopen(log_file, "w");
    if (log_fp == nullptr) {
      std::perror(log_file);
      std::exit(EXIT_FAILURE);
    }
  }
  Log("Log is written to %s", log_file == nullptr ? "stdout" : log_file);
}

void log_write(const char *format, ...) {
  va_list args;
  va_start(args, format);
  std::vfprintf(log_fp, format, args);
  va_end(args);
  std::fflush(log_fp);
}
