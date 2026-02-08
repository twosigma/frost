# Reorder Buffer

The Reorder Buffer is the central data structure in the FROST Tomasulo out-of-order
execution engine. It enables in-order instruction commit while allowing out-of-order
execution, providing precise exceptions and supporting speculation recovery.

## Overview

The Reorder Buffer is a 32-entry circular buffer that tracks all in-flight instructions
from dispatch to commit. Each entry holds instruction metadata, execution results, and
status flags. The Reorder Buffer supports unified INT/FP entries with a `dest_rf` flag
to distinguish between integer and floating-point destinations.

### Key Features

- **32-entry circular buffer** with head/tail pointers
- **Unified INT/FP entries** - single buffer for all instruction types
- **In-order allocation** at dispatch, **in-order commit** at retirement
- **Out-of-order completion** via CDB writes and branch updates
- **Branch misprediction detection** with checkpoint-based recovery
- **Exception handling** with precise trap support
- **Serializing instruction support**: WFI, CSR, FENCE, FENCE.I, MRET
- **Atomic instruction ordering**: AMO/LR/SC execute at head with SQ empty

## Architecture

```
                         Reorder Buffer Internal Structure
    +------------------------------------------------------------------------+
    |                                                                        |
    |  PARAMETERS:                                                           |
    |    REORDER_BUFFER_DEPTH = 32 (configurable, power of 2)                |
    |    REORDER_BUFFER_TAG_WIDTH = $clog2(DEPTH) = 5 bits                   |
    |                                                                        |
    |  +------------------------------------------------------------------+  |
    |  |                     CIRCULAR BUFFER                              |  |
    |  |                                                                  |  |
    |  |  HEAD (commit ptr)              TAIL (alloc ptr)                 |  |
    |  |    |                                |                            |  |
    |  |    v                                v                            |  |
    |  |  +-----+-----+-----+-----+-----+-----+-----+-----+               |  |
    |  |  |  0  |  1  |  2  |  3  |  4  |  5  |  6  | ... |  [DEPTH]      |  |
    |  |  +-----+-----+-----+-----+-----+-----+-----+-----+               |  |
    |  |                                                                  |  |
    |  +------------------------------------------------------------------+  |
    |                                                                        |
    |  CONTROL LOGIC:                                                        |
    |                                                                        |
    |  +---------------------------+    +----------------------------+       |
    |  |     ALLOCATION            |    |       COMMIT               |       |
    |  |                           |    |                            |       |
    |  |  if (!full && dispatch):  |    |  if (head.valid &&         |       |
    |  |    entry[tail] <- instr   |    |      head.done):           |       |
    |  |    tail <- tail + 1       |    |                            |       |
    |  |    return tail as tag     |    |    if (head.exception):    |       |
    |  |                           |    |      trigger_trap()        |       |
    |  +---------------------------+    |      flush_all()           |       |
    |                                   |    else:                   |       |
    |  +---------------------------+    |      if (dest_rf == INT):  |       |
    |  |     CDB WRITE             |    |        x_regfile[rd] <- v  |       |
    |  |                           |    |      else:                 |       |
    |  |  for each CDB broadcast:  |    |        f_regfile[rd] <- v  |       |
    |  |    if (tag matches entry):|    |      fcsr.flags |= fp_flags|       |
    |  |      entry.done <- 1      |    |      head <- head + 1      |       |
    |  |      entry.value <- data  |    |                            |       |
    |  |      entry.exc <- exc     |    +----------------------------+       |
    |  |      entry.fp_flags <- fl |                                         |
    |  +---------------------------+    +---------------------------+        |
    |                                   |       FLUSH               |        |
    |  +---------------------------+    |                           |        |
    |  |     STATUS SIGNALS        |    |  On branch mispredict:    |        |
    |  |                           |    |    tail <- branch_entry+1 |        |
    |  |  full = (tail+1 == head)  |    |    invalidate entries     |        |
    |  |  empty = (tail == head)   |    |      after branch         |        |
    |  |  count = tail - head      |    |                           |        |
    |  +---------------------------+    |  On exception:            |        |
    |                                   |    tail <- head           |        |
    |                                   |    invalidate all         |        |
    |                                   +---------------------------+        |
    |                                                                        |
    +------------------------------------------------------------------------+
```

## Entry Structure

Each Reorder Buffer entry contains approximately 120 bits of state.

### Storage Strategy

Multi-bit fields are stored in **distributed RAM (LUTRAM)** to reduce flip-flop usage.
Single-bit packed vectors that require per-entry flush/reset remain in **flip-flops**.

- **`sdp_dist_ram`** (1 write port): Fields written only at allocation — `pc`,
  `dest_reg`, `predicted_target`, `checkpoint_id`.
- **`mwp_dist_ram`** (2 write ports, LVT): Fields written at allocation *and*
  updated by the CDB or branch unit — `value`, `exc_cause`, `fp_flags`,
  `branch_target`. Port 0 = allocation (lower priority), port 1 = CDB/branch
  (higher priority). `value` has two read ports (head commit + RAT bypass), so
  it uses two `mwp_dist_ram` instances with identical writes.
- **Flip-flops**: All 1-bit packed vectors (`valid`, `done`, `exception`,
  `is_branch`, `mispredicted`, etc.) — need per-entry clear on flush/reset.

This saves approximately 5,500 FFs compared to a pure register-based design.

### Fields

| Field           | Width    | Storage  | Description                                    |
|-----------------|----------|----------|------------------------------------------------|
| valid           | 1 bit    | FF       | Entry is allocated                             |
| done            | 1 bit    | FF       | Execution complete                             |
| exception       | 1 bit    | FF       | Exception occurred                             |
| exc_cause       | 5 bits   | LUTRAM   | Exception cause code                           |
| pc              | 32 bits  | LUTRAM   | Instruction PC (for mepc)                      |
| dest_rf         | 1 bit    | FF       | 0=INT (x-reg), 1=FP (f-reg)                    |
| dest_reg        | 5 bits   | LUTRAM   | Architectural destination (rd)                 |
| dest_valid      | 1 bit    | FF       | Has destination register                       |
| value           | FLEN (64) bits | LUTRAM | Result value (FLEN for FP double support)      |
| is_store        | 1 bit    | FF       | Is store instruction                           |
| is_fp_store     | 1 bit    | FF       | Is FP store (FSW/FSD)                          |
| is_branch       | 1 bit    | FF       | Is branch/jump instruction                     |
| branch_taken    | 1 bit    | FF       | Actual branch outcome                          |
| branch_target   | 32 bits  | LUTRAM   | Actual branch target                           |
| predicted_taken | 1 bit    | FF       | BTB prediction                                 |
| predicted_target| 32 bits  | LUTRAM   | BTB/RAS predicted target                       |
| mispredicted    | 1 bit    | FF       | Branch unit determined misprediction (authoritative) |
| is_call         | 1 bit    | FF       | Is call (for RAS recovery)                     |
| is_return       | 1 bit    | FF       | Is return (for RAS recovery)                   |
| fp_flags        | 5 bits   | LUTRAM   | FP exception flags (NV/DZ/OF/UF/NX)            |
| has_checkpoint  | 1 bit    | FF       | Branch has allocated checkpoint                |
| checkpoint_id   | 2 bits   | LUTRAM   | Checkpoint index for recovery                  |
| is_csr/fence/...| various  | FF       | Serializing instruction flags                  |

## Interfaces

### Allocation Interface (from Dispatch)

```systemverilog
input  reorder_buffer_alloc_req_t  i_alloc_req   // Allocation request
output reorder_buffer_alloc_resp_t o_alloc_resp  // Returns tag, ready/full status
```

Dispatch requests a Reorder Buffer entry for each decoded instruction. The buffer
returns the allocated tag (entry index) which becomes the instruction's identifier
throughout the pipeline.

**Invariant**: Dispatch must not assert `alloc_valid` during flush cycles (`i_flush_en`
or `i_flush_all`). The `alloc_ready` signal gates on flush (deasserts during flush
cycles), but dispatch is also expected to be independently stalled by the flush
controller. An assertion in simulation verifies this invariant.

### CDB Write Interface (from Functional Units)

```systemverilog
input reorder_buffer_cdb_write_t i_cdb_write  // Tag, value, exception, FP flags
```

When a functional unit completes execution, it broadcasts the result on the CDB.
The Reorder Buffer captures results for matching tags, marking entries as `done`.

### Branch Update Interface (from Branch Unit)

```systemverilog
input reorder_buffer_branch_update_t i_branch_update  // Tag, taken, target
```

Branch resolution is separate from the CDB. The branch unit reports the actual
outcome, target, and **authoritative misprediction flag**. The Reorder Buffer stores
the `mispredicted` field directly and uses it at commit (it does not recompute
misprediction, deferring to the branch unit's knowledge of RAS, indirect predictor, etc.).

### Commit Output (to Regfiles, SQ, Trap Unit)

```systemverilog
output reorder_buffer_commit_t o_commit  // Committed instruction details
```

When the head entry is valid and done, the Reorder Buffer commits it by outputting
the destination register, value, and any exception/FP flag information.

### External Coordination

The Reorder Buffer coordinates with several external units for serializing instructions:

| Signal              | Direction | Purpose                                    |
|---------------------|-----------|------------------------------------------- |
| i_sq_empty          | Input     | Store queue is empty (FENCE, AMO)          |
| o_csr_start         | Output    | Signal CSR unit to execute                 |
| i_csr_done          | Input     | CSR execution complete                     |
| o_trap_pending      | Output    | Exception at head needs handling           |
| i_trap_taken        | Input     | Trap unit has taken the exception          |
| o_mret_start        | Output    | Signal trap unit for MRET                  |
| i_mret_done         | Input     | MRET handling complete                     |
| i_mepc              | Input     | Return PC from trap unit                   |
| i_interrupt_pending | Input     | Interrupt pending (wake WFI)               |
| o_fence_i_flush     | Output    | FENCE.I committed, flush pipeline          |

## Serializing Instructions

Certain instructions require special handling at commit:

### WFI (Wait For Interrupt)
- Stalls at Reorder Buffer head until `i_interrupt_pending` is asserted
- Commits as a NOP once interrupt arrives

### CSR Instructions
- **CSR reads execute speculatively** in the pipeline and broadcast results via CDB
- The CSR entry must be marked `done` (via CDB write) before it can commit
- At commit, the Reorder Buffer asserts `o_csr_start` to trigger CSR side effects
- Waits for `i_csr_done` before completing commit (allows CSR unit to finish writes)
- This ensures CSR side effects are visible only for architecturally committed instructions

### FENCE
- Waits for store queue to drain (`i_sq_empty`)
- Ensures all prior stores are visible before subsequent memory ops

### FENCE.I
- Same as FENCE, plus signals pipeline/icache flush after commit
- `o_fence_i_flush` pulses high the cycle after FENCE.I commits

### MRET
- Signals trap unit via `o_mret_start`
- Waits for `i_mret_done`, uses `i_mepc` for redirect PC
- Restores privilege state (handled by trap unit)

### AMO/LR/SC
- Must execute at Reorder Buffer head with store queue empty
- Ensures memory ordering for atomic operations

## Flush Behavior

### Partial Flush (Branch Misprediction)
- `i_flush_en` with `i_flush_tag` specifies the mispredicting branch
- All entries younger than the branch are invalidated
- Tail pointer resets to branch entry + 1

### Full Flush (Exception)
- `i_flush_all` invalidates all Reorder Buffer entries
- Tail pointer resets to head pointer
- Pipeline restarts from trap handler

## State Machine

The serializing instruction state machine handles commit stalls:

```
                    +------------+
                    | SERIAL_IDLE|<-----------------------+
                    +-----+------+                        |
                          |                               |
    +---------------------+---------------------+         |
    |         |           |           |         |         |
    v         v           v           v         v         |
+-------+ +-------+ +--------+ +-------+ +--------+       |
|WAIT_SQ| |CSR_   | |MRET_   | |WFI_   | |TRAP_   |       |
|       | |EXEC   | |EXEC    | |WAIT   | |WAIT    |       |
+---+---+ +---+---+ +----+---+ +---+---+ +----+---+       |
    |         |          |         |          |           |
    | sq_empty| csr_done | mret_done| int_pend| trap_taken|
    +---------+----------+----------+---------+-----------+
```

## Usage Example

```systemverilog
reorder_buffer u_reorder_buffer (
    .i_clk              (clk),
    .i_rst_n            (rst_n),

    // Allocation from dispatch
    .i_alloc_req        (dispatch_to_reorder_buffer),
    .o_alloc_resp       (reorder_buffer_to_dispatch),

    // Results from functional units
    .i_cdb_write        (cdb_broadcast),
    .i_branch_update    (branch_resolution),

    // Commit to regfiles
    .o_commit           (reorder_buffer_commit),

    // External coordination
    .i_sq_empty         (store_queue_empty),
    .o_csr_start        (csr_execute),
    .i_csr_done         (csr_complete),
    // ... other signals
);
```

## Files

| File               | Description                              |
|--------------------|------------------------------------------|
| reorder_buffer.sv  | Complete Reorder Buffer implementation   |

## Dependencies

- `riscv_pkg.sv` - RISC-V constants and types
- `tomasulo_pkg.sv` - Tomasulo-specific types (reorder_buffer_entry_t, etc.)
- `sdp_dist_ram.sv` - Distributed RAM primitive (single-write-port fields)
- `mwp_dist_ram.sv` - Multi-write-port distributed RAM (CDB/branch-updated fields)

## Testing

See `frost/verif/cocotb_tests/tomasulo/reorder_buffer/` for cocotb tests covering:

- Allocation and full detection
- CDB writes and value capture
- Branch updates and misprediction detection
- Commit flow for INT and FP destinations
- Serializing instruction handling
- Partial and full flush scenarios
- Edge cases (back-to-back operations, simultaneous events)
