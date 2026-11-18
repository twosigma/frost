// Copyright (c) 2026 John Goodacre.
// pd_itt_slot2 probe. Branch B is taken three iterations in four, so the BTB
// predicts it taken and the tagged predictor learns the not-taken fourth. The
// instruction after B is a non-return indirect call that runs only on the
// not-taken iterations, so the indirect target predictor learns its target.
// In the packet where B sits in slot 1, the call sits in the killed slot 2. A
// not-taken PD redirect for B must go to the call (B's fall-through). If it
// goes to the call's predicted target instead, the callee runs without the
// call: ra still holds the sentinel, and the callee returns to kva_bad.
    .text
    .option norvc
    .globl  pd_itt_probe
    .align  6
// a0 = iteration, a1 = callee
pd_itt_probe:
    addi    sp, sp, -16
    sd      ra, 8(sp)
    andi    t0, a0, 3
    addi    t0, t0, -3
    la      ra, pd_itt_bad              // sentinel: a skipped call returns here
    bnez    t0, 1f                      // B: taken unless (a0 & 3) == 3
    jalr    ra, 0(a1)                   // the call (B's fall-through)
    .globl  pd_itt_after_call
pd_itt_after_call:
    j       2f
1:  addi    t1, t1, 1
2:  ld      ra, 8(sp)
    addi    sp, sp, 16
    ret

    .globl  pd_itt_callee
    .align  4
pd_itt_callee:
    la      t1, pd_itt_calls
    ld      t2, 0(t1)
    addi    t2, t2, 1
    sd      t2, 0(t1)
    la      t1, pd_itt_after_call
    beq     ra, t1, 3f
    la      t1, pd_itt_bad_ra           // a wrong return address: count it
    ld      t2, 0(t1)
    addi    t2, t2, 1
    sd      t2, 0(t1)
3:  ret

pd_itt_bad:                             // reached only when the call was skipped
    la      t1, pd_itt_skipped
    ld      t2, 0(t1)
    addi    t2, t2, 1
    sd      t2, 0(t1)
    j       2b

    .data
    .align  3
    .globl  pd_itt_calls, pd_itt_skipped, pd_itt_bad_ra
pd_itt_calls:   .dword 0
pd_itt_skipped: .dword 0
pd_itt_bad_ra:  .dword 0
