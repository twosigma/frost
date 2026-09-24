/* Code-placement padding for CoreMark measurements. Nothing builds it by
 * default: SRC_C and EXTRA_ASM_SRC in this directory's Makefile do not name it.
 *
 * Linked with EXTRA_ASM_SRC=pad.S, it lands in .init right after crt0, so
 * FROST_PAD_BYTES of dead space shifts every later function, every .rodata
 * object, and every branch PC by a constant. That changes the direct-mapped
 * BTB index (PC[9:2]) and the LQ L0 index ((addr>>3)&127), which separates a
 * code-generation effect from placement luck. From tests/, inside the image:
 *
 *   EXTRA_ASM_SRC=pad.S COREMARK_EXTRA_CFLAGS=-DFROST_PAD_BYTES=512 \
 *       ./test_run_cocotb.py coremark
 *
 * Nothing falls through into the padding: crt0's .init ends with the call to
 * main(), a spin loop, and a literal pool.
 */
#ifndef FROST_PAD_BYTES
#define FROST_PAD_BYTES 0
#endif
    .section .init
    .align  3
#if FROST_PAD_BYTES > 0
    .space  FROST_PAD_BYTES, 0
#endif
