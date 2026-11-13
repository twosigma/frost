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
 * Ssnpm (pointer masking for U-mode, senvcfg.PMM bits 33:32) directed test.
 *
 * With PMM = 10 (PMLEN 7) or 11 (PMLEN 16), every explicit U-mode data access
 * ignores the top PMLEN address bits: under Sv39 they become the sign
 * extension of bit 63-PMLEN, under Bare zeros. Each case runs twice: in
 * U-mode itself (mret into U, ecall back) and in M with MPRV and MPP = U,
 * where the effective data privilege U selects senvcfg.PMM as well.
 *
 *   A  PMM WARL: 00, 10 and 11 read back; the reserved 01 keeps the old value.
 *   B  For each PMLEN, under Sv39 (low and upper-half pages) and Bare, over
 *      DDR and low BRAM: ld/sd/amoadd/lr+sc/cbo.zero with tagged pointers;
 *      a store through one tag and a load through another (back to back,
 *      and with the store's base late behind a divide); LR through one tag
 *      and SC through another.
 *   C  Faults after masking: a pointer non-canonical in the unmasked bits is
 *      a page fault (Sv39) or access fault (Bare), and a misaligned access a
 *      misaligned fault; xtval is the transformed address. PMLEN 7 leaves
 *      bits 56:48 unmasked.
 *   D  No masking for S (MPRV, MPP = S) and M (Bare), with MXR set, with
 *      PMM = 00, or for instruction fetch: the tagged pointer faults and
 *      xtval is the untransformed address.
 */

#include <stdint.h>

#include "trap.h"
#include "uart.h"

#define CSR_SENVCFG 0x10A
#define CSR_MENVCFG 0x30A
#define ENVCFG_CBZE (1ul << 7)
#define PMM_SHIFT 32
#define PMM_MASK (3ul << PMM_SHIFT)
#define PMM_OFF 0ul
#define PMM_7 2ul
#define PMM_16 3ul

#define CAUSE_FETCH_ACCESS 1ul
#define CAUSE_LOAD_MISALIGN 4ul
#define CAUSE_LOAD_ACCESS 5ul
#define CAUSE_STORE_MISALIGN 6ul
#define CAUSE_STORE_ACCESS 7ul
#define CAUSE_ECALL_U 8ul
#define CAUSE_FETCH_PAGE 12ul
#define CAUSE_LOAD_PAGE 13ul
#define CAUSE_STORE_PAGE 15ul
#define NO_TRAP (~0ul)

#define MSTATUS_MPRV (1ul << 17)
#define MSTATUS_MXR (1ul << 19)

#define PTE_V (1ul << 0)
#define PTE_R (1ul << 1)
#define PTE_W (1ul << 2)
#define PTE_X (1ul << 3)
#define PTE_U (1ul << 4)
#define PTE_A (1ul << 6)
#define PTE_D (1ul << 7)
#define PTE_PPN(pa) ((((unsigned long) (pa)) >> 12) << 10)
#define SATP_SV39 (8ul << 60)
#define URWAD (PTE_V | PTE_R | PTE_W | PTE_U | PTE_A | PTE_D)

/* Sv39 tables in cached DDR, clear of the program image. */
#define PT_ROOT 0x81000000ul
#define PT_L1 0x81001000ul
#define PT_L1_UP 0x81002000ul
#define PT_L0 0x81003000ul
#define FRAME(n) (0x81100000ul + ((unsigned long) (n) << 12))
/* Low VA window 0x400000 (root[0] -> l1[2] -> l0) and its upper-half twin
 * 0xFFFFFFFFC0400000 (root[511] -> l1_up[2] -> l0). l0[0..3] map DDR frames
 * 0..3, l0[4] the BRAM page. */
#define VA_LO 0x00400000ul
#define VA_UP 0xFFFFFFFFC0400000ul
#define PG_BRAM 4

enum kind { K_LD = 0, K_SD = 1, K_AMO = 2, K_LR = 3, K_SC = 4, K_CBOZ = 5, K_LW = 6, K_SW = 7 };
static const char *const kind_name[8] = {"ld", "sd", "amoadd", "lr", "sc", "cbo.zero", "lw", "sw"};

/* How the access runs: in U, in M with MPRV and MPP = U or S, or in M plain. */
enum how { H_U = 0, H_MPRV_U = 1, H_MPRV_S = 2, H_M = 3 };
static const char *const how_name[4] = {"U", "mprv-U", "mprv-S", "M"};

static volatile unsigned long g_cause;
static volatile unsigned long g_tval;

/* One page of low BRAM. */
static volatile uint64_t g_bram_page[512] __attribute__((aligned(4096)));

__attribute__((naked, aligned(4))) static void pm_trap_handler(void)
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

/*
 * One data access at va. In U the access runs after an mret into U and ends
 * with an ecall (cause 8, recorded as success). With MPRV the M-mode access
 * takes MPP's privilege. Returns the loaded value (LD/LW/AMO/LR) or the SC
 * result; g_cause is NO_TRAP for a successful access.
 */
static unsigned long access(int how, int kind, unsigned long va, unsigned long val)
{
    unsigned long out = 0;
    unsigned long mpp = (how == H_MPRV_S) ? 0x0800ul : 0ul;
    unsigned long mprv = (how == H_MPRV_U || how == H_MPRV_S) ? MSTATUS_MPRV : 0ul;
    unsigned long to_u = (how == H_U);
    g_cause = NO_TRAP;
    g_tval = NO_TRAP;
    __asm__ volatile("la   t0, 1f\n"
                     "csrw mscratch, t0\n"
                     "li   t0, 0x1800\n"
                     "csrc mstatus, t0\n"
                     "csrs mstatus, %[mpp]\n"
                     "csrs mstatus, %[mprv]\n"
                     "beqz %[to_u], 3f\n"
                     "la   t0, 3f\n"
                     "csrw mepc, t0\n"
                     "mret\n"
                     "3:\n"
                     "li   t2, 1\n"
                     "beq  %[k], t2, 11f\n"
                     "li   t2, 2\n"
                     "beq  %[k], t2, 12f\n"
                     "li   t2, 3\n"
                     "beq  %[k], t2, 13f\n"
                     "li   t2, 4\n"
                     "beq  %[k], t2, 14f\n"
                     "li   t2, 5\n"
                     "beq  %[k], t2, 15f\n"
                     "li   t2, 6\n"
                     "beq  %[k], t2, 16f\n"
                     "li   t2, 7\n"
                     "beq  %[k], t2, 17f\n"
                     "ld   %[out], 0(%[va])\n"
                     "j    4f\n"
                     "11: sd %[val], 0(%[va])\n"
                     "j    4f\n"
                     "12: amoadd.d %[out], %[val], (%[va])\n"
                     "j    4f\n"
                     "13: lr.d %[out], (%[va])\n"
                     "j    4f\n"
                     "14: sc.d %[out], %[val], (%[va])\n"
                     "j    4f\n"
                     "15: .insn i 0x0F, 2, x0, %[va], 4\n"
                     "j    4f\n"
                     "16: lw %[out], 0(%[va])\n"
                     "j    4f\n"
                     "17: sw %[val], 0(%[va])\n"
                     "4:\n"
                     "bnez %[to_u], 6f\n"
                     "1:\n"
                     "csrc mstatus, %[mprv]\n"
                     "j    7f\n"
                     "6: ecall\n"
                     "7:\n"
                     : [out] "+&r"(out)
                     : [va] "r"(va),
                       [val] "r"(val),
                       [k] "r"((unsigned long) kind),
                       [mpp] "r"(mpp),
                       [mprv] "r"(mprv),
                       [to_u] "r"(to_u)
                     : "t0", "t1", "t2", "t3", "memory");
    if (to_u && g_cause == CAUSE_ECALL_U) {
        g_cause = NO_TRAP;
        g_tval = NO_TRAP;
    }
    return out;
}

/*
 * A store through st_va, then a load through ld_va, in one privilege window.
 * With late set, the store's base waits for a divide, so the younger load
 * issues first and must be ordered behind the store when the store's
 * transformed address resolves.
 */
static unsigned long
store_load(int how, unsigned long st_va, unsigned long ld_va, unsigned long val, int late)
{
    unsigned long out = 0;
    unsigned long mprv = (how == H_MPRV_U) ? MSTATUS_MPRV : 0ul;
    unsigned long to_u = (how == H_U);
    unsigned long one = 1;
    g_cause = NO_TRAP;
    g_tval = NO_TRAP;
    __asm__ volatile("la   t0, 1f\n"
                     "csrw mscratch, t0\n"
                     "li   t0, 0x1800\n"
                     "csrc mstatus, t0\n"
                     "csrs mstatus, %[mprv]\n"
                     "beqz %[to_u], 3f\n"
                     "la   t0, 3f\n"
                     "csrw mepc, t0\n"
                     "mret\n"
                     "3:\n"
                     "mv   t1, %[st]\n"
                     "beqz %[late], 5f\n"
                     "divu t1, %[st], %[one]\n"
                     "divu t1, t1, %[one]\n"
                     "5:\n"
                     "sd   %[val], 0(t1)\n"
                     "ld   %[out], 0(%[ld])\n"
                     "bnez %[to_u], 6f\n"
                     "1:\n"
                     "csrc mstatus, %[mprv]\n"
                     "j    7f\n"
                     "6: ecall\n"
                     "7:\n"
                     : [out] "+&r"(out)
                     : [st] "r"(st_va),
                       [ld] "r"(ld_va),
                       [val] "r"(val),
                       [late] "r"((unsigned long) late),
                       [one] "r"(one),
                       [mprv] "r"(mprv),
                       [to_u] "r"(to_u)
                     : "t0", "t1", "t2", "t3", "memory");
    if (to_u && g_cause == CAUSE_ECALL_U) {
        g_cause = NO_TRAP;
        g_tval = NO_TRAP;
    }
    return out;
}

/* LR through one pointer, SC through another, in one privilege window. */
static unsigned long
lr_sc(int how, unsigned long lr_va, unsigned long sc_va, unsigned long val, unsigned long *loaded)
{
    unsigned long out = 0, ld = 0;
    unsigned long mprv = (how == H_MPRV_U) ? MSTATUS_MPRV : 0ul;
    unsigned long to_u = (how == H_U);
    g_cause = NO_TRAP;
    g_tval = NO_TRAP;
    __asm__ volatile(
        "la   t0, 1f\n"
        "csrw mscratch, t0\n"
        "li   t0, 0x1800\n"
        "csrc mstatus, t0\n"
        "csrs mstatus, %[mprv]\n"
        "beqz %[to_u], 3f\n"
        "la   t0, 3f\n"
        "csrw mepc, t0\n"
        "mret\n"
        "3:\n"
        "lr.d %[ld], (%[a])\n"
        "sc.d %[out], %[val], (%[b])\n"
        "bnez %[to_u], 6f\n"
        "1:\n"
        "csrc mstatus, %[mprv]\n"
        "j    7f\n"
        "6: ecall\n"
        "7:\n"
        : [out] "+&r"(out), [ld] "+&r"(ld)
        : [a] "r"(lr_va), [b] "r"(sc_va), [val] "r"(val), [mprv] "r"(mprv), [to_u] "r"(to_u)
        : "t0", "t1", "t2", "t3", "memory");
    if (to_u && g_cause == CAUSE_ECALL_U) {
        g_cause = NO_TRAP;
        g_tval = NO_TRAP;
    }
    *loaded = ld;
    return out;
}

/* Enter U at a (possibly tagged) PC; the fetch fault returns here. */
static void fetch_u(unsigned long pc)
{
    g_cause = NO_TRAP;
    g_tval = NO_TRAP;
    __asm__ volatile("la   t0, 1f\n"
                     "csrw mscratch, t0\n"
                     "li   t0, 0x1800\n"
                     "csrc mstatus, t0\n"
                     "csrw mepc, %0\n"
                     "mret\n"
                     "1:\n"
                     :
                     : "r"(pc)
                     : "t0", "t1", "t2", "t3", "memory");
}

static int g_fails;
static int g_passes;

/* Failures print in full; passes are counted and summarised per section, so
 * the UART does not dominate the simulation time. */
static void report(int ok, const char *name, int how, int kind, unsigned long va)
{
    if (ok) {
        g_passes++;
        return;
    }
    g_fails++;
    uart_puts("[FAIL] ");
    uart_puts(name);
    uart_puts(" ");
    uart_puts(how >= 0 ? how_name[how] : "-");
    uart_puts(" ");
    uart_puts(kind >= 0 ? kind_name[kind] : "-");
    uart_printf(" va=0x%016lx cause=0x%lx tval=0x%lx\r\n", va, g_cause, g_tval);
}

static int expect_trap(
    const char *name, int how, int kind, unsigned long va, unsigned long cause, unsigned long tval)
{
    int ok = g_cause == cause && (cause == NO_TRAP || g_tval == tval);
    report(ok, name, how, kind, va);
    if (!ok)
        uart_printf("  want cause=0x%lx tval=0x%016lx\r\n", cause, tval);
    return ok;
}

static int expect_value(
    const char *name, int how, int kind, unsigned long va, unsigned long got, unsigned long want)
{
    int ok = g_cause == NO_TRAP && got == want;
    report(ok, name, how, kind, va);
    if (!ok)
        uart_printf("  got 0x%016lx want 0x%016lx\r\n", got, want);
    return ok;
}

static unsigned long senvcfg_read(void)
{
    unsigned long v;
    __asm__ volatile("csrr %0, 0x10A" : "=r"(v));
    return v;
}

static void senvcfg_write(unsigned long v)
{
    __asm__ volatile("csrw 0x10A, %0" ::"r"(v) : "memory");
}

static void set_pmm(unsigned long pmm)
{
    senvcfg_write(ENVCFG_CBZE | (pmm << PMM_SHIFT));
}

static volatile unsigned long *const root = (volatile unsigned long *) PT_ROOT;
static volatile unsigned long *const l1 = (volatile unsigned long *) PT_L1;
static volatile unsigned long *const l1_up = (volatile unsigned long *) PT_L1_UP;
static volatile unsigned long *const l0 = (volatile unsigned long *) PT_L0;

static void build_tables(void)
{
    for (int i = 0; i < 512; i++) {
        root[i] = 0;
        l1[i] = 0;
        l1_up[i] = 0;
        l0[i] = 0;
    }
    root[0] = PTE_PPN(PT_L1) | PTE_V;
    root[511] = PTE_PPN(PT_L1_UP) | PTE_V;
    /* Low 2 MiB: identity, U, RWX, so U-mode runs the program from BRAM. */
    l1[0] = PTE_PPN(0) | URWAD | PTE_X;
    l1[2] = PTE_PPN(PT_L0) | PTE_V;
    l1_up[2] = PTE_PPN(PT_L0) | PTE_V;
    for (int i = 0; i < 4; i++)
        l0[i] = PTE_PPN(FRAME(i)) | URWAD;
    l0[PG_BRAM] = PTE_PPN(g_bram_page) | URWAD;
    __asm__ volatile("fence rw, rw" ::: "memory");
}

/* Put tag t in the top pmlen bits of va. */
static unsigned long tag(unsigned long va, int pmlen, unsigned long t)
{
    unsigned long keep = ~0ul >> pmlen;
    return (va & keep) | (t << (64 - pmlen));
}

/* The ignore transformation: sign extension (virt) or zero extension. */
static unsigned long xform(unsigned long a, int pmlen, int virt)
{
    unsigned long keep = ~0ul >> pmlen;
    unsigned long top = (a >> (63 - pmlen)) & 1ul;
    return (a & keep) | ((virt && top) ? ~keep : 0ul);
}

/*
 * Section B for one PMLEN, translation mode and window. base is the address
 * the window's backing word is at (a VA under Sv39, a PA under Bare); mem is
 * the M-mode (untranslated) pointer to the same word.
 */
static void
tagged_accesses(const char *name, int pmlen, int virt, unsigned long base, volatile uint64_t *mem)
{
    const unsigned long tags[4] = {0x5Aul, 0x7Ful, 0x01ul, 0x2Cul};
    for (int how = H_U; how <= H_MPRV_U; how++) {
        for (int i = 0; i < 4; i++) {
            unsigned long t = tags[i] & ((1ul << pmlen) - 1);
            unsigned long t2 = (tags[(i + 1) & 3] ^ 0x15ul) & ((1ul << pmlen) - 1);
            unsigned long off = (unsigned long) i * 0x48ul;
            unsigned long va = tag(base + off, pmlen, t);
            unsigned long va2 = tag(base + off, pmlen, t2);
            unsigned long seed = 0x0123456789ABCDEFul ^ ((unsigned long) pmlen << 40) ^
                                 ((unsigned long) how << 32) ^ off;
            volatile uint64_t *word = mem + off / 8;

            *word = seed;
            expect_value(name, how, K_LD, va, access(how, K_LD, va, 0), seed);
            access(how, K_SD, va, ~seed);
            expect_value(name, how, K_SD, va, *word, ~seed);
            expect_value(name,
                         how,
                         K_LW,
                         va2,
                         access(how, K_LW, va2, 0),
                         (unsigned long) (long) (int) (uint32_t) ~seed);
            access(how, K_SW, va2 + 4, 0x13579BDFul);
            expect_value(name, how, K_SW, va2 + 4, *word >> 32, 0x13579BDFul);
            *word = 40;
            expect_value(name, how, K_AMO, va, access(how, K_AMO, va, 2), 40);
            expect_value(name, how, K_AMO, va, *word, 42);

            /* Store through one tag, load through another: forwarding, and
             * ordering when the store's base arrives late. */
            expect_value(
                "B st-ld-forward", how, K_LD, va2, store_load(how, va, va2, seed + 1, 0), seed + 1);
            expect_value(
                "B st-ld-late", how, K_LD, va2, store_load(how, va2, va, seed + 2, 1), seed + 2);
            expect_value("B st-ld-untagged",
                         how,
                         K_LD,
                         base + off,
                         store_load(how, va, base + off, seed + 3, 1),
                         seed + 3);

            /* LR through one tag, SC through another: the same reservation. */
            {
                unsigned long loaded = 0;
                *word = 77;
                unsigned long sc = lr_sc(how, va, va2, 78, &loaded);
                expect_value("B lr-sc", how, K_SC, va2, (sc << 8) | loaded, 77);
                expect_value("B lr-sc-mem", how, K_SC, va2, *word, 78);
            }
        }
        /* cbo.zero through a tagged pointer zeroes the 64-byte block. */
        {
            unsigned long blk = base + 0x100;
            volatile uint64_t *bw = mem + 0x100 / 8;
            for (int j = 0; j < 8; j++)
                bw[j] = 0xFFFFul + (unsigned long) j;
            unsigned long va = tag(blk + 0x18, pmlen, 0x3ul);
            access(how, K_CBOZ, va, 0);
            unsigned long any = 0;
            for (int j = 0; j < 8; j++)
                any |= bw[j];
            expect_value("B cbo.zero", how, K_CBOZ, va, any, 0);
        }
        (void) virt;
    }
}

/* Section C: faults after masking report the transformed address. */
static void
masked_faults(const char *name, int pmlen, int virt, unsigned long base, unsigned long mis_base)
{
    for (int how = H_U; how <= H_MPRV_U; how++) {
        /* Bit 63-pmlen set over a low address: under Sv39 the transform fills
         * the top with ones, leaving bits 62-pmlen..38 zero; under Bare the
         * address lies above the physical map. */
        unsigned long bad = tag(base, pmlen, 0x55ul & ((1ul << pmlen) - 1)) | (1ul << (63 - pmlen));
        unsigned long cause_ld = virt ? CAUSE_LOAD_PAGE : CAUSE_LOAD_ACCESS;
        unsigned long cause_st = virt ? CAUSE_STORE_PAGE : CAUSE_STORE_ACCESS;
        access(how, K_LD, bad + 8, 0);
        expect_trap(name, how, K_LD, bad + 8, cause_ld, xform(bad + 8, pmlen, virt));
        access(how, K_SD, bad + 16, 1);
        expect_trap(name, how, K_SD, bad + 16, cause_st, xform(bad + 16, pmlen, virt));
        access(how, K_AMO, bad + 24, 1);
        expect_trap(name, how, K_AMO, bad + 24, cause_st, xform(bad + 24, pmlen, virt));
        access(how, K_CBOZ, bad + 64, 0);
        expect_trap(name, how, K_CBOZ, bad + 64, cause_st, xform(bad + 64, pmlen, virt));
        /* A misaligned access through a tagged pointer. Low BRAM keeps the
         * address-misaligned exception under MISALIGNED_HW too. */
        unsigned long mis = tag(mis_base + 0x203, pmlen, 0x6Bul & ((1ul << pmlen) - 1));
        access(how, K_LD, mis, 0);
        expect_trap(name, how, K_LD, mis, CAUSE_LOAD_MISALIGN, xform(mis, pmlen, virt));
        access(how, K_SD, mis, 0);
        expect_trap(name, how, K_SD, mis, CAUSE_STORE_MISALIGN, xform(mis, pmlen, virt));
        /* Under PMLEN 7, bits 56:48 stay address bits. */
        if (pmlen == 7) {
            unsigned long mid = tag(base, 7, 0x22ul) | (0x5Aul << 48);
            access(how, K_LD, mid, 0);
            expect_trap(name, how, K_LD, mid, cause_ld, xform(mid, 7, virt));
        }
    }
}

/* Section D: the same tagged pointer without masking faults with tval = the
 * untransformed address. */
static void unmasked(const char *name, int virt, unsigned long base, unsigned long mbase)
{
    unsigned long va = tag(base, 7, 0x41ul);
    unsigned long cause_ld = virt ? CAUSE_LOAD_PAGE : CAUSE_LOAD_ACCESS;
    if (virt) {
        access(H_MPRV_S, K_LD, va, 0);
        expect_trap(name, H_MPRV_S, K_LD, va, CAUSE_LOAD_PAGE, va);
    }
    /* M without MPRV: untranslated, never masked. */
    unsigned long mva = tag(mbase, 7, 0x41ul);
    access(H_M, K_LD, mva, 0);
    expect_trap(name, H_M, K_LD, mva, CAUSE_LOAD_ACCESS, mva);
    /* MXR set: masking is off for U (both in U and through MPRV). */
    __asm__ volatile("csrs mstatus, %0" ::"r"(MSTATUS_MXR));
    access(H_U, K_LD, va, 0);
    expect_trap(name, H_U, K_LD, va, cause_ld, va);
    access(H_MPRV_U, K_SD, va, 0);
    expect_trap(name, H_MPRV_U, K_SD, va, virt ? CAUSE_STORE_PAGE : CAUSE_STORE_ACCESS, va);
    __asm__ volatile("csrc mstatus, %0" ::"r"(MSTATUS_MXR));
}

int main(void)
{
    uart_puts("\r\n=== Ssnpm pointer masking test ===\r\n");
    set_trap_handler(&pm_trap_handler);
    csr_write(medeleg, 0);
    build_tables();
    for (int p = 0; p < 4; p++)
        for (int i = 0; i < 512; i++)
            ((volatile uint64_t *) FRAME(p))[i] = 0;
    csr_write(0x30A, ENVCFG_CBZE);

    /* A: WARL. */
    {
        senvcfg_write(PMM_7 << PMM_SHIFT);
        unsigned long r7 = senvcfg_read() & PMM_MASK;
        senvcfg_write(1ul << PMM_SHIFT); /* reserved 01: keeps 10 */
        unsigned long r1 = senvcfg_read() & PMM_MASK;
        senvcfg_write(PMM_16 << PMM_SHIFT);
        unsigned long r16 = senvcfg_read() & PMM_MASK;
        senvcfg_write(1ul << PMM_SHIFT); /* keeps 11 */
        unsigned long r1b = senvcfg_read() & PMM_MASK;
        senvcfg_write(0);
        unsigned long r0 = senvcfg_read() & PMM_MASK;
        g_cause = NO_TRAP;
        expect_value("A pmm-10", -1, -1, 0, r7, PMM_7 << PMM_SHIFT);
        expect_value("A pmm-01-keeps-10", -1, -1, 0, r1, PMM_7 << PMM_SHIFT);
        expect_value("A pmm-11", -1, -1, 0, r16, PMM_16 << PMM_SHIFT);
        expect_value("A pmm-01-keeps-11", -1, -1, 0, r1b, PMM_16 << PMM_SHIFT);
        expect_value("A pmm-00", -1, -1, 0, r0, 0);
    }

    for (int virt = 1; virt >= 0; virt--) {
        if (virt)
            __asm__ volatile("csrw satp, %0\n sfence.vma" : : "r"(SATP_SV39 | (PT_ROOT >> 12)));
        else
            __asm__ volatile("csrw satp, zero\n sfence.vma");
        uart_puts(virt ? "--- Sv39 ---\r\n" : "--- Bare ---\r\n");

        /* D first, with PMM = 00: nothing is masked. */
        set_pmm(PMM_OFF);
        unmasked("D pmm-00", virt, virt ? VA_LO : FRAME(0), FRAME(0));

        for (int pmlen = 7; pmlen <= 16; pmlen += 9) {
            set_pmm(pmlen == 7 ? PMM_7 : PMM_16);
            if (virt) {
                tagged_accesses(pmlen == 7 ? "B sv39-ddr-7" : "B sv39-ddr-16",
                                pmlen,
                                1,
                                VA_LO,
                                (volatile uint64_t *) FRAME(0));
                tagged_accesses(pmlen == 7 ? "B sv39-up-7" : "B sv39-up-16",
                                pmlen,
                                1,
                                VA_UP + 0x1000,
                                (volatile uint64_t *) FRAME(1));
                tagged_accesses(pmlen == 7 ? "B sv39-bram-7" : "B sv39-bram-16",
                                pmlen,
                                1,
                                VA_LO + ((unsigned long) PG_BRAM << 12),
                                g_bram_page);
                masked_faults(pmlen == 7 ? "C sv39-7" : "C sv39-16",
                              pmlen,
                              1,
                              VA_LO + 0x2000,
                              VA_LO + ((unsigned long) PG_BRAM << 12));
            } else {
                tagged_accesses(pmlen == 7 ? "B bare-ddr-7" : "B bare-ddr-16",
                                pmlen,
                                0,
                                FRAME(2),
                                (volatile uint64_t *) FRAME(2));
                tagged_accesses(pmlen == 7 ? "B bare-bram-7" : "B bare-bram-16",
                                pmlen,
                                0,
                                (unsigned long) g_bram_page,
                                g_bram_page);
                masked_faults(pmlen == 7 ? "C bare-7" : "C bare-16",
                              pmlen,
                              0,
                              FRAME(3),
                              (unsigned long) g_bram_page);
            }
            /* D: S, M, MXR and fetch stay unmasked. */
            unmasked(pmlen == 7 ? "D unmasked-7" : "D unmasked-16",
                     virt,
                     virt ? VA_LO : FRAME(0),
                     FRAME(0));
            {
                unsigned long pc = tag((unsigned long) &pm_trap_handler, pmlen, 0x3ul);
                fetch_u(pc);
                expect_trap(pmlen == 7 ? "D fetch-7" : "D fetch-16",
                            H_U,
                            -1,
                            pc,
                            virt ? CAUSE_FETCH_PAGE : CAUSE_FETCH_ACCESS,
                            pc);
            }
            uart_printf("%s PMLEN %d: %d checks passed, %d failed so far\r\n",
                        virt ? "Sv39" : "Bare",
                        pmlen,
                        g_passes,
                        g_fails);
        }
    }

    __asm__ volatile("csrw satp, zero\n sfence.vma");
    senvcfg_write(0);
    csr_write(0x30A, 0);
    uart_printf("\r\npasses=%d failures=%d\r\n", g_passes, g_fails);
    uart_puts(g_fails == 0 ? "\r\n<<PASS>>\r\n" : "\r\n<<FAIL>>\r\n");
    for (;;) {
    }
    return 0;
}
