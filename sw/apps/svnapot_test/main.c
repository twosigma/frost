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
 * Svnapot directed test. A level-0 leaf PTE with N (bit 63) set and
 * PPN[3:0] = 1000 maps one page of a naturally aligned 64 KiB range: the
 * translation takes PPN[3:0] from VA[15:12]. Linux builds such a range as 16
 * identical PTEs (its 64 KiB hugetlb pages and contiguous mappings).
 *
 *   A  A 64 KiB NAPOT range (16 identical PTEs) over a 64 KiB frame: every
 *      page reads and writes its own 4 KiB frame (loads, stores, AMOs), in S
 *      (MPRV, MPP = S) and in U (MPRV, MPP = U on a U range); code fetched
 *      from a NAPOT page executes.
 *   B  After refilling the 16-entry DTLB, the range answers from the
 *      second-level TLB with the same frames.
 *   C  Reserved N encodings are page faults (mtval = VA): PPN[3:0] = 0001,
 *      0010, 0100, 0000; N in a 2 MiB leaf; N in a pointer.
 *   D  Remapping the range (invalidate the 16 PTEs, sfence.vma for each of
 *      its pages, write a new NAPOT range) is seen on every page.
 *   E  A store to a NAPOT page with D = 0 is a store page fault, a load with
 *      A = 0 a load page fault (Svade: A/D are never set by hardware).
 */

#include <stdint.h>

#include "trap.h"
#include "uart.h"

#define CAUSE_FETCH_PAGE 12ul
#define CAUSE_LOAD_PAGE 13ul
#define CAUSE_STORE_PAGE 15ul
#define CAUSE_ECALL_S 9ul
#define NO_TRAP (~0ul)

#define MSTATUS_MPRV (1ul << 17)
#define MSTATUS_SUM (1ul << 18)

#define PTE_V (1ul << 0)
#define PTE_R (1ul << 1)
#define PTE_W (1ul << 2)
#define PTE_X (1ul << 3)
#define PTE_U (1ul << 4)
#define PTE_A (1ul << 6)
#define PTE_D (1ul << 7)
#define PTE_N (1ul << 63)
#define PTE_PPN(pa) ((((unsigned long) (pa)) >> 12) << 10)
#define SATP_SV39 (8ul << 60)
#define RWAD (PTE_V | PTE_R | PTE_W | PTE_A | PTE_D)
/* A NAPOT PTE for the 64 KiB range at pa: PPN[3:0] = 1000. */
#define NAPOT_PTE(pa, flags) (PTE_PPN(pa) | (8ul << 10) | PTE_N | (flags))

/* Sv39 tables in cached DDR, clear of the program image. */
#define PT_ROOT 0x81000000ul
#define PT_L1 0x81001000ul
#define PT_L0 0x81002000ul
#define PT_L0_BAD 0x81003000ul
#define RANGE_A 0x81100000ul /* 64 KiB aligned frames */
#define RANGE_B 0x81110000ul
#define RANGE_U 0x81120000ul
#define RANGE_X 0x81130000ul
#define FILL_FRAME 0x81140000ul
/* VA 0x400000: l1[2] -> l0. l0 slots 0..15 range A, 16..31 range U (U pages),
 * 32..47 range X (executable), 48..71 plain fill pages, 80.. reserved N. */
#define VA_L0 0x00400000ul
#define VA_PAGE(slot) (VA_L0 + ((unsigned long) (slot) << 12))
#define SLOT_A 0
#define SLOT_U 16
#define SLOT_X 32
#define SLOT_FILL 48
#define FILLS 24
#define SLOT_BAD 80
#define VA_MEGA_N 0x00600000ul /* l1[3]: a 2 MiB leaf with N */
#define VA_PTR_N 0x00800000ul  /* l1[4]: a pointer with N */

enum kind { K_LD = 0, K_SD = 1, K_AMO = 2 };

static volatile unsigned long g_cause;
static volatile unsigned long g_tval;

__attribute__((naked, aligned(4))) static void napot_trap_handler(void)
{
    __asm__ volatile("csrr t0, mcause\n"
                     "la   t1, g_cause\n"
                     "ld   t2, 0(t1)\n"
                     "li   t3, -1\n"
                     "bne  t2, t3, 2f\n"
                     "sd   t0, 0(t1)\n"
                     "csrr t0, mtval\n"
                     "la   t1, g_tval\n"
                     "sd   t0, 0(t1)\n"
                     "2:\n"
                     "csrr t0, mscratch\n"
                     "csrw mepc, t0\n"
                     "li   t0, 0x1800\n"
                     "csrs mstatus, t0\n"
                     "mret\n");
}

/* One data access at va in M with MPRV and MPP = mpp (S = 1, U = 0). */
static unsigned long access(int mpp_s, int kind, unsigned long va, unsigned long val)
{
    unsigned long out = 0;
    unsigned long mpp = mpp_s ? 0x0800ul : 0ul;
    unsigned long bits = MSTATUS_MPRV;
    g_cause = NO_TRAP;
    g_tval = NO_TRAP;
    __asm__ volatile("la   t0, 1f\n"
                     "csrw mscratch, t0\n"
                     "li   t0, 0x1800\n"
                     "csrc mstatus, t0\n"
                     "csrs mstatus, %[mpp]\n"
                     "csrs mstatus, %[bits]\n"
                     "li   t2, 1\n"
                     "beq  %[k], t2, 11f\n"
                     "li   t2, 2\n"
                     "beq  %[k], t2, 12f\n"
                     "ld   %[out], 0(%[va])\n"
                     "j    1f\n"
                     "11: sd %[val], 0(%[va])\n"
                     "j    1f\n"
                     "12: amoadd.d %[out], %[val], (%[va])\n"
                     "1:\n"
                     "csrc mstatus, %[bits]\n"
                     : [out] "+&r"(out)
                     : [va] "r"(va),
                       [val] "r"(val),
                       [k] "r"((unsigned long) kind),
                       [mpp] "r"(mpp),
                       [bits] "r"(bits)
                     : "t0", "t1", "t2", "t3", "memory");
    return out;
}

/* Enter S at pc with translation on. The code there sets a0 and ends in
 * ecall (cause 9); returns a0. */
static unsigned long run_s(unsigned long pc)
{
    unsigned long a0;
    g_cause = NO_TRAP;
    g_tval = NO_TRAP;
    __asm__ volatile("la   t0, 1f\n"
                     "csrw mscratch, t0\n"
                     "li   t0, 0x1800\n"
                     "csrc mstatus, t0\n"
                     "li   t0, 0x0800\n"
                     "csrs mstatus, t0\n"
                     "li   a0, 0\n"
                     "csrw mepc, %1\n"
                     "mret\n"
                     "1:\n"
                     "mv   %0, a0\n"
                     : "=r"(a0)
                     : "r"(pc)
                     : "t0", "t1", "t2", "t3", "a0", "memory");
    return a0;
}

static int g_fails;
static int g_passes;

/* Failures print in full; passes are counted. */
static void report(int ok, const char *name, unsigned long va)
{
    if (ok) {
        g_passes++;
        return;
    }
    g_fails++;
    uart_puts("[FAIL] ");
    uart_puts(name);
    uart_printf(" va=0x%lx cause=0x%lx tval=0x%lx\r\n", va, g_cause, g_tval);
}

static void expect_trap(const char *name, unsigned long va, unsigned long cause)
{
    int ok = g_cause == cause && g_tval == va;
    report(ok, name, va);
}

static void expect_value(const char *name, unsigned long va, unsigned long got, unsigned long want)
{
    int ok = g_cause == NO_TRAP && got == want;
    report(ok, name, va);
    if (!ok)
        uart_printf("  got 0x%016lx want 0x%016lx\r\n", got, want);
}

static volatile unsigned long *const root = (volatile unsigned long *) PT_ROOT;
static volatile unsigned long *const l1 = (volatile unsigned long *) PT_L1;
static volatile unsigned long *const l0 = (volatile unsigned long *) PT_L0;
static volatile unsigned long *const l0_bad = (volatile unsigned long *) PT_L0_BAD;

static void map_range(int slot, unsigned long pa, unsigned long flags)
{
    for (int i = 0; i < 16; i++)
        l0[slot + i] = NAPOT_PTE(pa, flags);
    __asm__ volatile("fence rw, rw" ::: "memory");
}

static void build_tables(void)
{
    for (int i = 0; i < 512; i++) {
        root[i] = 0;
        l1[i] = 0;
        l0[i] = 0;
        l0_bad[i] = 0;
    }
    root[0] = PTE_PPN(PT_L1) | PTE_V;
    l1[2] = PTE_PPN(PT_L0) | PTE_V;
    l1[3] = PTE_PPN(0x81200000ul) | RWAD | PTE_N;
    l1[4] = PTE_PPN(PT_L0_BAD) | PTE_V | PTE_N;
    l0_bad[0] = PTE_PPN(FILL_FRAME) | RWAD;
    map_range(SLOT_A, RANGE_A, RWAD);
    map_range(SLOT_U, RANGE_U, RWAD | PTE_U);
    map_range(SLOT_X, RANGE_X, RWAD | PTE_X);
    for (int i = 0; i < FILLS; i++)
        l0[SLOT_FILL + i] = PTE_PPN(FILL_FRAME + ((unsigned long) i << 12)) | RWAD;
    /* Reserved N encodings: PPN[3:0] = 0001, 0010, 0100, 0000. */
    l0[SLOT_BAD + 0] = PTE_PPN(RANGE_B) | (1ul << 10) | PTE_N | RWAD;
    l0[SLOT_BAD + 1] = PTE_PPN(RANGE_B) | (2ul << 10) | PTE_N | RWAD;
    l0[SLOT_BAD + 2] = PTE_PPN(RANGE_B) | (4ul << 10) | PTE_N | RWAD;
    l0[SLOT_BAD + 3] = PTE_PPN(RANGE_B) | PTE_N | RWAD;
    /* NAPOT with D = 0 and with A = 0. */
    l0[SLOT_BAD + 4] = NAPOT_PTE(RANGE_B, PTE_V | PTE_R | PTE_W | PTE_A);
    l0[SLOT_BAD + 5] = NAPOT_PTE(RANGE_B, PTE_V | PTE_R | PTE_W);
    __asm__ volatile("fence rw, rw" ::: "memory");
}

/* Every page of a range reads and writes its own frame. */
static void check_range(const char *name, int mpp_s, int slot, unsigned long pa, unsigned long seed)
{
    for (int p = 0; p < 16; p++) {
        unsigned long off = 0x10ul + ((unsigned long) p * 0x48ul & 0xFF8ul);
        volatile uint64_t *frame = (volatile uint64_t *) (pa + ((unsigned long) p << 12) + off);
        unsigned long va = VA_PAGE(slot + p) + off;
        unsigned long v = seed ^ ((unsigned long) p << 48) ^ off;
        *frame = v;
        expect_value(name, va, access(mpp_s, K_LD, va, 0), v);
        access(mpp_s, K_SD, va + 8, ~v);
        expect_value(name, va + 8, frame[1], ~v);
        frame[2] = 5;
        expect_value(name, va + 16, access(mpp_s, K_AMO, va + 16, 3), 5);
        expect_value(name, va + 16, frame[2], 8);
    }
}

int main(void)
{
    uart_puts("\r\n=== Svnapot test ===\r\n");
    set_trap_handler(&napot_trap_handler);
    csr_write(medeleg, 0);
    for (unsigned long a = RANGE_A; a < FILL_FRAME + ((unsigned long) FILLS << 12); a += 8)
        *(volatile uint64_t *) a = 0;
    build_tables();
    __asm__ volatile("csrw satp, %0\n sfence.vma" : : "r"(SATP_SV39 | (PT_ROOT >> 12)));

    /* A: S-mode and U-mode ranges, and code in a NAPOT page. */
    check_range("A s-range", 1, SLOT_A, RANGE_A, 0xA000000000000001ul);
    check_range("A u-range", 0, SLOT_U, RANGE_U, 0xA000000000000002ul);
    {
        /* li a0, 0x1234 ; ecall, at page 9 of the X range. */
        volatile uint32_t *code = (volatile uint32_t *) (RANGE_X + (9ul << 12) + 0x40);
        code[0] = 0x00001537u; /* lui a0, 0x1 */
        code[1] = 0x23450513u; /* addi a0, a0, 0x234 */
        code[2] = 0x00000073u; /* ecall */
        __asm__ volatile("fence.i" ::: "memory");
        unsigned long a0 = run_s(VA_PAGE(SLOT_X + 9) + 0x40);
        int ok = g_cause == CAUSE_ECALL_S && a0 == 0x1234;
        report(ok, "A fetch-napot", VA_PAGE(SLOT_X + 9) + 0x40);
    }

    /* B: refill the DTLB, then the ranges answer from the second-level TLB. */
    for (int i = 0; i < FILLS; i++)
        access(1, K_LD, VA_PAGE(SLOT_FILL + i), 0);
    check_range("B s-range-l2tlb", 1, SLOT_A, RANGE_A, 0xB000000000000001ul);

    /* C: reserved N encodings. */
    for (int i = 0; i < 4; i++) {
        unsigned long va = VA_PAGE(SLOT_BAD + i) + 0x20;
        access(1, K_LD, va, 0);
        expect_trap("C reserved-n-load", va, CAUSE_LOAD_PAGE);
        access(1, K_SD, va, 0);
        expect_trap("C reserved-n-store", va, CAUSE_STORE_PAGE);
    }
    access(1, K_LD, VA_MEGA_N + 0x3000, 0);
    expect_trap("C n-in-2m-leaf", VA_MEGA_N + 0x3000, CAUSE_LOAD_PAGE);
    access(1, K_LD, VA_PTR_N + 0x8, 0);
    expect_trap("C n-in-pointer", VA_PTR_N + 0x8, CAUSE_LOAD_PAGE);

    /* D: remap range A to range B, the way Linux changes a NAPOT mapping:
     * invalidate, sfence.vma each page, write the new range. */
    for (int i = 0; i < 16; i++)
        l0[SLOT_A + i] = 0;
    __asm__ volatile("fence rw, rw" ::: "memory");
    for (int i = 0; i < 16; i++)
        __asm__ volatile("sfence.vma %0, zero" ::"r"(VA_PAGE(SLOT_A + i)) : "memory");
    for (int i = 0; i < 16; i++) {
        access(1, K_LD, VA_PAGE(SLOT_A + i), 0);
        expect_trap("D invalid-after-sfence", VA_PAGE(SLOT_A + i), CAUSE_LOAD_PAGE);
    }
    map_range(SLOT_A, RANGE_B, RWAD);
    check_range("D remapped", 1, SLOT_A, RANGE_B, 0xD000000000000001ul);

    /* E: Svade on a NAPOT page. */
    {
        unsigned long va = VA_PAGE(SLOT_BAD + 4) + 0x30;
        /* Slot SLOT_BAD + 4 has VPN[3:0] = 4: page 4 of range B. */
        unsigned long pa = RANGE_B + ((unsigned long) ((SLOT_BAD + 4) & 15) << 12) + 0x30;
        expect_value("E d0-load", va, access(1, K_LD, va, 0), *(volatile uint64_t *) pa);
        access(1, K_SD, va, 1);
        expect_trap("E d0-store", va, CAUSE_STORE_PAGE);
        va = VA_PAGE(SLOT_BAD + 5) + 0x30;
        access(1, K_LD, va, 0);
        expect_trap("E a0-load", va, CAUSE_LOAD_PAGE);
    }

    __asm__ volatile("csrw satp, zero\n sfence.vma");
    uart_printf("\r\npasses=%d failures=%d\r\n", g_passes, g_fails);
    uart_puts(g_fails == 0 ? "\r\n<<PASS>>\r\n" : "\r\n<<FAIL>>\r\n");
    for (;;) {
    }
    return 0;
}
