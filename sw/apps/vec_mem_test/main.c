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
 * Directed test for unit-stride, whole-register and mask vector loads and
 * stores across VLEN 128, 256 and 512:
 *   - All element widths (8, 16, 32, 64) and legal EMULs (1/8 .. 8) across
 *     doubleword, 32 B sector, 64 B line and 4 KiB page boundaries, including
 *     3-register sector overlap at VLEN 128 and v31 end-of-VRF overhang.
 *   - Whole-register (vl1/2/4/8re8/16/32/64.v, vs1/2/4/8r.v, including under
 *     vill = 1) and mask (vlm.v, vsm.v) transfers.
 *   - Masking (vm = 0), vstart > 0, tail undisturbed, zero-active accesses on
 *     unmapped/non-canonical pointers, and mstatus.VS transitions.
 *   - Head-executed legality (vill, EMUL out of [1/8, 8], misaligned groups,
 *     masked load to v0 illegal vs masked store of v0 legal).
 *   - Scalar-vector ordering (V-O1, V-O2, V-O3, V-O4), Zicbom, Zicboz, LR/SC.
 *   - Bare PMA access faults, Sv39 translation (MPRV S/U, SUM, out-of-range
 *     PPN access fault, straddling faults, and Case-C partial Page-0 execution
 *     with demand-paging vstart resumption).
 *   - Speculative wrong-path squashes, misaligned scalar interleaving, and
 *     CLINT timer interrupts at varying phases.
 */

#include <stdint.h>

#include "csr.h"
#include "trap.h"
#include "uart.h"

/* Cached DDR scratch regions (offset across cache sets to avoid set-aliasing). */
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
#define SATP_SV39 (8ul << 60)

#define MSTATUS_VS (3ul << 9)
#define VS_INITIAL (1ul << 9)
#define VS_CLEAN (2ul << 9)
#define VS_DIRTY (3ul << 9)
#define MSTATUS_SUM (1ul << 18)

#define CAUSE_ILLEGAL 2ul
#define CAUSE_LOAD_ACCESS 5ul
#define CAUSE_STORE_ACCESS 7ul
#define CAUSE_LOAD_PAGE 13ul
#define CAUSE_STORE_PAGE 15ul

#define S_(x) #x
#define S(x) S_(x)

/* OP-V helper */
#define OPV(f6, vm, vs2, f15, f3, vd)                                                              \
    ((((f6) << 26) | ((vm) << 25) | ((vs2) << 20) | ((f15) << 15) | ((f3) << 12) | ((vd) << 7) |   \
      0x57))

/* Zicbom / Zicboz encodings (MISC-MEM, funct3 = 2, rd = x0) */
#define CBO_INVAL_ASM(reg) ".insn i 0x0F, 2, x0, " reg ", 0\n"
#define CBO_CLEAN_ASM(reg) ".insn i 0x0F, 2, x0, " reg ", 1\n"
#define CBO_FLUSH_ASM(reg) ".insn i 0x0F, 2, x0, " reg ", 2\n"
#define CBO_ZERO_ASM(reg) ".insn i 0x0F, 2, x0, " reg ", 4\n"

static volatile uint8_t *const buf = (volatile uint8_t *) DDR_BUF;
static uint8_t *const ref = (uint8_t *) DDR_REF;
static volatile uint8_t *const vrf_io = (volatile uint8_t *) DDR_VRF;

static int g_ok = 1;
static int g_checks;
static unsigned long g_vlenb;
static unsigned long g_vlen;

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
    csr_clear(mstatus, 0x20000ul); /* clear MPRV so UART MMIO is always bare */
    uart_printf("[UNEXPECTED TRAP] cause=%lx epc=%lx tval=%lx vstart=%lx\n<<FAIL>>\n",
                g_cause,
                g_epc,
                g_tval,
                g_vstart_trap);
    for (;;) {
    }
}

/* Bounce trap handler: records mcause, mepc, mtval, and vstart, then atomically consumes mscratch.
 */
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

/* Whole-register helpers to seed/dump v8..v15, v0, and v24..v31 via DDR_VRF. */
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

static void store_v0(volatile uint8_t *dst)
{
    __asm__ volatile(".insn r 0x27, 0, 0x01, x0, %0, x8" : : "r"(dst) : "memory");
}

static uint64_t seed_word_for(uint8_t fill_byte, unsigned long w)
{
    uint64_t f = (uint64_t) fill_byte * 0x0101010101010101ull;
    return f ^ ((w + 1ull) * 0x736565645A3C96A5ull);
}

static uint8_t seed_byte_for(uint8_t fill_byte, unsigned long i)
{
    return (uint8_t) (seed_word_for(fill_byte, i >> 3) >> (8u * (i & 7u)));
}

static void seed_v8_group(uint8_t fill_byte)
{
    volatile uint64_t *tmp64 = (volatile uint64_t *) vrf_io;
    unsigned long nwords = g_vlenb; /* 8 * g_vlenb bytes = g_vlenb 64-bit words */
    for (unsigned long w = 0; w < nwords; w++)
        tmp64[w] = seed_word_for(fill_byte, w);
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

/* Dispatch unit-stride load/store into v8 (or vs3 = v8) for width code {0,5,6,7} and vm {0,1}. */
static void vle_v8(const volatile void *p, int width, int vm)
{
    if (vm) {
        switch (width) {
            case 0:
                __asm__ volatile(".insn r 0x07, 0, 0x01, x8, %0, x0" : : "r"(p) : "memory");
                break;
            case 5:
                __asm__ volatile(".insn r 0x07, 5, 0x01, x8, %0, x0" : : "r"(p) : "memory");
                break;
            case 6:
                __asm__ volatile(".insn r 0x07, 6, 0x01, x8, %0, x0" : : "r"(p) : "memory");
                break;
            default:
                __asm__ volatile(".insn r 0x07, 7, 0x01, x8, %0, x0" : : "r"(p) : "memory");
                break;
        }
    } else {
        switch (width) {
            case 0:
                __asm__ volatile(".insn r 0x07, 0, 0x00, x8, %0, x0" : : "r"(p) : "memory");
                break;
            case 5:
                __asm__ volatile(".insn r 0x07, 5, 0x00, x8, %0, x0" : : "r"(p) : "memory");
                break;
            case 6:
                __asm__ volatile(".insn r 0x07, 6, 0x00, x8, %0, x0" : : "r"(p) : "memory");
                break;
            default:
                __asm__ volatile(".insn r 0x07, 7, 0x00, x8, %0, x0" : : "r"(p) : "memory");
                break;
        }
    }
}

static void vse_v8(volatile void *p, int width, int vm)
{
    if (vm) {
        switch (width) {
            case 0:
                __asm__ volatile(".insn r 0x27, 0, 0x01, x8, %0, x0" : : "r"(p) : "memory");
                break;
            case 5:
                __asm__ volatile(".insn r 0x27, 5, 0x01, x8, %0, x0" : : "r"(p) : "memory");
                break;
            case 6:
                __asm__ volatile(".insn r 0x27, 6, 0x01, x8, %0, x0" : : "r"(p) : "memory");
                break;
            default:
                __asm__ volatile(".insn r 0x27, 7, 0x01, x8, %0, x0" : : "r"(p) : "memory");
                break;
        }
    } else {
        switch (width) {
            case 0:
                __asm__ volatile(".insn r 0x27, 0, 0x00, x8, %0, x0" : : "r"(p) : "memory");
                break;
            case 5:
                __asm__ volatile(".insn r 0x27, 5, 0x00, x8, %0, x0" : : "r"(p) : "memory");
                break;
            case 6:
                __asm__ volatile(".insn r 0x27, 6, 0x00, x8, %0, x0" : : "r"(p) : "memory");
                break;
            default:
                __asm__ volatile(".insn r 0x27, 7, 0x00, x8, %0, x0" : : "r"(p) : "memory");
                break;
        }
    }
}

/* ========================================================================== */
/* 1. Unit-stride loads/stores across widths, EMULs, and boundaries           */
/* ========================================================================== */
struct mode_cfg {
    unsigned long vtype;
    int width;
    unsigned int eew_bytes;
    const char *name;
};

static const struct mode_cfg g_modes[] = {
    {0x18ul, 0, 1, "e64,m1+vle8 (EMUL=1/8)"},
    {0x10ul, 0, 1, "e32,m1+vle8 (EMUL=1/4)"},
    {0x08ul, 0, 1, "e16,m1+vle8 (EMUL=1/2)"},
    {0x00ul, 0, 1, "e8,m1+vle8 (EMUL=1)"},
    {0x09ul, 5, 2, "e16,m2+vle16 (EMUL=2)"},
    {0x12ul, 6, 4, "e32,m4+vle32 (EMUL=4)"},
    {0x1bul, 7, 8, "e64,m8+vle64 (EMUL=8)"},
    {0x02ul, 5, 2, "e8,m4+vle16 (EMUL=8)"},
};

static const unsigned long g_offsets[] = {
    0x000ul,
    0x001ul,
    0x003ul,
    0x01dul, /* crosses 32 B sector */
    0x03ful, /* crosses 64 B line */
    0xffeul, /* crosses 4 KiB page 0 -> page 1 */
    0xfe5ul, /* multi-sector unaligned across 4 KiB page */
};

static void test_unit_stride_geometry(void)
{
    volatile uint8_t *dump = vrf_io + 1024;
    fill_buf();

    for (unsigned int m = 0; m < sizeof(g_modes) / sizeof(g_modes[0]); m++) {
        unsigned long vlmax = setvl(~0ul, g_modes[m].vtype);
        unsigned int eb = g_modes[m].eew_bytes;
        for (unsigned int o = 0; o < sizeof(g_offsets) / sizeof(g_offsets[0]); o++) {
            unsigned long off = g_offsets[o];
            unsigned long vl = vlmax;
            if (vl > 3 && (o & 1u))
                vl = vlmax - 2; /* exercise tail undisturbed as well */
            setvl(vl, g_modes[m].vtype);
            seed_v8_group(0xA5u);
            vle_v8(buf + off, g_modes[m].width, 1);
            store_v8_group(dump);

            unsigned long active_bytes = vl * eb;
            const volatile uint64_t *dump64 = (const volatile uint64_t *) dump;
            const volatile uint64_t *seed64 = (const volatile uint64_t *) vrf_io;
            for (unsigned long b = 0; b < active_bytes; b++)
                vrf_io[b] = ref[off + b];
            for (unsigned long w = 0; w < g_vlenb; w++) {
                if (dump64[w] != seed64[w]) {
                    for (unsigned int k = 0; k < 8u; k++) {
                        unsigned long b = w * 8ul + k;
                        if (dump[b] != vrf_io[b]) {
                            check(0, g_modes[m].name, (off << 16) | b, dump[b], vrf_io[b]);
                            break;
                        }
                    }
                    break;
                }
            }
            g_checks++;

            /* Mutate v8..v15 in place and store to a second unaligned window. */
            unsigned long dst_off = 0x1200ul + off;
            volatile uint64_t *vrf64 = (volatile uint64_t *) vrf_io;
            uint64_t mtag = ((uint64_t) (m * 17u + o + 1u)) * 0x0101010101010101ull;
            for (unsigned long w = 0; w < g_vlenb; w++)
                vrf64[w] = pat_word(w + 512ul) ^ mtag;
            load_v8_group(vrf_io);
            setvl(vl, g_modes[m].vtype);
            vse_v8(buf + dst_off, g_modes[m].width, 1);
            for (unsigned long b = 0; b < active_bytes; b++)
                ref[dst_off + b] = vrf_io[b];

            unsigned long win_w_lo = (dst_off >= 16 ? dst_off - 16 : 0) >> 3;
            unsigned long win_w_hi = (dst_off + active_bytes + 23) >> 3;
            const volatile uint64_t *buf64 = (const volatile uint64_t *) buf;
            const uint64_t *ref64 = (const uint64_t *) ref;
            for (unsigned long w = win_w_lo; w < win_w_hi; w++) {
                if (buf64[w] != ref64[w]) {
                    for (unsigned int k = 0; k < 8u; k++) {
                        unsigned long i = w * 8ul + k;
                        if (buf[i] != ref[i]) {
                            check(0, "vse byte window", i, buf[i], ref[i]);
                            break;
                        }
                    }
                    break;
                }
            }
            g_checks++;
        }
    }

    /* v31 end-of-VRF overhang: unaligned sector crossing past v31 must NOT wrap to v0. */
    {
        for (unsigned long i = 0; i < g_vlenb; i++) {
            vrf_io[i] = (uint8_t) (0xE0u + i);
            vrf_io[256 + i] = (uint8_t) (0x10u + i);
        }
        load_v0(vrf_io);
        __asm__ volatile(".insn r 0x07, 0, 0x01, x31, %0, x8" : : "r"(vrf_io + 256) : "memory");
        setvl(~0ul, 0x00ul); /* e8, m1 */
        __asm__ volatile(".insn r 0x07, 0, 0x01, x31, %0, x0" : : "r"(buf + 0x57) : "memory");
        store_v0(vrf_io + 512);
        __asm__ volatile(".insn r 0x27, 0, 0x01, x31, %0, x8" : : "r"(vrf_io + 768) : "memory");
        for (unsigned long i = 0; i < g_vlenb; i++) {
            check(vrf_io[512 + i] == (uint8_t) (0xE0u + i),
                  "v31 load does not wrap to v0",
                  i,
                  vrf_io[512 + i],
                  (uint8_t) (0xE0u + i));
            check(vrf_io[768 + i] == ref[0x57 + i],
                  "v31 unaligned load byte",
                  i,
                  vrf_io[768 + i],
                  ref[0x57 + i]);
        }
    }

    /* minstret delta of an 8-register vector load and store equals 1 instruction. */
    {
        unsigned long c0, c1, c2, c3;
        setvl(~0ul, 0x03ul); /* e8, m8 */
        __asm__ volatile("csrr %0, minstret\n ld x0, 0(%2)\n csrr %1, minstret"
                         : "=&r"(c0), "=&r"(c1)
                         : "r"(buf)
                         : "memory");
        __asm__ volatile("csrr %0, minstret\n"
                         ".insn r 0x07, 0, 0x01, x8, %2, x0\n"
                         "csrr %1, minstret"
                         : "=&r"(c2), "=&r"(c3)
                         : "r"(buf + 7)
                         : "memory");
        check((c3 - c2) == (c1 - c0), "vle8 m8 minstret", 0, c3 - c2, c1 - c0);
    }
}

/* ========================================================================== */
/* 2. Whole-register and mask loads/stores                                    */
/* ========================================================================== */
static void test_whole_reg_and_mask(void)
{
    volatile uint8_t *dump = vrf_io + 1024;

    /* Set vill = 1 and vl = 0 via reserved vtype: whole-register ops must still succeed! */
    setvl(16, 0x04ul); /* vlmul = 100 reserved -> sets vill = 1, vl = 0 */
    check((csr_read_imm(0xC21) >> 63) == 1ul, "vill set for whole-reg", 0, csr_read_imm(0xC21), 1);

    /* vl1re8, vl2re16, vl4re32, vl8re64 + vs1r, vs2r, vs4r, vs8r across page boundary */
    seed_v8_group(0x5Au);
    __asm__ volatile(".insn r 0x07, 0, 0x01, x8, %0, x8" : : "r"(buf + 0xff9) : "memory");
    __asm__ volatile(".insn r 0x07, 5, 0x11, x10, %0, x8" : : "r"(buf + 0x113) : "memory");
    __asm__ volatile(".insn r 0x07, 6, 0x31, x12, %0, x8" : : "r"(buf + 0xfe4) : "memory");
    store_v8_group(dump);
    for (unsigned long i = 0; i < g_vlenb; i++)
        check(dump[i] == ref[0xff9 + i], "vl1re8 under vill", i, dump[i], ref[0xff9 + i]);
    for (unsigned long i = 0; i < 2u * g_vlenb; i++)
        check(dump[2u * g_vlenb + i] == ref[0x113 + i],
              "vl2re16 under vill",
              i,
              dump[2u * g_vlenb + i],
              ref[0x113 + i]);
    for (unsigned long i = 0; i < 4u * g_vlenb; i++)
        check(dump[4u * g_vlenb + i] == ref[0xfe4 + i],
              "vl4re32 under vill",
              i,
              dump[4u * g_vlenb + i],
              ref[0xfe4 + i]);

    /* Whole-register load with vstart > 0 at EEW=16 (vl2re16.v skips vstart * 2 bytes). */
    seed_v8_group(0xC3u);
    wr_vstart(3);
    __asm__ volatile(".insn r 0x07, 5, 0x11, x8, %0, x8" : : "r"(buf + 0x205) : "memory");
    check(rd_vstart() == 0, "vl2re16 clears vstart", 0, rd_vstart(), 0);
    store_v8_group(dump);
    for (unsigned long i = 0; i < 2u * g_vlenb; i++) {
        uint8_t want = (i < 6u) ? seed_byte_for(0xC3u, i) : ref[0x205 + i];
        check(dump[i] == want, "vl2re16 vstart=3 byte", i, dump[i], want);
    }

    /* Whole-register stores vs1r, vs2r, vs4r, vs8r across unaligned offsets. */
    __asm__ volatile(".insn r 0x27, 0, 0x31, x12, %0, x8" : : "r"(buf + 0x1fd7) : "memory");
    for (unsigned long i = 0; i < 4u * g_vlenb; i++)
        ref[0x1fd7 + i] = dump[4u * g_vlenb + i];
    for (unsigned long i = 0x1fd0; i < 0x1fd7 + 4u * g_vlenb + 8u; i++) {
        if (buf[i] != ref[i]) {
            check(0, "vs4r page-cross byte", i, buf[i], ref[i]);
            break;
        }
    }
    g_checks++;

    /* Mask vlm.v and vsm.v with non-multiple-of-8 vl and with vstart > 0. */
    unsigned long vls[3] = {1ul, 13ul, g_vlen - 3ul};
    for (int k = 0; k < 3; k++) {
        unsigned long vl = setvl(vls[k], 0x03ul); /* e8, m8 so vl up to VLEN is legal */
        unsigned long evl = (vl + 7ul) / 8ul;
        seed_v8_group(0x7Eu);
        if (k == 1)
            wr_vstart(1); /* vlm.v indexes bytes: skip byte 0 */
        __asm__ volatile(".insn r 0x07, 0, 0x01, x8, %0, x11" : : "r"(buf + 0x311 + k) : "memory");
        check(rd_vstart() == 0, "vlm clears vstart", k, rd_vstart(), 0);
        store_v8_group(dump);
        unsigned long start_b = (k == 1) ? 1ul : 0ul;
        for (unsigned long b = 0; b < g_vlenb; b++) {
            uint8_t want = (b >= start_b && b < evl) ? ref[0x311 + k + b] : seed_byte_for(0x7Eu, b);
            check(dump[b] == want, "vlm byte", (k << 8) | b, dump[b], want);
        }

        /* vsm.v back to memory */
        setvl(vls[k], 0x03ul);
        unsigned long moff = 0x1603ul + k * 97ul;
        __asm__ volatile(".insn r 0x27, 0, 0x01, x8, %0, x11" : : "r"(buf + moff) : "memory");
        for (unsigned long b = 0; b < evl; b++)
            ref[moff + b] = dump[b];
        for (unsigned long b = 0; b < g_vlenb + 8u; b++)
            check(buf[moff + b] == ref[moff + b],
                  "vsm byte",
                  (k << 8) | b,
                  buf[moff + b],
                  ref[moff + b]);
    }
}

/* ========================================================================== */
/* 3. Masking, vstart, zero-active pointers, and mstatus.VS                   */
/* ========================================================================== */
static void test_mask_vstart_and_vs(void)
{
    volatile uint8_t *dump = vrf_io + 1024;
    volatile uint8_t *mask_copy = vrf_io + 2048;

    /* Build sparse mask in v0: bit i = ((i * 5 + 1) & 2) != 0 */
    for (unsigned long b = 0; b < g_vlenb; b++) {
        uint8_t m = 0;
        for (unsigned int bit = 0; bit < 8; bit++) {
            unsigned long idx = b * 8u + bit;
            if (((idx * 5u + 1u) & 2u) != 0)
                m |= (uint8_t) (1u << bit);
        }
        mask_copy[b] = m;
    }
    load_v0(mask_copy);

    /* Masked vle32.v (EMUL=4) with vstart=3 and vl = vlmax - 2 across sector/line boundary */
    unsigned long vlmax = setvl(~0ul, 0x12ul); /* e32, m4 */
    unsigned long vl = vlmax - 2ul;
    setvl(vl, 0x12ul);
    seed_v8_group(0x96u);
    wr_vstart(3);
    vle_v8(buf + 0x23a, 6, 0); /* vm = 0 */
    check(rd_vstart() == 0, "masked vle32 clears vstart", 0, rd_vstart(), 0);
    store_v8_group(dump);

    for (unsigned long b = 0; b < 8u * g_vlenb; b++) {
        unsigned long elem = b / 4u;
        int mbit = (mask_copy[elem / 8u] >> (elem % 8u)) & 1;
        int active = (elem >= 3ul) && (elem < vl) && mbit;
        uint8_t want = active ? ref[0x23a + b] : seed_byte_for(0x96u, b);
        if (dump[b] != want) {
            check(0, "masked vle32 byte", b, dump[b], want);
            break;
        }
    }
    g_checks++;

    /* Masked vse16.v (EMUL=2) with vstart=2 and vl = vlmax - 3 */
    vlmax = setvl(~0ul, 0x09ul); /* e16, m2 */
    vl = vlmax - 3ul;
    setvl(vl, 0x09ul);
    for (unsigned long b = 0; b < 8u * g_vlenb; b++)
        vrf_io[b] = (uint8_t) (0x41u + b * 3u);
    load_v8_group(vrf_io);
    wr_vstart(2);
    unsigned long soff = 0x181dul;
    vse_v8(buf + soff, 5, 0); /* vm = 0 */
    check(rd_vstart() == 0, "masked vse16 clears vstart", 0, rd_vstart(), 0);
    for (unsigned long elem = 2; elem < vl; elem++) {
        int mbit = (mask_copy[elem / 8u] >> (elem % 8u)) & 1;
        if (mbit) {
            ref[soff + 2u * elem] = vrf_io[2u * elem];
            ref[soff + 2u * elem + 1u] = vrf_io[2u * elem + 1u];
        }
    }
    for (unsigned long i = soff - 8u; i < soff + 2u * vlmax + 8u; i++) {
        if (buf[i] != ref[i]) {
            check(0, "masked vse16 byte", i, buf[i], ref[i]);
            break;
        }
    }
    g_checks++;

    /* Zero-active accesses on unmapped/non-canonical pointer must NOT fault! */
    const volatile void *bad_ptr = (const volatile void *) 0xDEAD000000000000ul;
    g_cause = ~0ul;

    /* (a) vl == 0: VLOAD dirties VS; VSTORE with vstart==0 keeps VS Clean. */
    setvl(0, 0x10ul);
    set_vs(VS_CLEAN);
    vle_v8(bad_ptr, 6, 1);
    check(g_cause == ~0ul, "vl=0 vle32 bad ptr no fault", 0, g_cause, ~0ul);
    check(vs_field() == VS_DIRTY, "vl=0 vle32 dirties VS", 0, vs_field(), VS_DIRTY);

    set_vs(VS_CLEAN);
    vse_v8((volatile void *) bad_ptr, 6, 1);
    check(g_cause == ~0ul, "vl=0 vse32 bad ptr no fault", 0, g_cause, ~0ul);
    check(vs_field() == VS_CLEAN, "vl=0 vstart=0 vse32 keeps VS Clean", 0, vs_field(), VS_CLEAN);

    /* (b) vstart >= vl: clears vstart and dirties VS even on VSTORE! */
    setvl(2, 0x10ul);
    wr_vstart(5);
    set_vs(VS_CLEAN);
    vse_v8((volatile void *) bad_ptr, 6, 1);
    check(g_cause == ~0ul, "vstart>=vl vse32 bad ptr no fault", 0, g_cause, ~0ul);
    check(rd_vstart() == 0, "vstart>=vl vse32 clears vstart", 0, rd_vstart(), 0);
    check(vs_field() == VS_DIRTY, "vstart>0 vse32 dirties VS", 0, vs_field(), VS_DIRTY);

    /* (c) vm == 0 with all-zero v0 mask on bad_ptr: no fault! */
    for (unsigned long b = 0; b < g_vlenb; b++)
        vrf_io[b] = 0;
    load_v0(vrf_io);
    setvl(4, 0x10ul);
    wr_vstart(1);
    vle_v8(bad_ptr, 6, 0);
    check(g_cause == ~0ul, "all-zero mask vle32 bad ptr no fault", 0, g_cause, ~0ul);
    check(rd_vstart() == 0, "all-zero mask vle32 clears vstart", 0, rd_vstart(), 0);

    /* (d) Active store with vstart == 0 keeps VS Clean; active load sets VS Dirty. */
    setvl(4, 0x10ul);
    set_vs(VS_CLEAN);
    vse_v8(buf + 0x400, 6, 1);
    for (unsigned long b = 0; b < 16u; b++) {
        ref[0x400 + b] = (uint8_t) (0x41u + b * 3u);
        check(buf[0x400 + b] == ref[0x400 + b],
              "active vse32 byte",
              b,
              buf[0x400 + b],
              ref[0x400 + b]);
    }
    check(vs_field() == VS_CLEAN, "active vse32 vstart=0 keeps VS Clean", 0, vs_field(), VS_CLEAN);
    vle_v8(buf + 0x400, 6, 1);
    check(vs_field() == VS_DIRTY, "active vle32 sets VS Dirty", 0, vs_field(), VS_DIRTY);
}

/* ========================================================================== */
/* 4. Head-executed legality checks                                           */
/* ========================================================================== */
#define RUN_TRAP_INSN(asm_body, ptr)                                                               \
    ({                                                                                             \
        unsigned long exp_epc__;                                                                   \
        g_cause = ~0ul;                                                                            \
        g_tval = ~0ul;                                                                             \
        __asm__ volatile("la t0, 2f\n csrw mscratch, t0\n"                                         \
                         "la %0, 1f\n"                                                             \
                         "1:\n" asm_body "\n"                                                      \
                         "2:\n csrw mscratch, zero\n"                                              \
                         : "=&r"(exp_epc__)                                                        \
                         : "r"(ptr)                                                                \
                         : "t0", "memory");                                                        \
        exp_epc__;                                                                                 \
    })

static void expect_illegal(const char *what, unsigned long epc)
{
    uint32_t lo = *(const uint16_t *) epc;
    uint32_t hi = *(const uint16_t *) (epc + 2ul);
    uint32_t insn = lo | (hi << 16);
    check(g_cause == CAUSE_ILLEGAL && g_epc == epc && g_tval == (unsigned long) insn,
          what,
          epc,
          g_cause,
          CAUSE_ILLEGAL);
}

static void test_legality(void)
{
    /* vill = 1 (e64, mf2 -> SEW > LMUL * ELEN sets vill = 1): unit-stride and mask ops trap! */
    setvl(1, 0x1ful);
    check(
        (csr_read_imm(0xC21) >> 63) == 1ul, "e64,mf2 sets vill", 0, csr_read_imm(0xC21) >> 63, 1ul);
    set_vs(VS_CLEAN);
    expect_illegal("vill=1 vle8", RUN_TRAP_INSN(".insn r 0x07, 0, 0x01, x8, %1, x0", buf));
    expect_illegal("vill=1 vse8", RUN_TRAP_INSN(".insn r 0x27, 0, 0x01, x8, %1, x0", buf));
    expect_illegal("vill=1 vlm", RUN_TRAP_INSN(".insn r 0x07, 0, 0x01, x8, %1, x11", buf));
    expect_illegal("vill=1 vsm", RUN_TRAP_INSN(".insn r 0x27, 0, 0x01, x8, %1, x11", buf));

    /* EMUL > 8 with vill = 0: vtype = e8, m8 (0x03) + vle16/vse16 -> EMUL = 16 */
    setvl(4, 0x03ul);
    check(
        (csr_read_imm(0xC21) >> 63) == 0ul, "e8,m8 is legal vtype", 0, csr_read_imm(0xC21), 0x03ul);
    set_vs(VS_CLEAN);
    expect_illegal("EMUL=16 vle16", RUN_TRAP_INSN(".insn r 0x07, 5, 0x01, x8, %1, x0", buf));
    expect_illegal("EMUL=16 vse16", RUN_TRAP_INSN(".insn r 0x27, 5, 0x01, x8, %1, x0", buf));

    /* Unaligned register groups: EMUL=2 on v3, EMUL=4 on v6, EMUL=8 on v12, whole-reg NREG=4 on v2
     */
    setvl(4, 0x09ul); /* e16, m2 */
    set_vs(VS_CLEAN);
    expect_illegal("EMUL=2 vd=v3", RUN_TRAP_INSN(".insn r 0x07, 5, 0x01, x3, %1, x0", buf));
    setvl(4, 0x12ul); /* e32, m4 */
    set_vs(VS_CLEAN);
    expect_illegal("EMUL=4 vs3=v6", RUN_TRAP_INSN(".insn r 0x27, 6, 0x01, x6, %1, x0", buf));
    setvl(4, 0x1bul); /* e64, m8 */
    set_vs(VS_CLEAN);
    expect_illegal("EMUL=8 vd=v12", RUN_TRAP_INSN(".insn r 0x07, 7, 0x01, x12, %1, x0", buf));
    expect_illegal("vs4r vs3=v2", RUN_TRAP_INSN(".insn r 0x27, 0, 0x31, x2, %1, x8", buf));
    expect_illegal("vl8re32 vd=v4", RUN_TRAP_INSN(".insn r 0x07, 6, 0x71, x4, %1, x8", buf));
    check(vs_field() == VS_CLEAN, "illegal ops preserve VS Clean", 0, vs_field(), VS_CLEAN);

    /* Masked load to v0 (vm=0, vd=v0) is ILLEGAL, while masked store of v0 (vm=0, vs3=v0) is LEGAL!
     */
    setvl(4, 0x10ul); /* e32, m1 */
    expect_illegal("masked vle32 vd=v0", RUN_TRAP_INSN(".insn r 0x07, 6, 0x00, x0, %1, x0", buf));

    /* Seed v0: byte 0 = 0x05 (mask bits 0 and 2 enabled; element 0 = 0x33221105), elem 2 =
     * 0xCAFEBABEu */
    for (unsigned long b = 0; b < g_vlenb; b++)
        vrf_io[b] = 0;
    vrf_io[0] = 0x05u;
    vrf_io[1] = 0x11u;
    vrf_io[2] = 0x22u;
    vrf_io[3] = 0x33u;
    vrf_io[8] = 0xBEu;
    vrf_io[9] = 0xBAu;
    vrf_io[10] = 0xFEu;
    vrf_io[11] = 0xCAu;
    load_v0(vrf_io);
    setvl(4, 0x10ul);
    g_cause = ~0ul;
    __asm__ volatile(".insn r 0x27, 6, 0x00, x0, %0, x0" : : "r"(buf + 0x500) : "memory");
    check(g_cause == ~0ul, "masked vse32 vs3=v0 legal", 0, g_cause, ~0ul);
    for (int b = 0; b < 4; b++) {
        ref[0x500 + b] = vrf_io[b];
        ref[0x508 + b] = vrf_io[8 + b];
    }
    for (unsigned long i = 0x500; i < 0x510; i++)
        check(buf[i] == ref[i], "masked vse32 v0 byte", i, buf[i], ref[i]);
}

/* ========================================================================== */
/* 5. Scalar-vector memory ordering (V-O1..V-O4, Zicbom, Zicboz, LR/SC)       */
/* ========================================================================== */
static void test_ordering(void)
{
    volatile uint8_t *dump = vrf_io + 1024;

    /* V-O1a: burst of back-to-back scalar stores (hot + cold lines) immediately followed by vle8.v
     * m8 */
    unsigned long base = 0x600ul;
    setvl(~0ul, 0x03ul); /* e8, m8 */
    {
        volatile uint64_t *d = (volatile uint64_t *) (buf + base);
        uint64_t s0 = 0x1122334455667788ull;
        uint64_t s1 = 0x99AABBCCDDEEFF00ull;
        uint32_t s2 = 0xCAFE1234u;
        uint16_t s3 = 0xBEEFu;
        uint8_t s4 = 0x7Au;
        __asm__ volatile("sd %1, 0(%0)\n"
                         "sd %2, 64(%0)\n"
                         "sw %3, 28(%0)\n"
                         "sh %4, 62(%0)\n"
                         "sb %5, 127(%0)\n"
                         ".insn r 0x07, 0, 0x01, x8, %0, x0\n"
                         :
                         : "r"(d), "r"(s0), "r"(s1), "r"(s2), "r"(s3), "r"(s4)
                         : "memory");
        for (int b = 0; b < 8; b++) {
            ref[base + b] = (uint8_t) (s0 >> (8 * b));
            ref[base + 64 + b] = (uint8_t) (s1 >> (8 * b));
        }
        for (int b = 0; b < 4; b++)
            ref[base + 28 + b] = (uint8_t) (s2 >> (8 * b));
        ref[base + 62] = (uint8_t) (s3 & 0xffu);
        ref[base + 63] = (uint8_t) (s3 >> 8);
        ref[base + 127] = s4;

        store_v8_group(dump);
        for (unsigned long i = 0; i < 8u * g_vlenb; i++) {
            if (dump[i] != ref[base + i]) {
                check(0, "V-O1 store->vle8 byte", i, dump[i], ref[base + i]);
                break;
            }
        }
        g_checks++;
    }

    /* V-O1b: burst of older scalar stores immediately followed by overlapping vse8.v (younger vse
     * wins!) */
    {
        for (unsigned long i = 0; i < 8u * g_vlenb; i++)
            vrf_io[i] = (uint8_t) (0xB0u + i);
        load_v8_group(vrf_io);
        setvl(~0ul, 0x03ul);
        volatile uint64_t *d = (volatile uint64_t *) (buf + base);
        uint64_t old_val = 0xDEADDEADDEADDEADull;
        __asm__ volatile("sd %1, 0(%0)\n"
                         "sd %1, 32(%0)\n"
                         "sd %1, 64(%0)\n"
                         "sd %1, 96(%0)\n"
                         ".insn r 0x27, 0, 0x01, x8, %0, x0\n"
                         :
                         : "r"(d), "r"(old_val)
                         : "memory");
        for (unsigned long i = 0; i < 8u * g_vlenb; i++) {
            ref[base + i] = vrf_io[i];
            if (buf[base + i] != ref[base + i]) {
                check(0, "V-O1 store->vse8 byte", i, buf[base + i], ref[base + i]);
                break;
            }
        }
        g_checks++;
    }

    /* V-O2: vle8.v m8 immediately followed by younger scalar stores overwriting the same range */
    {
        setvl(~0ul, 0x03ul);
        volatile uint64_t *d = (volatile uint64_t *) (buf + base);
        uint64_t new_val = 0x55AA55AA55AA55AAull;
        __asm__ volatile(".insn r 0x07, 0, 0x01, x8, %0, x0\n"
                         "sd %1, 0(%0)\n"
                         "sd %1, 40(%0)\n"
                         "sd %1, 88(%0)\n"
                         :
                         : "r"(d), "r"(new_val)
                         : "memory");
        store_v8_group(dump);
        for (unsigned long i = 0; i < 8u * g_vlenb; i++) {
            if (dump[i] != ref[base + i]) {
                check(0, "V-O2 vle8->store old byte", i, dump[i], ref[base + i]);
                break;
            }
        }
        g_checks++;
        for (int b = 0; b < 8; b++) {
            uint8_t nb = (uint8_t) (new_val >> (8 * b));
            ref[base + b] = nb;
            ref[base + 40 + b] = nb;
            ref[base + 88 + b] = nb;
        }
        check(*(volatile uint64_t *) (buf + base + 40) == new_val,
              "V-O2 younger store landed",
              base + 40,
              *(volatile uint64_t *) (buf + base + 40),
              new_val);
    }

    /* V-O3: vse8.v m8 immediately followed by younger scalar loads and younger scalar store */
    {
        for (unsigned long i = 0; i < 8u * g_vlenb; i++)
            vrf_io[i] = (uint8_t) (0x21u + i * 5u);
        load_v8_group(vrf_io);
        setvl(~0ul, 0x03ul);
        volatile uint8_t *p = buf + base;
        uint64_t ld0, ld_last, overwrite = 0xFEDCBA9876543210ull;
        unsigned long last_dw = 8u * g_vlenb - 8u;
        __asm__ volatile(".insn r 0x27, 0, 0x01, x8, %2, x0\n"
                         "ld %0, 0(%2)\n"
                         "sd %4, 16(%2)\n"
                         "add t0, %2, %3\n"
                         "ld %1, 0(t0)\n"
                         : "=&r"(ld0), "=&r"(ld_last)
                         : "r"(p), "r"(last_dw), "r"(overwrite)
                         : "t0", "memory");
        for (unsigned long i = 0; i < 8u * g_vlenb; i++)
            ref[base + i] = vrf_io[i];
        for (int b = 0; b < 8; b++)
            ref[base + 16 + b] = (uint8_t) (overwrite >> (8 * b));

        uint64_t want0 = 0, want_last = 0;
        for (int b = 0; b < 8; b++) {
            want0 |= (uint64_t) vrf_io[b] << (8 * b);
            want_last |= (uint64_t) vrf_io[last_dw + b] << (8 * b);
        }
        check(ld0 == want0, "V-O3 vse8->ld first", base, ld0, want0);
        check(ld_last == want_last, "V-O3 vse8->ld last", base + last_dw, ld_last, want_last);
        check(*(volatile uint64_t *) (buf + base + 16) == overwrite,
              "V-O3 vse8->sd younger store",
              base + 16,
              *(volatile uint64_t *) (buf + base + 16),
              overwrite);
    }

    /* Zicbom & Zicboz ordering around VLOAD/VSTORE */
    {
        unsigned long cbase = 0x900ul; /* 64 B aligned */
        for (unsigned long i = 0; i < 8u * g_vlenb; i++)
            vrf_io[i] = (uint8_t) (0x63u + i);
        load_v8_group(vrf_io);
        setvl(~0ul, 0x03ul);
        register volatile uint8_t *a0 __asm__("a0") = buf + cbase;
        register volatile uint8_t *a1 __asm__("a1") = buf + cbase + 64;
        uint64_t after_cmo, zero_check;
        __asm__ volatile(".insn r 0x27, 0, 0x01, x8, a0, x0\n" CBO_CLEAN_ASM("a0")
                             CBO_FLUSH_ASM("a0") CBO_INVAL_ASM("a0")
                                 CBO_ZERO_ASM("a1") "ld %0, 8(a0)\n"
                                                    "ld %1, 8(a1)\n"
                         : "=&r"(after_cmo), "=&r"(zero_check)
                         : "r"(a0), "r"(a1)
                         : "memory");
        uint64_t want_cmo = 0;
        for (int b = 0; b < 8; b++)
            want_cmo |= (uint64_t) vrf_io[8 + b] << (8 * b);
        check(after_cmo == want_cmo, "vse8->cbo.clean/flush/inval->ld", cbase, after_cmo, want_cmo);
        check(zero_check == 0ull, "vse8->cbo.zero zeroes block", cbase + 64, zero_check, 0ull);

        /* vle8.v immediately followed by cbo.zero sees pre-zero data, then cbo.zero->vle8 sees 0 */
        setvl(~0ul, 0x00ul); /* e8, m1 */
        __asm__ volatile(".insn r 0x07, 0, 0x01, x8, a0, x0\n" CBO_ZERO_ASM(
                             "a0") ".insn r 0x07, 0, 0x01, x9, a0, x0\n"
                         :
                         : "r"(a0)
                         : "memory");
        store_v8_group(dump);
        for (unsigned long i = 0; i < g_vlenb; i++) {
            check(dump[i] == vrf_io[i], "vle8 before cbo.zero", i, dump[i], vrf_io[i]);
            check(dump[g_vlenb + i] == 0u, "vle8 after cbo.zero", i, dump[g_vlenb + i], 0u);
        }

        for (unsigned long i = 0; i < 8u * g_vlenb; i++)
            ref[cbase + i] = (i < 128u) ? 0u : vrf_io[i];
    }

    /* V-O4: FENCE and LR/SC around VSTORE */
    {
        unsigned long lbase = 0xa80ul;
        for (unsigned long i = 0; i < g_vlenb; i++)
            vrf_io[i] = (uint8_t) (0x91u + i);
        load_v8_group(vrf_io);
        setvl(~0ul, 0x00ul);
        uint64_t lr_val, sc_res;
        volatile uint64_t *lp = (volatile uint64_t *) (buf + lbase);
        __asm__ volatile(".insn r 0x27, 0, 0x01, x8, %2, x0\n"
                         "fence rw, rw\n"
                         "lr.d %0, (%2)\n"
                         "sc.d %1, %3, (%2)\n"
                         : "=&r"(lr_val), "=&r"(sc_res)
                         : "r"(lp), "r"(0x123456789ABCDEF0ull)
                         : "memory");
        uint64_t want_lr = 0;
        for (int b = 0; b < 8; b++)
            want_lr |= (uint64_t) vrf_io[b] << (8 * b);
        check(lr_val == want_lr && sc_res == 0, "vse8->fence->lr/sc", lbase, lr_val, want_lr);
        for (unsigned long i = 0; i < g_vlenb; i++)
            ref[lbase + i] = vrf_io[i];
        for (int b = 0; b < 8; b++)
            ref[lbase + b] = (uint8_t) (0x123456789ABCDEF0ull >> (8 * b));
    }
}

/* ========================================================================== */
/* 6. Bare PMA faults, Sv39 MPRV (S & U), straddles, and Case-C resumption    */
/* ========================================================================== */
#define MPRV_S_ON                                                                                  \
    "li t1, 0x1800\n csrc mstatus, t1\n li t1, 0x0800\n csrs mstatus, t1\n"                        \
    "li t1, 0x20000\n csrs mstatus, t1\n"
#define MPRV_U_ON                                                                                  \
    "li t1, 0x1800\n csrc mstatus, t1\n"                                                           \
    "li t1, 0x20000\n csrs mstatus, t1\n"
#define MPRV_OFF "1:\n li t1, 0x20000\n csrc mstatus, t1\n csrw mscratch, zero\n"

static void s_vle32_v8(unsigned long va, int masked)
{
    g_cause = ~0ul;
    g_tval = ~0ul;
    if (masked) {
        __asm__ volatile("la t0, 1f\n csrw mscratch, t0\n" MPRV_S_ON
                         ".insn r 0x07, 6, 0x00, x8, %0, x0\n" MPRV_OFF
                         :
                         : "r"(va)
                         : "t0", "t1", "memory");
    } else {
        __asm__ volatile("la t0, 1f\n csrw mscratch, t0\n" MPRV_S_ON
                         ".insn r 0x07, 6, 0x01, x8, %0, x0\n" MPRV_OFF
                         :
                         : "r"(va)
                         : "t0", "t1", "memory");
    }
}

static void u_vle32_v8(unsigned long va)
{
    g_cause = ~0ul;
    g_tval = ~0ul;
    __asm__ volatile("la t0, 1f\n csrw mscratch, t0\n" MPRV_U_ON
                     ".insn r 0x07, 6, 0x01, x8, %0, x0\n" MPRV_OFF
                     :
                     : "r"(va)
                     : "t0", "t1", "memory");
}

static void s_vse32_v8(unsigned long va)
{
    g_cause = ~0ul;
    g_tval = ~0ul;
    __asm__ volatile("la t0, 1f\n csrw mscratch, t0\n" MPRV_S_ON
                     ".insn r 0x27, 6, 0x01, x8, %0, x0\n" MPRV_OFF
                     :
                     : "r"(va)
                     : "t0", "t1", "memory");
}

static uint64_t frame_word(unsigned long w)
{
    return ((w + 1ull) * 0x517CC1B727220A95ull) ^ 0xA5A5F00DC3C355AAull;
}

static uint8_t frame_pat(unsigned long i)
{
    return (uint8_t) (frame_word(i >> 3) >> (8u * (i & 7u)));
}

static void test_pma_and_sv39(void)
{
    volatile uint8_t *dump = vrf_io + 1024;

    /* 6a. Bare PMA faults: stack in low BRAM and MMIO at 0x40000010 */
    {
        volatile uint64_t stack_buf[2] __attribute__((aligned(16)));
        stack_buf[0] = 0x1111222233334444ull;
        stack_buf[1] = 0x5555666677778888ull;
        setvl(4, 0x10ul); /* e32, m1 */
        wr_vstart(2);
        RUN_TRAP_INSN(".insn r 0x07, 6, 0x01, x8, %1, x0", stack_buf);
        check(g_cause == CAUSE_LOAD_ACCESS && g_tval == (unsigned long) stack_buf + 8ul &&
                  g_vstart_trap == 2ul,
              "BRAM vle32 access fault + vstart=2",
              g_tval,
              g_cause,
              CAUSE_LOAD_ACCESS);
        wr_vstart(0);
        RUN_TRAP_INSN(".insn r 0x27, 6, 0x01, x8, %1, x0", stack_buf);
        check(g_cause == CAUSE_STORE_ACCESS && g_tval == (unsigned long) stack_buf &&
                  stack_buf[0] == 0x1111222233334444ull,
              "BRAM vse32 access fault",
              g_tval,
              g_cause,
              CAUSE_STORE_ACCESS);
        RUN_TRAP_INSN(".insn r 0x07, 6, 0x01, x8, %1, x0", (void *) 0x40000010ul);
        check(g_cause == CAUSE_LOAD_ACCESS && g_tval == 0x40000010ul,
              "MMIO vle32 access fault",
              g_tval,
              g_cause,
              CAUSE_LOAD_ACCESS);
    }

    /* 6b. Sv39 page tables */
    volatile unsigned long *root = (volatile unsigned long *) PT_ROOT;
    volatile unsigned long *l1 = (volatile unsigned long *) PT_L1;
    volatile unsigned long *l0 = (volatile unsigned long *) PT_L0;
    volatile uint8_t *frames = (volatile uint8_t *) FRAMES;
    for (int i = 0; i < 512; i++) {
        root[i] = 0;
        l1[i] = 0;
        l0[i] = 0;
    }
    root[0] = PTE_PPN(PT_L1) | PTE_V;
    l1[2] = PTE_PPN(PT_L0) | PTE_V; /* VA_BASE = 0x400000 */

    l0[0] = PTE_PPN(FRAMES + 0u * 4096u) | PTE_V | PTE_R | PTE_W | PTE_A | PTE_D; /* 0: S RW */
    l0[1] = PTE_PPN(FRAMES + 1u * 4096u) | PTE_V | PTE_R | PTE_A;                 /* 1: S RO */
    l0[2] = 0;                                                                    /* 2: unmapped */
    l0[3] = PTE_PPN(FRAMES + 3u * 4096u) | PTE_V | PTE_R | PTE_W | PTE_A | PTE_D; /* 3: S RW */
    l0[4] = PTE_PPN(FRAMES + 4u * 4096u) | PTE_V | PTE_R | PTE_W | PTE_U | PTE_A | PTE_D; /* 4: U */
    l0[5] = PTE_PPN(FRAMES + 5u * 4096u) | PTE_V | PTE_R | PTE_W | PTE_A | PTE_D; /* 5: S RW */
    l0[6] = PTE_PPN(0x9000000000ul) | PTE_V | PTE_R | PTE_W | PTE_A | PTE_D;      /* 6: PPN > DDR */

    volatile uint64_t *frames64 = (volatile uint64_t *) frames;
    for (unsigned long pg = 0; pg < 6u; pg++) {
        unsigned long pg_w = pg * (4096ul / 8ul);
        for (unsigned long k = 0; k < 16ul; k++) {
            frames64[pg_w + k] = frame_word(pg_w + k);
            frames64[pg_w + (4096ul / 8ul) - 16ul + k] =
                frame_word(pg_w + (4096ul / 8ul) - 16ul + k);
        }
    }

    __asm__ volatile("fence rw, rw\n csrw satp, %0\n sfence.vma"
                     :
                     : "r"(SATP_SV39 | (PT_ROOT >> 12))
                     : "memory");

    /* Cross-page load Page 0 (RW) -> Page 1 (RO): succeeds! */
    setvl(8, 0x11ul); /* e32, m2 */
    seed_v8_group(0xEEu);
    s_vle32_v8(VA_BASE + 4096u - 10u, 0);
    check(g_cause == ~0ul, "Sv39 vle32 across RW->RO pages", 0, g_cause, ~0ul);
    store_v8_group(dump);
    for (unsigned long b = 0; b < 32u; b++)
        check(dump[b] == frame_pat(4096u - 10u + b),
              "Sv39 cross-page vle32 byte",
              b,
              dump[b],
              frame_pat(4096u - 10u + b));

    /* Non-canonical VA in Sv39 -> Load Page Fault with mtval = first_active_va */
    setvl(4, 0x10ul);
    wr_vstart(1);
    s_vle32_v8(0x0000004000000000ul, 0);
    check(g_cause == CAUSE_LOAD_PAGE && g_tval == 0x0000004000000004ul && g_vstart_trap == 1ul,
          "Sv39 non-canonical vle32 page fault",
          g_tval,
          g_cause,
          CAUSE_LOAD_PAGE);
    wr_vstart(0);

    /* Out-of-range leaf PPN (Page 6) -> Load/Store ACCESS fault (5/7), not page fault! */
    setvl(4, 0x10ul);
    s_vle32_v8(VA_BASE + 6u * 4096u + 16u, 0);
    check(g_cause == CAUSE_LOAD_ACCESS && g_tval == VA_BASE + 6u * 4096u + 16u,
          "Sv39 out-of-range PPN load access fault",
          g_tval,
          g_cause,
          CAUSE_LOAD_ACCESS);
    s_vse32_v8(VA_BASE + 6u * 4096u + 16u);
    check(g_cause == CAUSE_STORE_ACCESS && g_tval == VA_BASE + 6u * 4096u + 16u,
          "Sv39 out-of-range PPN store access fault",
          g_tval,
          g_cause,
          CAUSE_STORE_ACCESS);

    /* Masked-off Page-1 straddle: Page 1 (RO) -> Page 2 (unmapped), only elems 0,1 active -> no
     * fault! */
    for (unsigned long b = 0; b < g_vlenb; b++)
        vrf_io[b] = (b == 0) ? 0x03u : 0x00u;
    load_v0(vrf_io);
    setvl(4, 0x10ul);
    s_vle32_v8(VA_BASE + 2u * 4096u - 8u, 1);
    check(g_cause == ~0ul, "Sv39 masked-off unmapped Page 1 no fault", 0, g_cause, ~0ul);

    /* vstart skipping unmapped Page 2 into mapped Page 3 -> no fault! */
    setvl(4, 0x10ul);
    wr_vstart(2);
    s_vle32_v8(VA_BASE + 3u * 4096u - 8u, 0);
    check(
        g_cause == ~0ul && rd_vstart() == 0, "Sv39 vstart skips unmapped Page 0", 0, g_cause, ~0ul);

    /* Single straddling element (elem 0 at 0x1ffe..0x2001): Page 1 RO -> Page 2 unmapped -> mtval =
     * 0x2000 */
    setvl(1, 0x10ul);
    s_vle32_v8(VA_BASE + 2u * 4096u - 2u, 0);
    check(g_cause == CAUSE_LOAD_PAGE && g_tval == VA_BASE + 2u * 4096u && g_vstart_trap == 0ul,
          "Sv39 straddling elem 0 mtval=page_base",
          g_tval,
          g_cause,
          CAUSE_LOAD_PAGE);

    /* U-mode MPRV: Page 4 (U=1) -> Page 5 (U=0): U-mode loads Page 4, faults on Page 5 (Case C)! */
    setvl(8, 0x11ul); /* e32, m2 */
    seed_v8_group(0xAAu);
    u_vle32_v8(VA_BASE + 5u * 4096u - 8u);
    check(g_cause == CAUSE_LOAD_PAGE && g_tval == VA_BASE + 5u * 4096u && g_vstart_trap == 2ul,
          "Sv39 U-mode into S-page faults at elem 2",
          g_vstart_trap,
          g_cause,
          CAUSE_LOAD_PAGE);
    wr_vstart(0);

    /* S-mode MPRV into User Page 4: faults without SUM, succeeds with SUM! */
    setvl(4, 0x10ul);
    s_vle32_v8(VA_BASE + 4u * 4096u, 0);
    check(g_cause == CAUSE_LOAD_PAGE,
          "Sv39 S-mode U-page without SUM faults",
          0,
          g_cause,
          CAUSE_LOAD_PAGE);
    csr_set(mstatus, MSTATUS_SUM);
    s_vle32_v8(VA_BASE + 4u * 4096u, 0);
    csr_clear(mstatus, MSTATUS_SUM);
    check(g_cause == ~0ul, "Sv39 S-mode U-page with SUM succeeds", 0, g_cause, ~0ul);

    /* Case C store: Page 0 (RW) -> Page 1 (RO), 8 x 32b starting at 0x1000 - 12 (elems 0,1,2 in
     * Page 0) */
    for (unsigned long b = 0; b < 32u; b++)
        vrf_io[b] = (uint8_t) (0xD0u + b);
    load_v8_group(vrf_io);
    setvl(8, 0x11ul);
    s_vse32_v8(VA_BASE + 4096u - 12u);
    check(g_cause == CAUSE_STORE_PAGE && g_tval == VA_BASE + 4096u && g_vstart_trap == 3ul,
          "Sv39 Case-C vse32 trap cause/tval/vstart",
          g_vstart_trap,
          g_cause,
          CAUSE_STORE_PAGE);
    wr_vstart(0);
    for (unsigned long b = 0; b < 12u; b++)
        check(frames[4096u - 12u + b] == (uint8_t) (0xD0u + b),
              "Sv39 Case-C vse32 Page-0 committed",
              b,
              frames[4096u - 12u + b],
              (uint8_t) (0xD0u + b));
    for (unsigned long b = 0; b < 20u; b++)
        check(frames[4096u + b] == frame_pat(4096u + b),
              "Sv39 Case-C vse32 Page-1 untouched",
              b,
              frames[4096u + b],
              frame_pat(4096u + b));

    /* Case C load + Demand-Paging resumption with straddling element!
     * Map Page 2 RW, unmap Page 3. Start 8 x 32b load at VA_BASE + 3*4096 - 10:
     *   elem 0: -10..-7 (Page 2)
     *   elem 1: -6..-3  (Page 2)
     *   elem 2: -2..+1  (straddles Page 2 & unmapped Page 3 -> faults at Page 3 base, vstart = 2!)
     */
    l0[2] = PTE_PPN(FRAMES + 2u * 4096u) | PTE_V | PTE_R | PTE_W | PTE_A | PTE_D;
    l0[3] = 0;
    __asm__ volatile("fence rw, rw\n sfence.vma" ::: "memory");

    /* First check partial VRF state on fault: elems 0,1 written, elems 2..7 keep sentinel! */
    seed_v8_group(0xCCu);
    setvl(8, 0x11ul);
    s_vle32_v8(VA_BASE + 3u * 4096u - 10u, 0);
    check(g_cause == CAUSE_LOAD_PAGE && g_tval == VA_BASE + 3u * 4096u && g_vstart_trap == 2ul &&
              rd_vstart() == 2ul,
          "Sv39 Case-C straddle vle32 trap",
          g_vstart_trap,
          g_cause,
          CAUSE_LOAD_PAGE);
    wr_vstart(0);
    store_v8_group(dump);
    for (unsigned long b = 0; b < 32u; b++) {
        uint8_t want = (b < 8u) ? frame_pat(2u * 4096u + 4096u - 10u + b) : seed_byte_for(0xCCu, b);
        check(dump[b] == want, "Sv39 Case-C partial VRF byte", b, dump[b], want);
    }

    /* Now true demand-paging resume: fault sets vstart=2, map Page 3, re-issue vle32 without
     * touching vstart! */
    seed_v8_group(0x55u);
    setvl(8, 0x11ul);
    s_vle32_v8(VA_BASE + 3u * 4096u - 10u, 0);
    check(g_cause == CAUSE_LOAD_PAGE && rd_vstart() == 2ul,
          "Sv39 demand-page fault step 1",
          rd_vstart(),
          g_cause,
          CAUSE_LOAD_PAGE);
    l0[3] = PTE_PPN(FRAMES + 3u * 4096u) | PTE_V | PTE_R | PTE_W | PTE_A | PTE_D;
    __asm__ volatile("fence rw, rw\n sfence.vma" ::: "memory");
    s_vle32_v8(VA_BASE + 3u * 4096u - 10u, 0);
    check(g_cause == ~0ul && rd_vstart() == 0ul,
          "Sv39 demand-page resume step 2",
          rd_vstart(),
          g_cause,
          ~0ul);
    store_v8_group(dump);
    for (unsigned long b = 0; b < 32u; b++)
        check(dump[b] == frame_pat(3u * 4096u - 10u + b),
              "Sv39 demand-page resumed byte",
              b,
              dump[b],
              frame_pat(3u * 4096u - 10u + b));

    /* Svpbmt: PBMTE=0 rejects nonzero PBMT with a page fault; PBMTE=1 refuses
     * NC/IO leaves on vector loads and stores with an access fault unless a
     * leaf permission check fails first (which wins as a page fault).
     */
    csr_clear(0x30A, 1ul << 62); /* menvcfg.PBMTE = 0 */
    l0[3] = PTE_PPN(FRAMES + 3u * 4096u) | (1ul << 61) | PTE_V | PTE_R | PTE_W | PTE_A | PTE_D;
    __asm__ volatile("fence rw, rw\n sfence.vma" ::: "memory");
    setvl(4, 0x10ul);
    s_vle32_v8(VA_BASE + 3u * 4096u, 0);
    check(g_cause == CAUSE_LOAD_PAGE && g_tval == VA_BASE + 3u * 4096u,
          "Svpbmt PBMTE=0 NC vle32 page fault",
          g_tval,
          g_cause,
          CAUSE_LOAD_PAGE);

    csr_set(0x30A, 1ul << 62); /* menvcfg.PBMTE = 1 */
    __asm__ volatile("sfence.vma" ::: "memory");
    s_vle32_v8(VA_BASE + 3u * 4096u, 0);
    check(g_cause == CAUSE_LOAD_ACCESS && g_tval == VA_BASE + 3u * 4096u && g_vstart_trap == 0ul,
          "Svpbmt NC vle32 access fault",
          g_tval,
          g_cause,
          CAUSE_LOAD_ACCESS);
    s_vse32_v8(VA_BASE + 3u * 4096u);
    check(g_cause == CAUSE_STORE_ACCESS && g_tval == VA_BASE + 3u * 4096u && g_vstart_trap == 0ul,
          "Svpbmt NC vse32 access fault",
          g_tval,
          g_cause,
          CAUSE_STORE_ACCESS);
    /* U-mode MPRV on S-only NC page (U=0): page fault takes precedence over access fault. */
    u_vle32_v8(VA_BASE + 3u * 4096u);
    check(g_cause == CAUSE_LOAD_PAGE && g_tval == VA_BASE + 3u * 4096u,
          "Svpbmt NC U-mode perm page fault wins",
          g_tval,
          g_cause,
          CAUSE_LOAD_PAGE);
    /* Reserved PBMT=3 raises page fault even with PBMTE=1. */
    l0[3] = PTE_PPN(FRAMES + 3u * 4096u) | (3ul << 61) | PTE_V | PTE_R | PTE_W | PTE_A | PTE_D;
    __asm__ volatile("fence rw, rw\n sfence.vma" ::: "memory");
    s_vle32_v8(VA_BASE + 3u * 4096u, 0);
    check(g_cause == CAUSE_LOAD_PAGE && g_tval == VA_BASE + 3u * 4096u,
          "Svpbmt PBMT=3 vle32 page fault",
          g_tval,
          g_cause,
          CAUSE_LOAD_PAGE);
    csr_clear(0x30A, 1ul << 62);
    wr_vstart(0);
    g_cause = ~0ul;
    g_tval = ~0ul;

    __asm__ volatile("csrw satp, zero\n sfence.vma" ::: "memory");
}

/* ========================================================================== */
/* 7. Speculation, misaligned scalar interleaving, and timer interrupts       */
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
                     "li   t0, 0x4000001c\n" /* MTIMECMP_HI = ~0u: disarm until next iter */
                     "li   t1, -1\n"
                     "sw   t1, 0(t0)\n"
                     "ld   t0, 0(sp)\n"
                     "ld   t1, 8(sp)\n"
                     "addi sp, sp, 16\n"
                     "mret\n");
}

static void test_speculation_misaligned_and_irqs(void)
{
    volatile uint8_t *dump = vrf_io + 1024;

    /* 7a. Speculative wrong-path squash of 4 back-to-back VLOAD/VSTOREs on a bad pointer */
    g_cause = ~0ul;
    g_tval = ~0ul;
    setvl(~0ul, 0x03ul);
    volatile uint64_t *flag = (volatile uint64_t *) (buf + 0x100);
    const volatile void *bad = (const volatile void *) 0xDEAD000000000000ul;
    for (int iter = 0; iter < 20; iter++) {
        *flag =
            (iter % 5 == 4) ? 1ull : 0ull; /* train not-taken, then take over wrong-path VMEMs */
        if (*flag == 0ull) {
            /* Taken to safe scalar work when *flag == 0; when *flag == 1, branch predictor
             * speculates into bad VMEMs if we invert condition! Let's train branch-not-taken
             * into harmless work, then jump over bad VMEMs on load-dependent branch: */
        }
        __asm__ volatile("ld t0, 0(%0)\n"
                         "beqz t0, 2f\n"
                         "j 3f\n"
                         "2:\n"
                         "nop\n"
                         "j 4f\n"
                         "3:\n"
                         "bnez t0, 4f\n"
                         ".insn r 0x07, 0, 0x01, x8, %1, x0\n"
                         ".insn r 0x27, 0, 0x01, x8, %1, x0\n"
                         ".insn r 0x07, 0, 0x01, x16, %1, x0\n"
                         ".insn r 0x27, 0, 0x01, x16, %1, x0\n"
                         "4:\n"
                         "fence rw, rw\n"
                         :
                         : "r"(flag), "r"(bad)
                         : "t0", "memory");
    }
    /* Also run explicit load-delayed taken branch over 4 speculative VMEMs (like vec_state_test) */
    *flag = 1ull;
    for (int iter = 0; iter < 16; iter++) {
        __asm__ volatile("ld t0, 0(%0)\n"
                         "bnez t0, 2f\n"
                         ".insn r 0x07, 0, 0x01, x8, %1, x0\n"
                         ".insn r 0x27, 0, 0x01, x8, %1, x0\n"
                         ".insn r 0x07, 0, 0x01, x16, %1, x0\n"
                         ".insn r 0x27, 0, 0x01, x16, %1, x0\n"
                         "2:\n"
                         "fence rw, rw\n"
                         :
                         : "r"(flag), "r"(bad)
                         : "t0", "memory");
    }
    *(uint64_t *) (ref + 0x100) = 1ull;
    check(g_cause == ~0ul, "speculative wrong-path VMEMs squashed cleanly", 0, g_cause, ~0ul);

    /* 7b. Interleaved misaligned scalar ld/sd + vmv.x.s feeding misaligned address + VLOAD/VSTORE
     */
    {
        unsigned long mbase = 0x1100ul;
        for (unsigned long i = 0; i < 2u * g_vlenb; i++)
            vrf_io[i] = (uint8_t) (0x17u + i * 9u);
        /* Place exact unaligned target pointer (buf + mbase + 3) in element 0 of v12, read via
         * vmv.x.s! */
        uint64_t mis_addr_val = (uint64_t) (uintptr_t) (buf + mbase + 3u);
        *(volatile uint64_t *) (vrf_io + 512) = mis_addr_val;
        load_v8_group(vrf_io);
        __asm__ volatile(".insn r 0x07, 0, 0x01, x12, %0, x8" : : "r"(vrf_io + 512) : "memory");
        setvl(~0ul, 0x18ul); /* e64, m1 for vmv.x.s */
        uint64_t elem0, mis_ld;
        uintptr_t vmv_ptr;
        __asm__ volatile(".word " S(OPV(
            0x10, 1, 8, 0, 2, 10)) "\n"
                                   "mv %0, a0\n"
                                   ".word " S(OPV(0x10, 1, 12, 0, 2, 10)) "\n"
                                                                          "mv %1, a0\n"
                         : "=&r"(elem0), "=r"(vmv_ptr)
                         :
                         : "a0", "memory");
        setvl(~0ul, 0x01ul);                                 /* e8, m2 */
        volatile uint8_t *mp = (volatile uint8_t *) vmv_ptr; /* vmv.x.s feeds misaligned address! */
        uint64_t mis_st = elem0 ^ 0x0102030405060708ull;
        __asm__ volatile(".insn r 0x27, 0, 0x01, x8, %1, x0\n"
                         "sd %2, 5(%1)\n"
                         "ld %0, 1(%1)\n"
                         ".insn r 0x07, 0, 0x01, x10, %1, x0\n"
                         : "=&r"(mis_ld)
                         : "r"(mp), "r"(mis_st)
                         : "memory");
        for (unsigned long i = 0; i < 2u * g_vlenb; i++)
            ref[mbase + 3u + i] = vrf_io[i];
        for (int b = 0; b < 8; b++)
            ref[mbase + 8u + b] = (uint8_t) (mis_st >> (8 * b));

        uint64_t want_mis = 0;
        for (int b = 0; b < 8; b++)
            want_mis |= (uint64_t) ref[mbase + 4u + b] << (8 * b);
        check(mis_ld == want_mis, "vse8->misaligned sd->misaligned ld", mbase, mis_ld, want_mis);
        store_v8_group(dump);
        for (unsigned long i = 0; i < 2u * g_vlenb; i++)
            check(dump[2u * g_vlenb + i] == ref[mbase + 3u + i],
                  "misaligned sd->vle8 byte",
                  i,
                  dump[2u * g_vlenb + i],
                  ref[mbase + 3u + i]);
    }

    /* 7c. Multi-sector VLOAD/VSTORE + vector arithmetic + misaligned scalar under CLINT timer IRQs
     */
    set_trap_handler(&timer_handler);
    g_irq = 0;
    MTIMECMP_HI = 0xFFFFFFFFu;
    enable_timer_interrupt();
    enable_interrupts();

    setvl(~0ul, 0x03ul); /* e8, m8 */
    for (unsigned long iter = 0; iter < 48; iter++) {
        unsigned long src_off = 0x200ul + (iter * 43ul) % 0x700ul;
        unsigned long dst_off = 0x1300ul + (iter * 53ul) % 0x900ul;
        volatile uint8_t *sp = buf + src_off;
        volatile uint8_t *dp = buf + dst_off;
        MTIMECMP_HI = 0xFFFFFFFFu;
        MTIMECMP_LO = MTIME_LO + 8u + (uint32_t) (iter * 5ul);
        MTIMECMP_HI = 0u;
        /* vle8.v v8, (sp); vadd.vi v8, v8, 3; vse8.v v8, (dp); plus misaligned scalar load check */
        __asm__ volatile(".insn r 0x07, 0, 0x01, x8, %0, x0\n"
                         ".word " S(OPV(0x00, 1, 8, 3, 3, 8)) "\n"
                                                              ".insn r 0x27, 0, 0x01, x8, %1, x0\n"
                         :
                         : "r"(sp), "r"(dp)
                         : "memory");
        for (unsigned long b = 0; b < 8u * g_vlenb; b++)
            ref[dst_off + b] = (uint8_t) (ref[src_off + b] + 3u);
        uint32_t got_w, want_w = 0;
        __asm__ volatile("lwu %0, 3(%1)" : "=r"(got_w) : "r"(dp) : "memory");
        for (int b = 0; b < 4; b++)
            want_w |= (uint32_t) ref[dst_off + 3u + b] << (8 * b);
        if (got_w != want_w) {
            check(0, "vmem+irq lwu mismatch", iter, got_w, want_w);
            break;
        }
    }

    disable_interrupts();
    disable_timer_interrupt();
    set_trap_handler(&bounce_handler);

    check(g_irq >= 8u, "timer interrupts fired during VMEM", 0, g_irq, 8u);
    const volatile uint64_t *buf64 = (const volatile uint64_t *) buf;
    const uint64_t *ref64 = (const uint64_t *) ref;
    for (unsigned long w = 0; w < BUF_BYTES / 8ul; w++) {
        if (buf64[w] != ref64[w]) {
            for (unsigned int k = 0; k < 8u; k++) {
                unsigned long i = w * 8ul + k;
                if (buf[i] != ref[i]) {
                    check(0, "post-irq DDR image byte", i, buf[i], ref[i]);
                    break;
                }
            }
            break;
        }
    }
    g_checks++;
}

int main(void)
{
    csr_write(mscratch, 0);
    set_trap_handler(&bounce_handler);
    set_vs(VS_INITIAL);

    __asm__ volatile("csrr %0, 0xC22" : "=r"(g_vlenb));
    g_vlen = g_vlenb * 8ul;
    uart_printf("vec_mem_test VLEN=%lu\n", g_vlen);
    check(
        g_vlen == 128ul || g_vlen == 256ul || g_vlen == 512ul, "supported VLEN", 0, g_vlen, 256ul);

    test_unit_stride_geometry();
    uart_printf("  [1] geometry ok\n");
    test_whole_reg_and_mask();
    uart_printf("  [2] whole/mask ok\n");
    test_mask_vstart_and_vs();
    uart_printf("  [3] mask/vstart/VS ok\n");
    test_legality();
    uart_printf("  [4] legality ok\n");
    test_ordering();
    uart_printf("  [5] ordering ok\n");
    test_pma_and_sv39();
    uart_printf("  [6] pma/sv39 ok\n");
    test_speculation_misaligned_and_irqs();
    uart_printf("  [7] spec/mis/irq ok\n");

    uart_printf("%d checks\n", g_checks);
    uart_printf(g_ok ? "<<PASS>>\n" : "<<FAIL>>\n");
    for (;;) {
    }
    return 0;
}
