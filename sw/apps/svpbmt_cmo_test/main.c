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
 * Cache-block management through Svpbmt mappings.
 *
 * Zicbom cache-block operations ignore cacheability attributes: cbo.clean,
 * cbo.flush and cbo.inval act on the cache block irrespective of PBMT. One DDR
 * frame has three mappings: cacheable (PBMT 0), NC (1) and IO (2). Each case
 * first writes a baseline to a 64-byte line and flushes it, so DDR holds the
 * baseline, then dirties the line through the cacheable physical address (M
 * mode, so the line is Modified in the L1D), executes one CBO through one
 * view, and checks that
 *   - the CBO retires without a trap,
 *   - clean and flush write the dirty line to DDR (the CBO's sscratch window,
 *     checked by cocotb_tests/cache/cmo_ddr_watch with FROST_CMO_DDR_CHECK=1)
 *     and keep the data in every view (an NC or IO load takes the alias path
 *     into the coherent home, the cacheable load the L1D),
 *   - inval writes nothing and every view then reads the baseline (M mode
 *     performs an invalidate), or, in a CBO_INVAL_AS_FLUSH build (CBIE 11
 *     reads back 01), behaves as flush, and
 *   - a store through the IO view, then a CBO, reaches the next cacheable
 *     load (inval: the baseline).
 * A second set of blocks pairs each CBO with an immediately following load
 * across all nine combinations of the CBO and load mappings. Older integer
 * divisions delay retirement while the cache holds data newer than DDR.
 * A last pass dirties each line again and evicts it with conflicting stores;
 * those windows log the eviction's write-back.
 */

#include <stdint.h>

#include "trap.h"
#include "uart.h"

#define MENVCFG_PBMTE (1ul << 62)
#define ENVCFG_CBZE (1ul << 7)
#define NO_TRAP (~0ul)
#define MSTATUS_MPRV (1ul << 17)

#define PTE_V (1ul << 0)
#define PTE_R (1ul << 1)
#define PTE_W (1ul << 2)
#define PTE_A (1ul << 6)
#define PTE_D (1ul << 7)
#define PTE_PPN(pa) ((((unsigned long) (pa)) >> 12) << 10)
#define PTE_PBMT(v) ((unsigned long) (v) << 61)
#define SATP_SV39 (8ul << 60)
#define RWAD (PTE_V | PTE_R | PTE_W | PTE_A | PTE_D)

#define PT_ROOT 0x81000000ul
#define PT_L1 0x81001000ul
#define PT_L0 0x81002000ul
#define FRAME 0x81100000ul
#define VA_VIEW(v) (0x00400000ul + ((unsigned long) (v) << 12))

enum { VIEW_PMA = 0, VIEW_NC = 1, VIEW_IO = 2 };
static const char *const view_name[3] = {"pma", "nc", "io"};
static const char *const op_name[3] = {"inval", "clean", "flush"};

#define CBO_FLUSH_PA(pa) __asm__ volatile(".insn i 0x0F, 2, x0, %0, 2" ::"r"(pa) : "memory")
#define ENVCFG_CBIE(v) ((unsigned long) (v) << 4)

/* sscratch window for cmo_ddr_watch: marker, sequence, expectation, line PA. */
enum { EXPECT_NONE = 0, EXPECT_WRITE = 1, EXPECT_EITHER = 2 };
static unsigned int g_window;

static void open_window(int expect, unsigned long pa)
{
    unsigned long mark = (0xCB0Cul << 48) | ((unsigned long) (g_window++ & 0xff) << 40) |
                         ((unsigned long) expect << 38) | (pa & ((1ul << 36) - 1) & ~63ul);
    __asm__ volatile("fence rw, rw" ::: "memory");
    csr_write(sscratch, mark);
}

static void close_window(void)
{
    __asm__ volatile("fence iorw, iorw" ::: "memory");
    csr_write(sscratch, 0);
}

static volatile unsigned long g_cause;
static volatile unsigned long g_tval;

__attribute__((naked, aligned(4))) static void cmo_trap_handler(void)
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

#define S_MODE_PROLOGUE                                                                            \
    "la   t0, 1f\n"                                                                                \
    "csrw mscratch, t0\n"                                                                          \
    "li   t0, 0x1800\n"                                                                            \
    "csrc mstatus, t0\n"                                                                           \
    "li   t0, 0x0800\n"                                                                            \
    "csrs mstatus, t0\n"                                                                           \
    "csrs mstatus, %[bits]\n"

#define S_MODE_EPILOGUE "1: csrc mstatus, %[bits]\n"

#define CBO_CASE(n)                                                                                \
    case n:                                                                                        \
        __asm__ volatile(S_MODE_PROLOGUE ".insn i 0x0F, 2, x0, %[va], " #n "\n" S_MODE_EPILOGUE    \
                         :                                                                         \
                         : [va] "r"(va), [bits] "r"(bits)                                          \
                         : "t0", "t1", "t2", "t3", "memory");                                      \
        break

/* A load (op < 0) or a CBO (0 inval, 1 clean, 2 flush) at va with S rights. */
static unsigned long access_s(int op, unsigned long va)
{
    unsigned long out = 0;
    unsigned long bits = MSTATUS_MPRV;
    g_cause = NO_TRAP;
    g_tval = NO_TRAP;
    switch (op) {
        CBO_CASE(0);
        CBO_CASE(1);
        CBO_CASE(2);
        default:
            __asm__ volatile(S_MODE_PROLOGUE "ld %[out], 0(%[va])\n" S_MODE_EPILOGUE
                             : [out] "+r"(out)
                             : [va] "r"(va), [bits] "r"(bits)
                             : "t0", "t1", "t2", "t3", "memory");
            break;
    }
    return out;
}

static void store_s(unsigned long va, unsigned long val)
{
    unsigned long bits = MSTATUS_MPRV;
    g_cause = NO_TRAP;
    g_tval = NO_TRAP;
    __asm__ volatile(S_MODE_PROLOGUE "sd %[val], 0(%[va])\n" S_MODE_EPILOGUE
                     :
                     : [va] "r"(va), [val] "r"(val), [bits] "r"(bits)
                     : "t0", "t1", "t2", "t3", "memory");
}

static void fence_all(void)
{
    __asm__ volatile("fence iorw, iorw" ::: "memory");
}

static int
check(int cond, const char *what, int op, int view, unsigned long got, unsigned long want)
{
    uart_printf(
        "%s %s cbo.%s via %s", cond ? "[PASS]" : "[FAIL]", what, op_name[op], view_name[view]);
    if (!cond)
        uart_printf(" got=%lx want=%lx cause=%lx tval=%lx", got, want, g_cause, g_tval);
    uart_puts("\r\n");
    return cond;
}

/* Keep the CMO in the SQ long enough for a younger independent load to issue. */
#define ADJACENT_CMO(n)                                                                            \
    __asm__ volatile(S_MODE_PROLOGUE "divu t4, %[dividend], %[divisor]\n"                          \
                                     "divu t4, t4, %[divisor]\n"                                   \
                                     "divu t4, t4, %[divisor]\n"                                   \
                                     "divu t4, t4, %[divisor]\n"                                   \
                                     ".insn i 0x0f, 2, zero, %[target], " #n "\n"                  \
                                     "ld %[seen], 0(%[load_va])\n" S_MODE_EPILOGUE                 \
                     : [seen] "+&r"(seen)                                                          \
                     : [bits] "r"(bits),                                                           \
                       [target] "r"(target),                                                       \
                       [load_va] "r"(load_va),                                                     \
                       [dividend] "r"(~index),                                                     \
                       [divisor] "r"(index + 3)                                                    \
                     : "t0", "t1", "t2", "t3", "t4", "memory")

static int check_adjacent_load(int op, int cmo_view, int load_view, int inval_flushes)
{
    unsigned long index = (unsigned long) ((op * 3 + cmo_view) * 3 + load_view);
    unsigned long offset = (16 + index) * 64;
    volatile unsigned long *pa = (volatile unsigned long *) (FRAME + offset);
    unsigned long target = VA_VIEW(cmo_view) + offset + 23;
    unsigned long load_va = VA_VIEW(load_view) + offset;
    unsigned long cached_va = VA_VIEW(VIEW_PMA) + offset;
    unsigned long old = ~0x01230000ul - index;
    unsigned long dirty = old ^ 1;
    unsigned long want = op == 0 && !inval_flushes ? old : dirty;
    unsigned long seen = 0;
    unsigned long bits = MSTATUS_MPRV;

    *pa = old;
    fence_all();
    (void) access_s(-1, load_va);
    (void) access_s(1, target);
    *pa = dirty;
    fence_all();
    unsigned long warm = access_s(-1, cached_va);
    g_cause = NO_TRAP;
    switch (op) {
        case 0:
            ADJACENT_CMO(0);
            break;
        case 1:
            ADJACENT_CMO(1);
            break;
        default:
            ADJACENT_CMO(2);
            break;
    }
    fence_all();
    unsigned long later = *pa;
    int ok = warm == dirty && seen == want && later == want && g_cause == NO_TRAP;
    uart_printf("%s adjacent cbo.%s via %s, load via %s",
                ok ? "[PASS]" : "[FAIL]",
                op_name[op],
                view_name[cmo_view],
                view_name[load_view]);
    if (!ok)
        uart_printf(
            " warm=%lx seen=%lx later=%lx want=%lx cause=%lx", warm, seen, later, want, g_cause);
    uart_puts("\r\n");
    return ok;
}

static volatile unsigned long *const root = (volatile unsigned long *) PT_ROOT;
static volatile unsigned long *const l1 = (volatile unsigned long *) PT_L1;
static volatile unsigned long *const l0 = (volatile unsigned long *) PT_L0;

int main(void)
{
    int ok = 1;
    unsigned int line = 0;

    uart_puts("\r\n=== Svpbmt CMO test ===\r\n");
    set_trap_handler(&cmo_trap_handler);
    csr_write(medeleg, 0);
    for (int i = 0; i < 512; i++) {
        root[i] = 0;
        l1[i] = 0;
        l0[i] = 0;
    }
    root[0] = PTE_PPN(PT_L1) | PTE_V;
    l1[2] = PTE_PPN(PT_L0) | PTE_V;
    for (int v = 0; v < 3; v++)
        l0[v] = PTE_PPN(FRAME) | RWAD | PTE_PBMT(v);
    for (int i = 0; i < 512; i++)
        ((volatile uint64_t *) FRAME)[i] = 0;
    fence_all();
    /* A CBO_INVAL_AS_FLUSH build stores CBIE 11 as 01: cbo.inval flushes. */
    csr_write(0x30A, ENVCFG_CBIE(3));
    int inval_flushes = ((csr_read(0x30A) >> 4) & 3) == 1;
    uart_printf("cbo.inval %s\r\n", inval_flushes ? "executes as flush" : "invalidates");
    csr_write(0x30A, ENVCFG_CBZE | MENVCFG_PBMTE);
    __asm__ volatile("csrw satp, %0\n sfence.vma" : : "r"(SATP_SV39 | (PT_ROOT >> 12)));

    for (int view = VIEW_PMA; view <= VIEW_IO; view++) {
        for (int op = 0; op < 3; op++) {
            unsigned long off = (unsigned long) line * 64;
            volatile uint64_t *pa = (volatile uint64_t *) (FRAME + off);
            unsigned long va = VA_VIEW(view) + off;
            unsigned long nc_va = VA_VIEW(VIEW_NC) + off;
            unsigned long dirty = 0xD1D7000000000000ul | ((unsigned long) line << 8) | 0x11;
            unsigned long base = 0xBA5E000000000000ul | ((unsigned long) line << 8);
            /* A true invalidate drops the dirty bytes; every other CBO keeps them. */
            int drops = op == 0 && !inval_flushes;
            int expect = drops ? EXPECT_NONE : EXPECT_WRITE;

            /* DDR holds the baseline: write it and flush through the PA. */
            for (int i = 0; i < 8; i++)
                pa[i] = base + (unsigned long) i;
            fence_all();
            CBO_FLUSH_PA(FRAME + off);
            fence_all();

            /* Dirty line in the L1D, written through the cacheable PA. */
            pa[0] = dirty;
            pa[7] = ~dirty;
            fence_all();
            unsigned long want0 = drops ? base : dirty;
            unsigned long want7 = drops ? base + 7 : ~dirty;
            open_window(expect, FRAME + off);
            access_s(op, va);
            int no_trap = g_cause == NO_TRAP;
            unsigned long trap_cause = g_cause;
            close_window();
            g_cause = trap_cause;
            ok &= check(no_trap, "retires", op, view, trap_cause, NO_TRAP);
            unsigned long got = access_s(-1, nc_va);
            ok &= check(g_cause == NO_TRAP && got == want0, "nc-load-after", op, view, got, want0);
            got = access_s(-1, nc_va + 56);
            ok &= check(
                g_cause == NO_TRAP && got == want7, "nc-load-after-tail", op, view, got, want7);
            ok &= check(
                pa[0] == want0 && pa[7] == want7, "cached-load-after", op, view, pa[0], want0);

            /* An uncached store, a CBO, then the cacheable load. */
            unsigned long fresh = ~dirty ^ 0x5a5a;
            unsigned long want1 = drops ? base + 1 : fresh;
            store_s(VA_VIEW(VIEW_IO) + off + 8, fresh);
            fence_all();
            open_window(expect, FRAME + off);
            access_s(op, va);
            close_window();
            ok &= check(g_cause == NO_TRAP && pa[1] == want1,
                        "cached-load-after-uncached-store",
                        op,
                        view,
                        pa[1],
                        want1);
            line++;
        }
    }
    for (int op = 0; op < 3; op++)
        for (int cmo_view = VIEW_PMA; cmo_view <= VIEW_IO; cmo_view++)
            for (int load_view = VIEW_PMA; load_view <= VIEW_IO; load_view++)
                ok &= check_adjacent_load(op, cmo_view, load_view, inval_flushes);

    /* Eviction pass: dirty each test line again and evict it with a conflicting fill set
     * (16 dirty lines 512 KiB apart, more than the L2's ways and the L1D's); its window
     * logs the eviction's write-back. */
    for (unsigned int l = 0; l < line; l++) {
        volatile uint64_t *lp = (volatile uint64_t *) (FRAME + (unsigned long) l * 64);
        lp[2] = 0xE71C000000000000ul | l;
        fence_all();
        open_window(EXPECT_EITHER, FRAME + (unsigned long) l * 64);
        for (unsigned long k = 1; k <= 16; k++)
            ((volatile uint64_t *) (FRAME + (unsigned long) l * 64 + k * 0x80000ul))[0] = k + l;
        close_window();
    }
    __asm__ volatile("csrw satp, zero\n sfence.vma");
    csr_write(0x30A, 0);
    uart_puts(ok ? "\r\n<<PASS>>\r\n" : "\r\n<<FAIL>>\r\n");
    for (;;) {
    }
    return 0;
}
