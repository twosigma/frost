# Zfa FLI.H with Zvfh at VLEN 128, 256 and 512.
# Sail 0.16 gates Zvfh on mstatus.VS != Off, so VS is enabled alongside FS;
# vec_fp_test checks FLI.H with VS Off on RTL and Spike.
.noshrink
# Enable FS and VS and clear fcsr.
.4byte 0x000062b7  # lui t0, 0x6
.4byte 0x60028293  # addi t0, t0, 0x600
.4byte 0x3002a073  # csrs mstatus, t0
.4byte 0x00305073  # csrwi fcsr, 0

# All 32 half-precision constants, NaN-boxed in f5 with zero fflags.
.4byte 0xf41002d3  # fli.h f5, 0 (-1.0)
.assert trap == 0 "fli.h idx 0 retires"
.4byte 0xe2028553  # fmv.x.d a0, f5
.assert rd_addr == 10 "fli.h idx 0 writes a0"
.assert rd_wdata == 0xffffffffffffbc00 "fli.h idx 0 is -1.0"
.4byte 0x001015f3  # csrrw a1, fflags, zero
.assert rd_addr == 11 "fli.h idx 0 flags write a1"
.assert rd_wdata == 0x0 "fli.h idx 0 raises no flags"
.4byte 0xf41082d3  # fli.h f5, 1 (2^-14 (min normal))
.assert trap == 0 "fli.h idx 1 retires"
.4byte 0xe2028553  # fmv.x.d a0, f5
.assert rd_addr == 10 "fli.h idx 1 writes a0"
.assert rd_wdata == 0xffffffffffff0400 "fli.h idx 1 is 2^-14 (min normal)"
.4byte 0x001015f3  # csrrw a1, fflags, zero
.assert rd_addr == 11 "fli.h idx 1 flags write a1"
.assert rd_wdata == 0x0 "fli.h idx 1 raises no flags"
.4byte 0xf41102d3  # fli.h f5, 2 (2^-16 (subnormal))
.assert trap == 0 "fli.h idx 2 retires"
.4byte 0xe2028553  # fmv.x.d a0, f5
.assert rd_addr == 10 "fli.h idx 2 writes a0"
.assert rd_wdata == 0xffffffffffff0100 "fli.h idx 2 is 2^-16 (subnormal)"
.4byte 0x001015f3  # csrrw a1, fflags, zero
.assert rd_addr == 11 "fli.h idx 2 flags write a1"
.assert rd_wdata == 0x0 "fli.h idx 2 raises no flags"
.4byte 0xf41182d3  # fli.h f5, 3 (2^-15 (subnormal))
.assert trap == 0 "fli.h idx 3 retires"
.4byte 0xe2028553  # fmv.x.d a0, f5
.assert rd_addr == 10 "fli.h idx 3 writes a0"
.assert rd_wdata == 0xffffffffffff0200 "fli.h idx 3 is 2^-15 (subnormal)"
.4byte 0x001015f3  # csrrw a1, fflags, zero
.assert rd_addr == 11 "fli.h idx 3 flags write a1"
.assert rd_wdata == 0x0 "fli.h idx 3 raises no flags"
.4byte 0xf41202d3  # fli.h f5, 4 (2^-8)
.assert trap == 0 "fli.h idx 4 retires"
.4byte 0xe2028553  # fmv.x.d a0, f5
.assert rd_addr == 10 "fli.h idx 4 writes a0"
.assert rd_wdata == 0xffffffffffff1c00 "fli.h idx 4 is 2^-8"
.4byte 0x001015f3  # csrrw a1, fflags, zero
.assert rd_addr == 11 "fli.h idx 4 flags write a1"
.assert rd_wdata == 0x0 "fli.h idx 4 raises no flags"
.4byte 0xf41282d3  # fli.h f5, 5 (2^-7)
.assert trap == 0 "fli.h idx 5 retires"
.4byte 0xe2028553  # fmv.x.d a0, f5
.assert rd_addr == 10 "fli.h idx 5 writes a0"
.assert rd_wdata == 0xffffffffffff2000 "fli.h idx 5 is 2^-7"
.4byte 0x001015f3  # csrrw a1, fflags, zero
.assert rd_addr == 11 "fli.h idx 5 flags write a1"
.assert rd_wdata == 0x0 "fli.h idx 5 raises no flags"
.4byte 0xf41302d3  # fli.h f5, 6 (2^-4)
.assert trap == 0 "fli.h idx 6 retires"
.4byte 0xe2028553  # fmv.x.d a0, f5
.assert rd_addr == 10 "fli.h idx 6 writes a0"
.assert rd_wdata == 0xffffffffffff2c00 "fli.h idx 6 is 2^-4"
.4byte 0x001015f3  # csrrw a1, fflags, zero
.assert rd_addr == 11 "fli.h idx 6 flags write a1"
.assert rd_wdata == 0x0 "fli.h idx 6 raises no flags"
.4byte 0xf41382d3  # fli.h f5, 7 (2^-3)
.assert trap == 0 "fli.h idx 7 retires"
.4byte 0xe2028553  # fmv.x.d a0, f5
.assert rd_addr == 10 "fli.h idx 7 writes a0"
.assert rd_wdata == 0xffffffffffff3000 "fli.h idx 7 is 2^-3"
.4byte 0x001015f3  # csrrw a1, fflags, zero
.assert rd_addr == 11 "fli.h idx 7 flags write a1"
.assert rd_wdata == 0x0 "fli.h idx 7 raises no flags"
.4byte 0xf41402d3  # fli.h f5, 8 (0.25)
.assert trap == 0 "fli.h idx 8 retires"
.4byte 0xe2028553  # fmv.x.d a0, f5
.assert rd_addr == 10 "fli.h idx 8 writes a0"
.assert rd_wdata == 0xffffffffffff3400 "fli.h idx 8 is 0.25"
.4byte 0x001015f3  # csrrw a1, fflags, zero
.assert rd_addr == 11 "fli.h idx 8 flags write a1"
.assert rd_wdata == 0x0 "fli.h idx 8 raises no flags"
.4byte 0xf41482d3  # fli.h f5, 9 (0.3125)
.assert trap == 0 "fli.h idx 9 retires"
.4byte 0xe2028553  # fmv.x.d a0, f5
.assert rd_addr == 10 "fli.h idx 9 writes a0"
.assert rd_wdata == 0xffffffffffff3500 "fli.h idx 9 is 0.3125"
.4byte 0x001015f3  # csrrw a1, fflags, zero
.assert rd_addr == 11 "fli.h idx 9 flags write a1"
.assert rd_wdata == 0x0 "fli.h idx 9 raises no flags"
.4byte 0xf41502d3  # fli.h f5, 10 (0.375)
.assert trap == 0 "fli.h idx 10 retires"
.4byte 0xe2028553  # fmv.x.d a0, f5
.assert rd_addr == 10 "fli.h idx 10 writes a0"
.assert rd_wdata == 0xffffffffffff3600 "fli.h idx 10 is 0.375"
.4byte 0x001015f3  # csrrw a1, fflags, zero
.assert rd_addr == 11 "fli.h idx 10 flags write a1"
.assert rd_wdata == 0x0 "fli.h idx 10 raises no flags"
.4byte 0xf41582d3  # fli.h f5, 11 (0.4375)
.assert trap == 0 "fli.h idx 11 retires"
.4byte 0xe2028553  # fmv.x.d a0, f5
.assert rd_addr == 10 "fli.h idx 11 writes a0"
.assert rd_wdata == 0xffffffffffff3700 "fli.h idx 11 is 0.4375"
.4byte 0x001015f3  # csrrw a1, fflags, zero
.assert rd_addr == 11 "fli.h idx 11 flags write a1"
.assert rd_wdata == 0x0 "fli.h idx 11 raises no flags"
.4byte 0xf41602d3  # fli.h f5, 12 (0.5)
.assert trap == 0 "fli.h idx 12 retires"
.4byte 0xe2028553  # fmv.x.d a0, f5
.assert rd_addr == 10 "fli.h idx 12 writes a0"
.assert rd_wdata == 0xffffffffffff3800 "fli.h idx 12 is 0.5"
.4byte 0x001015f3  # csrrw a1, fflags, zero
.assert rd_addr == 11 "fli.h idx 12 flags write a1"
.assert rd_wdata == 0x0 "fli.h idx 12 raises no flags"
.4byte 0xf41682d3  # fli.h f5, 13 (0.625)
.assert trap == 0 "fli.h idx 13 retires"
.4byte 0xe2028553  # fmv.x.d a0, f5
.assert rd_addr == 10 "fli.h idx 13 writes a0"
.assert rd_wdata == 0xffffffffffff3900 "fli.h idx 13 is 0.625"
.4byte 0x001015f3  # csrrw a1, fflags, zero
.assert rd_addr == 11 "fli.h idx 13 flags write a1"
.assert rd_wdata == 0x0 "fli.h idx 13 raises no flags"
.4byte 0xf41702d3  # fli.h f5, 14 (0.75)
.assert trap == 0 "fli.h idx 14 retires"
.4byte 0xe2028553  # fmv.x.d a0, f5
.assert rd_addr == 10 "fli.h idx 14 writes a0"
.assert rd_wdata == 0xffffffffffff3a00 "fli.h idx 14 is 0.75"
.4byte 0x001015f3  # csrrw a1, fflags, zero
.assert rd_addr == 11 "fli.h idx 14 flags write a1"
.assert rd_wdata == 0x0 "fli.h idx 14 raises no flags"
.4byte 0xf41782d3  # fli.h f5, 15 (0.875)
.assert trap == 0 "fli.h idx 15 retires"
.4byte 0xe2028553  # fmv.x.d a0, f5
.assert rd_addr == 10 "fli.h idx 15 writes a0"
.assert rd_wdata == 0xffffffffffff3b00 "fli.h idx 15 is 0.875"
.4byte 0x001015f3  # csrrw a1, fflags, zero
.assert rd_addr == 11 "fli.h idx 15 flags write a1"
.assert rd_wdata == 0x0 "fli.h idx 15 raises no flags"
.4byte 0xf41802d3  # fli.h f5, 16 (1.0)
.assert trap == 0 "fli.h idx 16 retires"
.4byte 0xe2028553  # fmv.x.d a0, f5
.assert rd_addr == 10 "fli.h idx 16 writes a0"
.assert rd_wdata == 0xffffffffffff3c00 "fli.h idx 16 is 1.0"
.4byte 0x001015f3  # csrrw a1, fflags, zero
.assert rd_addr == 11 "fli.h idx 16 flags write a1"
.assert rd_wdata == 0x0 "fli.h idx 16 raises no flags"
.4byte 0xf41882d3  # fli.h f5, 17 (1.25)
.assert trap == 0 "fli.h idx 17 retires"
.4byte 0xe2028553  # fmv.x.d a0, f5
.assert rd_addr == 10 "fli.h idx 17 writes a0"
.assert rd_wdata == 0xffffffffffff3d00 "fli.h idx 17 is 1.25"
.4byte 0x001015f3  # csrrw a1, fflags, zero
.assert rd_addr == 11 "fli.h idx 17 flags write a1"
.assert rd_wdata == 0x0 "fli.h idx 17 raises no flags"
.4byte 0xf41902d3  # fli.h f5, 18 (1.5)
.assert trap == 0 "fli.h idx 18 retires"
.4byte 0xe2028553  # fmv.x.d a0, f5
.assert rd_addr == 10 "fli.h idx 18 writes a0"
.assert rd_wdata == 0xffffffffffff3e00 "fli.h idx 18 is 1.5"
.4byte 0x001015f3  # csrrw a1, fflags, zero
.assert rd_addr == 11 "fli.h idx 18 flags write a1"
.assert rd_wdata == 0x0 "fli.h idx 18 raises no flags"
.4byte 0xf41982d3  # fli.h f5, 19 (1.75)
.assert trap == 0 "fli.h idx 19 retires"
.4byte 0xe2028553  # fmv.x.d a0, f5
.assert rd_addr == 10 "fli.h idx 19 writes a0"
.assert rd_wdata == 0xffffffffffff3f00 "fli.h idx 19 is 1.75"
.4byte 0x001015f3  # csrrw a1, fflags, zero
.assert rd_addr == 11 "fli.h idx 19 flags write a1"
.assert rd_wdata == 0x0 "fli.h idx 19 raises no flags"
.4byte 0xf41a02d3  # fli.h f5, 20 (2.0)
.assert trap == 0 "fli.h idx 20 retires"
.4byte 0xe2028553  # fmv.x.d a0, f5
.assert rd_addr == 10 "fli.h idx 20 writes a0"
.assert rd_wdata == 0xffffffffffff4000 "fli.h idx 20 is 2.0"
.4byte 0x001015f3  # csrrw a1, fflags, zero
.assert rd_addr == 11 "fli.h idx 20 flags write a1"
.assert rd_wdata == 0x0 "fli.h idx 20 raises no flags"
.4byte 0xf41a82d3  # fli.h f5, 21 (2.5)
.assert trap == 0 "fli.h idx 21 retires"
.4byte 0xe2028553  # fmv.x.d a0, f5
.assert rd_addr == 10 "fli.h idx 21 writes a0"
.assert rd_wdata == 0xffffffffffff4100 "fli.h idx 21 is 2.5"
.4byte 0x001015f3  # csrrw a1, fflags, zero
.assert rd_addr == 11 "fli.h idx 21 flags write a1"
.assert rd_wdata == 0x0 "fli.h idx 21 raises no flags"
.4byte 0xf41b02d3  # fli.h f5, 22 (3.0)
.assert trap == 0 "fli.h idx 22 retires"
.4byte 0xe2028553  # fmv.x.d a0, f5
.assert rd_addr == 10 "fli.h idx 22 writes a0"
.assert rd_wdata == 0xffffffffffff4200 "fli.h idx 22 is 3.0"
.4byte 0x001015f3  # csrrw a1, fflags, zero
.assert rd_addr == 11 "fli.h idx 22 flags write a1"
.assert rd_wdata == 0x0 "fli.h idx 22 raises no flags"
.4byte 0xf41b82d3  # fli.h f5, 23 (4.0)
.assert trap == 0 "fli.h idx 23 retires"
.4byte 0xe2028553  # fmv.x.d a0, f5
.assert rd_addr == 10 "fli.h idx 23 writes a0"
.assert rd_wdata == 0xffffffffffff4400 "fli.h idx 23 is 4.0"
.4byte 0x001015f3  # csrrw a1, fflags, zero
.assert rd_addr == 11 "fli.h idx 23 flags write a1"
.assert rd_wdata == 0x0 "fli.h idx 23 raises no flags"
.4byte 0xf41c02d3  # fli.h f5, 24 (8.0)
.assert trap == 0 "fli.h idx 24 retires"
.4byte 0xe2028553  # fmv.x.d a0, f5
.assert rd_addr == 10 "fli.h idx 24 writes a0"
.assert rd_wdata == 0xffffffffffff4800 "fli.h idx 24 is 8.0"
.4byte 0x001015f3  # csrrw a1, fflags, zero
.assert rd_addr == 11 "fli.h idx 24 flags write a1"
.assert rd_wdata == 0x0 "fli.h idx 24 raises no flags"
.4byte 0xf41c82d3  # fli.h f5, 25 (16.0)
.assert trap == 0 "fli.h idx 25 retires"
.4byte 0xe2028553  # fmv.x.d a0, f5
.assert rd_addr == 10 "fli.h idx 25 writes a0"
.assert rd_wdata == 0xffffffffffff4c00 "fli.h idx 25 is 16.0"
.4byte 0x001015f3  # csrrw a1, fflags, zero
.assert rd_addr == 11 "fli.h idx 25 flags write a1"
.assert rd_wdata == 0x0 "fli.h idx 25 raises no flags"
.4byte 0xf41d02d3  # fli.h f5, 26 (128.0)
.assert trap == 0 "fli.h idx 26 retires"
.4byte 0xe2028553  # fmv.x.d a0, f5
.assert rd_addr == 10 "fli.h idx 26 writes a0"
.assert rd_wdata == 0xffffffffffff5800 "fli.h idx 26 is 128.0"
.4byte 0x001015f3  # csrrw a1, fflags, zero
.assert rd_addr == 11 "fli.h idx 26 flags write a1"
.assert rd_wdata == 0x0 "fli.h idx 26 raises no flags"
.4byte 0xf41d82d3  # fli.h f5, 27 (256.0)
.assert trap == 0 "fli.h idx 27 retires"
.4byte 0xe2028553  # fmv.x.d a0, f5
.assert rd_addr == 10 "fli.h idx 27 writes a0"
.assert rd_wdata == 0xffffffffffff5c00 "fli.h idx 27 is 256.0"
.4byte 0x001015f3  # csrrw a1, fflags, zero
.assert rd_addr == 11 "fli.h idx 27 flags write a1"
.assert rd_wdata == 0x0 "fli.h idx 27 raises no flags"
.4byte 0xf41e02d3  # fli.h f5, 28 (2^15)
.assert trap == 0 "fli.h idx 28 retires"
.4byte 0xe2028553  # fmv.x.d a0, f5
.assert rd_addr == 10 "fli.h idx 28 writes a0"
.assert rd_wdata == 0xffffffffffff7800 "fli.h idx 28 is 2^15"
.4byte 0x001015f3  # csrrw a1, fflags, zero
.assert rd_addr == 11 "fli.h idx 28 flags write a1"
.assert rd_wdata == 0x0 "fli.h idx 28 raises no flags"
.4byte 0xf41e82d3  # fli.h f5, 29 (+inf (2^16 overflow))
.assert trap == 0 "fli.h idx 29 retires"
.4byte 0xe2028553  # fmv.x.d a0, f5
.assert rd_addr == 10 "fli.h idx 29 writes a0"
.assert rd_wdata == 0xffffffffffff7c00 "fli.h idx 29 is +inf (2^16 overflow)"
.4byte 0x001015f3  # csrrw a1, fflags, zero
.assert rd_addr == 11 "fli.h idx 29 flags write a1"
.assert rd_wdata == 0x0 "fli.h idx 29 raises no flags"
.4byte 0xf41f02d3  # fli.h f5, 30 (+inf)
.assert trap == 0 "fli.h idx 30 retires"
.4byte 0xe2028553  # fmv.x.d a0, f5
.assert rd_addr == 10 "fli.h idx 30 writes a0"
.assert rd_wdata == 0xffffffffffff7c00 "fli.h idx 30 is +inf"
.4byte 0x001015f3  # csrrw a1, fflags, zero
.assert rd_addr == 11 "fli.h idx 30 flags write a1"
.assert rd_wdata == 0x0 "fli.h idx 30 raises no flags"
.4byte 0xf41f82d3  # fli.h f5, 31 (canonical qNaN)
.assert trap == 0 "fli.h idx 31 retires"
.4byte 0xe2028553  # fmv.x.d a0, f5
.assert rd_addr == 10 "fli.h idx 31 writes a0"
.assert rd_wdata == 0xffffffffffff7e00 "fli.h idx 31 is canonical qNaN"
.4byte 0x001015f3  # csrrw a1, fflags, zero
.assert rd_addr == 11 "fli.h idx 31 flags write a1"
.assert rd_wdata == 0x0 "fli.h idx 31 raises no flags"

# Reserved frm=7 is ignored by fli.h.
.4byte 0x0023d073  # csrwi frm, 7
.4byte 0xf41802d3  # fli.h f5, 16 (1.0)
.assert trap == 0 "fli.h with frm=7 retires"
.4byte 0xe2028553  # fmv.x.d a0, f5
.assert rd_addr == 10 "fli.h with frm=7 writes a0"
.assert rd_wdata == 0xffffffffffff3c00 "fli.h with frm=7 returns 1.0"
.4byte 0x001015f3  # csrrw a1, fflags, zero
.assert rd_addr == 11 "fli.h with frm=7 flags write a1"
.assert rd_wdata == 0x0 "fli.h with frm=7 raises no flags"
.4byte 0x00205073  # csrwi frm, 0

# fli.h dirties mstatus.FS from Clean.
.4byte 0x000062b7  # lui t0, 0x6
.4byte 0x3002b073  # csrc mstatus, t0
.4byte 0x000042b7  # lui t0, 0x4
.4byte 0x3002a073  # csrs mstatus, t0
.4byte 0xf41002d3  # fli.h f5, 0 (-1.0)
.assert trap == 0 "fli.h from FS Clean retires"
.4byte 0x30002573  # csrr a0, mstatus
.4byte 0x00d55513  # srli a0, a0, 13
.4byte 0x00357513  # andi a0, a0, 3
.assert rd_addr == 10 "FS state writes a0"
.assert rd_wdata == 0x3 "fli.h dirties FS from Clean"

# Nonzero funct3 traps as illegal instruction.
.4byte 0xf41812d3  # fli.h f5, 16 with funct3=1 (reserved)
.assert trap == 1 "fli.h with funct3=1 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "mcause writes a0"
.assert rd_wdata == 0x2 "fli.h with funct3=1 raises illegal instruction"

# mstatus.FS Off traps fli.h as illegal instruction.
.4byte 0x000062b7  # lui t0, 0x6
.4byte 0x3002b073  # csrc mstatus, t0
.4byte 0xf41802d3  # fli.h f5, 16 with FS Off
.assert trap == 1 "fli.h with FS Off traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "mcause writes a0"
.assert rd_wdata == 0x2 "fli.h with FS Off raises illegal instruction"
.4byte 0x3002a073  # csrs mstatus, t0
