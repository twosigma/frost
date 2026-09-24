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
 * The probe loop. Every iteration has the shape that exposes the load-queue
 * cached-slot hazard (see main.c), with no store between the settle point
 * of the previous iteration and the probed loads, so nothing holds the
 * memory bus while they launch:
 *
 *   B1 (its condition is rnd bit 0 behind STALE_B1_DIV_CHAIN dependent
 *       divides, 33 cycles each, so it resolves late and at a known time)
 *     arm X: STALE_A_DIV_CHAIN divides and STALE_A_MUL_CHAIN multiplies
 *            delay A1..A3, three loads of untouched lines that launch to
 *            the cached tier and miss before B1 resolves, so their
 *            responses are still in flight well after the recovery.
 *            STALE_A_FILLERS independent fillers in front of them give
 *            A1..A3 ROB tags beyond the ones arm Y allocates up to B2, so
 *            once the recovery reuses the tags, the drained slots' stale
 *            tags read as younger than B2's. Five more loads, A4..A8, wait
 *            on A1's value for their addresses: on the wrong path they
 *            hold queue entries but never launch, and they bring the
 *            path's load count to eight, the load queue's depth, so the
 *            next allocation wraps onto A1's entry. When arm X is the
 *            wrong path every one of these is flushed.
 *     arm Y: N, a load of the untouched marker line (-1), a chain of
 *            STALE_ADD_CHAIN dependent adds on B2's condition (register
 *            resolved, so B2 recovers a fixed number of cycles after N
 *            launched, while N is in flight), B2, then ten P loads of
 *            untouched lines (their per-line signature).
 *
 * rnd bit 0 picks B1's direction (1 = arm Y is the correct path), bit 1
 * picks B2's; rnd is the same xorshift sequence main.c replays. N and
 * P1..P10 are written to out[i*16 + 0..10]; the block's line 0 is then
 * loaded and written to out[i*16 + 11] (it checks that the pool held its
 * signatures without taking a cached slot during the probe), and a FENCE
 * and a short delay settle the machine before the next iteration. The
 * windows scale with the DDR latency: the test registry runs the simulation
 * DDR model at 150 cycles, so the drained responses stay in flight across
 * the second recovery.
 *
 *   void lq_stale_run(unsigned long iters, unsigned long pool,
 *                     unsigned long markers, unsigned long *out,
 *                     unsigned long seed);
 *
 * pool: 4 KiB per iteration of cached DDR whose probed lines main.c wrote
 * and evicted (line 0 at 0, A1..A3 at 64/128/192, A4..A8 from 256, P set 1
 * from 1024, P set 2 from 2048). markers: one -1 dword per iteration, 64
 * bytes apart, likewise evicted.
 */

#ifndef STALE_B1_DIV_CHAIN
#define STALE_B1_DIV_CHAIN 3
#endif
#ifndef STALE_A_DIV_CHAIN
#define STALE_A_DIV_CHAIN 1
#endif
#ifndef STALE_A_MUL_CHAIN
#define STALE_A_MUL_CHAIN 0
#endif
#ifndef STALE_A_FILLERS
#define STALE_A_FILLERS 12
#endif
#ifndef STALE_ADD_CHAIN
#define STALE_ADD_CHAIN 4
#endif

    .macro REPEAT_DIV0 n
    .if \n
    div  t0, t0, s11
    REPEAT_DIV0 "(\n - 1)"
    .endif
    .endm

    .macro REPEAT_DIV n
    .if \n
    div  t2, t2, s11
    REPEAT_DIV "(\n - 1)"
    .endif
    .endm

    .macro REPEAT_MUL n
    .if \n
    mul  t2, t2, s11
    REPEAT_MUL "(\n - 1)"
    .endif
    .endm

    .macro REPEAT_FILL n
    .if \n
    addi t3, a1, (\n) * 8
    REPEAT_FILL "(\n - 1)"
    .endif
    .endm

    .macro REPEAT_ADD n
    .if \n
    add  t2, t2, zero
    REPEAT_ADD "(\n - 1)"
    .endif
    .endm

    .text
    .globl lq_stale_run
    .type lq_stale_run, @function
    .balign 64
lq_stale_run:
    addi sp, sp, -96
    sd   s1, 80(sp)
    sd   s2, 0(sp)
    sd   s3, 8(sp)
    sd   s4, 16(sp)
    sd   s5, 24(sp)
    sd   s6, 32(sp)
    sd   s7, 40(sp)
    sd   s8, 48(sp)
    sd   s9, 56(sp)
    sd   s10, 64(sp)
    sd   s11, 72(sp)
    mv   s2, a0                 /* iterations left */
    mv   s3, a1                 /* pool */
    mv   s4, a2                 /* marker lines */
    mv   s5, a3                 /* out */
    mv   s6, a4                 /* rng state */
    li   s7, 0                  /* iteration index */
    li   s11, 1                 /* the divide/multiply chains' identity */
    fence
    beqz s2, .Lexit

.Lnext:
    /* rnd = xorshift(state) */
    slli t0, s6, 13
    xor  s6, s6, t0
    srli t0, s6, 7
    xor  s6, s6, t0
    slli t0, s6, 17
    xor  s6, s6, t0
    mv   a0, s6
    slli t0, s7, 12
    add  a1, s3, t0             /* blk */
    slli t0, s7, 6
    add  a2, s4, t0             /* marker line */
    slli t0, s7, 7
    add  a3, s5, t0             /* out + i*16 dwords */

    andi t1, a0, 1
    andi s1, a0, 2
    mv   t0, t1
    REPEAT_DIV0 STALE_B1_DIV_CHAIN /* B1's condition: bit 0 behind a divide chain */
    bnez t0, .Larm_y            /* B1 */

    /* ---- arm X ---- */
    addi t2, a1, 64
    REPEAT_DIV STALE_A_DIV_CHAIN /* t2 stays blk+64, ready one chain later */
    REPEAT_MUL STALE_A_MUL_CHAIN
    REPEAT_FILL STALE_A_FILLERS /* independent fillers push A1..A3's tags past B2's */
    ld   s8, 0(t2)              /* A1 */
    ld   s9, 64(t2)             /* A2 */
    ld   s10, 128(t2)           /* A3 */
    andi t5, s8, 0              /* A4..A8 wait on A1's value */
    addi t5, t5, 256
    add  t5, t5, a1
    ld   s11, 0(t5)
    ld   a4, 64(t5)
    ld   a5, 128(t5)
    ld   a6, 192(t5)
    ld   a7, 256(t5)
    add  t6, s9, s10
    li   s11, 1
    j    .Lstore

    /* ---- arm Y ---- */
.Larm_y:
    ld   s8, 0(a2)              /* N: the marker line, a DDR round trip */
    mv   t2, s1
    REPEAT_ADD STALE_ADD_CHAIN  /* B2's condition, ready one chain later */
    addi t3, a1, 1024
    addi t4, a1, 1024
    addi t4, t4, 1024
    bnez t2, .Larm_y2           /* B2 */
    ld   s9, 0(t3)              /* P1..P10, set 1 */
    ld   s10, 64(t3)
    ld   s11, 128(t3)
    ld   a4, 192(t3)
    ld   a5, 256(t3)
    ld   a6, 320(t3)
    ld   a7, 384(t3)
    ld   t5, 448(t3)
    ld   t6, 512(t3)
    ld   t1, 576(t3)
    j    .Lstore
.Larm_y2:
    ld   s9, 0(t4)              /* P1..P10, set 2 */
    ld   s10, 64(t4)
    ld   s11, 128(t4)
    ld   a4, 192(t4)
    ld   a5, 256(t4)
    ld   a6, 320(t4)
    ld   a7, 384(t4)
    ld   t5, 448(t4)
    ld   t6, 512(t4)
    ld   t1, 576(t4)

.Lstore:
    sd   s8, 0(a3)              /* N */
    sd   s9, 8(a3)              /* P1..P10 */
    sd   s10, 16(a3)
    sd   s11, 24(a3)
    sd   a4, 32(a3)
    sd   a5, 40(a3)
    sd   a6, 48(a3)
    sd   a7, 56(a3)
    sd   t5, 64(a3)
    sd   t6, 72(a3)
    sd   t1, 80(a3)
    ld   a0, 0(a1)              /* the block's line 0, loaded after the probe so */
    sd   a0, 88(a3)             /* it takes no slot: out[11], its signature */
    li   s11, 1
    fence
    li   t0, 64                 /* settle: stores drained, ROB empty */
1:  addi t0, t0, -1
    bnez t0, 1b
    addi s7, s7, 1
    addi s2, s2, -1
    bnez s2, .Lnext

.Lexit:
    ld   s2, 0(sp)
    ld   s3, 8(sp)
    ld   s4, 16(sp)
    ld   s5, 24(sp)
    ld   s6, 32(sp)
    ld   s7, 40(sp)
    ld   s8, 48(sp)
    ld   s9, 56(sp)
    ld   s10, 64(sp)
    ld   s11, 72(sp)
    ld   s1, 80(sp)
    addi sp, sp, 96
    ret
    .size lq_stale_run, . - lq_stale_run
