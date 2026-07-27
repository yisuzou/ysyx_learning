#include <utils.h>

void init_monitor(int argc, char *argv[]);
void engine_start();

int main(int argc, char *argv[]) {
  init_monitor(argc, argv);
  engine_start();
  return is_exit_status_bad();
}
