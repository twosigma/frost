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
 * Shared helpers for the vector bring-up programs.
 *
 * Every program is vector-length agnostic: it reads vlenb at run time and
 * checks its results against a scalar model computed in the same program.
 * The programs print <<PASS>> or <<FAIL>> as the other self-checking apps do.
 * Output goes to the UART, or to the Spike HTIF console when built with
 * -DVT_SPIKE (the reference run that proves a program correct before RTL
 * exists).
 *
 * The programs pin choices that the specification leaves to the implementation, because
 * they judge a particular design, and Spike and Sail make the same choices:
 *  - vsetvli returns VLMAX when VLMAX < AVL < 2 * VLMAX (the specification allows less);
 *  - every vtype whose SEW exceeds LMUL * ELEN, or that sets a reserved bit, sets vill
 *    (the specification lets an implementation support more, or trap instead);
 *  - a fault-only-first load that faults at element k > 0 returns vl = k exactly, where
 *    the specification lets it return fewer;
 *  - access faults write the faulting element's address to mtval;
 *  - mstatus.VS = Initial reads back as Initial until a vector instruction changes state.
 * A core that makes another legal choice fails these checks; change the check, not the core,
 * if the design decision changes.
 *
 * Fault-only-first and precise-fault cases need a mapped page followed by an
 * unmapped one: vt_fault_page() returns the last 4 KiB page below the first
 * unmapped address. On Spike that is the end of the 4 MiB RAM region; on FROST it
 * is the top of the configured DDR capacity.
 */

#ifndef VEC_TEST_H
#define VEC_TEST_H

#include <stddef.h>
#include <stdint.h>

#ifdef VT_SPIKE

extern volatile uint64_t tohost;
extern volatile uint64_t fromhost;
extern char __vt_ram_end[];

static inline void vt_putc(char c)
{
    /* HTIF console: device 1 (bcd), command 1 (putchar). The host zeroes
     * tohost when it takes the command and does not acknowledge a putchar. */
    while (tohost != 0) {
    }
    tohost = (1ull << 56) | (1ull << 48) | (uint8_t) c;
}

static inline uintptr_t vt_ff_end(void)
{
    uintptr_t v = (uintptr_t) __vt_ram_end;
    __asm__("" : "+r"(v)); /* hide the object so later arithmetic is not range-checked */
    return v;
}
#define VT_FF_END vt_ff_end()

#else /* FROST */

#include "uart.h"

#ifndef FROST_DDR_CAPACITY_LOG2_BYTES
#define FROST_DDR_CAPACITY_LOG2_BYTES 30
#endif
#define VT_FF_END (0x80000000ul + (1ul << FROST_DDR_CAPACITY_LOG2_BYTES))

static inline void vt_putc(char c)
{
    uart_putchar(c);
}

#endif

#ifdef VT_SPIKE
/* The Spike build links no C library; GCC may still call these. */
#define VT_LIBC_ATTR __attribute__((used, noinline, optimize("no-tree-loop-distribute-patterns")))
VT_LIBC_ATTR void *memset(void *d, int c, size_t n)
{
    unsigned char *p = d;
    while (n--)
        *p++ = (unsigned char) c;
    return d;
}
VT_LIBC_ATTR void *memcpy(void *d, const void *s, size_t n)
{
    unsigned char *p = d;
    const unsigned char *q = s;
    while (n--)
        *p++ = *q++;
    return d;
}
VT_LIBC_ATTR int memcmp(const void *a, const void *b, size_t n)
{
    const unsigned char *p = a, *q = b;
    for (; n; n--, p++, q++)
        if (*p != *q)
            return *p < *q ? -1 : 1;
    return 0;
}
#else
#include "string.h"
#endif

static inline void vt_puts(const char *s)
{
    while (*s)
        vt_putc(*s++);
}

static inline void vt_hex(uint64_t v)
{
    static const char digits[] = "0123456789abcdef";
    vt_puts("0x");
    for (int i = 60; i >= 0; i -= 4)
        vt_putc(digits[(v >> i) & 15]);
}

static inline void vt_dec(uint64_t v)
{
    char buf[24];
    int n = 0;
    do {
        buf[n++] = (char) ('0' + v % 10);
        v /= 10;
    } while (v);
    while (n)
        vt_putc(buf[--n]);
}

static unsigned vt_failures;
static unsigned vt_checks;

#define VT_FAIL_LIMIT 40

static inline void vt_fail_head(const char *what, int line)
{
    vt_failures++;
    if (vt_failures <= VT_FAIL_LIMIT) {
        vt_puts("FAIL ");
        vt_puts(what);
        vt_puts(" line ");
        vt_dec((uint64_t) line);
    }
}

static inline void vt_eq(uint64_t got, uint64_t want, const char *what, int line)
{
    vt_checks++;
    if (got != want) {
        vt_fail_head(what, line);
        if (vt_failures <= VT_FAIL_LIMIT) {
            vt_puts(" got ");
            vt_hex(got);
            vt_puts(" want ");
            vt_hex(want);
            vt_puts("\r\n");
        }
    }
}

#define VT_EQ(got, want, what) vt_eq((uint64_t) (got), (uint64_t) (want), what, __LINE__)
#define VT_TRUE(cond, what) vt_eq((cond) ? 1 : 0, 1, what, __LINE__)

/* Print the summary and end the run. Returns the process exit code. */
static inline int vt_finish(const char *name)
{
    vt_puts(name);
    vt_puts(": ");
    vt_dec(vt_checks);
    vt_puts(" checks, ");
    vt_dec(vt_failures);
    vt_puts(" failures\r\n");
    vt_puts(vt_failures ? "<<FAIL>>\r\n" : "<<PASS>>\r\n");
    return vt_failures ? 1 : 0;
}

/* ------------------------------------------------------------------------ */
/* CSR and vector state                                                      */
/* ------------------------------------------------------------------------ */

#define VT_CSR_READ(name)                                                                          \
    ({                                                                                             \
        unsigned long v_;                                                                          \
        __asm__ volatile("csrr %0, " #name : "=r"(v_));                                            \
        v_;                                                                                        \
    })
#define VT_CSR_WRITE(name, val)                                                                    \
    do {                                                                                           \
        unsigned long v_ = (val);                                                                  \
        __asm__ volatile("csrw " #name ", %0" : : "r"(v_) : "memory");                             \
    } while (0)

#define VT_MSTATUS_VS (3ul << 9)
#define VT_MSTATUS_FS (3ul << 13)

/* Turn on the vector and floating-point units (mstatus.VS and FS = Dirty). */
static inline void vt_enable_vector(void)
{
    unsigned long bits = VT_MSTATUS_VS | VT_MSTATUS_FS;
    __asm__ volatile("csrs mstatus, %0" : : "r"(bits));
}

static inline unsigned long vt_vlenb(void)
{
    return VT_CSR_READ(vlenb);
}

/* vtype encodings. */
#define VT_E8 0x0
#define VT_E16 0x1
#define VT_E32 0x2
#define VT_E64 0x3
#define VT_M1 0x0
#define VT_M2 0x1
#define VT_M4 0x2
#define VT_M8 0x3
#define VT_MF8 0x5
#define VT_MF4 0x6
#define VT_MF2 0x7
#define VT_TA (1u << 6)
#define VT_MA (1u << 7)

#define VT_VTYPE(sew, lmul, flags) ((unsigned long) (((sew) << 3) | (lmul) | (flags)))

/* Small deterministic generator for test data. */
static inline uint64_t vt_rand(uint64_t *state)
{
    uint64_t x = *state;
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    *state = x;
    return x * 0x2545F4914F6CDD1Dull;
}

/* ------------------------------------------------------------------------ */
/* Trap capture: records the first trap's cause, tval, epc and vstart, clears */
/* vstart, and resumes after the trapping instruction.                        */
/* ------------------------------------------------------------------------ */

__attribute__((used)) volatile unsigned long vt_trap_count;
__attribute__((used)) volatile unsigned long vt_trap_cause;
__attribute__((used)) volatile unsigned long vt_trap_tval;
__attribute__((used)) volatile unsigned long vt_trap_epc;
__attribute__((used)) volatile unsigned long vt_trap_vstart;
__attribute__((used)) static uint64_t vt_trap_save[3];

/* mscratch holds the address of vt_trap_save; t6 and mscratch swap on entry. */
__asm__(".pushsection .text.vt_trap,\"ax\"\n"
        ".balign 4\n"
        ".globl vt_trap_entry\n"
        "vt_trap_entry:\n"
        "  csrrw  t6, mscratch, t6\n"
        "  sd     t0, 0(t6)\n"
        "  sd     t1, 8(t6)\n"
        "  sd     t2, 16(t6)\n"
        "  csrr   t0, mcause\n"
        "  la     t1, vt_trap_cause\n"
        "  sd     t0, 0(t1)\n"
        "  csrr   t0, mtval\n"
        "  la     t1, vt_trap_tval\n"
        "  sd     t0, 0(t1)\n"
        "  csrr   t0, mepc\n"
        "  la     t1, vt_trap_epc\n"
        "  sd     t0, 0(t1)\n"
        "  csrr   t2, mstatus\n" /* vstart is inaccessible with VS off */
        "  srli   t2, t2, 9\n"
        "  andi   t2, t2, 3\n"
        "  li     t1, -1\n"
        "  beqz   t2, 2f\n"
        "  csrr   t1, vstart\n"
        "  csrw   vstart, zero\n"
        "2:\n"
        "  la     t2, vt_trap_vstart\n"
        "  sd     t1, 0(t2)\n"
        "  la     t1, vt_trap_count\n"
        "  ld     t2, 0(t1)\n"
        "  addi   t2, t2, 1\n"
        "  sd     t2, 0(t1)\n"
        "  lhu    t2, 0(t0)\n" /* skip the trapping instruction */
        "  andi   t2, t2, 3\n"
        "  addi   t2, t2, -3\n"
        "  li     t1, 4\n"
        "  beqz   t2, 1f\n"
        "  li     t1, 2\n"
        "1:\n"
        "  add    t0, t0, t1\n"
        "  csrw   mepc, t0\n"
        "  ld     t0, 0(t6)\n"
        "  ld     t1, 8(t6)\n"
        "  ld     t2, 16(t6)\n"
        "  csrrw  t6, mscratch, t6\n"
        "  mret\n"
        ".popsection\n");

extern char vt_trap_entry[];

static inline void vt_trap_install(void)
{
    __asm__ volatile("csrw mscratch, %0" : : "r"(vt_trap_save));
    __asm__ volatile("csrw mtvec, %0" : : "r"(vt_trap_entry));
    vt_trap_count = 0;
}

static inline void vt_trap_clear(void)
{
    vt_trap_count = 0;
    vt_trap_cause = 0;
    vt_trap_tval = 0;
    vt_trap_epc = 0;
    vt_trap_vstart = 0;
}

/* The last 4 KiB page that is mapped; the page after it is not. */
static inline uint8_t *vt_fault_page(void)
{
    return (uint8_t *) (VT_FF_END - 4096);
}

#endif /* VEC_TEST_H */
