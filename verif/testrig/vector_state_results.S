# Vector CSRs and scalar results at VLEN 128, 256 and 512.
# Tail and mask undisturbed. The scalar checks read only the five
# initialized mask bits or element zero of an initialized vector.
.noshrink
# VS encodings with FS Off.
.4byte 0x000062b7  # lui t0, 0x6
.4byte 0x60028293  # addi t0, t0, 0x600
.4byte 0x3002b073  # csrc mstatus, t0
.4byte 0x30002373  # csrr t1, mstatus
.4byte 0x00935313  # srli t1, t1, 9
.4byte 0x00337513  # andi a0, t1, 3
.assert rd_addr == 10 "andi a0, t1, 3 writes x10"
.assert rd_wdata == 0x0 "andi a0, t1, 3 result"
.4byte 0xc002f557  # vsetivli a0, 5, e8, m1, tu, mu
.assert trap == 1 "vsetivli traps with VS Off"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "csrr a0, mcause writes x10"
.assert rd_wdata == 0x2 "csrr a0, mcause result"

.4byte 0x20000293  # addi t0, zero, 0x200
.4byte 0x3002a073  # csrs mstatus, t0
.4byte 0x30002373  # csrr t1, mstatus
.4byte 0x00935313  # srli t1, t1, 9
.4byte 0x00337513  # andi a0, t1, 3
.assert rd_addr == 10 "andi a0, t1, 3 writes x10"
.assert rd_wdata == 0x1 "andi a0, t1, 3 result"
.4byte 0x60000293  # addi t0, zero, 0x600
.4byte 0x3002b073  # csrc mstatus, t0
.4byte 0x40000293  # addi t0, zero, 0x400
.4byte 0x3002a073  # csrs mstatus, t0
.4byte 0x30002373  # csrr t1, mstatus
.4byte 0x00935313  # srli t1, t1, 9
.4byte 0x00337513  # andi a0, t1, 3
.assert rd_addr == 10 "andi a0, t1, 3 writes x10"
.assert rd_wdata == 0x2 "andi a0, t1, 3 result"

# The successful configuration writes vector state and sets VS Dirty.
.4byte 0xc002f557  # vsetivli a0, 5, e8, m1, tu, mu
.assert rd_addr == 10 "vsetivli a0, 5, e8, m1, tu, mu writes x10"
.assert rd_wdata == 0x5 "vsetivli a0, 5, e8, m1, tu, mu result"
.4byte 0xc20025f3  # csrr a1, vl
.assert rd_addr == 11 "csrr a1, vl writes x11"
.assert rd_wdata == 0x5 "csrr a1, vl result"
.4byte 0xc2102673  # csrr a2, vtype
.assert rd_addr == 12 "csrr a2, vtype writes x12"
.assert rd_wdata == 0x0 "csrr a2, vtype result"
.4byte 0x30002373  # csrr t1, mstatus
.4byte 0x00935393  # srli t2, t1, 9
.4byte 0x0033f693  # andi a3, t2, 3
.assert rd_addr == 13 "andi a3, t2, 3 writes x13"
.assert rd_wdata == 0x3 "andi a3, t2, 3 result"
.4byte 0x03f35713  # srli a4, t1, 63
.assert rd_addr == 14 "srli a4, t1, 63 writes x14"
.assert rd_wdata == 0x1 "srli a4, t1, 63 result"

# vsetvl reads a vtype from a register and clears vstart.
.4byte 0x00200293  # addi t0, zero, 2
.4byte 0x00829073  # csrw vstart, t0
.4byte 0x00802573  # csrr a0, vstart
.assert rd_addr == 10 "csrr a0, vstart writes x10"
.assert rd_wdata == 0x2 "csrr a0, vstart result"
.4byte 0x00300293  # addi t0, zero, 3
.4byte 0x00800313  # addi t1, zero, 8
.4byte 0x8062f557  # vsetvl a0, t0, t1
.assert rd_addr == 10 "vsetvl a0, t0, t1 writes x10"
.assert rd_wdata == 0x3 "vsetvl a0, t0, t1 result"
.4byte 0xc20025f3  # csrr a1, vl
.assert rd_addr == 11 "csrr a1, vl writes x11"
.assert rd_wdata == 0x3 "csrr a1, vl result"
.4byte 0xc2102673  # csrr a2, vtype
.assert rd_addr == 12 "csrr a2, vtype writes x12"
.assert rd_wdata == 0x8 "csrr a2, vtype result"
.4byte 0x008026f3  # csrr a3, vstart
.assert rd_addr == 13 "csrr a3, vstart writes x13"
.assert rd_wdata == 0x0 "csrr a3, vstart result"
.4byte 0xc2202773  # csrr a4, vlenb
.assert rd_addr == 14 "csrr a4, vlenb writes x14"

.4byte 0x00500293  # addi t0, zero, 5
.4byte 0x00f29073  # csrw vcsr, t0
.4byte 0x00f02573  # csrr a0, vcsr
.assert rd_addr == 10 "csrr a0, vcsr writes x10"
.assert rd_wdata == 0x5 "csrr a0, vcsr result"
.4byte 0x00a025f3  # csrr a1, vxrm
.assert rd_addr == 11 "csrr a1, vxrm writes x11"
.assert rd_wdata == 0x2 "csrr a1, vxrm result"
.4byte 0x00902673  # csrr a2, vxsat
.assert rd_addr == 12 "csrr a2, vxsat writes x12"
.assert rd_wdata == 0x1 "csrr a2, vxsat result"

# Initialize the active mask bits through element zero.
.4byte 0xc000f057  # vsetivli zero, 1, e8, m1, tu, mu
.4byte 0x01600293  # addi t0, zero, 22
.4byte 0x4202e057  # vmv.s.x v0, t0
.4byte 0x01500293  # addi t0, zero, 21
.4byte 0x4202e0d7  # vmv.s.x v1, t0
.4byte 0x42006157  # vmv.s.x v2, zero
.4byte 0xc002f057  # vsetivli zero, 5, e8, m1, tu, mu
.4byte 0x42182557  # vcpop.m a0, v1
.assert rd_addr == 10 "vcpop.m a0, v1 writes x10"
.assert rd_wdata == 0x3 "vcpop.m a0, v1 result"
.4byte 0x4218a5d7  # vfirst.m a1, v1
.assert rd_addr == 11 "vfirst.m a1, v1 writes x11"
.assert rd_wdata == 0x0 "vfirst.m a1, v1 result"
.4byte 0x40182657  # vcpop.m a2, v1, v0.t
.assert rd_addr == 12 "vcpop.m a2, v1, v0.t writes x12"
.assert rd_wdata == 0x2 "vcpop.m a2, v1, v0.t result"
.4byte 0x4018a6d7  # vfirst.m a3, v1, v0.t
.assert rd_addr == 13 "vfirst.m a3, v1, v0.t writes x13"
.assert rd_wdata == 0x2 "vfirst.m a3, v1, v0.t result"
.4byte 0x42282757  # vcpop.m a4, v2
.assert rd_addr == 14 "vcpop.m a4, v2 writes x14"
.assert rd_wdata == 0x0 "vcpop.m a4, v2 result"
.4byte 0x4228a7d7  # vfirst.m a5, v2
.assert rd_addr == 15 "vfirst.m a5, v2 writes x15"
.assert rd_wdata == 0xffffffffffffffff "vfirst.m a5, v2 result"

# Scalar FP extraction, with the FP register exposed through x registers.
.4byte 0x000062b7  # lui t0, 0x6
.4byte 0x3002a073  # csrs mstatus, t0
.4byte 0xc100f057  # vsetivli zero, 1, e32, m1, tu, mu
.4byte 0x3f8002b7  # lui t0, 0x3f800
.4byte 0x4202e1d7  # vmv.s.x v3, t0
.4byte 0x42301057  # vfmv.f.s ft0, v3
.assert trap == 0 "vfmv.f.s retires"
.4byte 0xe0000553  # fmv.x.w a0, ft0
.assert rd_addr == 10 "fmv.x.w a0, ft0 writes x10"
.assert rd_wdata == 0x3f800000 "fmv.x.w a0, ft0 result"
.4byte 0xe20005d3  # fmv.x.d a1, ft0
.assert rd_addr == 11 "fmv.x.d a1, ft0 writes x11"
.assert rd_wdata == 0xffffffff3f800000 "fmv.x.d a1, ft0 result"
.4byte 0xc180f057  # vsetivli zero, 1, e64, m1, tu, mu
.4byte 0xc00002b7  # lui t0, 0xc0000
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x4202e1d7  # vmv.s.x v3, t0
.4byte 0x42301057  # vfmv.f.s ft0, v3
.assert trap == 0 "vfmv.f.s retires"
.4byte 0xe2000553  # fmv.x.d a0, ft0
.assert rd_addr == 10 "fmv.x.d a0, ft0 writes x10"
.assert rd_wdata == 0xc000000000000000 "fmv.x.d a0, ft0 result"
