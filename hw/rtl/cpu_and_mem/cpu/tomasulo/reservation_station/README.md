# Reservation Station

The Reservation Station is a generic, parameterized module in the FROST Tomasulo
out-of-order execution engine. It tracks source operand readiness and issues
instructions to functional units when all operands become available.

## Overview

The same module is instantiated 6 times with different depths:

| Instance | Depth | Purpose |
|----------|-------|---------|
| INT_RS   | 8     | Integer ALU, branches, CSR |
| MUL_RS   | 4     | Integer multiply/divide |
| MEM_RS   | 8     | Loads and stores (INT + FP) |
| FP_RS    | 6     | FP add/sub/cmp/cvt/classify/sgnj |
| FMUL_RS  | 4     | FP multiply/FMA (3 sources) |
| FDIV_RS  | 2     | FP divide/sqrt |

### Key Features

- **Parameterized depth** (2-8 entries, all FF-based storage)
- **Up to 3 source operands** for FMA instructions
- **CDB snoop** for broadcast wakeup with same-cycle dispatch bypass
- **Priority-encoder issue** selection (lowest index approximates FIFO)
- **Immediate bypass** (`use_imm` skips src2 readiness check)
- **Partial flush** (age-based via ROB tag comparison) and full flush

## Architecture

```
                     Reservation Station Block Diagram

     Dispatch             CDB Broadcast          Functional Unit
    ┌──────────┐        ┌──────────────┐        ┌──────────────┐
    │i_dispatch│        │   i_cdb      │        │  i_fu_ready  │
    │          │        │              │        │              │
    └────┬─────┘        └──────┬───────┘        └──────┬───────┘
         │                     │                       │
    write @ free          broadcast match         ready gate
         │                     │                       │
         ▼                     ▼                       ▼
┌─────────────────────────────────────────────────────────────┐
│                    DEPTH-Entry RS Array                     │
│                                                             │
│  Per-Entry FFs:                                             │
│    valid, rob_tag, op                                       │
│    src1: ready, tag, value    ← CDB snoop / dispatch bypass │
│    src2: ready, tag, value    ← CDB snoop / dispatch bypass │
│    src3: ready, tag, value    ← CDB snoop / dispatch bypass │
│    imm, use_imm, rm                                         │
│    branch_target, predicted_taken, predicted_target         │
│    is_fp_mem, mem_size, mem_signed                          │
│    csr_addr, csr_imm                                        │
│                                                             │
│  Priority Encoder ──── lowest-index free  ──→ dispatch      │
│  Priority Encoder ──── lowest-index ready ──→ issue         │
└─────────────────────────────────────────────────────────────┘
         │                                         │
         ▼                                         ▼
    ┌──────────┐                             ┌──────────┐
    │  o_full  │                             │ o_issue  │
    │  o_empty │                             │          │
    │  o_count │                             └──────────┘
    └──────────┘

    Flush Control
    ┌─────────────────────────────┐
    │ i_flush_all  → clear all    │
    │ i_flush_en   → age-based    │
    │ i_flush_tag  → boundary     │
    │ i_rob_head_tag → age ref    │
    └─────────────────────────────┘
```

## Storage Strategy

**All fields in FFs** (not LUTRAM). Rationale: RS entries are small (depth 2-8)
and require parallel content-addressable access for CDB tag comparison across all
entries simultaneously. LUTRAM only provides single-address reads, which doesn't
suit the RS broadcast-match access pattern.

1-bit flags use packed vectors (`logic [DEPTH-1:0]`) for bulk clear on flush.
Multi-bit fields use arrays of logic vectors.

## Interface

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `i_clk` | in | 1 | Clock |
| `i_rst_n` | in | 1 | Active-low reset |
| `i_dispatch` | in | `rs_dispatch_t` | Dispatch request |
| `o_full` | out | 1 | RS is full |
| `i_cdb` | in | `cdb_broadcast_t` | CDB broadcast for wakeup |
| `o_issue` | out | `rs_issue_t` | Issue to functional unit |
| `i_fu_ready` | in | 1 | FU can accept issue |
| `i_flush_en` | in | 1 | Partial flush enable |
| `i_flush_tag` | in | 5 | Flush boundary tag |
| `i_rob_head_tag` | in | 5 | ROB head for age calc |
| `i_flush_all` | in | 1 | Full flush |
| `o_empty` | out | 1 | RS is empty |
| `o_count` | out | `$clog2(DEPTH+1)` | Valid entry count |

## Behavior

### Dispatch
When `i_dispatch.valid && !full && !flush`, writes all fields to the first free
entry. Same-cycle CDB bypass: if a source tag matches the CDB broadcast tag,
captures the CDB value and marks the source ready immediately.

### CDB Snoop (Wakeup)
For each valid entry and each source (1, 2, 3): if the source is not ready and
its tag matches `i_cdb.tag`, sets the source ready and captures `i_cdb.value`.

### Issue Select
An entry is ready when: `valid && src1_ready && (src2_ready || use_imm) && src3_ready`.
Priority encoder selects lowest-index ready entry. Issue fires when
`any_ready && i_fu_ready`, invalidating the issued entry.

### Flush
- `i_flush_all`: Clears all valid bits in one cycle
- `i_flush_en`: Uses ROB-style age comparison to invalidate entries with
  `rob_tag` younger than `i_flush_tag` (relative to `i_rob_head_tag`)

## Verification

### Cocotb Tests
Unit tests in `verif/cocotb_tests/tomasulo/reservation_station/`:
- Basic dispatch, issue, full/empty checks
- CDB wakeup for src1/src2/src3, multi-source, cross-entry
- Same-cycle CDB bypass at dispatch
- Issue priority, FU ready gating, use_imm bypass
- Flush (full and partial)
- Constrained random stress tests

### Formal Properties
BMC and cover properties in the RTL (`ifdef FORMAL`):
- Combinational: full/empty/count consistency, issue validity
- Sequential: dispatch sets valid, issue clears valid, flush behavior,
  CDB wakeup correctness, partial flush preserves older entries
- Cover: dispatch+issue same cycle, CDB bypass, full RS, partial flush

## Files

| File | Description |
|------|-------------|
| `reservation_station.sv` | RTL module |
| `reservation_station.f` | Filelist |
| `README.md` | This file |

## Dependencies

| Module | Purpose |
|--------|---------|
| `riscv_pkg` | Type definitions (`rs_dispatch_t`, `rs_issue_t`, `cdb_broadcast_t`) |
