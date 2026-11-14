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


/*
 * vsetvli, vsetivli and vsetvl: rd, vl, vtype and vstart after each, against
 * a reference model of the specification's rules (Spike's set_vl), at the
 * VLEN the vector unit reports in vlenb. Sweeps vtype through every vsew,
 * vlmul, vta and vma value plus reserved bits, and AVL around VLMAX; covers
 * the rs1 = x0 forms (VLMAX, and keep with rd = x0), a dependent use of rd,
 * back-to-back configuration, the Dirty setting of mstatus.VS, and the
 * illegal-instruction trap while VS is Off. Instructions are emitted with
 * .insn so the program builds without the V extension in -march.
 */

#include <stdint.h>

#include "csr.h"
#include "uart.h"

#define MSTATUS_VS (3ul << 9)
#define VS_OFF 0ul
#define VS_INITIAL (1ul << 9)
#define VS_DIRTY (3ul << 9)
#define VILL (1ul << 63)

static int g_ok = 1;
static unsigned long g_vlen;
static volatile unsigned long g_cause;
static volatile unsigned long g_epc;

__attribute__((naked, aligned(4))) static void vsetvl_trap_handler(void)
{
    __asm__ volatile("csrr t0, mcause\n"
                     "la   t1, g_cause\n"
                     "sd   t0, 0(t1)\n"
                     "csrr t0, mepc\n"
                     "la   t1, g_epc\n"
                     "sd   t0, 0(t1)\n"
                     "addi t0, t0, 4\n"
                     "csrw mepc, t0\n"
                     "li   t0, 0x1800\n"
                     "csrs mstatus, t0\n"
                     "mret\n");
}

static void check(const char *name, unsigned long got, unsigned long want)
{
    if (got != want) {
        g_ok = 0;
        uart_printf("[FAIL] %s got=%lx want=%lx\n", name, got, want);
    }
}

/* Reference: VLMAX for a vtype, 0 when it is illegal (vill). */
static unsigned long ref_vlmax(unsigned long vtype)
{
    unsigned long vsew = (vtype >> 3) & 7, vlmul = vtype & 7;
    if (vtype >> 8)
        return 0;
    if (vlmul == 4 || vsew > 3)
        return 0;
    unsigned long sew = 8ul << vsew;
    if (vlmul >= 5) {
        unsigned long div = 1ul << (8 - vlmul); /* 5 -> 8, 6 -> 4, 7 -> 2 */
        if (sew * div > 64)
            return 0;
        return g_vlen / sew / div;
    }
    return (g_vlen / sew) << vlmul;
}

static unsigned long ref_vtype(unsigned long vtype)
{
    return ref_vlmax(vtype) ? (vtype & 0xff) : VILL;
}

static unsigned long min_ul(unsigned long a, unsigned long b)
{
    return a < b ? a : b;
}

static unsigned long read_vl(void)
{
    unsigned long v;
    __asm__ volatile("csrr %0, 0xC20" : "=r"(v));
    return v;
}

static unsigned long read_vtype(void)
{
    unsigned long v;
    __asm__ volatile("csrr %0, 0xC21" : "=r"(v));
    return v;
}

static unsigned long read_vstart(void)
{
    unsigned long v;
    __asm__ volatile("csrr %0, 0x008" : "=r"(v));
    return v;
}

static void write_vstart(unsigned long v)
{
    __asm__ volatile("csrw 0x008, %0" ::"r"(v) : "memory");
}

/* vsetvl rd, rs1, rs2 */
static unsigned long do_vsetvl(unsigned long avl, unsigned long vtype)
{
    unsigned long rd;
    __asm__ volatile(".insn r 0x57, 7, 0x40, %0, %1, %2"
                     : "=r"(rd)
                     : "r"(avl), "r"(vtype)
                     : "memory");
    return rd;
}

static void
check_state(const char *name, unsigned long rd, unsigned long want_vl, unsigned long vtype)
{
    int was_ok = g_ok;
    unsigned long vl = read_vl(), vt = read_vtype(), vs = read_vstart();
    check(name, rd, want_vl);
    check("  vl", vl, want_vl);
    check("  vtype", vt, ref_vtype(vtype));
    check("  vstart", vs, 0);
    if (was_ok && !g_ok)
        uart_printf("  first failure: vtype %lx\n", vtype);
}

int main(void)
{
    unsigned long v;
    csr_write(mtvec, (unsigned long) vsetvl_trap_handler);

    /* VS Off: every form is an illegal instruction. */
    csr_clear(mstatus, MSTATUS_VS);
    g_cause = ~0ul;
    __asm__ volatile(".insn i 0x57, 7, t4, t5, 0x018" ::: "t4", "memory");
    check("vsetvli illegal with VS Off", g_cause, 2);
    g_cause = ~0ul;
    __asm__ volatile(".insn r 0x57, 7, 0x40, t4, t5, t6" ::: "t4", "memory");
    check("vsetvl illegal with VS Off", g_cause, 2);

    csr_set(mstatus, VS_INITIAL);
    __asm__ volatile("csrr %0, 0xC22" : "=r"(v));
    g_vlen = v * 8;
    uart_printf("VLEN %lu\n", g_vlen);

    /* Every vsew/vlmul/vta/vma value, then reserved high bits. */
    unsigned long checked = 0;
    for (unsigned long vt = 0; vt < 0x100; vt++) {
        unsigned long vlmax = ref_vlmax(vt);
        const unsigned long avls[] = {
            0, 1, 3, vlmax ? vlmax - 1 : 2, vlmax, vlmax + 1, vlmax * 2 + 5, ~0ul};
        for (unsigned i = 0; i < sizeof(avls) / sizeof(avls[0]); i++) {
            write_vstart(1);
            unsigned long rd = do_vsetvl(avls[i], vt);
            if (g_ok && rd != (vlmax ? min_ul(avls[i], vlmax) : 0))
                uart_printf("  avl %lx\n", avls[i]);
            check_state("vsetvl sweep", rd, vlmax ? min_ul(avls[i], vlmax) : 0, vt);
            checked++;
        }
    }
    const unsigned long reserved[] = {0x100, 0x118, 1ul << 31, 1ul << 62, VILL, VILL | 0x18};
    for (unsigned i = 0; i < sizeof(reserved) / sizeof(reserved[0]); i++) {
        unsigned long rd = do_vsetvl(5, reserved[i]);
        check_state("vsetvl reserved bits", rd, 0, reserved[i]);
        checked++;
    }
    uart_printf("vsetvl cases %lu\n", checked);

    /* vsetvli e32, m1 (0x010) and e8, mf2 (0x007) with AVL in a register. */
    {
        unsigned long rd, avl = 3;
        __asm__ volatile(".insn i 0x57, 7, %0, %1, 0x010" : "=r"(rd) : "r"(avl) : "memory");
        check_state("vsetvli e32 m1", rd, min_ul(3, ref_vlmax(0x010)), 0x010);
        avl = 1000;
        __asm__ volatile(".insn i 0x57, 7, %0, %1, 0x007" : "=r"(rd) : "r"(avl) : "memory");
        check_state("vsetvli e8 mf2", rd, ref_vlmax(0x007), 0x007);
        /* tail and mask agnostic bits, e16 m4 (0x0CA) */
        __asm__ volatile(".insn i 0x57, 7, %0, %1, 0x0CA" : "=r"(rd) : "r"(avl) : "memory");
        check_state("vsetvli ta ma e16 m4", rd, min_ul(1000, ref_vlmax(0x0CA)), 0x0CA);
        /* reserved immediate bit 8 */
        __asm__ volatile(".insn i 0x57, 7, %0, %1, 0x110" : "=r"(rd) : "r"(avl) : "memory");
        check_state("vsetvli reserved bit", rd, 0, 0x110);
    }

    /* vsetivli: AVL 13 with e8 m1, AVL 31 with e64 m2; bits 31:30 set. */
    {
        unsigned long rd;
        __asm__ volatile(".insn i 0x57, 7, %0, x13, %1" : "=r"(rd) : "i"(0x000 - 0x400) : "memory");
        check_state("vsetivli 13 e8 m1", rd, min_ul(13, ref_vlmax(0x000)), 0x000);
        __asm__ volatile(".insn i 0x57, 7, %0, x31, %1" : "=r"(rd) : "i"(0x019 - 0x400) : "memory");
        check_state("vsetivli 31 e64 m2", rd, min_ul(31, ref_vlmax(0x019)), 0x019);
        __asm__ volatile(".insn i 0x57, 7, %0, x0, %1" : "=r"(rd) : "i"(0x010 - 0x400) : "memory");
        check_state("vsetivli 0", rd, 0, 0x010);
    }

    /* rs1 = x0, rd != x0: vl = VLMAX. */
    {
        unsigned long rd;
        __asm__ volatile(".insn i 0x57, 7, %0, x0, 0x011" : "=r"(rd)::"memory");
        check_state("vsetvli rd, x0 e32 m2", rd, ref_vlmax(0x011), 0x011);
    }

    /* rs1 = rd = x0: keep min(vl, VLMAX) under the new vtype. */
    {
        unsigned long rd;
        __asm__ volatile(".insn i 0x57, 7, %0, x0, 0x013" : "=r"(rd)::"memory"); /* e32 m8 */
        unsigned long big = ref_vlmax(0x013);
        __asm__ volatile(".insn i 0x57, 7, x0, x0, 0x010" ::: "memory"); /* e32 m1 */
        check("keep shrinks vl", read_vl(), min_ul(big, ref_vlmax(0x010)));
        check("keep vtype", read_vtype(), 0x010);
        __asm__ volatile(".insn i 0x57, 7, x0, x0, 0x013" ::: "memory");
        check("keep holds vl", read_vl(), ref_vlmax(0x010));
        /* keep with an illegal vtype gives vl 0 and vill */
        __asm__ volatile(".insn i 0x57, 7, x0, x0, 0x024" ::: "memory");
        check("keep with vill", read_vl(), 0);
        check("keep with vill vtype", read_vtype(), VILL);
    }

    /* A dependent use of rd, and back-to-back configuration. */
    {
        unsigned long sum;
        __asm__ volatile(".insn i 0x57, 7, t3, %1, 0x008\n" /* e16 m1 */
                         ".insn i 0x57, 7, t4, %1, 0x000\n" /* e8 m1 */
                         ".insn i 0x57, 7, t5, %1, 0x018\n" /* e64 m1 */
                         "add %0, t3, t4\n"
                         "add %0, %0, t5\n"
                         : "=&r"(sum)
                         : "r"(1000ul)
                         : "t3", "t4", "t5", "memory");
        check("dependent rd sum", sum, ref_vlmax(0x008) + ref_vlmax(0x000) + ref_vlmax(0x018));
        check("last vtype wins", read_vtype(), 0x018);
    }

    /* The register fields that are immediates in vsetvli (bits 24:20, part of
     * vtypei) and vsetivli (bits 19:15, the AVL) must not make the instruction
     * wait for that register. Here they name s3 (x19), written by an instruction
     * that completes behind a divide at the ROB head and so has broadcast its
     * result, but not retired, when the vector-config instruction dispatches. */
    {
        unsigned long rd, q;
        __asm__ volatile("li t1, 1000000007\n"
                         "li t2, 3\n"
                         "div %1, t1, t2\n"
                         "li s3, 1\n"
                         "nop\n"
                         "nop\n"
                         "nop\n"
                         "nop\n"
                         "nop\n"
                         "nop\n"
                         "nop\n"
                         "nop\n"
                         "nop\n"
                         "nop\n"
                         "nop\n"
                         "nop\n"
                         ".insn i 0x57, 7, %0, x0, 0x013\n" /* vsetvli rd, x0, e32 m8 */
                         : "=r"(rd), "=&r"(q)
                         :
                         : "t1", "t2", "s3", "memory");
        check_state(
            "vsetvli behind a done producer of its vtypei bits", rd, ref_vlmax(0x013), 0x013);
        __asm__ volatile("li t1, 1000000007\n"
                         "li t2, 3\n"
                         "div %1, t1, t2\n"
                         "li s3, 1\n"
                         "nop\n"
                         "nop\n"
                         "nop\n"
                         "nop\n"
                         "nop\n"
                         "nop\n"
                         "nop\n"
                         "nop\n"
                         "nop\n"
                         "nop\n"
                         "nop\n"
                         "nop\n"
                         ".insn i 0x57, 7, %0, x19, %2\n" /* vsetivli rd, 19, e32 m1 */
                         : "=r"(rd), "=&r"(q)
                         : "i"(0x010 - 0x400)
                         : "t1", "t2", "s3", "memory");
        check_state("vsetivli behind a done producer of its AVL bits",
                    rd,
                    min_ul(19, ref_vlmax(0x010)),
                    0x010);
    }

    check("VS Dirty after vsetvl", csr_read(mstatus) & MSTATUS_VS, VS_DIRTY);

    uart_printf(g_ok ? "<<PASS>>\n" : "<<FAIL>>\n");
    for (;;) {
    }
    return 0;
}
