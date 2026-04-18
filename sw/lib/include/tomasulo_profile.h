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

#ifndef TOMASULO_PROFILE_H
#define TOMASULO_PROFILE_H

#include "csr.h"
#include "uart.h"

#include <stdint.h>

#define TOMASULO_PROFILE_COUNTER_COUNT 104U

enum tomasulo_profile_counter_idx {
    TOMASULO_PERF_DISPATCH_FIRE = 0,
    TOMASULO_PERF_DISPATCH_STALL = 1,
    TOMASULO_PERF_FRONTEND_BUBBLE = 2,
    TOMASULO_PERF_FLUSH_RECOVERY = 3,
    TOMASULO_PERF_POST_FLUSH_HOLDOFF = 4,
    TOMASULO_PERF_CSR_SERIALIZE = 5,
    TOMASULO_PERF_CONTROL_FLOW_SERIALIZE = 6,
    TOMASULO_PERF_DISPATCH_STALL_ROB_FULL = 7,
    TOMASULO_PERF_DISPATCH_STALL_INT_RS_FULL = 8,
    TOMASULO_PERF_DISPATCH_STALL_MUL_RS_FULL = 9,
    TOMASULO_PERF_DISPATCH_STALL_MEM_RS_FULL = 10,
    TOMASULO_PERF_DISPATCH_STALL_FP_RS_FULL = 11,
    TOMASULO_PERF_DISPATCH_STALL_FMUL_RS_FULL = 12,
    TOMASULO_PERF_DISPATCH_STALL_FDIV_RS_FULL = 13,
    TOMASULO_PERF_DISPATCH_STALL_LQ_FULL = 14,
    TOMASULO_PERF_DISPATCH_STALL_SQ_FULL = 15,
    TOMASULO_PERF_DISPATCH_STALL_CHECKPOINT_FULL = 16,
    TOMASULO_PERF_NO_RETIRE_NOT_EMPTY = 17,
    TOMASULO_PERF_ROB_EMPTY = 18,
    TOMASULO_PERF_PREDICTION_DISABLED = 19,
    TOMASULO_PERF_PRED_FENCE_BRANCH = 20,
    TOMASULO_PERF_PRED_FENCE_JAL = 21,
    TOMASULO_PERF_PRED_FENCE_INDIRECT = 22,
    /* Slot-1 (2-wide dispatch) — fire is gate-dependent, opportunity/blocked
     * are gate-independent so a gate=1 baseline still surfaces pair density. */
    TOMASULO_PERF_SLOT1_FIRE = 23,
    TOMASULO_PERF_SLOT1_OPPORTUNITY = 24,
    TOMASULO_PERF_SLOT1_BLOCKED = 25,
    /* Slot-1 stall sub-buckets: decompose SLOT1_BLOCKED by which resource was
     * the bottleneck. INT_RS_ONLY + ROB2_ONLY + BOTH == SLOT1_BLOCKED.
     * PAIR_LOST is slot-0-dispatched + slot-1-opportunity + slot-1-no-fire;
     * at gate=1 this ≈ opportunity ∩ dispatch_fire, at gate=0 it should be
     * ~0 (slot1_resource_stall backpressures slot-0 too). */
    TOMASULO_PERF_SLOT1_STALL_INT_RS_ONLY = 26,
    TOMASULO_PERF_SLOT1_STALL_ROB2_ONLY = 27,
    TOMASULO_PERF_SLOT1_STALL_BOTH = 28,
    TOMASULO_PERF_SLOT1_PAIR_LOST = 29,
    /* Front-end bubble sub-cause decomposition.  Each sub-counter applies the
     * same outer gate as FRONTEND_BUBBLE plus a priority-ordered sel_nop-cause
     * mask sourced from IF.  Sum (C_EXT_FLUSH + ALIGN + PRED_TARGET + PRED_FETCH
     * + CF_HOLDOFF + OTHER) equals FRONTEND_BUBBLE; OTHER catches bubble cycles
     * where no tracked sel_nop cause fires (post-reset holdoff, PD/ID drops). */
    TOMASULO_PERF_FRONTEND_BUBBLE_C_EXT_FLUSH = 30,
    TOMASULO_PERF_FRONTEND_BUBBLE_ALIGN = 31,
    TOMASULO_PERF_FRONTEND_BUBBLE_PRED_TARGET = 32,
    TOMASULO_PERF_FRONTEND_BUBBLE_PRED_FETCH = 33,
    TOMASULO_PERF_FRONTEND_BUBBLE_CF_HOLDOFF = 34,
    TOMASULO_PERF_FRONTEND_BUBBLE_OTHER = 35,
    /* Second-level decomposition of FRONTEND_BUBBLE_OTHER: priority-ordered
     * partition covering the bubble cycles with no tracked IF sel_nop cause.
     *   PD_INVALID : pd_valid_q=0 (post-flush refill tail / chain cleared).
     *   STALL_TAIL : stall_q lag after dispatch_status.stall drops.
     *   ID_ILLEGAL : from_id_to_ex.is_illegal_instruction.
     *   ID_NOP     : from_id_to_ex.instruction==NOP with pd_valid_q=1 —
     *                likely PD-side wrong-path squash (pd_stage forces NOP
     *                into PD→ID register when pd_redirect_r fires), or
     *                program-encoded NOP (rare in optimized Coremark).
     *   REST       : residual.
     * Sum equals FRONTEND_BUBBLE_OTHER. */
    TOMASULO_PERF_FRONTEND_BUBBLE_OTHER_PD_INVALID = 36,
    TOMASULO_PERF_FRONTEND_BUBBLE_OTHER_STALL_TAIL = 37,
    TOMASULO_PERF_FRONTEND_BUBBLE_OTHER_ID_ILLEGAL = 38,
    TOMASULO_PERF_FRONTEND_BUBBLE_OTHER_ID_NOP = 39,
    TOMASULO_PERF_FRONTEND_BUBBLE_OTHER_REST = 40,
    TOMASULO_PERF_HEAD_WAIT_TOTAL = 41,
    TOMASULO_PERF_HEAD_WAIT_INT = 42,
    TOMASULO_PERF_HEAD_WAIT_BRANCH = 43,
    TOMASULO_PERF_HEAD_WAIT_MUL = 44,
    TOMASULO_PERF_HEAD_WAIT_MEM_LOAD = 45,
    TOMASULO_PERF_HEAD_WAIT_MEM_STORE = 46,
    TOMASULO_PERF_HEAD_WAIT_MEM_AMO = 47,
    TOMASULO_PERF_HEAD_WAIT_FP = 48,
    TOMASULO_PERF_HEAD_WAIT_FMUL = 49,
    TOMASULO_PERF_HEAD_WAIT_FDIV = 50,
    TOMASULO_PERF_COMMIT_BLOCKED_CSR = 51,
    TOMASULO_PERF_COMMIT_BLOCKED_FENCE = 52,
    TOMASULO_PERF_COMMIT_BLOCKED_WFI = 53,
    TOMASULO_PERF_COMMIT_BLOCKED_MRET = 54,
    TOMASULO_PERF_COMMIT_BLOCKED_TRAP = 55,
    TOMASULO_PERF_INT_BACKPRESSURE = 56,
    TOMASULO_PERF_MUL_BACKPRESSURE = 57,
    TOMASULO_PERF_MEM_RESULT_BACKPRESSURE = 58,
    TOMASULO_PERF_FP_ADD_BACKPRESSURE = 59,
    TOMASULO_PERF_FMUL_BACKPRESSURE = 60,
    TOMASULO_PERF_FDIV_BACKPRESSURE = 61,
    TOMASULO_PERF_MEM_DISAMBIGUATION_WAIT = 62,
    TOMASULO_PERF_SQ_COMMITTED_PENDING = 63,
    TOMASULO_PERF_SQ_MEM_WRITE_FIRE = 64,
    TOMASULO_PERF_LQ_MEM_READ_FIRE = 65,
    TOMASULO_PERF_ROB_OCCUPANCY_SUM = 66,
    TOMASULO_PERF_LQ_OCCUPANCY_SUM = 67,
    TOMASULO_PERF_SQ_OCCUPANCY_SUM = 68,
    TOMASULO_PERF_INT_RS_OCCUPANCY_SUM = 69,
    TOMASULO_PERF_MUL_RS_OCCUPANCY_SUM = 70,
    TOMASULO_PERF_MEM_RS_OCCUPANCY_SUM = 71,
    TOMASULO_PERF_FP_RS_OCCUPANCY_SUM = 72,
    TOMASULO_PERF_FMUL_RS_OCCUPANCY_SUM = 73,
    TOMASULO_PERF_FDIV_RS_OCCUPANCY_SUM = 74,
    TOMASULO_PERF_LQ_L0_HIT = 75,
    TOMASULO_PERF_LQ_L0_FILL = 76,
    TOMASULO_PERF_HEAD_AND_NEXT_DONE = 77,
    TOMASULO_PERF_HEAD_WAIT_LOAD_OUTSTANDING = 78,
    TOMASULO_PERF_HEAD_WAIT_LOAD_NO_OUTSTANDING = 79,
    TOMASULO_PERF_HEAD_PLUS_ONE_DONE = 80,
    TOMASULO_PERF_COMMIT_2_OPPORTUNITY = 81,
    TOMASULO_PERF_COMMIT_2_FIRE_ACTUAL = 82,
    TOMASULO_PERF_HEAD_LOAD_ADDR_PENDING = 83,
    TOMASULO_PERF_HEAD_LOAD_SQ_DISAMBIG = 84,
    TOMASULO_PERF_HEAD_LOAD_BUS_BLOCKED = 85,
    TOMASULO_PERF_HEAD_LOAD_CDB_WAIT = 86,
    TOMASULO_PERF_HEAD_LOAD_POST_LQ = 87,
    TOMASULO_PERF_HEAD_LOAD_BB_ISSUED = 88,
    TOMASULO_PERF_HEAD_LOAD_BB_BUS_BUSY = 89,
    TOMASULO_PERF_HEAD_LOAD_BB_AMO = 90,
    TOMASULO_PERF_HEAD_LOAD_BB_SQ_WAIT = 91,
    TOMASULO_PERF_HEAD_LOAD_BB_STAGING = 92,
    TOMASULO_PERF_HEAD_INT_OPERAND_WAIT = 93,
    TOMASULO_PERF_HEAD_INT_RS_READY_NOT_ISSUED = 94,
    TOMASULO_PERF_HEAD_INT_STAGE2 = 95,
    TOMASULO_PERF_HEAD_INT_POST_RS = 96,
    TOMASULO_PERF_COMMIT_2_BLOCKED_HEAD_SERIAL = 97,
    TOMASULO_PERF_COMMIT_2_BLOCKED_NEXT_SERIAL = 98,
    TOMASULO_PERF_COMMIT_2_BLOCKED_NEXT_BRANCH_MISPRED = 99,
    TOMASULO_PERF_COMMIT_2_BLOCKED_NEXT_BRANCH_CORRECT = 100,
    TOMASULO_PERF_HEAD_LOAD_BB_STG_CAPTURE = 101,
    TOMASULO_PERF_HEAD_LOAD_BB_STG_LAUNCH = 102,
    TOMASULO_PERF_HEAD_LOAD_BB_STG_OTHER = 103,
};

typedef struct tomasulo_profile_snapshot {
    uint64_t cycles;
    uint64_t instret;
    uint32_t counter_count;
    uint64_t counters[TOMASULO_PROFILE_COUNTER_COUNT];
} tomasulo_profile_snapshot_t;

static inline __attribute__((always_inline)) uint64_t tomasulo_profile_read_selected_counter64(void)
{
    uint64_t lo = csr_read_imm(CSR_MPERFDATA);
    uint64_t hi = csr_read_imm(CSR_MPERFDATAH);
    return (hi << 32) | lo;
}

static inline void tomasulo_profile_take_snapshot(tomasulo_profile_snapshot_t *snapshot)
{
    uint32_t i;
    uint32_t count;

    csr_write_imm(CSR_MPERFCTL, 1U);
    snapshot->cycles = rdcycle64();
    snapshot->instret = rdinstret64();

    count = csr_read_imm(CSR_MPERFCOUNT);
    if (count > TOMASULO_PROFILE_COUNTER_COUNT) {
        count = TOMASULO_PROFILE_COUNTER_COUNT;
    }
    snapshot->counter_count = count;

    for (i = 0; i < TOMASULO_PROFILE_COUNTER_COUNT; i++) {
        snapshot->counters[i] = 0;
    }

    for (i = 0; i < count; i++) {
        csr_write_imm(CSR_MPERFSEL, i);
        snapshot->counters[i] = tomasulo_profile_read_selected_counter64();
    }
}

static inline uint64_t tomasulo_profile_delta(const tomasulo_profile_snapshot_t *start,
                                              const tomasulo_profile_snapshot_t *end,
                                              uint32_t idx)
{
    uint32_t count = start->counter_count;
    if (end->counter_count < count) {
        count = end->counter_count;
    }
    if (idx >= count) {
        return 0;
    }
    return end->counters[idx] - start->counters[idx];
}

static inline uint32_t tomasulo_profile_ratio_scaled(uint64_t value, uint64_t total, uint32_t scale)
{
    if (total == 0) {
        return 0;
    }
    while (value > (UINT32_MAX / scale) || total > UINT32_MAX) {
        value >>= 1;
        total >>= 1;
        if (total == 0) {
            total = 1;
            break;
        }
    }
    return (((uint32_t) value * scale) + ((uint32_t) total / 2U)) / (uint32_t) total;
}

static inline uint32_t tomasulo_profile_pct_x10(uint64_t value, uint64_t total)
{
    return tomasulo_profile_ratio_scaled(value, total, 1000U);
}

static inline void tomasulo_profile_print_u64_hex(uint64_t value)
{
    uart_printf("0x%08x%08x", (unsigned int) (value >> 32), (unsigned int) (value & 0xFFFFFFFFu));
}

static inline void tomasulo_profile_print_metric(const char *label, uint64_t value, uint64_t total)
{
    uint32_t pct_x10 = tomasulo_profile_pct_x10(value, total);
    uart_printf("  %s: ", label);
    tomasulo_profile_print_u64_hex(value);
    uart_printf(
        " (%lu.%01lu%%)\n", (unsigned long) (pct_x10 / 10U), (unsigned long) (pct_x10 % 10U));
}

static inline void tomasulo_profile_print_average(const char *label, uint64_t sum, uint64_t cycles)
{
    uint32_t avg_x100 = tomasulo_profile_ratio_scaled(sum, cycles, 100U);
    uart_printf("  %s avg occ: %lu.%02lu\n",
                label,
                (unsigned long) (avg_x100 / 100U),
                (unsigned long) (avg_x100 % 100U));
}

static inline void tomasulo_profile_consider_top(const char **best_label,
                                                 uint64_t *best_value,
                                                 const char *candidate_label,
                                                 uint64_t candidate_value)
{
    if (candidate_value > *best_value) {
        *best_label = candidate_label;
        *best_value = candidate_value;
    }
}

static inline void
tomasulo_profile_pick_top_dispatch_cause(const tomasulo_profile_snapshot_t *start,
                                         const tomasulo_profile_snapshot_t *end,
                                         const char **label,
                                         uint64_t *value)
{
    *label = "none";
    *value = 0;

    tomasulo_profile_consider_top(
        label,
        value,
        "rob",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_DISPATCH_STALL_ROB_FULL));
    tomasulo_profile_consider_top(
        label,
        value,
        "int_rs",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_DISPATCH_STALL_INT_RS_FULL));
    tomasulo_profile_consider_top(
        label,
        value,
        "mul_rs",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_DISPATCH_STALL_MUL_RS_FULL));
    tomasulo_profile_consider_top(
        label,
        value,
        "mem_rs",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_DISPATCH_STALL_MEM_RS_FULL));
    tomasulo_profile_consider_top(
        label,
        value,
        "fp_rs",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_DISPATCH_STALL_FP_RS_FULL));
    tomasulo_profile_consider_top(
        label,
        value,
        "fmul_rs",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_DISPATCH_STALL_FMUL_RS_FULL));
    tomasulo_profile_consider_top(
        label,
        value,
        "fdiv_rs",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_DISPATCH_STALL_FDIV_RS_FULL));
    tomasulo_profile_consider_top(
        label,
        value,
        "lq",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_DISPATCH_STALL_LQ_FULL));
    tomasulo_profile_consider_top(
        label,
        value,
        "sq",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_DISPATCH_STALL_SQ_FULL));
    tomasulo_profile_consider_top(
        label,
        value,
        "ckpt",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_DISPATCH_STALL_CHECKPOINT_FULL));
}

static inline void tomasulo_profile_pick_top_retire_cause(const tomasulo_profile_snapshot_t *start,
                                                          const tomasulo_profile_snapshot_t *end,
                                                          const char **label,
                                                          uint64_t *value)
{
    *label = "none";
    *value = 0;

    tomasulo_profile_consider_top(
        label, value, "int", tomasulo_profile_delta(start, end, TOMASULO_PERF_HEAD_WAIT_INT));
    tomasulo_profile_consider_top(
        label, value, "branch", tomasulo_profile_delta(start, end, TOMASULO_PERF_HEAD_WAIT_BRANCH));
    tomasulo_profile_consider_top(
        label, value, "mul", tomasulo_profile_delta(start, end, TOMASULO_PERF_HEAD_WAIT_MUL));
    tomasulo_profile_consider_top(
        label, value, "ld", tomasulo_profile_delta(start, end, TOMASULO_PERF_HEAD_WAIT_MEM_LOAD));
    tomasulo_profile_consider_top(
        label, value, "st", tomasulo_profile_delta(start, end, TOMASULO_PERF_HEAD_WAIT_MEM_STORE));
    tomasulo_profile_consider_top(
        label, value, "amo", tomasulo_profile_delta(start, end, TOMASULO_PERF_HEAD_WAIT_MEM_AMO));
    tomasulo_profile_consider_top(
        label, value, "fp", tomasulo_profile_delta(start, end, TOMASULO_PERF_HEAD_WAIT_FP));
    tomasulo_profile_consider_top(
        label, value, "fmul", tomasulo_profile_delta(start, end, TOMASULO_PERF_HEAD_WAIT_FMUL));
    tomasulo_profile_consider_top(
        label, value, "fdiv", tomasulo_profile_delta(start, end, TOMASULO_PERF_HEAD_WAIT_FDIV));
    tomasulo_profile_consider_top(
        label, value, "csr", tomasulo_profile_delta(start, end, TOMASULO_PERF_COMMIT_BLOCKED_CSR));
    tomasulo_profile_consider_top(
        label,
        value,
        "fence",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_COMMIT_BLOCKED_FENCE));
    tomasulo_profile_consider_top(
        label, value, "wfi", tomasulo_profile_delta(start, end, TOMASULO_PERF_COMMIT_BLOCKED_WFI));
    tomasulo_profile_consider_top(
        label,
        value,
        "mret",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_COMMIT_BLOCKED_MRET));
    tomasulo_profile_consider_top(
        label,
        value,
        "trap",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_COMMIT_BLOCKED_TRAP));
}

static inline void tomasulo_profile_pick_top_backend_cause(const tomasulo_profile_snapshot_t *start,
                                                           const tomasulo_profile_snapshot_t *end,
                                                           const char **label,
                                                           uint64_t *value)
{
    *label = "none";
    *value = 0;

    tomasulo_profile_consider_top(
        label, value, "int_bp", tomasulo_profile_delta(start, end, TOMASULO_PERF_INT_BACKPRESSURE));
    tomasulo_profile_consider_top(
        label, value, "mul_bp", tomasulo_profile_delta(start, end, TOMASULO_PERF_MUL_BACKPRESSURE));
    tomasulo_profile_consider_top(
        label,
        value,
        "mem_bp",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_MEM_RESULT_BACKPRESSURE));
    tomasulo_profile_consider_top(
        label,
        value,
        "fp_bp",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_FP_ADD_BACKPRESSURE));
    tomasulo_profile_consider_top(
        label,
        value,
        "fmul_bp",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_FMUL_BACKPRESSURE));
    tomasulo_profile_consider_top(
        label,
        value,
        "fdiv_bp",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_FDIV_BACKPRESSURE));
    tomasulo_profile_consider_top(
        label,
        value,
        "ld_disambig",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_MEM_DISAMBIGUATION_WAIT));
    tomasulo_profile_consider_top(
        label,
        value,
        "sq_pending",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_SQ_COMMITTED_PENDING));
}

static inline void tomasulo_profile_print_brief_report(const char *label,
                                                       const tomasulo_profile_snapshot_t *start,
                                                       const tomasulo_profile_snapshot_t *end)
{
    uint64_t cycles = end->cycles - start->cycles;
    uint64_t instret = end->instret - start->instret;
    uint64_t dispatch_stall = tomasulo_profile_delta(start, end, TOMASULO_PERF_DISPATCH_STALL);
    uint64_t frontend_bubble = tomasulo_profile_delta(start, end, TOMASULO_PERF_FRONTEND_BUBBLE);
    uint64_t no_retire = tomasulo_profile_delta(start, end, TOMASULO_PERF_NO_RETIRE_NOT_EMPTY);
    const char *top_dispatch_label;
    const char *top_retire_label;
    const char *top_backend_label;
    uint64_t top_dispatch_value;
    uint64_t top_retire_value;
    uint64_t top_backend_value;
    uint32_t ipc_x100;
    uint32_t dispatch_stall_pct_x10;
    uint32_t frontend_bubble_pct_x10;
    uint32_t no_retire_pct_x10;
    uint32_t top_dispatch_pct_x10;
    uint32_t top_retire_pct_x10;
    uint32_t top_backend_pct_x10;

    if (start->counter_count == 0 || end->counter_count == 0) {
        return;
    }

    tomasulo_profile_pick_top_dispatch_cause(start, end, &top_dispatch_label, &top_dispatch_value);
    tomasulo_profile_pick_top_retire_cause(start, end, &top_retire_label, &top_retire_value);
    tomasulo_profile_pick_top_backend_cause(start, end, &top_backend_label, &top_backend_value);

    ipc_x100 = tomasulo_profile_ratio_scaled(instret, cycles, 100U);
    dispatch_stall_pct_x10 = tomasulo_profile_pct_x10(dispatch_stall, cycles);
    frontend_bubble_pct_x10 = tomasulo_profile_pct_x10(frontend_bubble, cycles);
    no_retire_pct_x10 = tomasulo_profile_pct_x10(no_retire, cycles);
    top_dispatch_pct_x10 = tomasulo_profile_pct_x10(top_dispatch_value, cycles);
    top_retire_pct_x10 = tomasulo_profile_pct_x10(top_retire_value, cycles);
    top_backend_pct_x10 = tomasulo_profile_pct_x10(top_backend_value, cycles);

    uart_printf(
        "  Profile %s: cyc=%llu inst=%llu ipc=%lu.%02lu stall=%lu.%01lu%% bubble=%lu.%01lu%% "
        "no_ret=%lu.%01lu%% topD=%s %lu.%01lu%% topR=%s %lu.%01lu%% topB=%s %lu.%01lu%%\n",
        label,
        (unsigned long long) cycles,
        (unsigned long long) instret,
        (unsigned long) (ipc_x100 / 100U),
        (unsigned long) (ipc_x100 % 100U),
        (unsigned long) (dispatch_stall_pct_x10 / 10U),
        (unsigned long) (dispatch_stall_pct_x10 % 10U),
        (unsigned long) (frontend_bubble_pct_x10 / 10U),
        (unsigned long) (frontend_bubble_pct_x10 % 10U),
        (unsigned long) (no_retire_pct_x10 / 10U),
        (unsigned long) (no_retire_pct_x10 % 10U),
        top_dispatch_label,
        (unsigned long) (top_dispatch_pct_x10 / 10U),
        (unsigned long) (top_dispatch_pct_x10 % 10U),
        top_retire_label,
        (unsigned long) (top_retire_pct_x10 / 10U),
        (unsigned long) (top_retire_pct_x10 % 10U),
        top_backend_label,
        (unsigned long) (top_backend_pct_x10 / 10U),
        (unsigned long) (top_backend_pct_x10 % 10U));
}

static inline void tomasulo_profile_print_report(const char *label,
                                                 const tomasulo_profile_snapshot_t *start,
                                                 const tomasulo_profile_snapshot_t *end)
{
    uint64_t cycles = end->cycles - start->cycles;
    uint64_t instret = end->instret - start->instret;
    uint64_t dispatch_fire;
    uint64_t dispatch_stall;
    uint64_t frontend_bubble;
    uint64_t flush_recovery;
    uint64_t post_flush_holdoff;
    uint64_t no_retire_not_empty;
    uint64_t head_wait_total;
    uint32_t ipc_x100;

    if (start->counter_count == 0 || end->counter_count == 0) {
        return;
    }

    dispatch_fire = tomasulo_profile_delta(start, end, TOMASULO_PERF_DISPATCH_FIRE);
    dispatch_stall = tomasulo_profile_delta(start, end, TOMASULO_PERF_DISPATCH_STALL);
    frontend_bubble = tomasulo_profile_delta(start, end, TOMASULO_PERF_FRONTEND_BUBBLE);
    flush_recovery = tomasulo_profile_delta(start, end, TOMASULO_PERF_FLUSH_RECOVERY);
    post_flush_holdoff = tomasulo_profile_delta(start, end, TOMASULO_PERF_POST_FLUSH_HOLDOFF);
    no_retire_not_empty = tomasulo_profile_delta(start, end, TOMASULO_PERF_NO_RETIRE_NOT_EMPTY);
    head_wait_total = tomasulo_profile_delta(start, end, TOMASULO_PERF_HEAD_WAIT_TOTAL);
    ipc_x100 = tomasulo_profile_ratio_scaled(instret, cycles, 100U);

    uart_printf("\nTomasulo Profile: %s\n", label);
    uart_printf("  Cycles: ");
    tomasulo_profile_print_u64_hex(cycles);
    uart_printf("  Instret: ");
    tomasulo_profile_print_u64_hex(instret);
    uart_printf(
        "  IPC: %lu.%02lu\n", (unsigned long) (ipc_x100 / 100U), (unsigned long) (ipc_x100 % 100U));

    uart_printf("  Front-end progress:\n");
    tomasulo_profile_print_metric("Dispatch fire", dispatch_fire, cycles);
    tomasulo_profile_print_metric("Dispatch backpressure", dispatch_stall, cycles);
    tomasulo_profile_print_metric("Front-end bubble", frontend_bubble, cycles);
    tomasulo_profile_print_metric(
        "  bubble: c-ext flush (frontend_state_flush)",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_FRONTEND_BUBBLE_C_EXT_FLUSH),
        cycles);
    tomasulo_profile_print_metric(
        "  bubble: align nop (sel_nop_align)",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_FRONTEND_BUBBLE_ALIGN),
        cycles);
    tomasulo_profile_print_metric(
        "  bubble: pred target holdoff",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_FRONTEND_BUBBLE_PRED_TARGET),
        cycles);
    tomasulo_profile_print_metric(
        "  bubble: pred fetch holdoff",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_FRONTEND_BUBBLE_PRED_FETCH),
        cycles);
    tomasulo_profile_print_metric(
        "  bubble: control-flow holdoff",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_FRONTEND_BUBBLE_CF_HOLDOFF),
        cycles);
    tomasulo_profile_print_metric(
        "  bubble: other (reset holdoff, PD/ID drop)",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_FRONTEND_BUBBLE_OTHER),
        cycles);
    tomasulo_profile_print_metric(
        "    other: pd_valid_q=0 (post-flush refill tail)",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_FRONTEND_BUBBLE_OTHER_PD_INVALID),
        cycles);
    tomasulo_profile_print_metric(
        "    other: stall_q tail (no replay flag)",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_FRONTEND_BUBBLE_OTHER_STALL_TAIL),
        cycles);
    tomasulo_profile_print_metric(
        "    other: ID illegal instruction",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_FRONTEND_BUBBLE_OTHER_ID_ILLEGAL),
        cycles);
    tomasulo_profile_print_metric(
        "    other: ID NOP (PD wrong-path squash or program-encoded)",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_FRONTEND_BUBBLE_OTHER_ID_NOP),
        cycles);
    tomasulo_profile_print_metric(
        "    other: rest (truly unexplained)",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_FRONTEND_BUBBLE_OTHER_REST),
        cycles);
    tomasulo_profile_print_metric("Flush recovery", flush_recovery, cycles);
    tomasulo_profile_print_metric("Post-flush holdoff", post_flush_holdoff, cycles);
    tomasulo_profile_print_metric(
        "CSR serialize", tomasulo_profile_delta(start, end, TOMASULO_PERF_CSR_SERIALIZE), cycles);
    tomasulo_profile_print_metric(
        "Control-flow serialize",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_CONTROL_FLOW_SERIALIZE),
        cycles);
    tomasulo_profile_print_metric(
        "Prediction disabled",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_PREDICTION_DISABLED),
        cycles);
    tomasulo_profile_print_metric(
        "Pred fence branch",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_PRED_FENCE_BRANCH),
        cycles);
    tomasulo_profile_print_metric(
        "Pred fence JAL", tomasulo_profile_delta(start, end, TOMASULO_PERF_PRED_FENCE_JAL), cycles);
    tomasulo_profile_print_metric(
        "Pred fence indirect",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_PRED_FENCE_INDIRECT),
        cycles);

    uart_printf("  Slot-1 (2-wide dispatch):\n");
    {
        uint64_t slot1_fire = tomasulo_profile_delta(start, end, TOMASULO_PERF_SLOT1_FIRE);
        uint64_t slot1_opp = tomasulo_profile_delta(start, end, TOMASULO_PERF_SLOT1_OPPORTUNITY);
        uint64_t slot1_blk = tomasulo_profile_delta(start, end, TOMASULO_PERF_SLOT1_BLOCKED);
        uint64_t slot1_stall_int_rs_only =
            tomasulo_profile_delta(start, end, TOMASULO_PERF_SLOT1_STALL_INT_RS_ONLY);
        uint64_t slot1_stall_rob2_only =
            tomasulo_profile_delta(start, end, TOMASULO_PERF_SLOT1_STALL_ROB2_ONLY);
        uint64_t slot1_stall_both =
            tomasulo_profile_delta(start, end, TOMASULO_PERF_SLOT1_STALL_BOTH);
        uint64_t slot1_pair_lost =
            tomasulo_profile_delta(start, end, TOMASULO_PERF_SLOT1_PAIR_LOST);
        tomasulo_profile_print_metric("Slot-1 fire", slot1_fire, cycles);
        tomasulo_profile_print_metric("Slot-1 opportunity (gate-indep)", slot1_opp, cycles);
        tomasulo_profile_print_metric("Slot-1 blocked (RS/ROB-2 full)", slot1_blk, cycles);
        tomasulo_profile_print_metric(
            "  Slot-1 blocked: INT_RS-full-for-2 only", slot1_stall_int_rs_only, cycles);
        tomasulo_profile_print_metric(
            "  Slot-1 blocked: ROB-2 full only", slot1_stall_rob2_only, cycles);
        tomasulo_profile_print_metric(
            "  Slot-1 blocked: INT_RS+ROB-2 both", slot1_stall_both, cycles);
        tomasulo_profile_print_metric(
            "Slot-1 pair lost (slot-0 went, slot-1 didn't)", slot1_pair_lost, cycles);
        if (slot1_opp > 0U) {
            uint32_t fire_rate_x10 = tomasulo_profile_ratio_scaled(slot1_fire, slot1_opp, 1000U);
            uart_printf("  Slot-1 fire rate (fire/opportunity): %lu.%01lu%%\n",
                        (unsigned long) (fire_rate_x10 / 10U),
                        (unsigned long) (fire_rate_x10 % 10U));
        }
    }

    uart_printf("  Dispatch stall breakdown:\n");
    tomasulo_profile_print_metric(
        "ROB full",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_DISPATCH_STALL_ROB_FULL),
        cycles);
    tomasulo_profile_print_metric(
        "INT RS full",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_DISPATCH_STALL_INT_RS_FULL),
        cycles);
    tomasulo_profile_print_metric(
        "MUL RS full",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_DISPATCH_STALL_MUL_RS_FULL),
        cycles);
    tomasulo_profile_print_metric(
        "MEM RS full",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_DISPATCH_STALL_MEM_RS_FULL),
        cycles);
    tomasulo_profile_print_metric(
        "FP RS full",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_DISPATCH_STALL_FP_RS_FULL),
        cycles);
    tomasulo_profile_print_metric(
        "FMUL RS full",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_DISPATCH_STALL_FMUL_RS_FULL),
        cycles);
    tomasulo_profile_print_metric(
        "FDIV RS full",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_DISPATCH_STALL_FDIV_RS_FULL),
        cycles);
    tomasulo_profile_print_metric(
        "LQ full",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_DISPATCH_STALL_LQ_FULL),
        cycles);
    tomasulo_profile_print_metric(
        "SQ full",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_DISPATCH_STALL_SQ_FULL),
        cycles);
    tomasulo_profile_print_metric(
        "Checkpoint full",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_DISPATCH_STALL_CHECKPOINT_FULL),
        cycles);

    uart_printf("  Retirement:\n");
    tomasulo_profile_print_metric("No retire, ROB non-empty", no_retire_not_empty, cycles);
    tomasulo_profile_print_metric(
        "ROB empty", tomasulo_profile_delta(start, end, TOMASULO_PERF_ROB_EMPTY), cycles);
    tomasulo_profile_print_metric("Head wait total", head_wait_total, cycles);
    tomasulo_profile_print_metric(
        "Head wait INT", tomasulo_profile_delta(start, end, TOMASULO_PERF_HEAD_WAIT_INT), cycles);
    tomasulo_profile_print_metric(
        "Head wait branch",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_HEAD_WAIT_BRANCH),
        cycles);
    tomasulo_profile_print_metric(
        "Head wait MUL", tomasulo_profile_delta(start, end, TOMASULO_PERF_HEAD_WAIT_MUL), cycles);
    tomasulo_profile_print_metric(
        "Head wait MEM load",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_HEAD_WAIT_MEM_LOAD),
        cycles);
    tomasulo_profile_print_metric(
        "Head wait MEM store",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_HEAD_WAIT_MEM_STORE),
        cycles);
    tomasulo_profile_print_metric(
        "Head wait MEM AMO/LR",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_HEAD_WAIT_MEM_AMO),
        cycles);
    tomasulo_profile_print_metric(
        "Head wait FP add", tomasulo_profile_delta(start, end, TOMASULO_PERF_HEAD_WAIT_FP), cycles);
    tomasulo_profile_print_metric(
        "Head wait FMUL", tomasulo_profile_delta(start, end, TOMASULO_PERF_HEAD_WAIT_FMUL), cycles);
    tomasulo_profile_print_metric(
        "Head wait FDIV", tomasulo_profile_delta(start, end, TOMASULO_PERF_HEAD_WAIT_FDIV), cycles);
    tomasulo_profile_print_metric(
        "Commit blocked CSR",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_COMMIT_BLOCKED_CSR),
        cycles);
    tomasulo_profile_print_metric(
        "Commit blocked FENCE",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_COMMIT_BLOCKED_FENCE),
        cycles);
    tomasulo_profile_print_metric(
        "Commit blocked WFI",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_COMMIT_BLOCKED_WFI),
        cycles);
    tomasulo_profile_print_metric(
        "Commit blocked MRET",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_COMMIT_BLOCKED_MRET),
        cycles);
    tomasulo_profile_print_metric(
        "Commit blocked trap",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_COMMIT_BLOCKED_TRAP),
        cycles);

    uart_printf("  Backend pressure:\n");
    tomasulo_profile_print_metric(
        "INT downstream block",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_INT_BACKPRESSURE),
        cycles);
    tomasulo_profile_print_metric(
        "MUL downstream block",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_MUL_BACKPRESSURE),
        cycles);
    tomasulo_profile_print_metric(
        "MEM result backpressure",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_MEM_RESULT_BACKPRESSURE),
        cycles);
    tomasulo_profile_print_metric(
        "FP add downstream block",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_FP_ADD_BACKPRESSURE),
        cycles);
    tomasulo_profile_print_metric(
        "FMUL downstream block",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_FMUL_BACKPRESSURE),
        cycles);
    tomasulo_profile_print_metric(
        "FDIV downstream block",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_FDIV_BACKPRESSURE),
        cycles);
    tomasulo_profile_print_metric(
        "Load disambiguation wait",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_MEM_DISAMBIGUATION_WAIT),
        cycles);
    tomasulo_profile_print_metric(
        "SQ committed pending",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_SQ_COMMITTED_PENDING),
        cycles);
    tomasulo_profile_print_metric(
        "SQ writes", tomasulo_profile_delta(start, end, TOMASULO_PERF_SQ_MEM_WRITE_FIRE), cycles);
    tomasulo_profile_print_metric(
        "LQ reads", tomasulo_profile_delta(start, end, TOMASULO_PERF_LQ_MEM_READ_FIRE), cycles);
    tomasulo_profile_print_metric(
        "L0 cache hit", tomasulo_profile_delta(start, end, TOMASULO_PERF_LQ_L0_HIT), cycles);
    tomasulo_profile_print_metric(
        "L0 cache fill", tomasulo_profile_delta(start, end, TOMASULO_PERF_LQ_L0_FILL), cycles);
    {
        uint64_t l0_hits = tomasulo_profile_delta(start, end, TOMASULO_PERF_LQ_L0_HIT);
        uint64_t lq_reads = tomasulo_profile_delta(start, end, TOMASULO_PERF_LQ_MEM_READ_FIRE);
        uint64_t load_completions = l0_hits + lq_reads;
        if (load_completions > 0U) {
            uint32_t hit_rate_x10 = tomasulo_profile_ratio_scaled(l0_hits, load_completions, 1000U);
            uart_printf("  L0 hit rate (hits / (hits + reads)): %lu.%01lu%%\n",
                        (unsigned long) (hit_rate_x10 / 10U),
                        (unsigned long) (hit_rate_x10 % 10U));
        }
    }
    uart_printf("  Diagnostic counters:\n");
    tomasulo_profile_print_metric(
        "Head+next both done",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_HEAD_AND_NEXT_DONE),
        cycles);
    tomasulo_profile_print_metric(
        "Head wait load, mem in flight",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_HEAD_WAIT_LOAD_OUTSTANDING),
        cycles);
    tomasulo_profile_print_metric(
        "Head wait load, no mem in flight",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_HEAD_WAIT_LOAD_NO_OUTSTANDING),
        cycles);
    tomasulo_profile_print_metric(
        "Head+1 done (ungated)",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_HEAD_PLUS_ONE_DONE),
        cycles);
    tomasulo_profile_print_metric(
        "Widen-commit 2-wide gate",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_COMMIT_2_OPPORTUNITY),
        cycles);
    tomasulo_profile_print_metric(
        "Widen-commit 2-wide fired",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_COMMIT_2_FIRE_ACTUAL),
        cycles);
    tomasulo_profile_print_metric(
        "Head load addr pending (rs1/MEM_RS)",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_HEAD_LOAD_ADDR_PENDING),
        cycles);
    tomasulo_profile_print_metric(
        "Head load SQ disambig blocked",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_HEAD_LOAD_SQ_DISAMBIG),
        cycles);
    tomasulo_profile_print_metric(
        "Head load bus/arb blocked",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_HEAD_LOAD_BUS_BLOCKED),
        cycles);
    tomasulo_profile_print_metric(
        "Head load waiting CDB slot",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_HEAD_LOAD_CDB_WAIT),
        cycles);
    tomasulo_profile_print_metric(
        "Head load CDB pipeline drain (LQ freed)",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_HEAD_LOAD_POST_LQ),
        cycles);
    tomasulo_profile_print_metric(
        "Head load bus-blocked: issued (post-launch)",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_HEAD_LOAD_BB_ISSUED),
        cycles);
    tomasulo_profile_print_metric(
        "Head load bus-blocked: bus_busy",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_HEAD_LOAD_BB_BUS_BUSY),
        cycles);
    tomasulo_profile_print_metric(
        "Head load bus-blocked: AMO blocked",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_HEAD_LOAD_BB_AMO),
        cycles);
    tomasulo_profile_print_metric(
        "Head load bus-blocked: SQ phase2 wait",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_HEAD_LOAD_BB_SQ_WAIT),
        cycles);
    tomasulo_profile_print_metric(
        "Head load bus-blocked: staging/misc",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_HEAD_LOAD_BB_STAGING),
        cycles);
    tomasulo_profile_print_metric(
        "  staging: capture cycle (sq_check_capture for head)",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_HEAD_LOAD_BB_STG_CAPTURE),
        cycles);
    tomasulo_profile_print_metric(
        "  staging: launch cycle (o_mem_read_en for head)",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_HEAD_LOAD_BB_STG_LAUNCH),
        cycles);
    tomasulo_profile_print_metric(
        "  staging: other (true idle / edge cases)",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_HEAD_LOAD_BB_STG_OTHER),
        cycles);
    tomasulo_profile_print_metric(
        "Head INT: operand wait (in RS, src not ready)",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_HEAD_INT_OPERAND_WAIT),
        cycles);
    tomasulo_profile_print_metric(
        "Head INT: RS ready, not issued",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_HEAD_INT_RS_READY_NOT_ISSUED),
        cycles);
    tomasulo_profile_print_metric("Head INT: parked in stage2",
                                  tomasulo_profile_delta(start, end, TOMASULO_PERF_HEAD_INT_STAGE2),
                                  cycles);
    tomasulo_profile_print_metric(
        "Head INT: post-RS CDB drain",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_HEAD_INT_POST_RS),
        cycles);
    tomasulo_profile_print_metric(
        "Widen blocked: head serial/mispred",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_COMMIT_2_BLOCKED_HEAD_SERIAL),
        cycles);
    tomasulo_profile_print_metric(
        "Widen blocked: head+1 serial",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_COMMIT_2_BLOCKED_NEXT_SERIAL),
        cycles);
    tomasulo_profile_print_metric(
        "Widen blocked: head+1 branch (mispred)",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_COMMIT_2_BLOCKED_NEXT_BRANCH_MISPRED),
        cycles);
    tomasulo_profile_print_metric(
        "Widen blocked: head+1 branch (correct)",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_COMMIT_2_BLOCKED_NEXT_BRANCH_CORRECT),
        cycles);

    uart_printf("  Average occupancies:\n");
    tomasulo_profile_print_average(
        "ROB", tomasulo_profile_delta(start, end, TOMASULO_PERF_ROB_OCCUPANCY_SUM), cycles);
    tomasulo_profile_print_average(
        "LQ", tomasulo_profile_delta(start, end, TOMASULO_PERF_LQ_OCCUPANCY_SUM), cycles);
    tomasulo_profile_print_average(
        "SQ", tomasulo_profile_delta(start, end, TOMASULO_PERF_SQ_OCCUPANCY_SUM), cycles);
    tomasulo_profile_print_average(
        "INT RS", tomasulo_profile_delta(start, end, TOMASULO_PERF_INT_RS_OCCUPANCY_SUM), cycles);
    tomasulo_profile_print_average(
        "MUL RS", tomasulo_profile_delta(start, end, TOMASULO_PERF_MUL_RS_OCCUPANCY_SUM), cycles);
    tomasulo_profile_print_average(
        "MEM RS", tomasulo_profile_delta(start, end, TOMASULO_PERF_MEM_RS_OCCUPANCY_SUM), cycles);
    tomasulo_profile_print_average(
        "FP RS", tomasulo_profile_delta(start, end, TOMASULO_PERF_FP_RS_OCCUPANCY_SUM), cycles);
    tomasulo_profile_print_average(
        "FMUL RS", tomasulo_profile_delta(start, end, TOMASULO_PERF_FMUL_RS_OCCUPANCY_SUM), cycles);
    tomasulo_profile_print_average(
        "FDIV RS", tomasulo_profile_delta(start, end, TOMASULO_PERF_FDIV_RS_OCCUPANCY_SUM), cycles);
}

#endif /* TOMASULO_PROFILE_H */
