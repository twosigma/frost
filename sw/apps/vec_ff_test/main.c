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
 * Directed test for fault-only-first vector loads (vle<eew>ff.v and
 * vlseg<nf>e<eew>ff.v) across VLEN 128, 256 and 512, with an Sv39 page that
 * is mapped followed by one that is not:
 *   1. A fault on element k > 0 ends the load without a trap and sets vl to
 *      k; elements 0..k-1 are loaded, the rest keep their old values. Every
 *      element width, k from 1 upwards, and segment forms (vl counts whole
 *      segments).
 *   2. A fault on element 0 traps with vl unchanged; with vstart = k a fault
 *      on element k sets vl to k without loading anything.
 *   3. A masked-off element on the unmapped page does not end the load.
 */
#include <stdint.h>

#include "csr.h"
#include "mmio.h"
#include "trap.h"
#include "uart.h"

#define DDR_BUF 0x83000000ul
#define DDR_REF 0x83004200ul
#define DDR_VRF 0x83008400ul
#define BUF_BYTES (3u * 4096u)

#define PT_ROOT 0x83010000ul
#define PT_L1 0x83011000ul
#define PT_L0 0x83012000ul
#define FRAMES 0x83020000ul
#define VA_BASE 0x00400000ul

#define PTE_V (1ul << 0)
#define PTE_R (1ul << 1)
#define PTE_W (1ul << 2)
#define PTE_U (1ul << 4)
#define PTE_A (1ul << 6)
#define PTE_D (1ul << 7)
#define PTE_PPN(pa) ((((unsigned long) (pa)) >> 12) << 10)
#define PTE_RW (PTE_V | PTE_R | PTE_W | PTE_A | PTE_D)
#define SATP_SV39 (8ul << 60)

#define MSTATUS_VS (3ul << 9)
#define VS_INITIAL (1ul << 9)
#define VS_CLEAN (2ul << 9)
#define VS_DIRTY (3ul << 9)

#define CAUSE_ILLEGAL 2ul
#define CAUSE_LOAD_ACCESS 5ul
#define CAUSE_STORE_ACCESS 7ul
#define CAUSE_LOAD_PAGE 13ul
#define CAUSE_STORE_PAGE 15ul

#define PMM_PMLEN7 (2ul << 32)

static volatile uint8_t *const buf = (volatile uint8_t *) DDR_BUF;
static uint8_t *const ref = (uint8_t *) DDR_REF;
static volatile uint8_t *const vrf_io = (volatile uint8_t *) DDR_VRF;

static int g_ok = 1;
static int g_checks;
static unsigned long g_vlenb;

static volatile unsigned long g_cause __attribute__((used));
static volatile unsigned long g_epc __attribute__((used));
static volatile unsigned long g_tval __attribute__((used));
static volatile unsigned long g_vstart_trap __attribute__((used));

static void
check(int cond, const char *what, unsigned long ctx, unsigned long got, unsigned long want)
{
    g_checks++;
    if (!cond) {
        g_ok = 0;
        uart_printf("[FAIL] %s (@%lx): got=%lx want=%lx\n", what, ctx, got, want);
    }
}

static void set_vs(unsigned long vs)
{
    csr_clear(mstatus, MSTATUS_VS);
    csr_set(mstatus, vs);
}

__attribute__((unused)) static unsigned long vs_field(void)
{
    return csr_read(mstatus) & MSTATUS_VS;
}

static unsigned long rd_vstart(void)
{
    unsigned long v;
    __asm__ volatile("csrr %0, 0x008" : "=r"(v));
    return v;
}

static void wr_vstart(unsigned long v)
{
    __asm__ volatile("csrw 0x008, %0" : : "r"(v) : "memory");
}

static unsigned long setvl(unsigned long avl, unsigned long vtype)
{
    unsigned long vl;
    __asm__ volatile(".insn r 0x57, 7, 0x40, %0, %1, %2"
                     : "=r"(vl)
                     : "r"(avl), "r"(vtype)
                     : "memory");
    return vl;
}

static void __attribute__((used, noreturn)) unexpected_trap_c(void)
{
    csr_clear(mstatus, 0x20000ul);
    uart_printf("[UNEXPECTED TRAP] cause=%lx epc=%lx tval=%lx vstart=%lx\n<<FAIL>>\n",
                g_cause,
                g_epc,
                g_tval,
                g_vstart_trap);
    for (;;) {
    }
}

__attribute__((naked, aligned(4))) static void bounce_handler(void)
{
    __asm__ volatile("csrr  t0, mcause\n"
                     "la    t1, g_cause\n"
                     "sd    t0, 0(t1)\n"
                     "csrr  t0, mepc\n"
                     "la    t1, g_epc\n"
                     "sd    t0, 0(t1)\n"
                     "csrr  t0, mtval\n"
                     "la    t1, g_tval\n"
                     "sd    t0, 0(t1)\n"
                     "csrr  t0, 0x008\n"
                     "la    t1, g_vstart_trap\n"
                     "sd    t0, 0(t1)\n"
                     "csrrw t0, mscratch, zero\n"
                     "beqz  t0, unexpected_trap_c\n"
                     "csrw  mepc, t0\n"
                     "mret\n");
}

/* Whole-register transfers of v8..v15, v16..v23 and v0 through DDR_VRF. */
static void load_v8_group(const volatile uint8_t *src)
{
    __asm__ volatile(".insn r 0x07, 0, 0x71, x8, %0, x8" : : "r"(src) : "memory");
}

static void store_v8_group(volatile uint8_t *dst)
{
    __asm__ volatile(".insn r 0x27, 0, 0x71, x8, %0, x8" : : "r"(dst) : "memory");
}

static void load_v16_group(const volatile uint8_t *src)
{
    __asm__ volatile(".insn r 0x07, 0, 0x71, x16, %0, x8" : : "r"(src) : "memory");
}

static void load_v0(const volatile uint8_t *src)
{
    __asm__ volatile(".insn r 0x07, 0, 0x01, x0, %0, x8" : : "r"(src) : "memory");
}

static uint64_t seed_word(uint8_t fill, unsigned long w)
{
    return ((uint64_t) fill * 0x0101010101010101ull) ^ ((w + 1u) * 0x736565645A3C96A5ull);
}

static uint8_t seed_byte(uint8_t fill, unsigned long i)
{
    return (uint8_t) (seed_word(fill, i / 8u) >> (8u * (i & 7u)));
}

static void seed_v8_group(uint8_t fill)
{
    volatile uint64_t *io64 = (volatile uint64_t *) vrf_io;
    for (unsigned long w = 0; w < g_vlenb; w++)
        io64[w] = seed_word(fill, w);
    load_v8_group(vrf_io);
}

__attribute__((unused)) static uint64_t pat_word(unsigned long w)
{
    return ((w + 1ull) * 0x9E3779B97F4A7C15ull) ^ 0xD1B54A32D192ED03ull;
}

__attribute__((unused)) static void fill_buf(void)
{
    volatile uint64_t *buf64 = (volatile uint64_t *) buf;
    uint64_t *ref64 = (uint64_t *) ref;
    for (unsigned long w = 0; w < BUF_BYTES / 8ul; w++) {
        uint64_t word = pat_word(w);
        ref64[w] = word;
        buf64[w] = word;
    }
}

__attribute__((unused)) static void
check_window(const char *what, unsigned long ctx, long lo, long hi)
{
    if (lo < 0)
        lo = 0;
    if (hi > (long) BUF_BYTES)
        hi = (long) BUF_BYTES;
    for (long i = lo; i < hi; i++) {
        if (buf[i] != ref[i]) {
            check(0, what, (ctx << 16) | (unsigned long) i, buf[i], ref[i]);
            return;
        }
    }
}

static unsigned width_bytes(int width)
{
    return width == 0 ? 1u : width == 5 ? 2u : width == 6 ? 4u : 8u;
}

/* The instruction under test runs from a trampoline built at run time in
 * cached DDR (instruction fetch sees data stores there after fence.i):
 * csrs mstatus, a2; <insn>; csrc mstatus, a2; ret, with a0 = base and
 * a1 = stride, so a2 carries MPRV for translated accesses. A trap on the
 * instruction resumes at the csrc. */
__attribute__((section(".ddr_data"), aligned(32))) static volatile uint32_t g_code[4];

static void exec_vec(uint32_t insn, unsigned long base, long stride, unsigned long mprv)
{
    g_code[0] = 0x30062073u; /* csrrs x0, mstatus, a2 */
    g_code[1] = insn;
    g_code[2] = 0x30063073u; /* csrrc x0, mstatus, a2 */
    g_code[3] = 0x00008067u; /* ret */
    __asm__ volatile("fence rw, rw\n fence.i" ::: "memory");
    g_cause = ~0ul;
    g_tval = ~0ul;
    g_vstart_trap = ~0ul;
    csr_write(mscratch, (unsigned long) (uintptr_t) &g_code[2]);
    register unsigned long a0 __asm__("a0") = base;
    register long a1 __asm__("a1") = stride;
    register unsigned long a2 __asm__("a2") = mprv;
    __asm__ volatile("jalr ra, 0(%3)"
                     : "+r"(a0), "+r"(a1), "+r"(a2)
                     : "r"((uintptr_t) g_code)
                     : "ra", "t0", "t1", "memory");
    csr_write(mscratch, 0);
}

/* Vector memory instruction words with vd/vs3 = v8, rs1 = a0, rs2 = a1 or
 * vs2 = v16. mop: 0 unit-stride, 1 unordered indexed, 2 strided, 3 ordered
 * indexed. */
__attribute__((unused)) static uint32_t
vmem_insn(int store, unsigned nf, int mop, int vm, int width)
{
    uint32_t rs2 = mop == 2 ? 11u : (mop & 1) ? 16u : 0u;
    return ((uint32_t) (nf - 1u) << 29) | ((uint32_t) mop << 26) | ((uint32_t) vm << 25) |
           (rs2 << 20) | (10u << 15) | ((uint32_t) width << 12) | (8u << 7) |
           (store ? 0x27u : 0x07u);
}

/* ========================================================================== */
/* 2. Precise faults and resumption                                           */
/* ========================================================================== */
static volatile uint8_t *const frames = (volatile uint8_t *) FRAMES;

static uint64_t frame_word(unsigned long w)
{
    return ((w + 1ull) * 0x517CC1B727220A95ull) ^ 0xA5A5F00DC3C355AAull;
}

static uint8_t frame_pat(unsigned long i)
{
    return (uint8_t) (frame_word(i >> 3) >> (8u * (i & 7u)));
}

static void fill_frames(void)
{
    volatile uint64_t *f64 = (volatile uint64_t *) frames;
    for (unsigned long w = 0; w < 6u * 4096u / 8u; w++)
        f64[w] = frame_word(w);
}

static void map_page(unsigned long page, unsigned long flags)
{
    volatile unsigned long *l0 = (volatile unsigned long *) PT_L0;
    l0[page] = flags ? (PTE_PPN(FRAMES + page * 4096u) | flags) : 0;
    __asm__ volatile("fence rw, rw\n sfence.vma" ::: "memory");
}

static void setup_sv39(void)
{
    volatile unsigned long *root = (volatile unsigned long *) PT_ROOT;
    volatile unsigned long *l1 = (volatile unsigned long *) PT_L1;
    volatile unsigned long *l0 = (volatile unsigned long *) PT_L0;
    for (int i = 0; i < 512; i++) {
        root[i] = 0;
        l1[i] = 0;
        l0[i] = 0;
    }
    root[0] = PTE_PPN(PT_L1) | PTE_V;
    l1[2] = PTE_PPN(PT_L0) | PTE_V; /* VA_BASE = 0x400000 */
    for (unsigned long pg = 0; pg < 6u; pg++)
        l0[pg] = PTE_PPN(FRAMES + pg * 4096u) | PTE_RW;
    __asm__ volatile("fence rw, rw\n csrw satp, %0\n sfence.vma"
                     :
                     : "r"(SATP_SV39 | (PT_ROOT >> 12))
                     : "memory");
}

#define MPRV_BIT (1ul << 17)
#define MPP_MASK (3ul << 11)
#define MPP_S (1ul << 11)

/* MPP = S for the next translated access (a trap sets MPP to M). */
static void mpp_s(void)
{
    csr_clear(mstatus, MPP_MASK);
    csr_set(mstatus, MPP_S);
}


static unsigned long rd_vl(void)
{
    unsigned long v;
    __asm__ volatile("csrr %0, 0xC20" : "=r"(v));
    return v;
}

/* vle<eew>ff.v / vlseg<nf>e<eew>ff.v v8, (a0): lumop 10000. */
static uint32_t ff_insn(unsigned nf, int vm, int width)
{
    return ((uint32_t) (nf - 1u) << 29) | ((uint32_t) vm << 25) | (16u << 20) | (10u << 15) |
           ((uint32_t) width << 12) | (8u << 7) | 0x07u;
}

/* Pages 0 and 1 mapped, page 2 not: the load starts k units (of nf * eew
 * bytes) below page 2, so unit k is the first to touch it. */
static void ff_case(unsigned nf,
                    int width,
                    unsigned long vtype,
                    unsigned long k,
                    unsigned long vstart,
                    unsigned long ctx)
{
    volatile uint8_t *dump = vrf_io + 1024;
    unsigned eew = width_bytes(width);
    unsigned long unit = nf * eew;
    unsigned long frame_off = 2u * 4096u - k * unit;
    seed_v8_group(0x2Eu);
    unsigned long vl = setvl(~0ul, vtype);
    if (vl <= k)
        return; /* the page boundary lies past VLMAX */
    if (vstart)
        wr_vstart(vstart);
    mpp_s();
    exec_vec(ff_insn(nf, 1, width), VA_BASE + frame_off, 0, MPRV_BIT);
    unsigned long vl_after = rd_vl();
    check(g_cause == ~0ul, "fault-only-first past element 0 does not trap", ctx, g_cause, ~0ul);
    check(vl_after == k, "vl is the faulting element", ctx, vl_after, k);
    check(rd_vstart() == 0, "vstart cleared", ctx, rd_vstart(), 0);
    store_v8_group(dump);
    unsigned long regs = (8u * g_vlenb) / nf; /* bytes per field group seen */
    (void) regs;
    for (unsigned f = 0; f < nf; f++) {
        for (unsigned long i = 0; i < vl && (i + 1u) * eew <= g_vlenb; i++) {
            for (unsigned b = 0; b < eew; b++) {
                unsigned long r = f * g_vlenb + i * eew + b;
                uint8_t want = (i >= vstart && i < k)
                                   ? frame_pat(frame_off + i * unit + f * eew + b)
                                   : seed_byte(0x2Eu, r);
                if (dump[r] != want) {
                    check(0, "fault-only-first data", (ctx << 16) | (f << 12) | i, dump[r], want);
                    return;
                }
            }
        }
    }
    g_checks++;
}

static void test_ff(void)
{
    setup_sv39();
    fill_frames();
    map_page(2, 0);
    static const struct {
        unsigned nf;
        int width;
        unsigned long vtype;
    } cfgs[] = {
        {1, 0, 0x00},
        {1, 5, 0x08},
        {1, 6, 0x10},
        {1, 7, 0x18},
        {1, 0, 0x03},
        {2, 6, 0x10},
        {3, 5, 0x08},
        {8, 0, 0x00},
    };
    for (unsigned c = 0; c < sizeof cfgs / sizeof cfgs[0]; c++)
        for (unsigned long k = 1; k < 6u; k += 2u)
            ff_case(cfgs[c].nf, cfgs[c].width, cfgs[c].vtype, k, 0, (c << 4) | k);
    /* vstart = k: nothing is loaded and vl becomes k. */
    ff_case(1, 6, 0x10, 3, 3, 0xF3);

    /* A fault on element 0 traps and leaves vl. */
    unsigned long vl = setvl(~0ul, 0x10ul);
    mpp_s();
    exec_vec(ff_insn(1, 1, 6), VA_BASE + 2u * 4096u + 8u, 0, MPRV_BIT);
    check(g_cause == CAUSE_LOAD_PAGE && g_tval == VA_BASE + 2u * 4096u + 8u && g_vstart_trap == 0u,
          "fault-only-first traps on element 0",
          g_tval,
          g_cause,
          CAUSE_LOAD_PAGE);
    check(rd_vl() == vl, "element 0 trap keeps vl", 0, rd_vl(), vl);

    /* A masked-off element on the unmapped page does not end the load. */
    for (unsigned long b = 0; b < g_vlenb; b++)
        vrf_io[b] = (b == 0) ? 0x03u : 0x00u; /* elements 0 and 1 */
    load_v0(vrf_io);
    setvl(4, 0x10ul);
    mpp_s();
    exec_vec(ff_insn(1, 0, 6), VA_BASE + 2u * 4096u - 8u, 0, MPRV_BIT);
    check(g_cause == ~0ul && rd_vl() == 4u,
          "masked-off element past the page keeps vl",
          0,
          rd_vl(),
          4u);
    map_page(2, PTE_RW);
    __asm__ volatile("csrw satp, zero\n sfence.vma" ::: "memory");
    csr_clear(mstatus, MPP_MASK);
}

/* Readers of vl placed right behind a trimming load: the trimmed vl lands on
 * the load's registered commit, and the next instruction's own commit reads
 * it on the following edge. The trampoline is csrrs mstatus, a2; <ff load>;
 * <next1>; <next2>; csrrc mstatus, a2; ret, with the result of next1/next2
 * in a3. */
__attribute__((section(".ddr_data"), aligned(32))) static volatile uint32_t g_code2[8];
#define RV_NOP 0x00000013u
#define CSRR_A3_VL 0xC20026F3u          /* csrr a3, vl */
#define VADD_VI_V8_V8_1 0x0280B457u     /* vadd.vi v8, v8, 1 */
#define VSETVLI_X0_X0_E32M1 0x01007057u /* vsetvli x0, x0, e32, m1 */
#define VCPOP_A3_V16 0x430826D7u        /* vcpop.m a3, v16 */

static unsigned long exec_tight(uint32_t insn, uint32_t n1, uint32_t n2, unsigned long base)
{
    g_code2[0] = 0x30062073u; /* csrrs x0, mstatus, a2 */
    g_code2[1] = insn;
    g_code2[2] = n1;
    g_code2[3] = n2;
    g_code2[4] = 0x30063073u; /* csrrc x0, mstatus, a2 */
    g_code2[5] = 0x00008067u; /* ret */
    __asm__ volatile("fence rw, rw\n fence.i" ::: "memory");
    g_cause = ~0ul;
    csr_write(mscratch, (unsigned long) (uintptr_t) &g_code2[4]);
    register unsigned long a0 __asm__("a0") = base;
    register unsigned long a2 __asm__("a2") = MPRV_BIT;
    register unsigned long a3 __asm__("a3") = ~0ul;
    __asm__ volatile("jalr ra, 0(%3)"
                     : "+r"(a0), "+r"(a2), "+r"(a3)
                     : "r"((uintptr_t) g_code2)
                     : "ra", "t0", "t1", "memory");
    csr_write(mscratch, 0);
    return a3;
}

static void test_tight(void)
{
    volatile uint8_t *dump = vrf_io + 1024;
    setup_sv39();
    fill_frames();
    map_page(2, 0);
    for (unsigned long k = 1; k < 6u; k += 2u) {
        unsigned long frame_off = 2u * 4096u - k * 4u;
        unsigned long vlmax = setvl(~0ul, 0x10ul);
        if (vlmax <= k)
            continue;
        /* T1: csrr vl right behind the trimming load */
        seed_v8_group(0x2Eu);
        setvl(~0ul, 0x10ul);
        mpp_s();
        unsigned long r = exec_tight(ff_insn(1, 1, 6), CSRR_A3_VL, RV_NOP, VA_BASE + frame_off);
        check(g_cause == ~0ul && r == k, "T1 csrr vl right behind the trim", k, r, k);
        /* T2: vadd.vi v8, v8, 1 (tail undisturbed) right behind it */
        seed_v8_group(0x2Eu);
        setvl(~0ul, 0x10ul);
        mpp_s();
        exec_tight(ff_insn(1, 1, 6), VADD_VI_V8_V8_1, RV_NOP, VA_BASE + frame_off);
        check(g_cause == ~0ul && rd_vl() == k, "T2 vl after the trim", k, rd_vl(), k);
        store_v8_group(dump);
        for (unsigned long i = 0; i < vlmax; i++) {
            uint32_t got = (uint32_t) dump[4 * i] | ((uint32_t) dump[4 * i + 1] << 8) |
                           ((uint32_t) dump[4 * i + 2] << 16) | ((uint32_t) dump[4 * i + 3] << 24);
            uint32_t want = 0;
            for (unsigned b = 0; b < 4u; b++)
                want |= (uint32_t) ((i < k) ? frame_pat(frame_off + i * 4u + b)
                                            : seed_byte(0x2Eu, i * 4u + b))
                        << (8u * b);
            if (i < k)
                want += 1u;
            check(got == want, "T2 vadd.vi right behind the trim", (k << 16) | i, got, want);
        }
        /* T3: vsetvli x0, x0 (keep) right behind it, then csrr vl */
        seed_v8_group(0x2Eu);
        setvl(~0ul, 0x10ul);
        mpp_s();
        r = exec_tight(ff_insn(1, 1, 6), VSETVLI_X0_X0_E32M1, CSRR_A3_VL, VA_BASE + frame_off);
        check(g_cause == ~0ul && r == k, "T3 vsetvli keep right behind the trim", k, r, k);
        /* T4: vcpop.m a3, v16 (all ones) right behind it */
        for (unsigned long b = 0; b < 8u * g_vlenb; b++)
            vrf_io[b] = 0xFFu;
        load_v16_group(vrf_io);
        seed_v8_group(0x2Eu);
        setvl(~0ul, 0x10ul);
        mpp_s();
        r = exec_tight(ff_insn(1, 1, 6), VCPOP_A3_V16, RV_NOP, VA_BASE + frame_off);
        check(g_cause == ~0ul && r == k, "T4 vcpop.m right behind the trim", k, r, k);
    }
    map_page(2, PTE_RW);
    __asm__ volatile("csrw satp, zero\n sfence.vma" ::: "memory");
    csr_clear(mstatus, MPP_MASK);
}


int main(void)
{
    csr_write(mscratch, 0);
    set_trap_handler(&bounce_handler);
    set_vs(VS_INITIAL);
    __asm__ volatile("csrr %0, 0xC22" : "=r"(g_vlenb));
    uart_printf("vec_ff_test VLEN=%lu\n", g_vlenb * 8u);
    test_ff();
    uart_printf("  [1-3] fault-only-first ok\n");
    test_tight();
    uart_printf("  [4] vl readers right behind the trim ok\n");
    uart_printf("%d checks\n", g_checks);
    uart_printf(g_ok ? "<<PASS>>\n" : "<<FAIL>>\n");
    for (;;) {
    }
    return 0;
}
