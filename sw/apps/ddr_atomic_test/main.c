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

/*
 * Directed reproducer for word-form (.w) atomics to the cached DDR region.
 *
 * A no-MMU Linux boot hangs on a store-conditional (sc.w.rl) to a printk
 * ring-buffer descriptor in DDR, so LR/SC to the cached tier deadlocks even
 * though atomics to low BRAM work (FreeRTOS A-extension stress passes).
 *
 * This isolates it: the target variable lives in .ddr_data, the cached tier.
 * Each step prints a progress letter before it runs, so the last letter
 * received over UART pinpoints which operation wedged:
 *   "S"        started
 *   "SL"       plain DDR store/load OK (hang at the AMO)
 *   "SLA"      one amoadd.w to DDR OK (hang in the AMO loop)
 *   "SLAR"     256 repeated amoadd.w increments OK (hang at the struct AMO)
 *   "SLARP"    amoadd.w into a struct field OK (hang at LR/SC)
 *   "SLARPC"   LR/SC to DDR OK
 *   "<<PASS>>" all DDR atomics work (then the kernel hang is elsewhere)
 */

#include <stdint.h>

#define UTX (*(volatile uint32_t *) 0x40000000u)
#define UTX_ST (*(volatile uint32_t *) 0x40000028u)
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

/* Lives in the cached DDR region. */
__attribute__((section(".ddr_data"))) static volatile uint32_t ddr_var = 0x10;
struct pde_like {
    uint32_t in_use;
    uint32_t refcnt;
    uint8_t pad[88];
    uint16_t mode;
    uint8_t flags;
    uint8_t namelen;
    uint32_t tail;
};
__attribute__((section(".ddr_data"))) static volatile struct pde_like ddr_pde_like;

/* lp64 + medany cannot materialize .ddr_data addresses PC-relatively from the
 * BRAM-linked text (R_RISCV_PCREL_HI20 tops out ~2 GiB short of 0x8000_0000),
 * so route every access through pointers whose absolute values are link-time
 * R_RISCV_64 data relocs in BRAM. The pointers are volatile-qualified so -O3
 * cannot constant-fold them back into direct (PC-relative) references. */
static volatile uint32_t *volatile dv = &ddr_var;
static volatile struct pde_like *volatile pde = &ddr_pde_like;

int main(void)
{
    putc_('S');

    /* 1. Plain DDR store/load. ddr_test already covers this path. */
    *dv = 0x20;
    if (*dv != 0x20) {
        puts_("\r\n<<FAIL>> ddr store/load\r\n");
        for (;;) {
        }
    }
    putc_('L');

    /* 2. AMO to DDR (amoadd.w). Hangs here if AMO-to-cached deadlocks. */
    uint32_t old_amo;
    __asm__ volatile("amoadd.w %0, %2, (%1)" : "=r"(old_amo) : "r"(dv), "r"(1u) : "memory");
    if (old_amo != 0x20) {
        puts_("\r\n<<FAIL>> amo old value\r\n");
        for (;;) {
        }
    }
    if (*dv != 0x21) {
        puts_("\r\n<<FAIL>> amo result\r\n");
        for (;;) {
        }
    }
    putc_('A');

    /* 2b. Refcount-like repeated AMO increments: validate both old and new values. */
    *dv = 1;
    for (uint32_t i = 0; i < 256; i++) {
        uint32_t old_loop;
        __asm__ volatile("amoadd.w %0, %2, (%1)" : "=r"(old_loop) : "r"(dv), "r"(1u) : "memory");
        if (old_loop != i + 1 || *dv != i + 2) {
            puts_("\r\n<<FAIL>> amo loop value\r\n");
            for (;;) {
            }
        }
    }
    putc_('R');

    /* 2c. Proc-dir-entry-like layout: AMO at +4 must not corrupt mode at +96. */
    pde->in_use = 0x11111111u;
    pde->refcnt = 1u;
    pde->mode = 0x8124u;
    pde->flags = 0x5au;
    pde->namelen = 7u;
    pde->tail = 0xa5a55a5au;
    for (uint32_t i = 0; i < 256; i++) {
        uint32_t old_ref;
        __asm__ volatile("amoadd.w %0, %2, (%1)"
                         : "=r"(old_ref)
                         : "r"(&pde->refcnt), "r"(1u)
                         : "memory");
        if (old_ref != i + 1 || pde->refcnt != i + 2 || pde->in_use != 0x11111111u ||
            pde->mode != 0x8124u || pde->flags != 0x5au || pde->namelen != 7u ||
            pde->tail != 0xa5a55a5au) {
            puts_("\r\n<<FAIL>> amo struct corruption\r\n");
            for (;;) {
            }
        }
    }
    putc_('P');

    /* 3. LR/SC compare-exchange to DDR (matches the kernel's sc.w.rl). */
    uint32_t prev;
    __asm__ volatile("1: lr.w    %0, (%1)\n"
                     "   sc.w.rl t0, %2, (%1)\n"
                     "   bnez    t0, 1b\n"
                     : "=&r"(prev)
                     : "r"(dv), "r"(0xABCDu)
                     : "t0", "memory");
    if (*dv != 0xABCDu) {
        puts_("\r\n<<FAIL>> lr/sc result\r\n");
        for (;;) {
        }
    }
    putc_('C');

    puts_("\r\n<<PASS>>\r\n");
    for (;;) {
    }
    return 0;
}
