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

/**
 * RISC-V ISA Compliance Test Suite for Frost Processor
 *
 * Tests all extensions claimed by Frost (RV32IMAFDCB):
 *   - RV32I:  Base integer instruction set
 *   - M:      Integer multiply/divide
 *   - A:      Atomic memory operations
 *   - F:      Single-precision floating-point
 *   - D:      Double-precision floating-point
 *   - C:      Compressed 16-bit instructions
 *   - B:      Bit manipulation (B = Zba + Zbb + Zbs)
 *   - Zicsr:  CSR access instructions
 *   - Zicntr: Base counters (cycle, time, instret)
 *   - Zifencei: Instruction fetch fence
 *   - Zicond: Conditional zero operations
 *   - Zbkb:   Bit manipulation for cryptography
 *   - Zihintpause: Pause hint for spin-wait loops
 *
 * Each instruction is tested with known inputs and expected outputs.
 * Results are tracked per-instruction and summarized by extension.
 */

#include "mmio.h"
#include "string.h"
#include "timer.h"
#include "uart.h"
#include <stdbool.h>
#include <stdint.h>

/* ========================================================================== */
/* Test Framework                                                             */
/* ========================================================================== */

/* Maximum number of tests per extension */
#define MAX_TESTS_PER_EXT 64

/* Compact mode: use test numbers instead of names to save space */
#define COMPACT_MODE 1

/* Extension IDs */
typedef enum {
    EXT_RV32I = 0,
    EXT_M,
    EXT_A,
    EXT_C,
    EXT_F,
    EXT_D,
    EXT_ZICSR,
    EXT_ZICNTR,
    EXT_ZIFENCEI,
    EXT_ZBA,
    EXT_ZBB,
    EXT_ZBS,
    EXT_ZICOND,
    EXT_ZBKB,
    EXT_ZIHINTPAUSE,
    EXT_MMODE,
    EXT_COUNT
} extension_id_t;

/* Extension names for reporting */
static const char *extension_names[EXT_COUNT] = {
    "RV32I",       /* Base integer */
    "M",           /* Multiply/divide */
    "A",           /* Atomics */
    "C",           /* Compressed 16-bit instructions */
    "F",           /* Single-precision floating-point */
    "D",           /* Double-precision floating-point */
    "Zicsr",       /* CSR instructions */
    "Zicntr",      /* Counters */
    "Zifencei",    /* Instruction fence */
    "Zba",         /* Address generation */
    "Zbb",         /* Bit manipulation */
    "Zbs",         /* Single-bit ops */
    "Zicond",      /* Conditional zero */
    "Zbkb",        /* Crypto bit ops */
    "Zihintpause", /* Pause hint */
    "MachMode"     /* Machine mode (RTOS support) */
};

/* Test result tracking */
typedef struct {
    uint32_t tests_passed;
    uint32_t tests_failed;
    uint32_t failed_mask; /* Bitmask of which tests failed (up to 32) */
} extension_result_t;

static extension_result_t results[EXT_COUNT];

#if !COMPACT_MODE
/* Failed instruction names (stored when a test fails) - not used in compact mode */
static const char *failed_instructions[EXT_COUNT][MAX_TESTS_PER_EXT];
static uint32_t failed_count[EXT_COUNT];
#endif

/* Current extension being tested */
static extension_id_t current_ext;
static uint32_t current_test_index;

/* Test macros */
#define BEGIN_EXTENSION(ext)                                                                       \
    do {                                                                                           \
        current_ext = (ext);                                                                       \
        current_test_index = 0;                                                                    \
        uart_printf("Testing %s...", extension_names[ext]);                                        \
    } while (0)

#define END_EXTENSION()                                                                            \
    do {                                                                                           \
        if (results[current_ext].tests_failed == 0) {                                              \
            uart_printf(" OK (%lu)\n", (unsigned long) results[current_ext].tests_passed);         \
        } else {                                                                                   \
            uart_printf(" FAIL\n");                                                                \
        }                                                                                          \
    } while (0)

#if COMPACT_MODE
/* Compact mode: no test names stored, use test index for failure identification */
#define TEST(name, got, expected)                                                                  \
    do {                                                                                           \
        uint32_t _got = (got);                                                                     \
        uint32_t _exp = (expected);                                                                \
        if (_got == _exp) {                                                                        \
            results[current_ext].tests_passed++;                                                   \
        } else {                                                                                   \
            results[current_ext].tests_failed++;                                                   \
            results[current_ext].failed_mask |= (1U << (current_test_index & 31));                 \
            uart_printf(                                                                           \
                "\n  #%lu:0x%08X!=0x%08X", (unsigned long) current_test_index, _got, _exp);        \
        }                                                                                          \
        current_test_index++;                                                                      \
    } while (0)
#define TEST64(name, got, expected)                                                                \
    do {                                                                                           \
        uint64_t _got = (got);                                                                     \
        uint64_t _exp = (expected);                                                                \
        if (_got == _exp) {                                                                        \
            results[current_ext].tests_passed++;                                                   \
        } else {                                                                                   \
            results[current_ext].tests_failed++;                                                   \
            results[current_ext].failed_mask |= (1U << (current_test_index & 31));                 \
            uart_printf("\n  #%lu:0x%08X%08X!=0x%08X%08X",                                         \
                        (unsigned long) current_test_index,                                        \
                        (unsigned) (_got >> 32),                                                   \
                        (unsigned) _got,                                                           \
                        (unsigned) (_exp >> 32),                                                   \
                        (unsigned) _exp);                                                          \
        }                                                                                          \
        current_test_index++;                                                                      \
    } while (0)
#else
#define TEST(name, got, expected)                                                                  \
    do {                                                                                           \
        uint32_t _got = (got);                                                                     \
        uint32_t _exp = (expected);                                                                \
        if (_got == _exp) {                                                                        \
            results[current_ext].tests_passed++;                                                   \
            uart_printf("  [PASS] %s\n", name);                                                    \
        } else {                                                                                   \
            results[current_ext].tests_failed++;                                                   \
            results[current_ext].failed_mask |= (1U << (current_test_index & 31));                 \
            if (failed_count[current_ext] < MAX_TESTS_PER_EXT) {                                   \
                failed_instructions[current_ext][failed_count[current_ext]++] = name;              \
            }                                                                                      \
            uart_printf("  [FAIL] %s: 0x%08X!=0x%08X\n", name, _got, _exp);                        \
        }                                                                                          \
        current_test_index++;                                                                      \
    } while (0)
#define TEST64(name, got, expected)                                                                \
    do {                                                                                           \
        uint64_t _got = (got);                                                                     \
        uint64_t _exp = (expected);                                                                \
        if (_got == _exp) {                                                                        \
            results[current_ext].tests_passed++;                                                   \
            uart_printf("  [PASS] %s\n", name);                                                    \
        } else {                                                                                   \
            results[current_ext].tests_failed++;                                                   \
            results[current_ext].failed_mask |= (1U << (current_test_index & 31));                 \
            if (failed_count[current_ext] < MAX_TESTS_PER_EXT) {                                   \
                failed_instructions[current_ext][failed_count[current_ext]++] = name;              \
            }                                                                                      \
            uart_printf("  [FAIL] %s: 0x%08X%08X!=0x%08X%08X\n",                                   \
                        name,                                                                      \
                        (unsigned) (_got >> 32),                                                   \
                        (unsigned) _got,                                                           \
                        (unsigned) (_exp >> 32),                                                   \
                        (unsigned) _exp);                                                          \
        }                                                                                          \
        current_test_index++;                                                                      \
    } while (0)
#endif

/* For tests that just need to not crash (like fence instructions) */
#define TEST_NO_CRASH(name)                                                                        \
    do {                                                                                           \
        results[current_ext].tests_passed++;                                                       \
        current_test_index++;                                                                      \
    } while (0)

/* ========================================================================== */
/* RV32I Base Integer Tests                                                   */
/* ========================================================================== */

static void test_rv32i(void)
{
    BEGIN_EXTENSION(EXT_RV32I);

    uint32_t result;
    int32_t signed_result;

    /* ===== ADD: rd = rs1 + rs2 ===== */
    __asm__ volatile("add %0, %1, %2" : "=r"(result) : "r"(100), "r"(23));
    TEST("ADD basic", result, 123);
    __asm__ volatile("add %0, %1, %2" : "=r"(result) : "r"(0), "r"(0));
    TEST("ADD 0+0", result, 0);
    __asm__ volatile("add %0, %1, %2" : "=r"(result) : "r"(0xFFFFFFFF), "r"(1));
    TEST("ADD overflow", result, 0); /* Wraps around */
    __asm__ volatile("add %0, %1, %2" : "=r"(result) : "r"(0x7FFFFFFF), "r"(1));
    TEST("ADD sign flip", result, 0x80000000);
    __asm__ volatile("add %0, %1, %2" : "=r"(result) : "r"(0x80000000), "r"(0x80000000));
    TEST("ADD MIN+MIN", result, 0);

    /* ===== SUB: rd = rs1 - rs2 ===== */
    __asm__ volatile("sub %0, %1, %2" : "=r"(result) : "r"(100), "r"(23));
    TEST("SUB basic", result, 77);
    __asm__ volatile("sub %0, %1, %2" : "=r"(result) : "r"(0), "r"(0));
    TEST("SUB 0-0", result, 0);
    __asm__ volatile("sub %0, %1, %2" : "=r"(result) : "r"(0), "r"(1));
    TEST("SUB underflow", result, 0xFFFFFFFF);
    __asm__ volatile("sub %0, %1, %2" : "=r"(result) : "r"(0x80000000), "r"(1));
    TEST("SUB MIN-1", result, 0x7FFFFFFF);

    /* ===== AND/OR/XOR ===== */
    __asm__ volatile("and %0, %1, %2" : "=r"(result) : "r"(0xFF00FF00), "r"(0x0F0F0F0F));
    TEST("AND", result, 0x0F000F00);
    __asm__ volatile("and %0, %1, %2" : "=r"(result) : "r"(0xFFFFFFFF), "r"(0));
    TEST("AND with 0", result, 0);
    __asm__ volatile("or %0, %1, %2" : "=r"(result) : "r"(0xFF00FF00), "r"(0x0F0F0F0F));
    TEST("OR", result, 0xFF0FFF0F);
    __asm__ volatile("or %0, %1, %2" : "=r"(result) : "r"(0), "r"(0));
    TEST("OR 0|0", result, 0);
    __asm__ volatile("xor %0, %1, %2" : "=r"(result) : "r"(0xFF00FF00), "r"(0x0F0F0F0F));
    TEST("XOR", result, 0xF00FF00F);
    __asm__ volatile("xor %0, %1, %2" : "=r"(result) : "r"(0xFFFFFFFF), "r"(0xFFFFFFFF));
    TEST("XOR self", result, 0);

    /* ===== SLL: rd = rs1 << rs2[4:0] ===== */
    __asm__ volatile("sll %0, %1, %2" : "=r"(result) : "r"(1), "r"(0));
    TEST("SLL by 0", result, 1);
    __asm__ volatile("sll %0, %1, %2" : "=r"(result) : "r"(1), "r"(1));
    TEST("SLL by 1", result, 2);
    __asm__ volatile("sll %0, %1, %2" : "=r"(result) : "r"(1), "r"(31));
    TEST("SLL by 31", result, 0x80000000);
    __asm__ volatile("sll %0, %1, %2" : "=r"(result) : "r"(1), "r"(32));
    TEST("SLL by 32 (wraps)", result, 1); /* Uses only lower 5 bits */
    __asm__ volatile("sll %0, %1, %2" : "=r"(result) : "r"(0xFFFFFFFF), "r"(16));
    TEST("SLL MAX<<16", result, 0xFFFF0000);

    /* ===== SRL: rd = rs1 >> rs2[4:0] (logical) ===== */
    __asm__ volatile("srl %0, %1, %2" : "=r"(result) : "r"(0x80000000), "r"(0));
    TEST("SRL by 0", result, 0x80000000);
    __asm__ volatile("srl %0, %1, %2" : "=r"(result) : "r"(0x80000000), "r"(1));
    TEST("SRL by 1", result, 0x40000000);
    __asm__ volatile("srl %0, %1, %2" : "=r"(result) : "r"(0x80000000), "r"(31));
    TEST("SRL by 31", result, 1);
    __asm__ volatile("srl %0, %1, %2" : "=r"(result) : "r"(0x80000000), "r"(32));
    TEST("SRL by 32 (wraps)", result, 0x80000000);
    __asm__ volatile("srl %0, %1, %2" : "=r"(result) : "r"(0xFFFFFFFF), "r"(16));
    TEST("SRL MAX>>16", result, 0x0000FFFF);

    /* ===== SRA: rd = rs1 >> rs2[4:0] (arithmetic) ===== */
    __asm__ volatile("sra %0, %1, %2" : "=r"(result) : "r"(0x80000000), "r"(0));
    TEST("SRA neg by 0", result, 0x80000000);
    __asm__ volatile("sra %0, %1, %2" : "=r"(result) : "r"(0x80000000), "r"(1));
    TEST("SRA neg by 1", result, 0xC0000000);
    __asm__ volatile("sra %0, %1, %2" : "=r"(result) : "r"(0x80000000), "r"(31));
    TEST("SRA neg by 31", result, 0xFFFFFFFF);
    __asm__ volatile("sra %0, %1, %2" : "=r"(result) : "r"(0x7FFFFFFF), "r"(31));
    TEST("SRA pos by 31", result, 0);
    __asm__ volatile("sra %0, %1, %2" : "=r"(result) : "r"(0x40000000), "r"(1));
    TEST("SRA pos by 1", result, 0x20000000);

    /* ===== SLT: rd = (rs1 < rs2) ? 1 : 0 (signed) ===== */
    __asm__ volatile("slt %0, %1, %2" : "=r"(result) : "r"(-1), "r"(1));
    TEST("SLT -1<1", result, 1);
    __asm__ volatile("slt %0, %1, %2" : "=r"(result) : "r"(1), "r"(-1));
    TEST("SLT 1<-1", result, 0);
    __asm__ volatile("slt %0, %1, %2" : "=r"(result) : "r"(5), "r"(5));
    TEST("SLT equal", result, 0);
    __asm__ volatile("slt %0, %1, %2" : "=r"(result) : "r"(0x80000000), "r"(0x7FFFFFFF));
    TEST("SLT MIN<MAX", result, 1);
    __asm__ volatile("slt %0, %1, %2" : "=r"(result) : "r"(0x7FFFFFFF), "r"(0x80000000));
    TEST("SLT MAX<MIN", result, 0);

    /* ===== SLTU: rd = (rs1 < rs2) ? 1 : 0 (unsigned) ===== */
    __asm__ volatile("sltu %0, %1, %2" : "=r"(result) : "r"(1), "r"(0xFFFFFFFF));
    TEST("SLTU 1<MAX", result, 1);
    __asm__ volatile("sltu %0, %1, %2" : "=r"(result) : "r"(0xFFFFFFFF), "r"(1));
    TEST("SLTU MAX<1", result, 0);
    __asm__ volatile("sltu %0, %1, %2" : "=r"(result) : "r"(0), "r"(1));
    TEST("SLTU 0<1", result, 1);
    __asm__ volatile("sltu %0, %1, %2" : "=r"(result) : "r"(0), "r"(0));
    TEST("SLTU 0<0", result, 0);

    /* ===== Immediate arithmetic ===== */
    __asm__ volatile("addi %0, %1, 42" : "=r"(result) : "r"(100));
    TEST("ADDI pos", result, 142);
    __asm__ volatile("addi %0, %1, -42" : "=r"(signed_result) : "r"(100));
    TEST("ADDI neg", signed_result, 58);
    __asm__ volatile("addi %0, %1, 0" : "=r"(result) : "r"(0xDEADBEEF));
    TEST("ADDI zero", result, 0xDEADBEEF);
    __asm__ volatile("andi %0, %1, 0xFF" : "=r"(result) : "r"(0x12345678));
    TEST("ANDI", result, 0x78);
    __asm__ volatile("andi %0, %1, -1" : "=r"(result) : "r"(0x12345678));
    TEST("ANDI -1", result, 0x12345678);
    __asm__ volatile("ori %0, %1, 0xFF" : "=r"(result) : "r"(0x12345600));
    TEST("ORI", result, 0x123456FF);
    __asm__ volatile("xori %0, %1, -1" : "=r"(result) : "r"(0x12345678));
    TEST("XORI -1 (NOT)", result, 0xEDCBA987);

    /* ===== SLTI/SLTIU ===== */
    __asm__ volatile("slti %0, %1, 10" : "=r"(result) : "r"(5));
    TEST("SLTI 5<10", result, 1);
    __asm__ volatile("slti %0, %1, 10" : "=r"(result) : "r"(10));
    TEST("SLTI 10<10", result, 0);
    __asm__ volatile("slti %0, %1, -1" : "=r"(result) : "r"(0));
    TEST("SLTI 0<-1", result, 0);
    __asm__ volatile("sltiu %0, %1, 10" : "=r"(result) : "r"(5));
    TEST("SLTIU 5<10", result, 1);

    /* ===== Shift immediates ===== */
    __asm__ volatile("slli %0, %1, 0" : "=r"(result) : "r"(0x12345678));
    TEST("SLLI by 0", result, 0x12345678);
    __asm__ volatile("slli %0, %1, 31" : "=r"(result) : "r"(1));
    TEST("SLLI by 31", result, 0x80000000);
    __asm__ volatile("srli %0, %1, 0" : "=r"(result) : "r"(0x12345678));
    TEST("SRLI by 0", result, 0x12345678);
    __asm__ volatile("srli %0, %1, 31" : "=r"(result) : "r"(0x80000000));
    TEST("SRLI by 31", result, 1);
    __asm__ volatile("srai %0, %1, 0" : "=r"(result) : "r"(0x80000000));
    TEST("SRAI by 0", result, 0x80000000);
    __asm__ volatile("srai %0, %1, 31" : "=r"(result) : "r"(0x80000000));
    TEST("SRAI by 31", result, 0xFFFFFFFF);

    /* ===== LUI/AUIPC ===== */
    __asm__ volatile("lui %0, 0x12345" : "=r"(result));
    TEST("LUI", result, 0x12345000);
    __asm__ volatile("lui %0, 0xFFFFF" : "=r"(result));
    TEST("LUI max", result, 0xFFFFF000);
    __asm__ volatile("lui %0, 0" : "=r"(result));
    TEST("LUI zero", result, 0);
    /* AUIPC: get PC-relative address */
    __asm__ volatile("auipc %0, 0" : "=r"(result));
    TEST("AUIPC (non-zero PC)", (result != 0) ? 1 : 0, 1);

    /* ===== Memory operations ===== */
    volatile uint32_t mem_test_word = 0xDEADBEEF;
    volatile uint16_t mem_test_half = 0xBEEF;
    volatile uint8_t mem_test_byte = 0xAB;

    __asm__ volatile("lw %0, 0(%1)" : "=r"(result) : "r"(&mem_test_word));
    TEST("LW", result, 0xDEADBEEF);
    __asm__ volatile("lh %0, 0(%1)" : "=r"(result) : "r"(&mem_test_half));
    TEST("LH (sign-ext)", result, 0xFFFFBEEF);
    __asm__ volatile("lhu %0, 0(%1)" : "=r"(result) : "r"(&mem_test_half));
    TEST("LHU (zero-ext)", result, 0x0000BEEF);
    __asm__ volatile("lb %0, 0(%1)" : "=r"(result) : "r"(&mem_test_byte));
    TEST("LB (sign-ext)", result, 0xFFFFFFAB);
    __asm__ volatile("lbu %0, 0(%1)" : "=r"(result) : "r"(&mem_test_byte));
    TEST("LBU (zero-ext)", result, 0x000000AB);

    /* Test positive sign extension */
    volatile uint16_t pos_half = 0x7FFF;
    volatile uint8_t pos_byte = 0x7F;
    __asm__ volatile("lh %0, 0(%1)" : "=r"(result) : "r"(&pos_half));
    TEST("LH pos", result, 0x00007FFF);
    __asm__ volatile("lb %0, 0(%1)" : "=r"(result) : "r"(&pos_byte));
    TEST("LB pos", result, 0x0000007F);

    /* Store operations */
    volatile uint32_t store_target = 0;
    __asm__ volatile("sw %1, 0(%0)" : : "r"(&store_target), "r"(0x12345678) : "memory");
    TEST("SW", store_target, 0x12345678);
    volatile uint16_t store_target_h = 0;
    __asm__ volatile("sh %1, 0(%0)" : : "r"(&store_target_h), "r"(0xFFFFABCD) : "memory");
    TEST("SH (truncate)", store_target_h, 0xABCD);
    volatile uint8_t store_target_b = 0;
    __asm__ volatile("sb %1, 0(%0)" : : "r"(&store_target_b), "r"(0xFFFFFFEF) : "memory");
    TEST("SB (truncate)", store_target_b, 0xEF);

    /* ===== Branch instructions - both taken and not-taken ===== */
    /* BEQ taken */
    result = 0;
    __asm__ volatile("li t0, 5\n li t1, 5\n beq t0, t1, 1f\n li %0, 0\n j 2f\n 1: li %0, 1\n 2:\n"
                     : "=r"(result)
                     :
                     : "t0", "t1");
    TEST("BEQ taken", result, 1);
    /* BEQ not taken */
    result = 0;
    __asm__ volatile("li t0, 5\n li t1, 6\n beq t0, t1, 1f\n li %0, 1\n j 2f\n 1: li %0, 0\n 2:\n"
                     : "=r"(result)
                     :
                     : "t0", "t1");
    TEST("BEQ not taken", result, 1);

    /* BNE taken */
    result = 0;
    __asm__ volatile("li t0, 5\n li t1, 6\n bne t0, t1, 1f\n li %0, 0\n j 2f\n 1: li %0, 1\n 2:\n"
                     : "=r"(result)
                     :
                     : "t0", "t1");
    TEST("BNE taken", result, 1);
    /* BNE not taken */
    result = 0;
    __asm__ volatile("li t0, 5\n li t1, 5\n bne t0, t1, 1f\n li %0, 1\n j 2f\n 1: li %0, 0\n 2:\n"
                     : "=r"(result)
                     :
                     : "t0", "t1");
    TEST("BNE not taken", result, 1);

    /* BLT taken (signed) */
    result = 0;
    __asm__ volatile("li t0, -1\n li t1, 1\n blt t0, t1, 1f\n li %0, 0\n j 2f\n 1: li %0, 1\n 2:\n"
                     : "=r"(result)
                     :
                     : "t0", "t1");
    TEST("BLT taken", result, 1);
    /* BLT not taken (equal) */
    result = 0;
    __asm__ volatile("li t0, 5\n li t1, 5\n blt t0, t1, 1f\n li %0, 1\n j 2f\n 1: li %0, 0\n 2:\n"
                     : "=r"(result)
                     :
                     : "t0", "t1");
    TEST("BLT not taken eq", result, 1);
    /* BLT not taken (greater) */
    result = 0;
    __asm__ volatile("li t0, 6\n li t1, 5\n blt t0, t1, 1f\n li %0, 1\n j 2f\n 1: li %0, 0\n 2:\n"
                     : "=r"(result)
                     :
                     : "t0", "t1");
    TEST("BLT not taken gt", result, 1);

    /* BGE taken (equal) */
    result = 0;
    __asm__ volatile("li t0, 5\n li t1, 5\n bge t0, t1, 1f\n li %0, 0\n j 2f\n 1: li %0, 1\n 2:\n"
                     : "=r"(result)
                     :
                     : "t0", "t1");
    TEST("BGE taken eq", result, 1);
    /* BGE taken (greater) */
    result = 0;
    __asm__ volatile("li t0, 6\n li t1, 5\n bge t0, t1, 1f\n li %0, 0\n j 2f\n 1: li %0, 1\n 2:\n"
                     : "=r"(result)
                     :
                     : "t0", "t1");
    TEST("BGE taken gt", result, 1);
    /* BGE not taken */
    result = 0;
    __asm__ volatile("li t0, 4\n li t1, 5\n bge t0, t1, 1f\n li %0, 1\n j 2f\n 1: li %0, 0\n 2:\n"
                     : "=r"(result)
                     :
                     : "t0", "t1");
    TEST("BGE not taken", result, 1);

    /* BLTU taken (unsigned) */
    result = 0;
    __asm__ volatile("li t0, 1\n li t1, -1\n bltu t0, t1, 1f\n li %0, 0\n j 2f\n 1: li %0, 1\n 2:\n"
                     : "=r"(result)
                     :
                     : "t0", "t1");
    TEST("BLTU taken", result, 1);
    /* BLTU not taken */
    result = 0;
    __asm__ volatile("li t0, -1\n li t1, 1\n bltu t0, t1, 1f\n li %0, 1\n j 2f\n 1: li %0, 0\n 2:\n"
                     : "=r"(result)
                     :
                     : "t0", "t1");
    TEST("BLTU not taken", result, 1);

    /* BGEU taken */
    result = 0;
    __asm__ volatile("li t0, -1\n li t1, 1\n bgeu t0, t1, 1f\n li %0, 0\n j 2f\n 1: li %0, 1\n 2:\n"
                     : "=r"(result)
                     :
                     : "t0", "t1");
    TEST("BGEU taken", result, 1);
    /* BGEU not taken */
    result = 0;
    __asm__ volatile("li t0, 1\n li t1, -1\n bgeu t0, t1, 1f\n li %0, 1\n j 2f\n 1: li %0, 0\n 2:\n"
                     : "=r"(result)
                     :
                     : "t0", "t1");
    TEST("BGEU not taken", result, 1);

    /* ===== JAL/JALR explicit tests ===== */
    /* JAL: jump and link - verify return address is saved */
    result = 0;
    __asm__ volatile("jal t0, 1f\n"
                     "2: li %0, 1\n"
                     "j 3f\n"
                     "1: jalr zero, t0, 0\n" /* Return to caller */
                     "3:\n"
                     : "=r"(result)
                     :
                     : "t0");
    TEST("JAL/JALR", result, 1);

    /* FENCE: memory ordering */
    __asm__ volatile("fence" ::: "memory");
    TEST_NO_CRASH("FENCE");
    __asm__ volatile("fence rw, rw" ::: "memory");
    TEST_NO_CRASH("FENCE rw,rw");

    END_EXTENSION();
}

/* ========================================================================== */
/* M Extension Tests (Multiply/Divide)                                        */
/* ========================================================================== */

static void test_m_extension(void)
{
    BEGIN_EXTENSION(EXT_M);

    uint32_t result;
    int32_t signed_result;

    /* ===== MUL: rd = (rs1 * rs2)[31:0] ===== */
    __asm__ volatile("mul %0, %1, %2" : "=r"(result) : "r"(7), "r"(6));
    TEST("MUL basic", result, 42);
    __asm__ volatile("mul %0, %1, %2" : "=r"(result) : "r"(0), "r"(0x12345678));
    TEST("MUL 0*x", result, 0);
    __asm__ volatile("mul %0, %1, %2" : "=r"(result) : "r"(0x12345678), "r"(0));
    TEST("MUL x*0", result, 0);
    __asm__ volatile("mul %0, %1, %2" : "=r"(result) : "r"(1), "r"(0xDEADBEEF));
    TEST("MUL 1*x", result, 0xDEADBEEF);
    __asm__ volatile("mul %0, %1, %2" : "=r"(result) : "r"(-1), "r"(5));
    TEST("MUL -1*5", result, (uint32_t) -5);
    __asm__ volatile("mul %0, %1, %2" : "=r"(result) : "r"(-1), "r"(-1));
    TEST("MUL -1*-1", result, 1);
    /* MUL with overflow (only lower 32 bits) */
    __asm__ volatile("mul %0, %1, %2" : "=r"(result) : "r"(0x10000), "r"(0x10000));
    TEST("MUL overflow", result, 0); /* Lower 32 bits of 0x100000000 */
    __asm__ volatile("mul %0, %1, %2" : "=r"(result) : "r"(0x80000000), "r"(2));
    TEST("MUL MIN*2", result, 0); /* 0x100000000 lower bits */
    __asm__ volatile("mul %0, %1, %2" : "=r"(result) : "r"(0x80000000), "r"(0x80000000));
    TEST("MUL MIN*MIN", result, 0); /* Lower 32 bits of 2^62 */

    /* ===== MULH: rd = (rs1 * rs2)[63:32] (signed * signed) ===== */
    __asm__ volatile("mulh %0, %1, %2" : "=r"(result) : "r"(0x10000), "r"(0x10000));
    TEST("MULH basic", result, 1); /* Upper 32 bits of 0x100000000 */
    __asm__ volatile("mulh %0, %1, %2" : "=r"(result) : "r"(0), "r"(0xFFFFFFFF));
    TEST("MULH 0*x", result, 0);
    __asm__ volatile("mulh %0, %1, %2" : "=r"(signed_result) : "r"(-2), "r"(0x80000000));
    TEST("MULH -2*MIN", signed_result, 1); /* -2 * -2^31 = 2^32, upper bits = 1 */
    __asm__ volatile("mulh %0, %1, %2" : "=r"(signed_result) : "r"(-1), "r"(-1));
    TEST("MULH -1*-1", signed_result, 0); /* 1, high bits = 0 */
    /* MIN * MIN signed: (-2^31) * (-2^31) = 2^62, high 32 bits = 0x40000000 */
    __asm__ volatile("mulh %0, %1, %2" : "=r"(result) : "r"(0x80000000), "r"(0x80000000));
    TEST("MULH MIN*MIN", result, 0x40000000);
    /* MAX * MAX signed: (2^31-1) * (2^31-1) = 2^62 - 2^32 + 1, high = 0x3FFFFFFF */
    __asm__ volatile("mulh %0, %1, %2" : "=r"(result) : "r"(0x7FFFFFFF), "r"(0x7FFFFFFF));
    TEST("MULH MAX*MAX", result, 0x3FFFFFFF);
    /* MIN * MAX signed: -2^31 * (2^31-1) = -2^62 + 2^31, high = 0xC0000000 */
    __asm__ volatile("mulh %0, %1, %2" : "=r"(signed_result) : "r"(0x80000000), "r"(0x7FFFFFFF));
    TEST("MULH MIN*MAX", signed_result, (int32_t) 0xC0000000);

    /* ===== MULHU: rd = (rs1 * rs2)[63:32] (unsigned * unsigned) ===== */
    __asm__ volatile("mulhu %0, %1, %2" : "=r"(result) : "r"(0x80000000), "r"(2));
    TEST("MULHU basic", result, 1);
    __asm__ volatile("mulhu %0, %1, %2" : "=r"(result) : "r"(0), "r"(0xFFFFFFFF));
    TEST("MULHU 0*MAX", result, 0);
    /* MAX * MAX unsigned: (2^32-1) * (2^32-1) = 2^64 - 2^33 + 1, high = 0xFFFFFFFE */
    __asm__ volatile("mulhu %0, %1, %2" : "=r"(result) : "r"(0xFFFFFFFF), "r"(0xFFFFFFFF));
    TEST("MULHU MAX*MAX", result, 0xFFFFFFFE);
    /* 0x80000000 * 0x80000000 unsigned = 2^62, high = 0x40000000 */
    __asm__ volatile("mulhu %0, %1, %2" : "=r"(result) : "r"(0x80000000), "r"(0x80000000));
    TEST("MULHU 0x8*0x8", result, 0x40000000);

    /* ===== MULHSU: rd = (rs1 * rs2)[63:32] (signed * unsigned) ===== */
    __asm__ volatile("mulhsu %0, %1, %2" : "=r"(signed_result) : "r"(-1), "r"(1));
    TEST("MULHSU -1*1", signed_result, -1); /* -1 * 1 = -1, sign-extended high bits */
    __asm__ volatile("mulhsu %0, %1, %2" : "=r"(result) : "r"(1), "r"(0xFFFFFFFF));
    TEST("MULHSU 1*MAX", result, 0); /* 1 * (2^32-1) = 2^32-1, high = 0 */
    __asm__ volatile("mulhsu %0, %1, %2" : "=r"(signed_result) : "r"(-1), "r"(0xFFFFFFFF));
    TEST("MULHSU -1*MAX", signed_result, -1); /* -1 * MAX = -MAX, high = -1 */
    /* MIN (signed) * MAX (unsigned): -2^31 * (2^32-1) = -2^63 + 2^31 = 0x8000_0000_8000_0000 */
    __asm__ volatile("mulhsu %0, %1, %2" : "=r"(signed_result) : "r"(0x80000000), "r"(0xFFFFFFFF));
    TEST("MULHSU MIN*MAX", signed_result, (int32_t) 0x80000000);
    /* MAX (signed) * MAX (unsigned): (2^31-1) * (2^32-1), high = 0x7FFFFFFE */
    __asm__ volatile("mulhsu %0, %1, %2" : "=r"(result) : "r"(0x7FFFFFFF), "r"(0xFFFFFFFF));
    TEST("MULHSU SMAX*UMAX", result, 0x7FFFFFFE);

    /* ===== DIV: rd = rs1 / rs2 (signed) ===== */
    __asm__ volatile("div %0, %1, %2" : "=r"(signed_result) : "r"(42), "r"(7));
    TEST("DIV basic", signed_result, 6);
    __asm__ volatile("div %0, %1, %2" : "=r"(signed_result) : "r"(-42), "r"(7));
    TEST("DIV neg/pos", signed_result, -6);
    __asm__ volatile("div %0, %1, %2" : "=r"(signed_result) : "r"(42), "r"(-7));
    TEST("DIV pos/neg", signed_result, -6);
    __asm__ volatile("div %0, %1, %2" : "=r"(signed_result) : "r"(-42), "r"(-7));
    TEST("DIV neg/neg", signed_result, 6);
    __asm__ volatile("div %0, %1, %2" : "=r"(signed_result) : "r"(0), "r"(5));
    TEST("DIV 0/x", signed_result, 0);
    __asm__ volatile("div %0, %1, %2" : "=r"(signed_result) : "r"(5), "r"(5));
    TEST("DIV x/x", signed_result, 1);
    __asm__ volatile("div %0, %1, %2" : "=r"(signed_result) : "r"(5), "r"(10));
    TEST("DIV 5/10", signed_result, 0); /* Truncates toward zero */
    /* DIV by zero (RISC-V spec: returns -1) */
    __asm__ volatile("div %0, %1, %2" : "=r"(signed_result) : "r"(42), "r"(0));
    TEST("DIV by zero", signed_result, -1);
    /* DIV overflow: MIN / -1 (RISC-V spec: returns MIN, not trap) */
    __asm__ volatile("div %0, %1, %2" : "=r"(signed_result) : "r"(0x80000000), "r"(-1));
    TEST("DIV MIN/-1", signed_result, (int32_t) 0x80000000);

    /* ===== DIVU: rd = rs1 / rs2 (unsigned) ===== */
    __asm__ volatile("divu %0, %1, %2" : "=r"(result) : "r"(100), "r"(10));
    TEST("DIVU basic", result, 10);
    __asm__ volatile("divu %0, %1, %2" : "=r"(result) : "r"(0xFFFFFFFF), "r"(2));
    TEST("DIVU MAX/2", result, 0x7FFFFFFF);
    __asm__ volatile("divu %0, %1, %2" : "=r"(result) : "r"(0x80000000), "r"(0x80000000));
    TEST("DIVU x/x", result, 1);
    /* DIVU by zero (RISC-V spec: returns 0xFFFFFFFF) */
    __asm__ volatile("divu %0, %1, %2" : "=r"(result) : "r"(42), "r"(0));
    TEST("DIVU by zero", result, 0xFFFFFFFF);

    /* ===== REM: rd = rs1 % rs2 (signed) ===== */
    __asm__ volatile("rem %0, %1, %2" : "=r"(signed_result) : "r"(43), "r"(7));
    TEST("REM basic", signed_result, 1);
    __asm__ volatile("rem %0, %1, %2" : "=r"(signed_result) : "r"(-43), "r"(7));
    TEST("REM neg/pos", signed_result, -1);
    __asm__ volatile("rem %0, %1, %2" : "=r"(signed_result) : "r"(43), "r"(-7));
    TEST("REM pos/neg", signed_result, 1);
    __asm__ volatile("rem %0, %1, %2" : "=r"(signed_result) : "r"(-43), "r"(-7));
    TEST("REM neg/neg", signed_result, -1);
    __asm__ volatile("rem %0, %1, %2" : "=r"(signed_result) : "r"(42), "r"(7));
    TEST("REM exact", signed_result, 0); /* Exact division */
    /* REM by zero (RISC-V spec: returns dividend) */
    __asm__ volatile("rem %0, %1, %2" : "=r"(signed_result) : "r"(42), "r"(0));
    TEST("REM by zero", signed_result, 42);
    /* REM overflow: MIN % -1 (RISC-V spec: returns 0) */
    __asm__ volatile("rem %0, %1, %2" : "=r"(signed_result) : "r"(0x80000000), "r"(-1));
    TEST("REM MIN%-1", signed_result, 0);

    /* ===== REMU: rd = rs1 % rs2 (unsigned) ===== */
    __asm__ volatile("remu %0, %1, %2" : "=r"(result) : "r"(43), "r"(7));
    TEST("REMU basic", result, 1);
    __asm__ volatile("remu %0, %1, %2" : "=r"(result) : "r"(0xFFFFFFFF), "r"(0x10000));
    TEST("REMU MAX", result, 0xFFFF);
    __asm__ volatile("remu %0, %1, %2" : "=r"(result) : "r"(100), "r"(100));
    TEST("REMU exact", result, 0);
    /* REMU by zero (RISC-V spec: returns dividend) */
    __asm__ volatile("remu %0, %1, %2" : "=r"(result) : "r"(42), "r"(0));
    TEST("REMU by zero", result, 42);

    END_EXTENSION();
}

/* ========================================================================== */
/* A Extension Tests (Atomics)                                                */
/* ========================================================================== */

static void test_a_extension(void)
{
    BEGIN_EXTENSION(EXT_A);

    volatile uint32_t atomic_mem __attribute__((aligned(4))) = 0;
    volatile uint32_t atomic_mem2 __attribute__((aligned(4))) = 0;
    uint32_t result, result2;

    /* ===== LR.W / SC.W: Load-reserved / Store-conditional ===== */
    /* Basic success case */
    atomic_mem = 0x12345678;
    __asm__ volatile("lr.w %0, (%2)\n"     /* Load-reserved */
                     "addi %0, %0, 1\n"    /* Modify */
                     "sc.w %1, %0, (%2)\n" /* Store-conditional */
                     : "=&r"(result), "=&r"(result2)
                     : "r"(&atomic_mem)
                     : "memory");
    TEST("LR.W/SC.W value", atomic_mem, 0x12345679);
    TEST("SC.W success=0", result2, 0); /* 0 = success */

    /* Back-to-back LR/SC storing zero (tests pipeline forwarding) */
    atomic_mem = 100;
    __asm__ volatile("lr.w %0, (%2)\n"       /* LR to atomic_mem */
                     "sc.w %1, zero, (%2)\n" /* SC should succeed (store 0) */
                     : "=&r"(result), "=&r"(result2)
                     : "r"(&atomic_mem)
                     : "memory");
    TEST("SC.W store zero", result2, 0);
    TEST("SC.W zero value", atomic_mem, 0);

    /* SC.W failure case: SC to different address than LR (reservation lost) */
    atomic_mem = 0xAAAAAAAA;
    atomic_mem2 = 0xBBBBBBBB;
    __asm__ volatile("lr.w %0, (%2)\n"     /* LR from atomic_mem */
                     "sc.w %1, %0, (%3)\n" /* SC to atomic_mem2 (different address!) */
                     : "=&r"(result), "=&r"(result2)
                     : "r"(&atomic_mem), "r"(&atomic_mem2)
                     : "memory");
    TEST("SC.W fail=1", result2, 1);                  /* 1 = failure (wrong address) */
    TEST("SC.W fail no-wr", atomic_mem2, 0xBBBBBBBB); /* Should not have written */

    /* SC.W without prior LR (should fail) */
    atomic_mem = 0xDEADBEEF;
    __asm__ volatile("sc.w %0, %1, (%2)\n"
                     : "=r"(result2)
                     : "r"(0x12345678), "r"(&atomic_mem)
                     : "memory");
    TEST("SC.W no LR", result2, 1);                   /* 1 = failure */
    TEST("SC.W no LR no-wr", atomic_mem, 0xDEADBEEF); /* Should not have written */

    /* ===== AMOSWAP.W ===== */
    atomic_mem = 100;
    __asm__ volatile("amoswap.w %0, %1, (%2)"
                     : "=r"(result)
                     : "r"(200), "r"(&atomic_mem)
                     : "memory");
    TEST("AMOSWAP old", result, 100);
    TEST("AMOSWAP new", atomic_mem, 200);
    /* Swap with zero */
    atomic_mem = 0xDEADBEEF;
    __asm__ volatile("amoswap.w %0, zero, (%1)" : "=r"(result) : "r"(&atomic_mem) : "memory");
    TEST("AMOSWAP zero", atomic_mem, 0);

    /* ===== AMOADD.W ===== */
    atomic_mem = 100;
    __asm__ volatile("amoadd.w %0, %1, (%2)" : "=r"(result) : "r"(50), "r"(&atomic_mem) : "memory");
    TEST("AMOADD old", result, 100);
    TEST("AMOADD new", atomic_mem, 150);
    /* Add with overflow */
    atomic_mem = 0xFFFFFFFF;
    __asm__ volatile("amoadd.w %0, %1, (%2)" : "=r"(result) : "r"(1), "r"(&atomic_mem) : "memory");
    TEST("AMOADD ovf", atomic_mem, 0);
    /* Add negative */
    atomic_mem = 100;
    __asm__ volatile("amoadd.w %0, %1, (%2)"
                     : "=r"(result)
                     : "r"(-50), "r"(&atomic_mem)
                     : "memory");
    TEST("AMOADD neg", atomic_mem, 50);

    /* ===== AMOAND.W ===== */
    atomic_mem = 0xFF00FF00;
    __asm__ volatile("amoand.w %0, %1, (%2)"
                     : "=r"(result)
                     : "r"(0x0F0F0F0F), "r"(&atomic_mem)
                     : "memory");
    TEST("AMOAND old", result, 0xFF00FF00);
    TEST("AMOAND new", atomic_mem, 0x0F000F00);

    /* ===== AMOOR.W ===== */
    atomic_mem = 0x00FF00FF;
    __asm__ volatile("amoor.w %0, %1, (%2)"
                     : "=r"(result)
                     : "r"(0xF0F0F0F0), "r"(&atomic_mem)
                     : "memory");
    TEST("AMOOR old", result, 0x00FF00FF);
    TEST("AMOOR new", atomic_mem, 0xF0FFF0FF);

    /* ===== AMOXOR.W ===== */
    atomic_mem = 0xFF00FF00;
    __asm__ volatile("amoxor.w %0, %1, (%2)"
                     : "=r"(result)
                     : "r"(0xFFFFFFFF), "r"(&atomic_mem)
                     : "memory");
    TEST("AMOXOR old", result, 0xFF00FF00);
    TEST("AMOXOR new", atomic_mem, 0x00FF00FF);

    /* ===== AMOMIN.W (signed) ===== */
    atomic_mem = 100;
    __asm__ volatile("amomin.w %0, %1, (%2)"
                     : "=r"(result)
                     : "r"(-50), "r"(&atomic_mem)
                     : "memory");
    TEST("AMOMIN old", result, 100);
    TEST("AMOMIN new", atomic_mem, (uint32_t) -50);
    /* MIN boundary: MIN_INT vs positive */
    atomic_mem = 0x80000000; /* MIN_INT */
    __asm__ volatile("amomin.w %0, %1, (%2)"
                     : "=r"(result)
                     : "r"(100), "r"(&atomic_mem)
                     : "memory");
    TEST("AMOMIN MIN", atomic_mem, 0x80000000); /* MIN_INT is smaller (signed) */
    /* MIN boundary: MAX_INT vs negative */
    atomic_mem = 0x7FFFFFFF; /* MAX_INT */
    __asm__ volatile("amomin.w %0, %1, (%2)" : "=r"(result) : "r"(-1), "r"(&atomic_mem) : "memory");
    TEST("AMOMIN MAX", atomic_mem, (uint32_t) -1);

    /* ===== AMOMAX.W (signed) ===== */
    atomic_mem = (uint32_t) -100;
    __asm__ volatile("amomax.w %0, %1, (%2)" : "=r"(result) : "r"(50), "r"(&atomic_mem) : "memory");
    TEST("AMOMAX old", result, (uint32_t) -100);
    TEST("AMOMAX new", atomic_mem, 50);
    /* MAX boundary: MAX_INT vs negative */
    atomic_mem = 0x7FFFFFFF; /* MAX_INT */
    __asm__ volatile("amomax.w %0, %1, (%2)" : "=r"(result) : "r"(-1), "r"(&atomic_mem) : "memory");
    TEST("AMOMAX MAX", atomic_mem, 0x7FFFFFFF); /* MAX_INT is larger (signed) */
    /* MAX boundary: MIN_INT vs positive */
    atomic_mem = 0x80000000; /* MIN_INT */
    __asm__ volatile("amomax.w %0, %1, (%2)"
                     : "=r"(result)
                     : "r"(100), "r"(&atomic_mem)
                     : "memory");
    TEST("AMOMAX MIN", atomic_mem, 100);

    /* ===== AMOMINU.W (unsigned) ===== */
    atomic_mem = 100;
    __asm__ volatile("amominu.w %0, %1, (%2)"
                     : "=r"(result)
                     : "r"(50), "r"(&atomic_mem)
                     : "memory");
    TEST("AMOMINU old", result, 100);
    TEST("AMOMINU new", atomic_mem, 50);
    /* MINU: 0x80000000 is LARGE unsigned */
    atomic_mem = 0x80000000;
    __asm__ volatile("amominu.w %0, %1, (%2)"
                     : "=r"(result)
                     : "r"(100), "r"(&atomic_mem)
                     : "memory");
    TEST("AMOMINU 0x8", atomic_mem, 100); /* 100 < 0x80000000 unsigned */

    /* ===== AMOMAXU.W (unsigned) ===== */
    atomic_mem = 100;
    __asm__ volatile("amomaxu.w %0, %1, (%2)"
                     : "=r"(result)
                     : "r"(200), "r"(&atomic_mem)
                     : "memory");
    TEST("AMOMAXU old", result, 100);
    TEST("AMOMAXU new", atomic_mem, 200);
    /* MAXU: 0x80000000 is LARGE unsigned */
    atomic_mem = 100;
    __asm__ volatile("amomaxu.w %0, %1, (%2)"
                     : "=r"(result)
                     : "r"(0x80000000), "r"(&atomic_mem)
                     : "memory");
    TEST("AMOMAXU 0x8", atomic_mem, 0x80000000);
    /* MAXU: MAX unsigned */
    atomic_mem = 0xFFFFFFFE;
    __asm__ volatile("amomaxu.w %0, %1, (%2)"
                     : "=r"(result)
                     : "r"(0xFFFFFFFF), "r"(&atomic_mem)
                     : "memory");
    TEST("AMOMAXU MAX", atomic_mem, 0xFFFFFFFF);

    END_EXTENSION();
}

/* ========================================================================== */
/* C Extension Tests (Compressed 16-bit Instructions)                         */
/* ========================================================================== */

/* Trap handler state for C.EBREAK test */
static volatile uint32_t c_trap_taken = 0;
static volatile uint32_t c_trap_cause = 0;

/* Assembly trap handler for C extension - saves mcause, advances mepc, returns */
__attribute__((naked, aligned(4))) static void c_test_trap_handler(void)
{
    __asm__ volatile(
        /* Save mcause to global */
        "csrr t0, mcause\n"
        "lui t1, %%hi(c_trap_cause)\n"
        "sw t0, %%lo(c_trap_cause)(t1)\n"
        /* Set trap_taken flag */
        "li t0, 1\n"
        "lui t1, %%hi(c_trap_taken)\n"
        "sw t0, %%lo(c_trap_taken)(t1)\n"
        /* Advance mepc past the trapping instruction (detect 16-bit vs 32-bit) */
        "csrr t0, mepc\n"
        "lhu t2, 0(t0)\n"
        "andi t2, t2, 0x3\n"
        "li t3, 0x3\n"
        "addi t0, t0, 2\n" /* Assume 16-bit */
        "bne t2, t3, 1f\n"
        "addi t0, t0, 2\n" /* 32-bit: add 2 more */
        "1:\n"
        "csrw mepc, t0\n"
        "mret\n" ::
            : "t0", "t1", "t2", "t3");
}

static void test_c_extension(void)
{
    BEGIN_EXTENSION(EXT_C);

    register uint32_t result __asm__("a0");
    uint64_t result64;
    uint32_t result_lo;
    uint32_t result_hi;
    volatile uint32_t mem_val;

    /* ===== Quadrant 0: Stack-relative loads/stores ===== */

    /* C.ADDI4SPN: addi rd', sp, nzuimm (rd' = x8-x15) */
    /* This adds a scaled immediate to sp and stores in rd' */
    __asm__ volatile("mv t0, sp\n"             /* Save sp */
                     "li sp, 0x1000\n"         /* Set known sp */
                     "c.addi4spn s0, sp, 64\n" /* s0 = sp + 64 */
                     "mv %0, s0\n"
                     "mv sp, t0\n" /* Restore sp */
                     : "=r"(result)::"t0", "s0");
    TEST("addi4spn", result, 0x1040);

    mem_val = 0xDEADBEEF;
    __asm__ volatile("mv s0, %1\n"
                     "c.lw s1, 0(s0)\n"
                     "mv %0, s1\n"
                     : "=r"(result)
                     : "r"(&mem_val)
                     : "s0", "s1");
    TEST("lw", result, 0xDEADBEEF);

    mem_val = 0;
    __asm__ volatile("mv s0, %0\n"
                     "li s1, 0x12345678\n"
                     "c.sw s1, 0(s0)\n" ::"r"(&mem_val)
                     : "s0", "s1", "memory");
    TEST("sw", mem_val, 0x12345678);

    __asm__ volatile("c.nop" :::);
    TEST_NO_CRASH("nop");

    __asm__ volatile("li s0, 100\n"
                     "c.addi s0, 23\n"
                     "mv %0, s0\n"
                     : "=r"(result)::"s0");
    TEST("addi+", result, 123);

    __asm__ volatile("li s0, 100\n"
                     "c.addi s0, -10\n"
                     "mv %0, s0\n"
                     : "=r"(result)::"s0");
    TEST("addi-", result, 90);

    __asm__ volatile("la t0, 1f\n"
                     "c.jal 2f\n"
                     "1: mv %0, ra\n"
                     "j 3f\n"
                     "2: c.jr ra\n"
                     "3:\n"
                     : "=r"(result)::"t0", "ra");
    TEST_NO_CRASH("jal");

    __asm__ volatile("c.li s0, 31\n"
                     "mv %0, s0\n"
                     : "=r"(result)::"s0");
    TEST("li+", result, 31);

    __asm__ volatile("c.li s0, -1\n"
                     "mv %0, s0\n"
                     : "=r"(result)::"s0");
    TEST("li-", result, 0xFFFFFFFF);

    __asm__ volatile("mv t0, sp\n"
                     "li sp, 0x2000\n"
                     "c.addi16sp sp, 32\n"
                     "mv %0, sp\n"
                     "mv sp, t0\n"
                     : "=r"(result)::"t0");
    TEST("a16sp+", result, 0x2020);

    __asm__ volatile("mv t0, sp\n"
                     "li sp, 0x2000\n"
                     "c.addi16sp sp, -16\n"
                     "mv %0, sp\n"
                     "mv sp, t0\n"
                     : "=r"(result)::"t0");
    TEST("a16sp-", result, 0x1FF0);

    __asm__ volatile("c.lui s0, 31\n"
                     "mv %0, s0\n"
                     : "=r"(result)::"s0");
    TEST("lui", result, 31 << 12);

    __asm__ volatile("li s0, 0x80000000\n"
                     "c.srli s0, 4\n"
                     "mv %0, s0\n"
                     : "=r"(result)::"s0");
    TEST("srli", result, 0x08000000);

    __asm__ volatile("li s0, 0x80000000\n"
                     "c.srai s0, 4\n"
                     "mv %0, s0\n"
                     : "=r"(result)::"s0");
    TEST("srai", result, 0xF8000000);

    __asm__ volatile("li s0, 0xFF\n"
                     "c.andi s0, 0x0F\n"
                     "mv %0, s0\n"
                     : "=r"(result)::"s0");
    TEST("andi", result, 0x0F);

    __asm__ volatile("li s0, 100\n"
                     "li s1, 30\n"
                     "c.sub s0, s1\n"
                     "mv %0, s0\n"
                     : "=r"(result)::"s0", "s1");
    TEST("sub", result, 70);

    __asm__ volatile("li s0, 0xFF00FF00\n"
                     "li s1, 0xF0F0F0F0\n"
                     "c.xor s0, s1\n"
                     "mv %0, s0\n"
                     : "=r"(result)::"s0", "s1");
    TEST("xor", result, 0x0FF00FF0);

    __asm__ volatile("li s0, 0xF0F0F0F0\n"
                     "li s1, 0x0F0F0F0F\n"
                     "c.or s0, s1\n"
                     "mv %0, s0\n"
                     : "=r"(result)::"s0", "s1");
    TEST("or", result, 0xFFFFFFFF);

    __asm__ volatile("li s0, 0xFF00FF00\n"
                     "li s1, 0xF0F0F0F0\n"
                     "c.and s0, s1\n"
                     "mv %0, s0\n"
                     : "=r"(result)::"s0", "s1");
    TEST("and", result, 0xF000F000);

    __asm__ volatile("li %0, 0\n"
                     "c.j 1f\n"
                     "li %0, 999\n"
                     "1: c.nop\n"
                     : "=r"(result)::);
    TEST("j", result, 0);

    __asm__ volatile("li s0, 0\n"
                     "li %0, 1\n"
                     "c.beqz s0, 1f\n"
                     "li %0, 0\n"
                     "1: c.nop\n"
                     : "=r"(result)::"s0");
    TEST("beqz_t", result, 1);

    __asm__ volatile("li s0, 1\n"
                     "li %0, 0\n"
                     "c.beqz s0, 1f\n"
                     "li %0, 1\n"
                     "1: c.nop\n"
                     : "=r"(result)::"s0");
    TEST("beqz_n", result, 1);

    __asm__ volatile("li s0, 5\n"
                     "li %0, 1\n"
                     "c.bnez s0, 1f\n"
                     "li %0, 0\n"
                     "1: c.nop\n"
                     : "=r"(result)::"s0");
    TEST("bnez_t", result, 1);

    __asm__ volatile("li s0, 0\n"
                     "li %0, 0\n"
                     "c.bnez s0, 1f\n"
                     "li %0, 1\n"
                     "1: c.nop\n"
                     : "=r"(result)::"s0");
    TEST("bnez_n", result, 1);

    __asm__ volatile("li a1, 0x00000001\n"
                     "c.slli a1, 16\n"
                     "mv %0, a1\n"
                     : "=r"(result)::"a1");
    TEST("slli", result, 0x00010000);

    __asm__ volatile("addi sp, sp, -16\n"
                     "li t0, 0xCAFEBABE\n"
                     "sw t0, 0(sp)\n"
                     "c.lwsp a1, 0(sp)\n"
                     "mv %0, a1\n"
                     "addi sp, sp, 16\n"
                     : "=r"(result)::"t0", "a1");
    TEST("lwsp", result, 0xCAFEBABE);

    __asm__ volatile("la t0, 1f\n"
                     "li %0, 0\n"
                     "c.jr t0\n"
                     "li %0, 999\n"
                     "1: c.nop\n"
                     : "=r"(result)::"t0");
    TEST("jr", result, 0);

    __asm__ volatile("li a1, 0x12345678\n"
                     "c.mv a2, a1\n"
                     "mv %0, a2\n"
                     : "=r"(result)::"a1", "a2");
    TEST("mv", result, 0x12345678);

    __asm__ volatile("la t0, 1f\n"
                     "c.jalr t0\n"
                     "j 2f\n"
                     "1: c.jr ra\n"
                     "2: li %0, 1\n"
                     : "=r"(result)::"t0", "ra");
    TEST("jalr", result, 1);

    __asm__ volatile("li a1, 1000\n"
                     "li a2, 234\n"
                     "c.add a1, a2\n"
                     "mv %0, a1\n"
                     : "=r"(result)::"a1", "a2");
    TEST("add", result, 1234);

    __asm__ volatile("addi sp, sp, -16\n"
                     "li a1, 0xBEEFCAFE\n"
                     "c.swsp a1, 0(sp)\n"
                     "lw %0, 0(sp)\n"
                     "addi sp, sp, 16\n"
                     : "=r"(result)::"a1");
    TEST("swsp", result, 0xBEEFCAFE);

    /* ===== Compressed Floating-Point Load/Store (RV32FC) ===== */

    /* C.FSW: Store FP register to memory using compressed format */
    /* Format: c.fsw rs2', offset(rs1') where rs1', rs2' are x8-x15/f8-f15 */
    volatile uint32_t cfp_mem[4] __attribute__((aligned(4)));
    cfp_mem[0] = 0;
    __asm__ volatile("li s0, 0x12345678\n" /* Load test pattern into x8 */
                     "fmv.w.x fs1, s0\n"   /* Move to f9 (fs1) */
                     "mv s0, %0\n"         /* s0 = &cfp_mem[0] */
                     "c.fsw fs1, 0(s0)\n"  /* Store f9 to memory via C.FSW */
                     :
                     : "r"(&cfp_mem[0])
                     : "s0", "fs1", "memory");
    TEST("c.fsw", cfp_mem[0], 0x12345678);

    /* C.FLW: Load FP register from memory using compressed format */
    /* Note: C.FLW only supports f8-f15 (fs0-fs1, fa0-fa5) */
    cfp_mem[1] = 0xDEADBEEF;
    __asm__ volatile("mv s0, %1\n"        /* s0 = &cfp_mem[1] */
                     "c.flw fa0, 0(s0)\n" /* Load from memory into f10 (fa0) */
                     "fmv.x.w %0, fa0\n"  /* Move to integer for checking */
                     : "=r"(result)
                     : "r"(&cfp_mem[1])
                     : "s0", "fa0");
    TEST("c.flw", result, 0xDEADBEEF);

    /* C.FLW with offset: Load from base+offset */
    cfp_mem[2] = 0xCAFEBABE;
    __asm__ volatile("mv s0, %1\n"        /* s0 = &cfp_mem[0] */
                     "c.flw fa1, 8(s0)\n" /* Load cfp_mem[2] into f11 (fa1) */
                     "fmv.x.w %0, fa1\n"
                     : "=r"(result)
                     : "r"(&cfp_mem[0])
                     : "s0", "fa1");
    TEST("c.flw+o", result, 0xCAFEBABE);

    /* C.FSWSP: Store FP register to stack using compressed format */
    __asm__ volatile("addi sp, sp, -16\n"
                     "li t0, 0xABCD1234\n"
                     "fmv.w.x ft0, t0\n"    /* ft0 = 0xABCD1234 */
                     "c.fswsp ft0, 0(sp)\n" /* Store to stack */
                     "lw %0, 0(sp)\n"       /* Load back as integer to check */
                     "addi sp, sp, 16\n"
                     : "=r"(result)
                     :
                     : "t0", "ft0", "memory");
    TEST("c.fswsp", result, 0xABCD1234);

    /* C.FLWSP: Load FP register from stack using compressed format */
    __asm__ volatile("addi sp, sp, -16\n"
                     "li t0, 0x87654321\n"
                     "sw t0, 4(sp)\n"       /* Store test value at sp+4 */
                     "c.flwsp ft1, 4(sp)\n" /* Load into ft1 */
                     "fmv.x.w %0, ft1\n"    /* Move to integer for checking */
                     "addi sp, sp, 16\n"
                     : "=r"(result)
                     :
                     : "t0", "ft1", "memory");
    TEST("c.flwsp", result, 0x87654321);

    /* ===== Compressed Double-Precision Load/Store (RV32DC / Zcd) ===== */

    volatile uint64_t cfp_mem_d[4] __attribute__((aligned(8)));
    cfp_mem_d[0] = 0x0123456789ABCDEFull;
    cfp_mem_d[1] = 0;
    __asm__ volatile("mv s0, %0\n"
                     "c.fld fs0, 0(s0)\n"
                     "c.fsd fs0, 8(s0)\n"
                     :
                     : "r"(&cfp_mem_d[0])
                     : "s0", "fs0", "memory");
    TEST64("c.fsd", cfp_mem_d[1], 0x0123456789ABCDEFull);

    cfp_mem_d[2] = 0x0FEDCBA987654321ull;
    __asm__ volatile("mv s0, %1\n"
                     "c.fld fa0, 16(s0)\n"
                     "fsd fa0, 0(%0)\n"
                     :
                     : "r"(&cfp_mem_d[3]), "r"(&cfp_mem_d[0])
                     : "s0", "fa0", "memory");
    TEST64("c.fld+o", cfp_mem_d[3], 0x0FEDCBA987654321ull);

    __asm__ volatile("addi sp, sp, -32\n"
                     "li t0, 0x89ABCDEF\n"
                     "li t1, 0x01234567\n"
                     "sw t0, 0(sp)\n"
                     "sw t1, 4(sp)\n"
                     "c.fldsp fs1, 0(sp)\n"
                     "c.fsdsp fs1, 8(sp)\n"
                     "lw %0, 8(sp)\n"
                     "lw %1, 12(sp)\n"
                     "addi sp, sp, 32\n"
                     : "=r"(result_lo), "=r"(result_hi)
                     :
                     : "t0", "t1", "fs1", "memory");
    result64 = ((uint64_t) result_hi << 32) | result_lo;
    TEST64("c.fsdsp", result64, 0x0123456789ABCDEFull);

    uint32_t old_mtvec;
    __asm__ volatile("csrr %0, mtvec" : "=r"(old_mtvec));
    __asm__ volatile("csrw mtvec, %0" ::"r"((uint32_t) c_test_trap_handler));
    __asm__ volatile("csrc mstatus, %0" ::"r"(0x8));

    c_trap_taken = 0;
    c_trap_cause = 0;
    __asm__ volatile(".insn 0x9002" ::: "memory");
    TEST("ebrk_t", c_trap_taken, 1);
    TEST("ebrk_c", c_trap_cause, 3);

    __asm__ volatile("csrw mtvec, %0" ::"r"(old_mtvec));
    __asm__ volatile("csrs mstatus, %0" ::"r"(0x8)); /* Re-enable interrupts */

    END_EXTENSION();
}

/* ========================================================================== */
/* F Extension Tests (Single-Precision Floating-Point)                        */
/* ========================================================================== */

/* IEEE 754 single-precision constants */
#define FP_POS_ZERO 0x00000000U   /* +0.0 */
#define FP_NEG_ZERO 0x80000000U   /* -0.0 */
#define FP_POS_ONE 0x3F800000U    /* +1.0 */
#define FP_NEG_ONE 0xBF800000U    /* -1.0 */
#define FP_POS_TWO 0x40000000U    /* +2.0 */
#define FP_POS_THREE 0x40400000U  /* +3.0 */
#define FP_POS_FOUR 0x40800000U   /* +4.0 */
#define FP_POS_HALF 0x3F000000U   /* +0.5 */
#define FP_POS_INF 0x7F800000U    /* +infinity */
#define FP_NEG_INF 0xFF800000U    /* -infinity */
#define FP_QNAN 0x7FC00000U       /* Quiet NaN (canonical) */
#define FP_SNAN 0x7F800001U       /* Signaling NaN */
#define FP_POS_DENORM 0x00000001U /* Smallest positive denormal */
#define FP_NEG_DENORM 0x80000001U /* Smallest negative denormal */
#define FP_POS_MAX 0x7F7FFFFFU    /* Largest finite positive */
#define FP_NEG_MAX 0xFF7FFFFFU    /* Largest finite negative */
#define FP_PI 0x40490FDBU         /* ~3.14159265 */
#define FP_E 0x402DF854U          /* ~2.71828182 */

/* IEEE 754 double-precision constants */
#define DP_POS_ZERO 0x0000000000000000ull   /* +0.0 */
#define DP_NEG_ZERO 0x8000000000000000ull   /* -0.0 */
#define DP_POS_ONE 0x3FF0000000000000ull    /* +1.0 */
#define DP_NEG_ONE 0xBFF0000000000000ull    /* -1.0 */
#define DP_POS_TWO 0x4000000000000000ull    /* +2.0 */
#define DP_POS_THREE 0x4008000000000000ull  /* +3.0 */
#define DP_POS_FOUR 0x4010000000000000ull   /* +4.0 */
#define DP_POS_HALF 0x3FE0000000000000ull   /* +0.5 */
#define DP_POS_INF 0x7FF0000000000000ull    /* +infinity */
#define DP_NEG_INF 0xFFF0000000000000ull    /* -infinity */
#define DP_QNAN 0x7FF8000000000000ull       /* Quiet NaN (canonical) */
#define DP_SNAN 0x7FF0000000000001ull       /* Signaling NaN */
#define DP_POS_DENORM 0x0000000000000001ull /* Smallest positive denormal */
#define DP_NEG_DENORM 0x8000000000000001ull /* Smallest negative denormal */
#define DP_POS_MAX 0x7FEFFFFFFFFFFFFFull    /* Largest finite positive */
#define DP_NEG_MAX 0xFFEFFFFFFFFFFFFFull    /* Largest finite negative */
#define DP_PI 0x400921FB54442D18ull         /* ~3.141592653589793 */
#define DP_E 0x4005BF0A8B145769ull          /* ~2.718281828459045 */

/* FCLASS bit positions */
#define FCLASS_NEG_INF (1 << 0)
#define FCLASS_NEG_NORMAL (1 << 1)
#define FCLASS_NEG_SUBNORM (1 << 2)
#define FCLASS_NEG_ZERO (1 << 3)
#define FCLASS_POS_ZERO (1 << 4)
#define FCLASS_POS_SUBNORM (1 << 5)
#define FCLASS_POS_NORMAL (1 << 6)
#define FCLASS_POS_INF (1 << 7)
#define FCLASS_SNAN (1 << 8)
#define FCLASS_QNAN (1 << 9)

/* Helper to convert uint32_t bit pattern to float */
static inline float u32_to_float(uint32_t bits)
{
    union {
        uint32_t u;
        float f;
    } conv;
    conv.u = bits;
    return conv.f;
}

/* Helper to convert float to uint32_t bit pattern */
static inline uint32_t float_to_u32(float f)
{
    union {
        uint32_t u;
        float f;
    } conv;
    conv.f = f;
    return conv.u;
}

/* Helper to convert uint64_t bit pattern to double */
static inline double u64_to_double(uint64_t bits)
{
    union {
        uint64_t u;
        double d;
    } conv;
    conv.u = bits;
    return conv.d;
}

/* Helper to convert double to uint64_t bit pattern */
static inline uint64_t double_to_u64(double d)
{
    union {
        uint64_t u;
        double d;
    } conv;
    conv.d = d;
    return conv.u;
}

/* Storage for FLW/FSW tests */
static volatile float fp_test_mem[4] __attribute__((aligned(4)));
static volatile double fp_test_mem_d[4] __attribute__((aligned(8)));

static void test_f_extension(void)
{
    BEGIN_EXTENSION(EXT_F);

    uint32_t result;
    float fresult;

    uart_printf("  F: Starting FMV tests\n");

    /* ===================================================================== */
    /* FMV.W.X / FMV.X.W - Move between integer and FP registers             */
    /* ===================================================================== */

    /* FMV.W.X: Move bits from integer register to FP register */
    /* FMV.X.W: Move bits from FP register to integer register */
    uart_printf("  F: Before FMV roundtrip\n");
    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fmv.x.w %0, ft0"
                     : "=r"(result)
                     : "r"(FP_POS_ONE)
                     : "ft0");
    uart_printf("  F: After FMV roundtrip\n");
    TEST("FMV roundtrip", result, FP_POS_ONE);

    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fmv.x.w %0, ft0"
                     : "=r"(result)
                     : "r"(FP_NEG_ZERO)
                     : "ft0");
    TEST("FMV -0", result, FP_NEG_ZERO);

    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fmv.x.w %0, ft0"
                     : "=r"(result)
                     : "r"(FP_QNAN)
                     : "ft0");
    TEST("FMV NaN", result, FP_QNAN);

    /* ===================================================================== */
    /* FLW / FSW - Floating-Point Load/Store                                 */
    /* ===================================================================== */

    /* FSW: Store float to memory */
    fresult = u32_to_float(FP_PI);
    __asm__ volatile("fsw %0, 0(%1)" ::"f"(fresult), "r"(&fp_test_mem[0]) : "memory");
    result = *(volatile uint32_t *) &fp_test_mem[0];
    TEST("FSW basic", result, FP_PI);

    /* FLW: Load float from memory */
    *(volatile uint32_t *) &fp_test_mem[1] = FP_E;
    __asm__ volatile("flw ft1, 0(%1)\n\t"
                     "fmv.x.w %0, ft1"
                     : "=r"(result)
                     : "r"(&fp_test_mem[1])
                     : "ft1", "memory");
    TEST("FLW basic", result, FP_E);

    /* Test with offset */
    *(volatile uint32_t *) &fp_test_mem[2] = FP_POS_TWO;
    __asm__ volatile("flw ft2, 8(%1)\n\t"
                     "fmv.x.w %0, ft2"
                     : "=r"(result)
                     : "r"(&fp_test_mem[0])
                     : "ft2", "memory");
    TEST("FLW offset", result, FP_POS_TWO);

    /* ===================================================================== */
    /* FSGNJ.S / FSGNJN.S / FSGNJX.S - Sign Injection                        */
    /* ===================================================================== */

    /* FSGNJ.S: result = |rs1| with sign of rs2 */
    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fmv.w.x ft1, %2\n\t"
                     "fsgnj.s ft2, ft0, ft1\n\t"
                     "fmv.x.w %0, ft2"
                     : "=r"(result)
                     : "r"(FP_POS_ONE), "r"(FP_NEG_ONE)
                     : "ft0", "ft1", "ft2");
    TEST("FSGNJ +,- -> -", result, FP_NEG_ONE);

    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fmv.w.x ft1, %2\n\t"
                     "fsgnj.s ft2, ft0, ft1\n\t"
                     "fmv.x.w %0, ft2"
                     : "=r"(result)
                     : "r"(FP_NEG_ONE), "r"(FP_POS_ONE)
                     : "ft0", "ft1", "ft2");
    TEST("FSGNJ -,+ -> +", result, FP_POS_ONE);

    /* FSGNJN.S: result = |rs1| with negated sign of rs2 */
    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fmv.w.x ft1, %2\n\t"
                     "fsgnjn.s ft2, ft0, ft1\n\t"
                     "fmv.x.w %0, ft2"
                     : "=r"(result)
                     : "r"(FP_POS_ONE), "r"(FP_NEG_ONE)
                     : "ft0", "ft1", "ft2");
    TEST("FSGNJN +,- -> +", result, FP_POS_ONE);

    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fmv.w.x ft1, %2\n\t"
                     "fsgnjn.s ft2, ft0, ft1\n\t"
                     "fmv.x.w %0, ft2"
                     : "=r"(result)
                     : "r"(FP_POS_ONE), "r"(FP_POS_ONE)
                     : "ft0", "ft1", "ft2");
    TEST("FSGNJN +,+ -> -", result, FP_NEG_ONE);

    /* FSGNJX.S: result = rs1 with sign = rs1.sign XOR rs2.sign */
    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fmv.w.x ft1, %2\n\t"
                     "fsgnjx.s ft2, ft0, ft1\n\t"
                     "fmv.x.w %0, ft2"
                     : "=r"(result)
                     : "r"(FP_POS_ONE), "r"(FP_NEG_ONE)
                     : "ft0", "ft1", "ft2");
    TEST("FSGNJX +,- -> -", result, FP_NEG_ONE);

    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fmv.w.x ft1, %2\n\t"
                     "fsgnjx.s ft2, ft0, ft1\n\t"
                     "fmv.x.w %0, ft2"
                     : "=r"(result)
                     : "r"(FP_NEG_ONE), "r"(FP_NEG_ONE)
                     : "ft0", "ft1", "ft2");
    TEST("FSGNJX -,- -> +", result, FP_POS_ONE);

    /* FABS (pseudo: FSGNJX with same operand) */
    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fabs.s ft1, ft0\n\t"
                     "fmv.x.w %0, ft1"
                     : "=r"(result)
                     : "r"(FP_NEG_ONE)
                     : "ft0", "ft1");
    TEST("FABS -1 -> +1", result, FP_POS_ONE);

    /* FNEG (pseudo: FSGNJN with same operand) */
    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fneg.s ft1, ft0\n\t"
                     "fmv.x.w %0, ft1"
                     : "=r"(result)
                     : "r"(FP_POS_ONE)
                     : "ft0", "ft1");
    TEST("FNEG +1 -> -1", result, FP_NEG_ONE);

    /* ===================================================================== */
    /* FCLASS.S - Classify floating-point value                              */
    /* ===================================================================== */

    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fclass.s %0, ft0"
                     : "=r"(result)
                     : "r"(FP_NEG_INF)
                     : "ft0");
    TEST("FCLASS -inf", result, FCLASS_NEG_INF);

    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fclass.s %0, ft0"
                     : "=r"(result)
                     : "r"(FP_NEG_ONE)
                     : "ft0");
    TEST("FCLASS -normal", result, FCLASS_NEG_NORMAL);

    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fclass.s %0, ft0"
                     : "=r"(result)
                     : "r"(FP_NEG_DENORM)
                     : "ft0");
    TEST("FCLASS -subnorm", result, FCLASS_NEG_SUBNORM);

    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fclass.s %0, ft0"
                     : "=r"(result)
                     : "r"(FP_NEG_ZERO)
                     : "ft0");
    TEST("FCLASS -0", result, FCLASS_NEG_ZERO);

    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fclass.s %0, ft0"
                     : "=r"(result)
                     : "r"(FP_POS_ZERO)
                     : "ft0");
    TEST("FCLASS +0", result, FCLASS_POS_ZERO);

    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fclass.s %0, ft0"
                     : "=r"(result)
                     : "r"(FP_POS_DENORM)
                     : "ft0");
    TEST("FCLASS +subnorm", result, FCLASS_POS_SUBNORM);

    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fclass.s %0, ft0"
                     : "=r"(result)
                     : "r"(FP_POS_ONE)
                     : "ft0");
    TEST("FCLASS +normal", result, FCLASS_POS_NORMAL);

    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fclass.s %0, ft0"
                     : "=r"(result)
                     : "r"(FP_POS_INF)
                     : "ft0");
    TEST("FCLASS +inf", result, FCLASS_POS_INF);

    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fclass.s %0, ft0"
                     : "=r"(result)
                     : "r"(FP_SNAN)
                     : "ft0");
    TEST("FCLASS sNaN", result, FCLASS_SNAN);

    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fclass.s %0, ft0"
                     : "=r"(result)
                     : "r"(FP_QNAN)
                     : "ft0");
    TEST("FCLASS qNaN", result, FCLASS_QNAN);

    /* ===================================================================== */
    /* FEQ.S / FLT.S / FLE.S - Floating-Point Comparisons                    */
    /* ===================================================================== */

    /* FEQ.S: rd = (rs1 == rs2) ? 1 : 0 */
    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fmv.w.x ft1, %2\n\t"
                     "feq.s %0, ft0, ft1"
                     : "=r"(result)
                     : "r"(FP_POS_ONE), "r"(FP_POS_ONE)
                     : "ft0", "ft1");
    TEST("FEQ 1==1", result, 1);

    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fmv.w.x ft1, %2\n\t"
                     "feq.s %0, ft0, ft1"
                     : "=r"(result)
                     : "r"(FP_POS_ONE), "r"(FP_POS_TWO)
                     : "ft0", "ft1");
    TEST("FEQ 1==2", result, 0);

    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fmv.w.x ft1, %2\n\t"
                     "feq.s %0, ft0, ft1"
                     : "=r"(result)
                     : "r"(FP_POS_ZERO), "r"(FP_NEG_ZERO)
                     : "ft0", "ft1");
    TEST("FEQ +0==-0", result, 1); /* +0 and -0 are equal */

    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fmv.w.x ft1, %2\n\t"
                     "feq.s %0, ft0, ft1"
                     : "=r"(result)
                     : "r"(FP_QNAN), "r"(FP_QNAN)
                     : "ft0", "ft1");
    TEST("FEQ NaN==NaN", result, 0); /* NaN != NaN */

    /* FLT.S: rd = (rs1 < rs2) ? 1 : 0 */
    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fmv.w.x ft1, %2\n\t"
                     "flt.s %0, ft0, ft1"
                     : "=r"(result)
                     : "r"(FP_POS_ONE), "r"(FP_POS_TWO)
                     : "ft0", "ft1");
    TEST("FLT 1<2", result, 1);

    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fmv.w.x ft1, %2\n\t"
                     "flt.s %0, ft0, ft1"
                     : "=r"(result)
                     : "r"(FP_POS_TWO), "r"(FP_POS_ONE)
                     : "ft0", "ft1");
    TEST("FLT 2<1", result, 0);

    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fmv.w.x ft1, %2\n\t"
                     "flt.s %0, ft0, ft1"
                     : "=r"(result)
                     : "r"(FP_NEG_ONE), "r"(FP_POS_ONE)
                     : "ft0", "ft1");
    TEST("FLT -1<1", result, 1);

    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fmv.w.x ft1, %2\n\t"
                     "flt.s %0, ft0, ft1"
                     : "=r"(result)
                     : "r"(FP_NEG_INF), "r"(FP_POS_INF)
                     : "ft0", "ft1");
    TEST("FLT -inf<+inf", result, 1);

    /* FLE.S: rd = (rs1 <= rs2) ? 1 : 0 */
    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fmv.w.x ft1, %2\n\t"
                     "fle.s %0, ft0, ft1"
                     : "=r"(result)
                     : "r"(FP_POS_ONE), "r"(FP_POS_ONE)
                     : "ft0", "ft1");
    TEST("FLE 1<=1", result, 1);

    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fmv.w.x ft1, %2\n\t"
                     "fle.s %0, ft0, ft1"
                     : "=r"(result)
                     : "r"(FP_POS_ONE), "r"(FP_POS_TWO)
                     : "ft0", "ft1");
    TEST("FLE 1<=2", result, 1);

    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fmv.w.x ft1, %2\n\t"
                     "fle.s %0, ft0, ft1"
                     : "=r"(result)
                     : "r"(FP_POS_TWO), "r"(FP_POS_ONE)
                     : "ft0", "ft1");
    TEST("FLE 2<=1", result, 0);

    /* ===================================================================== */
    /* FMIN.S / FMAX.S - Minimum and Maximum                                 */
    /* ===================================================================== */

    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fmv.w.x ft1, %2\n\t"
                     "fmin.s ft2, ft0, ft1\n\t"
                     "fmv.x.w %0, ft2"
                     : "=r"(result)
                     : "r"(FP_POS_ONE), "r"(FP_POS_TWO)
                     : "ft0", "ft1", "ft2");
    TEST("FMIN 1,2", result, FP_POS_ONE);

    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fmv.w.x ft1, %2\n\t"
                     "fmin.s ft2, ft0, ft1\n\t"
                     "fmv.x.w %0, ft2"
                     : "=r"(result)
                     : "r"(FP_NEG_ONE), "r"(FP_POS_ONE)
                     : "ft0", "ft1", "ft2");
    TEST("FMIN -1,1", result, FP_NEG_ONE);

    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fmv.w.x ft1, %2\n\t"
                     "fmin.s ft2, ft0, ft1\n\t"
                     "fmv.x.w %0, ft2"
                     : "=r"(result)
                     : "r"(FP_POS_ZERO), "r"(FP_NEG_ZERO)
                     : "ft0", "ft1", "ft2");
    TEST("FMIN +0,-0", result, FP_NEG_ZERO); /* -0 is smaller */

    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fmv.w.x ft1, %2\n\t"
                     "fmax.s ft2, ft0, ft1\n\t"
                     "fmv.x.w %0, ft2"
                     : "=r"(result)
                     : "r"(FP_POS_ONE), "r"(FP_POS_TWO)
                     : "ft0", "ft1", "ft2");
    TEST("FMAX 1,2", result, FP_POS_TWO);

    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fmv.w.x ft1, %2\n\t"
                     "fmax.s ft2, ft0, ft1\n\t"
                     "fmv.x.w %0, ft2"
                     : "=r"(result)
                     : "r"(FP_NEG_ONE), "r"(FP_POS_ONE)
                     : "ft0", "ft1", "ft2");
    TEST("FMAX -1,1", result, FP_POS_ONE);

    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fmv.w.x ft1, %2\n\t"
                     "fmax.s ft2, ft0, ft1\n\t"
                     "fmv.x.w %0, ft2"
                     : "=r"(result)
                     : "r"(FP_POS_ZERO), "r"(FP_NEG_ZERO)
                     : "ft0", "ft1", "ft2");
    TEST("FMAX +0,-0", result, FP_POS_ZERO); /* +0 is larger */

    /* FMIN/FMAX with NaN: return the non-NaN operand */
    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fmv.w.x ft1, %2\n\t"
                     "fmin.s ft2, ft0, ft1\n\t"
                     "fmv.x.w %0, ft2"
                     : "=r"(result)
                     : "r"(FP_POS_ONE), "r"(FP_QNAN)
                     : "ft0", "ft1", "ft2");
    TEST("FMIN 1,NaN", result, FP_POS_ONE);

    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fmv.w.x ft1, %2\n\t"
                     "fmax.s ft2, ft0, ft1\n\t"
                     "fmv.x.w %0, ft2"
                     : "=r"(result)
                     : "r"(FP_QNAN), "r"(FP_POS_TWO)
                     : "ft0", "ft1", "ft2");
    TEST("FMAX NaN,2", result, FP_POS_TWO);

    /* ===================================================================== */
    /* FCVT.W.S / FCVT.WU.S - Float to Integer Conversion                    */
    /* ===================================================================== */

    /* FCVT.W.S: Convert float to signed 32-bit integer */
    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fcvt.w.s %0, ft0, rtz"
                     : "=r"(result)
                     : "r"(FP_POS_ONE)
                     : "ft0");
    TEST("FCVT.W.S 1.0", result, 1);

    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fcvt.w.s %0, ft0, rtz"
                     : "=r"(result)
                     : "r"(FP_NEG_ONE)
                     : "ft0");
    TEST("FCVT.W.S -1.0", result, (uint32_t) -1);

    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fcvt.w.s %0, ft0, rtz"
                     : "=r"(result)
                     : "r"(FP_PI)
                     : "ft0");
    TEST("FCVT.W.S pi->3", result, 3);

    /* Overflow: +inf -> INT32_MAX */
    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fcvt.w.s %0, ft0, rtz"
                     : "=r"(result)
                     : "r"(FP_POS_INF)
                     : "ft0");
    TEST("FCVT.W.S +inf", result, 0x7FFFFFFF);

    /* Overflow: -inf -> INT32_MIN */
    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fcvt.w.s %0, ft0, rtz"
                     : "=r"(result)
                     : "r"(FP_NEG_INF)
                     : "ft0");
    TEST("FCVT.W.S -inf", result, 0x80000000);

    /* NaN -> INT32_MAX */
    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fcvt.w.s %0, ft0, rtz"
                     : "=r"(result)
                     : "r"(FP_QNAN)
                     : "ft0");
    TEST("FCVT.W.S NaN", result, 0x7FFFFFFF);

    /* FCVT.WU.S: Convert float to unsigned 32-bit integer */
    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fcvt.wu.s %0, ft0, rtz"
                     : "=r"(result)
                     : "r"(FP_POS_ONE)
                     : "ft0");
    TEST("FCVT.WU.S 1.0", result, 1);

    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fcvt.wu.s %0, ft0, rtz"
                     : "=r"(result)
                     : "r"(FP_POS_TWO)
                     : "ft0");
    TEST("FCVT.WU.S 2.0", result, 2);

    /* Negative -> 0 (saturates) */
    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fcvt.wu.s %0, ft0, rtz"
                     : "=r"(result)
                     : "r"(FP_NEG_ONE)
                     : "ft0");
    TEST("FCVT.WU.S -1.0", result, 0);

    /* ===================================================================== */
    /* FCVT.S.W / FCVT.S.WU - Integer to Float Conversion                    */
    /* ===================================================================== */

    /* FCVT.S.W: Convert signed 32-bit integer to float */
    __asm__ volatile("fcvt.s.w ft0, %1\n\t"
                     "fmv.x.w %0, ft0"
                     : "=r"(result)
                     : "r"(1)
                     : "ft0");
    TEST("FCVT.S.W 1", result, FP_POS_ONE);

    __asm__ volatile("fcvt.s.w ft0, %1\n\t"
                     "fmv.x.w %0, ft0"
                     : "=r"(result)
                     : "r"(-1)
                     : "ft0");
    TEST("FCVT.S.W -1", result, FP_NEG_ONE);

    __asm__ volatile("fcvt.s.w ft0, %1\n\t"
                     "fmv.x.w %0, ft0"
                     : "=r"(result)
                     : "r"(0)
                     : "ft0");
    TEST("FCVT.S.W 0", result, FP_POS_ZERO);

    /* FCVT.S.WU: Convert unsigned 32-bit integer to float */
    __asm__ volatile("fcvt.s.wu ft0, %1\n\t"
                     "fmv.x.w %0, ft0"
                     : "=r"(result)
                     : "r"(1U)
                     : "ft0");
    TEST("FCVT.S.WU 1", result, FP_POS_ONE);

    __asm__ volatile("fcvt.s.wu ft0, %1\n\t"
                     "fmv.x.w %0, ft0"
                     : "=r"(result)
                     : "r"(2U)
                     : "ft0");
    TEST("FCVT.S.WU 2", result, FP_POS_TWO);

    /* ===================================================================== */
    /* FADD.S / FSUB.S - Floating-Point Addition and Subtraction             */
    /* ===================================================================== */

    /* FADD.S: rd = rs1 + rs2 */
    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fmv.w.x ft1, %2\n\t"
                     "fadd.s ft2, ft0, ft1\n\t"
                     "fmv.x.w %0, ft2"
                     : "=r"(result)
                     : "r"(FP_POS_ONE), "r"(FP_POS_ONE)
                     : "ft0", "ft1", "ft2");
    TEST("FADD 1+1=2", result, FP_POS_TWO);

    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fmv.w.x ft1, %2\n\t"
                     "fadd.s ft2, ft0, ft1\n\t"
                     "fmv.x.w %0, ft2"
                     : "=r"(result)
                     : "r"(FP_POS_ONE), "r"(FP_NEG_ONE)
                     : "ft0", "ft1", "ft2");
    TEST("FADD 1+(-1)=0", result, FP_POS_ZERO);

    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fmv.w.x ft1, %2\n\t"
                     "fadd.s ft2, ft0, ft1\n\t"
                     "fmv.x.w %0, ft2"
                     : "=r"(result)
                     : "r"(FP_POS_ZERO), "r"(FP_NEG_ZERO)
                     : "ft0", "ft1", "ft2");
    TEST("FADD +0+(-0)=+0", result, FP_POS_ZERO);

    /* FADD with infinity */
    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fmv.w.x ft1, %2\n\t"
                     "fadd.s ft2, ft0, ft1\n\t"
                     "fmv.x.w %0, ft2"
                     : "=r"(result)
                     : "r"(FP_POS_ONE), "r"(FP_POS_INF)
                     : "ft0", "ft1", "ft2");
    TEST("FADD 1+inf=inf", result, FP_POS_INF);

    /* FSUB.S: rd = rs1 - rs2 */
    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fmv.w.x ft1, %2\n\t"
                     "fsub.s ft2, ft0, ft1\n\t"
                     "fmv.x.w %0, ft2"
                     : "=r"(result)
                     : "r"(FP_POS_TWO), "r"(FP_POS_ONE)
                     : "ft0", "ft1", "ft2");
    TEST("FSUB 2-1=1", result, FP_POS_ONE);

    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fmv.w.x ft1, %2\n\t"
                     "fsub.s ft2, ft0, ft1\n\t"
                     "fmv.x.w %0, ft2"
                     : "=r"(result)
                     : "r"(FP_POS_ONE), "r"(FP_POS_TWO)
                     : "ft0", "ft1", "ft2");
    TEST("FSUB 1-2=-1", result, FP_NEG_ONE);

    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fmv.w.x ft1, %2\n\t"
                     "fsub.s ft2, ft0, ft1\n\t"
                     "fmv.x.w %0, ft2"
                     : "=r"(result)
                     : "r"(FP_POS_ONE), "r"(FP_POS_ONE)
                     : "ft0", "ft1", "ft2");
    TEST("FSUB 1-1=0", result, FP_POS_ZERO);

    /* ===================================================================== */
    /* FMUL.S - Floating-Point Multiplication                                */
    /* ===================================================================== */

    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fmv.w.x ft1, %2\n\t"
                     "fmul.s ft2, ft0, ft1\n\t"
                     "fmv.x.w %0, ft2"
                     : "=r"(result)
                     : "r"(FP_POS_TWO), "r"(FP_POS_TWO)
                     : "ft0", "ft1", "ft2");
    TEST("FMUL 2*2=4", result, FP_POS_FOUR);

    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fmv.w.x ft1, %2\n\t"
                     "fmul.s ft2, ft0, ft1\n\t"
                     "fmv.x.w %0, ft2"
                     : "=r"(result)
                     : "r"(FP_POS_TWO), "r"(FP_POS_HALF)
                     : "ft0", "ft1", "ft2");
    TEST("FMUL 2*0.5=1", result, FP_POS_ONE);

    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fmv.w.x ft1, %2\n\t"
                     "fmul.s ft2, ft0, ft1\n\t"
                     "fmv.x.w %0, ft2"
                     : "=r"(result)
                     : "r"(FP_NEG_ONE), "r"(FP_NEG_ONE)
                     : "ft0", "ft1", "ft2");
    TEST("FMUL -1*-1=1", result, FP_POS_ONE);

    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fmv.w.x ft1, %2\n\t"
                     "fmul.s ft2, ft0, ft1\n\t"
                     "fmv.x.w %0, ft2"
                     : "=r"(result)
                     : "r"(FP_POS_ONE), "r"(FP_NEG_ONE)
                     : "ft0", "ft1", "ft2");
    TEST("FMUL 1*-1=-1", result, FP_NEG_ONE);

    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fmv.w.x ft1, %2\n\t"
                     "fmul.s ft2, ft0, ft1\n\t"
                     "fmv.x.w %0, ft2"
                     : "=r"(result)
                     : "r"(FP_POS_ONE), "r"(FP_POS_ZERO)
                     : "ft0", "ft1", "ft2");
    TEST("FMUL 1*0=0", result, FP_POS_ZERO);

    /* ===================================================================== */
    /* FDIV.S - Floating-Point Division                                      */
    /* ===================================================================== */

    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fmv.w.x ft1, %2\n\t"
                     "fdiv.s ft2, ft0, ft1\n\t"
                     "fmv.x.w %0, ft2"
                     : "=r"(result)
                     : "r"(FP_POS_FOUR), "r"(FP_POS_TWO)
                     : "ft0", "ft1", "ft2");
    TEST("FDIV 4/2=2", result, FP_POS_TWO);

    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fmv.w.x ft1, %2\n\t"
                     "fdiv.s ft2, ft0, ft1\n\t"
                     "fmv.x.w %0, ft2"
                     : "=r"(result)
                     : "r"(FP_POS_ONE), "r"(FP_POS_TWO)
                     : "ft0", "ft1", "ft2");
    TEST("FDIV 1/2=0.5", result, FP_POS_HALF);

    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fmv.w.x ft1, %2\n\t"
                     "fdiv.s ft2, ft0, ft1\n\t"
                     "fmv.x.w %0, ft2"
                     : "=r"(result)
                     : "r"(FP_NEG_ONE), "r"(FP_POS_ONE)
                     : "ft0", "ft1", "ft2");
    TEST("FDIV -1/1=-1", result, FP_NEG_ONE);

    /* Division by zero -> infinity */
    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fmv.w.x ft1, %2\n\t"
                     "fdiv.s ft2, ft0, ft1\n\t"
                     "fmv.x.w %0, ft2"
                     : "=r"(result)
                     : "r"(FP_POS_ONE), "r"(FP_POS_ZERO)
                     : "ft0", "ft1", "ft2");
    TEST("FDIV 1/0=+inf", result, FP_POS_INF);

    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fmv.w.x ft1, %2\n\t"
                     "fdiv.s ft2, ft0, ft1\n\t"
                     "fmv.x.w %0, ft2"
                     : "=r"(result)
                     : "r"(FP_NEG_ONE), "r"(FP_POS_ZERO)
                     : "ft0", "ft1", "ft2");
    TEST("FDIV -1/0=-inf", result, FP_NEG_INF);

    /* 0/0 -> NaN */
    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fmv.w.x ft1, %2\n\t"
                     "fdiv.s ft2, ft0, ft1\n\t"
                     "fmv.x.w %0, ft2"
                     : "=r"(result)
                     : "r"(FP_POS_ZERO), "r"(FP_POS_ZERO)
                     : "ft0", "ft1", "ft2");
    TEST("FDIV 0/0=NaN", result, FP_QNAN);

    /* ===================================================================== */
    /* FSQRT.S - Floating-Point Square Root                                  */
    /* ===================================================================== */

    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fsqrt.s ft1, ft0\n\t"
                     "fmv.x.w %0, ft1"
                     : "=r"(result)
                     : "r"(FP_POS_FOUR)
                     : "ft0", "ft1");
    TEST("FSQRT 4=2", result, FP_POS_TWO);

    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fsqrt.s ft1, ft0\n\t"
                     "fmv.x.w %0, ft1"
                     : "=r"(result)
                     : "r"(FP_POS_ONE)
                     : "ft0", "ft1");
    TEST("FSQRT 1=1", result, FP_POS_ONE);

    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fsqrt.s ft1, ft0\n\t"
                     "fmv.x.w %0, ft1"
                     : "=r"(result)
                     : "r"(FP_POS_ZERO)
                     : "ft0", "ft1");
    TEST("FSQRT +0=+0", result, FP_POS_ZERO);

    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fsqrt.s ft1, ft0\n\t"
                     "fmv.x.w %0, ft1"
                     : "=r"(result)
                     : "r"(FP_NEG_ZERO)
                     : "ft0", "ft1");
    TEST("FSQRT -0=-0", result, FP_NEG_ZERO);

    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fsqrt.s ft1, ft0\n\t"
                     "fmv.x.w %0, ft1"
                     : "=r"(result)
                     : "r"(FP_POS_INF)
                     : "ft0", "ft1");
    TEST("FSQRT +inf=+inf", result, FP_POS_INF);

    /* sqrt(-1) -> NaN */
    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fsqrt.s ft1, ft0\n\t"
                     "fmv.x.w %0, ft1"
                     : "=r"(result)
                     : "r"(FP_NEG_ONE)
                     : "ft0", "ft1");
    TEST("FSQRT -1=NaN", result, FP_QNAN);

    /* ===================================================================== */
    /* FMADD.S / FMSUB.S / FNMADD.S / FNMSUB.S - Fused Multiply-Add          */
    /* ===================================================================== */

    /* FMADD.S: rd = (rs1 * rs2) + rs3 */
    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fmv.w.x ft1, %2\n\t"
                     "fmv.w.x ft2, %3\n\t"
                     "fmadd.s ft3, ft0, ft1, ft2\n\t"
                     "fmv.x.w %0, ft3"
                     : "=r"(result)
                     : "r"(FP_POS_TWO), "r"(FP_POS_TWO), "r"(FP_POS_ONE)
                     : "ft0", "ft1", "ft2", "ft3");
    TEST("FMADD 2*2+1=5", result, 0x40A00000); /* 5.0 */

    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fmv.w.x ft1, %2\n\t"
                     "fmv.w.x ft2, %3\n\t"
                     "fmadd.s ft3, ft0, ft1, ft2\n\t"
                     "fmv.x.w %0, ft3"
                     : "=r"(result)
                     : "r"(FP_POS_ONE), "r"(FP_POS_ONE), "r"(FP_POS_ONE)
                     : "ft0", "ft1", "ft2", "ft3");
    TEST("FMADD 1*1+1=2", result, FP_POS_TWO);

    /* FMSUB.S: rd = (rs1 * rs2) - rs3 */
    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fmv.w.x ft1, %2\n\t"
                     "fmv.w.x ft2, %3\n\t"
                     "fmsub.s ft3, ft0, ft1, ft2\n\t"
                     "fmv.x.w %0, ft3"
                     : "=r"(result)
                     : "r"(FP_POS_TWO), "r"(FP_POS_TWO), "r"(FP_POS_ONE)
                     : "ft0", "ft1", "ft2", "ft3");
    TEST("FMSUB 2*2-1=3", result, FP_POS_THREE);

    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fmv.w.x ft1, %2\n\t"
                     "fmv.w.x ft2, %3\n\t"
                     "fmsub.s ft3, ft0, ft1, ft2\n\t"
                     "fmv.x.w %0, ft3"
                     : "=r"(result)
                     : "r"(FP_POS_ONE), "r"(FP_POS_ONE), "r"(FP_POS_ONE)
                     : "ft0", "ft1", "ft2", "ft3");
    TEST("FMSUB 1*1-1=0", result, FP_POS_ZERO);

    /* FNMADD.S: rd = -(rs1 * rs2) - rs3 */
    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fmv.w.x ft1, %2\n\t"
                     "fmv.w.x ft2, %3\n\t"
                     "fnmadd.s ft3, ft0, ft1, ft2\n\t"
                     "fmv.x.w %0, ft3"
                     : "=r"(result)
                     : "r"(FP_POS_ONE), "r"(FP_POS_ONE), "r"(FP_POS_ONE)
                     : "ft0", "ft1", "ft2", "ft3");
    TEST("FNMADD -(1*1)-1=-2", result, 0xC0000000); /* -2.0 */

    /* FNMSUB.S: rd = -(rs1 * rs2) + rs3 */
    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fmv.w.x ft1, %2\n\t"
                     "fmv.w.x ft2, %3\n\t"
                     "fnmsub.s ft3, ft0, ft1, ft2\n\t"
                     "fmv.x.w %0, ft3"
                     : "=r"(result)
                     : "r"(FP_POS_ONE), "r"(FP_POS_ONE), "r"(FP_POS_TWO)
                     : "ft0", "ft1", "ft2", "ft3");
    TEST("FNMSUB -(1*1)+2=1", result, FP_POS_ONE);

    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fmv.w.x ft1, %2\n\t"
                     "fmv.w.x ft2, %3\n\t"
                     "fnmsub.s ft3, ft0, ft1, ft2\n\t"
                     "fmv.x.w %0, ft3"
                     : "=r"(result)
                     : "r"(FP_POS_TWO), "r"(FP_POS_TWO), "r"(FP_POS_ONE)
                     : "ft0", "ft1", "ft2", "ft3");
    TEST("FNMSUB -(2*2)+1=-3", result, 0xC0400000); /* -3.0 */

    /* ===================================================================== */
    /* FP CSR Tests - fflags, frm, fcsr                                      */
    /* ===================================================================== */

    /* Clear fflags before testing */
    __asm__ volatile("csrw fflags, zero");

    /* Trigger invalid operation (sqrt of negative) */
    __asm__ volatile("fmv.w.x ft0, %0\n\t"
                     "fsqrt.s ft1, ft0"
                     :
                     : "r"(FP_NEG_ONE)
                     : "ft0", "ft1");
    __asm__ volatile("csrr %0, fflags" : "=r"(result));
    TEST("fflags NV set", (result & 0x10) != 0, 1);

    /* Clear fflags */
    __asm__ volatile("csrw fflags, zero");

    /* Trigger divide by zero */
    __asm__ volatile("fmv.w.x ft0, %0\n\t"
                     "fmv.w.x ft1, %1\n\t"
                     "fdiv.s ft2, ft0, ft1"
                     :
                     : "r"(FP_POS_ONE), "r"(FP_POS_ZERO)
                     : "ft0", "ft1", "ft2");
    __asm__ volatile("csrr %0, fflags" : "=r"(result));
    TEST("fflags DZ set", (result & 0x08) != 0, 1);

    /* Read/write frm (rounding mode) */
    __asm__ volatile("csrw frm, %0" ::"r"(0)); /* RNE */
    __asm__ volatile("csrr %0, frm" : "=r"(result));
    TEST("frm RNE", result, 0);

    __asm__ volatile("csrw frm, %0" ::"r"(1)); /* RTZ */
    __asm__ volatile("csrr %0, frm" : "=r"(result));
    TEST("frm RTZ", result, 1);

    __asm__ volatile("csrw frm, %0" ::"r"(2)); /* RDN */
    __asm__ volatile("csrr %0, frm" : "=r"(result));
    TEST("frm RDN", result, 2);

    __asm__ volatile("csrw frm, %0" ::"r"(3)); /* RUP */
    __asm__ volatile("csrr %0, frm" : "=r"(result));
    TEST("frm RUP", result, 3);

    __asm__ volatile("csrw frm, %0" ::"r"(4)); /* RMM */
    __asm__ volatile("csrr %0, frm" : "=r"(result));
    TEST("frm RMM", result, 4);

    /* Reset to RNE */
    __asm__ volatile("csrw frm, zero");

    /* Test fcsr (combined frm and fflags) */
    __asm__ volatile("csrw fcsr, %0" ::"r"(0x00));
    __asm__ volatile("csrr %0, fcsr" : "=r"(result));
    TEST("fcsr clear", result, 0);

    __asm__ volatile("csrw fcsr, %0" ::"r"(0xFF)); /* Write all bits */
    __asm__ volatile("csrr %0, fcsr" : "=r"(result));
    TEST("fcsr mask", result, 0xFF); /* Only 8 bits are valid (3 frm + 5 fflags) */

    /* Reset fcsr */
    __asm__ volatile("csrw fcsr, zero");

    END_EXTENSION();
}

/* ========================================================================== */
/* D Extension Tests (Double-Precision Floating-Point)                        */
/* ========================================================================== */

static void test_d_extension(void)
{
    BEGIN_EXTENSION(EXT_D);

    uint32_t result;
    uint64_t result64;
    double dresult;

    /* ===================================================================== */
    /* FLD / FSD - Double-Precision Load/Store                               */
    /* ===================================================================== */

    dresult = u64_to_double(DP_PI);
    __asm__ volatile("fsd %0, 0(%1)" ::"f"(dresult), "r"(&fp_test_mem_d[0]) : "memory");
    result64 = double_to_u64(fp_test_mem_d[0]);
    TEST64("FSD basic", result64, DP_PI);

    fp_test_mem_d[1] = u64_to_double(DP_E);
    __asm__ volatile("fld %0, 0(%1)" : "=f"(dresult) : "r"(&fp_test_mem_d[1]) : "memory");
    result64 = double_to_u64(dresult);
    TEST64("FLD basic", result64, DP_E);

    fp_test_mem_d[2] = u64_to_double(DP_POS_TWO);
    __asm__ volatile("fld %0, 16(%1)" : "=f"(dresult) : "r"(&fp_test_mem_d[0]) : "memory");
    result64 = double_to_u64(dresult);
    TEST64("FLD offset", result64, DP_POS_TWO);

    /* ===================================================================== */
    /* FSGNJ.D / FSGNJN.D / FSGNJX.D - Sign Injection                        */
    /* ===================================================================== */

    __asm__ volatile("fsgnj.d %0, %1, %2"
                     : "=f"(dresult)
                     : "f"(u64_to_double(DP_POS_ONE)), "f"(u64_to_double(DP_NEG_ONE)));
    TEST64("FSGNJ +,- -> -", double_to_u64(dresult), DP_NEG_ONE);

    __asm__ volatile("fsgnj.d %0, %1, %2"
                     : "=f"(dresult)
                     : "f"(u64_to_double(DP_NEG_ONE)), "f"(u64_to_double(DP_POS_ONE)));
    TEST64("FSGNJ -,+ -> +", double_to_u64(dresult), DP_POS_ONE);

    __asm__ volatile("fsgnjn.d %0, %1, %2"
                     : "=f"(dresult)
                     : "f"(u64_to_double(DP_POS_ONE)), "f"(u64_to_double(DP_NEG_ONE)));
    TEST64("FSGNJN +,- -> +", double_to_u64(dresult), DP_POS_ONE);

    __asm__ volatile("fsgnjn.d %0, %1, %2"
                     : "=f"(dresult)
                     : "f"(u64_to_double(DP_POS_ONE)), "f"(u64_to_double(DP_POS_ONE)));
    TEST64("FSGNJN +,+ -> -", double_to_u64(dresult), DP_NEG_ONE);

    __asm__ volatile("fsgnjx.d %0, %1, %2"
                     : "=f"(dresult)
                     : "f"(u64_to_double(DP_POS_ONE)), "f"(u64_to_double(DP_NEG_ONE)));
    TEST64("FSGNJX +,- -> -", double_to_u64(dresult), DP_NEG_ONE);

    __asm__ volatile("fsgnjx.d %0, %1, %2"
                     : "=f"(dresult)
                     : "f"(u64_to_double(DP_NEG_ONE)), "f"(u64_to_double(DP_NEG_ONE)));
    TEST64("FSGNJX -,- -> +", double_to_u64(dresult), DP_POS_ONE);

    __asm__ volatile("fabs.d %0, %1" : "=f"(dresult) : "f"(u64_to_double(DP_NEG_ONE)));
    TEST64("FABS -1 -> +1", double_to_u64(dresult), DP_POS_ONE);

    __asm__ volatile("fneg.d %0, %1" : "=f"(dresult) : "f"(u64_to_double(DP_POS_ONE)));
    TEST64("FNEG +1 -> -1", double_to_u64(dresult), DP_NEG_ONE);

    /* ===================================================================== */
    /* FCLASS.D - Classify floating-point value                              */
    /* ===================================================================== */

    __asm__ volatile("fclass.d %0, %1" : "=r"(result) : "f"(u64_to_double(DP_NEG_INF)));
    TEST("FCLASS -inf", result, FCLASS_NEG_INF);

    __asm__ volatile("fclass.d %0, %1" : "=r"(result) : "f"(u64_to_double(DP_NEG_ONE)));
    TEST("FCLASS -normal", result, FCLASS_NEG_NORMAL);

    __asm__ volatile("fclass.d %0, %1" : "=r"(result) : "f"(u64_to_double(DP_NEG_DENORM)));
    TEST("FCLASS -subnorm", result, FCLASS_NEG_SUBNORM);

    __asm__ volatile("fclass.d %0, %1" : "=r"(result) : "f"(u64_to_double(DP_NEG_ZERO)));
    TEST("FCLASS -0", result, FCLASS_NEG_ZERO);

    __asm__ volatile("fclass.d %0, %1" : "=r"(result) : "f"(u64_to_double(DP_POS_ZERO)));
    TEST("FCLASS +0", result, FCLASS_POS_ZERO);

    __asm__ volatile("fclass.d %0, %1" : "=r"(result) : "f"(u64_to_double(DP_POS_DENORM)));
    TEST("FCLASS +subnorm", result, FCLASS_POS_SUBNORM);

    __asm__ volatile("fclass.d %0, %1" : "=r"(result) : "f"(u64_to_double(DP_POS_ONE)));
    TEST("FCLASS +normal", result, FCLASS_POS_NORMAL);

    __asm__ volatile("fclass.d %0, %1" : "=r"(result) : "f"(u64_to_double(DP_POS_INF)));
    TEST("FCLASS +inf", result, FCLASS_POS_INF);

    __asm__ volatile("fclass.d %0, %1" : "=r"(result) : "f"(u64_to_double(DP_SNAN)));
    TEST("FCLASS sNaN", result, FCLASS_SNAN);

    __asm__ volatile("fclass.d %0, %1" : "=r"(result) : "f"(u64_to_double(DP_QNAN)));
    TEST("FCLASS qNaN", result, FCLASS_QNAN);

    /* ===================================================================== */
    /* FEQ.D / FLT.D / FLE.D - Floating-Point Comparisons                    */
    /* ===================================================================== */

    __asm__ volatile("feq.d %0, %1, %2"
                     : "=r"(result)
                     : "f"(u64_to_double(DP_POS_ONE)), "f"(u64_to_double(DP_POS_ONE)));
    TEST("FEQ 1==1", result, 1);

    __asm__ volatile("feq.d %0, %1, %2"
                     : "=r"(result)
                     : "f"(u64_to_double(DP_POS_ONE)), "f"(u64_to_double(DP_POS_TWO)));
    TEST("FEQ 1==2", result, 0);

    __asm__ volatile("feq.d %0, %1, %2"
                     : "=r"(result)
                     : "f"(u64_to_double(DP_POS_ZERO)), "f"(u64_to_double(DP_NEG_ZERO)));
    TEST("FEQ +0==-0", result, 1);

    __asm__ volatile("feq.d %0, %1, %2"
                     : "=r"(result)
                     : "f"(u64_to_double(DP_QNAN)), "f"(u64_to_double(DP_QNAN)));
    TEST("FEQ NaN==NaN", result, 0);

    __asm__ volatile("flt.d %0, %1, %2"
                     : "=r"(result)
                     : "f"(u64_to_double(DP_POS_ONE)), "f"(u64_to_double(DP_POS_TWO)));
    TEST("FLT 1<2", result, 1);

    __asm__ volatile("flt.d %0, %1, %2"
                     : "=r"(result)
                     : "f"(u64_to_double(DP_POS_TWO)), "f"(u64_to_double(DP_POS_ONE)));
    TEST("FLT 2<1", result, 0);

    __asm__ volatile("flt.d %0, %1, %2"
                     : "=r"(result)
                     : "f"(u64_to_double(DP_NEG_ONE)), "f"(u64_to_double(DP_POS_ONE)));
    TEST("FLT -1<1", result, 1);

    __asm__ volatile("flt.d %0, %1, %2"
                     : "=r"(result)
                     : "f"(u64_to_double(DP_NEG_INF)), "f"(u64_to_double(DP_POS_INF)));
    TEST("FLT -inf<+inf", result, 1);

    __asm__ volatile("fle.d %0, %1, %2"
                     : "=r"(result)
                     : "f"(u64_to_double(DP_POS_ONE)), "f"(u64_to_double(DP_POS_ONE)));
    TEST("FLE 1<=1", result, 1);

    __asm__ volatile("fle.d %0, %1, %2"
                     : "=r"(result)
                     : "f"(u64_to_double(DP_POS_ONE)), "f"(u64_to_double(DP_POS_TWO)));
    TEST("FLE 1<=2", result, 1);

    __asm__ volatile("fle.d %0, %1, %2"
                     : "=r"(result)
                     : "f"(u64_to_double(DP_POS_TWO)), "f"(u64_to_double(DP_POS_ONE)));
    TEST("FLE 2<=1", result, 0);

    /* ===================================================================== */
    /* FMIN.D / FMAX.D - Minimum and Maximum                                 */
    /* ===================================================================== */

    __asm__ volatile("fmin.d %0, %1, %2"
                     : "=f"(dresult)
                     : "f"(u64_to_double(DP_POS_ONE)), "f"(u64_to_double(DP_POS_TWO)));
    TEST64("FMIN 1,2", double_to_u64(dresult), DP_POS_ONE);

    __asm__ volatile("fmin.d %0, %1, %2"
                     : "=f"(dresult)
                     : "f"(u64_to_double(DP_NEG_ONE)), "f"(u64_to_double(DP_POS_ONE)));
    TEST64("FMIN -1,1", double_to_u64(dresult), DP_NEG_ONE);

    __asm__ volatile("fmin.d %0, %1, %2"
                     : "=f"(dresult)
                     : "f"(u64_to_double(DP_POS_ZERO)), "f"(u64_to_double(DP_NEG_ZERO)));
    TEST64("FMIN +0,-0", double_to_u64(dresult), DP_NEG_ZERO);

    __asm__ volatile("fmax.d %0, %1, %2"
                     : "=f"(dresult)
                     : "f"(u64_to_double(DP_POS_ONE)), "f"(u64_to_double(DP_POS_TWO)));
    TEST64("FMAX 1,2", double_to_u64(dresult), DP_POS_TWO);

    __asm__ volatile("fmax.d %0, %1, %2"
                     : "=f"(dresult)
                     : "f"(u64_to_double(DP_NEG_ONE)), "f"(u64_to_double(DP_POS_ONE)));
    TEST64("FMAX -1,1", double_to_u64(dresult), DP_POS_ONE);

    __asm__ volatile("fmax.d %0, %1, %2"
                     : "=f"(dresult)
                     : "f"(u64_to_double(DP_POS_ZERO)), "f"(u64_to_double(DP_NEG_ZERO)));
    TEST64("FMAX +0,-0", double_to_u64(dresult), DP_POS_ZERO);

    __asm__ volatile("fmin.d %0, %1, %2"
                     : "=f"(dresult)
                     : "f"(u64_to_double(DP_POS_ONE)), "f"(u64_to_double(DP_QNAN)));
    TEST64("FMIN 1,NaN", double_to_u64(dresult), DP_POS_ONE);

    __asm__ volatile("fmax.d %0, %1, %2"
                     : "=f"(dresult)
                     : "f"(u64_to_double(DP_QNAN)), "f"(u64_to_double(DP_POS_TWO)));
    TEST64("FMAX NaN,2", double_to_u64(dresult), DP_POS_TWO);

    /* ===================================================================== */
    /* FCVT.W.D / FCVT.WU.D - Double to Integer Conversion                   */
    /* ===================================================================== */

    __asm__ volatile("fcvt.w.d %0, %1, rtz" : "=r"(result) : "f"(u64_to_double(DP_POS_ONE)));
    TEST("FCVT.W.D 1.0", result, 1);

    __asm__ volatile("fcvt.w.d %0, %1, rtz" : "=r"(result) : "f"(u64_to_double(DP_NEG_ONE)));
    TEST("FCVT.W.D -1.0", result, (uint32_t) -1);

    __asm__ volatile("fcvt.w.d %0, %1, rtz" : "=r"(result) : "f"(u64_to_double(DP_PI)));
    TEST("FCVT.W.D pi->3", result, 3);

    __asm__ volatile("fcvt.w.d %0, %1, rtz" : "=r"(result) : "f"(u64_to_double(DP_POS_INF)));
    TEST("FCVT.W.D +inf", result, 0x7FFFFFFF);

    __asm__ volatile("fcvt.w.d %0, %1, rtz" : "=r"(result) : "f"(u64_to_double(DP_NEG_INF)));
    TEST("FCVT.W.D -inf", result, 0x80000000);

    __asm__ volatile("fcvt.w.d %0, %1, rtz" : "=r"(result) : "f"(u64_to_double(DP_QNAN)));
    TEST("FCVT.W.D NaN", result, 0x7FFFFFFF);

    __asm__ volatile("fcvt.wu.d %0, %1, rtz" : "=r"(result) : "f"(u64_to_double(DP_POS_ONE)));
    TEST("FCVT.WU.D 1.0", result, 1);

    __asm__ volatile("fcvt.wu.d %0, %1, rtz" : "=r"(result) : "f"(u64_to_double(DP_POS_TWO)));
    TEST("FCVT.WU.D 2.0", result, 2);

    __asm__ volatile("fcvt.wu.d %0, %1, rtz" : "=r"(result) : "f"(u64_to_double(DP_NEG_ONE)));
    TEST("FCVT.WU.D -1.0", result, 0);

    /* ===================================================================== */
    /* FCVT.D.W / FCVT.D.WU - Integer to Double Conversion                   */
    /* ===================================================================== */

    __asm__ volatile("fcvt.d.w %0, %1" : "=f"(dresult) : "r"(1));
    TEST64("FCVT.D.W 1", double_to_u64(dresult), DP_POS_ONE);

    __asm__ volatile("fcvt.d.w %0, %1" : "=f"(dresult) : "r"(-1));
    TEST64("FCVT.D.W -1", double_to_u64(dresult), DP_NEG_ONE);

    __asm__ volatile("fcvt.d.w %0, %1" : "=f"(dresult) : "r"(0));
    TEST64("FCVT.D.W 0", double_to_u64(dresult), DP_POS_ZERO);

    __asm__ volatile("fcvt.d.wu %0, %1" : "=f"(dresult) : "r"(1U));
    TEST64("FCVT.D.WU 1", double_to_u64(dresult), DP_POS_ONE);

    __asm__ volatile("fcvt.d.wu %0, %1" : "=f"(dresult) : "r"(2U));
    TEST64("FCVT.D.WU 2", double_to_u64(dresult), DP_POS_TWO);

    /* ===================================================================== */
    /* FCVT.S.D / FCVT.D.S - Convert between single and double               */
    /* ===================================================================== */

    fp_test_mem_d[0] = u64_to_double(DP_POS_ONE);
    __asm__ volatile("fld ft0, 0(%1)\n\t"
                     "fcvt.s.d ft1, ft0\n\t"
                     "fmv.x.w %0, ft1"
                     : "=r"(result)
                     : "r"(&fp_test_mem_d[0])
                     : "ft0", "ft1", "memory");
    TEST("FCVT.S.D 1", result, FP_POS_ONE);

    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fcvt.d.s ft1, ft0\n\t"
                     "fsd ft1, 0(%0)"
                     :
                     : "r"(&fp_test_mem_d[1]), "r"(FP_POS_ONE)
                     : "ft0", "ft1", "memory");
    result64 = double_to_u64(fp_test_mem_d[1]);
    TEST64("FCVT.D.S 1", result64, DP_POS_ONE);

    /* ===================================================================== */
    /* FADD.D / FSUB.D - Floating-Point Addition and Subtraction             */
    /* ===================================================================== */

    __asm__ volatile("fadd.d %0, %1, %2"
                     : "=f"(dresult)
                     : "f"(u64_to_double(DP_POS_ONE)), "f"(u64_to_double(DP_POS_ONE)));
    TEST64("FADD 1+1=2", double_to_u64(dresult), DP_POS_TWO);

    __asm__ volatile("fadd.d %0, %1, %2"
                     : "=f"(dresult)
                     : "f"(u64_to_double(DP_POS_ONE)), "f"(u64_to_double(DP_NEG_ONE)));
    TEST64("FADD 1+(-1)=0", double_to_u64(dresult), DP_POS_ZERO);

    __asm__ volatile("fadd.d %0, %1, %2"
                     : "=f"(dresult)
                     : "f"(u64_to_double(DP_POS_ZERO)), "f"(u64_to_double(DP_NEG_ZERO)));
    TEST64("FADD +0+(-0)=+0", double_to_u64(dresult), DP_POS_ZERO);

    __asm__ volatile("fadd.d %0, %1, %2"
                     : "=f"(dresult)
                     : "f"(u64_to_double(DP_POS_ONE)), "f"(u64_to_double(DP_POS_INF)));
    TEST64("FADD 1+inf=inf", double_to_u64(dresult), DP_POS_INF);

    __asm__ volatile("fsub.d %0, %1, %2"
                     : "=f"(dresult)
                     : "f"(u64_to_double(DP_POS_TWO)), "f"(u64_to_double(DP_POS_ONE)));
    TEST64("FSUB 2-1=1", double_to_u64(dresult), DP_POS_ONE);

    __asm__ volatile("fsub.d %0, %1, %2"
                     : "=f"(dresult)
                     : "f"(u64_to_double(DP_POS_ONE)), "f"(u64_to_double(DP_POS_TWO)));
    TEST64("FSUB 1-2=-1", double_to_u64(dresult), DP_NEG_ONE);

    __asm__ volatile("fsub.d %0, %1, %2"
                     : "=f"(dresult)
                     : "f"(u64_to_double(DP_POS_ONE)), "f"(u64_to_double(DP_POS_ONE)));
    TEST64("FSUB 1-1=0", double_to_u64(dresult), DP_POS_ZERO);

    /* ===================================================================== */
    /* FMUL.D - Floating-Point Multiplication                                */
    /* ===================================================================== */

    __asm__ volatile("fmul.d %0, %1, %2"
                     : "=f"(dresult)
                     : "f"(u64_to_double(DP_POS_TWO)), "f"(u64_to_double(DP_POS_TWO)));
    TEST64("FMUL 2*2=4", double_to_u64(dresult), DP_POS_FOUR);

    __asm__ volatile("fmul.d %0, %1, %2"
                     : "=f"(dresult)
                     : "f"(u64_to_double(DP_POS_TWO)), "f"(u64_to_double(DP_POS_HALF)));
    TEST64("FMUL 2*0.5=1", double_to_u64(dresult), DP_POS_ONE);

    __asm__ volatile("fmul.d %0, %1, %2"
                     : "=f"(dresult)
                     : "f"(u64_to_double(DP_NEG_ONE)), "f"(u64_to_double(DP_NEG_ONE)));
    TEST64("FMUL -1*-1=1", double_to_u64(dresult), DP_POS_ONE);

    __asm__ volatile("fmul.d %0, %1, %2"
                     : "=f"(dresult)
                     : "f"(u64_to_double(DP_POS_ONE)), "f"(u64_to_double(DP_NEG_ONE)));
    TEST64("FMUL 1*-1=-1", double_to_u64(dresult), DP_NEG_ONE);

    __asm__ volatile("fmul.d %0, %1, %2"
                     : "=f"(dresult)
                     : "f"(u64_to_double(DP_POS_ONE)), "f"(u64_to_double(DP_POS_ZERO)));
    TEST64("FMUL 1*0=0", double_to_u64(dresult), DP_POS_ZERO);

    /* ===================================================================== */
    /* FDIV.D - Floating-Point Division                                      */
    /* ===================================================================== */

    __asm__ volatile("fdiv.d %0, %1, %2"
                     : "=f"(dresult)
                     : "f"(u64_to_double(DP_POS_FOUR)), "f"(u64_to_double(DP_POS_TWO)));
    TEST64("FDIV 4/2=2", double_to_u64(dresult), DP_POS_TWO);

    __asm__ volatile("fdiv.d %0, %1, %2"
                     : "=f"(dresult)
                     : "f"(u64_to_double(DP_POS_ONE)), "f"(u64_to_double(DP_POS_TWO)));
    TEST64("FDIV 1/2=0.5", double_to_u64(dresult), DP_POS_HALF);

    __asm__ volatile("fdiv.d %0, %1, %2"
                     : "=f"(dresult)
                     : "f"(u64_to_double(DP_NEG_ONE)), "f"(u64_to_double(DP_POS_ONE)));
    TEST64("FDIV -1/1=-1", double_to_u64(dresult), DP_NEG_ONE);

    __asm__ volatile("fdiv.d %0, %1, %2"
                     : "=f"(dresult)
                     : "f"(u64_to_double(DP_POS_ONE)), "f"(u64_to_double(DP_POS_ZERO)));
    TEST64("FDIV 1/0=+inf", double_to_u64(dresult), DP_POS_INF);

    __asm__ volatile("fdiv.d %0, %1, %2"
                     : "=f"(dresult)
                     : "f"(u64_to_double(DP_NEG_ONE)), "f"(u64_to_double(DP_POS_ZERO)));
    TEST64("FDIV -1/0=-inf", double_to_u64(dresult), DP_NEG_INF);

    __asm__ volatile("fdiv.d %0, %1, %2"
                     : "=f"(dresult)
                     : "f"(u64_to_double(DP_POS_ZERO)), "f"(u64_to_double(DP_POS_ZERO)));
    TEST64("FDIV 0/0=NaN", double_to_u64(dresult), DP_QNAN);

    /* ===================================================================== */
    /* FSQRT.D - Floating-Point Square Root                                  */
    /* ===================================================================== */

    __asm__ volatile("fsqrt.d %0, %1" : "=f"(dresult) : "f"(u64_to_double(DP_POS_FOUR)));
    TEST64("FSQRT 4=2", double_to_u64(dresult), DP_POS_TWO);

    __asm__ volatile("fsqrt.d %0, %1" : "=f"(dresult) : "f"(u64_to_double(DP_POS_ONE)));
    TEST64("FSQRT 1=1", double_to_u64(dresult), DP_POS_ONE);

    __asm__ volatile("fsqrt.d %0, %1" : "=f"(dresult) : "f"(u64_to_double(DP_POS_ZERO)));
    TEST64("FSQRT +0=+0", double_to_u64(dresult), DP_POS_ZERO);

    __asm__ volatile("fsqrt.d %0, %1" : "=f"(dresult) : "f"(u64_to_double(DP_NEG_ZERO)));
    TEST64("FSQRT -0=-0", double_to_u64(dresult), DP_NEG_ZERO);

    __asm__ volatile("fsqrt.d %0, %1" : "=f"(dresult) : "f"(u64_to_double(DP_POS_INF)));
    TEST64("FSQRT +inf=+inf", double_to_u64(dresult), DP_POS_INF);

    __asm__ volatile("fsqrt.d %0, %1" : "=f"(dresult) : "f"(u64_to_double(DP_NEG_ONE)));
    TEST64("FSQRT -1=NaN", double_to_u64(dresult), DP_QNAN);

    /* ===================================================================== */
    /* FMADD.D / FMSUB.D / FNMADD.D / FNMSUB.D - Fused Multiply-Add          */
    /* ===================================================================== */

    __asm__ volatile("fmadd.d %0, %1, %2, %3"
                     : "=f"(dresult)
                     : "f"(u64_to_double(DP_POS_TWO)),
                       "f"(u64_to_double(DP_POS_TWO)),
                       "f"(u64_to_double(DP_POS_ONE)));
    TEST64("FMADD 2*2+1=5", double_to_u64(dresult), 0x4014000000000000ull);

    __asm__ volatile("fmadd.d %0, %1, %2, %3"
                     : "=f"(dresult)
                     : "f"(u64_to_double(DP_POS_ONE)),
                       "f"(u64_to_double(DP_POS_ONE)),
                       "f"(u64_to_double(DP_POS_ONE)));
    TEST64("FMADD 1*1+1=2", double_to_u64(dresult), DP_POS_TWO);

    __asm__ volatile("fmsub.d %0, %1, %2, %3"
                     : "=f"(dresult)
                     : "f"(u64_to_double(DP_POS_TWO)),
                       "f"(u64_to_double(DP_POS_TWO)),
                       "f"(u64_to_double(DP_POS_ONE)));
    TEST64("FMSUB 2*2-1=3", double_to_u64(dresult), DP_POS_THREE);

    __asm__ volatile("fmsub.d %0, %1, %2, %3"
                     : "=f"(dresult)
                     : "f"(u64_to_double(DP_POS_ONE)),
                       "f"(u64_to_double(DP_POS_ONE)),
                       "f"(u64_to_double(DP_POS_ONE)));
    TEST64("FMSUB 1*1-1=0", double_to_u64(dresult), DP_POS_ZERO);

    __asm__ volatile("fnmadd.d %0, %1, %2, %3"
                     : "=f"(dresult)
                     : "f"(u64_to_double(DP_POS_ONE)),
                       "f"(u64_to_double(DP_POS_ONE)),
                       "f"(u64_to_double(DP_POS_ONE)));
    TEST64("FNMADD -(1*1)-1=-2", double_to_u64(dresult), 0xC000000000000000ull);

    __asm__ volatile("fnmsub.d %0, %1, %2, %3"
                     : "=f"(dresult)
                     : "f"(u64_to_double(DP_POS_ONE)),
                       "f"(u64_to_double(DP_POS_ONE)),
                       "f"(u64_to_double(DP_POS_TWO)));
    TEST64("FNMSUB -(1*1)+2=1", double_to_u64(dresult), DP_POS_ONE);

    __asm__ volatile("fnmsub.d %0, %1, %2, %3"
                     : "=f"(dresult)
                     : "f"(u64_to_double(DP_POS_TWO)),
                       "f"(u64_to_double(DP_POS_TWO)),
                       "f"(u64_to_double(DP_POS_ONE)));
    TEST64("FNMSUB -(2*2)+1=-3", double_to_u64(dresult), 0xC008000000000000ull);

    /* ===================================================================== */
    /* FP CSR Tests - fflags, frm, fcsr                                      */
    /* ===================================================================== */

    __asm__ volatile("csrw fflags, zero");

    __asm__ volatile("fsqrt.d %0, %1" : "=f"(dresult) : "f"(u64_to_double(DP_NEG_ONE)));
    __asm__ volatile("csrr %0, fflags" : "=r"(result));
    TEST("fflags NV set", (result & 0x10) != 0, 1);

    __asm__ volatile("csrw fflags, zero");

    __asm__ volatile("fdiv.d %0, %1, %2"
                     : "=f"(dresult)
                     : "f"(u64_to_double(DP_POS_ONE)), "f"(u64_to_double(DP_POS_ZERO)));
    __asm__ volatile("csrr %0, fflags" : "=r"(result));
    TEST("fflags DZ set", (result & 0x08) != 0, 1);

    __asm__ volatile("csrw frm, %0" ::"r"(0));
    __asm__ volatile("csrr %0, frm" : "=r"(result));
    TEST("frm RNE", result, 0);

    __asm__ volatile("csrw frm, %0" ::"r"(1));
    __asm__ volatile("csrr %0, frm" : "=r"(result));
    TEST("frm RTZ", result, 1);

    __asm__ volatile("csrw frm, %0" ::"r"(2));
    __asm__ volatile("csrr %0, frm" : "=r"(result));
    TEST("frm RDN", result, 2);

    __asm__ volatile("csrw frm, %0" ::"r"(3));
    __asm__ volatile("csrr %0, frm" : "=r"(result));
    TEST("frm RUP", result, 3);

    __asm__ volatile("csrw frm, %0" ::"r"(4));
    __asm__ volatile("csrr %0, frm" : "=r"(result));
    TEST("frm RMM", result, 4);

    __asm__ volatile("csrw frm, zero");

    __asm__ volatile("csrw fcsr, %0" ::"r"(0x00));
    __asm__ volatile("csrr %0, fcsr" : "=r"(result));
    TEST("fcsr clear", result, 0);

    __asm__ volatile("csrw fcsr, %0" ::"r"(0xFF));
    __asm__ volatile("csrr %0, fcsr" : "=r"(result));
    TEST("fcsr mask", result, 0xFF);

    __asm__ volatile("csrw fcsr, zero");

    END_EXTENSION();
}

/* ========================================================================== */
/* Zicsr Tests (CSR Instructions)                                             */
/* ========================================================================== */

static void test_zicsr(void)
{
    BEGIN_EXTENSION(EXT_ZICSR);

    uint32_t result1, result2;

    /* CSRR (pseudo-instruction for CSRRS with rs1=x0): read CSR */
    __asm__ volatile("csrr %0, cycle" : "=r"(result1));
    __asm__ volatile("csrr %0, cycle" : "=r"(result2));
    /* Cycle counter should advance between reads */
    TEST("CSRR cycle (advancing)", (result2 > result1) ? 1 : 0, 1);

    /* CSRRS: read and set bits (we can only test read on read-only counters) */
    __asm__ volatile("csrrs %0, cycle, x0" : "=r"(result1));
    TEST("CSRRS (read)", (result1 > 0) ? 1 : 0, 1);

    /* CSRRC: read and clear bits (test read portion) */
    __asm__ volatile("csrrc %0, cycle, x0" : "=r"(result1));
    TEST("CSRRC (read)", (result1 > 0) ? 1 : 0, 1);

    /* Note: We can't fully test CSRRW/CSRRS/CSRRC write behavior on read-only counters
     * A full test would require access to writable CSRs (machine mode) */

    END_EXTENSION();
}

/* ========================================================================== */
/* Zicntr Tests (Counter Instructions)                                        */
/* ========================================================================== */

static void test_zicntr(void)
{
    BEGIN_EXTENSION(EXT_ZICNTR);

    uint32_t result1, result2;
    uint64_t result64;

    /* RDCYCLE: read cycle counter low */
    __asm__ volatile("rdcycle %0" : "=r"(result1));
    __asm__ volatile("rdcycle %0" : "=r"(result2));
    TEST("RDCYCLE (advancing)", (result2 > result1) ? 1 : 0, 1);

    /* RDCYCLEH: read cycle counter high */
    __asm__ volatile("rdcycleh %0" : "=r"(result1));
    TEST("RDCYCLEH (readable)", 1, 1); /* Just verify it doesn't crash */

    /* RDTIME: read time counter low (aliased to cycle on Frost) */
    __asm__ volatile("rdtime %0" : "=r"(result1));
    __asm__ volatile("rdtime %0" : "=r"(result2));
    TEST("RDTIME (advancing)", (result2 > result1) ? 1 : 0, 1);

    /* RDTIMEH: read time counter high */
    __asm__ volatile("rdtimeh %0" : "=r"(result1));
    TEST("RDTIMEH (readable)", 1, 1);

    /* RDINSTRET: read instructions retired counter low */
    __asm__ volatile("rdinstret %0" : "=r"(result1));
    __asm__ volatile("nop\n nop\n nop\n nop\n rdinstret %0" : "=r"(result2));
    TEST("RDINSTRET (advancing)", (result2 > result1) ? 1 : 0, 1);

    /* RDINSTRETH: read instructions retired counter high */
    __asm__ volatile("rdinstreth %0" : "=r"(result1));
    TEST("RDINSTRETH (readable)", 1, 1);

    /* Test 64-bit counter read (using library function) */
    result64 = rdcycle64();
    TEST("rdcycle64 (non-zero)", (result64 > 0) ? 1 : 0, 1);

    END_EXTENSION();
}

/* ========================================================================== */
/* Zifencei Tests (Instruction Fence)                                         */
/* ========================================================================== */

static void test_zifencei(void)
{
    BEGIN_EXTENSION(EXT_ZIFENCEI);

    /* FENCE.I: instruction fetch fence
     * On Frost with no I-cache, this is a NOP but should execute without error */
    __asm__ volatile("fence.i" ::: "memory");
    TEST_NO_CRASH("FENCE.I");

    END_EXTENSION();
}

/* ========================================================================== */
/* Zba Tests (Address Generation)                                             */
/* ========================================================================== */

static void test_zba(void)
{
    BEGIN_EXTENSION(EXT_ZBA);

    uint32_t result;

    /* ===== SH1ADD: rd = rs2 + (rs1 << 1) ===== */
    __asm__ volatile("sh1add %0, %1, %2" : "=r"(result) : "r"(10), "r"(100));
    TEST("SH1ADD basic", result, 120); /* 100 + (10 << 1) = 100 + 20 = 120 */
    __asm__ volatile("sh1add %0, %1, %2" : "=r"(result) : "r"(0), "r"(100));
    TEST("SH1ADD rs1=0", result, 100);
    __asm__ volatile("sh1add %0, %1, %2" : "=r"(result) : "r"(10), "r"(0));
    TEST("SH1ADD rs2=0", result, 20);
    __asm__ volatile("sh1add %0, %1, %2" : "=r"(result) : "r"(0x40000000), "r"(0));
    TEST("SH1ADD large", result, 0x80000000);
    __asm__ volatile("sh1add %0, %1, %2" : "=r"(result) : "r"(0x80000000), "r"(0));
    TEST("SH1ADD ovf", result, 0); /* Overflow wraps */
    __asm__ volatile("sh1add %0, %1, %2" : "=r"(result) : "r"(0xFFFFFFFF), "r"(0xFFFFFFFF));
    TEST("SH1ADD MAX", result, 0xFFFFFFFD); /* -1 + (-2) = -3 */

    /* ===== SH2ADD: rd = rs2 + (rs1 << 2) ===== */
    __asm__ volatile("sh2add %0, %1, %2" : "=r"(result) : "r"(10), "r"(100));
    TEST("SH2ADD basic", result, 140); /* 100 + (10 << 2) = 100 + 40 = 140 */
    __asm__ volatile("sh2add %0, %1, %2" : "=r"(result) : "r"(0), "r"(100));
    TEST("SH2ADD rs1=0", result, 100);
    __asm__ volatile("sh2add %0, %1, %2" : "=r"(result) : "r"(0x20000000), "r"(0));
    TEST("SH2ADD large", result, 0x80000000);
    __asm__ volatile("sh2add %0, %1, %2" : "=r"(result) : "r"(0x40000000), "r"(0));
    TEST("SH2ADD ovf", result, 0);

    /* ===== SH3ADD: rd = rs2 + (rs1 << 3) ===== */
    __asm__ volatile("sh3add %0, %1, %2" : "=r"(result) : "r"(10), "r"(100));
    TEST("SH3ADD basic", result, 180); /* 100 + (10 << 3) = 100 + 80 = 180 */
    __asm__ volatile("sh3add %0, %1, %2" : "=r"(result) : "r"(0), "r"(100));
    TEST("SH3ADD rs1=0", result, 100);
    __asm__ volatile("sh3add %0, %1, %2" : "=r"(result) : "r"(0x10000000), "r"(0));
    TEST("SH3ADD large", result, 0x80000000);
    __asm__ volatile("sh3add %0, %1, %2" : "=r"(result) : "r"(0x20000000), "r"(0));
    TEST("SH3ADD ovf", result, 0);

    END_EXTENSION();
}

/* ========================================================================== */
/* Zbb Tests (Basic Bit Manipulation)                                         */
/* ========================================================================== */

static void test_zbb(void)
{
    BEGIN_EXTENSION(EXT_ZBB);

    uint32_t result;
    int32_t signed_result;

    /* ===== CLZ: count leading zeros ===== */
    __asm__ volatile("clz %0, %1" : "=r"(result) : "r"(0x00100000));
    TEST("CLZ basic", result, 11);
    __asm__ volatile("clz %0, %1" : "=r"(result) : "r"(0x80000000));
    TEST("CLZ MSB", result, 0);
    __asm__ volatile("clz %0, %1" : "=r"(result) : "r"(0));
    TEST("CLZ zero", result, 32);
    __asm__ volatile("clz %0, %1" : "=r"(result) : "r"(1));
    TEST("CLZ 1", result, 31);
    __asm__ volatile("clz %0, %1" : "=r"(result) : "r"(0xFFFFFFFF));
    TEST("CLZ MAX", result, 0);

    /* ===== CTZ: count trailing zeros ===== */
    __asm__ volatile("ctz %0, %1" : "=r"(result) : "r"(0x00100000));
    TEST("CTZ basic", result, 20);
    __asm__ volatile("ctz %0, %1" : "=r"(result) : "r"(1));
    TEST("CTZ LSB", result, 0);
    __asm__ volatile("ctz %0, %1" : "=r"(result) : "r"(0));
    TEST("CTZ zero", result, 32);
    __asm__ volatile("ctz %0, %1" : "=r"(result) : "r"(0x80000000));
    TEST("CTZ MSB", result, 31);
    __asm__ volatile("ctz %0, %1" : "=r"(result) : "r"(0xFFFFFFFF));
    TEST("CTZ MAX", result, 0);

    /* ===== CPOP: count set bits ===== */
    __asm__ volatile("cpop %0, %1" : "=r"(result) : "r"(0xFF00FF00));
    TEST("CPOP basic", result, 16);
    __asm__ volatile("cpop %0, %1" : "=r"(result) : "r"(0xFFFFFFFF));
    TEST("CPOP all 1", result, 32);
    __asm__ volatile("cpop %0, %1" : "=r"(result) : "r"(0));
    TEST("CPOP zero", result, 0);
    __asm__ volatile("cpop %0, %1" : "=r"(result) : "r"(1));
    TEST("CPOP 1", result, 1);
    __asm__ volatile("cpop %0, %1" : "=r"(result) : "r"(0x55555555));
    TEST("CPOP alt", result, 16);

    /* ===== MIN: signed minimum ===== */
    __asm__ volatile("min %0, %1, %2" : "=r"(signed_result) : "r"(10), "r"(20));
    TEST("MIN basic", signed_result, 10);
    __asm__ volatile("min %0, %1, %2" : "=r"(signed_result) : "r"(-10), "r"(10));
    TEST("MIN signed", signed_result, -10);
    __asm__ volatile("min %0, %1, %2" : "=r"(signed_result) : "r"(0x80000000), "r"(0x7FFFFFFF));
    TEST("MIN boundaries", signed_result, (int32_t) 0x80000000);
    __asm__ volatile("min %0, %1, %2" : "=r"(signed_result) : "r"(5), "r"(5));
    TEST("MIN equal", signed_result, 5);

    /* ===== MAX: signed maximum ===== */
    __asm__ volatile("max %0, %1, %2" : "=r"(signed_result) : "r"(10), "r"(20));
    TEST("MAX basic", signed_result, 20);
    __asm__ volatile("max %0, %1, %2" : "=r"(signed_result) : "r"(-10), "r"(10));
    TEST("MAX signed", signed_result, 10);
    __asm__ volatile("max %0, %1, %2" : "=r"(signed_result) : "r"(0x80000000), "r"(0x7FFFFFFF));
    TEST("MAX boundaries", signed_result, 0x7FFFFFFF);
    __asm__ volatile("max %0, %1, %2" : "=r"(signed_result) : "r"(5), "r"(5));
    TEST("MAX equal", signed_result, 5);

    /* ===== MINU: unsigned minimum ===== */
    __asm__ volatile("minu %0, %1, %2" : "=r"(result) : "r"(10), "r"(0xFFFFFFFF));
    TEST("MINU basic", result, 10);
    __asm__ volatile("minu %0, %1, %2" : "=r"(result) : "r"(0x80000000), "r"(0x7FFFFFFF));
    TEST("MINU bndry", result, 0x7FFFFFFF); /* 0x7FFFFFFF < 0x80000000 unsigned */
    __asm__ volatile("minu %0, %1, %2" : "=r"(result) : "r"(0), "r"(0xFFFFFFFF));
    TEST("MINU 0", result, 0);

    /* ===== MAXU: unsigned maximum ===== */
    __asm__ volatile("maxu %0, %1, %2" : "=r"(result) : "r"(10), "r"(0xFFFFFFFF));
    TEST("MAXU basic", result, 0xFFFFFFFF);
    __asm__ volatile("maxu %0, %1, %2" : "=r"(result) : "r"(0x80000000), "r"(0x7FFFFFFF));
    TEST("MAXU bndry", result, 0x80000000);
    __asm__ volatile("maxu %0, %1, %2" : "=r"(result) : "r"(0), "r"(1));
    TEST("MAXU 0vs1", result, 1);

    /* ===== SEXT.B: sign-extend byte ===== */
    __asm__ volatile("sext.b %0, %1" : "=r"(signed_result) : "r"(0x0000007F));
    TEST("SEXT.B pos", signed_result, 0x7F);
    __asm__ volatile("sext.b %0, %1" : "=r"(signed_result) : "r"(0x00000080));
    TEST("SEXT.B neg", signed_result, (int32_t) 0xFFFFFF80);
    __asm__ volatile("sext.b %0, %1" : "=r"(signed_result) : "r"(0x12345600));
    TEST("SEXT.B 0", signed_result, 0);
    __asm__ volatile("sext.b %0, %1" : "=r"(signed_result) : "r"(0xFFFFFFFF));
    TEST("SEXT.B FF", signed_result, -1);

    /* ===== SEXT.H: sign-extend halfword ===== */
    __asm__ volatile("sext.h %0, %1" : "=r"(signed_result) : "r"(0x00007FFF));
    TEST("SEXT.H pos", signed_result, 0x7FFF);
    __asm__ volatile("sext.h %0, %1" : "=r"(signed_result) : "r"(0x00008000));
    TEST("SEXT.H neg", signed_result, (int32_t) 0xFFFF8000);
    __asm__ volatile("sext.h %0, %1" : "=r"(signed_result) : "r"(0x12340000));
    TEST("SEXT.H 0", signed_result, 0);

    /* ===== ZEXT.H: zero-extend halfword ===== */
    __asm__ volatile("zext.h %0, %1" : "=r"(result) : "r"(0xFFFF8000));
    TEST("ZEXT.H basic", result, 0x00008000);
    __asm__ volatile("zext.h %0, %1" : "=r"(result) : "r"(0xFFFFFFFF));
    TEST("ZEXT.H MAX", result, 0x0000FFFF);
    __asm__ volatile("zext.h %0, %1" : "=r"(result) : "r"(0x00007FFF));
    TEST("ZEXT.H pos", result, 0x00007FFF);

    /* ===== ROL: rotate left ===== */
    __asm__ volatile("rol %0, %1, %2" : "=r"(result) : "r"(0x80000001), "r"(1));
    TEST("ROL 1", result, 0x00000003);
    __asm__ volatile("rol %0, %1, %2" : "=r"(result) : "r"(0x12345678), "r"(8));
    TEST("ROL 8", result, 0x34567812);
    __asm__ volatile("rol %0, %1, %2" : "=r"(result) : "r"(0x12345678), "r"(0));
    TEST("ROL 0", result, 0x12345678);
    __asm__ volatile("rol %0, %1, %2" : "=r"(result) : "r"(0x12345678), "r"(32));
    TEST("ROL 32", result, 0x12345678); /* 32 % 32 = 0 */
    __asm__ volatile("rol %0, %1, %2" : "=r"(result) : "r"(0x12345678), "r"(16));
    TEST("ROL 16", result, 0x56781234);

    /* ===== ROR: rotate right ===== */
    __asm__ volatile("ror %0, %1, %2" : "=r"(result) : "r"(0x80000001), "r"(1));
    TEST("ROR 1", result, 0xC0000000);
    __asm__ volatile("ror %0, %1, %2" : "=r"(result) : "r"(0x12345678), "r"(8));
    TEST("ROR 8", result, 0x78123456);
    __asm__ volatile("ror %0, %1, %2" : "=r"(result) : "r"(0x12345678), "r"(0));
    TEST("ROR 0", result, 0x12345678);
    __asm__ volatile("ror %0, %1, %2" : "=r"(result) : "r"(0x12345678), "r"(32));
    TEST("ROR 32", result, 0x12345678);

    /* ===== RORI: rotate right immediate ===== */
    __asm__ volatile("rori %0, %1, 4" : "=r"(result) : "r"(0x12345678));
    TEST("RORI 4", result, 0x81234567);
    __asm__ volatile("rori %0, %1, 0" : "=r"(result) : "r"(0x12345678));
    TEST("RORI 0", result, 0x12345678);
    __asm__ volatile("rori %0, %1, 31" : "=r"(result) : "r"(0x80000000));
    TEST("RORI 31", result, 0x00000001);

    /* ===== ORC.B: or-combine bytes ===== */
    __asm__ volatile("orc.b %0, %1" : "=r"(result) : "r"(0x01020408));
    TEST("ORC.B all", result, 0xFFFFFFFF);
    __asm__ volatile("orc.b %0, %1" : "=r"(result) : "r"(0x00FF0000));
    TEST("ORC.B part", result, 0x00FF0000);
    __asm__ volatile("orc.b %0, %1" : "=r"(result) : "r"(0));
    TEST("ORC.B 0", result, 0);

    /* ===== REV8: byte-reverse ===== */
    __asm__ volatile("rev8 %0, %1" : "=r"(result) : "r"(0x12345678));
    TEST("REV8 basic", result, 0x78563412);
    __asm__ volatile("rev8 %0, %1" : "=r"(result) : "r"(0xDEADBEEF));
    TEST("REV8 2", result, 0xEFBEADDE);
    __asm__ volatile("rev8 %0, %1" : "=r"(result) : "r"(0));
    TEST("REV8 0", result, 0);
    __asm__ volatile("rev8 %0, %1" : "=r"(result) : "r"(0xFF000000));
    TEST("REV8 high", result, 0x000000FF);

    /* ===== ANDN: rd = rs1 & ~rs2 ===== */
    __asm__ volatile("andn %0, %1, %2" : "=r"(result) : "r"(0xFFFFFFFF), "r"(0x0F0F0F0F));
    TEST("ANDN basic", result, 0xF0F0F0F0);
    __asm__ volatile("andn %0, %1, %2" : "=r"(result) : "r"(0xFFFFFFFF), "r"(0xFFFFFFFF));
    TEST("ANDN all", result, 0);

    /* ===== ORN: rd = rs1 | ~rs2 ===== */
    __asm__ volatile("orn %0, %1, %2" : "=r"(result) : "r"(0x00000000), "r"(0x0F0F0F0F));
    TEST("ORN basic", result, 0xF0F0F0F0);
    __asm__ volatile("orn %0, %1, %2" : "=r"(result) : "r"(0x00000000), "r"(0xFFFFFFFF));
    TEST("ORN all", result, 0);

    /* ===== XNOR: rd = rs1 ^ ~rs2 ===== */
    __asm__ volatile("xnor %0, %1, %2" : "=r"(result) : "r"(0xFFFFFFFF), "r"(0xAAAAAAAA));
    TEST("XNOR basic", result, 0xAAAAAAAA);
    __asm__ volatile("xnor %0, %1, %2" : "=r"(result) : "r"(0), "r"(0));
    TEST("XNOR 0", result, 0xFFFFFFFF);

    END_EXTENSION();
}

/* ========================================================================== */
/* Zbs Tests (Single-Bit Operations)                                          */
/* ========================================================================== */

static void test_zbs(void)
{
    BEGIN_EXTENSION(EXT_ZBS);

    uint32_t result;

    /* ===== BSET: set bit (rd = rs1 | (1 << rs2[4:0])) ===== */
    __asm__ volatile("bset %0, %1, %2" : "=r"(result) : "r"(0), "r"(5));
    TEST("BSET basic", result, 0x20);
    __asm__ volatile("bset %0, %1, %2" : "=r"(result) : "r"(0xFFFFFFFF), "r"(0));
    TEST("BSET set", result, 0xFFFFFFFF);
    __asm__ volatile("bset %0, %1, %2" : "=r"(result) : "r"(0), "r"(0));
    TEST("BSET bit0", result, 1);
    __asm__ volatile("bset %0, %1, %2" : "=r"(result) : "r"(0), "r"(31));
    TEST("BSET bit31", result, 0x80000000);
    __asm__ volatile("bset %0, %1, %2" : "=r"(result) : "r"(0), "r"(32));
    TEST("BSET wrap32", result, 1); /* 32 % 32 = 0 */

    /* ===== BCLR: clear bit (rd = rs1 & ~(1 << rs2[4:0])) ===== */
    __asm__ volatile("bclr %0, %1, %2" : "=r"(result) : "r"(0xFF), "r"(3));
    TEST("BCLR basic", result, 0xF7);
    __asm__ volatile("bclr %0, %1, %2" : "=r"(result) : "r"(0), "r"(5));
    TEST("BCLR clear", result, 0);
    __asm__ volatile("bclr %0, %1, %2" : "=r"(result) : "r"(0xFFFFFFFF), "r"(0));
    TEST("BCLR bit0", result, 0xFFFFFFFE);
    __asm__ volatile("bclr %0, %1, %2" : "=r"(result) : "r"(0xFFFFFFFF), "r"(31));
    TEST("BCLR bit31", result, 0x7FFFFFFF);

    /* ===== BINV: invert bit (rd = rs1 ^ (1 << rs2[4:0])) ===== */
    __asm__ volatile("binv %0, %1, %2" : "=r"(result) : "r"(0), "r"(7));
    TEST("BINV 0->1", result, 0x80);
    __asm__ volatile("binv %0, %1, %2" : "=r"(result) : "r"(0x80), "r"(7));
    TEST("BINV 1->0", result, 0);
    __asm__ volatile("binv %0, %1, %2" : "=r"(result) : "r"(0), "r"(31));
    TEST("BINV bit31", result, 0x80000000);
    __asm__ volatile("binv %0, %1, %2" : "=r"(result) : "r"(0x80000000), "r"(31));
    TEST("BINV clr31", result, 0);

    /* ===== BEXT: extract bit (rd = (rs1 >> rs2[4:0]) & 1) ===== */
    __asm__ volatile("bext %0, %1, %2" : "=r"(result) : "r"(0x80), "r"(7));
    TEST("BEXT 1", result, 1);
    __asm__ volatile("bext %0, %1, %2" : "=r"(result) : "r"(0x80), "r"(6));
    TEST("BEXT 0", result, 0);
    __asm__ volatile("bext %0, %1, %2" : "=r"(result) : "r"(0x80000000), "r"(31));
    TEST("BEXT bit31", result, 1);
    __asm__ volatile("bext %0, %1, %2" : "=r"(result) : "r"(1), "r"(0));
    TEST("BEXT bit0", result, 1);
    __asm__ volatile("bext %0, %1, %2" : "=r"(result) : "r"(0xFFFFFFFF), "r"(15));
    TEST("BEXT mid", result, 1);

    /* ===== BSETI: set bit immediate ===== */
    __asm__ volatile("bseti %0, %1, 10" : "=r"(result) : "r"(0));
    TEST("BSETI basic", result, 0x400);
    __asm__ volatile("bseti %0, %1, 0" : "=r"(result) : "r"(0));
    TEST("BSETI bit0", result, 1);
    __asm__ volatile("bseti %0, %1, 31" : "=r"(result) : "r"(0));
    TEST("BSETI bit31", result, 0x80000000);

    /* ===== BCLRI: clear bit immediate ===== */
    __asm__ volatile("bclri %0, %1, 10" : "=r"(result) : "r"(0xFFFFFFFF));
    TEST("BCLRI basic", result, 0xFFFFFBFF);
    __asm__ volatile("bclri %0, %1, 0" : "=r"(result) : "r"(0xFFFFFFFF));
    TEST("BCLRI bit0", result, 0xFFFFFFFE);
    __asm__ volatile("bclri %0, %1, 31" : "=r"(result) : "r"(0xFFFFFFFF));
    TEST("BCLRI bit31", result, 0x7FFFFFFF);

    /* ===== BINVI: invert bit immediate ===== */
    __asm__ volatile("binvi %0, %1, 31" : "=r"(result) : "r"(0));
    TEST("BINVI basic", result, 0x80000000);
    __asm__ volatile("binvi %0, %1, 0" : "=r"(result) : "r"(0));
    TEST("BINVI bit0", result, 1);
    __asm__ volatile("binvi %0, %1, 0" : "=r"(result) : "r"(1));
    TEST("BINVI clr0", result, 0);

    /* ===== BEXTI: extract bit immediate ===== */
    __asm__ volatile("bexti %0, %1, 31" : "=r"(result) : "r"(0x80000000));
    TEST("BEXTI 1", result, 1);
    __asm__ volatile("bexti %0, %1, 30" : "=r"(result) : "r"(0x80000000));
    TEST("BEXTI 0", result, 0);
    __asm__ volatile("bexti %0, %1, 0" : "=r"(result) : "r"(1));
    TEST("BEXTI bit0", result, 1);
    __asm__ volatile("bexti %0, %1, 0" : "=r"(result) : "r"(0xFFFFFFFE));
    TEST("BEXTI bit0-0", result, 0);

    END_EXTENSION();
}

/* ========================================================================== */
/* Zicond Tests (Conditional Zero Operations)                                 */
/* ========================================================================== */

static void test_zicond(void)
{
    BEGIN_EXTENSION(EXT_ZICOND);

    uint32_t result;

    /* CZERO.EQZ: if rs2 == 0, rd = 0; else rd = rs1 */
    __asm__ volatile("czero.eqz %0, %1, %2" : "=r"(result) : "r"(42), "r"(0));
    TEST("CZERO.EQZ (rs2=0)", result, 0);

    __asm__ volatile("czero.eqz %0, %1, %2" : "=r"(result) : "r"(42), "r"(1));
    TEST("CZERO.EQZ (rs2!=0)", result, 42);

    __asm__ volatile("czero.eqz %0, %1, %2" : "=r"(result) : "r"(0xDEADBEEF), "r"(0xFFFFFFFF));
    TEST("CZERO.EQZ (large)", result, 0xDEADBEEF);

    /* CZERO.NEZ: if rs2 != 0, rd = 0; else rd = rs1 */
    __asm__ volatile("czero.nez %0, %1, %2" : "=r"(result) : "r"(42), "r"(0));
    TEST("CZERO.NEZ (rs2=0)", result, 42);

    __asm__ volatile("czero.nez %0, %1, %2" : "=r"(result) : "r"(42), "r"(1));
    TEST("CZERO.NEZ (rs2!=0)", result, 0);

    __asm__ volatile("czero.nez %0, %1, %2" : "=r"(result) : "r"(0xDEADBEEF), "r"(0));
    TEST("CZERO.NEZ (large)", result, 0xDEADBEEF);

    /* Test conditional select pattern: result = cond ? a : b
     * Implemented as: czero.eqz t1, a, cond; czero.nez t2, b, cond; or result, t1, t2 */
    uint32_t a = 100, b = 200, cond = 1;
    uint32_t t1, t2;
    __asm__ volatile("czero.eqz %0, %2, %4\n" /* t1 = cond==0 ? 0 : a */
                     "czero.nez %1, %3, %4\n" /* t2 = cond!=0 ? 0 : b */
                     "or %0, %0, %1\n"        /* result = t1 | t2 */
                     : "=&r"(t1), "=&r"(t2)
                     : "r"(a), "r"(b), "r"(cond));
    TEST("CZERO (select cond=1)", t1, 100); /* Should select a */

    cond = 0;
    __asm__ volatile("czero.eqz %0, %2, %4\n"
                     "czero.nez %1, %3, %4\n"
                     "or %0, %0, %1\n"
                     : "=&r"(t1), "=&r"(t2)
                     : "r"(a), "r"(b), "r"(cond));
    TEST("CZERO (select cond=0)", t1, 200); /* Should select b */

    END_EXTENSION();
}

/* ========================================================================== */
/* Zbkb Tests (Bit Manipulation for Cryptography)                             */
/* ========================================================================== */

static void test_zbkb(void)
{
    BEGIN_EXTENSION(EXT_ZBKB);

    uint32_t result;

    /* PACK: pack low halves of rs1 and rs2
     * rd[15:0] = rs1[15:0], rd[31:16] = rs2[15:0] */
    __asm__ volatile("pack %0, %1, %2" : "=r"(result) : "r"(0xAAAA1234), "r"(0xBBBB5678));
    TEST("PACK", result, 0x56781234);

    __asm__ volatile("pack %0, %1, %2" : "=r"(result) : "r"(0x0000FFFF), "r"(0x0000FFFF));
    TEST("PACK (2)", result, 0xFFFFFFFF);

    /* PACKH: pack low bytes of rs1 and rs2
     * rd[7:0] = rs1[7:0], rd[15:8] = rs2[7:0], rd[31:16] = 0 */
    __asm__ volatile("packh %0, %1, %2" : "=r"(result) : "r"(0xABCDEF12), "r"(0x12345678));
    TEST("PACKH", result, 0x00007812);

    __asm__ volatile("packh %0, %1, %2" : "=r"(result) : "r"(0xFF), "r"(0xFF));
    TEST("PACKH (2)", result, 0x0000FFFF);

    /* BREV8: bit-reverse each byte independently */
    /* Input: 0x12345678 -> bytes are [0x78, 0x56, 0x34, 0x12] (LSB to MSB) */
    /* 0x78 = 0111_1000 -> reversed: 0001_1110 = 0x1E (byte 0) */
    /* 0x56 = 0101_0110 -> reversed: 0110_1010 = 0x6A (byte 1) */
    /* 0x34 = 0011_0100 -> reversed: 0010_1100 = 0x2C (byte 2) */
    /* 0x12 = 0001_0010 -> reversed: 0100_1000 = 0x48 (byte 3) */
    /* Result: 0x482C6A1E */
    __asm__ volatile("brev8 %0, %1" : "=r"(result) : "r"(0x12345678));
    TEST("BREV8", result, 0x482C6A1E);

    __asm__ volatile("brev8 %0, %1" : "=r"(result) : "r"(0x80808080));
    TEST("BREV8 (2)", result, 0x01010101);

    /* ZIP: interleave bits from lower and upper halves
     * Odd bits come from upper half, even bits from lower half */
    __asm__ volatile("zip %0, %1" : "=r"(result) : "r"(0xFFFF0000));
    TEST("ZIP", result, 0xAAAAAAAA); /* Alternating 10101010... */

    __asm__ volatile("zip %0, %1" : "=r"(result) : "r"(0x0000FFFF));
    TEST("ZIP (2)", result, 0x55555555); /* Alternating 01010101... */

    /* UNZIP: de-interleave bits (inverse of zip)
     * Even bits go to lower half, odd bits go to upper half */
    __asm__ volatile("unzip %0, %1" : "=r"(result) : "r"(0xAAAAAAAA));
    TEST("UNZIP", result, 0xFFFF0000);

    __asm__ volatile("unzip %0, %1" : "=r"(result) : "r"(0x55555555));
    TEST("UNZIP (2)", result, 0x0000FFFF);

    /* ZIP followed by UNZIP should be identity */
    __asm__ volatile("zip %0, %1\n"
                     "unzip %0, %0\n"
                     : "=r"(result)
                     : "r"(0x12345678));
    TEST("ZIP/UNZIP (identity)", result, 0x12345678);

    END_EXTENSION();
}

/* ========================================================================== */
/* Zihintpause Tests (Pause Hint)                                             */
/* ========================================================================== */

static void test_zihintpause(void)
{
    BEGIN_EXTENSION(EXT_ZIHINTPAUSE);

    /* PAUSE: hint instruction for spin-wait loops
     * Encoded as: fence pred=W, succ=0 (or fence 0,1)
     * Should execute as a NOP but may reduce power consumption */
    __asm__ volatile("pause" :::);
    TEST_NO_CRASH("PAUSE");

    /* Multiple pause instructions in sequence */
    __asm__ volatile("pause\n pause\n pause" :::);
    TEST_NO_CRASH("PAUSE (x3)");

    END_EXTENSION();
}

/* ========================================================================== */
/* Machine Mode Tests (RTOS Support)                                          */
/* ========================================================================== */

/* Flag set by trap handler to indicate trap was taken */
static volatile uint32_t trap_taken = 0;
static volatile uint32_t trap_cause = 0;

/* Assembly trap handler - saves mcause, advances mepc, then returns */
/* Uses lui+offset for absolute addressing to trap_cause/trap_taken globals */
/* NOTE: With C extension, must detect 16-bit vs 32-bit instructions */
/* NOTE: Must be 4-byte aligned for mtvec (bits [1:0] are MODE bits) */
__attribute__((naked, aligned(4))) static void test_trap_handler(void)
{
    __asm__ volatile(
        /* Save mcause to global using symbol addressing */
        "csrr t0, mcause\n"
        "la t1, trap_cause\n"
        "sw t0, 0(t1)\n"
        /* Set trap_taken flag */
        "li t0, 1\n"
        "la t1, trap_taken\n"
        "sw t0, 0(t1)\n"
        /* Advance mepc past the trapping instruction.
         * With C extension, need to detect if it's 16-bit or 32-bit.
         * 32-bit instructions have bits[1:0] = 0b11 */
        "csrr t0, mepc\n"
        "nop\n" /* Allow pipeline to settle */
        "nop\n"
        "nop\n"
        "nop\n"
        "lhu t2, 0(t0)\n"    /* Load low halfword of instruction */
        "andi t2, t2, 0x3\n" /* Check bits [1:0] */
        "li t3, 0x3\n"
        "addi t0, t0, 2\n" /* Assume 16-bit (add 2) */
        "bne t2, t3, 1f\n" /* If not 0x3, it's 16-bit, skip */
        "addi t0, t0, 2\n" /* It's 32-bit, add 2 more (total 4) */
        "1:\n"
        "csrw mepc, t0\n"
        /* Return from trap */
        "mret\n");
}

static void test_mmode(void)
{
    BEGIN_EXTENSION(EXT_MMODE);

    uint32_t result1, result2;

    /* ===== MSCRATCH: Machine Scratch Register ===== */
    /* This is a read/write register for trap handler use */
    /* Add NOPs to ensure CSR write completes before read (pipeline hazard) */
    __asm__ volatile("csrrw %0, mscratch, %2\n"
                     "nop\nnop\nnop\nnop\nnop\n"
                     "csrr %1, mscratch"
                     : "=r"(result1), "=r"(result2)
                     : "r"(0xDEADBEEF));
    TEST("MSCRATCH write", result2, 0xDEADBEEF);

    __asm__ volatile("csrrs %0, mscratch, %1" : "=r"(result1) : "r"(0x00F00000));
    TEST("MSCRATCH set", result1, 0xDEADBEEF); /* Returns old value */
    __asm__ volatile("csrr %0, mscratch" : "=r"(result2));
    TEST("MSCRATCH after set", result2, 0xDEFDBEEF);

    __asm__ volatile("csrrc %0, mscratch, %1" : "=r"(result1) : "r"(0x000D0000));
    __asm__ volatile("csrr %0, mscratch" : "=r"(result2));
    TEST("MSCRATCH clear", result2, 0xDEF0BEEF);

    /* ===== MTVEC: Machine Trap Vector ===== */
    uint32_t old_mtvec;
    __asm__ volatile("csrr %0, mtvec" : "=r"(old_mtvec));
    TEST("MTVEC readable", 1, 1);

    __asm__ volatile("csrw mtvec, %0" ::"r"(0x00001000));
    __asm__ volatile("csrr %0, mtvec" : "=r"(result1));
    TEST("MTVEC write", result1, 0x00001000);
    __asm__ volatile("csrw mtvec, %0" ::"r"(old_mtvec)); /* Restore */

    /* ===== MSTATUS: Machine Status ===== */
    __asm__ volatile("csrr %0, mstatus" : "=r"(result1));
    TEST("MSTATUS readable", 1, 1);

    /* Test MIE bit toggle (carefully - don't leave interrupts disabled) */
    __asm__ volatile("csrc mstatus, %0" ::"r"(0x8)); /* Clear MIE */
    __asm__ volatile("csrr %0, mstatus" : "=r"(result1));
    TEST("MSTATUS MIE clear", (result1 & 0x8), 0);

    __asm__ volatile("csrs mstatus, %0" ::"r"(0x8)); /* Set MIE */
    __asm__ volatile("csrr %0, mstatus" : "=r"(result1));
    TEST("MSTATUS MIE set", (result1 & 0x8), 0x8);

    /* ===== MIE: Machine Interrupt Enable ===== */
    __asm__ volatile("csrr %0, mie" : "=r"(result1));
    TEST("MIE readable", 1, 1);

    /* Test timer interrupt enable bit */
    __asm__ volatile("csrs mie, %0" ::"r"(0x80)); /* Set MTIE */
    __asm__ volatile("csrr %0, mie" : "=r"(result1));
    TEST("MIE MTIE set", (result1 & 0x80), 0x80);

    __asm__ volatile("csrc mie, %0" ::"r"(0x80)); /* Clear MTIE */
    __asm__ volatile("csrr %0, mie" : "=r"(result1));
    TEST("MIE MTIE clear", (result1 & 0x80), 0);

    /* ===== MIP: Machine Interrupt Pending (read-only) ===== */
    __asm__ volatile("csrr %0, mip" : "=r"(result1));
    TEST("MIP readable", 1, 1);

    /* ===== MISA: Machine ISA (read-only) ===== */
    __asm__ volatile("csrr %0, misa" : "=r"(result1));
    /* MISA should indicate RV32 (bits 31:30 = 01) and I extension (bit 8) */
    TEST("MISA RV32", (result1 >> 30), 1);
    TEST("MISA I-ext", (result1 >> 8) & 1, 1);
    TEST("MISA M-ext", (result1 >> 12) & 1, 1);
    TEST("MISA A-ext", (result1 >> 0) & 1, 1);

    /* ===== WFI: Wait For Interrupt ===== */
    /* WFI stalls until an interrupt is pending (even if not enabled).
     * We must trigger a software interrupt first, or WFI will hang forever. */
    MSIP = 1; /* Set software interrupt pending - WFI will see this and not stall */
    __asm__ volatile("wfi" ::: "memory");
    MSIP = 0; /* Clear software interrupt */
    TEST_NO_CRASH("WFI");

    /* ===== ECALL/EBREAK/MRET: Test trap handling ===== */
    /* Set up our test trap handler */
    __asm__ volatile("csrw mtvec, %0" ::"r"((uint32_t) test_trap_handler));

    /* Disable interrupts during trap tests to avoid interference */
    __asm__ volatile("csrc mstatus, %0" ::"r"(0x8));

    /* Test ECALL (mcause should be 11 for M-mode environment call) */
    trap_taken = 0;
    trap_cause = 0;
    __asm__ volatile("ecall" ::: "memory");
    TEST("ECALL trap taken", trap_taken, 1);
    TEST("ECALL mcause", trap_cause, 11);

    /* Test EBREAK (mcause should be 3 for breakpoint) */
    trap_taken = 0;
    trap_cause = 0;
    __asm__ volatile(".insn 0x00100073" ::: "memory");
    TEST("EBREAK trap taken", trap_taken, 1);
    TEST("EBREAK mcause", trap_cause, 3);

    /* Restore original trap handler and re-enable interrupts */
    __asm__ volatile("csrw mtvec, %0" ::"r"(old_mtvec));
    __asm__ volatile("csrs mstatus, %0" ::"r"(0x8));

    /* Note: MRET is tested implicitly by the trap handler returning successfully */
    TEST_NO_CRASH("MRET (via handler)");

    END_EXTENSION();
}

/* ========================================================================== */
/* Result Summary                                                             */
/* ========================================================================== */

static void print_summary(void)
{
    uart_printf("\n");
    uart_printf("============================================================\n");
    uart_printf("                    ISA TEST SUMMARY\n");
    uart_printf("============================================================\n\n");

    uint32_t total_passed = 0;
    uint32_t total_failed = 0;
    uint32_t extensions_passed = 0;
    uint32_t extensions_failed = 0;

    /* Print per-extension results */
    for (int i = 0; i < EXT_COUNT; i++) {
        uint32_t passed = results[i].tests_passed;
        uint32_t failed = results[i].tests_failed;
        total_passed += passed;
        total_failed += failed;

        const char *status = (failed == 0) ? "PASS" : "FAIL";
        if (failed == 0) {
            extensions_passed++;
        } else {
            extensions_failed++;
        }

        /* Print extension name with manual padding (uart_printf doesn't support %-12s) */
        uart_printf("  %s", extension_names[i]);
        /* Pad to 12 characters */
        for (int pad = strlen(extension_names[i]); pad < 12; pad++)
            uart_putchar(' ');
        uart_printf(" [%s]  %lu/%lu tests passed\n",
                    status,
                    (unsigned long) passed,
                    (unsigned long) (passed + failed));

#if !COMPACT_MODE
        /* List failed instructions for this extension (not available in compact mode) */
        if (failed > 0) {
            uart_printf("    Failed: ");
            for (uint32_t j = 0; j < failed_count[i] && j < MAX_TESTS_PER_EXT; j++) {
                if (j > 0)
                    uart_printf(", ");
                uart_printf("%s", failed_instructions[i][j]);
            }
            uart_printf("\n");
        }
#endif
    }

    uart_printf("\n------------------------------------------------------------\n");
    uart_printf("  EXTENSIONS: %lu PASSED, %lu FAILED\n",
                (unsigned long) extensions_passed,
                (unsigned long) extensions_failed);
    uart_printf("  TESTS:      %lu PASSED, %lu FAILED\n",
                (unsigned long) total_passed,
                (unsigned long) total_failed);
    uart_printf("------------------------------------------------------------\n\n");

    if (total_failed == 0) {
        uart_printf("  *** ALL TESTS PASSED - PROCESSOR IS COMPLIANT ***\n\n");
        uart_printf("<<PASS>>\n");
    } else {
        uart_printf("  *** SOME TESTS FAILED - SEE DETAILS ABOVE ***\n\n");
        uart_printf("<<FAIL>>\n");
    }
}

/* ========================================================================== */
/* Main Entry Point                                                           */
/* ========================================================================== */

int main(void)
{
    uart_printf("\n");
    uart_printf("============================================================\n");
    uart_printf("     FROST RISC-V ISA COMPLIANCE TEST SUITE\n");
    uart_printf("============================================================\n");
    uart_printf("  Target: RV32GCB_Zicsr_Zicntr_Zifencei_Zicond_Zbkb_Zihintpause + M-mode\n");
    uart_printf("  Note:   G = IMAFD (base integer + M/A/F/D)\n");
    uart_printf("  Note:   B = Zba + Zbb + Zbs (full bit manipulation extension)\n");
    uart_printf("  Note:   F = Single-precision floating-point\n");
    uart_printf("  Note:   D = Double-precision floating-point\n");
    uart_printf("  Clock:  %u Hz\n", FPGA_CPU_CLK_FREQ);
    uart_printf("============================================================\n");

    uint64_t start_cycles = rdcycle64();

    /* Run all test suites */
    test_rv32i();
    test_m_extension();
    test_a_extension();
    test_c_extension();
    test_f_extension();
    test_d_extension();
    test_zicsr();
    test_zicntr();
    test_zifencei();
    test_zba();
    test_zbb();
    test_zbs();
    test_zicond();
    test_zbkb();
    test_zihintpause();
    test_mmode();

    uint64_t end_cycles = rdcycle64();
    uint64_t elapsed = end_cycles - start_cycles;

    /* Print elapsed cycles (avoid 64-bit division which requires libgcc) */
    uart_printf("\nTest completed in %llu cycles\n", (unsigned long long) elapsed);

    /* Print final summary */
    print_summary();

    /* Loop forever */
    for (;;) {
        __asm__ volatile("pause" :::); /* Low-power spin loop */
    }

    return 0;
}
