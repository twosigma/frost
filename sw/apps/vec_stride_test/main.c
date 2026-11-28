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
 * Directed test for strided vector loads and stores (vlse<eew>.v, vsse<eew>.v)
 * across VLEN 128, 256 and 512:
 *   1. Every element width and EMUL from 1/8 to 8, with strides that are
 *      positive, negative, zero, misaligned, one page and more than a page,
 *      from bases that put elements across sector, line and page boundaries.
 *      Elements are performed in element order, so a zero or overlapping
 *      stride leaves the last element's bytes.
 *   2. Masked elements, vstart > 0 and tail elements keep their old values;
 *      mstatus.VS becomes Dirty on a load and on a store that clears vstart.
 *   3. Precise faults: an element in low BRAM (bare), and Sv39 page faults
 *      part-way through, on a straddling element and with a negative stride,
 *      report vstart = the faulting element and mtval = its address (the next
 *      page's base for an element that straddles into it) after the elements
 *      before it are performed; the re-executed instruction resumes at vstart.
 *   4. Scalar-vector ordering in both directions on element addresses, with
 *      an AMO, LR/SC and a vector access between them.
 *   5. Ssnpm pointer masking of element addresses under MPRV with MPP = U, with
 *      Bare and Sv39 translation, for strided and unit-stride forms, and the
 *      transformed address a fault reports.
 *   6. Legality: EMUL out of range, misaligned groups, masked load to v0 and
 *      vill.
 *   7. CLINT timer interrupts arriving during long element runs.
 */

#include <stdint.h>

#include "csr.h"
#include "mmio.h"
#include "trap.h"
#include "uart.h"

/* Cached DDR regions (offset across cache sets). */
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

#define CSR_SENVCFG 0x10A
#define PMM_PMLEN7 (2ul << 32)

static volatile uint8_t *const buf = (volatile uint8_t *) DDR_BUF;
static uint8_t *const ref = (uint8_t *) DDR_REF;
static volatile uint8_t *const vrf_io = (volatile uint8_t *) DDR_VRF;

static int g_ok = 1;
static int g_checks;
static unsigned long g_vlenb;

static volatile unsigned long g_cause;
static volatile unsigned long g_epc;
static volatile unsigned long g_tval;
static volatile unsigned long g_vstart_trap;
static volatile uint32_t g_irq;

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

static unsigned long vs_field(void)
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

/* vsetvl rd, avl, vtype */
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

/* Records mcause, mepc, mtval and vstart, then resumes at mscratch (which it
 * clears); a trap with mscratch zero is unexpected. */
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

/* Whole-register transfers of v8..v15 and v0 through DDR_VRF. */
static void load_v8_group(const volatile uint8_t *src)
{
    __asm__ volatile(".insn r 0x07, 0, 0x71, x8, %0, x8" : : "r"(src) : "memory");
}

static void store_v8_group(volatile uint8_t *dst)
{
    __asm__ volatile(".insn r 0x27, 0, 0x71, x8, %0, x8" : : "r"(dst) : "memory");
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

/* v8..v15 hold seed_byte(fill, i) at group byte i. */
static void seed_v8_group(uint8_t fill)
{
    volatile uint64_t *io64 = (volatile uint64_t *) vrf_io;
    for (unsigned long w = 0; w < g_vlenb; w++)
        io64[w] = seed_word(fill, w);
    load_v8_group(vrf_io);
}

static uint64_t pat_word(unsigned long w)
{
    return ((w + 1ull) * 0x9E3779B97F4A7C15ull) ^ 0xD1B54A32D192ED03ull;
}

static void fill_buf(void)
{
    volatile uint64_t *buf64 = (volatile uint64_t *) buf;
    uint64_t *ref64 = (uint64_t *) ref;
    for (unsigned long w = 0; w < BUF_BYTES / 8ul; w++) {
        uint64_t word = pat_word(w);
        ref64[w] = word;
        buf64[w] = word;
    }
}

/* Compares DDR_BUF bytes [lo, hi) with the model. */
static void check_window(const char *what, unsigned long ctx, long lo, long hi)
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

/* Compares DDR_BUF with its model; reports the first differing byte. */
static void check_buf(const char *what, unsigned long ctx)
{
    const volatile uint64_t *buf64 = (const volatile uint64_t *) buf;
    const uint64_t *ref64 = (const uint64_t *) ref;
    for (unsigned long w = 0; w < BUF_BYTES / 8ul; w++) {
        if (buf64[w] != ref64[w]) {
            for (unsigned long k = 0; k < 8u; k++) {
                unsigned long i = w * 8u + k;
                if (buf[i] != ref[i]) {
                    check(0, what, (ctx << 16) | i, buf[i], ref[i]);
                    return;
                }
            }
        }
    }
    g_checks++;
}

/* Strided load into v8 or store from v8 (vs3 = v8): width code 0/5/6/7,
 * vm 0 (masked by v0) or 1. rs1 = base, rs2 = stride. */
#define VLSE(w, f7)                                                                                \
    __asm__ volatile(".insn r 0x07, " #w ", " #f7 ", x8, %0, %1" ::"r"(p), "r"(s) : "memory")
#define VSSE(w, f7)                                                                                \
    __asm__ volatile(".insn r 0x27, " #w ", " #f7 ", x8, %0, %1" ::"r"(p), "r"(s) : "memory")

static void vlse_v8(unsigned long p, long s, int width, int vm)
{
    switch (width * 2 + vm) {
        case 0:
            VLSE(0, 0x04);
            break;
        case 1:
            VLSE(0, 0x05);
            break;
        case 10:
            VLSE(5, 0x04);
            break;
        case 11:
            VLSE(5, 0x05);
            break;
        case 12:
            VLSE(6, 0x04);
            break;
        case 13:
            VLSE(6, 0x05);
            break;
        case 14:
            VLSE(7, 0x04);
            break;
        default:
            VLSE(7, 0x05);
            break;
    }
}

static void vsse_v8(unsigned long p, long s, int width, int vm)
{
    switch (width * 2 + vm) {
        case 0:
            VSSE(0, 0x04);
            break;
        case 1:
            VSSE(0, 0x05);
            break;
        case 10:
            VSSE(5, 0x04);
            break;
        case 11:
            VSSE(5, 0x05);
            break;
        case 12:
            VSSE(6, 0x04);
            break;
        case 13:
            VSSE(6, 0x05);
            break;
        case 14:
            VSSE(7, 0x04);
            break;
        default:
            VSSE(7, 0x05);
            break;
    }
}

static unsigned width_bytes(int width)
{
    return width == 0 ? 1u : width == 5 ? 2u : width == 6 ? 4u : 8u;
}

/* The mask register image used by masked cases: element i active when
 * mask_bit(i). */
static int mask_bit(unsigned long i)
{
    return ((i * 7u + 3u) % 5u) != 0u;
}

static void load_mask(void)
{
    for (unsigned long b = 0; b < g_vlenb; b++) {
        uint8_t m = 0;
        for (unsigned k = 0; k < 8; k++)
            m |= (uint8_t) (mask_bit(b * 8u + k) << k);
        vrf_io[b] = m;
    }
    load_v0(vrf_io);
}

/* One strided load and one strided store, checked against the model.
 * vtype selects SEW and LMUL; vl elements of width_bytes(width) at base
 * offset off with the given stride; elements below vstart, masked off (vm 0)
 * or at or past vl keep their old values. DDR_BUF and its model change only
 * by the stores, so the cases share one image. */
static void run_case(int width,
                     unsigned long vtype,
                     unsigned long avl,
                     unsigned long off,
                     long stride,
                     unsigned long vstart,
                     int vm,
                     unsigned long ctx)
{
    unsigned eew = width_bytes(width);
    volatile uint8_t *dump = vrf_io + 1024;

    /* Load. */
    seed_v8_group(0x3Cu);
    if (!vm)
        load_mask();
    unsigned long vl = setvl(avl, vtype);
    if (vstart)
        wr_vstart(vstart);
    set_vs(VS_CLEAN);
    vlse_v8(DDR_BUF + off, stride, width, vm);
    check(vs_field() == VS_DIRTY, "strided load sets VS Dirty", ctx, vs_field(), VS_DIRTY);
    check(rd_vstart() == 0, "strided load clears vstart", ctx, rd_vstart(), 0);
    store_v8_group(dump);
    /* The elements and the tail after them. */
    unsigned long cmp = vl * eew + 32u;
    if (cmp > 8u * g_vlenb)
        cmp = 8u * g_vlenb;
    for (unsigned long b = 0; b < cmp; b++) {
        unsigned long i = b / eew;
        uint8_t want = seed_byte(0x3Cu, b);
        if (i < vl && i >= vstart && (vm || mask_bit(i)))
            want = ref[(unsigned long) ((long) off + (long) i * stride) + b % eew];
        if (dump[b] != want) {
            check(0, "strided load byte", (ctx << 16) | b, dump[b], want);
            break;
        }
    }
    g_checks++;

    /* Store: the model applies the elements in element order. */
    seed_v8_group(0xA5u);
    if (!vm)
        load_mask();
    vl = setvl(avl, vtype);
    if (vstart)
        wr_vstart(vstart);
    set_vs(VS_CLEAN);
    vsse_v8(DDR_BUF + off, stride, width, vm);
    check(vs_field() == (vstart ? VS_DIRTY : VS_CLEAN),
          "strided store VS",
          ctx,
          vs_field(),
          vstart ? VS_DIRTY : VS_CLEAN);
    for (unsigned long i = vstart; i < vl; i++) {
        if (!vm && !mask_bit(i))
            continue;
        for (unsigned b = 0; b < eew; b++)
            ref[(unsigned long) ((long) off + (long) i * stride) + b] =
                seed_byte(0xA5u, i * eew + b);
    }
    /* Every element's bytes, active or not, and 8 bytes on each side. */
    for (unsigned long i = 0; i < vl + 1u; i++) {
        long a = (long) off + (long) i * stride;
        check_window("strided store image", ctx, a - 8, a + (long) eew + 8);
    }
    g_checks++;
}

/* ========================================================================== */
/* 1, 2. Geometry, masks, vstart, tail and VS                                 */
/* ========================================================================== */
struct cfg {
    int width;
    unsigned long vtype;
    unsigned long lmul_x8; /* LMUL * 8 */
    unsigned long sew;     /* bytes */
};

static const struct cfg g_cfgs[] = {
    {0, 0x00, 8, 1},  /* e8 m1, EMUL 1 */
    {0, 0x03, 64, 1}, /* e8 m8, EMUL 8 */
    {0, 0x05, 1, 1},  /* e8 mf8, EMUL 1/8 */
    {5, 0x09, 16, 2}, /* e16 m2 */
    {6, 0x10, 8, 4},  /* e32 m1 */
    {6, 0x17, 4, 4},  /* e32 mf2 */
    {7, 0x18, 8, 8},  /* e64 m1 */
    {7, 0x1A, 32, 8}, /* e64 m4 */
    {0, 0x10, 8, 4},  /* vlse8 under e32 m1: EEW 8, EMUL 1/4 */
    {7, 0x00, 8, 1},  /* vlse64 under e8 m1: EEW 64, EMUL 8 */
};

static void test_geometry(void)
{
    fill_buf();
    /* One instruction with every element of the largest group. */
    run_case(0, 0x03, ~0ul, 0x101u, 1, 0, 1, 0xE00);
    for (unsigned c = 0; c < sizeof g_cfgs / sizeof g_cfgs[0]; c++) {
        const struct cfg *cf = &g_cfgs[c];
        long eew = (long) width_bytes(cf->width);
        unsigned long vlmax = g_vlenb * cf->lmul_x8 / (8u * cf->sew);
        const long strides[] = {
            eew, 3 * eew, -2 * eew, 0, eew + 1, 4095, -4097, 4096 + eew / 2 + 1};
        for (unsigned s = 0; s < sizeof strides / sizeof strides[0]; s++) {
            long stride = strides[s];
            unsigned long mag = (unsigned long) (stride < 0 ? -stride : stride);
            unsigned long fit = mag ? (BUF_BYTES - 256u) / mag : vlmax;
            unsigned long avl = vlmax < fit ? vlmax : fit;
            if (avl > 20u)
                avl = 20u;
            if (s & 1u)
                avl = avl > 3 ? avl - 2 : avl; /* a tail */
            /* Elements start just below a page boundary where they fit, so
             * they cross sectors, lines and the page; a negative stride
             * starts high enough for its last element. */
            unsigned long span = mag * (avl ? avl - 1 : 0);
            unsigned long off = 4096u - 3u * (unsigned long) eew - 1u;
            if (stride < 0)
                off = span + 13u + (unsigned long) c;
            else if (span + (unsigned long) eew + off > BUF_BYTES)
                off = 64u + (unsigned long) (c * 3u);
            run_case(cf->width, cf->vtype, avl, off, stride, 0, 1, (c << 8) | s);
        }
        /* Masked, with vstart > 0. */
        unsigned long avl = vlmax < 20u ? vlmax : 20u;
        run_case(cf->width, cf->vtype, avl, 0x7F3u, 5 * eew, avl > 2 ? 2u : 0u, 0, (c << 8) | 0x80);
        run_case(
            cf->width, cf->vtype, avl, 0x1803u, -3 * eew, avl > 3 ? 3u : 0u, 1, (c << 8) | 0x81);
    }
    /* vstart >= vl: nothing is accessed, and the instruction completes. */
    run_case(6, 0x10, 4, 0x100u, 16, 7, 1, 0xF00);
    /* vl = 0. */
    run_case(6, 0x10, 0, 0x100u, 16, 0, 1, 0xF01);
}

/* ========================================================================== */
/* 3. Precise faults and resumption                                           */
/* ========================================================================== */
#define RUN_TRAP_STRIDED(insn_asm, base, stride)                                                   \
    do {                                                                                           \
        g_cause = ~0ul;                                                                            \
        g_tval = ~0ul;                                                                             \
        g_vstart_trap = ~0ul;                                                                      \
        __asm__ volatile("la t0, 1f\n csrw mscratch, t0\n" insn_asm "\n1:\n csrw mscratch, zero\n" \
                         :                                                                         \
                         : "r"(base), "r"(stride)                                                  \
                         : "t0", "memory");                                                        \
    } while (0)

#define MPRV_S_ON                                                                                  \
    "li t1, 0x1800\n csrc mstatus, t1\n li t1, 0x0800\n csrs mstatus, t1\n"                        \
    "li t1, 0x20000\n csrs mstatus, t1\n"
#define MPRV_U_ON                                                                                  \
    "li t1, 0x1800\n csrc mstatus, t1\n"                                                           \
    "li t1, 0x20000\n csrs mstatus, t1\n"
#define MPRV_OFF "1:\n li t1, 0x20000\n csrc mstatus, t1\n csrw mscratch, zero\n"

/* vlse32/vsse32 v8 under MPRV with MPP = S or U. */
#define MPRV_STRIDED(mprv_on, insn_asm, base, stride)                                              \
    do {                                                                                           \
        g_cause = ~0ul;                                                                            \
        g_tval = ~0ul;                                                                             \
        g_vstart_trap = ~0ul;                                                                      \
        __asm__ volatile("la t0, 1f\n csrw mscratch, t0\n" mprv_on insn_asm "\n" MPRV_OFF          \
                         :                                                                         \
                         : "r"(base), "r"(stride)                                                  \
                         : "t0", "t1", "memory");                                                  \
    } while (0)

#define VLSE32_V8 ".insn r 0x07, 6, 0x05, x8, %0, %1"
#define VSSE32_V8 ".insn r 0x27, 6, 0x05, x8, %0, %1"
#define VLSE64_V8 ".insn r 0x07, 7, 0x05, x8, %0, %1"
#define VLE32_V8 ".insn r 0x07, 6, 0x01, x8, %0, x0"

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
        l0[pg] = PTE_PPN(FRAMES + pg * 4096u) | PTE_RW | (pg >= 4u ? PTE_U : 0ul);
    __asm__ volatile("fence rw, rw\n csrw satp, %0\n sfence.vma"
                     :
                     : "r"(SATP_SV39 | (PT_ROOT >> 12))
                     : "memory");
}

/* Checks v8's 32-bit elements: element i holds frame bytes at frame_off(i)
 * when i < loaded_upto (from first), else the seed. */
static void check_v8_e32(const char *what,
                         unsigned long vl,
                         unsigned long first,
                         unsigned long upto,
                         unsigned long frame_base,
                         long stride,
                         uint8_t fill)
{
    volatile uint8_t *dump = vrf_io + 1024;
    store_v8_group(dump);
    for (unsigned long b = 0; b < 4u * vl; b++) {
        unsigned long i = b / 4u;
        uint8_t want = seed_byte(fill, b);
        if (i >= first && i < upto)
            want = frame_pat((unsigned long) ((long) frame_base + (long) i * stride) + b % 4u);
        if (dump[b] != want) {
            check(0, what, b, dump[b], want);
            return;
        }
    }
    g_checks++;
}

static void test_faults(void)
{
    /* 3a. Bare: mixed DDR -> low BRAM succeeds; DDR -> unmapped PA 0x40000
     * faults at element 1 after element 0 completes. */
    volatile uint64_t stack_word[2] __attribute__((aligned(16)));
    stack_word[0] = 0x1122334455667788ull;
    unsigned long bram = (unsigned long) &stack_word[0];
    long to_bram = (long) bram - (long) (DDR_BUF + 0x200u);
    fill_buf();
    seed_v8_group(0x77u);
    setvl(2, 0x18ul); /* e64 m1 */
    RUN_TRAP_STRIDED(VLSE64_V8, DDR_BUF + 0x200u, to_bram);
    check(g_cause == ~0ul, "bare vlse64 DDR->BRAM succeeds", 0, g_cause, ~0ul);
    {
        volatile uint64_t *dump64 = (volatile uint64_t *) (vrf_io + 1024);
        store_v8_group((volatile uint8_t *) dump64);
        check(dump64[1] == 0x1122334455667788ull,
              "bare vlse64 BRAM element loaded",
              1,
              dump64[1],
              0x1122334455667788ull);
    }

    const unsigned long unmapped = 0x00040000ul;
    long to_unmapped = (long) unmapped - (long) (DDR_BUF + 0x200u);
    const unsigned long fault_elem = 1u;
    fill_buf();
    seed_v8_group(0x77u);
    setvl(4, 0x18ul); /* e64 m1 */
    set_vs(VS_CLEAN);
    RUN_TRAP_STRIDED(VLSE64_V8, DDR_BUF + 0x200u, to_unmapped);
    check(g_cause == CAUSE_LOAD_ACCESS && g_tval == unmapped && g_vstart_trap == fault_elem,
          "bare vlse64 access fault at an unmapped element",
          g_vstart_trap,
          g_cause,
          CAUSE_LOAD_ACCESS);
    check(vs_field() == VS_DIRTY, "partial strided load dirties VS", 0, vs_field(), VS_DIRTY);
    wr_vstart(0);
    {
        volatile uint8_t *dump = vrf_io + 1024;
        store_v8_group(dump);
        for (unsigned long b = 0; b < 32u; b++) {
            unsigned long i = b / 8u;
            uint8_t want = (i < fault_elem)
                               ? ref[(unsigned long) (0x200 + (long) i * to_unmapped) + b % 8u]
                               : seed_byte(0x77u, b);
            check(dump[b] == want, "bare fault: elements before vstart loaded", b, dump[b], want);
        }
    }
    /* The store form writes the elements before the fault and nothing else. */
    fill_buf();
    seed_v8_group(0x99u);
    setvl(4, 0x18ul);
    RUN_TRAP_STRIDED(".insn r 0x27, 7, 0x05, x8, %0, %1", DDR_BUF + 0x200u, to_unmapped);
    check(g_cause == CAUSE_STORE_ACCESS && g_tval == unmapped && g_vstart_trap == fault_elem,
          "bare vsse64 access fault at an unmapped element",
          g_vstart_trap,
          g_cause,
          CAUSE_STORE_ACCESS);
    wr_vstart(0);
    for (unsigned long i = 0; i < fault_elem; i++)
        for (unsigned b = 0; b < 8u; b++)
            ref[(unsigned long) (0x200 + (long) i * to_unmapped) + b] =
                seed_byte(0x99u, i * 8u + b);
    check_buf("bare fault: store image", 0);
    check(stack_word[0] == 0x1122334455667788ull, "BRAM word untouched", 0, stack_word[0], 0);

    /* 3b. Sv39 under MPRV with MPP = S: one element per page from page 0,
     * page 2 unmapped. */
    setup_sv39();
    fill_frames();
    map_page(2, 0);
    seed_v8_group(0x11u);
    setvl(4, 0x10ul); /* e32 m1 */
    set_vs(VS_CLEAN);
    MPRV_STRIDED(MPRV_S_ON, VLSE32_V8, VA_BASE + 0x104u, 4096l);
    check(g_cause == CAUSE_LOAD_PAGE && g_tval == VA_BASE + 2u * 4096u + 0x104u &&
              g_vstart_trap == 2u && rd_vstart() == 2u,
          "Sv39 vlse32 fault at element 2",
          g_tval,
          g_cause,
          CAUSE_LOAD_PAGE);
    check(vs_field() == VS_DIRTY, "Sv39 partial strided load dirties VS", 0, vs_field(), VS_DIRTY);
    /* The dump is a vector store, which honors and clears vstart. */
    wr_vstart(0);
    check_v8_e32("Sv39 partial: elements 0, 1 loaded", 4, 0, 2, 0x104u, 4096, 0x11u);
    /* Demand paging: map the page and run the same instruction at vstart 2,
     * as a handler that saved and restored vstart would. */
    map_page(2, PTE_RW);
    setvl(4, 0x10ul);
    wr_vstart(2);
    MPRV_STRIDED(MPRV_S_ON, VLSE32_V8, VA_BASE + 0x104u, 4096l);
    check(g_cause == ~0ul && rd_vstart() == 0, "Sv39 vlse32 resumes", 0, g_cause, ~0ul);
    check_v8_e32("Sv39 resumed: all elements", 4, 0, 4, 0x104u, 4096, 0x11u);

    /* Store: elements 0 and 1 land before the fault; the resumed instruction
     * writes elements 2 and 3 only. */
    fill_frames();
    map_page(2, 0);
    for (unsigned long i = 0; i < 32u; i++)
        vrf_io[i] = (uint8_t) (0xC0u + i);
    load_v8_group(vrf_io);
    setvl(4, 0x10ul);
    MPRV_STRIDED(MPRV_S_ON, VSSE32_V8, VA_BASE + 0x208u, 4096l);
    check(g_cause == CAUSE_STORE_PAGE && g_tval == VA_BASE + 2u * 4096u + 0x208u &&
              g_vstart_trap == 2u,
          "Sv39 vsse32 fault at element 2",
          g_tval,
          g_cause,
          CAUSE_STORE_PAGE);
    for (unsigned long i = 0; i < 4u; i++)
        for (unsigned b = 0; b < 4u; b++) {
            unsigned long fo = i * 4096u + 0x208u + b;
            uint8_t want = (i < 2u) ? (uint8_t) (0xC0u + i * 4u + b) : frame_pat(fo);
            check(frames[fo] == want, "Sv39 vsse32 partial image", fo, frames[fo], want);
        }
    map_page(2, PTE_RW);
    setvl(4, 0x10ul);
    wr_vstart(2);
    MPRV_STRIDED(MPRV_S_ON, VSSE32_V8, VA_BASE + 0x208u, 4096l);
    check(g_cause == ~0ul && rd_vstart() == 0, "Sv39 vsse32 resumes", 0, g_cause, ~0ul);
    for (unsigned long i = 0; i < 4u; i++)
        for (unsigned b = 0; b < 4u; b++) {
            unsigned long fo = i * 4096u + 0x208u + b;
            check(frames[fo] == (uint8_t) (0xC0u + i * 4u + b),
                  "Sv39 vsse32 resumed image",
                  fo,
                  frames[fo],
                  (uint8_t) (0xC0u + i * 4u + b));
        }

    /* A straddling element: element 2 at page 1's last two bytes and page 2. */
    fill_frames();
    map_page(2, 0);
    seed_v8_group(0x22u);
    setvl(4, 0x10ul);
    MPRV_STRIDED(MPRV_S_ON, VLSE32_V8, VA_BASE + 2u * 4096u - 26u, 12l);
    check(g_cause == CAUSE_LOAD_PAGE && g_tval == VA_BASE + 2u * 4096u && g_vstart_trap == 2u,
          "Sv39 straddling element: mtval is the page base",
          g_tval,
          g_cause,
          CAUSE_LOAD_PAGE);
    wr_vstart(0);
    check_v8_e32("Sv39 straddle: elements 0, 1 loaded", 4, 0, 2, 2u * 4096u - 26u, 12, 0x22u);

    /* Negative stride from page 3 into unmapped page 2. */
    seed_v8_group(0x33u);
    setvl(3, 0x10ul);
    MPRV_STRIDED(MPRV_S_ON, VLSE32_V8, VA_BASE + 3u * 4096u + 0x10u, -4096l);
    check(g_cause == CAUSE_LOAD_PAGE && g_tval == VA_BASE + 2u * 4096u + 0x10u &&
              g_vstart_trap == 1u,
          "Sv39 negative stride fault at element 1",
          g_tval,
          g_cause,
          CAUSE_LOAD_PAGE);
    wr_vstart(0);
    check_v8_e32(
        "Sv39 negative stride: element 0 loaded", 3, 0, 1, 3u * 4096u + 0x10u, -4096, 0x33u);

    /* A masked-off element on the unmapped page does not fault. */
    for (unsigned long b = 0; b < g_vlenb; b++)
        vrf_io[b] = (b == 0) ? 0x0Bu : 0x00u; /* elements 0, 1, 3 */
    load_v0(vrf_io);
    seed_v8_group(0x44u);
    setvl(4, 0x10ul);
    MPRV_STRIDED(MPRV_S_ON, ".insn r 0x07, 6, 0x04, x8, %0, %1", VA_BASE + 0x40u, 4096l);
    check(g_cause == ~0ul, "masked-off element on an unmapped page", 0, g_cause, ~0ul);
    map_page(2, PTE_RW);
    __asm__ volatile("csrw satp, zero\n sfence.vma" ::: "memory");
}

/* ========================================================================== */
/* 4. Scalar-vector ordering                                                  */
/* ========================================================================== */
static void test_ordering(void)
{
    volatile uint8_t *dump = vrf_io + 1024;
    volatile uint64_t *w = (volatile uint64_t *) (buf + 0x400);

    /* Scalar stores immediately before a strided load of the same words. */
    fill_buf();
    setvl(6, 0x1Aul); /* e64 m4 */
    w[0] = 0x0101010101010101ull;
    w[3] = 0x0303030303030303ull;
    w[6] = 0x0606060606060606ull;
    w[9] = 0x0909090909090909ull;
    vlse_v8(DDR_BUF + 0x400u, 24, 7, 1);
    store_v8_group(dump);
    {
        const volatile uint64_t *d = (const volatile uint64_t *) dump;
        check(d[0] == 0x0101010101010101ull && d[1] == 0x0303030303030303ull &&
                  d[2] == 0x0606060606060606ull && d[3] == 0x0909090909090909ull,
              "scalar stores before a strided load",
              0,
              d[1],
              0x0303030303030303ull);
    }

    /* A strided store immediately before scalar loads of its elements and of
     * the words between them. */
    for (unsigned long i = 0; i < 64u; i++)
        vrf_io[i] = (uint8_t) (0x80u + i);
    load_v8_group(vrf_io);
    setvl(4, 0x1Aul);
    vsse_v8(DDR_BUF + 0x800u, 16, 7, 1);
    {
        volatile uint64_t *d = (volatile uint64_t *) (buf + 0x800);
        uint64_t e1 = d[2], gap = d[1], e3 = d[6];
        check(e1 == 0x8F8E8D8C8B8A8988ull,
              "scalar load after a strided store",
              1,
              e1,
              0x8F8E8D8C8B8A8988ull);
        check(
            e3 == 0x9F9E9D9C9B9A9998ull, "scalar load of element 3", 3, e3, 0x9F9E9D9C9B9A9998ull);
        check(gap == pat_word((0x800u >> 3) + 1u),
              "gap word unchanged",
              0,
              gap,
              pat_word((0x800u >> 3) + 1u));
    }

    /* A strided load, then a younger scalar store to its first element: the
     * load reads the old value. */
    fill_buf();
    setvl(4, 0x1Aul);
    {
        volatile uint64_t *d = (volatile uint64_t *) (buf + 0xC00);
        uint64_t old = d[0];
        __asm__ volatile(".insn r 0x07, 7, 0x05, x8, %0, %1\n"
                         "sd %2, 0(%0)\n"
                         :
                         : "r"(DDR_BUF + 0xC00u), "r"(40l), "r"(0x5555AAAA5555AAAAull)
                         : "memory");
        store_v8_group(dump);
        check(((const volatile uint64_t *) dump)[0] == old,
              "younger store after a strided load",
              0,
              ((const volatile uint64_t *) dump)[0],
              old);
        check(d[0] == 0x5555AAAA5555AAAAull, "younger store lands", 0, d[0], 0x5555AAAA5555AAAAull);
    }

    /* A strided store followed by an AMO, LR/SC and a strided load of the same
     * element. */
    for (unsigned long i = 0; i < 64u; i++)
        vrf_io[i] = (uint8_t) (0x10u + i);
    load_v8_group(vrf_io);
    setvl(3, 0x1Aul);
    {
        volatile uint64_t *d = (volatile uint64_t *) (buf + 0x1000);
        uint64_t got_amo, got_lr, sc_fail;
        __asm__ volatile(".insn r 0x27, 7, 0x05, x8, %3, %4\n"
                         "amoadd.d %0, %5, (%3)\n"
                         "1: lr.d %1, (%3)\n"
                         "addi %2, %1, 1\n"
                         "sc.d %2, %2, (%3)\n"
                         "bnez %2, 1b\n"
                         : "=&r"(got_amo), "=&r"(got_lr), "=&r"(sc_fail)
                         : "r"(DDR_BUF + 0x1000u), "r"(24l), "r"(1ul)
                         : "memory");
        check(got_amo == 0x1716151413121110ull,
              "AMO after a strided store",
              0,
              got_amo,
              0x1716151413121110ull);
        check(
            got_lr == 0x1716151413121111ull, "LR after the AMO", 0, got_lr, 0x1716151413121111ull);
        check(d[0] == 0x1716151413121112ull, "SC result", 0, d[0], 0x1716151413121112ull);
        setvl(3, 0x1Aul);
        vlse_v8(DDR_BUF + 0x1000u, 24, 7, 1);
        store_v8_group(dump);
        const volatile uint64_t *v = (const volatile uint64_t *) dump;
        check(v[0] == 0x1716151413121112ull && v[1] == 0x1F1E1D1C1B1A1918ull &&
                  v[2] == 0x2726252423222120ull,
              "strided load after AMO and SC",
              0,
              v[0],
              0x1716151413121112ull);
    }
}

/* ========================================================================== */
/* 5. Pointer masking of element addresses                                    */
/* ========================================================================== */
static void senvcfg_write(unsigned long v)
{
    __asm__ volatile("csrw 0x10A, %0" : : "r"(v) : "memory");
}

static void test_pointer_masking(void)
{
    volatile uint8_t *dump = vrf_io + 1024;
    const unsigned long tag7 = 0x5Bul << 57;

    /* Bare, MPRV with MPP = U and PMLEN 7: the tag is removed (zero
     * extension) from every element address, strided and unit-stride. */
    fill_buf();
    senvcfg_write(PMM_PMLEN7);
    seed_v8_group(0x66u);
    setvl(4, 0x10ul);
    MPRV_STRIDED(MPRV_U_ON, VLSE32_V8, (DDR_BUF + 0x300u) | tag7, 36l);
    check(g_cause == ~0ul, "tagged strided load under Bare", 0, g_cause, ~0ul);
    store_v8_group(dump);
    for (unsigned long b = 0; b < 16u; b++)
        check(dump[b] == ref[0x300u + (b / 4u) * 36u + b % 4u],
              "tagged strided load data",
              b,
              dump[b],
              ref[0x300u + (b / 4u) * 36u + b % 4u]);
    for (unsigned long i = 0; i < 16u; i++)
        vrf_io[i] = (uint8_t) (0xE0u + i);
    load_v8_group(vrf_io);
    setvl(4, 0x10ul);
    MPRV_STRIDED(MPRV_U_ON, VSSE32_V8, (DDR_BUF + 0x900u) | tag7, -20l);
    check(g_cause == ~0ul, "tagged strided store under Bare", 0, g_cause, ~0ul);
    for (unsigned long i = 0; i < 4u; i++)
        for (unsigned b = 0; b < 4u; b++)
            ref[0x900u - i * 20u + b] = (uint8_t) (0xE0u + i * 4u + b);
    check_buf("tagged strided store image", 0);
    seed_v8_group(0x67u);
    setvl(4, 0x10ul);
    MPRV_STRIDED(MPRV_U_ON, VLE32_V8, (DDR_BUF + 0xFF8u) | tag7, 0l);
    check(g_cause == ~0ul, "tagged unit-stride load across a page", 0, g_cause, ~0ul);
    store_v8_group(dump);
    for (unsigned long b = 0; b < 16u; b++)
        check(dump[b] == ref[0xFF8u + b], "tagged unit-stride data", b, dump[b], ref[0xFF8u + b]);

    /* Without masking the tagged address is not memory: an access fault with
     * the address as it was. */
    senvcfg_write(0);
    setvl(4, 0x10ul);
    MPRV_STRIDED(MPRV_U_ON, VLSE32_V8, (DDR_BUF + 0x300u) | tag7, 36l);
    check(g_cause == CAUSE_LOAD_ACCESS && g_tval == ((DDR_BUF + 0x300u) | tag7) &&
              g_vstart_trap == 0,
          "tagged address without masking faults",
          g_tval,
          g_cause,
          CAUSE_LOAD_ACCESS);
    wr_vstart(0);

    /* Sv39 with U pages 4 and 5 (page 6 unmapped): sign extension from bit
     * 56; the fault reports the masked address of the faulting element. */
    setup_sv39();
    fill_frames();
    senvcfg_write(PMM_PMLEN7);
    seed_v8_group(0x68u);
    setvl(4, 0x10ul);
    MPRV_STRIDED(MPRV_U_ON, VLSE32_V8, (VA_BASE + 4u * 4096u + 0xFF0u) | tag7, 0x804l);
    check(g_cause == CAUSE_LOAD_PAGE && g_tval == VA_BASE + 6u * 4096u + 0x7FCu &&
              g_vstart_trap == 3u,
          "tagged Sv39 strided load faults at element 3 with the masked address",
          g_tval,
          g_cause,
          CAUSE_LOAD_PAGE);
    wr_vstart(0);
    check_v8_e32("tagged Sv39 elements 0..2", 4, 0, 3, 4u * 4096u + 0xFF0u, 0x804, 0x68u);
    senvcfg_write(0);
    __asm__ volatile("csrw satp, zero\n sfence.vma" ::: "memory");
}

/* ========================================================================== */
/* 6. Legality                                                                */
/* ========================================================================== */
static void expect_illegal(const char *what)
{
    check(g_cause == CAUSE_ILLEGAL, what, g_epc, g_cause, CAUSE_ILLEGAL);
}

static void test_legality(void)
{
    unsigned long p = DDR_BUF + 0x100u;
    long s = 8;
    set_vs(VS_CLEAN);
    setvl(1, 0x1Ful); /* e64 mf2: vill */
    RUN_TRAP_STRIDED(VLSE32_V8, p, s);
    expect_illegal("vill vlse32");
    RUN_TRAP_STRIDED(VSSE32_V8, p, s);
    expect_illegal("vill vsse32");
    setvl(4, 0x03ul); /* e8 m8: vlse16 has EMUL 16 */
    RUN_TRAP_STRIDED(".insn r 0x07, 5, 0x05, x8, %0, %1", p, s);
    expect_illegal("EMUL 16 vlse16");
    setvl(4, 0x11ul); /* e32 m2: vd = v9 is misaligned */
    RUN_TRAP_STRIDED(".insn r 0x07, 6, 0x05, x9, %0, %1", p, s);
    expect_illegal("EMUL 2 vlse32 vd=v9");
    RUN_TRAP_STRIDED(".insn r 0x27, 6, 0x05, x9, %0, %1", p, s);
    expect_illegal("EMUL 2 vsse32 vs3=v9");
    setvl(4, 0x10ul);
    /* vsetvl sets VS Dirty; an illegal vector load leaves it as it was. */
    set_vs(VS_CLEAN);
    RUN_TRAP_STRIDED(".insn r 0x07, 6, 0x04, x0, %0, %1", p, s);
    expect_illegal("masked vlse32 vd=v0");
    check(vs_field() == VS_CLEAN, "illegal strided forms keep VS Clean", 0, vs_field(), VS_CLEAN);
    /* A masked strided store of v0 reads v0 as data and as the mask (EEW 1):
     * reserved, so it traps and writes nothing. */
    fill_buf();
    for (unsigned long b = 0; b < g_vlenb; b++)
        vrf_io[b] = (uint8_t) (b == 0 ? 0x05u : 0x40u + b);
    load_v0(vrf_io);
    setvl(4, 0x10ul);
    RUN_TRAP_STRIDED(".insn r 0x27, 6, 0x04, x0, %0, %1", p, s);
    expect_illegal("masked vsse32 vs3=v0");
    check_buf("masked vsse32 of v0 wrote nothing", 0);
}

/* ========================================================================== */
/* 7. Timer interrupts during element runs                                    */
/* ========================================================================== */
__attribute__((naked, aligned(4))) static void timer_handler(void)
{
    __asm__ volatile("addi sp, sp, -16\n"
                     "sd   t0, 0(sp)\n"
                     "sd   t1, 8(sp)\n"
                     "la   t0, g_irq\n"
                     "lw   t1, 0(t0)\n"
                     "addi t1, t1, 1\n"
                     "sw   t1, 0(t0)\n"
                     "li   t0, 0x4000001c\n" /* MTIMECMP_HI = ~0u: disarm until the next case */
                     "li   t1, -1\n"
                     "sw   t1, 0(t0)\n"
                     "ld   t0, 0(sp)\n"
                     "ld   t1, 8(sp)\n"
                     "addi sp, sp, 16\n"
                     "mret\n");
}

static void test_interrupts(void)
{
    volatile uint8_t *dump = vrf_io + 1024;
    set_trap_handler(&timer_handler);
    g_irq = 0;
    MTIMECMP_HI = 0xFFFFFFFFu;
    enable_timer_interrupt();
    enable_interrupts();
    fill_buf();
    for (unsigned long iter = 0; iter < 12u; iter++) {
        unsigned long off = 0x40u + iter * 7u;
        long stride = 5 + (long) iter;
        unsigned long vl = setvl(~0ul, 0x01ul); /* e8 m2 */
        MTIMECMP_HI = 0xFFFFFFFFu;
        MTIMECMP_LO = MTIME_LO + 4u + (uint32_t) (iter * 9u);
        MTIMECMP_HI = 0u;
        vlse_v8(DDR_BUF + off, stride, 0, 1);
        store_v8_group(dump);
        for (unsigned long i = 0; i < vl; i++) {
            uint8_t want = ref[off + i * (unsigned long) stride];
            if (dump[i] != want) {
                check(0, "strided load under timer interrupts", (iter << 16) | i, dump[i], want);
                break;
            }
        }
    }
    disable_interrupts();
    disable_timer_interrupt();
    set_trap_handler(&bounce_handler);
    check(g_irq >= 4u, "timer interrupts taken around element runs", 0, g_irq, 4u);
}

int main(void)
{
    csr_write(mscratch, 0);
    set_trap_handler(&bounce_handler);
    set_vs(VS_INITIAL);
    __asm__ volatile("csrr %0, 0xC22" : "=r"(g_vlenb));
    uart_printf("vec_stride_test VLEN=%lu\n", g_vlenb * 8u);
    check(g_vlenb == 16u || g_vlenb == 32u || g_vlenb == 64u, "supported VLEN", 0, g_vlenb, 32u);

    test_geometry();
    uart_printf("  [1,2] geometry, masks, vstart ok\n");
    test_faults();
    uart_printf("  [3] faults ok\n");
    test_ordering();
    uart_printf("  [4] ordering ok\n");
    test_pointer_masking();
    uart_printf("  [5] pointer masking ok\n");
    test_legality();
    uart_printf("  [6] legality ok\n");
    test_interrupts();
    uart_printf("  [7] interrupts ok\n");

    uart_printf("%d checks\n", g_checks);
    uart_printf(g_ok ? "<<PASS>>\n" : "<<FAIL>>\n");
    for (;;) {
    }
    return 0;
}
