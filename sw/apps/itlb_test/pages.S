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
 * Code pages for the Sv39 fetch-translation test (Phase 3 M5).
 *
 * Each page is 4 KiB-aligned and position-independent: it holds constants and
 * ecall only, and the page-crossing jump is a raw relative JAL. The driver can
 * therefore map any of them at any virtual page. Every page has a head marker,
 * so a direct entry reports which page ran. Encodings are written as raw words
 * where the halfword placement matters.
 *
 *   page_a   head: a0 = 0xA1; ecall
 *            tail: 0xFF8 addi a1, zero, 0xA4 | 0xFFC c.nop |
 *                  0xFFE low half of "addi a0, zero, 0xA3" (straddles into
 *                  the next page's word 0)
 *   page_b   head: 0x000 high half of that addi | 0x002 ecall
 *   page_a2  head: a0 = 0xA5; ecall
 *            tail: 0xFFC c.nop | 0xFFE c.nop (a compressed pair whose
 *                  successor is the next page's word 0)
 *   page_b2  head: a0 = 0xB1; ecall
 *   page_j   head: jal x0, +4096 (falls into the next virtual page)
 *   page_e   head: a0 = 0xCC; ecall
 *   page_c   six entries (0x000, 0x040, 0x080, 0x0C0, 0x100, 0xE00): auipc ra, 1;
 *            addi ra, ra, off; jalr x0, 0(ra) -- an indirect jump into the
 *            NEXT virtual page at 0x000, 0x008, 0x010, 0x020, 0x040, 0xFF8;
 *            six more (0x200..0x340) load ra from the data page four
 *            virtual pages up and return through c.jr / jalr at every
 *            window position, all into the next page's head
 *            a seventh (0x380) targets 0x5E0, the vDSO trampoline's offset
 *   page_t   at each of those offsets (and 0x5E0: a0 = 0xD6): a0 = 0xD0 + k; ecall, nop-filled
 *            between them, so a skipped first instruction reports a0 = 0
 *            and a skipped window reports the next pair's marker
 */

    /* No linker relaxation: with it, .balign emits maximal NOP padding
     * that the linker later shrinks, which moves the location counter past
     * the .org offsets below. Every instruction here is a fixed encoding. */
    .option norelax

    .section .text.itlb_page_a, "ax", @progbits
    .balign 4096
    .globl itlb_page_a
itlb_page_a:
    .word 0x0A100513            /* addi a0, zero, 0xA1 */
    .word 0x00000073            /* ecall */
    .org 0xFF8
    .word 0x0A400593            /* addi a1, zero, 0xA4 */
    .half 0x0001                /* c.nop */
    .half 0x0513                /* addi a0, zero, 0xA3: low half */

    .section .text.itlb_page_b, "ax", @progbits
    .balign 4096
    .globl itlb_page_b
itlb_page_b:
    .half 0x0A30                /* addi a0, zero, 0xA3: high half */
    .word 0x00000073            /* ecall (at offset 2) */
    .org 0x1000 - 4
    .word 0x00000013            /* keep the page fully populated */

    .section .text.itlb_page_a2, "ax", @progbits
    .balign 4096
    .globl itlb_page_a2
itlb_page_a2:
    .word 0x0A500513            /* addi a0, zero, 0xA5 */
    .word 0x00000073            /* ecall */
    .org 0xFFC
    .half 0x0001                /* c.nop */
    .half 0x0001                /* c.nop */

    .section .text.itlb_page_b2, "ax", @progbits
    .balign 4096
    .globl itlb_page_b2
itlb_page_b2:
    .word 0x0B100513            /* addi a0, zero, 0xB1 */
    .word 0x00000073            /* ecall */
    .org 0x1000 - 4
    .word 0x00000013

    .section .text.itlb_page_j, "ax", @progbits
    .balign 4096
    .globl itlb_page_j
itlb_page_j:
    .word 0x0000106F            /* jal x0, +4096 */
    .org 0x1000 - 4
    .word 0x00000013

    .section .text.itlb_page_e, "ax", @progbits
    .balign 4096
    .globl itlb_page_e
itlb_page_e:
    .word 0x0CC00513            /* addi a0, zero, 0xCC */
    .word 0x00000073            /* ecall */
    .org 0x1000 - 4
    .word 0x00000013

    .section .text.itlb_page_c, "ax", @progbits
    .balign 4096
    .globl itlb_page_c
itlb_page_c:
    .org 0x000
    .word 0x00001097            /* auipc ra, 1: the next virtual page */
    .word 0x00008093            /* addi ra, ra, 0x0 -> page_t + 0x000 */
    .word 0x00008067            /* jalr x0, 0(ra) */
    .org 0x040
    .word 0x00001097            /* auipc ra, 1: the next virtual page */
    .word 0xFC808093            /* addi ra, ra, -0x38 -> page_t + 0x008 */
    .word 0x00008067            /* jalr x0, 0(ra) */
    .org 0x080
    .word 0x00001097            /* auipc ra, 1: the next virtual page */
    .word 0xF9008093            /* addi ra, ra, -0x70 -> page_t + 0x010 */
    .word 0x00008067            /* jalr x0, 0(ra) */
    .org 0x0C0
    .word 0x00001097            /* auipc ra, 1: the next virtual page */
    .word 0xF6008093            /* addi ra, ra, -0xa0 -> page_t + 0x020 */
    .word 0x00008067            /* jalr x0, 0(ra) */
    .org 0x100
    .word 0x00001097            /* auipc ra, 1: the next virtual page */
    .word 0xF4008093            /* addi ra, ra, -0xc0 -> page_t + 0x040 */
    .word 0x00008067            /* jalr x0, 0(ra) */
    /* Load-based returns (the kernel handler epilogue's shape): ra comes
     * from the data page four virtual pages up (auipc t0, 4 lands at this
     * entry's offset in it), so the jump resolves only after that load's
     * own walk. The return
     * instruction sits at every window position: c.jr ra at +0/+2/+4/+6 of
     * an 8-byte window, and the 32-bit jalr at +0 and +2 (0xF0 blocks). */
    .org 0x200
    .word 0x00004297            /* auipc t0, 4 */
    .word 0x0002B083            /* ld ra, 0(t0): auipc already carries this entry's offset */
    .half 0x8082                /* c.jr ra (window +0) */
    .org 0x240
    .word 0x00004297            /* auipc t0, 4 */
    .word 0x0002B083            /* ld ra, 0(t0): auipc already carries this entry's offset */
    .half 0x0001                /* c.nop */
    .half 0x8082                /* c.jr ra (window +2) */
    .org 0x280
    .word 0x00004297            /* auipc t0, 4 */
    .word 0x0002B083            /* ld ra, 0(t0): auipc already carries this entry's offset */
    .half 0x0001                /* c.nop */
    .half 0x0001                /* c.nop */
    .half 0x8082                /* c.jr ra (window +4) */
    .org 0x2C0
    .word 0x00004297            /* auipc t0, 4 */
    .word 0x0002B083            /* ld ra, 0(t0): auipc already carries this entry's offset */
    .half 0x0001                /* c.nop */
    .half 0x0001                /* c.nop */
    .half 0x0001                /* c.nop */
    .half 0x8082                /* c.jr ra (window +6) */
    .org 0x300
    .word 0x00004297            /* auipc t0, 4 */
    .word 0x0002B083            /* ld ra, 0(t0): auipc already carries this entry's offset */
    .word 0x00008067            /* jalr x0, 0(ra) (window +0) */
    .org 0x340
    .word 0x00004297            /* auipc t0, 4 */
    .word 0x0002B083            /* ld ra, 0(t0): auipc already carries this entry's offset */
    .half 0x0001                /* c.nop */
    .word 0x00008067            /* jalr x0, 0(ra) (window +2, straddling) */
    .org 0x380
    .word 0x00001097            /* auipc ra, 1: the next virtual page */
    .word 0x26008093            /* addi ra, ra, 0x260 -> page_t + 0x5E0 (the vDSO's offset) */
    .word 0x00008067            /* jalr x0, 0(ra) */
    .org 0xE00
    .word 0x00001097            /* auipc ra, 1: the next virtual page */
    .word 0x1F808093            /* addi ra, ra, 0x1f8 -> page_t + 0xFF8 */
    .word 0x00008067            /* jalr x0, 0(ra) */
    .org 0x1000 - 4
    .word 0x00000013

    .section .text.itlb_page_t, "ax", @progbits
    .balign 4096
    .globl itlb_page_t
itlb_page_t:
    .word 0x0D000513            /* addi a0, zero, 0xD0 (offset 0x000) */
    .word 0x00000073            /* ecall */
    .fill (0x008 - (. - itlb_page_t)) / 4, 4, 0x00000013
    .word 0x0D100513            /* addi a0, zero, 0xD1 (offset 0x008) */
    .word 0x00000073            /* ecall */
    .fill (0x010 - (. - itlb_page_t)) / 4, 4, 0x00000013
    .word 0x0D200513            /* addi a0, zero, 0xD2 (offset 0x010) */
    .word 0x00000073            /* ecall */
    .fill (0x020 - (. - itlb_page_t)) / 4, 4, 0x00000013
    .word 0x0D300513            /* addi a0, zero, 0xD3 (offset 0x020) */
    .word 0x00000073            /* ecall */
    .fill (0x040 - (. - itlb_page_t)) / 4, 4, 0x00000013
    .word 0x0D400513            /* addi a0, zero, 0xD4 (offset 0x040) */
    .word 0x00000073            /* ecall */
    .fill (0x5E0 - (. - itlb_page_t)) / 4, 4, 0x00000013
    .word 0x0D600513            /* addi a0, zero, 0xD6 (offset 0x5E0) */
    .word 0x00000073            /* ecall */
    .fill (0xFF8 - (. - itlb_page_t)) / 4, 4, 0x00000013
    .word 0x0D500513            /* addi a0, zero, 0xD5 (offset 0xFF8) */
    .word 0x00000073            /* ecall */

    /*
     * Z (cached tier): DDR-resident twins of the Linux signal-return pages,
     * fetched through the L1I fetch provider rather than the low-BRAM
     * presenter. The layouts mirror the kernel's: a user text page holding
     * the interrupted body and the handler, and a text page whose stub at
     * 0x5E0 is the vDSO's `li a7, 139; ecall` followed by zero padding, with
     * the line before it zero as well. Control stubs sit at 0x000 (a line
     * start at the page head) and 0x7E8 (line offset 8). Every instruction
     * is a fixed encoding.
     *
     *   ddr_page_u  0x000: li a7, 0x104 (the "wait4" number); jal ra, 0x100
     *                      (the RAS now holds 0x008, a user return address);
     *                      0x008: li a7, 0x105; ecall (the done marker, only
     *                      reached if the wrapper returns)
     *               0x100: ecall (the interrupted syscall); ret
     *               0x200: li a7, 0x104; ecall (the body without a call)
     *               0x300: handler: li a7, 0x104; li a0, 0x99; li a2, 0x88;
     *                      c.jr ra
     *               0x380: the same handler returning through jalr x0, 0(ra)
     *               0x3B4: the same, with the jalr at 0x3C0 (a line start, as
     *                      busybox ash's signal_handler returns)
     *   ddr_page_t  0x000 / 0x5E0 / 0x7E8: li a7, 139; ecall; zeros
     *   ddr_thrash  16.5 KiB of straight-line nops and a ret: run from
     *               M-mode at its physical address, it walks every L1I set
     *               and cycles the provider's slots and victim store, so the
     *               next fetch of ddr_page_t misses all the way to L2
     *   z_s_handler the S-mode "kernel": ecall from U with state 0 is the
     *               interrupted syscall: it writes a signal frame to the
     *               data page (SUM), points sepc at the handler and ra at
     *               the stub, optionally sfence.vma's, and srets; state 1 is
     *               the stub's ecall: it records a7 and sepc and ecalls to M
     *               with a0 = 0xE1, a1 = a7. An instruction page fault inside
     *               the stub page is the kernel's lazy vDSO map: install the
     *               PTE named by the control block, sfence.vma the address,
     *               count it, and sret to the faulting PC. Anything else
     *               reports a0 = 0xEE, a1 = scause. sscratch points at the
     *               control block of 8-byte fields:
     *                 0 state          1 data VA        2 handler VA
     *                 3 stub VA        4 sfence flag    5 a7 seen at the stub
     *                 6 sepc at stub   7 scause seen    8 lazy PTE address
     *                 9 lazy PTE value 10 fault count   11 stub page VA
     *                12 fault sepc    13 PTE to rewrite before the sret
     *                14 its new value (13 = 0: none)
     */
    .section .ddr_text.itlb_ddr_page_u, "ax", @progbits
    .balign 4096
    .globl itlb_ddr_page_u
itlb_ddr_page_u:
    .org 0x000
    .word 0x10400893            /* addi a7, zero, 0x104 */
    .word 0x0FC000EF            /* jal ra, +0xfc -> 0x100 (RAS: 0x008) */
    .word 0x10500893            /* addi a7, zero, 0x105 (offset 0x008) */
    .word 0x00000073            /* ecall */
    .word 0x0000006F            /* j . */
    .org 0x100
    .word 0x00000073            /* ecall: the interrupted syscall */
    .word 0x00008067            /* ret */
    .org 0x200
    .word 0x10400893            /* addi a7, zero, 0x104 */
    .word 0x00000073            /* ecall */
    .word 0x0000006F            /* j . */
    .org 0x300
    .word 0x10400893            /* addi a7, zero, 0x104 */
    .word 0x09900513            /* addi a0, zero, 0x99 */
    .word 0x08800613            /* addi a2, zero, 0x88 */
    .half 0x8082                /* c.jr ra (offset 0x30C) */
    .half 0x0001                /* c.nop */
    .org 0x380
    .word 0x10400893            /* addi a7, zero, 0x104 */
    .word 0x09900513            /* addi a0, zero, 0x99 */
    .word 0x08800613            /* addi a2, zero, 0x88 */
    .word 0x00008067            /* jalr x0, 0(ra) (offset 0x38C) */
    .org 0x3B4
    .word 0x10400893            /* addi a7, zero, 0x104 */
    .word 0x09900513            /* addi a0, zero, 0x99 */
    .word 0x08800613            /* addi a2, zero, 0x88 */
    .word 0x00008067            /* jalr x0, 0(ra) (offset 0x3C0, a line start) */
    .org 0x1000 - 4
    .word 0x00000013

    .section .ddr_text.itlb_ddr_page_t, "ax", @progbits
    .balign 4096
    .globl itlb_ddr_page_t
itlb_ddr_page_t:
    .word 0x08B00893            /* addi a7, zero, 139 (offset 0x000) */
    .word 0x00000073            /* ecall */
    .fill (0x5E0 - (. - itlb_ddr_page_t)) / 4, 4, 0x00000000
    .word 0x08B00893            /* addi a7, zero, 139 (offset 0x5E0, the vDSO's) */
    .word 0x00000073            /* ecall */
    .fill (0x7E8 - (. - itlb_ddr_page_t)) / 4, 4, 0x00000000
    .word 0x08B00893            /* addi a7, zero, 139 (offset 0x7E8) */
    .word 0x00000073            /* ecall */
    .fill (0x1000 - (. - itlb_ddr_page_t)) / 4, 4, 0x00000000

    .section .ddr_text.itlb_ddr_thrash, "ax", @progbits
    .balign 64
    .globl itlb_ddr_thrash
itlb_ddr_thrash:
    .fill 4224, 4, 0x00000013   /* 16.5 KiB of nops: every L1I set */
    .word 0x00008067            /* ret */

    .section .ddr_text.itlb_ddr_z_s_handler, "ax", @progbits
    .balign 64
    .globl itlb_ddr_z_s_handler
itlb_ddr_z_s_handler:
    csrr t0, sscratch
    csrr t1, scause
    li   t2, 8
    bne  t1, t2, 9f
    ld   t2, 0(t0)
    bnez t2, 1f
    /* state 0: deliver the signal */
    lui  t1, 0x40               /* sstatus.SUM */
    csrs sstatus, t1
    ld   t1, 8(t0)
    sd   t0, 0(t1)
    sd   t1, 8(t1)
    sd   t2, 16(t1)
    sd   ra, 24(t1)
    sd   sp, 32(t1)
    sd   a0, 40(t1)
    sd   a1, 48(t1)
    sd   a7, 56(t1)
    sd   t0, 64(t1)
    sd   t1, 72(t1)
    sd   t2, 80(t1)
    sd   ra, 88(t1)
    sd   sp, 96(t1)
    sd   a0, 104(t1)
    sd   a1, 112(t1)
    sd   a7, 120(t1)
    /* Optional PTE rewrite before the return (the page holding the RAS's
     * return address goes away or turns S-only, as the kernel's world
     * differs from the handler's). */
    ld   t1, 104(t0)
    beqz t1, 3f
    ld   t2, 112(t0)
    sd   t2, 0(t1)
3:
    ld   t1, 16(t0)
    csrw sepc, t1
    ld   ra, 24(t0)
    ld   t1, 32(t0)
    beqz t1, 2f
    sfence.vma
2:
    li   t2, 1
    sd   t2, 0(t0)
    sret
1:
    /* state 1: the stub's ecall */
    sd   a7, 40(t0)
    csrr t1, sepc
    sd   t1, 48(t0)
    li   a0, 0xE1
    mv   a1, a7
    ecall
    j    .
9:
    /* An instruction page fault inside the stub page: the lazy vDSO map. */
    li   t2, 12
    bne  t1, t2, 8f
    csrr t2, stval
    ld   t3, 88(t0)
    srli t2, t2, 12
    srli t3, t3, 12
    bne  t2, t3, 8f
    ld   t2, 64(t0)
    ld   t3, 72(t0)
    sd   t3, 0(t2)
    ld   t2, 80(t0)
    addi t2, t2, 1
    sd   t2, 80(t0)
    csrr t2, sepc
    sd   t2, 96(t0)
    csrr t2, stval
    sfence.vma t2, x0
    sret
8:
    sd   t1, 56(t0)
    csrr t1, sepc
    sd   t1, 48(t0)
    li   a0, 0xEE
    csrr a1, scause
    ecall
    j    .
