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
 * Code-mutation torture
 *
 * Generates random leaf functions into cached DDR, trains the predictors by
 * calling them, then changes the code under the trained PCs and checks that
 * the next calls compute what the new code says. Two kinds of change:
 *
 *   patch       rewrite random instructions in place, keeping each one's
 *               size, as Linux does when it switches a nop and a jump
 *   regenerate  write a new function with a different layout into the same
 *               buffer, as a JIT does when it reuses code memory
 *
 * Every change is followed by fence.i. The vocabulary mixes 16- and 32-bit
 * encodings so each kind lands in both slots of the 64-bit fetch window:
 * ALU ops on a0, nops, forward jumps, always-taken and never-taken branches,
 * and an early return. A small interpreter gives the expected a0. In
 * simulation the core's next-PC check also catches any wrong-path retirement.
 *
 * Self-checking; build with -DSMC_SEED=<n> to vary the stream.
 */

#include <stdint.h>

#ifdef SMC_HOST
/* Host replay of the generator: same random stream, prints every round's
 * code instead of running it. Build with cc -DSMC_HOST -DSMC_VERBOSE. */
#include <stdio.h>
#define uart_printf printf
#define SMC_DDR
#else
#include "../../lib/include/uart.h"
#define SMC_DDR __attribute__((section(".ddr_bss"), aligned(64)))
#endif

#ifndef SMC_SEED
#define SMC_SEED 0x5eed1234u
#endif
#define ROUNDS 48
#define CALLS 4
#define MAX_INSNS 48
#define MAX_BYTES 200 /* keeps every forward branch inside c.beqz range */
#define PATCHES 3

enum kind {
    K_ADDI,   /* addi a0, a0, imm           32 */
    K_CADDI,  /* c.addi a0, imm             16 */
    K_NOP,    /* addi x0, x0, 0             32 */
    K_CNOP,   /* c.nop                      16 */
    K_J,      /* jal x0, fwd                32 */
    K_CJ,     /* c.j fwd                    16 */
    K_BEQ,    /* beq x0, x0, fwd (taken)    32 */
    K_BNE,    /* bne x0, x0, fwd (not taken) 32 */
    K_CBEQZ,  /* c.beqz a5, fwd (taken)     16 */
    K_CBNEZ,  /* c.bnez a5, fwd (not taken) 16 */
    K_RET,    /* jalr x0, 0(ra)             32 */
    K_CRET,   /* c.jr ra                    16 */
    K_COUNT
};

struct insn {
    uint8_t kind;
    int8_t imm;      /* ALU immediate */
    uint8_t target;  /* instruction index for jumps and branches */
    uint16_t offset; /* byte offset from the function start */
};

/* The prologue (li a5, 0) and the final ret are fixed; body slots vary. */
struct func {
    unsigned n;
    struct insn in[MAX_INSNS];
};

SMC_DDR static volatile uint16_t ddr_code_buf[MAX_BYTES];

/* Low-BRAM code cannot reach .ddr_bss PC-relatively; load its address. */
static volatile uint16_t *volatile const ddr_code_p = ddr_code_buf;

typedef long (*body_fn_t)(long);

static uint32_t rng_state = SMC_SEED;

static uint32_t rng(void)
{
    uint32_t x = rng_state;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    rng_state = x;
    return x;
}

static unsigned kind_size(unsigned k)
{
    switch (k) {
        case K_CADDI:
        case K_CNOP:
        case K_CJ:
        case K_CBEQZ:
        case K_CBNEZ:
        case K_CRET:
            return 2;
        default:
            return 4;
    }
}

static int kind_is_cf(unsigned k)
{
    return k == K_J || k == K_CJ || k == K_BEQ || k == K_BNE || k == K_CBEQZ || k == K_CBNEZ;
}

/* A random body kind of the given size (0 = any). Returns are rarer. */
static unsigned random_kind(unsigned size)
{
    for (;;) {
        unsigned k = rng() % K_COUNT;
        if ((k == K_RET || k == K_CRET) && (rng() & 3)) {
            continue;
        }
        if (size == 0 || kind_size(k) == size) {
            return k;
        }
    }
}

static int8_t random_imm(void)
{
    int8_t imm = (int8_t) ((int) (rng() % 61) - 30); /* c.addi range, nonzero */
    return imm ? imm : 1;
}

/* Lay out offsets; index 0 is the prologue, n-1 the final ret. */
static void layout(struct func *f)
{
    unsigned off = 0;
    for (unsigned i = 0; i < f->n; i++) {
        f->in[i].offset = (uint16_t) off;
        off += kind_size(f->in[i].kind);
    }
}

/* Pick forward targets in (i, n-1] for control flow at index i. */
static void pick_target(struct func *f, unsigned i)
{
    f->in[i].target = (uint8_t) (i + 1 + rng() % (f->n - 1 - i));
}

static void generate(struct func *f)
{
    unsigned bytes = 4 + 4; /* prologue and final ret */
    unsigned n = 1;
    f->in[0].kind = K_ADDI; /* placeholder; emitted as li a5, 0 */
    unsigned want = 4 + rng() % (MAX_INSNS - 6);
    while (n < want + 1 && bytes + 4 <= MAX_BYTES) {
        unsigned k = random_kind(0);
        f->in[n].kind = (uint8_t) k;
        f->in[n].imm = random_imm();
        bytes += kind_size(k);
        n++;
    }
    f->in[n].kind = K_RET;
    f->n = n + 1;
    layout(f);
    for (unsigned i = 1; i + 1 < f->n; i++) {
        if (kind_is_cf(f->in[i].kind)) {
            pick_target(f, i);
        }
    }
}

/* Rewrite a few body instructions in place with others of the same size. */
static void patch(struct func *f)
{
    for (unsigned p = 0; p < PATCHES; p++) {
        unsigned i = 1 + rng() % (f->n - 2);
        unsigned k = random_kind(kind_size(f->in[i].kind));
        f->in[i].kind = (uint8_t) k;
        f->in[i].imm = random_imm();
        if (kind_is_cf(k)) {
            pick_target(f, i);
        }
    }
}

static uint32_t enc_j(int off)
{
    uint32_t u = (uint32_t) off;
    return (((u >> 20) & 1) << 31) | (((u >> 1) & 0x3ff) << 21) | (((u >> 11) & 1) << 20) |
           (((u >> 12) & 0xff) << 12) | 0x6f;
}

static uint32_t enc_b(int off, unsigned funct3)
{
    uint32_t u = (uint32_t) off;
    return (((u >> 12) & 1) << 31) | (((u >> 5) & 0x3f) << 25) | (funct3 << 12) |
           (((u >> 1) & 0xf) << 8) | (((u >> 11) & 1) << 7) | 0x63;
}

static uint16_t enc_cj(int off)
{
    uint32_t u = (uint32_t) off;
    return (uint16_t) ((0x5u << 13) | (((u >> 11) & 1) << 12) | (((u >> 4) & 1) << 11) |
                       (((u >> 8) & 3) << 9) | (((u >> 10) & 1) << 8) | (((u >> 6) & 1) << 7) |
                       (((u >> 7) & 1) << 6) | (((u >> 1) & 7) << 3) | (((u >> 5) & 1) << 2) |
                       0x1);
}

static uint16_t enc_cb(int off, unsigned funct3)
{
    uint32_t u = (uint32_t) off;
    return (uint16_t) ((funct3 << 13) | (((u >> 8) & 1) << 12) | (((u >> 3) & 3) << 10) |
                       (7u << 7) /* a5 */ | (((u >> 6) & 3) << 5) | (((u >> 1) & 3) << 3) |
                       (((u >> 5) & 1) << 2) | 0x1);
}

static void put32(volatile uint16_t *code, unsigned off, uint32_t w)
{
    code[off / 2] = (uint16_t) w;
    code[off / 2 + 1] = (uint16_t) (w >> 16);
}

static void emit(const struct func *f)
{
    volatile uint16_t *code = ddr_code_p;
    for (unsigned i = 0; i < f->n; i++) {
        const struct insn *x = &f->in[i];
        unsigned off = x->offset;
        int rel = kind_is_cf(x->kind) ? (int) f->in[x->target].offset - (int) off : 0;
        uint32_t imm = (uint32_t) (int32_t) x->imm;
        if (i == 0) {
            put32(code, off, (15u << 7) | 0x13); /* li a5, 0 */
            continue;
        }
        switch (x->kind) {
            case K_ADDI:
                put32(code, off, ((imm & 0xfff) << 20) | (10u << 15) | (10u << 7) | 0x13);
                break;
            case K_CADDI:
                code[off / 2] = (uint16_t) ((((imm >> 5) & 1) << 12) | (10u << 7) |
                                            ((imm & 0x1f) << 2) | 0x1);
                break;
            case K_NOP:
                put32(code, off, 0x00000013u);
                break;
            case K_CNOP:
                code[off / 2] = 0x0001;
                break;
            case K_J:
                put32(code, off, enc_j(rel));
                break;
            case K_CJ:
                code[off / 2] = enc_cj(rel);
                break;
            case K_BEQ:
                put32(code, off, enc_b(rel, 0));
                break;
            case K_BNE:
                put32(code, off, enc_b(rel, 1));
                break;
            case K_CBEQZ:
                code[off / 2] = enc_cb(rel, 6);
                break;
            case K_CBNEZ:
                code[off / 2] = enc_cb(rel, 7);
                break;
            case K_RET:
                put32(code, off, 0x00008067u);
                break;
            case K_CRET:
                code[off / 2] = 0x8082;
                break;
        }
    }
#ifndef SMC_HOST
    __asm__ volatile("fence.i" ::: "memory");
#endif
}

static long model(const struct func *f, long a0)
{
    unsigned i = 1;
    while (i < f->n) {
        const struct insn *x = &f->in[i];
        switch (x->kind) {
            case K_ADDI:
            case K_CADDI:
                a0 += x->imm;
                i++;
                break;
            case K_J:
            case K_CJ:
            case K_BEQ:
            case K_CBEQZ:
                i = x->target;
                break;
            case K_RET:
            case K_CRET:
                return a0;
            default: /* nops and never-taken branches */
                i++;
                break;
        }
    }
    return a0;
}

static int failures;

#ifdef SMC_VERBOSE
static void dump(const char *what, unsigned round, const struct func *f)
{
    static const char *const names[K_COUNT] = {"addi", "c.addi", "nop", "c.nop", "j", "c.j",
                                               "beq", "bne", "c.beqz", "c.bnez", "ret", "c.ret"};
    uart_printf("round %u %s:", round, what);
    for (unsigned i = 1; i < f->n; i++) {
        const struct insn *x = &f->in[i];
        if (kind_is_cf(x->kind)) {
            uart_printf(" %x:%s->%x", x->offset, names[x->kind], f->in[x->target].offset);
        } else if (x->kind == K_ADDI || x->kind == K_CADDI) {
            uart_printf(" %x:%s(%d)", x->offset, names[x->kind], x->imm);
        } else {
            uart_printf(" %x:%s", x->offset, names[x->kind]);
        }
    }
    uart_printf("\n");
}
#else
#define dump(what, round, f) ((void) 0)
#endif

static void run(const char *what, unsigned round, const struct func *f)
{
    dump(what, round, f);
    for (long c = 0; c < CALLS; c++) {
        long arg = (long) (rng() & 0xffff);
        long want = model(f, arg);
#ifdef SMC_HOST
        long got = want;
#else
        long got = ((body_fn_t) (uintptr_t) ddr_code_p)(arg);
#endif
        if (got != want) {
            if (failures < 8) {
                uart_printf("FAIL: round %u %s call %ld got %ld want %ld\n", round, what, c, got,
                            want);
            }
            failures++;
        }
    }
}

int main(void)
{
    static struct func f;
    uart_printf("smc_torture: seed %x rounds %d\n", (unsigned) SMC_SEED, ROUNDS);
    generate(&f);
    emit(&f);
    run("initial", 0, &f);
    for (unsigned round = 1; round <= ROUNDS; round++) {
        if (rng() & 1) {
            patch(&f);
            emit(&f);
            run("patch", round, &f);
        } else {
            generate(&f);
            emit(&f);
            run("regenerate", round, &f);
        }
    }

    if (failures == 0) {
        uart_printf("<<PASS>>\n");
    } else {
        uart_printf("<<FAIL>> (%d failures)\n", failures);
    }

#ifndef SMC_HOST
    while (1) {
    }
#endif
    return 0;
}
