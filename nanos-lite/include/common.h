#ifndef __COMMON_H__
#define __COMMON_H__

/* Uncomment these macros to enable corresponding functionality. */
#define HAS_CTE
// #define HAS_VME
// #define MULTIPROGRAM
// #define TIME_SHARING

#include <am.h>
#include <klib-macros.h>
#include <klib.h>

#include <debug.h> //这个只能放在最后，因为 debug.h 里面有些宏定义会覆盖前面的宏定义
#endif
