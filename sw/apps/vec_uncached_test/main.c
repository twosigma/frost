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
 * Directed test for vector loads and stores reaching uncached regions (low
 * BRAM, MMIO devices with read side effects, and Svpbmt NC/IO pages) across
 * VLEN 128, 256 and 512:
 *   1. Low BRAM (static BSS and stack buffers in [0, 0x40000)): unit-stride
 *      (EEW 8/16/32/64, masked/unmasked, vstart > 0), whole-register
 *      (vl1/2re8/16/32/64, vs1/2r, including under vill=1), mask (vlm/vsm),
 *      strided (positive, negative, zero), indexed (unordered and ordered,
 *      index EEW 8/16/32/64), segments (unit-stride, strided, indexed, nf=2/4),
 *      and fault-only-first (unit-stride and segment, including boundary trim
 *      at 0x40000).
 *   2. Low-BRAM L0 cache coherence (scalar load warms L0 -> vector store ->
 *      scalar load sees updated value) and LR/SC reservation invalidation.
 *   3. Side-effecting devices (FIFO0 at 0x40000008, FIFO1 at 0x4000000C,
 *      MTIME at 0x40000010): exact element order and zero duplicate reads/pops
 *      across unit-stride, whole-register, strided (stride 0, +4, -4, masked),
 *      indexed (ordered and unordered, alternating FIFO0/FIFO1 and mixed
 *      DDR+BRAM+FIFO0+FIFO1), segment (nf=2 on FIFO0/FIFO1), and fault-only-
 *      first forms.
 *   4. Program order with scalar MMIO (interleaved scalar and vector FIFO0/1
 *      pushes and pops) and wrong-path non-speculation (mispredicted branch
 *      over a FIFO0 vector load must not pop FIFO0).
 *   5. Faults matching scalar rules: alignment faults (cause 4/6) on low BRAM
 *      and MMIO, unmapped PMA access faults (cause 5/7) with exact vstart and
 *      mtval, Sv39 permissions and Svpbmt NC/IO (over DDR alias, low BRAM, and
 *      MMIO), and mixed cached-DDR + uncached-BRAM page crossings.
 *   6. Mid-run M-mode timer interrupt (MTI + mret) during uncached unit-stride
 *      low-BRAM, stride-0 FIFO0, and segment FIFO0/FIFO1 vector runs: verifies
 *      0 < vstart < vl, mepc == insn_pc, VS Dirty, exact element order, and
 *      zero duplicate or lost FIFO pops across interrupt and resume.
 */

#include <stdint.h>

#include "csr.h"
#include "mmio.h"
#include "trap.h"
#include "uart.h"

#define FIFO0_PA 0x40000008ul
#define FIFO1_PA 0x4000000Cul
#define MTIME_PA 0x40000010ul
#define LOW_BRAM_LIMIT 0x00040000ul
#define UNMAPPED_DEV_PA 0x40040000ul
#define BRAM_PAGE_PA 0x00028000ul
#define BRAM_SRC_PA 0x00029000ul
#define BRAM_DST_PA 0x00029400ul
#define BRAM_IDX_PA 0x00029800ul
#define BRAM_BUF_LEN 512u

#define DDR_SCRATCH 0x83200000ul
#define DDR_VRF 0x83204000ul
#define PT_ROOT 0x83210000ul
#define PT_L1 0x83211000ul
#define PT_L0 0x83212000ul
#define DDR_FRAMES 0x83220000ul
#define VA_BASE 0x00400000ul

#define PTE_V (1ul << 0)
#define PTE_R (1ul << 1)
#define PTE_W (1ul << 2)
#define PTE_U (1ul << 4)
#define PTE_A (1ul << 6)
#define PTE_D (1ul << 7)
#define PTE_PBMT_NC (1ul << 61)
#define PTE_PBMT_IO (2ul << 61)
#define PTE_PPN(pa) ((((unsigned long) (pa)) >> 12) << 10)
#define SATP_SV39 (8ul << 60)

#define MSTATUS_MIE (1ul << 3)
#define MSTATUS_VS (3ul << 9)
#define VS_INITIAL (1ul << 9)
#define VS_CLEAN (2ul << 9)
#define VS_DIRTY (3ul << 9)
#define MIE_MTIE (1ul << 7)
#define MENVCFG_PBMTE (1ul << 62)

#define CAUSE_LOAD_MISALIGN 4ul
#define CAUSE_LOAD_ACCESS 5ul
#define CAUSE_STORE_MISALIGN 6ul
#define CAUSE_STORE_ACCESS 7ul
#define CAUSE_LOAD_PAGE 13ul
#define CAUSE_STORE_PAGE 15ul
#define CAUSE_MTI (MCAUSE_INTERRUPT_BIT | 7ul)

#define VT_E8 0u
#define VT_E16 1u
#define VT_E32 2u
#define VT_E64 3u
#define VT_M1 0u
#define VT_M2 1u
#define VT_M4 2u
#define VT_M8 3u
#define VT_MF2 7u
#define VT_VTYPE(sew, lmul) ((unsigned long) (((sew) << 3) | (lmul)))

/* Fixed low-BRAM scratch buffers in [0x28000, 0x29BFF), valid in both BRAM and DDR layouts. */
static volatile uint8_t *const bram_src = (volatile uint8_t *) BRAM_SRC_PA;
static volatile uint8_t *const bram_dst = (volatile uint8_t *) BRAM_DST_PA;
static volatile uint8_t *const bram_idx = (volatile uint8_t *) BRAM_IDX_PA;
static volatile uint8_t *const ddr_scratch = (volatile uint8_t *) DDR_SCRATCH;
static volatile uint8_t *const vrf_io = (volatile uint8_t *) DDR_VRF;

/* Dynamic code trampoline in cached DDR for mid-run interrupt PC checks. */
__attribute__((section(".ddr_data"), aligned(64))) static volatile uint32_t g_tramp[8];

static int g_ok = 1;
static int g_checks;
static unsigned long g_vlenb;

static volatile unsigned long g_cause;
static volatile unsigned long g_epc;
static volatile unsigned long g_tval;
static volatile unsigned long g_vstart_trap;

static volatile int g_irq_mode;
static volatile unsigned long g_irq_count;
static volatile unsigned long g_irq_vstart;
static volatile unsigned long g_irq_mepc;
static volatile unsigned long g_irq_vs;

static void
check(int cond, const char *what, unsigned long ctx, unsigned long got, unsigned long want)
{
    g_checks++;
    if (!cond) {
        g_ok = 0;
        uart_printf("[FAIL] %s (@%lx): got=%lx want=%lx\n", what, ctx, got, want);
    }
}

static inline unsigned long rd_vl(void)
{
    unsigned long v;
    __asm__ volatile("csrr %0, 0xC20" : "=r"(v));
    return v;
}

static inline unsigned long rd_vstart(void)
{
    unsigned long v;
    __asm__ volatile("csrr %0, 0x008" : "=r"(v));
    return v;
}

static inline void wr_vstart(unsigned long v)
{
    __asm__ volatile("csrw 0x008, %0" : : "r"(v) : "memory");
}

static inline unsigned long setvl(unsigned long avl, unsigned long vtype)
{
    unsigned long vl;
    __asm__ volatile(".insn r 0x57, 7, 0x40, %0, %1, %2"
                     : "=r"(vl)
                     : "r"(avl), "r"(vtype)
                     : "memory");
    return vl;
}

static inline void set_vs(unsigned long vs)
{
    csr_clear(mstatus, MSTATUS_VS);
    csr_set(mstatus, vs);
}

static inline unsigned long vs_field(void)
{
    return csr_read(mstatus) & MSTATUS_VS;
}

static inline void load_v8_group(const volatile void *src)
{
    __asm__ volatile(".insn r 0x07, 0, 0x71, x8, %0, x8" : : "r"(src) : "memory");
}

static inline void store_v8_group(volatile void *dst)
{
    __asm__ volatile(".insn r 0x27, 0, 0x71, x8, %0, x8" : : "r"(dst) : "memory");
}

static inline void load_v16_group(const volatile void *src)
{
    __asm__ volatile(".insn r 0x07, 0, 0x71, x16, %0, x8" : : "r"(src) : "memory");
}

static inline void load_v0(const volatile void *src)
{
    __asm__ volatile(".insn r 0x07, 0, 0x01, x0, %0, x8" : : "r"(src) : "memory");
}

static inline void cbo_flush_line(unsigned long addr)
{
    __asm__ volatile(".insn i 0x0F, 2, x0, %0, 2" : : "r"(addr) : "memory");
}

static inline uint64_t rd_mtime64(void)
{
    uint32_t hi0, lo, hi1;
    do {
        hi0 = MTIME_HI;
        lo = MTIME_LO;
        hi1 = MTIME_HI;
    } while (hi0 != hi1);
    return ((uint64_t) hi1 << 32) | lo;
}

static inline void disarm_timer(void)
{
    MTIMECMP_HI = 0xFFFFFFFFu;
    MTIMECMP_LO = 0xFFFFFFFFu;
}

static inline void arm_timer_delta(uint64_t delta)
{
    uint64_t t = rd_mtime64() + delta;
    MTIMECMP_HI = 0xFFFFFFFFu;
    MTIMECMP_LO = (uint32_t) t;
    MTIMECMP_HI = (uint32_t) (t >> 32);
}

static void drain_fifos(void)
{
    for (int i = 0; i < 64; i++) {
        (void) FIFO0;
        (void) FIFO1;
    }
}

static void __attribute__((used)) irq_handler_c(void)
{
    unsigned long cause = csr_read(mcause);
    if (cause == CAUSE_MTI && g_irq_mode) {
        disarm_timer();
        if (g_irq_count == 0ul) {
            g_irq_mepc = csr_read(mepc);
            g_irq_vstart = rd_vstart();
            g_irq_vs = vs_field();
        }
        g_irq_count++;
        return;
    }
    disarm_timer();
    csr_clear(mstatus, MSTATUS_MIE);
    g_ok = 0;
    uart_printf("[UNEXPECTED IRQ] cause=%lx epc=%lx\n<<FAIL>>\n", cause, csr_read(mepc));
    for (;;) {
    }
}

static void __attribute__((used, noreturn)) unexpected_trap_c(void)
{
    uart_printf("[UNEXPECTED TRAP] cause=%lx epc=%lx tval=%lx vstart=%lx\n<<FAIL>>\n",
                g_cause,
                g_epc,
                g_tval,
                g_vstart_trap);
    for (;;) {
    }
}

/* Unified assembly trap entry:
 * - Interrupts (mcause < 0): save all caller-saved registers, call irq_handler_c,
 *   restore, and mret back to the interrupted vector instruction with vstart intact.
 * - Synchronous exceptions: clear MPRV before touching memory, record
 *   mcause/mepc/mtval/vstart (using only clobbered t0/t1), redirect mepc to
 *   mscratch, and mret. */
__attribute__((naked, aligned(4))) static void unified_trap_handler(void)
{
    __asm__ volatile(
        "csrw  sscratch, t0\n"
        "csrr  t0, mcause\n"
        "bltz  t0, 1f\n"
        /* Synchronous exception: clear MPRV so globals are accessed bare. */
        "li    t1, 0x20000\n"
        "csrc  mstatus, t1\n"
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
        "beqz  t0, 2f\n"
        "csrw  mepc, t0\n"
        "mret\n"
        "2:\n"
        "j     unexpected_trap_c\n"
        /* Interrupt path: preserve all caller-saved registers across C call. */
        "1:\n"
        "addi  sp, sp, -128\n"
        "sd    ra,   0(sp)\n"
        "csrr  t0, sscratch\n"
        "sd    t0,   8(sp)\n"
        "sd    t1,  16(sp)\n"
        "sd    t2,  24(sp)\n"
        "sd    t3,  32(sp)\n"
        "sd    t4,  40(sp)\n"
        "sd    t5,  48(sp)\n"
        "sd    t6,  56(sp)\n"
        "sd    a0,  64(sp)\n"
        "sd    a1,  72(sp)\n"
        "sd    a2,  80(sp)\n"
        "sd    a3,  88(sp)\n"
        "sd    a4,  96(sp)\n"
        "sd    a5, 104(sp)\n"
        "sd    a6, 112(sp)\n"
        "sd    a7, 120(sp)\n"
        "call  irq_handler_c\n"
        "ld    ra,   0(sp)\n"
        "ld    t0,   8(sp)\n"
        "ld    t1,  16(sp)\n"
        "ld    t2,  24(sp)\n"
        "ld    t3,  32(sp)\n"
        "ld    t4,  40(sp)\n"
        "ld    t5,  48(sp)\n"
        "ld    t6,  56(sp)\n"
        "ld    a0,  64(sp)\n"
        "ld    a1,  72(sp)\n"
        "ld    a2,  80(sp)\n"
        "ld    a3,  88(sp)\n"
        "ld    a4,  96(sp)\n"
        "ld    a5, 104(sp)\n"
        "ld    a6, 112(sp)\n"
        "ld    a7, 120(sp)\n"
        "addi  sp, sp, 128\n"
        "mret\n");
}

#define RUN_TRAP_1(insn, base)                                                                     \
    do {                                                                                           \
        g_cause = ~0ul;                                                                            \
        g_tval = ~0ul;                                                                             \
        g_vstart_trap = ~0ul;                                                                      \
        __asm__ volatile("la t0, 1f\n csrw mscratch, t0\n" insn "\n"                               \
                         "1:\n csrw mscratch, zero\n"                                              \
                         :                                                                         \
                         : "r"(base)                                                               \
                         : "t0", "t1", "memory");                                                  \
    } while (0)

#define RUN_TRAP_2(insn, base, stride)                                                             \
    do {                                                                                           \
        g_cause = ~0ul;                                                                            \
        g_tval = ~0ul;                                                                             \
        g_vstart_trap = ~0ul;                                                                      \
        __asm__ volatile("la t0, 1f\n csrw mscratch, t0\n" insn "\n"                               \
                         "1:\n csrw mscratch, zero\n"                                              \
                         :                                                                         \
                         : "r"(base), "r"(stride)                                                  \
                         : "t0", "t1", "memory");                                                  \
    } while (0)

#define MPRV_S_ON                                                                                  \
    "li t1, 0x1800\n csrc mstatus, t1\n li t1, 0x0800\n csrs mstatus, t1\n"                        \
    "li t1, 0x20000\n csrs mstatus, t1\n"
#define MPRV_U_ON                                                                                  \
    "li t1, 0x1800\n csrc mstatus, t1\n"                                                           \
    "li t1, 0x20000\n csrs mstatus, t1\n"
#define MPRV_OFF "1:\n li t1, 0x20000\n csrc mstatus, t1\n csrw mscratch, zero\n"

#define RUN_MPRV_1(mprv, insn, va)                                                                 \
    do {                                                                                           \
        g_cause = ~0ul;                                                                            \
        g_tval = ~0ul;                                                                             \
        g_vstart_trap = ~0ul;                                                                      \
        __asm__ volatile("la t0, 1f\n csrw mscratch, t0\n" mprv insn "\n" MPRV_OFF                 \
                         :                                                                         \
                         : "r"(va)                                                                 \
                         : "t0", "t1", "memory");                                                  \
    } while (0)

#define RUN_MPRV_2(mprv, insn, va, stride)                                                         \
    do {                                                                                           \
        g_cause = ~0ul;                                                                            \
        g_tval = ~0ul;                                                                             \
        g_vstart_trap = ~0ul;                                                                      \
        __asm__ volatile("la t0, 1f\n csrw mscratch, t0\n" mprv insn "\n" MPRV_OFF                 \
                         :                                                                         \
                         : "r"(va), "r"(stride)                                                    \
                         : "t0", "t1", "memory");                                                  \
    } while (0)

static void seed_v8(uint8_t base_pat)
{
    for (unsigned long i = 0; i < 8u * g_vlenb; i++)
        vrf_io[i] = (uint8_t) (base_pat ^ (uint8_t) i);
    load_v8_group(vrf_io);
}

static unsigned long lmul_for_16_e32(void)
{
    return g_vlenb == 16u ? VT_M4 : (g_vlenb == 32u ? VT_M2 : VT_M1);
}

static unsigned long lmul_for_8_e32(void)
{
    return g_vlenb == 16u ? VT_M2 : VT_M1;
}

/* ========================================================================== */
/* 1. Low BRAM: every vector memory form + L0 coherence + LR/SC invalidation  */
/* ========================================================================== */
static void test_low_bram_all_forms(void)
{
    check((unsigned long) bram_src + BRAM_BUF_LEN <= LOW_BRAM_LIMIT,
          "bram_src resides in low BRAM",
          (unsigned long) bram_src,
          0,
          1);
    for (unsigned i = 0; i < BRAM_BUF_LEN; i++) {
        bram_src[i] = (uint8_t) (0x21u + i * 3u);
        bram_dst[i] = 0xEEu;
    }

    /* 1a. Unit-stride EEW 8, 16, 32, 64 (unmasked, masked, vstart > 0) */
    {
        static const unsigned eew_bytes[4] = {1u, 2u, 4u, 8u};
        for (unsigned e = 0; e < 4u; e++) {
            unsigned long vl = setvl(4, VT_VTYPE(e, VT_M1));
            unsigned nb = (unsigned) vl * eew_bytes[e];
            for (unsigned i = 0; i < nb + 8u; i++)
                bram_dst[i] = 0xAAu;
            switch (e) {
                case 0:
                    RUN_TRAP_1(".insn r 0x07, 0, 0x01, x8, %0, x0", bram_src + 1);
                    check(g_cause == ~0ul, "BRAM vle8", e, g_cause, ~0ul);
                    RUN_TRAP_1(".insn r 0x27, 0, 0x01, x8, %0, x0", bram_dst + 1);
                    check(g_cause == ~0ul, "BRAM vse8", e, g_cause, ~0ul);
                    for (unsigned i = 0; i < nb; i++)
                        check(bram_dst[1 + i] == bram_src[1 + i],
                              "BRAM unit e8 data",
                              i,
                              bram_dst[1 + i],
                              bram_src[1 + i]);
                    break;
                case 1:
                    RUN_TRAP_1(".insn r 0x07, 5, 0x01, x8, %0, x0", bram_src + 2);
                    check(g_cause == ~0ul, "BRAM vle16", e, g_cause, ~0ul);
                    RUN_TRAP_1(".insn r 0x27, 5, 0x01, x8, %0, x0", bram_dst + 2);
                    check(g_cause == ~0ul, "BRAM vse16", e, g_cause, ~0ul);
                    for (unsigned i = 0; i < nb; i++)
                        check(bram_dst[2 + i] == bram_src[2 + i],
                              "BRAM unit e16 data",
                              i,
                              bram_dst[2 + i],
                              bram_src[2 + i]);
                    break;
                case 2:
                    RUN_TRAP_1(".insn r 0x07, 6, 0x01, x8, %0, x0", bram_src + 4);
                    check(g_cause == ~0ul, "BRAM vle32", e, g_cause, ~0ul);
                    RUN_TRAP_1(".insn r 0x27, 6, 0x01, x8, %0, x0", bram_dst + 4);
                    check(g_cause == ~0ul, "BRAM vse32", e, g_cause, ~0ul);
                    for (unsigned i = 0; i < nb; i++)
                        check(bram_dst[4 + i] == bram_src[4 + i],
                              "BRAM unit e32 data",
                              i,
                              bram_dst[4 + i],
                              bram_src[4 + i]);
                    break;
                default:
                    RUN_TRAP_1(".insn r 0x07, 7, 0x01, x8, %0, x0", bram_src + 8);
                    check(g_cause == ~0ul, "BRAM vle64", e, g_cause, ~0ul);
                    RUN_TRAP_1(".insn r 0x27, 7, 0x01, x8, %0, x0", bram_dst + 8);
                    check(g_cause == ~0ul, "BRAM vse64", e, g_cause, ~0ul);
                    for (unsigned i = 0; i < nb; i++)
                        check(bram_dst[8 + i] == bram_src[8 + i],
                              "BRAM unit e64 data",
                              i,
                              bram_dst[8 + i],
                              bram_src[8 + i]);
                    break;
            }
        }

        /* Masked + vstart > 0 unit-stride on stack buffer in low BRAM */
        volatile uint32_t stk_src[4] __attribute__((aligned(16))) = {
            0x10101010u, 0x20202020u, 0x30303030u, 0x40404040u
        };
        volatile uint32_t stk_dst[4] __attribute__((aligned(16))) = {
            0xAAAAAAAAu, 0xBBBBBBBBu, 0xCCCCCCCCu, 0xDDDDDDDDu
        };
        check((unsigned long) stk_src > BRAM_IDX_PA + 256u &&
                  (unsigned long) stk_src + sizeof(stk_src) <= LOW_BRAM_LIMIT,
              "stack buffer in low BRAM above scratch",
              (unsigned long) stk_src,
              0,
              1);
        vrf_io[0] = 0x0Au; /* active bits 1 and 3 */
        for (unsigned long i = 1; i < g_vlenb; i++)
            vrf_io[i] = 0u;
        load_v0(vrf_io);
        setvl(4, VT_VTYPE(VT_E32, VT_M1));
        seed_v8(0x55u);
        wr_vstart(1);
        RUN_TRAP_1(".insn r 0x07, 6, 0x00, x8, %0, x0", stk_src);
        check(g_cause == ~0ul && rd_vstart() == 0ul, "BRAM stack masked vle32", 0, g_cause, ~0ul);
        wr_vstart(1);
        RUN_TRAP_1(".insn r 0x27, 6, 0x00, x8, %0, x0", stk_dst);
        check(g_cause == ~0ul, "BRAM stack masked vse32", 0, g_cause, ~0ul);
        check(stk_dst[0] == 0xAAAAAAAAu && stk_dst[1] == 0x20202020u &&
                  stk_dst[2] == 0xCCCCCCCCu && stk_dst[3] == 0x40404040u,
              "BRAM stack masked data",
              stk_dst[1],
              stk_dst[3],
              0x40404040u);
    }

    /* 1b. Whole-register (vl1re32/vs1r, vl2re64/vs2r, including under vill=1) */
    {
        for (unsigned long i = 0; i < 2u * g_vlenb; i++)
            bram_dst[i] = 0x77u;
        /* Set vill=1 via reserved vtype bit */
        (void) setvl(4, 1ul << 30);
        RUN_TRAP_1(".insn r 0x07, 6, 0x01, x8, %0, x8", bram_src);
        check(g_cause == ~0ul, "BRAM vl1re32 under vill", 0, g_cause, ~0ul);
        RUN_TRAP_1(".insn r 0x27, 0, 0x01, x8, %0, x8", bram_dst);
        check(g_cause == ~0ul, "BRAM vs1r under vill", 0, g_cause, ~0ul);
        for (unsigned long i = 0; i < g_vlenb; i++)
            check(bram_dst[i] == bram_src[i], "BRAM whole-reg 1 byte", i, bram_dst[i], bram_src[i]);
        RUN_TRAP_1(".insn r 0x07, 7, 0x11, x8, %0, x8", bram_src);
        check(g_cause == ~0ul, "BRAM vl2re64 under vill", 0, g_cause, ~0ul);
        RUN_TRAP_1(".insn r 0x27, 0, 0x11, x8, %0, x8", bram_dst);
        check(g_cause == ~0ul, "BRAM vs2r under vill", 0, g_cause, ~0ul);
        for (unsigned long i = 0; i < 2u * g_vlenb; i++)
            check(bram_dst[i] == bram_src[i], "BRAM whole-reg 2 byte", i, bram_dst[i], bram_src[i]);
    }

    /* 1c. Mask load/store (vlm.v, vsm.v at odd low-BRAM byte address) */
    {
        for (unsigned i = 0; i < 8u; i++)
            bram_dst[i] = 0xEEu;
        setvl(19, VT_VTYPE(VT_E8, VT_M2)); /* 3 mask bytes */
        RUN_TRAP_1(".insn r 0x07, 0, 0x01, x8, %0, x11", bram_src + 3);
        check(g_cause == ~0ul, "BRAM vlm.v", 0, g_cause, ~0ul);
        RUN_TRAP_1(".insn r 0x27, 0, 0x01, x8, %0, x11", bram_dst + 3);
        check(g_cause == ~0ul, "BRAM vsm.v", 0, g_cause, ~0ul);
        for (unsigned i = 0; i < 3u; i++)
            check(bram_dst[3 + i] == bram_src[3 + i],
                  "BRAM mask byte",
                  i,
                  bram_dst[3 + i],
                  bram_src[3 + i]);
        check(bram_dst[6] == 0xEEu, "BRAM mask tail guard", 6, bram_dst[6], 0xEEu);
    }

    /* 1d. Strided (positive, negative, zero stride) in low BRAM */
    {
        volatile uint32_t *s32 = (volatile uint32_t *) bram_src;
        volatile uint32_t *d32 = (volatile uint32_t *) bram_dst;
        for (unsigned i = 0; i < 16u; i++) {
            s32[i] = 0xA0000000u + i;
            d32[i] = 0xDEADBEEFu;
        }
        setvl(4, VT_VTYPE(VT_E32, VT_M1));
        RUN_TRAP_2(".insn r 0x07, 6, 0x05, x8, %0, %1", s32 + 9, -8l); /* elems at 9,7,5,3 */
        check(g_cause == ~0ul, "BRAM neg vlse32", 0, g_cause, ~0ul);
        RUN_TRAP_2(".insn r 0x27, 6, 0x05, x8, %0, %1", d32, 12l); /* elems at 0,3,6,9 */
        check(g_cause == ~0ul, "BRAM pos vsse32", 0, g_cause, ~0ul);
        check(d32[0] == 0xA0000009u && d32[3] == 0xA0000007u && d32[6] == 0xA0000005u &&
                  d32[9] == 0xA0000003u && d32[1] == 0xDEADBEEFu,
              "BRAM strided data",
              d32[0],
              d32[9],
              0xA0000003u);
    }

    /* 1e. Indexed (ordered & unordered, index EEW 16 & 32) in low BRAM */
    {
        volatile uint32_t *s32 = (volatile uint32_t *) bram_src;
        volatile uint32_t *d32 = (volatile uint32_t *) bram_dst;
        volatile uint16_t *ix16 = (volatile uint16_t *) bram_idx;
        for (unsigned i = 0; i < 16u; i++) {
            s32[i] = 0xB0000000u + i;
            d32[i] = 0x55555555u;
        }
        ix16[0] = 24u; /* s32[6] */
        ix16[1] = 8u;  /* s32[2] */
        ix16[2] = 44u; /* s32[11] */
        ix16[3] = 0u;  /* s32[0] */
        setvl(4, VT_VTYPE(VT_E16, VT_M1));
        RUN_TRAP_1(".insn r 0x07, 5, 0x01, x16, %0, x0", ix16);
        setvl(4, VT_VTYPE(VT_E32, VT_M1));
        RUN_TRAP_1(".insn r 0x07, 5, 0x03, x8, %0, x16", s32); /* vluxei16.v v8,(s32),v16 */
        check(g_cause == ~0ul, "BRAM vluxei16", 0, g_cause, ~0ul);
        RUN_TRAP_1(".insn r 0x27, 5, 0x07, x8, %0, x16", d32); /* vsoxei16.v v8,(d32),v16 */
        check(g_cause == ~0ul, "BRAM vsoxei16", 0, g_cause, ~0ul);
        check(d32[6] == 0xB0000006u && d32[2] == 0xB0000002u && d32[11] == 0xB000000Bu &&
                  d32[0] == 0xB0000000u && d32[1] == 0x55555555u,
              "BRAM indexed data",
              d32[6],
              d32[11],
              0xB000000Bu);
    }

    /* 1f. Segments (unit-stride nf=2 & nf=4, strided nf=2, indexed nf=2) in low BRAM */
    {
        volatile uint32_t *s32 = (volatile uint32_t *) bram_src;
        volatile uint32_t *d32 = (volatile uint32_t *) bram_dst;
        for (unsigned i = 0; i < 32u; i++) {
            s32[i] = 0xC0000000u + i;
            d32[i] = 0u;
        }
        setvl(4, VT_VTYPE(VT_E32, VT_M1));
        /* vlseg4e32.v v8, (s32) -> vsseg4e32.v v8, (d32) */
        RUN_TRAP_1(".insn r 0x07, 6, 0x31, x8, %0, x0", s32);
        check(g_cause == ~0ul, "BRAM vlseg4e32", 0, g_cause, ~0ul);
        RUN_TRAP_1(".insn r 0x27, 6, 0x31, x8, %0, x0", d32);
        check(g_cause == ~0ul, "BRAM vsseg4e32", 0, g_cause, ~0ul);
        for (unsigned i = 0; i < 16u; i++)
            check(d32[i] == s32[i], "BRAM seg4 word", i, d32[i], s32[i]);

        /* vlsseg2e32 / vssseg2e32 with stride 16 */
        for (unsigned i = 0; i < 16u; i++)
            d32[i] = 0u;
        RUN_TRAP_2(".insn r 0x07, 6, 0x15, x8, %0, %1", s32, 16l);
        check(g_cause == ~0ul, "BRAM vlsseg2e32", 0, g_cause, ~0ul);
        RUN_TRAP_2(".insn r 0x27, 6, 0x15, x8, %0, %1", d32, 16l);
        check(g_cause == ~0ul, "BRAM vssseg2e32", 0, g_cause, ~0ul);
        for (unsigned e = 0; e < 4u; e++) {
            check(d32[4 * e] == s32[4 * e] && d32[4 * e + 1] == s32[4 * e + 1] &&
                      d32[4 * e + 2] == 0u,
                  "BRAM strided seg2",
                  e,
                  d32[4 * e + 1],
                  s32[4 * e + 1]);
        }

        /* vloxseg2ei32 / vsoxseg2ei32 */
        volatile uint32_t *ix32 = (volatile uint32_t *) bram_idx;
        ix32[0] = 24u;
        ix32[1] = 0u;
        ix32[2] = 40u;
        ix32[3] = 8u;
        RUN_TRAP_1(".insn r 0x07, 6, 0x01, x16, %0, x0", ix32);
        for (unsigned i = 0; i < 16u; i++)
            d32[i] = 0u;
        RUN_TRAP_1(".insn r 0x07, 6, 0x17, x8, %0, x16", s32);
        check(g_cause == ~0ul, "BRAM vloxseg2ei32", 0, g_cause, ~0ul);
        RUN_TRAP_1(".insn r 0x27, 6, 0x17, x8, %0, x16", d32);
        check(g_cause == ~0ul, "BRAM vsoxseg2ei32", 0, g_cause, ~0ul);
        check(d32[6] == s32[6] && d32[7] == s32[7] && d32[10] == s32[10] && d32[11] == s32[11],
              "BRAM indexed seg2",
              d32[10],
              d32[11],
              s32[11]);
    }

    /* 1g. Fault-only-first on low BRAM, plus boundary trim across 0x40000 */
    {
        volatile uint32_t *s32 = (volatile uint32_t *) bram_src;
        volatile uint32_t *d32 = (volatile uint32_t *) bram_dst;
        setvl(4, VT_VTYPE(VT_E32, VT_M1));
        RUN_TRAP_1(".insn r 0x07, 6, 0x01, x8, %0, x16", s32); /* vle32ff.v */
        check(g_cause == ~0ul && rd_vl() == 4ul, "BRAM vle32ff", rd_vl(), g_cause, ~0ul);
        RUN_TRAP_1(".insn r 0x07, 6, 0x11, x8, %0, x16", s32); /* vlseg2e32ff.v */
        check(g_cause == ~0ul && rd_vl() == 4ul, "BRAM vlseg2e32ff", rd_vl(), g_cause, ~0ul);

        /* Cross upper edge of low BRAM [0x3FFF8..0x3FFFF] into unmapped 0x40000.
         * Note: stack top is 0x40000; reading the top 8 bytes is non-destructive! */
        setvl(4, VT_VTYPE(VT_E32, VT_M1));
        RUN_TRAP_1(".insn r 0x07, 6, 0x01, x8, %0, x16", (void *) (LOW_BRAM_LIMIT - 8ul));
        check(g_cause == ~0ul && rd_vl() == 2ul && rd_vstart() == 0ul,
              "BRAM vle32ff trims vl at 0x40000 boundary",
              rd_vl(),
              g_cause,
              ~0ul);
        /* Element 0 at unmapped 0x40000 traps with cause 5 */
        setvl(4, VT_VTYPE(VT_E32, VT_M1));
        RUN_TRAP_1(".insn r 0x07, 6, 0x01, x8, %0, x16", (void *) LOW_BRAM_LIMIT);
        check(g_cause == CAUSE_LOAD_ACCESS && g_tval == LOW_BRAM_LIMIT && g_vstart_trap == 0ul,
              "BRAM vle32ff elem-0 at 0x40000 traps",
              g_tval,
              g_cause,
              CAUSE_LOAD_ACCESS);
        wr_vstart(0);
        (void) d32;
    }

    /* 1h. Low-BRAM L0 coherence & LR/SC reservation invalidation */
    {
        volatile uint64_t *b64 = (volatile uint64_t *) bram_dst;
        b64[0] = 0x1111111111111111ull;
        b64[1] = 0x2222222222222222ull;
        /* Warm scalar L0 cache with scalar loads from low BRAM */
        uint64_t warm0 = b64[0];
        uint64_t warm1 = b64[1];
        check(warm0 == 0x1111111111111111ull && warm1 == 0x2222222222222222ull,
              "BRAM L0 warm",
              0,
              warm0,
              0x1111111111111111ull);
        /* Overwrite via vector store and read immediately with scalar load (no fence!) */
        *(volatile uint64_t *) (vrf_io + 0) = 0xCAFEBABE12345678ull;
        *(volatile uint64_t *) (vrf_io + 8) = 0xFEEDFACE87654321ull;
        load_v8_group(vrf_io);
        setvl(2, VT_VTYPE(VT_E64, VT_M1));
        RUN_TRAP_1(".insn r 0x27, 7, 0x01, x8, %0, x0", b64);
        uint64_t after0 = b64[0];
        uint64_t after1 = b64[1];
        check(after0 == 0xCAFEBABE12345678ull && after1 == 0xFEEDFACE87654321ull,
              "BRAM L0 invalidated by vector store",
              after0,
              after1,
              0xFEEDFACE87654321ull);

        /* LR/SC reservation in low BRAM invalidated by vector store */
        volatile uint32_t *b32 = (volatile uint32_t *) bram_dst;
        b32[0] = 0x12340001u;
        *(volatile uint32_t *) vrf_io = 0x56780002u;
        load_v8_group(vrf_io);
        setvl(1, VT_VTYPE(VT_E32, VT_M1));
        uint64_t lr_val, sc_res;
        __asm__ volatile("lr.w %0, (%2)\n"
                         ".insn r 0x27, 6, 0x01, x8, %2, x0\n"
                         "sc.w %1, %3, (%2)\n"
                         : "=&r"(lr_val), "=&r"(sc_res)
                         : "r"(b32), "r"(0x99990003u)
                         : "memory");
        check(lr_val == 0x12340001u && sc_res != 0ul && b32[0] == 0x56780002u,
              "BRAM LR/SC invalidated by vector store",
              sc_res,
              b32[0],
              0x56780002u);
    }
}

/* ========================================================================== */
/* 2. Side-effecting devices (FIFO0, FIFO1, MTIME): order, zero dup, mixing   */
/* ========================================================================== */
static void test_device_side_effects_and_order(void)
{
    volatile uint32_t *dump32 = (volatile uint32_t *) (vrf_io + 1024);
    drain_fifos();

    /* 2a. Unit-stride vse32/vle32 across [FIFO0, FIFO1] (tests addr[2]==1 replication!) */
    {
        *(volatile uint32_t *) (vrf_io + 0) = 0x10010001u;
        *(volatile uint32_t *) (vrf_io + 4) = 0x20020002u;
        load_v8_group(vrf_io);
        setvl(2, VT_VTYPE(VT_E32, VT_M1));
        RUN_TRAP_1(".insn r 0x27, 6, 0x01, x8, %0, x0", (void *) FIFO0_PA);
        check(g_cause == ~0ul, "MMIO unit vse32 FIFO0+FIFO1", 0, g_cause, ~0ul);
        /* Push sentinels after so we verify exact pop count = 1 each */
        FIFO0 = 0x1001EEEEu;
        FIFO1 = 0x2002EEEEu;
        seed_v8(0x33u);
        RUN_TRAP_1(".insn r 0x07, 6, 0x01, x8, %0, x0", (void *) FIFO0_PA);
        check(g_cause == ~0ul, "MMIO unit vle32 FIFO0+FIFO1", 0, g_cause, ~0ul);
        store_v8_group(dump32);
        uint32_t rem0 = FIFO0;
        uint32_t rem1 = FIFO1;
        check(dump32[0] == 0x10010001u && dump32[1] == 0x20020002u && rem0 == 0x1001EEEEu &&
                  rem1 == 0x2002EEEEu && FIFO0 == 0u && FIFO1 == 0u,
              "MMIO unit FIFO0+FIFO1 exact order & no dup pops",
              rem0,
              dump32[1],
              0x20020002u);
    }

    /* 2b. Whole-register vl1re32.v at FIFO0: pops FIFO0 once and FIFO1 once */
    {
        FIFO0 = 0x31313131u;
        FIFO0 = 0x31319999u;
        FIFO1 = 0x41414141u;
        FIFO1 = 0x41419999u;
        seed_v8(0x44u);
        RUN_TRAP_1(".insn r 0x07, 6, 0x01, x8, %0, x8", (void *) FIFO0_PA);
        check(g_cause == ~0ul, "MMIO vl1re32 at FIFO0", 0, g_cause, ~0ul);
        store_v8_group(dump32);
        uint32_t rem0 = FIFO0;
        uint32_t rem1 = FIFO1;
        check(dump32[0] == 0x31313131u && dump32[1] == 0x41414141u && rem0 == 0x31319999u &&
                  rem1 == 0x41419999u && FIFO0 == 0u && FIFO1 == 0u,
              "MMIO vl1re32 exact single pop of FIFO0 & FIFO1",
              rem0,
              rem1,
              0x41419999u);

        /* Monotonic hardware counter (MTIME_LO) via stride-0 vlse32 */
        uint32_t mt_before = MTIME_LO;
        setvl(4, VT_VTYPE(VT_E32, VT_M1));
        RUN_TRAP_2(".insn r 0x07, 6, 0x05, x8, %0, %1", (void *) MTIME_PA, 0l);
        uint32_t mt_after = MTIME_LO;
        store_v8_group(dump32);
        check(g_cause == ~0ul && dump32[0] >= mt_before && dump32[1] > dump32[0] &&
                  dump32[2] > dump32[1] && dump32[3] > dump32[2] && mt_after >= dump32[3],
              "MMIO stride-0 vlse32 MTIME strictly advances per element",
              dump32[0],
              dump32[3],
              mt_after);
    }

    /* 2c. Strided stride-0 vsse32 / vlse32 (8 words, exact order & zero dup pops) +
     *     masked vlse32 (inactive lanes must NOT pop FIFO0!) + negative stride -4 */
    {
        unsigned long m8 = lmul_for_8_e32();
        for (unsigned i = 0; i < 8u; i++)
            ((volatile uint32_t *) vrf_io)[i] = 0x51000001u + i;
        load_v8_group(vrf_io);
        setvl(8, VT_VTYPE(VT_E32, m8));
        RUN_TRAP_2(".insn r 0x27, 6, 0x05, x8, %0, %1", (void *) FIFO0_PA, 0l);
        check(g_cause == ~0ul, "MMIO stride-0 vsse32 FIFO0", 0, g_cause, ~0ul);
        for (unsigned i = 0; i < 8u; i++) {
            uint32_t v = FIFO0;
            check(v == 0x51000001u + i, "MMIO vsse32 FIFO0 order", i, v, 0x51000001u + i);
        }
        check(FIFO0 == 0u, "MMIO vsse32 no extra push", 0, FIFO0, 0u);

        for (unsigned i = 0; i < 9u; i++)
            FIFO0 = 0x52000001u + i;
        seed_v8(0x66u);
        RUN_TRAP_2(".insn r 0x07, 6, 0x05, x8, %0, %1", (void *) FIFO0_PA, 0l);
        check(g_cause == ~0ul, "MMIO stride-0 vlse32 FIFO0", 0, g_cause, ~0ul);
        store_v8_group(dump32);
        for (unsigned i = 0; i < 8u; i++)
            check(dump32[i] == 0x52000001u + i,
                  "MMIO vlse32 FIFO0 order",
                  i,
                  dump32[i],
                  0x52000001u + i);
        uint32_t sentinel = FIFO0;
        check(sentinel == 0x52000009u && FIFO0 == 0u,
              "MMIO vlse32 zero dup pops",
              0,
              sentinel,
              0x52000009u);

        /* Masked vlse32: mask 0x55 (4 active lanes: 0,2,4,6) pops exactly 4 entries! */
        for (unsigned i = 0; i < 5u; i++)
            FIFO0 = 0x53000001u + i;
        vrf_io[0] = 0x55u;
        for (unsigned long i = 1; i < g_vlenb; i++)
            vrf_io[i] = 0u;
        load_v0(vrf_io);
        seed_v8(0x22u);
        setvl(8, VT_VTYPE(VT_E32, m8));
        RUN_TRAP_2(".insn r 0x07, 6, 0x04, x8, %0, %1", (void *) FIFO0_PA, 0l);
        check(g_cause == ~0ul, "MMIO masked vlse32 FIFO0", 0, g_cause, ~0ul);
        store_v8_group(dump32);
        for (unsigned k = 0; k < 4u; k++)
            check(dump32[2 * k] == 0x53000001u + k,
                  "MMIO masked vlse32 active lane",
                  k,
                  dump32[2 * k],
                  0x53000001u + k);
        uint32_t rem = FIFO0;
        check(rem == 0x53000005u && FIFO0 == 0u,
              "MMIO masked vlse32 inactive lanes did not pop",
              0,
              rem,
              0x53000005u);

        /* Negative stride -4 from FIFO1 to FIFO0 */
        FIFO1 = 0x54000001u;
        FIFO0 = 0x54000002u;
        setvl(2, VT_VTYPE(VT_E32, VT_M1));
        RUN_TRAP_2(".insn r 0x07, 6, 0x05, x8, %0, %1", (void *) FIFO1_PA, -4l);
        store_v8_group(dump32);
        check(dump32[0] == 0x54000001u && dump32[1] == 0x54000002u && FIFO0 == 0u && FIFO1 == 0u,
              "MMIO neg-stride FIFO1->FIFO0",
              dump32[0],
              dump32[1],
              0x54000002u);
    }

    /* 2d. Indexed ordered & unordered on FIFO0/FIFO1 + mixed DDR/BRAM/FIFO0/FIFO1 */
    {
        unsigned long m8 = lmul_for_8_e32();
        volatile uint32_t *ix32 = (volatile uint32_t *) bram_idx;
        ix32[0] = 0u;
        ix32[1] = 4u;
        ix32[2] = 0u;
        ix32[3] = 4u;
        ix32[4] = 0u;
        ix32[5] = 4u;
        setvl(6, VT_VTYPE(VT_E32, m8));
        RUN_TRAP_1(".insn r 0x07, 6, 0x01, x16, %0, x0", ix32);

        for (unsigned i = 0; i < 6u; i++)
            ((volatile uint32_t *) vrf_io)[i] = 0x61000001u + i;
        load_v8_group(vrf_io);
        /* vsoxei32.v v8, (FIFO0), v16 */
        RUN_TRAP_1(".insn r 0x27, 6, 0x07, x8, %0, x16", (void *) FIFO0_PA);
        check(g_cause == ~0ul, "MMIO vsoxei32 FIFO0/1", 0, g_cause, ~0ul);
        /* FIFO0 has 1,3,5; FIFO1 has 2,4,6 */
        FIFO0 = 0x6100EEEEu;
        FIFO1 = 0x6101EEEEu;
        seed_v8(0x77u);
        /* vloxei32.v v8, (FIFO0), v16 */
        RUN_TRAP_1(".insn r 0x07, 6, 0x07, x8, %0, x16", (void *) FIFO0_PA);
        check(g_cause == ~0ul, "MMIO vloxei32 FIFO0/1", 0, g_cause, ~0ul);
        store_v8_group(dump32);
        for (unsigned i = 0; i < 6u; i++)
            check(dump32[i] == 0x61000001u + i,
                  "MMIO vloxei32 FIFO0/1 order",
                  i,
                  dump32[i],
                  0x61000001u + i);
        check(FIFO0 == 0x6100EEEEu && FIFO1 == 0x6101EEEEu && FIFO0 == 0u && FIFO1 == 0u,
              "MMIO vloxei32 zero dup pops",
              0,
              0,
              0);

        /* Unordered vluxei32 mixing DDR, low BRAM, FIFO0, FIFO1, DDR in one op */
        volatile uint32_t *ddr32 = (volatile uint32_t *) ddr_scratch;
        volatile uint32_t *bram32 = (volatile uint32_t *) bram_src;
        ddr32[0] = 0xD0000001u;
        bram32[0] = 0xB0000002u;
        FIFO0 = 0xF0000003u;
        FIFO1 = 0xF1000004u;
        ddr32[1] = 0xD0000005u;
        volatile uint64_t *ix64 = (volatile uint64_t *) ddr_scratch + 16;
        ix64[0] = (unsigned long) &ddr32[0];
        ix64[1] = (unsigned long) &bram32[0];
        ix64[2] = FIFO0_PA;
        ix64[3] = FIFO1_PA;
        ix64[4] = (unsigned long) &ddr32[1];
        setvl(5, VT_VTYPE(VT_E64, lmul_for_16_e32()));
        RUN_TRAP_1(".insn r 0x07, 7, 0x01, x16, %0, x0", ix64);
        setvl(5, VT_VTYPE(VT_E32, m8));
        RUN_TRAP_1(".insn r 0x07, 7, 0x03, x8, %0, x16", 0ul); /* vluxei64.v v8,(x0),v16 */
        check(g_cause == ~0ul, "mixed DDR+BRAM+FIFO0+FIFO1 vluxei64", 0, g_cause, ~0ul);
        store_v8_group(dump32);
        check(dump32[0] == 0xD0000001u && dump32[1] == 0xB0000002u && dump32[2] == 0xF0000003u &&
                  dump32[3] == 0xF1000004u && dump32[4] == 0xD0000005u && FIFO0 == 0u &&
                  FIFO1 == 0u,
              "mixed DDR+BRAM+FIFO0+FIFO1 data",
              dump32[2],
              dump32[4],
              0xD0000005u);
    }

    /* 2e. Segment stride-0 vssseg2e32 / vlsseg2e32 on [FIFO0, FIFO1] */
    {
        for (unsigned i = 0; i < 4u; i++) {
            ((volatile uint32_t *) (vrf_io + 0 * g_vlenb))[i] = 0x70000001u + i;
            ((volatile uint32_t *) (vrf_io + 1 * g_vlenb))[i] = 0x71000001u + i;
        }
        load_v8_group(vrf_io);
        setvl(4, VT_VTYPE(VT_E32, VT_M1));
        RUN_TRAP_2(".insn r 0x27, 6, 0x15, x8, %0, %1", (void *) FIFO0_PA, 0l); /* vssseg2e32 */
        check(g_cause == ~0ul, "MMIO vssseg2e32 FIFO0/1", 0, g_cause, ~0ul);
        FIFO0 = 0x7000EEEEu;
        FIFO1 = 0x7100EEEEu;
        seed_v8(0x88u);
        RUN_TRAP_2(".insn r 0x07, 6, 0x15, x8, %0, %1", (void *) FIFO0_PA, 0l); /* vlsseg2e32 */
        check(g_cause == ~0ul, "MMIO vlsseg2e32 FIFO0/1", 0, g_cause, ~0ul);
        store_v8_group(dump32);
        for (unsigned i = 0; i < 4u; i++) {
            uint32_t f0 = ((volatile uint32_t *) ((volatile uint8_t *) dump32 + 0 * g_vlenb))[i];
            uint32_t f1 = ((volatile uint32_t *) ((volatile uint8_t *) dump32 + 1 * g_vlenb))[i];
            check(f0 == 0x70000001u + i && f1 == 0x71000001u + i,
                  "MMIO vlsseg2e32 order",
                  i,
                  f0,
                  0x70000001u + i);
        }
        check(FIFO0 == 0x7000EEEEu && FIFO1 == 0x7100EEEEu && FIFO0 == 0u && FIFO1 == 0u,
              "MMIO vlsseg2e32 zero dup pops",
              0,
              0,
              0);
    }

    /* 2f. Fault-only-first vle32ff.v and vlseg2e32ff.v on FIFO0/FIFO1 */
    {
        FIFO0 = 0x80000001u;
        FIFO0 = 0x8000EEEEu;
        FIFO1 = 0x81000001u;
        FIFO1 = 0x8100EEEEu;
        setvl(2, VT_VTYPE(VT_E32, VT_M1));
        RUN_TRAP_1(".insn r 0x07, 6, 0x01, x8, %0, x16", (void *) FIFO0_PA);
        store_v8_group(dump32);
        check(g_cause == ~0ul && rd_vl() == 2ul && dump32[0] == 0x80000001u &&
                  dump32[1] == 0x81000001u,
              "MMIO vle32ff FIFO0/1",
              dump32[0],
              dump32[1],
              0x81000001u);
        setvl(1, VT_VTYPE(VT_E32, VT_M1));
        RUN_TRAP_1(".insn r 0x07, 6, 0x11, x8, %0, x16", (void *) FIFO0_PA);
        store_v8_group(dump32);
        uint32_t f0 = ((volatile uint32_t *) ((volatile uint8_t *) dump32 + 0 * g_vlenb))[0];
        uint32_t f1 = ((volatile uint32_t *) ((volatile uint8_t *) dump32 + 1 * g_vlenb))[0];
        check(g_cause == ~0ul && rd_vl() == 1ul && f0 == 0x8000EEEEu && f1 == 0x8100EEEEu &&
                  FIFO0 == 0u && FIFO1 == 0u,
              "MMIO vlseg2e32ff FIFO0/1",
              f0,
              f1,
              0x8100EEEEu);
    }

    /* 2g. Program order with scalar MMIO (interleaved scalar & vector on FIFO0)
     *     AND wrong-path non-speculation over FIFO0 vector load */
    {
        ((volatile uint32_t *) vrf_io)[0] = 0xA0000002u;
        ((volatile uint32_t *) vrf_io)[1] = 0xA0000003u;
        load_v8_group(vrf_io);
        setvl(2, VT_VTYPE(VT_E32, VT_M1));
        /* Push sequence: scalar 1 -> vector (2, 3) -> scalar 4 */
        FIFO0 = 0xA0000001u;
        RUN_TRAP_2(".insn r 0x27, 6, 0x05, x8, %0, %1", (void *) FIFO0_PA, 0l);
        FIFO0 = 0xA0000004u;
        /* Pop sequence: vector (1, 2) -> scalar 3 -> vector (4) */
        RUN_TRAP_2(".insn r 0x07, 6, 0x05, x8, %0, %1", (void *) FIFO0_PA, 0l);
        store_v8_group(dump32);
        uint32_t s3 = FIFO0;
        setvl(1, VT_VTYPE(VT_E32, VT_M1));
        RUN_TRAP_1(".insn r 0x07, 6, 0x01, x8, %0, x0", (void *) FIFO0_PA);
        store_v8_group(dump32 + 4);
        check(dump32[0] == 0xA0000001u && dump32[1] == 0xA0000002u && s3 == 0xA0000003u &&
                  dump32[4] == 0xA0000004u && FIFO0 == 0u,
              "scalar-vector MMIO FIFO0 program order",
              s3,
              dump32[4],
              0xA0000004u);

        /* Speculative wrong-path branch over a FIFO0 vector load must never pop FIFO0 */
        FIFO0 = 0xCAFE0001u;
        volatile uint64_t cond_mem = 1ull;
        setvl(2, VT_VTYPE(VT_E32, VT_M1));
        for (int iter = 0; iter < 8; iter++) {
            __asm__ volatile("ld t0, 0(%0)\n"
                             "bnez t0, 1f\n"
                             ".insn r 0x07, 6, 0x01, x8, %1, x0\n"
                             "1:\n"
                             :
                             : "r"(&cond_mem), "r"((void *) FIFO0_PA)
                             : "t0", "memory");
        }
        uint32_t intact = FIFO0;
        check(intact == 0xCAFE0001u && FIFO0 == 0u,
              "wrong-path vector load never pops FIFO0",
              0,
              intact,
              0xCAFE0001u);
    }
}

/* ========================================================================== */
/* 3. Faults, vstart, Sv39 permissions, Svpbmt NC/IO, and mixed page crossings */
/* ========================================================================== */
static void test_faults_and_sv39_svpbmt(void)
{
    volatile uint32_t *dump32 = (volatile uint32_t *) (vrf_io + 1024);
    drain_fifos();

    /* 3a. Partial device run faulting at element 1 on alignment (cause 4) & PMA (cause 5) */
    {
        FIFO0 = 0x90000001u;
        FIFO0 = 0x9000EEEEu;
        volatile uint64_t *ix64 = (volatile uint64_t *) ddr_scratch;
        ix64[0] = FIFO0_PA;
        ix64[1] = FIFO0_PA + 2ul; /* misaligned MMIO -> cause 4 */
        ix64[2] = FIFO0_PA;
        setvl(3, VT_VTYPE(VT_E64, lmul_for_8_e32()));
        RUN_TRAP_1(".insn r 0x07, 7, 0x01, x16, %0, x0", ix64);
        setvl(3, VT_VTYPE(VT_E32, VT_M1));
        seed_v8(0xAAu);
        RUN_TRAP_1(".insn r 0x07, 7, 0x07, x8, %0, x16", 0ul);
        check(g_cause == CAUSE_LOAD_MISALIGN && g_tval == FIFO0_PA + 2ul && g_vstart_trap == 1ul &&
                  rd_vstart() == 1ul,
              "MMIO elem-1 misaligned trap + vstart=1",
              g_vstart_trap,
              g_cause,
              CAUSE_LOAD_MISALIGN);
        wr_vstart(0);
        store_v8_group(dump32);
        uint32_t rem = FIFO0;
        check(dump32[0] == 0x90000001u && rem == 0x9000EEEEu && FIFO0 == 0u,
              "MMIO elem-1 misaligned popped elem 0 only",
              dump32[0],
              rem,
              0x9000EEEEu);

        /* Element 0 = FIFO0, element 1 = unmapped 0x40040000 -> cause 5, vstart=1 */
        FIFO0 = 0x91000001u;
        FIFO0 = 0x9100EEEEu;
        ix64[1] = UNMAPPED_DEV_PA;
        setvl(3, VT_VTYPE(VT_E64, lmul_for_8_e32()));
        RUN_TRAP_1(".insn r 0x07, 7, 0x01, x16, %0, x0", ix64);
        setvl(3, VT_VTYPE(VT_E32, VT_M1));
        RUN_TRAP_1(".insn r 0x07, 7, 0x07, x8, %0, x16", 0ul);
        check(g_cause == CAUSE_LOAD_ACCESS && g_tval == UNMAPPED_DEV_PA && g_vstart_trap == 1ul,
              "MMIO elem-1 unmapped access fault + vstart=1",
              g_vstart_trap,
              g_cause,
              CAUSE_LOAD_ACCESS);
        wr_vstart(0);
        check(FIFO0 == 0x9100EEEEu && FIFO0 == 0u,
              "MMIO elem-1 access fault popped elem 0 only",
              0,
              0,
              0);
    }

    /* 3b. Sv39 + Svpbmt NC/IO: mapped low BRAM, mapped FIFO0/1 (IO), mapped DDR (NC/IO),
     *     permissions, misaligned rules, and mixed cached DDR -> uncached BRAM page crossing */
    {
        volatile uint64_t *root = (volatile uint64_t *) PT_ROOT;
        volatile uint64_t *l1 = (volatile uint64_t *) PT_L1;
        volatile uint64_t *l0 = (volatile uint64_t *) PT_L0;
        for (unsigned i = 0; i < 512u; i++) {
            root[i] = 0;
            l1[i] = 0;
            l0[i] = 0;
        }
        root[0] = PTE_PPN(PT_L1) | PTE_V;
        l1[2] = PTE_PPN(PT_L0) | PTE_V; /* VA_BASE = 0x400000 */

        unsigned long bram_page_pa = BRAM_PAGE_PA;
        /* Page 0: Cached DDR (PMA)
         * Page 1: Low BRAM (PMA) -> tests mixed cached Page 0 -> uncached Page 1 crossing!
         * Page 2: Low BRAM with Svpbmt NC (PBMT=1)
         * Page 3: MMIO page 0x40000000 with Svpbmt IO (PBMT=2), S RW (U=0)
         * Page 4: MMIO page 0x40000000 with Svpbmt IO (PBMT=2), S RO (W=0)
         * Page 5: DDR frame with Svpbmt NC (PBMT=1)
         * Page 6: DDR frame with Svpbmt IO (PBMT=2)
         * Page 8: Low BRAM (PMA) -> Page 9: unmapped (FoF crossing) */
        l0[0] = PTE_PPN(DDR_FRAMES + 0u * 4096u) | PTE_V | PTE_R | PTE_W | PTE_A | PTE_D;
        l0[1] = PTE_PPN(bram_page_pa) | PTE_V | PTE_R | PTE_W | PTE_A | PTE_D;
        l0[2] = PTE_PPN(bram_page_pa) | PTE_PBMT_NC | PTE_V | PTE_R | PTE_W | PTE_A | PTE_D;
        l0[3] = PTE_PPN(0x40000000ul) | PTE_PBMT_IO | PTE_V | PTE_R | PTE_W | PTE_A | PTE_D;
        l0[4] = PTE_PPN(0x40000000ul) | PTE_PBMT_IO | PTE_V | PTE_R | PTE_A;
        l0[5] = PTE_PPN(DDR_FRAMES + 1u * 4096u) | PTE_PBMT_NC | PTE_V | PTE_R | PTE_W | PTE_A |
                PTE_D;
        l0[6] = PTE_PPN(DDR_FRAMES + 2u * 4096u) | PTE_PBMT_IO | PTE_V | PTE_R | PTE_W | PTE_A |
                PTE_D;
        l0[8] = PTE_PPN(bram_page_pa) | PTE_V | PTE_R | PTE_W | PTE_A | PTE_D;
        l0[9] = 0ul;

        csr_set(0x30A, MENVCFG_PBMTE); /* menvcfg.PBMTE = 1 */
        __asm__ volatile("fence rw, rw\n csrw satp, %0\n sfence.vma"
                         :
                         : "r"(SATP_SV39 | (PT_ROOT >> 12))
                         : "memory");

        /* Mixed cached Page 0 (DDR) -> uncached Page 1 (low BRAM) unit-stride & segment */
        volatile uint32_t *p0_end = (volatile uint32_t *) (DDR_FRAMES + 4096u - 8u);
        volatile uint32_t *p1_start = (volatile uint32_t *) bram_page_pa;
        p0_end[0] = 0x11110001u;
        p0_end[1] = 0x11110002u;
        p1_start[0] = 0x22220003u;
        p1_start[1] = 0x22220004u;
        setvl(4, VT_VTYPE(VT_E32, VT_M1));
        RUN_MPRV_1(MPRV_S_ON, ".insn r 0x07, 6, 0x01, x8, %0, x0", VA_BASE + 4096u - 8u);
        check(g_cause == ~0ul, "Sv39 cached->BRAM unit vle32", 0, g_cause, ~0ul);
        store_v8_group(dump32);
        check(dump32[0] == 0x11110001u && dump32[1] == 0x11110002u && dump32[2] == 0x22220003u &&
                  dump32[3] == 0x22220004u,
              "Sv39 cached->BRAM unit vle32 data",
              dump32[1],
              dump32[2],
              0x22220003u);

        /* Segment vlseg4e32 crossing cached Page 0 -> uncached low-BRAM Page 1 */
        setvl(1, VT_VTYPE(VT_E32, VT_M1));
        RUN_MPRV_1(MPRV_S_ON, ".insn r 0x07, 6, 0x31, x8, %0, x0", VA_BASE + 4096u - 8u);
        check(g_cause == ~0ul, "Sv39 cached->BRAM vlseg4e32", 0, g_cause, ~0ul);
        store_v8_group(dump32);
        uint32_t sf0 = ((volatile uint32_t *) ((volatile uint8_t *) dump32 + 0 * g_vlenb))[0];
        uint32_t sf1 = ((volatile uint32_t *) ((volatile uint8_t *) dump32 + 1 * g_vlenb))[0];
        uint32_t sf2 = ((volatile uint32_t *) ((volatile uint8_t *) dump32 + 2 * g_vlenb))[0];
        uint32_t sf3 = ((volatile uint32_t *) ((volatile uint8_t *) dump32 + 3 * g_vlenb))[0];
        check(sf0 == 0x11110001u && sf1 == 0x11110002u && sf2 == 0x22220003u && sf3 == 0x22220004u,
              "Sv39 cached->BRAM vlseg4e32 data",
              sf2,
              sf3,
              0x22220004u);

        /* Svpbmt NC over low BRAM (Page 2): aligned succeeds, misaligned raises cause 4 */
        p1_start[0] = 0x33330001u;
        p1_start[1] = 0x33330002u;
        setvl(2, VT_VTYPE(VT_E32, VT_M1));
        RUN_MPRV_1(MPRV_S_ON, ".insn r 0x07, 6, 0x01, x8, %0, x0", VA_BASE + 2u * 4096u);
        store_v8_group(dump32);
        check(g_cause == ~0ul && dump32[0] == 0x33330001u && dump32[1] == 0x33330002u,
              "Svpbmt NC low BRAM aligned vle32",
              dump32[0],
              g_cause,
              ~0ul);
        RUN_MPRV_1(MPRV_S_ON, ".insn r 0x07, 6, 0x01, x8, %0, x0", VA_BASE + 2u * 4096u + 2u);
        check(g_cause == CAUSE_LOAD_MISALIGN && g_tval == VA_BASE + 2u * 4096u + 2u,
              "Svpbmt NC low BRAM misaligned raises cause 4",
              g_tval,
              g_cause,
              CAUSE_LOAD_MISALIGN);
        wr_vstart(0);

        /* Svpbmt IO over MMIO FIFO0/1 (Page 3 RW, Page 4 RO, U-mode perm fault) */
        FIFO0 = 0x44440001u;
        FIFO0 = 0x44440002u;
        FIFO0 = 0x4444EEEEu;
        setvl(2, VT_VTYPE(VT_E32, VT_M1));
        /* U-mode on S-only Page 3: page fault (13) with ZERO FIFO0 pops */
        RUN_MPRV_2(MPRV_U_ON, ".insn r 0x07, 6, 0x05, x8, %0, %1", VA_BASE + 3u * 4096u + 8u, 0l);
        check(g_cause == CAUSE_LOAD_PAGE && g_tval == VA_BASE + 3u * 4096u + 8u,
              "Svpbmt IO FIFO0 U-mode page fault",
              g_tval,
              g_cause,
              CAUSE_LOAD_PAGE);
        wr_vstart(0);
        /* S-mode store to RO Page 4: store page fault (15) */
        RUN_MPRV_2(MPRV_S_ON, ".insn r 0x27, 6, 0x05, x8, %0, %1", VA_BASE + 4u * 4096u + 8u, 0l);
        check(g_cause == CAUSE_STORE_PAGE && g_tval == VA_BASE + 4u * 4096u + 8u,
              "Svpbmt IO FIFO0 RO store page fault",
              g_tval,
              g_cause,
              CAUSE_STORE_PAGE);
        wr_vstart(0);
        /* S-mode load on RW Page 3 succeeds and pops 1, 2 (sentinel intact) */
        RUN_MPRV_2(MPRV_S_ON, ".insn r 0x07, 6, 0x05, x8, %0, %1", VA_BASE + 3u * 4096u + 8u, 0l);
        store_v8_group(dump32);
        uint32_t rem = FIFO0;
        check(g_cause == ~0ul && dump32[0] == 0x44440001u && dump32[1] == 0x44440002u &&
                  rem == 0x4444EEEEu && FIFO0 == 0u,
              "Svpbmt IO FIFO0 S-mode stride-0 vlse32",
              dump32[0],
              rem,
              0x4444EEEEu);

        /* Svpbmt NC (Page 5) & IO (Page 6) over DDR alias: aligned succeeds, misaligned -> cause 5/7 */
        volatile uint32_t *f1 = (volatile uint32_t *) (DDR_FRAMES + 1u * 4096u);
        volatile uint32_t *f2 = (volatile uint32_t *) (DDR_FRAMES + 2u * 4096u);
        f1[0] = 0x55550001u;
        f1[1] = 0x55550002u;
        f2[0] = 0x66660001u;
        f2[1] = 0x66660002u;
        __asm__ volatile("fence iorw, iorw" ::: "memory");
        cbo_flush_line((unsigned long) f1);
        cbo_flush_line((unsigned long) f2);
        __asm__ volatile("fence iorw, iorw" ::: "memory");
        setvl(2, VT_VTYPE(VT_E32, VT_M1));
        RUN_MPRV_1(MPRV_S_ON, ".insn r 0x07, 6, 0x01, x8, %0, x0", VA_BASE + 5u * 4096u);
        store_v8_group(dump32);
        check(g_cause == ~0ul && dump32[0] == 0x55550001u && dump32[1] == 0x55550002u,
              "Svpbmt NC DDR alias aligned vle32",
              dump32[0],
              dump32[1],
              0x55550002u);
        RUN_MPRV_1(MPRV_S_ON, ".insn r 0x07, 6, 0x01, x8, %0, x0", VA_BASE + 6u * 4096u);
        store_v8_group(dump32);
        check(g_cause == ~0ul && dump32[0] == 0x66660001u && dump32[1] == 0x66660002u,
              "Svpbmt IO DDR alias aligned vle32",
              dump32[0],
              dump32[1],
              0x66660002u);
        RUN_MPRV_1(MPRV_S_ON, ".insn r 0x07, 6, 0x01, x8, %0, x0", VA_BASE + 6u * 4096u + 2u);
        check(g_cause == CAUSE_LOAD_ACCESS && g_tval == VA_BASE + 6u * 4096u + 2u,
              "Svpbmt IO DDR alias misaligned raises cause 5",
              g_tval,
              g_cause,
              CAUSE_LOAD_ACCESS);
        wr_vstart(0);

        /* Sv39 FoF crossing mapped low-BRAM Page 8 -> unmapped Page 9 trims vl to 2 */
        setvl(4, VT_VTYPE(VT_E32, VT_M1));
        RUN_MPRV_1(MPRV_S_ON, ".insn r 0x07, 6, 0x01, x8, %0, x16", VA_BASE + 9u * 4096u - 8u);
        check(g_cause == ~0ul && rd_vl() == 2ul && rd_vstart() == 0ul,
              "Sv39 BRAM->unmapped vle32ff trims vl=2",
              rd_vl(),
              g_cause,
              ~0ul);

        csr_clear(0x30A, MENVCFG_PBMTE);
        __asm__ volatile("csrw satp, zero\n sfence.vma" ::: "memory");
    }
}

/* ========================================================================== */
/* 4. Mid-run M-mode timer interrupt during uncached runs (BRAM, FIFO0, seg2) */
/* ========================================================================== */
static void run_trampoline_irq(uint32_t insn,
                               unsigned long base,
                               long stride,
                               uint64_t delta,
                               unsigned long expected_vl,
                               const char *label)
{
    g_tramp[0] = 0x30062073u; /* csrrs x0, mstatus, a2 (MIE) */
    g_tramp[1] = insn;
    g_tramp[2] = 0x00000013u; /* nop */
    g_tramp[3] = 0x30063073u; /* csrrc x0, mstatus, a2 (MIE) */
    g_tramp[4] = 0x00008067u; /* ret */
    __asm__ volatile("fence rw, rw\n fence.i" ::: "memory");

    /* Warm g_tramp in L1I with vl=0 and MIE=0 so the timed call has zero
     * instruction-miss jitter and zero memory or FIFO side effects. */
    unsigned long saved_vtype;
    __asm__ volatile("csrr %0, 0xC21" : "=r"(saved_vtype));
    (void) setvl(0, saved_vtype);
    {
        register unsigned long a0 __asm__("a0") = base;
        register long a1 __asm__("a1") = stride;
        register unsigned long a2 __asm__("a2") = 0ul;
        __asm__ volatile("jalr ra, 0(%3)"
                         : "+r"(a0), "+r"(a1), "+r"(a2)
                         : "r"((uintptr_t) g_tramp)
                         : "ra", "t0", "t1", "memory");
    }
    (void) setvl(expected_vl, saved_vtype);

    g_cause = ~0ul;
    g_irq_count = 0ul;
    g_irq_vstart = ~0ul;
    g_irq_mepc = 0ul;
    g_irq_vs = 0ul;
    g_irq_mode = 1;

    set_vs(VS_CLEAN);
    csr_set(mie, MIE_MTIE);
    arm_timer_delta(delta);

    {
        register unsigned long a0 __asm__("a0") = base;
        register long a1 __asm__("a1") = stride;
        register unsigned long a2 __asm__("a2") = MSTATUS_MIE;
        __asm__ volatile("jalr ra, 0(%3)"
                         : "+r"(a0), "+r"(a1), "+r"(a2)
                         : "r"((uintptr_t) g_tramp)
                         : "ra", "t0", "t1", "memory");
    }

    csr_clear(mstatus, MSTATUS_MIE);
    csr_clear(mie, MIE_MTIE);
    disarm_timer();
    g_irq_mode = 0;

    check(g_cause == ~0ul, label, 0, g_cause, ~0ul);
    check(g_irq_count >= 1ul && g_irq_mepc == (unsigned long) &g_tramp[1] &&
              g_irq_vstart > 0ul && g_irq_vstart < expected_vl && g_irq_vs == VS_DIRTY,
          label,
          g_irq_vstart,
          g_irq_mepc,
          (unsigned long) &g_tramp[1]);
}

static void test_mid_run_uncached_interrupts(void)
{
    volatile uint32_t *dump32 = (volatile uint32_t *) (vrf_io + 1024);
    unsigned long m16 = lmul_for_16_e32();
    unsigned long m8 = lmul_for_8_e32();
    drain_fifos();

    unsigned long irq_vs0 = 0ul, irq_vs1 = 0ul, irq_vs2 = 0ul;

    /* 4a. Mid-run MTI during stride-0 vlse32.v popping 16 words from FIFO0.
     *     Verify 0 < vstart < 16, exact values 0..15, and sentinel 16 untouched! */
    {
        for (unsigned i = 0; i < 17u; i++)
            FIFO0 = 0x77000000u + i;
        setvl(16, VT_VTYPE(VT_E32, m16));
        seed_v8(0x11u);
        /* vlse32.v v8, (a0), a1: mop=2, vm=1, rs2=x11(a1), rs1=x10(a0), width=6, vd=8 */
        uint32_t vlse32_a0_a1 = (2u << 26) | (1u << 25) | (11u << 20) | (10u << 15) | (6u << 12) |
                                (8u << 7) | 0x07u;
        run_trampoline_irq(vlse32_a0_a1, FIFO0_PA, 0l, 140u, 16u, "IRQ mid-run FIFO0 vlse32");
        irq_vs0 = g_irq_vstart;
        store_v8_group(dump32);
        for (unsigned i = 0; i < 16u; i++)
            check(dump32[i] == 0x77000000u + i,
                  "IRQ FIFO0 vlse32 element order",
                  i,
                  dump32[i],
                  0x77000000u + i);
        uint32_t sent = FIFO0;
        check(sent == 0x77000010u && FIFO0 == 0u,
              "IRQ FIFO0 vlse32 zero dup/lost pops",
              g_irq_vstart,
              sent,
              0x77000010u);
    }

    /* 4b. Mid-run MTI during unit-stride vle32.v (span-fallback!) on low BRAM */
    {
        volatile uint32_t *s32 = (volatile uint32_t *) bram_src;
        for (unsigned i = 0; i < 16u; i++)
            s32[i] = 0x88000000u + i;
        setvl(16, VT_VTYPE(VT_E32, m16));
        seed_v8(0x22u);
        /* vle32.v v8, (a0) */
        uint32_t vle32_a0 = (1u << 25) | (10u << 15) | (6u << 12) | (8u << 7) | 0x07u;
        run_trampoline_irq(vle32_a0, (unsigned long) s32, 0l, 140u, 16u, "IRQ mid-run BRAM vle32");
        irq_vs1 = g_irq_vstart;
        store_v8_group(dump32);
        for (unsigned i = 0; i < 16u; i++)
            check(dump32[i] == 0x88000000u + i,
                  "IRQ BRAM vle32 element",
                  i,
                  dump32[i],
                  0x88000000u + i);
    }

    /* 4c. Mid-run MTI during segment vlsseg2e32.v (stride 0, vl=8) on FIFO0/FIFO1.
     *     Interrupt must land on a segment boundary (not between field 0 and field 1),
     *     and both FIFO0 and FIFO1 must pop exactly 8 words with zero duplicates! */
    {
        for (unsigned i = 0; i < 9u; i++) {
            FIFO0 = 0x99000000u + i;
            FIFO1 = 0xAA000000u + i;
        }
        setvl(8, VT_VTYPE(VT_E32, m8));
        seed_v8(0x33u);
        /* vlsseg2e32.v v8, (a0), a1: nf=1, mop=2, vm=1, rs2=x11, rs1=x10, width=6, vd=8 */
        uint32_t vlsseg2_a0_a1 = (1u << 29) | (2u << 26) | (1u << 25) | (11u << 20) | (10u << 15) |
                                 (6u << 12) | (8u << 7) | 0x07u;
        run_trampoline_irq(vlsseg2_a0_a1, FIFO0_PA, 0l, 140u, 8u, "IRQ mid-run FIFO0/1 vlsseg2e32");
        irq_vs2 = g_irq_vstart;
        store_v8_group(dump32);
        unsigned long emul_stride = (m8 == VT_M2) ? (2u * g_vlenb) : g_vlenb;
        for (unsigned i = 0; i < 8u; i++) {
            uint32_t f0 = ((volatile uint32_t *) ((volatile uint8_t *) dump32 + 0))[i];
            uint32_t f1 = ((volatile uint32_t *) ((volatile uint8_t *) dump32 + emul_stride))[i];
            check(f0 == 0x99000000u + i && f1 == 0xAA000000u + i,
                  "IRQ FIFO0/1 vlsseg2e32 element",
                  i,
                  f0,
                  0x99000000u + i);
        }
        uint32_t s0 = FIFO0;
        uint32_t s1 = FIFO1;
        check(s0 == 0x99000008u && s1 == 0xAA000008u && FIFO0 == 0u && FIFO1 == 0u,
              "IRQ FIFO0/1 vlsseg2e32 zero dup/lost pops",
              s0,
              s1,
              0xAA000008u);
    }
    uart_printf("irq vstart: %lu %lu %lu\n", irq_vs0, irq_vs1, irq_vs2);
}

int main(void)
{
    disarm_timer();
    set_trap_handler(unified_trap_handler);
    set_vs(VS_INITIAL);
    __asm__ volatile("csrr %0, 0xC22" : "=r"(g_vlenb));
    uart_printf("vec_uncached_test VLEN=%lu\n", g_vlenb * 8ul);

    test_low_bram_all_forms();
    test_device_side_effects_and_order();
    test_faults_and_sv39_svpbmt();
    test_mid_run_uncached_interrupts();

    uart_printf("vec_uncached_test checks=%d %s\n", g_checks, g_ok ? "<<PASS>>" : "<<FAIL>>");
    for (;;) {
    }
    return 0;
}
