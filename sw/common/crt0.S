    // C Runtime Startup Code (crt0.S) - Executed before main()
    // Initializes processor state, copies initialized data, zeros BSS, then calls main()
    // This code is placed first in memory by the linker script
    .section .init
    .option  push
    .option  norelax          // Keep global pointer (gp) loads absolute (don't optimize)
    .globl  _start
_start:
    // Step 1: Initialize stack pointer (sp) and global pointer (gp)
    // sp points to top of stack (grows downward)
    // gp points to middle of small data region for efficient access
    la      sp, _stack_top
    la      gp, __global_pointer$

    // Step 2: Copy initialized data from ROM to RAM (.data and .sdata sections)
    // Initialized global variables are stored in ROM and must be copied to RAM
    la      t0, __data_load_start // t0 = source address (ROM)
    la      t1, __data_start      // t1 = destination address (RAM)
    la      t2, __data_end        // t2 = end of data section
1:  beq     t1, t2, 2f            // If dst == end, done copying
    lw      t3, 0(t0)             // Load word from ROM
    sw      t3, 0(t1)             // Store word to RAM
    addi    t0, t0, 4             // Advance source pointer by 4 bytes
    addi    t1, t1, 4             // Advance destination pointer by 4 bytes
    j       1b                    // Loop back

    // Step 3: Zero-initialize small BSS section (.sbss)
    // Uninitialized global variables must be set to zero per C standard
2:  la      t0, __sbss_start      // t0 = start of small BSS
    la      t1, __sbss_end        // t1 = end of small BSS
3:  beq     t0, t1, 4f            // If start == end, done zeroing
    sw      zero, 0(t0)           // Write zero to current address
    addi    t0, t0, 4             // Advance pointer by 4 bytes
    j       3b                    // Loop back

    // Step 4: Zero-initialize regular BSS section (.bss)
4:  la      t0, __bss_start       // t0 = start of BSS
    la      t1, __bss_end         // t1 = end of BSS
5:  beq     t0, t1, 6f            // If start == end, done zeroing
    sw      zero, 0(t0)           // Write zero to current address
    addi    t0, t0, 4             // Advance pointer by 4 bytes
    j       5b                    // Loop back

    // Step 5: Zero-initialize the cached-region BSS (.ddr_bss). Empty (the
    // linker PROVIDEs both symbols as 0) unless the unified linker script
    // places zero-init sections in the DDR-backed cached region.
6:  la      t0, __ddr_bss_start
    la      t1, __ddr_bss_end
8:  bgeu    t0, t1, 9f
    sw      zero, 0(t0)
    addi    t0, t0, 4
    j       8b

    // Step 6: Call main() function (C program entry point)
9:  call    main

    // Step 7: If main() returns (shouldn't happen), loop forever
7:  j       7b                    // Infinite loop

    .option  pop
