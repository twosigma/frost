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
 * Page clearing with cbo.zero as Linux 6.12 does it, in S-mode under Sv39.
 *
 * clear_page (arch/riscv/lib/clear_page.S with a 64-byte block) is an
 * unrolled loop of sixteen cbo.zero instructions per iteration, four
 * iterations per 4 KiB page. Here it runs from cached DDR, fetched through
 * the L1I as kernel text is. Each page is reached through either a 1 GiB
 * linear-map alias or 4 KiB page tables, so data translation walks page
 * tables in cached DDR while cbo.zero blocks are in flight.
 *
 * Pages are chosen at 1 MiB strides, the way span of a 4 MiB 4-way L2, so
 * successive clears of the same sets evict Modified zero lines and their
 * write-backs race new zero fills. Before a clear, some pages are dirtied
 * with stores (a page in prior use); right after it, freelist-style stores
 * land in the zeroed blocks and a metadata array is updated, as the slab
 * allocator does after kernel_init_pages. Every block is then checked by a
 * load. A second pass clears the same pages warm, in a different order.
 *
 * Build knobs: CBO_PAGES_ALIAS (pages per set group, default 8),
 * CBO_PAGES_ROUNDS (default 16), CBO_PAGES_PASSES (default 2) and
 * CBO_PAGES_MMODE (1 runs the same work in M-mode without translation).
 */

#include <stdint.h>

#include "trap.h"
#include "uart.h"

#ifndef CBO_PAGES_ALIAS
#define CBO_PAGES_ALIAS 8
#endif
#ifndef CBO_PAGES_ROUNDS
#define CBO_PAGES_ROUNDS 16
#endif
#ifndef CBO_PAGES_PASSES
#define CBO_PAGES_PASSES 2
#endif
#ifndef CBO_PAGES_MMODE
#define CBO_PAGES_MMODE 0
#endif

/* Freelist object size: 256 stores into lower sectors only, 32 into both. */
#ifndef CBO_PAGES_OBJ
#define CBO_PAGES_OBJ 256ul
#endif
#ifndef CBO_PAGES_PT_PAGES
#define CBO_PAGES_PT_PAGES 16
#endif
#define PT_DYN 0x81400000ul

#define PAGE 4096ul
#define BLOCK 64ul
#define WAY_SPAN (1ul << 20)
#define DATA_BASE 0x82000000ul
#define META_BASE 0x83000000ul
#define DIRTY_PATTERN 0x5EEDF00DCAFE0000ul

#define CAUSE_ECALL_S 9ul
#define CAUSE_ECALL_M 11ul

/* Sv39 tables in cached DDR. */
#define PT_ROOT 0x81000000ul
#define PT_L1 0x81001000ul
#define PT_L0 0x81002000ul /* four tables: 8 MiB of 4 KiB pages from DATA_BASE */
#define PTE_V (1ul << 0)
#define PTE_R (1ul << 1)
#define PTE_W (1ul << 2)
#define PTE_X (1ul << 3)
#define PTE_G (1ul << 5)
#define PTE_A (1ul << 6)
#define PTE_D (1ul << 7)
#define PTE_PPN(pa) ((((unsigned long) (pa)) >> 12) << 10)
#define SATP_SV39 (8ul << 60)
#define VA_LINEAR 0xFFFFFFD800000000ul /* + (pa - 0x80000000): 1 GiB leaf */
#define VA_PAGED 0xFFFFFFC000000000ul  /* + (pa - 0x80000000): 4 KiB leaves */
#define VA_MEGA 0xFFFFFFE000000000ul   /* + (pa - 0x80000000): 2 MiB leaves */
#define PT_L1M 0x81006000ul

static volatile unsigned long g_cause;
static volatile unsigned long g_tval;
static volatile unsigned long g_epc;
static volatile unsigned long g_errors;
static volatile unsigned long g_first_bad;
static volatile unsigned long g_pages;
unsigned long g_saved_regs[2];

/* clear_page as Linux 6.12 patches it for a 64-byte block: the order 11, 10,
 * 9 and 8 early exits become nop pairs, leaving sixteen cbo.zero per
 * iteration. a0 = page, a1 = block size. It runs from cached DDR, so it is
 * reached through an absolute pointer. */
__attribute__((naked, section(".ddr_text"), aligned(64))) static void clear_page_ddr(void)
{
    __asm__ volatile(".option push\n"
                     ".option norvc\n"
                     "li   a2, 4096\n"
                     "nop\n"
                     "add  a2, a0, a2\n"
                     "1:\n"
                     ".insn i 0x0F, 2, x0, a0, 4\n"
                     "add  a0, a0, a1\n"
                     "nop\n nop\n"
                     ".insn i 0x0F, 2, x0, a0, 4\n"
                     "add  a0, a0, a1\n"
                     "nop\n nop\n"
                     ".insn i 0x0F, 2, x0, a0, 4\n"
                     "add  a0, a0, a1\n"
                     ".insn i 0x0F, 2, x0, a0, 4\n"
                     "add  a0, a0, a1\n"
                     "nop\n nop\n"
                     ".insn i 0x0F, 2, x0, a0, 4\n"
                     "add  a0, a0, a1\n"
                     ".insn i 0x0F, 2, x0, a0, 4\n"
                     "add  a0, a0, a1\n"
                     ".insn i 0x0F, 2, x0, a0, 4\n"
                     "add  a0, a0, a1\n"
                     ".insn i 0x0F, 2, x0, a0, 4\n"
                     "add  a0, a0, a1\n"
                     "nop\n nop\n"
                     ".insn i 0x0F, 2, x0, a0, 4\n"
                     "add  a0, a0, a1\n"
                     ".insn i 0x0F, 2, x0, a0, 4\n"
                     "add  a0, a0, a1\n"
                     ".insn i 0x0F, 2, x0, a0, 4\n"
                     "add  a0, a0, a1\n"
                     ".insn i 0x0F, 2, x0, a0, 4\n"
                     "add  a0, a0, a1\n"
                     ".insn i 0x0F, 2, x0, a0, 4\n"
                     "add  a0, a0, a1\n"
                     ".insn i 0x0F, 2, x0, a0, 4\n"
                     "add  a0, a0, a1\n"
                     ".insn i 0x0F, 2, x0, a0, 4\n"
                     "add  a0, a0, a1\n"
                     ".insn i 0x0F, 2, x0, a0, 4\n"
                     "add  a0, a0, a1\n"
                     "bltu a0, a2, 1b\n"
                     "ret\n"
                     ".option pop\n");
}

/* Absolute address: pc-relative forms cannot reach DDR from low BRAM. */
static void (*volatile const g_clear_page)(void) = clear_page_ddr;

static inline void clear_page(unsigned long va)
{
    register unsigned long a0 __asm__("a0") = va;
    register unsigned long a1 __asm__("a1") = BLOCK;
    register void (*fn)(void) = g_clear_page;
    __asm__ volatile("jalr ra, 0(%[fn])"
                     : "+r"(a0), "+r"(a1)
                     : [fn] "r"(fn)
                     : "ra", "a2", "memory");
}

static unsigned long page_pa(unsigned pass, unsigned round, unsigned group)
{
    /* The second pass walks the groups backwards and the rounds rotated. */
    if (pass & 1) {
        group = CBO_PAGES_ALIAS - 1u - group;
        round = (round + 5u) % CBO_PAGES_ROUNDS;
    }
    return DATA_BASE + (unsigned long) group * WAY_SPAN + (unsigned long) round * PAGE;
}

static unsigned long to_va(unsigned long pa, unsigned which)
{
#if CBO_PAGES_MMODE
    (void) which;
    return pa;
#else
    return (which == 2 ? VA_MEGA : which ? VA_PAGED : VA_LINEAR) + (pa - 0x80000000ul);
#endif
}

#ifndef CBO_PAGES_THRASH
#define CBO_PAGES_THRASH 0
#endif
#if CBO_PAGES_THRASH
#define THRASH_BASE 0x83400000ul
static volatile unsigned long g_sink;

/* A line in the L1D set of the page block's upper sector (32 KiB way span),
 * in thrash region k (each region is another tag of the same sets). */
static volatile unsigned long *thrash_line(unsigned long pa, unsigned long k, unsigned long blk)
{
    return (volatile unsigned long *) to_va(
        THRASH_BASE + k * 0x8000ul + (pa & 0x7FFFul) + blk * BLOCK + 32, 0);
}
#endif

static void note_error(unsigned long va)
{
    if (g_errors == 0)
        g_first_bad = va;
    g_errors = g_errors + 1;
}

/* The workload: runs in S (translated) or, with CBO_PAGES_MMODE, in M. */
static void workload(void)
{
    volatile unsigned long *meta = (volatile unsigned long *) to_va(META_BASE, 0);
    unsigned long count = 0;
    for (unsigned pass = 0; pass < CBO_PAGES_PASSES; pass++) {
        for (unsigned round = 0; round < CBO_PAGES_ROUNDS; round++) {
            for (unsigned group = 0; group < CBO_PAGES_ALIAS; group++) {
                unsigned long pa = page_pa(pass, round, group);
                unsigned long va = to_va(pa, (round + group + pass) % 3u);
                volatile unsigned long *p = (volatile unsigned long *) va;
                /* A page in prior use: dirty lines in both sectors of some blocks. */
                if ((round + group) % 3u != 0u) {
                    p[0] = DIRTY_PATTERN | count;
                    p[7 * 8 + 5] = DIRTY_PATTERN | count;
                    p[2048 / 8] = DIRTY_PATTERN | count;
                    p[4088 / 8] = DIRTY_PATTERN | count;
                }
#if CBO_PAGES_THRASH
                /* Upper sectors Modified and least recently used in the L1D, so
                 * that loads right behind clear_page evict them while each
                 * block's lower record and twin are still in flight. */
                for (unsigned long blk = 0; blk < PAGE / BLOCK; blk++)
                    p[blk * 8 + 4] = DIRTY_PATTERN | blk;
                for (unsigned long k = 0; k < 3; k++)
                    for (unsigned long blk = 0; blk < PAGE / BLOCK; blk++)
                        g_sink += *thrash_line(pa, k, blk);
#endif
                clear_page(va);
#if CBO_PAGES_THRASH
                for (unsigned long blk = 0; blk < PAGE / BLOCK; blk++)
                    g_sink += *thrash_line(pa, 3, blk);
#endif
                /* Freelist stores into the zeroed page and a metadata update. */
                for (unsigned long obj = 0; obj < PAGE; obj += CBO_PAGES_OBJ)
                    p[obj / 8] = va + obj + CBO_PAGES_OBJ;
                meta[count & 511u] = pa | 1u;
                /* One load per block, at a dword the freelist leaves zero. */
                for (unsigned long blk = 0; blk < PAGE / BLOCK; blk++) {
                    unsigned long index = blk * 8 + 1 + (blk % 7);
                    if ((index * 8) % CBO_PAGES_OBJ == 0)
                        index--; /* a freelist slot: check the dword before it */
                    if (p[index] != 0)
                        note_error(va + index * 8);
                }
                for (unsigned long obj = 0; obj < PAGE; obj += CBO_PAGES_OBJ)
                    if (p[obj / 8] != va + obj + CBO_PAGES_OBJ)
                        note_error(va + obj);
                count++;
                g_pages = count;
            }
            uart_putchar(pass ? 'w' : 'c'); /* progress: one mark per round */
        }
        __asm__ volatile("sfence.vma" ::: "memory");
    }
#if !CBO_PAGES_MMODE
    /* Page-table pages as pte_alloc makes them: clear a fresh page through the
     * linear map, write leaf PTEs into it, link it into the L1 table and use
     * the mapping at once. The walker then reads lines that cbo.zero just
     * zeroed, beside lines of the same page still in flight. */
    volatile unsigned long *l1 = (volatile unsigned long *) to_va(PT_L1, 0);
    unsigned long first = ((DATA_BASE - 0x80000000ul) >> 21) & 0x1FF;
    for (unsigned long i = 0; i < CBO_PAGES_PT_PAGES; i++) {
        unsigned long slot = first + 4 + (i % 8);
        unsigned long table_pa = PT_DYN + i * PAGE;
        volatile unsigned long *table = (volatile unsigned long *) to_va(table_pa, 0);
        clear_page((unsigned long) table);
        for (unsigned long e = 0; e < 8; e++)
            table[e * 64 + (i % 8)] = PTE_PPN(DATA_BASE + ((i * 8 + e) % 2048) * PAGE) | PTE_V |
                                      PTE_R | PTE_W | PTE_A | PTE_D | PTE_G;
        __asm__ volatile("fence rw, rw" ::: "memory");
        l1[slot] = PTE_PPN(table_pa) | PTE_V;
        __asm__ volatile("sfence.vma" ::: "memory");
        for (unsigned long e = 0; e < 8; e++) {
            unsigned long va = VA_PAGED + ((slot << 21) | ((e * 64 + (i % 8)) << 12));
            volatile unsigned long *p = (volatile unsigned long *) va;
            clear_page(va);
            p[3] = va;
            if (p[3] != va || p[9] != 0)
                note_error(va);
        }
        g_pages = g_pages + 1;
        uart_putchar('t');
    }
    __asm__ volatile("sfence.vma" ::: "memory");
#endif
}

__attribute__((naked, aligned(4))) static void bounce_handler(void)
{
    __asm__ volatile("csrr t0, mcause\n"
                     "la   t1, g_cause\n"
                     "sd   t0, 0(t1)\n"
                     "csrr t0, mtval\n"
                     "la   t1, g_tval\n"
                     "sd   t0, 0(t1)\n"
                     "csrr t0, mepc\n"
                     "la   t1, g_epc\n"
                     "sd   t0, 0(t1)\n"
                     "csrr t0, mscratch\n"
                     "csrw mepc, t0\n"
                     "li   t0, 0x1800\n"
                     "csrs mstatus, t0\n"
                     "mret\n");
}

__attribute__((noinline)) static void s_entry(void)
{
    /* Linux 6.12 riscv_user_isa_enable: senvcfg.CBZE for user mode. */
    __asm__ volatile("csrs 0x10A, %0" : : "r"(1ul << 7));
    workload();
    __asm__ volatile("ecall");
    for (;;) {
    }
}

static void build_tables(void)
{
    volatile unsigned long *root = (volatile unsigned long *) PT_ROOT;
    volatile unsigned long *l1 = (volatile unsigned long *) PT_L1;
    volatile unsigned long *l0 = (volatile unsigned long *) PT_L0;
    const unsigned long leaf = PTE_V | PTE_R | PTE_W | PTE_A | PTE_D | PTE_G;
    for (int i = 0; i < 512; i++) {
        root[i] = 0;
        l1[i] = 0;
    }
    root[0] = PTE_PPN(0x00000000ul) | leaf | PTE_X; /* low BRAM: code, data, stack */
    root[1] = PTE_PPN(0x40000000ul) | leaf;         /* devices: UART */
    root[2] = PTE_PPN(0x80000000ul) | leaf | PTE_X; /* DDR identity: the DDR text */
    root[(VA_LINEAR >> 30) & 0x1FF] = PTE_PPN(0x80000000ul) | leaf;
    root[(VA_PAGED >> 30) & 0x1FF] = PTE_PPN(PT_L1) | PTE_V;
    /* 2 MiB leaves over the first GiB of DDR, as Linux maps the linear map
     * below the first 1 GiB boundary after OpenSBI's reserved 2 MiB. */
    volatile unsigned long *l1m = (volatile unsigned long *) PT_L1M;
    for (unsigned long i = 0; i < 512; i++)
        l1m[i] = PTE_PPN(0x80000000ul + (i << 21)) | leaf;
    root[(VA_MEGA >> 30) & 0x1FF] = PTE_PPN(PT_L1M) | PTE_V;
    unsigned long first = ((DATA_BASE - 0x80000000ul) >> 21) & 0x1FF;
    for (unsigned long t = 0; t < 4; t++) {
        l1[first + t] = PTE_PPN(PT_L0 + t * PAGE) | PTE_V;
        for (unsigned long i = 0; i < 512; i++)
            l0[t * 512 + i] = PTE_PPN(DATA_BASE + (t * 512 + i) * PAGE) | leaf;
    }
    __asm__ volatile("fence rw, rw" ::: "memory");
}

int main(void)
{
    uart_puts("\r\n=== cbo.zero page clearing ===\r\n");
    uart_printf("alias %d rounds %d passes %d mmode %d\r\n",
                CBO_PAGES_ALIAS,
                CBO_PAGES_ROUNDS,
                CBO_PAGES_PASSES,
                CBO_PAGES_MMODE);
    set_trap_handler(&bounce_handler);
    csr_write(medeleg, 0);
    g_cause = ~0ul;
    g_errors = 0;
    g_pages = 0;
#if CBO_PAGES_MMODE
    workload();
    g_cause = CAUSE_ECALL_S;
#else
    build_tables();
    __asm__ volatile("csrw 0x30A, %0" : : "r"(1ul << 7)); /* menvcfg.CBZE */
    __asm__ volatile("csrw satp, %0\n sfence.vma" : : "r"(SATP_SV39 | (PT_ROOT >> 12)));
    /* S never returns: the trap comes back to the continuation, which
     * restores sp and s0; the other callee-saved registers are clobbered. */
    __asm__ volatile(
        "la   t0, g_saved_regs\n"
        "sd   sp, 0(t0)\n"
        "sd   s0, 8(t0)\n"
        "la   t0, 1f\n"
        "csrw mscratch, t0\n"
        "li   t0, 0x1800\n"
        "csrc mstatus, t0\n"
        "li   t0, 0x0800\n"
        "csrs mstatus, t0\n"
        "csrw mepc, %0\n"
        "mret\n"
        ".balign 4\n"
        "1:\n"
        "la   t0, g_saved_regs\n"
        "ld   sp, 0(t0)\n"
        "ld   s0, 8(t0)\n"
        :
        : "r"((unsigned long) &s_entry)
        : "t0", "ra", "s1", "s2", "s3", "s4", "s5", "s6", "s7", "s8", "s9", "s10", "s11", "memory");
    __asm__ volatile("csrw satp, zero\n sfence.vma");
#endif
    uart_printf("pages %lu errors %lu first_bad 0x%016lx\r\n", g_pages, g_errors, g_first_bad);
    uart_printf("cause 0x%lx tval 0x%016lx epc 0x%016lx\r\n", g_cause, g_tval, g_epc);
    int ok = g_cause == CAUSE_ECALL_S && g_errors == 0 &&
             g_pages == (unsigned long) CBO_PAGES_ALIAS * CBO_PAGES_ROUNDS * CBO_PAGES_PASSES +
                            (CBO_PAGES_MMODE ? 0ul : CBO_PAGES_PT_PAGES);
    uart_puts(ok ? "\r\n<<PASS>>\r\n" : "\r\n<<FAIL>>\r\n");
    for (;;) {
    }
    return 0;
}
