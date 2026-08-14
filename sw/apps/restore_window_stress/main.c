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
 * M-mode ret_from_exception restore-window stress (directed, phase-swept).
 *
 * Faithful miniature of the Linux no-MMU kernel exit sequence that the
 * (since-retired) ret_from_exception binary patch — the mutation formerly
 * applied by what is now linux/buildroot-external/board/frost/
 * patch_linux_image.py — was introduced to protect; this regression is the
 * retirement evidence. Per iteration, with the machine timer phase swept so
 * ticks land at every cycle offset across the sequence (the shape follows
 * the rv64 kernel — ld/sc.d at 8-byte pt_regs stride, per the macros
 * below):
 *
 *   <MIE=1 region>            handler-tail analog: ticks become eligible here
 *   rw_irqoff:  csrci mstatus, 8        kernel IRQ-off before exit
 *               [lr.w t0, (frame)]      every other iteration: arm a dangling
 *                                       reservation so the SC really stores
 *               lw   a2, 0(frame)       PT_EPC load
 *   rw_sc:      sc.w x0, a2, (frame)    reservation-clear store (drains to DDR)
 *   rw_wincsr:  csrw mstatus, a0        image {MIE=0, MPIE=1, MPP=U|M}
 *   rw_winepc:  csrw mepc, a2
 *               lw   t1..t4, 4..16(frame)   register-restore DDR loads
 *   rw_mret:    mret                    -> U-pad (ecall back) or M-pad
 *   rw_winend:
 *
 * The frame lives in the cached DDR region and is evicted via an L1D-alias
 * store each iteration, so the SC/loads genuinely miss and the committed SC
 * drains slowly — the condition under which the June 2026 flaky boot hung.
 *
 * Trap-handler invariants checked on EVERY machine-timer tick:
 *   1. mstatus.MIE == 0 at handler entry (trap-entry contract; catches any
 *      path that could hand the kernel a restore image with MIE set).
 *   2. mepc is NOT strictly inside (rw_irqoff, rw_winend): after the csrci
 *      commits, MIE=0 makes every boundary up to and including the mret
 *      ineligible for machine-interrupt delivery in M-mode, and a delivery at
 *      the mret itself is exactly the mepc-clobber that produced the SIGILL at
 *      ret_from_exception+0x76. A held tick must instead deliver post-MRET
 *      (mepc = pad) via the mret_taken resume-PC seed / priv<M eligibility.
 * Plus: any illegal-instruction trap (the U-mode-executes-MRET signature) is
 * an immediate failure, and each iteration must reach its landing pad exactly
 * once. Every 8th iteration interleaves the kernel idle shape
 * (csrsi mstatus,8; wfi; csrci mstatus,8) with a due timer.
 *
 * PASS: all iterations complete, zero invariant hits, tick count confirms the
 * sweep actually exercised the window. FAIL prints forensics.
 */

#include <stdint.h>

#include "trap.h"

#ifndef N_ITER
#define N_ITER 800u
#endif

/* Cached-DDR frame: rotated across 64 line-spaced slots; the matching L1D
 * alias (+0x20000, 128 KiB direct-mapped) is dirtied each iteration to evict
 * the slot so next use misses cold and the SC write-back really drains.
 * Kept inside the sim DDR model's 64 MiB backing (offset 0x0280_0000). */
#define FRAME_BASE 0x82800000u
#define FRAME_ALIAS_XOR 0x20000u

/* XLEN split (D12). The window under test mirrors the kernel's
 * ret_from_exception, and the rv64 kernel restores with ld at the 8-byte
 * pt_regs stride and clears the reservation with sc.d, so the gadget follows
 * suit; the handler must likewise save/restore its temporaries at full width
 * or it corrupts the upper halves of the interrupted context. The mcause
 * compare needs the interrupt bit at XLEN-1. The uint32_t g_* counters
 * and the 32-bit CLINT MMIO accesses use lw/sw on purpose.
 */
#define XL "ld  "  /* XLEN register load                       */
#define XS "sd  "  /* XLEN register store                      */
#define XLR "lr.d" /* kernel-width reservation pair           */
#define XSC "sc.d"
#define XO0 "0" /* n * XLEN-byte frame offsets                */
#define XO1 "8"
#define XO2 "16"
#define XO3 "24"
#define XO4 "32"
#define XFRAME "48"   /* handler stack frame (5 saves, padded)  */
#define XAMO_OFF "48" /* AMO cell: clear of frame[0..4]       */
#define XMCAUSE_MTI "0x8000000000000007"
typedef uint64_t rw_word_t;

static void uart_putc(char c)
{
    UART_TX = (uint8_t) c;
}
static void uart_puts(const char *s)
{
    while (*s)
        uart_putc(*s++);
}
static void uart_hex(uint32_t v)
{
    static const char hex[] = "0123456789ABCDEF";
    uart_puts("0x");
    for (int i = 28; i >= 0; i -= 4)
        uart_putc(hex[(v >> i) & 0xF]);
}

volatile uint32_t g_iter;      /* progress marker for hang triage            */
volatile uint32_t g_irq;       /* machine-timer tick count                   */
volatile uint32_t g_irq_pad;   /* ticks delivered AT a landing pad: a tick
                                * that arose inside the MIE=0 window and was
                                * correctly held until after the MRET — the
                                * window-crossing mechanism under test        */
volatile uint32_t g_pad;       /* landing-pad executions                     */
volatile uint32_t g_fail;      /* invariant violations                       */
volatile uint32_t g_fail_mepc; /* first violation: offending mepc            */
volatile uint32_t g_fail_kind; /* 1=mepc-in-window 2=MIE-at-entry 3=illegal  */
volatile uint32_t g_fail_arg;  /* extra forensic word (mcause/mstatus)       */

/* Window boundary labels (defined in the gadget below). */
extern const char rw_irqoff[];
extern const char rw_winend[];

/*
 * M-mode trap handler. Timer ticks: check the two invariants, re-arm the
 * timer with a drifting period (712 + (g_irq & 0xFF)) so the phase sweeps,
 * and return to the interrupted context untouched. Ecall-from-U (the U-pad
 * handoff) and any failure bounce to the continuation stashed in mscratch
 * with MPP=M. Illegal instruction records forensics and bounces.
 */
__attribute__((naked, aligned(4))) static void rw_trap_handler(void)
{
    __asm__ volatile("addi sp, sp, -" XFRAME "\n" XS " t0, " XO0 "(sp)\n" XS " t1, " XO1 "(sp)\n" XS
                     " t2, " XO2 "(sp)\n" XS " t3, " XO3 "(sp)\n" XS " t4, " XO4 "(sp)\n"
                     "csrr t0, mcause\n"
                     "li   t1, " XMCAUSE_MTI "\n"
                     "beq  t0, t1, 1f\n" /* machine timer            */
                     "li   t1, 8\n"
                     "beq  t0, t1, 5f\n" /* ecall from U: pad handoff */
                     /* ---- unexpected synchronous trap (illegal instr = the signature) */
                     "lui  t1, %hi(g_fail)\n"
                     "lw   t2, %lo(g_fail)(t1)\n"
                     "addi t2, t2, 1\n"
                     "sw   t2, %lo(g_fail)(t1)\n"
                     "lui  t1, %hi(g_fail_kind)\n"
                     "li   t2, 3\n"
                     "sw   t2, %lo(g_fail_kind)(t1)\n"
                     "lui  t1, %hi(g_fail_arg)\n"
                     "sw   t0, %lo(g_fail_arg)(t1)\n"
                     "csrr t0, mepc\n"
                     "lui  t1, %hi(g_fail_mepc)\n"
                     "sw   t0, %lo(g_fail_mepc)(t1)\n"
                     "j    5f\n" /* bounce to continuation; C reports */
                     /* ---- machine timer ---- */
                     "1:\n"
                     /* Sweep-coverage counter: a delivery at a landing pad means the tick
                      * arose inside the MIE=0 window and was held until after the MRET. */
                     "csrr t1, mepc\n"
                     "la   t2, u_pad_start\n"
                     "bltu t1, t2, 7f\n"
                     "la   t2, pads_end\n"
                     "bgeu t1, t2, 7f\n"
                     "lui  t3, %hi(g_irq_pad)\n"
                     "lw   t4, %lo(g_irq_pad)(t3)\n"
                     "addi t4, t4, 1\n"
                     "sw   t4, %lo(g_irq_pad)(t3)\n"
                     "7:\n"
                     /* Invariant 2: mepc must not be strictly inside (rw_irqoff, rw_winend) */
                     "la   t2, rw_irqoff\n"
                     "bleu t1, t2, 2f\n" /* <= csrci: legal (enabled region)  */
                     "la   t2, rw_winend\n"
                     "bgeu t1, t2, 2f\n" /* >= post-mret label: legal          */
                     "lui  t3, %hi(g_fail)\n"
                     "lw   t4, %lo(g_fail)(t3)\n"
                     "addi t4, t4, 1\n"
                     "sw   t4, %lo(g_fail)(t3)\n"
                     "lui  t3, %hi(g_fail_kind)\n"
                     "li   t4, 1\n"
                     "sw   t4, %lo(g_fail_kind)(t3)\n"
                     "lui  t3, %hi(g_fail_mepc)\n"
                     "sw   t1, %lo(g_fail_mepc)(t3)\n"
                     "2:\n"
                     /* Invariant 1: mstatus.MIE must be 0 at handler entry */
                     "csrr t1, mstatus\n"
                     "andi t2, t1, 8\n"
                     "beqz t2, 3f\n"
                     "lui  t3, %hi(g_fail)\n"
                     "lw   t4, %lo(g_fail)(t3)\n"
                     "addi t4, t4, 1\n"
                     "sw   t4, %lo(g_fail)(t3)\n"
                     "lui  t3, %hi(g_fail_kind)\n"
                     "li   t4, 2\n"
                     "sw   t4, %lo(g_fail_kind)(t3)\n"
                     "lui  t3, %hi(g_fail_arg)\n"
                     "sw   t1, %lo(g_fail_arg)(t3)\n"
                     "3:\n"
                     /* re-arm: mtimecmp = mtime + 712 + (g_irq & 0xFF); g_irq++ */
                     "lui  t0, %hi(g_irq)\n"
                     "lw   t1, %lo(g_irq)(t0)\n"
                     "andi t2, t1, 0xFF\n"
                     "addi t2, t2, 712\n"
                     "addi t1, t1, 1\n"
                     "sw   t1, %lo(g_irq)(t0)\n"
                     "li   t0, 0x40000010\n" /* MTIME_LO */
                     "lw   t1, 0(t0)\n"
                     "add  t1, t1, t2\n"
                     "li   t0, 0x40000018\n" /* MTIMECMP_LO (HI pinned 0 in main) */
                     "sw   t1, 0(t0)\n" XL " t0, " XO0 "(sp)\n" XL " t1, " XO1 "(sp)\n" XL
                     " t2, " XO2 "(sp)\n" XL " t3, " XO3 "(sp)\n" XL " t4, " XO4 "(sp)\n"
                     "addi sp, sp, " XFRAME "\n"
                     "mret\n"
                     /* ---- bounce to the gadget continuation in M-mode ---- */
                     "5:\n"
                     "csrr t0, mscratch\n"
                     "csrw mepc, t0\n"
                     "li   t0, 0x1800\n"
                     "csrs mstatus, t0\n" /* MPP = M */
                     XL " t0, " XO0 "(sp)\n" XL " t1, " XO1 "(sp)\n" XL " t2, " XO2 "(sp)\n" XL
                     " t3, " XO3 "(sp)\n" XL " t4, " XO4 "(sp)\n"
                     "addi sp, sp, " XFRAME "\n"
                     "mret\n");
}

/* Landing pads, one naked function so [u_pad_start, pads_end) is a single
 * contiguous range the handler can classify mepc against.
 *   u_pad_start: U-mode pad — bump g_pad (no memory protection in M/U
 *                FROST), ecall back to M; the handler bounces on.
 *   m_pad_start: M-mode pad — bump g_pad, jump straight to the continuation.
 */
extern const char u_pad_start[];
extern const char m_pad_start[];
__attribute__((naked, aligned(4))) void pads(void)
{
    __asm__ volatile(".global u_pad_start\n"
                     "u_pad_start:\n"
                     "lui  t0, %hi(g_pad)\n"
                     "lw   t1, %lo(g_pad)(t0)\n"
                     "addi t1, t1, 1\n"
                     "sw   t1, %lo(g_pad)(t0)\n"
                     "ecall\n"
                     ".global m_pad_start\n"
                     "m_pad_start:\n"
                     "lui  t0, %hi(g_pad)\n"
                     "lw   t1, %lo(g_pad)(t0)\n"
                     "addi t1, t1, 1\n"
                     "sw   t1, %lo(g_pad)(t0)\n"
                     "csrr t0, mscratch\n"
                     "jr   t0\n"
                     ".global pads_end\n"
                     "pads_end:\n"
                     "nop\n");
}

/*
 * One restore-window iteration. a0 image = {MPIE=1, MPP per variant, MIE=0};
 * frame[0] holds the pad address ("PT_EPC"). arm_lr=1 issues an LR first so
 * the SC succeeds and its store genuinely drains; arm_lr=0 leaves the SC
 * failing like the kernel's usual dangling-reservation-free case.
 */
__attribute__((noinline)) static void
run_window(uint32_t image, volatile rw_word_t *frame, uint32_t arm_lr, uint32_t do_amo)
{
    __asm__ volatile("la   t0, 9f\n"
                     "csrw mscratch, t0\n" /* continuation for pads/handler   */
                     /* handler-tail analog: interrupts enabled, a little work */
                     "csrsi mstatus, 8\n"
                     "addi t1, x0, 7\n"
                     "slli t1, t1, 3\n"
                     "xor  t1, t1, t0\n"
                     "andi t1, t1, 255\n"
                     /* variant: a cached-region AMO with interrupts enabled, so swept
                      * ticks land while the AMO owns the ROB head and exercise the AMO
                      * interrupt shield's take-deferral right before the window */
                     "beqz %3, 8f\n"
                     "addi t1, %1, " XAMO_OFF "\n"
                     "amoswap.w t2, t1, (t1)\n"
                     "8:\n"
                     ".global rw_irqoff\n"
                     "rw_irqoff:\n"
                     "csrci mstatus, 8\n"                /* kernel IRQ-off before exit       */
                     "beqz  %2, 6f\n" XLR "  t1, (%1)\n" /* variant: arm dangling reservation */
                     "6:\n" XL " a2, " XO0 "(%1)\n"      /* PT_EPC                        */
                     ".global rw_sc\n"
                     "rw_sc:\n" XSC " x0, a2, (%1)\n" /* reservation-clear store          */
                     ".global rw_wincsr\n"
                     "rw_wincsr:\n"
                     "csrw mstatus, %0\n" /* image {MIE=0, MPIE=1, MPP=U|M}    */
                     ".global rw_winepc\n"
                     "rw_winepc:\n"
                     "csrw mepc, a2\n" XL " t1, " XO1 "(%1)\n" /* register-restore DDR loads    */
                     XL " t2, " XO2 "(%1)\n" XL " t3, " XO3 "(%1)\n" XL " t4, " XO4 "(%1)\n"
                     ".global rw_mret\n"
                     "rw_mret:\n"
                     "mret\n"
                     ".global rw_winend\n"
                     "rw_winend:\n"
                     "9:\n"
                     :
                     : "r"(image), "r"(frame), "r"(arm_lr), "r"(do_amo)
                     : "t0", "t1", "t2", "t3", "t4", "a2", "memory");
}

int main(void)
{
    uart_puts("\r\n=== restore-window stress ===\r\n");
    set_trap_handler(&rw_trap_handler);

    MTIMECMP_HI = 0;
    MTIMECMP_LO = (uint32_t) rdmtime() + 200;
    enable_timer_interrupt(); /* mie.MTIE; global MIE toggled per iteration */

    for (uint32_t i = 0; i < N_ITER; i++) {
        g_iter = i;
        uint32_t pad_before = g_pad;

        /* Rotate the frame across 64 line-spaced slots. Write it, then dirty
         * its L1D alias (same set, 128 KiB direct-mapped) so the just-written
         * frame line is EVICTED: its write-back drains to DDR and the window's
         * PT_EPC load + SC miss cold — and that refill in turn evicts the
         * dirty alias line, keeping a write-back draining inside the window. */
        volatile rw_word_t *frame = (volatile rw_word_t *) (FRAME_BASE + ((i & 63u) << 6));
        volatile rw_word_t *alias = (volatile rw_word_t *) ((uintptr_t) frame ^ FRAME_ALIAS_XOR);

        uint32_t to_umode = i & 1u;
        frame[0] =
            to_umode ? (rw_word_t) (uintptr_t) u_pad_start : (rw_word_t) (uintptr_t) m_pad_start;
        frame[1] = i;
        frame[2] = i ^ 0x55555555u;
        frame[3] = ~i;
        frame[4] = i * 3u;
        alias[0] = i;
        alias[4] = i ^ 0xA5A5A5A5u;

        /* Place the next tick at a finely swept offset around window entry
         * (the handler's own re-arm then keeps the phase drifting). */
        MTIMECMP_LO = (uint32_t) rdmtime() + 90u + ((i * 13u) & 0x1FFu);

        /* Every 8th iteration: kernel idle shape with a due timer. */
        if ((i & 7u) == 7u) {
            __asm__ volatile("csrsi mstatus, 8\n"
                             "wfi\n"
                             "csrci mstatus, 8\n" ::
                                 : "memory");
        }

        uint32_t image = 0x80u | (to_umode ? 0u : 0x1800u); /* MPIE | MPP */
        run_window(image, frame, (i >> 1) & 1u, (i & 3u) == 3u);

        if (g_pad != pad_before + 1u) {
            g_fail++;
            g_fail_kind = 4;
            g_fail_arg = g_pad - pad_before;
            break;
        }
        if (g_fail)
            break;
    }

    disable_timer_interrupt();
    uart_puts("iters=");
    uart_hex(g_iter);
    uart_puts(" irqs=");
    uart_hex(g_irq);
    uart_puts(" pad_irqs=");
    uart_hex(g_irq_pad);
    uart_puts(" pads=");
    uart_hex(g_pad);
    uart_puts("\r\n");
    /* The sweep must have really exercised the mechanism: demand ticks
     * overall AND held ticks delivered at the pads (window crossings). */
    if (g_fail == 0 && g_pad == N_ITER && g_irq >= (N_ITER / 4u) && g_irq_pad >= 8u) {
        uart_puts("<<PASS>>\r\n");
    } else {
        uart_puts("fail_kind=");
        uart_hex(g_fail_kind);
        uart_puts(" mepc=");
        uart_hex(g_fail_mepc);
        uart_puts(" arg=");
        uart_hex(g_fail_arg);
        uart_puts(" window=[");
        uart_hex((uint32_t) (uintptr_t) rw_irqoff);
        uart_puts(",");
        uart_hex((uint32_t) (uintptr_t) rw_winend);
        uart_puts("]\r\n<<FAIL>>\r\n");
    }
    for (;;) {
    }
    return 0;
}
