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
 * S-mode (supervisor privilege) directed test, Phase 3 M1.
 *
 * Exercises the Machine+Supervisor+User privilege architecture end-to-end on
 * the real core and self-checks over UART (<<PASS>> / <<FAIL>>). Two trap
 * handlers cooperate. The M handler (mtvec) records mcause and MPP, then
 * bounces to a continuation stashed in mscratch, the same mechanism
 * umode_test uses. The S handler (stvec) records scause, sepc, stval and SPP, then takes
 * one of two exits: it ecalls out to M, ending the case with mcause=9, or it
 * clears the firing sie bit and SRETs to resume the S body.
 *
 *   A. MRET with MPP=S enters S-mode: sstatus is readable there; the ending
 *      ecall reports cause 9 (ecall-from-S) with mstatus.MPP=S at M.
 *   B. Undelegated ecall-from-U -> M with mcause=8 (baseline against C).
 *   C. Delegated ecall-from-U (medeleg[8]=1) -> S handler: scause=8,
 *      sstatus.SPP=U, sepc=the U body; handler ecalls out (mcause=9).
 *   D. SRET round-trip: S drops to U via SRET with SPP=U preloaded, the U
 *      body ecalls, and with medeleg[8] still set the S handler takes it.
 *      That shows the SRET landed in U and the trap still routes to S.
 *   E. Delegated illegal-from-S (medeleg[2]=1): reading an M CSR from S
 *      traps to the S handler itself with scause=2 and SPP=S.
 *   F. TSR: with mstatus.TSR=1, SRET in S is an illegal instruction
 *      (mcause=2 at M; medeleg[2] cleared for this case).
 *   G. TVM: with mstatus.TVM=1, reading satp in S traps illegal (mcause=2);
 *      with TVM=0 the same read succeeds (case ends with ecall, cause 9).
 *   H. TVM gates SFENCE.VMA the same way; with TVM=0 SFENCE.VMA executes to
 *      completion in S (exercising its serialized fence machinery).
 *   I. SFENCE.VMA in U is illegal regardless (mcause=2).
 *   J. WFI in U is illegal (matches the pinned Spike: WFI requires S).
 *   K. TW: with TW=1, WFI in S is illegal (mcause=2); with TW=0 and a
 *      pending (masked) interrupt, WFI in S completes.
 *   L. Delegated supervisor timer interrupt: M injects mip.STIP with
 *      mideleg[STI]=1 and sie.STIE=1; entering S with sstatus.SIE=1 traps to
 *      the S handler (scause=INT|5), which clears sie.STIE and SRETs to
 *      resume the body. That covers S-side interrupt entry, sepc resume, and
 *      handler SRET.
 *  L2. The sstatus.SIE csrsi/csrci race: an interrupt made eligible by
 *      `csrsi sstatus,2` is still taken when the very next instruction
 *      clears SIE again.
 *   M. Undelegated supervisor software interrupt: mip.SSIP with
 *      mideleg[SSI]=0 and mie.SSIE=1 targets M, and is taken in M-mode with
 *      MIE=1 (mcause=INT|1).
 *   N. Machine timer interrupt preempts S-mode with MIE=0 (mcause=INT|7,
 *      from priv S): M-target interrupts always fire below M.
 *   O. sstatus is a strict view: with mstatus.MPIE/MPP set, sstatus read
 *      from S shows zeros in the M-only fields; SUM/MXR round-trip through
 *      sstatus writes.
 *   P. sie visibility follows mideleg: with mie.SSIE=1 but mideleg[SSI]=0,
 *      sie reads 0 in bit 1 and sie writes cannot set it; delegating makes
 *      the same bit visible/writable. sip.SSIP is S-writable when delegated.
 *   Q. scounteren chain: U-mode counter reads need mcounteren AND
 *      scounteren; S-mode reads need mcounteren only.
 *   R. Unimplemented CSRs trap illegal at every privilege (mcountinhibit
 *      0x320 from M; hpmcounter3 0xC03 from S).
 *   S. WARL: medeleg all-ones reads back the implemented mask 0xB3FF;
 *      mideleg all-ones reads back 0x222; mstatus.MPP write of the reserved
 *      encoding 2'b10 folds to U.
 *   T. Delegated ebreak from U (medeleg[3]=1): scause=3 and stval = the U
 *      body's address (breakpoint tval = faulting PC, steered to stval).
 *
 * Every S/U body ends in a trapping instruction, or spins until an injected
 * interrupt fires, so a missing gate fails with a recorded cause instead of
 * hanging.
 */

#include <stdint.h>

#include "trap.h"

/* ---- minimal UART (UART_TX is provided by mmio.h via trap.h) ---- */
static void uart_putc(char c)
{
    UART_TX = (uint8_t) c;
}

static void uart_puts(const char *s)
{
    while (*s)
        uart_putc(*s++);
}

static void uart_hex(unsigned long v)
{
    static const char hex[] = "0123456789ABCDEF";
    uart_puts("0x");
    for (int i = (int) (sizeof(unsigned long) * 8) - 4; i >= 0; i -= 4)
        uart_putc(hex[(v >> i) & 0xF]);
}

/* ---- trap state shared with the naked handlers ---- */
static volatile unsigned long g_cause;   /* M handler: mcause */
static volatile uint32_t g_from_priv;    /* M handler: mstatus.MPP */
static volatile unsigned long g_s_cause; /* S handler: scause */
static volatile unsigned long g_s_epc;   /* S handler: sepc */
static volatile unsigned long g_s_tval;  /* S handler: stval */
static volatile uint32_t g_s_spp;        /* S handler: sstatus.SPP */
static volatile uint32_t g_s_resume;     /* S handler mode: 1 = clear
                                          * sie.STIE/SSIE and SRET-resume;
                                          * 0 = ecall out to M */
static volatile uint32_t g_s_trap_seen;  /* set by the S handler */

#define LREG "ld"
#define SREG "sd"

/*
 * Naked M-mode trap handler. Records mcause and the trapping privilege once
 * per case, pushes mtimecmp to max so a timer interrupt cannot refire, clears
 * the injected software-pending bits, and returns to M-mode at the
 * continuation stashed in mscratch.
 */
__attribute__((naked, aligned(4))) static void m_trap_handler(void)
{
    __asm__ volatile("csrr t0, mcause\n"
                     "la   t1, g_cause\n" LREG " t2, 0(t1)\n"
                     "li   t3, -1\n" /* only the FIRST trap of each case records */
                     "bne  t2, t3, 2f\n" SREG " t0, 0(t1)\n"
                     "csrr t0, mstatus\n"
                     "srli t0, t0, 11\n"
                     "andi t0, t0, 0x3\n" /* mstatus.MPP */
                     "la   t1, g_from_priv\n"
                     "sw   t0, 0(t1)\n"
                     "2:\n"
                     "li   t1, 0x4000001C\n" /* MTIMECMP_HI: ack any timer */
                     "li   t0, -1\n"
                     "sw   t0, 0(t1)\n"
                     "li   t0, 0x222\n" /* drop injected S software-pending bits */
                     "csrc mip, t0\n"
                     "csrr t0, mscratch\n" /* M-mode continuation */
                     "csrw mepc, t0\n"
                     "li   t0, 0x1800\n" /* MPP = M */
                     "csrs mstatus, t0\n"
                     "mret\n");
}

/*
 * Naked S-mode trap handler. Records scause/sepc/stval/SPP once per case,
 * then takes one of two exits. With g_s_resume set, as in the interrupt
 * cases, it clears sie.STIE and sie.SSIE so the source cannot refire and SRETs back to
 * the S body. Otherwise it ecalls out to M, ending the case with cause 9.
 */
__attribute__((naked, aligned(4))) static void s_trap_handler(void)
{
    __asm__ volatile("csrr t0, scause\n"
                     "la   t1, g_s_cause\n" LREG " t2, 0(t1)\n"
                     "li   t3, -1\n"
                     "bne  t2, t3, 2f\n" SREG " t0, 0(t1)\n"
                     "csrr t0, sepc\n"
                     "la   t1, g_s_epc\n" SREG " t0, 0(t1)\n"
                     "csrr t0, stval\n"
                     "la   t1, g_s_tval\n" SREG " t0, 0(t1)\n"
                     "csrr t0, sstatus\n"
                     "srli t0, t0, 8\n"
                     "andi t0, t0, 0x1\n" /* sstatus.SPP */
                     "la   t1, g_s_spp\n"
                     "sw   t0, 0(t1)\n"
                     "li   t0, 1\n"
                     "la   t1, g_s_trap_seen\n"
                     "sw   t0, 0(t1)\n"
                     "2:\n"
                     "la   t1, g_s_resume\n"
                     "lw   t0, 0(t1)\n"
                     "beqz t0, 3f\n"
                     "li   t0, 0x22\n" /* sie.STIE|sie.SSIE: prevent refire */
                     "csrc sie, t0\n"
                     "sret\n" /* resume the S body at sepc */
                     "3:\n"
                     "ecall\n" /* end the case: cause 9 at M */
                     "j    .\n");
}

/*
 * Enter privilege `mpp` (2'b01 = S, 2'b00 = U) at fn; the M handler returns
 * control to the instruction after the MRET. Returns mcause of the trap that
 * ended the case.
 */
static unsigned long run_at_priv(void (*fn)(void), unsigned long mpp)
{
    g_cause = ~0ul;
    g_from_priv = 0xFFFFFFFFu;
    __asm__ volatile("la   t0, 1f\n"
                     "csrw mscratch, t0\n"
                     "li   t0, 0x1800\n"
                     "csrc mstatus, t0\n" /* MPP = U */
                     "slli t1, %1, 11\n"
                     "csrs mstatus, t1\n" /* MPP |= mpp */
                     "csrw mepc, %0\n"
                     "mret\n"
                     "1:\n"
                     :
                     : "r"(fn), "r"(mpp)
                     : "t0", "t1", "t2", "t3", "t4", "t5", "t6", "memory");
    return g_cause;
}

static void reset_s_record(void)
{
    g_s_cause = ~0ul;
    g_s_epc = 0;
    g_s_tval = ~0ul;
    g_s_spp = 0xFFFFFFFFu;
    g_s_trap_seen = 0;
    g_s_resume = 0;
}

/* ---- S/U test bodies: naked, no prologue. Each ends in a trapping
 *      instruction, or spins until an injected interrupt fires, so a
 *      missing gate fails rather than hangs. */
__attribute__((naked)) static void b_ecall(void)
{
    __asm__ volatile("ecall\n j .");
}

__attribute__((naked)) static void b_spin(void)
{
    __asm__ volatile("j .");
}

__attribute__((naked)) static void b_read_sstatus_then_ecall(void)
{
    __asm__ volatile("csrr t0, sstatus\n ecall\n j .");
}

__attribute__((naked)) static void b_read_mstatus(void)
{
    /* Illegal below M (cause 2); trailing ecall is the fallback. */
    __asm__ volatile("csrr t0, mstatus\n ecall\n j .");
}

__attribute__((naked)) static void b_sret(void)
{
    /* SRET: with TSR=1 in S this is illegal, and the ecall is the fallback.
     * For the legal round-trip case the caller preloads SPP=U. */
    __asm__ volatile("sret\n ecall\n j .");
}

__attribute__((naked)) static void b_read_satp(void)
{
    __asm__ volatile("csrr t0, satp\n ecall\n j .");
}

__attribute__((naked)) static void b_sfence_vma(void)
{
    __asm__ volatile("sfence.vma\n ecall\n j .");
}

__attribute__((naked)) static void b_wfi(void)
{
    __asm__ volatile("wfi\n ecall\n j .");
}

__attribute__((naked)) static void b_ebreak(void)
{
    __asm__ volatile("ebreak\n ecall\n j .");
}

__attribute__((naked)) static void b_read_cycle(void)
{
    __asm__ volatile("csrr t0, cycle\n ecall\n j .");
}

__attribute__((naked)) static void b_read_hpm3(void)
{
    /* hpmcounter3 (0xC03) is unimplemented -> illegal at any privilege. */
    __asm__ volatile("csrr t0, 0xC03\n ecall\n j .");
}

/* S body for the delegated-interrupt resume case (L). The wfi parks until the
 * injected STIP wakes it; a pending bit wakes WFI regardless of the enables.
 * The delegated STI traps to the S handler, which SRETs back here, and the
 * ecall ends the case. If the interrupt never fires the wfi still completes,
 * because STIP is pending, and the case fails on g_s_trap_seen. */
__attribute__((naked)) static void b_wfi_then_ecall(void)
{
    __asm__ volatile("wfi\n ecall\n j .");
}

/* S body for the sstatus.SIE csrsi/csrci race (L2), the S-mode analog of the
 * M-mode lost-tick hold. With a delegated STIP already pending and sie.STIE
 * set, `csrsi sstatus,2` makes the interrupt eligible at an instruction
 * boundary that the immediately following `csrci sstatus,2` is younger than,
 * so the trap has to be taken even though the live global enable has dropped
 * by the time the registered take fires. The csrci is squashed and
 * re-executed after the handler. The handler runs in resume mode: it records,
 * clears sie.STIE, and SRETs, and the ecall ends the case. A lost tick leaves
 * g_s_trap_seen=0. */
__attribute__((naked)) static void b_sie_toggle_race(void)
{
    __asm__ volatile("csrsi sstatus, 0x2\n"
                     "csrci sstatus, 0x2\n"
                     "ecall\n j .");
}

/* S body for view checks (O): capture sstatus and sie into globals. */
static volatile unsigned long g_seen_sstatus;
static volatile unsigned long g_seen_sie;
__attribute__((naked)) static void b_capture_views(void)
{
    __asm__ volatile("csrr t0, sstatus\n"
                     "la   t1, g_seen_sstatus\n" SREG " t0, 0(t1)\n"
                     "csrr t0, sie\n"
                     "la   t1, g_seen_sie\n" SREG " t0, 0(t1)\n"
                     "ecall\n j .");
}

/* S body for sie/sip write-through checks (P): try to set sie.SSIP/sip.SSIP
 * from S and capture what reads back. */
static volatile unsigned long g_seen_sie_after;
static volatile unsigned long g_seen_sip_after;
__attribute__((naked)) static void b_poke_sie_sip(void)
{
    __asm__ volatile("li   t0, 0x2\n"
                     "csrs sie, t0\n"
                     "csrr t0, sie\n"
                     "la   t1, g_seen_sie_after\n" SREG " t0, 0(t1)\n"
                     "li   t0, 0x2\n"
                     "csrs sip, t0\n"
                     "csrr t0, sip\n"
                     "la   t1, g_seen_sip_after\n" SREG " t0, 0(t1)\n"
                     "li   t0, 0x2\n"
                     "csrc sip, t0\n" /* drop the self-injected SSIP again */
                     "csrc sie, t0\n"
                     "ecall\n j .");
}

/* S body for SUM/MXR round-trip through sstatus (O). */
static volatile unsigned long g_seen_sum_mxr;
__attribute__((naked)) static void b_poke_sum_mxr(void)
{
    __asm__ volatile("li   t0, 0xC0000\n" /* SUM|MXR */
                     "csrs sstatus, t0\n"
                     "csrr t1, sstatus\n"
                     "csrc sstatus, t0\n"
                     "csrr t2, sstatus\n"
                     "and  t1, t1, t0\n" /* set-phase view of SUM|MXR */
                     "and  t2, t2, t0\n" /* cleared-phase view (want 0) */
                     "or   t1, t1, t2\n"
                     "la   t3, g_seen_sum_mxr\n" SREG " t1, 0(t3)\n"
                     "ecall\n j .");
}

static int report(const char *name, unsigned long got, unsigned long want)
{
    int ok = (got == want);
    uart_puts(ok ? "[PASS] " : "[FAIL] ");
    uart_puts(name);
    uart_puts(" got=");
    uart_hex(got);
    uart_puts(" want=");
    uart_hex(want);
    uart_puts("\r\n");
    return ok;
}

#define MCAUSE_INT_BIT (1ul << 63)
#define PRIV_U 0ul
#define PRIV_S 1ul

int main(void)
{
    int all_ok = 1;
    unsigned long cause;

    uart_puts("\r\n=== S-mode privilege test ===\r\n");
    set_trap_handler(&m_trap_handler);
    csr_write(stvec, (unsigned long) &s_trap_handler);
    csr_write(medeleg, 0);
    csr_write(mideleg, 0);
    reset_s_record();

    /* A: MRET to S; sstatus readable there; ecall-from-S -> mcause 9, MPP=S */
    cause = run_at_priv(&b_read_sstatus_then_ecall, PRIV_S);
    all_ok &= report("A ecall-from-S", cause, 9u);
    all_ok &= report("A from-priv", g_from_priv, 1u);

    /* B: undelegated ecall-from-U -> mcause 8 at M */
    cause = run_at_priv(&b_ecall, PRIV_U);
    all_ok &= report("B ecall-from-U-undelegated", cause, 8u);
    all_ok &= report("B from-priv", g_from_priv, 0u);

    /* C: delegated ecall-from-U -> S handler (scause 8, SPP=U), which ecalls
     * out (mcause 9 from S). */
    csr_write(medeleg, 1u << 8);
    reset_s_record();
    cause = run_at_priv(&b_ecall, PRIV_U);
    all_ok &= report("C mcause-after-s-handler", cause, 9u);
    all_ok &= report("C scause", g_s_cause, 8u);
    all_ok &= report("C s-spp", g_s_spp, 0u);
    all_ok &= report("C sepc", g_s_epc, (unsigned long) &b_ecall);

    /* D: SRET round-trip. Enter S at b_sret with sstatus.SPP preloaded U and
     * sepc pointing at the U ecall body; the SRET drops to U; the delegated
     * ecall lands in the S handler (scause 8) and ends via M (mcause 9). */
    reset_s_record();
    csr_clear(sstatus, 1u << 8); /* SPP = U */
    csr_write(sepc, (unsigned long) &b_ecall);
    cause = run_at_priv(&b_sret, PRIV_S);
    all_ok &= report("D sret-to-U-then-delegated-ecall", cause, 9u);
    all_ok &= report("D scause", g_s_cause, 8u);
    all_ok &= report("D s-spp", g_s_spp, 0u);

    /* E: delegated illegal-from-S: M-CSR read in S with medeleg[2]=1 traps
     * to the S handler itself (scause 2, SPP=S). */
    csr_write(medeleg, 1u << 2);
    reset_s_record();
    cause = run_at_priv(&b_read_mstatus, PRIV_S);
    all_ok &= report("E delegated-illegal-from-S", cause, 9u);
    all_ok &= report("E scause", g_s_cause, 2u);
    all_ok &= report("E s-spp", g_s_spp, 1u);
    csr_write(medeleg, 0);

    /* F: TSR traps SRET in S (illegal, mcause 2 at M). */
    csr_set(mstatus, 1ul << 22); /* TSR */
    reset_s_record();
    csr_clear(sstatus, 1u << 8);
    csr_write(sepc, (unsigned long) &b_ecall);
    cause = run_at_priv(&b_sret, PRIV_S);
    all_ok &= report("F tsr-traps-sret", cause, 2u);
    csr_clear(mstatus, 1ul << 22);

    /* G: TVM traps satp reads in S; without TVM the read succeeds. */
    csr_set(mstatus, 1ul << 20); /* TVM */
    cause = run_at_priv(&b_read_satp, PRIV_S);
    all_ok &= report("G tvm-traps-satp", cause, 2u);
    csr_clear(mstatus, 1ul << 20);
    cause = run_at_priv(&b_read_satp, PRIV_S);
    all_ok &= report("G satp-readable-in-S", cause, 9u);

    /* H: TVM gates SFENCE.VMA; without TVM it completes in S. */
    csr_set(mstatus, 1ul << 20);
    cause = run_at_priv(&b_sfence_vma, PRIV_S);
    all_ok &= report("H tvm-traps-sfence", cause, 2u);
    csr_clear(mstatus, 1ul << 20);
    cause = run_at_priv(&b_sfence_vma, PRIV_S);
    all_ok &= report("H sfence-completes-in-S", cause, 9u);

    /* I: SFENCE.VMA in U is illegal. */
    cause = run_at_priv(&b_sfence_vma, PRIV_U);
    all_ok &= report("I sfence-illegal-in-U", cause, 2u);

    /* J: WFI in U is illegal (matches the pinned Spike). */
    cause = run_at_priv(&b_wfi, PRIV_U);
    all_ok &= report("J wfi-illegal-in-U", cause, 2u);

    /* K: TW traps WFI in S; with TW=0 and a pending (disabled) software
     * interrupt, WFI in S completes and the ecall ends the case. */
    csr_set(mstatus, 1ul << 21); /* TW */
    cause = run_at_priv(&b_wfi, PRIV_S);
    all_ok &= report("K tw-traps-wfi-in-S", cause, 2u);
    csr_clear(mstatus, 1ul << 21);
    csr_set(mip, 1u << 1); /* SSIP pending (disabled: mie.SSIE=0) wakes WFI */
    cause = run_at_priv(&b_wfi, PRIV_S);
    all_ok &= report("K wfi-completes-in-S", cause, 9u);
    csr_clear(mip, 1u << 1);

    /* L: delegated supervisor timer interrupt with SRET resume. M injects
     * STIP, delegates STI, enables sie.STIE and sstatus.SIE, then enters S:
     * the S handler records scause=INT|5, clears sie.STIE, SRETs; the body's
     * wfi completes (STIP still pending) and the ecall ends the case. */
    csr_write(mideleg, 1u << 5);
    csr_set(mie, 1u << 5);     /* sie.STIE (shared storage) */
    csr_set(sstatus, 1u << 1); /* sstatus.SIE */
    csr_set(mip, 1u << 5);     /* inject STIP */
    reset_s_record();
    g_s_resume = 1;
    cause = run_at_priv(&b_wfi_then_ecall, PRIV_S);
    all_ok &= report("L delegated-sti-ends", cause, 9u);
    all_ok &= report("L scause", g_s_cause, MCAUSE_INT_BIT | 5ul);
    all_ok &= report("L s-trap-seen", g_s_trap_seen, 1u);
    g_s_resume = 0;
    csr_clear(mip, 1u << 5);
    csr_write(mideleg, 0);
    csr_clear(sstatus, 1u << 1);

    /* L2: the sstatus.SIE csrsi/csrci race. An interrupt made eligible by
     * csrsi has to survive the immediately following csrci, the S-mode analog
     * of the M-mode held-tick contract. Enter S with SIE=0; the body toggles
     * SIE around nothing. */
    csr_write(mideleg, 1u << 5);
    csr_set(mie, 1u << 5);
    csr_clear(sstatus, 1u << 1);
    csr_set(mip, 1u << 5); /* STIP pending before entry */
    reset_s_record();
    g_s_resume = 1;
    cause = run_at_priv(&b_sie_toggle_race, PRIV_S);
    all_ok &= report("L2 sie-toggle-race-ends", cause, 9u);
    all_ok &= report("L2 held-tick-taken", g_s_trap_seen, 1u);
    all_ok &= report("L2 scause", g_s_cause, MCAUSE_INT_BIT | 5ul);
    g_s_resume = 0;
    csr_clear(mip, 1u << 5);
    csr_write(mideleg, 0);
    csr_clear(mie, 1u << 5);
    csr_clear(sstatus, 1u << 1);

    /* M: an undelegated SSI targets M. With MIE=1 in M-mode, injecting SSIP
     * with mie.SSIE=1 traps immediately (mcause=INT|1). The M handler clears
     * the injected bit and bounces to the continuation. */
    csr_set(mie, 1u << 1); /* mie.SSIE */
    g_cause = ~0ul;
    g_from_priv = 0xFFFFFFFFu;
    __asm__ volatile("la   t0, 1f\n"
                     "csrw mscratch, t0\n"
                     "li   t0, 0x2\n"
                     "csrs mip, t0\n"       /* inject SSIP */
                     "csrsi mstatus, 0x8\n" /* MIE = 1 */
                     /* Interrupt entry is registered + armed (a few cycles);
                      * the 2-wide core retires ~2 nops/cycle, so give the
                      * take a wide window before MIE drops again. */
                     "nop\n nop\n nop\n nop\n nop\n nop\n nop\n nop\n"
                     "nop\n nop\n nop\n nop\n nop\n nop\n nop\n nop\n"
                     "nop\n nop\n nop\n nop\n nop\n nop\n nop\n nop\n"
                     "nop\n nop\n nop\n nop\n nop\n nop\n nop\n nop\n"
                     "1:\n"
                     "csrci mstatus, 0x8\n" ::
                         : "t0", "memory");
    all_ok &= report("M undelegated-ssi-to-M", g_cause, MCAUSE_INT_BIT | 1ul);
    csr_clear(mie, 1u << 1);

    /* N: machine timer preempts S-mode with MIE=0 (M-target interrupts always
     * fire below M); from-priv records S. */
    (void) disable_interrupts();
    csr_clear(mstatus, MSTATUS_MPIE);
    enable_timer_interrupt();
    set_timer_cmp(rdmtime() + 300);
    cause = run_at_priv(&b_spin, PRIV_S);
    all_ok &= report("N mti-preempts-S", cause, MCAUSE_INT_BIT | 7ul);
    all_ok &= report("N from-priv", g_from_priv, 1u);
    disable_timer_interrupt();

    /* O: sstatus is a strict view (M fields invisible) and SUM/MXR
     * round-trip through it. MPIE is set by the MRET sequence in
     * run_at_priv; MPP is nonzero while in S. */
    reset_s_record();
    cause = run_at_priv(&b_capture_views, PRIV_S);
    all_ok &= report("O view-case-ends", cause, 9u);
    all_ok &= report(
        "O sstatus-m-fields-zero", g_seen_sstatus & ((1ul << 3) | (1ul << 7) | (3ul << 11)), 0ul);
    reset_s_record();
    cause = run_at_priv(&b_poke_sum_mxr, PRIV_S);
    all_ok &= report("O sum-mxr-roundtrip-ends", cause, 9u);
    all_ok &= report("O sum-mxr-roundtrip", g_seen_sum_mxr, 0xC0000ul);

    /* P: sie/sip visibility follows mideleg. Undelegated: mie.SSIE=1 is
     * invisible through sie, and S cannot set sie.SSIE/sip.SSIP. Delegated:
     * both become visible and S-writable. */
    csr_write(mideleg, 0);
    csr_set(mie, 1u << 1); /* mie.SSIE=1, but not delegated */
    reset_s_record();
    cause = run_at_priv(&b_capture_views, PRIV_S);
    all_ok &= report("P undelegated-sie-invisible", g_seen_sie & 0x2ul, 0ul);
    reset_s_record();
    cause = run_at_priv(&b_poke_sie_sip, PRIV_S);
    all_ok &= report("P undelegated-sie-unwritable", g_seen_sie_after & 0x2ul, 0ul);
    all_ok &= report("P undelegated-sip-unwritable", g_seen_sip_after & 0x2ul, 0ul);
    csr_clear(mie, 1u << 1);
    csr_write(mideleg, 1u << 1); /* delegate SSI */
    reset_s_record();
    cause = run_at_priv(&b_poke_sie_sip, PRIV_S);
    all_ok &= report("P delegated-sie-writable", g_seen_sie_after & 0x2ul, 0x2ul);
    all_ok &= report("P delegated-sip-writable", g_seen_sip_after & 0x2ul, 0x2ul);
    csr_write(mideleg, 0);
    csr_clear(mie, 1u << 1); /* drop the S-side sie.SSIE write-through */

    /* Q: scounteren chain. U needs mcounteren AND scounteren; S needs
     * mcounteren only. */
    csr_write(mcounteren, 0x7u);
    csr_write(scounteren, 0x0u);
    cause = run_at_priv(&b_read_cycle, PRIV_U);
    all_ok &= report("Q u-gated-by-scounteren", cause, 2u);
    cause = run_at_priv(&b_read_cycle, PRIV_S);
    all_ok &= report("Q s-ignores-scounteren", cause, 9u);
    csr_write(scounteren, 0x7u);
    cause = run_at_priv(&b_read_cycle, PRIV_U);
    all_ok &= report("Q u-allowed-when-both", cause, 8u);
    csr_write(mcounteren, 0x0u);
    cause = run_at_priv(&b_read_cycle, PRIV_S);
    all_ok &= report("Q s-gated-by-mcounteren", cause, 2u);
    csr_write(mcounteren, 0x7u);

    /* R: unimplemented CSRs trap at every privilege. */
    g_cause = ~0ul;
    __asm__ volatile("la   t0, 1f\n"
                     "csrw mscratch, t0\n"
                     "csrr t0, 0x320\n" /* mcountinhibit: unimplemented */
                     "1:\n" ::
                         : "t0", "memory");
    all_ok &= report("R unimpl-csr-from-M", g_cause, 2u);
    cause = run_at_priv(&b_read_hpm3, PRIV_S);
    all_ok &= report("R unimpl-csr-from-S", cause, 2u);

    /* S: WARL masks and the MPP reserved-encoding fold. */
    csr_write(medeleg, ~0ul);
    all_ok &= report("S medeleg-warl", csr_read(medeleg), 0xB3FFul);
    csr_write(medeleg, 0);
    csr_write(mideleg, ~0ul);
    all_ok &= report("S mideleg-warl", csr_read(mideleg), 0x222ul);
    csr_write(mideleg, 0);
    csr_clear(mstatus, 3ul << 11);
    csr_set(mstatus, 2ul << 11); /* reserved MPP=2'b10 */
    all_ok &= report("S mpp-fold", (csr_read(mstatus) >> 11) & 0x3ul, 0ul);

    /* T: delegated ebreak from U: scause=3, stval = the body's address
     * (breakpoint tval = faulting PC, steered to the S side). */
    csr_write(medeleg, 1u << 3);
    reset_s_record();
    cause = run_at_priv(&b_ebreak, PRIV_U);
    all_ok &= report("T delegated-ebreak-ends", cause, 9u);
    all_ok &= report("T scause", g_s_cause, 3u);
    all_ok &= report("T stval", g_s_tval, (unsigned long) &b_ebreak);
    all_ok &= report("T sepc", g_s_epc, (unsigned long) &b_ebreak);
    csr_write(medeleg, 0);

    uart_puts(all_ok ? "\r\n<<PASS>>\r\n" : "\r\n<<FAIL>>\r\n");
    for (;;) {
    }
    return 0;
}
