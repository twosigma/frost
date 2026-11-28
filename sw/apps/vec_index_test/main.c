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
 * Directed test for indexed vector loads and stores (vluxei, vloxei, vsuxei,
 * vsoxei) across VLEN 128, 256 and 512:
 *   1. Every data SEW with every index EEW whose index EMUL is legal, with
 *      unsigned byte offsets that are reversed, scattered, misaligned, across
 *      sector, line and page boundaries, and repeated. Elements are performed
 *      in element order, so repeated offsets leave the last element's bytes.
 *   2. Masked elements, vstart > 0 and tail elements keep their old values.
 *   3. The register overlaps the specification permits between the
 *      destination and the index group, and the ones it reserves.
 *   4. Precise faults: an element in low BRAM (bare) and an Sv39 page fault
 *      part-way through report vstart = the faulting element and mtval = its
 *      address after the elements before it are performed; the re-executed
 *      instruction resumes at vstart.
 *   5. Scalar-vector ordering on element addresses, pointer masking of the
 *      element addresses under MPRV with MPP = U, legality, and timer
 *      interrupts during long gathers.
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

static unsigned width_bytes(int width)
{
    return width == 0 ? 1u : width == 5 ? 2u : width == 6 ? 4u : 8u;
}

/* The index register image: element i of v16.. holds offs[i] at the index
 * width. */
static unsigned long g_offs[512];

static void load_index(unsigned ieew, unsigned long n)
{
    volatile uint8_t *io = vrf_io + 2048;
    for (unsigned long i = 0; i < n; i++)
        for (unsigned b = 0; b < ieew; b++)
            io[i * ieew + b] = (uint8_t) (g_offs[i] >> (8u * b));
    load_v16_group(io);
}

/* Indexed load into v8 or store from v8 with the index in v16: index width
 * code 0/5/6/7, mop 1 (unordered) or 3 (ordered), vm 0 or 1. funct7 =
 * mop << 1 | vm. */
#define VLX(w, f7)                                                                                 \
    __asm__ volatile(".insn r 0x07, " #w ", " #f7 ", x8, %0, x16" ::"r"(p) : "memory")
#define VSX(w, f7)                                                                                 \
    __asm__ volatile(".insn r 0x27, " #w ", " #f7 ", x8, %0, x16" ::"r"(p) : "memory")

static void vlx_v8(unsigned long p, int width, int ordered, int vm)
{
    switch ((width * 2 + ordered) * 2 + vm) {
        case 0:
            VLX(0, 0x02);
            break;
        case 1:
            VLX(0, 0x03);
            break;
        case 2:
            VLX(0, 0x06);
            break;
        case 3:
            VLX(0, 0x07);
            break;
        case 20:
            VLX(5, 0x02);
            break;
        case 21:
            VLX(5, 0x03);
            break;
        case 22:
            VLX(5, 0x06);
            break;
        case 23:
            VLX(5, 0x07);
            break;
        case 24:
            VLX(6, 0x02);
            break;
        case 25:
            VLX(6, 0x03);
            break;
        case 26:
            VLX(6, 0x06);
            break;
        case 27:
            VLX(6, 0x07);
            break;
        case 28:
            VLX(7, 0x02);
            break;
        case 29:
            VLX(7, 0x03);
            break;
        case 30:
            VLX(7, 0x06);
            break;
        default:
            VLX(7, 0x07);
            break;
    }
}

static void vsx_v8(unsigned long p, int width, int ordered, int vm)
{
    switch ((width * 2 + ordered) * 2 + vm) {
        case 0:
            VSX(0, 0x02);
            break;
        case 1:
            VSX(0, 0x03);
            break;
        case 2:
            VSX(0, 0x06);
            break;
        case 3:
            VSX(0, 0x07);
            break;
        case 20:
            VSX(5, 0x02);
            break;
        case 21:
            VSX(5, 0x03);
            break;
        case 22:
            VSX(5, 0x06);
            break;
        case 23:
            VSX(5, 0x07);
            break;
        case 24:
            VSX(6, 0x02);
            break;
        case 25:
            VSX(6, 0x03);
            break;
        case 26:
            VSX(6, 0x06);
            break;
        case 27:
            VSX(6, 0x07);
            break;
        case 28:
            VSX(7, 0x02);
            break;
        case 29:
            VSX(7, 0x03);
            break;
        case 30:
            VSX(7, 0x06);
            break;
        default:
            VSX(7, 0x07);
            break;
    }
}

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

/* One indexed load and one indexed store at data SEW sew bytes (vtype) with
 * index width code iwidth, against the model. */
static void run_case(unsigned long vtype,
                     unsigned sew,
                     int iwidth,
                     int ordered,
                     unsigned long avl,
                     unsigned long vstart,
                     int vm,
                     unsigned long ctx)
{
    volatile uint8_t *dump = vrf_io + 1024;
    unsigned ieew = width_bytes(iwidth);

    seed_v8_group(0x3Cu);
    if (!vm)
        load_mask();
    unsigned long vl = setvl(avl, vtype);
    load_index(ieew, vl);
    vl = setvl(avl, vtype);
    if (vstart)
        wr_vstart(vstart);
    set_vs(VS_CLEAN);
    vlx_v8(DDR_BUF, iwidth, ordered, vm);
    check(vs_field() == VS_DIRTY, "indexed load sets VS Dirty", ctx, vs_field(), VS_DIRTY);
    check(rd_vstart() == 0, "indexed load clears vstart", ctx, rd_vstart(), 0);
    store_v8_group(dump);
    unsigned long cmp = vl * sew + 32u;
    if (cmp > 8u * g_vlenb)
        cmp = 8u * g_vlenb;
    for (unsigned long b = 0; b < cmp; b++) {
        unsigned long i = b / sew;
        uint8_t want = seed_byte(0x3Cu, b);
        if (i < vl && i >= vstart && (vm || mask_bit(i)))
            want = ref[g_offs[i] + b % sew];
        if (dump[b] != want) {
            check(0, "indexed load byte", (ctx << 16) | b, dump[b], want);
            break;
        }
    }
    g_checks++;

    seed_v8_group(0xA5u);
    if (!vm)
        load_mask();
    vl = setvl(avl, vtype);
    if (vstart)
        wr_vstart(vstart);
    set_vs(VS_CLEAN);
    vsx_v8(DDR_BUF, iwidth, ordered, vm);
    check(vs_field() == (vstart ? VS_DIRTY : VS_CLEAN),
          "indexed store VS",
          ctx,
          vs_field(),
          vstart ? VS_DIRTY : VS_CLEAN);
    for (unsigned long i = vstart; i < vl; i++) {
        if (!vm && !mask_bit(i))
            continue;
        for (unsigned b = 0; b < sew; b++)
            ref[g_offs[i] + b] = seed_byte(0xA5u, i * sew + b);
    }
    for (unsigned long i = 0; i < vl; i++)
        check_window(
            "indexed store image", ctx, (long) g_offs[i] - 8, (long) (g_offs[i] + sew + 8u));
    g_checks++;
}

/* Offset patterns: 0 reversed, 1 scattered with page crossings, 2 repeated,
 * each limited to what the index width can hold. */
static void make_offsets(int pattern, unsigned ieew, unsigned sew, unsigned long n)
{
    unsigned long lim = ieew == 1 ? 256u - sew : BUF_BYTES - sew - 1u;
    for (unsigned long i = 0; i < n; i++) {
        unsigned long o;
        if (pattern == 0)
            o = (n - 1u - i) * sew;
        else if (pattern == 1)
            o = (i * 0x9E5u + 4093u - (i & 3u) * 7u) % (lim + 1u);
        else
            o = 0x123u % (lim + 1u);
        if (o > lim)
            o = lim;
        g_offs[i] = o;
    }
}

struct cfg {
    unsigned long vtype;
    unsigned sew;
    unsigned long lmul_x8;
    int iwidth;
};

/* Index EMUL = EEW_index / SEW * LMUL stays within [1/8, 8]. */
static const struct cfg g_cfgs[] = {
    {0x00, 1, 8, 0},  /* e8 m1, index 8 */
    {0x00, 1, 8, 7},  /* e8 m1, index 64 (EMUL 8) */
    {0x09, 2, 16, 0}, /* e16 m2, index 8 (EMUL 1) */
    {0x09, 2, 16, 6}, /* e16 m2, index 32 (EMUL 4) */
    {0x10, 4, 8, 5},  /* e32 m1, index 16 (EMUL 1/2) */
    {0x10, 4, 8, 6},  /* e32 m1, index 32 */
    {0x1A, 8, 32, 0}, /* e64 m4, index 8 (EMUL 1/2) */
    {0x18, 8, 8, 7},  /* e64 m1, index 64 */
    {0x17, 4, 4, 0},  /* e32 mf2, index 8 (EMUL 1/8) */
};

static void test_geometry(void)
{
    fill_buf();
    for (unsigned c = 0; c < sizeof g_cfgs / sizeof g_cfgs[0]; c++) {
        const struct cfg *cf = &g_cfgs[c];
        unsigned ieew = width_bytes(cf->iwidth);
        unsigned long vlmax = g_vlenb * cf->lmul_x8 / (8u * cf->sew);
        unsigned long avl = vlmax < 20u ? vlmax : 20u;
        for (int pattern = 0; pattern < 3; pattern++) {
            make_offsets(pattern, ieew, cf->sew, avl);
            run_case(cf->vtype,
                     cf->sew,
                     cf->iwidth,
                     pattern & 1,
                     avl,
                     0,
                     1,
                     (c << 8) | (unsigned) pattern);
        }
        make_offsets(1, ieew, cf->sew, avl);
        run_case(cf->vtype, cf->sew, cf->iwidth, 1, avl, avl > 2 ? 2u : 0u, 0, (c << 8) | 0x80);
    }
    /* Every element of a large group. */
    unsigned long n = g_vlenb * 4u;
    make_offsets(1, 2, 1, n);
    run_case(0x02, 1, 5, 0, n, 0, 1, 0xE00); /* e8 m4, index 16 (EMUL 8) */
}

/* ========================================================================== */
/* 3. Register overlap between the destination and the index group           */
/* ========================================================================== */
#define RUN_TRAP(insn_asm, base)                                                                   \
    do {                                                                                           \
        g_cause = ~0ul;                                                                            \
        g_tval = ~0ul;                                                                             \
        g_vstart_trap = ~0ul;                                                                      \
        __asm__ volatile("la t0, 1f\n csrw mscratch, t0\n" insn_asm "\n1:\n csrw mscratch, zero\n" \
                         :                                                                         \
                         : "r"(base)                                                               \
                         : "t0", "memory");                                                        \
    } while (0)

static void test_overlap(void)
{
    volatile uint8_t *dump = vrf_io + 1024;
    unsigned long n;

    /* Same EEW: vluxei32 v8, (a0), v8. Each element's index is read before
     * the element is written. */
    fill_buf();
    n = setvl(8, 0x10ul); /* e32 m1 */
    {
        volatile uint32_t *io = (volatile uint32_t *) (vrf_io + 2048);
        for (unsigned long i = 0; i < n; i++)
            io[i] = (uint32_t) ((n - 1u - i) * 8u + 4u);
        __asm__ volatile(".insn r 0x07, 0, 0x01, x8, %0, x8" : : "r"(vrf_io + 2048) : "memory");
    }
    setvl(8, 0x10ul);
    RUN_TRAP(".insn r 0x07, 6, 0x03, x8, %0, x8", DDR_BUF);
    check(g_cause == ~0ul, "vluxei32 with vd = vs2 is legal", 0, g_cause, ~0ul);
    store_v8_group(dump);
    for (unsigned long i = 0; i < n; i++)
        for (unsigned b = 0; b < 4u; b++)
            check(dump[i * 4u + b] == ref[(n - 1u - i) * 8u + 4u + b],
                  "vd = vs2 gather",
                  i,
                  dump[i * 4u + b],
                  ref[(n - 1u - i) * 8u + 4u + b]);

    /* Destination EEW below the index EEW: the destination may be the index
     * group's lowest register (e8 m1 data in v8, 16-bit index in v8..v9). */
    n = setvl(8, 0x00ul); /* e8 m1 */
    {
        volatile uint16_t *io = (volatile uint16_t *) (vrf_io + 2048);
        for (unsigned long i = 0; i < 2u * g_vlenb / 2u; i++)
            io[i] = (uint16_t) (i * 3u + 1u);
        __asm__ volatile(".insn r 0x07, 0, 0x11, x8, %0, x8" : : "r"(vrf_io + 2048) : "memory");
    }
    setvl(8, 0x00ul);
    RUN_TRAP(".insn r 0x07, 5, 0x03, x8, %0, x8", DDR_BUF);
    check(g_cause == ~0ul, "vluxei16 e8 with vd at vs2's low register", 0, g_cause, ~0ul);
    store_v8_group(dump);
    for (unsigned long i = 0; i < n; i++)
        check(dump[i] == ref[i * 3u + 1u], "low-part overlap gather", i, dump[i], ref[i * 3u + 1u]);
    /* The index group's high register is reserved as a destination. */
    setvl(8, 0x00ul);
    RUN_TRAP(".insn r 0x07, 5, 0x03, x9, %0, x8", DDR_BUF);
    check(g_cause == CAUSE_ILLEGAL,
          "vd at vs2's high register is reserved",
          0,
          g_cause,
          CAUSE_ILLEGAL);

    /* Destination EEW above the index EEW: the index group may be the
     * destination group's highest register (e16 m2 data in v8..v9, 8-bit
     * index in v9). */
    n = setvl(8, 0x09ul); /* e16 m2 */
    {
        volatile uint8_t *io = vrf_io + 2048;
        for (unsigned long i = 0; i < g_vlenb; i++)
            io[g_vlenb + i] = (uint8_t) (i * 6u);
        __asm__ volatile(".insn r 0x07, 0, 0x11, x8, %0, x8" : : "r"(vrf_io + 2048) : "memory");
    }
    setvl(8, 0x09ul);
    RUN_TRAP(".insn r 0x07, 0, 0x03, x8, %0, x9", DDR_BUF);
    check(g_cause == ~0ul, "vluxei8 e16 with vs2 at vd's high register", 0, g_cause, ~0ul);
    store_v8_group(dump);
    for (unsigned long i = 0; i < n; i++)
        for (unsigned b = 0; b < 2u; b++)
            check(dump[i * 2u + b] == ref[i * 6u + b],
                  "high-part overlap gather",
                  i,
                  dump[i * 2u + b],
                  ref[i * 6u + b]);
    setvl(8, 0x09ul);
    RUN_TRAP(".insn r 0x07, 0, 0x03, x8, %0, x8", DDR_BUF);
    check(g_cause == CAUSE_ILLEGAL,
          "vs2 at vd's low register is reserved",
          0,
          g_cause,
          CAUSE_ILLEGAL);
    /* With a fractional index EMUL any overlap is reserved (e16 m1 data,
     * 8-bit index EMUL 1/2). */
    setvl(8, 0x08ul);
    RUN_TRAP(".insn r 0x07, 0, 0x03, x8, %0, x8", DDR_BUF);
    check(g_cause == CAUSE_ILLEGAL,
          "overlap with a fractional index group is reserved",
          0,
          g_cause,
          CAUSE_ILLEGAL);
    /* Stores read both groups: an overlap is legal when SEW equals the index
     * EEW, and reserved otherwise, since it reads one register at two widths. */
    setvl(8, 0x09ul);
    RUN_TRAP(".insn r 0x27, 0, 0x03, x8, %0, x8", DDR_BUF);
    check(g_cause == CAUSE_ILLEGAL,
          "vsuxei8 over its own index at SEW 16 is reserved",
          0,
          g_cause,
          CAUSE_ILLEGAL);
    setvl(8, 0x01ul);
    RUN_TRAP(".insn r 0x27, 0, 0x03, x8, %0, x8", DDR_BUF);
    check(g_cause == ~0ul, "vsuxei8 over its own index at SEW 8 is legal", 0, g_cause, ~0ul);
    fill_buf();
}

/* ========================================================================== */
/* 4. Precise faults and resumption                                           */
/* ========================================================================== */
#define MPRV_S_ON                                                                                  \
    "li t1, 0x1800\n csrc mstatus, t1\n li t1, 0x0800\n csrs mstatus, t1\n"                        \
    "li t1, 0x20000\n csrs mstatus, t1\n"
#define MPRV_U_ON                                                                                  \
    "li t1, 0x1800\n csrc mstatus, t1\n"                                                           \
    "li t1, 0x20000\n csrs mstatus, t1\n"
#define MPRV_OFF "1:\n li t1, 0x20000\n csrc mstatus, t1\n csrw mscratch, zero\n"

#define MPRV_INDEXED(mprv_on, insn_asm, base)                                                      \
    do {                                                                                           \
        g_cause = ~0ul;                                                                            \
        g_tval = ~0ul;                                                                             \
        g_vstart_trap = ~0ul;                                                                      \
        __asm__ volatile("la t0, 1f\n csrw mscratch, t0\n" mprv_on insn_asm "\n" MPRV_OFF          \
                         :                                                                         \
                         : "r"(base)                                                               \
                         : "t0", "t1", "memory");                                                  \
    } while (0)

/* vluxei64 / vsoxei64 v8, (base), v16 with e32 m1 data (index EMUL 2) */
#define VLUXEI64_E32 ".insn r 0x07, 7, 0x03, x8, %0, x16"
#define VSOXEI64_E32 ".insn r 0x27, 7, 0x07, x8, %0, x16"

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

static void check_v8_e32(const char *what, unsigned long vl, unsigned long upto, uint8_t fill)
{
    volatile uint8_t *dump = vrf_io + 1024;
    store_v8_group(dump);
    for (unsigned long b = 0; b < 4u * vl; b++) {
        unsigned long i = b / 4u;
        uint8_t want = (i < upto) ? frame_pat(g_offs[i] + b % 4u) : seed_byte(fill, b);
        if (dump[b] != want) {
            check(0, what, b, dump[b], want);
            return;
        }
    }
    g_checks++;
}

static void test_faults(void)
{
    /* Bare: mixed DDR + low BRAM succeeds; unmapped PA 0x40000 faults at element 1. */
    volatile uint64_t stack_word[2] __attribute__((aligned(16)));
    stack_word[0] = 0x1122334455667788ull;
    unsigned long bram = (unsigned long) &stack_word[0];
    fill_buf();
    seed_v8_group(0x77u);
    g_offs[0] = 0x300u;
    g_offs[1] = bram - DDR_BUF;
    g_offs[2] = 0x340u;
    setvl(3, 0x10ul);
    load_index(8, 3);
    setvl(3, 0x10ul);
    RUN_TRAP(VLUXEI64_E32, DDR_BUF);
    check(g_cause == ~0ul, "bare vluxei64 DDR+BRAM succeeds", 0, g_cause, ~0ul);
    {
        volatile uint32_t *dump32 = (volatile uint32_t *) (vrf_io + 1024);
        store_v8_group((volatile uint8_t *) dump32);
        check(dump32[1] == 0x55667788u,
              "bare vluxei64 BRAM element loaded",
              1,
              dump32[1],
              0x55667788u);
    }

    const unsigned long unmapped = 0x00040000ul;
    fill_buf();
    seed_v8_group(0x77u);
    g_offs[0] = 0x300u;
    g_offs[1] = unmapped - DDR_BUF; /* wraps to unmapped PA past low BRAM */
    g_offs[2] = 0x340u;
    setvl(3, 0x10ul);
    load_index(8, 3);
    setvl(3, 0x10ul);
    set_vs(VS_CLEAN);
    RUN_TRAP(VLUXEI64_E32, DDR_BUF);
    check(g_cause == CAUSE_LOAD_ACCESS && g_tval == unmapped && g_vstart_trap == 1u,
          "bare vluxei64 access fault at element 1",
          g_vstart_trap,
          g_cause,
          CAUSE_LOAD_ACCESS);
    check(vs_field() == VS_DIRTY, "partial indexed load dirties VS", 0, vs_field(), VS_DIRTY);
    wr_vstart(0);
    {
        volatile uint8_t *dump = vrf_io + 1024;
        store_v8_group(dump);
        for (unsigned long b = 0; b < 12u; b++) {
            uint8_t want = (b < 4u) ? ref[0x300u + b] : seed_byte(0x77u, b);
            check(dump[b] == want, "bare fault: element 0 loaded", b, dump[b], want);
        }
    }
    seed_v8_group(0x99u);
    setvl(3, 0x10ul);
    RUN_TRAP(VSOXEI64_E32, DDR_BUF);
    check(g_cause == CAUSE_STORE_ACCESS && g_tval == unmapped && g_vstart_trap == 1u,
          "bare vsoxei64 access fault at element 1",
          g_vstart_trap,
          g_cause,
          CAUSE_STORE_ACCESS);
    wr_vstart(0);
    for (unsigned b = 0; b < 4u; b++)
        ref[0x300u + b] = seed_byte(0x99u, b);
    check_window("bare fault: indexed store image", 0, 0x2F0, 0x350);
    check(stack_word[0] == 0x1122334455667788ull, "BRAM word untouched", 0, stack_word[0], 0);

    /* Sv39 under MPRV with MPP = S: element 2 points into unmapped page 2. */
    setup_sv39();
    fill_frames();
    map_page(2, 0);
    seed_v8_group(0x11u);
    g_offs[0] = 0x0104u;
    g_offs[1] = 0x1F00u;
    g_offs[2] = 0x2208u;
    g_offs[3] = 0x3010u;
    setvl(4, 0x10ul);
    load_index(8, 4);
    setvl(4, 0x10ul);
    MPRV_INDEXED(MPRV_S_ON, VLUXEI64_E32, VA_BASE);
    check(g_cause == CAUSE_LOAD_PAGE && g_tval == VA_BASE + 0x2208u && g_vstart_trap == 2u &&
              rd_vstart() == 2u,
          "Sv39 vluxei64 fault at element 2",
          g_tval,
          g_cause,
          CAUSE_LOAD_PAGE);
    wr_vstart(0);
    check_v8_e32("Sv39 partial gather", 4, 2, 0x11u);
    map_page(2, PTE_RW);
    setvl(4, 0x10ul);
    wr_vstart(2);
    MPRV_INDEXED(MPRV_S_ON, VLUXEI64_E32, VA_BASE);
    check(g_cause == ~0ul && rd_vstart() == 0, "Sv39 vluxei64 resumes", 0, g_cause, ~0ul);
    check_v8_e32("Sv39 resumed gather", 4, 4, 0x11u);
    __asm__ volatile("csrw satp, zero\n sfence.vma" ::: "memory");
}

/* ========================================================================== */
/* 5. Ordering, pointer masking, legality and interrupts                      */
/* ========================================================================== */
static void senvcfg_write(unsigned long v)
{
    __asm__ volatile("csrw 0x10A, %0" : : "r"(v) : "memory");
}

static void test_ordering_and_masking(void)
{
    volatile uint8_t *dump = vrf_io + 1024;
    fill_buf();
    /* Scalar stores right before a gather of the same words. */
    g_offs[0] = 0x808u;
    g_offs[1] = 0x400u;
    g_offs[2] = 0x1000u;
    setvl(3, 0x1Aul); /* e64 m4: index EMUL 4 */
    load_index(8, 3);
    setvl(3, 0x1Aul);
    *(volatile uint64_t *) (buf + 0x808) = 0x0808080808080808ull;
    *(volatile uint64_t *) (buf + 0x400) = 0x0404040404040404ull;
    *(volatile uint64_t *) (buf + 0x1000) = 0x1010101010101010ull;
    __asm__ volatile(".insn r 0x07, 7, 0x07, x8, %0, x16" : : "r"(DDR_BUF) : "memory");
    store_v8_group(dump);
    {
        const volatile uint64_t *d = (const volatile uint64_t *) dump;
        check(d[0] == 0x0808080808080808ull && d[1] == 0x0404040404040404ull &&
                  d[2] == 0x1010101010101010ull,
              "scalar stores before a gather",
              0,
              d[1],
              0x0404040404040404ull);
    }
    /* A scatter right before scalar loads of its elements. */
    for (unsigned long i = 0; i < 24u; i++)
        vrf_io[i] = (uint8_t) (0x50u + i);
    load_v8_group(vrf_io);
    setvl(3, 0x1Aul);
    __asm__ volatile(".insn r 0x27, 7, 0x07, x8, %0, x16" : : "r"(DDR_BUF) : "memory");
    {
        uint64_t a = *(volatile uint64_t *) (buf + 0x400);
        uint64_t b = *(volatile uint64_t *) (buf + 0x1000);
        check(
            a == 0x5F5E5D5C5B5A5958ull, "scalar load after a scatter", 1, a, 0x5F5E5D5C5B5A5958ull);
        check(b == 0x6766656463626160ull, "scalar load of element 2", 2, b, 0x6766656463626160ull);
    }

    /* Pointer masking under MPRV with MPP = U and Bare: the tag is removed
     * from base + index. */
    fill_buf();
    senvcfg_write(PMM_PMLEN7);
    seed_v8_group(0x66u);
    g_offs[0] = 0x0FFCu;
    g_offs[1] = 0x0200u;
    g_offs[2] = 0x2001u;
    g_offs[3] = 0x0010u;
    setvl(4, 0x10ul);
    load_index(8, 4);
    setvl(4, 0x10ul);
    MPRV_INDEXED(MPRV_U_ON, VLUXEI64_E32, DDR_BUF | (0x5Bul << 57));
    check(g_cause == ~0ul, "tagged gather under Bare", 0, g_cause, ~0ul);
    store_v8_group(dump);
    for (unsigned long b = 0; b < 16u; b++)
        check(dump[b] == ref[g_offs[b / 4u] + b % 4u],
              "tagged gather data",
              b,
              dump[b],
              ref[g_offs[b / 4u] + b % 4u]);
    senvcfg_write(0);
    setvl(4, 0x10ul);
    MPRV_INDEXED(MPRV_U_ON, VLUXEI64_E32, DDR_BUF | (0x5Bul << 57));
    check(g_cause == CAUSE_LOAD_ACCESS && g_tval == ((DDR_BUF + 0x0FFCu) | (0x5Bul << 57)),
          "tagged gather without masking faults",
          g_tval,
          g_cause,
          CAUSE_LOAD_ACCESS);
    wr_vstart(0);
}

static void expect_illegal(const char *what)
{
    check(g_cause == CAUSE_ILLEGAL, what, g_epc, g_cause, CAUSE_ILLEGAL);
}

static void test_legality(void)
{
    unsigned long p = DDR_BUF + 0x100u;
    set_vs(VS_CLEAN);
    setvl(1, 0x1Ful); /* vill */
    RUN_TRAP(".insn r 0x07, 6, 0x03, x8, %0, x16", p);
    expect_illegal("vill vluxei32");
    setvl(4, 0x01ul); /* e8 m2: a 64-bit index has EMUL 16 */
    RUN_TRAP(".insn r 0x07, 7, 0x03, x8, %0, x16", p);
    expect_illegal("index EMUL 16");
    setvl(4, 0x11ul); /* e32 m2: vd v9 misaligned */
    RUN_TRAP(".insn r 0x07, 6, 0x03, x9, %0, x16", p);
    expect_illegal("vluxei32 vd=v9 under m2");
    RUN_TRAP(".insn r 0x07, 6, 0x03, x8, %0, x17", p);
    expect_illegal("vluxei32 vs2=v17 with index EMUL 2");
    setvl(4, 0x10ul);
    /* vsetvl sets VS Dirty; an illegal vector load leaves it as it was. */
    set_vs(VS_CLEAN);
    RUN_TRAP(".insn r 0x07, 6, 0x02, x0, %0, x16", p);
    expect_illegal("masked vluxei32 vd=v0");
    check(vs_field() == VS_CLEAN, "illegal indexed forms keep VS Clean", 0, vs_field(), VS_CLEAN);
}

__attribute__((naked, aligned(4))) static void timer_handler(void)
{
    __asm__ volatile("addi sp, sp, -16\n"
                     "sd   t0, 0(sp)\n"
                     "sd   t1, 8(sp)\n"
                     "la   t0, g_irq\n"
                     "lw   t1, 0(t0)\n"
                     "addi t1, t1, 1\n"
                     "sw   t1, 0(t0)\n"
                     "li   t0, 0x4000001c\n"
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
    fill_buf();
    unsigned long vl = setvl(~0ul, 0x01ul); /* e8 m2 */
    make_offsets(1, 2, 1, vl);
    load_index(2, vl); /* 16-bit index: EMUL 4 */
    set_trap_handler(&timer_handler);
    g_irq = 0;
    MTIMECMP_HI = 0xFFFFFFFFu;
    enable_timer_interrupt();
    enable_interrupts();
    for (unsigned long iter = 0; iter < 8u; iter++) {
        setvl(~0ul, 0x01ul);
        MTIMECMP_HI = 0xFFFFFFFFu;
        MTIMECMP_LO = MTIME_LO + 4u + (uint32_t) (iter * 11u);
        MTIMECMP_HI = 0u;
        __asm__ volatile(".insn r 0x07, 5, 0x07, x8, %0, x16" : : "r"(DDR_BUF) : "memory");
        store_v8_group(dump);
        for (unsigned long i = 0; i < vl; i++) {
            if (dump[i] != ref[g_offs[i]]) {
                check(
                    0, "gather under timer interrupts", (iter << 16) | i, dump[i], ref[g_offs[i]]);
                break;
            }
        }
    }
    disable_interrupts();
    disable_timer_interrupt();
    set_trap_handler(&bounce_handler);
    check(g_irq >= 3u, "timer interrupts taken around gathers", 0, g_irq, 3u);
}

/* A gather whose destination is its own index group (vluxei8.v v8, (a0), v8
 * at e8 m8) under timer interrupts. Element i reads its index from v8[i]
 * before it writes v8[i]. An interrupt taken mid-run must stop at an element
 * boundary with mepc at the gather and vstart naming the next element so
 * resumption after mret starts at vstart and never re-reads indices already
 * overwritten. The handler records mepc and vstart. mtime counts cycles in
 * simulation, so a deadline compares with the mcycle stamps around the
 * gather. */
static volatile unsigned long g_irq_epc __attribute__((used));
static volatile unsigned long g_irq_vstart __attribute__((used));
static volatile unsigned long g_gather_start, g_gather_end;
extern char gather_overlap_insn[];

__attribute__((naked, aligned(4))) static void timer_stamp_handler(void)
{
    __asm__ volatile("addi sp, sp, -16\n"
                     "sd   t0, 0(sp)\n"
                     "sd   t1, 8(sp)\n"
                     "la   t0, g_irq\n"
                     "lw   t1, 0(t0)\n"
                     "addi t1, t1, 1\n"
                     "sw   t1, 0(t0)\n"
                     "csrr t1, mepc\n"
                     "la   t0, g_irq_epc\n"
                     "sd   t1, 0(t0)\n"
                     "csrr t1, 0x008\n"
                     "la   t0, g_irq_vstart\n"
                     "sd   t1, 0(t0)\n"
                     "li   t0, 0x4000001c\n"
                     "li   t1, -1\n"
                     "sw   t1, 0(t0)\n"
                     "ld   t0, 0(sp)\n"
                     "ld   t1, 8(sp)\n"
                     "addi sp, sp, 16\n"
                     "mret\n");
}

__attribute__((noinline)) static void gather_overlap(unsigned long base)
{
    unsigned long c0, c1;
    __asm__ volatile("csrr %0, mcycle\n"
                     ".globl gather_overlap_insn\n"
                     "gather_overlap_insn:\n"
                     ".insn r 0x07, 0, 0x03, x8, %2, x8\n"
                     "csrr %1, mcycle\n"
                     : "=&r"(c0), "=&r"(c1)
                     : "r"(base)
                     : "memory");
    g_gather_start = c0;
    g_gather_end = c1;
}

static void test_overlapping_gather_interrupts(void)
{
    volatile uint8_t *dump = vrf_io + 1024;
    for (unsigned x = 0; x < 256u; x++)
        buf[x] = (uint8_t) (x * 7u + 3u);
    static const uint32_t delays[] = {40, 150, 400, 900, 1600, 2500, 4000, 6000, 9000, 14000};
    unsigned inside = 0;
    set_trap_handler(&timer_stamp_handler);
    for (unsigned it = 0; it < sizeof delays / sizeof delays[0]; it++) {
        unsigned long vl = setvl(~0ul, 0x03ul); /* e8 m8 */
        for (unsigned long i = 0; i < 8u * g_vlenb; i++)
            vrf_io[i] = (uint8_t) (i * 5u + 1u);
        load_v8_group(vrf_io);
        setvl(~0ul, 0x03ul);
        g_irq = 0;
        g_irq_epc = 0;
        MTIMECMP_HI = 0xFFFFFFFFu;
        enable_timer_interrupt();
        enable_interrupts();
        unsigned long c_set;
        __asm__ volatile("csrr %0, mcycle" : "=r"(c_set));
        MTIMECMP_LO = MTIME_LO + delays[it];
        MTIMECMP_HI = 0u;
        gather_overlap(DDR_BUF);
        disable_interrupts();
        MTIMECMP_HI = 0xFFFFFFFFu;
        disable_timer_interrupt();
        /* A deadline well inside the gather's window is taken at an element boundary. */
        long rs = (long) (g_gather_start - c_set), re = (long) (g_gather_end - c_set);
        if ((long) delays[it] > rs + 300 && (long) delays[it] + 300 < re) {
            inside++;
            unsigned long at = g_irq_epc - (unsigned long) (uintptr_t) gather_overlap_insn;
            check(g_irq == 1u && at == 0u && g_irq_vstart > 0u && g_irq_vstart < vl,
                  "interrupt during a started gather taken at element boundary with vstart",
                  (it << 16) | g_irq_vstart,
                  at,
                  0u);
        }
        store_v8_group(dump);
        for (unsigned long i = 0; i < vl; i++) {
            uint8_t want = buf[(uint8_t) (i * 5u + 1u)];
            if (dump[i] != want) {
                check(
                    0, "overlapping gather under a timer interrupt", (it << 16) | i, dump[i], want);
                break;
            }
        }
        g_checks++;
    }
    set_trap_handler(&bounce_handler);
    check(inside > 0u, "a deadline fell inside a gather", 0, inside, 1);
}

int main(void)
{
    csr_write(mscratch, 0);
    set_trap_handler(&bounce_handler);
    set_vs(VS_INITIAL);
    __asm__ volatile("csrr %0, 0xC22" : "=r"(g_vlenb));
    uart_printf("vec_index_test VLEN=%lu\n", g_vlenb * 8u);
    check(g_vlenb == 16u || g_vlenb == 32u || g_vlenb == 64u, "supported VLEN", 0, g_vlenb, 32u);

    test_geometry();
    uart_printf("  [1,2] geometry, masks, vstart ok\n");
    test_overlap();
    uart_printf("  [3] register overlap ok\n");
    test_faults();
    uart_printf("  [4] faults ok\n");
    test_ordering_and_masking();
    uart_printf("  [5] ordering and pointer masking ok\n");
    test_legality();
    uart_printf("  [6] legality ok\n");
    test_interrupts();
    uart_printf("  [7] interrupts ok\n");
    test_overlapping_gather_interrupts();
    uart_printf("  [8] overlapping gather under interrupts ok\n");

    uart_printf("%d checks\n", g_checks);
    uart_printf(g_ok ? "<<PASS>>\n" : "<<FAIL>>\n");
    for (;;) {
    }
    return 0;
}
