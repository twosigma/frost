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
 * identical PTEs for its 64 KiB hugetlb pages.
 *
 *   A  A 64 KiB NAPOT range (16 identical PTEs) over a 64 KiB frame: every
 *      page reads and writes its own 4 KiB frame (loads, stores, AMOs), in S
 *      (MPRV, MPP = S) and in U (MPRV, MPP = U on a U range); code fetched
 *      from a NAPOT page executes.
 *   B  One S-mode sequence fills the range, evicts its DTLB entries, and
 *      checks that sixteen repeat DTLB misses leave the walker idle.
 *   C  All fifteen reserved level-0 N encodings are page faults (mtval = VA),
 *      as are N in a 2 MiB or 1 GiB leaf and N in a pointer.
 *   D  Remapping the range (invalidate the 16 PTEs, sfence.vma for each of
 *      its pages, write a new NAPOT range) is seen on every page.
 *   E  A store to a NAPOT page with D = 0 is a store page fault, a load with
 *      A = 0 a load page fault (Svade: A/D are never set by hardware).
 *   F  Split data accesses and instruction fetch cross a 4 KiB boundary;
 *      an upper-page fault reports that page and a store changes no bytes.
 *   G  NC and IO NAPOT leaves use the substituted physical page under PBMTE.
 */

#include <stdint.h>

#include "trap.h"
#include "uart.h"

#define CAUSE_FETCH_ACCESS 1ul
#define CAUSE_LOAD_ACCESS 5ul
#define CAUSE_STORE_ACCESS 7ul
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
#define PTE_NC (1ul << 61)
#define PTE_IO (2ul << 61)
#define MENVCFG_PBMTE (1ul << 62)
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
 * 32..47 range X (executable), 80.. reserved N, 128..143 and 256..271 plain
 * fill pages aliasing sets 0..15 of the 2-way 128-set DMMU S1 cache. */
#define VA_L0 0x00400000ul
#define VA_PAGE(slot) (VA_L0 + ((unsigned long) (slot) << 12))
#define SLOT_A 0
#define SLOT_U 16
#define SLOT_X 32
#define SLOT_FILL0 128
#define SLOT_FILL1 256
#define FILLS 16
#define SLOT_BAD 80
#define SLOT_D0 96
#define SLOT_A0 97
#define SLOT_PBMT 112
#define VA_MEGA_N 0x00600000ul /* l1[3]: a 2 MiB leaf with N */
#define VA_GIGA_N 0x40003000ul
#define VA_ROOT_N 0xc0000008ul
#define VA_PTR_N 0x00800000ul /* l1[4]: a pointer with N */

enum kind { K_LD = 0, K_SD = 1, K_AMO = 2 };

static volatile unsigned long g_cause;
static volatile unsigned long g_tval;
static volatile unsigned long g_l2_counts[2];
static volatile unsigned long g_remap_pte;

/* Fill sixteen NAPOT pages, evict both the 16-entry DTLB and both ways of
 * sets 0..15 in the 128-set S1 cache, then read the NAPOT pages again so
 * all sixteen hit in the L2 TLB. No privilege or translation-control write
 * separates the passes. Unrolled accesses keep loop-exit speculation out of
 * the counters. The first measured address depends on the counter read. */
__attribute__((naked, aligned(4))) static void napot_l2_body(void)
{
    __asm__ volatile("li t4, 0x400200\n"
                     "li t6, 4096\n"
                     ".rept 16\n"
                     "ld a0, 0(t4)\n"
                     "add t4, t4, t6\n"
                     ".endr\n"
                     "li t4, 0x480000\n"
                     ".rept 16\n"
                     "ld a0, 0(t4)\n"
                     "add t4, t4, t6\n"
                     ".endr\n"
                     "li t4, 0x500000\n"
                     ".rept 16\n"
                     "ld a0, 0(t4)\n"
                     "add t4, t4, t6\n"
                     ".endr\n"
                     "csrr a2, 0xc06\n"
                     "csrr a3, 0xc08\n"
                     "andi t4, a3, 0\n"
                     "li t5, 0x400200\n"
                     "add t4, t4, t5\n"
                     "li a0, 0\n"
                     ".rept 16\n"
                     "ld a1, 0(t4)\n"
                     "add a0, a0, a1\n"
                     "add t4, t4, t6\n"
                     ".endr\n"
                     "csrr t4, 0xc06\n"
                     "csrr t5, 0xc08\n"
                     "sub a1, t4, a2\n"
                     "sub a2, t5, a3\n"
                     "ecall\n");
}

/* Keep translations live while replacing the range's PTEs in S-mode. */
__attribute__((naked, aligned(4))) static void napot_remap_body(void)
{
    __asm__ volatile("li t4, 0x400200\n"
                     "li t5, 16\n"
                     "li t6, 4096\n"
                     "1: ld a0, 0(t4)\n"
                     "add t4, t4, t6\n"
                     "addi t5, t5, -1\n"
                     "bnez t5, 1b\n"
                     "li a2, 0x81002000\n"
                     "li t5, 16\n"
                     "2: sd zero, 0(a2)\n"
                     "addi a2, a2, 8\n"
                     "addi t5, t5, -1\n"
                     "bnez t5, 2b\n"
                     "fence rw, rw\n"
                     "li t4, 0x400000\n"
                     "li t5, 16\n"
                     "3: sfence.vma t4, zero\n"
                     "add t4, t4, t6\n"
                     "addi t5, t5, -1\n"
                     "bnez t5, 3b\n"
                     "la a3, g_remap_pte\n"
                     "ld a3, 0(a3)\n"
                     "li a2, 0x81002000\n"
                     "li t5, 16\n"
                     "4: sd a3, 0(a2)\n"
                     "addi a2, a2, 8\n"
                     "addi t5, t5, -1\n"
                     "bnez t5, 4b\n"
                     "fence rw, rw\n"
                     "li t4, 0x400200\n"
                     "li t5, 16\n"
                     "li a0, 0\n"
                     "5: ld a1, 0(t4)\n"
                     "add a0, a0, a1\n"
                     "add t4, t4, t6\n"
                     "addi t5, t5, -1\n"
                     "bnez t5, 5b\n"
                     "ecall\n");
}

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
 * ecall (cause 9); returns a0. Counter results travel in a1/a2 so their
 * output stores cannot introduce a translation inside the measured region. */
static unsigned long run_s(unsigned long pc)
{
    unsigned long a0, count0, count1;
    g_cause = NO_TRAP;
    g_tval = NO_TRAP;
    __asm__ volatile(
        "la   t0, 1f\n"
        "csrw mscratch, t0\n"
        "li   t0, 0x1800\n"
        "csrc mstatus, t0\n"
        "li   t0, 0x0800\n"
        "csrs mstatus, t0\n"
        "li   a0, 0\n"
        "csrw mepc, %3\n"
        "mret\n"
        "1:\n"
        "mv   %0, a0\n"
        "mv   %1, a1\n"
        "mv   %2, a2\n"
        : "=r"(a0), "=r"(count0), "=r"(count1)
        : "r"(pc)
        : "t0", "t1", "t2", "t3", "t4", "t5", "t6", "a0", "a1", "a2", "a3", "a4", "memory");
    g_l2_counts[0] = count0;
    g_l2_counts[1] = count1;
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
    root[1] = PTE_PPN(0x80000000ul) | RWAD | PTE_N;
    root[2] = PTE_PPN(0x80000000ul) | RWAD | PTE_X;
    root[3] = PTE_PPN(PT_L1) | PTE_V | PTE_N;
    l1[0] = RWAD | PTE_X;
    l1[2] = PTE_PPN(PT_L0) | PTE_V;
    l1[3] = PTE_PPN(0x81200000ul) | RWAD | PTE_N;
    l1[4] = PTE_PPN(PT_L0_BAD) | PTE_V | PTE_N;
    l0_bad[0] = PTE_PPN(FILL_FRAME) | RWAD;
    map_range(SLOT_A, RANGE_A, RWAD);
    map_range(SLOT_U, RANGE_U, RWAD | PTE_U);
    map_range(SLOT_X, RANGE_X, RWAD | PTE_X);
    for (int i = 0; i < FILLS; i++) {
        l0[SLOT_FILL0 + i] = PTE_PPN(FILL_FRAME + ((unsigned long) i << 12)) | RWAD;
        l0[SLOT_FILL1 + i] = PTE_PPN(FILL_FRAME + ((unsigned long) i << 12)) | RWAD;
    }
    /* Every PPN[3:0] value except 1000 is reserved with N set. */
    for (int i = 0; i < 16; i++)
        if (i != 8)
            l0[SLOT_BAD + i] = PTE_PPN(RANGE_B) | ((unsigned long) i << 10) | PTE_N | RWAD | PTE_X;
    l0[SLOT_D0] = NAPOT_PTE(RANGE_B, PTE_V | PTE_R | PTE_W | PTE_A);
    l0[SLOT_A0] = NAPOT_PTE(RANGE_B, PTE_V | PTE_R | PTE_W | PTE_X);
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

    /* B: stay in S throughout the fill, eviction and repeat passes. */
    for (int i = 0; i < 16; i++)
        *(volatile uint64_t *) (RANGE_A + ((unsigned long) i << 12) + 0x200) = 0x100 + i;
    csr_write_imm(0x326, 6);
    csr_write_imm(0x328, 16);
    csr_write_imm(0x320, 0);
    csr_write_imm(0x306, 0x1ff);
    __asm__ volatile("fence rw, rw" ::: "memory");
    unsigned long sum = run_s((unsigned long) napot_l2_body);
    report(g_cause == CAUSE_ECALL_S && sum == 16 * 0x100 + 120, "B l2-values", VA_L0);
    report(g_l2_counts[0] == 16 && g_l2_counts[1] == 0, "B l2-residency", VA_L0);
    uart_printf("NAPOT L2 dtlb_misses=%lu walker_busy=%lu\r\n", g_l2_counts[0], g_l2_counts[1]);

    /* C: reserved N encodings. */
    for (int i = 0; i < 16; i++) {
        if (i == 8)
            continue;
        unsigned long va = VA_PAGE(SLOT_BAD + i) + 0x20;
        access(1, K_LD, va, 0);
        expect_trap("C reserved-n-load", va, CAUSE_LOAD_PAGE);
        access(1, K_SD, va, 0);
        expect_trap("C reserved-n-store", va, CAUSE_STORE_PAGE);
        run_s(va);
        expect_trap("C reserved-n-fetch", va, CAUSE_FETCH_PAGE);
    }
    access(1, K_LD, VA_MEGA_N + 0x3000, 0);
    expect_trap("C n-in-2m-leaf", VA_MEGA_N + 0x3000, CAUSE_LOAD_PAGE);
    access(1, K_LD, VA_GIGA_N, 0);
    expect_trap("C n-in-1g-leaf", VA_GIGA_N, CAUSE_LOAD_PAGE);
    access(1, K_LD, VA_ROOT_N, 0);
    expect_trap("C n-in-root-pointer", VA_ROOT_N, CAUSE_LOAD_PAGE);
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
    map_range(SLOT_A, RANGE_A, RWAD);
    for (int i = 0; i < 16; i++)
        *(volatile uint64_t *) (RANGE_B + ((unsigned long) i << 12) + 0x200) = 0x200 + i;
    g_remap_pte = NAPOT_PTE(RANGE_B, RWAD);
    __asm__ volatile("fence rw, rw" ::: "memory");
    sum = run_s((unsigned long) napot_remap_body);
    report(g_cause == CAUSE_ECALL_S && sum == 16 * 0x200 + 120, "D live-remap", VA_L0);
    check_range("D remapped", 1, SLOT_A, RANGE_B, 0xD000000000000001ul);

    /* E: Svade on a NAPOT page. */
    {
        unsigned long va = VA_PAGE(SLOT_D0) + 0x30;
        /* The translated page takes its low PPN bits from the VA. */
        unsigned long pa = RANGE_B + ((unsigned long) (SLOT_D0 & 15) << 12) + 0x30;
        expect_value("E d0-load", va, access(1, K_LD, va, 0), *(volatile uint64_t *) pa);
        access(1, K_SD, va, 1);
        expect_trap("E d0-store", va, CAUSE_STORE_PAGE);
        access(1, K_AMO, va, 1);
        expect_trap("E d0-amo", va, CAUSE_STORE_PAGE);
        report(!(l0[SLOT_D0] & PTE_D), "E d-unchanged", va);
        va = VA_PAGE(SLOT_A0) + 0x30;
        access(1, K_LD, va, 0);
        expect_trap("E a0-load", va, CAUSE_LOAD_PAGE);
        run_s(va);
        expect_trap("E a0-fetch", va, CAUSE_FETCH_PAGE);
        report(!(l0[SLOT_A0] & (PTE_A | PTE_D)), "E ad-unchanged", va);
    }

    /* F: every interior page boundary of the remapped range. */
    for (int page = 1; page < 16; page++) {
        unsigned long va = VA_PAGE(page) - 3;
        volatile uint64_t *words =
            (volatile uint64_t *) (RANGE_B + ((unsigned long) page << 12) - 8);
        words[0] = 0x7766554433221100ul;
        words[1] = 0xffeeddccbbaa9988ul;
        expect_value("F split-load", va, access(1, K_LD, va, 0), 0xccbbaa9988776655ul);
        access(1, K_SD, va, 0x0123456789abcdeful);
        expect_value("F split-store-low", va, words[0], 0xabcdef4433221100ul);
        expect_value("F split-store-high", va, words[1], 0xffeedd0123456789ul);
    }
    {
        unsigned long va = VA_PAGE(15) - 3;
        volatile uint64_t *low = (volatile uint64_t *) (RANGE_B + (15ul << 12) - 8);
        unsigned long before = *low;
        l0[15] = 0;
        __asm__ volatile("sfence.vma %0, zero" ::"r"(VA_PAGE(15)) : "memory");
        access(1, K_LD, va, 0);
        expect_trap("F split-load-upper-fault", VA_PAGE(15), CAUSE_LOAD_PAGE);
        access(1, K_SD, va, 0);
        expect_trap("F split-store-upper-fault", VA_PAGE(15), CAUSE_STORE_PAGE);
        report(*low == before, "F split-fault-no-store", va);
        l0[15] = NAPOT_PTE(RANGE_B, RWAD);
        __asm__ volatile("sfence.vma %0, zero" ::"r"(VA_PAGE(15)) : "memory");
    }
    {
        unsigned long pc = VA_PAGE(SLOT_X + 7) + 0xffe;
        volatile uint16_t *code = (volatile uint16_t *) (RANGE_X + (7ul << 12) + 0xffe);
        code[0] = 0x1537;
        code[1] = 0;
        code[2] = 0x0513;
        code[3] = 0x2345;
        code[4] = 0x0073;
        code[5] = 0;
        __asm__ volatile("fence.i" ::: "memory");
        unsigned long value = run_s(pc);
        report(g_cause == CAUSE_ECALL_S && value == 0x1234, "F split-fetch", pc);
        l0[SLOT_X + 8] = 0;
        __asm__ volatile("sfence.vma %0, zero" ::"r"(VA_PAGE(SLOT_X + 8)) : "memory");
        run_s(pc);
        expect_trap("F split-fetch-upper-fault", VA_PAGE(SLOT_X + 8), CAUSE_FETCH_PAGE);
        l0[SLOT_X + 8] = NAPOT_PTE(RANGE_X, RWAD | PTE_X);
        __asm__ volatile("sfence.vma %0, zero" ::"r"(VA_PAGE(SLOT_X + 8)) : "memory");
    }

    /* G: PBMT is applied after the NAPOT PPN substitution. */
    map_range(SLOT_PBMT, RANGE_A, RWAD | PTE_NC);
    __asm__ volatile("csrc menvcfg, %0\n sfence.vma" ::"r"(MENVCFG_PBMTE) : "memory");
    access(1, K_LD, VA_PAGE(SLOT_PBMT + 7), 0);
    expect_trap("G pbmte-off", VA_PAGE(SLOT_PBMT + 7), CAUSE_LOAD_PAGE);
    __asm__ volatile("csrs menvcfg, %0\n sfence.vma" ::"r"(MENVCFG_PBMTE) : "memory");
    for (int kind = 0; kind < 2; kind++) {
        map_range(SLOT_PBMT, RANGE_A, RWAD | PTE_X | (kind ? PTE_IO : PTE_NC));
        __asm__ volatile("sfence.vma" ::: "memory");
        const int pages[] = {0, 7, 15};
        for (int p = 0; p < 3; p++) {
            unsigned long va = VA_PAGE(SLOT_PBMT + pages[p]) + 0x180;
            volatile uint64_t *pa =
                (volatile uint64_t *) (RANGE_A + ((unsigned long) pages[p] << 12) + 0x180);
            *pa = 0x7000 + pages[p];
            __asm__ volatile(
                "fence iorw, iorw\n .insn i 0x0f, 2, x0, %0, 2\n fence iorw, iorw" ::"r"(pa)
                : "memory");
            expect_value("G alias-load", va, access(1, K_LD, va, 0), 0x7000 + pages[p]);
            access(1, K_SD, va, 0x8000 + pages[p]);
            __asm__ volatile("fence iorw, iorw" ::: "memory");
            expect_value("G alias-store", va, *pa, 0x8000 + pages[p]);
            access(1, K_AMO, va, 1);
            expect_trap("G alias-amo-fault", va, CAUSE_STORE_ACCESS);
            run_s(va);
            expect_trap("G alias-fetch-fault", va, CAUSE_FETCH_ACCESS);
            access(1, K_LD, va + 1, 0);
            expect_trap("G alias-split-load-fault", va + 1, CAUSE_LOAD_ACCESS);
            access(1, K_SD, va + 1, 0);
            expect_trap("G alias-split-store-fault", va + 1, CAUSE_STORE_ACCESS);
            report(*pa == 0x8000ul + pages[p], "G alias-split-no-store", va + 1);
        }
    }
    __asm__ volatile("csrw satp, zero\n sfence.vma");
    uart_printf("\r\npasses=%d failures=%d\r\n", g_passes, g_fails);
    uart_puts(g_fails == 0 ? "\r\n<<PASS>>\r\n" : "\r\n<<FAIL>>\r\n");
    for (;;) {
    }
    return 0;
}
