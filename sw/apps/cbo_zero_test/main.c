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
 * Zicboz directed test. cbo.zero zeroes the naturally aligned 64-byte block
 * containing rs1, in cached DDR and in low BRAM, and leaves its neighbours
 * untouched. It acts as a store: an unaligned rs1 never traps as misaligned,
 * a fault reports rs1 itself in mtval, a device or out-of-map block is a
 * store access fault, and a translated block takes store page faults.
 * Younger loads see the zeros without a fence; a younger store to the block
 * lands over them; a dirty line is overwritten.
 *
 * CBZE gate: cbo.zero is always legal in M, legal in S with menvcfg.CBZE,
 * and legal in U with menvcfg.CBZE and senvcfg.CBZE; otherwise it raises an
 * illegal-instruction exception and writes nothing.
 *
 * The handler returns through an mscratch continuation (vm_test shape).
 * Translated cases run in M with MPRV and MPP=S, so the gate (current
 * privilege) passes and translation uses S permissions.
 *
 * Line-scope cases (H) use blocks of cached DDR that nothing has touched, so
 * the home installs each as zeros without a memory read. DMA writes and
 * reads of a block race its cbo.zero at several delays: each sector ends
 * either all written or all zero, never mixed, and a read sees each sector
 * whole. A block held by the L1I refetches its zeros after FENCE.I. Blocks
 * zeroed back to back, with stores and loads beside them, end in program
 * order.
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
#define ENVCFG_CBZE (1ul << 7)
#define CSR_MENVCFG 0x30A
#define CSR_SENVCFG 0x10A

#define CAUSE_ILLEGAL 2ul
#define CAUSE_STORE_ACCESS 7ul
#define CAUSE_ECALL_U 8ul
#define CAUSE_ECALL_S 9ul
#define CAUSE_ECALL_M 11ul
#define CAUSE_STORE_PAGE 15ul

#define PATTERN 0xA5A5C3C3F00F1234ul

/* cbo.zero (rs1): MISC-MEM, funct3 010, funct12 0x004, rd x0. */
#define CBO_ZERO_ASM(reg) ".insn i 0x0F, 2, x0, " reg ", 4\n"

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

/* Three blocks each in low BRAM and cached DDR; tests zero the middle one. */
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

static void report_line(int ok, const char *name)
{
    uart_puts(ok ? "[PASS] " : "[FAIL] ");
    uart_puts(name);
    uart_puts(" cause=");
    uart_hex(g_cause);
    uart_puts(" tval=");
    uart_hex(g_tval);
    uart_puts("\r\n");
}

static int expect(const char *name, unsigned long cause, unsigned long tval, int check_tval)
{
    int ok = (g_cause == cause) && (!check_tval || g_tval == tval);
    report_line(ok, name);
    return ok;
}

static void fill(volatile uint64_t *buf, unsigned long dwords)
{
    for (unsigned long i = 0; i < dwords; i++)
        buf[i] = PATTERN ^ (i * 0x0101010101010101ul);
}

/* Middle block zero (or untouched when zeroed is 0), outer blocks intact. */
static int check_blocks(const char *name, volatile uint64_t *buf, int zeroed)
{
    int ok = 1;
    for (unsigned long i = 0; i < 3 * BLOCK / 8; i++) {
        uint64_t want = PATTERN ^ (i * 0x0101010101010101ul);
        if (zeroed && i >= BLOCK / 8 && i < 2 * BLOCK / 8)
            want = 0;
        if (buf[i] != want) {
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
    uart_puts("\r\n");
    return ok;
}

/* Run cbo.zero (rs1) in M and record any fault; a clean case ends in ecall. */
static void run_m(unsigned long rs1)
{
    g_cause = ~0ul;
    g_tval = ~0ul;
    __asm__ volatile("la   t0, 1f\n"
                     "csrw mscratch, t0\n"
                     "mv   t1, %0\n" CBO_ZERO_ASM("t1") "ecall\n"
                                                        "1:\n"
                     :
                     : "r"(rs1)
                     : "t0", "t1", "t2", "t3", "memory");
}

/* Run cbo.zero (rs1) in M with MPRV and MPP=S: translated with S rights. */
static void run_mprv_s(unsigned long rs1)
{
    g_cause = ~0ul;
    g_tval = ~0ul;
    __asm__ volatile("la   t0, 1f\n"
                     "csrw mscratch, t0\n"
                     "li   t0, 0x1800\n"
                     "csrc mstatus, t0\n"
                     "li   t0, 0x0800\n"
                     "csrs mstatus, t0\n"
                     "li   t0, 0x20000\n"
                     "csrs mstatus, t0\n"
                     "mv   t1, %0\n" CBO_ZERO_ASM("t1") "li   t0, 0x20000\n"
                                                        "csrc mstatus, t0\n"
                                                        "ecall\n"
                                                        "1:\n"
                     :
                     : "r"(rs1)
                     : "t0", "t1", "t2", "t3", "memory");
    __asm__ volatile("li t0, 0x20000\n csrc mstatus, t0" ::: "t0");
}

/* Lower-privilege body: a0 holds rs1. */
__attribute__((naked)) static void lower_body(void)
{
    __asm__ volatile(CBO_ZERO_ASM("a0") "ecall\n"
                                        "j .\n");
}

/* Enter S (mpp=1) or U (mpp=0) at lower_body with a0 = rs1. Returns mcause. */
static unsigned long run_lower(unsigned long mpp, unsigned long rs1)
{
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
                     : "r"(mpp), "r"((unsigned long) &lower_body), "r"(rs1)
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
#define PTE_A (1ul << 6)
#define PTE_D (1ul << 7)
#define PTE_PPN(pa) ((((unsigned long) (pa)) >> 12) << 10)
#define SATP_SV39 (8ul << 60)

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
    /* 1 GiB leaf over the device quadrant: translation succeeds, PMA faults. */
    root[3] = PTE_PPN(0x40000000ul) | PTE_V | PTE_R | PTE_W | PTE_A | PTE_D;
    l1[2] = PTE_PPN(PT_L0) | PTE_V;
    l0[0] = PTE_PPN(FRAME(0)) | PTE_V | PTE_R | PTE_W | PTE_A | PTE_D; /* writable */
    l0[1] = PTE_PPN(FRAME(1)) | PTE_V | PTE_R | PTE_A;                 /* read-only */
    /* l0[2] stays invalid. */
    l0[3] = PTE_PPN(FRAME(3)) | PTE_V | PTE_R | PTE_W | PTE_A; /* D clear (Svade) */
}

/* ---- Line-scope cases: fresh cached-DDR blocks, clear of the tables. ---- */
#define H_BASE 0x81400000ul
#define H_BLOCK(n) (H_BASE + (unsigned long) (n) * 0x1000ul)
#define H_SCRATCH 0x81600000ul
#define H_DELAYS 8

static void cbo_zero_at(unsigned long addr)
{
    __asm__ volatile("mv t0, %0\n" CBO_ZERO_ASM("t0") : : "r"(addr) : "t0", "memory");
}

static void spin(unsigned long n)
{
    for (volatile unsigned long i = 0; i < n; i++) {
    }
}

/* One 32-byte sector: every word equal to its DMA fill value, or zero. */
static int sector_whole(volatile uint32_t *s, uint32_t pattern, int *filled)
{
    int all_fill = 1, all_zero = 1;
    for (int i = 0; i < 8; i++) {
        all_fill &= s[i] == pattern + (uint32_t) i;
        all_zero &= s[i] == 0;
    }
    *filled = all_fill;
    return all_fill || all_zero;
}

static int block_zero(volatile uint64_t *b, int from, int to)
{
    int ok = 1;
    for (int i = from; i < to; i++)
        ok &= b[i] == 0;
    return ok;
}

static void report(int ok, const char *name)
{
    uart_puts(ok ? "[PASS] " : "[FAIL] ");
    uart_puts(name);
    uart_puts("\r\n");
}

/* Call code at addr in M; a fault returns to the continuation. Returns a0, or
 * ~0 with g_cause set when the code traps. */
static unsigned long call_code(unsigned long addr)
{
    unsigned long result;
    g_cause = ~0ul;
    g_tval = ~0ul;
    __asm__ volatile("la   t0, 1f\n"
                     "csrw mscratch, t0\n"
                     "li   a0, -1\n"
                     "jalr ra, 0(%1)\n"
                     "1:\n"
                     "mv   %0, a0\n"
                     : "=r"(result)
                     : "r"(addr)
                     : "t0", "a0", "ra", "memory");
    return result;
}

#define INSN_LI_A0(v) ((uint32_t) (((v) << 20) | (10u << 7) | 0x13u))
#define INSN_RET 0x00008067u

static int line_scope_cases(void)
{
    int ok = 1;

    /* H1: a DMA write fills the upper sector while cbo.zero zeroes the
     * block, at several delays. The upper sector ends whole, the lower one
     * zero, and the neighbouring blocks untouched. */
    {
        int h_ok = 1, kept = 0;
        for (int d = 0; d < H_DELAYS; d++) {
            unsigned long blk = H_BLOCK(d) + BLOCK;
            volatile uint64_t *b = (volatile uint64_t *) blk;
            uint32_t pattern = 0x5A000000u + (uint32_t) (d << 8);
            dma_engine_setup(0, (uint32_t) (blk + 32), 32, DMA_ENGINE_MODE_FILL, pattern, 0, 0);
            dma_engine_start();
            spin((unsigned long) d * 3);
            cbo_zero_at(blk + 5);
            dma_engine_wait();
            __asm__ volatile("fence rw, rw" ::: "memory");
            int filled;
            h_ok &= sector_whole((volatile uint32_t *) (blk + 32), pattern, &filled);
            h_ok &= block_zero(b, 0, 4);
            kept += filled;
        }
        report(h_ok, "H1 dma-write-races-zero");
        uart_printf("  H1 sectors keeping the DMA write: %d of %d\r\n", kept, H_DELAYS);
        ok &= h_ok;
    }

    /* H2: a DMA copy of the block runs beside its cbo.zero: the copy sees
     * each sector whole, old or zero, and the block then reads as zeros. */
    {
        int h_ok = 1;
        for (int d = 0; d < H_DELAYS; d++) {
            unsigned long blk = H_BLOCK(16 + d) + BLOCK;
            volatile uint32_t *w = (volatile uint32_t *) blk;
            uint32_t pattern = 0x3C000000u + (uint32_t) (d << 8);
            for (int i = 0; i < 16; i++)
                w[i] = pattern + (uint32_t) (i & 7);
            __asm__ volatile("fence rw, rw" ::: "memory");
            unsigned long dst = H_SCRATCH + (unsigned long) d * BLOCK;
            dma_engine_setup((uint32_t) blk, (uint32_t) dst, 64, DMA_ENGINE_MODE_COPY, 0, 0, 0);
            dma_engine_start();
            spin((unsigned long) d * 3);
            cbo_zero_at(blk);
            dma_engine_wait();
            __asm__ volatile("fence rw, rw" ::: "memory");
            int filled;
            h_ok &= sector_whole((volatile uint32_t *) dst, pattern, &filled);
            h_ok &= sector_whole((volatile uint32_t *) (dst + 32), pattern, &filled);
            h_ok &= block_zero((volatile uint64_t *) blk, 0, 8);
        }
        report(h_ok, "H2 dma-read-during-zero");
        ok &= h_ok;
    }

    /* H3: a block held by the L1I. Code in its upper sector runs; cbo.zero
     * then new code in its lower sector and FENCE.I: the new code runs, and
     * the zeroed upper sector traps as an illegal instruction. */
    {
        unsigned long blk = H_BLOCK(32);
        volatile uint32_t *code = (volatile uint32_t *) blk;
        code[8] = INSN_LI_A0(42u);
        code[9] = INSN_RET;
        __asm__ volatile("fence rw, rw\n fence.i" ::: "memory");
        unsigned long first = call_code(blk + 32);
        cbo_zero_at(blk);
        code[0] = INSN_LI_A0(7u);
        code[1] = INSN_RET;
        __asm__ volatile("fence rw, rw\n fence.i" ::: "memory");
        unsigned long second = call_code(blk);
        unsigned long zeroed = call_code(blk + 32);
        int h_ok = first == 42 && second == 7 && zeroed == ~0ul && g_cause == CAUSE_ILLEGAL;
        report(h_ok, "H3 l1i-held-block");
        ok &= h_ok;
    }

    /* H4: eight blocks zeroed back to back with no fence: a store before,
     * a store between and loads right behind them land in program order. */
    {
        unsigned long base = H_BLOCK(40);
        volatile uint64_t *b = (volatile uint64_t *) base;
        unsigned long l3, l5, l6;
        b[3 * 8 + 2] = PATTERN; /* before its cbo.zero */
        __asm__ volatile("mv   t0, %[base]\n" CBO_ZERO_ASM("t0") "addi t0, t0, 64\n" CBO_ZERO_ASM("t0") "addi t0, t0, 64\n" CBO_ZERO_ASM(
                             "t0") "addi t0, t0, 64\n" CBO_ZERO_ASM("t0") "sd   %[pat], "
                                                                          "0xF8(%[base])\n" /* block
                                                                                               3,
                                                                                               after
                                                                                               its
                                                                                               cbo.zero
                                                                                             */
                                                                          "addi t0, t0, "
                                                                          "64\n" CBO_ZERO_ASM("t0") "addi t0, t0, 64\n" CBO_ZERO_ASM(
                                                                              "t0") "ld   %[l5], "
                                                                                    "0x168(%[base])"
                                                                                    "\n"
                                                                                    "addi t0, t0, "
                                                                                    "64"
                                                                                    "\n" CBO_ZERO_ASM(
                                                                                        "t0") "ld  "
                                                                                              " %["
                                                                                              "l6],"
                                                                                              " 0x1"
                                                                                              "80(%"
                                                                                              "[bas"
                                                                                              "e])"
                                                                                              "\n"
                                                                                              "addi"
                                                                                              " t0,"
                                                                                              " t0,"
                                                                                              " 64"
                                                                                              "\n" CBO_ZERO_ASM(
                                                                                                  "t0") "ld   %[l3], 0xF8(%[base])\n"
                         : [l3] "=&r"(l3), [l5] "=&r"(l5), [l6] "=&r"(l6)
                         : [base] "r"(base), [pat] "r"(PATTERN)
                         : "t0", "memory");
        int h_ok = l3 == PATTERN && l5 == 0 && l6 == 0;
        for (int i = 0; i < 64; i++)
            h_ok &= b[i] == (i == 3 * 8 + 7 ? PATTERN : 0);
        report(h_ok, "H4 back-to-back");
        ok &= h_ok;
    }

    /* H5: store, cbo.zero, load on a fresh block, and cbo.zero then load. */
    {
        volatile uint64_t *b = (volatile uint64_t *) H_BLOCK(48);
        volatile uint64_t *c = (volatile uint64_t *) H_BLOCK(49);
        unsigned long after_store, after_zero;
        __asm__ volatile("sd   %[pat], 40(%[b])\n"
                         "mv   t0, %[b]\n" CBO_ZERO_ASM("t0") "ld   %[s], 40(%[b])\n"
                                                              "mv   t0, %[c]\n" CBO_ZERO_ASM(
                                                                  "t0") "ld   %[z], 16(%[c])\n"
                         : [s] "=&r"(after_store), [z] "=&r"(after_zero)
                         : [b] "r"(b), [c] "r"(c), [pat] "r"(PATTERN)
                         : "t0", "memory");
        int h_ok =
            after_store == 0 && after_zero == 0 && block_zero(b, 0, 8) && block_zero(c, 0, 8);
        report(h_ok, "H5 store-zero-load");
        ok &= h_ok;
    }
    return ok;
}

int main(void)
{
    int ok = 1;
    unsigned long cause;

    uart_puts("\r\n=== cbo.zero test ===\r\n");
    set_trap_handler(&cbo_trap_handler);
    csr_write(medeleg, 0);

    /* A: M-mode zeroes the block containing an unaligned rs1, cached DDR. */
    fill(g_ddr_buf, 3 * BLOCK / 8);
    run_m((unsigned long) &g_ddr_buf[BLOCK / 8] + 0x2B);
    ok &= expect("A ddr-m-retires", CAUSE_ECALL_M, 0, 0);
    ok &= check_blocks("A ddr-block", g_ddr_buf, 1);

    /* B: the same in low BRAM, with rs1 at the block's last byte. */
    fill(g_bram_buf, 3 * BLOCK / 8);
    run_m((unsigned long) &g_bram_buf[BLOCK / 8] + 0x3F);
    ok &= expect("B bram-m-retires", CAUSE_ECALL_M, 0, 0);
    ok &= check_blocks("B bram-block", g_bram_buf, 1);

    /* C: younger accesses in program order with no fence: a load sees the
     * zeros, a younger store lands over them, and a load before the zero
     * sees the old value. */
    for (int region = 0; region < 2; region++) {
        volatile uint64_t *buf = region ? g_bram_buf : g_ddr_buf;
        unsigned long base = (unsigned long) &buf[BLOCK / 8];
        unsigned long before, after, stored, neighbour;
        fill(buf, 3 * BLOCK / 8);
        __asm__ volatile(
            "ld   %[b4], 0x38(%[base])\n"
            "addi t0, %[base], 0x11\n" CBO_ZERO_ASM("t0") "ld   %[a4], 0x38(%[base])\n"
                                                          "sd   %[pat], 8(%[base])\n"
                                                          "ld   %[st], 8(%[base])\n"
                                                          "ld   %[nb], 16(%[base])\n"
            : [b4] "=&r"(before), [a4] "=&r"(after), [st] "=&r"(stored), [nb] "=&r"(neighbour)
            : [base] "r"(base), [pat] "r"(PATTERN)
            : "t0", "memory");
        int c_ok = before == (PATTERN ^ (15ul * 0x0101010101010101ul)) && after == 0 &&
                   stored == PATTERN && neighbour == 0 && buf[BLOCK / 8 + 1] == PATTERN &&
                   buf[BLOCK / 8] == 0 &&
                   buf[2 * BLOCK / 8] == (PATTERN ^ (16ul * 0x0101010101010101ul));
        uart_puts(c_ok ? "[PASS] " : "[FAIL] ");
        uart_puts(region ? "C bram-order\r\n" : "C ddr-order\r\n");
        ok &= c_ok;
    }

    /* D: a dirty L1D line (just written) is overwritten, and the zeros stay
     * after a fence pushes the stores out. */
    fill(g_ddr_buf, 3 * BLOCK / 8);
    run_m((unsigned long) &g_ddr_buf[BLOCK / 8]);
    __asm__ volatile("fence rw, rw" ::: "memory");
    ok &= check_blocks("D dirty-line", g_ddr_buf, 1);

    /* E: CBZE gate. S needs menvcfg.CBZE; U needs both bits. An illegal
     * cbo.zero writes nothing; a legal one zeroes its block. */
    {
        static const struct {
            unsigned long mpp, menv, senv, cause;
            const char *name;
        } cases[] = {
            {1, 0, 0, CAUSE_ILLEGAL, "E s-m0"},
            {1, 0, ENVCFG_CBZE, CAUSE_ILLEGAL, "E s-m0-s1"},
            {1, ENVCFG_CBZE, 0, CAUSE_ECALL_S, "E s-m1"},
            {0, 0, 0, CAUSE_ILLEGAL, "E u-m0-s0"},
            {0, ENVCFG_CBZE, 0, CAUSE_ILLEGAL, "E u-m1-s0"},
            {0, 0, ENVCFG_CBZE, CAUSE_ILLEGAL, "E u-m0-s1"},
            {0, ENVCFG_CBZE, ENVCFG_CBZE, CAUSE_ECALL_U, "E u-m1-s1"},
        };
        for (unsigned i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
            fill(g_bram_buf, 3 * BLOCK / 8);
            csr_write_num(0x30A, cases[i].menv);
            csr_write_num(0x10A, cases[i].senv);
            cause = run_lower(cases[i].mpp, (unsigned long) &g_bram_buf[BLOCK / 8] + 5);
            ok &= expect(cases[i].name, cases[i].cause, 0, cases[i].cause == CAUSE_ILLEGAL);
            ok &= check_blocks(cases[i].name, g_bram_buf, cause != CAUSE_ILLEGAL);
        }
        csr_write_num(0x30A, 0);
        csr_write_num(0x10A, 0);
        /* M ignores both bits. */
        fill(g_bram_buf, 3 * BLOCK / 8);
        run_m((unsigned long) &g_bram_buf[BLOCK / 8] + 9);
        ok &= expect("E m-cbze0", CAUSE_ECALL_M, 0, 0);
        ok &= check_blocks("E m-cbze0-block", g_bram_buf, 1);
    }

    /* F: untranslated access faults report rs1 itself. */
    {
        unsigned long device = 0x40009013ul; /* unserved device-quadrant page */
        run_m(device);
        ok &= expect("F device-access", CAUSE_STORE_ACCESS, device, 1);
        unsigned long beyond = DDR_LIMIT + 0x101ul;
        run_m(beyond);
        ok &= expect("F beyond-ddr", CAUSE_STORE_ACCESS, beyond, 1);
        unsigned long wild = 0x0000100000000035ul;
        run_m(wild);
        ok &= expect("F wild", CAUSE_STORE_ACCESS, wild, 1);
    }

    /* G: translated (MPRV, MPP=S): a writable page zeroes its physical
     * block; read-only, invalid and D-clear pages take store page faults;
     * a device leaf takes a store access fault. mtval is the unaligned VA. */
    {
        build_tables();
        volatile uint64_t *frame0 = (volatile uint64_t *) FRAME(0);
        volatile uint64_t *frame1 = (volatile uint64_t *) FRAME(1);
        volatile uint64_t *frame3 = (volatile uint64_t *) FRAME(3);
        fill(frame0, 3 * BLOCK / 8);
        fill(frame1, 3 * BLOCK / 8);
        fill(frame3, 3 * BLOCK / 8);
        __asm__ volatile("csrw satp, %0\n sfence.vma" : : "r"(SATP_SV39 | (PT_ROOT >> 12)));

        run_mprv_s(VA_4K(0) + BLOCK + 0x21);
        ok &= expect("G va-writable", CAUSE_ECALL_M, 0, 0);
        ok &= check_blocks("G va-writable-block", frame0, 1);

        unsigned long va = VA_4K(1) + BLOCK + 0x07;
        run_mprv_s(va);
        ok &= expect("G va-readonly", CAUSE_STORE_PAGE, va, 1);
        ok &= check_blocks("G va-readonly-block", frame1, 0);

        va = VA_4K(2) + 0x3A;
        run_mprv_s(va);
        ok &= expect("G va-invalid", CAUSE_STORE_PAGE, va, 1);

        va = VA_4K(3) + BLOCK + 0x01;
        run_mprv_s(va);
        ok &= expect("G va-dirty-clear", CAUSE_STORE_PAGE, va, 1);
        ok &= check_blocks("G va-dirty-clear-block", frame3, 0);

        va = VA_1G_DEVICE + 0x9013ul;
        run_mprv_s(va);
        ok &= expect("G va-device", CAUSE_STORE_ACCESS, va, 1);

        __asm__ volatile("csrw satp, zero\n sfence.vma");
    }

    ok &= line_scope_cases();

    uart_puts(ok ? "\r\n<<PASS>>\r\n" : "\r\n<<FAIL>>\r\n");
    for (;;) {
    }
    return 0;
}
