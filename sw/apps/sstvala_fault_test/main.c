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
 * Sstvala directed test for access faults raised by failed bus responses.
 * The registry makes the DDR model answer SLVERR to every read of the line at
 * ERR. A load, LR or AMO there takes a load or store/AMO access fault, an
 * instruction fetch there an instruction access fault, and mtval (or stval
 * when medeleg delegates the cause) holds the faulting virtual address:
 *
 *   - doubleword, word and byte loads, LR and AMOs in M, S and U, delegated
 *     and not;
 *   - the same accesses through Sv39 from S and U, where the virtual address
 *     (VA_ERR) differs from the physical one;
 *   - misaligned loads the misaligned-access engine performs (when the build
 *     has it): the first byte of the lowest failed part, the access's own
 *     address in the failed line or the base of the failed line when only the
 *     upper part lies in it;
 *   - fetches from the line, and a 32-bit instruction whose second halfword
 *     lies in it (xtval = its PC + 2).
 *
 * Each case checks the cause, xepc and xtval; a delegated case checks scause,
 * sepc and stval, then that the S handler's ECALL reaches M. The test never
 * writes the failed line, so no case finds it in a cache.
 */

#include <stdint.h>

#include "trap.h"
#include "uart.h"

#define CAUSE_FETCH_ACCESS 1ul
#define CAUSE_LOAD_ACCESS 5ul
#define CAUSE_STORE_ACCESS 7ul
#define CAUSE_ECALL_S 9ul
#define CAUSE_ECALL_M 11ul

#define MODE_U 0ul
#define MODE_S 1ul
#define MODE_M 3ul

#define MSTATUS_SUM (1ul << 18)

/* The failed line (registry: +axi_rd_error_addr=3000000, DDR at 0x80000000). */
#define ERR 0x83000000ul
/* Page tables and a probe line in DDR, away from the program in either tier. */
#define ROOT_S 0x81000000ul
#define ROOT_U 0x81001000ul
#define PROBE_LINE 0x81002000ul

/* Sv39 gigapages. Both roots map gigapages 0 and 2 (low BRAM and devices,
 * DDR) to themselves and gigapage 8 to DDR, so VA_ERR reaches ERR. ROOT_U's
 * leaves are user pages; it also maps gigapages 4 and 6 to 0 and 2 as
 * supervisor pages, an alias at ALIAS for the S handler of a delegated
 * U-mode trap. */
#define GIGA 0x40000000ul
#define VA_ERR (8 * GIGA + (ERR - 2 * GIGA))
#define ALIAS (4 * GIGA)
#define PTE_S_LEAF 0xCFul /* V R W X A D */
#define PTE_U_LEAF 0xDFul /* V R W X U A D */
#define SATP_SV39 (8ul << 60)

static volatile unsigned long g_mcause, g_mtval, g_mepc;
static volatile unsigned long g_scause, g_stval, g_sepc;

/* M handler: record mcause/mtval/mepc, return to M at mscratch. */
__attribute__((naked, aligned(4))) static void m_handler(void)
{
    __asm__ volatile("csrr t0, mcause\n"
                     "la   t1, g_mcause\n"
                     "sd   t0, 0(t1)\n"
                     "csrr t0, mtval\n"
                     "la   t1, g_mtval\n"
                     "sd   t0, 0(t1)\n"
                     "csrr t0, mepc\n"
                     "la   t1, g_mepc\n"
                     "sd   t0, 0(t1)\n"
                     "csrr t0, mscratch\n"
                     "csrw mepc, t0\n"
                     "li   t0, 0x1800\n"
                     "csrs mstatus, t0\n"
                     "mret\n");
}

/* S handler for delegated traps: record scause/stval/sepc, then ecall to M. */
__attribute__((naked, aligned(4))) static void s_handler(void)
{
    __asm__ volatile("csrr t0, scause\n"
                     "la   t1, g_scause\n"
                     "sd   t0, 0(t1)\n"
                     "csrr t0, stval\n"
                     "la   t1, g_stval\n"
                     "sd   t0, 0(t1)\n"
                     "csrr t0, sepc\n"
                     "la   t1, g_sepc\n"
                     "sd   t0, 0(t1)\n"
                     "ecall\n"
                     "j .\n");
}

/* Each body's first instruction is the case, with its address in a0; a body
 * that does not trap reaches its ecall. */
#define BODY(name, insn)                                                                           \
    extern char name[];                                                                            \
    __asm__(".text\n.balign 4\n.global " #name "\n" #name ":\n.option push\n.option norvc\n" insn  \
            "\nlui t6, 0xfffff\necall\nj .\n.option pop\n");

BODY(b_ld, "ld t6, 0(a0)")
BODY(b_lw, "lw t6, 0(a0)")
BODY(b_lbu, "lbu t6, 0(a0)")
BODY(b_lr_d, "lr.d t6, (a0)")
BODY(b_lr_w, "lr.w t6, (a0)")
BODY(b_amoadd_d, "amoadd.d t6, t5, (a0)")
BODY(b_amoswap_w, "amoswap.w t6, t5, (a0)")
BODY(b_amoor_d, "amoor.d t6, t5, (a0)")
/* Fetch cases jump to a0. */
BODY(b_jr, "jr a0")

/* Run pc in mode with a0 = arg and t5 = 1, back in M at the label. */
static void run_at(unsigned long mpp, const void *pc, unsigned long arg)
{
    register unsigned long a0 __asm__("a0") = arg;
    __asm__ volatile("la   t0, 1f\n"
                     "csrw mscratch, t0\n"
                     "li   t0, 0x1800\n"
                     "csrc mstatus, t0\n"
                     "slli t0, %1, 11\n"
                     "csrs mstatus, t0\n"
                     "csrw mepc, %2\n"
                     "li   t5, 1\n"
                     "mret\n"
                     "1:\n"
                     : "+r"(a0)
                     : "r"(mpp), "r"((unsigned long) pc)
                     : "t0", "t1", "t5", "t6", "memory");
}

static const char *const mode_name[4] = {"U", "S", "?", "M"};

/* Run one case; epc is the faulting instruction's address. */
static int expect(const char *name,
                  unsigned long mode,
                  const void *pc,
                  unsigned long arg,
                  unsigned long cause,
                  unsigned long tval,
                  unsigned long epc,
                  int delegated)
{
    int ok;
    g_mcause = g_mtval = g_mepc = ~0ul;
    g_scause = g_stval = g_sepc = ~0ul;
    run_at(mode, pc, arg);
    if (delegated) {
        ok = g_scause == cause && g_stval == tval && g_sepc == epc && g_mcause == CAUSE_ECALL_S &&
             g_mtval == 0;
        uart_puts(ok ? "[PASS] " : "[FAIL] ");
        uart_printf("%s mode=%s delegated scause=%lu stval=0x%lx sepc=0x%lx want=%lu/0x%lx/0x%lx "
                    "mcause=%lu\r\n",
                    name,
                    mode_name[mode],
                    g_scause,
                    g_stval,
                    g_sepc,
                    cause,
                    tval,
                    epc,
                    g_mcause);
    } else {
        ok = g_mcause == cause && g_mtval == tval && g_mepc == epc;
        uart_puts(ok ? "[PASS] " : "[FAIL] ");
        uart_printf("%s mode=%s mcause=%lu mtval=0x%lx mepc=0x%lx want=%lu/0x%lx/0x%lx\r\n",
                    name,
                    mode_name[mode],
                    g_mcause,
                    g_mtval,
                    g_mepc,
                    cause,
                    tval,
                    epc);
    }
    return ok;
}

/* A data access at va in mode; its body is the faulting instruction. */
static int data_case(const char *name,
                     unsigned long mode,
                     const char *body,
                     unsigned long va,
                     unsigned long cause,
                     unsigned long tval,
                     int delegated)
{
    return expect(name, mode, body, va, cause, tval, (unsigned long) body, delegated);
}

/* A fetch at target in mode, reached by jr. */
static int fetch_case(
    const char *name, unsigned long mode, unsigned long target, unsigned long tval, int delegated)
{
    return expect(name, mode, b_jr, target, CAUSE_FETCH_ACCESS, tval, target, delegated);
}

static void map_root(unsigned long root, unsigned long leaf)
{
    volatile unsigned long *pte = (volatile unsigned long *) root;
    for (int i = 0; i < 512; i++)
        pte[i] = 0;
    pte[0] = ((0 * GIGA) >> 2) | leaf;
    pte[2] = ((2 * GIGA) >> 2) | leaf;
    pte[8] = ((2 * GIGA) >> 2) | leaf;
    if (leaf == PTE_U_LEAF) {
        pte[4] = ((0 * GIGA) >> 2) | PTE_S_LEAF;
        pte[6] = ((2 * GIGA) >> 2) | PTE_S_LEAF;
    }
}

static void use_root(unsigned long root)
{
    __asm__ volatile("sfence.vma" ::: "memory");
    csr_write(satp, root ? SATP_SV39 | (root >> 12) : 0);
    __asm__ volatile("sfence.vma" ::: "memory");
}

int main(void)
{
    int ok = 1;
    int engine;
    const unsigned long deleg =
        (1ul << CAUSE_FETCH_ACCESS) | (1ul << CAUSE_LOAD_ACCESS) | (1ul << CAUSE_STORE_ACCESS);

    uart_puts("\r\n=== Sstvala bus-fault test ===\r\n");
    set_trap_handler(&m_handler);
    csr_write(stvec, (unsigned long) &s_handler);
    csr_write(medeleg, 0);
    csr_write(satp, 0);

    /* A native addi whose upper halfword starts the failed line. */
    *(volatile uint16_t *) (ERR - 2) = 0x0013;
    __asm__ volatile("fence.i" ::: "memory");

    /* The engine performs a misaligned load in DDR; without it the load
     * takes its address-misaligned exception. */
    g_mcause = ~0ul;
    run_at(MODE_M, b_lw, PROBE_LINE + 1);
    engine = g_mcause == CAUSE_ECALL_M;
    uart_puts(engine ? "misaligned-access engine present\r\n"
                     : "[SKIP] misaligned cases: no misaligned-access engine\r\n");

    /* Bare, not delegated. */
    ok &= data_case("ld", MODE_M, b_ld, ERR + 0x18, CAUSE_LOAD_ACCESS, ERR + 0x18, 0);
    ok &= data_case("lw", MODE_M, b_lw, ERR + 0x24, CAUSE_LOAD_ACCESS, ERR + 0x24, 0);
    ok &= data_case("lbu", MODE_M, b_lbu, ERR + 0x3F, CAUSE_LOAD_ACCESS, ERR + 0x3F, 0);
    ok &= data_case("lr.d", MODE_M, b_lr_d, ERR + 0x18, CAUSE_LOAD_ACCESS, ERR + 0x18, 0);
    ok &= data_case("amoadd.d", MODE_M, b_amoadd_d, ERR + 0x18, CAUSE_STORE_ACCESS, ERR + 0x18, 0);
    ok &= data_case("ld", MODE_S, b_ld, ERR + 0x08, CAUSE_LOAD_ACCESS, ERR + 0x08, 0);
    ok &=
        data_case("amoswap.w", MODE_S, b_amoswap_w, ERR + 0x20, CAUSE_STORE_ACCESS, ERR + 0x20, 0);
    ok &= data_case("lbu", MODE_U, b_lbu, ERR + 0x01, CAUSE_LOAD_ACCESS, ERR + 0x01, 0);
    ok &= data_case("lr.w", MODE_U, b_lr_w, ERR + 0x24, CAUSE_LOAD_ACCESS, ERR + 0x24, 0);
    ok &= data_case("amoor.d", MODE_U, b_amoor_d, ERR + 0x28, CAUSE_STORE_ACCESS, ERR + 0x28, 0);
    ok &= fetch_case("fetch", MODE_M, ERR + 0x20, ERR + 0x20, 0);
    ok &= fetch_case("fetch", MODE_U, ERR + 0x30, ERR + 0x30, 0);
    ok &= fetch_case("fetch upper halfword", MODE_M, ERR - 2, ERR, 0);
    if (engine) {
        /* Upper part in the failed line, both parts in it, lower part only. */
        ok &= data_case("misaligned ld upper", MODE_M, b_ld, ERR - 4, CAUSE_LOAD_ACCESS, ERR, 0);
        ok &= data_case(
            "misaligned lw both", MODE_M, b_lw, ERR + 0x1E, CAUSE_LOAD_ACCESS, ERR + 0x1E, 0);
        ok &= data_case(
            "misaligned ld lower", MODE_U, b_ld, ERR + 0x3C, CAUSE_LOAD_ACCESS, ERR + 0x3C, 0);
    }

    /* Bare, delegated to S. */
    csr_write(medeleg, deleg);
    ok &= data_case("ld", MODE_S, b_ld, ERR + 0x10, CAUSE_LOAD_ACCESS, ERR + 0x10, 1);
    ok &= data_case("amoadd.d", MODE_U, b_amoadd_d, ERR + 0x30, CAUSE_STORE_ACCESS, ERR + 0x30, 1);
    ok &= fetch_case("fetch", MODE_U, ERR + 0x20, ERR + 0x20, 1);
    if (engine)
        ok &= data_case("misaligned ld upper", MODE_U, b_ld, ERR - 4, CAUSE_LOAD_ACCESS, ERR, 1);
    csr_write(medeleg, 0);

    /* Sv39 from S: supervisor pages. */
    map_root(ROOT_S, PTE_S_LEAF);
    map_root(ROOT_U, PTE_U_LEAF);
    use_root(ROOT_S);
    ok &= data_case("sv39 ld", MODE_S, b_ld, VA_ERR + 0x18, CAUSE_LOAD_ACCESS, VA_ERR + 0x18, 0);
    ok &= data_case(
        "sv39 amoadd.d", MODE_S, b_amoadd_d, VA_ERR + 0x08, CAUSE_STORE_ACCESS, VA_ERR + 0x08, 0);
    csr_write(medeleg, deleg);
    ok &= data_case("sv39 lw", MODE_S, b_lw, VA_ERR + 0x24, CAUSE_LOAD_ACCESS, VA_ERR + 0x24, 1);
    ok &=
        data_case("sv39 lr.d", MODE_S, b_lr_d, VA_ERR + 0x18, CAUSE_LOAD_ACCESS, VA_ERR + 0x18, 1);
    ok &= fetch_case("sv39 fetch", MODE_S, VA_ERR + 0x20, VA_ERR + 0x20, 1);
    if (engine)
        ok &= data_case(
            "sv39 misaligned ld upper", MODE_S, b_ld, VA_ERR - 4, CAUSE_LOAD_ACCESS, VA_ERR, 1);
    csr_write(medeleg, 0);

    /* Sv39 from U: user pages; the S handler runs at its supervisor alias,
     * and SUM lets it record the trap through the user pages. */
    use_root(ROOT_U);
    csr_set(mstatus, MSTATUS_SUM);
    csr_write(stvec, (unsigned long) &s_handler + ALIAS);
    ok &= data_case("sv39 lbu", MODE_U, b_lbu, VA_ERR + 0x05, CAUSE_LOAD_ACCESS, VA_ERR + 0x05, 0);
    ok &= data_case(
        "sv39 amoswap.w", MODE_U, b_amoswap_w, VA_ERR + 0x20, CAUSE_STORE_ACCESS, VA_ERR + 0x20, 0);
    csr_write(medeleg, deleg);
    ok &= data_case("sv39 ld", MODE_U, b_ld, VA_ERR + 0x38, CAUSE_LOAD_ACCESS, VA_ERR + 0x38, 1);
    ok &= data_case(
        "sv39 amoor.d", MODE_U, b_amoor_d, VA_ERR + 0x10, CAUSE_STORE_ACCESS, VA_ERR + 0x10, 1);
    ok &=
        data_case("sv39 lr.w", MODE_U, b_lr_w, VA_ERR + 0x2C, CAUSE_LOAD_ACCESS, VA_ERR + 0x2C, 1);
    ok &= fetch_case("sv39 fetch", MODE_U, VA_ERR + 0x30, VA_ERR + 0x30, 1);
    if (engine)
        ok &= data_case("sv39 misaligned lw both",
                        MODE_U,
                        b_lw,
                        VA_ERR + 0x1E,
                        CAUSE_LOAD_ACCESS,
                        VA_ERR + 0x1E,
                        1);
    csr_write(medeleg, 0);
    csr_write(stvec, (unsigned long) &s_handler);
    csr_clear(mstatus, MSTATUS_SUM);
    use_root(0);

    uart_puts(ok ? "\r\n<<PASS>>\r\n" : "\r\n<<FAIL>>\r\n");
    for (;;) {
    }
    return 0;
}
