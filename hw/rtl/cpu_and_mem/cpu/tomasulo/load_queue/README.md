# Load Queue

Circular buffer that tracks in-flight load instructions from dispatch through
memory access to CDB broadcast. Entries are allocated in program order and
freed when their result is accepted by the CDB arbiter (via `fu_cdb_adapter`).

## Architecture

```
  Dispatch ──> [Alloc] ──> Tail
                              |
  MEM_RS Issue ──> [Addr Update] ──> CAM search by rob_tag
                              |
  [Issue Selection] ──> Priority scan head→tail
      |           |
   Phase A     Phase B
   (CDB)       (Memory)
      |           |
      |        [SQ Disambig] ──> o_sq_check_* / i_sq_forward
      |           |
      |        [Mem Issue] ──> o_mem_read_*
      |           |
      |        [Mem Resp] ──> load_unit ──> data capture
      |           |
   [CDB Broadcast] ──> o_fu_complete ──> fu_cdb_adapter ──> CDB slot 3
      |
  [Free Entry] ──> Head advances
```

## Storage Strategy

All fields in FFs (not LUTRAM/BRAM). 8 entries at ~116 bits each (~928 bits
total). Rationale:

- **CAM-style tag search**: Address update must find matching `rob_tag` across
  all entries in parallel. RAM primitives only provide single-address reads.
- **Per-entry invalidation**: Partial flush (branch misprediction) must clear
  individual entries by age comparison in a single cycle.
- **Parallel priority scan**: Issue selection reads all entries to find the
  oldest ready candidate. RAM would require sequential iteration.
- **8 entries**: Too small for BRAM (minimum 18 Kbit), marginal for LUTRAM.
- Same rationale as reservation stations, which use FF arrays at depths 2-8.

## Entry Structure

| Field       | Width   | Description                              |
|-------------|---------|------------------------------------------|
| valid       | 1 bit   | Entry allocated                          |
| rob_tag     | 5 bits  | Associated ROB entry                     |
| is_fp       | 1 bit   | FP load (FLW/FLD)                        |
| addr_valid  | 1 bit   | Address has been calculated              |
| address     | 32 bits | Load address                             |
| size        | 2 bits  | 00=B, 01=H, 10=W, 11=D (for FLD)        |
| sign_ext    | 1 bit   | Sign extend result (INT only)            |
| is_mmio     | 1 bit   | MMIO address (non-speculative only)      |
| fp64_phase  | 1 bit   | FLD phase: 0=low word, 1=high word       |
| issued      | 1 bit   | Sent to memory                           |
| data_valid  | 1 bit   | Data received from memory/forward        |
| data        | 64 bits | Loaded data (FLEN for FLD)               |
| forwarded   | 1 bit   | Data from store queue forward            |
| **Total**   | **~116 bits** |                                     |

## Ports

| Port | Dir | Type | Description |
|------|-----|------|-------------|
| `i_clk` | in | logic | Clock |
| `i_rst_n` | in | logic | Active-low reset |
| `i_alloc` | in | `lq_alloc_req_t` | Allocation from dispatch |
| `o_full` | out | logic | LQ is full |
| `i_addr_update` | in | `lq_addr_update_t` | Address from MEM_RS issue |
| `o_sq_check_valid` | out | logic | SQ disambiguation request |
| `o_sq_check_addr` | out | XLEN | Address for SQ check |
| `o_sq_check_rob_tag` | out | 5 bits | ROB tag for SQ check |
| `o_sq_check_size` | out | `mem_size_e` | Size for SQ check |
| `i_sq_all_older_addrs_known` | in | logic | SQ has all older addresses |
| `i_sq_forward` | in | `sq_forward_result_t` | SQ forwarding result |
| `o_mem_read_en` | out | logic | Memory read request |
| `o_mem_read_addr` | out | XLEN | Memory read address |
| `o_mem_read_size` | out | `mem_size_e` | Memory read size |
| `i_mem_read_data` | in | XLEN | Memory read data |
| `i_mem_read_valid` | in | logic | Memory read response valid |
| `o_fu_complete` | out | `fu_complete_t` | CDB result to adapter |
| `i_adapter_result_pending` | in | logic | Back-pressure from adapter |
| `i_rob_head_tag` | in | 5 bits | ROB head for MMIO ordering |
| `i_flush_en` | in | logic | Partial flush enable |
| `i_flush_tag` | in | 5 bits | Partial flush tag boundary |
| `i_flush_all` | in | logic | Full pipeline flush |
| `o_empty` | out | logic | LQ is empty |
| `o_count` | out | 4 bits | Number of valid entries |

## Key Behaviors

1. **Allocation**: On `i_alloc.valid && !o_full`, write entry at tail, advance
   tail pointer.

2. **Address Update**: CAM search all entries for matching `rob_tag` with
   `!addr_valid`. Write address and `is_mmio` flag.

3. **Issue Selection**: Two-phase priority scan from head to tail:
   - Phase A: Oldest entry with `data_valid` (ready for CDB broadcast)
   - Phase B: Oldest entry with `addr_valid && !issued && !data_valid`
     (ready for SQ disambiguation and memory)

4. **Store Disambiguation**: Phase B candidate drives `o_sq_check_*` ports.
   Response determines action: forward data, issue to memory, or stall.

5. **Memory Issue**: Single outstanding read. `issued_idx` register tracks
   which entry is awaiting response. FLD uses two phases (addr, addr+4).

6. **Memory Response**: Load unit extracts bytes/halfwords with sign extension.
   FLD phase 0 stores low word and resets `issued` for phase 1 re-issue.

7. **CDB Broadcast**: INT loads zero-extend XLEN to FLEN. FLW NaN-boxes
   (`{32'hFFFF_FFFF, data[31:0]}`). FLD uses raw 64-bit data.

8. **Entry Freeing**: When CDB broadcasts, the entry is freed. Head pointer
   advances past contiguous freed entries.

9. **MMIO**: MMIO entries only issue when `rob_tag == i_rob_head_tag`.

10. **Flush**: `i_flush_all` resets all state. `i_flush_en` invalidates
    entries younger than `i_flush_tag` (age comparison relative to ROB head).

## Verification

- **Formal**: `ifdef FORMAL` block with BMC (depth 12) and cover (depth 20).
  Assertions check pointer/count consistency, issue prerequisites, MMIO
  ordering, CDB back-pressure, and flush behavior.
- **Cocotb**: 21 unit tests covering reset, allocation, address update,
  LW/LB/LBU/LH/LHU, SQ forwarding, MMIO, FLD two-phase, FLW NaN-boxing,
  flush, ordering, back-pressure, and constrained random.

## Files

- `load_queue.sv` - Module implementation
- `load_queue.f` - Cocotb compilation file list
- `README.md` - This file
