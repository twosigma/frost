# Machine counters 3..10 have writable storage and reset-disabled selectors.
# Machine counters and selectors 11..31 read zero and ignore writes.
# User aliases 3..10 mirror machine storage; user aliases 11..31 read zero in
# M-mode and trap on writes or below M-mode.
.4byte 0xb03022f3 # csrr x5, mhpmcounter3
.4byte 0xb1f022f3 # csrr x5, mhpmcounter31
.4byte 0x323022f3 # csrr x5, mhpmevent3
.4byte 0x33f022f3 # csrr x5, mhpmevent31
.4byte 0xfff00313 # addi x6, x0, -1
.4byte 0xb0331073 # csrw mhpmcounter3, x6
.4byte 0xb03023f3 # csrr x7, mhpmcounter3
.4byte 0xc0302473 # csrr x8, hpmcounter3
.4byte 0x33f31073 # csrw mhpmevent31, x6
.4byte 0x33f023f3 # csrr x7, mhpmevent31
.4byte 0xc0b02473 # csrr x8, hpmcounter11 (zero in M-mode)
.4byte 0xc0b31073 # csrw hpmcounter11, x6 (read-only: traps)
