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
 * Misaligned loads and stores in M-mode.
 *
 * In cached DDR every size and offset is performed: each load is checked
 * against a byte-by-byte reference (sign and zero extension, NaN boxing for
 * FLW), each store against the bytes it must change and the neighbours it
 * must keep, across a doubleword, a 32-byte sector, a 64-byte line and a 4 KiB
 * page, and with compressed and FP forms. A misaligned load to x0 writes
 * nothing, a store of x0 writes zeros, and an access retires as exactly one
 * instruction. In low BRAM a misaligned access still raises the
 * address-misaligned exception with the access's address as the trap value.
 * Under Sv39 (S-mode data accesses through MPRV), accesses cross into
 * read-only, unmapped and user pages, with the trap value and the unchanged
 * memory of a faulting store checked. Last, misaligned accesses run while
 * timer interrupts arrive at varying phases.
 */

#include <stdint.h>

#include "csr.h"
#include "trap.h"
#include "uart.h"

#define DDR_AREA 0x83000000ul /* three pages inside the simulation DDR model */
#define AREA_BYTES (3u * 4096u)

static volatile uint8_t *const area = (volatile uint8_t *) DDR_AREA;
static volatile uint64_t g_bram_word[2] __attribute__((aligned(16)));

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

/* M-mode bounce handler: record the trap and resume at mscratch. */
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
                     "mret\n");
}

extern char trig_bram_load[], trig_bram_store[];

/* Sv39 through an MPRV window: M-mode code, data accesses translated at S.
 * VA 0x40_0000 + n * 4 KiB maps frame n of FRAMES with these leaves: */
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
        volatile uint8_t *p = (volatile uint8_t *) g_bram_word + 3;
        g_bram_word[0] = 0x1111111111111111ull;
        g_bram_word[1] = 0x2222222222222222ull;
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
                  g_tval == (unsigned long) p && g_bram_word[0] == 0x1111111111111111ull,
              "bram store trap",
              g_tval,
              g_cause,
              6u);
    }

    check_sv39();
    check_under_interrupts();

    uart_printf("%d checks\n", g_checks);
    uart_printf(g_ok ? "<<PASS>>\n" : "<<FAIL>>\n");
    for (;;) {
    }
}
