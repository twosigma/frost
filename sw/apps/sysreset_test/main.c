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
 * SYSRESET directed test: SBI system reset.
 *
 * A 32-bit store of 0x7777 to 0x4002_F000 resets the core domain exactly as
 * the debug module's ndmreset does: the hart restarts at the boot address
 * (crt0, the boot ROM's entry), the SoC registers return to their reset
 * values, and BRAM keeps its contents. OpenSBI reaches this register through
 * syscon-reboot to serve SBI SRST, so Linux `reboot` restarts the board.
 *
 * Run 1 (the memory word at BOOT_MARK is not the magic):
 *   - sets BOOT_MARK to the magic, mscratch and mtimecmp to known values;
 *   - stores wrong keys (0x1234, 0x7776, a byte store of 0x77, a store to
 *     the neighbouring word) and checks nothing resets, which shows by the
 *     hart still running;
 *   - stores the key, then spins. The reset ends the spin.
 * Run 2 (BOOT_MARK holds the magic, so the program started again):
 *   - mscratch is zero and mtimecmp holds its reset value, the reset reached
 *     the hart and the timer registers;
 *   - clears BOOT_MARK and prints <<PASS>>.
 * The marker word sits below the stack, outside .data and .bss, which crt0
 * would rewrite.
 */

#include <stdint.h>

#define SYSRESET (*(volatile uint32_t *) 0x4002F000u)
#define SYSRESET_NEXT (*(volatile uint32_t *) 0x4002F004u)
#define SYSRESET_H (*(volatile uint16_t *) 0x4002F000u)
#define SYSRESET_B (*(volatile uint8_t *) 0x4002F000u)

#define NAT_MTIMECMP_LO (*(volatile uint32_t *) 0x40000018u)
#define NAT_MTIMECMP_HI (*(volatile uint32_t *) 0x4000001Cu)

#define UTX (*(volatile uint32_t *) 0x40000000u)
#define UTX_ST (*(volatile uint32_t *) 0x40000028u)

#define BOOT_MARK (*(volatile uint32_t *) 0x00030000u)
#define MAGIC 0x5E5E7777u

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

int main(void)
{
    if (BOOT_MARK != MAGIC) {
        /* Run 1. */
        BOOT_MARK = MAGIC;
        __asm__ volatile("csrw mscratch, %0" ::"r"(0x1234u));
        NAT_MTIMECMP_HI = 0x1u;
        NAT_MTIMECMP_LO = 0x2u;

        /* Writes that are not the key leave the system running. */
        SYSRESET = 0x1234u;
        SYSRESET = 0x7776u;
        SYSRESET = 0x00010000u; /* upper half only */
        SYSRESET_B = 0x77u;
        SYSRESET_NEXT = 0x7777u; /* the neighbouring word */
        for (volatile int i = 0; i < 2000; i++) {
        }
        puts_("\r\nrun1: no reset from wrong writes\r\n");

        /* A 16-bit store of the key resets as well as the 32-bit store. The
         * test uses the 32-bit form, which is what syscon-reboot issues. */
        SYSRESET = 0x7777u;
        for (volatile int i = 0; i < 1000000; i++) {
        }
        /* Reached only if the reset did not happen. */
        puts_("\r\n<<FAIL>> no reset\r\n");
        for (;;) {
        }
    }

    /* Run 2: the hart restarted. */
    unsigned long scratch;
    __asm__ volatile("csrr %0, mscratch" : "=r"(scratch));
    unsigned bad = 0;
    bad |= (scratch == 0u) ? 0u : 1u;
    bad |= (NAT_MTIMECMP_HI == 0xFFFFFFFFu) ? 0u : 2u;
    BOOT_MARK = 0u;
    if (bad == 0u) {
        puts_("\r\nrun2: restarted\r\n<<PASS>>\r\n");
    } else {
        puts_("\r\n<<FAIL>> state not reset\r\n");
    }
    for (;;) {
    }
    return 0;
}
