# Zawrs: wrs.sto and wrs.nto in M (with mstatus.TW set), in S and U with TW
# clear, and inside an LR/SC reservation window on cached DDR.
.4byte 0x800402b7 # lui x5, 0x80040
.4byte 0x02029293 # slli x5, x5, 32
.4byte 0x0202d293 # srli x5, x5, 32
.4byte 0x30529073 # csrw mtvec, x5
# M-mode with TW=1 and an active LR.D reservation on 0x8000_2000.
.4byte 0x00200337 # lui x6, 0x200
.4byte 0x30031073 # csrw mstatus, x6
.4byte 0x800023b7 # lui x7, 0x80002
.4byte 0x02039393 # slli x7, x7, 32
.4byte 0x0203d393 # srli x7, x7, 32
.4byte 0x1003b42f # lr.d x8, (x7)
.4byte 0x01d00073 # wrs.sto
.4byte 0x00d00073 # wrs.nto
.4byte 0x1873b4af # sc.d x9, x7, (x7)
# Enter S-mode with TW=0, execute wrs.sto, wrs.nto and wfi, then ecall to M.
.4byte 0x00001337 # lui x6, 0x1
.4byte 0x8003031b # addiw x6, x6, -2048
.4byte 0x30031073 # csrw mstatus, x6
.4byte 0x80000337 # lui x6, 0x80000
.4byte 0x1003031b # addiw x6, x6, 256
.4byte 0x02031313 # slli x6, x6, 32
.4byte 0x02035313 # srli x6, x6, 32
.4byte 0x34131073 # csrw mepc, x6
.4byte 0x30200073 # mret
.4byte 0x01d00073 # wrs.sto
.4byte 0x00d00073 # wrs.nto
.4byte 0x10500073 # wfi
.4byte 0x00000073 # ecall
.4byte 0x34202573 # csrr x10, mcause
# Enter U-mode with TW=0, execute wrs.sto and wrs.nto, then trap on wfi.
.4byte 0x30001073 # csrw mstatus, x0
.4byte 0x34131073 # csrw mepc, x6
.4byte 0x30200073 # mret
.4byte 0x01d00073 # wrs.sto
.4byte 0x00d00073 # wrs.nto
.4byte 0x10500073 # wfi
.4byte 0x342025f3 # csrr x11, mcause
.4byte 0x34302673 # csrr x12, mtval
