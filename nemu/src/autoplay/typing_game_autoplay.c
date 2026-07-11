#include <common.h>
#include <memory/paddr.h>
#include <stdbool.h>
#include <stdlib.h>
#include <SDL2/SDL.h>

void send_key(uint8_t scancode, bool is_keydown);//复用nemu的键盘相关处理函数接口

#define AUTOPLAY_NCHAR      128
#define AUTOPLAY_CHAR_SIZE  20
#define AUTOPLAY_CH_OFFSET  0
#define AUTOPLAY_V_OFFSET   12

static bool initialized = false;
static bool enabled = false;
static paddr_t chars_addr = 0; //结构体地址
static bool shot[128]; //对应chars结构体数组

static void autoplay_send_char(char ch) {
    if (ch < 'A' || ch > 'Z') return;
    send_key(SDL_SCANCODE_A + (ch - 'A'), true);
}

void nemu_autoplay_update(void){
    if(!initialized){
        initialized = true;

        const char *s = getenv("NEMU_AUTOPLAY_CHARS");
        // 如果环境变量存在且不为空，则将其转换为十六进制地址
        if (s != NULL && s[0] != '\0') {
            chars_addr = (paddr_t)strtoull(s, NULL, 0);
            enabled = chars_addr != 0;// 如果地址不为0，则启用自动游戏
        }
    }
    if(!enabled) return; //如果未启用自动游戏，则直接返回

    for (int i = 0 ; i < AUTOPLAY_NCHAR ; i++){
        paddr_t base = chars_addr + i * AUTOPLAY_CHAR_SIZE;
        char ch = (char)paddr_read(base + AUTOPLAY_CH_OFFSET, 1);
        int32_t v = (int32_t)paddr_read(base + AUTOPLAY_V_OFFSET, 4);

        if (ch == '\0') {
            shot[i] = false; // 如果字符为空，则将shot标记为false
            continue;
        }

        if(ch>='A' && ch<='Z' && v > 0 && !shot[i]){
            autoplay_send_char(ch);
            shot[i] = true; // 如果字符是大写字母且v大于0且未被标记为已发送，则发送该字符并将shot标记为true
        }
    }

}
