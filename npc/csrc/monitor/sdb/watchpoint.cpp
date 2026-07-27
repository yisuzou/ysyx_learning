#include "sdb.h"

#include <cstdio>
#include <cstring>

static constexpr int NR_WP = 32;
static WP wp_pool[NR_WP] = {};
static WP *head = nullptr;
static WP *free_list = nullptr;

void init_wp_pool() {
  for (int i = 0; i < NR_WP; i++) {
    wp_pool[i].NO = i;
    wp_pool[i].next = i + 1 < NR_WP ? &wp_pool[i + 1] : nullptr;
  }
  head = nullptr;
  free_list = &wp_pool[0];
}

WP *new_wp() {
  if (free_list == nullptr) {
    std::printf("watchpoint pool is full\n");
    return nullptr;
  }
  WP *wp = free_list;
  free_list = free_list->next;
  wp->next = head;
  head = wp;
  return wp;
}

void free_wp(WP *wp) {
  if (wp == nullptr) {
    return;
  }
  if (head == wp) {
    head = wp->next;
  } else {
    WP *previous = head;
    while (previous != nullptr && previous->next != wp) {
      previous = previous->next;
    }
    if (previous == nullptr) {
      return;
    }
    previous->next = wp->next;
  }
  wp->next = free_list;
  free_list = wp;
}

WP *find_wp(uint32_t number, bool *empty) {
  *empty = head == nullptr;
  for (WP *wp = head; wp != nullptr; wp = wp->next) {
    if (wp->NO == static_cast<int>(number)) {
      return wp;
    }
  }
  return nullptr;
}

bool check_watchpoints() {
  bool changed = false;
  for (WP *wp = head; wp != nullptr; wp = wp->next) {
    bool success = true;
    word_t value = expr(wp->expr, &success);
    if (!success) {
      std::printf("watchpoint %d expression became invalid: %s\n", wp->NO,
                  wp->expr);
      return true;
    }
    if (value != wp->tar_val) {
      std::printf("watchpoint %d triggered: %s: 0x%x -> 0x%x\n", wp->NO,
                  wp->expr, wp->tar_val, value);
      wp->tar_val = value;
      changed = true;
    }
  }
  return changed;
}
