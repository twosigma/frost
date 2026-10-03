#    Copyright 2026 Two Sigma Open Source, LLC
#
#    Licensed under the Apache License, Version 2.0 (the "License");
#    you may not use this file except in compliance with the License.
#    You may obtain a copy of the License at
#
#        http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS,
#    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#    See the License for the specific language governing permissions and
#    limitations under the License.

# UART transmit bursts from back-to-back stores
#
# Each burst starts from an idle transmitter (ns16550 LSR.TEMT) and writes its
# bytes with consecutive stores from preloaded registers, so the next byte is
# already in the transmit FIFO when the FIFO presents the first one to the
# idle uart_tx, which takes it at once. The C programs pace every byte on the
# TX status register and never queue one that early.
#
# The bench decodes the serial TX line (FROST_UART_LINE_CHECK, set by the
# registry) and requires it to carry every byte the CPU wrote, once and in
# order. A FIFO that loads its output from a RAM read issued before its read
# pointer moved sends "AAC" for the first burst.

    .equ UART_TX, 0x40000000
    .equ NS16550_BASE, 0x40001000
    .equ NS16550_LSR, 0x14
    .equ LSR_TEMT, 0x40

    .section .init
    .option push
    .option norvc
    .globl _start

_start:
    li      s0, UART_TX
    li      s1, NS16550_BASE

    # Burst 1: three bytes into an idle transmitter.
    jal     ra, wait_idle
    li      t0, 'A'
    li      t1, 'B'
    li      t2, 'C'
    sb      t0, 0(s0)
    sb      t1, 0(s0)
    sb      t2, 0(s0)

    # Burst 2: eleven bytes, most of them queued behind a busy transmitter.
    jal     ra, wait_idle
    li      t0, '0'
    li      t1, '1'
    li      t2, '2'
    li      t3, '3'
    li      t4, '4'
    li      t5, '5'
    li      a0, '6'
    li      a1, '7'
    li      a2, '8'
    li      a3, '9'
    li      a4, '\n'
    sb      t0, 0(s0)
    sb      t1, 0(s0)
    sb      t2, 0(s0)
    sb      t3, 0(s0)
    sb      t4, 0(s0)
    sb      t5, 0(s0)
    sb      a0, 0(s0)
    sb      a1, 0(s0)
    sb      a2, 0(s0)
    sb      a3, 0(s0)
    sb      a4, 0(s0)

    # Burst 3: the pass marker.
    jal     ra, wait_idle
    li      t0, '<'
    li      t1, 'P'
    li      t2, 'A'
    li      t3, 'S'
    li      t4, '>'
    li      t5, '\n'
    sb      t0, 0(s0)
    sb      t0, 0(s0)
    sb      t1, 0(s0)
    sb      t2, 0(s0)
    sb      t3, 0(s0)
    sb      t3, 0(s0)
    sb      t4, 0(s0)
    sb      t4, 0(s0)
    sb      t5, 0(s0)
done:
    j       done

# wait_idle: return once the transmit FIFO is empty and uart_tx is idle.
wait_idle:
    lw      t6, NS16550_LSR(s1)
    andi    t6, t6, LSR_TEMT
    beqz    t6, wait_idle
    ret

    .option pop
