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

/**
 * Misaligned loads and stores across M, S and U modes.
 *
 * In cached DDR every size and offset is performed: each load is checked
 * against a byte-by-byte reference (sign and zero extension, NaN boxing for
 * FLW), each store against the bytes it must change and the neighbours it
 * must keep, across a doubleword, a 32-byte sector, a 64-byte line and a 4 KiB
 * page, and with compressed and FP forms. A misaligned load to x0 writes
 * nothing, a store of x0 writes zeros, and an access retires as exactly one
 * instruction. In low BRAM a misaligned access raises the address-misaligned
 * exception with the access's address as the trap value. Under Sv39 (through
 * MPRV and in S and U modes, with direct and delegated traps), accesses cross
 * into read-only, unmapped, execute-only, supervisor and user pages, with the
 * trap value and the unchanged memory of a faulting store checked. Last,
 * misaligned accesses run while timer interrupts arrive at varying phases.
 */

#include <stdint.h>

#include "csr.h"
#include "trap.h"
#include "uart.h"

#define DDR_AREA 0x83000000ul /* three pages inside the simulation DDR model */
#define AREA_BYTES (3u * 4096u)

static volatile uint8_t *const area = (volatile uint8_t *) DDR_AREA;

static int g_ok = 1;
static int g_checks;
static volatile unsigned long g_cause;
static volatile unsigned long g_epc;
static volatile unsigned long g_tval;

/* Byte pattern of the reference image. */
static uint8_t pattern(unsigned long offset)
{
    return (uint8_t) (offset * 151u + (offset >> 8) * 29u + 7u);
}

static uint8_t ref[AREA_BYTES];

static void fill(void)
{
    for (unsigned long i = 0; i < AREA_BYTES; i++) {
        ref[i] = pattern(i);
        area[i] = ref[i];
    }
}

static uint64_t ref_bytes(unsigned long offset, unsigned int count)
{
    uint64_t value = 0;
    for (unsigned int i = 0; i < count; i++)
        value |= (uint64_t) ref[offset + i] << (8u * i);
    return value;
}

static void check(int ok, const char *what, unsigned long offset, uint64_t got, uint64_t want)
{
    g_checks++;
    if (!ok) {
        g_ok = 0;
        uart_printf("[FAIL] %s at +%lx: got %lx want %lx\n",
                    what,
                    offset,
                    (unsigned long) got,
                    (unsigned long) want);
    }
}

static int64_t sext(uint64_t value, unsigned int bits)
{
    uint64_t sign = 1ull << (bits - 1u);
    return (int64_t) ((value ^ sign) - sign);
}

static void check_loads(unsigned long offset)
{
    volatile uint8_t *p = area + offset;
    uint64_t v;
    v = ref_bytes(offset, 2);
    {
        int64_t r;
        uint64_t u;
        __asm__ volatile("lh %0, 0(%1)" : "=r"(r) : "r"(p) : "memory");
        check(r == sext(v, 16), "lh", offset, (uint64_t) r, (uint64_t) sext(v, 16));
        __asm__ volatile("lhu %0, 0(%1)" : "=r"(u) : "r"(p) : "memory");
        check(u == v, "lhu", offset, u, v);
    }
    v = ref_bytes(offset, 4);
    {
        int64_t r;
        uint64_t u;
        __asm__ volatile("lw %0, 0(%1)" : "=r"(r) : "r"(p) : "memory");
        check(r == sext(v, 32), "lw", offset, (uint64_t) r, (uint64_t) sext(v, 32));
        __asm__ volatile("lwu %0, 0(%1)" : "=r"(u) : "r"(p) : "memory");
        check(u == v, "lwu", offset, u, v);
        __asm__ volatile("flw ft0, 0(%1)\n fmv.x.d %0, ft0" : "=r"(u) : "r"(p) : "ft0", "memory");
        check(u == (v | 0xFFFFFFFF00000000ull), "flw", offset, u, v | 0xFFFFFFFF00000000ull);
    }
    v = ref_bytes(offset, 8);
    {
        uint64_t u;
        __asm__ volatile("ld %0, 0(%1)" : "=r"(u) : "r"(p) : "memory");
        check(u == v, "ld", offset, u, v);
        __asm__ volatile("fld ft0, 0(%1)\n fmv.x.d %0, ft0" : "=r"(u) : "r"(p) : "ft0", "memory");
        check(u == v, "fld", offset, u, v);
    }
    {
        /* Compressed forms with x8..x15 operands. */
        register uint64_t base __asm__("a1") = (uint64_t) p;
        register uint64_t out __asm__("a0");
        __asm__ volatile(".option push\n .option rvc\n c.lw a0, 0(a1)\n .option pop"
                         : "=r"(out)
                         : "r"(base)
                         : "memory");
        check(out == (uint64_t) sext(ref_bytes(offset, 4), 32),
              "c.lw",
              offset,
              out,
              (uint64_t) sext(ref_bytes(offset, 4), 32));
        __asm__ volatile(".option push\n .option rvc\n c.ld a0, 0(a1)\n .option pop"
                         : "=r"(out)
                         : "r"(base)
                         : "memory");
        check(out == ref_bytes(offset, 8), "c.ld", offset, out, ref_bytes(offset, 8));
    }
}

/* Store count bytes of value at offset with the given instruction, then
 * check the window around it. */
static void check_store(unsigned long offset, unsigned int count, int fp, uint64_t value)
{
    volatile uint8_t *p = area + offset;
    if (count == 2) {
        __asm__ volatile("sh %0, 0(%1)" : : "r"(value), "r"(p) : "memory");
    } else if (count == 4) {
        if (fp)
            __asm__ volatile("fmv.d.x ft1, %0\n fsw ft1, 0(%1)"
                             :
                             : "r"(value), "r"(p)
                             : "ft1", "memory");
        else
            __asm__ volatile("sw %0, 0(%1)" : : "r"(value), "r"(p) : "memory");
    } else {
        if (fp)
            __asm__ volatile("fmv.d.x ft1, %0\n fsd ft1, 0(%1)"
                             :
                             : "r"(value), "r"(p)
                             : "ft1", "memory");
        else
            __asm__ volatile("sd %0, 0(%1)" : : "r"(value), "r"(p) : "memory");
    }
    for (unsigned int i = 0; i < count; i++)
        ref[offset + i] = (uint8_t) (value >> (8u * i));
    unsigned long lo = offset >= 16 ? offset - 16 : 0;
    unsigned long hi = offset + count + 16 <= AREA_BYTES ? offset + count + 16 : AREA_BYTES;
    for (unsigned long i = lo; i < hi; i++)
        check(area[i] == ref[i], fp ? "fp store byte" : "store byte", i, area[i], ref[i]);
}

/* Offsets: inside a doubleword, across one, and ending just past a sector,
 * a line and a page boundary. */
static const unsigned long g_bases[] = {0x10, 0x18, 0x40, 0x7c0, 0x1000, 0x1fe0};

/* M-mode bounce handler: record the trap and resume in M-mode at mscratch. */
__attribute__((naked, aligned(4))) static void bounce_handler(void)
{
    __asm__ volatile("csrr t0, mcause\n"
                     "la   t1, g_cause\n"
                     "sd   t0, 0(t1)\n"
                     "csrr t0, mepc\n"
                     "la   t1, g_epc\n"
                     "sd   t0, 0(t1)\n"
                     "csrr t0, mtval\n"
                     "la   t1, g_tval\n"
                     "sd   t0, 0(t1)\n"
                     "csrr t0, mscratch\n"
                     "csrw mepc, t0\n"
                     "li   t0, 0x1800\n"
                     "csrs mstatus, t0\n"
                     "mret\n");
}

extern char trig_bram_load[], trig_bram_store[];

/* Sv39 through an MPRV window: M-mode code, data accesses translated at S.
 * VA 0x40_0000 + n * 4 KiB maps frame n of FRAMES with these leaves: */
#define PT_ROOT 0x83010000ul
#define PT_L1 0x83011000ul
#define PT_L0 0x83012000ul
#define PT_ROOT_U 0x83013000ul
#define PT_L1_U 0x83014000ul
#define PT_L0_U 0x83015000ul
#define FRAMES 0x83020000ul
#define VA_BASE 0x00400000ul
#define GIGA 0x40000000ul
#define S_HANDLER_ALIAS (4ul * GIGA)
#define MODE_U 0ul
#define MODE_S 1ul
#define MSTATUS_SUM (1ul << 18)
#define MSTATUS_MXR (1ul << 19)
#define PTE_V (1ul << 0)
#define PTE_R (1ul << 1)
#define PTE_W (1ul << 2)
#define PTE_X (1ul << 3)
#define PTE_U (1ul << 4)
#define PTE_G (1ul << 5)
#define PTE_A (1ul << 6)
#define PTE_D (1ul << 7)
#define PTE_PPN(pa) ((((unsigned long) (pa)) >> 12) << 10)
#define SATP_SV39 (8ul << 60)
#define CAUSE_LOAD_PAGE_FAULT 13ul
#define CAUSE_STORE_PAGE_FAULT 15ul
static const unsigned long g_leaf_flags[7] = {
    PTE_R | PTE_W | PTE_A | PTE_D,         /* 0: read-write */
    PTE_R | PTE_A,                         /* 1: read-only */
    0,                                     /* 2: unmapped */
    PTE_R | PTE_W | PTE_A | PTE_D,         /* 3: read-write */
    PTE_R | PTE_W | PTE_U | PTE_A | PTE_D, /* 4: user page, no access at S without SUM */
    0,                                     /* 5: unmapped */
    0,                                     /* 6: unmapped */
};

static uint8_t frame_byte(unsigned long offset)
{
    return (uint8_t) (offset * 73u + (offset >> 12) * 41u + 3u);
}

static uint64_t frame_bytes(unsigned long offset, unsigned int count)
{
    uint64_t value = 0;
    for (unsigned int i = 0; i < count; i++)
        value |= (uint64_t) frame_byte(offset + i) << (8u * i);
    return value;
}

/* One access at S through the MPRV window. A fault resumes at label 1 through
 * the bounce handler; MPRV is cleared on both paths. */
#define MPRV_ON                                                                                    \
    "li t1, 0x1800\n csrc mstatus, t1\n li t1, 0x0800\n csrs mstatus, t1\n"                        \
    "li t1, 0x20000\n csrs mstatus, t1\n"
#define MPRV_OFF "1:\n li t1, 0x20000\n csrc mstatus, t1\n"

static uint64_t s_ld(unsigned long va)
{
    uint64_t value = 0xBAD0BAD0BAD0BAD0ull;
    g_cause = ~0ul;
    __asm__ volatile("la t0, 1f\n csrw mscratch, t0\n" MPRV_ON "ld %0, 0(%1)\n" MPRV_OFF
                     : "+r"(value)
                     : "r"(va)
                     : "t0", "t1", "memory");
    return value;
}

static uint64_t s_lw(unsigned long va)
{
    uint64_t value = 0xBAD0BAD0BAD0BAD0ull;
    g_cause = ~0ul;
    __asm__ volatile("la t0, 1f\n csrw mscratch, t0\n" MPRV_ON "lwu %0, 0(%1)\n" MPRV_OFF
                     : "+r"(value)
                     : "r"(va)
                     : "t0", "t1", "memory");
    return value;
}

static void s_sd(unsigned long va, uint64_t value)
{
    g_cause = ~0ul;
    __asm__ volatile("la t0, 1f\n csrw mscratch, t0\n" MPRV_ON "sd %0, 0(%1)\n" MPRV_OFF
                     :
                     : "r"(value), "r"(va)
                     : "t0", "t1", "memory");
}

static void check_fault(const char *what, unsigned long cause, unsigned long tval)
{
    check(g_cause == cause && g_tval == tval, what, g_tval, g_cause, tval);
}

/* Translated misaligned accesses: across a page into each kind of upper
 * page, with the lower page unmapped, and with both unmapped. A fault of the
 * upper page reports that page's base; any other reports the access's
 * address. A faulting store changes nothing. */
static void check_sv39(void)
{
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
    l1[2] = PTE_PPN(PT_L0) | PTE_V; /* VA 0x40_0000 */
    for (unsigned long n = 0; n < 7; n++)
        if (g_leaf_flags[n] != 0)
            l0[n] = PTE_PPN(FRAMES + n * 4096u) | PTE_V | g_leaf_flags[n];
    for (unsigned long i = 0; i < 7u * 4096u; i++)
        frames[i] = frame_byte(i);
    __asm__ volatile("fence rw, rw\n csrw satp, %0\n sfence.vma"
                     :
                     : "r"(SATP_SV39 | (PT_ROOT >> 12))
                     : "memory");

    const unsigned long page = 4096u;
    uint64_t got;

    /* Read-write into read-only: the load is performed. */
    got = s_ld(VA_BASE + page - 3u);
    check(g_cause == ~0ul && got == frame_bytes(page - 3u, 8),
          "sv39 ld across pages",
          page - 3u,
          got,
          frame_bytes(page - 3u, 8));
    /* ... and the store faults on the upper page and writes nothing. */
    s_sd(VA_BASE + page - 5u, 0x0102030405060708ull);
    check_fault("sv39 sd into read-only page", CAUSE_STORE_PAGE_FAULT, VA_BASE + page);
    for (unsigned long i = page - 8u; i < page + 8u; i++)
        check(frames[i] == frame_byte(i), "sv39 faulting sd byte", i, frames[i], frame_byte(i));
    /* Into an unmapped page. */
    got = s_ld(VA_BASE + 2u * page - 2u);
    check_fault("sv39 ld into unmapped page", CAUSE_LOAD_PAGE_FAULT, VA_BASE + 2u * page);
    check(got == 0xBAD0BAD0BAD0BAD0ull,
          "sv39 faulting ld writes nothing",
          0,
          got,
          0xBAD0BAD0BAD0BAD0ull);
    /* Out of an unmapped page into a mapped one: the lower part's fault. */
    s_lw(VA_BASE + 3u * page - 2u);
    check_fault("sv39 lw from unmapped page", CAUSE_LOAD_PAGE_FAULT, VA_BASE + 3u * page - 2u);
    /* Into a user page, at S without SUM. */
    s_lw(VA_BASE + 4u * page - 1u);
    check_fault("sv39 lw into user page", CAUSE_LOAD_PAGE_FAULT, VA_BASE + 4u * page);
    /* Both pages unmapped: the lower one is reported. */
    s_lw(VA_BASE + 6u * page - 2u);
    check_fault("sv39 lw across unmapped pages", CAUSE_LOAD_PAGE_FAULT, VA_BASE + 6u * page - 2u);
    /* A store across a line inside a read-write page is performed. */
    s_sd(VA_BASE + 3u * page + 0x7Cu, 0x8877665544332211ull);
    check(g_cause == ~0ul, "sv39 sd across a line", 0x7Cu, g_cause, ~0ul);
    got = s_ld(VA_BASE + 3u * page + 0x7Cu);
    check(got == 0x8877665544332211ull, "sv39 ld after sd", 0x7Cu, got, 0x8877665544332211ull);
    for (unsigned long i = 0; i < 8; i++) {
        unsigned long pa_off = 3u * page + 0x7Cu + i;
        uint8_t want = (uint8_t) (0x8877665544332211ull >> (8u * i));
        check(frames[pa_off] == want, "sv39 sd byte", pa_off, frames[pa_off], want);
    }

    __asm__ volatile("csrw satp, zero\n sfence.vma" ::: "memory");
}

/* S-mode bounce handler: ecall to M-mode, keeping scause/sepc/stval intact. */
__attribute__((naked, aligned(4))) static void s_bounce_handler(void)
{
    __asm__ volatile(".option push\n .option norvc\n ecall\n j .\n .option pop");
}

#define MA_BODY(name, insn)                                                                        \
    __attribute__((naked, aligned(4))) static void name(void)                                      \
    {                                                                                              \
        __asm__ volatile(".option push\n .option norvc\n " insn "\n ecall\n j .\n .option pop");   \
    }
MA_BODY(b_ma_ld, "ld a1, 0(a0)")
MA_BODY(b_ma_lwu, "lwu a1, 0(a0)")
MA_BODY(b_ma_sd, "sd a1, 0(a0)")

/* Enter S or U mode (mpp = MODE_S or MODE_U) with MPRV=0, execute the body at
 * pc with a0=va and a1=in_val, and return a1 after the body or trap handler
 * returns to M-mode. */
__attribute__((noinline)) static uint64_t
run_ma_mode(unsigned long mpp, const void *pc, unsigned long va, uint64_t in_val)
{
    register unsigned long a0 __asm__("a0") = va;
    register uint64_t a1 __asm__("a1") = in_val;
    unsigned long mpp_bits = (mpp & 3ul) << 11;
    g_cause = ~0ul;
    g_epc = 0;
    g_tval = ~0ul;
    __asm__ volatile("csrw scause, %[ones]\n"
                     "csrw sepc, zero\n"
                     "csrw stval, zero\n"
                     "la   t0, 1f\n"
                     "csrw mscratch, t0\n"
                     "li   t0, 0x21800\n"
                     "csrc mstatus, t0\n"
                     "csrs mstatus, %[mpp]\n"
                     "csrw mepc, %[pc]\n"
                     "mret\n"
                     "1:\n"
                     : [a0] "+r"(a0), [a1] "+r"(a1)
                     : [pc] "r"(pc), [mpp] "r"(mpp_bits), [ones] "r"(~0ul)
                     : "t0", "t1", "memory");
    return a1;
}

static void check_deleg_fault(const char *what,
                              unsigned long mpp,
                              unsigned long stvec_va,
                              const void *pc,
                              unsigned long cause,
                              unsigned long tval)
{
    unsigned long scause, sepc, stval, sstatus;
    __asm__ volatile("csrr %0, scause\n"
                     "csrr %1, sepc\n"
                     "csrr %2, stval\n"
                     "csrr %3, sstatus"
                     : "=r"(scause), "=r"(sepc), "=r"(stval), "=r"(sstatus));
    unsigned long spp = (sstatus >> 8) & 1ul;
    int ok = g_cause == 9ul && g_epc == stvec_va && scause == cause && sepc == (unsigned long) pc &&
             stval == tval && spp == mpp;
    check(ok, what, stval, scause, cause);
}

/* Sv39 misaligned accesses executed directly in S-mode and U-mode (instruction
 * fetch and data translation active together, with ASIDs, global leaves, SUM,
 * MXR, non-contiguous frames, and direct and medeleg-delegated page faults). */
static void check_sv39_modes(void)
{
    volatile unsigned long *root = (volatile unsigned long *) PT_ROOT;
    volatile unsigned long *l1 = (volatile unsigned long *) PT_L1;
    volatile unsigned long *l0 = (volatile unsigned long *) PT_L0;
    volatile unsigned long *root_u = (volatile unsigned long *) PT_ROOT_U;
    volatile unsigned long *l1_u = (volatile unsigned long *) PT_L1_U;
    volatile unsigned long *l0_u = (volatile unsigned long *) PT_L0_U;
    volatile uint8_t *frames = (volatile uint8_t *) FRAMES;
    const unsigned long page = 4096u;
    const unsigned long deleg_pf = (1ul << CAUSE_LOAD_PAGE_FAULT) | (1ul << CAUSE_STORE_PAGE_FAULT);

    for (int i = 0; i < 512; i++) {
        root[i] = 0;
        l1[i] = 0;
        l0[i] = 0;
        root_u[i] = 0;
        l1_u[i] = 0;
        l0_u[i] = 0;
    }

    /* S-mode page table: identity superpages over low BRAM (2 MiB at PA 0) and
     * DDR (1 GiB at PA 0x8000_0000), plus 4 KiB leaves at VA_BASE. */
    root[0] = PTE_PPN(PT_L1) | PTE_V;
    root[2] = PTE_PPN(2ul * GIGA) | PTE_V | PTE_R | PTE_W | PTE_X | PTE_A | PTE_D;
    l1[0] = PTE_PPN(0) | PTE_V | PTE_R | PTE_W | PTE_X | PTE_A | PTE_D;
    l1[2] = PTE_PPN(PT_L0) | PTE_V;
    l0[0] = PTE_PPN(FRAMES + 0u * page) | PTE_V | PTE_R | PTE_W | PTE_G | PTE_A | PTE_D;
    l0[1] = PTE_PPN(FRAMES + 1u * page) | PTE_V | PTE_R | PTE_A;
    l0[2] = 0;
    l0[3] = PTE_PPN(FRAMES + 3u * page) | PTE_V | PTE_R | PTE_W | PTE_A | PTE_D;
    l0[4] = PTE_PPN(FRAMES + 4u * page) | PTE_V | PTE_R | PTE_W | PTE_U | PTE_A | PTE_D;
    l0[5] = PTE_PPN(FRAMES + 5u * page) | PTE_V | PTE_R | PTE_W | PTE_A | PTE_D;
    l0[6] = PTE_PPN(FRAMES + 6u * page) | PTE_V | PTE_X | PTE_A;

    for (unsigned long i = 0; i < 7u * page; i++)
        frames[i] = frame_byte(i);

    unsigned long s_stvec = (unsigned long) &s_bounce_handler;
    __asm__ volatile("csrw medeleg, zero\n"
                     "csrw stvec, %0\n"
                     "csrc mstatus, %1\n"
                     "fence rw, rw\n"
                     "csrw satp, %2\n"
                     "sfence.vma"
                     :
                     : "r"(s_stvec),
                       "r"(MSTATUS_SUM | MSTATUS_MXR),
                       "r"(SATP_SV39 | (1ul << 44) | (PT_ROOT >> 12))
                     : "memory");

    uint64_t got;
    const uint64_t sentinel = 0xBAD0BAD0BAD0BAD0ull;

    /* S-mode: load across global RW leaf into RO upper page. */
    got = run_ma_mode(MODE_S, &b_ma_ld, VA_BASE + page - 3u, sentinel);
    check(g_cause == 9ul && g_epc == (unsigned long) &b_ma_ld + 4u &&
              got == frame_bytes(page - 3u, 8),
          "s-mode ld across pages",
          page - 3u,
          got,
          frame_bytes(page - 3u, 8));

    /* S-mode, direct trap to M: store faults on RO upper page and writes nothing. */
    run_ma_mode(MODE_S, &b_ma_sd, VA_BASE + page - 5u, 0x1122334455667788ull);
    check(g_cause == CAUSE_STORE_PAGE_FAULT && g_epc == (unsigned long) &b_ma_sd &&
              g_tval == VA_BASE + page,
          "s-mode direct sd ro fault",
          g_tval,
          g_cause,
          CAUSE_STORE_PAGE_FAULT);
    for (unsigned long i = page - 8u; i < page + 8u; i++)
        check(frames[i] == frame_byte(i), "s-mode direct sd byte", i, frames[i], frame_byte(i));

    /* Delegate load/store page faults to S-mode. */
    __asm__ volatile("csrw medeleg, %0" : : "r"(deleg_pf));

    run_ma_mode(MODE_S, &b_ma_sd, VA_BASE + page - 5u, 0x99AABBCCDDEEFF00ull);
    check_deleg_fault("s-mode deleg sd ro fault",
                      MODE_S,
                      s_stvec,
                      &b_ma_sd,
                      CAUSE_STORE_PAGE_FAULT,
                      VA_BASE + page);
    for (unsigned long i = page - 8u; i < page + 8u; i++)
        check(frames[i] == frame_byte(i), "s-mode deleg sd byte", i, frames[i], frame_byte(i));

    got = run_ma_mode(MODE_S, &b_ma_ld, VA_BASE + 2u * page - 2u, sentinel);
    check_deleg_fault("s-mode deleg ld unmapped",
                      MODE_S,
                      s_stvec,
                      &b_ma_ld,
                      CAUSE_LOAD_PAGE_FAULT,
                      VA_BASE + 2u * page);
    check(got == sentinel, "s-mode deleg ld dest", 0, got, sentinel);

    /* S-mode crossing into a U page: faults with SUM=0, succeeds with SUM=1. */
    run_ma_mode(MODE_S, &b_ma_sd, VA_BASE + 4u * page - 6u, 0xA5A5A5A55A5A5A5Aull);
    check_deleg_fault("s-mode sd user sum=0",
                      MODE_S,
                      s_stvec,
                      &b_ma_sd,
                      CAUSE_STORE_PAGE_FAULT,
                      VA_BASE + 4u * page);
    for (unsigned long i = 4u * page - 8u; i < 4u * page + 8u; i++)
        check(frames[i] == frame_byte(i), "s-mode sum=0 byte", i, frames[i], frame_byte(i));

    __asm__ volatile("csrs mstatus, %0" : : "r"(MSTATUS_SUM));
    run_ma_mode(MODE_S, &b_ma_sd, VA_BASE + 4u * page - 6u, 0xA5A5A5A55A5A5A5Aull);
    check(g_cause == 9ul && g_epc == (unsigned long) &b_ma_sd + 4u,
          "s-mode sd user sum=1",
          0,
          g_cause,
          9ul);
    got = run_ma_mode(MODE_S, &b_ma_ld, VA_BASE + 4u * page - 6u, sentinel);
    check(g_cause == 9ul && got == 0xA5A5A5A55A5A5A5Aull,
          "s-mode ld user sum=1",
          0,
          got,
          0xA5A5A5A55A5A5A5Aull);
    __asm__ volatile("csrc mstatus, %0" : : "r"(MSTATUS_SUM));
    for (unsigned long i = 4u * page - 8u; i < 4u * page + 8u; i++)
        frames[i] = frame_byte(i);

    /* S-mode crossing into an execute-only page: faults with MXR=0, loads with MXR=1. */
    got = run_ma_mode(MODE_S, &b_ma_lwu, VA_BASE + 6u * page - 1u, sentinel);
    check_deleg_fault("s-mode lwu xo mxr=0",
                      MODE_S,
                      s_stvec,
                      &b_ma_lwu,
                      CAUSE_LOAD_PAGE_FAULT,
                      VA_BASE + 6u * page);
    check(got == sentinel, "s-mode mxr=0 dest", 0, got, sentinel);

    __asm__ volatile("csrs mstatus, %0" : : "r"(MSTATUS_MXR));
    got = run_ma_mode(MODE_S, &b_ma_lwu, VA_BASE + 6u * page - 1u, sentinel);
    check(g_cause == 9ul && got == frame_bytes(6u * page - 1u, 4),
          "s-mode lwu xo mxr=1",
          0,
          got,
          frame_bytes(6u * page - 1u, 4));
    __asm__ volatile("csrc mstatus, %0" : : "r"(MSTATUS_MXR));

    /* U-mode page table: user identity superpages for code fetch, supervisor
     * alias superpages (+S_HANDLER_ALIAS) for s_bounce_handler, and 4 KiB
     * leaves at VA_BASE with non-contiguous frames and mixed permissions. */
    root_u[0] = PTE_PPN(PT_L1_U) | PTE_V;
    root_u[2] = PTE_PPN(2ul * GIGA) | PTE_V | PTE_R | PTE_W | PTE_X | PTE_U | PTE_A | PTE_D;
    root_u[4] = PTE_PPN(0) | PTE_V | PTE_R | PTE_W | PTE_X | PTE_A | PTE_D;
    root_u[6] = PTE_PPN(2ul * GIGA) | PTE_V | PTE_R | PTE_W | PTE_X | PTE_A | PTE_D;
    l1_u[0] = PTE_PPN(0) | PTE_V | PTE_R | PTE_W | PTE_X | PTE_U | PTE_A | PTE_D;
    l1_u[2] = PTE_PPN(PT_L0_U) | PTE_V;
    l0_u[0] = PTE_PPN(FRAMES + 5u * page) | PTE_V | PTE_R | PTE_W | PTE_U | PTE_A | PTE_D;
    l0_u[1] = PTE_PPN(FRAMES + 0u * page) | PTE_V | PTE_R | PTE_W | PTE_U | PTE_A | PTE_D;
    l0_u[2] = PTE_PPN(FRAMES + 1u * page) | PTE_V | PTE_R | PTE_U | PTE_A;
    l0_u[3] = 0;
    l0_u[4] = PTE_PPN(FRAMES + 2u * page) | PTE_V | PTE_R | PTE_W | PTE_U | PTE_A | PTE_D;
    l0_u[5] = PTE_PPN(FRAMES + 3u * page) | PTE_V | PTE_R | PTE_W | PTE_G | PTE_A | PTE_D;

    unsigned long u_stvec = (unsigned long) &s_bounce_handler + S_HANDLER_ALIAS;
    __asm__ volatile("csrw stvec, %0\n"
                     "fence rw, rw\n"
                     "csrw satp, %1\n"
                     "sfence.vma"
                     :
                     : "r"(u_stvec), "r"(SATP_SV39 | (2ul << 44) | (PT_ROOT_U >> 12))
                     : "memory");

    /* U-mode: store and load across two U RW pages backed by non-contiguous frames (5 and 0). */
    const uint64_t u_val = 0xCAFEBABE12345678ull;
    run_ma_mode(MODE_U, &b_ma_sd, VA_BASE + page - 5u, u_val);
    check(g_cause == 8ul && g_epc == (unsigned long) &b_ma_sd + 4u,
          "u-mode sd across non-contig pages",
          0,
          g_cause,
          8ul);
    got = run_ma_mode(MODE_U, &b_ma_ld, VA_BASE + page - 5u, sentinel);
    check(g_cause == 8ul && got == u_val, "u-mode ld across non-contig pages", 0, got, u_val);
    for (unsigned int k = 0; k < 8; k++) {
        unsigned long pa_off = k < 5u ? (6u * page - 5u + k) : (k - 5u);
        uint8_t want = (uint8_t) (u_val >> (8u * k));
        check(frames[pa_off] == want, "u-mode non-contig sd byte", pa_off, frames[pa_off], want);
        frames[pa_off] = frame_byte(pa_off);
    }

    /* U-mode: load across U RW (frame 0) into U RO (frame 1). */
    got = run_ma_mode(MODE_U, &b_ma_ld, VA_BASE + 2u * page - 3u, sentinel);
    check(g_cause == 8ul && got == frame_bytes(page - 3u, 8),
          "u-mode ld into ro page",
          page - 3u,
          got,
          frame_bytes(page - 3u, 8));

    /* U-mode: store into U RO upper page, direct to M and delegated to S. */
    __asm__ volatile("csrw medeleg, zero");
    run_ma_mode(MODE_U, &b_ma_sd, VA_BASE + 2u * page - 5u, 0xDEADBEEFCAFE0000ull);
    check(g_cause == CAUSE_STORE_PAGE_FAULT && g_epc == (unsigned long) &b_ma_sd &&
              g_tval == VA_BASE + 2u * page,
          "u-mode direct sd ro fault",
          g_tval,
          g_cause,
          CAUSE_STORE_PAGE_FAULT);
    for (unsigned long i = page - 8u; i < page + 8u; i++)
        check(frames[i] == frame_byte(i), "u-mode direct sd byte", i, frames[i], frame_byte(i));

    __asm__ volatile("csrw medeleg, %0" : : "r"(deleg_pf));
    run_ma_mode(MODE_U, &b_ma_sd, VA_BASE + 2u * page - 5u, 0xDEADBEEFCAFE0000ull);
    check_deleg_fault("u-mode deleg sd ro fault",
                      MODE_U,
                      u_stvec,
                      &b_ma_sd,
                      CAUSE_STORE_PAGE_FAULT,
                      VA_BASE + 2u * page);
    for (unsigned long i = page - 8u; i < page + 8u; i++)
        check(frames[i] == frame_byte(i), "u-mode deleg sd byte", i, frames[i], frame_byte(i));

    /* U-mode: load into unmapped upper page. */
    got = run_ma_mode(MODE_U, &b_ma_ld, VA_BASE + 3u * page - 2u, sentinel);
    check_deleg_fault("u-mode deleg ld unmapped",
                      MODE_U,
                      u_stvec,
                      &b_ma_ld,
                      CAUSE_LOAD_PAGE_FAULT,
                      VA_BASE + 3u * page);
    check(got == sentinel, "u-mode deleg ld dest", 0, got, sentinel);

    /* U-mode: store and load into supervisor upper page (PTE_U=0) fault even with SUM=1. */
    __asm__ volatile("csrs mstatus, %0" : : "r"(MSTATUS_SUM));
    run_ma_mode(MODE_U, &b_ma_sd, VA_BASE + 5u * page - 3u, 0x0F0E0D0C0B0A0908ull);
    check_deleg_fault("u-mode sd supervisor upper",
                      MODE_U,
                      u_stvec,
                      &b_ma_sd,
                      CAUSE_STORE_PAGE_FAULT,
                      VA_BASE + 5u * page);
    for (unsigned long i = 3u * page - 8u; i < 3u * page + 8u; i++)
        check(frames[i] == frame_byte(i), "u-mode sd sup byte", i, frames[i], frame_byte(i));

    got = run_ma_mode(MODE_U, &b_ma_lwu, VA_BASE + 5u * page - 1u, sentinel);
    check_deleg_fault("u-mode lwu supervisor upper",
                      MODE_U,
                      u_stvec,
                      &b_ma_lwu,
                      CAUSE_LOAD_PAGE_FAULT,
                      VA_BASE + 5u * page);
    check(got == sentinel, "u-mode lwu sup dest", 0, got, sentinel);

    __asm__ volatile("csrw medeleg, zero\n"
                     "csrw stvec, zero\n"
                     "csrc mstatus, %0\n"
                     "csrw satp, zero\n"
                     "sfence.vma"
                     :
                     : "r"(MSTATUS_SUM | MSTATUS_MXR)
                     : "memory");
}

static volatile uint32_t g_irq;

/* Timer handler: count, re-arm 300 to 555 cycles ahead (longer than the
 * trap round trip, about as long as an engine access), and MRET. */
__attribute__((naked, aligned(4))) static void timer_handler(void)
{
    __asm__ volatile("addi sp, sp, -32\n"
                     "sd   t0, 0(sp)\n"
                     "sd   t1, 8(sp)\n"
                     "sd   t2, 16(sp)\n"
                     "la   t0, g_irq\n"
                     "lw   t1, 0(t0)\n"
                     "andi t2, t1, 0xff\n"
                     "addi t2, t2, 300\n"
                     "addi t1, t1, 1\n"
                     "sw   t1, 0(t0)\n"
                     "li   t0, 0x40000010\n" /* MTIME_LO */
                     "lw   t1, 0(t0)\n"
                     "add  t1, t1, t2\n"
                     "li   t0, 0x40000018\n" /* MTIMECMP_LO; MTIMECMP_HI is 0 */
                     "sw   t1, 0(t0)\n"
                     "ld   t0, 0(sp)\n"
                     "ld   t1, 8(sp)\n"
                     "ld   t2, 16(sp)\n"
                     "addi sp, sp, 32\n"
                     "mret\n");
}

/* Misaligned stores and loads while timer interrupts arrive at varying
 * phases: an interrupt waits for the engine, and no result is lost or
 * written twice. */
static void check_under_interrupts(void)
{
    set_trap_handler(&timer_handler);
    MTIMECMP_HI = 0;
    MTIMECMP_LO = (uint32_t) rdmtime() + 50;
    enable_timer_interrupt();
    enable_interrupts();
    for (unsigned long i = 0; i < 200; i++) {
        unsigned long offset = 0x200 + (i * 37u) % 0x600u;
        if ((offset & 7u) == 0)
            offset++;
        uint64_t value = 0x9E3779B97F4A7C15ull * (i + 1u);
        __asm__ volatile("sd %0, 0(%1)" : : "r"(value), "r"(area + offset) : "memory");
        for (unsigned int k = 0; k < 8; k++)
            ref[offset + k] = (uint8_t) (value >> (8u * k));
        uint64_t got;
        int64_t word;
        __asm__ volatile("ld %0, 0(%1)" : "=r"(got) : "r"(area + offset) : "memory");
        check(got == value, "ld under interrupts", offset, got, value);
        __asm__ volatile("lw %0, 1(%1)" : "=r"(word) : "r"(area + offset) : "memory");
        check(word == sext(ref_bytes(offset + 1u, 4), 32),
              "lw under interrupts",
              offset + 1u,
              (uint64_t) word,
              (uint64_t) sext(ref_bytes(offset + 1u, 4), 32));
    }
    disable_interrupts();
    disable_timer_interrupt();
    check(g_irq >= 20u, "timer interrupts", 0, g_irq, 20u);
    for (unsigned long i = 0; i < AREA_BYTES; i++)
        if (area[i] != ref[i]) {
            check(0, "area byte", i, area[i], ref[i]);
            break;
        }
}

int main(void)
{
    uart_printf("\n=== Misaligned load/store test ===\n");
    set_trap_handler(&bounce_handler);
    fill();

    for (unsigned int b = 0; b < sizeof(g_bases) / sizeof(g_bases[0]); b++) {
        for (unsigned long d = 1; d < 8; d++) {
            unsigned long base = g_bases[b];
            /* Accesses ending one to seven bytes past base's boundary. */
            unsigned long offset = (base & 0x3f) == 0 || (base & 0xfff) == 0 ? base - d : base + d;
            check_loads(offset);
        }
    }
    for (unsigned int b = 0; b < sizeof(g_bases) / sizeof(g_bases[0]); b++) {
        for (unsigned long d = 1; d < 8; d++) {
            unsigned long base = g_bases[b];
            unsigned long offset = (base & 0x3f) == 0 || (base & 0xfff) == 0 ? base - d : base + d;
            uint64_t value = 0x0102030405060708ull * (d + 3u) ^ (uint64_t) offset << 17;
            check_store(offset, 2, 0, value);
            check_store(offset, 4, (int) (d & 1u), value >> 3);
            check_store(offset, 8, (int) (d & 2u) != 0, value ^ 0x5555AAAA5555AAAAull);
            check_loads(offset);
        }
    }

    /* A load to x0 writes nothing; a misaligned access retires as one
     * instruction (the same instret delta as an aligned one). */
    {
        uint64_t before, after, aligned_delta, misaligned_delta;
        volatile uint8_t *p = area + 0x101;
        volatile uint8_t *q = area + 0x100;
        __asm__ volatile("csrr %0, minstret\n ld x0, 0(%2)\n csrr %1, minstret"
                         : "=&r"(before), "=&r"(after)
                         : "r"(q)
                         : "memory");
        aligned_delta = after - before;
        __asm__ volatile("csrr %0, minstret\n ld x0, 0(%2)\n csrr %1, minstret"
                         : "=&r"(before), "=&r"(after)
                         : "r"(p)
                         : "memory");
        misaligned_delta = after - before;
        check(misaligned_delta == aligned_delta, "instret", 0x101, misaligned_delta, aligned_delta);
    }

    /* A store of x0 writes zeros. */
    {
        unsigned long offset = 0x123;
        __asm__ volatile("sd x0, 0(%0)" : : "r"(area + offset) : "memory");
        for (unsigned int k = 0; k < 8; k++)
            ref[offset + k] = 0;
        for (unsigned long i = offset - 8u; i < offset + 16u; i++)
            check(area[i] == ref[i], "x0 store byte", i, area[i], ref[i]);
    }

    /* Low BRAM keeps the exception: cause 4 or 6, mepc at the access, mtval
     * its address, and a store writes nothing. */
    {
        /* On the stack, which is in low BRAM in every memory layout. */
        volatile uint64_t bram_word[2] __attribute__((aligned(16)));
        volatile uint8_t *p = (volatile uint8_t *) bram_word + 3;
        bram_word[0] = 0x1111111111111111ull;
        bram_word[1] = 0x2222222222222222ull;
        g_cause = ~0ul;
        __asm__ volatile("la t0, 1f\n csrw mscratch, t0\n"
                         ".globl trig_bram_load\n trig_bram_load:\n lw t1, 0(%0)\n 1:\n"
                         :
                         : "r"(p)
                         : "t0", "t1", "memory");
        check(g_cause == 4u && g_epc == (unsigned long) trig_bram_load &&
                  g_tval == (unsigned long) p,
              "bram load trap",
              g_tval,
              g_cause,
              4u);
        g_cause = ~0ul;
        __asm__ volatile("la t0, 1f\n csrw mscratch, t0\n"
                         ".globl trig_bram_store\n trig_bram_store:\n sw zero, 0(%0)\n 1:\n"
                         :
                         : "r"(p)
                         : "t0", "memory");
        check(g_cause == 6u && g_epc == (unsigned long) trig_bram_store &&
                  g_tval == (unsigned long) p && bram_word[0] == 0x1111111111111111ull,
              "bram store trap",
              g_tval,
              g_cause,
              6u);
    }

    check_sv39();
    check_sv39_modes();
    check_under_interrupts();

    uart_printf("%d checks\n", g_checks);
    uart_printf(g_ok ? "<<PASS>>\n" : "<<FAIL>>\n");
    for (;;) {
    }
}
