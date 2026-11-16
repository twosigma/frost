# Svinval encodings, mstatus.TVM/U-mode legality, SYSTEM funct3=000 reserved
# fields, and Sstc S-mode stimecmp gating across menvcfg.STCE x mcounteren.TM.
.4byte 0x10000093 # addi x1, x0, 0x100 (low BRAM mepc)
.4byte 0x34109073 # csrw mepc, x1
.4byte 0x18001073 # csrw satp, x0
.4byte 0x30201073 # csrw medeleg, x0
# M-mode legal Svinval sequence.
.4byte 0x04000293 # addi x5, x0, 64
.4byte 0x00300313 # addi x6, x0, 3
.4byte 0x18000073 # sfence.w.inval
.4byte 0x16000073 # sinval.vma x0, x0
.4byte 0x16628073 # sinval.vma x5, x6
.4byte 0x18100073 # sfence.inval.ir
# Malformed SYSTEM funct3=000 words trap with mtval = instruction bits.
.4byte 0x160000f3 # sinval.vma with rd=x1
.4byte 0x34202173 # csrr x2, mcause
.4byte 0x343021f3 # csrr x3, mtval
.4byte 0x18008073 # sfence.w.inval with rs1=x1
.4byte 0x34202173 # csrr x2, mcause
.4byte 0x343021f3 # csrr x3, mtval
.4byte 0x181000f3 # sfence.inval.ir with rd=x1
.4byte 0x34202173 # csrr x2, mcause
.4byte 0x343021f3 # csrr x3, mtval
.4byte 0x120000f3 # sfence.vma with rd=x1
.4byte 0x34202173 # csrr x2, mcause
.4byte 0x343021f3 # csrr x3, mtval
.4byte 0x00008073 # ecall with rs1=x1
.4byte 0x34202173 # csrr x2, mcause
.4byte 0x343021f3 # csrr x3, mtval
.4byte 0x302000f3 # mret with rd=x1
.4byte 0x34202173 # csrr x2, mcause
.4byte 0x343021f3 # csrr x3, mtval
# S-mode Svinval with mstatus.TVM = 0: all three retire.
.4byte 0x00002237 # lui x4, 0x2
.4byte 0x80020213 # addi x4, x4, -2048 (0x1800 = MPP mask)
.4byte 0x000013b7 # lui x7, 0x1
.4byte 0x80038393 # addi x7, x7, -2048 (0x0800 = MPP_S)
.4byte 0x30023073 # csrc mstatus, x4
.4byte 0x3003a073 # csrs mstatus, x7
.4byte 0x34109073 # csrw mepc, x1
.4byte 0x30200073 # mret -> S-mode
.4byte 0x18000073 # sfence.w.inval
.4byte 0x16628073 # sinval.vma x5, x6
.4byte 0x18100073 # sfence.inval.ir
.4byte 0x00000073 # ecall -> M-mode
.4byte 0x34202173 # csrr x2, mcause
# S-mode Svinval with mstatus.TVM = 1: fences retire, sinval.vma traps.
.4byte 0x00100437 # lui x8, 0x100 (0x100000 = TVM)
.4byte 0x30042073 # csrs mstatus, x8
.4byte 0x30023073 # csrc mstatus, x4
.4byte 0x3003a073 # csrs mstatus, x7
.4byte 0x34109073 # csrw mepc, x1
.4byte 0x30200073 # mret -> S-mode (TVM=1)
.4byte 0x18000073 # sfence.w.inval (legal under TVM=1)
.4byte 0x18100073 # sfence.inval.ir (legal under TVM=1)
.4byte 0x16000073 # sinval.vma x0, x0 (illegal under TVM=1)
.4byte 0x34202173 # csrr x2, mcause
.4byte 0x343021f3 # csrr x3, mtval
.4byte 0x30043073 # csrc mstatus, x8
# U-mode Svinval: all three trap.
.4byte 0x30023073 # csrc mstatus, x4
.4byte 0x34109073 # csrw mepc, x1
.4byte 0x30200073 # mret -> U-mode
.4byte 0x18000073 # sfence.w.inval (illegal in U-mode)
.4byte 0x34202173 # csrr x2, mcause
.4byte 0x30023073 # csrc mstatus, x4
.4byte 0x34109073 # csrw mepc, x1
.4byte 0x30200073 # mret -> U-mode
.4byte 0x18100073 # sfence.inval.ir (illegal in U-mode)
.4byte 0x34202173 # csrr x2, mcause
.4byte 0x30023073 # csrc mstatus, x4
.4byte 0x34109073 # csrw mepc, x1
.4byte 0x30200073 # mret -> U-mode
.4byte 0x16000073 # sinval.vma x0, x0 (illegal in U-mode)
.4byte 0x34202173 # csrr x2, mcause
# Sstc S-mode stimecmp requires both menvcfg.STCE and mcounteren.TM.
.4byte 0x00100493 # addi x9, x0, 1
.4byte 0x03f49493 # slli x9, x9, 63 (STCE)
.4byte 0x00200513 # addi x10, x0, 2 (TM)
.4byte 0x30a49073 # csrw menvcfg, x9 (STCE=1)
.4byte 0x30601073 # csrw mcounteren, x0 (TM=0)
.4byte 0x30023073 # csrc mstatus, x4
.4byte 0x3003a073 # csrs mstatus, x7
.4byte 0x34109073 # csrw mepc, x1
.4byte 0x30200073 # mret -> S-mode
.4byte 0x14d025f3 # csrr x11, stimecmp (STCE=1, TM=0: traps)
.4byte 0x34202173 # csrr x2, mcause
.4byte 0x30a01073 # csrw menvcfg, x0 (STCE=0)
.4byte 0x30651073 # csrw mcounteren, x10 (TM=1)
.4byte 0x30023073 # csrc mstatus, x4
.4byte 0x3003a073 # csrs mstatus, x7
.4byte 0x34109073 # csrw mepc, x1
.4byte 0x30200073 # mret -> S-mode
.4byte 0x14d025f3 # csrr x11, stimecmp (STCE=0, TM=1: traps)
.4byte 0x34202173 # csrr x2, mcause
.4byte 0x30a49073 # csrw menvcfg, x9 (STCE=1)
.4byte 0x30651073 # csrw mcounteren, x10 (TM=1)
.4byte 0x30023073 # csrc mstatus, x4
.4byte 0x3003a073 # csrs mstatus, x7
.4byte 0x34109073 # csrw mepc, x1
.4byte 0x30200073 # mret -> S-mode
.4byte 0x14d31073 # csrw stimecmp, x6
.4byte 0x14d025f3 # csrr x11, stimecmp (STCE=1, TM=1: reads 3)
.4byte 0x00000073 # ecall -> M-mode
.4byte 0x34202173 # csrr x2, mcause
