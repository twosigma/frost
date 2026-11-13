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

/**
 * Vector state smoke test: vlenb, vsetvli, vsetivli, vsetvl, vl and vtype
 * for every legal and several illegal configurations, vstart, vxrm, vxsat,
 * vcsr, and mstatus.VS. Written without any vector memory access so that it
 * is the first vector program to bring up.
 *
 * Checks, for VLEN = 8 * vlenb and ELEN = 64:
 *   - vlenb is a power of two between 16 and 64 bytes.
 *   - For every SEW and LMUL, an AVL above VLMAX gives vl = VLMAX,
 *     AVL <= VLMAX gives vl = AVL, and AVL = 0 gives vl = 0.
 *   - A reserved vtype (SEW > ELEN, LMUL * ELEN < SEW, reserved LMUL
 *     encodings) sets vill, clears vl and vstart, and still writes rd.
 *   - vtype reads back the written vsew, vlmul, vta and vma.
 *   - rd = x0, rs1 = x0 keeps vl; rd != x0, rs1 = x0 sets vl = VLMAX.
 *   - vxrm, vxsat and the vcsr alias update each other.
 *   - vstart is writable and vsetvli clears it; vl is read-only.
 *   - mstatus.VS reads Dirty after a vector instruction changes state.
 */

#include "vec_test.h"

#define STR_(x) #x
#define STR(x) STR_(x)


/* Run vsetvl with a register vtype so one routine covers every encoding. */
static unsigned long
do_vsetvl(unsigned long avl, unsigned long vtype, unsigned long *vtype_out, unsigned long *vl_csr)
{
    unsigned long vl, vt, vlc;
    __asm__ volatile("vsetvl %0, %3, %4\n\t"
                     "csrr %1, vtype\n\t"
                     "csrr %2, vl\n\t"
                     : "=&r"(vl), "=&r"(vt), "=&r"(vlc)
                     : "r"(avl), "r"(vtype));
    *vtype_out = vt;
    *vl_csr = vlc;
    return vl;
}


static void test_vlenb(void)
{
    unsigned long vlenb = vt_vlenb();
    VT_TRUE(vlenb >= 16 && vlenb <= 64, "vlenb in 16..64");
    VT_TRUE((vlenb & (vlenb - 1)) == 0, "vlenb power of two");
    vt_puts("vlenb ");
    vt_dec(vlenb);
    vt_puts("\r\n");
}

/* VLMAX = VLEN / SEW * LMUL, with fractional LMUL as a divisor. */
static unsigned long vlmax_of(unsigned sew_enc, unsigned lmul_enc, int *legal)
{
    unsigned long vlenb = vt_vlenb();
    unsigned long sew_bits = 8ul << sew_enc;
    unsigned long vlen = vlenb * 8;
    unsigned long num, den;
    switch (lmul_enc) {
        case VT_M1:
            num = 1;
            den = 1;
            break;
        case VT_M2:
            num = 2;
            den = 1;
            break;
        case VT_M4:
            num = 4;
            den = 1;
            break;
        case VT_M8:
            num = 8;
            den = 1;
            break;
        case VT_MF2:
            num = 1;
            den = 2;
            break;
        case VT_MF4:
            num = 1;
            den = 4;
            break;
        case VT_MF8:
            num = 1;
            den = 8;
            break;
        default:
            *legal = 0;
            return 0;
    }
    /* LMUL >= SEW / ELEN (ELEN = 64) is required. */
    *legal = (num * 64 >= sew_bits * den) ? 1 : 0;
    return vlen / sew_bits * num / den;
}

static void test_vsetvl_matrix(void)
{
    for (unsigned sew = VT_E8; sew <= VT_E64; sew++) {
        for (unsigned lmul = 0; lmul < 8; lmul++) {
            if (lmul == 4)
                continue; /* reserved encoding, covered below */
            int legal;
            unsigned long vlmax = vlmax_of(sew, lmul, &legal);
            unsigned long vtype = VT_VTYPE(sew, lmul, VT_TA);
            unsigned long vt, vlc;
            unsigned long avls[] = {
                0, 1, 3, vlmax ? vlmax - 1 : 0, vlmax, vlmax + 1, 2 * vlmax + 1, 1000};
            for (unsigned i = 0; i < sizeof avls / sizeof avls[0]; i++) {
                unsigned long vl = do_vsetvl(avls[i], vtype, &vt, &vlc);
                if (!legal) {
                    VT_EQ(vl, 0, "illegal vtype gives vl 0");
                    VT_EQ(vt, 1ul << 63, "illegal vtype gives only vill");
                    VT_EQ(vlc, 0, "illegal vtype vl csr 0");
                    continue;
                }
                unsigned long want = avls[i] > vlmax ? vlmax : avls[i];
                /* The spec allows vl between ceil(AVL/2) and VLMAX when
                 * VLMAX < AVL < 2 * VLMAX; both models and the RTL are
                 * expected to choose VLMAX. */
                if (avls[i] < 2 * vlmax && avls[i] > vlmax)
                    want = vlmax;
                VT_EQ(vl, want, "vsetvl vl");
                VT_EQ(vlc, want, "vl csr equals rd");
                VT_EQ(vt, vtype, "vtype readback");
            }
        }
    }
}

static void test_reserved(void)
{
    unsigned long vt, vlc;
    /* LMUL encoding 4 is reserved. */
    unsigned long vl = do_vsetvl(5, VT_VTYPE(VT_E32, 4, 0), &vt, &vlc);
    VT_EQ(vl, 0, "reserved lmul vl");
    VT_EQ(vt >> 63, 1, "reserved lmul vill");
    /* SEW encodings 4..7 are reserved. */
    for (unsigned sew = 4; sew < 8; sew++) {
        vl = do_vsetvl(5, VT_VTYPE(sew, VT_M1, 0), &vt, &vlc);
        VT_EQ(vl, 0, "reserved sew vl");
        VT_EQ(vt >> 63, 1, "reserved sew vill");
    }
    /* A non-zero reserved vtype bit (bit 8) sets vill. */
    vl = do_vsetvl(5, VT_VTYPE(VT_E8, VT_M1, 0) | (1ul << 8), &vt, &vlc);
    VT_EQ(vl, 0, "reserved vtype bit vl");
    VT_EQ(vt >> 63, 1, "reserved vtype bit vill");
    /* A legal setting afterwards clears vill. */
    vl = do_vsetvl(4, VT_VTYPE(VT_E32, VT_M1, 0), &vt, &vlc);
    VT_EQ(vl, 4 <= vt_vlenb() / 4 ? 4 : vt_vlenb() / 4, "recover vl");
    VT_EQ(vt >> 63, 0, "recover vill");
}

static void test_flags(void)
{
    unsigned long vt, vlc;
    for (unsigned flags = 0; flags < 4; flags++) {
        unsigned long f = ((flags & 1) ? VT_TA : 0) | ((flags & 2) ? VT_MA : 0);
        do_vsetvl(1, VT_VTYPE(VT_E16, VT_M2, f), &vt, &vlc);
        VT_EQ(vt, VT_VTYPE(VT_E16, VT_M2, f), "vta/vma readback");
    }
}

static void test_immediate_forms(void)
{
    unsigned long vl, vt;
    unsigned long vlenb = vt_vlenb();
    /* vsetivli: uimm AVL 0..31. */
    __asm__ volatile("vsetivli %0, 7, e8, m1, ta, ma\n\tcsrr %1, vtype" : "=r"(vl), "=r"(vt));
    VT_EQ(vl, 7 <= vlenb ? 7 : vlenb, "vsetivli 7 e8 m1");
    VT_EQ(vt, VT_VTYPE(VT_E8, VT_M1, VT_TA | VT_MA), "vsetivli vtype");
    __asm__ volatile("vsetivli %0, 31, e64, m8, tu, mu" : "=r"(vl));
    VT_EQ(vl, 31 < vlenb ? 31 : vlenb, "vsetivli 31 e64 m8 (VLMAX = vlenb)");
    __asm__ volatile("vsetivli %0, 0, e32, mf2, ta, mu" : "=r"(vl));
    VT_EQ(vl, 0, "vsetivli 0");
    /* vsetvli with a register AVL. */
    __asm__ volatile("vsetvli %0, %2, e16, m4, ta, ma\n\tcsrr %1, vtype"
                     : "=r"(vl), "=r"(vt)
                     : "r"(100ul));
    VT_EQ(vl, 100 < vlenb * 2 ? 100 : vlenb * 2, "vsetvli e16 m4 vl");
    /* rs1 = x0, rd != x0: vl = VLMAX. */
    __asm__ volatile("vsetvli %0, x0, e8, m2, ta, ma" : "=r"(vl));
    VT_EQ(vl, vlenb * 2, "vsetvli x0 AVL = VLMAX");
    /* rd = x0, rs1 = x0: keep vl, change vtype (ratio unchanged). */
    __asm__ volatile("vsetvli %0, %1, e16, m1, ta, ma" : "=r"(vl) : "r"(3ul));
    unsigned long vl2;
    __asm__ volatile("vsetvli x0, x0, e16, m1, tu, mu\n\tcsrr %0, vl\n\tcsrr %1, vtype"
                     : "=r"(vl2), "=r"(vt));
    VT_EQ(vl2, vl, "vsetvli x0,x0 keeps vl");
    VT_EQ(vt, VT_VTYPE(VT_E16, VT_M1, 0), "vsetvli x0,x0 vtype");
    /* rd = x0 with an AVL: vl is set and rd is not written. */
    __asm__ volatile("vsetvli x0, %1, e32, m1, ta, ma\n\tcsrr %0, vl" : "=r"(vl2) : "r"(2ul));
    VT_EQ(vl2, 2 <= vlenb / 4 ? 2 : vlenb / 4, "vsetvli x0, rs1");
}

static void test_vstart_csr(void)
{
    unsigned long v;
    __asm__ volatile("vsetvli x0, %0, e32, m1, ta, ma" : : "r"(4ul));
    VT_EQ(VT_CSR_READ(vstart), 0, "vstart 0 after vsetvli");
    VT_CSR_WRITE(vstart, 3);
    VT_EQ(VT_CSR_READ(vstart), 3, "vstart writable");
    /* vsetvli clears vstart. */
    __asm__ volatile("vsetvli x0, %0, e32, m1, ta, ma" : : "r"(4ul));
    VT_EQ(VT_CSR_READ(vstart), 0, "vsetvli clears vstart");
    /* A non-zero vstart on a successful vsetvli is cleared as well. */
    VT_CSR_WRITE(vstart, 2);
    __asm__ volatile("vsetvli %0, %1, e8, m1, ta, ma" : "=r"(v) : "r"(9ul));
    VT_EQ(VT_CSR_READ(vstart), 0, "vsetvli clears vstart again");
    /* vstart holds only enough bits for VLEN - 1. */
    VT_CSR_WRITE(vstart, ~0ul);
    unsigned long vlen_bits = vt_vlenb() * 8;
    VT_EQ(VT_CSR_READ(vstart), vlen_bits - 1, "vstart width is log2(VLEN) bits");
    VT_CSR_WRITE(vstart, 0);
}

static void test_vxrm_vxsat(void)
{
    VT_CSR_WRITE(vxrm, 0);
    VT_CSR_WRITE(vxsat, 0);
    VT_EQ(VT_CSR_READ(vcsr), 0, "vcsr reset");
    VT_CSR_WRITE(vxrm, 3);
    VT_EQ(VT_CSR_READ(vcsr), 3ul << 1, "vxrm in vcsr[2:1]");
    VT_CSR_WRITE(vxsat, 1);
    VT_EQ(VT_CSR_READ(vcsr), (3ul << 1) | 1, "vxsat in vcsr[0]");
    VT_CSR_WRITE(vcsr, 2ul << 1);
    VT_EQ(VT_CSR_READ(vxrm), 2, "vcsr write updates vxrm");
    VT_EQ(VT_CSR_READ(vxsat), 0, "vcsr write updates vxsat");
    VT_CSR_WRITE(vxrm, 7);
    VT_EQ(VT_CSR_READ(vxrm), 3, "vxrm is two bits");
    VT_CSR_WRITE(vxsat, 3);
    VT_EQ(VT_CSR_READ(vxsat), 1, "vxsat is one bit");
    /* A saturating add sets vxsat: 0x7f + 0x7f at e8 saturates. */
    unsigned long sat;
    __asm__ volatile("vsetivli x0, 1, e8, m1, ta, ma\n\t"
                     "vmv.v.i v1, 0x7\n\t"
                     "vsll.vi v1, v1, 4\n\t" /* 0x70 */
                     "vsadd.vv v2, v1, v1\n\t"
                     "csrr %0, vxsat\n\t"
                     : "=r"(sat));
    VT_EQ(sat, 1, "vsadd sets vxsat");
    VT_CSR_WRITE(vxsat, 0);
    VT_CSR_WRITE(vxrm, 0);
}

static void test_vlenb_ro_and_vl_ro(void)
{
    /* vl, vtype and vlenb are read-only to csrw: the write traps. */
    vt_trap_clear();
    __asm__ volatile("csrw vl, zero");
    VT_EQ(vt_trap_count, 1, "csrw vl traps");
    VT_EQ(vt_trap_cause, 2, "csrw vl is illegal instruction");
    vt_trap_clear();
    __asm__ volatile("csrw vlenb, zero");
    VT_EQ(vt_trap_count, 1, "csrw vlenb traps");
    VT_EQ(vt_trap_cause, 2, "csrw vlenb is illegal instruction");
    vt_trap_clear();
    __asm__ volatile("csrw vtype, zero");
    VT_EQ(vt_trap_count, 1, "csrw vtype traps");
    VT_EQ(vt_trap_cause, 2, "csrw vtype is illegal instruction");
    vt_trap_clear();
}

static void test_mstatus_vs(void)
{
    unsigned long ms;
    /* The startup code leaves VS = Dirty (3). Turn the unit off and a vector
     * instruction must raise illegal instruction; turn it on at Initial and
     * a state-changing instruction must leave it Dirty. */
    __asm__ volatile("csrc mstatus, %0" : : "r"(VT_MSTATUS_VS));
    vt_trap_clear();
    __asm__ volatile("vsetivli x0, 1, e8, m1, ta, ma");
    VT_EQ(vt_trap_count, 1, "vsetivli with VS off traps");
    VT_EQ(vt_trap_cause, 2, "VS off is illegal instruction");
    vt_trap_clear();
    VT_CSR_WRITE(mstatus, VT_CSR_READ(mstatus) | (1ul << 9)); /* VS = Initial */
    __asm__ volatile("csrr %0, mstatus" : "=r"(ms));
    VT_EQ((ms >> 9) & 3, 1, "VS = Initial reads back");
    __asm__ volatile("vsetivli x0, 1, e8, m1, ta, ma\n\tvmv.v.i v3, 5");
    __asm__ volatile("csrr %0, mstatus" : "=r"(ms));
    VT_EQ((ms >> 9) & 3, 3, "VS = Dirty after a vector write");
    VT_EQ(ms >> 63, 1, "SD set when VS is Dirty");
    __asm__ volatile("csrs mstatus, %0" : : "r"(VT_MSTATUS_VS));
}

static void test_misa(void)
{
    unsigned long misa = VT_CSR_READ(misa);
    VT_EQ((misa >> 21) & 1, 1, "misa.V set");
}

int main(void)
{
    vt_enable_vector();
    vt_trap_install();

    test_misa();
    test_vlenb();
    test_vsetvl_matrix();
    test_reserved();
    test_flags();
    test_immediate_forms();
    test_vstart_csr();
    test_vxrm_vxsat();
    test_vlenb_ro_and_vl_ro();
    test_mstatus_vs();

    return vt_finish("vec_smoke");
}
