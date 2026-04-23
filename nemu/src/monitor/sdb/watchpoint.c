/***************************************************************************************
 * Copyright (c) 2014-2024 Zihao Yu, Nanjing University
 *
 * NEMU is licensed under Mulan PSL v2.
 * You can use this software according to the terms and conditions of the Mulan
 * PSL v2. You may obtain a copy of Mulan PSL v2 at:
 *          http://license.coscl.org.cn/MulanPSL2
 *
 * THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY
 * KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO
 * NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
 *
 * See the Mulan PSL v2 for more details.
 ***************************************************************************************/

#include "common.h"
#include "sdb.h"
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <threads.h>
#include <time.h>

#define NR_WP 32
/*
typedef struct watchpoint {
  int NO;
  struct watchpoint *next;


  //w EXPR
设置监测点，需要保存值用来对比是否发生变化，也需要保存EXPR，这样才知道该监测点的观测对象
  word_t tar_val;
  char expr[256];
} WP;
*/
static WP wp_pool[NR_WP] = {};
static WP *head = NULL, *free_ = NULL;

void init_wp_pool() {
  int i;
  for (i = 0; i < NR_WP; i++) {
    wp_pool[i].NO = i;
    wp_pool[i].next = (i == NR_WP - 1 ? NULL : &wp_pool[i + 1]);
  }

  head = NULL;
  free_ = wp_pool;
}

/* TODO: Implement the functionality of watchpoint */
WP *new_wp() {
  WP *wp;
  if (free_ == NULL) {
    printf("pool run out!\n");
    assert(0);
  }
  wp = free_;          // 将wp链接到池中的第一个节点；wp.NO = 0 wp.next = WP1；
  free_ = free_->next; // 取出后，将free连接到后一个，
  wp->next = head;     // 至此，改变了取出节点的指向关系,
                       // 原来的head指向NuLL，这里下一个就是指向null；
  head = wp;           // head 又指向了wp，保持了head 的头部位置
  return wp;
}
void free_wp(WP *wp) {
  // 让目标节点的上一节点指向目标节点的下一节点
  // 如果目标节点是头，那就直接改变头的位置
  // 如果目标不是头，从头开始遍历，找到下一节点是目标节点的节点，使它指向目标节点的下一节点
  if (wp == head) {
    head = wp->next;
  } else {
    WP *p = head;
    while (p->next != wp) {
      p = p->next;
    }
    p->next = wp->next;
  }
  // 接下来要将它返回到free，这和将wp取出的操作一样；
  wp->next = free_; // 指向未使用链表的头
  free_ = wp;       // 再将free移动过来；
}

WP *find_wp(uint32_t N, bool *isempty) {
  if (head == NULL) {
    *isempty = true;
    return head;
  }
  WP *p = head;
  while (p != NULL) {
    if (p->NO == N) {
      return p;
    }
    p = p->next;
  }
  return p;
}

bool check_wp() {
  bool isempty = false;
  bool change = false;
  bool success = true;
  for (int i = 0; i < NR_WP;
       i++) { // 更明智的方法似乎是使用p指向head，判断p!=NULL使用p=p->next来遍历
    WP *p = find_wp(i, &isempty);
    if (isempty) { // 如果没有监视点，不用循环直接退出；
      return false;
    }
    if (p != NULL) {
      // 根据存储的表达式求值，然后和存储的值比较是否发生变化，如果发生变化，存储新值返回true
      uint32_t new_val = expr(p->expr, &success);
      // 可以成功创建监视点，表达式就是合法的可被计算的，如果出错了，很不正常，必须报错
      assert(success);
      if (new_val != p->tar_val) {
        printf("wp %d is triggered. %s: val:%u --> val:%u .\n", p->NO, p->expr,
               p->tar_val, new_val);
        change = true;
        p->tar_val = new_val; // 存储新值
      }
    }
  }
  if (change) {
    return true;
  }
  return false;
}
