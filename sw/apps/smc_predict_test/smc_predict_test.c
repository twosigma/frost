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
 * Stale branch predictions on rewritten code
 *
 * A JIT reuses code addresses: a slot that held a control-flow instruction
 * may later hold a plain ALU instruction. Each case trains the predictors on
 * body A, whose control-flow instruction sits at a fixed PC, then rewrites
 * the buffer with body B, which has an addi at that PC, runs fence.i and
 * calls B. B's result must not depend on what A predicted.
 *
 *   ret     A: addi; ret              B: addi; addi; addi; ret     want x+3
 *   jump    A: addi; j +8; addi 100;  B: addi; addi; addi; ret     want x+3
 *              ret (skips the 100)
 *   branch  A: addi; beq x0,x0,+8;    B: addi; addi; addi; ret     want x+3
 *              addi 100; ret
 */

#include <stdint.h>

#include "../../lib/include/uart.h"

#define TRAIN_CALLS 32
#define CHECK_CALLS 8

#define INSN_ADDI_A0_1 0x00150513u   /* addi a0, a0, 1 */
#define INSN_ADDI_A0_100 0x06450513u /* addi a0, a0, 100 */
#define INSN_RET 0x00008067u         /* jalr x0, 0(ra) */
#define INSN_J_8 0x0080006fu         /* jal x0, +8 */
#define INSN_BEQ_8 0x00000463u       /* beq x0, x0, +8 */

__attribute__((section(".ddr_bss"), aligned(64))) static volatile uint32_t ddr_code_buf[16];

/* Low-BRAM code cannot reach .ddr_bss PC-relatively; load its address. */
static volatile uint32_t *volatile const ddr_code_p = ddr_code_buf;

typedef long (*body_fn_t)(long);

static int failures;

static void load(const uint32_t *insns, unsigned n)
{
    volatile uint32_t *code = ddr_code_p;
    for (unsigned i = 0; i < n; i++) {
        code[i] = insns[i];
    }
    __asm__ volatile("fence.i" ::: "memory");
}

static void run_case(const char *name, const uint32_t *a, unsigned na, long a_add)
{
    static const uint32_t b[] = {INSN_ADDI_A0_1, INSN_ADDI_A0_1, INSN_ADDI_A0_1, INSN_RET};
    body_fn_t fn = (body_fn_t) (uintptr_t) ddr_code_p;
    int bad = 0;

    load(a, na);
    for (long i = 0; i < TRAIN_CALLS; i++) {
        long got = fn(i);
        if (got != i + a_add) {
            uart_printf("FAIL: %s training call %ld got %ld want %ld\n", name, i, got, i + a_add);
            bad++;
        }
    }

    load(b, sizeof(b) / sizeof(b[0]));
    for (long i = 0; i < CHECK_CALLS; i++) {
        long got = fn(i);
        if (got != i + 3) {
            uart_printf("FAIL: %s call %ld after rewrite got %ld want %ld\n", name, i, got, i + 3);
            bad++;
        }
    }
    uart_printf("%s: %s\n", name, bad ? "stale" : "ok");
    failures += bad;
}

int main(void)
{
    static const uint32_t a_ret[] = {INSN_ADDI_A0_1, INSN_RET};
    static const uint32_t a_jump[] = {INSN_ADDI_A0_1, INSN_J_8, INSN_ADDI_A0_100, INSN_RET};
    static const uint32_t a_branch[] = {INSN_ADDI_A0_1, INSN_BEQ_8, INSN_ADDI_A0_100, INSN_RET};

    run_case("ret", a_ret, 2, 1);
    run_case("jump", a_jump, 4, 1);
    run_case("branch", a_branch, 4, 1);

    if (failures == 0) {
        uart_printf("<<PASS>>\n");
    } else {
        uart_printf("<<FAIL>> (%d failures)\n", failures);
    }

    while (1) {
    }
    return 0;
}
