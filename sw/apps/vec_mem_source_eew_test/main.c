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
 * Vector loads and stores that would read one register at two element widths
 * are reserved ("Vector Operands": a mask source has EEW 1), and FROST raises
 * an illegal-instruction exception for them, before any element:
 *   - a masked load or store whose index group contains v0;
 *   - a masked store whose data group contains v0, in every addressing mode
 *     and as a segment;
 *   - an indexed store, segment or not, whose data overlaps its index group
 *     when SEW differs from the index EEW.
 * Each case checks the trap, its mtval, that memory, the destination, vstart and
 * mstatus.VS are unchanged, beside a legal neighbor of the same form. Last, an
 * element of a strided or indexed run on a valid device register succeeds while
 * one on an unmapped device-quadrant address takes the access fault there, with
 * vstart naming it and the elements before it done.
 */

#include "../vec_common/vec_test.h"

/* A trap handler that leaves vstart and VS alone (vec_test.h's clears vstart,
 * which sets VS Dirty): it records mcause, mtval, vstart, VS and mepc, and
 * resumes after the trapping instruction. */
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

#define BUF 0x83100000ul
#define BUF_BYTES 0x200u
#define OUT (BUF + 0x800ul)
#define SNAPSHOT_OFFSET 0x200u
static volatile uint8_t *const buf = (volatile uint8_t *) BUF;
static volatile uint8_t *const out = (volatile uint8_t *) OUT;

#define LD 0x07u
#define ST 0x27u
#define VMEM(nf, mop, vm, rs2, w, vd, opc)                                                         \
    ((unsigned) (((nf) << 29) | ((mop) << 26) | ((vm) << 25) | ((rs2) << 20) | (10u << 15) |       \
                 ((w) << 12) | ((vd) << 7) | (opc)))
#define OPV(f6, vm, vs2, vs1, f3, vd)                                                              \
    ((unsigned) (((f6) << 26) | ((vm) << 25) | ((vs2) << 20) | ((vs1) << 15) | ((f3) << 12) |      \
                 ((vd) << 7) | 0x57u))
/* vsetvli t6, x0, vtype: vl = VLMAX */
#define VSETMAX(vtype) ((unsigned) (((vtype) << 20) | (7u << 12) | (31u << 7) | 0x57u))
#define E8M1 0x00u
#define E8M2 0x01u
#define E16M1 0x08u
#define E16M2 0x09u
#define E32M1 0x10u
#define E32M4 0x12u
#define VMV_VI(vd, imm) OPV(0x17u, 1u, 0u, (imm) & 31u, 3u, vd)
#define VID(vd) OPV(0x14u, 1u, 0u, 0x11u, 2u, vd)
/* An unmasked whole-register store, independent of the mask and vtype. */
#define STORE_REGS(reg, count, addr) RUN_AT(VMEM((count) - 1u, 0u, 1u, 8u, 0u, reg, ST), addr, 0ul)

#define EMIT(insn) __asm__ volatile(".word %0" : : "i"(insn) : "t6", "memory")
#define RUN(insn) RUN_AT(insn, BUF, 4ul)
/* a0 = base, t0 = stride */
#define RUN_AT(insn, base, stride)                                                                 \
    do {                                                                                           \
        register unsigned long a0_ __asm__("a0") = (base);                                         \
        register unsigned long t0_ __asm__("t0") = (stride);                                       \
        __asm__ volatile(".word %2" : : "r"(a0_), "r"(t0_), "i"(insn) : "t6", "memory");           \
    } while (0)

/* v0 all ones (every element active), v8 = 0, 1, 2, ..., v9 = 2, v16 = 7. */
static void setup(void)
{
    EMIT(VSETMAX(E8M1));
    EMIT(VMV_VI(0u, 31u));
    EMIT(VID(8u));
    EMIT(VMV_VI(9u, 2u));
    EMIT(VMV_VI(16u, 7u));
    for (unsigned i = 0; i < BUF_BYTES; i++)
        buf[i] = 0xA5u;
}

static unsigned vlmax_e8(void)
{
    return (unsigned) (VT_CSR_READ(vlenb));
}

static void check_buf_untouched(const char *what)
{
    unsigned bad = 0;
    for (unsigned i = 0; i < BUF_BYTES; i++)
        bad += buf[i] != 0xA5u;
    VT_EQ(bad, 0, what);
}

/* v16's bytes: the first n equal first, the rest equal rest. */
static void check_v16_bytes(unsigned n, uint8_t first, uint8_t rest, const char *what)
{
    EMIT(VSETMAX(E8M1));
    STORE_REGS(16u, 1u, OUT);
    unsigned bad = 0;
    for (unsigned i = 0; i < vlmax_e8(); i++)
        bad += out[i] != (i < n ? first : rest);
    VT_EQ(bad, 0, what);
}

static void check_v16_value(uint8_t want, const char *what)
{
    check_v16_bytes(0u, want, want, what);
}

static void check_saved_dest(unsigned regs, const char *what)
{
    unsigned bad = 0;
    for (unsigned i = 0; i < regs * vlmax_e8(); i++)
        bad += out[i] != out[SNAPSHOT_OFFSET + i];
    VT_EQ(bad, 0, what);
}

/* Every possible index fits in the checked memory window, including when v0
 * supplies the index at EEW 32. Mask bits 1 to 3 are active past vstart. */
static void setup_reserved(void)
{
    setup();
    EMIT(VSETMAX(E32M4));
    EMIT(VMV_VI(8u, 4u));
    EMIT(VSETMAX(E32M1));
    EMIT(VMV_VI(0u, 15u));
}

/* A reserved encoding: one illegal-instruction trap, mtval the encoding. */
#define RESERVED(vtype, insn, what, dest_regs)                                                     \
    do {                                                                                           \
        setup_reserved();                                                                          \
        if (dest_regs)                                                                             \
            STORE_REGS(((insn) >> 7) & 31u, dest_regs, OUT);                                       \
        EMIT(VSETMAX(vtype));                                                                      \
        VT_CSR_WRITE(vstart, 1ul);                                                                 \
        VT_CSR_WRITE(mstatus, (VT_CSR_READ(mstatus) & ~(3ul << 9)) | (2ul << 9));                  \
        vt_trap_clear();                                                                           \
        RUN(insn);                                                                                 \
        unsigned long vs_ = (VT_CSR_READ(mstatus) >> 9) & 3ul;                                     \
        VT_EQ(vt_trap_count, 1, what ": traps");                                                   \
        VT_EQ(vt_trap_cause, 2, what ": illegal instruction");                                     \
        VT_EQ(vt_trap_tval, (insn), what ": mtval");                                               \
        VT_EQ(vt_trap_vstart, 1, what ": vstart at the trap");                                     \
        VT_EQ(mem_trap_vs, 2, what ": VS Clean at the trap");                                      \
        VT_EQ(VT_CSR_READ(vstart), 1, what ": vstart kept");                                       \
        VT_EQ(vs_, 2, what ": VS stays Clean");                                                    \
        VT_CSR_WRITE(vstart, 0ul);                                                                 \
        check_buf_untouched(what ": memory unchanged");                                            \
        if (dest_regs) {                                                                           \
            STORE_REGS(((insn) >> 7) & 31u, dest_regs, OUT + SNAPSHOT_OFFSET);                     \
            check_saved_dest(dest_regs, what ": destination unchanged");                           \
        }                                                                                          \
    } while (0)

/* A legal neighbor: no trap. */
#define LEGAL(vtype, insn, what)                                                                   \
    do {                                                                                           \
        setup();                                                                                   \
        EMIT(VSETMAX(vtype));                                                                      \
        vt_trap_clear();                                                                           \
        RUN(insn);                                                                                 \
        VT_EQ(vt_trap_count, 0, what ": no trap");                                                 \
    } while (0)

static void masked_index_v0(void)
{
    /* vluxei8.v v16, (a0), v0, v0.t and vloxei16.v at SEW 16 (equal EEWs): v0 is mask and index */
    RESERVED(E8M1, VMEM(0u, 1u, 0u, 0u, 0u, 16u, LD), "vluxei8 v16,(a0),v0,v0.t", 1);
    RESERVED(E16M1, VMEM(0u, 3u, 0u, 0u, 5u, 16u, LD), "vloxei16 v16,(a0),v0,v0.t", 1);
    /* vsuxei8.v v8, (a0), v0, v0.t */
    RESERVED(E8M1, VMEM(0u, 1u, 0u, 0u, 0u, 8u, ST), "vsuxei8 v8,(a0),v0,v0.t", 0);
    /* Segments, and an index EEW of 32 at SEW 32. */
    RESERVED(E32M1, VMEM(1u, 1u, 0u, 0u, 0u, 8u, LD), "vluxseg2ei8 v8,(a0),v0,v0.t", 2);
    RESERVED(E32M1, VMEM(1u, 3u, 0u, 0u, 6u, 8u, LD), "vloxseg2ei32 v8,(a0),v0,v0.t", 2);
    RESERVED(E32M1, VMEM(0u, 3u, 0u, 0u, 6u, 8u, ST), "vsoxei32 v8,(a0),v0,v0.t", 0);
    /* Neighbors: v0 as an index without masking; index v8, masked, into v16. */
    LEGAL(E8M1, VMEM(0u, 1u, 1u, 0u, 0u, 8u, LD), "vluxei8 v8,(a0),v0");
    LEGAL(E8M1, VMEM(0u, 1u, 0u, 8u, 0u, 16u, LD), "vluxei8 v16,(a0),v8,v0.t");
    check_v16_value(0xA5u, "vluxei8 v16,(a0),v8,v0.t: loaded the buffer");
}

static void masked_store_data_v0(void)
{
    RESERVED(E8M1, VMEM(0u, 0u, 0u, 0u, 0u, 0u, ST), "vse8 v0,(a0),v0.t", 0);
    RESERVED(E8M2, VMEM(0u, 0u, 0u, 0u, 0u, 0u, ST), "vse8 v0,(a0),v0.t at LMUL 2", 0);
    RESERVED(E8M1, VMEM(0u, 2u, 0u, 5u, 0u, 0u, ST), "vsse8 v0,(a0),t0,v0.t", 0);
    RESERVED(E8M1, VMEM(0u, 1u, 0u, 8u, 0u, 0u, ST), "vsuxei8 v0,(a0),v8,v0.t", 0);
    RESERVED(E8M1, VMEM(1u, 0u, 0u, 0u, 0u, 0u, ST), "vsseg2e8 v0,(a0),v0.t", 0);
    RESERVED(E32M1, VMEM(0u, 0u, 0u, 0u, 6u, 0u, ST), "vse32 v0,(a0),v0.t", 0);
    RESERVED(E32M1, VMEM(0u, 2u, 0u, 5u, 6u, 0u, ST), "vsse32 v0,(a0),t0,v0.t", 0);
    RESERVED(E32M1, VMEM(0u, 1u, 0u, 8u, 6u, 0u, ST), "vsuxei32 v0,(a0),v8,v0.t", 0);
    RESERVED(E32M1, VMEM(1u, 0u, 0u, 0u, 6u, 0u, ST), "vsseg2e32 v0,(a0),v0.t", 0);
    RESERVED(E32M1, VMEM(1u, 2u, 0u, 5u, 6u, 0u, ST), "vssseg2e32 v0,(a0),t0,v0.t", 0);
    LEGAL(E32M1, VMEM(0u, 2u, 1u, 5u, 6u, 0u, ST), "vsse32 v0,(a0),t0");
    /* Neighbors: v0 stored unmasked (one width), and v8 stored under v0. */
    LEGAL(E8M1, VMEM(0u, 0u, 1u, 0u, 0u, 0u, ST), "vse8 v0,(a0)");
    unsigned bad = 0;
    for (unsigned i = 0; i < vlmax_e8(); i++)
        bad += buf[i] != 0xFFu;
    VT_EQ(bad, 0, "vse8 v0,(a0): stored the mask bytes");
    LEGAL(E8M1, VMEM(0u, 0u, 0u, 0u, 0u, 8u, ST), "vse8 v8,(a0),v0.t");
    bad = 0;
    for (unsigned i = 0; i < vlmax_e8(); i++)
        bad += buf[i] != (uint8_t) i;
    VT_EQ(bad, 0, "vse8 v8,(a0),v0.t: stored v8");
}

static void indexed_store_overlap(void)
{
    /* SEW 16, index EEW 8: vsuxei8.v v8, (a0), v8 reads v8 at both widths. */
    RESERVED(E16M1, VMEM(0u, 1u, 1u, 8u, 0u, 8u, ST), "vsuxei8 v8,(a0),v8 at SEW 16", 0);
    /* SEW 8, index EEW 32 (index group v8..v11): vsoxei32.v v8, (a0), v8. */
    RESERVED(E8M1, VMEM(0u, 3u, 1u, 8u, 6u, 8u, ST), "vsoxei32 v8,(a0),v8 at SEW 8", 0);
    /* At LMUL 2, the data group v8..v9 against index v8 or v9 at EEW 8, and an
     * index group v8..v9 at EEW 32 against data v8 at SEW 16. */
    RESERVED(E16M2, VMEM(0u, 1u, 1u, 8u, 0u, 8u, ST), "vsuxei8 v8,(a0),v8 at SEW 16, LMUL 2", 0);
    RESERVED(E16M2, VMEM(0u, 1u, 1u, 9u, 0u, 8u, ST), "vsuxei8 v8,(a0),v9 at SEW 16, LMUL 2", 0);
    RESERVED(E16M1, VMEM(0u, 3u, 1u, 8u, 6u, 8u, ST), "vsoxei32 v8,(a0),v8 at SEW 16", 0);
    /* Segment: fields v8, v9 at SEW 16 over index v9 at EEW 8. */
    RESERVED(E16M1, VMEM(1u, 1u, 1u, 9u, 0u, 8u, ST), "vsuxseg2ei8 v8,(a0),v9 at SEW 16", 0);
    /* Neighbors: equal widths may share a register. */
    LEGAL(E16M2, VMEM(0u, 1u, 1u, 8u, 5u, 8u, ST), "vsuxei16 v8,(a0),v8 at SEW 16, LMUL 2");
    LEGAL(E16M1, VMEM(1u, 1u, 1u, 9u, 5u, 8u, ST), "vsuxseg2ei16 v8,(a0),v9 at SEW 16");
    /* Byte i goes to offset i. */
    LEGAL(E8M1, VMEM(0u, 1u, 1u, 8u, 0u, 8u, ST), "vsuxei8 v8,(a0),v8 at SEW 8");
    unsigned bad = 0;
    for (unsigned i = 0; i < vlmax_e8(); i++)
        bad += buf[i] != (uint8_t) i;
    VT_EQ(bad, 0, "vsuxei8 v8,(a0),v8 at SEW 8: stored v8 at its own offsets");
}

static void existing_rule(void)
{
    /* A masked load into v0 also violates the destination overlap rule. */
    RESERVED(E8M1, VMEM(0u, 1u, 0u, 8u, 0u, 0u, LD), "vluxei8 v0,(a0),v8,v0.t", 1);
}

/* An element on a valid device register succeeds, while an element on an
 * unmapped device-quadrant address takes the access fault there. */
static void device_elements(void)
{
    const unsigned long mtime = 0x40000010ul;
    const unsigned long unmapped = 0x40040000ul;
    volatile uint32_t *idx = (volatile uint32_t *) (OUT + 0x400ul);

    /* Strided load crossing DDR -> MTIME succeeds. */
    setup();
    vt_trap_clear();
    RUN_AT(VMEM(0u, 2u, 1u, 5u, 0u, 16u, LD), BUF, mtime - BUF); /* vlse8 v16,(a0),t0 */
    VT_EQ(vt_trap_count, 1, "vlse8 past MTIME traps at unmapped elem 2");
    VT_EQ(vt_trap_cause, 5, "vlse8 past MTIME: load access fault");
    VT_EQ(VT_CSR_READ(vstart), 2, "vlse8 past MTIME: vstart=2 after DDR+MTIME");
    VT_CSR_WRITE(vstart, 0ul);

    /* Unmapped device-quadrant element at element 1 faults with vstart = 1. */
    setup();
    vt_trap_clear();
    RUN_AT(VMEM(0u, 2u, 1u, 5u, 0u, 16u, LD), BUF, unmapped - BUF); /* vlse8 v16,(a0),t0 */
    VT_EQ(vt_trap_count, 1, "vlse8 into unmapped gap: traps");
    VT_EQ(vt_trap_cause, 5, "vlse8 into unmapped gap: load access fault");
    VT_EQ(vt_trap_tval, unmapped, "vlse8 into unmapped gap: mtval");
    VT_EQ(VT_CSR_READ(vstart), 1, "vlse8 into unmapped gap: vstart");
    VT_CSR_WRITE(vstart, 0ul);
    check_v16_bytes(1u, 0xA5u, 7u, "vlse8 into unmapped gap: element 0 loaded, the rest kept");

    setup();
    vt_trap_clear();
    RUN_AT(VMEM(0u, 2u, 1u, 5u, 0u, 8u, ST), BUF, unmapped - BUF); /* vsse8 v8,(a0),t0 */
    VT_EQ(vt_trap_count, 1, "vsse8 into unmapped gap: traps");
    VT_EQ(vt_trap_cause, 7, "vsse8 into unmapped gap: store access fault");
    VT_EQ(vt_trap_tval, unmapped, "vsse8 into unmapped gap: mtval");
    VT_EQ(VT_CSR_READ(vstart), 1, "vsse8 into unmapped gap: vstart");
    VT_CSR_WRITE(vstart, 0ul);
    VT_EQ(buf[0], 0, "vsse8 into unmapped gap: element 0 stored");

    /* Indexed, from base 0: element 0 at BUF, element 1 at MTIME succeeds. */
    setup();
    for (unsigned i = 0; i < 16; i++)
        idx[i] = (uint32_t) BUF;
    idx[1] = (uint32_t) mtime;
    EMIT(VSETMAX(E32M1));
    RUN_AT(VMEM(0u, 0u, 1u, 0u, 6u, 8u, LD), OUT + 0x400ul, 0ul); /* vle32 v8,(a0) */
    vt_trap_clear();
    RUN_AT(VMEM(0u, 1u, 1u, 8u, 6u, 16u, LD), 0ul, 0ul); /* vluxei32 v16,(a0),v8 */
    VT_EQ(vt_trap_count, 0, "vluxei32 with MTIME element succeeds");

    /* Indexed, from base 0: element 0 at BUF, element 1 on unmapped gap. */
    setup();
    for (unsigned i = 0; i < 16; i++)
        idx[i] = (uint32_t) BUF;
    idx[1] = (uint32_t) unmapped;
    EMIT(VSETMAX(E32M1));
    RUN_AT(VMEM(0u, 0u, 1u, 0u, 6u, 8u, LD), OUT + 0x400ul, 0ul); /* vle32 v8,(a0) */
    vt_trap_clear();
    RUN_AT(VMEM(0u, 1u, 1u, 8u, 6u, 16u, LD), 0ul, 0ul); /* vluxei32 v16,(a0),v8 */
    VT_EQ(vt_trap_count, 1, "vluxei32 into unmapped gap: traps");
    VT_EQ(vt_trap_cause, 5, "vluxei32 into unmapped gap: load access fault");
    VT_EQ(vt_trap_tval, unmapped, "vluxei32 into unmapped gap: mtval");
    VT_EQ(VT_CSR_READ(vstart), 1, "vluxei32 into unmapped gap: vstart");
    VT_CSR_WRITE(vstart, 0ul);
    check_v16_bytes(4u, 0xA5u, 7u, "vluxei32 into unmapped gap: element 0 loaded, the rest kept");

    EMIT(VMV_VI(16u, 7u));
    EMIT(VSETMAX(E32M1));
    vt_trap_clear();
    RUN_AT(VMEM(0u, 1u, 1u, 8u, 6u, 16u, ST), 0ul, 0ul); /* vsuxei32 v16,(a0),v8 */
    VT_EQ(vt_trap_count, 1, "vsuxei32 into unmapped gap: traps");
    VT_EQ(vt_trap_cause, 7, "vsuxei32 into unmapped gap: store access fault");
    VT_EQ(vt_trap_tval, unmapped, "vsuxei32 into unmapped gap: mtval");
    VT_EQ(VT_CSR_READ(vstart), 1, "vsuxei32 into unmapped gap: vstart");
    VT_CSR_WRITE(vstart, 0ul);
    VT_EQ(buf[0], 7u, "vsuxei32 into unmapped gap: element 0 stored");
}

int main(void)
{
    vt_enable_vector();
    vt_trap_install();
    __asm__ volatile("csrw mtvec, %0" : : "r"(mem_trap_entry));
    masked_index_v0();
    masked_store_data_v0();
    indexed_store_overlap();
    existing_rule();
    device_elements();
    return vt_finish("vec_mem_source_eew_test");
}
