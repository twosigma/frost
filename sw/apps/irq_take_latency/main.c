/*
 *    Copyright (c) 2026 John Goodacre.
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
 * S-mode interrupt take latency across the instruction mixes of a NAPI
 * receive path. Each trial enters S at a pattern loop that never exits on its
 * own; a delegated interrupt fires mid-loop and the S handler redirects sepc
 * to an exit stub. The handler's first instruction reads time, so:
 *
 *   STI   (Sstc stimecmp):         latency = time@handler - stimecmp
 *   LCOFI (Sscofpmf counter 9):    latency = hpmcounter9@handler (cycles
 *                                  since the counter wrapped to zero)
 *   SEI   (IMSIC S file, self MSI): latency = time@handler - time@MSI store
 *   NEST  STI nested inside the SEI handler after it re-enables SIE with
 *         csrs, as Linux runs softirqs on interrupt exit
 *

 * mtime advances once per core cycle in simulation (SIM_TIMER_SPEEDUP=1).
 * An M timer watchdog ends a trial whose interrupt is never taken.
 *
 * Patterns: alu, mmio_ld (device reads), mmio_st (device writes),
 * mmio_rw (readl/writel with their fences), amo (DDR amoadd.d),
 * lrsc (DDR lr.d/sc.d), fence (store, fence rw,rw, load), sie_pair
 * (csrc/csrs sstatus.SIE around a short body), chase (dependent DDR misses),
 * csr (sscratch/time/sip), st_stream (DDR store misses), mixed (all of the
 * above in one body), wfi (reference wake path), and the device-access
 * spacings that once starved every interrupt: device stores back to back
 * (mmio_st, st_gap2), a cached store before a device read (cst_mld), and
 * wider spacings and atomics for comparison.
 *
 * Every trial must be taken. LIMIT_CYCLES fails a pattern whose worst
 * latency exceeds it; the DDR-bound patterns (chase, st_stream, mixed) may
 * add DDR round trips (CHASE_LIMIT_CYCLES). LIMIT_CYCLES=0 reports only.
 */

#include <stdint.h>

#include "imsic.h"
#include "trap.h"

#ifndef TRIALS
#define TRIALS 4
#endif
#ifndef PAT_MASK
#define PAT_MASK 0xFFFFFFFFu
#endif
#ifndef SRC_MASK
#define SRC_MASK 15u
#endif
#ifndef LIMIT_CYCLES
#define LIMIT_CYCLES 200
#endif
#ifndef CHASE_LIMIT_CYCLES
#define CHASE_LIMIT_CYCLES 1000
#endif

#define CHASE_BASE 0x80400000ul
#define CHASE_STRIDE 0x10040ul
#define CHASE_NODES 256
#define AMO_ADDR 0x80200000ul
#define MSI_ID 3
#define WATCHDOG_CYCLES 200000ul

#define SRC_STI 0
#define SRC_LCOF 1
#define SRC_SEI 2
#define SRC_NEST 3 /* STI nested in an SEI handler after csrs SIE */

static void uart_putc(char c)
{
    UART_TX = (uint8_t) c;
}
static void uart_puts(const char *s)
{
    while (*s)
        uart_putc(*s++);
}
static void uart_dec(unsigned long v)
{
    char b[24];
    int i = 0;
    do {
        b[i++] = (char) ('0' + v % 10);
        v /= 10;
    } while (v);
    while (i)
        uart_putc(b[--i]);
}

#define csr_read_num(num)                                                                          \
    ({                                                                                             \
        unsigned long v_;                                                                          \
        __asm__ volatile("csrr %0, " #num : "=r"(v_));                                             \
        v_;                                                                                        \
    })
#define csr_write_num(num, val)                                                                    \
    do {                                                                                           \
        unsigned long v_ = (val);                                                                  \
        __asm__ volatile("csrw " #num ", %0" : : "r"(v_));                                         \
    } while (0)

/* {pattern fn, stimecmp delay, MSI id, nest flag} read by run_in_s. */
volatile unsigned long g_args[4];
/* S exit stub results: {time@handler, hpm9@handler, scause, stimecmp, MSI time}. */
volatile unsigned long g_res[5];
volatile unsigned long g_m_cause;
volatile unsigned long g_timeout;

/* ---- S side ---- */
/*
 * With the nest flag (a6) set, the first trap is the self-MSI's SEI: the
 * handler claims it, arms stimecmp, re-enables SIE with csrs (as Linux does
 * before running softirqs on interrupt exit) and runs the pattern loop in
 * handler context, so the measured STI nests inside the SEI handler.
 */
__attribute__((naked, aligned(4))) void s_handler(void)
{
    __asm__ volatile("csrr t5, time\n"
                     "csrr t3, 0xC09\n"
                     "csrr t4, scause\n"
                     "beqz a6, 3f\n"
                     "li   a6, 0\n"
                     "csrrw zero, 0x15C, zero\n"
                     "csrr t0, time\n"
                     "add  t0, t0, a1\n"
                     "csrw 0x14D, t0\n"
                     "li   t0, 2\n"
                     "csrs sstatus, t0\n"
                     "jr   a0\n"
                     "3:\n"
                     "csrr t6, 0x14D\n"
                     "li   a0, -1\n"
                     "csrw 0x14D, a0\n"
                     "li   a0, 0x2000\n"
                     "csrc sip, a0\n"
                     "csrrw a0, 0x15C, zero\n"
                     "la   a0, s_exit\n"
                     "csrw sepc, a0\n"
                     "sret\n"
                     ".globl s_exit\n"
                     "s_exit:\n"
                     "la   a0, g_res\n"
                     "sd   t5, 0(a0)\n"
                     "sd   t3, 8(a0)\n"
                     "sd   t4, 16(a0)\n"
                     "sd   t6, 24(a0)\n"
                     "sd   s11, 32(a0)\n"
                     "ecall\n"
                     "j .\n");
}

/* Entry stubs: a0 = pattern loop, a1 = delay, a7 = MSI id. */
__attribute__((naked, aligned(4))) void s_entry_sti(void)
{
    __asm__ volatile("csrr t0, time\n add t0, t0, a1\n csrw 0x14D, t0\n jr a0\n");
}
__attribute__((naked, aligned(4))) void s_entry_lcof(void)
{
    __asm__ volatile("jr a0\n");
}
__attribute__((naked, aligned(4))) void s_entry_sei(void)
{
    __asm__ volatile("csrr s11, time\n sw a7, 0(s10)\n jr a0\n");
}

/* Pattern loops. a2 = MMIO base, a3 = chase pointer, a4 = AMO word, a5 = 1. */
__attribute__((naked, aligned(64))) void p_alu(void)
{
    __asm__ volatile("1: addi t0, t0, 1\n xor t1, t1, t0\n add t2, t2, t1\n"
                     "addi t0, t0, 3\n xor t1, t1, t2\n add t2, t2, t0\n j 1b\n");
}
__attribute__((naked, aligned(64))) void p_mmio_ld(void)
{
    __asm__ volatile("1: lw t0, 0x10(a2)\n lw t1, 0x14(a2)\n add t2, t0, t1\n j 1b\n");
}
__attribute__((naked, aligned(64))) void p_mmio_st(void)
{
    __asm__ volatile("1: sw zero, 0x20(a2)\n sw zero, 0x20(a2)\n addi t0, t0, 1\n j 1b\n");
}
__attribute__((naked, aligned(64))) void p_mmio_rw(void)
{
    /* readl = lw; fence i,r. writel = fence w,o; sw. */
    __asm__ volatile("1: lw t0, 0x10(a2)\n fence i, r\n addi t1, t0, 1\n"
                     "fence w, o\n sw zero, 0x20(a2)\n j 1b\n");
}
__attribute__((naked, aligned(64))) void p_amo(void)
{
    __asm__ volatile("1: amoadd.d t0, a5, (a4)\n addi t1, t0, 1\n j 1b\n");
}
__attribute__((naked, aligned(64))) void p_lrsc(void)
{
    __asm__ volatile("1: lr.d t0, (a4)\n addi t0, t0, 1\n sc.d t1, t0, (a4)\n"
                     "bnez t1, 1b\n j 1b\n");
}
__attribute__((naked, aligned(64))) void p_fence(void)
{
    __asm__ volatile("1: sd t0, 8(a4)\n fence rw, rw\n ld t1, 16(a4)\n addi t0, t0, 1\n j 1b\n");
}
__attribute__((naked, aligned(64))) void p_sie_pair(void)
{
    __asm__ volatile("li t2, 2\n"
                     "1: csrc sstatus, t2\n addi t0, t0, 1\n addi t1, t1, 1\n"
                     "csrs sstatus, t2\n addi t0, t0, 1\n j 1b\n");
}
__attribute__((naked, aligned(64))) void p_chase(void)
{
    __asm__ volatile("1: ld a3, 0(a3)\n j 1b\n");
}
__attribute__((naked, aligned(64))) void p_csr(void)
{
    __asm__ volatile("1: csrr t0, sscratch\n addi t0, t0, 1\n csrw sscratch, t0\n"
                     "csrr t1, time\n csrr t2, sip\n j 1b\n");
}
__attribute__((naked, aligned(64))) void p_st_stream(void)
{
    __asm__ volatile(
        "li t1, 0xFFFC0\n li s2, 0\n li s3, 0x80800000\n"
        "1: add t0, s3, s2\n sd a5, 0(t0)\n addi s2, s2, 64\n and s2, s2, t1\n j 1b\n");
}
__attribute__((naked, aligned(64))) void p_mixed(void)
{
    __asm__ volatile("li t2, 2\n"
                     "1: lw t0, 0x10(a2)\n fence i, r\n"
                     "ld a3, 0(a3)\n"
                     "amoadd.d t1, a5, (a4)\n"
                     "2: lr.d s2, (a4)\n addi s2, s2, 1\n sc.d s2, s2, (a4)\n bnez s2, 2b\n"
                     "csrc sstatus, t2\n addi s3, s3, 1\n csrs sstatus, t2\n"
                     "fence w, o\n sw zero, 0x20(a2)\n fence rw, rw\n"
                     "csrr t0, sscratch\n csrw sscratch, t0\n"
                     "j 1b\n");
}
/* Device stores separated by N independent ALU instructions. */
#define P_MMIO_ST_GAP(n)                                                                           \
    __attribute__((naked, aligned(64))) void p_mmio_st_gap##n(void)                                \
    {                                                                                              \
        __asm__ volatile("1: sw zero, 0x20(a2)\n .rept " #n "\n addi t0, t0, 1\n .endr\n j 1b\n"); \
    }
__attribute__((naked, aligned(64))) void p_cst_mld(void)
{
    /* Cached store, then a device read. */
    __asm__ volatile("1: sd t0, 8(a4)\n lw t1, 0x10(a2)\n addi t0, t0, 1\n j 1b\n");
}
__attribute__((naked, aligned(64))) void p_cst_writel(void)
{
    /* Cached store, then writel (fence w,o; sw), as when a driver publishes a descriptor. */
    __asm__ volatile("1: sd t0, 8(a4)\n fence w, o\n sw zero, 0x20(a2)\n addi t0, t0, 1\n j 1b\n");
}
__attribute__((naked, aligned(64))) void p_cst_amo(void)
{
    /* Cached store, then an AMO (atomic_inc after a field update). */
    __asm__ volatile("1: sd t0, 64(a4)\n amoadd.d t1, a5, (a4)\n addi t0, t0, 1\n j 1b\n");
}
__attribute__((naked, aligned(64))) void p_cst_lrsc(void)
{
    /* Cached store, then an LR/SC increment (cmpxchg after a field update). */
    __asm__ volatile("1: sd t0, 64(a4)\n"
                     "2: lr.d t1, (a4)\n addi t1, t1, 1\n sc.d t2, t1, (a4)\n bnez t2, 2b\n"
                     "addi t0, t0, 1\n j 1b\n");
}
__attribute__((naked, aligned(64))) void p_cst_amo_gap(void)
{
    /* Kernel-like: two stores, a load, an AMO and eight ALU instructions. */
    __asm__ volatile("1: sd t0, 64(a4)\n sd t0, 72(a4)\n ld t1, 80(a4)\n amoadd.d t1, a5, (a4)\n"
                     ".rept 8\n addi t0, t0, 1\n .endr\n j 1b\n");
}
P_MMIO_ST_GAP(2)
P_MMIO_ST_GAP(8)
P_MMIO_ST_GAP(32)
P_MMIO_ST_GAP(128)
__attribute__((naked, aligned(64))) void p_mmio_st_ld(void)
{
    /* writel immediately followed by readl, as in IRQ unmask + posted-write flush. */
    __asm__ volatile("1: sw zero, 0x20(a2)\n lw t0, 0x10(a2)\n addi t1, t1, 1\n"
                     "addi t2, t2, 1\n addi t0, t0, 1\n addi t1, t1, 1\n j 1b\n");
}
__attribute__((naked, aligned(64))) void p_wfi(void)
{
    __asm__ volatile("1: wfi\n j 1b\n");
}

/* ---- M side ---- */
__attribute__((naked, aligned(4))) static void m_trap_handler(void)
{
    __asm__ volatile("csrr t0, mcause\n"
                     "la   t1, g_m_cause\n"
                     "sd   t0, 0(t1)\n"
                     "bgez t0, 2f\n"
                     /* M timer watchdog: silence it and flag the timeout. */
                     "li   t1, -1\n"
                     "li   t2, 0x4000001C\n"
                     "sw   t1, 0(t2)\n"
                     "la   t1, g_timeout\n"
                     "li   t2, 1\n"
                     "sd   t2, 0(t1)\n"
                     "2:\n"
                     "csrr t0, mscratch\n"
                     "csrw mepc, t0\n"
                     "li   t0, 0x1800\n"
                     "csrs mstatus, t0\n"
                     "mret\n");
}

static void run_in_s(void (*entry)(void))
{
    __asm__ volatile("la   t0, 1f\n"
                     "csrw mscratch, t0\n"
                     "li   t0, 0x1800\n"
                     "csrc mstatus, t0\n"
                     "li   t0, 0x0800\n"
                     "csrs mstatus, t0\n"
                     "la   t0, g_args\n"
                     "ld   a0, 0(t0)\n"
                     "ld   a1, 8(t0)\n"
                     "ld   a7, 16(t0)\n"
                     "ld   a6, 24(t0)\n"
                     "li   a2, 0x40000000\n"
                     "li   a3, %1\n"
                     "li   a4, %2\n"
                     "li   a5, 1\n"
                     "li   s10, %3\n"
                     "li   s11, 0\n"
                     "csrw mepc, %0\n"
                     "mret\n"
                     "1:\n"
                     :
                     : "r"(entry), "i"(CHASE_BASE), "i"(AMO_ADDR), "i"(IMSIC_S_BASE)
                     : "ra",
                       "t0",
                       "t1",
                       "t2",
                       "t3",
                       "t4",
                       "t5",
                       "t6",
                       "a0",
                       "a1",
                       "a2",
                       "a3",
                       "a4",
                       "a5",
                       "a6",
                       "a7",
                       "s2",
                       "s3",
                       "s10",
                       "s11",
                       "memory");
}

static void set_mtimecmp(uint64_t v)
{
    MTIMECMP_HI = 0xFFFFFFFFu;
    MTIMECMP_LO = (uint32_t) v;
    MTIMECMP_HI = (uint32_t) (v >> 32);
}

struct pattern {
    const char *name;
    void (*fn)(void);
    int memory_bound;
};

static const struct pattern patterns[] = {
    {"alu", p_alu, 0},
    {"mmio_ld", p_mmio_ld, 0},
    {"mmio_st", p_mmio_st, 0},
    {"mmio_rw", p_mmio_rw, 0},
    {"amo", p_amo, 0},
    {"lrsc", p_lrsc, 0},
    {"fence", p_fence, 0},
    {"sie_pair", p_sie_pair, 0},
    {"chase", p_chase, 1},
    {"csr", p_csr, 0},
    {"st_stream", p_st_stream, 1},
    {"mixed", p_mixed, 1},
    {"wfi", p_wfi, 0},
    {"mmio_st_ld", p_mmio_st_ld, 0},
    {"st_gap2", p_mmio_st_gap2, 0},
    {"st_gap8", p_mmio_st_gap8, 0},
    {"st_gap32", p_mmio_st_gap32, 0},
    {"st_gap128", p_mmio_st_gap128, 0},
    {"cst_mld", p_cst_mld, 0},
    {"cst_writel", p_cst_writel, 0},
    {"cst_amo", p_cst_amo, 0},
    {"cst_lrsc", p_cst_lrsc, 0},
    {"cst_amo_gap", p_cst_amo_gap, 0},
};
#define NPAT ((int) (sizeof(patterns) / sizeof(patterns[0])))

static const char *const src_names[] = {"STI", "LCOFI", "SEI", "NEST"};
static const unsigned long src_cause[] = {0x8000000000000000ul | 5,
                                          0x8000000000000000ul | 13,
                                          0x8000000000000000ul | 9,
                                          0x8000000000000000ul | 5};

int main(void)
{
    int ok = 1;

    uart_puts("\r\n=== S-mode interrupt take latency ===\r\n");
    set_trap_handler(&m_trap_handler);

    /* Dependent chase through 16 MiB of DDR (more than the L2), one node per
     * 64 KiB + 64 B so consecutive nodes use different sets. */
    for (int i = 0; i < CHASE_NODES; i++) {
        volatile uint64_t *node =
            (volatile uint64_t *) (CHASE_BASE + (unsigned long) i * CHASE_STRIDE);
        *node = CHASE_BASE + (unsigned long) ((i + 1) % CHASE_NODES) * CHASE_STRIDE;
    }
    *(volatile uint64_t *) AMO_ADDR = 0;

    csr_write_num(0x30A, 1ul << 63); /* menvcfg.STCE */
    csr_write_num(0x306, 0x7FF);     /* mcounteren: CY, TM, IR, HPM3..10 */
    csr_write_num(0x14D, ~0ul);
    csr_write(mideleg, (1ul << 5) | (1ul << 9) | (1ul << 13));
    csr_write(stvec, (unsigned long) &s_handler);
    imsic_write(1, IMSIC_EIDELIVERY, 1);
    imsic_write(1, IMSIC_EITHRESHOLD, 0);
    imsic_write(1, IMSIC_EIE0, 1ul << MSI_ID);
    csr_set(mie, (1ul << 5) | (1ul << 7) | (1ul << 9) | (1ul << 13));

    uart_puts("pattern src min max mean bad\r\n");
    for (int p = 0; p < NPAT; p++) {
        if (!((PAT_MASK >> p) & 1u))
            continue;
        for (int s = 0; s < 4; s++) {
            if (!((SRC_MASK >> s) & 1u))
                continue;
            unsigned long mn = ~0ul, mx = 0, sum = 0, bad = 0;
            for (int k = 0; k < TRIALS; k++) {
                unsigned long delay = 300ul + 37ul * (unsigned long) k;
                g_args[0] = (unsigned long) patterns[p].fn;
                g_args[1] = delay;
                g_args[2] = MSI_ID;
                g_args[3] = s == SRC_NEST;
                g_res[0] = g_res[1] = g_res[2] = g_res[3] = g_res[4] = 0;
                g_timeout = 0;
                g_m_cause = 0;
                if (s == SRC_LCOF) {
                    csr_write_num(0x329, 9); /* count cycles, OF clear */
                    csr_write_num(0xB09, 0ul - delay);
                } else {
                    csr_write_num(0x329, 0);
                }
                csr_set(mstatus, 1ul << 1); /* sstatus.SIE */
                set_mtimecmp(rdmtime() + WATCHDOG_CYCLES);
                run_in_s(s == SRC_STI ? s_entry_sti : s == SRC_LCOF ? s_entry_lcof : s_entry_sei);
                set_mtimecmp(~0ull);
                csr_write_num(0x329, 0);
                csr_write_num(0x14D, ~0ul);
                (void) imsic_claim(1);

                unsigned long lat;
                if (s == SRC_STI || s == SRC_NEST)
                    lat = g_res[0] - g_res[3];
                else if (s == SRC_LCOF)
                    lat = g_res[1];
                else
                    lat = g_res[0] - g_res[4];
                if (g_timeout || g_m_cause != 9 || g_res[2] != src_cause[s]) {
                    bad++;
                    uart_puts("  bad trial ");
                    uart_puts(patterns[p].name);
                    uart_putc(' ');
                    uart_puts(src_names[s]);
                    uart_puts(" k=");
                    uart_dec((unsigned long) k);
                    uart_puts(" timeout=");
                    uart_dec(g_timeout);
                    uart_puts(" mcause=");
                    uart_dec(g_m_cause);
                    uart_puts(" scause_lo=");
                    uart_dec(g_res[2] & 0xFF);
                    uart_puts("\r\n");
                    continue;
                }
                if (lat < mn)
                    mn = lat;
                if (lat > mx)
                    mx = lat;
                sum += lat;
            }
            unsigned long good = TRIALS - bad;
            uart_puts("LAT ");
            uart_puts(patterns[p].name);
            uart_putc(' ');
            uart_puts(src_names[s]);
            uart_putc(' ');
            uart_dec(good ? mn : 0);
            uart_putc(' ');
            uart_dec(mx);
            uart_putc(' ');
            uart_dec(good ? sum / good : 0);
            uart_putc(' ');
            uart_dec(bad);
            uart_puts("\r\n");
            if (bad)
                ok = 0;
            unsigned long limit = patterns[p].memory_bound ? CHASE_LIMIT_CYCLES : LIMIT_CYCLES;
            if (LIMIT_CYCLES && mx > limit) {
                uart_puts("  over limit ");
                uart_dec(limit);
                uart_puts("\r\n");
                ok = 0;
            }
        }
    }

    uart_puts(ok ? "\r\n<<PASS>>\r\n" : "\r\n<<FAIL>>\r\n");
    for (;;) {
    }
    return 0;
}
