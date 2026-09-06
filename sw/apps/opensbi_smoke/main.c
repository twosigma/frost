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
 * OpenSBI smoke test: a bare S-mode payload booted by the real fw_jump
 * firmware through the FROST boot layout (Phase 3 M7). It checks, from the
 * supervisor's point of view, everything Linux will rely on the firmware for:
 *
 *   A. SBI base: spec/impl ids, extension probes, mvendorid/marchid/mimpid.
 *   B. Entry state: satp Bare, scounteren, time/cycle readable, stimecmp
 *      accessible (menvcfg.STCE set by the firmware: the mcountinhibit
 *      privileged-version probe), sfence.vma forms, HSM status.
 *   C. Timers: an S-timer interrupt through stimecmp, and through
 *      sbi_set_timer (which writes stimecmp under Sstc).
 *   D. IPI to self through the SBI (SSIP injection) and an RFENCE call.
 *   E. Console: SBI DBCN write and the legacy putchar.
 *   F. Misaligned loads/stores emulated by OpenSBI in M-mode (they are not
 *      delegated by default): every scalar width, the RV64 compressed forms,
 *      FP fld/fsd and C.FLD/C.FSD with FS dirtying, under satp Bare and
 *      under an Sv39 map through a non-identity alias, from S and from U,
 *      plus an emulated access that page-faults (S touching a U page with
 *      SUM=0) and must be redirected to S with the faulting VA in stval.
 *   G. FWFT misaligned delegation (the Linux path): after
 *      SBI_FWFT_MISALIGNED_EXC_DELEG=1 the traps arrive in S-mode instead.
 *   H. SBI PMU on the fixed counters: stop, config-match, start with a
 *      2^63-class initial value, read, stop (inhibit) and a second round.
 *
 * Output goes to the native UART (the bench captures every byte); the run
 * ends with <<PASS>> or <<FAIL>>.
 */

#include <stdint.h>

/* ---- native UART (identity-mapped under the MMIO megapage) ---- */
#define UART_TX (*(volatile uint8_t *) 0x40000000ul)
#define UART_TX_STATUS (*(volatile uint32_t *) 0x40000028ul)

static void putc_(char c)
{
    while (!(UART_TX_STATUS & 1u))
        ;
    UART_TX = (uint8_t) c;
}

static void puts_(const char *s)
{
    for (; *s; s++) {
        if (*s == '\n')
            putc_('\r');
        putc_(*s);
    }
}

static void puthex(uint64_t v)
{
    static const char hex[] = "0123456789abcdef";
    puts_("0x");
    for (int i = 60; i >= 0; i -= 4)
        putc_(hex[(v >> i) & 0xf]);
}

static int g_failed;

static void check(const char *name, int ok)
{
    puts_(ok ? "  ok   " : "  FAIL ");
    puts_(name);
    puts_("\n");
    if (!ok)
        g_failed = 1;
}

static void check_eq(const char *name, uint64_t got, uint64_t want)
{
    check(name, got == want);
    if (got != want) {
        puts_("         got ");
        puthex(got);
        puts_(" want ");
        puthex(want);
        puts_("\n");
    }
}

/* ---- CSRs ---- */
#define csr_read(csr)                                                                              \
    ({                                                                                             \
        uint64_t __v;                                                                              \
        __asm__ volatile("csrr %0, " #csr : "=r"(__v));                                            \
        __v;                                                                                       \
    })
#define csr_write(csr, v) __asm__ volatile("csrw " #csr ", %0" ::"r"((uint64_t) (v)))
#define csr_set(csr, v) __asm__ volatile("csrs " #csr ", %0" ::"r"((uint64_t) (v)))
#define csr_clear(csr, v) __asm__ volatile("csrc " #csr ", %0" ::"r"((uint64_t) (v)))

#define SSTATUS_SIE (1ul << 1)
#define SSTATUS_SPP (1ul << 8)
#define SSTATUS_FS (3ul << 13)
#define SSTATUS_FS_DIRTY (3ul << 13)
#define SSTATUS_SUM (1ul << 18)
#define SIE_SSIE (1ul << 1)
#define SIE_STIE (1ul << 5)
#define CAUSE_MISALIGNED_LOAD 4
#define CAUSE_MISALIGNED_STORE 6
#define CAUSE_USER_ECALL 8
#define CAUSE_LOAD_PAGE_FAULT 13
#define CAUSE_STORE_PAGE_FAULT 15
#define CAUSE_ILLEGAL 2
#define IRQ_S_SOFT 1
#define IRQ_S_TIMER 5

/* ---- SBI ---- */
struct sbiret {
    long error;
    long value;
};

static struct sbiret sbi_ecall(
    long ext, long fid, unsigned long a0, unsigned long a1, unsigned long a2, unsigned long a3)
{
    register unsigned long r_a0 __asm__("a0") = a0;
    register unsigned long r_a1 __asm__("a1") = a1;
    register unsigned long r_a2 __asm__("a2") = a2;
    register unsigned long r_a3 __asm__("a3") = a3;
    register long r_a6 __asm__("a6") = fid;
    register long r_a7 __asm__("a7") = ext;
    __asm__ volatile("ecall"
                     : "+r"(r_a0), "+r"(r_a1)
                     : "r"(r_a2), "r"(r_a3), "r"(r_a6), "r"(r_a7)
                     : "memory");
    struct sbiret ret = {(long) r_a0, (long) r_a1};
    return ret;
}

#define SBI_EXT_BASE 0x10
#define SBI_EXT_TIME 0x54494D45
#define SBI_EXT_IPI 0x735049
#define SBI_EXT_RFENCE 0x52464E43
#define SBI_EXT_HSM 0x48534D
#define SBI_EXT_SRST 0x53525354
#define SBI_EXT_PMU 0x504D55
#define SBI_EXT_DBCN 0x4442434E
#define SBI_EXT_FWFT 0x46574654
#define SBI_EXT_LEGACY_PUTCHAR 0x01

#define SBI_PMU_HW_CPU_CYCLES 1
#define SBI_PMU_HW_INSTRUCTIONS 2
#define SBI_PMU_START_FLAG_SET_INIT_VALUE 1ul
#define SBI_ERR_ALREADY_STARTED (-7)
#define SBI_ERR_ALREADY_STOPPED (-8)
#define SBI_FWFT_MISALIGNED_EXC_DELEG 0

/* ---- trap record (filled by handle_trap) ---- */
static volatile uint64_t g_timer_irqs, g_soft_irqs;
static volatile uint64_t g_last_cause, g_last_tval, g_last_epc, g_trap_count;
static volatile uint64_t g_illegal_count;

struct frame {
    uint64_t x[31]; /* x1..x31 */
    uint64_t sepc, scause, stval, sstatus;
};

static unsigned long insn_len_at(uint64_t pc)
{
    /* The faulting instruction may live on a U page: read it with SUM. */
    uint64_t saved = csr_read(sstatus);
    csr_set(sstatus, SSTATUS_SUM);
    uint16_t low = *(volatile uint16_t *) pc;
    csr_write(sstatus, saved);
    return ((low & 3u) == 3u) ? 4 : 2;
}

/* Returns 0 to sret into the frame, 1 to unwind to run_in_umode()'s caller. */
int handle_trap(struct frame *f)
{
    uint64_t cause = f->scause;
    g_trap_count++;
    if (cause >> 63) {
        uint64_t irq = cause & 0xff;
        if (irq == IRQ_S_TIMER) {
            g_timer_irqs++;
            csr_write(0x14D, ~0ul); /* stimecmp: disarm */
        } else if (irq == IRQ_S_SOFT) {
            g_soft_irqs++;
            csr_clear(sip, SIE_SSIE);
        } else {
            g_failed = 1;
            puts_("  unexpected interrupt\n");
            csr_clear(sie, 1ul << irq);
        }
        return 0;
    }
    g_last_cause = cause;
    g_last_tval = f->stval;
    g_last_epc = f->sepc;
    switch (cause) {
        case CAUSE_USER_ECALL:
            return 1;
        case CAUSE_ILLEGAL:
            g_illegal_count++;
            f->sepc += insn_len_at(f->sepc);
            return 0;
        case CAUSE_MISALIGNED_LOAD:
        case CAUSE_MISALIGNED_STORE:
        case CAUSE_LOAD_PAGE_FAULT:
        case CAUSE_STORE_PAGE_FAULT:
            /* Recorded; skip the instruction (the tests inspect the record). */
            f->sepc += insn_len_at(f->sepc);
            return 0;
        default:
            g_failed = 1;
            puts_("  unexpected exception cause ");
            puthex(cause);
            puts_(" at ");
            puthex(f->sepc);
            puts_(" tval ");
            puthex(f->stval);
            puts_("\n");
            for (;;)
                __asm__ volatile("wfi");
    }
}

extern unsigned long run_in_umode(unsigned long fn_va, unsigned long arg, unsigned long ustack_va);

/* ---- Sv39 map: identity for the payload and MMIO, plus two aliases ---- */
#define PAYLOAD_PA 0x80200000ul
#define S_ALIAS_VA 0x10000000ul /* VPN2 0, VPN1 0x80: supervisor-only alias */
#define U_ALIAS_VA 0x20000000ul /* VPN2 0, VPN1 0x100: user-accessible alias */
#define PTE_V 0x01ul
#define PTE_R 0x02ul
#define PTE_W 0x04ul
#define PTE_X 0x08ul
#define PTE_U 0x10ul
#define PTE_A 0x40ul
#define PTE_D 0x80ul
#define PTE_RWX (PTE_R | PTE_W | PTE_X)

static uint64_t g_root[512] __attribute__((aligned(4096)));
static uint64_t g_l2_low[512] __attribute__((aligned(4096)));  /* VPN2 = 0 */
static uint64_t g_l2_mmio[512] __attribute__((aligned(4096))); /* VPN2 = 1 */
static uint64_t g_l2_ddr[512] __attribute__((aligned(4096)));  /* VPN2 = 2 */

static uint64_t megapage(uint64_t pa, uint64_t flags)
{
    return ((pa >> 12) << 10) | flags | PTE_A | PTE_D | PTE_V;
}

static uint64_t table(const void *pt)
{
    return (((uint64_t) (uintptr_t) pt >> 12) << 10) | PTE_V;
}

static void enable_sv39(void)
{
    g_root[0] = table(g_l2_low);
    g_root[1] = table(g_l2_mmio);
    g_root[2] = table(g_l2_ddr);
    g_l2_ddr[1] = megapage(PAYLOAD_PA, PTE_RWX);             /* identity */
    g_l2_mmio[0] = megapage(0x40000000ul, PTE_R | PTE_W);    /* UART/CLINT */
    g_l2_low[0x80] = megapage(PAYLOAD_PA, PTE_RWX);          /* S alias */
    g_l2_low[0x100] = megapage(PAYLOAD_PA, PTE_RWX | PTE_U); /* U alias */
    uint64_t satp = (8ul << 60) | ((uint64_t) (uintptr_t) g_root >> 12);
    __asm__ volatile("sfence.vma" ::: "memory");
    csr_write(satp, satp);
    __asm__ volatile("sfence.vma" ::: "memory");
}

static uintptr_t s_alias(const void *p)
{
    return (uintptr_t) p - PAYLOAD_PA + S_ALIAS_VA;
}

static uintptr_t u_alias(const void *p)
{
    return (uintptr_t) p - PAYLOAD_PA + U_ALIAS_VA;
}

/* ---- misaligned access bodies ----
 * Each takes the buffer address as its argument, touches only its stack and
 * arguments (so it can run at any alias and in U-mode), and returns a value
 * folded from the results. The 32-bit forms are forced uncompressed and the
 * compressed forms are spelled explicitly, so the trap handler's length
 * arithmetic and the emulator's decode see the intended encodings. */

static uint64_t __attribute__((noinline)) body_scalar_loads(uint8_t *b)
{
    uint64_t w, d, h, hu, wu;
    __asm__ volatile(".option push\n.option norvc\n"
                     "lw %0, 1(%5)\n"
                     "ld %1, 1(%5)\n"
                     "lh %2, 1(%5)\n"
                     "lhu %3, 3(%5)\n"
                     "lwu %4, 3(%5)\n"
                     ".option pop\n"
                     : "=&r"(w), "=&r"(d), "=&r"(h), "=&r"(hu), "=&r"(wu)
                     : "r"(b)
                     : "memory");
    /* Fold: the pattern is byte i = i + base. */
    return w ^ (d << 1) ^ (h << 2) ^ (hu << 3) ^ (wu << 4);
}

static uint64_t expected_scalar_loads(const uint8_t *b)
{
    uint64_t w = 0, d = 0, h, hu, wu = 0;
    for (int i = 0; i < 4; i++)
        w |= (uint64_t) b[1 + i] << (8 * i);
    for (int i = 0; i < 8; i++)
        d |= (uint64_t) b[1 + i] << (8 * i);
    h = (uint64_t) (int64_t) (int16_t) (b[1] | (b[2] << 8));
    hu = b[3] | (b[4] << 8);
    for (int i = 0; i < 4; i++)
        wu |= (uint64_t) b[3 + i] << (8 * i);
    w = (uint64_t) (int64_t) (int32_t) w;
    return w ^ (d << 1) ^ (h << 2) ^ (hu << 3) ^ (wu << 4);
}

static void __attribute__((noinline)) body_scalar_stores(uint8_t *b)
{
    __asm__ volatile(".option push\n.option norvc\n"
                     "li t0, 0x11223344\n"
                     "sw t0, 5(%0)\n"
                     "li t0, 0x5566778899aabbcc\n"
                     "sd t0, 9(%0)\n"
                     "li t0, 0xddee\n"
                     "sh t0, 19(%0)\n"
                     ".option pop\n"
                     :
                     : "r"(b)
                     : "t0", "memory");
}

static uint64_t __attribute__((noinline)) body_compressed(uint8_t *b)
{
    uint64_t w, d;
    /* c.lw/c.ld need x8-x15 for both operands; a1/a2 qualify. */
    __asm__ volatile("addi a1, %2, 1\n"
                     "c.lw a2, 0(a1)\n"
                     "mv %0, a2\n"
                     "c.ld a2, 0(a1)\n"
                     "mv %1, a2\n"
                     "li a2, 0x7788\n"
                     "addi a1, %2, 33\n"
                     "c.sw a2, 0(a1)\n"
                     "li a2, 0x99aabbccddeeff00\n"
                     "addi a1, %2, 41\n"
                     "c.sd a2, 0(a1)\n"
                     : "=&r"(w), "=&r"(d)
                     : "r"(b)
                     : "a1", "a2", "memory");
    return w ^ (d << 1);
}

static uint64_t __attribute__((noinline)) body_fp(uint8_t *b)
{
    uint64_t d, cd;
    __asm__ volatile(".option push\n.option norvc\n"
                     "fld ft0, 1(%2)\n"
                     "fmv.x.d %0, ft0\n"
                     "fsd ft0, 49(%2)\n"
                     ".option pop\n"
                     "addi a1, %2, 9\n"
                     "c.fld fa0, 0(a1)\n"
                     "fmv.x.d %1, fa0\n"
                     "addi a1, %2, 57\n"
                     "c.fsd fa0, 0(a1)\n"
                     : "=&r"(d), "=&r"(cd)
                     : "r"(b)
                     : "a1", "ft0", "fa0", "memory");
    return d ^ (cd << 1);
}

/* U-mode wrapper: runs a body and hands its value back through the ecall. */
static void __attribute__((noinline, naked)) ubody_loads(void)
{
    __asm__ volatile("addi sp, sp, -16\n"
                     "sd ra, 8(sp)\n"
                     "call body_scalar_loads\n"
                     "ld ra, 8(sp)\n"
                     "addi sp, sp, 16\n"
                     "ecall\n"
                     "j .\n");
}

static void __attribute__((noinline, naked)) ubody_compressed(void)
{
    __asm__ volatile("addi sp, sp, -16\n"
                     "sd ra, 8(sp)\n"
                     "call body_compressed\n"
                     "ld ra, 8(sp)\n"
                     "addi sp, sp, 16\n"
                     "ecall\n"
                     "j .\n");
}

static uint8_t g_buf[128] __attribute__((aligned(16)));
static uint8_t g_ustack[8192] __attribute__((aligned(16)));

static void fill(uint8_t *b, uint8_t base)
{
    for (int i = 0; i < 128; i++)
        b[i] = (uint8_t) (base + i);
}

static uint64_t expected_d(const uint8_t *b, int off)
{
    uint64_t d = 0;
    for (int i = 0; i < 8; i++)
        d |= (uint64_t) b[off + i] << (8 * i);
    return d;
}

static int stores_ok(const uint8_t *b)
{
    uint64_t sw = 0, sd = 0, sh = 0;
    for (int i = 0; i < 4; i++)
        sw |= (uint64_t) b[5 + i] << (8 * i);
    for (int i = 0; i < 8; i++)
        sd |= (uint64_t) b[9 + i] << (8 * i);
    for (int i = 0; i < 2; i++)
        sh |= (uint64_t) b[19 + i] << (8 * i);
    return sw == 0x11223344 && sd == 0x5566778899aabbccull && sh == 0xddee && b[4] == 4 &&
           b[21] == 21;
}

static void misaligned_suite(const char *tag,
                             uint8_t *data,
                             uint8_t *(*view)(uint8_t *),
                             uintptr_t (*code)(const void *))
{
    uint8_t *v = view(data);
    uint64_t (*loads)(uint8_t *) = (uint64_t (*)(uint8_t *)) code((const void *) body_scalar_loads);
    void (*stores)(uint8_t *) = (void (*)(uint8_t *)) code((const void *) body_scalar_stores);
    uint64_t (*comp)(uint8_t *) = (uint64_t (*)(uint8_t *)) code((const void *) body_compressed);
    uint64_t (*fp)(uint8_t *) = (uint64_t (*)(uint8_t *)) code((const void *) body_fp);

    puts_(tag);
    puts_("\n");
    fill(data, 0);
    g_trap_count = 0;
    check_eq("scalar misaligned loads", loads(v), expected_scalar_loads(data));
    check("emulated without a supervisor trap", g_trap_count == 0);
    stores(v);
    check("scalar misaligned stores", stores_ok(data));

    fill(data, 0x40);
    uint64_t w = 0;
    for (int i = 0; i < 4; i++)
        w |= (uint64_t) data[1 + i] << (8 * i);
    w = (uint64_t) (int64_t) (int32_t) w;
    check_eq("compressed misaligned loads", comp(v), w ^ (expected_d(data, 1) << 1));
    check("compressed misaligned stores",
          data[33] == 0x88 && data[34] == 0x77 && data[35] == 0 && data[36] == 0 &&
              expected_d(data, 41) == 0x99aabbccddeeff00ull && data[40] == 0x40 + 40);

    fill(data, 0x80);
    csr_clear(sstatus, SSTATUS_FS);
    csr_set(sstatus, 1ul << 13); /* FS = Initial */
    uint64_t want = expected_d(data, 1) ^ (expected_d(data, 9) << 1);
    uint64_t got = fp(v);
    check_eq("fp misaligned loads (fld, c.fld)", got, want);
    check("fp misaligned stores (fsd, c.fsd)",
          expected_d(data, 49) == expected_d(data, 1) &&
              expected_d(data, 57) == expected_d(data, 9));
    check("FS is Dirty after the emulated fp load",
          (csr_read(sstatus) & SSTATUS_FS) == SSTATUS_FS_DIRTY);
}

static uint8_t *view_identity(uint8_t *p)
{
    return p;
}

static uint8_t *view_s_alias(uint8_t *p)
{
    return (uint8_t *) s_alias(p);
}

static uintptr_t code_identity(const void *p)
{
    return (uintptr_t) p;
}

static uintptr_t code_s_alias(const void *p)
{
    return s_alias(p);
}

/* ---- the run ---- */
static void wait_irqs(volatile uint64_t *counter, uint64_t target)
{
    uint64_t start = csr_read(cycle);
    while (*counter < target) {
        __asm__ volatile("wfi");
        if (csr_read(cycle) - start > 20000000ul) {
            g_failed = 1;
            puts_("  timeout waiting for an interrupt\n");
            return;
        }
    }
}

int main(unsigned long hartid, unsigned long fdt)
{
    struct sbiret r;

    puts_("\n=== OpenSBI smoke (S-mode payload) ===\n");
    puts_("hartid ");
    puthex(hartid);
    puts_(" fdt ");
    puthex(fdt);
    puts_("\n");

    /* A: SBI base. */
    puts_("A: SBI base\n");
    r = sbi_ecall(SBI_EXT_BASE, 0, 0, 0, 0, 0);
    puts_("  spec version ");
    puthex((uint64_t) r.value);
    puts_("\n");
    check("spec version >= 2.0", r.error == 0 && r.value >= 0x2000000);
    r = sbi_ecall(SBI_EXT_BASE, 1, 0, 0, 0, 0);
    check_eq("implementation id is OpenSBI", (uint64_t) r.value, 1);
    r = sbi_ecall(SBI_EXT_BASE, 2, 0, 0, 0, 0);
    puts_("  implementation version ");
    puthex((uint64_t) r.value);
    puts_("\n");
    static const struct {
        long ext;
        const char *name;
    } probes[] = {{SBI_EXT_TIME, "TIME"},
                  {SBI_EXT_IPI, "IPI"},
                  {SBI_EXT_RFENCE, "RFENCE"},
                  {SBI_EXT_HSM, "HSM"},
                  {SBI_EXT_DBCN, "DBCN"},
                  {SBI_EXT_PMU, "PMU"},
                  {SBI_EXT_FWFT, "FWFT"}};
    for (unsigned i = 0; i < sizeof(probes) / sizeof(probes[0]); i++) {
        r = sbi_ecall(SBI_EXT_BASE, 3, (unsigned long) probes[i].ext, 0, 0, 0);
        puts_("  probe ");
        puts_(probes[i].name);
        check(" present", r.error == 0 && r.value != 0);
    }
    r = sbi_ecall(SBI_EXT_BASE, 3, SBI_EXT_SRST, 0, 0, 0);
    puts_("  probe SRST (no reset device expected): ");
    puthex((uint64_t) r.value);
    puts_("\n");
    r = sbi_ecall(SBI_EXT_BASE, 4, 0, 0, 0, 0);
    check_eq("mvendorid reads 0", (uint64_t) r.value, 0);
    r = sbi_ecall(SBI_EXT_BASE, 5, 0, 0, 0, 0);
    check_eq("marchid reads 0", (uint64_t) r.value, 0);
    r = sbi_ecall(SBI_EXT_BASE, 6, 0, 0, 0, 0);
    check_eq("mimpid reads 0", (uint64_t) r.value, 0);
    r = sbi_ecall(SBI_EXT_HSM, 2, hartid, 0, 0, 0);
    check_eq("HSM reports this hart STARTED", (uint64_t) r.value, 0);

    /* B: entry state. */
    puts_("B: entry state\n");
    check_eq("satp is Bare", csr_read(satp), 0);
    check_eq("scounteren opened by the firmware", csr_read(scounteren), 7);
    uint64_t t0 = csr_read(time);
    uint64_t c0 = csr_read(cycle);
    for (volatile int i = 0; i < 100; i++)
        ;
    check("time advances", csr_read(time) > t0);
    check("cycle readable and advances", csr_read(cycle) > c0);
    g_illegal_count = 0;
    uint64_t stc = csr_read(0x14D);
    csr_write(0x14D, stc);
    check("stimecmp accessible from S (menvcfg.STCE set)", g_illegal_count == 0);
    __asm__ volatile("sfence.vma\n sfence.vma x0, %0\n sfence.vma %0, x0\n" ::"r"(0ul) : "memory");
    check("sfence.vma operand forms accepted", g_illegal_count == 0);

    /* C: timers. */
    puts_("C: timers\n");
    csr_set(sie, SIE_STIE);
    csr_set(sstatus, SSTATUS_SIE);
    csr_write(0x14D, csr_read(time) + 2000);
    wait_irqs(&g_timer_irqs, 1);
    check_eq("stimecmp fires the S timer interrupt", g_timer_irqs, 1);
    r = sbi_ecall(SBI_EXT_TIME, 0, csr_read(time) + 2000, 0, 0, 0);
    check_eq("sbi_set_timer accepted", (uint64_t) r.error, 0);
    wait_irqs(&g_timer_irqs, 2);
    check_eq("sbi_set_timer fires the S timer interrupt (via stimecmp)", g_timer_irqs, 2);

    /* D: IPI and RFENCE. */
    puts_("D: IPI and RFENCE\n");
    csr_set(sie, SIE_SSIE);
    r = sbi_ecall(SBI_EXT_IPI, 0, 1, 0, 0, 0);
    check_eq("sbi_send_ipi accepted", (uint64_t) r.error, 0);
    wait_irqs(&g_soft_irqs, 1);
    check_eq("self IPI delivered as SSIP", g_soft_irqs, 1);
    r = sbi_ecall(SBI_EXT_RFENCE, 1, 1, 0, 0, 0);
    check_eq("remote sfence.vma accepted", (uint64_t) r.error, 0);
    r = sbi_ecall(SBI_EXT_RFENCE, 0, 1, 0, 0, 0);
    check_eq("remote fence.i accepted", (uint64_t) r.error, 0);
    csr_clear(sstatus, SSTATUS_SIE);

    /* E: console. */
    puts_("E: console\n");
    static const char dbcn_msg[] = "  [DBCN] hello from the SBI console\r\n";
    r = sbi_ecall(SBI_EXT_DBCN, 0, sizeof(dbcn_msg) - 1, (unsigned long) dbcn_msg, 0, 0);
    check("DBCN write returned the byte count",
          r.error == 0 && (unsigned long) r.value == sizeof(dbcn_msg) - 1);
    sbi_ecall(SBI_EXT_LEGACY_PUTCHAR, 0, '\n', 0, 0, 0);

    /* F: misaligned accesses emulated by the firmware. */
    puts_("F: misaligned emulation\n");
    misaligned_suite("  F1: satp Bare", g_buf, view_identity, code_identity);
    enable_sv39();
    check_eq("satp holds Sv39", csr_read(satp) >> 60, 8);
    misaligned_suite("  F2: Sv39, identity", g_buf, view_identity, code_identity);
    misaligned_suite("  F3: Sv39, code and data at the S alias", g_buf, view_s_alias, code_s_alias);
    puts_("  F4: U-mode at the U alias\n");
    fill(g_buf, 0);
    g_trap_count = 0;
    uint64_t uv = run_in_umode(
        u_alias((const void *) ubody_loads), u_alias(g_buf), u_alias(g_ustack + sizeof(g_ustack)));
    check_eq("U-mode scalar misaligned loads", uv, expected_scalar_loads(g_buf));
    check("only the final ecall trapped to S", g_trap_count == 1);
    fill(g_buf, 0x40);
    g_trap_count = 0;
    uint64_t wexp = 0;
    for (int i = 0; i < 4; i++)
        wexp |= (uint64_t) g_buf[1 + i] << (8 * i);
    wexp = (uint64_t) (int64_t) (int32_t) wexp;
    uv = run_in_umode(u_alias((const void *) ubody_compressed),
                      u_alias(g_buf),
                      u_alias(g_ustack + sizeof(g_ustack)));
    check_eq("U-mode compressed misaligned loads", uv, wexp ^ (expected_d(g_buf, 1) << 1));
    check("U-mode compressed misaligned stores", g_buf[33] == 0x88 && g_buf[34] == 0x77);
    puts_("  F5: emulated S access to a U page with SUM=0\n");
    csr_clear(sstatus, SSTATUS_SUM);
    g_last_cause = ~0ul;
    g_trap_count = 0;
    uint8_t *ub = (uint8_t *) u_alias(g_buf);
    uint64_t dummy;
    __asm__ volatile(".option push\n.option norvc\nlw %0, 1(%1)\n.option pop\n"
                     : "=r"(dummy)
                     : "r"(ub)
                     : "memory");
    check_eq("load page fault redirected to S", g_last_cause, CAUSE_LOAD_PAGE_FAULT);
    check_eq("stval carries the faulting VA", g_last_tval, (uint64_t) (uintptr_t) ub + 1);
    csr_set(sstatus, SSTATUS_SUM);
    g_trap_count = 0;
    __asm__ volatile(".option push\n.option norvc\nlw %0, 1(%1)\n.option pop\n"
                     : "=r"(dummy)
                     : "r"(ub)
                     : "memory");
    check("same access succeeds with SUM=1", g_trap_count == 0);
    check_eq("and returns the U page's data", dummy, (uint64_t) (int64_t) (int32_t) wexp);

    /* G: FWFT misaligned delegation (what Linux requests). */
    puts_("G: FWFT misaligned delegation\n");
    r = sbi_ecall(SBI_EXT_FWFT, 0, SBI_FWFT_MISALIGNED_EXC_DELEG, 1, 0, 0);
    check_eq("fwft_set(MISALIGNED_EXC_DELEG, 1)", (uint64_t) r.error, 0);
    r = sbi_ecall(SBI_EXT_FWFT, 1, SBI_FWFT_MISALIGNED_EXC_DELEG, 0, 0, 0);
    check("fwft_get reads it back", r.error == 0 && r.value == 1);
    g_last_cause = ~0ul;
    __asm__ volatile(".option push\n.option norvc\nlw %0, 1(%1)\n.option pop\n"
                     : "=r"(dummy)
                     : "r"(g_buf)
                     : "memory");
    check_eq("misaligned load now traps to S", g_last_cause, CAUSE_MISALIGNED_LOAD);
    check_eq("stval carries the misaligned VA", g_last_tval, (uint64_t) (uintptr_t) g_buf + 1);
    g_last_cause = ~0ul;
    __asm__ volatile(".option push\n.option norvc\nsw %0, 1(%1)\n.option pop\n"
                     :
                     : "r"(dummy), "r"(g_buf)
                     : "memory");
    check_eq("misaligned store now traps to S", g_last_cause, CAUSE_MISALIGNED_STORE);
    r = sbi_ecall(SBI_EXT_FWFT, 0, SBI_FWFT_MISALIGNED_EXC_DELEG, 0, 0, 0);
    check_eq("fwft_set(MISALIGNED_EXC_DELEG, 0)", (uint64_t) r.error, 0);

    /* H: SBI PMU on the fixed counters. */
    puts_("H: SBI PMU\n");
    r = sbi_ecall(SBI_EXT_PMU, 0, 0, 0, 0, 0);
    puts_("  counters ");
    puthex((uint64_t) r.value);
    puts_("\n");
    check("at least the three fixed counters", r.error == 0 && r.value >= 3);
    r = sbi_ecall(SBI_EXT_PMU, 1, 0, 0, 0, 0);
    check("counter 0 is a hardware counter", r.error == 0 && ((uint64_t) r.value >> 63) == 0);
    /* The bare payload has no Linux-style stop-all: stop cycle and instret
     * first (they run out of reset), then follow the Linux sequence. */
    r = sbi_ecall(SBI_EXT_PMU, 4, 0, 0x5, 0, 0);
    check("counter_stop(cycle, instret)", r.error == 0 || r.error == SBI_ERR_ALREADY_STOPPED);
    uint64_t cy1 = csr_read(cycle);
    for (volatile int i = 0; i < 100; i++)
        ;
    check("cycle is inhibited after the stop", csr_read(cycle) == cy1);
    r = sbi_ecall(SBI_EXT_PMU, 2, 0, 0x7, 0, SBI_PMU_HW_CPU_CYCLES);
    check_eq("config_matching(HW_CPU_CYCLES) picks counter 0", (uint64_t) r.value, 0);
    r = sbi_ecall(SBI_EXT_PMU, 2, 0, 0x7, 0, SBI_PMU_HW_INSTRUCTIONS);
    check_eq("config_matching(HW_INSTRUCTIONS) picks counter 2", (uint64_t) r.value, 2);
    r = sbi_ecall(SBI_EXT_PMU, 3, 0, 0x1, SBI_PMU_START_FLAG_SET_INIT_VALUE, 0x8000000000001000ul);
    check_eq("counter_start(cycle, init 2^63 + 0x1000)", (uint64_t) r.error, 0);
    uint64_t cy2 = csr_read(cycle);
    check("cycle restarted from the initial value",
          cy2 >= 0x8000000000001000ul && cy2 < 0x8000000000001000ul + 4096);
    r = sbi_ecall(SBI_EXT_PMU, 3, 0, 0x4, SBI_PMU_START_FLAG_SET_INIT_VALUE, 0x8000000000000000ul);
    check_eq("counter_start(instret, init 2^63)", (uint64_t) r.error, 0);
    uint64_t ir1 = csr_read(instret);
    for (volatile int i = 0; i < 100; i++)
        ;
    uint64_t ir2 = csr_read(instret);
    check("instret restarted from the initial value and counts",
          ir1 >= 0x8000000000000000ul && ir2 > ir1 && ir2 - ir1 < 100000);
    r = sbi_ecall(SBI_EXT_PMU, 3, 0, 0x1, SBI_PMU_START_FLAG_SET_INIT_VALUE, 0);
    check_eq("starting a running counter reports ALREADY_STARTED",
             (uint64_t) r.error,
             (uint64_t) SBI_ERR_ALREADY_STARTED);
    r = sbi_ecall(SBI_EXT_PMU, 4, 0, 0x5, 0, 0);
    check_eq("counter_stop(cycle, instret) again", (uint64_t) r.error, 0);
    uint64_t cy3 = csr_read(cycle);
    uint64_t ir3 = csr_read(instret);
    for (volatile int i = 0; i < 100; i++)
        ;
    check("both counters inhibited again", csr_read(cycle) == cy3 && csr_read(instret) == ir3);
    r = sbi_ecall(SBI_EXT_PMU, 3, 0, 0x5, SBI_PMU_START_FLAG_SET_INIT_VALUE, 0x100);
    check_eq("second start round", (uint64_t) r.error, 0);
    check("counters run from the second initial value",
          csr_read(cycle) >= 0x100 && csr_read(cycle) < 0x100 + 4096);

    puts_(g_failed ? "\n=== OpenSBI smoke FAILED ===\n<<FAIL>>\n"
                   : "\n=== OpenSBI smoke PASSED ===\n<<PASS>>\n");
    for (;;)
        __asm__ volatile("wfi");
}
