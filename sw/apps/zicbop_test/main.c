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
 * Zicbop directed test. prefetch.i, prefetch.r and prefetch.w are ORI
 * encodings with rd = x0 and imm[4:0] = 0, 1 and 3; the CMO chapter makes
 * them HINTs that never raise an exception and never change architectural
 * state. FROST executes them as ORI to x0.
 *
 * Each case runs the three prefetches, with positive and negative offsets,
 * in M, S and U, on addresses that a load would fault on (null, an unserved
 * device page, beyond DDR, a non-canonical address, an unaligned address,
 * and an Sv39 address with no mapping while translation is on in S and U),
 * and on ordinary cached DDR. A case passes when it ends in the mode's ecall
 * (no trap), with rs1 and the neighbouring registers unchanged and memory
 * untouched.
 */

#include <stdint.h>

#include "trap.h"
#include "uart.h"

#ifndef FROST_DDR_CAPACITY_LOG2_BYTES
#define FROST_DDR_CAPACITY_LOG2_BYTES 30
#endif
#define DDR_LIMIT (0x80000000ul + (1ul << FROST_DDR_CAPACITY_LOG2_BYTES))

#define CAUSE_ECALL_U 8ul
#define CAUSE_ECALL_S 9ul
#define CAUSE_ECALL_M 11ul

static volatile unsigned long g_cause;
static volatile unsigned long g_a0_after;
static volatile unsigned long g_a1_after;
static volatile uint64_t g_ddr_word __attribute__((aligned(64), section(".ddr_data")));

__attribute__((naked, aligned(4))) static void zicbop_trap_handler(void)
{
    __asm__ volatile("csrr t0, mcause\n"
                     "la   t1, g_cause\n"
                     "sd   t0, 0(t1)\n"
                     "la   t1, g_a0_after\n"
                     "sd   a0, 0(t1)\n"
                     "la   t1, g_a1_after\n"
                     "sd   a1, 0(t1)\n"
                     "csrr t0, mscratch\n"
                     "csrw mepc, t0\n"
                     "li   t0, 0x1800\n"
                     "csrs mstatus, t0\n"
                     "mret\n");
}

/* ORI x0, a0, imm: prefetch.i (imm[4:0] = 0), prefetch.r (1), prefetch.w (3)
 * with offsets 0, +64, -64 and +2016 (imm[11:5] is the offset / 32). a1 is
 * a canary that ecall reports back. */
__attribute__((naked)) static void prefetch_body(void)
{
    __asm__ volatile(".insn i 0x13, 6, x0, a0, 0\n"     /* prefetch.i 0(a0) */
                     ".insn i 0x13, 6, x0, a0, 1\n"     /* prefetch.r 0(a0) */
                     ".insn i 0x13, 6, x0, a0, 3\n"     /* prefetch.w 0(a0) */
                     ".insn i 0x13, 6, x0, a0, 64\n"    /* prefetch.i 64(a0) */
                     ".insn i 0x13, 6, x0, a0, 65\n"    /* prefetch.r 64(a0) */
                     ".insn i 0x13, 6, x0, a0, 67\n"    /* prefetch.w 64(a0) */
                     ".insn i 0x13, 6, x0, a0, -64\n"   /* prefetch.i -64(a0) */
                     ".insn i 0x13, 6, x0, a0, -63\n"   /* prefetch.r -64(a0) */
                     ".insn i 0x13, 6, x0, a0, -61\n"   /* prefetch.w -64(a0) */
                     ".insn i 0x13, 6, x0, a0, 2016\n"  /* prefetch.i 2016(a0) */
                     ".insn i 0x13, 6, x0, a0, 2017\n"  /* prefetch.r 2016(a0) */
                     ".insn i 0x13, 6, x0, a0, 2019\n"  /* prefetch.w 2016(a0) */
                     ".insn i 0x13, 6, x0, a0, -2048\n" /* prefetch.i -2048(a0) */
                     "ecall\n"
                     "j .\n");
}

static unsigned long run_mode(unsigned long mpp, unsigned long rs1)
{
    g_cause = ~0ul;
    g_a0_after = 0;
    g_a1_after = 0;
    __asm__ volatile("la   t0, 1f\n"
                     "csrw mscratch, t0\n"
                     "li   t0, 0x1800\n"
                     "csrc mstatus, t0\n"
                     "slli t0, %0, 11\n"
                     "csrs mstatus, t0\n"
                     "csrw mepc, %1\n"
                     "mv   a0, %2\n"
                     "li   a1, 0x5a5a1234\n"
                     "mret\n"
                     "1:\n"
                     :
                     : "r"(mpp), "r"((unsigned long) &prefetch_body), "r"(rs1)
                     : "t0", "t1", "t2", "t3", "a0", "a1", "memory");
    return g_cause;
}

/* ---- Sv39 tables: an identity gigapage for low BRAM code and data, DDR
 * gigapages, and nothing at VA 0x4000_0000 (unmapped). ---- */
#define PT_ROOT 0x81000000ul
#define PTE_V (1ul << 0)
#define PTE_R (1ul << 1)
#define PTE_W (1ul << 2)
#define PTE_X (1ul << 3)
#define PTE_U (1ul << 4)
#define PTE_A (1ul << 6)
#define PTE_D (1ul << 7)
#define PTE_PPN(pa) ((((unsigned long) (pa)) >> 12) << 10)
#define SATP_SV39 (8ul << 60)
#define MSTATUS_SUM (1ul << 18)

static void build_tables(unsigned long user)
{
    volatile unsigned long *root = (volatile unsigned long *) PT_ROOT;
    for (int i = 0; i < 512; i++)
        root[i] = 0;
    unsigned long leaf = PTE_V | PTE_R | PTE_W | PTE_X | PTE_A | PTE_D | user;
    root[0] = PTE_PPN(0x0ul) | leaf;
    root[2] = PTE_PPN(0x80000000ul) | leaf;
    root[3] = PTE_PPN(0xC0000000ul) | leaf;
}

static int run_case(const char *name, unsigned long mpp, unsigned long rs1)
{
    static const unsigned long want[4] = {CAUSE_ECALL_U, CAUSE_ECALL_S, 0, CAUSE_ECALL_M};
    uint64_t before = g_ddr_word;
    unsigned long cause = run_mode(mpp, rs1);
    int ok = cause == want[mpp] && g_a0_after == rs1 && g_a1_after == 0x5a5a1234ul &&
             g_ddr_word == before;
    uart_puts(ok ? "[PASS] " : "[FAIL] ");
    uart_puts(name);
    uart_printf(" mode=%lu rs1=0x%lx cause=%lu a0=0x%lx\r\n", mpp, rs1, cause, g_a0_after);
    return ok;
}

int main(void)
{
    int ok = 1;
    static const struct {
        const char *name;
        unsigned long rs1;
    } targets[] = {
        {"null", 0x0ul},
        {"device-unserved", 0x40009013ul},
        {"beyond-ddr", DDR_LIMIT + 0x1000ul},
        {"non-canonical", 0x0000100000000000ul},
        {"top-of-space", 0xFFFFFFFFFFFFFFC0ul},
        {"unaligned", 0x80000007ul},
        {"cached-ddr", 0},
    };

    uart_puts("\r\n=== Zicbop test ===\r\n");
    set_trap_handler(&zicbop_trap_handler);
    csr_write(medeleg, 0);
    g_ddr_word = 0x1122334455667788ul;

    for (unsigned long mpp = 0; mpp < 4; mpp++) {
        if (mpp == 2)
            continue;
        for (unsigned i = 0; i < sizeof(targets) / sizeof(targets[0]); i++) {
            unsigned long rs1 = targets[i].rs1 ? targets[i].rs1 : (unsigned long) &g_ddr_word;
            ok &= run_case(targets[i].name, mpp, rs1);
        }
    }

    /* Sv39 on in S and U: prefetch an unmapped VA, a supervisor page from U,
     * and a mapped DDR VA. Code and data stay identity-mapped. */
    for (unsigned long mpp = 0; mpp < 2; mpp++) {
        build_tables(mpp == 0 ? PTE_U : 0);
        __asm__ volatile("csrw satp, %0\n sfence.vma"
                         :
                         : "r"(SATP_SV39 | (PT_ROOT >> 12))
                         : "memory");
        ok &= run_case("sv39-unmapped", mpp, 0x40000000ul + 0x123ul);
        ok &= run_case("sv39-non-canonical", mpp, 0x0000004000000000ul);
        ok &= run_case("sv39-ddr", mpp, (unsigned long) &g_ddr_word);
        __asm__ volatile("csrw satp, zero\n sfence.vma" ::: "memory");
    }
    /* U-mode prefetch of a supervisor-only page. */
    build_tables(0);
    {
        volatile unsigned long *root = (volatile unsigned long *) PT_ROOT;
        root[0] |= PTE_U; /* U code and stack in low BRAM */
    }
    __asm__ volatile("csrw satp, %0\n sfence.vma" : : "r"(SATP_SV39 | (PT_ROOT >> 12)) : "memory");
    ok &= run_case("sv39-u-on-s-page", 0, (unsigned long) &g_ddr_word);
    __asm__ volatile("csrw satp, zero\n sfence.vma" ::: "memory");

    uart_puts(ok ? "\r\n<<PASS>>\r\n" : "\r\n<<FAIL>>\r\n");
    for (;;) {
    }
    return 0;
}
