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
 * Svpbmt directed test. Leaf PTE bits 62:61 (PBMT) select the memory type of a
 * page: 0 PMA, 1 NC, 2 IO, 3 reserved. menvcfg.PBMTE (bit 62) enables them.
 *
 * Faults (load page fault 13 / store page fault 15, mtval = VA):
 *   - any nonzero PBMT while PBMTE is clear,
 *   - PBMT = 3 in a leaf,
 *   - nonzero PBMT in a non-leaf PTE.
 * NC and IO pages are uncached: FROST sends their loads and stores, at the ROB
 * head and in program order, through the uncached alias of DDR into the
 * coherent DMA port, so they read and write the bytes a cacheable mapping of
 * the same frame sees after device completion. Adjacent mixed-view accesses
 * also run with and without the Svpbmt fence/flush/fence sequence. PMA overrides
 * on NC and IO pages (norm:Svpbmt_impl_may_override_pmas): AMOs and SC take a
 * store access fault (7), LR a load access fault (5), cbo.zero a store access
 * fault (7), instruction fetch an instruction access fault (1). The TLBs keep
 * the field, so a second access (a DTLB hit) and an access after the DTLB has
 * been refilled (a second-level TLB hit) behave the same. A 2 MiB IO superpage
 * over DDR and an NC page over low BRAM behave the same way. The alias itself
 * is outside the PMA map: untranslated accesses and PMA leaves there fault.
 * After PBMTE is cleared and sfence.vma executes, the same NC page faults.
 *
 * Data accesses run in M with MPRV and MPP=S, so they translate with S rights;
 * the fetch case enters S. The handler returns through an mscratch
 * continuation (cbo_mgmt_test shape).
 */

#include <stdint.h>

#include "trap.h"
#include "uart.h"

#ifndef FROST_DDR_CAPACITY_LOG2_BYTES
#define FROST_DDR_CAPACITY_LOG2_BYTES 30
#endif
#ifndef SVPBMT_BUS_ERRORS
#define SVPBMT_BUS_ERRORS 0
#endif
/* Bus-fault VA retention reports the program's VA, not the real or encoded
 * alias PA. Set this to zero only when testing an older core without it. */
#ifndef SVPBMT_EXPECT_BUS_FAULT_VA
#define SVPBMT_EXPECT_BUS_FAULT_VA 1
#endif
/* riscv_pkg::PbmtAliasBit: bit 30 for DDR of at most 1 GiB, else the DDR size bit. */
#if FROST_DDR_CAPACITY_LOG2_BYTES <= 30
#define PBMT_ALIAS_OFFSET (1ul << 30)
#else
#define PBMT_ALIAS_OFFSET (1ul << FROST_DDR_CAPACITY_LOG2_BYTES)
#endif

#define MENVCFG_PBMTE (1ul << 62)
#define ENVCFG_CBZE (1ul << 7)

#define CAUSE_FETCH_ACCESS 1ul
#define CAUSE_LOAD_ACCESS 5ul
#define CAUSE_STORE_ACCESS 7ul
#define CAUSE_LOAD_PAGE 13ul
#define CAUSE_STORE_PAGE 15ul
#define NO_TRAP (~0ul)

#define MSTATUS_MPRV (1ul << 17)

#define PTE_V (1ul << 0)
#define PTE_R (1ul << 1)
#define PTE_W (1ul << 2)
#define PTE_X (1ul << 3)
#define PTE_A (1ul << 6)
#define PTE_D (1ul << 7)
#define PTE_PPN(pa) ((((unsigned long) (pa)) >> 12) << 10)
#define PTE_PBMT(v) ((unsigned long) (v) << 61)
#define PBMT_NC 1ul
#define PBMT_IO 2ul
#define PBMT_RES 3ul
#define SATP_SV39 (8ul << 60)
#define RWAD (PTE_V | PTE_R | PTE_W | PTE_A | PTE_D)

/* Sv39 tables in cached DDR, clear of the program image. */
#define PT_ROOT 0x81000000ul
#define PT_L1 0x81001000ul
#define PT_L0 0x81002000ul
#define PT_L0_BAD 0x81003000ul
#define FRAME(n) (0x81100000ul + ((unsigned long) (n) << 12))
#define MEGA_FRAME 0x81200000ul /* 2 MiB aligned */
#define VA_4K(n) (0x00400000ul + ((unsigned long) (n) << 12))
#define VA_MEGA 0x00600000ul
#define VA_BAD_NONLEAF 0x00800000ul

enum {
    PG_PLAIN = 0,
    PG_NC = 1,
    PG_IO = 2,
    PG_RES = 3,
    PG_NC_EXEC = 4,
    PG_BRAM_NC = 5,
    PG_FILL0 = 8, /* PG_FILL0 .. PG_FILL0 + 23: plain pages that refill the DTLB */
    PG_FILLS = 24
};

enum kind { K_LD = 0, K_SD = 1, K_AMO = 2, K_LR = 3, K_SC = 4, K_CBOZ = 5 };
static const char *const kind_name[6] = {"ld", "sd", "amoadd", "lr", "sc", "cbo.zero"};

static volatile unsigned long g_cause;
static volatile unsigned long g_tval;

/* One page of low BRAM, mapped NC. */
static volatile uint64_t g_bram_page[512] __attribute__((aligned(4096)));

__attribute__((naked, aligned(4))) static void pbmt_trap_handler(void)
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

/* One data access at va, translated with S rights (MPRV, MPP=S). Returns the
 * loaded (or SC result) value; g_cause stays NO_TRAP unless it traps. */
static unsigned long access_s(int kind, unsigned long va, unsigned long val)
{
    unsigned long out = 0;
    unsigned long bits = MSTATUS_MPRV;
    g_cause = NO_TRAP;
    g_tval = NO_TRAP;
    __asm__ volatile("la   t0, 1f\n"
                     "csrw mscratch, t0\n"
                     "li   t0, 0x1800\n"
                     "csrc mstatus, t0\n"
                     "li   t0, 0x0800\n"
                     "csrs mstatus, t0\n"
                     "csrs mstatus, %[bits]\n"
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
                     "ld   %[out], 0(%[va])\n"
                     "j    1f\n"
                     "11: sd %[val], 0(%[va])\n"
                     "j    1f\n"
                     "12: amoadd.d %[out], %[val], (%[va])\n"
                     "j    1f\n"
                     "13: lr.d %[out], (%[va])\n"
                     "j    1f\n"
                     "14: sc.d %[out], %[val], (%[va])\n"
                     "j    1f\n"
                     "15: .insn i 0x0F, 2, x0, %[va], 4\n"
                     "1:\n"
                     "csrc mstatus, %[bits]\n"
                     : [out] "+r"(out)
                     : [va] "r"(va), [val] "r"(val), [k] "r"((unsigned long) kind), [bits] "r"(bits)
                     : "t0", "t1", "t2", "t3", "memory");
    return out;
}

/* Enter S at va with translation on; a fetch fault returns here. */
static void fetch_s(unsigned long va)
{
    g_cause = NO_TRAP;
    g_tval = NO_TRAP;
    __asm__ volatile("la   t0, 1f\n"
                     "csrw mscratch, t0\n"
                     "li   t0, 0x1800\n"
                     "csrc mstatus, t0\n"
                     "li   t0, 0x0800\n"
                     "csrs mstatus, t0\n"
                     "csrw mepc, %0\n"
                     "mret\n"
                     "1:\n"
                     :
                     : "r"(va)
                     : "t0", "t1", "t2", "t3", "memory");
}

static void report(int ok, const char *name, const char *detail)
{
    uart_puts(ok ? "[PASS] " : "[FAIL] ");
    uart_puts(name);
    if (detail) {
        uart_puts(" ");
        uart_puts(detail);
    }
    uart_printf(" cause=0x%lx tval=0x%lx\r\n", g_cause, g_tval);
}

static int expect_trap(const char *name, int kind, unsigned long cause, unsigned long va)
{
    int ok = g_cause == cause && (cause == NO_TRAP || g_tval == va);
    report(ok, name, kind >= 0 ? kind_name[kind] : 0);
    return ok;
}

static int expect_value(const char *name, unsigned long got, unsigned long want)
{
    int ok = g_cause == NO_TRAP && got == want;
    report(ok, name, 0);
    if (!ok)
        uart_printf("  got 0x%016lx want 0x%016lx\r\n", got, want);
    return ok;
}

static void sfence_all(void)
{
    __asm__ volatile("sfence.vma" ::: "memory");
}

static volatile unsigned long *const root = (volatile unsigned long *) PT_ROOT;
static volatile unsigned long *const l1 = (volatile unsigned long *) PT_L1;
static volatile unsigned long *const l0 = (volatile unsigned long *) PT_L0;
static volatile unsigned long *const l0_bad = (volatile unsigned long *) PT_L0_BAD;

static void build_tables(void)
{
    for (int i = 0; i < 512; i++) {
        root[i] = 0;
        l1[i] = 0;
        l0[i] = 0;
        l0_bad[i] = 0;
    }
    root[0] = PTE_PPN(PT_L1) | PTE_V;
    l1[2] = PTE_PPN(PT_L0) | PTE_V;
    /* A 2 MiB IO leaf over DDR. */
    l1[3] = PTE_PPN(MEGA_FRAME) | RWAD | PTE_PBMT(PBMT_IO);
    /* A pointer with PBMT set: reserved in a non-leaf, so a page fault. */
    l1[4] = PTE_PPN(PT_L0_BAD) | PTE_V | PTE_PBMT(PBMT_NC);
    l0_bad[0] = PTE_PPN(FRAME(PG_PLAIN)) | RWAD;
    l0[PG_PLAIN] = PTE_PPN(FRAME(PG_PLAIN)) | RWAD;
    l0[PG_NC] = PTE_PPN(FRAME(PG_NC)) | RWAD | PTE_PBMT(PBMT_NC);
    l0[PG_IO] = PTE_PPN(FRAME(PG_IO)) | RWAD | PTE_PBMT(PBMT_IO);
    l0[PG_RES] = PTE_PPN(FRAME(PG_RES)) | RWAD | PTE_PBMT(PBMT_RES);
    l0[PG_NC_EXEC] = PTE_PPN(FRAME(PG_NC_EXEC)) | RWAD | PTE_X | PTE_PBMT(PBMT_NC);
    l0[PG_BRAM_NC] = PTE_PPN(g_bram_page) | RWAD | PTE_X | PTE_PBMT(PBMT_NC);
    for (int i = 0; i < PG_FILLS; i++)
        l0[PG_FILL0 + i] = PTE_PPN(FRAME(PG_FILL0 + i)) | RWAD;
    __asm__ volatile("fence rw, rw" ::: "memory");
}

/* Coherence of an uncached page with the cacheable view of its frame: a
 * cacheable store (dirty in the L1D) is what the uncached load returns, and an
 * uncached store is what the next cacheable load returns. */
static int
coherent_pair(const char *name, unsigned long va, volatile uint64_t *pa, unsigned long seed)
{
    int ok = 1;
    for (int i = 0; i < 4; i++) {
        unsigned long a = seed ^ (0x1111111111111111ul * (unsigned long) (i + 1));
        unsigned long off = (unsigned long) i * 0x208ul;
        pa[off / 8] = a;
        unsigned long got = access_s(K_LD, va + off, 0);
        ok &= expect_value(name, got, a);
        access_s(K_SD, va + off, ~a);
        ok &= expect_trap(name, K_SD, NO_TRAP, 0);
        ok &= expect_value(name, pa[off / 8], ~a);
        /* Back to back, no fence: the uncached load sees the uncached store. */
        access_s(K_SD, va + off + 8, a + 1);
        ok &= expect_value(name, access_s(K_LD, va + off + 8, 0), a + 1);
    }
    return ok;
}

/* AMO, LR, SC and cbo.zero on an uncached page are access faults. */
static int no_atomics(const char *name, unsigned long va)
{
    int ok = 1;
    access_s(K_AMO, va, 1);
    ok &= expect_trap(name, K_AMO, CAUSE_STORE_ACCESS, va);
    access_s(K_LR, va, 0);
    ok &= expect_trap(name, K_LR, CAUSE_LOAD_ACCESS, va);
    access_s(K_SC, va, 1);
    ok &= expect_trap(name, K_SC, CAUSE_STORE_ACCESS, va);
    access_s(K_CBOZ, va, 0);
    ok &= expect_trap(name, K_CBOZ, CAUSE_STORE_ACCESS, va);
    return ok;
}


/* The store and load are adjacent in the unfenced case. Delaying the store
 * value lets the younger load run while the older store waits for its data. */
#define ALIAS_PAIR(store, middle, load)                                                            \
    __asm__ volatile("la t0, 1f\n"                                                                 \
                     "csrw mscratch, t0\n"                                                         \
                     "li t0, 0x1800\n"                                                             \
                     "csrc mstatus, t0\n"                                                          \
                     "li t0, 0x0800\n"                                                             \
                     "csrs mstatus, t0\n"                                                          \
                     "csrs mstatus, %[mprv]\n"                                                     \
                     "mv t4, %[value]\n"                                                           \
                     ".rept 6\n divu t4, t4, %[one]\n .endr\n" store                               \
                     " t4, 0(%[store_va])\n" middle load " %[out], 0(%[load_va])\n"                \
                     "1: csrc mstatus, %[mprv]\n"                                                  \
                     : [out] "+&r"(out)                                                            \
                     : [store_va] "r"(store_va),                                                   \
                       [load_va] "r"(load_va),                                                     \
                       [flush_va] "r"(flush_va),                                                   \
                       [value] "r"(value),                                                         \
                       [one] "r"(1ul),                                                             \
                       [mprv] "r"(MSTATUS_MPRV)                                                    \
                     : "t0", "t1", "t2", "t3", "t4", "memory")

#define ALIAS_SYNC "fence iorw, iorw\n .insn i 0x0f, 2, x0, %[flush_va], 2\n fence iorw, iorw\n"
#define ALIAS_CASE(n, store, load)                                                                 \
    case n:                                                                                        \
        if (ordered) {                                                                             \
            ALIAS_PAIR(store, ALIAS_SYNC, load);                                                   \
        } else {                                                                                   \
            ALIAS_PAIR(store, "", load);                                                           \
        }                                                                                          \
        break

static unsigned long alias_pair(unsigned long store_va,
                                unsigned long load_va,
                                unsigned long flush_va,
                                unsigned long value,
                                int sizes,
                                int ordered)
{
    unsigned long out = 0;
    g_cause = NO_TRAP;
    g_tval = NO_TRAP;
    switch (sizes) {
        ALIAS_CASE(0, "sd", "ld");
        ALIAS_CASE(1, "sb", "ld");
        ALIAS_CASE(2, "sd", "lbu");
        ALIAS_CASE(3, "sw", "lhu");
        ALIAS_CASE(4, "sh", "lwu");
    }
    return out;
}

static unsigned long byte_mask(unsigned int bytes)
{
    return bytes == 8 ? ~0ul : (1ul << (bytes * 8)) - 1;
}

/* Both CBO addresses name the same frame. The sequence must work with either
 * address, in either direction, including when the accesses differ in size.
 * Without it, a load may see the old value, but the store must persist. */
static int alias_orders(void)
{
    static const unsigned int store_bytes[] = {8, 1, 8, 4, 2};
    static const unsigned int load_bytes[] = {8, 8, 1, 2, 4};
    unsigned int cases = 0, stale = 0, failed = 0;
    for (unsigned long pg = PG_NC; pg <= PG_IO; pg++) {
        l0[PG_PLAIN] = PTE_PPN(FRAME(pg)) | RWAD;
        sfence_all();
        for (int reverse = 0; reverse < 2; reverse++) {
            for (int ordered = 0; ordered < 2; ordered++) {
                for (int flush_unc = 0; flush_unc < (ordered ? 2 : 1); flush_unc++) {
                    for (int sizes = 0; sizes < 5; sizes++) {
                        for (unsigned long off = 0; off <= 64; off += 8) {
                            unsigned long cached = VA_4K(PG_PLAIN) + off;
                            unsigned long uncached = VA_4K(pg) + off;
                            volatile unsigned long *pa =
                                (volatile unsigned long *) (FRAME(pg) + off);
                            unsigned long old = 0x123456789abcdef0ul ^ (cases << 8);
                            unsigned long value = ~old;
                            unsigned long mask = byte_mask(store_bytes[sizes]);
                            unsigned long final = (old & ~mask) | (value & mask);
                            unsigned long load_mask = byte_mask(load_bytes[sizes]);
                            *pa = old;
                            __asm__ volatile("fence iorw, iorw" ::: "memory");
                            access_s(K_LD, cached, 0);
                            access_s(K_LD, uncached, 0);
                            unsigned long got = alias_pair(reverse ? cached : uncached,
                                                           reverse ? uncached : cached,
                                                           flush_unc ? uncached : cached,
                                                           value,
                                                           sizes,
                                                           ordered);
                            int good = g_cause == NO_TRAP;
                            if (ordered)
                                good &= got == (final & load_mask);
                            else {
                                good &= got == (final & load_mask) || got == (old & load_mask);
                                stale += got == (old & load_mask);
                            }
                            __asm__ volatile("fence iorw, iorw" ::: "memory");
                            good &= *pa == final;
                            if (!good) {
                                failed++;
                                uart_printf("[FAIL] alias-order pg=%lu reverse=%d ordered=%d "
                                            "flush_unc=%d sizes=%d off=%lu got=%lx want=%lx "
                                            "cause=%lx tval=%lx final=%lx\r\n",
                                            pg,
                                            reverse,
                                            ordered,
                                            flush_unc,
                                            sizes,
                                            off,
                                            got,
                                            final & load_mask,
                                            g_cause,
                                            g_tval,
                                            *pa);
                            }
                            cases++;
                        }
                    }
                }
            }
        }
    }
    l0[PG_PLAIN] = PTE_PPN(FRAME(PG_PLAIN)) | RWAD;
    sfence_all();
    uart_printf("%s alias-orders cases=%u stale-unfenced=%u failed=%u\r\n",
                failed ? "[FAIL]" : "[PASS]",
                cases,
                stale,
                failed);
    return failed == 0;
}

/* A 2 GiB DDR aperture has no encoded alias. Device mappings keep their
 * ordinary register path with either NC or IO; MSIP is safe with MIE clear. */
static int no_alias_map(void)
{
    int ok = 1;
    csr_write(0x30A, ENVCFG_CBZE | MENVCFG_PBMTE);
    __asm__ volatile("csrw satp, %0\n sfence.vma" : : "r"(SATP_SV39 | (PT_ROOT >> 12)));
    for (unsigned long pg = PG_NC; pg <= PG_IO; pg++) {
        unsigned long va = VA_4K(pg) + 0x18;
        access_s(K_LD, va, 0);
        ok &= expect_trap("2g ddr-load", K_LD, CAUSE_LOAD_ACCESS, va);
        access_s(K_SD, va, 7);
        ok &= expect_trap("2g ddr-store", K_SD, CAUSE_STORE_ACCESS, va);
        l0[PG_FILL0] = PTE_PPN(0x40010000ul) | RWAD | PTE_PBMT(pg);
        sfence_all();
        unsigned long device_va = VA_4K(PG_FILL0);
        access_s(K_SD, device_va, 1);
        ok &= expect_trap("2g device-set", K_SD, NO_TRAP, NO_TRAP);
        ok &= expect_value("2g device-read-one", access_s(K_LD, device_va, 0), 1);
        access_s(K_SD, device_va, 0);
        ok &= expect_trap("2g device-clear", K_SD, NO_TRAP, NO_TRAP);
        ok &= expect_value("2g device-read-zero", access_s(K_LD, device_va, 0), 0);
    }
    unsigned long va = VA_MEGA + 0x1230;
    access_s(K_LD, va, 0);
    ok &= expect_trap("2g superpage-load", K_LD, CAUSE_LOAD_ACCESS, va);
    access_s(K_SD, va, 9);
    ok &= expect_trap("2g superpage-store", K_SD, CAUSE_STORE_ACCESS, va);
    fetch_s(VA_4K(PG_NC_EXEC));
    ok &= expect_trap("2g fetch", -1, CAUSE_FETCH_ACCESS, VA_4K(PG_NC_EXEC));
    return ok;
}

/* +axi_rd_error_addr=3000000 fails the DDR fill behind each alias request.
 * Both a load's R error and a partial store's B error must reach retirement.
 * Without bus-fault VA retention, xtval is zero; with it, xtval is the VA. */
static int alias_bus_errors(void)
{
    int ok = 1;
    csr_write(0x30A, ENVCFG_CBZE | MENVCFG_PBMTE);
    __asm__ volatile("csrw satp, %0\n sfence.vma" : : "r"(SATP_SV39 | (PT_ROOT >> 12)));
    for (unsigned long pbmt = PBMT_NC; pbmt <= PBMT_IO; pbmt++) {
        l0[PG_FILL0] = PTE_PPN(0x83000000ul) | RWAD | PTE_PBMT(pbmt);
        sfence_all();
        unsigned long va = VA_4K(PG_FILL0) + 0x18;
        access_s(K_LD, va, 0);
        ok &= expect_trap(
            "alias-bus-load", K_LD, CAUSE_LOAD_ACCESS, SVPBMT_EXPECT_BUS_FAULT_VA ? va : 0);
        va += 8;
        access_s(K_SD, va, 0x12345678);
        ok &= expect_trap(
            "alias-bus-store", K_SD, CAUSE_STORE_ACCESS, SVPBMT_EXPECT_BUS_FAULT_VA ? va : 0);
    }
    /* A successful transfer after the errors checks that the port recovered. */
    *(volatile unsigned long *) 0x83100000ul = 0x5678;
    __asm__ volatile("fence iorw, iorw" ::: "memory");
    l0[PG_FILL0] = PTE_PPN(0x83100000ul) | RWAD | PTE_PBMT(PBMT_IO);
    sfence_all();
    ok &= expect_value("alias-bus-recovery", access_s(K_LD, VA_4K(PG_FILL0), 0), 0x5678);
    return ok;
}

int main(void)
{
    int ok = 1;

    uart_puts("\r\n=== Svpbmt test ===\r\n");
    set_trap_handler(&pbmt_trap_handler);
    csr_write(medeleg, 0);
    build_tables();
    if (FROST_DDR_CAPACITY_LOG2_BYTES == 31) {
        ok = no_alias_map();
        goto done;
    }
    if (SVPBMT_BUS_ERRORS) {
        ok = alias_bus_errors();
        goto done;
    }
    for (int p = 0; p < PG_FILL0 + PG_FILLS; p++)
        for (int i = 0; i < 512; i++)
            ((volatile uint64_t *) FRAME(p))[i] = 0;

    /* A: PBMTE = 0. Svpbmt is absent: any nonzero PBMT field faults. */
    csr_write(0x30A, ENVCFG_CBZE);
    __asm__ volatile("csrw satp, %0\n sfence.vma" : : "r"(SATP_SV39 | (PT_ROOT >> 12)));
    {
        unsigned long va = VA_4K(PG_NC) + 0x18;
        access_s(K_LD, va, 0);
        ok &= expect_trap("A pbmte0-nc-load", K_LD, CAUSE_LOAD_PAGE, va);
        access_s(K_SD, va, 5);
        ok &= expect_trap("A pbmte0-nc-store", K_SD, CAUSE_STORE_PAGE, va);
        va = VA_4K(PG_IO) + 0x20;
        access_s(K_LD, va, 0);
        ok &= expect_trap("A pbmte0-io-load", K_LD, CAUSE_LOAD_PAGE, va);
        va = VA_MEGA + 0x1230;
        access_s(K_LD, va, 0);
        ok &= expect_trap("A pbmte0-io-2m-load", K_LD, CAUSE_LOAD_PAGE, va);
        fetch_s(VA_4K(PG_NC_EXEC));
        ok &= expect_trap("A pbmte0-nc-fetch", -1, 12ul, VA_4K(PG_NC_EXEC));
        /* A PMA page is unaffected. */
        ((volatile uint64_t *) FRAME(PG_PLAIN))[3] = 0x1234;
        ok &= expect_value("A pbmte0-plain", access_s(K_LD, VA_4K(PG_PLAIN) + 0x18, 0), 0x1234);
    }

    /* B: PBMTE = 1 after sfence.vma. Reserved encodings still fault. */
    csr_write(0x30A, ENVCFG_CBZE | MENVCFG_PBMTE);
    sfence_all();
    {
        unsigned long va = VA_4K(PG_RES) + 0x40;
        access_s(K_LD, va, 0);
        ok &= expect_trap("B pbmt3-load", K_LD, CAUSE_LOAD_PAGE, va);
        access_s(K_SD, va, 1);
        ok &= expect_trap("B pbmt3-store", K_SD, CAUSE_STORE_PAGE, va);
        va = VA_BAD_NONLEAF + 0x8;
        access_s(K_LD, va, 0);
        ok &= expect_trap("B nonleaf-pbmt-load", K_LD, CAUSE_LOAD_PAGE, va);
        access_s(K_SD, va, 1);
        ok &= expect_trap("B nonleaf-pbmt-store", K_SD, CAUSE_STORE_PAGE, va);
    }

    /* C: NC and IO 4 KiB pages over DDR, and a 2 MiB IO superpage, are
     * coherent with the cacheable view of their frames. */
    ok &= coherent_pair("C nc", VA_4K(PG_NC), (volatile uint64_t *) FRAME(PG_NC), 0xC0DE0001ul);
    ok &= coherent_pair("C io", VA_4K(PG_IO), (volatile uint64_t *) FRAME(PG_IO), 0xC0DE0002ul);
    ok &= coherent_pair(
        "C io-2m", VA_MEGA + 0x7000, (volatile uint64_t *) (MEGA_FRAME + 0x7000), 0xC0DE0003ul);
    ok &= coherent_pair("C io-2m-high",
                        VA_MEGA + 0x1FF000,
                        (volatile uint64_t *) (MEGA_FRAME + 0x1FF000),
                        0xC0DE0004ul);

    /* D: PMA overrides. The first access of each page walked in C, so the
     * DTLB hit keeps the field: AMOs, LR, SC and cbo.zero are access faults,
     * fetch is an instruction access fault. */
    ok &= no_atomics("D nc", VA_4K(PG_NC) + 0x40);
    ok &= no_atomics("D io", VA_4K(PG_IO) + 0x80);
    ok &= no_atomics("D io-2m", VA_MEGA + 0x3100);
    fetch_s(VA_4K(PG_NC_EXEC) + 0x10);
    ok &= expect_trap("D nc-fetch", -1, CAUSE_FETCH_ACCESS, VA_4K(PG_NC_EXEC) + 0x10);
    /* A PMA page still takes AMOs. */
    ((volatile uint64_t *) FRAME(PG_PLAIN))[4] = 40;
    ok &= expect_value("D plain-amo", access_s(K_AMO, VA_4K(PG_PLAIN) + 0x20, 2), 40);
    ok &= expect_value("D plain-amo-result", ((volatile uint64_t *) FRAME(PG_PLAIN))[4], 42);

    /* E: refill the 16-entry DTLB with plain pages, so the NC and IO pages
     * answer from the second-level TLB (4 KiB array and superpage array); the
     * field survives there too. */
    for (int i = 0; i < PG_FILLS; i++)
        access_s(K_LD, VA_4K(PG_FILL0 + i), 0);
    ok &= no_atomics("E nc-l2tlb", VA_4K(PG_NC) + 0x48);
    for (int i = 0; i < PG_FILLS; i++)
        access_s(K_LD, VA_4K(PG_FILL0 + i), 0);
    ok &= no_atomics("E io-2m-l2tlb", VA_MEGA + 0x5000);
    ok &= coherent_pair("E nc-l2tlb", VA_4K(PG_NC), (volatile uint64_t *) FRAME(PG_NC), 0xE0E0ul);

    ok &= alias_orders();

    /* F: an NC page over low BRAM: uncached loads and stores, no AMOs, no
     * fetch. */
    {
        unsigned long va = VA_4K(PG_BRAM_NC);
        int f_ok = 1;
        for (int i = 0; i < 4; i++) {
            unsigned long a = 0xF00D0000ul + (unsigned long) i;
            g_bram_page[i * 9] = a;
            f_ok &=
                expect_value("F bram-nc-load", access_s(K_LD, va + (unsigned long) i * 72, 0), a);
            access_s(K_SD, va + (unsigned long) i * 72, ~a);
            f_ok &= expect_value("F bram-nc-store", g_bram_page[i * 9], ~a);
        }
        f_ok &= no_atomics("F bram-nc", va + 0x100);
        fetch_s(va + 0x40);
        f_ok &= expect_trap("F bram-nc-fetch", -1, CAUSE_FETCH_ACCESS, va + 0x40);
        ok &= f_ok;
    }

    /* G: the uncached alias is not in the PMA map. An untranslated access to
     * it, and a PMA (PBMT = 0) leaf over it, are access faults; only an NC or
     * IO leaf reaches it. */
    {
        unsigned long alias = FRAME(PG_IO) | PBMT_ALIAS_OFFSET;
        /* M without MPRV: untranslated. */
        g_cause = NO_TRAP;
        g_tval = NO_TRAP;
        __asm__ volatile("la   t0, 1f\n"
                         "csrw mscratch, t0\n"
                         "ld   t1, 0(%0)\n"
                         "1:\n"
                         :
                         : "r"(alias)
                         : "t0", "t1", "t2", "t3", "memory");
        ok &= expect_trap("G bare-alias-load", K_LD, CAUSE_LOAD_ACCESS, alias);
        g_cause = NO_TRAP;
        g_tval = NO_TRAP;
        __asm__ volatile("la   t0, 1f\n"
                         "csrw mscratch, t0\n"
                         "sd   zero, 8(%0)\n"
                         "1:\n"
                         :
                         : "r"(alias)
                         : "t0", "t1", "t2", "t3", "memory");
        ok &= expect_trap("G bare-alias-store", K_SD, CAUSE_STORE_ACCESS, alias + 8);
        l0[PG_FILL0] = PTE_PPN(alias) | RWAD;
        sfence_all();
        access_s(K_LD, VA_4K(PG_FILL0) + 0x10, 0);
        ok &= expect_trap("G pma-leaf-alias-load", K_LD, CAUSE_LOAD_ACCESS, VA_4K(PG_FILL0) + 0x10);
        access_s(K_SD, VA_4K(PG_FILL0) + 0x18, 1);
        ok &=
            expect_trap("G pma-leaf-alias-store", K_SD, CAUSE_STORE_ACCESS, VA_4K(PG_FILL0) + 0x18);
        l0[PG_FILL0] = PTE_PPN(FRAME(PG_FILL0)) | RWAD;
        sfence_all();
    }

    /* H: clearing PBMTE and executing sfence.vma makes the NC page fault
     * again (the TLBs held its translation). */
    csr_write(0x30A, ENVCFG_CBZE);
    sfence_all();
    {
        unsigned long va = VA_4K(PG_NC) + 0x50;
        access_s(K_LD, va, 0);
        ok &= expect_trap("H pbmte-off-sfence", K_LD, CAUSE_LOAD_PAGE, va);
        va = VA_MEGA + 0x50;
        access_s(K_SD, va, 0);
        ok &= expect_trap("H pbmte-off-sfence-2m", K_SD, CAUSE_STORE_PAGE, va);
    }

done:
    __asm__ volatile("csrw satp, zero\n sfence.vma");
    csr_write(0x30A, 0);
    uart_puts(ok ? "\r\n<<PASS>>\r\n" : "\r\n<<FAIL>>\r\n");
    for (;;) {
    }
    return 0;
}
