# FROST RTL

FROST's synthesizable SystemVerilog: an out-of-order RV64GCB CPU with a
2-wide IF/PD/ID front-end, Tomasulo scheduling across six function units, and
precise 2-wide in-order commit. The core takes M/S/U-mode traps with delegation
(Phase 3), translates through Sv39 (an 8-entry ITLB in IF, a 16-entry DTLB on
the data side, and one read-only page-table walker shared by both), and has
separate instruction and data memory ports. It is RV64-only
(`riscv_pkg::XLEN == 64`; rv32 support was retired at the end of Phase 1).

Pipeline width is asymmetric. Fetch, decode, rename, ROB allocation, result
writeback, and commit move up to two instructions or completions per cycle.
Most reservation stations issue one operation; INT_RS feeds two ALU pipes,
with branches restricted to pipe 0. The two-lane CDB grants the highest-priority
two FU completions, while aligned plain stores bypass it. Both lanes provide
same-cycle resident wakeup (`LANE1_ISSUE_BYPASS` defaults on). Six reservation
stations can issue concurrently, or seven operations including INT_RS's second
port, but execution is not fully symmetric two-issue.

The RTL is intended to stay portable: the core uses generic SystemVerilog and
is built in CI with Verilator for simulation plus Yosys for vendor-agnostic
coarse synthesis checks. Full board synthesis is currently Xilinx-focused and
lives under `fpga/` and `boards/`.

`frost.f` is the source of truth for file ordering and inclusion.

## Top-Level Shape

```
frost.sv
  cpu_and_mem.sv
    instruction RAM  <---- JTAG/software-load port on clk_div4
    data RAM (low 256 KiB BRAM, 1-cycle)
    fetch_provider -> two-line L1I fetch buffer (cached fetch @ 0x8000_0000)
    cached tier @ 0x8000_0000 (1 GiB), frost_cache_hierarchy:
      data: cached_tier_adapter -> L1D (128 KiB BRAM) -----------------------\
      walker: PTW -----------------------------------------\                 arbiter ->
      instr: L1I (16 KiB BRAM, read-only) ------------------ arbiter -------/
        [L2 (2 MiB URAM data + packed tags, X3)] -> line_port_axi_bridge -> DDR AXI port
           (behavioral DDR model in sim; board DDR controller on hardware)
    MMIO timer/UART/FIFOs
    debug/: JTAG TAP -> DTM -> debug module -> slice writer (programming port)
    cpu_ooo.sv
      IF -> PD -> ID -> 2-wide dispatch
                         ROB / RAT / RS / LQ / SQ / CDBx2
                         FU shims around ALU, MUL/DIV, FPU
                         2-wide commit -> INT/FP regfiles
  UART clock-domain crossing FIFOs
```

The front-end stages are IF, PD, and ID:

| Stage | Main Files | Role |
|-------|------------|------|
| IF | `cpu_and_mem/cpu/if_stage/` | 64-bit fetch window, PC control, BTB + bimodal direction predictor + RAS, staged slot-2 BTB lookup, RVC parcel alignment, slot-2 RVC decompression (per-candidate, in the aligner) |
| PD | `cpu_and_mem/cpu/pd_stage/` | Slot-1 RVC decompression, instruction selection, PD-stage computed-target redirect for predicted-taken conditional BTB misses, early source extraction and narrow source-hot timing bypasses |
| ID | `cpu_and_mem/cpu/id_stage/` | Decode, immediate generation, branch target precompute, CSR address/zimm extraction (the CSR read/write itself fires at commit), two registered dispatch packets |

The BTB supplies targets while a 1024-entry bimodal direction predictor trains
from committed conditional branches. IF carries the direction and its index;
PD computes `PC + imm` for a predicted-taken conditional BTB miss. When a
taken lookup redirects ahead of an older compressed packet, IF recovers the
predict-time index from the pending prediction's exact owner PC so the delayed
branch still trains the row it originally read.

The PD boundary keeps late controls off carry chains without another stage. At
an odd-halfword PC, IF forms a native spanning candidate; compressed
instructions use their raw parcel. This keeps the size sideband out of PD's
branch-target adder. Format-specific helpers reduce each target cone to a
13-bit low sum and `{immediate sign, low-add carry}`; the redirect edge captures
that state beside PC-high `{H,H+1,H-1}` banks for shallow reconstruction. The
same edge captures only the branch/direction redirect payload. The
BTB/RAS/bubble/fault vetoes already registered in the PD-to-ID packet qualify
the visible redirect in one LUT; its bubble bit also masks a raw wrong-path
candidate after a redirect, without changing the redirect cycle.

Slot-2 early-source addresses register raw payload bits and clear synchronously
for bubbles, flushes, and PD redirects, so invalid slots expose x0 without a
final IMEM-data NOP mux. Per-word sideband carries `{rs2[1], rs1[2:1]}` for
each RVC halfword. IF aligns these bits and PD substitutes them into the five
timing-sensitive source fields. Instruction and early-source views remain
bit-identical; latency and throughput are unchanged.

Slot-2 BTB data is read from the live fetch PC one cycle ahead and registered
beside the instruction-memory request. Three single-address images hold the
+2, +4, and index-rotated +2 entries. Payloads use block RAM, while full tags
use staged distributed RAM so their comparisons launch from FFs instead of
block-RAM outputs. The rotated image supplies the next-word +2 case without an
`A+1` RAM address on the fetch-PC cone; full tags reject aliases, and same-edge
writes forward the complete replacement entry. BTB target payloads are 32
bits: a target-valid row restores the upper bits from its exactly matched
branch or predecessor PC, so control flow that crosses a 4-GiB region is a
BTB miss.

Slot-2 redirects take same-cycle priority over a younger live slot-1 BTB
prediction, killing its PC handoff and metadata. A registered redirect bubble
quarantines any colliding slot-1 holdoff, which clears on the first delivered bubble. BPC
establishes live slot-1/slot-2 BTB alias ownership from the one-hot +2/+4
candidate before the full slot-2 packet-valid gate. This keeps late packet
shape and served-window qualification out of live BTB selection; authoritative
slot-2 validity is restored before either a redirect or a live-hit transfer.
The RAS is deliberately outside this ownership boundary because it classifies
an older, registered instruction. A real older call still pushes while a
younger slot-2 redirect proceeds, and an older return preempts that younger
redirect so its pop and target remain atomic.

Because the older RAS operation commits on the edge that captures the younger
IF bundle, both younger slots carry its post-operation `{tos, valid_count}` as
their recovery entry state. A later recovery therefore retains an older call
and does not resurrect an older return. A globally blocked timing candidate
may still look owner-like, but it cannot clear the registered direction/index
snapshot; only an emitted slot 2 or an enabled one-wide pending-owner case can.

On the first live response after an unstalled fetch-invalid gap, variable
latency can collapse the lookup lead until the live slot-1 PC names the branch
already emitted in slot 2. An unstaged live BTB hit can then transfer to that
emitted slot, preserving its redirect and direction metadata instead of
attaching them to the following packet. Bare PC equality is insufficient:
fixed-latency BRAM normally has the same equality as its one-request lookahead.
At fixed lead, only a taken live alias becomes candidate-owned by slot 2. An
agreeing staged image has already redirected; a staged miss or disagreement
resolves normally and does not turn the redundant live lookup into a future
slot-1 owner. The +2 image covers the staged base and successor word index,
while +4 covers the staged base index only; any other non-collapsed
relationship is a BTB miss. These covered cases add neither redirect latency
nor a bubble.

When a slot-1 prediction must wait for `pc_reg` to walk older instructions, its
one-deep saved metadata is tagged with the exact branch PC. This matters for a
slow low-BRAM response: the served-window carve-out can emit the immediately
preceding instruction with the prediction holdoff open, but an owner-PC
mismatch keeps that predecessor unpredicted and preserves the saved metadata
until the branch packet itself arrives (including through stall replay). The
predecessor also keeps its paired predict-time direction bit/index. Releasing
that packet opens the registered redirect hold for `pc_reg` on the same edge,
so the predecessor cannot be dispatched once, left at the current PC, and then
dispatched again after a variable-latency served-window retry. A retry that
rejects the release also freezes the halfword-crossing witness with `pc_reg`,
so the pending owner cannot skip the still-owed predecessor. When an
unblocked, non-buffer-stale exact owner is already present in a covering window
on the first pending-active prediction-holdoff cycle, it atomically emits with
the registered taken metadata and applies the target handoff, avoiding both a
bubble and a later duplicate replay. A blocked first owner instead saves that
metadata and replays it after the normal readiness handshake. The pending-owner
bundle is always one-wide: an owner that appears in predecessor slot 2 remains
withheld, and once the owner reaches slot 1 its sequential sibling is
wrong-path even if stale bytes classify slot 1 as non-control. One common gate
applies that rule to the slot-2 packet, staged prediction eligibility, and PC
advance.

The fetch providers expose PC-critical size, pairability, and slot-2-start
timing replicas in physical `{odd,even}` word order. Low BRAM supplies those
registered parity lanes directly; the cached provider converts its positional
`{word1,word0}` values on the same edge that captures the payload. The aligner
therefore selects provider and `pc_reg` word parity in one LUT, without a
post-Q bank-select mux on the served-window recurrence.

The served-window guard validates packet shape as well as current-word
presence. A lagging `S=P-1` window may emit an unbuffered high-parcel RVC
one-wide. High-parcel native or buffered packets retry because they require
`P+1`, preventing predecessor bytes from supplying a spanning half or slot 2.
For a post-prediction buffer release, the guard's late buffer qualification
selects only its final MUXF8. The aligner supplies a factored no-buffer
served-last verdict to the earlier MUXF7: PC-low accepts the served last word
unconditionally, while PC-high accepts it only for a compressed high parcel.
This is exactly the portion of packet-size qualification observable when the
buffer select is low; when it is high, the verdict is irrelevant. Thus
`prediction_holdoff` no longer traverses the aligner's size mux before the
coverage decision.

If recovery temporarily requests the containing word below a high-half
architectural target, a registered resteer witness blocks that preceding low
parcel's BTB row through provider gaps and NOP holdoffs. It also neutralizes
the preceding parcel's direction result: a conditional target carries a
conservative not-taken bit and its own predict-time index. After the real
target bundle emits, the existing +2 sequential arm restores the normal fetch
lead in one cycle without adding a wide PC comparison.

After ID, `tomasulo/dispatch/dispatch.sv` allocates Tomasulo resources for one
or two instructions per cycle and sends work to
`tomasulo/tomasulo_wrapper/tomasulo_wrapper.sv`. The wrapper owns the ROB,
RATs, reservation stations, load/store queues, CDB arbiter, FU shims, and
profiling counters, with private glue modules under `tomasulo_wrapper/`. See
[cpu/README.md](cpu_and_mem/cpu/README.md)
and [cpu/tomasulo/README.md](cpu_and_mem/cpu/tomasulo/README.md) for the detailed
backend notes.

## Directory Map

| Path | Status | Notes |
|------|--------|-------|
| `frost.sv` | In use | Chip-level wrapper around CPU/memory and UART/FIFO CDC |
| `frost.f` | In use | Authoritative RTL file list |
| `cpu_and_mem/` | In use | CPU, RAMs, MMIO timer/UART/FIFO interface |
| `cpu_and_mem/imem_predecode.sv` | In use | Instruction RAM with 64-bit fetch (even/odd interleaved BRAM banks, each split at no extra block-RAM cost into 28 cold data bits plus the frontend-hot word bits `{15,10,7,6}`), word-local class/bundle and RVC source-hot predecode sideband, a five-lane block-RAM replica of the raw high-parcel bits `C[15]`, `C[13]`, `C[12]`, `rd==x2`, and `AllowsSlot2AfterHi`, plus a pinned `[0, 16 KiB)` per-parity scalar LUTRAM overlay (with output FFs) for every sideband predicate on the IF PC feedback cone: `IsCompressedLo/Hi`, `EvenLocalPairValid`, `PairableNativeLo`, `PairableCompressedHi`, `PairableNativeHi`, and `Slot2StartValidLo`. Overlay windows retain the normal one-cycle response. A window crossing or above 16 KiB repeats once while those seven predicates are redecoded from the reconstructed raw words into the same scalar-bank output FFs; the canonical full-depth sideband BRAM remains the same-edge oracle but never drives those PC lanes. Live programming writes quarantine fetch readiness until the canonical word and registered slow predicates realign. |
| `cpu_and_mem/low_bram_fetch_presenter.sv` | In use | One-entry low-BRAM request presenter: repeats the exact VA/PA/fault bundle for a slow metadata response, cancels it when a registered retarget invalidates the owed request, and holds or identity-suppresses publication across the front end's registered stall/replay cadence. A leading slot-1 prediction preserves its still-owed branch response before launching the target. |
| `cpu_and_mem/imem_predecode_line.sv` | In use | Per-line word-local predecode (the `riscv_pkg::imem_make_sideband` shared source) for L1I fill data |
| `cpu_and_mem/fetch_provider.sv` | In use | High-address fetch provider: two-line L1I fetch buffer with owed-ask tracking, unaccepted-PC-movement redirect detection plus a separate landed recovery/already-emitted-prediction/resteer and trap/xRET/FENCE epoch retarget, edge-aligned registered readiness/tag validation, one line fill in flight per slot (the window's line and the following line fill concurrently, tagged with the slot number), a six-line victim store behind the slots that copies a re-entered line back in one cycle instead of an L1I round trip, and fence.i invalidate |
| `cpu_and_mem/plic.sv` | In use | Platform-level interrupt controller (PLIC spec 1.0, Phase 3 M6) at `0x4400_0000`: two sources, M and S contexts for hart 0, level-sensitive gateways, destructive claim read. See [Memory Map](#memory-map) |
| `cpu_and_mem/hang_triage.sv` | In use | On-silicon boot-hang classifier (`ENABLE_HANG_TRIAGE`, default 0): when the console UART goes quiet it streams a state snapshot (commit count, timer state, cached read/write debt, recent PCs) over the UART and re-emits it periodically |
| `cpu_and_mem/debug/` | In use | RISC-V Debug Spec 0.13.2 transport and module (Phase 3 M3): `jtag_tap` (generic 5-bit-IR TAP for simulation and portable synthesis), `dtm_core` (dtmcs/dmi with the sticky-busy rule, TCK<->core toggle-handshake CDC, a BSCAN-style pin bundle so the boards' BSCANE2 chains drive it), `debug_module` (halt/resume/step, abstract GPR access, an 8-word program buffer with impebreak, abstractauto, ndmreset; no system bus), `debug_slice_writer` (lands the module's words in the low BRAM through the div4 programming port and mirrors Debug-Mode stores into the instruction copy). See [Debug](#debug) |
| `cpu_and_mem/cpu/cpu_ooo/` | In use | CPU integration top (`cpu_ooo.sv`) and glue modules for register files, front-end validity, branch recovery, commit, pipeline control, memory routing, redirects, and performance counters |
| `cpu_and_mem/cpu/tomasulo/` | In use | ROB, RAT, RS, LQ, SQ, 2-lane CDB, dispatch glue, FU shims. Larger modules nest helper submodules: `tomasulo_wrapper/{perf,commit_bus,dispatch_routing,store_addr,atomics}/`, `store_queue/sq_forwarding_unit`, `load_queue/{load_unit,lq_l0_cache,lq_issue_selector}`, `reservation_station/rs_issue2_selector`, `reorder_buffer/rob_serializer` (see the per-module READMEs) |
| `cpu_and_mem/cpu/if_stage/`, `pd_stage/`, `id_stage/` | In use | Reused front-end stages |
| `cpu_and_mem/cpu/mmu/` | In use | Sv39 translation: `dtlb` (fully associative, superpage-aware; instantiated as the 16-entry DTLB and the 8-entry ITLB), `dmmu` (data-side translation stage inside the wrapper, bypassed combinationally while translation is off), `immu` (Bare bypass and the tagged fetch translation in `if_stage`), and `ptw` (read-only walker, Svade, one walk at a time over the hierarchy's walker port). There is no ASID tagging: `sfence.vma` and `satp` writes flash-clear both TLBs |
| `cpu_and_mem/cpu/csr/` | In use | CSR file: Zicsr/Zicntr, fcsr, the M and S CSR sets with `medeleg`/`mideleg`, `satp`, and the debug CSRs |
| `cpu_and_mem/cpu/wb_stage/generic_regfile.sv` | In use | Parameterized INT/FP regfiles for OOO commit |
| `cpu_and_mem/cpu/ex_stage/` | In use | Shared ALU, multiplier/divider, FPU, and `branch_jump_unit.sv` used by the OOO core and FU shims |
| `cpu_and_mem/cpu/control/trap_unit.sv` | In use | M/S/U exception/interrupt handling with delegation (traps taken in M or S) |
| `lib/` | In use | Portable RAM/FIFO/stall helper primitives, plus `lib/cache/` (the `frost_cache` hierarchy, AXI bridge, and behavioral DDR model), `lib/ram/sdp_ram_byte_en.sv` (row-granular byte-enable RAM with a selectable block/ultra primitive backing the cache data arrays), and `lib/ram/sdp_packed_tag_uram.sv` (width-generic packed UltraRAM tags for the X3 L2) |
| `peripherals/` | In use | UART TX/RX blocks |

## Memory Map

The low BRAM memory is 256 KiB (95 KiB ROM + the 1 KiB debug slice + 160 KiB
RAM in the unified linker script); the data port additionally reaches a
1 GiB cached region served by the cache hierarchy:

| Region | Address | Size | Description |
|--------|---------|------|-------------|
| ROM | `0x0000_0000` | 95 KiB | Code and read-only data (fast BRAM) |
| DEBUG | `0x0001_7C00` | 1 KiB | Debug-module execution slice (park loop, abstract-command and program-buffer words); reserved by every linker script, written only by the debug module |
| RAM | `0x0001_8000` | 160 KiB | Data, BSS, stack (fast BRAM) |
| MMIO | `0x4000_0000` | 112 KiB | UART/FIFOs/timer; plus Linux-facing ns16550a UART (`0x4000_1000`) and SiFive CLINT (`0x4001_0000`) |
| PLIC | `0x4400_0000` | 4 MiB | Platform-level interrupt controller (M and S contexts for hart 0; sources: 1 = ns16550, 2 = the board's external-interrupt pin) |
| DDR | `0x8000_0000` | 1 GiB | Cached region: code (`.ddr_text`), heap and large data (see below) |

The whole MMIO window is one strongly ordered I/O region: same-hart accesses
anywhere in it complete in program order with no fences required. The load
queue hands an ROB-head MMIO request to the data-memory router, whose
one-entry hold always stages the device read for one cycle and then keeps it
parked until every committed store has drained. A full flush can cancel
that staged request before terminal accept; the router's pending Q tells the
LQ that no response debt remains. A device read also spends one cycle arming
behind the device-read interrupt shield, so interrupt delivery is held before
the irrevocable read fires and cannot duplicate it (the load queue README
gives the argument). This ordering is a platform contract rather than an ISA
default: the CLINT window aliases the native timer registers at second
addresses, and both bare-metal apps and Linux's relaxed MMIO accessors depend
on cross-address same-device ordering.

The cached tier serves both sides of the core: loads and stores through the
data L1, and instruction fetch through a dedicated 16 KiB L1I
(`L1I_CACHE_BYTES`) fed by `fetch_provider`'s two-line fetch buffer. The
buffer keeps one fill in flight per slot, so the window's line and the
following line fetch concurrently, and it keeps the lines the slots replace in
a six-line victim store, so a loop body of up to eight lines re-enters without
an L1I round trip. Every line port carries a transaction id (the tagged line
protocol in [lib/cache/README.md](lib/cache/README.md)). A tree of two 2:1
`line_port_arbiter` instances (fixed priority D > walker > I, no grant lock)
merges the L1D, page-table walker, and L1I ports into the single downstream
port consumed by the full-system L2. The lower-level hierarchy module retains
an L1-only topology for focused unit coverage, where the same port connects
directly to the DDR bridge. Each level prefixes its port index to the ids, so
requests from all three sources can be in flight together.

Low-BRAM fetch windows wholly below 16 KiB stay one-cycle; other low-BRAM
windows repeat once to register their PC predicates. The fixed-seed default
low-memory CoreMark runs retain their exact timed tick counts across this
split. Every MMIO handoff first spends one cycle in the router hold and one
further cycle arming behind the device-read interrupt shield, may wait more
cycles while committed stores drain, and returns one cycle after terminal
accept. Cached accesses complete by handshake with variable latency: an L1
hit in a few cycles, a miss after a writeback/fill round trip through
`frost_cache` and, on X3, an L2 with URAM data plus four-way packed URAM
tags. `frost_cache` is direct-mapped with 32 B lines, write-back and
write-allocate, and non-blocking: an L1 read hit returns
`DATA_READ_LATENCY + 1` cycles after its fire, L1 hits stream one per cycle
past misses held in `NUM_MSHR` miss-status slots, and a store is acknowledged
once the L1D has ordered it, with a write miss merging into its fill. The L2
serializes requests through its three-cycle tag lookup before reaching the
DDR AXI port, whose `line_port_axi_bridge` keeps any number of tagged
transactions in flight with the line ids as AXI ids. `cached_tier_adapter`
converts CPU beats to cache lines and keeps up to
`riscv_pkg::CachedLoadSlots` tagged loads plus one store in flight, queueing
read responses behind the fast tier's fixed-latency beat.
`data_mem_request_router` folds the handshake completions into the LQ/SQ
ordering gates so reads never pass an in-flight write; its registered pending
Q also feeds directly back into the LQ bus-busy gate while a device read is
parked.

Stores publish code via `fence.i`: the ROB serializer drains the store
queue, then holds commit while the hierarchy writes back every dirty L1D
line and invalidates the L1I, in that order, so an instruction fill racing
the sync cannot survive with stale data. The commit's flush pulse then drops
the fetch buffer before the refetch. The caches re-invalidate on any reset
(tag sweep), so a JTAG program reload never observes stale lines.
`ENABLE_CACHED_TIER=0` omits the hierarchy: cached-region accesses complete
with zero data and fetch falls back to the low-BRAM-only path.
The full-system hierarchy always includes the 2 MiB L2 used by X3, and
`USE_BEHAVIORAL_DDR=0` routes the bridge's AXI master to the top-level
`o_ddr_axi_*` ports for the board DDR controller instead of the simulation-only
behavioral model.

MMIO registers:

| Address | Name | Description |
|---------|------|-------------|
| `0x4000_0000` | UART_TX | UART transmit write |
| `0x4000_0004` | UART_RX_DATA | UART receive read, pops one byte |
| `0x4000_0008` | FIFO0 | MMIO FIFO channel 0 |
| `0x4000_000C` | FIFO1 | MMIO FIFO channel 1 |
| `0x4000_0010` | MTIME_LO | Machine timer low word |
| `0x4000_0014` | MTIME_HI | Machine timer high word |
| `0x4000_0018` | MTIMECMP_LO | Timer compare low word |
| `0x4000_001C` | MTIMECMP_HI | Timer compare high word |
| `0x4000_0020` | MSIP | Machine software interrupt pending |
| `0x4000_0024` | UART_RX_STATUS | Bit 0 is data available |
| `0x4000_0028` | UART_TX_STATUS | Bit 0 is can accept byte |
| `0x4000_1000`–`101C` | ns16550a UART face | 16550 register file (word stride) aliasing UART_TX/RX for the Linux 8250 driver |
| `0x4001_0000` | CLINT MSIP | SiFive CLINT alias of MSIP |
| `0x4001_4000`/`4004` | CLINT MTIMECMP_LO/HI | SiFive CLINT alias of MTIMECMP |
| `0x4001_BFF8`/`BFFC` | CLINT MTIME_LO/HI | SiFive CLINT alias of MTIME |

The PLIC window (`0x4400_0000`, spec register layout: per-source priorities,
pending, per-context enables at `0x2000 + 0x80*ctx`, threshold and
claim/complete at `0x20_0000 + 0x1000*ctx`) carries both external-interrupt
lines: the machine context drives `mip.MEIP` (the ns16550 interrupt reaches
the core only through the PLIC as source 1) and the supervisor context ORs
into the `mip.SEIP` readback beside the M-mode software-injection bit. The
claim read is destructive and rides the same router device-read shield as
the UART RX pop.

### Debug

The RISC-V debug module (Debug Spec 0.13.2, `cpu_and_mem/debug/`) halts,
inspects, patches, steps and resumes the hart over JTAG. Its transport is
the generic five-bit-IR TAP on `frost`'s `i_jtag_*` pins in simulation and
the portable synthesis targets, and two BSCANE2 USER chains on the FPGA's
own TAP on the boards (`boards/`, `fpga/debug/` for the OpenOCD side).

Debug Mode is a third take class in the trap unit beside the M and S
interrupt classes: a halt request (dmcontrol.haltreq, or the single-step
completion) is latched, armed and taken with the same store-drain wait and
AMO / device-read shields as an interrupt, saves `dpc`/`dcsr` in the CSR
file, installs M privilege, and redirects to the park loop at the top of the
debug slice; `dret` returns through the xRET path. Interrupts are masked in
Debug Mode and while a step is armed; `ebreak` enters Debug Mode when the
matching `dcsr.ebreak{m,s,u}` bit is set; exceptions raised in Debug Mode
re-park the hart without touching any CSR (that is how a debug command
ends, or fails with cmderr 3). Abstract GPR accesses execute as
instructions the module writes into the slice (`csrw`/`csrr` through the
`ddata` CSR, the hart's view of data0/data1); the program buffer follows
them, and the module's `go` redirect starts a command or the resume word.

The slice lives in the low BRAM because the instruction copy of that RAM is
written only through the div4 programming port: `debug_slice_writer` drives
that port when the JTAG loader is idle, and in Debug Mode it also mirrors
every low-BRAM store into the instruction copy (a read-back of the data
copy's row, written to the instruction copy only), so software breakpoints
and debugger loads into BRAM code are fetchable. OpenOCD executes `fence.i`
from the program buffer before every resume and after every memory write,
which publishes debugger writes to DDR code through the existing cache sync.
With the module idle nothing changes architecturally: the Bare-mode
benchmark tick counts are unchanged, and the debug CSRs
(`dcsr`/`dpc`/`dscratch0`/`dscratch1`/`ddata`) and `dret` are illegal
outside Debug Mode.

### Data-tier bus contract

Every data-side bus below the load/store queues (BRAM tier, cached tier,
MMIO, router, adapter responses) moves one aligned 64-bit beat per
transaction (`riscv_pkg::MemDataBits`) with an 8-lane byte strobe
(`MemStrbBits`): the beat is the dword at `addr[31:3]`, and byte lane *i* is
byte address `{addr[31:3], i}`. Producers position by `addr[2:0]` and
consumers extract by `addr[2:0]`:

- Store data is replicated across the beat (`{8{byte}}`, `{4{half}}`,
  `{2{word}}`, dword pass-through) and the strobe selects the lanes:
  `BYTE = 8'h01 << addr[2:0]`, `HALF = 8'h03 << {addr[2:1], 1'b0}`,
  `WORD = addr[2] ? 8'hF0 : 8'h0F`, `DOUBLE = 8'hFF`
  (`riscv_pkg::mem_strobe_for`). Replication keeps the write-data mux
  shallow; there is no byte-lane shifter.
- Reads return the full beat; `load_unit` selects the word by `addr[2]`,
  then the half/byte, then sign- or zero-extends. FLD/LD consume the beat.
- MMIO registers appear in their address-matching lanes, so extraction
  needs no MMIO special case (a 32-bit register at offset +4 sits in lanes
  [63:32]).
- A dword access never spans beats, so no crossing logic exists; the
  size-cased misalignment checks cover the 8-byte class (`|addr[2:0]`).
- The L0 cache and store-to-load forwarding work at dword granule, and the
  data BRAM's `$readmemh` image is the dword-paired `sw64.mem`
  (`sw/common/make_dword_mem.py`); every other image and loader format
  stays 32-bit-word.
- Cached-tier loads are tagged: the load queue names one of its
  `riscv_pkg::CachedLoadSlots` slots on each cached launch, the adapter
  carries that id on the line port, and the response returns it
  (`is_cached` + slot id beside the beat), so several cached loads are in
  flight at once and complete in any order. Low-BRAM and MMIO loads keep
  the untagged fixed-latency response, which owns the response port in its
  cycle; a cached response arriving that cycle waits in the adapter.

The MMIO bus rides this contract. The dword-aligned CLINT pairs support
native 64-bit access: an 8-byte load of `mtime` (`0x4001_BFF8`) returns the
whole counter single-copy-atomically, and an 8-byte `mtimecmp` store lands
atomically (the 32-bit lo/hi aliases keep their word semantics). UART and
FIFO registers are 32-bit-access-max: a wider store writes only the
addressed word lanes.

The hardware UART console is configured for 115200 baud, 8 data bits, no
parity, and 1 stop bit (8N1).

For no-MMU Linux, the same UART is also reachable through a standard
ns16550a register face at `0x4000_1000` (word stride; device-tree
`reg-shift=2`, `reg-io-width=4`; `earlycon=uart8250,mmio32`), and the timer
through a SiFive-CLINT-compatible window at `0x4001_0000` (`mtimecmp` at
`+0x4000`, `mtime` at `+0xBFF8`). Both alias the native registers listed
above onto the same hardware, so the in-tree Linux 8250 console and CLINT
timer drivers work without a board-specific driver.

If these addresses change, update `cpu_and_mem.sv`, `cpu_ooo.sv` parameters,
`sw/common/link.ld`, `sw/lib/include/mmio.h`, and the verification constants in
`verif/config.py`. The debug slice's location is `riscv_pkg::DebugSliceBase`;
every linker script under `sw/` reserves it as the `DEBUG` region.

## Build and Simulation

From the repo root (simulation and synthesis checks run in the pinned
container via the wrapper; Vivado builds run natively):

```bash
# Cocotb/Verilator simulation
./scripts/frost.py cocotb hello_world
./scripts/frost.py cocotb tomasulo_test
./scripts/frost.py cocotb --list-tests    # show all registered tests

# Open-source RTL synthesis checks
./scripts/frost.py synthesis

# Vivado FPGA builds
./fpga/build/build.py x3
```

The top-level simulation file list is `frost.f`; the CPU build file list is
`cpu_and_mem/cpu/cpu_ooo/cpu_ooo.f`.

## Parameters

| Module | Parameter | Default | Description |
|--------|-----------|---------|-------------|
| `frost.sv` | `CLK_FREQ_HZ` | `300000000` | Main CPU clock frequency |
| `frost.sv` | `MEM_SIZE_BYTES` | `2 ** 18` | 256 KiB low BRAM |
| `frost.sv` | `SIM_TIMER_SPEEDUP` | `1` | Multiplies `mtime` increment rate for simulation |
| `frost.sv` | `CACHED_BASE` | `32'h8000_0000` | Cached-region base address |
| `frost.sv` | `CACHED_SIZE_BYTES` | `32'h4000_0000` | Cached-region size (1 GiB) |
| `frost.sv` | `ENABLE_CACHED_TIER` | `0` | 1 instantiates the cache hierarchy (simulation enables via `-G`; boards enable with their DDR controller) |
| `frost.sv` | `L1_CACHE_BYTES` / `L1I_CACHE_BYTES` / `L2_CACHE_BYTES` | `128 KiB` / `16 KiB` / `2 MiB` | Data L1, instruction L1I, and L2 cache sizes |
| `frost.sv` | `USE_BEHAVIORAL_DDR` | `1` | 1 ends the tier in the simulation-only DDR model; 0 exports the bridge's AXI master on `o_ddr_axi_*` |
| `frost.sv` | `DDR_MODEL_BYTES` / `DDR_MODEL_LATENCY` | `64 MiB` / `30` | Behavioral DDR model size and access latency (simulation) |
| `frost.sv` | `FETCH_VALID_FUZZ` | `0` | Simulation-only: 1 wraps the low BRAM in a variable-latency fetch model (LFSR fetch-valid gaps) that mirrors the L1I provider's fetch contract; hardware keeps 0 |
| `cpu_ooo.sv` | `MMIO_ADDR` | `32'h4000_0000` | MMIO base |
| `cpu_ooo.sv` | `MMIO_SIZE_BYTES` | `32'h2C` | MMIO range size; `cpu_and_mem.sv` overrides to `32'h1_C000` (covers the ns16550a face + CLINT alias) |

Simulation overrides parameters through Verilator generics (`-G`): the test
Makefile enables the cached tier with the X3 hierarchy shape by default
and sets the behavioral DDR model's size/latency and the low BRAM's 256 KiB
hardware size (`SIM_MEM_SIZE_BYTES`). The focused cache unit benches still
drive `frost_cache_hierarchy` directly with `-GHAS_L2={0,1}` to cover its
generic optional topology, while selected fetch-fuzz program runs use a
separate `-GFETCH_VALID_FUZZ=1` build.

## Notes for RTL Changes

- Keep `frost.f` and nested `.f` files authoritative.
- Prefer generic RTL over vendor primitives in the core.
- Update the root README, this file, and the relevant submodule README when
  changing architecture-visible behavior.
- Run Verilator tests for functional changes and Yosys/formal checks for shared
  blocks where practical.

## License

Copyright 2026 Two Sigma Open Source, LLC

Licensed under the Apache License, Version 2.0.
