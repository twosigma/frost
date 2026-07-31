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

# Phase 1 execution plan — RV64GCB

Execution plan for [ROADMAP Phase 1](../../ROADMAP.md): widen FROST from
RV32GCB to RV64GCB (still M/U-only, no MMU, FLEN=64, physical map unchanged
below 4 GiB). Grounded in the [XLEN=64 readiness audit](xlen_audit.md)
(365 findings against `main` @ `9b76e39`); read that document's verdicts
section first — two of its results shape this plan's spine.

Exit criteria (from the roadmap, made concrete in Milestone M8 below):
rv64 suites green in CI, an rv64 no-MMU Buildroot Linux boots in CI, X3
timing re-closed at 300 MHz post-route, and the rv32-configuration
keep-or-freeze decision recorded with measured costs.

## Strategy

1. **rv32 stays the referee until rv64 can testify.** Until rv64 suites
   run, the rv32 matrix is the only regression evidence, so every landing
   keeps rv32 CI green and rv64 capability accretes behind a build define.
   The roadmap's freeze-vs-maintain decision stays open at zero incremental
   cost until phase exit, when its true price (RTL generate branches + CI
   lanes) has been measured rather than estimated.

2. **The 64-bit data tier lands first, under rv32.** The audit refuted the
   assumption that FLD/FSD imply an 8-byte memory path: doubles are
   two-phase word pairs end-to-end, the AMO/reservation machinery is
   word-granular, and a phased 64-bit read of the rolling `mtime` counter
   tears — so RV64 requires a native 64-bit single-beat data tier
   regardless. That widening is XLEN-*independent*: FLD/FSD and the
   existing rv32 suites (riscv-tests rv32ud, arch F/D batches, torture,
   ddr_test/ddr_atomic_test, the frost_cache bench, LQ/SQ formal targets)
   exercise every widened structure. Landing it as its own rv32-green
   milestone (M1) removes the largest, most bug-prone RV64 dependency from
   the flip itself — and deletes the two-phase FSM complexity and its
   "doubles fly alone" drain restriction as a bonus.

3. **Substrate before semantics.** A behavior-preserving parameterization
   pass (M0) kills the audit's hazard classes — hardcoded sign-extension
   replication counts, 32-bit cause/overflow constants, `[31:0]` struct
   fields, XLEN-relative region decodes — while everything still runs
   rv32. Each fix is mechanically reviewable and the full rv32 matrix
   gates it.

4. **Then climb the ISA in test-suite rungs.** Decode+execute for one
   extension group at a time, each gated by its rv64 riscv-tests /
   arch-test batch before the next begins: I → B/K at 64 → M → A → F/D
   converts → C recode → CSR/trap surface → torture → programs → Linux.

5. **Timing risk is concentrated, not diffuse — and mostly avoidable.**
   The known-critical rename/wakeup/CDB structures are tag-indexed or
   already FLEN-wide: they do not change. The 64-bit exposure is (a)
   ALU/shifter/compare datapaths, (b) LQ/SQ address CAMs, (c) BTB tag
   compare, (d) AGU adders, (e) mul/div. The address-side exposure is
   neutralized by the canonicalization policy (D3): PCs and effective
   addresses are constrained to the sub-4-GiB physical space at their
   producers, so synthesis constant-sweeps the upper 32 bits of every
   downstream PC/address register, compare, and prediction RAM. What
   remains is the arithmetic datapath itself, probed early with
   synthesis-only runs (M1/M3 checkpoints) and closed for real at M8.

## Decisions

Numbered so later commits can reference them (e.g. "per D3"). Each is a
recommendation adopted by this plan unless a probe overturns it; overturning
one updates this file in the same change.

- **D1 — XLEN mechanism: build-time define, package remains the single
  source of truth.** `riscv_pkg` derives `XLEN` from a `FROST_RV64`
  preprocessor define (default off → 32). Module-level `parameter XLEN`
  defaults change from `32` to `riscv_pkg::XLEN` (the audit found the
  bare-32 defaults are a live footgun for standalone unit benches);
  `tomasulo_wrapper` has no XLEN parameter and bakes package structs into
  its ports, so per-instance dual-width elaboration is illusory — the
  define is the only honest dual-XLEN mechanism. Where RV32/RV64
  *semantics* differ (decode legality, RVC tables, CSR legality, misa),
  code branches on `XLEN == 64` in ordinary generate/ternary form. The
  define is plumbed through tests/Makefile (`COMPILE_ARGS`), the Yosys
  targets, formal `.sby` files, and the Vivado build as one switch.

- **D2 — Data tier: widen to native 64-bit single-beat.** 64-bit
  data buses and 8-lane byte enables end-to-end: SQ drain / LQ fill /
  router / cached_tier_adapter (dword lane select `addr[3+:...]`) / BRAM
  tier / MMIO. Delete the FLD/FSD two-phase FSMs, the `+4` second-beat
  legs, and the DOUBLE drain-pipelining exclusion. The CLINT gains native
  8-byte access at `mtime`/`mtimecmp` (single-copy-atomic, as RV64 Linux
  expects) while keeping the 32-bit lo/hi aliases for rv32 compatibility.
  UART/FIFO MMIO registers are declared 32-bit-access-max and documented as
  such in the MMIO map. dmem organization: decided at implementation
  between one 64-bit byte-enabled BRAM (needs a Port-A 32→64 lane adapter
  for the JTAG loader and a second `$readmemh` init format) and two
  interleaved 32-bit banks (keeps `sw.mem` and the loader byte-exact);
  bias toward whichever produces the smaller verified diff — the image
  *file formats* stay 32-bit-word either way (audit: they are memory-side,
  not XLEN-side). imem stays 32-bit-word organized (predecode sideband is
  per-word).

- **D3 — Addresses: full-width architectural state, producer-side
  canonicalization to the 4-GiB physical space.** CSRs that hold
  addresses (mepc/mtvec/mscratch/mtval) keep full 64-bit storage —
  arch-test privilege suites probe their WARL behavior against Spike, so
  masking *storage* risks signature mismatches. Instead, addresses are
  canonicalized where they become fetch/memory addresses: the PC-redirect
  producers (branch/JALR resolution, trap/mret targets entering the PC
  mux) and the AGU outputs mask bits [63:32] to zero. Consequences:
  every downstream PC register, BTB/RAS/L0 tag, ROB PC RAM, forwarding
  CAM, and region decode ([31:30] MMIO quadrant, bit-31 tier select) sees
  structurally-zero upper bits and synthesis sweeps them — the audit's
  address-side storage/timing growth largely evaporates, and the
  hand-tiled SQ comparators keep their current tiling. Region decodes are
  simultaneously fixed to physical-bit form (`addr[31]`/`addr[31:30]`,
  never `[XLEN-1]` — closing the `if_stage.sv:884` dead-guard hazard).
  Simulation-only assertions flag any nonzero [63:32] reaching the seams,
  so nonconformant software is caught loudly in sim instead of aliasing
  silently. Software that jumps to a non-canonical address observes
  aliasing rather than an access fault; a real fetch/access-fault path is
  deliberately deferred to Phase 3's PMA work.

  Why this is signature-safe against Spike (independently cross-checked
  against the vendored test-suite and toolchain sources): standard rv64
  codegen for this map is PC-relative (`-mcmodel=medany`, `la`, `auipc`),
  and both riscv-tests and riscv-arch-test form control-flow and data
  addresses that way, so with a canonical entry PC every suite-reachable
  address — including the ones landing in mtval on misaligned-access
  tests — is already sub-4-GiB positive and masking is the identity. RV64
  `lui` does sign-extend, but a bare `lui`-materialized DDR-region
  address is exactly the class that would raise an access fault on
  Spike's own memory map (nothing exists at 0xFFFFFFFF_8xxxxxxx), so no
  portable signature test can rely on it; gas's `li` pseudo materializes
  exact positive constants, so the boot shim's `li` addresses stay
  canonical (verified again at M7 as part of the shim review). Recorded
  invariant: the physical map stays below 4 GiB through Phase 1 (also
  pins cache-tier `ADDR_WIDTH=32` and the fixed `[31:0]` AXI wiring as
  documented contract, per audit).

- **D4 — Prediction storage: keep derived widths, rely on D3 sweeping.**
  No explicit tag/target compression work. If post-M3 synthesis probes
  show the BTB tag compare or LUTRAM growth surviving the sweep (they
  should not), revisit with explicit 32-bit stored targets.

- **D5 — Immediates: widen `from_id_to_ex_t` fields to `[XLEN-1:0]` and
  fix sign-extension in `immediate_decoder` (XLEN-relative replication
  counts).** One point of truth beats auditing every consumer for
  mandatory `signed'` casts; the cost (~160 flops/slot, wider RS payload)
  is inherent to carrying 64-bit immediates and lands inside the M0
  substrate where rv32 equivalence is checkable. The PD-stage B-immediate
  replications get the same one-line fixes.

- **D6 — `store_op_e` gains `STD` (widen to 3 bits, `STN` stays 0 for
  Verilator 2-state init).** The audit resolved the apparent conflict: the
  SQ data path keys on `mem_size_e` (already has `MEM_SIZE_DOUBLE`), so
  `STD` is decode/dispatch-side classification only. `instruction_type_decoder`
  additionally gains a double-word load class (LD must not classify as a
  word load).

- **D7 — Multiplier: rebuild as 65×65→128 via `dsp_tiled_multiplier_unsigned`
  plus a sign-correction wrapper, uniform latency.** The bespoke 33×33 unit
  retires. Pipeline depth becomes whatever closes 300 MHz (expect 5–6);
  `MulPipeDepth` in `int_muldiv_shim` is derived from a shared localparam
  exported by the multiplier, never hand-copied (audit hazard). MULW takes
  the same pipe (no early-out — variable latency breaks the shift-register
  tracker); result select becomes a tracked 3-way (low64 / high64 /
  sext-low32).

- **D8 — Divider: stay 2-bits/stage at 64 (33-cycle latency), W-forms
  share the 64-bit path with a tracked sext flag.** Uniform latency keeps
  the tracker simple. If the doubled per-stage subtract chain misses
  300 MHz, fall back to 1 bit/stage (65 cycles) rather than restructuring.

- **D9 — Dual-XLEN through the phase; fate decided at exit with measured
  costs.** rv32 CI lanes run unchanged throughout; rv64 lanes are added
  per milestone. At M8, record: lines of `XLEN==64` generate branching,
  CI wall-time of the dual matrix (~71 sim jobs today; dual roughly
  doubles), and the maintenance friction observed — then decide
  keep-dual / demote-rv32-to-nightly / freeze-rv32, and reword the docs'
  ISA claims accordingly.

- **D10 — Spike gets pinned into the Docker image.** A
  riscv-isa-sim build stage joins the Dockerfile so golden-reference
  regeneration (all arch-test + torture references, both XLENs) is
  containerized and reproducible. This unblocks and gates every rv64
  signature suite; the currently-unpinned host-Spike provenance is
  retired.

- **D11 — Signatures stay 4-byte/8-hex; references are namespaced per
  XLEN.** Matches riscv-arch-test granularity conventions and minimizes
  extractor churn; fixes the audit's reference-path collision
  (`rv64i_m/I/add-01` currently resolves to the rv32 golden). Torture's
  signature layout is re-derived for 64-bit GPRs (64 GPR words) in the
  same change as its rv64 generator config.

- **D12 — Linux: add an rv64 image alongside rv32; both boot lanes run
  during the phase.** rv64 defconfig derived from Buildroot's
  `qemu_riscv64_nommu_virt` (BR2_RISCV_64, uClibc + elf2flt bFLT — the
  upstream-precedented rv64-nommu userspace; verified in the vendored
  trees: `ARCH_HAS_BINFMT_FLAT` is unconditional for riscv, Buildroot's
  own riscv64-virt nommu kernel config uses `CONFIG_BINFMT_FLAT`, and
  nommu kernels default `RELOCATABLE`, i.e. PC-relative and
  D3-canonical). One watch item: Buildroot's arch config gates some
  hard-float ABI choices on MMU support, so whether userspace is lp64d
  or falls back to lp64 soft-float is confirmed when the defconfig is
  re-derived — the kernel side is unaffected either way. Kernel base
  config regenerated (CONFIG_ARCH_RV64I), rv64 DTS strings emitted by
  `build_fpga_boot.py`, the boot shim's address materialization verified
  per D3, `patch_linux_image.py`'s rv32-pinned byte offsets re-derived or
  gated off for rv64, `frost-stress` gains an `__riscv_xlen==64` counter
  path (single 64-bit `csrr`; counters-unavailable stays a FROST-side
  failure), and the QEMU lane runs `qemu-system-riscv64 -cpu rv64,mmu=off`
  (binary already in the image).

- **D13 — FreeRTOS demo freezes at rv32 during the phase.** Its
  FROST-local port (`port_frost_asm.S`, 4-byte context frames) needs a
  full sd/ld rewrite for rv64; not on the critical path. Ported at exit
  only if D9 resolves to keep-dual; otherwise its fate is decided with
  D9.

- **D14 — Custom `mperfdata`/`mperfdatah` keep the split 32-bit pair.**
  Custom CSR space, zero software churn; documented as a deliberate
  rv64 inconsistency with the architectural counters.

- **D15 — `mstatus.FS` gets a real (still minimal) implementation in
  M5.** The audit surfaced that FS is absent-hardwired-0 while F/D
  execute — a latent nonconformance that rv64 Linux with hard-float
  userspace actively depends on. Cross-checking the pinned 6.18.7 tree
  confirmed the exact mechanism: `fstate_save` saves FP state only when
  the trapped task's saved status shows FS==Dirty, and `fstate_restore`
  skips when FS==Off (`arch/riscv/include/asm/switch_to.h`), so
  *hardware Dirty-setting reflected into the trap-time mstatus image* is
  the load-bearing behavior — without it every task's FP context is
  silently never saved. Scheme: FS a writable 2-bit field, hardware sets
  Dirty on any FP-architectural-state write (FP regfile or fcsr), SD
  mirrors FS==Dirty at bit 63, **and FP instructions raise
  illegal-instruction when FS==Off** — the Off-trap is not optional:
  riscv-tests' machine-mode `csr` test asserts an `fsw` with FS clear
  either traps or has no effect (it is plausibly why `csr` sits in
  today's skip list; landing D15 is what makes it un-skippable on both
  XLENs). Verified by directed test, the un-skipped `csr` test, and the
  rv64 Linux boot itself. (This also retro-fixes the latent rv32
  exposure.)

## Workstreams and milestones

Workstreams are the units of review; milestones M0–M8 are the ordered
landing sequence on `main`, each with an acceptance gate. Standing gate for
*every* milestone: the full rv32 matrix (cocotb both tiers, riscv-tests,
arch, torture, formal, Yosys targets, Linux lanes) stays green.

### M0 — Substrate: XLEN-clean at rv32 (Workstream A)

The behavior-preserving parameterization pass over the audit's hazard +
mechanical inventory. Highlights: immediate_decoder/pd_stage replication
counts → XLEN-relative (D5, including the struct-field widening);
`IntMachine*` → XLEN-wide with the interrupt bit at `XLEN-1`; 64-bit
DIV-overflow constants added alongside the 32-bit ones; region decodes to
physical-bit form (D3 producer masks + sim assertions); module XLEN
defaults → `riscv_pkg::XLEN`; `c_ext_state`/aligner/`cpu_ooo.i_served_addr`
port widths; `cpu_tb` taps re-expressed in `riscv_pkg::XLEN`; the
`FROST_RV64` define plumbed through every build entry point (D1); verif
width constants centralized (one shared module replacing the ~16 private
`XLEN=32` copies feeding struct packers); `FROST_XILINX_PRIMS` FDRE loop
bound by `$bits`; retire-trace/hang-triage formats widened.

Gate: rv32 matrix green (bit-identical behavior expected); with
`FROST_RV64=1` the tree *elaborates* (Verilator lint + Yosys generic) even
though rv64 semantics are absent. Zero-width-replication cleanup is
explicitly optional (audit proved all pinned tools accept it) — done only
where touched anyway.

### M1 — 64-bit data tier, proven under rv32 (Workstream C)

D2 in full: buses/strobes widened, LQ/SQ single-beat DOUBLE (two-phase
FSMs deleted), forwarding matrix reworked at dword granule (3-bit store
offset, 8-lane masks, SD→LD/FLD exact-forward cases), L0 dword geometry,
AMO strobe derivation, CLINT 8-byte access, MMIO 64-bit read mux, dmem
reorganization + loader adapter, `memory_model`/`memory_utils` widened to
match.

Gate: full rv32 matrix green — with attention called to rv32ud, arch F/D
batches, `ddr_test`/`ddr_heap_test`/`ddr_atomic_test`, torture (FLD/FSD
heavy), `restore_window_stress` (its DDR-draining-SC shape exercises the
drain path), the frost_cache bench, and re-tuned `load_queue`/`store_queue`
formal targets (depth/timeout re-measured per audit). rv32 Linux boot lanes
green (CLINT alias compatibility). First synthesis-only timing probe
(Yosys UltraScale+ target + Vivado synth) to size the widened BRAM write
cascade and forwarding CAMs.

### M2 — First rv64 instruction retires (Workstreams B+E minimum)

Smallest end-to-end rv64 slice: `common.mk` march/mabi axis
(`rv64…/lp64d`) + `standalone_asm.mk` emulation + the 9 per-app
ARCH/ABI Makefiles parameterized; a hand-written rv64 asm smoke app
(W-op/LD/SD/shamt6 sanity, no libc) through the cocotb custom-program
flow; decode/ALU/load-unit minimum to run it (full WS-B lands in M3).
Predecode init generator consumed per-XLEN (C-table still rv32-shaped
until M4 — the smoke app avoids compressed code, built `-march=rv64i…`
no-C).

Gate: smoke app passes in cocotb under `FROST_RV64=1`; rv32 matrix green.

### M3 — RV64 integer ISA complete (Workstream B)

- Decode: OP-IMM-32/OP-32 arms, LD/LWU/SD, 6-bit shamt legality
  restructure (funct3=001/101 collision matrix per audit), ZIP/UNZIP →
  illegal, REV8 immediate re-key, ZEXT.H → PACKW alias, all four
  op-classification copies + dispatch mem_size/mem_signed/imm-select
  cases updated in lockstep — with the audit-recommended simulation
  assertions that convert silent-default misclassification into loud
  failures (e.g. any op with `mem_needs_lq/sq` must resolve a non-default
  `mem_size`).
- ALU: 64-bit shifts/rotates (6-bit shamt channel through decode → RS →
  shims), W-op family with single final sext mux, Zbs 6-bit indices,
  SEXT_B/H fixes, 64-bit ORC_B/REV8/BREV8/PACK, ctz64/cpop64 helpers,
  CLZW/CTZW/CPOPW; dead `ENABLE_MULDIV` legacy path deleted.
- M: D7 multiplier + D8 divider, shim trackers re-derived.
- A: LR.D/SC.D/AMO*.D decode + LQ AMO width bit (32-bit sub-ALU +
  sext for .W forms — a semantic fix for .W at 64), 8-byte reservation
  granule everywhere (sc_pending, wrapper snoop, LQ invalidate — audit
  lists the `[XLEN-1:2]` sites), wrapper `make_lq_alloc`/`make_sq_alloc`/
  `is_sc` classification extended.
- F/D: fp_convert decouples the integer width from XLEN at runtime — the
  op selects W vs L bounds (sign bit `XLEN-1` fix), W-form integer
  operands pre-extend into the XLEN datapath, and W-form results
  (including WU and FMV.X.W — RV64 semantic) sign-extend from bit 31
  inside the converter, so the shim consumes XLEN-correct rd values with
  no extra width flag; the 10 new convert/FMV ops thread through the
  classification expressions + stage-4 case + shim routing; FEQ/FLT/FLE
  boxing fix in `fpu_compare_unit` (the audit's `fp_add_shim` `.XLEN`
  override and LQ NaN-box concat findings were already resolved by M0's
  default-tracking and M1's beat extraction).
- Verif mirror (Workstream E, interleaved per rung): encoders (shamt6
  layout, W-op factories, AMO funct3 param), alu/branch/fp model widening
  (parametric to_signed/to_unsigned, 64-bit helpers, W evaluators,
  LW-sign-extends semantic), suite runners re-keyed (rv64 suites +
  re-derived skip lists — rv64ud `move` newly runnable as the
  FMV.X.D/FMV.D.X coverage; the rv32ud skip stays, that upstream test
  being RV64-only), reference namespacing + D10
  Spike-in-Docker + full golden regeneration, K-filter re-derivation
  (packw in, zip/unzip out).

Gate (cumulative, bram tier first then ddr): riscv-tests rv64ui → rv64um →
rv64ua → rv64uf/ud green; arch-test rv64 I/M/A/F/D/B/K/Zicond batches
green; branch-unit and id_stage cocotb suites extended with
64-bit-discriminating vectors (audit's vacuous-pass list). Second
synthesis-only timing probe (64-bit ALU/mul/div in place).

### M4 — RV64C recode (Workstream D)

The five-site lockstep recode: `rvc_decompressor` (C.ADDIW, C.LD/C.SD/
C.LDSP/C.SDSP with 8-scaled immediates, C.SUBW/C.ADDW, 6-bit C-shamts,
reserved-rd checks), `riscv_pkg::imem_compressed_control` +
`imem_rvc_source_hot`, the aligner's `slot1_branch_compressed`,
`frontend_validity_tracker`'s classifier, `ras_detector`'s C.JAL gate, and
the offline generator `generate_imem_predecode_init.py` — plus regenerated
Vivado init images. Unit-test policy: RV32-reserved-now-valid vectors are
replaced by positive RV64 vectors (decompressor/aligner/predecode/
ras_detector suites per the audit's inverted-test list); the
RTL-vs-Python cross-checks and the independently-derived fast-replica
model are re-derived from the RV64 spec, not copy-pasted.

Gate: rv64uc + arch C batch green; predecode/decompressor/aligner/
ras_detector cocotb suites green with the new positive vectors; rv32
equivalents still green (dual C-table per D1/D9).

### M5 — CSR/trap/counter surface (Workstream F)

misa (MXL=2, correct letter set), mstatus 64-bit rebuild (UXL=2 hardwired,
SD at 63, D15 FS implementation), mcause bit-63 plumbing end-to-end
(constants landed in M0; trap_unit/formal properties verified), counters as
single 64-bit CSRs with `*h` addresses illegal at every privilege (csr_file
read mux + the ROB `ucounter_onehot` addr[7] re-restriction + mcounteren
gate unchanged for the base three), mepc/mtvec write masks reviewed under
D3, sw `csr.h`/`trap.h`/`limits.h` widened (`unsigned long` accessors,
`MCAUSE_INTERRUPT_BIT` at `__riscv_xlen-1`, rd*64 single-csrr on rv64),
umode_test/csr gating matrix rewritten for rv64 semantics (base counters
gated by mcounteren; `*h` trap unconditionally).

Gate: rv64mi + arch privilege batch green; directed traps + umode_test
rv64 variants green; the riscv-tests `csr` skip re-evaluated now that
D15's FS lands (expected: un-skippable on both XLENs); formal
csr_file/trap_unit targets re-proven at 64.

### M6 — Randomized + program-level convergence

Torture rv64 (generator config, 64-bit signature layout per D11, new
Spike goldens), cocotb real-program suite at rv64 both tiers (isa_test
rv64 expectations fork, c_ext_test rv64 variant, new W-op/LD/SD/AMO.D
directed apps registered in `TEST_REGISTRY`), coremark/coremark-pro
rebuilt lp64d (stack/ROM budgets re-measured per audit's link.ld note),
`cpu_random`/multicycle registry notes updated. FreeRTOS demo marked
rv32-only per D13.

Gate: torture rv64 green both tiers; full program suite green both tiers
at rv64; rv32 matrix still green.

### M7 — rv64 no-MMU Linux (Workstream G)

D12 in full. Bring-up order: QEMU rv64 boots the image first (validates
kernel/userspace/DT independent of RTL), then cocotb bounded boot-health
(the 22M-cycle checkpoint regression re-baselined for rv64), then
hardware. `restore_window_stress` re-run at rv64 (sret comes in Phase 3;
the M-mode window shape is unchanged but W-op/64-bit restore images are
new). Both Linux lanes (rv32 + rv64) in CI.

Gate: `linux-boot-qemu` (rv64) asserts `FROST_USERSPACE_STRESS_PASS` +
login prompt + counter deltas present; `linux-boot-cocotb` (rv64) reaches
its checkpoint; rv32 lanes unaffected.

### M8 — Timing closure, hardware, and the exit decision (Workstream H)

Full X3 Vivado place+route at 300 MHz (per the Vivado run policy this is
the feature-final run; interim probes were synthesis-only), WNS ≥ 0;
iterate on the audit's predicted hot cones (BRAM write cascade, forwarding
CAMs, branch-target equality, divider stages) as needed. Genesys2: build
attempted; if the 64-bit datapath does not fit/close at 133 MHz on the
~69%-full Kintex-7, Genesys2 is documented rv32-only pending a slimming
side-quest — this plan treats rv64 as X3-first and does not gate the phase
on Genesys2. Hardware: 10-boot rv64 soak on X3 via `linux_boot_soak.py`;
`hw_regression.py` BASELINE_SCORES reset to None at the switchover and
re-recorded from phase-exit hardware runs; README utilization/CoreMark
tables regenerated. Record the D9 decision with measured costs; update
ROADMAP Phase 1 to done; sweep the audit's documentation-staleness list
(README ISA claims, per-module READMEs' latency/phasing/reservation text,
sw/CONTRIBUTING templates, linux/README ABI - ISA string, counter section).

Gate = the roadmap exit criteria, plus: every audit finding is either
closed by a commit or explicitly recorded as deferred-with-rationale in
this directory.

## Verification additions beyond the mirrored matrices

Directed coverage the mirrored suites don't guarantee (tracked as new
cocotb tests/apps as each area lands): W-op sign-extension corners
(negative 32-bit results into 64-bit rd), LW-vs-LWU extension, shamt
32–63 boundary set, SLLIW-with-bit-25 illegal, C.ADDIW-vs-C.JAL decode
(including rd=0 reserved), C.ADDIW-not-a-RAS-call regression, compressed
negative-offset PD-redirect (the audit found the compressed arm has zero
coverage today), LR.D/SC.D granule (SC.W-vs-LR.D pairing, snoop kills
across the dword), AMO*.W sext at 64, FCVT.L rounding/saturation corners,
FEQ-writes-exactly-0-or-1 at 64-bit rd, NaN-box checks for FCVT.S.L/LU,
counter `*h`-illegal traps from both privileges, mcause bit-63 interrupt
classification, mtime 8-byte single-copy-atomic read (torn-read
regression), 64-bit-discriminating branch-compare vectors, and D3 seam
assertions (no nonzero [63:32] reaches fetch/memory).

## Risks and watch items

- **Coverage debt in the giant files.** load_queue/store_queue/RS/wrapper
  were audited grep-driven; M1/M3 implementation re-reads surrounding
  logic as it changes, and the loud-assertion policy (M3) is the backstop
  for what grep missed.
- **Suite-runner drift.** The skip/filter tables are re-derived (not
  renamed) per audit — several rv32 skips invert meaning at rv64.
- **Formal budgets.** LQ/SQ/csr_file/trap_unit state grows; depths and
  `SBY_TASK_TIMEOUT_S` re-measured at M1/M5 rather than discovered flaky.
- **Yosys/CI wall time.** The UltraScale+ synthesis lane already measures
  ~2750 s against a 3600 s timeout; re-budget after the first rv64
  synthesis. Dual CI lanes roughly double ~71 sim jobs — acceptable during
  the phase, revisited at D9.
- **Genesys2 fit.** Explicitly non-gating (M8).
- **lp64 stack/ROM growth.** link.ld budgets re-measured in M6.
- **`instr_op_e` enum ordinals.** id_stage's cocotb bench pins ordinals;
  new ops are appended (documented append-only discipline) and the bench
  table is regenerated in the same commit.

## Working agreements for this phase

- Every landing keeps the rv32 matrix green; rv64 gates accrete per
  milestone. Feature branches per milestone (or finer), landing to `main`
  sequentially.
- Documentation moves with each change (repo policy); the audit's
  staleness inventory is the checklist, M8 sweeps the remainder.
- Line-referenced audit findings are checked off in commit messages by
  content, not line number (the tree drifts).
- Timing evidence: synthesis-only probes at M1/M3 checkpoints; the one
  full place+route at M8 per the Vivado run policy.
