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
 * Directed test for the registered uncached-port grant when buffered scalar
 * low-BRAM stores are still in flight in the uncached adapter right before an
 * uncached vector load or store:
 *   1. Single and back-to-back buffered scalar low-BRAM stores (sw/sd)
 *      immediately followed (no fence) by unit-stride, strided, indexed,
 *      segment, fault-only-first, and whole-register uncached vector loads
 *      and stores targeting the same low-BRAM addresses, distinct low-BRAM
 *      addresses, and side-effecting MMIO devices (FIFO0/FIFO1).
 *   2. Sub-word and doubleword element widths (EEW 8/32/64) across all three
 *      supported vector lengths (VLEN 128, 256, 512).
 *   3. Vector memory retirement immediately followed by a scalar misaligned
 *      cached-DDR load and store, exercising the misaligned-assist window
 *      behind a retiring vector memory shield.
 */

#include <stdint.h>

#include "csr.h"
#include "mmio.h"
#include "trap.h"
#include "uart.h"

#define FIFO0_PA 0x40000008ul
#define FIFO1_PA 0x4000000Cul

/* Fixed low-BRAM scratch buffers in [0x29000, 0x29C00), valid in both BRAM and DDR layouts. */
#define BRAM_A_PA 0x00029000ul
#define BRAM_B_PA 0x00029200ul
#define BRAM_IDX_PA 0x00029400ul
#define BRAM_DUMP_PA 0x00029600ul
#define DDR_MA_PA 0x83204000ul

#define MSTATUS_VS (3ul << 9)
#define VS_INITIAL (1ul << 9)

#define VT_E8 0u
#define VT_E32 2u
#define VT_E64 3u
#define VT_M1 0u
#define VT_VTYPE(sew, lmul) ((unsigned long) (((sew) << 3) | (lmul)))

static volatile uint32_t *const bram_a32 = (volatile uint32_t *) BRAM_A_PA;
static volatile uint32_t *const bram_b32 = (volatile uint32_t *) BRAM_B_PA;
static volatile uint32_t *const bram_idx32 = (volatile uint32_t *) BRAM_IDX_PA;
static volatile uint32_t *const bram_dump32 = (volatile uint32_t *) BRAM_DUMP_PA;
static volatile uint8_t *const ddr_ma = (volatile uint8_t *) DDR_MA_PA;

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

static inline unsigned long setvl(unsigned long avl, unsigned long vtype)
{
    unsigned long vl;
    __asm__ volatile(".insn r 0x57, 7, 0x40, %0, %1, %2"
                     : "=r"(vl)
                     : "r"(avl), "r"(vtype)
                     : "memory");
    return vl;
}

static inline void load_v8_e32(const volatile void *src)
{
    __asm__ volatile(".insn r 0x07, 6, 0x01, x8, %0, x0" : : "r"(src) : "memory");
}

static inline void store_v8_e32(volatile void *dst)
{
    __asm__ volatile(".insn r 0x27, 6, 0x01, x8, %0, x0" : : "r"(dst) : "memory");
}

static inline void load_v9_e32(const volatile void *src)
{
    __asm__ volatile(".insn r 0x07, 6, 0x01, x9, %0, x0" : : "r"(src) : "memory");
}

static inline void store_v9_e32(volatile void *dst)
{
    __asm__ volatile(".insn r 0x27, 6, 0x01, x9, %0, x0" : : "r"(dst) : "memory");
}

static inline void load_v16_e32(const volatile void *src)
{
    __asm__ volatile(".insn r 0x07, 6, 0x01, x16, %0, x0" : : "r"(src) : "memory");
}

static void drain_fifos(void)
{
    for (int i = 0; i < 64; i++) {
        (void) FIFO0;
        (void) FIFO1;
    }
}

static void __attribute__((used, noreturn))
unexpected_trap_c(unsigned long cause, unsigned long epc, unsigned long tval)
{
    uart_printf("[UNEXPECTED TRAP] cause=%lx epc=%lx tval=%lx\n<<FAIL>>\n", cause, epc, tval);
    for (;;) {
    }
}

__attribute__((naked, aligned(4))) static void trap_entry(void)
{
    __asm__ volatile("csrr a0, mcause\n"
                     "csrr a1, mepc\n"
                     "csrr a2, mtval\n"
                     "j unexpected_trap_c\n");
}

static void test_scalar_store_before_vec_load(void)
{
    setvl(4, VT_VTYPE(VT_E32, VT_M1));

    for (unsigned iter = 0; iter < 8u; iter++) {
        uint32_t v0 = 0x10000000u + (iter << 8) + 0u;
        uint32_t v1 = 0x10000000u + (iter << 8) + 1u;
        uint32_t v2 = 0x10000000u + (iter << 8) + 2u;
        uint32_t v3 = 0x10000000u + (iter << 8) + 3u;
        uint64_t d01 = ((uint64_t) v1 << 32) | v0;
        uint64_t d23 = ((uint64_t) v3 << 32) | v2;

        /* 1a. Back-to-back buffered scalar low-BRAM sd stores immediately
         *     followed by vle32.v to the SAME low-BRAM buffer. */
        bram_a32[0] = 0xDEAD0000u;
        bram_a32[1] = 0xDEAD0001u;
        bram_a32[2] = 0xDEAD0002u;
        bram_a32[3] = 0xDEAD0003u;
        __asm__ volatile("sd %0, 0(%2)\n"
                         "sd %1, 8(%2)\n"
                         ".insn r 0x07, 6, 0x01, x8, %2, x0\n"
                         :
                         : "r"(d01), "r"(d23), "r"(bram_a32)
                         : "memory");
        store_v8_e32(bram_dump32);
        check(bram_dump32[0] == v0 && bram_dump32[1] == v1 && bram_dump32[2] == v2 &&
                  bram_dump32[3] == v3,
              "sd+sd -> vle32 same BRAM",
              iter,
              bram_dump32[0],
              v0);

        /* 1b. Single buffered scalar sw immediately followed by vle32.v to a
         *     DIFFERENT low-BRAM buffer (keeps write_count_q=1 during read). */
        for (unsigned i = 0; i < 4u; i++)
            bram_b32[i] = 0x20000000u + (iter << 8) + i;
        uint32_t tag = 0x33000000u + iter;
        __asm__ volatile("sw %0, 0(%1)\n"
                         ".insn r 0x07, 6, 0x01, x8, %2, x0\n"
                         :
                         : "r"(tag), "r"(bram_a32), "r"(bram_b32)
                         : "memory");
        store_v8_e32(bram_dump32);
        check(bram_a32[0] == tag && bram_dump32[0] == (0x20000000u + (iter << 8)) &&
                  bram_dump32[3] == (0x20000003u + (iter << 8)),
              "sw -> vle32 other BRAM",
              iter,
              bram_dump32[0],
              0x20000000u + (iter << 8));

        /* 1c. Back-to-back buffered scalar low-BRAM sd stores immediately
         *     followed by stride-0 vlse32.v popping FIFO0 (side-effecting). */
        drain_fifos();
        for (unsigned i = 0; i < 5u; i++)
            FIFO0 = 0x40000000u + (iter << 8) + i;
        uint64_t zero_stride = 0ul;
        __asm__ volatile("sd %0, 0(%3)\n"
                         "sd %1, 8(%3)\n"
                         ".insn r 0x07, 6, 0x05, x8, %2, %4\n"
                         :
                         : "r"(d01 ^ 0x5555555555555555ull),
                           "r"(d23 ^ 0x5555555555555555ull),
                           "r"(FIFO0_PA),
                           "r"(bram_a32),
                           "r"(zero_stride)
                         : "memory");
        store_v8_e32(bram_dump32);
        uint32_t sent = FIFO0;
        check(bram_dump32[0] == (0x40000000u + (iter << 8)) &&
                  bram_dump32[3] == (0x40000003u + (iter << 8)) &&
                  sent == (0x40000004u + (iter << 8)) && FIFO0 == 0u,
              "sd+sd -> vlse32 FIFO0",
              iter,
              sent,
              0x40000004u + (iter << 8));
    }
}

static void test_scalar_store_before_vec_store(void)
{
    setvl(4, VT_VTYPE(VT_E32, VT_M1));

    for (unsigned iter = 0; iter < 8u; iter++) {
        uint32_t vec_vals[4];
        for (unsigned i = 0; i < 4u; i++)
            vec_vals[i] = 0x50000000u + (iter << 8) + i;
        for (unsigned i = 0; i < 4u; i++)
            bram_dump32[i] = vec_vals[i];
        load_v8_e32(bram_dump32);

        uint64_t s01 = 0xAAAAAAAA00000000ull | (0xBB000000u + iter);
        uint64_t s23 = 0xCCCCCCCC00000000ull | (0xDD000000u + iter);

        /* 2a. Back-to-back buffered scalar low-BRAM sd stores immediately
         *     followed by vse32.v to the SAME low-BRAM buffer. The vector
         *     store must wait for both buffered writes and overwrite them. */
        __asm__ volatile("sd %0, 0(%2)\n"
                         "sd %1, 8(%2)\n"
                         ".insn r 0x27, 6, 0x01, x8, %2, x0\n"
                         :
                         : "r"(s01), "r"(s23), "r"(bram_a32)
                         : "memory");
        for (unsigned i = 0; i < 4u; i++)
            check(bram_a32[i] == vec_vals[i],
                  "sd+sd -> vse32 same BRAM",
                  (iter << 4) | i,
                  bram_a32[i],
                  vec_vals[i]);

        /* 2b. Back-to-back buffered scalar low-BRAM sd stores immediately
         *     followed by vse32.v to a DIFFERENT low-BRAM buffer. Both the
         *     scalar stores and all 4 vector store beats must land intact. */
        for (unsigned i = 0; i < 4u; i++)
            bram_b32[i] = 0u;
        __asm__ volatile("sd %0, 0(%2)\n"
                         "sd %1, 8(%2)\n"
                         ".insn r 0x27, 6, 0x01, x8, %3, x0\n"
                         :
                         : "r"(s01), "r"(s23), "r"(bram_a32), "r"(bram_b32)
                         : "memory");
        check(*(volatile uint64_t *) &bram_a32[0] == s01 &&
                  *(volatile uint64_t *) &bram_a32[2] == s23,
              "sd+sd -> vse32 other BRAM (scalar intact)",
              iter,
              *(volatile uint64_t *) &bram_a32[0],
              s01);
        for (unsigned i = 0; i < 4u; i++)
            check(bram_b32[i] == vec_vals[i],
                  "sd+sd -> vse32 other BRAM (vec intact)",
                  (iter << 4) | i,
                  bram_b32[i],
                  vec_vals[i]);

        /* 2c. Back-to-back buffered scalar low-BRAM sd stores immediately
         *     followed by stride-0 vsse32.v pushing 4 words into FIFO0. */
        drain_fifos();
        uint64_t zero_stride = 0ul;
        __asm__ volatile(
            "sd %0, 0(%2)\n"
            "sd %1, 8(%2)\n"
            ".insn r 0x27, 6, 0x05, x8, %3, %4\n"
            :
            : "r"(s01 ^ 1ull), "r"(s23 ^ 1ull), "r"(bram_a32), "r"(FIFO0_PA), "r"(zero_stride)
            : "memory");
        for (unsigned i = 0; i < 4u; i++) {
            uint32_t popped = FIFO0;
            check(popped == vec_vals[i],
                  "sd+sd -> vsse32 FIFO0",
                  (iter << 4) | i,
                  popped,
                  vec_vals[i]);
        }
        check(FIFO0 == 0u, "sd+sd -> vsse32 FIFO0 empty", iter, FIFO0, 0u);
    }
}

static void test_scalar_store_before_other_forms_and_widths(void)
{
    /* 3a. Indexed ordered load and store (vloxei32 / vsoxei32) after sd+sd. */
    setvl(4, VT_VTYPE(VT_E32, VT_M1));
    bram_idx32[0] = 12u;
    bram_idx32[1] = 4u;
    bram_idx32[2] = 8u;
    bram_idx32[3] = 0u;
    load_v16_e32(bram_idx32);

    uint64_t d01 = 0x6100000161000000ull;
    uint64_t d23 = 0x6100000361000002ull;
    __asm__ volatile("sd %0, 0(%2)\n"
                     "sd %1, 8(%2)\n"
                     ".insn r 0x07, 6, 0x07, x8, %2, x16\n"
                     :
                     : "r"(d01), "r"(d23), "r"(bram_a32)
                     : "memory");
    store_v8_e32(bram_dump32);
    check(bram_dump32[0] == 0x61000003u && bram_dump32[1] == 0x61000001u &&
              bram_dump32[2] == 0x61000002u && bram_dump32[3] == 0x61000000u,
          "sd+sd -> vloxei32 BRAM",
          0,
          bram_dump32[0],
          0x61000003u);

    __asm__ volatile("sd %0, 0(%2)\n"
                     "sd %1, 8(%2)\n"
                     ".insn r 0x27, 6, 0x07, x8, %3, x16\n"
                     :
                     : "r"(d01 ^ 0x1010101010101010ull),
                       "r"(d23 ^ 0x1010101010101010ull),
                       "r"(bram_a32),
                       "r"(bram_b32)
                     : "memory");
    check(bram_b32[0] == 0x61000000u && bram_b32[1] == 0x61000001u && bram_b32[2] == 0x61000002u &&
              bram_b32[3] == 0x61000003u,
          "sd+sd -> vsoxei32 BRAM",
          0,
          bram_b32[0],
          0x61000000u);

    /* 3b. Segment nf=2 store and load (vssseg2e32 / vlsseg2e32) on FIFO0/FIFO1
     *     immediately after buffered scalar low-BRAM sd+sd stores. */
    drain_fifos();
    for (unsigned i = 0; i < 4u; i++)
        bram_dump32[i] = 0x70000000u + i;
    load_v8_e32(bram_dump32);
    for (unsigned i = 0; i < 4u; i++)
        bram_dump32[i] = 0x71000000u + i;
    load_v9_e32(bram_dump32);
    uint64_t zero_stride = 0ul;
    __asm__ volatile("sd %0, 0(%2)\n"
                     "sd %1, 8(%2)\n"
                     ".insn r 0x27, 6, 0x15, x8, %3, %4\n"
                     :
                     : "r"(d01), "r"(d23), "r"(bram_a32), "r"(FIFO0_PA), "r"(zero_stride)
                     : "memory");
    __asm__ volatile(
        "sd %0, 0(%2)\n"
        "sd %1, 8(%2)\n"
        ".insn r 0x07, 6, 0x15, x8, %3, %4\n"
        :
        : "r"(d01 ^ 2ull), "r"(d23 ^ 2ull), "r"(bram_a32), "r"(FIFO0_PA), "r"(zero_stride)
        : "memory");
    store_v8_e32(bram_dump32);
    for (unsigned i = 0; i < 4u; i++)
        check(bram_dump32[i] == 0x70000000u + i,
              "sd+sd -> vssseg2/vlsseg2 FIFO0",
              i,
              bram_dump32[i],
              0x70000000u + i);
    store_v9_e32(bram_dump32);
    for (unsigned i = 0; i < 4u; i++)
        check(bram_dump32[i] == 0x71000000u + i,
              "sd+sd -> vssseg2/vlsseg2 FIFO1",
              i,
              bram_dump32[i],
              0x71000000u + i);
    check(FIFO0 == 0u && FIFO1 == 0u, "sd+sd -> seg FIFOs drained", 0, FIFO0, 0u);

    /* 3c. Fault-only-first vle32ff.v and whole-register vl1re32/vs1r after sd+sd. */
    __asm__ volatile("sd %0, 0(%2)\n"
                     "sd %1, 8(%2)\n"
                     ".insn r 0x07, 6, 0x01, x8, %2, x16\n"
                     :
                     : "r"(d01), "r"(d23), "r"(bram_a32)
                     : "memory");
    store_v8_e32(bram_dump32);
    check(bram_dump32[0] == 0x61000000u && bram_dump32[3] == 0x61000003u,
          "sd+sd -> vle32ff BRAM",
          0,
          bram_dump32[0],
          0x61000000u);

    for (unsigned i = 0; i < g_vlenb / 4u; i++) {
        bram_a32[i] = 0x80000000u + i;
        bram_b32[i] = 0u;
    }
    __asm__ volatile("sd %0, 0(%2)\n"
                     "sd %1, 8(%2)\n"
                     ".insn r 0x07, 6, 0x01, x8, %2, x8\n"
                     :
                     : "r"(0x8000000180000000ull), "r"(0x8000000380000002ull), "r"(bram_a32)
                     : "memory");
    __asm__ volatile(
        "sd %0, 0(%2)\n"
        "sd %1, 8(%2)\n"
        ".insn r 0x27, 0, 0x01, x8, %3, x8\n"
        :
        : "r"(0x8100000181000000ull), "r"(0x8100000381000002ull), "r"(bram_a32), "r"(bram_b32)
        : "memory");
    for (unsigned i = 0; i < g_vlenb / 4u; i++)
        check(bram_b32[i] == 0x80000000u + i,
              "sd+sd -> vl1re32/vs1r BRAM",
              i,
              bram_b32[i],
              0x80000000u + i);

    /* 3d. Byte (EEW=8) and doubleword (EEW=64) after buffered scalar stores. */
    setvl(8, VT_VTYPE(VT_E8, VT_M1));
    uint64_t bpat = 0x0807060504030201ull;
    __asm__ volatile("sd %0, 0(%1)\n"
                     ".insn r 0x07, 0, 0x01, x8, %1, x0\n"
                     :
                     : "r"(bpat), "r"(bram_a32)
                     : "memory");
    __asm__ volatile("sd %0, 0(%1)\n"
                     ".insn r 0x27, 0, 0x01, x8, %2, x0\n"
                     :
                     : "r"(~bpat), "r"(bram_a32), "r"(bram_b32)
                     : "memory");
    check(*(volatile uint64_t *) bram_b32 == bpat,
          "sd -> vle8/vse8 BRAM",
          0,
          *(volatile uint64_t *) bram_b32,
          bpat);

    setvl(2, VT_VTYPE(VT_E64, VT_M1));
    uint64_t q0 = 0x1122334455667788ull;
    uint64_t q1 = 0x99AABBCCDDEEFF00ull;
    __asm__ volatile("sd %0, 0(%2)\n"
                     "sd %1, 8(%2)\n"
                     ".insn r 0x07, 7, 0x01, x8, %2, x0\n"
                     :
                     : "r"(q0), "r"(q1), "r"(bram_a32)
                     : "memory");
    __asm__ volatile("sd %0, 0(%2)\n"
                     "sd %1, 8(%2)\n"
                     ".insn r 0x27, 7, 0x01, x8, %3, x0\n"
                     :
                     : "r"(~q0), "r"(~q1), "r"(bram_a32), "r"(bram_b32)
                     : "memory");
    check(*(volatile uint64_t *) &bram_b32[0] == q0 && *(volatile uint64_t *) &bram_b32[2] == q1,
          "sd+sd -> vle64/vse64 BRAM",
          0,
          *(volatile uint64_t *) &bram_b32[0],
          q0);
}

static void test_vec_retire_before_scalar_misaligned(void)
{
    /* Exercise a retiring vector memory op immediately followed by a scalar
     * misaligned cached-DDR load and store, verifying hardware assist runs
     * cleanly without taking an architectural misaligned exception. */
    setvl(4, VT_VTYPE(VT_E32, VT_M1));
    for (unsigned i = 0; i < 32u; i++)
        ddr_ma[i] = (uint8_t) (0xA0u + i);
    for (unsigned i = 0; i < 4u; i++)
        bram_a32[i] = 0x90000000u + i;

    for (unsigned off = 1u; off <= 7u; off++) {
        uint64_t ma_addr = DDR_MA_PA + off;
        uint64_t loaded = 0ul;
        /* Cached DDR vector load immediately followed by scalar misaligned ld. */
        __asm__ volatile(".insn r 0x07, 6, 0x01, x8, %1, x0\n"
                         "ld %0, 0(%2)\n"
                         : "=r"(loaded)
                         : "r"(DDR_MA_PA), "r"(ma_addr)
                         : "memory");
        uint64_t want = 0ul;
        for (unsigned b = 0; b < 8u; b++)
            want |= ((uint64_t) (uint8_t) (0xA0u + off + b)) << (b * 8u);
        check(loaded == want, "cached vle32 -> scalar ma ld", off, loaded, want);

        /* Uncached low-BRAM vector load immediately followed by scalar misaligned ld. */
        loaded = 0ul;
        __asm__ volatile(".insn r 0x07, 6, 0x01, x8, %1, x0\n"
                         "ld %0, 0(%2)\n"
                         : "=r"(loaded)
                         : "r"(bram_a32), "r"(ma_addr)
                         : "memory");
        check(loaded == want, "uncached vle32 -> scalar ma ld", off, loaded, want);

        /* Uncached low-BRAM vector store immediately followed by scalar misaligned sd. */
        uint64_t store_val = 0x554433221100FF00ull | off;
        uint64_t ma_dst = DDR_MA_PA + 16ul + off;
        __asm__ volatile(".insn r 0x27, 6, 0x01, x8, %0, x0\n"
                         "sd %1, 0(%2)\n"
                         :
                         : "r"(bram_b32), "r"(store_val), "r"(ma_dst)
                         : "memory");
        uint64_t readback = 0ul;
        for (unsigned b = 0; b < 8u; b++)
            readback |= ((uint64_t) ddr_ma[16u + off + b]) << (b * 8u);
        check(readback == store_val, "uncached vse32 -> scalar ma sd", off, readback, store_val);
    }
}

int main(void)
{
    set_trap_handler(trap_entry);
    csr_clear(mstatus, MSTATUS_VS);
    csr_set(mstatus, VS_INITIAL);
    __asm__ volatile("csrr %0, 0xC22" : "=r"(g_vlenb));
    uart_printf("vec_uncached_grant_test VLEN=%lu\n", g_vlenb * 8ul);

    test_scalar_store_before_vec_load();
    test_scalar_store_before_vec_store();
    test_scalar_store_before_other_forms_and_widths();
    test_vec_retire_before_scalar_misaligned();

    uart_printf("vec_uncached_grant_test checks=%d %s\n", g_checks, g_ok ? "<<PASS>>" : "<<FAIL>>");
    for (;;) {
    }
    return 0;
}
