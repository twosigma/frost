/*
 * Copyright (c) 2026 John Goodacre.
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
 * Stale instruction bytes after fence.i
 *
 * Code rewritten while an older copy sits further out in the hierarchy must
 * still be the code that runs after fence.i, on every later call. Each
 * iteration writes a version of the code, runs fence.i and calls it, then
 * (optionally) evicts the L1D so the L2 holds that version. It then rewrites
 * one instruction, so the new bytes are dirty in the L1D while the L2 holds
 * the old ones, runs fence.i, and calls several times.
 *
 *   jump    entry: j +64; the target line holds addi a0, a0, K; ret
 *   fall    entry: nops up to the target line, so fetch walks into it
 *           sequentially (next-line prefetch can reach it first)
 *
 * Each call must return arg + K for the current K.
 */

#include <stdint.h>

#include "../../lib/include/uart.h"

#define ITERATIONS 6
#define CALLS 6
#define EVICT_BYTES (256 * 1024) /* twice the L1D */
#define TARGET_WORD 16           /* byte 64: the third 32-byte line */

#define INSN_NOP 0x00000013u
#define INSN_RET 0x00008067u

__attribute__((section(".ddr_bss"), aligned(64))) static volatile uint32_t ddr_code_buf[32];
__attribute__((section(".ddr_bss"),
               aligned(64))) static volatile uint64_t ddr_evict_buf[EVICT_BYTES / 8];

/* Low-BRAM code cannot reach .ddr_bss PC-relatively; load the addresses. */
static volatile uint32_t *volatile const ddr_code_p = ddr_code_buf;
static volatile uint64_t *volatile const ddr_evict_p = ddr_evict_buf;

typedef long (*body_fn_t)(long);

static int failures;

static uint32_t enc_addi_a0(int imm)
{
    return (((uint32_t) imm & 0xfff) << 20) | (10u << 15) | (10u << 7) | 0x13;
}

static void fence_i(void)
{
    __asm__ volatile("fence.i" ::: "memory");
}

/* Store to every line of a buffer twice the L1D, so the code line's
 * dirty data leaves the L1D for the L2. */
static void evict_l1d(unsigned salt)
{
    volatile uint64_t *b = ddr_evict_p;
    for (unsigned i = 0; i < EVICT_BYTES / 8; i += 4) {
        b[i] = i ^ salt;
    }
}

static void write_entry(int fall)
{
    volatile uint32_t *code = ddr_code_p;
    if (fall) {
        for (unsigned i = 0; i < TARGET_WORD; i++) {
            code[i] = INSN_NOP;
        }
    } else {
        code[0] = 0x0400006fu; /* jal x0, +64 */
        for (unsigned i = 1; i < TARGET_WORD; i++) {
            code[i] = INSN_NOP;
        }
    }
    code[TARGET_WORD + 1] = INSN_RET;
}

static void check_calls(const char *mode, int evict, int it, long k)
{
    body_fn_t fn = (body_fn_t) (uintptr_t) ddr_code_p;
    for (long c = 0; c < CALLS; c++) {
        long got = fn(1000 * c);
        if (got != 1000 * c + k) {
            if (failures < 10) {
                uart_printf("FAIL: %s evict=%d iter %d call %ld got %ld want %ld\n",
                            mode,
                            evict,
                            it,
                            c,
                            got,
                            1000 * c + k);
            }
            failures++;
        }
    }
}

static void run(const char *mode, int fall, int evict)
{
    volatile uint32_t *code = ddr_code_p;
    write_entry(fall);
    for (int it = 0; it < ITERATIONS; it++) {
        long k_old = 2 * it + 1, k_new = 2 * it + 2;
        code[TARGET_WORD] = enc_addi_a0((int) k_old);
        fence_i();
        check_calls(mode, evict, it, k_old);
        if (evict) {
            evict_l1d((unsigned) it);
        }
        code[TARGET_WORD] = enc_addi_a0((int) k_new);
        fence_i();
        check_calls(mode, evict, it, k_new);
    }
    uart_printf("%s evict=%d: %s\n", mode, evict, failures ? "stale" : "ok");
}

int main(void)
{
    run("jump", 0, 1);
    run("fall", 1, 1);
    run("jump", 0, 0);
    run("fall", 1, 0);

    if (failures == 0) {
        uart_printf("<<PASS>>\n");
    } else {
        uart_printf("<<FAIL>> (%d failures)\n", failures);
    }

    while (1) {
    }
    return 0;
}
