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
 * Directed test for odd-halfword slot-1 fast-BTB predictions, non-crossing
 * pending-prediction handoffs to odd targets, cache-line- and page-spanning
 * 32-bit branches/calls (including a faulting second page and RAS integrity),
 * and overlapping 32-bit instructions across odd BTB entries.
 */

#include <stddef.h>
#include <stdint.h>

#include "trap.h"
#include "uart.h"

extern uint64_t ohp_case1a_loop(uint64_t iters);
extern uint64_t ohp_case1b_loop(uint64_t iters);
extern uint64_t ohp_case2_loop(uint64_t iters);
extern uint64_t ohp_case3a_line_end(uint64_t iters);

extern uint64_t ohp_case4a_train(uint64_t a0, uint64_t a1, uint64_t a2);
extern uint64_t
ohp_case4a_overlap(uint64_t a0, uint64_t a1, uint64_t a2, uint64_t a3, uint64_t a4, uint64_t a5);

extern uint64_t ohp_case4b_train(uint64_t a0, uint64_t a1, uint64_t a2);
extern uint64_t
ohp_case4b_overlap(uint64_t a0, uint64_t a1, uint64_t a2, uint64_t a3, uint64_t a4, uint64_t a5);

extern uint64_t ohp_case4c_train(uint64_t a0, uint64_t a1, uint64_t a2);
extern uint64_t
ohp_case4c_overlap(uint64_t a0, uint64_t a1, uint64_t a2, uint64_t a3, uint64_t a4, uint64_t a5);

extern char ohp_case1a_head[];
extern char ohp_case1a_bne[];
extern char ohp_case1b_head[];
extern char ohp_case1b_target[];
extern char ohp_case1b_bne[];
extern char ohp_case2_head[];
extern char ohp_case2_call[];
extern char ohp_case2_bne[];
extern char ohp_case3a_base[];
extern char ohp_case3a_call[];
extern char ohp_case3a_bne[];
extern char ohp_page_caller[];
extern char ohp_page0[];
extern char ohp_page0_span_jal[];
extern char ohp_page0_end[];
extern char ohp_page1[];
extern char ohp_page_evict[];
extern void ohp_enter_s_driver(unsigned long va_entry, unsigned long ctx_addr);
extern void ohp_m_trap_handler(void);

#define PT_ROOT 0x81000000ul
#define PT_L1 0x81001000ul
#define PT_L0_BASE 0x81002000ul
#define OHP_CTX_ADDR 0x81020000ul

#define VA_CALLER 0x00600000ul
#define VA_PAGE0 0x00602000ul
#define VA_PAGE1 0x00603000ul
#define VA_SPAN_PC (VA_PAGE0 + 0xffeul)
#define EVICT_STRIDE 0x00080000ul
#define EVICT_PAGES 20u
/* Training calls and one faulting call per attempt (cases.S, ohp_page_caller). */
#define TRAIN_ITERS 8u
#define FAULT_ATTEMPTS 2u

#define PTE_V (1ul << 0)
#define PTE_R (1ul << 1)
#define PTE_W (1ul << 2)
#define PTE_X (1ul << 3)
#define PTE_A (1ul << 6)
#define PTE_D (1ul << 7)
#define PTE_PPN(pa) ((((unsigned long) (pa)) >> 12) << 10)
#define SATP_SV39 (8ul << 60)

struct ohp_s_ctx {
    uint64_t va_page0_entry;
    uint64_t pte_page1_ptr;
    uint64_t pte_page1_valid;
    uint64_t va_evict_base;
    uint64_t evict_count;
    uint64_t train_iters;
    uint64_t seen_faults;
    uint64_t seen_cause;
    uint64_t seen_epc;
    uint64_t seen_tval;
    uint64_t post_fault_a1;
    uint64_t post_fault_a3;
    uint64_t outer_ret_mispred;
    uint64_t exit_mcause;
    uint64_t fault_attempts;
};

_Static_assert(offsetof(struct ohp_s_ctx, va_page0_entry) == 0, "offset 0");
_Static_assert(offsetof(struct ohp_s_ctx, pte_page1_ptr) == 8, "offset 8");
_Static_assert(offsetof(struct ohp_s_ctx, pte_page1_valid) == 16, "offset 16");
_Static_assert(offsetof(struct ohp_s_ctx, va_evict_base) == 24, "offset 24");
_Static_assert(offsetof(struct ohp_s_ctx, evict_count) == 32, "offset 32");
_Static_assert(offsetof(struct ohp_s_ctx, train_iters) == 40, "offset 40");
_Static_assert(offsetof(struct ohp_s_ctx, seen_faults) == 48, "offset 48");
_Static_assert(offsetof(struct ohp_s_ctx, seen_cause) == 56, "offset 56");
_Static_assert(offsetof(struct ohp_s_ctx, seen_epc) == 64, "offset 64");
_Static_assert(offsetof(struct ohp_s_ctx, seen_tval) == 72, "offset 72");
_Static_assert(offsetof(struct ohp_s_ctx, post_fault_a1) == 80, "offset 80");
_Static_assert(offsetof(struct ohp_s_ctx, post_fault_a3) == 88, "offset 88");
_Static_assert(offsetof(struct ohp_s_ctx, outer_ret_mispred) == 96, "offset 96");
_Static_assert(offsetof(struct ohp_s_ctx, exit_mcause) == 104, "offset 104");
_Static_assert(offsetof(struct ohp_s_ctx, fault_attempts) == 112, "offset 112");

static inline uint64_t read_mhpm3(void)
{
    uint64_t v;
    __asm__ volatile("csrr %0, mhpmcounter3" : "=r"(v));
    return v;
}

static inline uint64_t read_mhpm4(void)
{
    uint64_t v;
    __asm__ volatile("csrr %0, mhpmcounter4" : "=r"(v));
    return v;
}

static inline uint64_t read_minstret(void)
{
    uint64_t v;
    __asm__ volatile("csrr %0, minstret" : "=r"(v));
    return v;
}

static void init_counters(void)
{
    unsigned long ev3 = 3ul;
    unsigned long ev4 = 4ul;
    unsigned long mcen = 0x7fful;
    __asm__ volatile("csrw 0x323, %0\n"
                     "csrw 0x324, %1\n"
                     "csrw 0x320, zero\n"
                     "csrw mcounteren, %2\n"
                     :
                     : "r"(ev3), "r"(ev4), "r"(mcen));
}

static int run_loop_case(const char *name,
                         uint64_t (*fn)(uint64_t),
                         uint64_t iters,
                         uint64_t want_ret,
                         uint64_t min_branches,
                         uint64_t max_mispreds,
                         uint64_t min_instret)
{
    /* Warm the fast BTB, bimodal, and tagged predictors at the target trip count. */
    (void) fn(iters);

    uint64_t b0 = read_mhpm3();
    uint64_t m0 = read_mhpm4();
    uint64_t i0 = read_minstret();
    uint64_t got = fn(iters);
    uint64_t db = read_mhpm3() - b0;
    uint64_t dm = read_mhpm4() - m0;
    uint64_t di = read_minstret() - i0;

    int ok =
        (got == want_ret) && (db >= min_branches) && (dm <= max_mispreds) && (di >= min_instret);
    uart_printf("%s %s: got=0x%llx br=%llu misp=%llu inst=%llu\n",
                ok ? "[PASS]" : "[FAIL]",
                name,
                (unsigned long long) got,
                (unsigned long long) db,
                (unsigned long long) dm,
                (unsigned long long) di);
    return ok;
}

static unsigned long map_va_4k(unsigned long va, unsigned long pa, unsigned long flags)
{
    volatile unsigned long *l1 = (volatile unsigned long *) PT_L1;
    unsigned long vpn1 = (va >> 21) & 0x1fful;
    unsigned long vpn0 = (va >> 12) & 0x1fful;
    unsigned long l0_pa = PT_L0_BASE + ((vpn1 - 3ul) * 0x1000ul);
    volatile unsigned long *l0 = (volatile unsigned long *) l0_pa;
    l1[vpn1] = PTE_PPN(l0_pa) | PTE_V;
    l0[vpn0] = PTE_PPN(pa) | flags;
    return (unsigned long) &l0[vpn0];
}

static int run_page_end_case(const char *name, int delegate_to_s)
{
    volatile unsigned long *root = (volatile unsigned long *) PT_ROOT;
    volatile unsigned long *l1 = (volatile unsigned long *) PT_L1;
    volatile struct ohp_s_ctx *ctx = (volatile struct ohp_s_ctx *) OHP_CTX_ADDR;

    for (unsigned i = 0; i < 512; i++) {
        root[i] = 0;
        l1[i] = 0;
    }
    for (unsigned tbl = 0; tbl < 6; tbl++) {
        volatile unsigned long *l0 =
            (volatile unsigned long *) (PT_L0_BASE + (unsigned long) tbl * 0x1000ul);
        for (unsigned i = 0; i < 512; i++)
            l0[i] = 0;
    }

    root[0] = PTE_PPN(PT_L1) | PTE_V;
    /* Identity-map DDR 0x8000_0000..0xbfff_ffff so S-mode accesses page tables and ctx. */
    root[2] = PTE_PPN(0x80000000ul) | PTE_V | PTE_R | PTE_W | PTE_A | PTE_D;

    map_va_4k(VA_CALLER, (unsigned long) ohp_page_caller, PTE_V | PTE_R | PTE_X | PTE_A);
    map_va_4k(VA_PAGE0, (unsigned long) ohp_page0, PTE_V | PTE_R | PTE_X | PTE_A);
    unsigned long pte_p1_addr =
        map_va_4k(VA_PAGE1, (unsigned long) ohp_page1, PTE_V | PTE_R | PTE_X | PTE_A);
    unsigned long valid_p1_pte = *(volatile unsigned long *) pte_p1_addr;

    for (unsigned k = 0; k < EVICT_PAGES; k++) {
        unsigned long va = VA_PAGE1 + (unsigned long) (k + 1u) * EVICT_STRIDE;
        map_va_4k(va, (unsigned long) ohp_page_evict, PTE_V | PTE_R | PTE_X | PTE_A);
    }

    ctx->va_page0_entry = VA_PAGE0 + 0xfb0ul;
    ctx->pte_page1_ptr = pte_p1_addr;
    ctx->pte_page1_valid = valid_p1_pte;
    ctx->va_evict_base = VA_PAGE1 + EVICT_STRIDE + 0x100ul;
    ctx->evict_count = EVICT_PAGES;
    ctx->train_iters = TRAIN_ITERS;
    ctx->fault_attempts = FAULT_ATTEMPTS;
    ctx->seen_faults = 0u;
    ctx->seen_cause = ~0ull;
    ctx->seen_epc = ~0ull;
    ctx->seen_tval = ~0ull;
    ctx->post_fault_a1 = 0u;
    ctx->post_fault_a3 = 0u;
    ctx->outer_ret_mispred = ~0ull;
    ctx->exit_mcause = ~0ull;

    set_trap_handler(&ohp_m_trap_handler);
    unsigned long medeleg_val = delegate_to_s ? (1ul << 12) : 0ul;
    unsigned long stvec_val = VA_CALLER + 0x200ul;
    unsigned long satp_val = SATP_SV39 | (PT_ROOT >> 12);

    __asm__ volatile("csrw medeleg, %0\n"
                     "csrw stvec, %1\n"
                     "sfence.vma\n"
                     "csrw satp, %2\n"
                     "sfence.vma\n"
                     :
                     : "r"(medeleg_val), "r"(stvec_val), "r"(satp_val)
                     : "memory");

    ohp_enter_s_driver(VA_CALLER, OHP_CTX_ADDR);

    __asm__ volatile("csrw satp, zero\n"
                     "csrw medeleg, zero\n"
                     "sfence.vma\n" ::
                         : "memory");

    int ras_ok = delegate_to_s ? (ctx->outer_ret_mispred == 0u) : 1;
    /* Each call through ohp_page0 adds 1 to a1 and 11 to a3. */
    uint64_t calls = (uint64_t) FAULT_ATTEMPTS * (TRAIN_ITERS + 1u);
    int ok = (ctx->seen_faults == FAULT_ATTEMPTS) && (ctx->seen_cause == 12u) &&
             (ctx->seen_epc == VA_SPAN_PC) && (ctx->seen_tval == (VA_SPAN_PC + 2ul)) &&
             (ctx->post_fault_a1 == calls) && (ctx->post_fault_a3 == 11u * calls) &&
             (ctx->exit_mcause == 9u) && ras_ok;

    uart_printf("%s %s: faults=%llu cause=%llu epc=0x%llx tval=0x%llx "
                "a1=%llu a3=%llu ret_misp=%llu\n",
                ok ? "[PASS]" : "[FAIL]",
                name,
                (unsigned long long) ctx->seen_faults,
                (unsigned long long) ctx->seen_cause,
                (unsigned long long) ctx->seen_epc,
                (unsigned long long) ctx->seen_tval,
                (unsigned long long) ctx->post_fault_a1,
                (unsigned long long) ctx->post_fault_a3,
                (unsigned long long) ctx->outer_ret_mispred);
    return ok;
}

static int
run_overlap_case(const char *name,
                 uint64_t (*train_fn)(uint64_t, uint64_t, uint64_t),
                 uint64_t (*overlap_fn)(uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t),
                 uint64_t want_overlap)
{
    int ok = 1;
    uint64_t last_got = 0;

    for (int round = 0; round < 4; round++) {
        for (int t = 0; t < 6; t++) {
            uint64_t tr = train_fn(1u, 0u, 0u);
            if (tr != 0u)
                ok = 0;
        }
        last_got = overlap_fn(0u, 0u, 0u, 0u, 0u, 1u);
        if (last_got != want_overlap)
            ok = 0;
    }

    uart_printf("%s %s: got=0x%016llx want=0x%016llx\n",
                ok ? "[PASS]" : "[FAIL]",
                name,
                (unsigned long long) last_got,
                (unsigned long long) want_overlap);
    return ok;
}

static int check_pinned_layout(void)
{
    int ok = ((uintptr_t) ohp_case1a_bne - (uintptr_t) ohp_case1a_head == 0x06u) &&
             ((uintptr_t) ohp_case1b_target - (uintptr_t) ohp_case1b_head == 0x0au) &&
             ((uintptr_t) ohp_case1b_bne - (uintptr_t) ohp_case1b_head == 0x12u) &&
             ((uintptr_t) ohp_case2_call - (uintptr_t) ohp_case2_head == 0x06u) &&
             ((uintptr_t) ohp_case2_bne - (uintptr_t) ohp_case2_head == 0x0eu) &&
             ((uintptr_t) ohp_case3a_call - (uintptr_t) ohp_case3a_base == 0x1eu) &&
             ((uintptr_t) ohp_case3a_bne - (uintptr_t) ohp_case3a_base == 0x3eu) &&
             ((uintptr_t) ohp_case4a_train - (uintptr_t) ohp_case4a_overlap == 0x0au) &&
             ((uintptr_t) ohp_case4b_train - (uintptr_t) ohp_case4b_overlap == 0x0au) &&
             ((uintptr_t) ohp_case4c_train - (uintptr_t) ohp_case4c_overlap == 0x0cu) &&
             ((uintptr_t) ohp_page0_span_jal - (uintptr_t) ohp_page0 == 0xffeu) &&
             ((uintptr_t) ohp_page0_end - (uintptr_t) ohp_page0 == 0x1000u);
    uart_printf("%s pinned alignment layout check\n", ok ? "[PASS]" : "[FAIL]");
    return ok;
}

int main(void)
{
    int all_ok = 1;

    uart_puts("\n=== Odd-Halfword Fast-BTB & Handoff Test ===\n");
    init_counters();
    all_ok &= check_pinned_layout();

    all_ok &= run_loop_case("1a odd-halfword 32b loop branch",
                            ohp_case1a_loop,
                            64u,
                            (64ull << 16) | 192ull,
                            64u,
                            8u,
                            192u);
    all_ok &= run_loop_case("1b even-to-odd 32b target + odd 32b branch",
                            ohp_case1b_loop,
                            64u,
                            (64ull << 16) | 320ull,
                            192u,
                            8u,
                            320u);
    all_ok &= run_loop_case("2 odd-halfword 32b jal ra + return",
                            ohp_case2_loop,
                            64u,
                            (64ull << 16) | 512ull,
                            192u,
                            8u,
                            384u);
    all_ok &= run_loop_case("3a cache-line-end spanning jal + bne",
                            ohp_case3a_line_end,
                            64u,
                            (64ull << 16) | 832ull,
                            192u,
                            8u,
                            832u);
    all_ok &= run_page_end_case("3b-S Sv39 page-end spanning jal fault+retry (Svvptc)", 1);
    all_ok &= run_page_end_case("3b-M Sv39 page-end spanning jal fault+retry (M-mode)", 0);
    all_ok &= run_overlap_case("4a overlapping 32b lui over compressed BTB entry",
                               ohp_case4a_train,
                               ohp_case4a_overlap,
                               0xffffffffa0190055ull);
    all_ok &= run_overlap_case("4b overlapping 32b lui over native 32b BTB entry",
                               ohp_case4b_train,
                               ohp_case4b_overlap,
                               0x0000000014630055ull);
    all_ok &= run_overlap_case("4c overlapping 32b lui over even pending BTB entry",
                               ohp_case4c_train,
                               ohp_case4c_overlap,
                               0xffffffffa0190055ull);

    uart_puts(all_ok ? "<<PASS>>\n" : "<<FAIL>>\n");
    for (;;) {
    }
}
