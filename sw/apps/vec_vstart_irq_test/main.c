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
 * Directed test for taking interrupts between elements of strided, indexed,
 * segment, and fault-only-first vector loads and stores (VLEN 128/256/512):
 *   1. M-mode timer interrupts (MTI + mret) mid-run on long strided (positive,
 *      negative, zero stride, masked, multi-interrupt), indexed (unordered,
 *      ordered, masked, and in-place vd == vs2), segment (unit-stride,
 *      strided, indexed, nf = 2 and nf = 4), and fault-only-first loads and
 *      stores.
 *   2. Handler checks mepc == insn_pc, 0 < vstart < vl, mstatus.VS == Dirty
 *      (even when entered with VS == Clean), interrupt latency bounded by one
 *      element rather than the full instruction, elements < vstart complete,
 *      elements >= vstart untouched, poisons prestart memory to prove resume
 *      never rewrites/re-reads prestart elements, runs scratch vector
 *      arithmetic, restores vl/vtype/vstart, and returns with mret.
 *   3. Fault-only-first mid-run interrupt followed by Sv39 fault trimming at
 *      k > vstart, trimming immediately at k == vstart > 0 (page unmapped in
 *      handler), and masked-off faulting elements preserving vl.
 *   4. Combined mid-run interrupt followed by a synchronous Sv39 page fault on
 *      the same instruction, verifying both vstart paths agree.
 *   5. Delegated S-mode timer interrupts (Sstc stimecmp + sret) across all
 *      four classes (loads and stores).
 */

#include <stdint.h>

#include "csr.h"
#include "mmio.h"
#include "trap.h"
#include "uart.h"

#define DDR_SRC 0x83100000ul
#define DDR_DST 0x83120000ul
#define DDR_VRF 0x83140000ul
#define DDR_SNAP 0x83144000ul
#define PT_ROOT 0x83150000ul
#define PT_L1 0x83151000ul
#define PT_L0 0x83152000ul
#define FRAMES 0x83160000ul
#define VA_BASE 0x00400000ul
#define NUM_FRAMES 16u

#define PTE_V (1ul << 0)
#define PTE_R (1ul << 1)
#define PTE_W (1ul << 2)
#define PTE_U (1ul << 4)
#define PTE_A (1ul << 6)
#define PTE_D (1ul << 7)
#define PTE_PPN(pa) ((((unsigned long) (pa)) >> 12) << 10)
#define PTE_RW (PTE_V | PTE_R | PTE_W | PTE_U | PTE_A | PTE_D)
#define SATP_SV39 (8ul << 60)

#define MSTATUS_SIE (1ul << 1)
#define MSTATUS_MPRV (1ul << 17)
#define MSTATUS_VS (3ul << 9)
#define VS_CLEAN (2ul << 9)
#define VS_DIRTY (3ul << 9)
#define MSTATUS_MPP_S (1ul << 11)

#define CAUSE_MTI (MCAUSE_INTERRUPT_BIT | 7ul)
#define CAUSE_STI (MCAUSE_INTERRUPT_BIT | 5ul)
#define CAUSE_ECALL_S 9ul
#define CAUSE_LOAD_PAGE 13ul
#define CAUSE_STORE_PAGE 15ul

#define VT_E8 0u
#define VT_E16 1u
#define VT_E32 2u
#define VT_M1 0u
#define VT_M2 1u
#define VT_M4 2u
#define VT_M8 3u
#define VT_VTYPE(sew, lmul) ((unsigned long) (((sew) << 3) | (lmul)))

#define SENTINEL32 0x5A5AA5A5u
#define POISON32_BASE 0xDEAD0000u
#define SENTINEL16 0x5A5Au
#define POISON16_BASE 0xDF00u
#define SENTINEL8 0x5Au
#define POISON8_XOR 0xA5u

static int g_ok = 1;
static int g_checks;
static unsigned long g_vlenb;

static void
check(int cond, const char *what, unsigned long ctx, unsigned long got, unsigned long want)
{
    g_checks++;
    if (!cond) {
        g_ok = 0;
        uart_printf("[FAIL] %s (@%lx): got=%lx want=%lx\n", what, ctx, got, want);
    }
}

static inline void cbo_flush_line(unsigned long addr)
{
    __asm__ volatile(".insn i 0x0F, 2, x0, %0, 2" : : "r"(addr) : "memory");
}

static inline unsigned long rd_vl(void)
{
    unsigned long v;
    __asm__ volatile("csrr %0, 0xC20" : "=r"(v));
    return v;
}

static inline unsigned long rd_vtype(void)
{
    unsigned long v;
    __asm__ volatile("csrr %0, 0xC21" : "=r"(v));
    return v;
}

static inline unsigned long rd_vstart(void)
{
    unsigned long v;
    __asm__ volatile("csrr %0, 0x008" : "=r"(v));
    return v;
}

static inline void wr_vstart(unsigned long v)
{
    __asm__ volatile("csrw 0x008, %0" : : "r"(v) : "memory");
}

static inline unsigned long setvl(unsigned long avl, unsigned long vtype)
{
    unsigned long vl;
    __asm__ volatile(".insn r 0x57, 7, 0x40, %0, %1, %2"
                     : "=r"(vl)
                     : "r"(avl), "r"(vtype)
                     : "memory");
    return vl;
}

static inline void set_vs(unsigned long vs)
{
    csr_clear(mstatus, MSTATUS_VS);
    csr_set(mstatus, vs);
}

static inline void load_v8_group(const volatile void *src)
{
    __asm__ volatile(".insn r 0x07, 0, 0x71, x8, %0, x8" : : "r"(src) : "memory");
}

static inline void store_v8_group(volatile void *dst)
{
    __asm__ volatile(".insn r 0x27, 0, 0x71, x8, %0, x8" : : "r"(dst) : "memory");
}

static inline void load_v16_group(const volatile void *src)
{
    __asm__ volatile(".insn r 0x07, 0, 0x71, x16, %0, x8" : : "r"(src) : "memory");
}

static inline void load_v0(const volatile void *src)
{
    __asm__ volatile(".insn r 0x07, 0, 0x01, x0, %0, x8" : : "r"(src) : "memory");
}

static uint32_t vmem_insn(int store, unsigned nf, int mop, int vm, int width, unsigned rs2_or_umop)
{
    return ((uint32_t) (nf - 1u) << 29) | ((uint32_t) mop << 26) | ((uint32_t) vm << 25) |
           ((rs2_or_umop & 31u) << 20) | (10u << 15) | ((uint32_t) width << 12) | (8u << 7) |
           (store ? 0x27u : 0x07u);
}

/* LMUL helpers that yield identical element counts across VLEN 128/256/512. */
static unsigned long lmul_for_32_e32(void)
{
    return g_vlenb == 16u ? VT_M8 : (g_vlenb == 32u ? VT_M4 : VT_M2);
}

static unsigned long lmul_for_64_e16(void)
{
    return g_vlenb == 16u ? VT_M8 : (g_vlenb == 32u ? VT_M4 : VT_M2);
}

static unsigned long lmul_for_seg2_e32(unsigned *out_vl)
{
    if (g_vlenb == 16u) {
        *out_vl = 16u;
        return VT_M4;
    }
    *out_vl = 32u;
    return g_vlenb == 32u ? VT_M4 : VT_M2;
}

static unsigned long emul_regs(unsigned long lmul)
{
    return lmul <= 3u ? (1ul << lmul) : 1ul;
}

/* ========================================================================== */
/* Sv39 page table helpers                                                    */
/* ========================================================================== */

static void setup_sv39(void)
{
    volatile uint64_t *root = (volatile uint64_t *) PT_ROOT;
    volatile uint64_t *l1 = (volatile uint64_t *) PT_L1;
    volatile uint64_t *l0 = (volatile uint64_t *) PT_L0;
    for (unsigned i = 0; i < 512u; i++) {
        root[i] = 0;
        l1[i] = 0;
        l0[i] = 0;
    }
    root[0] = PTE_PPN(PT_L1) | PTE_V;
    l1[2] = PTE_PPN(PT_L0) | PTE_V; /* VA 0x00400000 */
    for (unsigned i = 0; i < NUM_FRAMES; i++)
        l0[i] = PTE_PPN(FRAMES + (unsigned long) i * 4096ul) | PTE_RW;
    csr_write(satp, SATP_SV39 | (PT_ROOT >> 12));
    __asm__ volatile("fence rw, rw\n sfence.vma" ::: "memory");
}

static void map_sv39_page(unsigned page, unsigned long flags)
{
    volatile uint64_t *l0 = (volatile uint64_t *) PT_L0;
    l0[page] = flags ? (PTE_PPN(FRAMES + (unsigned long) page * 4096ul) | flags) : 0ul;
    __asm__ volatile("fence rw, rw\n sfence.vma" ::: "memory");
}

/* ========================================================================== */
/* Trampoline and active-case trap context                                    */
/* ========================================================================== */

/* Dynamic trampoline in cached DDR:
 *   g_code[0]: csrs mstatus, a2   (or nop in S-mode)
 *   g_code[1]: <vector load/store>
 *   g_code[2]: nop                (distinct post-insn PC)
 *   g_code[3]: csrc mstatus, a2   (or nop in S-mode)
 *   g_code[4]: ret                (or ecall in S-mode)
 */
__attribute__((section(".ddr_data"), aligned(64))) static volatile uint32_t g_code[8];

enum addr_mode_e {
    ADDR_STRIDED = 0,
    ADDR_INDEXED = 1,
    ADDR_UNIT_SEG = 2,
};

struct case_ctx {
    const char *name;
    int is_store;
    int is_fof;
    int is_masked;
    int is_smode;
    int addr_mode;
    unsigned nf;
    unsigned eew_bytes;
    unsigned long field_regs;
    unsigned vl;
    unsigned long phys_base; /* physical base for handler verification/poison */
    long stride;
    uint32_t idx_off[64];
    uint64_t mask_bits;
    uint32_t expect_val[4][64];
    uint32_t init_reg[4][64];
    uint32_t init_mem[4][64];

    /* Special actions inside trap handler */
    int multi_irq_target;
    uint64_t multi_irq_step;
    int unmap_vstart_page;
    int expect_page_fault;
    unsigned fault_page_idx;
    unsigned fault_elem_idx;

    /* Observations recorded across traps */
    uint64_t arm_time;
    unsigned irq_count;
    unsigned fault_count;
    unsigned long irq_epc[4];
    unsigned long irq_cause[4];
    unsigned long irq_vstart[4];
    unsigned long irq_vl[4];
    unsigned long irq_vs[4];
    uint64_t irq_lat[4];
    unsigned long fault_epc;
    unsigned long fault_cause;
    unsigned long fault_tval;
    unsigned long fault_vstart;
    unsigned poisoned_upto;
    int snap_bad;
};

static struct case_ctx g_ctx;
static volatile unsigned long g_s_return_pc __attribute__((used));

static uint32_t elem_offset(const struct case_ctx *c, unsigned i, unsigned f)
{
    long off;
    if (c->addr_mode == ADDR_INDEXED) {
        off = (long) c->idx_off[i] + (long) (f * c->eew_bytes);
    } else if (c->addr_mode == ADDR_UNIT_SEG) {
        off = (long) ((i * c->nf + f) * c->eew_bytes);
    } else {
        off = (long) i * c->stride + (long) (f * c->eew_bytes);
    }
    return (uint32_t) off;
}

static unsigned long elem_phys_addr(const struct case_ctx *c, unsigned i, unsigned f)
{
    long off;
    if (c->addr_mode == ADDR_INDEXED) {
        off = (long) c->idx_off[i] + (long) (f * c->eew_bytes);
    } else if (c->addr_mode == ADDR_UNIT_SEG) {
        off = (long) ((i * c->nf + f) * c->eew_bytes);
    } else {
        off = (long) i * c->stride + (long) (f * c->eew_bytes);
    }
    return (unsigned long) ((long) c->phys_base + off);
}

static uint32_t read_phys_elem(unsigned long addr, unsigned eew_bytes)
{
    if (eew_bytes == 1u)
        return *(volatile uint8_t *) addr;
    if (eew_bytes == 2u)
        return *(volatile uint16_t *) addr;
    return *(volatile uint32_t *) addr;
}

static void write_phys_elem(unsigned long addr, unsigned eew_bytes, uint32_t val)
{
    if (eew_bytes == 1u)
        *(volatile uint8_t *) addr = (uint8_t) val;
    else if (eew_bytes == 2u)
        *(volatile uint16_t *) addr = (uint16_t) val;
    else
        *(volatile uint32_t *) addr = val;
}

static uint32_t read_snap_elem(
    const volatile uint8_t *snap, unsigned field_regs, unsigned f, unsigned i, unsigned eew_bytes)
{
    unsigned long base = (unsigned long) f * field_regs * g_vlenb + (unsigned long) i * eew_bytes;
    if (eew_bytes == 1u)
        return snap[base];
    if (eew_bytes == 2u)
        return (uint32_t) snap[base] | ((uint32_t) snap[base + 1u] << 8);
    return (uint32_t) snap[base] | ((uint32_t) snap[base + 1u] << 8) |
           ((uint32_t) snap[base + 2u] << 16) | ((uint32_t) snap[base + 3u] << 24);
}

static void write_vrf_elem(volatile uint8_t *buf,
                           unsigned field_regs,
                           unsigned f,
                           unsigned i,
                           unsigned eew_bytes,
                           uint32_t val)
{
    unsigned long base = (unsigned long) f * field_regs * g_vlenb + (unsigned long) i * eew_bytes;
    buf[base] = (uint8_t) (val & 0xFFu);
    if (eew_bytes >= 2u)
        buf[base + 1u] = (uint8_t) ((val >> 8) & 0xFFu);
    if (eew_bytes >= 4u) {
        buf[base + 2u] = (uint8_t) ((val >> 16) & 0xFFu);
        buf[base + 3u] = (uint8_t) ((val >> 24) & 0xFFu);
    }
}

static uint32_t poison_val(unsigned eew_bytes, unsigned f, unsigned i)
{
    if (eew_bytes == 1u)
        return (uint32_t) ((0xC0u ^ (f << 4) ^ i) & 0xFFu);
    if (eew_bytes == 2u)
        return (uint32_t) ((POISON16_BASE | (f << 8) | i) & 0xFFFFu);
    return POISON32_BASE | (f << 12) | i;
}

static int elem_active(const struct case_ctx *c, unsigned i)
{
    return !c->is_masked || ((c->mask_bits >> i) & 1ull);
}

/* Exercise scratch vector arithmetic inside the interrupt handler to verify
 * that handler vector use does not disturb the interrupted instruction once
 * vl, vtype, and vstart are restored. */
static void handler_scratch_vec_work(void)
{
    setvl(4u, VT_VTYPE(VT_E32, VT_M1));
    __asm__ volatile(".word 0x5e003c57\n" /* vmv.v.i v24, 0 */
                     ".word 0x5e02bc57\n" /* vmv.v.i v24, 5 */
                     ".word 0x0381bc57\n" /* vadd.vi v24, v24, 3 */
                     ::
                         : "memory");
}

static void inspect_and_poison(struct case_ctx *c, unsigned vs, unsigned prev_vs)
{
    volatile uint8_t *snap = (volatile uint8_t *) DDR_SNAP;
    if (!c->is_store) {
        store_v8_group(snap);
        for (unsigned i = prev_vs; i < c->vl; i++) {
            for (unsigned f = 0; f < c->nf; f++) {
                uint32_t got = read_snap_elem(snap, c->field_regs, f, i, c->eew_bytes);
                uint32_t want;
                if (i < vs && elem_active(c, i))
                    want = c->expect_val[f][i];
                else
                    want = c->init_reg[f][i];
                if (got != want && !c->snap_bad) {
                    c->snap_bad = 1;
                    check(0,
                          c->name,
                          ((unsigned long) vs << 16) | ((unsigned long) f << 8) | i,
                          got,
                          want);
                }
            }
        }
        /* Poison source memory for newly completed prestart elements [prev_vs..vs-1].
         * Skip poisoning when stride == 0 (all elements alias the same address). */
        if (!(c->addr_mode == ADDR_STRIDED && c->stride == 0)) {
            for (unsigned i = prev_vs; i < vs; i++) {
                if (!elem_active(c, i))
                    continue;
                for (unsigned f = 0; f < c->nf; f++) {
                    unsigned long pa = elem_phys_addr(c, i, f);
                    write_phys_elem(pa, c->eew_bytes, poison_val(c->eew_bytes, f, i));
                }
            }
        }
    } else {
        for (unsigned i = prev_vs; i < c->vl; i++) {
            /* For stride == 0, every element shares one memory cell; only verify
             * non-aliasing addresses or wait until completion. */
            if (c->addr_mode == ADDR_STRIDED && c->stride == 0)
                break;
            for (unsigned f = 0; f < c->nf; f++) {
                unsigned long pa = elem_phys_addr(c, i, f);
                uint32_t got = read_phys_elem(pa, c->eew_bytes);
                uint32_t want;
                if (i < vs && elem_active(c, i))
                    want = c->expect_val[f][i];
                else
                    want = c->init_mem[f][i];
                if (got != want && !c->snap_bad) {
                    c->snap_bad = 1;
                    check(0,
                          c->name,
                          ((unsigned long) vs << 16) | ((unsigned long) f << 8) | i,
                          got,
                          want);
                }
            }
        }
        /* Poison destination memory for prestart elements [prev_vs..vs-1]. */
        if (!(c->addr_mode == ADDR_STRIDED && c->stride == 0)) {
            for (unsigned i = prev_vs; i < vs; i++) {
                if (!elem_active(c, i))
                    continue;
                for (unsigned f = 0; f < c->nf; f++) {
                    unsigned long pa = elem_phys_addr(c, i, f);
                    write_phys_elem(pa, c->eew_bytes, poison_val(c->eew_bytes, f, i));
                }
            }
        }
    }
    if (vs > c->poisoned_upto)
        c->poisoned_upto = vs;
}

static void handle_common_trap(int is_smode,
                               unsigned long cause,
                               unsigned long epc,
                               unsigned long tval,
                               unsigned long status,
                               uint64_t t_entry)
{
    struct case_ctx *c = &g_ctx;
    unsigned long saved_vl = rd_vl();
    unsigned long saved_vtype = rd_vtype();
    unsigned long saved_vstart = rd_vstart();

    /* Disarm timers immediately. */
    if (is_smode)
        csr_write_imm(0x14D, ~0ul);
    else
        MTIMECMP_HI = 0xFFFFFFFFu;

    if ((cause & MCAUSE_INTERRUPT_BIT) != 0ul) {
        unsigned idx = c->irq_count;
        if (idx < 4u) {
            c->irq_epc[idx] = epc;
            c->irq_cause[idx] = cause;
            c->irq_vstart[idx] = saved_vstart;
            c->irq_vl[idx] = saved_vl;
            c->irq_vs[idx] = (status & MSTATUS_VS) >> 9;
            c->irq_lat[idx] = t_entry >= c->arm_time ? (t_entry - c->arm_time) : 0ull;
        }
        c->irq_count++;

        wr_vstart(0);
        if (epc == (unsigned long) (uintptr_t) &g_code[1] && saved_vstart > 0ul &&
            saved_vstart < c->vl) {
            inspect_and_poison(c, (unsigned) saved_vstart, c->poisoned_upto);
            if (c->unmap_vstart_page && idx == 0u) {
                /* Unmap the page containing element saved_vstart (only in M-mode Sv39 test). */
                unsigned page = (unsigned) ((elem_offset(c, (unsigned) saved_vstart, 0u)) >> 12);
                map_sv39_page(page, 0ul);
            }
        }
        handler_scratch_vec_work();
        setvl(saved_vl, saved_vtype);
        wr_vstart(saved_vstart);

        /* Re-arm for multi-interrupt tests if more mid-run interrupts are wanted. */
        if (!is_smode && c->multi_irq_target > 1 && (int) c->irq_count < c->multi_irq_target &&
            epc == (unsigned long) (uintptr_t) &g_code[1] && saved_vstart < c->vl) {
            uint64_t next_t = rdtime64() + c->multi_irq_step;
            c->arm_time = next_t;
            set_timer_cmp(next_t);
        }
        return;
    }

    /* Synchronous exception */
    if (!is_smode && cause == CAUSE_ECALL_S) {
        /* Return from S-mode trial back to M-mode caller. */
        csr_write(mepc, g_s_return_pc);
        csr_set(mstatus, 0x1800ul); /* MPP = M */
        return;
    }

    if (!is_smode && c->expect_page_fault &&
        (cause == CAUSE_LOAD_PAGE || cause == CAUSE_STORE_PAGE)) {
        c->fault_count++;
        c->fault_epc = epc;
        c->fault_cause = cause;
        c->fault_tval = tval;
        c->fault_vstart = saved_vstart;
        wr_vstart(0);
        if (saved_vstart <= c->vl)
            inspect_and_poison(c, (unsigned) saved_vstart, c->poisoned_upto);
        /* Map the faulting page so resumption completes. */
        map_sv39_page(c->fault_page_idx, PTE_RW);
        handler_scratch_vec_work();
        setvl(saved_vl, saved_vtype);
        wr_vstart(saved_vstart);
        return;
    }

    uart_printf("[UNEXPECTED TRAP] mode=%d cause=%lx epc=%lx tval=%lx vstart=%lx\n<<FAIL>>\n",
                is_smode,
                cause,
                epc,
                tval,
                saved_vstart);
    for (;;) {
    }
}

void __attribute__((used)) m_trap_c(unsigned long old_mstatus, uint64_t t_entry)
{
    handle_common_trap(0, csr_read(mcause), csr_read(mepc), csr_read(mtval), old_mstatus, t_entry);
}

void __attribute__((used)) s_trap_c(unsigned long old_sstatus, uint64_t t_entry)
{
    handle_common_trap(1, csr_read(scause), csr_read(sepc), csr_read(stval), old_sstatus, t_entry);
}

/* M-mode trap entry: clears MPRV before touching memory, captures time early,
 * saves caller-saved GPRs, calls m_trap_c, restores MPRV and all GPRs, mret. */
__attribute__((naked, aligned(4))) static void m_trap_entry(void)
{
    __asm__ volatile("csrrw t6, mscratch, t6\n"
                     "li    t6, 0x20000\n" /* MSTATUS_MPRV */
                     "csrrc t6, mstatus, t6\n"
                     "addi  sp, sp, -160\n"
                     "sd    t6, 136(sp)\n" /* old mstatus */
                     "csrr  t6, time\n"
                     "sd    t6, 144(sp)\n" /* t_entry */
                     "csrr  t6, mscratch\n"
                     "sd    t6, 128(sp)\n" /* old t6 */
                     "sd    ra,   0(sp)\n"
                     "sd    t0,   8(sp)\n"
                     "sd    t1,  16(sp)\n"
                     "sd    t2,  24(sp)\n"
                     "sd    t3,  32(sp)\n"
                     "sd    t4,  40(sp)\n"
                     "sd    t5,  48(sp)\n"
                     "sd    a0,  56(sp)\n"
                     "sd    a1,  64(sp)\n"
                     "sd    a2,  72(sp)\n"
                     "sd    a3,  80(sp)\n"
                     "sd    a4,  88(sp)\n"
                     "sd    a5,  96(sp)\n"
                     "sd    a6, 104(sp)\n"
                     "sd    a7, 112(sp)\n"
                     "ld    a0, 136(sp)\n"
                     "ld    a1, 144(sp)\n"
                     "call  m_trap_c\n"
                     "ld    ra,   0(sp)\n"
                     "ld    t0,   8(sp)\n"
                     "ld    t1,  16(sp)\n"
                     "ld    t2,  24(sp)\n"
                     "ld    t3,  32(sp)\n"
                     "ld    t4,  40(sp)\n"
                     "ld    t5,  48(sp)\n"
                     "ld    a0,  56(sp)\n"
                     "ld    a1,  64(sp)\n"
                     "ld    a2,  72(sp)\n"
                     "ld    a3,  80(sp)\n"
                     "ld    a4,  88(sp)\n"
                     "ld    a5,  96(sp)\n"
                     "ld    a6, 104(sp)\n"
                     "ld    a7, 112(sp)\n"
                     "ld    t6, 128(sp)\n"
                     "csrw  mscratch, t6\n"
                     "ld    t6, 136(sp)\n"
                     "addi  sp, sp, 160\n"
                     "srli  t6, t6, 17\n"
                     "andi  t6, t6, 1\n"
                     "slli  t6, t6, 17\n"
                     "csrs  mstatus, t6\n"
                     "csrrw t6, mscratch, t6\n"
                     "mret\n");
}

/* S-mode trap entry (runs bare with satp == 0). */
__attribute__((naked, aligned(4))) static void s_trap_entry(void)
{
    __asm__ volatile("addi  sp, sp, -160\n"
                     "sd    t6, 128(sp)\n"
                     "csrr  t6, time\n"
                     "sd    t6, 144(sp)\n"
                     "csrr  t6, sstatus\n"
                     "sd    t6, 136(sp)\n"
                     "sd    ra,   0(sp)\n"
                     "sd    t0,   8(sp)\n"
                     "sd    t1,  16(sp)\n"
                     "sd    t2,  24(sp)\n"
                     "sd    t3,  32(sp)\n"
                     "sd    t4,  40(sp)\n"
                     "sd    t5,  48(sp)\n"
                     "sd    a0,  56(sp)\n"
                     "sd    a1,  64(sp)\n"
                     "sd    a2,  72(sp)\n"
                     "sd    a3,  80(sp)\n"
                     "sd    a4,  88(sp)\n"
                     "sd    a5,  96(sp)\n"
                     "sd    a6, 104(sp)\n"
                     "sd    a7, 112(sp)\n"
                     "ld    a0, 136(sp)\n"
                     "ld    a1, 144(sp)\n"
                     "call  s_trap_c\n"
                     "ld    ra,   0(sp)\n"
                     "ld    t0,   8(sp)\n"
                     "ld    t1,  16(sp)\n"
                     "ld    t2,  24(sp)\n"
                     "ld    t3,  32(sp)\n"
                     "ld    t4,  40(sp)\n"
                     "ld    t5,  48(sp)\n"
                     "ld    a0,  56(sp)\n"
                     "ld    a1,  64(sp)\n"
                     "ld    a2,  72(sp)\n"
                     "ld    a3,  80(sp)\n"
                     "ld    a4,  88(sp)\n"
                     "ld    a5,  96(sp)\n"
                     "ld    a6, 104(sp)\n"
                     "ld    a7, 112(sp)\n"
                     "ld    t6, 128(sp)\n"
                     "addi  sp, sp, 160\n"
                     "sret\n");
}

static uint64_t exec_m_trampoline(
    uint32_t insn, unsigned long base, long stride, unsigned long mstatus_mask, uint64_t irq_delay)
{
    g_code[0] = 0x30062073u; /* csrrs x0, mstatus, a2 */
    g_code[1] = insn;
    g_code[2] = 0x00000013u; /* nop */
    g_code[3] = 0x30063073u; /* csrrc x0, mstatus, a2 */
    g_code[4] = 0x00008067u; /* ret */
    __asm__ volatile("fence rw, rw\n fence.i" ::: "memory");

    /* When MPRV is requested, select MPP = U so loads/stores translate via
     * Sv39 both before any trap and after M-mode mret (which sets MPP = U). */
    if ((mstatus_mask & MSTATUS_MPRV) != 0ul)
        csr_clear(mstatus, MSTATUS_MPP);

    uint64_t t0 = rdtime64();
    if (irq_delay != 0ull) {
        uint64_t target = t0 + irq_delay;
        g_ctx.arm_time = target;
        set_timer_cmp(target);
    } else {
        MTIMECMP_HI = 0xFFFFFFFFu;
    }

    register unsigned long a0 __asm__("a0") = base;
    register long a1 __asm__("a1") = stride;
    register unsigned long a2 __asm__("a2") = mstatus_mask;
    __asm__ volatile("jalr ra, 0(%3)"
                     : "+r"(a0), "+r"(a1), "+r"(a2)
                     : "r"((uintptr_t) g_code)
                     : "ra", "t0", "t1", "memory");
    MTIMECMP_HI = 0xFFFFFFFFu;
    uint64_t t1 = rdtime64();
    return t1 - t0;
}

static uint64_t
exec_s_trampoline(uint32_t insn, unsigned long base, long stride, uint64_t irq_delay)
{
    /* S-mode trampoline: enable SIE, run vector insn, nop, disable SIE, ecall to M. */
    g_code[0] = 0x10062073u; /* csrrs x0, sstatus, a2 (SIE) */
    g_code[1] = insn;
    g_code[2] = 0x00000013u; /* nop */
    g_code[3] = 0x10063073u; /* csrrc x0, sstatus, a2 (SIE) */
    g_code[4] = 0x00000073u; /* ecall */
    __asm__ volatile("fence rw, rw\n fence.i" ::: "memory");

    uint64_t t0 = rdtime64();
    if (irq_delay != 0ull) {
        uint64_t target = t0 + irq_delay;
        g_ctx.arm_time = target;
        csr_write_imm(0x14D, target); /* stimecmp */
    } else {
        csr_write_imm(0x14D, ~0ul);
    }

    /* Enter S-mode at g_code with sstatus.SIE initially 0 (g_code[0] sets it),
     * MPP = S, satp = 0 (bare). ECALL returns to label 1f in M-mode. */
    csr_clear(mstatus, MSTATUS_MPP | MSTATUS_SIE);
    csr_set(mstatus, MSTATUS_MPP_S);
    csr_write(mepc, (unsigned long) (uintptr_t) g_code);

    register unsigned long a0 __asm__("a0") = base;
    register long a1 __asm__("a1") = stride;
    register unsigned long a2 __asm__("a2") = MSTATUS_SIE;
    __asm__ volatile("la   t0, 1f\n"
                     "la   t1, g_s_return_pc\n"
                     "sd   t0, 0(t1)\n"
                     "mret\n"
                     "1:\n"
                     : "+r"(a0), "+r"(a1), "+r"(a2)
                     :
                     : "t0", "t1", "memory");
    csr_write_imm(0x14D, ~0ul);
    uint64_t t1 = rdtime64();
    return t1 - t0;
}

/* ========================================================================== */
/* Generic case runner                                                        */
/* ========================================================================== */

static void prep_vrf_and_mem(struct case_ctx *c, int in_place_idx, int cold_flush)
{
    volatile uint8_t *vrf = (volatile uint8_t *) DDR_VRF;
    for (unsigned long b = 0; b < 8ul * g_vlenb; b++)
        vrf[b] = 0x33u;

    for (unsigned f = 0; f < c->nf; f++) {
        for (unsigned i = 0; i < c->vl; i++) {
            uint32_t init_r = c->init_reg[f][i];
            if (in_place_idx)
                init_r = c->idx_off[i];
            write_vrf_elem(vrf, c->field_regs, f, i, c->eew_bytes, init_r);
        }
    }
    load_v8_group(vrf);

    if (c->addr_mode == ADDR_INDEXED && !in_place_idx) {
        for (unsigned long b = 0; b < 8ul * g_vlenb; b++)
            vrf[b] = 0u;
        for (unsigned i = 0; i < c->vl; i++)
            write_vrf_elem(vrf, c->field_regs, 0u, i, 4u, c->idx_off[i]);
        load_v16_group(vrf);
    }

    if (c->is_masked) {
        for (unsigned long b = 0; b < g_vlenb; b++)
            vrf[b] = 0u;
        for (unsigned b = 0; b < 8u; b++)
            vrf[b] = (uint8_t) ((c->mask_bits >> (8u * b)) & 0xFFu);
        load_v0(vrf);
    }

    for (unsigned i = 0; i < c->vl; i++) {
        for (unsigned f = 0; f < c->nf; f++) {
            unsigned long pa = elem_phys_addr(c, i, f);
            write_phys_elem(pa, c->eew_bytes, c->init_mem[f][i]);
        }
    }

    if (cold_flush) {
        for (unsigned i = 0; i < c->vl; i++) {
            for (unsigned f = 0; f < c->nf; f++)
                cbo_flush_line(elem_phys_addr(c, i, f));
        }
        __asm__ volatile("fence rw, rw" ::: "memory");
    }
}

static void run_irq_case(struct case_ctx *c,
                         uint32_t insn,
                         unsigned long vtype,
                         unsigned long va_base,
                         unsigned long mprv_bit,
                         int in_place_idx,
                         int cold_flush,
                         unsigned expect_final_vl)
{
    /* Step 1: uninterrupted baseline run to calibrate delay = T_full / 4. */
    c->irq_count = 0;
    c->fault_count = 0;
    c->poisoned_upto = 0;
    c->snap_bad = 0;
    wr_vstart(0);
    prep_vrf_and_mem(c, in_place_idx, cold_flush);
    unsigned long vl_got = setvl(c->vl, vtype);
    check(vl_got == c->vl, c->name, 0x100, vl_got, c->vl);
    set_vs(VS_CLEAN);
    uint64_t t_full;
    if (c->is_smode)
        t_full = exec_s_trampoline(insn, va_base, c->stride, 0ull);
    else
        t_full = exec_m_trampoline(insn, va_base, c->stride, mprv_bit, 0ull);

    /* Step 2: interrupted run armed at ~25% of uninterrupted duration. */
    c->irq_count = 0;
    c->fault_count = 0;
    c->poisoned_upto = 0;
    c->snap_bad = 0;
    for (unsigned k = 0; k < 4u; k++) {
        c->irq_epc[k] = 0;
        c->irq_cause[k] = 0;
        c->irq_vstart[k] = ~0ul;
        c->irq_vl[k] = ~0ul;
        c->irq_vs[k] = 0;
        c->irq_lat[k] = 0;
    }
    wr_vstart(0);
    prep_vrf_and_mem(c, in_place_idx, cold_flush);
    setvl(c->vl, vtype);
    set_vs(VS_CLEAN);

    uint64_t delay = t_full / 4ull;
    if (delay < 40ull)
        delay = 40ull;
    if (c->multi_irq_target > 1) {
        delay = t_full / 6ull;
        if (delay < 40ull)
            delay = 40ull;
        c->multi_irq_step = t_full / 6ull;
        if (c->multi_irq_step < 60ull)
            c->multi_irq_step = 60ull;
    }

    if (c->is_smode)
        (void) exec_s_trampoline(insn, va_base, c->stride, delay);
    else
        (void) exec_m_trampoline(insn, va_base, c->stride, mprv_bit | MSTATUS_MIE, delay);

    unsigned long final_vl = rd_vl();
    unsigned long final_vstart = rd_vstart();
    unsigned long want_cause = c->is_smode ? CAUSE_STI : CAUSE_MTI;
    unsigned long insn_pc = (unsigned long) (uintptr_t) &g_code[1];

    uart_printf("LAT %s full=%lu irq=%u lat=%lu vstart=%lu/%u\n",
                c->name,
                (unsigned long) t_full,
                c->irq_count,
                (unsigned long) c->irq_lat[0],
                c->irq_vstart[0],
                c->vl);

    /* Verify interrupt stopped cleanly mid-instruction. */
    check(c->irq_count >= 1u, c->name, 0x200, c->irq_count, 1u);
    check(c->irq_cause[0] == want_cause, c->name, 0x201, c->irq_cause[0], want_cause);
    check(c->irq_epc[0] == insn_pc, c->name, 0x202, c->irq_epc[0], insn_pc);
    check(c->irq_vstart[0] > 0ul && c->irq_vstart[0] < c->vl,
          c->name,
          0x203,
          c->irq_vstart[0],
          c->vl);
    check(c->irq_vl[0] == c->vl, c->name, 0x204, c->irq_vl[0], c->vl);
    check(c->irq_vs[0] == 3ul, c->name, 0x205, c->irq_vs[0], 3ul);

    /* Verify interrupt latency is bounded by one element, not the full instruction.
     * t_full covers vl elements; irq_lat must stay well below half of t_full. */
    uint64_t lat_limit = t_full / 2ull;
    check(c->irq_lat[0] < lat_limit,
          c->name,
          0x206,
          (unsigned long) c->irq_lat[0],
          (unsigned long) lat_limit);

    if (c->multi_irq_target > 1) {
        check(c->irq_count >= 2u, c->name, 0x207, c->irq_count, 2u);
        if (c->irq_count >= 2u) {
            check(c->irq_epc[1] == insn_pc, c->name, 0x208, c->irq_epc[1], insn_pc);
            check(c->irq_vstart[1] > c->irq_vstart[0] && c->irq_vstart[1] < c->vl,
                  c->name,
                  0x209,
                  c->irq_vstart[1],
                  c->irq_vstart[0]);
            check(c->irq_lat[1] < lat_limit,
                  c->name,
                  0x20A,
                  (unsigned long) c->irq_lat[1],
                  (unsigned long) lat_limit);
        }
    }

    if (c->expect_page_fault) {
        check(c->fault_count == 1u, c->name, 0x210, c->fault_count, 1u);
        check(c->fault_epc == insn_pc, c->name, 0x211, c->fault_epc, insn_pc);
        check(c->fault_vstart == c->fault_elem_idx,
              c->name,
              0x212,
              c->fault_vstart,
              c->fault_elem_idx);
        unsigned long want_fc = c->is_store ? CAUSE_STORE_PAGE : CAUSE_LOAD_PAGE;
        check(c->fault_cause == want_fc, c->name, 0x213, c->fault_cause, want_fc);
        unsigned long want_tval = va_base + (unsigned long) elem_offset(c, c->fault_elem_idx, 0u);
        check(c->fault_tval == want_tval, c->name, 0x214, c->fault_tval, want_tval);
    }

    /* Verify post-completion architectural state. */
    unsigned want_vl = c->unmap_vstart_page ? (unsigned) c->irq_vstart[0] : expect_final_vl;
    check(final_vl == want_vl, c->name, 0x300, final_vl, want_vl);
    check(final_vstart == 0ul, c->name, 0x301, final_vstart, 0ul);

    if (!c->is_store) {
        volatile uint8_t *out = (volatile uint8_t *) DDR_VRF;
        store_v8_group(out);
        for (unsigned i = 0; i < c->vl; i++) {
            for (unsigned f = 0; f < c->nf; f++) {
                uint32_t got = read_snap_elem(out, c->field_regs, f, i, c->eew_bytes);
                uint32_t want;
                if (i < want_vl && elem_active(c, i))
                    want = c->expect_val[f][i];
                else
                    want = in_place_idx ? c->idx_off[i] : c->init_reg[f][i];
                if (got != want) {
                    check(0, c->name, 0x40000ul | ((unsigned long) f << 8) | i, got, want);
                    return;
                }
            }
        }
    } else if (!(c->addr_mode == ADDR_STRIDED && c->stride == 0)) {
        for (unsigned i = 0; i < c->vl; i++) {
            for (unsigned f = 0; f < c->nf; f++) {
                unsigned long pa = elem_phys_addr(c, i, f);
                uint32_t got = read_phys_elem(pa, c->eew_bytes);
                uint32_t want;
                if (!elem_active(c, i))
                    want = c->init_mem[f][i];
                else if (i < c->poisoned_upto)
                    want = poison_val(c->eew_bytes, f, i); /* must NOT be rewritten! */
                else
                    want = c->expect_val[f][i];
                if (got != want) {
                    check(0, c->name, 0x50000ul | ((unsigned long) f << 8) | i, got, want);
                    return;
                }
            }
        }
    } else {
        /* Zero-stride store: single memory location receives final active element. */
        uint32_t want = c->init_mem[0][0];
        for (unsigned i = 0; i < c->vl; i++) {
            if (elem_active(c, i))
                want = c->expect_val[0][i];
        }
        uint32_t got = read_phys_elem(c->phys_base, c->eew_bytes);
        check(got == want, c->name, 0x50001ul, got, want);
    }
}

/* ========================================================================== */
/* Case builders                                                              */
/* ========================================================================== */

static void zero_ctx(struct case_ctx *c)
{
    uint8_t *p = (uint8_t *) c;
    for (unsigned long i = 0; i < sizeof(*c); i++)
        p[i] = 0u;
}

static void init_e32_data(struct case_ctx *c, int is_store, unsigned nf, unsigned vl, uint32_t tag)
{
    c->is_store = is_store;
    c->nf = nf;
    c->eew_bytes = 4u;
    c->vl = vl;
    for (unsigned f = 0; f < nf; f++) {
        for (unsigned i = 0; i < vl; i++) {
            uint32_t val = (tag << 24) | (f << 16) | (i * 0x101u + 0x13u);
            if (!is_store) {
                c->init_reg[f][i] = SENTINEL32 ^ (f << 8) ^ i;
                c->init_mem[f][i] = val;
                c->expect_val[f][i] = val;
            } else {
                c->init_reg[f][i] = val;
                c->init_mem[f][i] = SENTINEL32 ^ (f << 8) ^ i;
                c->expect_val[f][i] = val;
            }
        }
    }
}

static void test_strided_cases(void)
{
    unsigned long lmul = lmul_for_32_e32();
    unsigned long vtype = VT_VTYPE(VT_E32, lmul);
    unsigned long fregs = emul_regs(lmul);

    /* 1. Positive-stride load, vl=32, stride=64 (32 cold cache lines). */
    zero_ctx(&g_ctx);
    g_ctx.name = "strided_ld_pos";
    g_ctx.addr_mode = ADDR_STRIDED;
    g_ctx.field_regs = fregs;
    g_ctx.phys_base = DDR_SRC;
    g_ctx.stride = 64;
    init_e32_data(&g_ctx, 0, 1u, 32u, 0x11u);
    run_irq_case(&g_ctx, vmem_insn(0, 1u, 2, 1, 6, 11u), vtype, DDR_SRC, 0ul, 0, 1, 32u);

    /* 2. Positive-stride store, vl=32, stride=64 (cold cache lines + prestart poison). */
    zero_ctx(&g_ctx);
    g_ctx.name = "strided_st_pos";
    g_ctx.addr_mode = ADDR_STRIDED;
    g_ctx.field_regs = fregs;
    g_ctx.phys_base = DDR_DST;
    g_ctx.stride = 64;
    init_e32_data(&g_ctx, 1, 1u, 32u, 0x12u);
    run_irq_case(&g_ctx, vmem_insn(1, 1u, 2, 1, 6, 11u), vtype, DDR_DST, 0ul, 0, 1, 32u);

    /* 3. Negative-stride masked load, vl=32, stride=-64. */
    zero_ctx(&g_ctx);
    g_ctx.name = "strided_ld_neg_mask";
    g_ctx.addr_mode = ADDR_STRIDED;
    g_ctx.is_masked = 1;
    g_ctx.mask_bits = 0xD5B36E9Bull;
    g_ctx.field_regs = fregs;
    g_ctx.phys_base = DDR_SRC + 31ul * 64ul;
    g_ctx.stride = -64;
    init_e32_data(&g_ctx, 0, 1u, 32u, 0x13u);
    run_irq_case(
        &g_ctx, vmem_insn(0, 1u, 2, 0, 6, 11u), vtype, DDR_SRC + 31ul * 64ul, 0ul, 0, 1, 32u);

    /* 4. Zero-stride load (warm, vl=64 e16 -> long run at single address). */
    zero_ctx(&g_ctx);
    unsigned long lmul16 = lmul_for_64_e16();
    g_ctx.name = "strided_ld_zero";
    g_ctx.addr_mode = ADDR_STRIDED;
    g_ctx.field_regs = emul_regs(lmul16);
    g_ctx.is_store = 0;
    g_ctx.nf = 1u;
    g_ctx.eew_bytes = 2u;
    g_ctx.vl = 64u;
    g_ctx.phys_base = DDR_SRC;
    g_ctx.stride = 0;
    for (unsigned i = 0; i < 64u; i++) {
        g_ctx.init_reg[0][i] = (SENTINEL16 ^ i) & 0xFFFFu;
        g_ctx.init_mem[0][i] = 0x3A7Cu;
        g_ctx.expect_val[0][i] = 0x3A7Cu;
    }
    run_irq_case(
        &g_ctx, vmem_insn(0, 1u, 2, 1, 5, 11u), VT_VTYPE(VT_E16, lmul16), DDR_SRC, 0ul, 0, 0, 64u);

    /* 5. Multiple interrupts during a single strided load and store. */
    zero_ctx(&g_ctx);
    g_ctx.name = "strided_ld_multi";
    g_ctx.addr_mode = ADDR_STRIDED;
    g_ctx.field_regs = fregs;
    g_ctx.phys_base = DDR_SRC;
    g_ctx.stride = 64;
    g_ctx.multi_irq_target = 3;
    init_e32_data(&g_ctx, 0, 1u, 32u, 0x15u);
    run_irq_case(&g_ctx, vmem_insn(0, 1u, 2, 1, 6, 11u), vtype, DDR_SRC, 0ul, 0, 1, 32u);

    zero_ctx(&g_ctx);
    g_ctx.name = "strided_st_multi";
    g_ctx.addr_mode = ADDR_STRIDED;
    g_ctx.field_regs = fregs;
    g_ctx.phys_base = DDR_DST;
    g_ctx.stride = 64;
    g_ctx.multi_irq_target = 3;
    init_e32_data(&g_ctx, 1, 1u, 32u, 0x16u);
    run_irq_case(&g_ctx, vmem_insn(1, 1u, 2, 1, 6, 11u), vtype, DDR_DST, 0ul, 0, 1, 32u);
}

static void test_indexed_cases(void)
{
    unsigned long lmul = lmul_for_32_e32();
    unsigned long vtype = VT_VTYPE(VT_E32, lmul);
    unsigned long fregs = emul_regs(lmul);

    /* 1. Unordered indexed load (vluxei32.v), scattered cold cache lines. */
    zero_ctx(&g_ctx);
    g_ctx.name = "indexed_ux_ld";
    g_ctx.addr_mode = ADDR_INDEXED;
    g_ctx.field_regs = fregs;
    g_ctx.phys_base = DDR_SRC;
    for (unsigned i = 0; i < 32u; i++)
        g_ctx.idx_off[i] = ((i * 7u + 3u) & 31u) * 64u + (i & 3u) * 4u;
    init_e32_data(&g_ctx, 0, 1u, 32u, 0x21u);
    run_irq_case(&g_ctx, vmem_insn(0, 1u, 1, 1, 6, 16u), vtype, DDR_SRC, 0ul, 0, 1, 32u);

    /* 2. Ordered indexed store (vsoxei32.v), masked, cold cache lines. */
    zero_ctx(&g_ctx);
    g_ctx.name = "indexed_ox_st_mask";
    g_ctx.addr_mode = ADDR_INDEXED;
    g_ctx.is_masked = 1;
    g_ctx.mask_bits = 0xE7B5D3A9ull;
    g_ctx.field_regs = fregs;
    g_ctx.phys_base = DDR_DST;
    for (unsigned i = 0; i < 32u; i++)
        g_ctx.idx_off[i] = ((31u - i) * 64u) + 8u;
    init_e32_data(&g_ctx, 1, 1u, 32u, 0x22u);
    run_irq_case(&g_ctx, vmem_insn(1, 1u, 3, 0, 6, 16u), vtype, DDR_DST, 0ul, 0, 1, 32u);

    /* 3. Unordered indexed store (vsuxei32.v), unmasked. */
    zero_ctx(&g_ctx);
    g_ctx.name = "indexed_ux_st";
    g_ctx.addr_mode = ADDR_INDEXED;
    g_ctx.field_regs = fregs;
    g_ctx.phys_base = DDR_DST;
    for (unsigned i = 0; i < 32u; i++)
        g_ctx.idx_off[i] = ((i * 11u + 5u) & 31u) * 64u;
    init_e32_data(&g_ctx, 1, 1u, 32u, 0x23u);
    run_irq_case(&g_ctx, vmem_insn(1, 1u, 1, 1, 6, 16u), vtype, DDR_DST, 0ul, 0, 1, 32u);

    /* 4. In-place gather (vd == vs2 == v8): loaded values are 0xF0xxxxxx which
     * would cause a load access fault if prestart elements were re-read as
     * indices after mret! */
    zero_ctx(&g_ctx);
    g_ctx.name = "indexed_inplace_ld";
    g_ctx.addr_mode = ADDR_INDEXED;
    g_ctx.field_regs = fregs;
    g_ctx.phys_base = DDR_SRC;
    for (unsigned i = 0; i < 32u; i++)
        g_ctx.idx_off[i] = i * 64u;
    init_e32_data(&g_ctx, 0, 1u, 32u, 0xF0u);
    for (unsigned i = 0; i < 32u; i++)
        g_ctx.init_reg[0][i] = g_ctx.idx_off[i];
    run_irq_case(&g_ctx, vmem_insn(0, 1u, 3, 1, 6, 8u), vtype, DDR_SRC, 0ul, 1, 1, 32u);
}

static void test_segment_cases(void)
{
    unsigned seg_vl = 0;
    unsigned long lmul = lmul_for_seg2_e32(&seg_vl);
    unsigned long vtype = VT_VTYPE(VT_E32, lmul);
    unsigned long fregs = emul_regs(lmul);

    /* 1. Unit-stride segment load (vlseg2e32.v) and store (vsseg2e32.v), cold. */
    zero_ctx(&g_ctx);
    g_ctx.name = "seg2_unit_ld";
    g_ctx.addr_mode = ADDR_UNIT_SEG;
    g_ctx.field_regs = fregs;
    g_ctx.phys_base = DDR_SRC;
    init_e32_data(&g_ctx, 0, 2u, seg_vl, 0x31u);
    run_irq_case(&g_ctx, vmem_insn(0, 2u, 0, 1, 6, 0u), vtype, DDR_SRC, 0ul, 0, 1, seg_vl);

    zero_ctx(&g_ctx);
    g_ctx.name = "seg2_unit_st";
    g_ctx.addr_mode = ADDR_UNIT_SEG;
    g_ctx.field_regs = fregs;
    g_ctx.phys_base = DDR_DST;
    init_e32_data(&g_ctx, 1, 2u, seg_vl, 0x32u);
    run_irq_case(&g_ctx, vmem_insn(1, 2u, 0, 1, 6, 0u), vtype, DDR_DST, 0ul, 0, 1, seg_vl);

    /* 2. Strided segment load (vlsseg2e32.v) and store (vssseg2e32.v), stride=64. */
    zero_ctx(&g_ctx);
    g_ctx.name = "seg2_strided_ld";
    g_ctx.addr_mode = ADDR_STRIDED;
    g_ctx.field_regs = fregs;
    g_ctx.phys_base = DDR_SRC;
    g_ctx.stride = 64;
    init_e32_data(&g_ctx, 0, 2u, seg_vl, 0x33u);
    run_irq_case(&g_ctx, vmem_insn(0, 2u, 2, 1, 6, 11u), vtype, DDR_SRC, 0ul, 0, 1, seg_vl);

    zero_ctx(&g_ctx);
    g_ctx.name = "seg2_strided_st";
    g_ctx.addr_mode = ADDR_STRIDED;
    g_ctx.field_regs = fregs;
    g_ctx.phys_base = DDR_DST;
    g_ctx.stride = 64;
    init_e32_data(&g_ctx, 1, 2u, seg_vl, 0x34u);
    run_irq_case(&g_ctx, vmem_insn(1, 2u, 2, 1, 6, 11u), vtype, DDR_DST, 0ul, 0, 1, seg_vl);

    /* 3. Indexed segment load (vluxseg2e32.v) and store (vsoxseg2e32.v), masked. */
    zero_ctx(&g_ctx);
    g_ctx.name = "seg2_idx_ld_mask";
    g_ctx.addr_mode = ADDR_INDEXED;
    g_ctx.is_masked = 1;
    g_ctx.mask_bits = 0xB6DB6DB7ull;
    g_ctx.field_regs = fregs;
    g_ctx.phys_base = DDR_SRC;
    for (unsigned i = 0; i < seg_vl; i++)
        g_ctx.idx_off[i] = ((i * 5u + 1u) % seg_vl) * 64u;
    init_e32_data(&g_ctx, 0, 2u, seg_vl, 0x35u);
    run_irq_case(&g_ctx, vmem_insn(0, 2u, 1, 0, 6, 16u), vtype, DDR_SRC, 0ul, 0, 1, seg_vl);

    zero_ctx(&g_ctx);
    g_ctx.name = "seg2_idx_st";
    g_ctx.addr_mode = ADDR_INDEXED;
    g_ctx.field_regs = fregs;
    g_ctx.phys_base = DDR_DST;
    for (unsigned i = 0; i < seg_vl; i++)
        g_ctx.idx_off[i] = ((seg_vl - 1u - i) * 64u) + 16u;
    init_e32_data(&g_ctx, 1, 2u, seg_vl, 0x36u);
    run_irq_case(&g_ctx, vmem_insn(1, 2u, 3, 1, 6, 16u), vtype, DDR_DST, 0ul, 0, 1, seg_vl);

    /* 4. nf=4 segment load & store (vlsseg4e8.v / vssseg4e8.v, e8 m2 -> vl=32 at all VLENs). */
    zero_ctx(&g_ctx);
    g_ctx.name = "seg4_strided_ld";
    g_ctx.addr_mode = ADDR_STRIDED;
    g_ctx.field_regs = 2u;
    g_ctx.is_store = 0;
    g_ctx.nf = 4u;
    g_ctx.eew_bytes = 1u;
    g_ctx.vl = 32u;
    g_ctx.phys_base = DDR_SRC;
    g_ctx.stride = 64;
    for (unsigned f = 0; f < 4u; f++) {
        for (unsigned i = 0; i < 32u; i++) {
            uint32_t v = (0x10u + (f << 5) + i) & 0xFFu;
            g_ctx.init_reg[f][i] = (SENTINEL8 ^ (f << 3) ^ i) & 0xFFu;
            g_ctx.init_mem[f][i] = v;
            g_ctx.expect_val[f][i] = v;
        }
    }
    run_irq_case(
        &g_ctx, vmem_insn(0, 4u, 2, 1, 0, 11u), VT_VTYPE(VT_E8, VT_M2), DDR_SRC, 0ul, 0, 1, 32u);

    zero_ctx(&g_ctx);
    g_ctx.name = "seg4_strided_st";
    g_ctx.addr_mode = ADDR_STRIDED;
    g_ctx.field_regs = 2u;
    g_ctx.is_store = 1;
    g_ctx.nf = 4u;
    g_ctx.eew_bytes = 1u;
    g_ctx.vl = 32u;
    g_ctx.phys_base = DDR_DST;
    g_ctx.stride = 64;
    for (unsigned f = 0; f < 4u; f++) {
        for (unsigned i = 0; i < 32u; i++) {
            uint32_t v = (0x20u + (f << 5) + i) & 0xFFu;
            g_ctx.init_reg[f][i] = v;
            g_ctx.init_mem[f][i] = (SENTINEL8 ^ (f << 3) ^ i) & 0xFFu;
            g_ctx.expect_val[f][i] = v;
        }
    }
    run_irq_case(
        &g_ctx, vmem_insn(1, 4u, 2, 1, 0, 11u), VT_VTYPE(VT_E8, VT_M2), DDR_DST, 0ul, 0, 1, 32u);
}

static void test_fof_and_fault_agreement(void)
{
    setup_sv39();
    unsigned long lmul16 = lmul_for_64_e16();
    unsigned long vtype16 = VT_VTYPE(VT_E16, lmul16);
    unsigned long fregs16 = emul_regs(lmul16);
    unsigned long lmul32 = lmul_for_32_e32();
    unsigned long vtype32 = VT_VTYPE(VT_E32, lmul32);
    unsigned long fregs32 = emul_regs(lmul32);

    /* 1. All-mapped vle16ff.v (vl=64, warm L1D): mid-run IRQ leaves vl=64, resumes to completion.
     */
    zero_ctx(&g_ctx);
    g_ctx.name = "fof_e16_full";
    g_ctx.is_fof = 1;
    g_ctx.addr_mode = ADDR_UNIT_SEG;
    g_ctx.field_regs = fregs16;
    g_ctx.is_store = 0;
    g_ctx.nf = 1u;
    g_ctx.eew_bytes = 2u;
    g_ctx.vl = 64u;
    g_ctx.phys_base = FRAMES;
    for (unsigned i = 0; i < 64u; i++) {
        uint32_t v = (0x4100u + i * 3u) & 0xFFFFu;
        g_ctx.init_reg[0][i] = (SENTINEL16 ^ i) & 0xFFFFu;
        g_ctx.init_mem[0][i] = v;
        g_ctx.expect_val[0][i] = v;
    }
    run_irq_case(
        &g_ctx, vmem_insn(0, 1u, 0, 1, 5, 0x10u), vtype16, VA_BASE, MSTATUS_MPRV, 0, 0, 64u);

    /* 2. vle16ff.v (vl=64) across page boundary at elem 48:
     *    base = VA_BASE + 4096 - 48*2 (page 0 mapped, page 1 unmapped).
     *    Mid-run IRQ arrives around elem ~12 (vl still 64 in handler!), resumes
     *    from vstart, hits unmapped page 1 at elem 48 -> trims vl = 48 without trap! */
    map_sv39_page(1u, 0ul);
    zero_ctx(&g_ctx);
    g_ctx.name = "fof_e16_irq_trim";
    g_ctx.is_fof = 1;
    g_ctx.addr_mode = ADDR_UNIT_SEG;
    g_ctx.field_regs = fregs16;
    g_ctx.is_store = 0;
    g_ctx.nf = 1u;
    g_ctx.eew_bytes = 2u;
    g_ctx.vl = 64u;
    g_ctx.phys_base = FRAMES + 4096ul - 96ul;
    for (unsigned i = 0; i < 64u; i++) {
        uint32_t v = (0x4200u + i * 5u) & 0xFFFFu;
        g_ctx.init_reg[0][i] = (SENTINEL16 ^ i) & 0xFFFFu;
        g_ctx.init_mem[0][i] = v;
        g_ctx.expect_val[0][i] = v;
    }
    run_irq_case(&g_ctx,
                 vmem_insn(0, 1u, 0, 1, 5, 0x10u),
                 vtype16,
                 VA_BASE + 4096ul - 96ul,
                 MSTATUS_MPRV,
                 0,
                 0,
                 48u);

    /* 3. vle16ff.v (vl=64): handler unmaps page 0 while stopped at vstart > 0!
     *    On mret, element vstart > 0 immediately faults -> trims vl = vstart
     *    without trapping and without modifying elements >= vstart. */
    map_sv39_page(0u, PTE_RW);
    map_sv39_page(1u, PTE_RW);
    zero_ctx(&g_ctx);
    g_ctx.name = "fof_e16_trim_at_vs";
    g_ctx.is_fof = 1;
    g_ctx.unmap_vstart_page = 1;
    g_ctx.addr_mode = ADDR_UNIT_SEG;
    g_ctx.field_regs = fregs16;
    g_ctx.is_store = 0;
    g_ctx.nf = 1u;
    g_ctx.eew_bytes = 2u;
    g_ctx.vl = 64u;
    g_ctx.phys_base = FRAMES;
    for (unsigned i = 0; i < 64u; i++) {
        uint32_t v = (0x4300u + i * 7u) & 0xFFFFu;
        g_ctx.init_reg[0][i] = (SENTINEL16 ^ i) & 0xFFFFu;
        g_ctx.init_mem[0][i] = v;
        g_ctx.expect_val[0][i] = v;
    }
    run_irq_case(
        &g_ctx, vmem_insn(0, 1u, 0, 1, 5, 0x10u), vtype16, VA_BASE, MSTATUS_MPRV, 0, 0, 64u);
    map_sv39_page(0u, PTE_RW);

    /* 4. Masked vle16ff.v (vl=64) with elements 48..63 masked off on unmapped page 1:
     *    mid-run IRQ + resume completes with vl == 64 unchanged! */
    map_sv39_page(1u, 0ul);
    zero_ctx(&g_ctx);
    g_ctx.name = "fof_e16_mask_unmap";
    g_ctx.is_fof = 1;
    g_ctx.is_masked = 1;
    g_ctx.mask_bits = (1ull << 48) - 1ull; /* bits 0..47 active, 48..63 masked off */
    g_ctx.addr_mode = ADDR_UNIT_SEG;
    g_ctx.field_regs = fregs16;
    g_ctx.is_store = 0;
    g_ctx.nf = 1u;
    g_ctx.eew_bytes = 2u;
    g_ctx.vl = 64u;
    g_ctx.phys_base = FRAMES + 4096ul - 96ul;
    for (unsigned i = 0; i < 64u; i++) {
        uint32_t v = (0x4400u + i * 9u) & 0xFFFFu;
        g_ctx.init_reg[0][i] = (SENTINEL16 ^ i) & 0xFFFFu;
        g_ctx.init_mem[0][i] = v;
        g_ctx.expect_val[0][i] = v;
    }
    run_irq_case(&g_ctx,
                 vmem_insn(0, 1u, 0, 0, 5, 0x10u),
                 vtype16,
                 VA_BASE + 4096ul - 96ul,
                 MSTATUS_MPRV,
                 0,
                 0,
                 64u);

    /* 5. Segment fault-only-first (vlseg2e32ff.v): mid-run IRQ + trim at segment k. */
    unsigned seg_vl = 0;
    unsigned long seg_lmul = lmul_for_seg2_e32(&seg_vl);
    unsigned seg_trim = (seg_vl * 3u) / 4u; /* 12 or 24 */
    zero_ctx(&g_ctx);
    g_ctx.name = "fof_seg2_irq_trim";
    g_ctx.is_fof = 1;
    g_ctx.addr_mode = ADDR_UNIT_SEG;
    g_ctx.field_regs = emul_regs(seg_lmul);
    g_ctx.phys_base = FRAMES + 4096ul - (unsigned long) seg_trim * 8ul;
    init_e32_data(&g_ctx, 0, 2u, seg_vl, 0x45u);
    run_irq_case(&g_ctx,
                 vmem_insn(0, 2u, 0, 1, 6, 0x10u),
                 VT_VTYPE(VT_E32, seg_lmul),
                 VA_BASE + 4096ul - (unsigned long) seg_trim * 8ul,
                 MSTATUS_MPRV,
                 0,
                 0,
                 seg_trim);
    map_sv39_page(1u, PTE_RW);

    /* 6. Combined async interrupt + synchronous Sv39 page fault on the SAME
     *    strided load and strided store:
     *    stride = 512 bytes -> 8 elements per 4 KiB page.
     *    Page 3 (elements 24..31) is unmapped on the interrupted run!
     *    - Interrupt arrives around elem ~6 -> sets vstart = j, resumes via mret.
     *    - Element 24 hits unmapped page 3 -> synchronous page fault with vstart = 24,
     *      mtval = VA_BASE + 3*4096. Handler maps page 3, restores vstart = 24, mret.
     *    - Remaining elements 24..31 complete with vstart = 0. */
    for (int is_store = 0; is_store <= 1; is_store++) {
        map_sv39_page(3u, PTE_RW); /* mapped during baseline calibration */
        zero_ctx(&g_ctx);
        g_ctx.name = is_store ? "irq_then_pf_st" : "irq_then_pf_ld";
        g_ctx.addr_mode = ADDR_STRIDED;
        g_ctx.field_regs = fregs32;
        g_ctx.phys_base = FRAMES;
        g_ctx.stride = 512;
        init_e32_data(&g_ctx, is_store, 1u, 32u, is_store ? 0x52u : 0x51u);

        /* Baseline timing with page 3 mapped. */
        wr_vstart(0);
        prep_vrf_and_mem(&g_ctx, 0, 1);
        setvl(32u, vtype32);
        uint32_t insn = vmem_insn(is_store, 1u, 2, 1, 6, 11u);
        uint64_t t_full = exec_m_trampoline(insn, VA_BASE, 512, MSTATUS_MPRV, 0ull);

        /* Interrupted + page-faulting run: unmap page 3 before running. */
        g_ctx.irq_count = 0;
        g_ctx.fault_count = 0;
        g_ctx.poisoned_upto = 0;
        g_ctx.snap_bad = 0;
        g_ctx.expect_page_fault = 1;
        g_ctx.fault_page_idx = 3u;
        g_ctx.fault_elem_idx = 24u;
        wr_vstart(0);
        prep_vrf_and_mem(&g_ctx, 0, 1);
        map_sv39_page(3u, 0ul);
        setvl(32u, vtype32);
        set_vs(VS_CLEAN);
        uint64_t delay = t_full / 4ull;
        if (delay < 40ull)
            delay = 40ull;
        (void) exec_m_trampoline(insn, VA_BASE, 512, MSTATUS_MPRV | MSTATUS_MIE, delay);
        map_sv39_page(3u, PTE_RW);

        unsigned long insn_pc = (unsigned long) (uintptr_t) &g_code[1];
        uart_printf("LAT %s full=%lu irq=%u lat=%lu vstart=%lu pf_vs=%lu\n",
                    g_ctx.name,
                    (unsigned long) t_full,
                    g_ctx.irq_count,
                    (unsigned long) g_ctx.irq_lat[0],
                    g_ctx.irq_vstart[0],
                    g_ctx.fault_vstart);
        check(g_ctx.irq_count == 1u, g_ctx.name, 0x600, g_ctx.irq_count, 1u);
        check(g_ctx.irq_vstart[0] > 0ul && g_ctx.irq_vstart[0] < 24ul,
              g_ctx.name,
              0x601,
              g_ctx.irq_vstart[0],
              24ul);
        check(g_ctx.irq_lat[0] < t_full / 2ull,
              g_ctx.name,
              0x602,
              (unsigned long) g_ctx.irq_lat[0],
              (unsigned long) (t_full / 2ull));
        check(g_ctx.fault_count == 1u, g_ctx.name, 0x603, g_ctx.fault_count, 1u);
        check(g_ctx.fault_epc == insn_pc, g_ctx.name, 0x604, g_ctx.fault_epc, insn_pc);
        check(g_ctx.fault_vstart == 24ul, g_ctx.name, 0x605, g_ctx.fault_vstart, 24ul);
        check(g_ctx.fault_tval == VA_BASE + 3ul * 4096ul,
              g_ctx.name,
              0x606,
              g_ctx.fault_tval,
              VA_BASE + 3ul * 4096ul);
        check(rd_vstart() == 0ul, g_ctx.name, 0x607, rd_vstart(), 0ul);

        if (!is_store) {
            volatile uint8_t *out = (volatile uint8_t *) DDR_VRF;
            store_v8_group(out);
            for (unsigned i = 0; i < 32u; i++) {
                uint32_t got = read_snap_elem(out, fregs32, 0u, i, 4u);
                check(got == g_ctx.expect_val[0][i],
                      g_ctx.name,
                      0x6100u | i,
                      got,
                      g_ctx.expect_val[0][i]);
            }
        } else {
            for (unsigned i = 0; i < 32u; i++) {
                unsigned long pa = elem_phys_addr(&g_ctx, i, 0u);
                uint32_t got = read_phys_elem(pa, 4u);
                uint32_t want = i < 24u ? poison_val(4u, 0u, i) : g_ctx.expect_val[0][i];
                check(got == want, g_ctx.name, 0x6200u | i, got, want);
            }
        }
    }

    csr_write(satp, 0ul);
    __asm__ volatile("sfence.vma" ::: "memory");
}

static void test_smode_cases(void)
{
    /* Enable Sstc (menvcfg.STCE), expose time counter, delegate STI to S-mode. */
    csr_write_imm(0x30A, 1ul << 63); /* menvcfg.STCE */
    csr_write_imm(0x306, 0x7ul);     /* mcounteren: CY, TM, IR */
    csr_write_imm(0x14D, ~0ul);      /* stimecmp = ~0 */
    csr_write(mideleg, 1ul << 5);    /* delegate STI */
    csr_write(stvec, (unsigned long) (uintptr_t) &s_trap_entry);
    csr_set(mie, 1ul << 5); /* STIE (also visible in sie) */

    unsigned long lmul = lmul_for_32_e32();
    unsigned long vtype = VT_VTYPE(VT_E32, lmul);
    unsigned long fregs = emul_regs(lmul);

    /* 1. S-mode strided load + sret */
    zero_ctx(&g_ctx);
    g_ctx.name = "smode_strided_ld";
    g_ctx.is_smode = 1;
    g_ctx.addr_mode = ADDR_STRIDED;
    g_ctx.field_regs = fregs;
    g_ctx.phys_base = DDR_SRC;
    g_ctx.stride = 64;
    init_e32_data(&g_ctx, 0, 1u, 32u, 0x61u);
    run_irq_case(&g_ctx, vmem_insn(0, 1u, 2, 1, 6, 11u), vtype, DDR_SRC, 0ul, 0, 1, 32u);

    /* 2. S-mode strided store + sret */
    zero_ctx(&g_ctx);
    g_ctx.name = "smode_strided_st";
    g_ctx.is_smode = 1;
    g_ctx.addr_mode = ADDR_STRIDED;
    g_ctx.field_regs = fregs;
    g_ctx.phys_base = DDR_DST;
    g_ctx.stride = 64;
    init_e32_data(&g_ctx, 1, 1u, 32u, 0x62u);
    run_irq_case(&g_ctx, vmem_insn(1, 1u, 2, 1, 6, 11u), vtype, DDR_DST, 0ul, 0, 1, 32u);

    /* 3. S-mode indexed load + sret */
    zero_ctx(&g_ctx);
    g_ctx.name = "smode_indexed_ld";
    g_ctx.is_smode = 1;
    g_ctx.addr_mode = ADDR_INDEXED;
    g_ctx.field_regs = fregs;
    g_ctx.phys_base = DDR_SRC;
    for (unsigned i = 0; i < 32u; i++)
        g_ctx.idx_off[i] = ((i * 5u + 3u) & 31u) * 64u;
    init_e32_data(&g_ctx, 0, 1u, 32u, 0x63u);
    run_irq_case(&g_ctx, vmem_insn(0, 1u, 3, 1, 6, 16u), vtype, DDR_SRC, 0ul, 0, 1, 32u);

    /* 4. S-mode segment store (vsseg2e32.v) + sret */
    unsigned seg_vl = 0;
    unsigned long seg_lmul = lmul_for_seg2_e32(&seg_vl);
    zero_ctx(&g_ctx);
    g_ctx.name = "smode_seg2_st";
    g_ctx.is_smode = 1;
    g_ctx.addr_mode = ADDR_UNIT_SEG;
    g_ctx.field_regs = emul_regs(seg_lmul);
    g_ctx.phys_base = DDR_DST;
    init_e32_data(&g_ctx, 1, 2u, seg_vl, 0x64u);
    run_irq_case(&g_ctx,
                 vmem_insn(1, 2u, 0, 1, 6, 0u),
                 VT_VTYPE(VT_E32, seg_lmul),
                 DDR_DST,
                 0ul,
                 0,
                 1,
                 seg_vl);

    /* 5. S-mode fault-only-first load (vle16ff.v) + sret */
    unsigned long lmul16 = lmul_for_64_e16();
    zero_ctx(&g_ctx);
    g_ctx.name = "smode_fof_ld";
    g_ctx.is_smode = 1;
    g_ctx.is_fof = 1;
    g_ctx.addr_mode = ADDR_UNIT_SEG;
    g_ctx.field_regs = emul_regs(lmul16);
    g_ctx.is_store = 0;
    g_ctx.nf = 1u;
    g_ctx.eew_bytes = 2u;
    g_ctx.vl = 64u;
    g_ctx.phys_base = DDR_SRC;
    for (unsigned i = 0; i < 64u; i++) {
        uint32_t v = (0x6500u + i * 3u) & 0xFFFFu;
        g_ctx.init_reg[0][i] = (SENTINEL16 ^ i) & 0xFFFFu;
        g_ctx.init_mem[0][i] = v;
        g_ctx.expect_val[0][i] = v;
    }
    run_irq_case(&g_ctx,
                 vmem_insn(0, 1u, 0, 1, 5, 0x10u),
                 VT_VTYPE(VT_E16, lmul16),
                 DDR_SRC,
                 0ul,
                 0,
                 0,
                 64u);

    csr_clear(mie, 1ul << 5);
    csr_write(mideleg, 0ul);
}

int main(void)
{
    csr_write(mscratch, 0);
    set_trap_handler(&m_trap_entry);
    set_vs(VS_DIRTY);
    __asm__ volatile("csrr %0, 0xC22" : "=r"(g_vlenb));
    uart_printf("vec_vstart_irq_test VLEN=%lu\n", g_vlenb * 8u);
    check(g_vlenb == 16u || g_vlenb == 32u || g_vlenb == 64u, "supported VLEN", 0, g_vlenb, 32u);

    MTIMECMP_HI = 0xFFFFFFFFu;
    enable_timer_interrupt();

    test_strided_cases();
    uart_printf("  [1] strided M-mode IRQ ok\n");
    test_indexed_cases();
    uart_printf("  [2] indexed M-mode IRQ ok\n");
    test_segment_cases();
    uart_printf("  [3] segment M-mode IRQ ok\n");
    test_fof_and_fault_agreement();
    uart_printf("  [4] fault-only-first and fault-path agreement ok\n");
    test_smode_cases();
    uart_printf("  [5] S-mode delegated IRQ ok\n");

    disable_timer_interrupt();
    uart_printf("%d checks\n", g_checks);
    uart_printf(g_ok ? "<<PASS>>\n" : "<<FAIL>>\n");
    for (;;) {
    }
    return 0;
}
