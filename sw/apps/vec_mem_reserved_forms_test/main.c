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
 * Exhaustive legality check of unit-stride-class (mop = 00) vector loads and
 * stores, plus whole-register alignment across all 32 registers under vill = 1
 * and architectural state preservation for each reserved class:
 *   1. Cross-product over opcode (LOAD-FP, STORE-FP), lumop/sumop (all 32
 *      values), nf (all 8), mew (0, 1), vector width (000, 101, 110, 111), and
 *      vm (0, 1): 8,192 encodings compared against the RISC-V V 1.0 table of
 *      214 defined combinations (7,978 reserved).
 *   2. Whole-register loads and stores across all 32 vd/vs3 register numbers
 *      and all four defined nf values (0, 1, 3, 7) under vill = 1: 256
 *      encodings (120 aligned execute, 136 misaligned trap).
 *   3. State-preservation checks verifying unchanged memory, destination
 *      registers, vstart and mstatus.VS for every reserved class, beside
 *      data-transfer checks on legal whole-register and mask neighbors.
 */

#include "../vec_common/vec_test.h"

/* Assembly tables and trap runners defined in sweep_tables.S. */
extern char res_mop00_dispatch[];
extern const uint32_t res_mop00_table[];
extern const uint32_t res_mop00_table_end[];
extern const uint32_t def_mop00_table[];
extern const uint32_t def_mop00_table_end[];
extern char def_mop00_exec[];
extern char res_whole_dispatch[];
extern const uint32_t res_whole_table[];
extern const uint32_t res_whole_table_end[];
extern const uint32_t def_whole_table[];
extern const uint32_t def_whole_table_end[];
extern char def_whole_exec[];
extern char fast_trap_reserved[];
extern char fast_trap_skip[];
extern char fast_trap_replay[];
extern unsigned long run_reserved_table(uintptr_t dispatch_pc,
                                        unsigned long base,
                                        const uint32_t *table,
                                        const uint32_t *table_end,
                                        volatile uint32_t *case_log,
                                        unsigned case_base,
                                        unsigned long *fail_out,
                                        unsigned long *first_fail_case_out);
extern unsigned long run_defined_table(uintptr_t exec_pc,
                                       unsigned long base,
                                       const uint32_t *table,
                                       volatile uint32_t *case_log,
                                       unsigned case_base,
                                       unsigned long *first_fail_case_out);

/* Active encoding and 1-based case index recorded before each encoding runs so
 * the test bench can report the encoding if a run times out or fails without
 * <<PASS>>: [0] = 32-bit encoding, [1] = 1-based case number. On DDR builds
 * writes go to the write-through low-BRAM slot at 0x00018000 so the bench can
 * read them without draining write-back caches. */
__attribute__((used, aligned(8))) volatile uint32_t vec_mem_active_case[2];

static volatile uint32_t *case_log_ptr(void)
{
#ifdef VT_SPIKE
    return vec_mem_active_case;
#else
    return ((uintptr_t) vec_mem_active_case < 0x40000ul) ? vec_mem_active_case
                                                         : (volatile uint32_t *) 0x00018000ul;
#endif
}

static inline void record_active_case(uint32_t insn, unsigned case_num)
{
    volatile uint32_t *slot = case_log_ptr();
    slot[0] = insn;
    slot[1] = (uint32_t) case_num;
}

/* State-preserving trap handler (leaves vstart and mstatus.VS unchanged). */
__attribute__((used)) volatile unsigned long mem_trap_vs;
__asm__(".pushsection .text.mem_trap,\"ax\"\n"
        ".balign 4\n.globl mem_trap_entry\nmem_trap_entry:\n"
        "csrrw t6, mscratch, t6\n"
        "sd t0, 0(t6)\nsd t1, 8(t6)\n"
        "csrr t0, mcause\nla t1, vt_trap_cause\nsd t0, 0(t1)\n"
        "csrr t0, mtval\nla t1, vt_trap_tval\nsd t0, 0(t1)\n"
        "csrr t0, vstart\nla t1, vt_trap_vstart\nsd t0, 0(t1)\n"
        "csrr t0, mstatus\nsrli t0, t0, 9\nandi t0, t0, 3\n"
        "la t1, mem_trap_vs\nsd t0, 0(t1)\n"
        "la t1, vt_trap_count\nld t0, 0(t1)\naddi t0, t0, 1\nsd t0, 0(t1)\n"
        "csrr t0, mepc\nla t1, vt_trap_epc\nsd t0, 0(t1)\n"
        "addi t0, t0, 4\ncsrw mepc, t0\n"
        "ld t0, 0(t6)\nld t1, 8(t6)\n"
        "csrrw t6, mscratch, t6\nmret\n.popsection\n");
extern char mem_trap_entry[];

#define BUF_BYTES 0x200u
#define BUF_WORDS (BUF_BYTES / 8u)
#define BUF_FILL64 0xA5A5A5A5A5A5A5A5ull
#define SNAPSHOT_OFFSET 0x200u
#define INSN_RET 0x00008067u

#ifdef VT_SPIKE
static uint8_t spike_mem[0x1000] __attribute__((aligned(64)));
static uint32_t spike_code[4] __attribute__((aligned(64)));
static volatile uint8_t *const buf = (volatile uint8_t *) spike_mem;
static volatile uint8_t *const out = (volatile uint8_t *) (spike_mem + 0x800u);
static volatile uint64_t *const buf64 = (volatile uint64_t *) spike_mem;
static volatile uint64_t *const out64 = (volatile uint64_t *) (spike_mem + 0x800u);
static volatile uint32_t *const code_buf = (volatile uint32_t *) spike_code;
#define BUF_ADDR ((unsigned long) spike_mem)
#define OUT_ADDR ((unsigned long) (spike_mem + 0x800u))
#else
#define BUF_ADDR 0x83100000ul
#define OUT_ADDR (BUF_ADDR + 0x800ul)
#define CODE_ADDR (BUF_ADDR + 0x2000ul)
static volatile uint8_t *const buf = (volatile uint8_t *) BUF_ADDR;
static volatile uint8_t *const out = (volatile uint8_t *) OUT_ADDR;
static volatile uint64_t *const buf64 = (volatile uint64_t *) BUF_ADDR;
static volatile uint64_t *const out64 = (volatile uint64_t *) OUT_ADDR;
static volatile uint32_t *const code_buf = (volatile uint32_t *) CODE_ADDR;
#endif

#define LD 0x07u
#define ST 0x27u
#define UMOP_UNIT 0x00u
#define UMOP_WHOLE 0x08u
#define UMOP_MASK 0x0bu
#define UMOP_FF 0x10u

#define VMEM_RAW(nf, mew, mop, vm, umop, w, vd, opc)                                               \
    ((uint32_t) (((nf) << 29) | ((mew) << 28) | ((mop) << 26) | ((vm) << 25) | ((umop) << 20) |    \
                 (10u << 15) | ((w) << 12) | ((vd) << 7) | (opc)))
#define VMEM(nf, vm, umop, w, vd, opc) VMEM_RAW(nf, 0u, 0u, vm, umop, w, vd, opc)

#define OPV(f6, vm, vs2, vs1, f3, vd)                                                              \
    ((uint32_t) (((f6) << 26) | ((vm) << 25) | ((vs2) << 20) | ((vs1) << 15) | ((f3) << 12) |      \
                 ((vd) << 7) | 0x57u))
/* vsetvli t6, x0, vtype: vl = VLMAX */
#define VSETMAX(vtype) ((uint32_t) (((vtype) << 20) | (7u << 12) | (31u << 7) | 0x57u))
/* vsetivli t6, uimm, vtype: vl = min(uimm, VLMAX) */
#define VSETI(uimm, vtype)                                                                         \
    ((uint32_t) ((3u << 30) | ((vtype) << 20) | (((uimm) & 31u) << 15) | (7u << 12) | (31u << 7) | \
                 0x57u))
#define E8M1 0x00u
#define E8M8 0x03u
#define E32M1 0x10u
#define E64M1 0x18u
#define VTYPE_ILL 0x20u /* reserved vsew=100 sets vill=1, vl=0 */
#define VMV_VI(vd, imm) OPV(0x17u, 1u, 0u, (imm) & 31u, 3u, vd)
#define VID(vd) OPV(0x14u, 1u, 0u, 0x11u, 2u, vd)

#define EMIT(insn) __asm__ volatile(".word %0" : : "i"(insn) : "t6", "memory")
#define RUN_AT(insn, base)                                                                         \
    do {                                                                                           \
        register unsigned long a0_ __asm__("a0") = (base);                                         \
        __asm__ volatile(".word %1" : : "r"(a0_), "i"(insn) : "t6", "memory");                     \
    } while (0)
#define RUN(insn) RUN_AT(insn, BUF_ADDR)

/* Unmasked whole-register store of 8 aligned registers (v0..v7 or v8..v15). */
#define STORE_GROUP8(base_reg, addr) RUN_AT(VMEM(7u, 1u, UMOP_WHOLE, 0u, base_reg, ST), addr)
#define STORE_REG1(reg, addr) RUN_AT(VMEM(0u, 1u, UMOP_WHOLE, 0u, reg, ST), addr)

static unsigned vlenb_val(void)
{
    return (unsigned) VT_CSR_READ(vlenb);
}

/* Populate v0..v15 with known patterns and buf with 0xA5. */
static void setup(void)
{
    EMIT(VSETMAX(E8M8));
    EMIT(VMV_VI(0u, 31u)); /* v0..v7 = 0xFF (all mask bits active) */
    EMIT(VMV_VI(8u, 7u));  /* v8..v15 = 0x07 */
    EMIT(VSETMAX(E8M1));
    EMIT(VID(8u)); /* v8 = 0, 1, 2, ... */
    EMIT(VMV_VI(9u, 9u));
    EMIT(VMV_VI(10u, 10u));
    EMIT(VMV_VI(12u, 12u));
    for (unsigned i = 0; i < BUF_WORDS; i++)
        buf64[i] = BUF_FILL64;
}

static void set_vtype(unsigned vtype)
{
    if (vtype == E8M1)
        EMIT(VSETMAX(E8M1));
    else if (vtype == E32M1)
        EMIT(VSETMAX(E32M1));
    else if (vtype == E8M8)
        EMIT(VSETMAX(E8M8));
    else
        EMIT(VSETMAX(VTYPE_ILL));
}

/*
 * RISC-V V 1.0 specification table of defined unit-stride-class (mop = 00)
 * encodings for vector widths (000, 101, 110, 111):
 *   - mew must be 0;
 *   - umop 00000: unit-stride and unit-stride segment (loads and stores,
 *                 all nf, both vm, all four vector widths);
 *   - umop 01000: whole-register load (vm = 1, nf in {0, 1, 3, 7}, all four
 *                 vector widths) and store (vm = 1, nf in {0, 1, 3, 7},
 *                 width = 000);
 *   - umop 01011: mask load/store vlm.v/vsm.v (vm = 1, nf = 0, width = 000);
 *   - umop 10000: fault-only-first load / segment load (loads only, all nf,
 *                 both vm, all four vector widths).
 * Every other combination in the cross-product is reserved.
 */
static int unit_stride_defined(
    unsigned is_store, unsigned nf, unsigned mew, unsigned vm, unsigned umop, unsigned width)
{
    if (mew != 0u)
        return 0;
    switch (umop) {
        case UMOP_UNIT:
            return 1;
        case UMOP_WHOLE:
            if (vm != 1u)
                return 0;
            if (nf != 0u && nf != 1u && nf != 3u && nf != 7u)
                return 0;
            return !is_store || (width == 0u);
        case UMOP_MASK:
            return (vm == 1u) && (nf == 0u) && (width == 0u);
        case UMOP_FF:
            return !is_store;
        default:
            return 0;
    }
}

static void record_sweep_mismatch(const char *tag,
                                  uint32_t insn,
                                  int expect_defined,
                                  unsigned long trapped,
                                  unsigned long cause,
                                  unsigned long tval)
{
    vt_failures++;
    if (vt_failures <= VT_FAIL_LIMIT) {
        vt_puts("FAIL ");
        vt_puts(tag);
        vt_puts(" insn=");
        vt_hex(insn);
        vt_puts(" def=");
        vt_dec((uint64_t) expect_defined);
        vt_puts(" trap=");
        vt_dec(trapped);
        vt_puts(" cause=");
        vt_hex(cause);
        vt_puts(" tval=");
        vt_hex(tval);
        vt_puts("\r\n");
    }
}

/* Slow per-encoding replay via 2-word code_buf stub; entered only if a fast
 * table sweep detects a mismatch, starting from the first mismatching entry. */
static void replay_table_verbose(const char *tag,
                                 const uint32_t *table,
                                 unsigned n,
                                 int expect_def,
                                 unsigned start_idx,
                                 unsigned case_base)
{
    uint32_t first_bad_insn = 0u;
    unsigned first_bad_case = 0u;
    int have_bad = 0;

    if (start_idx > n)
        start_idx = 0u;
    vt_checks += start_idx;

    __asm__ volatile("csrw mtvec, %0" : : "r"(fast_trap_replay));
    uintptr_t stub_pc = (uintptr_t) code_buf;
    for (unsigned i = start_idx; i < n; i++) {
        uint32_t insn = table[i];
        unsigned case_num = case_base + i;
        record_active_case(insn, case_num);
        code_buf[0] = insn;
        code_buf[1] = INSN_RET;
        __asm__ volatile("fence.i" ::: "memory");
        register unsigned long a0_ __asm__("a0") = BUF_ADDR;
        register unsigned long t0_ __asm__("t0") = (unsigned long) stub_pc;
        register unsigned long t1_ __asm__("t1") = 0;
        register unsigned long t2_ __asm__("t2") = 0;
        register unsigned long t3_ __asm__("t3") = 0;
        __asm__ volatile("jalr ra, t0, 0"
                         : "+r"(t1_), "+r"(t2_), "+r"(t3_)
                         : "r"(a0_), "r"(t0_)
                         : "ra", "memory");
        vt_checks++;
        int bad =
            expect_def ? (t1_ != 0ul) : (t1_ != 1ul || t2_ != 2ul || t3_ != (unsigned long) insn);
        if (bad) {
            if (!have_bad) {
                first_bad_insn = insn;
                first_bad_case = case_num;
                have_bad = 1;
            }
            record_sweep_mismatch(tag, insn, expect_def, t1_, t2_, t3_);
            if (vt_failures >= VT_FAIL_LIMIT)
                break;
        }
    }
    if (have_bad)
        record_active_case(first_bad_insn, first_bad_case);
}

/* Cross-check every instruction word in sweep_tables.S against the C
 * specification oracle before running the tables. */
static void verify_tables_against_oracle(void)
{
    static const unsigned widths[4] = {0u, 5u, 6u, 7u};
    static const unsigned nfs[4] = {0u, 1u, 3u, 7u};
    unsigned res_idx = 0u, def_idx = 0u, bad = 0u;
    unsigned res_n = (unsigned) (res_mop00_table_end - res_mop00_table);
    unsigned def_n = (unsigned) (def_mop00_table_end - def_mop00_table);

    for (unsigned is_store = 0u; is_store < 2u; is_store++) {
        unsigned opc = is_store ? ST : LD;
        for (unsigned umop = 0u; umop < 32u; umop++) {
            for (unsigned nf = 0u; nf < 8u; nf++) {
                for (unsigned mew = 0u; mew < 2u; mew++) {
                    for (unsigned wi = 0u; wi < 4u; wi++) {
                        unsigned w = widths[wi];
                        for (unsigned vm = 0u; vm < 2u; vm++) {
                            uint32_t insn = VMEM_RAW(nf, mew, 0u, vm, umop, w, 8u, opc);
                            if (unit_stride_defined(is_store, nf, mew, vm, umop, w)) {
                                if (def_idx >= def_n || def_mop00_table[def_idx] != insn)
                                    bad++;
                                def_idx++;
                            } else {
                                if (res_idx >= res_n || res_mop00_table[res_idx] != insn)
                                    bad++;
                                res_idx++;
                            }
                        }
                    }
                }
            }
        }
    }
    VT_EQ(res_idx, 7978u, "mop=00 reserved table count");
    VT_EQ(def_idx, 214u, "mop=00 defined table count");
    VT_EQ(res_idx + def_idx, 8192u, "mop=00 total encodings");
    VT_EQ(bad, 0u, "mop=00 table matches C oracle");

    res_idx = 0u;
    def_idx = 0u;
    bad = 0u;
    res_n = (unsigned) (res_whole_table_end - res_whole_table);
    def_n = (unsigned) (def_whole_table_end - def_whole_table);
    for (unsigned is_store = 0u; is_store < 2u; is_store++) {
        unsigned opc = is_store ? ST : LD;
        for (unsigned ni = 0u; ni < 4u; ni++) {
            unsigned nf = nfs[ni];
            for (unsigned reg = 0u; reg < 32u; reg++) {
                uint32_t insn = VMEM(nf, 1u, UMOP_WHOLE, 0u, reg, opc);
                if ((reg & nf) == 0u) {
                    if (def_idx >= def_n || def_whole_table[def_idx] != insn)
                        bad++;
                    def_idx++;
                } else {
                    if (res_idx >= res_n || res_whole_table[res_idx] != insn)
                        bad++;
                    res_idx++;
                }
            }
        }
    }
    VT_EQ(res_idx, 136u, "whole-reg misaligned count");
    VT_EQ(def_idx, 120u, "whole-reg aligned count");
    VT_EQ(res_idx + def_idx, 256u, "whole-reg total encodings");
    VT_EQ(bad, 0u, "whole-reg table matches C oracle");
}

#define CASE_BASE_RES_MOP00 1u
#define CASE_BASE_DEF_MOP00 7979u
#define CASE_BASE_RES_WHOLE 8193u
#define CASE_BASE_DEF_WHOLE 8329u
#define CASE_BASE_STATE 8449u

/* Exhaustive 8,192-encoding sweep of unit-stride-class (mop = 00) loads and
 * stores. Under SEW = 64, LMUL = 1, vl = 1, vd/vs3 = v8 and v0 = 0xFF:
 *   - EMUL for EEW in {8, 16, 32, 64} is {1/8, 1/4, 1/2, 1}, all in [1/8, 8];
 *   - max(EMUL, 1) = 1 register per field, so NF * 1 <= 8 and v8 + nf <= v15;
 *   - v8 is a multiple of 8 (aligned for whole-register nf in {0, 1, 3, 7})
 *     and disjoint from v0 (legal when vm = 0). */
static void sweep_unit_stride_space(void)
{
    unsigned res_n = (unsigned) (res_mop00_table_end - res_mop00_table);
    unsigned def_n = (unsigned) (def_mop00_table_end - def_mop00_table);
    volatile uint32_t *slot = case_log_ptr();
    unsigned long fails = 0, first_fail_case = CASE_BASE_RES_MOP00;

    setup();
    EMIT(VSETI(1u, E64M1));

    __asm__ volatile("csrw mtvec, %0" : : "r"(fast_trap_reserved));
    unsigned long ok = run_reserved_table((uintptr_t) res_mop00_dispatch,
                                          BUF_ADDR,
                                          res_mop00_table,
                                          res_mop00_table_end,
                                          slot,
                                          CASE_BASE_RES_MOP00,
                                          &fails,
                                          &first_fail_case);
    if (ok == (unsigned long) res_n && fails == 0ul) {
        vt_checks += res_n;
    } else {
        unsigned start_idx = (first_fail_case >= CASE_BASE_RES_MOP00)
                                 ? (unsigned) (first_fail_case - CASE_BASE_RES_MOP00)
                                 : 0u;
        replay_table_verbose("mop00", res_mop00_table, res_n, 0, start_idx, CASE_BASE_RES_MOP00);
        return;
    }

    EMIT(VSETI(1u, E64M1));
    __asm__ volatile("csrw mtvec, %0" : : "r"(fast_trap_skip));
    first_fail_case = CASE_BASE_DEF_MOP00;
    unsigned long traps = run_defined_table((uintptr_t) def_mop00_exec,
                                            BUF_ADDR,
                                            def_mop00_table,
                                            slot,
                                            CASE_BASE_DEF_MOP00,
                                            &first_fail_case);
    if (traps == 0ul) {
        vt_checks += def_n;
    } else {
        unsigned start_idx = (first_fail_case >= CASE_BASE_DEF_MOP00)
                                 ? (unsigned) (first_fail_case - CASE_BASE_DEF_MOP00)
                                 : 0u;
        replay_table_verbose("mop00", def_mop00_table, def_n, 1, start_idx, CASE_BASE_DEF_MOP00);
    }
}

/* Exhaustive 256-encoding sweep of whole-register alignment across all 32
 * register numbers and all four defined nf values (0, 1, 3, 7) under vill = 1. */
static void sweep_whole_reg_alignment_vill(void)
{
    unsigned res_n = (unsigned) (res_whole_table_end - res_whole_table);
    unsigned def_n = (unsigned) (def_whole_table_end - def_whole_table);
    volatile uint32_t *slot = case_log_ptr();
    unsigned long fails = 0, first_fail_case = CASE_BASE_RES_WHOLE;

    setup();
    EMIT(VSETMAX(VTYPE_ILL));

    __asm__ volatile("csrw mtvec, %0" : : "r"(fast_trap_reserved));
    unsigned long ok = run_reserved_table((uintptr_t) res_whole_dispatch,
                                          BUF_ADDR,
                                          res_whole_table,
                                          res_whole_table_end,
                                          slot,
                                          CASE_BASE_RES_WHOLE,
                                          &fails,
                                          &first_fail_case);
    if (ok == (unsigned long) res_n && fails == 0ul) {
        vt_checks += res_n;
    } else {
        unsigned start_idx = (first_fail_case >= CASE_BASE_RES_WHOLE)
                                 ? (unsigned) (first_fail_case - CASE_BASE_RES_WHOLE)
                                 : 0u;
        replay_table_verbose(
            "whole_align", res_whole_table, res_n, 0, start_idx, CASE_BASE_RES_WHOLE);
        return;
    }

    EMIT(VSETMAX(VTYPE_ILL));
    __asm__ volatile("csrw mtvec, %0" : : "r"(fast_trap_skip));
    first_fail_case = CASE_BASE_DEF_WHOLE;
    unsigned long traps = run_defined_table((uintptr_t) def_whole_exec,
                                            BUF_ADDR,
                                            def_whole_table,
                                            slot,
                                            CASE_BASE_DEF_WHOLE,
                                            &first_fail_case);
    if (traps == 0ul) {
        vt_checks += def_n;
    } else {
        unsigned start_idx = (first_fail_case >= CASE_BASE_DEF_WHOLE)
                                 ? (unsigned) (first_fail_case - CASE_BASE_DEF_WHOLE)
                                 : 0u;
        replay_table_verbose(
            "whole_align", def_whole_table, def_n, 1, start_idx, CASE_BASE_DEF_WHOLE);
    }
}

/* Full state-preservation check on one reserved encoding: illegal-instruction
 * cause and mtval, vstart and mstatus.VS Clean preserved, memory untouched,
 * and (for loads) the aligned 8-register target group unchanged. */
static unsigned state_case_num = CASE_BASE_STATE;

static void check_reserved_state(unsigned vtype, uint32_t insn, const char *what, int check_dest)
{
    unsigned case_num = state_case_num++;
    setup();
    if (check_dest)
        STORE_GROUP8(8u, OUT_ADDR);
    set_vtype(vtype);
    VT_CSR_WRITE(vstart, 1ul);
    VT_CSR_WRITE(mstatus, (VT_CSR_READ(mstatus) & ~(3ul << 9)) | (2ul << 9));
    vt_trap_clear();

    record_active_case(insn, case_num);
    code_buf[0] = insn;
    code_buf[1] = INSN_RET;
    __asm__ volatile("fence.i" ::: "memory");
    register unsigned long a0_ __asm__("a0") = BUF_ADDR;
    register unsigned long t0_ __asm__("t0") = (unsigned long) (uintptr_t) code_buf;
    __asm__ volatile("jalr ra, t0, 0" : : "r"(a0_), "r"(t0_) : "ra", "t6", "memory");

    unsigned long vs = (VT_CSR_READ(mstatus) >> 9) & 3ul;
    unsigned long vstart_after = VT_CSR_READ(vstart);
    VT_CSR_WRITE(vstart, 0ul);

    unsigned bad_buf = 0u;
    for (unsigned i = 0; i < BUF_WORDS; i++)
        bad_buf += buf64[i] != BUF_FILL64;

    unsigned bad_dest = 0u;
    if (check_dest) {
        STORE_GROUP8(8u, OUT_ADDR + SNAPSHOT_OFFSET);
        unsigned words = vlenb_val();
        for (unsigned i = 0; i < words; i++)
            bad_dest += out64[i] != out64[(SNAPSHOT_OFFSET / 8u) + i];
    }

    VT_EQ(vt_trap_count, 1ul, what);
    VT_EQ(vt_trap_cause, 2ul, what);
    VT_EQ(vt_trap_tval, (unsigned long) insn, what);
    VT_EQ(vt_trap_vstart, 1ul, what);
    VT_EQ(mem_trap_vs, 2ul, what);
    VT_EQ(vstart_after, 1ul, what);
    VT_EQ(vs, 2ul, what);
    VT_EQ(bad_buf, 0u, what);
    if (check_dest)
        VT_EQ(bad_dest, 0u, what);
}

static void check_state_preservation_and_data(void)
{
    __asm__ volatile("csrw mtvec, %0" : : "r"(mem_trap_entry));

    /* Reserved lumop / sumop (including fault-only-first store sumop = 10000). */
    check_reserved_state(E8M1, VMEM(0u, 1u, 0x01u, 0u, 8u, LD), "reserved lumop=0x01", 1);
    check_reserved_state(E8M1, VMEM(0u, 1u, 0x1fu, 6u, 8u, LD), "reserved lumop=0x1f", 1);
    check_reserved_state(E8M1, VMEM(0u, 1u, 0x01u, 0u, 8u, ST), "reserved sumop=0x01", 0);
    check_reserved_state(E8M1, VMEM(0u, 1u, UMOP_FF, 0u, 8u, ST), "reserved sumop=0x10", 0);

    /* Whole-register loads: vm = 0, reserved nf, mew = 1, misaligned vd, vill = 1. */
    check_reserved_state(E8M1, VMEM(0u, 0u, UMOP_WHOLE, 0u, 8u, LD), "vl1re8 vm=0", 1);
    check_reserved_state(E32M1, VMEM(7u, 0u, UMOP_WHOLE, 7u, 8u, LD), "vl8re64 vm=0", 1);
    check_reserved_state(VTYPE_ILL, VMEM(0u, 0u, UMOP_WHOLE, 0u, 8u, LD), "vl1re8 vm=0 vill=1", 1);
    check_reserved_state(E8M1, VMEM(2u, 1u, UMOP_WHOLE, 0u, 8u, LD), "vl3re8 nf=2", 1);
    check_reserved_state(E32M1, VMEM(5u, 1u, UMOP_WHOLE, 6u, 8u, LD), "vl6re32 nf=5", 1);
    check_reserved_state(VTYPE_ILL, VMEM(2u, 1u, UMOP_WHOLE, 0u, 8u, LD), "vl3re8 nf=2 vill=1", 1);
    check_reserved_state(E8M1, VMEM_RAW(0u, 1u, 0u, 1u, UMOP_WHOLE, 0u, 8u, LD), "vl1re8 mew=1", 1);
    check_reserved_state(E8M1, VMEM(1u, 1u, UMOP_WHOLE, 0u, 9u, LD), "vl2re8 misaligned", 1);

    /* Whole-register stores: vm = 0, reserved nf, nonzero width, mew = 1, misaligned vs3. */
    check_reserved_state(E8M1, VMEM(0u, 0u, UMOP_WHOLE, 0u, 8u, ST), "vs1r vm=0", 0);
    check_reserved_state(E8M1, VMEM(2u, 1u, UMOP_WHOLE, 0u, 8u, ST), "vs3r nf=2", 0);
    check_reserved_state(E32M1, VMEM(0u, 1u, UMOP_WHOLE, 6u, 8u, ST), "vs1r width=e32", 0);
    check_reserved_state(E8M1, VMEM_RAW(0u, 1u, 0u, 1u, UMOP_WHOLE, 0u, 8u, ST), "vs1r mew=1", 0);
    check_reserved_state(E8M1, VMEM(3u, 1u, UMOP_WHOLE, 0u, 10u, ST), "vs4r misaligned", 0);

    /* Mask loads and stores: vm = 0, nonzero nf, nonzero width, mew = 1, vill = 1. */
    check_reserved_state(E8M1, VMEM(0u, 0u, UMOP_MASK, 0u, 8u, LD), "vlm vm=0", 1);
    check_reserved_state(E8M1, VMEM(1u, 1u, UMOP_MASK, 0u, 8u, LD), "vlm nf=1", 1);
    check_reserved_state(E32M1, VMEM(0u, 1u, UMOP_MASK, 6u, 8u, LD), "vlm width=e32", 1);
    check_reserved_state(E8M1, VMEM_RAW(0u, 1u, 0u, 1u, UMOP_MASK, 0u, 8u, LD), "vlm mew=1", 1);
    check_reserved_state(VTYPE_ILL, VMEM(0u, 1u, UMOP_MASK, 0u, 8u, LD), "vlm vill=1", 1);

    check_reserved_state(E8M1, VMEM(0u, 0u, UMOP_MASK, 0u, 8u, ST), "vsm vm=0", 0);
    check_reserved_state(E8M1, VMEM(1u, 1u, UMOP_MASK, 0u, 8u, ST), "vsm nf=1", 0);
    check_reserved_state(E32M1, VMEM(0u, 1u, UMOP_MASK, 6u, 8u, ST), "vsm width=e32", 0);
    check_reserved_state(E8M1, VMEM_RAW(0u, 1u, 0u, 1u, UMOP_MASK, 0u, 8u, ST), "vsm mew=1", 0);
    check_reserved_state(VTYPE_ILL, VMEM(0u, 1u, UMOP_MASK, 0u, 8u, ST), "vsm vill=1", 0);

    /* Legal data-transfer checks: whole-register under vill = 1 and mask forms under LMUL 8. */
    setup();
    EMIT(VSETMAX(VTYPE_ILL));
    vt_trap_clear();
    record_active_case(VMEM(7u, 1u, UMOP_WHOLE, 7u, 8u, LD), state_case_num++);
    RUN(VMEM(7u, 1u, UMOP_WHOLE, 7u, 8u, LD));
    VT_EQ(vt_trap_count, 0ul, "vl8re64 v8 vill=1 no trap");
    STORE_GROUP8(8u, OUT_ADDR);
    unsigned bad = 0;
    for (unsigned i = 0; i < 8u * vlenb_val(); i++)
        bad += out[i] != 0xA5u;
    VT_EQ(bad, 0u, "vl8re64 v8 vill=1 loaded 8 registers");

    setup();
    EMIT(VSETMAX(VTYPE_ILL));
    vt_trap_clear();
    record_active_case(VMEM(0u, 1u, UMOP_WHOLE, 0u, 8u, ST), state_case_num++);
    RUN(VMEM(0u, 1u, UMOP_WHOLE, 0u, 8u, ST));
    VT_EQ(vt_trap_count, 0ul, "vs1r v8 vill=1 no trap");
    bad = 0;
    for (unsigned i = 0; i < vlenb_val(); i++)
        bad += buf[i] != (uint8_t) i;
    VT_EQ(bad, 0u, "vs1r v8 vill=1 stored v8");

    unsigned evl = vlenb_val(); /* VLMAX(e8,m8) = 8 * vlenb -> ceil(vl / 8) = vlenb */
    setup();
    EMIT(VSETMAX(E8M8));
    vt_trap_clear();
    record_active_case(VMEM(0u, 1u, UMOP_MASK, 0u, 9u, LD), state_case_num++);
    RUN(VMEM(0u, 1u, UMOP_MASK, 0u, 9u, LD));
    VT_EQ(vt_trap_count, 0ul, "vlm v9 no trap");
    STORE_REG1(9u, OUT_ADDR);
    bad = 0;
    for (unsigned i = 0; i < evl; i++)
        bad += out[i] != 0xA5u;
    VT_EQ(bad, 0u, "vlm v9 loaded evl bytes");

    setup();
    EMIT(VSETMAX(E8M8));
    vt_trap_clear();
    record_active_case(VMEM(0u, 1u, UMOP_MASK, 0u, 0u, ST), state_case_num++);
    RUN(VMEM(0u, 1u, UMOP_MASK, 0u, 0u, ST));
    VT_EQ(vt_trap_count, 0ul, "vsm v0 no trap");
    bad = 0;
    for (unsigned i = 0; i < evl; i++)
        bad += buf[i] != 0xFFu;
    VT_EQ(bad, 0u, "vsm v0 stored mask bytes");
}

int main(void)
{
    record_active_case(0u, 0u);
    state_case_num = CASE_BASE_STATE;
    vt_enable_vector();
    vt_trap_install();
    verify_tables_against_oracle();
    sweep_unit_stride_space();
    if (vt_failures == 0)
        sweep_whole_reg_alignment_vill();
    if (vt_failures == 0)
        check_state_preservation_and_data();
    return vt_finish("vec_mem_reserved_forms_test");
}
