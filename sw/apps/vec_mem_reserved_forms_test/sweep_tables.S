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
 * Exhaustive compile-time instruction tables in .text so the unit-stride
 * (8,192 encodings) and whole-register alignment (256 encodings) sweeps run
 * directly from instruction memory with no self-modifying code or fence.i on
 * the passing path. main.c cross-checks every word in these tables at runtime
 * against the C specification oracle before executing them.
 */

.section .text.sweep, "ax"
.option push
.option norvc
.option norelax

.equ RES_MOP00_N, 7978
.equ DEF_MOP00_N, 214
.equ RES_WHOLE_N, 136
.equ DEF_WHOLE_N, 120

.macro emit_unit_stride want_def, with_step=0
  .irp _st, 0, 1
    .if \_st == 0
      .set _opc, 0x07
    .else
      .set _opc, 0x27
    .endif
    .set _umop, 0
    .rept 32
      .set _nf, 0
      .rept 8
        .irp _mew, 0, 1
          .irp _w, 0, 5, 6, 7
            .irp _vm, 0, 1
              .set _def, 0
              .if \_mew == 0
                .if _umop == 0x00
                  .set _def, 1
                .elseif _umop == 0x08
                  .if (\_vm == 1) && ((_nf == 0) || (_nf == 1) || (_nf == 3) || (_nf == 7)) && ((\_st == 0) || (\_w == 0))
                    .set _def, 1
                  .endif
                .elseif _umop == 0x0b
                  .if (\_vm == 1) && (_nf == 0) && (\_w == 0)
                    .set _def, 1
                  .endif
                .elseif _umop == 0x10
                  .if \_st == 0
                    .set _def, 1
                  .endif
                .endif
              .endif
              .if _def == \want_def
                .if \with_step
                  jal ra, def_step
                .endif
                .word (_nf << 29) | (\_mew << 28) | (\_vm << 25) | (_umop << 20) | (10 << 15) | (\_w << 12) | (8 << 7) | _opc
              .endif
            .endr
          .endr
        .endr
        .set _nf, _nf + 1
      .endr
      .set _umop, _umop + 1
    .endr
  .endr
.endm

.macro emit_jal_ra off
  .word ((((\off) >> 20) & 1) << 31) | ((((\off) >> 1) & 0x3ff) << 21) | ((((\off) >> 11) & 1) << 20) | ((((\off) >> 12) & 0xff) << 12) | (1 << 7) | 0x6f
.endm

.macro emit_whole_align want_ok, with_step=0
  .irp _st, 0, 1
    .if \_st == 0
      .set _opc, 0x07
    .else
      .set _opc, 0x27
    .endif
    .irp _nf, 0, 1, 3, 7
      .set _reg, 0
      .rept 32
        .if (_reg & \_nf) == 0
          .set _ok, 1
        .else
          .set _ok, 0
        .endif
        .if _ok == \want_ok
          .if \with_step
            jal ra, def_step
          .endif
          .word (\_nf << 29) | (1 << 25) | (0x08 << 20) | (10 << 15) | (_reg << 7) | _opc
        .endif
        .set _reg, _reg + 1
      .endr
    .endr
  .endr
.endm

/*
 * Reserved mop = 00 dispatch + packed table.
 * Each slot A[i] executes `jal ra, B[i]`, pushing &A[i+1] onto the return
 * stack; fast_trap_reserved verifies mcause/mtval against *s2, records the
 * next encoding and case index in *s7, and returns directly to A[i+1].
 */
.balign 4
.globl res_mop00_dispatch
res_mop00_dispatch:
.rept RES_MOP00_N
  emit_jal_ra (4 * (RES_MOP00_N + 1))
.endr
  jr s1

.globl res_mop00_table
res_mop00_table:
  emit_unit_stride 0
.globl res_mop00_table_end
res_mop00_table_end:
  j fast_notrap_tail

.if (res_mop00_table - res_mop00_dispatch) != 4 * (RES_MOP00_N + 1)
  .error "res_mop00_dispatch size mismatch"
.endif
.if (res_mop00_table_end - res_mop00_table) != 4 * RES_MOP00_N
  .error "res_mop00_table size mismatch"
.endif

/* Defined mop = 00 packed word table (for oracle check and replay) + runner. */
.balign 4
.globl def_mop00_table
def_mop00_table:
  emit_unit_stride 1, 0
.globl def_mop00_table_end
def_mop00_table_end:

.if (def_mop00_table_end - def_mop00_table) != 4 * DEF_MOP00_N
  .error "def_mop00_table size mismatch"
.endif

.balign 4
.globl def_mop00_exec
def_mop00_exec:
  emit_unit_stride 1, 1
  jr s1

/* Reserved whole-register alignment dispatch + packed table. */
.balign 4
.globl res_whole_dispatch
res_whole_dispatch:
.rept RES_WHOLE_N
  emit_jal_ra (4 * (RES_WHOLE_N + 1))
.endr
  jr s1

.globl res_whole_table
res_whole_table:
  emit_whole_align 0
.globl res_whole_table_end
res_whole_table_end:
  j fast_notrap_tail

.if (res_whole_table - res_whole_dispatch) != 4 * (RES_WHOLE_N + 1)
  .error "res_whole_dispatch size mismatch"
.endif
.if (res_whole_table_end - res_whole_table) != 4 * RES_WHOLE_N
  .error "res_whole_table size mismatch"
.endif

/* Defined whole-register alignment table + runner under vill = 1. */
.balign 4
.globl def_whole_table
def_whole_table:
  emit_whole_align 1, 0
.globl def_whole_table_end
def_whole_table_end:

.if (def_whole_table_end - def_whole_table) != 4 * DEF_WHOLE_N
  .error "def_whole_table size mismatch"
.endif

.balign 4
.globl def_whole_exec
def_whole_exec:
  emit_whole_align 1, 1
  jr s1

/* Record the next defined encoding and 1-based case index before executing it. */
.balign 4
def_step:
  lwu t4, 0(s2)
  addi s2, s2, 4
  sw t4, 0(s7)
  sw s8, 4(s7)
  addi s8, s8, 1
  ret

/* Sentinel tail reached only if the last slot of a reserved table does not trap. */
.balign 4
fast_notrap_tail:
  bnez s5, 1f
  mv s10, s8
1:
  addi s5, s5, 1
  ret

/* Register-only M-mode trap handler for reserved-table sweeps:
 *   s2  = expected uint32_t encoding pointer (advances by 4 per trap)
 *   s3  = expected mcause (2)
 *   s4  = verified-trap counter
 *   s5  = mismatch counter
 *   s7  = active-case record pointer ({ uint32_t insn; uint32_t case_num; })
 *   s8  = 1-based case index of the encoding just checked
 *   s9  = table end pointer
 *   s10 = 1-based case index of the first mismatch
 * Returns directly to ra (the next dispatch slot); M-mode with MIE = 0 needs
 * no mepc/mret round trip. */
.balign 4
.globl fast_trap_reserved
fast_trap_reserved:
  lwu t4, 0(s2)
  addi s2, s2, 4
  csrr t2, mcause
  csrr t3, mtval
  bne t2, s3, 1f
  bne t3, t4, 1f
  addi s4, s4, 1
  j 2f
1:
  bnez s5, 3f
  mv s10, s8
3:
  addi s5, s5, 1
2:
  addi s8, s8, 1
  bgeu s2, s9, 4f
  lwu t4, 0(s2)
  sw t4, 0(s7)
  sw s8, 4(s7)
4:
  ret

/* Trap handler for defined-table runners: records an unexpected trap in t1,
 * remembers the first failing 1-based case in s10, and skips the 4-byte
 * instruction so execution finishes cleanly and triggers verbose replay. */
.balign 4
.globl fast_trap_skip
fast_trap_skip:
  bnez t1, 1f
  addi s10, s8, -1
1:
  addi t1, t1, 1
  csrr t0, mepc
  addi t0, t0, 4
  csrw mepc, t0
  mret

/* Register-only trap handler for verbose failure replay via code_buf. */
.balign 4
.globl fast_trap_replay
fast_trap_replay:
  addi t1, t1, 1
  csrr t2, mcause
  csrr t3, mtval
  ret

/* Call a reserved dispatch table:
 *   a0 = dispatch_pc, a1 = base, a2 = table, a3 = table_end,
 *   a4 = case_log, a5 = case_base, a6 = fail_out, a7 = first_fail_case_out.
 * Returns verified-trap count. */
.balign 4
.globl run_reserved_table
run_reserved_table:
  addi sp, sp, -96
  sd ra, 0(sp)
  sd s1, 8(sp)
  sd s2, 16(sp)
  sd s3, 24(sp)
  sd s4, 32(sp)
  sd s5, 40(sp)
  sd s6, 48(sp)
  sd s7, 56(sp)
  sd s8, 64(sp)
  sd s9, 72(sp)
  sd s10, 80(sp)
  sd s11, 88(sp)
  mv t0, a0
  mv a0, a1
  mv s2, a2
  mv s9, a3
  mv s7, a4
  mv s8, a5
  mv s6, a6
  mv s11, a7
  li s3, 2
  li s4, 0
  li s5, 0
  mv s10, s8
  lwu t4, 0(s2)
  sw t4, 0(s7)
  sw s8, 4(s7)
  jal s1, 2f
  j 1f
2:
  jr t0
1:
  sd s5, 0(s6)
  sd s10, 0(s11)
  mv a0, s4
  ld ra, 0(sp)
  ld s1, 8(sp)
  ld s2, 16(sp)
  ld s3, 24(sp)
  ld s4, 32(sp)
  ld s5, 40(sp)
  ld s6, 48(sp)
  ld s7, 56(sp)
  ld s8, 64(sp)
  ld s9, 72(sp)
  ld s10, 80(sp)
  ld s11, 88(sp)
  addi sp, sp, 96
  ret

/* Call a defined-table runner:
 *   a0 = exec_pc, a1 = base, a2 = table, a3 = case_log,
 *   a4 = case_base, a5 = first_fail_case_out.
 * Returns unexpected-trap count. */
.balign 4
.globl run_defined_table
run_defined_table:
  addi sp, sp, -64
  sd ra, 0(sp)
  sd s1, 8(sp)
  sd s2, 16(sp)
  sd s7, 24(sp)
  sd s8, 32(sp)
  sd s10, 40(sp)
  sd s11, 48(sp)
  mv t0, a0
  mv a0, a1
  mv s2, a2
  mv s7, a3
  mv s8, a4
  mv s11, a5
  mv s10, s8
  li t1, 0
  jal s1, 2f
  j 1f
2:
  jr t0
1:
  sd s10, 0(s11)
  mv a0, t1
  ld ra, 0(sp)
  ld s1, 8(sp)
  ld s2, 16(sp)
  ld s7, 24(sp)
  ld s8, 32(sp)
  ld s10, 40(sp)
  ld s11, 48(sp)
  addi sp, sp, 64
  ret

.option pop
