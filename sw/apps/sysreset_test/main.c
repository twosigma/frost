/*
 *    Copyright (c) 2026 John Goodacre
 *
 *    Licensed under the Apache License, Version 2.0 (the "License");
 *    you may not use this file except in compliance with the License.
 *    You may obtain a copy of the License at
 *
 *        http://www.apache.org/licenses/LICENSE-2.0
 *
 *    Unless required by applicable law or agreed to in writing, software
 *    distributed under the License is distributed on an "AS IS" BASIS,
 *    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *    See the License for the specific language governing permissions and
 *    limitations under the License.
 */

/*
 * SYSRESET register test. The marker is outside .data and .bss, within the
 * general BRAM stack reserve but below this program's small stack. The load
 * image clears it on every load; crt0 leaves it intact across SYSRESET.
 * Set the next-boot marker only
 * after invalid writes have completed, so an unintended reset fails.
 * Word and halfword requests each restart the program at its reset entry.
 */

#include <stdint.h>

#define SYSRESET (*(volatile uint32_t *) 0x4002F000u)
#define SYSRESET_NEXT (*(volatile uint32_t *) 0x4002F004u)
#define SYSRESET_H (*(volatile uint16_t *) 0x4002F000u)
#define SYSRESET_HIGH_H (*(volatile uint16_t *) 0x4002F002u)
#define SYSRESET_B (*(volatile uint8_t *) 0x4002F000u)
#define SYSRESET_HIGH_B (*(volatile uint8_t *) 0x4002F001u)
#define NAT_MTIMECMP_LO (*(volatile uint32_t *) 0x40000018u)
#define NAT_MTIMECMP_HI (*(volatile uint32_t *) 0x4000001Cu)
#define UTX (*(volatile uint32_t *) 0x40000000u)
#define UTX_ST (*(volatile uint32_t *) 0x40000028u)
#define BOOT_MARK (*(volatile uint32_t *) 0x00030000u)
#define CHECKING 0x5E5E0001u
#define WORD_RESET 0x5E5E0002u
#define HALF_RESET 0x5E5E0003u

static void putc_(char c)
{
    while (!(UTX_ST & 1u)) {
    }
    UTX = (uint8_t) c;
}
static void puts_(const char *s)
{
    while (*s)
        putc_(*s++);
}
static void fail(const char *s)
{
    puts_("\r\n<<FAIL>> ");
    puts_(s);
    puts_("\r\n");
    for (;;) {
    }
}
static void poison_state(void)
{
    __asm__ volatile("csrw mscratch, %0" ::"r"(0x1234u));
    NAT_MTIMECMP_HI = 1u;
    NAT_MTIMECMP_LO = 2u;
}
static void reset_must_arrive(void)
{
    for (volatile int i = 0; i < 1000000; i++) {
    }
    fail("no reset");
}

int main(void)
{
    uint32_t phase = BOOT_MARK;
    if (phase == CHECKING)
        fail("reset from an invalid write");
    if (phase == WORD_RESET || phase == HALF_RESET) {
        unsigned long scratch;
        __asm__ volatile("csrr %0, mscratch" : "=r"(scratch));
        if (scratch != 0 || NAT_MTIMECMP_HI != 0xFFFFFFFFu || NAT_MTIMECMP_LO != 0xFFFFFFFFu)
            fail("state not reset");
        if (SYSRESET != 0)
            fail("reset register read");
        if (phase == HALF_RESET) {
            BOOT_MARK = 0;
            puts_("\r\nword and halfword resets completed\r\n<<PASS>>\r\n");
            for (;;) {
            }
        }
        poison_state();
        BOOT_MARK = HALF_RESET;
        __asm__ volatile("fence iorw, iorw" ::: "memory");
        SYSRESET_H = 0x7777u;
        reset_must_arrive();
    }

    BOOT_MARK = CHECKING;
    __asm__ volatile("fence iorw, iorw" ::: "memory");
    poison_state();
    SYSRESET = 0x1234u;
    SYSRESET = 0x7776u;
    SYSRESET = 0x00010000u;
    SYSRESET_B = 0x77u;
    SYSRESET_HIGH_B = 0x77u;
    SYSRESET_HIGH_H = 0x7777u;
    SYSRESET_NEXT = 0x7777u;
    for (volatile int i = 0; i < 2000; i++) {
    }
    if (SYSRESET != 0)
        fail("reset register read");
    puts_("\r\nno reset from invalid writes\r\n");
    BOOT_MARK = WORD_RESET;
    __asm__ volatile("fence iorw, iorw" ::: "memory");
    SYSRESET = 0x7777u;
    reset_must_arrive();
    return 0;
}
