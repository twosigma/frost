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
 * Directed test for segment vector loads and stores across VLEN 128, 256 and
 * 512, with unit-stride (vlseg, vsseg), strided (vlsseg, vssseg) and indexed
 * (vluxseg, vloxseg, vsuxseg, vsoxseg) addressing:
 *   1. NF 2 to 8 at every EEW, fields of one and of several registers, field
 *      order (field f of segment i is the f-th EEW-sized value of the
 *      segment), segments across sector, line and page boundaries, masks,
 *      vstart and tails.
 *   2. Precise faults: a segment that reaches an unmapped Sv39 page traps
 *      with vstart = the segment and mtval = the first byte in that page,
 *      before any field of that segment is accessed, after the earlier
 *      segments are performed; the re-executed instruction resumes.
 *   3. Legality: NF * EMUL above 8, field groups past v31, and an indexed
 *      segment load whose fields overlap the index group are reserved.
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
static uint32_t vmem_insn(int store, unsigned nf, int mop, int vm, int width)
{
    uint32_t rs2 = mop == 2 ? 11u : (mop & 1) ? 16u : 0u;
    return ((uint32_t) (nf - 1u) << 29) | ((uint32_t) mop << 26) | ((uint32_t) vm << 25) |
           (rs2 << 20) | (10u << 15) | ((uint32_t) width << 12) | (8u << 7) |
           (store ? 0x27u : 0x07u);
}

static unsigned long g_addr[512];

/* One segment load and one segment store with NF fields: segment i at
 * DDR_BUF + g_addr[i]; fields of regs registers each from v8. */
static void run_seg(int mop,
                    unsigned nf,
                    int width,
                    unsigned long vtype,
                    unsigned regs,
                    int vm,
                    unsigned long vstart,
                    unsigned long avl,
                    long stride,
                    unsigned long ctx)
{
    volatile uint8_t *dump = vrf_io + 1024;
    unsigned eew = width_bytes(width);
    /* Unit-stride and strided segments start at segment 0's address; indexed
     * ones add their offsets to the buffer. */
    unsigned long base = (mop & 1) ? DDR_BUF : DDR_BUF + g_addr[0];
    /* Load. */
    seed_v8_group(0x5Au);
    if (!vm)
        load_mask();
    unsigned long vl = setvl(avl, vtype);
    if (mop & 1) {
        for (unsigned long i = 0; i < vl; i++)
            g_offs[i] = g_addr[i];
        load_index(2, vl); /* 16-bit indices */
        vl = setvl(avl, vtype);
    }
    if (vstart)
        wr_vstart(vstart);
    exec_vec(vmem_insn(0, nf, mop, vm, mop & 1 ? 5 : width), base, stride, 0);
    check(g_cause == ~0ul, "segment load completes", ctx, g_cause, ~0ul);
    store_v8_group(dump);
    for (unsigned f = 0; f < nf; f++) {
        unsigned long lim = vl + 2u;
        if (lim * eew > regs * g_vlenb)
            lim = regs * g_vlenb / eew;
        for (unsigned long i = 0; i < lim; i++) {
            for (unsigned b = 0; b < eew; b++) {
                unsigned long r = f * regs * g_vlenb + i * eew + b;
                uint8_t want = seed_byte(0x5Au, r);
                if (i < vl && i >= vstart && (vm || mask_bit(i)))
                    want = ref[g_addr[i] + f * eew + b];
                if (dump[r] != want) {
                    check(0, "segment load byte", (ctx << 16) | (f << 12) | i, dump[r], want);
                    goto stored;
                }
            }
        }
    }
    g_checks++;
stored:
    /* Store: fields go to consecutive EEW-sized slots of each segment. */
    seed_v8_group(0xC3u);
    if (!vm)
        load_mask();
    vl = setvl(avl, vtype);
    if (vstart)
        wr_vstart(vstart);
    exec_vec(vmem_insn(1, nf, mop, vm, mop & 1 ? 5 : width), base, stride, 0);
    check(g_cause == ~0ul, "segment store completes", ctx, g_cause, ~0ul);
    for (unsigned long i = vstart; i < vl; i++) {
        if (!vm && !mask_bit(i))
            continue;
        for (unsigned f = 0; f < nf; f++)
            for (unsigned b = 0; b < eew; b++)
                ref[g_addr[i] + f * eew + b] = seed_byte(0xC3u, f * regs * g_vlenb + i * eew + b);
    }
    for (unsigned long i = 0; i < vl; i++)
        check_window(
            "segment store image", ctx, (long) g_addr[i] - 8, (long) (g_addr[i] + nf * eew + 8u));
    g_checks++;
}

static void test_geometry(void)
{
    static const struct {
        unsigned nf;
        int width;
        unsigned long vtype;
        unsigned regs;
    } cfgs[] = {
        {2, 0, 0x00, 1}, /* e8 m1 */
        {3, 5, 0x08, 1}, /* e16 m1 */
        {4, 6, 0x10, 1}, /* e32 m1 */
        {5, 7, 0x18, 1}, /* e64 m1 */
        {8, 0, 0x00, 1}, /* e8 m1, eight fields */
        {7, 6, 0x10, 1}, /* e32 m1, seven fields */
        {2, 6, 0x11, 2}, /* e32 m2: two-register fields */
        {4, 5, 0x09, 2}, /* e16 m2, four fields of two registers */
        {2, 7, 0x1A, 4}, /* e64 m4: four-register fields */
        {3, 0, 0x07, 1}, /* e8 mf2 */
    };
    fill_buf();
    for (unsigned c = 0; c < sizeof cfgs / sizeof cfgs[0]; c++) {
        unsigned eew = width_bytes(cfgs[c].width);
        unsigned seg = cfgs[c].nf * eew;
        unsigned long avl = 12;
        /* Unit-stride: segments are contiguous from just below a page. */
        unsigned long off = 4096u - 2u * seg - 3u;
        for (unsigned long i = 0; i < avl; i++)
            g_addr[i] = off + i * seg;
        run_seg(0, cfgs[c].nf, cfgs[c].width, cfgs[c].vtype, cfgs[c].regs, 1, 0, avl, 0, c << 4);
        /* Strided: a stride that is not the segment size, and a negative one. */
        long stride = (long) seg + 13;
        for (unsigned long i = 0; i < avl; i++)
            g_addr[i] = (unsigned long) ((long) 0x900 + (long) i * stride);
        run_seg(2,
                cfgs[c].nf,
                cfgs[c].width,
                cfgs[c].vtype,
                cfgs[c].regs,
                1,
                0,
                avl,
                stride,
                (c << 4) | 1);
        stride = -(long) seg - 40;
        for (unsigned long i = 0; i < avl; i++)
            g_addr[i] = (unsigned long) ((long) 0x2000 + (long) i * stride);
        run_seg(2,
                cfgs[c].nf,
                cfgs[c].width,
                cfgs[c].vtype,
                cfgs[c].regs,
                0,
                1,
                avl,
                stride,
                (c << 4) | 2);
        /* Indexed, ordered and unordered, with 16-bit offsets across a page. */
        for (unsigned long i = 0; i < avl; i++)
            g_addr[i] = (0x1F00u + (avl - 1u - i) * (seg + 7u)) % (BUF_BYTES - 128u);
        run_seg(
            1, cfgs[c].nf, cfgs[c].width, cfgs[c].vtype, cfgs[c].regs, 1, 0, avl, 0, (c << 4) | 3);
        run_seg(
            3, cfgs[c].nf, cfgs[c].width, cfgs[c].vtype, cfgs[c].regs, 0, 2, avl, 0, (c << 4) | 4);
    }
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

static void test_faults(void)
{
    volatile uint8_t *dump = vrf_io + 1024;
    setup_sv39();
    fill_frames();
    map_page(2, 0);

    /* vlseg3e32 from 18 bytes below page 2: segment 0 (12 bytes) lies in
     * page 1, segment 1 straddles into unmapped page 2. */
    unsigned long base = VA_BASE + 2u * 4096u - 18u;
    seed_v8_group(0x21u);
    setvl(4, 0x10ul);
    mpp_s();
    exec_vec(vmem_insn(0, 3, 0, 1, 6), base, 0, MPRV_BIT);
    check(g_cause == CAUSE_LOAD_PAGE && g_tval == VA_BASE + 2u * 4096u && g_vstart_trap == 1u &&
              rd_vstart() == 1u,
          "vlseg3e32 straddling segment faults with vstart 1",
          g_tval,
          g_cause,
          CAUSE_LOAD_PAGE);
    wr_vstart(0);
    store_v8_group(dump);
    for (unsigned f = 0; f < 3u; f++)
        for (unsigned long i = 0; i < 4u; i++)
            for (unsigned b = 0; b < 4u; b++) {
                unsigned long r = f * g_vlenb + i * 4u + b;
                uint8_t want =
                    (i == 0u) ? frame_pat(2u * 4096u - 18u + f * 4u + b) : seed_byte(0x21u, r);
                if (dump[r] != want) {
                    check(
                        0, "faulting segment: only segment 0 written", (f << 8) | i, dump[r], want);
                    f = 3u;
                    i = 4u;
                    break;
                }
            }
    g_checks++;
    /* Demand paging: map page 2 and resume at segment 1. */
    map_page(2, PTE_RW);
    setvl(4, 0x10ul);
    wr_vstart(1);
    mpp_s();
    exec_vec(vmem_insn(0, 3, 0, 1, 6), base, 0, MPRV_BIT);
    check(g_cause == ~0ul && rd_vstart() == 0, "vlseg3e32 resumes", 0, g_cause, ~0ul);
    store_v8_group(dump);
    for (unsigned f = 0; f < 3u; f++)
        for (unsigned long i = 0; i < 4u; i++)
            for (unsigned b = 0; b < 4u; b++) {
                unsigned long r = f * g_vlenb + i * 4u + b;
                uint8_t want = frame_pat(2u * 4096u - 18u + i * 12u + f * 4u + b);
                if (dump[r] != want) {
                    check(0, "resumed segments", (f << 8) | i, dump[r], want);
                    f = 3u;
                    i = 4u;
                    break;
                }
            }
    g_checks++;

    /* A strided segment store whose segment 2 lands on unmapped page 2:
     * segments 0 and 1 are stored, nothing of segment 2. */
    map_page(2, 0);
    fill_frames();
    for (unsigned long i = 0; i < 2u * g_vlenb; i++)
        vrf_io[i] = (uint8_t) (0x80u + i);
    load_v8_group(vrf_io);
    setvl(3, 0x08ul); /* e16 m1 */
    mpp_s();
    exec_vec(vmem_insn(1, 2, 2, 1, 5), VA_BASE + 0x1F0u, 0x1000, MPRV_BIT);
    check(g_cause == CAUSE_STORE_PAGE && g_tval == VA_BASE + 0x21F0u && g_vstart_trap == 2u,
          "vssseg2e16 faults at segment 2",
          g_tval,
          g_cause,
          CAUSE_STORE_PAGE);
    wr_vstart(0);
    for (unsigned long i = 0; i < 3u; i++)
        for (unsigned f = 0; f < 2u; f++)
            for (unsigned b = 0; b < 2u; b++) {
                unsigned long fo = 0x1F0u + i * 0x1000u + f * 2u + b;
                uint8_t want =
                    (i < 2u) ? (uint8_t) (0x80u + f * g_vlenb + i * 2u + b) : frame_pat(fo);
                check(frames[fo] == want, "vssseg2e16 partial image", fo, frames[fo], want);
            }
    map_page(2, PTE_RW);
    csr_clear(mstatus, MPP_MASK);
    __asm__ volatile("csrw satp, zero\n sfence.vma" ::: "memory");
}

/* ========================================================================== */
/* 3. Legality                                                                */
/* ========================================================================== */
static void expect_illegal(const char *what, uint32_t insn)
{
    check(g_cause == CAUSE_ILLEGAL && g_tval == insn, what, insn, g_cause, CAUSE_ILLEGAL);
}

static void test_legality(void)
{
    uint32_t insn;
    setvl(4, 0x12ul); /* e32 m4: three fields need 12 registers */
    set_vs(VS_CLEAN);
    insn = vmem_insn(0, 3, 0, 1, 6);
    exec_vec(insn, DDR_BUF, 0, 0);
    expect_illegal("vlseg3e32 at m4 (NF * EMUL 12)", insn);
    setvl(4, 0x00ul); /* e8 m1 */
    set_vs(VS_CLEAN);
    insn = (vmem_insn(0, 8, 0, 1, 0) & ~(31u << 7)) | (28u << 7);
    exec_vec(insn, DDR_BUF, 0, 0);
    expect_illegal("vlseg8e8 v28 (fields past v31)", insn);
    /* Indexed segment load whose fields reach the index group v16:
     * vluxseg2ei8 v15, (a0), v16 at e8 m1 writes v15 and v16. */
    insn = (vmem_insn(0, 2, 1, 1, 0) & ~(31u << 7)) | (15u << 7);
    exec_vec(insn, DDR_BUF, 0, 0);
    expect_illegal("vluxseg2ei8 fields overlapping vs2", insn);
    check(vs_field() == VS_CLEAN, "illegal segment forms keep VS Clean", 0, vs_field(), VS_CLEAN);
    /* The store form reads both groups, which may overlap. */
    fill_buf();
    for (unsigned long i = 0; i < 2u * g_vlenb; i++)
        vrf_io[g_vlenb * 7u + i] = (uint8_t) (i & 0x3Fu);
    __asm__ volatile(".insn r 0x07, 0, 0x71, x8, %0, x8" : : "r"(vrf_io) : "memory");
    setvl(4, 0x00ul);
    insn = (vmem_insn(1, 2, 1, 1, 0) & ~(31u << 7)) | (15u << 7);
    exec_vec(insn, DDR_BUF, 0, 0);
    check(g_cause == ~0ul, "vsuxseg2ei8 with overlapping groups is legal", 0, g_cause, ~0ul);
    fill_buf();
}

int main(void)
{
    csr_write(mscratch, 0);
    set_trap_handler(&bounce_handler);
    set_vs(VS_INITIAL);
    __asm__ volatile("csrr %0, 0xC22" : "=r"(g_vlenb));
    uart_printf("vec_segment_test VLEN=%lu\n", g_vlenb * 8u);
    check(g_vlenb == 16u || g_vlenb == 32u || g_vlenb == 64u, "supported VLEN", 0, g_vlenb, 32u);

    test_geometry();
    uart_printf("  [1] geometry, masks, vstart ok\n");
    test_faults();
    uart_printf("  [2] faults ok\n");
    test_legality();
    uart_printf("  [3] legality ok\n");

    uart_printf("%d checks\n", g_checks);
    uart_printf(g_ok ? "<<PASS>>\n" : "<<FAIL>>\n");
    for (;;) {
    }
    return 0;
}
