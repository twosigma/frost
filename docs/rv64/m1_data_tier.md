<!--
   Copyright 2026 Two Sigma Open Source, LLC

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
-->

# M1 — the 64-bit data tier (design note)

Interface contract for [phase1_plan.md](phase1_plan.md) Milestone M1 /
decision D2: the data-memory tier below the load/store queues becomes
native 64-bit single-beat, implemented and proven **while the core was
still rv32** (the tier width is deliberately XLEN-independent). The
FLD/FSD two-phase machinery is deleted, not generalized — the
[audit](xlen_audit.md) established that phased dwords cannot serve RV64
(torn `mtime` reads, unphaseable AMO*.D) and that reusing them for INT
dwords is throwaway work.

Everything here is provable by the existing rv32 suites: FLD/FSD exercise
every widened path single-beat, rv32 word/half/byte ops exercise the
lane/strobe machinery, and the Linux boot lanes exercise the CLINT.

## The bus contract

New `riscv_pkg` constants (data-tier width, not XLEN):

```systemverilog
localparam int unsigned MemDataBits = 64;            // data-tier beat width
localparam int unsigned MemStrbBits = MemDataBits/8; // 8 byte lanes
```

- **Aligned-dword view.** Every data-side bus (BRAM tier, cached tier,
  MMIO, router, adapter responses) carries the aligned dword at
  `addr[31:3]`; byte lane *i* is byte address `{addr[31:3], i}`. Consumers
  extract by `addr[2:0]`; producers position by `addr[2:0]`.
- **Write positioning by replication.** Store data is replicated across
  the beat (`{8{byte}}`, `{4{half}}`, `{2{word}}`, dword pass-through) and
  the 8-lane strobe selects: `BYTE = 8'h01 << addr[2:0]`,
  `HALF = 8'h03 << {addr[2:1],1'b0}`, `WORD = addr[2] ? 8'hF0 : 8'h0F`,
  `DOUBLE = 8'hFF`. Replication keeps the data mux shallow (no
  byte-lane shifter) — the same shape the 32-bit tier uses today, one
  level wider.
- **Read extraction is uniform.** `load_unit` gains an `addr[2]` word
  select ahead of its existing half/byte selects; FLD consumes the full
  beat. The MMIO mux positions register values in their address-matching
  lanes so extraction needs no MMIO special case (a 32-bit register at
  offset +4 appears in lanes [63:32]).
- **Misalignment is unchanged.** The existing size-cased checks already
  implement the 8-byte class (`|addr[2:0]` for DOUBLE); a dword access
  never spans beats, so no crossing logic exists anywhere.

## Memory-side changes (M1.1)

- **`data_mem_request_router`**: all data ports `MemDataBits`, strobes
  `MemStrbBits`; AMO writes (word-sized until RV64A in M3) drive
  `addr[2] ? 8'hF0 : 8'h0F` with `{2{amo_data}}` instead of hardcoded
  `4'b1111`.
- **`cached_tier_adapter`**: beat width 64 — word select becomes the
  dword index `addr[4:3]` (4 dwords per 32 B line), wstrb placement
  `addr[4:3]*8 +: 8`. Line geometry and the single-outstanding contract
  are untouched (that is Phase 2).
- **dmem (BRAM tier)**: one 64-bit-wide byte-enabled BRAM at half depth.
  Init comes from a new `sw64.mem` (64-bit `$readmemh` tokens) emitted by
  the same objcopy step that produces `sw.mem`; `sw.mem` itself is
  unchanged (imem stays 32-bit-word organized for the predecode sideband,
  and every loader/image format stays 32-bit-word per the audit's
  keep-the-formats recommendation). The instruction-programming /JTAG
  Port A keeps its 32-bit face through a lane adapter (`addr[2]` steers
  the strobe nibble) so `load_software`/`file_to_ddr` are untouched.
- **MMIO**: `mmio_read_data` becomes 64-bit with lane positioning;
  32-bit register writes honor the strobe lanes (so the existing lo/hi
  word decodes keep working unchanged). The **CLINT** gains what RV64
  requires and rv32 can already verify: `mtime` at `+0xBFF8` is
  dword-aligned, so a 64-bit read returns the whole counter in one beat
  (single-copy atomic — no more hi/lo/hi loop tearing exposure) and a
  64-bit `mtimecmp` write lands atomically; the 32-bit lo/hi aliases
  remain as strobed half-writes with identical rv32 semantics. UART/FIFO
  registers are 32-bit-access-max, documented in the MMIO map (an SD to
  them writes the addressed word lanes only).
- **`FROST_XILINX_PRIMS`** FDRE loop already follows `$bits` (M0).

## Queue-side changes (M1.2)

- **LQ**: delete the FLD two-phase state (`fp64_phase`, the `+4` second
  beat, phase-advance/re-issue arms, response lo/hi steering); merge the
  split lo/hi data RAMs into one FLEN-wide RAM; the `is_fp &&
  MEM_SIZE_DOUBLE` conjunctions collapse to size-only tests (the audit's
  hazard list — un-gating these is exactly what RV64 LD reuses in M3).
  MMIO loads ride the same aligned-dword view.
- **`load_unit`**: input becomes the 64-bit beat; extraction order
  `addr[2]` word select → existing half/byte selects → existing
  sign/zero extension. FLD passes the beat through. (RV64 LW/LWU/LD
  semantics arrive in M3; at rv32 this is bit-identical behavior.)
- **`lq_l0_cache`**: dword-granule lines — index `addr[3 +: IW]`, 64-bit
  data, tag `addr[31:3+IW]` (D3 keeps tags physical-width). Fills come
  from full beats; stores/AMOs invalidate the containing dword
  (conservative for sub-dword stores — same policy as today, one
  granule coarser). FLD becomes L0-eligible for free.
- **SQ**: delete the FSD two-phase drain (`sq_fp64_phase`, `+4` leg, the
  completes-gate) and the "doubles fly alone" pipelining exclusion —
  DOUBLE joins the plain fast-drain; `gen_byte_en`/`gen_write_data`
  follow the bus contract above.
- **`sq_forwarding_unit`**: overlap model moves to dword granule —
  `store_off` becomes `addr[2:0]` (3 bits), byte masks 8-lane, image
  reconstruction shifts by `{store_off,3'b0}` up to 56, the
  size-compatibility matrix becomes: exact-dword forward
  (DOUBLE→DOUBLE), covered-subset forward for any load whose 8-lane mask
  is a subset of the store's, and the `double_hi_match` special cases
  disappear (a dword store fully covers both its words by construction).
  The hand-tiled equality comparators re-tile at `[31:3]` granule.
- **AMO/LR/SC**: word-sized semantics unchanged (RV64A is M3); only the
  strobe/lane positioning adapts. The reservation granule stays word for
  now (M3 widens it); the interrupt-shield/orphaned-write machinery is
  untouched in shape — `restore_window_stress` must pass unmodified.

## Verif mirror (M1.3)

`memory_model` driver/monitor takes 8-lane strobes + 64-bit data;
`memory_utils.calculate_byte_mask_for_store` gains the 8-lane forms;
`test_directed_multicycle`'s FLD lo/hi split-word modeling and
`test_directed_atomics` init patterns update to single-beat. All keyed
off `config` widths (M0 centralization).

## Gate (before M1 is done)

rv32, all green: rv32ud + rv32uf riscv-tests; arch F/D bram batches;
`fpu_assembly_test`, `ddr_test`, `ddr_heap_test`, `ddr_atomic_test`,
`ddr_smc_test`; torture (FLD/FSD-heavy) both tiers; `frost_cache` bench;
`restore_window_stress`; `directed_atomics` (CLI); LQ/SQ/L0 formal
targets re-proven (depths/timeouts re-measured per the audit's formal
budget warning); the Linux boot-health cocotb leg (CLINT compatibility);
plus a synthesis-only timing probe (Yosys UltraScale+ target) to size
the widened BRAM write cascade before M2's flip.

Documentation moving with this change: `hw/rtl/README.md` MMIO map
(CLINT 64-bit access + UART/FIFO 32-bit-max), `linux/README.md` counters
section (mtime single-copy-atomic 64-bit read), store_queue/load_queue
READMEs (two-phase sections retire), tomasulo README FP-phasing rows.
