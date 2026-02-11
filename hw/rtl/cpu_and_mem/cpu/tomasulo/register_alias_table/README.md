# Register Alias Table

The Register Alias Table (RAT) maps architectural registers to in-flight ROB tags for
register renaming in the FROST Tomasulo out-of-order execution engine. It maintains
separate INT (x0-x31) and FP (f0-f31) rename tables with 4-slot checkpoint storage for
branch speculation recovery.

## Key Features

- **Separate INT and FP rename tables** — 32 entries each, unified `rat_entry_t` format
- **x0 hardwired** — always returns `{renamed=0, value=0}`, writes ignored
- **5 source lookups** — 2 INT (rs1/rs2), 3 FP (fs1/fs2/fs3 for FMA)
- **Single rename write port** from dispatch with INT/FP selection
- **Tag-matched commit clear** — only clears entry if current tag matches committing tag
- **4 checkpoint slots** for branch misprediction recovery
- **RAS state capture** in checkpoints (tos pointer + valid count)
- **Full flush** clears all rename state and checkpoints on exception

## Architecture

```
                     Register Alias Table Block Diagram

      Dispatch (Source Lookup)        Dispatch (Rename)       ROB (Commit)
     ┌───────────────────────┐      ┌──────────────┐       ┌──────────────┐
     │ int_src1/src2_addr    │      │ alloc_valid  │       │ commit.valid │
     │ fp_src1/src2/src3_addr│      │ alloc_dest_rf│       │ commit.tag   │
     │ regfile_data (INT/FP) │      │ alloc_dest_reg│      │ commit.dest* │
     └──────────┬────────────┘      │ alloc_rob_tag│       └──────┬───────┘
                │                   └──────┬───────┘              │
           comb read               sync write @ reg         sync clear if
                │                        │                   tag matches
                ▼                        ▼                        ▼
   ┌─────────────────────────────────────────────────────────────────────┐
   │                                                                     │
   │  FF: Active INT RAT (32 × 6b = 192b)                                │
   │  ┊  int_rat[0] = {valid=0, tag=---}  (x0 hardwired, never valid)    │
   │  ┊  int_rat[1..31] = {valid, tag}                                   │
   │                                                                     │
   │  FF: Active FP RAT (32 × 6b = 192b)                                 │
   │  ┊  fp_rat[0..31] = {valid, tag}                                    │
   │                                                                     │
   └────────────────────────────┬────────────────────────────────────────┘
                                │
            ┌───────────────────┼────────────────────┐
            │                   │                    │
     checkpoint save    checkpoint restore    checkpoint free
            │                   │                    │
            ▼                   ▼                    ▼
   ┌─────────────────────────────────────────────────────────────────────┐
   │                     Checkpoint Storage (4 slots)                    │
   │                                                                     │
   │  FF: checkpoint_valid[3:0]                                          │
   │                                                                     │
   │  sdp_dist_ram: RAT snapshots (384b wide × 4 deep)                   │
   │  ┊  INT RAT[31:0] + FP RAT[31:0] packed per checkpoint              │
   │                                                                     │
   │  sdp_dist_ram: Metadata (12b wide × 4 deep)                         │
   │  ┊  branch_tag[4:0] + ras_tos[2:0] + ras_valid_count[3:0]           │
   │                                                                     │
   └─────────────────────────────────────────────────────────────────────┘
            │                                        │
            ▼                                        ▼
   ┌────────────────────┐               ┌─────────────────────┐
   │ o_checkpoint_      │               │ o_ras_tos           │
   │   available        │               │ o_ras_valid_count   │
   │ o_checkpoint_      │               │ (on restore)        │
   │   alloc_id         │               └─────────────────────┘
   └────────────────────┘
```

## Entry Structure

### RAT Entry (`rat_entry_t`)

| Field   | Width | Description                                    |
|---------|-------|------------------------------------------------|
| `valid` | 1 bit | Register has an in-flight producer in the ROB   |
| `tag`   | 5 bits| ROB tag of the producing instruction            |

Total: 6 bits per register. INT RAT = 32 × 6 = 192 bits. FP RAT = 32 × 6 = 192 bits.

### RAT Lookup Result (`rat_lookup_t`)

| Field     | Width    | Description                                       |
|-----------|----------|---------------------------------------------------|
| `renamed` | 1 bit    | Source is renamed (must wait for ROB tag)          |
| `tag`     | 5 bits   | ROB tag if renamed                                |
| `value`   | FLEN bits| Value from regfile (valid if not renamed)          |

### Checkpoint Metadata

| Field              | Width  | Storage      | Description                        |
|--------------------|--------|--------------|------------------------------------|
| `valid`            | 1 bit  | FF           | Checkpoint slot is active          |
| `branch_tag`       | 5 bits | `sdp_dist_ram` | ROB tag of associated branch     |
| `ras_tos`          | 3 bits | `sdp_dist_ram` | RAS top-of-stack pointer         |
| `ras_valid_count`  | 4 bits | `sdp_dist_ram` | RAS valid entry count            |
| `int_rat` snapshot | 192 bits | `sdp_dist_ram` | Full INT RAT state             |
| `fp_rat` snapshot  | 192 bits | `sdp_dist_ram` | Full FP RAT state              |

## Storage Strategy

| Structure | Storage | Rationale |
|-----------|---------|-----------|
| Active INT RAT (32 × 6b) | FF | Bulk parallel write on checkpoint restore; multi-port reads; per-entry conditional commit clear |
| Active FP RAT (32 × 6b) | FF | Same reasons as INT RAT |
| Checkpoint RAT snapshots (4 × 384b) | `sdp_dist_ram` | Single-write (save), single-read (restore), addressed by checkpoint_id |
| Checkpoint metadata (4 × 12b) | `sdp_dist_ram` | Same access pattern as RAT snapshots |
| Checkpoint valid bits (4 × 1b) | FF | Need per-entry clear on free and bulk clear on flush |

## Interfaces

### Source Lookup (from Dispatch)

```systemverilog
input  logic [RegAddrWidth-1:0] i_int_src1_addr, i_int_src2_addr
output rat_lookup_t             o_int_src1, o_int_src2

input  logic [RegAddrWidth-1:0] i_fp_src1_addr, i_fp_src2_addr, i_fp_src3_addr
output rat_lookup_t             o_fp_src1, o_fp_src2, o_fp_src3

input logic [XLEN-1:0] i_int_regfile_data1, i_int_regfile_data2
input logic [FLEN-1:0] i_fp_regfile_data1, i_fp_regfile_data2, i_fp_regfile_data3
```

Combinational lookup. For each source register address, the RAT checks whether the
register is renamed (has an in-flight producer). If renamed, returns `{renamed=1, tag}`.
If not, returns `{renamed=0, value=regfile_data}`. INT x0 always returns
`{renamed=0, value=0}` regardless of regfile data.

Dispatch uses the lookup result to decide whether to read the value from the regfile
(not renamed) or wait for the ROB tag (renamed). If renamed, dispatch separately
queries the ROB bypass interface to check if the value is already available.

### Rename Write (from Dispatch)

```systemverilog
input logic                             i_alloc_valid
input logic                             i_alloc_dest_rf    // 0=INT, 1=FP
input logic [RegAddrWidth-1:0]          i_alloc_dest_reg
input logic [ReorderBufferTagWidth-1:0] i_alloc_rob_tag
```

Synchronous write. Sets `{valid=1, tag=rob_tag}` in the selected RAT table. INT x0
writes are silently ignored. Must not be asserted during `i_flush_all` or
`i_checkpoint_restore`.

### Commit (from ROB)

```systemverilog
input reorder_buffer_commit_t i_commit
```

On valid commit with `dest_valid`: if the current RAT entry's tag matches the
committing tag, clears the entry's valid bit. This means the architectural regfile
now holds the committed value and the register is no longer renamed.

If a rename and commit target the same register in the same cycle, the rename takes
priority (the new mapping supersedes the one being committed).

### Checkpoint Save (from Dispatch)

```systemverilog
input logic                             i_checkpoint_save
input logic [CheckpointIdWidth-1:0]     i_checkpoint_id
input logic [ReorderBufferTagWidth-1:0] i_checkpoint_branch_tag
input logic [RasPtrBits-1:0]            i_ras_tos
input logic [RasPtrBits:0]              i_ras_valid_count
```

Snapshots the current INT RAT, FP RAT, and RAS state into the specified checkpoint
slot. Occurs when dispatch allocates a branch instruction that needs speculation
recovery capability.

### Checkpoint Restore (from Flush Controller)

```systemverilog
input  logic                          i_checkpoint_restore
input  logic [CheckpointIdWidth-1:0]  i_checkpoint_restore_id
output logic [RasPtrBits-1:0]         o_ras_tos
output logic [RasPtrBits:0]           o_ras_valid_count
```

On branch misprediction, bulk overwrites the active INT and FP RATs from the
checkpoint snapshot. Also outputs the restored RAS state for the frontend to recover.
Restore takes priority over all other operations (dispatch is stalled during restore).

### Checkpoint Free (from ROB)

```systemverilog
input logic                          i_checkpoint_free
input logic [CheckpointIdWidth-1:0]  i_checkpoint_free_id
```

Frees a checkpoint slot when the associated branch commits with a correct prediction.

### Flush All (Exception)

```systemverilog
input logic i_flush_all
```

Clears all INT and FP RAT valid bits and all checkpoint valid bits in a single cycle.
Takes priority over all other operations.

### Checkpoint Availability (to Dispatch)

```systemverilog
output logic                          o_checkpoint_available
output logic [CheckpointIdWidth-1:0]  o_checkpoint_alloc_id
```

Combinational priority encoder over free checkpoint slots. Dispatch uses this to
determine whether it can allocate a checkpoint for a new branch. If no checkpoint is
available, dispatch stalls the branch instruction.

## Operations

### Read (Source Lookup)

```
For INT source (rs1/rs2):
  if (rs == x0):       return {renamed=0, tag=0, value=0}
  elif (rat[rs].valid): return {renamed=1, tag=rat[rs].tag, value=regfile[rs]}
  else:                 return {renamed=0, tag=0,           value=regfile[rs]}

For FP source (fs1/fs2/fs3):
  if (rat[fs].valid):   return {renamed=1, tag=rat[fs].tag, value=fregfile[fs]}
  else:                 return {renamed=0, tag=0,           value=fregfile[fs]}
```

### Write (Rename)

```
if (alloc_valid && !flush_all && !checkpoint_restore):
  if (dest_rf == INT && dest_reg != x0):
    int_rat[dest_reg] = {valid=1, tag=rob_tag}
  elif (dest_rf == FP):
    fp_rat[dest_reg] = {valid=1, tag=rob_tag}
```

### Commit Clear

```
if (commit.valid && commit.dest_valid && !flush_all && !restore):
  table = (dest_rf == INT) ? int_rat : fp_rat
  if (table[dest_reg].valid && table[dest_reg].tag == commit.tag):
    table[dest_reg].valid = 0
```

### Checkpoint Save

```
if (checkpoint_save && !flush_all):
  checkpoint_rat[id] = {int_rat, fp_rat}
  checkpoint_meta[id] = {branch_tag, ras_tos, ras_valid_count}
  checkpoint_valid[id] = 1
```

### Checkpoint Restore

```
if (checkpoint_restore):
  int_rat = checkpoint_rat[id].int_rat
  fp_rat  = checkpoint_rat[id].fp_rat
  output ras_tos, ras_valid_count from checkpoint_meta[id]
```

### Flush All

```
if (flush_all):
  for all i: int_rat[i].valid = 0, fp_rat[i].valid = 0
  checkpoint_valid = 0
```

## x0 Handling

Integer register x0 is hardwired to zero in RISC-V. The RAT enforces this invariant:

- **Reads**: Looking up x0 always returns `{renamed=0, tag=0, value=0}`, regardless
  of the RAT entry state or regfile data
- **Writes**: Rename writes to x0 are silently ignored (`i_alloc_dest_reg == 0` with
  `i_alloc_dest_rf == 0` does not modify the INT RAT)
- **Commit**: Commit clears skip x0 (redundant given x0 is never valid, but explicit)
- **Invariant**: `int_rat[0].valid` is always 0, enforced by formal assertion
- **Dispatch**: Expected to never request x0 rename (simulation assertion warns)

## Checkpoint Management

### Sizing Rationale

With `NUM_CHECKPOINTS = 4` and `ROB_DEPTH = 32`:

- Average basic block size is 4-6 instructions
- Expect ~5-8 branches in flight at typical utilization
- 4 checkpoints cover most workloads without stalling

When all 4 checkpoints are in use, dispatch stalls any new branch that requires a
checkpoint until one is freed. This is the simple "stall on exhaustion" policy.

### Storage Cost

Per checkpoint: INT RAT (192b) + FP RAT (192b) + branch_tag (5b) + RAS state (7b)
+ valid (1b) = 397 bits. Total: 4 × 397 = 1,588 bits.

The RAT snapshot and metadata portions (396 bits × 4 = 1,584 bits) are stored in
distributed RAM, saving ~1,584 FFs compared to an all-FF design.

## Verification

### Formal Verification (`ifdef FORMAL)

**Assumes** (interface contracts from dispatch/flush controller):
- `i_alloc_valid` never asserted during `i_flush_all` or `i_checkpoint_restore`
- `i_checkpoint_save` and `i_checkpoint_restore` not simultaneous
- `i_checkpoint_restore` targets a valid checkpoint
- `i_alloc_dest_reg != 0` when `i_alloc_dest_rf == 0` and `i_alloc_valid`

**Combinational asserts**:
- `int_rat[0].valid` is never set (x0 invariant)
- x0 source lookups always return `{renamed=0, value=0}`
- `o_checkpoint_available` consistent with `checkpoint_valid` bits

**Sequential asserts**:
- `i_flush_all` clears all INT/FP RAT valid bits and checkpoint valid bits
- Rename write sets the correct entry with the correct tag
- Commit clears entry only when tag matches; preserves entry when tag doesn't match
- Reset clears all state

**Cover properties**:
- Simultaneous rename + commit to same register
- All 4 checkpoints in use (exhaustion)
- Checkpoint save and restore
- Full flush from non-empty state

### Simulation Assertions (`ifndef SYNTHESIS)

Runtime checks for protocol violations:
- No rename during flush_all or checkpoint_restore
- Checkpoint save targets a free slot
- Checkpoint restore targets a valid slot
- No INT x0 rename attempted
- No simultaneous checkpoint save and restore

## Files

| File                       | Description                          |
|----------------------------|--------------------------------------|
| register_alias_table.sv   | RAT implementation                   |
| README.md                 | This document                        |

## Dependencies

- **`riscv_pkg.sv`** — RISC-V constants, types, and struct definitions
  (`rat_entry_t`, `rat_lookup_t`, `int_rat_state_t`, `fp_rat_state_t`,
  `checkpoint_t`, `reorder_buffer_commit_t`)
- **`sdp_dist_ram.sv`** — Simple dual-port distributed RAM (1 write, 1 async read)
