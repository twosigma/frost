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
 * Zicbom directed test. cbo.clean, cbo.flush and cbo.inval name the naturally
 * aligned 64-byte block containing rs1. Every bus master in FROST is coherent,
 * so each executes as an ordered no-op: the block's data never changes, and
 * loads and stores around it keep program order.
 *
 * Gates (menvcfg/senvcfg): CBCFE (bit 6) enables cbo.clean and cbo.flush below
 * M (S needs menvcfg.CBCFE, U needs both). CBIE (bits 5:4) is WARL {00, 01, 11}:
 * cbo.inval is illegal in S with menvcfg.CBIE = 00 and in U with either CBIE =
 * 00, and a write of the reserved 10 reads back 00. M always executes all
 * three. menvcfg.PBMTE (bit 62) is writable; senvcfg has no PBMTE.
 *
 * Permissions: a CMO is permitted where a load is (R, or X with MXR; A must be
 * set; D is ignored), so a read-only or D-clear page is fine where cbo.zero
 * faults. Faults are store faults with mtval = rs1: store page fault (15) for
 * a page with no load permission, A clear, or invalid; store access fault (7)
 * for a block outside the PMA map. A block in a device window executes as a
 * no-op. rs1 never traps as misaligned.
 *
 * The handler returns through an mscratch continuation (cbo_zero_test shape).
 */

#include <stdint.h>

#include "dma_engine.h"
#include "trap.h"
#include "uart.h"

#ifndef FROST_DDR_CAPACITY_LOG2_BYTES
#define FROST_DDR_CAPACITY_LOG2_BYTES 30
#endif
#define DDR_LIMIT (0x80000000ul + (1ul << FROST_DDR_CAPACITY_LOG2_BYTES))

#define BLOCK 64ul
#define ENVCFG_CBIE_SHIFT 4
#define ENVCFG_CBIE(v) ((unsigned long) (v) << ENVCFG_CBIE_SHIFT)
#define ENVCFG_CBIE_MASK ENVCFG_CBIE(3)
#define ENVCFG_CBCFE (1ul << 6)
#define ENVCFG_CBZE (1ul << 7)
#define MENVCFG_PBMTE (1ul << 62)

#define CAUSE_ILLEGAL 2ul
#define CAUSE_STORE_ACCESS 7ul
#define CAUSE_ECALL_U 8ul
#define CAUSE_ECALL_S 9ul
#define CAUSE_ECALL_M 11ul
#define CAUSE_STORE_PAGE 15ul

#define PATTERN 0xA5A5C3C3F00F1234ul

/* MISC-MEM, funct3 010, rd x0: funct12 0x000 inval, 0x001 clean, 0x002 flush. */
#define CBO_INVAL_ASM(reg) ".insn i 0x0F, 2, x0, " reg ", 0\n"
#define CBO_CLEAN_ASM(reg) ".insn i 0x0F, 2, x0, " reg ", 1\n"
#define CBO_FLUSH_ASM(reg) ".insn i 0x0F, 2, x0, " reg ", 2\n"

enum cbo_op { OP_INVAL = 0, OP_CLEAN = 1, OP_FLUSH = 2 };
static const char *const op_name[3] = {"inval", "clean", "flush"};

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

static void uart_hex(unsigned long v)
{
    uart_printf("0x%016lx", v);
}

static volatile unsigned long g_cause;
static volatile unsigned long g_tval;

/* Three blocks each in low BRAM and cached DDR; tests target the middle one. */
static volatile uint64_t g_bram_buf[3 * BLOCK / 8] __attribute__((aligned(64)));
static volatile uint64_t g_ddr_buf[3 * BLOCK / 8]
    __attribute__((aligned(64), section(".ddr_data")));

/* M-mode bounce handler: record mcause and mtval once per case, set MPP=M and
 * return to the mscratch continuation. */
__attribute__((naked, aligned(4))) static void cbo_trap_handler(void)
{
    __asm__ volatile("csrr t0, mcause\n"
                     "la   t1, g_cause\n"
                     "ld   t2, 0(t1)\n"
                     "li   t3, -1\n"
                     "bne  t2, t3, 2f\n"
                     "sd   t0, 0(t1)\n"
                     "csrr t0, mtval\n"
                     "la   t1, g_tval\n"
                     "sd   t0, 0(t1)\n"
                     "2:\n"
                     "csrr t0, mscratch\n"
                     "csrw mepc, t0\n"
                     "li   t0, 0x1800\n"
                     "csrs mstatus, t0\n"
                     "mret\n");
}

static void report(int ok, const char *name, const char *op)
{
    uart_puts(ok ? "[PASS] " : "[FAIL] ");
    uart_puts(name);
    if (op) {
        uart_puts(" ");
        uart_puts(op);
    }
    uart_puts(" cause=");
    uart_hex(g_cause);
    uart_puts(" tval=");
    uart_hex(g_tval);
    uart_puts("\r\n");
}

static int expect(const char *name, int op, unsigned long cause, unsigned long tval, int check_tval)
{
    int ok = (g_cause == cause) && (!check_tval || g_tval == tval);
    report(ok, name, op >= 0 ? op_name[op] : 0);
    return ok;
}

static uint64_t pattern_at(unsigned long i)
{
    return PATTERN ^ (i * 0x0101010101010101ul);
}

static void fill(volatile uint64_t *buf, unsigned long dwords)
{
    for (unsigned long i = 0; i < dwords; i++)
        buf[i] = pattern_at(i);
}

/* Every dword still holds its fill value: a coherent CMO changes no data. */
static int check_intact(const char *name, int op, volatile uint64_t *buf)
{
    int ok = 1;
    for (unsigned long i = 0; i < 3 * BLOCK / 8; i++) {
        if (buf[i] != pattern_at(i)) {
            uart_puts("  mismatch dword ");
            uart_hex(i);
            uart_puts(" got ");
            uart_hex(buf[i]);
            uart_puts("\r\n");
            ok = 0;
        }
    }
    uart_puts(ok ? "[PASS] " : "[FAIL] ");
    uart_puts(name);
    uart_puts(" ");
    uart_puts(op_name[op]);
    uart_puts(" data-intact\r\n");
    return ok;
}

/* Execute one CMO at rs1 (M, or translated through MPRV). */
static void cbo_at(int op, unsigned long rs1)
{
    switch (op) {
        case OP_INVAL:
            __asm__ volatile("mv t1, %0\n" CBO_INVAL_ASM("t1") : : "r"(rs1) : "t1", "memory");
            break;
        case OP_CLEAN:
            __asm__ volatile("mv t1, %0\n" CBO_CLEAN_ASM("t1") : : "r"(rs1) : "t1", "memory");
            break;
        default:
            __asm__ volatile("mv t1, %0\n" CBO_FLUSH_ASM("t1") : : "r"(rs1) : "t1", "memory");
            break;
    }
}

#define MSTATUS_MPRV (1ul << 17)

/* Run one CMO in M and record any fault; a clean case ends in ecall. With
 * MPRV in bits the CMO runs with MPP=S, so it translates with S rights, under
 * the other bits of bits (SUM, MXR) too. */
static void run_op(int op, unsigned long rs1, unsigned long bits)
{
    g_cause = ~0ul;
    g_tval = ~0ul;
    __asm__ volatile(
        "la   t0, 1f\n"
        "csrw mscratch, t0\n"
        "li   t0, 0x1800\n"
        "csrc mstatus, t0\n"
        "li   t0, 0x0800\n"
        "csrs mstatus, t0\n"
        "mv   t1, %[rs1]\n"
        "csrs mstatus, %[bits]\n"
        "li   t2, 1\n"
        "beq  %[op], t2, 3f\n"
        "li   t2, 2\n"
        "beq  %[op], t2, 4f\n" CBO_INVAL_ASM(
            "t1") "j    5f\n"
                  "3:\n" CBO_CLEAN_ASM("t1") "j    5f\n"
                                             "4:\n" CBO_FLUSH_ASM("t1") "5:\n"
                                                                        "csrc mstatus, %[bits]\n"
                                                                        "ecall\n"
                                                                        "1:\n"
        :
        : [rs1] "r"(rs1), [bits] "r"(bits), [op] "r"((unsigned long) op)
        : "t0", "t1", "t2", "t3", "memory");
    /* A fault skips the clear above; the handler returns with MPP=M. */
    __asm__ volatile("csrc mstatus, %0" ::"r"(bits));
}

static void run_m(int op, unsigned long rs1)
{
    run_op(op, rs1, 0);
}

static void run_mprv_s(int op, unsigned long rs1, unsigned long extra)
{
    run_op(op, rs1, MSTATUS_MPRV | extra);
}

/* Lower-privilege bodies: a0 holds rs1. */
__attribute__((naked)) static void lower_inval(void)
{
    __asm__ volatile(CBO_INVAL_ASM("a0") "ecall\n"
                                         "j .\n");
}
__attribute__((naked)) static void lower_clean(void)
{
    __asm__ volatile(CBO_CLEAN_ASM("a0") "ecall\n"
                                         "j .\n");
}
__attribute__((naked)) static void lower_flush(void)
{
    __asm__ volatile(CBO_FLUSH_ASM("a0") "ecall\n"
                                         "j .\n");
}

/* Enter S (mpp=1) or U (mpp=0) at the op's body with a0 = rs1. Returns mcause. */
static unsigned long run_lower(unsigned long mpp, int op, unsigned long rs1)
{
    unsigned long body = op == OP_INVAL   ? (unsigned long) &lower_inval
                         : op == OP_CLEAN ? (unsigned long) &lower_clean
                                          : (unsigned long) &lower_flush;
    g_cause = ~0ul;
    g_tval = ~0ul;
    __asm__ volatile("la   t0, 1f\n"
                     "csrw mscratch, t0\n"
                     "li   t0, 0x1800\n"
                     "csrc mstatus, t0\n"
                     "slli t0, %0, 11\n"
                     "csrs mstatus, t0\n"
                     "csrw mepc, %1\n"
                     "mv   a0, %2\n"
                     "mret\n"
                     "1:\n"
                     :
                     : "r"(mpp), "r"(body), "r"(rs1)
                     : "t0", "a0", "memory");
    return g_cause;
}

/* ---- Sv39 tables in cached DDR, clear of the program image. ---- */
#define PT_ROOT 0x81000000ul
#define PT_L1 0x81001000ul
#define PT_L0 0x81002000ul
#define FRAME(n) (0x81100000ul + ((unsigned long) (n) << 12))
#define VA_4K(n) (0x00400000ul + ((unsigned long) (n) << 12))
#define VA_1G_DEVICE 0xC0000000ul

#define PTE_V (1ul << 0)
#define PTE_R (1ul << 1)
#define PTE_W (1ul << 2)
#define PTE_X (1ul << 3)
#define PTE_U (1ul << 4)
#define PTE_A (1ul << 6)
#define PTE_D (1ul << 7)
#define PTE_PPN(pa) ((((unsigned long) (pa)) >> 12) << 10)
#define SATP_SV39 (8ul << 60)
#define MSTATUS_SUM (1ul << 18)
#define MSTATUS_MXR (1ul << 19)

enum {
    PG_RW = 0,
    PG_RO = 1,
    PG_INVALID = 2,
    PG_DCLEAR = 3,
    PG_ACLEAR = 4,
    PG_XONLY = 5,
    PG_USER = 6,
    PG_BEYOND = 7,
    PG_COUNT = 8
};

static void build_tables(void)
{
    volatile unsigned long *root = (volatile unsigned long *) PT_ROOT;
    volatile unsigned long *l1 = (volatile unsigned long *) PT_L1;
    volatile unsigned long *l0 = (volatile unsigned long *) PT_L0;
    for (int i = 0; i < 512; i++) {
        root[i] = 0;
        l1[i] = 0;
        l0[i] = 0;
    }
    root[0] = PTE_PPN(PT_L1) | PTE_V;
    /* 1 GiB leaf over the device quadrant: a CMO there is a no-op. */
    root[3] = PTE_PPN(0x40000000ul) | PTE_V | PTE_R | PTE_W | PTE_A | PTE_D;
    l1[2] = PTE_PPN(PT_L0) | PTE_V;
    l0[PG_RW] = PTE_PPN(FRAME(PG_RW)) | PTE_V | PTE_R | PTE_W | PTE_A | PTE_D;
    l0[PG_RO] = PTE_PPN(FRAME(PG_RO)) | PTE_V | PTE_R | PTE_A;
    /* l0[PG_INVALID] stays invalid. */
    l0[PG_DCLEAR] = PTE_PPN(FRAME(PG_DCLEAR)) | PTE_V | PTE_R | PTE_W | PTE_A;
    l0[PG_ACLEAR] = PTE_PPN(FRAME(PG_ACLEAR)) | PTE_V | PTE_R | PTE_W | PTE_D;
    l0[PG_XONLY] = PTE_PPN(FRAME(PG_XONLY)) | PTE_V | PTE_X | PTE_A;
    l0[PG_USER] = PTE_PPN(FRAME(PG_USER)) | PTE_V | PTE_R | PTE_W | PTE_U | PTE_A | PTE_D;
    /* A leaf beyond the end of DDR: translation succeeds, the PMA refuses. */
    l0[PG_BEYOND] = PTE_PPN(DDR_LIMIT) | PTE_V | PTE_R | PTE_W | PTE_A | PTE_D;
}

static void spin(unsigned long n)
{
    for (volatile unsigned long i = 0; i < n; i++) {
    }
}

int main(void)
{
    int ok = 1;

    uart_puts("\r\n=== Zicbom test ===\r\n");
    set_trap_handler(&cbo_trap_handler);
    csr_write(medeleg, 0);

    /* A: M executes each op on cached DDR and low BRAM with an unaligned rs1,
     * retires, and changes no data. */
    for (int op = 0; op < 3; op++) {
        fill(g_ddr_buf, 3 * BLOCK / 8);
        run_m(op, (unsigned long) &g_ddr_buf[BLOCK / 8] + 0x2B);
        ok &= expect("A ddr-m-retires", op, CAUSE_ECALL_M, 0, 0);
        ok &= check_intact("A ddr", op, g_ddr_buf);
        fill(g_bram_buf, 3 * BLOCK / 8);
        run_m(op, (unsigned long) &g_bram_buf[BLOCK / 8] + 0x3F);
        ok &= expect("A bram-m-retires", op, CAUSE_ECALL_M, 0, 0);
        ok &= check_intact("A bram", op, g_bram_buf);
    }

    /* B: device windows are ordered no-ops; outside the map is a store access
     * fault with mtval = rs1. */
    for (int op = 0; op < 3; op++) {
        run_m(op, 0x40000013ul); /* MMIO register page */
        ok &= expect("B mmio-noop", op, CAUSE_ECALL_M, 0, 0);
        run_m(op, 0x44000021ul); /* APLIC */
        ok &= expect("B aplic-noop", op, CAUSE_ECALL_M, 0, 0);
        unsigned long beyond = DDR_LIMIT + 0x101ul;
        run_m(op, beyond);
        ok &= expect("B beyond-ddr", op, CAUSE_STORE_ACCESS, beyond, 1);
        unsigned long wild = 0x0000100000000035ul;
        run_m(op, wild);
        ok &= expect("B wild", op, CAUSE_STORE_ACCESS, wild, 1);
    }

    /* C: CSR fields. CBIE is WARL {00, 01, 11}: 10 reads back 00. CBCFE and
     * CBIE read back in both CSRs; PBMTE only in menvcfg. */
    {
        int c_ok = 1;
        for (unsigned long v = 0; v < 4; v++) {
            unsigned long want = (v == 2) ? 0 : v;
            csr_write_num(0x30A, ENVCFG_CBIE(v));
            c_ok &= (csr_read_num(0x30A) & ENVCFG_CBIE_MASK) == ENVCFG_CBIE(want);
            csr_write_num(0x10A, ENVCFG_CBIE(v));
            c_ok &= (csr_read_num(0x10A) & ENVCFG_CBIE_MASK) == ENVCFG_CBIE(want);
        }
        csr_write_num(0x30A, ENVCFG_CBCFE | ENVCFG_CBIE(3) | ENVCFG_CBZE | MENVCFG_PBMTE);
        c_ok &= (csr_read_num(0x30A) &
                 (ENVCFG_CBCFE | ENVCFG_CBIE_MASK | ENVCFG_CBZE | MENVCFG_PBMTE)) ==
                (ENVCFG_CBCFE | ENVCFG_CBIE(3) | ENVCFG_CBZE | MENVCFG_PBMTE);
        csr_write_num(0x10A, ~0ul);
        c_ok &= csr_read_num(0x10A) == (ENVCFG_CBCFE | ENVCFG_CBIE(3) | ENVCFG_CBZE | 1ul);
        /* A set or clear of the reserved pattern through csrs/csrc: 01 | 10 = 11. */
        csr_write_num(0x30A, ENVCFG_CBIE(1));
        __asm__ volatile("csrs 0x30A, %0" ::"r"(ENVCFG_CBIE(2)));
        c_ok &= (csr_read_num(0x30A) & ENVCFG_CBIE_MASK) == ENVCFG_CBIE(3);
        __asm__ volatile("csrc 0x30A, %0" ::"r"(ENVCFG_CBIE(1)));
        c_ok &= (csr_read_num(0x30A) & ENVCFG_CBIE_MASK) == 0;
        csr_write_num(0x30A, 0);
        csr_write_num(0x10A, 0);
        report(c_ok, "C envcfg-fields", 0);
        ok &= c_ok;
    }

    /* D: gates in S and U for each op. clean/flush need CBCFE (S: menvcfg; U:
     * both); inval needs CBIE != 00 (S: menvcfg; U: both). An executed op
     * changes no data; an illegal one traps with cause 2. */
    {
        static const struct {
            unsigned long mpp, menv, senv;
            int cf_legal, inval_legal;
            const char *name;
        } cases[] = {
            {1, 0, 0, 0, 0, "D s-m0"},
            {1, 0, ENVCFG_CBCFE | ENVCFG_CBIE(3), 0, 0, "D s-m0-s1"},
            {1, ENVCFG_CBCFE, 0, 1, 0, "D s-cbcfe"},
            {1, ENVCFG_CBIE(1), 0, 0, 1, "D s-cbie01"},
            {1, ENVCFG_CBIE(3), 0, 0, 1, "D s-cbie11"},
            {1, ENVCFG_CBIE(2), 0, 0, 0, "D s-cbie10-stores00"},
            {0, ENVCFG_CBCFE | ENVCFG_CBIE(3), 0, 0, 0, "D u-m1-s0"},
            {0, 0, ENVCFG_CBCFE | ENVCFG_CBIE(3), 0, 0, "D u-m0-s1"},
            {0, ENVCFG_CBCFE, ENVCFG_CBCFE, 1, 0, "D u-cbcfe"},
            {0, ENVCFG_CBIE(1), ENVCFG_CBIE(3), 0, 1, "D u-cbie01-11"},
            {0, ENVCFG_CBIE(3), ENVCFG_CBIE(1), 0, 1, "D u-cbie11-01"},
            {0, ENVCFG_CBIE(3), ENVCFG_CBIE(3), 0, 1, "D u-cbie11-11"},
            {0, ENVCFG_CBIE(3), ENVCFG_CBIE(2), 0, 0, "D u-cbie11-10"},
            {0, ENVCFG_CBCFE | ENVCFG_CBIE(3), ENVCFG_CBCFE | ENVCFG_CBIE(3), 1, 1, "D u-all"},
        };
        for (unsigned i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
            for (int op = 0; op < 3; op++) {
                int legal = op == OP_INVAL ? cases[i].inval_legal : cases[i].cf_legal;
                unsigned long want = !legal              ? CAUSE_ILLEGAL
                                     : cases[i].mpp == 1 ? CAUSE_ECALL_S
                                                         : CAUSE_ECALL_U;
                fill(g_bram_buf, 3 * BLOCK / 8);
                csr_write_num(0x30A, cases[i].menv);
                csr_write_num(0x10A, cases[i].senv);
                run_lower(cases[i].mpp, op, (unsigned long) &g_bram_buf[BLOCK / 8] + 5);
                ok &= expect(cases[i].name, op, want, 0, want == CAUSE_ILLEGAL);
                ok &= check_intact(cases[i].name, op, g_bram_buf);
            }
        }
        csr_write_num(0x30A, 0);
        csr_write_num(0x10A, 0);
        /* M ignores both CSRs. */
        for (int op = 0; op < 3; op++) {
            run_m(op, (unsigned long) &g_bram_buf[BLOCK / 8] + 9);
            ok &= expect("D m-gates-off", op, CAUSE_ECALL_M, 0, 0);
        }
    }

    /* E: program order with no fence. Each op sits between a store and loads
     * of its block in DDR and BRAM: the loads see the store, the store after
     * the op lands, and nothing else changes. */
    for (int region = 0; region < 2; region++) {
        for (int op = 0; op < 3; op++) {
            volatile uint64_t *buf = region ? g_bram_buf : g_ddr_buf;
            unsigned long base = (unsigned long) &buf[BLOCK / 8];
            unsigned long seen, seen2, other;
            fill(buf, 3 * BLOCK / 8);
            buf[BLOCK / 8 + 3] = PATTERN;
            cbo_at(op, base + 0x11);
            seen = buf[BLOCK / 8 + 3];
            buf[BLOCK / 8 + 4] = ~PATTERN;
            cbo_at(op, base + 0x30);
            seen2 = buf[BLOCK / 8 + 4];
            other = buf[BLOCK / 8 + 7];
            int e_ok = seen == PATTERN && seen2 == ~PATTERN && other == pattern_at(BLOCK / 8 + 7);
            buf[BLOCK / 8 + 3] = pattern_at(BLOCK / 8 + 3);
            buf[BLOCK / 8 + 4] = pattern_at(BLOCK / 8 + 4);
            report(e_ok, region ? "E bram-order" : "E ddr-order", op_name[op]);
            ok &= e_ok;
            ok &= check_intact(region ? "E bram" : "E ddr", op, buf);
        }
    }

    /* F: back-to-back ops over eight blocks with stores and loads between. */
    {
        volatile uint64_t *b = (volatile uint64_t *) 0x81400000ul;
        for (int i = 0; i < 64; i++)
            b[i] = pattern_at((unsigned long) i);
        unsigned long base = (unsigned long) b;
        cbo_at(OP_CLEAN, base);
        cbo_at(OP_FLUSH, base + BLOCK);
        b[9] = PATTERN;
        cbo_at(OP_INVAL, base + 2 * BLOCK);
        unsigned long l1v = b[9];
        cbo_at(OP_CLEAN, base + 3 * BLOCK);
        cbo_at(OP_FLUSH, base + 4 * BLOCK);
        cbo_at(OP_INVAL, base + 5 * BLOCK);
        cbo_at(OP_INVAL, base + 6 * BLOCK);
        unsigned long l6v = b[0x180 / 8];
        int f_ok = l1v == PATTERN && l6v == pattern_at(0x180 / 8);
        for (int i = 0; i < 64; i++)
            f_ok &= b[i] == (i == 9 ? PATTERN : pattern_at((unsigned long) i));
        report(f_ok, "F back-to-back", 0);
        ok &= f_ok;
    }

    /* G: a DMA engine write lands while the CPU cleans and invalidates the
     * block, and a DMA copy reads a block the CPU just wrote and cleaned. The
     * engine is coherent, so the CPU reads the DMA bytes and the copy sees the
     * CPU's bytes, with or without the CMO. */
    {
        int g_ok = 1;
        unsigned long blk = 0x81410000ul;
        volatile uint32_t *w = (volatile uint32_t *) blk;
        for (int d = 0; d < 4; d++) {
            uint32_t pattern = 0x6B000000u + (uint32_t) (d << 8);
            for (int i = 0; i < 16; i++)
                w[i] = 0;
            cbo_at(OP_CLEAN, blk);
            dma_engine_setup(0, (uint32_t) blk, 64, DMA_ENGINE_MODE_FILL, pattern, 0, 0);
            dma_engine_start();
            spin((unsigned long) d * 3);
            cbo_at(OP_INVAL, blk);
            dma_engine_wait();
            cbo_at(OP_INVAL, blk + 32);
            for (int i = 0; i < 16; i++)
                g_ok &= w[i] == pattern + (uint32_t) i;
        }
        unsigned long src = 0x81411000ul, dst = 0x81412000ul;
        volatile uint64_t *s = (volatile uint64_t *) src;
        for (int i = 0; i < 8; i++)
            s[i] = pattern_at((unsigned long) i + 40);
        cbo_at(OP_CLEAN, src);
        __asm__ volatile("fence rw, rw" ::: "memory");
        dma_engine_setup((uint32_t) src, (uint32_t) dst, 64, DMA_ENGINE_MODE_COPY, 0, 0, 0);
        dma_engine_start();
        dma_engine_wait();
        cbo_at(OP_INVAL, dst);
        for (int i = 0; i < 8; i++)
            g_ok &= ((volatile uint64_t *) dst)[i] == pattern_at((unsigned long) i + 40);
        report(g_ok, "G coherent-dma", 0);
        ok &= g_ok;
    }

    /* H: translated (MPRV, MPP=S). Load permission is enough: read-write,
     * read-only and D-clear pages execute; invalid, A-clear and X-only pages
     * (without MXR) take store page faults; X-only with MXR executes; a U page
     * needs SUM; a device leaf is a no-op; a leaf beyond DDR is a store access
     * fault. mtval is the unaligned VA. */
    {
        build_tables();
        for (int p = 0; p < PG_COUNT; p++)
            if (p != PG_BEYOND)
                fill((volatile uint64_t *) FRAME(p), 3 * BLOCK / 8);
        __asm__ volatile("csrw satp, %0\n sfence.vma" : : "r"(SATP_SV39 | (PT_ROOT >> 12)));

        static const struct {
            int page;
            unsigned long extra, cause;
            const char *name;
        } cases[] = {
            {PG_RW, 0, CAUSE_ECALL_M, "H va-rw"},
            {PG_RO, 0, CAUSE_ECALL_M, "H va-readonly"},
            {PG_DCLEAR, 0, CAUSE_ECALL_M, "H va-dirty-clear"},
            {PG_INVALID, 0, CAUSE_STORE_PAGE, "H va-invalid"},
            {PG_ACLEAR, 0, CAUSE_STORE_PAGE, "H va-access-clear"},
            {PG_XONLY, 0, CAUSE_STORE_PAGE, "H va-xonly"},
            {PG_XONLY, MSTATUS_MXR, CAUSE_ECALL_M, "H va-xonly-mxr"},
            {PG_USER, 0, CAUSE_STORE_PAGE, "H va-user-nosum"},
            {PG_USER, MSTATUS_SUM, CAUSE_ECALL_M, "H va-user-sum"},
            {PG_BEYOND, 0, CAUSE_STORE_ACCESS, "H va-beyond-ddr"},
        };
        for (unsigned i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
            for (int op = 0; op < 3; op++) {
                unsigned long va = VA_4K(cases[i].page) + BLOCK + 0x07 + (unsigned long) op;
                run_mprv_s(op, va, cases[i].extra);
                ok &=
                    expect(cases[i].name, op, cases[i].cause, va, cases[i].cause != CAUSE_ECALL_M);
            }
            if (cases[i].page != PG_BEYOND && cases[i].page != PG_INVALID)
                ok &= check_intact(
                    cases[i].name, OP_FLUSH, (volatile uint64_t *) FRAME(cases[i].page));
        }
        for (int op = 0; op < 3; op++) {
            run_mprv_s(op, VA_1G_DEVICE + 0x13ul, 0);
            ok &= expect("H va-device-noop", op, CAUSE_ECALL_M, 0, 0);
        }
        __asm__ volatile("csrw satp, zero\n sfence.vma");
    }

    uart_puts(ok ? "\r\n<<PASS>>\r\n" : "\r\n<<FAIL>>\r\n");
    for (;;) {
    }
    return 0;
}
