/*
 *    Copyright (c) 2026 John Goodacre
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
 * Zawrs directed test. FROST completes wrs.nto and wrs.sto at once (the
 * stall is permitted, not required). The Zawrs chapter makes both available
 * in every privilege mode, and makes wrs.nto raise illegal-instruction below
 * M-mode when mstatus.TW=1 and it does not complete within the bounded time
 * limit; FROST's limit is zero, as for WFI. wrs.sto never traps.
 *
 * Cases: wrs.nto and wrs.sto in M, S and U with TW clear and set, with and
 * without a valid reservation from lr.d; then the Linux __cmpwait shape
 * (lr.d, compare, wrs.nto, loop) in S, which must return once the watched
 * word holds the expected value, and an SC after wrs.nto that still sees its
 * reservation.
 */

#include <stdint.h>

#include "trap.h"
#include "uart.h"

#define CAUSE_ILLEGAL 2ul
#define CAUSE_ECALL_U 8ul
#define CAUSE_ECALL_S 9ul
#define CAUSE_ECALL_M 11ul

#define MSTATUS_TW (1ul << 21)

static volatile unsigned long g_cause;
static volatile unsigned long g_a0;
static volatile uint64_t g_word __attribute__((aligned(64), section(".ddr_data")));

__attribute__((naked, aligned(4))) static void zawrs_trap_handler(void)
{
    __asm__ volatile("csrr t0, mcause\n"
                     "la   t1, g_cause\n"
                     "sd   t0, 0(t1)\n"
                     "la   t1, g_a0\n"
                     "sd   a0, 0(t1)\n"
                     "csrr t0, mscratch\n"
                     "csrw mepc, t0\n"
                     "li   t0, 0x1800\n"
                     "csrs mstatus, t0\n"
                     "mret\n");
}

/* a0 = address of a dword in cached DDR. */
#define BODY(name, insns)                                                                          \
    __attribute__((naked)) static void name(void)                                                  \
    {                                                                                              \
        __asm__ volatile(insns "ecall\n"                                                           \
                               "j .\n");                                                           \
    }

/* wrs.nto = 0x00d00073, wrs.sto = 0x01d00073 (the default -march has no
 * zawrs). */
#define WRS_NTO ".word 0x00d00073\n"
#define WRS_STO ".word 0x01d00073\n"
BODY(body_nto, WRS_NTO)
BODY(body_sto, WRS_STO)
BODY(body_lr_nto, "lr.d t0, (a0)\n" WRS_NTO)
BODY(body_lr_sto, "lr.d t0, (a0)\n" WRS_STO)
/* LR, wrs.nto, then SC to the same address: SC succeeds (a0 = 0) because
 * nothing broke the reservation. */
BODY(body_lr_nto_sc, "mv t1, a0\n lr.d t0, (t1)\n" WRS_NTO "addi t0, t0, 1\n sc.d a0, t0, (t1)\n")
/* Linux __cmpwait loop on a word that already differs from the expected old
 * value (a1): lr.d, xor, bnez exits at once; otherwise wrs.nto and retry,
 * bounded to 64 rounds (a0 = rounds left). */
BODY(body_cmpwait,
     "mv t1, a0\n li a0, 64\n"
     "1: lr.d t0, (t1)\n xor t0, t0, a1\n bnez t0, 2f\n" WRS_NTO "addi a0, a0, -1\n bnez a0, 1b\n"
     "2:\n")

static unsigned long
run_mode(unsigned long mpp, void (*body)(void), unsigned long a0, unsigned long a1)
{
    g_cause = ~0ul;
    g_a0 = ~0ul;
    __asm__ volatile("la   t0, 1f\n"
                     "csrw mscratch, t0\n"
                     "li   t0, 0x1800\n"
                     "csrc mstatus, t0\n"
                     "slli t0, %0, 11\n"
                     "csrs mstatus, t0\n"
                     "csrw mepc, %1\n"
                     "mv   a0, %2\n"
                     "mv   a1, %3\n"
                     "mret\n"
                     "1:\n"
                     :
                     : "r"(mpp), "r"((unsigned long) body), "r"(a0), "r"(a1)
                     : "t0", "t1", "t2", "t3", "a0", "a1", "memory");
    return g_cause;
}

static const unsigned long ecall_cause[4] = {CAUSE_ECALL_U, CAUSE_ECALL_S, 0, CAUSE_ECALL_M};
static const char *const mode_name[4] = {"U", "S", "?", "M"};

static int check(const char *name, unsigned long mpp, int tw, unsigned long want)
{
    int ok = g_cause == want;
    uart_puts(ok ? "[PASS] " : "[FAIL] ");
    uart_printf("%s mode=%s tw=%d cause=%lu want=%lu\r\n", name, mode_name[mpp], tw, g_cause, want);
    return ok;
}

int main(void)
{
    int ok = 1;
    static const struct {
        const char *name;
        void (*body)(void);
        int is_nto;
    } insns[] = {
        {"wrs.nto", body_nto, 1},
        {"wrs.sto", body_sto, 0},
        {"lr.d+wrs.nto", body_lr_nto, 1},
        {"lr.d+wrs.sto", body_lr_sto, 0},
    };

    uart_puts("\r\n=== Zawrs test ===\r\n");
    set_trap_handler(&zawrs_trap_handler);
    csr_write(medeleg, 0);
    g_word = 0x1234;

    for (int tw = 0; tw < 2; tw++) {
        if (tw)
            csr_set(mstatus, MSTATUS_TW);
        else
            csr_clear(mstatus, MSTATUS_TW);
        for (unsigned long mpp = 0; mpp < 4; mpp++) {
            if (mpp == 2)
                continue;
            for (unsigned i = 0; i < sizeof(insns) / sizeof(insns[0]); i++) {
                int traps = insns[i].is_nto && tw && mpp != 3;
                run_mode(mpp, insns[i].body, (unsigned long) &g_word, 0);
                ok &= check(insns[i].name, mpp, tw, traps ? CAUSE_ILLEGAL : ecall_cause[mpp]);
            }
        }
    }
    csr_clear(mstatus, MSTATUS_TW);

    /* The reservation survives wrs.nto: SC after it succeeds, in S and U. */
    for (unsigned long mpp = 0; mpp < 4; mpp++) {
        if (mpp == 2)
            continue;
        g_word = 0x40;
        run_mode(mpp, body_lr_nto_sc, (unsigned long) &g_word, 0);
        int sc_ok = g_cause == ecall_cause[mpp] && g_a0 == 0 && g_word == 0x41;
        uart_puts(sc_ok ? "[PASS] " : "[FAIL] ");
        uart_printf("lr.d+wrs.nto+sc.d mode=%s sc=%lu word=0x%lx\r\n",
                    mode_name[mpp],
                    g_a0,
                    (unsigned long) g_word);
        ok &= sc_ok;
    }

    /* __cmpwait: the word differs from the old value, so the loop exits on
     * the first compare; with the old value equal it spins through .word 0x00d00073
     * 64 times and exits on the bound (no hang, no trap). */
    g_word = 7;
    run_mode(1, body_cmpwait, (unsigned long) &g_word, 3);
    int cw_ok = g_cause == CAUSE_ECALL_S && g_a0 == 64;
    run_mode(1, body_cmpwait, (unsigned long) &g_word, 7);
    cw_ok &= g_cause == CAUSE_ECALL_S && g_a0 == 0;
    uart_puts(cw_ok ? "[PASS] " : "[FAIL] ");
    uart_puts("cmpwait loop in S\r\n");
    ok &= cw_ok;

    uart_puts(ok ? "\r\n<<PASS>>\r\n" : "\r\n<<FAIL>>\r\n");
    for (;;) {
    }
    return 0;
}
