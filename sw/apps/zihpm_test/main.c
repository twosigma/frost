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
 * Zihpm directed test: the privilege gating of hpmcounter3..31.
 *
 * - hpmcounterN (N = 3..10) is a read-only shadow of mhpmcounterN: with the
 *   counter inhibited, a value written to mhpmcounterN reads back through
 *   hpmcounterN in M, S and U.
 * - S reads hpmcounterN only with mcounteren.HPMN set; U needs both
 *   mcounteren.HPMN and scounteren.HPMN. A blocked read raises
 *   illegal-instruction. M is never gated.
 * - Writes to hpmcounterN (a read-only CSR) are illegal in every mode;
 *   mhpmcounterN and mhpmeventN are M-only.
 * - mcounteren and scounteren bits 3..10 are writable (Sscounterenw), bits
 *   11..31 read zero; mhpmcounter11..31 and mhpmevent11..31 read zero and
 *   ignore writes; hpmcounter11..31 are unimplemented and illegal at every
 *   privilege (Zihpm permits either a trap or a constant).
 */

#include <stdint.h>

#include "trap.h"
#include "uart.h"

#define CAUSE_ILLEGAL 2ul
#define CAUSE_ECALL_U 8ul
#define CAUSE_ECALL_S 9ul
#define CAUSE_ECALL_M 11ul

static volatile unsigned long g_cause;
static volatile unsigned long g_value;

__attribute__((naked, aligned(4))) static void zihpm_trap_handler(void)
{
    __asm__ volatile("csrr t0, mcause\n"
                     "la   t1, g_cause\n"
                     "sd   t0, 0(t1)\n"
                     "la   t1, g_value\n"
                     "sd   a0, 0(t1)\n"
                     "csrr t0, mscratch\n"
                     "csrw mepc, t0\n"
                     "li   t0, 0x1800\n"
                     "csrs mstatus, t0\n"
                     "mret\n");
}

/* Bodies: read (csrr a0) or write (csrw from a1) one CSR, then ecall. */
#define READ_BODY(num)                                                                             \
    __attribute__((naked)) static void read_##num(void)                                            \
    {                                                                                              \
        __asm__ volatile("li a0, -1\n"                                                             \
                         "csrr a0, " #num "\n"                                                     \
                         "ecall\n"                                                                 \
                         "j .\n");                                                                 \
    }
#define WRITE_BODY(num)                                                                            \
    __attribute__((naked)) static void write_##num(void)                                           \
    {                                                                                              \
        __asm__ volatile("li a0, 0\n"                                                              \
                         "csrw " #num ", a1\n"                                                     \
                         "ecall\n"                                                                 \
                         "j .\n");                                                                 \
    }

/* hpmcounter3..10, 11, 31; mhpmcounter3, 10, 11, 31; mhpmevent3, 11, 31. */
READ_BODY(0xC03)
READ_BODY(0xC04)
READ_BODY(0xC05)
READ_BODY(0xC06)
READ_BODY(0xC07)
READ_BODY(0xC08)
READ_BODY(0xC09)
READ_BODY(0xC0A)
READ_BODY(0xC0B)
READ_BODY(0xC1F)
READ_BODY(0xB03)
READ_BODY(0xB0A)
READ_BODY(0xB0B)
READ_BODY(0xB1F)
READ_BODY(0x323)
READ_BODY(0x32B)
READ_BODY(0x33F)
WRITE_BODY(0xC03)
WRITE_BODY(0xC0A)
WRITE_BODY(0xB03)
WRITE_BODY(0xB0B)
WRITE_BODY(0xB1F)
WRITE_BODY(0x32B)

static void (*const hpm_read[8])(void) = {
    read_0xC03, read_0xC04, read_0xC05, read_0xC06, read_0xC07, read_0xC08, read_0xC09, read_0xC0A};

static unsigned long run_mode(unsigned long mpp, void (*body)(void), unsigned long a1)
{
    g_cause = ~0ul;
    g_value = ~0ul;
    __asm__ volatile("la   t0, 1f\n"
                     "csrw mscratch, t0\n"
                     "li   t0, 0x1800\n"
                     "csrc mstatus, t0\n"
                     "slli t0, %0, 11\n"
                     "csrs mstatus, t0\n"
                     "csrw mepc, %1\n"
                     "mv   a1, %2\n"
                     "mret\n"
                     "1:\n"
                     :
                     : "r"(mpp), "r"((unsigned long) body), "r"(a1)
                     : "t0", "t1", "t2", "t3", "a0", "a1", "memory");
    return g_cause;
}

static const unsigned long ecall_cause[4] = {CAUSE_ECALL_U, CAUSE_ECALL_S, 0, CAUSE_ECALL_M};
static const char *const mode_name[4] = {"U", "S", "?", "M"};

static int expect(const char *what,
                  unsigned long mpp,
                  unsigned long n,
                  unsigned long cause,
                  int check_value,
                  unsigned long value)
{
    int ok = g_cause == cause && (!check_value || g_value == value);
    if (!ok) {
        uart_printf("[FAIL] %s mode=%s n=%lu cause=%lu want=%lu value=0x%lx want=0x%lx\r\n",
                    what,
                    mode_name[mpp],
                    n,
                    g_cause,
                    cause,
                    g_value,
                    value);
    }
    return ok;
}

static void report(int ok, const char *name)
{
    uart_puts(ok ? "[PASS] " : "[FAIL] ");
    uart_puts(name);
    uart_puts("\r\n");
}

int main(void)
{
    int ok = 1;
    uint32_t menable, senable;

    uart_puts("\r\n=== Zihpm test ===\r\n");
    set_trap_handler(&zihpm_trap_handler);
    csr_write(medeleg, 0);

    /* A: counter-enable WARL masks (Sscounterenw: HPM3..10 writable). */
    csr_write(mcounteren, 0xFFFFFFFFu);
    csr_write(scounteren, 0xFFFFFFFFu);
    menable = (uint32_t) csr_read(mcounteren);
    senable = (uint32_t) csr_read(scounteren);
    csr_write(scounteren, 0x0u);
    int a_ok = menable == 0x7FFu && senable == 0x7FFu && csr_read(scounteren) == 0;
    report(a_ok, "A counteren-masks");
    ok &= a_ok;

    /* B: shadows. Inhibit the counters, load distinct values into
     * mhpmcounter3..10, and read each hpmcounter in M with all enables. */
    csr_write(mcountinhibit, 0x7FDu);
    __asm__ volatile("li t0, 0x1003\n csrw 0xB03, t0\n"
                     "li t0, 0x1004\n csrw 0xB04, t0\n"
                     "li t0, 0x1005\n csrw 0xB05, t0\n"
                     "li t0, 0x1006\n csrw 0xB06, t0\n"
                     "li t0, 0x1007\n csrw 0xB07, t0\n"
                     "li t0, 0x1008\n csrw 0xB08, t0\n"
                     "li t0, 0x1009\n csrw 0xB09, t0\n"
                     "li t0, 0x100A\n csrw 0xB0A, t0\n" ::
                         : "t0");

    /* C: every mode and every enable combination for HPM3..10. */
    int c_ok = 1;
    for (unsigned long mpp = 0; mpp < 4; mpp++) {
        if (mpp == 2)
            continue;
        for (unsigned long n = 3; n <= 10; n++) {
            for (unsigned combo = 0; combo < 4; combo++) {
                unsigned long mbit = (combo & 1) ? (1ul << n) : 0;
                unsigned long sbit = (combo & 2) ? (1ul << n) : 0;
                csr_write(mcounteren, (0x7FFu & ~(1ul << n)) | mbit);
                csr_write(scounteren, (0x7FFu & ~(1ul << n)) | sbit);
                int allowed = mpp == 3 || (mpp == 1 && mbit) || (mpp == 0 && mbit && sbit);
                run_mode(mpp, hpm_read[n - 3], 0);
                c_ok &= expect("hpm-read",
                               mpp,
                               n,
                               allowed ? ecall_cause[mpp] : CAUSE_ILLEGAL,
                               allowed,
                               0x1000ul + n);
            }
        }
    }
    csr_write(mcounteren, 0x7FFu);
    csr_write(scounteren, 0x7FFu);
    report(c_ok, "C hpmcounter3-10 gating and shadow values");
    ok &= c_ok;

    /* D: read-only and M-only rules, all enables set. */
    int d_ok = 1;
    for (unsigned long mpp = 0; mpp < 4; mpp++) {
        if (mpp == 2)
            continue;
        unsigned long m_only = mpp == 3 ? ecall_cause[3] : CAUSE_ILLEGAL;
        run_mode(mpp, write_0xC03, 5);
        d_ok &= expect("hpmcounter3-write", mpp, 3, CAUSE_ILLEGAL, 0, 0);
        run_mode(mpp, write_0xC0A, 5);
        d_ok &= expect("hpmcounter10-write", mpp, 10, CAUSE_ILLEGAL, 0, 0);
        run_mode(mpp, read_0xB03, 0);
        d_ok &= expect("mhpmcounter3-read", mpp, 3, m_only, mpp == 3, 0x1003ul);
        run_mode(mpp, read_0xB0A, 0);
        d_ok &= expect("mhpmcounter10-read", mpp, 10, m_only, mpp == 3, 0x100Aul);
        run_mode(mpp, read_0x323, 0);
        d_ok &= expect("mhpmevent3-read", mpp, 3, m_only, 0, 0);
        run_mode(mpp, write_0xB03, 0x2003);
        d_ok &= expect("mhpmcounter3-write", mpp, 3, m_only, 0, 0);
        /* E: unimplemented user counters trap everywhere. */
        run_mode(mpp, read_0xC0B, 0);
        d_ok &= expect("hpmcounter11-read", mpp, 11, CAUSE_ILLEGAL, 0, 0);
        run_mode(mpp, read_0xC1F, 0);
        d_ok &= expect("hpmcounter31-read", mpp, 31, CAUSE_ILLEGAL, 0, 0);
    }
    /* mhpmcounter3 took the M write. */
    run_mode(3, read_0xC03, 0);
    d_ok &= expect("hpmcounter3-after-m-write", 3, 3, CAUSE_ECALL_M, 1, 0x2003ul);
    report(d_ok, "D read-only, M-only and unimplemented counters");
    ok &= d_ok;

    /* F: zero-only machine pairs 11..31. */
    int f_ok = 1;
    run_mode(3, write_0xB0B, 0x1234);
    f_ok &= expect("mhpmcounter11-write", 3, 11, CAUSE_ECALL_M, 0, 0);
    run_mode(3, write_0xB1F, 0x1234);
    f_ok &= expect("mhpmcounter31-write", 3, 31, CAUSE_ECALL_M, 0, 0);
    run_mode(3, write_0x32B, 0x3);
    f_ok &= expect("mhpmevent11-write", 3, 11, CAUSE_ECALL_M, 0, 0);
    run_mode(3, read_0xB0B, 0);
    f_ok &= expect("mhpmcounter11-read", 3, 11, CAUSE_ECALL_M, 1, 0);
    run_mode(3, read_0xB1F, 0);
    f_ok &= expect("mhpmcounter31-read", 3, 31, CAUSE_ECALL_M, 1, 0);
    run_mode(3, read_0x32B, 0);
    f_ok &= expect("mhpmevent11-read", 3, 11, CAUSE_ECALL_M, 1, 0);
    run_mode(3, read_0x33F, 0);
    f_ok &= expect("mhpmevent31-read", 3, 31, CAUSE_ECALL_M, 1, 0);
    report(f_ok, "F zero-only mhpm pairs 11-31");
    ok &= f_ok;

    csr_write(mcountinhibit, 0x0u);
    uart_puts(ok ? "\r\n<<PASS>>\r\n" : "\r\n<<FAIL>>\r\n");
    for (;;) {
    }
    return 0;
}
