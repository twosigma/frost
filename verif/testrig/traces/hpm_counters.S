# The machine HPM counters and event selectors exist, read zero, and ignore
# writes; FROST raised illegal instruction for them (issue #58). The user
# alias hpmcounter3 does not exist and traps on both.
.4byte 0xb03022f3 # csrr x5, mhpmcounter3
.4byte 0xb1f022f3 # csrr x5, mhpmcounter31
.4byte 0x323022f3 # csrr x5, mhpmevent3
.4byte 0x33f022f3 # csrr x5, mhpmevent31
.4byte 0xfff00313 # addi x6, x0, -1
.4byte 0xb0331073 # csrw mhpmcounter3, x6
.4byte 0xb03023f3 # csrr x7, mhpmcounter3
.4byte 0x33f31073 # csrw mhpmevent31, x6
.4byte 0x33f023f3 # csrr x7, mhpmevent31
.4byte 0xc0302473 # csrr x8, hpmcounter3 (illegal: no Zihpm user counters)
