#include "local-include/csr.h"
#include <isa.h>
#include <stdbool.h>
#include <stdio.h>

void isa_csr_display() {
  for (int i = 0; i < CSR_NUM; i++) {
    printf("%s : 0x%x\n", csr_map[i].name, cpu.csr[csr_map[i].idx]);
  }
}

word_t isa_csr_str2val(const char *s, bool *success) {
  for (int i = 0; i < CSR_NUM; i++) {
    if (strcmp(s, csr_map[i].name) == 0) {
      return cpu.csr[csr_map[i].idx];
    }
  }
  printf("no match CSR NAME! Retry!\n");
  *success = false;
  return 0;
}
