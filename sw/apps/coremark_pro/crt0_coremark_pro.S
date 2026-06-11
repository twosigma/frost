    // CoreMark-PRO startup.
    //
    // This is local to sw/apps/coremark_pro so the overlap-safe .data copy can
    // support initialized-data images that sit below their runtime RAM address.
    // Define COREMARK_PRO_TRACE=1 to re-enable early UART boot markers.
    .section .init
    .option  push
    .option  norelax
    .globl  _start

_start:
    la      sp, _stack_top
    la      gp, __global_pointer$

    la      t0, early_trap
    csrw    mtvec, t0

#if COREMARK_PRO_TRACE
    la      a0, msg_b0
    call    early_puts
#endif

    // Copy initialized data from its load image to RAM. The load image and RAM
    // destination can overlap inside FROST's 128 KiB low BRAM, so copy backward
    // whenever the destination is above the source.
    la      t0, __data_load_start
    la      t1, __data_start
    la      t2, __data_end
    beq     t1, t2, 2f
    bltu    t0, t1, 12f
1:  beq     t1, t2, 2f
    lw      t3, 0(t0)
    sw      t3, 0(t1)
    addi    t0, t0, 4
    addi    t1, t1, 4
    j       1b

12: sub     t4, t2, t1
    add     t0, t0, t4
    mv      t3, t2
13: beq     t3, t1, 2f
    addi    t0, t0, -4
    addi    t3, t3, -4
    lw      t5, 0(t0)
    sw      t5, 0(t3)
    j       13b

2:  la      a0, msg_b1
#if COREMARK_PRO_TRACE
    call    early_puts
#endif

    // Zero small BSS.
    la      t0, __sbss_start
    la      t1, __sbss_end
3:  beq     t0, t1, 4f
    sw      zero, 0(t0)
    addi    t0, t0, 4
    j       3b

4:  la      a0, msg_b2
#if COREMARK_PRO_TRACE
    call    early_puts
#endif

    // Zero regular BSS.
    la      t0, __bss_start
    la      t1, __bss_end
5:  beq     t0, t1, 6f
    sw      zero, 0(t0)
    addi    t0, t0, 4
    j       5b

6:  la      a0, msg_b3
#if COREMARK_PRO_TRACE
    call    early_puts
#endif

    // Zero the cached-region BSS (.ddr_bss). Empty (PROVIDEd as 0) unless the
    // unified linker script places zero-init sections in the DDR region.
    la      t0, __ddr_bss_start
    la      t1, __ddr_bss_end
9:  bgeu    t0, t1, 10f
    sw      zero, 0(t0)
    addi    t0, t0, 4
    j       9b

10: call    main

7:  j       7b

early_trap:
    la      a0, msg_trap
    call    early_puts
8:  j       8b

early_puts:
    mv      t4, a0
9:  lbu     t5, 0(t4)
    beqz    t5, 11f
10: la      t0, UART_TX_STATUS_ADDR
    lw      t1, 0(t0)
    andi    t1, t1, 1
    beqz    t1, 10b
    la      t0, UART_ADDR
    sb      t5, 0(t0)
    addi    t4, t4, 1
    j       9b
11: ret

msg_b0:
    .asciz  "<<BOOT0>>\n"
msg_b1:
    .asciz  "<<BOOT1>>\n"
msg_b2:
    .asciz  "<<BOOT2>>\n"
msg_b3:
    .asciz  "<<BOOT3>>\n"
msg_trap:
    .asciz  "<<BOOT_TRAP>>\n"

    .option pop
