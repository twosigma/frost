/*
 *    Copyright 2026 Two Sigma Open Source, LLC
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

/* S-mode payload for the SRST cold and warm reboot tests. */
#include <stdint.h>

#ifndef FROST_SBI_RESET_TYPE
#define FROST_SBI_RESET_TYPE 1
#endif
#define UTX (*(volatile uint32_t *) 0x40000000u)
#define UTX_ST (*(volatile uint32_t *) 0x40000028u)
#define SBI_EXT_BASE 0x10
#define SBI_EXT_SRST 0x53525354

static void puts_(const char *s)
{
    while (*s) {
        while (!(UTX_ST & 1u)) {
        }
        UTX = (uint8_t) *s++;
    }
}
static void fail(void)
{
    puts_("\r\n<<FAIL>> SBI reset\r\n");
    for (;;) {
    }
}

struct sbiret {
    long error;
    long value;
};

static struct sbiret sbi_ecall(
    long ext, long fid, unsigned long a0, unsigned long a1, unsigned long a2, unsigned long a3)
{
    register unsigned long r_a0 __asm__("a0") = a0;
    register unsigned long r_a1 __asm__("a1") = a1;
    register unsigned long r_a2 __asm__("a2") = a2;
    register unsigned long r_a3 __asm__("a3") = a3;
    register long r_a6 __asm__("a6") = fid;
    register long r_a7 __asm__("a7") = ext;
    __asm__ volatile("ecall"
                     : "+r"(r_a0), "+r"(r_a1)
                     : "r"(r_a2), "r"(r_a3), "r"(r_a6), "r"(r_a7)
                     : "memory");
    struct sbiret ret = {(long) r_a0, (long) r_a1};
    return ret;
}


int handle_trap(void *frame)
{
    (void) frame;
    fail();
    return 0;
}

int main(void)
{
    struct sbiret r = sbi_ecall(SBI_EXT_BASE, 3, SBI_EXT_SRST, 0, 0, 0);
    if (r.error || !r.value)
        fail();
    r = sbi_ecall(SBI_EXT_SRST, 0, 0, 0, 0, 0);
    if (r.error != -2) /* No shutdown device. */
        fail();
    r = sbi_ecall(SBI_EXT_SRST, 0, 3, 0, 0, 0);
    if (r.error != -3) /* Invalid reset type. */
        fail();
    r = sbi_ecall(SBI_EXT_SRST, 0, FROST_SBI_RESET_TYPE, 2, 0, 0);
    if (r.error != -3) /* Invalid reset reason. */
        fail();
    puts_("\r\nSBI reset: requesting reboot\r\n");
    sbi_ecall(SBI_EXT_SRST, 0, FROST_SBI_RESET_TYPE, 0, 0, 0);
    fail();
    return 0;
}
