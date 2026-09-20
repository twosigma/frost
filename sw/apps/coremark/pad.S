/* Placement-ensemble padding. Measurement only; nothing builds this by
 * default, because SRC_C and EXTRA_ASM_SRC in this directory's Makefile do not
 * name it.
 *
 * Linked with EXTRA_ASM_SRC=pad.S it lands in .init immediately after crt0,
 * so FROST_PAD_BYTES of dead space shifts every later function, every .rodata
 * object and every branch PC by a constant, without changing one instruction.
 * That resamples the direct-mapped BTB index (PC[9:2]) and the LQ L0 index
 * ((addr>>3)&127), which is how a codegen result is told apart from placement
 * luck: over N = 0/64/128/256/512/1024 the shipped build spans 0.045% of
 * timed-region ticks.
 *
 *   EXTRA_ASM_SRC=pad.S COREMARK_EXTRA_CFLAGS=-DFROST_PAD_BYTES=512 \
 *       ./test_run_cocotb.py coremark
 *
 * Nothing falls through into the padding: crt0's .init ends in a call to
 * main() and a literal pool.
 */
#ifndef FROST_PAD_BYTES
#define FROST_PAD_BYTES 0
#endif
    .section .init
    .align  3
#if FROST_PAD_BYTES > 0
    .space  FROST_PAD_BYTES, 0
#endif
