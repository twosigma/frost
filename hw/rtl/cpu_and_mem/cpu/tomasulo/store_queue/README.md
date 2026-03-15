# Store Queue

Commit-ordered store buffer that holds in-flight store instructions from dispatch
until they write to memory after ROB commit. Entries are allocated in program order
and freed when their memory write completes.

## Architecture

```
                           Store Queue Block Diagram

       Dispatch         MEM_RS Issue          ROB Commit       LQ (Fwd Check)
      ┌──────────┐     ┌────────────┐       ┌───────────┐     ┌──────────────┐
      │ i_alloc  │     │addr_update │       │commit_    │     │i_sq_check_*  │
      └────┬─────┘     │data_update │       │valid/tag  │     └──────┬───────┘
           │           └─────┬──────┘       └─────┬─────┘            │
      write @ tail    CAM tag match        CAM tag match       comb scan all
           │                │                    │              older entries
           ▼                ▼                    ▼                    ▼
  ┌─────────────────────────────────────────────────────────────────────────┐
  │                     DEPTH-Entry Circular Buffer                        │
  │                                                                        │
  │  Per-Entry FFs (control / CAM-scanned):                                │
  │    valid, rob_tag, is_fp, addr_valid, address[31:0], size[1:0]         │
  │    data_valid, is_mmio, fp64_phase, committed, sent, is_sc             │
  │                                                                        │
  │  LUTRAM (2× sdp_dist_ram, identical writes, independent reads):        │
  │    data[63:0]                                                          │
  │    Write: CAM-resolved index on data_update                            │
  │    Read 1: fwd_match_idx (forwarding to LQ)                            │
  │    Read 2: head_idx (memory writeback)                                 │
  │                                                                        │
  │  Forwarding Scan (combinational, all entries):                         │
  │    For each valid older entry with addr_valid:                         │
  │      addr match + size match + data_valid → can_forward                │
  │    all_older_addrs_known: conservative stall signal                    │
  │                                                                        │
  │      head_ptr ─────┐                           ┌────── tail_ptr        │
  │   (4-bit, wrap MSB)│                           │(4-bit, wrap MSB)      │
  └────────────────────┼───────────────────────────┼───────────────────────┘
            ┌──────────┘                           └───────────┐
            ▼                                                  ▼
  ┌──────────────────────────┐                    ┌────────────────────────┐
  │  Head Drain (Mem Write)  │                    │  Forwarding Result     │
  │                          │                    │  o_sq_forward          │
  │  Fires when:             │                    │    match, can_forward, │
  │   committed && addr_valid│                    │    data                │
  │   && data_valid && !sent │                    │  o_sq_all_older_addrs_ │
  │                          │                    │    known               │
  │  o_mem_write_en/addr/    │                    └────────────────────────┘
  │    data/byte_en          │
  │  FSD: 2-phase (lo, hi)   │                    ┌────────────────────────┐
  │                          │                    │  o_full / o_empty      │
  │  On write done:          │                    │  o_committed_empty     │
  │   → free entry           │                    │  o_count               │
  │   → advance head         │                    └────────────────────────┘
  │   → o_cache_invalidate   │
  │     (to LQ L0 cache)     │                    ┌────────────────────────┐
  └──────────────────────────┘                    │  Flush Control         │
                                                  │  flush_all → reset all │
  ┌──────────────────────────┐                    │  flush_en → age-based  │
  │  SC Discard              │                    │   (uncommitted only)   │
  │  i_sc_discard → invalid- │                    └────────────────────────┘
  │  ate uncommitted SC entry│
  └──────────────────────────┘
```

## Storage Strategy

**Hybrid FF + LUTRAM.** Control and CAM-scanned fields remain in FFs; the
64-bit `data` field is stored in duplicated `sdp_dist_ram` instances (one per
read port).

- **FFs**: `valid`, `rob_tag`, `is_fp`, `addr_valid`, `address`, `data_valid`,
  `size`, `is_mmio`, `fp64_phase`, `committed`, `sent`. These require parallel
  CAM-style tag search (address/data update, commit), per-entry invalidation on
  flush, and parallel forwarding scan.
- **LUTRAM** (2× `sdp_dist_ram`, same write, different read addresses):
  - Write: CAM-resolved index on data update (1 write port).
  - Read port 1: forwarding scan match index (combinational from FF-based
    address/tag comparison).
  - Read port 2: head index for memory writeback.
  - Duplicated instances allow two independent async reads with a single
    shared write.

## Entry Structure

| Field       | Width   | Description                              |
|-------------|---------|------------------------------------------|
| valid       | 1 bit   | Entry allocated                          |
| rob_tag     | 5 bits  | ROB entry for this store                 |
| is_fp       | 1 bit   | FP store (FSW/FSD)                       |
| addr_valid  | 1 bit   | Address has been calculated              |
| address     | 32 bits | Store address                            |
| data_valid  | 1 bit   | Data is available                        |
| data        | 64 bits | Store data (FLEN for FSD) — in LUTRAM    |
| size        | 2 bits  | 00=B, 01=H, 10=W, 11=D (for FSD)         |
| is_mmio     | 1 bit   | MMIO address (bypass cache on commit)    |
| fp64_phase  | 1 bit   | FSD phase: 0=low word, 1=high word       |
| committed   | 1 bit   | ROB has committed this store             |
| sent        | 1 bit   | Written to memory                        |
| **Total**   | **~115 bits** |                                    |

## Ports

| Port | Dir | Type | Description |
|------|-----|------|-------------|
| `i_clk` | in | logic | Clock |
| `i_rst_n` | in | logic | Active-low reset |
| `i_alloc` | in | `sq_alloc_req_t` | Allocation from dispatch |
| `o_full` | out | logic | SQ is full |
| `i_addr_update` | in | `sq_addr_update_t` | Address from MEM_RS issue |
| `i_data_update` | in | `sq_data_update_t` | Data from MEM_RS issue (src2) |
| `i_commit_valid` | in | logic | Store committed by ROB |
| `i_commit_rob_tag` | in | 5 bits | Tag of committed store |
| `i_sq_check_valid` | in | logic | LQ disambiguation request |
| `i_sq_check_addr` | in | XLEN | Load address from LQ |
| `i_sq_check_rob_tag` | in | 5 bits | Load ROB tag from LQ |
| `i_sq_check_size` | in | `mem_size_e` | Load size from LQ |
| `o_sq_all_older_addrs_known` | out | logic | All older stores have addr |
| `o_sq_forward` | out | `sq_forward_result_t` | Forwarding result to LQ |
| `o_mem_write_en` | out | logic | Memory write request |
| `o_mem_write_addr` | out | XLEN | Memory write address |
| `o_mem_write_data` | out | XLEN | Memory write data |
| `o_mem_write_byte_en` | out | 4 bits | Byte-lane enables |
| `i_mem_write_done` | in | logic | Memory write acknowledged |
| `o_cache_invalidate_valid` | out | logic | L0 cache invalidation |
| `o_cache_invalidate_addr` | out | XLEN | Address to invalidate |
| `i_rob_head_tag` | in | 5 bits | ROB head for age comparisons |
| `i_flush_en` | in | logic | Partial flush enable |
| `i_flush_tag` | in | 5 bits | Partial flush tag boundary |
| `i_flush_all` | in | logic | Full pipeline flush |
| `o_empty` | out | logic | SQ is empty |
| `o_count` | out | 4 bits | Number of valid entries |

## Key Behaviors

1. **Allocation**: On `i_alloc.valid && !o_full`, write entry at tail, advance
   tail pointer.

2. **Address Update**: CAM search all entries for matching `rob_tag` with
   `!addr_valid`. Write address and `is_mmio` flag.

3. **Data Update**: CAM search all entries for matching `rob_tag` with
   `!data_valid`. Write store data (FLEN-wide).

4. **Commit**: When ROB commits a store (`i_commit_valid`), CAM search for
   matching `rob_tag` and set `committed = 1`.

5. **Memory Write**: Head entry writes to memory when `committed && addr_valid
   && data_valid && !sent`. Single outstanding write. Byte enables generated
   from size and address offset.

6. **FSD Two-Phase**: Phase 0 writes low word (addr), phase 1 writes high word
   (addr+4). Both must complete before entry is freed.

7. **Store-to-Load Forwarding**: Combinational scan of all entries. For each
   valid entry older than the load: check addr_valid for disambiguation, check
   address overlap for matching. Forward when exact address match, same size,
   WORD/DOUBLE, and data_valid.

8. **L0 Cache Invalidation**: On memory write completion, output the written
   address to the LQ's L0 cache for invalidation.

9. **Flush**: `i_flush_all` resets all state. `i_flush_en` invalidates
   uncommitted entries younger than `i_flush_tag`. Committed entries are never
   flushed (they must complete to memory).

## Verification

- **Formal**: `ifdef FORMAL` block with BMC (depth 12) and cover (depth 20).
  Assertions check pointer/count consistency, memory write prerequisites,
  forwarding invariants, committed-survives-flush, and reset behavior.
- **Cocotb**: Unit tests covering reset, allocation, address/data update,
  commit + memory write (SW/SH/SB), FSD two-phase, FSW, store-to-load
  forwarding, MMIO, flush, and constrained random.

## Dependencies

| Module | Purpose |
|--------|---------|
| `riscv_pkg` | Type definitions |
| `sdp_dist_ram` | Simple dual-port distributed RAM for sq_data LUTRAM (2 instances) |

## Files

- `store_queue.sv` - Module implementation
- `store_queue.f` - Cocotb compilation file list
- `README.md` - This file
