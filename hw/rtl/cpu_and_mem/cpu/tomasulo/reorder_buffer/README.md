# Reorder Buffer

The Reorder Buffer is the central data structure in the FROST Tomasulo out-of-order
execution engine. It enables in-order instruction commit while allowing out-of-order
execution, providing precise exceptions and supporting speculation recovery.

## Overview

The Reorder Buffer is a 32-entry circular buffer that tracks all in-flight instructions
from dispatch to commit. Each entry holds instruction metadata, execution results, and
status flags. The buffer uses unified INT/FP entries with a `dest_rf` flag to
distinguish integer from floating-point destinations, so a single pool serves all
instruction types.

### Key Features

- **32-entry circular buffer** with head/tail pointers (wrap-bit full/empty detection)
- **Unified INT/FP entries** — single buffer for all instruction types
- **In-order allocation** at dispatch, **in-order commit** at retirement
- **Out-of-order completion** via CDB writes and branch updates
- **Branch misprediction recovery** with checkpoint-based RAT restore
- **Precise exceptions** with trap signaling at head
- **Serializing instruction support**: WFI, CSR, FENCE, FENCE.I, MRET
- **Atomic instruction ordering**: AMO/LR/SC commit only with store queue empty
- **FP exception flag propagation** for `fcsr.fflags` accumulation
- **Compressed instruction awareness** for correct redirect PC (PC+2 vs PC+4)

## Architecture

```
                         Reorder Buffer Block Diagram

        Dispatch          CDB (FUs)        Branch Unit      Checkpoint
       ┌──────────┐     ┌──────────┐      ┌───────────┐    ┌──────────┐
       │alloc_req │     │cdb_write │      │branch_upd │    │ckpt_valid│
       │alloc_resp│     │          │      │           │    │ckpt_id   │
       └────┬─────┘     └────┬─────┘      └─────┬─────┘    └────┬─────┘
            │                │                   │              │
       write @ tail     write @ tag         write @ tag     write @ tail
            │                │                   │              │
            ▼                ▼                   ▼              ▼
   ┌─────────────────────────────────────────────────────────────────────┐
   │                     32-Entry Circular Buffer                        │
   │                                                                     │
   │  FF Packed Vectors (25 × 1-bit flags per entry)                     │
   │  ┊  valid, done, exception, is_branch, mispredicted, ...            │
   │  ┊  Per-entry clear on partial flush; bulk clear on full flush      │
   │                                                                     │
   │  sdp_dist_ram — 1 write port (alloc only)                           │
   │  ┊  pc [32], dest_reg [5], predicted_target [32], ckpt_id [2]       │
   │                                                                     │
   │  mwp_dist_ram — 2 write ports via LVT                               │
   │  ┊  value [64] (×2 instances: head read + RAT bypass read)          │
   │  ┊  exc_cause [5], fp_flags [5], branch_target [32]                 │
   │  ┊  Port 0 = alloc (low pri)  Port 1 = CDB/branch (high pri)        │
   │                                                                     │
   │      head_ptr ─────┐                  ┌────── tail_ptr              │
   │   (6-bit, wrap MSB)│                  │(6-bit, wrap MSB)            │
   └────────────────────┼──────────────────┼─────────────────────────────┘
             ┌──────────┘                  └───────────┐
             ▼                                         ▼
   ┌──────────────────────┐                 ┌────────────────────┐
   │    Commit Logic      │                 │   Alloc Response   │
   │                      │                 │   tag = tail_idx   │
   │ head_ready =         │                 │   ready = !full    │
   │   valid && done      │                 │          && !flush │
   │                      │                 └────────────────────┘
   │ commit_en =          │
   │   head_ready         │                 ┌────────────────────┐
   │   && !commit_stall◀──┼─────────────────│  Serializing FSM   │
   │   && !flush          │                 │  WAIT_SQ, CSR_EXEC │
   │                      │                 │  MRET_EXEC, WFI_   │
   │ Redirect PC:         │                 │  WAIT, TRAP_WAIT   │
   │  MRET → mepc         │                 └────────────────────┘
   │  Taken → branch_tgt  │
   │  !Taken → PC+2/4     │                 ┌────────────────────┐
   └──────────┬───────────┘                 │  RAT Bypass Read   │
              │                             │  i_read_tag →      │
              ▼                             │    o_read_done,    │
   ┌──────────────────────────────┐         │    o_read_value    │
   │  o_commit (regfiles, SQ)     │         └────────────────────┘
   │  o_csr_start   → CSR unit    │
   │  o_mret_start  → trap unit   │
   │  o_trap_pending → trap unit  │
   │  o_fence_i_flush → pipeline  │
   │  o_full/empty/count          │
   └──────────────────────────────┘
```

## Pointer Logic

The head and tail pointers are each `ReorderBufferTagWidth + 1` bits wide (6 bits for a
32-entry buffer). The lower 5 bits index into the circular buffer; the MSB is a **wrap
bit** that toggles each time the pointer wraps around.

- **Empty**: `head_ptr == tail_ptr` (all bits match — same position, same wrap count)
- **Full**: `head_ptr[MSB] != tail_ptr[MSB] && head_idx == tail_idx` (same position,
  different wrap count — tail has lapped head by exactly one full cycle)
- **Count**: `tail_ptr - head_ptr` (unsigned subtraction, naturally handles wrap)

This eliminates the ambiguity between full and empty that arises when using only
`TAG_WIDTH` bits for both pointers.

## Entry Structure

Each entry contains 202 bits of state (with XLEN=32, FLEN=64). Multi-bit fields are
stored in **distributed RAM (LUTRAM)** to reduce flip-flop usage; 1-bit flags that
require per-entry flush/reset remain in **flip-flops**.

### Storage Strategy

- **`sdp_dist_ram`** (1 write port): Fields written only at allocation.
  Read at `head_idx` for commit.
- **`mwp_dist_ram`** (2 write ports, LVT-based): Fields written at allocation *and*
  updated later by the CDB or branch unit. Port 0 = allocation (lower priority),
  Port 1 = CDB/branch (higher priority). The `value` field needs two independent
  read addresses (`head_idx` for commit, `i_read_tag` for RAT bypass), so it uses
  two `mwp_dist_ram` instances with identical writes and different read ports.
- **Flip-flops**: All 1-bit packed vectors — need per-entry clear on partial flush
  and bulk clear on full flush/reset.

This saves approximately 5,500 FFs compared to a pure register-based design.

### Fields

#### Core State

| Field       | Width       | Storage | Description                              |
|-------------|-------------|---------|------------------------------------------|
| valid       | 1 bit       | FF      | Entry is allocated and not yet committed |
| done        | 1 bit       | FF      | Execution complete (ready to commit)     |
| exception   | 1 bit       | FF      | Exception occurred during execution      |
| exc_cause   | 5 bits      | LUTRAM  | Exception cause code (`exc_cause_t`)     |
| pc          | XLEN (32)   | LUTRAM  | Instruction PC (for traps and redirect)  |

#### Destination

| Field       | Width       | Storage | Description                              |
|-------------|-------------|---------|------------------------------------------|
| dest_rf     | 1 bit       | FF      | 0 = INT (x-reg), 1 = FP (f-reg)         |
| dest_reg    | 5 bits      | LUTRAM  | Architectural destination register (rd)  |
| dest_valid  | 1 bit       | FF      | Instruction writes a destination         |
| value       | FLEN (64)   | LUTRAM  | Result value (FLEN-wide for FP double)   |

#### Branch / Jump

| Field            | Width       | Storage | Description                                  |
|------------------|-------------|---------|----------------------------------------------|
| is_branch        | 1 bit       | FF      | Is branch or jump instruction                |
| branch_taken     | 1 bit       | FF      | Actual branch outcome (resolved)             |
| branch_target    | XLEN (32)   | LUTRAM  | Actual taken target (from branch unit)       |
| predicted_taken  | 1 bit       | FF      | BTB predicted taken                          |
| predicted_target | XLEN (32)   | LUTRAM  | BTB/RAS predicted target                     |
| mispredicted     | 1 bit       | FF      | Authoritative misprediction flag from branch unit |
| is_call          | 1 bit       | FF      | Is call instruction (for BPU update)         |
| is_return        | 1 bit       | FF      | Is return instruction (for BPU update)       |
| is_jal           | 1 bit       | FF      | Is JAL (done at allocation)                  |
| is_jalr          | 1 bit       | FF      | Is JALR (done at branch resolution)          |

#### Checkpoint

| Field           | Width  | Storage | Description                           |
|-----------------|--------|---------|---------------------------------------|
| has_checkpoint  | 1 bit  | FF      | Branch has allocated a RAT checkpoint |
| checkpoint_id   | 2 bits | LUTRAM  | Checkpoint index for recovery         |

#### Floating-Point

| Field    | Width  | Storage | Description                               |
|----------|--------|---------|-------------------------------------------|
| fp_flags | 5 bits | LUTRAM  | FP exception flags (NV, DZ, OF, UF, NX)  |

#### Memory / Atomic

| Field       | Width | Storage | Description                   |
|-------------|-------|---------|-------------------------------|
| is_store    | 1 bit | FF      | Is store instruction          |
| is_fp_store | 1 bit | FF      | Is FP store (FSW/FSD)         |
| is_amo      | 1 bit | FF      | Is atomic memory operation    |
| is_lr       | 1 bit | FF      | Is load-reserved              |
| is_sc       | 1 bit | FF      | Is store-conditional          |

#### Serializing / Control

| Field         | Width | Storage | Description                      |
|---------------|-------|---------|----------------------------------|
| is_csr        | 1 bit | FF      | Is CSR instruction               |
| is_fence      | 1 bit | FF      | Is FENCE                         |
| is_fence_i    | 1 bit | FF      | Is FENCE.I                       |
| is_wfi        | 1 bit | FF      | Is WFI                           |
| is_mret       | 1 bit | FF      | Is MRET                          |
| is_compressed | 1 bit | FF      | Is compressed (16-bit) encoding  |

## Interfaces

### Allocation Interface (from Dispatch)

```systemverilog
input  reorder_buffer_alloc_req_t  i_alloc_req   // Allocation request
output reorder_buffer_alloc_resp_t o_alloc_resp   // Returns tag, ready/full status
```

Dispatch requests a Reorder Buffer entry for each decoded instruction. The buffer
returns the allocated tag (`tail_idx`) which becomes the instruction's identifier
throughout the pipeline.

**Allocation condition**: `alloc_valid && !full && !flush_all && !flush_en`.

**Invariant**: Dispatch must not assert `alloc_valid` during flush cycles. The
`alloc_ready` signal independently deasserts during flush, but dispatch is also
expected to be stalled by the flush controller. A simulation assertion verifies this.

### CDB Write Interface (from Functional Units)

```systemverilog
input reorder_buffer_cdb_write_t i_cdb_write  // Tag, value, exception, FP flags
```

When a functional unit completes, it broadcasts the result on the CDB.
The Reorder Buffer captures results for the matching tag, setting `done` and
`exception`. The `value`, `exc_cause`, and `fp_flags` fields are written via
multi-write-port distributed RAM.

### Branch Update Interface (from Branch Unit)

```systemverilog
input reorder_buffer_branch_update_t i_branch_update  // Tag, taken, target, mispredicted
```

Branch resolution is separate from the CDB. The branch unit reports the actual
outcome, target, and an **authoritative misprediction flag**. The ROB stores
`mispredicted` directly — it does not recompute misprediction itself, deferring to
the branch unit's knowledge of RAS state, indirect predictor, etc.

For JALR and conditional branches, the branch update marks the entry `done`.
JAL entries are already `done` from allocation (see [Allocation Behavior](#allocation-behavior)).

### Checkpoint Interface (from RAT Checkpoint Unit)

```systemverilog
input logic                       i_checkpoint_valid
input logic [CheckpointIdWidth-1:0] i_checkpoint_id
```

When dispatch allocates a branch that needs a RAT checkpoint, the checkpoint unit
provides the checkpoint ID on the same cycle. The ROB records `has_checkpoint` and
`checkpoint_id` for the entry, which are later included in the commit output for
misprediction recovery.

### Commit Output (to Regfiles, SQ, Trap Unit)

```systemverilog
output reorder_buffer_commit_t o_commit  // Committed instruction details
```

When the head entry is valid and done (and not stalled by the serializing FSM), the
ROB commits it. The commit output includes the destination register, value,
exception/FP flag information, misprediction status, checkpoint ID, and redirect PC.

### RAT Bypass Read Interface

```systemverilog
input  logic [ReorderBufferTagWidth-1:0] i_read_tag
output logic                             o_read_done
output logic [FLEN-1:0]                  o_read_value
```

Allows the RAT to check whether an in-flight ROB entry has completed and read its
value for operand bypass. This is an asynchronous read — `o_read_done` and
`o_read_value` are combinational functions of `i_read_tag`.

### Flush Interface

```systemverilog
input logic                                  i_flush_en    // Partial flush (misprediction)
input logic [ReorderBufferTagWidth-1:0]      i_flush_tag   // Flush entries younger than this
input logic                                  i_flush_all   // Full flush (exception)
```

See [Flush Behavior](#flush-behavior) for details.

### External Coordination

| Signal              | Direction | Purpose                                    |
|---------------------|-----------|------------------------------------------- |
| `i_sq_empty`        | Input     | Store queue is empty (FENCE, AMO ordering) |
| `o_csr_start`       | Output    | Signal CSR unit to apply side effects      |
| `i_csr_done`        | Input     | CSR execution complete                     |
| `o_trap_pending`    | Output    | Exception at head needs handling           |
| `o_trap_pc`         | Output    | PC of excepting instruction                |
| `o_trap_cause`      | Output    | Exception cause code                       |
| `i_trap_taken`      | Input     | Trap unit has taken the exception          |
| `o_mret_start`      | Output    | Signal trap unit for MRET handling         |
| `i_mret_done`       | Input     | MRET handling complete                     |
| `i_mepc`            | Input     | Return PC from trap unit                   |
| `i_interrupt_pending` | Input   | Interrupt pending (wakes WFI)              |
| `o_fence_i_flush`   | Output    | FENCE.I committed — flush pipeline/icache  |

### Status Outputs

| Signal       | Width              | Description                              |
|--------------|--------------------|------------------------------------------|
| `o_full`     | 1 bit              | Buffer is full (backpressure to dispatch)|
| `o_empty`    | 1 bit              | Buffer is empty                          |
| `o_count`    | `TagWidth + 1` bits| Number of valid entries                  |
| `o_head_tag` | `TagWidth` bits    | Head entry index                         |
| `o_head_valid`| 1 bit             | Head entry is allocated                  |
| `o_head_done`| 1 bit              | Head entry is valid and done             |

## Allocation Behavior

When an instruction is allocated, most fields are initialized from the dispatch
request. Several instruction types receive special treatment:

- **JAL**: Marked `done` immediately at allocation. The link address (PC+2 or PC+4,
  zero-extended to FLEN) is written to `value`, and `branch_taken` is set. The target
  is known at decode, so no execution phase is needed.
- **JALR**: Allocated as not-done. The link address is written to `value` at
  allocation, but the entry waits for the branch unit to resolve the target and
  mark it `done`.
- **WFI, FENCE, FENCE.I, MRET**: Marked `done` at allocation — these have no
  execution phase. However, commit is gated by the serializing FSM (they stall at
  the head until their completion condition is met).
- **All others** (ALU, MUL, DIV, MEM, FP, conditional branches): Allocated as
  not-done. They are marked `done` when the CDB write or branch update arrives.

## Commit Logic

The head entry commits when all three conditions hold:

```
commit_en = head_ready && !commit_stall && !flush_en && !flush_all
```

where `head_ready = head_valid && head_done`, and `commit_stall` is asserted by the
serializing FSM for instructions requiring external coordination.

### Misprediction at Commit

The commit output includes `misprediction = is_branch && mispredicted`. The
`mispredicted` flag is the authoritative value written by the branch unit — the ROB
does not recompute it.

### Redirect PC

When a commit carries a misprediction or MRET, the downstream flush controller needs
a redirect address. The ROB provides this via a three-way mux:

| Condition              | Redirect PC                                     |
|------------------------|-------------------------------------------------|
| MRET                   | `i_mepc` (stable — MRET handshake completed)    |
| Branch taken           | `branch_target` (actual taken target)            |
| Branch not-taken       | `pc + (is_compressed ? 2 : 4)` (fall-through)   |

## Serializing Instructions

Certain instructions require special handling at commit. When one of these reaches the
head and is `done`, the serializing FSM stalls `commit_en` until the completion
condition is satisfied.

### WFI (Wait For Interrupt)

Stalls at the ROB head until `i_interrupt_pending` asserts.
Commits as a NOP once the interrupt arrives.

### CSR Instructions

CSR reads execute speculatively in the pipeline and broadcast results via the CDB.
The entry must be marked `done` (via CDB write) before it reaches the head. At that
point the ROB asserts `o_csr_start` to trigger CSR side effects, then waits for
`i_csr_done`. This ensures side effects are applied only for architecturally committed
instructions.

### FENCE

Waits for the store queue to drain (`i_sq_empty`), then commits.
Ensures all prior stores are visible before subsequent memory operations.

### FENCE.I

Same as FENCE (waits for `i_sq_empty`), plus `o_fence_i_flush` pulses high
**one cycle after** FENCE.I commits (registered output), signaling the pipeline and
icache to flush.

### MRET

Asserts `o_mret_start` to the trap unit, waits for `i_mret_done`. The commit redirect
PC is set to `i_mepc` (guaranteed stable by the handshake completing before
`commit_en` asserts).

### AMO / LR / SC

Must commit at the ROB head with the store queue empty. If the SQ is not yet empty,
the serializing FSM enters `SERIAL_WAIT_SQ`. Actual atomic execution happens in the
memory unit.

## Serializing Instruction State Machine

```
                     +─────────────+
                     │ SERIAL_IDLE │◀──────────────────────────+
                     +──────┬──────+                           │
                            │                                  │
      +─────────────────────┼─────────────────────+            │
      │         │           │           │         │            │
      ▼         ▼           ▼           ▼         ▼            │
 +─────────+ +───────+ +────────+ +─────────+ +────────+       │
 │ WAIT_SQ │ │CSR_   │ │MRET_   │ │WFI_     │ │TRAP_   │       │
 │         │ │EXEC   │ │EXEC    │ │WAIT     │ │WAIT    │       │
 +────┬────+ +───┬───+ +────┬───+ +────┬────+ +────┬───+       │
      │          │          │          │           │           │
   sq_empty  csr_done   mret_done  int_pending  trap_taken     │
      │          │          │          │           │           │
      +──────────+──────────+──────────+───────────+───────────+
```

All non-IDLE states assert `commit_stall`, blocking `commit_en` until the completion
condition is met. `flush_all` resets the FSM to IDLE from any state.

## Flush Behavior

### Partial Flush (Branch Misprediction)

Triggered by `i_flush_en` with `i_flush_tag` identifying the mispredicting branch.

- All entries **younger** than `flush_tag` are invalidated. Age is computed relative
  to `head_idx` using modular subtraction, correctly handling pointer wrap.
- The tail pointer resets to `flush_tag + 1` (via age-based arithmetic on the full
  6-bit pointer).
- The mispredicting branch entry itself is **not** flushed — it remains valid and
  commits normally.

### Full Flush (Exception)

Triggered by `i_flush_all`.

- All `rob_valid` bits are cleared in a single cycle.
- The tail pointer resets to `head_ptr` (buffer becomes empty).
- The serializing FSM resets to IDLE.
- The pipeline restarts from the trap handler address.

## Verification

### Cocotb Tests

See `frost/verif/cocotb_tests/tomasulo/reorder_buffer/` for simulation-based tests
covering:

- Allocation and full detection
- CDB writes and value capture
- Branch updates and misprediction detection
- Commit flow for INT and FP destinations
- Serializing instruction handling (WFI, CSR, FENCE, FENCE.I, MRET)
- Atomic instruction ordering (AMO/LR/SC)
- Partial and full flush scenarios
- Edge cases (back-to-back operations, simultaneous alloc + commit)

### Formal Verification

The RTL includes inline formal properties (under `` `ifdef FORMAL ``):

**Structural assumes** (interface contracts from upstream units):
- CDB write and branch update cannot target the same tag simultaneously
- `alloc_valid` is never asserted during flush

**Combinational asserts**:
- `full` and `empty` are mutually exclusive
- `count` equals `tail_ptr - head_ptr`
- `full`/`empty` match their pointer-based definitions
- `alloc_en` is never asserted when `full`
- `commit_en` requires `head_valid && head_done`
- Commit output tag always equals `head_idx`
- `commit_stall` blocks `commit_en`

**Sequential asserts**:
- Allocation sets `rob_valid` at the allocated index
- Commit clears `rob_valid` at the committed index
- `flush_all` results in an empty buffer
- `o_csr_start` only fires from IDLE state with a CSR at head
- `o_mret_start` only fires from IDLE state with an MRET at head
- `o_fence_i_flush` is a registered one-cycle pulse after FENCE.I commit

**Reset properties**:
- All `rob_valid` bits clear, pointers zero, FSM in IDLE

**Cover properties**:
- Simultaneous allocation and commit
- Buffer reaches full
- Partial flush, CSR serialization, WFI wakeup, MRET completion
- Exception triggering trap, FENCE.I generating flush pulse

### Simulation Assertions

Under `` `ifndef SYNTHESIS ``, runtime assertions check:
- No allocation when full
- No allocation during flush
- CDB writes and branch updates target valid entries
- Serialization state is consistent with head readiness

## Files

| File              | Description                            |
|-------------------|----------------------------------------|
| reorder_buffer.sv | Reorder Buffer implementation          |
| README.md         | This document                          |

## Dependencies

- **`riscv_pkg.sv`** — RISC-V constants, types, and struct definitions
  (`reorder_buffer_alloc_req_t`, `reorder_buffer_commit_t`, `exc_cause_t`, etc.)
- **`sdp_dist_ram.sv`** — Simple dual-port distributed RAM (1 write, 1 async read)
- **`mwp_dist_ram.sv`** — Multi-write-port distributed RAM with Live Value Table
