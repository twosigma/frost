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
 * ptw_coherence_test: the page-table walker must see dirty L1D lines.
 *
 * FROST's walker line port ("wup") sits ABOVE the shared level: it reads
 * page-table entries from L2 (or main memory when there is no L2), not from
 * the write-back L1D (hw/rtl/cpu_and_mem/cpu/mmu/ptw.sv line port ->
 * hw/rtl/lib/cache/frost_cache_hierarchy.sv -> L2). The hierarchy's
 * walker_coherence_sequencer keeps those reads coherent: every walk read
 * first probes the L1D (PROBE_CLEAN), so a dirty page-table line is written
 * back and ordered at the shared level ahead of the read. sfence.vma /
 * fence.i still perform an L1D writeback-all (id_stage.sv decodes BOTH
 * SFENCE.VMA and FENCE.I as is_fence_i; sfence.vma additionally
 * flash-invalidates the TLBs), but a walk no longer depends on it.
 *
 * The bug it reproduces (diagnosed on X3 hardware, before the sequencer):
 * Linux __set_memory -> split_linear_mapping replaces a 2 MiB PMD leaf with a
 * pointer to a freshly filled 4 KiB PTE table, then keeps touching the region
 * BEFORE the closing sfence.vma. The L1D evicted the PMD line (holding the
 * new pointer) down to L2 while the new PTE-table lines were still dirty in
 * the L1D. A DTLB miss then walked the new PMD pointer from L2 together with
 * the STALE PTE-table words from L2 -- a page table state that never existed
 * in program order. The RISC-V privileged spec only permits translations that
 * were valid at some point since the last SFENCE.VMA; a torn walk takes a
 * load page fault on a correctly mapped address, or (if a stale word decodes
 * as a leaf) returns valid-looking garbage.
 *
 * This test drives that exact hazard from bare metal. It extends vm_test's
 * M-mode / MPRV-window approach (sw/apps/vm_test/main.c): M-mode fetch stays
 * untranslated, and every translated data access runs in a short MPRV window
 * (MPP=S, MPRV=1). Page tables and the data regions live in cached DDR (they
 * pass through the L1D/L2 hierarchy in either memory tier, so the hazard
 * reproduces in the bram tier too; run with FROST_COCOTB_MEM_CONFIG=ddr for
 * the kernel-faithful cached tier). Code and stack stay clear of the cache
 * indices the test manipulates (stack is uncached low BRAM).
 *
 * Per iteration, for a chosen R (2 MiB VA region), T (new child PTE page) and
 * target page tp inside R, the sequence is:
 *
 *   S1  Seed the child page T and point PMD[R] at a valid, readable 2 MiB leaf
 *       mapping R -> P1 (per-word signatures). The seed is the "stale" content
 *       the walker must NOT observe as a live translation:
 *         - INVALID flavor: T filled with 0 (V=0). A torn walk page-faults.
 *         - DECOY   flavor: T filled with LEGAL A-set 4 KiB leaves -> a decoy
 *           frame carrying a different signature. A torn walk returns wrong
 *           data with no fault -- this rejects any "fault-only" fix.
 *       (Stale words with A=0 would fault under Svade at ptw.sv rather than
 *       mis-map, so the decoy leaf sets A/D.)
 *   S2  sfence.vma. This publishes the OLD contents to L2 (a writeback-all,
 *       not merely to DRAM) and flash-clears the DTLB. This is the "closing
 *       sfence" of the prior mapping; no sfence.vma/fence.i runs after S5.
 *   S3  Touch R once (MPRV window) so the walker installs R's 2 MiB DTLB entry
 *       and we confirm R currently reads its P1 signature.
 *   S4  Evict R's DTLB entry WITHOUT any sfence by touching 24 distinct 2 MiB
 *       superpages OUTSIDE R (the DTLB has 16 entries with rotating
 *       replacement and superpage-masked matching; 16 touches inside one
 *       superpage evict nothing -- dtlb.sv). This is the capacity miss that
 *       forces the S7 walk.
 *   --- no sfence.vma or fence.i from here to S7 ---
 *   S5  Fill all 512 new PTEs of T with aligned 64-bit stores (R -> P1, page by
 *       page: identical data to the old leaf), `fence w,w`, then publish the
 *       PMD pointer PMD[R] -> T. These stores leave T's lines and the PMD line
 *       DIRTY in the L1D; L2 still holds the OLD contents. T's page and the PMD
 *       line sit at distinct L1D indices.
 *   S6  Evict ONLY the PMD line to L2 with a STORE to PMD_line_PA + 0x20000
 *       (the L1D is direct-mapped 128 KiB / 32 B lines, so +128 KiB aliases the
 *       same index with a different tag). A store is used, not a load: a load
 *       can be answered by the load path without displacing the L1D line.
 *       After a drain, a physical reload of the PMD line (which no longer hits
 *       the L1D) forces the writeback to complete through frost_cache's
 *       same-line writeback interlock, and confirms L2 now holds the new
 *       pointer. T's 128 dirty lines are never touched.
 *   S7  Load R+tp (MPRV window). The DTLB misses and the walker reads the new
 *       PMD pointer from L2 and the STALE child words from L2:
 *         - INVALID: V=0 -> load page fault (cause 13).
 *         - DECOY:   stale leaf -> decoy frame -> wrong signature.
 *
 * PASS requires, for every iteration, NO fault AND the exact P1 signature:
 * S7's walk probes the PMD line and then T's line out of the L1D, reads the
 * new table (R -> P1) and returns the P1 signature. With the walker reading
 * the shared level alone (the RTL before walker_coherence_sequencer), every
 * iteration faulted (INVALID) or read the decoy signature (DECOY) and the app
 * printed <<FAIL>>.
 *
 * Note: the isolated DMMU/PTW cocotb benches feed the walker synthetic line
 * responses and so cannot exhibit this; it must run as a full-SoC program.
 */

#include "uart.h"
#include <stdint.h>

/* ------------------------------------------------------------------ *
 * Physical layout (cached DDR, inside the 64 MiB simulation model,
 * clear of any program image). L1D is direct-mapped 128 KiB with 32 B
 * lines: index = PA[16:5], so the L1D "index block" of a 4 KiB page is
 * PA[16:12] (= (PA>>12)&0x1F). Distinct blocks below never collide.
 *
 *   block 0  PT_ROOT      0x8300_0000  Sv39 root (level 2)
 *   block 1  PT_PMD       0x8300_1000  level-1 table (R + filler entries)
 *   block 2  T page 0     0x8300_2000  child level-0 table
 *   block 3  DECOY_FRAME  0x8300_3000  wrong-data frame for the DECOY flavor
 *   block 4  OUT_SCRATCH  0x8300_4000  critical-window outputs (safe index)
 *   block 6  T page 1     0x8300_6000
 *   block 10 T page 2     0x8300_A000
 *   block 1  ALIAS        0x8302_1xxx  PMD_line + 0x20000 (evict scratch)
 *   P1       0x8340_0000  R's physical 2 MiB region (2 MiB aligned)
 *   P_FILLER 0x8380_0000  filler superpage target (2 MiB aligned)
 * ------------------------------------------------------------------ */
#define PT_ROOT 0x83000000ul
#define PT_PMD 0x83001000ul
#define DECOY_FRAME 0x83003000ul
#define OUT_SCRATCH 0x83004000ul
#define P1_BASE 0x83400000ul
#define P_FILLER 0x83800000ul
#define L1D_ALIAS_STRIDE 0x20000ul /* 128 KiB: same L1D index, different tag */

static const unsigned long T_PAGES[3] = {
    0x83002000ul,
    0x83006000ul,
    0x8300A000ul,
};

/* Virtual layout: vpn2 = 0 for everything, so root[0] -> PT_PMD.
 *   R:       vpn1 = Rv1;   VA = Rv1 << 21
 *   fillers: vpn1 = 0x80 .. 0x97 (24 superpages OUTSIDE any R). */
#define R_VA(rv1) (((unsigned long) (rv1)) << 21)
#define FILLER_VA(i) (((unsigned long) (0x80 + (i))) << 21)
#define NUM_FILLERS 24u

#define PTE_V (1ul << 0)
#define PTE_R (1ul << 1)
#define PTE_W (1ul << 2)
#define PTE_X (1ul << 3)
#define PTE_U (1ul << 4)
#define PTE_A (1ul << 6)
#define PTE_D (1ul << 7)
#define PTE_PPN(pa) ((((unsigned long) (pa)) >> 12) << 10)

#define PTE_LEAF_RW (PTE_V | PTE_R | PTE_W | PTE_A | PTE_D) /* 0xC7 */
#define PTE_LEAF_RO_A (PTE_V | PTE_R | PTE_A | PTE_D)       /* 0xC3, A set */
#define PTE_PTR (PTE_V)                                     /* non-leaf */

#define SATP_SV39 (8ul << 60)

enum {
    FLAVOR_INVALID = 0, /* stale seed decodes V=0 -> torn walk page-faults */
    FLAVOR_DECOY = 1,   /* stale seed is a legal A-set leaf -> wrong data  */
};

struct iter_cfg {
    unsigned rv1;    /* PMD index (vpn1) for R */
    unsigned tp;     /* target 4 KiB page within R (vpn0); also its P1 block */
    unsigned t_page; /* index into T_PAGES */
    unsigned flavor;
};

/* Each tp is chosen so R's target P1 page (L1D block tp&0x1F) does not collide
 * with any reserved block {0,1,2,3,4,6,10}. */
static const struct iter_cfg CFGS[] = {
    {0x20, 12, 0, FLAVOR_INVALID},
    {0x21, 5, 1, FLAVOR_DECOY},
    {0x22, 7, 2, FLAVOR_INVALID},
    {0x23, 8, 0, FLAVOR_DECOY},
    {0x24, 9, 1, FLAVOR_INVALID},
    {0x25, 11, 2, FLAVOR_DECOY},
};
#define NUM_CFGS (sizeof(CFGS) / sizeof(CFGS[0]))

/* ------------------------------------------------------------------ *
 * Trap plumbing (vm_test shape). The M-mode handler records the first
 * trap of a window and returns to the mscratch continuation with MPP=M
 * forced, so the continuation runs untranslated even while MPRV is up.
 * ------------------------------------------------------------------ */
static volatile unsigned long g_cause;
static volatile unsigned long g_epc;
static volatile unsigned long g_tval;
static volatile unsigned long g_ld_val; /* value captured by translated_load  */

__attribute__((naked, aligned(4))) static void ptw_trap_handler(void)
{
    __asm__ volatile("csrr t0, mcause\n"
                     "la   t1, g_cause\n"
                     "ld   t2, 0(t1)\n"
                     "li   t3, -1\n"
                     "bne  t2, t3, 2f\n"
                     "sd   t0, 0(t1)\n"
                     "csrr t0, mepc\n"
                     "la   t1, g_epc\n"
                     "sd   t0, 0(t1)\n"
                     "csrr t0, mtval\n"
                     "la   t1, g_tval\n"
                     "sd   t0, 0(t1)\n"
                     "2:\n"
                     "csrr t0, mscratch\n"
                     "csrw mepc, t0\n"
                     "li   t0, 0x1800\n" /* MPP=M so the continuation is untranslated */
                     "csrs mstatus, t0\n"
                     "mret\n");
}

static inline void set_trap_handler(void (*h)(void))
{
    __asm__ volatile("csrw mtvec, %0" : : "r"(h));
}

static inline void sfence_vma(void)
{
    __asm__ volatile("sfence.vma" ::: "memory");
}

static inline void write_satp(unsigned long v)
{
    __asm__ volatile("csrw satp, %0" : : "r"(v));
}

/* One translated (S-mode, MPRV) load of `va`. Returns the loaded value on the
 * no-fault path; g_cause stays ~0 on success, or holds the trap cause on a
 * fault. The window touches only `va`, so it is safe outside the critical
 * region (it stores the result to a global). */
static unsigned long translated_load(unsigned long va)
{
    g_cause = ~0ul;
    g_epc = ~0ul;
    g_tval = ~0ul;
    g_ld_val = 0xBADul;
    __asm__ volatile("la   t0, 1f\n"
                     "csrw mscratch, t0\n"
                     "li   t0, 0x1800\n csrc mstatus, t0\n"  /* MPP <- 0 */
                     "li   t0, 0x0800\n csrs mstatus, t0\n"  /* MPP <- S */
                     "li   t0, 0x20000\n csrs mstatus, t0\n" /* MPRV <- 1 */
                     "ld   t2, 0(%0)\n"                      /* translated load */
                     "li   t0, 0x20000\n csrc mstatus, t0\n" /* drop MPRV (no fault) */
                     "la   t1, g_ld_val\n sd t2, 0(t1)\n"    /* capture (untranslated) */
                     "1:\n"
                     "li   t0, 0x20000\n csrc mstatus, t0\n" /* drop MPRV (fault path) */
                     :
                     : "r"(va)
                     : "t0", "t1", "t2", "memory");
    return g_ld_val;
}

static inline void sd_phys(unsigned long addr, unsigned long v)
{
    *(volatile unsigned long *) addr = v;
}

static inline unsigned long ld_phys(unsigned long addr)
{
    return *(volatile unsigned long *) addr;
}

static unsigned long sig1_of(unsigned iter, unsigned tp)
{
    return 0x5100000000000000ul | ((unsigned long) iter << 32) | ((unsigned long) tp << 12);
}

static unsigned long sigd_of(unsigned iter, unsigned tp)
{
    return 0xDEC0000000000000ul | ((unsigned long) iter << 32) | ((unsigned long) tp << 12);
}

/* Build the parts of the page tables that never change across iterations:
 * the root's single entry and the 24 filler superpages. */
static void build_static_tables(void)
{
    volatile unsigned long *root = (volatile unsigned long *) PT_ROOT;
    volatile unsigned long *pmd = (volatile unsigned long *) PT_PMD;

    for (int i = 0; i < 512; i++) {
        root[i] = 0;
        pmd[i] = 0;
    }
    root[0] = PTE_PPN(PT_PMD) | PTE_PTR;

    /* Filler 2 MiB leaves -> one shared physical frame; distinct vpn1 each. */
    for (unsigned i = 0; i < NUM_FILLERS; i++)
        pmd[0x80 + i] = PTE_PPN(P_FILLER) | PTE_LEAF_RW;

    /* Seed the decoy frame's target word once (read directly by S7, not
     * walked). */
    sd_phys(DECOY_FRAME, 0); /* placeholder; per-iter value set in do_iter */
    (void) ld_phys(P_FILLER);
}

/* Returns 1 if the iteration passed (no fault AND exact P1 signature). */
static int do_iter(unsigned iter, const struct iter_cfg *c)
{
    const unsigned long T = T_PAGES[c->t_page];
    const unsigned long r_va = R_VA(c->rv1) + (unsigned long) c->tp * 4096ul;
    const unsigned long p1_target = P1_BASE + (unsigned long) c->tp * 4096ul;
    const unsigned long sig1 = sig1_of(iter, c->tp);
    const unsigned long sigd = sigd_of(iter, c->tp);
    const unsigned long pmd_entry = PT_PMD + (unsigned long) c->rv1 * 8ul;
    const unsigned long pmd_line = pmd_entry & ~31ul;
    const unsigned long alias = pmd_line + L1D_ALIAS_STRIDE;
    const unsigned long pmd_ptr = PTE_PPN(T) | PTE_PTR;
    const unsigned long seed =
        (c->flavor == FLAVOR_DECOY) ? (PTE_PPN(DECOY_FRAME) | PTE_LEAF_RO_A) : 0ul;

    volatile unsigned long *pmd = (volatile unsigned long *) PT_PMD;
    volatile unsigned long *t = (volatile unsigned long *) T;

    /* --- S1: seed the child page (the stale contents) and map R via a valid
     * 2 MiB leaf; seed R's P1 target word and the decoy word. --- */
    for (int k = 0; k < 512; k++)
        t[k] = seed;
    pmd[c->rv1] = PTE_PPN(P1_BASE) | PTE_LEAF_RW; /* 2 MiB leaf, PPN 2 MiB aligned */
    sd_phys(p1_target, sig1);
    if (c->flavor == FLAVOR_DECOY)
        sd_phys(DECOY_FRAME, sigd);

    /* --- S2: publish the OLD contents to L2 (writeback-all) and clear the
     * DTLB. This is the last sfence before the hazard. --- */
    sfence_vma();
    write_satp(SATP_SV39 | (PT_ROOT >> 12));

    /* --- S3: install R's 2 MiB DTLB entry and confirm it reads its P1
     * signature (a torn walk later is therefore on a correctly mapped VA). --- */
    unsigned long r0 = translated_load(r_va);
    if (g_cause != ~0ul || r0 != sig1) {
        uart_printf("  [setup] iter %u: baseline R read faulted/wrong: cause=%lx val=%lx "
                    "want=%lx\r\n",
                    iter,
                    g_cause,
                    r0,
                    sig1);
        return 0;
    }

    /* --- S4: evict R from the DTLB with 24 distinct superpages OUTSIDE R (no
     * sfence). Rotating replacement overwrites all 16 entries. --- */
    for (unsigned i = 0; i < NUM_FILLERS; i++) {
        (void) translated_load(FILLER_VA(i));
        if (g_cause != ~0ul) {
            uart_printf("  [setup] iter %u: filler %u faulted cause=%lx tval=%lx\r\n",
                        iter,
                        i,
                        g_cause,
                        g_tval);
            return 0;
        }
    }

    /* Outputs live at a fixed L1D index (block 4) distinct from T, so writing
     * them mid-window cannot evict a dirty child line. Presets before the
     * critical window (T is still clean here). */
    sd_phys(OUT_SCRATCH + 0, 0xBADul); /* pmd readback  */
    sd_phys(OUT_SCRATCH + 8, 0xBADul); /* S7 load value */
    g_cause = ~0ul;
    g_epc = ~0ul;
    g_tval = ~0ul;

    /* --- S5/S6/S7 as one block: no compiler-inserted cached access can slip
     * between filling T and the faulting load. Every cached access here is to
     * a controlled address at a block distinct from T's dirty lines. --- */
    __asm__ volatile(
        /* S5: fill all 512 PTEs of T (R page k -> P1 page k), leaving them
         * dirty in the L1D while L2 still holds the seed. */
        "  mv   t0, %[T]\n"
        "  mv   t1, %[P1]\n"
        "  li   t2, 512\n"
        "  li   t4, 4096\n"
        "5:\n"
        "  srli t3, t1, 12\n"
        "  slli t3, t3, 10\n"
        "  ori  t3, t3, 0xC7\n" /* V|R|W|A|D */
        "  sd   t3, 0(t0)\n"
        "  addi t0, t0, 8\n"
        "  add  t1, t1, t4\n"
        "  addi t2, t2, -1\n"
        "  bnez t2, 5b\n"
        "  fence w, w\n" /* PTE writes ordered before the PMD publish */
        /* S5b: publish the PMD pointer -> T (dirty in the L1D). */
        "  sd   %[pmdptr], 0(%[pmdent])\n"
        "  fence\n" /* PMD store settled into the L1D before eviction */
        /* S6a: evict ONLY the PMD line with a STORE to the +128 KiB alias. */
        "  sd   x0, 0(%[alias])\n"
        "  fence\n" /* drain: the eviction writeback is now in flight */
        /* S6b: reload the PMD line (no L1D hit) -> completes the writeback via
         * the same-line interlock; L2 now holds the new pointer. */
        "  ld   t5, 0(%[pmdent])\n"
        "  sd   t5, 0(%[scratch])\n"
        /* S7: translated load of R. DTLB miss -> walk reads the new pointer and
         * the stale child words from L2. */
        "  la   t0, 1f\n csrw mscratch, t0\n"
        "  li   t0, 0x1800\n csrc mstatus, t0\n"
        "  li   t0, 0x0800\n csrs mstatus, t0\n"
        "  li   t0, 0x20000\n csrs mstatus, t0\n"
        "  ld   t6, 0(%[rva])\n"
        "  li   t0, 0x20000\n csrc mstatus, t0\n"
        "  sd   t6, 8(%[scratch])\n"
        "1:\n"
        "  li   t0, 0x20000\n csrc mstatus, t0\n"
        :
        : [T] "r"(T),
          [P1] "r"(P1_BASE),
          [pmdptr] "r"(pmd_ptr),
          [pmdent] "r"(pmd_entry),
          [alias] "r"(alias),
          [rva] "r"(r_va),
          [scratch] "r"(OUT_SCRATCH)
        : "t0", "t1", "t2", "t3", "t4", "t5", "t6", "memory");

    unsigned long pmd_readback = ld_phys(OUT_SCRATCH + 0);
    unsigned long r_val = ld_phys(OUT_SCRATCH + 8);
    int faulted = (g_cause != ~0ul);

    /* pmd_readback confirms the eviction/writeback landed (L2 has the pointer).
     * If it did not, the walk would have found the old 2 MiB leaf and the
     * "pass" would be meaningless -- flag it. */
    int conditions_ok = (pmd_readback == pmd_ptr);

    int ok = conditions_ok && !faulted && (r_val == sig1);

    uart_printf("  iter %u %s R=%lx tp=%u T=%lx: ",
                iter,
                c->flavor == FLAVOR_DECOY ? "DECOY" : "INVALID",
                r_va,
                c->tp,
                T);
    if (!conditions_ok) {
        uart_printf("SETUP-FAIL pmd_readback=%lx want=%lx (eviction/writeback not confirmed)\r\n",
                    pmd_readback,
                    pmd_ptr);
    } else if (faulted) {
        uart_printf("FAIL torn walk faulted: cause=%lu tval=%lx epc=%lx (want value %lx)\r\n",
                    g_cause,
                    g_tval,
                    g_epc,
                    sig1);
    } else if (r_val != sig1) {
        uart_printf("FAIL torn walk mis-mapped: got %lx%s, want %lx\r\n",
                    r_val,
                    (r_val == sigd) ? " (the decoy signature)" : "",
                    sig1);
    } else {
        uart_printf("PASS value=%lx\r\n", r_val);
    }
    return ok;
}

int main(void)
{
    int all_ok = 1;

    uart_printf("\r\nptw_coherence_test: walker-vs-dirty-L1D coherence (%u iterations)\r\n",
                (unsigned) NUM_CFGS);

    set_trap_handler(&ptw_trap_handler);
    build_static_tables();

    for (unsigned i = 0; i < NUM_CFGS; i++)
        all_ok &= do_iter(i, &CFGS[i]);

    write_satp(0);

    uart_printf(all_ok ? "\r\n<<PASS>>\r\n" : "\r\n<<FAIL>>\r\n");
    for (;;) {
    }
    return 0;
}
