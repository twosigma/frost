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

#define TOMASULO_PROFILE_COUNTER_COUNT 106U

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
    /* 2-wide width funnel: IF->PD delivery width + slot-2 kill causes +
     * slot-2 BTB predicted-taken events. */
    TOMASULO_PERF_IF_DELIVER1 = 23,
    TOMASULO_PERF_IF_DELIVER2 = 24,
    TOMASULO_PERF_IF_S2KILL_S1_NATIVE_CTRL = 25,
    TOMASULO_PERF_IF_S2KILL_S1_NATIVE_SERIALIZE = 26,
    TOMASULO_PERF_IF_S2KILL_S1_CTRL = 27,
    TOMASULO_PERF_IF_S2KILL_S2_CLASS = 28,
    TOMASULO_PERF_IF_S2KILL_WINDOW_LIMIT = 29,
    TOMASULO_PERF_IF_S2KILL_TRANSIENT = 30,
    TOMASULO_PERF_IF_SLOT2_PRED_TAKEN = 31,
    /* 2-wide width funnel: dispatch fire-2 + slot-2 blocked causes. */
    TOMASULO_PERF_DISPATCH_FIRE_2 = 32,
    TOMASULO_PERF_DISPATCH_SLOT2_PRESENT = 33,
    TOMASULO_PERF_DISPATCH_SLOT2_FP_SERIALIZED = 34,
    TOMASULO_PERF_DISPATCH_SLOT2_BLOCK_S1_BRANCH = 35,
    TOMASULO_PERF_DISPATCH_SLOT2_BLOCK_ROB_FULL2 = 36,
    TOMASULO_PERF_DISPATCH_SLOT2_BLOCK_RS_FULL2 = 37,
    TOMASULO_PERF_DISPATCH_SLOT2_BLOCK_LSQ_FULL2 = 38,
    TOMASULO_PERF_DISPATCH_SLOT2_BLOCK_CKPT = 39,
    /* 2-wide width funnel: back-end single-resource limiters. */
    TOMASULO_PERF_MEM_RS_TWO_READY_ONE_ISSUED = 40,
    TOMASULO_PERF_CDB_OVERSUBSCRIBED = 41,
    /* Wrapper (tomasulo) counters follow: base shifts with the top block. */
    TOMASULO_PERF_HEAD_WAIT_TOTAL = 42,
    TOMASULO_PERF_HEAD_WAIT_INT = 43,
    TOMASULO_PERF_HEAD_WAIT_BRANCH = 44,
    TOMASULO_PERF_HEAD_WAIT_MUL = 45,
    TOMASULO_PERF_HEAD_WAIT_MEM_LOAD = 46,
    TOMASULO_PERF_HEAD_WAIT_MEM_STORE = 47,
    TOMASULO_PERF_HEAD_WAIT_MEM_AMO = 48,
    TOMASULO_PERF_HEAD_WAIT_FP = 49,
    TOMASULO_PERF_HEAD_WAIT_FMUL = 50,
    TOMASULO_PERF_HEAD_WAIT_FDIV = 51,
    TOMASULO_PERF_COMMIT_BLOCKED_CSR = 52,
    TOMASULO_PERF_COMMIT_BLOCKED_FENCE = 53,
    TOMASULO_PERF_COMMIT_BLOCKED_WFI = 54,
    TOMASULO_PERF_COMMIT_BLOCKED_MRET = 55,
    TOMASULO_PERF_COMMIT_BLOCKED_TRAP = 56,
    TOMASULO_PERF_INT_BACKPRESSURE = 57,
    TOMASULO_PERF_MUL_BACKPRESSURE = 58,
    TOMASULO_PERF_MEM_RESULT_BACKPRESSURE = 59,
    TOMASULO_PERF_FP_ADD_BACKPRESSURE = 60,
    TOMASULO_PERF_FMUL_BACKPRESSURE = 61,
    TOMASULO_PERF_FDIV_BACKPRESSURE = 62,
    TOMASULO_PERF_MEM_DISAMBIGUATION_WAIT = 63,
    TOMASULO_PERF_SQ_COMMITTED_PENDING = 64,
    TOMASULO_PERF_SQ_MEM_WRITE_FIRE = 65,
    TOMASULO_PERF_LQ_MEM_READ_FIRE = 66,
    TOMASULO_PERF_ROB_OCCUPANCY_SUM = 67,
    TOMASULO_PERF_LQ_OCCUPANCY_SUM = 68,
    TOMASULO_PERF_SQ_OCCUPANCY_SUM = 69,
    TOMASULO_PERF_INT_RS_OCCUPANCY_SUM = 70,
    TOMASULO_PERF_MUL_RS_OCCUPANCY_SUM = 71,
    TOMASULO_PERF_MEM_RS_OCCUPANCY_SUM = 72,
    TOMASULO_PERF_FP_RS_OCCUPANCY_SUM = 73,
    TOMASULO_PERF_FMUL_RS_OCCUPANCY_SUM = 74,
    TOMASULO_PERF_FDIV_RS_OCCUPANCY_SUM = 75,
    TOMASULO_PERF_LQ_L0_HIT = 76,
    TOMASULO_PERF_LQ_L0_FILL = 77,
    TOMASULO_PERF_HEAD_AND_NEXT_DONE = 78,
    TOMASULO_PERF_HEAD_WAIT_LOAD_OUTSTANDING = 79,
    TOMASULO_PERF_HEAD_WAIT_LOAD_NO_OUTSTANDING = 80,
    TOMASULO_PERF_HEAD_PLUS_ONE_DONE = 81,
    TOMASULO_PERF_COMMIT_2_OPPORTUNITY = 82,
    TOMASULO_PERF_COMMIT_2_FIRE_ACTUAL = 83,
    TOMASULO_PERF_HEAD_LOAD_ADDR_PENDING = 84,
    TOMASULO_PERF_HEAD_LOAD_SQ_DISAMBIG = 85,
    TOMASULO_PERF_HEAD_LOAD_BUS_BLOCKED = 86,
    TOMASULO_PERF_HEAD_LOAD_CDB_WAIT = 87,
    TOMASULO_PERF_HEAD_LOAD_POST_LQ = 88,
    TOMASULO_PERF_HEAD_LOAD_BB_ISSUED = 89,
    TOMASULO_PERF_HEAD_LOAD_BB_BUS_BUSY = 90,
    TOMASULO_PERF_HEAD_LOAD_BB_AMO = 91,
    TOMASULO_PERF_HEAD_LOAD_BB_SQ_WAIT = 92,
    TOMASULO_PERF_HEAD_LOAD_BB_STAGING = 93,
    TOMASULO_PERF_HEAD_INT_OPERAND_WAIT = 94,
    TOMASULO_PERF_HEAD_INT_RS_READY_NOT_ISSUED = 95,
    TOMASULO_PERF_HEAD_INT_STAGE2 = 96,
    TOMASULO_PERF_HEAD_INT_POST_RS = 97,
    TOMASULO_PERF_COMMIT_2_BLOCKED_HEAD_SERIAL = 98,
    TOMASULO_PERF_COMMIT_2_BLOCKED_NEXT_SERIAL = 99,
    TOMASULO_PERF_COMMIT_2_BLOCKED_NEXT_BRANCH_MISPRED = 100,
    TOMASULO_PERF_COMMIT_2_BLOCKED_NEXT_BRANCH_CORRECT = 101,
    /* Staging catch-all sub-decomposition (partitions HEAD_LOAD_BB_STAGING). */
    TOMASULO_PERF_HEAD_LOAD_BBS_OTHER_IN_STAGING = 102,
    TOMASULO_PERF_HEAD_LOAD_BBS_LAUNCH_GATED = 103,
    TOMASULO_PERF_HEAD_LOAD_BBS_SLOW_OUTSTANDING = 104,
    TOMASULO_PERF_HEAD_LOAD_BBS_CAPTURE_GAP = 105,
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

typedef struct tomasulo_profile_u96 {
    uint32_t lo;
    uint32_t mid;
    uint32_t hi;
} tomasulo_profile_u96_t;

/* Multiply a 64-bit value by a 32-bit value without requiring a 64-bit
 * multiply. Each partial product is only 32x32->64. */
static inline tomasulo_profile_u96_t tomasulo_profile_mul_u64_u32(uint64_t value,
                                                                  uint32_t multiplier)
{
    uint64_t lo_product = (uint64_t) (uint32_t) value * multiplier;
    uint64_t hi_product = (uint64_t) (uint32_t) (value >> 32) * multiplier;
    uint64_t middle = (lo_product >> 32) + (uint32_t) hi_product;
    tomasulo_profile_u96_t result;

    result.lo = (uint32_t) lo_product;
    result.mid = (uint32_t) middle;
    result.hi = (uint32_t) (hi_product >> 32) + (uint32_t) (middle >> 32);
    return result;
}

static inline int tomasulo_profile_cmp_u96(tomasulo_profile_u96_t lhs, tomasulo_profile_u96_t rhs)
{
    if (lhs.hi != rhs.hi) {
        return lhs.hi < rhs.hi ? -1 : 1;
    }
    if (lhs.mid != rhs.mid) {
        return lhs.mid < rhs.mid ? -1 : 1;
    }
    if (lhs.lo != rhs.lo) {
        return lhs.lo < rhs.lo ? -1 : 1;
    }
    return 0;
}

static inline tomasulo_profile_u96_t tomasulo_profile_add_u64(tomasulo_profile_u96_t value,
                                                              uint64_t addend)
{
    uint32_t old_lo = value.lo;
    uint32_t old_mid;
    uint32_t carry;

    value.lo += (uint32_t) addend;
    carry = value.lo < old_lo;

    old_mid = value.mid;
    value.mid += (uint32_t) (addend >> 32);
    value.hi += value.mid < old_mid;

    old_mid = value.mid;
    value.mid += carry;
    value.hi += value.mid < old_mid;
    return value;
}

static inline uint32_t tomasulo_profile_ratio_scaled(uint64_t value, uint64_t total, uint32_t scale)
{
    tomasulo_profile_u96_t numerator;
    tomasulo_profile_u96_t product;
    uint32_t low;
    uint32_t high;

    if (total == 0 || scale == 0) {
        return 0;
    }

    /* Keep the common case in native 32-bit arithmetic. */
    if (value <= UINT32_MAX && total <= UINT32_MAX) {
        uint32_t value32 = (uint32_t) value;
        uint32_t total32 = (uint32_t) total;
        uint32_t half = total32 / 2U;

        if (value32 <= (UINT32_MAX - half) / scale) {
            return (value32 * scale + half) / total32;
        }
    }

    /* The exact fallback represents products as three 32-bit limbs. Avoiding
     * an approximate right shift preserves low-order bits around rounding
     * boundaries, while binary search avoids a 64-bit division helper on
     * RV32. */
    numerator = tomasulo_profile_mul_u64_u32(value, scale);
    product = tomasulo_profile_mul_u64_u32(total, UINT32_MAX);
    if (tomasulo_profile_cmp_u96(numerator, product) >= 0) {
        return UINT32_MAX;
    }

    low = 0;
    high = UINT32_MAX - 1U;
    while (low < high) {
        uint32_t quotient = low + ((high - low) >> 1) + 1U;

        product = tomasulo_profile_mul_u64_u32(total, quotient);
        if (tomasulo_profile_cmp_u96(product, numerator) <= 0) {
            low = quotient;
        } else {
            high = quotient - 1U;
        }
    }

    product = tomasulo_profile_mul_u64_u32(total, low);
    product = tomasulo_profile_add_u64(product, (total >> 1) + (total & 1U));
    if (tomasulo_profile_cmp_u96(numerator, product) >= 0) {
        low++;
    }
    return low;
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

    uart_printf("  2-wide width funnel:\n");
    {
        uint64_t if_d1 = tomasulo_profile_delta(start, end, TOMASULO_PERF_IF_DELIVER1);
        uint64_t if_d2 = tomasulo_profile_delta(start, end, TOMASULO_PERF_IF_DELIVER2);
        uint64_t if_kills = if_d1 - if_d2;
        uint64_t fire_2 = tomasulo_profile_delta(start, end, TOMASULO_PERF_DISPATCH_FIRE_2);
        uint64_t commit_2 = tomasulo_profile_delta(start, end, TOMASULO_PERF_COMMIT_2_FIRE_ACTUAL);
        uint64_t commit_cycles = (instret > commit_2) ? (instret - commit_2) : instret;

        /* Each funnel stage prints value plus percent of its own denominator:
         * IF-2wide%   = 2-wide handoffs / all IF->PD handoffs
         * kill causes = share of the 1-wide handoffs (partition)
         * s2 pred tkn = slot-2 taken-prediction events / 2-wide handoffs
         * disp-2wide% = slot-2 fires / slot-1 fires
         * mem-rs/cdb  = limiter cycles / elapsed cycles
         * cmt-2wide%  = dual-retire cycles / total commit cycles */
        tomasulo_profile_print_metric("IF 2-wide (of IF deliveries)", if_d2, if_d1);
        tomasulo_profile_print_metric(
            "IF kill: slot-1 native ctrl",
            tomasulo_profile_delta(start, end, TOMASULO_PERF_IF_S2KILL_S1_NATIVE_CTRL),
            if_kills);
        tomasulo_profile_print_metric(
            "IF kill: slot-1 native serialize",
            tomasulo_profile_delta(start, end, TOMASULO_PERF_IF_S2KILL_S1_NATIVE_SERIALIZE),
            if_kills);
        tomasulo_profile_print_metric(
            "IF kill: slot-1 RVC ctrl",
            tomasulo_profile_delta(start, end, TOMASULO_PERF_IF_S2KILL_S1_CTRL),
            if_kills);
        tomasulo_profile_print_metric(
            "IF kill: slot-2 class (CSR/fence/AMO/FP)",
            tomasulo_profile_delta(start, end, TOMASULO_PERF_IF_S2KILL_S2_CLASS),
            if_kills);
        tomasulo_profile_print_metric(
            "IF kill: 64b fetch-window limit",
            tomasulo_profile_delta(start, end, TOMASULO_PERF_IF_S2KILL_WINDOW_LIMIT),
            if_kills);
        tomasulo_profile_print_metric(
            "IF kill: aligner/BRAM transient",
            tomasulo_profile_delta(start, end, TOMASULO_PERF_IF_S2KILL_TRANSIENT),
            if_kills);
        tomasulo_profile_print_metric(
            "Slot-2 BTB pred taken (of 2-wide)",
            tomasulo_profile_delta(start, end, TOMASULO_PERF_IF_SLOT2_PRED_TAKEN),
            if_d2);
        tomasulo_profile_print_metric("Dispatch 2-wide (of slot-1 fires)", fire_2, dispatch_fire);
        tomasulo_profile_print_metric(
            "Slot-2 present at dispatch",
            tomasulo_profile_delta(start, end, TOMASULO_PERF_DISPATCH_SLOT2_PRESENT),
            cycles);
        tomasulo_profile_print_metric(
            "Slot-2 FP-compute serialized",
            tomasulo_profile_delta(start, end, TOMASULO_PERF_DISPATCH_SLOT2_FP_SERIALIZED),
            cycles);
        tomasulo_profile_print_metric(
            "Slot-2 blk: slot-1 branch",
            tomasulo_profile_delta(start, end, TOMASULO_PERF_DISPATCH_SLOT2_BLOCK_S1_BRANCH),
            cycles);
        tomasulo_profile_print_metric(
            "Slot-2 blk: ROB room-for-2",
            tomasulo_profile_delta(start, end, TOMASULO_PERF_DISPATCH_SLOT2_BLOCK_ROB_FULL2),
            cycles);
        tomasulo_profile_print_metric(
            "Slot-2 blk: RS room",
            tomasulo_profile_delta(start, end, TOMASULO_PERF_DISPATCH_SLOT2_BLOCK_RS_FULL2),
            cycles);
        tomasulo_profile_print_metric(
            "Slot-2 blk: LQ/SQ room",
            tomasulo_profile_delta(start, end, TOMASULO_PERF_DISPATCH_SLOT2_BLOCK_LSQ_FULL2),
            cycles);
        tomasulo_profile_print_metric(
            "Slot-2 blk: checkpoint",
            tomasulo_profile_delta(start, end, TOMASULO_PERF_DISPATCH_SLOT2_BLOCK_CKPT),
            cycles);
        tomasulo_profile_print_metric(
            "MEM_RS 2+ ready, 1 issue port",
            tomasulo_profile_delta(start, end, TOMASULO_PERF_MEM_RS_TWO_READY_ONE_ISSUED),
            cycles);
        tomasulo_profile_print_metric(
            "CDB 3+ requests for 2 lanes",
            tomasulo_profile_delta(start, end, TOMASULO_PERF_CDB_OVERSUBSCRIBED),
            cycles);
        tomasulo_profile_print_metric("Commit 2-wide (of commit cycles)", commit_2, commit_cycles);
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
        "  staging: other load in sq_check",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_HEAD_LOAD_BBS_OTHER_IN_STAGING),
        cycles);
    tomasulo_profile_print_metric(
        "  staging: head staged, launch gated",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_HEAD_LOAD_BBS_LAUNCH_GATED),
        cycles);
    tomasulo_profile_print_metric(
        "  staging: cached load outstanding",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_HEAD_LOAD_BBS_SLOW_OUTSTANDING),
        cycles);
    tomasulo_profile_print_metric(
        "  staging: capture gap",
        tomasulo_profile_delta(start, end, TOMASULO_PERF_HEAD_LOAD_BBS_CAPTURE_GAP),
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
