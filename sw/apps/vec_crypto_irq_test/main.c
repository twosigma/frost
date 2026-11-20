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
 * Machine-timer interrupts swept one cycle at a time across a crypto
 * instruction: its service at the ROB head and its execution in the vector
 * engine after it retires. mtime counts core cycles, so arming mtimecmp at
 * now + K for every K from shortly before the instruction to past the end of
 * its execution, as an uninterrupted run measures them, makes the interrupt
 * arrive in each cycle of both.
 *
 * The handler records mepc, vl, vtype and vstart, saves v8-v9 and v16-v17
 * with whole-register stores, changes vl and vtype, overwrites the registers,
 * restores them and returns. A whole-register store waits for the engine, so
 * the saved image must be the instruction's sources when mepc is at or before
 * it and its complete result when mepc is after it, never a mixture. After
 * each interrupt the destination, the key, vl, vtype and vstart must equal an
 * uninterrupted run's.
 *
 * Cases: vaesz.vs on two element groups (the result is checked against the
 * round-key XOR as well), the same after csrw vstart, 4 (the interrupt may
 * arrive between the two), and vclmul.vv on four elements, which runs one
 * element at a time.
 */
#include "../vec_common/vec_test.h"
#include "mmio.h"

/* Two-register images in the cached DDR scratch region. */
#define IMAGES_BASE 0x83008400ul
#define IMG_STATE (IMAGES_BASE + 0x000ul) /* v16-v17 */
#define IMG_KEY (IMAGES_BASE + 0x080ul)   /* v8-v9 */
#define IMG_V24 (IMAGES_BASE + 0x100ul)   /* v24-v25 */
#define IMG_RESULT (IMAGES_BASE + 0x180ul)
#define IMG_REFERENCE (IMAGES_BASE + 0x200ul)
#define IMG_SNAP (IMAGES_BASE + 0x280ul) /* the handler's copy of v16-v17 */
#define IMG_SAVE8 (IMAGES_BASE + 0x300ul)
#define IMG_KEY_AFTER (IMAGES_BASE + 0x380ul)
#define S_(x) #x
#define S(x) S_(x)
#define IMG(addr) ((volatile uint64_t *) (addr))

__attribute__((used)) volatile uint64_t g_irq, g_unexpected, g_mcause, g_mepc, g_vl, g_vtype,
    g_vstart;
__attribute__((used)) static uint64_t irq_save[5];

/* mscratch holds irq_save. The handler preserves t0-t3 and t6 and the vector
 * state it changes. */
__asm__(
    ".pushsection .text.vec_irq,\"ax\"\n"
    ".balign 4\n"
    "irq_entry:\n"
    "  csrrw  t6, mscratch, t6\n"
    "  sd     t0, 0(t6)\n"
    "  sd     t1, 8(t6)\n"
    "  sd     t2, 16(t6)\n"
    "  sd     t3, 24(t6)\n"
    "  csrr   t0, mcause\n"
    "  la     t1, g_mcause\n"
    "  sd     t0, 0(t1)\n"
    "  bgez   t0, 3f\n"
    "  li     t0, 0x4000001c\n" /* mtimecmp[63:32] = ~0: disarm */
    "  li     t1, -1\n"
    "  sw     t1, 0(t0)\n"
    "  la     t1, g_irq\n"
    "  ld     t0, 0(t1)\n"
    "  addi   t0, t0, 1\n"
    "  sd     t0, 0(t1)\n"
    "  csrr   t0, mepc\n"
    "  la     t1, g_mepc\n"
    "  sd     t0, 0(t1)\n"
    "  csrr   t2, vl\n"
    "  csrr   t3, vtype\n"
    "  la     t1, g_vl\n"
    "  sd     t2, 0(t1)\n"
    "  la     t1, g_vtype\n"
    "  sd     t3, 0(t1)\n"
    "  csrr   t0, vstart\n"
    "  la     t1, g_vstart\n"
    "  sd     t0, 0(t1)\n"
    "  sd     t0, 32(t6)\n"
    "  csrw   vstart, zero\n"
    "  li     t1, " S(
        IMG_SNAP) "\n"
                  "  .insn r 0x27, 0, 0x11, x16, t1, x8\n" /* vs2r.v v16 */
                  "  li     t1, " S(
                      IMG_SAVE8) "\n"
                                 "  .insn r 0x27, 0, 0x11, x8, t1, x8\n" /* vs2r.v v8 */
                                 "  .insn i 0x57, 7, t0, x0, 1\n" /* vsetvli t0, x0, e8, m2 */
                                 "  .word 0x5e0fb857\n"           /* vmv.v.i v16, -1 */
                                 "  .word 0x5e003457\n"           /* vmv.v.i v8, 0 */
                                 "  li     t1, " S(
                                     IMG_SNAP) "\n"
                                               "  .insn r 0x07, 0, 0x11, x16, t1, x8\n" /* vl2re8.v
                                                                                           v16 */
                                               "  li     t1, " S(
                                                   IMG_SAVE8) "\n"
                                                              "  .insn r 0x07, 0, 0x11, x8, t1, "
                                                              "x8\n" /* vl2re8.v v8 */
                                                              "  .insn r 0x57, 7, 0x40, x0, t2, "
                                                              "t3\n" /* vsetvl x0, t2, t3 */
                                                              "  ld     t0, 32(t6)\n"
                                                              "  csrw   vstart, t0\n"
                                                              "  j      4f\n"
                                                              "3:\n" /* an exception: count it and
                                                                        skip the instruction */
                                                              "  la     t1, g_unexpected\n"
                                                              "  ld     t0, 0(t1)\n"
                                                              "  addi   t0, t0, 1\n"
                                                              "  sd     t0, 0(t1)\n"
                                                              "  csrr   t0, mepc\n"
                                                              "  addi   t0, t0, 4\n"
                                                              "  csrw   mepc, t0\n"
                                                              "4:\n"
                                                              "  ld     t0, 0(t6)\n"
                                                              "  ld     t1, 8(t6)\n"
                                                              "  ld     t2, 16(t6)\n"
                                                              "  ld     t3, 24(t6)\n"
                                                              "  csrrw  t6, mscratch, t6\n"
                                                              "  mret\n"
                                                              ".popsection\n");
extern char irq_entry[];

#define OPV(f, m, a, b, t, d)                                                                      \
    (((uint32_t) (f) << 26) | ((m) << 25) | ((a) << 20) | ((b) << 15) | ((t) << 12) | ((d) << 7) | \
     0x57)
#define VAESZ_VS (OPV(0x29, 1, 8, 7, 2, 16) | 0x20u) /* vaesz.vs v16, v8 */
#define VCLMUL_VV OPV(0x0c, 1, 8, 24, 2, 16)         /* vclmul.vv v16, v8, v24 */

static unsigned long setvl(unsigned long avl, unsigned long vt)
{
    unsigned long vl;
    __asm__ volatile(".insn r 0x57, 7, 0x40, %0, %1, %2" : "=r"(vl) : "r"(avl), "r"(vt) : "memory");
    return vl;
}

static void load_registers(void)
{
    __asm__ volatile(".insn r 0x07, 0, 0x11, x8, %0, x8" ::"r"(IMG_KEY) : "memory");
    __asm__ volatile(".insn r 0x07, 0, 0x11, x16, %0, x8" ::"r"(IMG_STATE) : "memory");
    __asm__ volatile(".insn r 0x07, 0, 0x11, x24, %0, x8" ::"r"(IMG_V24) : "memory");
}

static void store_registers(unsigned long result)
{
    __asm__ volatile(".insn r 0x27, 0, 0x11, x16, %0, x8" ::"r"(result) : "memory");
    __asm__ volatile(".insn r 0x27, 0, 0x11, x8, %0, x8" ::"r"(IMG_KEY_AFTER) : "memory");
}

struct marks {
    unsigned long csrw, crypto;
};

/* Sets mstatus bits `mie`, runs the case's instruction and waits up to
 * `spins` polls for the interrupt, all in one block, so mepc orders against
 * the instruction by address. marks receives the addresses. */
#define WINDOW(prefix, word)                                                                       \
    __asm__ volatile("lla %0, 1f\n"                                                                \
                     "lla %1, 2f\n"                                                                \
                     "csrs mstatus, %4\n"                                                          \
                     "1: " prefix "\n"                                                             \
                     "2: .word %6\n"                                                               \
                     "3: ld %3, 0(%5)\n"                                                           \
                     "bnez %3, 4f\n"                                                               \
                     "addi %2, %2, -1\n"                                                           \
                     "bnez %2, 3b\n"                                                               \
                     "4: csrc mstatus, %4\n"                                                       \
                     : "=&r"(a), "=&r"(b), "+r"(spins), "=&r"(t)                                   \
                     : "r"(mie), "r"(&g_irq), "i"(word), "r"(4ul)                                  \
                     : "memory")

static void operation(unsigned c, unsigned long mie, unsigned long spins, struct marks *m)
{
    unsigned long a, b, t;
    switch (c) {
        case 0:
            WINDOW("nop", VAESZ_VS);
            break;
        case 1:
            WINDOW("csrw vstart, %7", VAESZ_VS);
            break;
        default:
            WINDOW("nop", VCLMUL_VV);
            break;
    }
    m->csrw = c == 1 ? a : 0;
    m->crypto = b;
}

static uint64_t rdmtime(void)
{
    uint32_t hi, lo;
    do {
        hi = MTIME_HI;
        lo = MTIME_LO;
    } while (hi != MTIME_HI);
    return ((uint64_t) hi << 32) | lo;
}

static void arm(uint64_t when)
{
    MTIMECMP_HI = ~0u;
    MTIMECMP_LO = (uint32_t) when;
    MTIMECMP_HI = (uint32_t) (when >> 32);
}

static unsigned g_words;
static unsigned g_before, g_at, g_after;

static uint32_t element32(volatile uint64_t *regs, unsigned e)
{
    return (uint32_t) (regs[e / 2] >> (32 * (e & 1)));
}

/* Two element groups of e32/m2 (vl = 8) or four elements of e64/m2 at every
 * vector length, so the sweep has the same length at each. */
static void run_case(unsigned c)
{
    const unsigned long vt = c == 2 ? VT_VTYPE(VT_E64, VT_M2, 0) : VT_VTYPE(VT_E32, VT_M2, 0);
    const unsigned long avl = c == 2 ? 4 : 8;
    const unsigned start = c == 1 ? 4 : 0;
    struct marks m;

    /* Uninterrupted reference run. lead is the time from reading mtime to
     * the window; busy runs to the end of the engine's execution, which a
     * vector CSR read waits for. */
    load_registers();
    unsigned long vl = setvl(avl, vt);
    VT_EQ(vl, avl, "case vl");
    uint64_t t0 = rdmtime();
    arm(~0ull);
    uint64_t t1 = rdmtime();
    operation(c, 0, 1, &m);
    (void) VT_CSR_READ(vl);
    uint64_t t2 = rdmtime();
    store_registers(IMG_REFERENCE);
    const uint64_t lead = t1 - t0, busy = t2 - t1;
    VT_EQ(VT_CSR_READ(vstart), 0, "reference run clears vstart");
    if (c < 2) {
        for (unsigned e = 0; e < g_words * 2; e++) {
            uint32_t initial = element32(IMG(IMG_STATE), e);
            uint32_t want =
                e >= start && e < vl ? initial ^ element32(IMG(IMG_KEY), e % 4) : initial;
            VT_EQ(element32(IMG(IMG_REFERENCE), e), want, "round-zero reference");
        }
    }

    unsigned before = 0, at = 0, after = 0;
    for (uint64_t k = lead > 16 ? lead - 16 : 0; k <= lead + busy + 16; k++) {
        load_registers();
        setvl(avl, vt);
        g_irq = 0;
        g_mepc = 0;
        g_vstart = ~0ul;
        arm(rdmtime() + k);
        operation(c, 8, 4096, &m);
        MTIMECMP_HI = ~0u;
        store_registers(IMG_RESULT);
        VT_EQ(g_irq, 1, "one interrupt per arming");
        VT_EQ(g_mcause, 0x8000000000000007ull, "machine timer interrupt");
        VT_EQ(VT_CSR_READ(vl), vl, "vl after the interrupt");
        VT_EQ(VT_CSR_READ(vtype), vt, "vtype after the interrupt");
        VT_EQ(VT_CSR_READ(vstart), 0, "vstart after the instruction");
        VT_EQ(g_vl, vl, "vl seen by the handler");
        VT_EQ(g_vtype, vt, "vtype seen by the handler");
        int executed = g_mepc > m.crypto;
        int restarting = m.csrw != 0 && g_mepc > m.csrw && g_mepc <= m.crypto;
        VT_EQ(g_vstart, restarting ? 4 : 0, "vstart seen by the handler");
        before += g_mepc < m.crypto;
        at += g_mepc == m.crypto;
        after += executed;
        unsigned bad_snap = 0, bad_result = 0, bad_key = 0;
        for (unsigned w = 0; w < g_words; w++) {
            uint64_t old = IMG(IMG_STATE)[w], done = IMG(IMG_REFERENCE)[w];
            bad_snap += IMG(IMG_SNAP)[w] != (executed ? done : old);
            bad_result += IMG(IMG_RESULT)[w] != done;
            bad_key += IMG(IMG_KEY_AFTER)[w] != IMG(IMG_KEY)[w];
        }
        VT_EQ(bad_snap, 0, "handler sees all of the instruction or none");
        VT_EQ(bad_result, 0, "interrupted result");
        VT_EQ(bad_key, 0, "interrupted key");
        if (bad_snap || bad_result) {
            vt_puts("  at k=");
            vt_dec(k);
            vt_puts(" mepc-crypto=");
            vt_dec(g_mepc - m.crypto);
            vt_puts("\r\n");
        }
    }
    VT_TRUE(before != 0, "interrupts before the instruction");
    VT_TRUE(at != 0, "interrupts at the instruction");
    VT_TRUE(after != 0, "interrupts after the instruction");
    g_before += before;
    g_at += at;
    g_after += after;
}

int main(void)
{
    vt_enable_vector();
    g_words = (unsigned) (2 * vt_vlenb() / 8); /* 64-bit words in two registers */
    __asm__ volatile("csrw mscratch, %0" ::"r"(irq_save));
    __asm__ volatile("csrw mtvec, %0" ::"r"(irq_entry));
    uint64_t seed = 0x9e3779b97f4a7c15ull;
    for (unsigned w = 0; w < 3 * g_words; w++)
        IMG(IMAGES_BASE)[w + (w / g_words) * (16 - g_words)] = vt_rand(&seed);
    MTIMECMP_HI = ~0u;
    __asm__ volatile("csrs mie, %0" ::"r"(1ul << 7));
    for (unsigned c = 0; c < 3; c++)
        run_case(c);
    __asm__ volatile("csrc mie, %0" ::"r"(1ul << 7));
    VT_EQ(g_unexpected, 0, "no exceptions");
    vt_puts("interrupts before ");
    vt_dec(g_before);
    vt_puts(", at ");
    vt_dec(g_at);
    vt_puts(", after ");
    vt_dec(g_after);
    vt_puts("\r\n");
    return vt_finish("vec_crypto_irq_test");
}
