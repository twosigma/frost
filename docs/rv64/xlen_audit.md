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

# XLEN=64 readiness audit

Point-in-time audit of everything that must change — or would silently
misbehave — if `riscv_pkg`'s `localparam XLEN` were flipped from 32 to 64.
Audited tree: `main` @ `9b76e39` (2026-07-28). Line numbers reference that
commit and have drifted as Phase 1 landed; the finding descriptions are written
to stay locatable by content.

This document was the working inventory for
[Phase 1 of the roadmap](../../ROADMAP.md), now complete — the execution
plan that sequenced it is [`phase1_plan.md`](phase1_plan.md). Scope: RV64GCB
(+Zicntr/Zifencei/Zicond/Zbkb/Zihintpause), still M/U-only, no MMU, FLEN
stays 64, physical memory map unchanged (sub-4-GiB).

**Method.** Fifteen subsystem auditors swept every RTL, verification,
software, and build file (plus four gap-fill auditors dispatched by a
completeness pass); three adversarial verifiers attacked the load-bearing
"already 64-bit-ready" claims; findings are cited as `file:line` against the
audited commit. Every finding is classified:

- **hazard** — compiles clean at XLEN=64 and silently misbehaves at runtime.
  The most valuable class; there are 106 of them.
- **design** — new logic or semantics (W-ops, RVC recode, 64-bit mul/div,
  CSR legality, …).
- **policy** — needs a project decision before code changes.
- **mechanical** — width/literal/comment hygiene fixed by parameterization.

Totals: **365 findings** — 106 hazard, 104 design, 31 policy, 124
mechanical. Coverage caveat from the completeness pass: the largest files
(`load_queue.sv`, `store_queue.sv`, `reservation_station.sv`,
`tomasulo_wrapper.sv`, `cpu_ooo.sv`) were audited by targeted (grep-driven)
reading rather than line-by-line; residual risk concentrates exactly where
findings are already densest, so implementation work in those files should
re-scan surrounding code as it lands.

## The three load-bearing verdicts

**1. "FLD/FSD exist, so the 8-byte LD/SD data path below dispatch is
already there" — REFUTED.** The entire memory system below the queues is
32-bit-per-transaction with 4-bit byte enables: FLD/FSD are synthesized by
two-phase state machines in the LQ/SQ that issue two independent word
transactions (`store_queue.sv:30/356/370/761`, `load_queue.sv:29`). The
load-side phase machinery is `is_fp`-gated at ≥6 sites, so an integer
`MEM_SIZE_DOUBLE` load would silently complete with a zero-extended low
word; the INT result-return path is structurally 32-bit at four formatting
sites; the word-granular L0 would serve a bogus single-word hit for an INT
dword; the AMO datapath and LR/SC reservation granule are word-wide; and the
CLINT is architected as lo/hi word pairs, so a phased 64-bit `LD` of the
rolling `mtime` counter would tear (RV64 software does single 8-byte CLINT
accesses and does not guard against tearing). What *is* already 64-bit: MEM
RS payloads, SQ entry storage and the forward payload struct, LQ entry
lo/hi halves, the CDB, and the 8-byte misalignment checks. Consequence: the
data tier below the queues must be widened to native 64-bit single-beat —
two-phase reuse is not a viable RV64 fallback — and this widening is
XLEN-independent, provable under the existing rv32 suites (see the plan's
Workstream C).

**2. "Integer results ride FLEN=64 carriers end-to-end with
correct-at-64 extension points" — HOLDS with exceptions.** Every carrier
struct and RAM (RS src values, CDB, ROB value, RAT lookup, commit, regfile
buses) is FLEN-wide, extension points are the identity-at-64
`{{(FLEN-XLEN){1'b0}}, x}` idiom, and no double-extension exists. The
exceptions are localized: `int_muldiv_shim.sv` hard-codes the 32-bit
MUL/DIV datapath widths (operand capture, product, result select — all
being rebuilt for RV64M anyway), and the four FLW NaN-boxing concatenations
in `load_queue.sv` (`{32'hFFFF_FFFF, xlen_data}`) silently drop the box at
XLEN=64.

**3. "Front-end PCs widen coherently; only prediction storage has explicit
widths" — HOLDS, with the exception list inverted.** The in-core front end
(pc_controller, if_stage datapath, aligner handoff, all five prediction
structures) is XLEN-parametric — BTB tag/target widths are *derived*
(`TagBits = XLEN-9`), so prediction storage widens automatically; the cost
is LUTRAM growth and a 23→55-bit tag compare, not recode. The real porting
boundary is the fetch seam: `fetch_provider.sv` is a wholesale
hardcoded-32 island, `cpu_and_mem.sv` truncates the PC at the instantiation
boundary, and bit 31 doubles as the cached-tier select. One semantic
hazard: `if_stage.sv:884` guards a served-window desync check with
`pc_reg[XLEN-1]` meaning "cached region" — at XLEN=64 bit 63 is never set,
the guard silently dies, and the exact boot-Oops class it was added to stop
returns. There is no hardcoded reset vector (PC resets to `'0`).

## Cross-cutting facts established empirically

- **Zero-width replication is a non-issue.** `{{(FLEN-XLEN){1'b0}}, x}`
  with FLEN=XLEN=64 was tested against every pinned tool: Verilator 5.050
  (`-Wall` clean), Yosys 0.64 (clean; SAT proves exact pass-through),
  Verible (clean), Vivado 2025.2 xvlog (clean) and synth_design (benign
  `Synth 8-693` warning, correct netlist). The ~15 sites flagged across
  subsystems are cosmetics; rewrite as `FLEN'(x)` casts only for a
  warning-free Vivado log.
- **The pinned container toolchain is rv64-ready.** xPack
  riscv-none-elf-gcc 15.2.0-1 ships `rv64imafdc_zicsr_zaamo_zalrsc/lp64d`
  multilibs; `qemu-system-riscv64` is already in the image.
- **Spike is now pinned in the container** [resolved]. At audit time every
  arch-test/torture golden came from an unpinned host Spike, gating rv64
  reference regeneration; the Dockerfile has since gained a pinned
  riscv-isa-sim build, so reference regeneration (both XLENs) is
  containerized and reproducible.
- **Reference-path collision:** `rv64i_m/I/add-01.S` resolves to the
  committed *rv32* golden signature today (`test_arch_compliance.py:196`
  keys references by extension + stem only).

## Top hazard clusters (what actually bites on a bare XLEN flip)

1. **Sign-extension replication counts hardcoded for 32-bit results** —
   `immediate_decoder.sv` (all I/S/B/J/U formats), `pd_stage.sv` (both
   PD-redirect immediate arms). Every negative immediate, backward-branch
   target, and LUI with bit 19 set silently zero-extends. The single
   highest-blast-radius hazard class.
2. **mcause interrupt bit baked at 31** — `IntMachine*` constants,
   `trap_unit`, sw `csr.h`, verif checks. Every interrupt would read as a
   giant synchronous exception; self-consistent constants mean sim and
   formal stay green while Linux misroutes every interrupt.
3. **RVC C-table reinterpretation** — C.JAL→C.ADDIW (decompressor + 3
   sideband/classifier copies + the offline Python generator + ras_detector,
   which would push a garbage RAS entry on every C.ADDIW),
   C.FLW/C.FSW/C.FLWSP/C.FSWSP→C.LD/C.SD/C.LDSP/C.SDSP (8-scaled
   immediates, integer regfile), C.SUBW/C.ADDW/shamt6 un-reserving.
4. **5-bit shamt truncation** — ALU shifts/rotates/Zbs indices, both int
   shims, the encoder's `(sh & 0x1F) | (f7 << 5)` packing, and the verif
   ALU model. Shift amounts 32–63 silently alias 0–31 everywhere.
5. **32-bit DIV/REM special-case constants** — INT_MIN/-1 and div-by-zero
   detection silently stops firing at 64 (RTL and Python model both).
6. **Word-shaped address comparators** — the SQ/forwarding hand-tiled
   comparators ignore diff bits above [29]/[31]; `lq_l0_cache`'s
   XLEN-relative MMIO decode makes MMIO cacheable at 64; `sq_forwarding`'s
   2-bit store offset misplaces bytes in a 64-bit image.
7. **Counter CSR surface** — cycleh/timeh/instreth (and mcycleh/minstreth)
   must become illegal; the ROB's `ucounter_onehot` deliberately aliases
   addr[7] so they'd stay mcounteren-gated-legal; `csr_file` returns
   `[31:0]` slices of the 64-bit counters; the just-landed frost-stress
   counter phase reads `0xc80-0xc82` and would silently report
   `counters=unavailable` on rv64 while still printing PASS.
8. **Silent-default classification whitelists** — the op-classification
   lists exist 4× (id_stage slot-1/slot-2 + sim-only pkg helpers) plus
   dispatch's mem_size/imm-select cases; any of the ~45 new ops missed in
   any copy dispatches as a no-dest RS_INT op and "completes" without
   executing. The audit recommends assertion guards to convert these to
   loud failures during bring-up.
9. **Test suites that would pin wrong behavior** — `test_ras_detector`
   asserts C.JAL-classifies-as-call (green against un-recoded RTL);
   decompressor tests assert C.SUBW/shamt6 are illegal; branch-unit vectors
   all fit in 32 bits (vacuous pass if a comparator stays [31:0]). The
   recode policy is: RV32-reserved-now-valid vectors are *replaced by
   positive RV64 vectors*, never deleted.

---

# Findings by subsystem

Each subsystem section opens with the auditor's summary, then findings
grouped hazard → design → policy → mechanical.

## instruction decode + riscv_pkg types

The decode subsystem splits cleanly into three risk tiers. Tier 1 (silent-wrong hazards on a bare XLEN flip): immediate_decoder's sign-extension replications are hardcoded to 32-bit results ({20{}}/{19{}}/{11{}} and the U-type concatenation), so at XLEN=64 every negative I/S/B/J immediate and every LUI/AUIPC with bit 31 set zero-extends — and these wires feed branch_target_precompute directly, corrupting every backward branch/JAL precomputed target; riscv_pkg's from_id_to_ex_t immediates are hardcoded [31:0] and get silently truncated at the id_stage pipeline register; the interrupt-cause constants bake the mcause interrupt bit at 31; and the 32-bit DIV-overflow magic constants stop matching 64-bit operands. Tier 2 (accept-when-must-trap): ZIP/UNZIP and the RV32-form REV8 immediate would still decode as valid on RV64 because instr_decoder contains zero XLEN references — no widening pass will touch it. Tier 3 (loud missing decode): instr_decoder is a strict whitelist (every unmatched encoding hits o_illegal), so LD/LWU/SD, the .D atomics, all W-ops, FCVT.L forms, FMV.X.D/D.X, and 6-bit shamts simply trap today — safe, but the shamt6 restructure has real encoding-collision complexity in the funct3=001/101 families. The most dangerous integration hazard is the 4-way duplication of op-classification whitelists (id_stage slot-1 + slot-2 + eight riscv_pkg sim-only helpers): any of the ~45 new instr_op_e members missed in any copy silently defaults to RS_INT/no-dest/no-sources, e.g. an LD dispatching to the integer RS and 'completing' without touching memory. instruction_type_decoder additionally needs a double-word load class (LD would silently classify as a 32-bit word load; LWU works by accident), and store_op_e is full at 2 bits and needs an STD member with STN kept at 0. branch_target_precompute is the one genuinely clean-parametric file, contingent on the immediate fix. Parameter plumbing is verified live: cpu_ooo passes riscv_pkg::XLEN down the whole id hierarchy.

### Hazards (compile-clean, silently wrong at XLEN=64)

- **`hw/rtl/cpu_and_mem/cpu/id_stage/immediate_decoder.sv:43`** [high] I/S/B/J sign-extension replication counts are hardcoded for 32-bit results ({20{...}} at L43-45 and L49-51, {19{...}} at L56-63, {11{...}} at L72-79) while outputs are [XLEN-1:0]. At XLEN=64 each 32-bit concatenation ZERO-extends into the 64-bit output, so every negative immediate is silently corrupted (e.g. imm=-4 becomes 64'h00000000_FFFFFFFC). These wires feed branch_target_precompute directly (id_stage.sv L197-199), so every backward branch/JAL target, ras_expected_rs1, and btb_expected_rs1 goes wrong; the XLEN'(signed') casts in branch_target_precompute are no-ops on already-64-bit inputs and cannot repair this. Fix: replication counts must be XLEN-12/XLEN-13/XLEN-21 (e.g. {{(XLEN-12){i_instruction.funct7[6]}}, ...}).
  - *Action:* Parameterize all sign-extend replication counts on XLEN
- **`hw/rtl/cpu_and_mem/cpu/id_stage/immediate_decoder.sv:67`** [high] U-type: o_immediate_u_type = {i_instruction[31:12], 12'h0} is exactly 32 bits and zero-extends into the 64-bit output. RV64 LUI/AUIPC sign-extend bit 31 to XLEN, so any LUI with imm[19]=1 (e.g. lui x,0x80000) silently produces a positive 64-bit value instead of a sign-extended negative one.
  - *Action:* Change to {{(XLEN-32){i_instruction[31]}}, i_instruction[31:12], 12'h0}
- **`hw/rtl/cpu_and_mem/cpu/riscv_pkg.sv:927`** [high] from_id_to_ex_t immediate_i/s/b/u/j_type are hardcoded logic [31:0] (L927-931) while immediate_decoder outputs and all other datapath fields are [XLEN-1:0]. At XLEN=64, id_stage L834-838/L1523-1527 silently truncate 64-bit wires into these 32-bit fields. All five formats DO fit in 32 signed bits, and at least one consumer (ex_stage/branch_jump_unit.sv:83) already applies XLEN'(signed'(...)), so keep-32+sign-extend-at-every-use is viable — but any consumer that zero-extends instead breaks silently. Needs an explicit decision plus an audit of every field reader.
  - *Action:* Decide widen-to-XLEN vs keep-[31:0]-with-mandatory-signed-extension; audit all consumers either way
- **`hw/rtl/cpu_and_mem/cpu/riscv_pkg.sv:742`** [high] IntMachineSoftware/Timer/External = 32'h8000_0003/7/B (L742-744) bake the mcause interrupt bit at bit 31. On RV64 the interrupt bit is bit 63; if these bit[31:0] constants are assigned/compared against a 64-bit mcause they zero-extend with bit 63 clear, so interrupts would be silently reported as (nonexistent) synchronous exceptions with huge cause codes. Compile-clean, wrong at runtime.
  - *Action:* Rebuild as {1'b1, (XLEN-2)'0, cause} or widen to XLEN with the interrupt bit at XLEN-1
- **`hw/rtl/cpu_and_mem/cpu/riscv_pkg.sv:808`** [high] SignedInt32Min/SignedInt32Max/UnsignedInt32Max/NegativeOne are bit[31:0] magic constants used for DIV/REM overflow and divide-by-zero special cases. At XLEN=64, equality of a 64-bit operand against zero-extended 32'h8000_0000 NEVER matches INT64_MIN and (a == NegativeOne) never matches 64-bit -1, so the DIV/REM overflow path silently stops firing. 64-bit counterparts (SignedInt64Min etc.) are needed for native ops; the 32-bit ones are still needed for DIVW/REMW.
  - *Action:* Add 64-bit variants; re-audit every use site (ALU/divider) for which width applies
- **`hw/rtl/cpu_and_mem/cpu/riscv_pkg.sv:1419`** [medium] Comment in reorder_buffer_alloc_req_t documents the dispatch pattern value={{FLEN-XLEN{1'b0}}, link_addr}. At XLEN=64, FLEN-XLEN=0 → zero-width replication (legal SV inside a concatenation but a per-tool lint hazard; this repo runs Verilator 5.050 + Yosys 0.64 which differ on it). The actual code lives in dispatch (another agent's file) but this comment is the contract statement and goes stale — every {{FLEN-XLEN{...}}} occurrence must be rewritten as FLEN'(...) or guarded.
  - *Action:* Rewrite the documented pattern (and comment) as a width cast; grep-sweep FLEN-XLEN repo-wide
- **`hw/rtl/cpu_and_mem/cpu/riscv_pkg.sv:1851`** [medium] Sim-only (`ifndef SYNTHESIS) helpers get_rs_type/has_int_dest/has_fp_dest/uses_fp_rs1/uses_fp_rs2/uses_fp_rs3/uses_int_rs1/uses_int_rs2 (L1851-2084) enumerate ops by whitelist with defaults. Every new RV64 op omitted from a list silently falls to the default (RS_INT, no dest, no source) in simulation-side classification, diverging from the synthesized inlined copies in id_stage. ZIP/UNZIP must also be dropped. Also stale doc: L1394 comment says mcause interrupt bit is 'bit 31'.
  - *Action:* Extend all eight helper lists in lockstep with the id_stage inlined copies; fix L1394 comment
- **`hw/rtl/cpu_and_mem/cpu/id_stage/instr_decoder.sv:134`** [medium] ZIP (L133-135) and UNZIP (L156-159) are RV32-only Zbkb encodings but would still decode as valid on RV64 — the core would silently execute nonexistent instructions instead of trapping. Nothing about flipping XLEN changes this decoder (it has no XLEN reference), so this is an explicit edit that will be missed by a pure-widening pass.
  - *Action:* Make ZIP/UNZIP decode o_illegal=1 on RV64
- **`hw/rtl/cpu_and_mem/cpu/id_stage/instr_decoder.sv:152`** [medium] REV8 decodes as funct7=0110100, rs2=11000 (imm 011010011000) — that is the RV32 encoding. The RV64 REV8 immediate is 011010111000 (funct7=0110101, rs2=11000). As written, RV64 code's REV8 traps illegal AND the RV32-only encoding is silently accepted. BREV8 (rs2=00111, same funct7 block) is encoding-stable across XLEN.
  - *Action:* Move REV8 match to funct7=0110101 on RV64; make the 0110100+11000 form illegal
- **`hw/rtl/cpu_and_mem/cpu/id_stage/instruction_type_decoder.sv:80`** [high] Load class flags have no double-word class: o_is_load_byte/o_is_load_halfword (L80-83) plus implicit 'word otherwise'. Once LD (funct3=011) decodes, it classifies as a WORD load here — silently truncating 64-bit loads to 32. LWU (110) accidentally classifies correctly (not byte/half + funct3[2]=1 via o_is_load_unsigned at L84 -> word, unsigned). An o_is_load_double output (or a 2-bit size) is required, and downstream consumers of these flags must map to MEM_SIZE_DOUBLE. Also RV64 LW must be treated as SIGNED word (funct3[2]=0 already gives that).
  - *Action:* Add double-word load classification output and plumb through from_id_to_ex_t
- **`hw/rtl/cpu_and_mem/cpu/id_stage/id_stage.sv:834`** [medium] The [XLEN-1:0] immediate wires (L82-86, L866-870) are registered into the hardcoded [31:0] from_id_to_ex_t fields at L834-838 and L1523-1527 — a silent truncation at XLEN=64. Benign only if the keep-32+signed-extend-at-use policy is adopted AND immediate_decoder is fixed (truncating a correctly sign-extended 64-bit value to 32 preserves all information for these formats); otherwise a live bug. Pairs with the riscv_pkg L927 finding.
  - *Action:* Resolve together with from_id_to_ex_t immediate-width decision
- **`hw/rtl/cpu_and_mem/cpu/id_stage/id_stage.sv:382`** [high] The pre-decoded operand-classification case lists exist FOUR times (slot-1 L382-660, slot-2 L1100-1376, plus the two sim-only pkg helper sets) and are whitelists with silent defaults. Every new RV64 op missed in any copy silently gets rs_type=RS_INT, no dest, no sources — e.g. an LD absent from the RS_MEM list (L424-436/L1142-1154) dispatches to the integer RS as a no-dest op and 'completes' without loading; a MULW absent from RS_MUL (L418-422) does the same. Required insertions: RS_MEM += LWU/LD/SD/LR_D/SC_D/AMO*_D; RS_MUL += MULW/DIVW/DIVUW/REMW/REMUW; RS_INT += all W-ALU/W-shift/Zba.UW/Zbb-W ops; is_int_store (L471/L1189) += SD; has_int_dest (L529-569/L1246-1287) += all of the above with int rd plus FCVT_L_*/FMV_X_D; has_fp_dest/uses_fp_rs1 += FCVT_S_L(U)/FCVT_D_L(U)/FMV_D_X (int rs1!)/FMV_X_D (fp rs1); uses_int_rs2 (L634-659/L1350-1375) += W R-type ops, SD, SC_D, AMO*_D; ZIP/UNZIP removed from all lists (L411/L550/L650/L1129/L1268/L1366).
  - *Action:* Update all four copies in lockstep; consider generating them from one table to kill the divergence risk

### Design work (new logic or semantics)

- **`hw/rtl/cpu_and_mem/cpu/riscv_pkg.sv:766`** [medium] store_op_e is a FULL 2-bit enum {STN,STB,STH,STW}; SD needs a new member and the enum must widen to 3 bits with STN kept at 0 (Verilator 2-state init requirement). Note FSD today routes as STN + 'FP64 store unit' (instr_decoder.sv L329-332), so SD could alternatively reuse that 64-bit store path — but the flag would then not say 'store nothing' for a real store, so a proper STD member is cleaner.
  - *Action:* Widen enum to bit[2:0], add STD, keep STN=0; update every store_op_e consumer
- **`hw/rtl/cpu_and_mem/cpu/riscv_pkg.sv`** [resolved] The planned RV64 instruction-operation members have landed, while ZIP and UNZIP remain named but decode illegal at XLEN=64. The resulting 207 ordinals occupy 0..206. `instr_op_e` now has an explicit unsigned, two-state `bit [7:0]` base instead of the implicit 32-bit `int`, preserving every ordinal while shrinking all packed carriers.
  - *Resolution:* `InstrOpWidth=8` is shared by the RS payload and verification mirrors; enum-parsing benches accept both implicit and explicit bit/logic bases.
- **`hw/rtl/cpu_and_mem/cpu/riscv_pkg.sv:74`** [medium] opc_e has no OP-IMM-32 (7'b0011011) or OP-32 (7'b0111011) members; all RV64 W-form ALU decode needs them (and pd/if predecode class functions elsewhere compare raw 7-bit literals that may also need these opcodes classified).
  - *Action:* Add OPC_OP_IMM_32 and OPC_OP_32 to opc_e
- **`hw/rtl/cpu_and_mem/cpu/riscv_pkg.sv:640`** [medium] CsrCycleH/CsrTimeH/CsrInstretH (0xC80-0xC82, L640-642) and CsrMcycleH/CsrMinstretH (0xB80/0xB82, L646/648) must become ILLEGAL CSR addresses on RV64, and cycle/time/instret/mcycle/minstret become single 64-bit CSRs. The constants likely survive for the illegality check, but their '(high 32 bits)' comments and every CSR-file consumer change. mcounteren (L655) stays a 32-bit CSR — no change here.
  - *Action:* Keep addresses for illegal-decode; rework CSR module legality and comments
- **`hw/rtl/cpu_and_mem/cpu/riscv_pkg.sv:717`** [medium] mstatus bit-position localparams are RV32-only (comment says so): MstatusMieBit/MpieBit/MppLo/MprvBit keep their positions on RV64, but SD moves 31->63 and UXL appears at [33:32] (reads 2, can be read-only) — neither has a constant here. misa MXL moves to [63:62] (no misa layout constant in this package; CSR module owns it).
  - *Action:* Add MstatusSdBit=63, MstatusUxlLo=32 constants for the CSR module
- **`hw/rtl/cpu_and_mem/cpu/id_stage/instr_decoder.sv:119`** [high] 6-bit shamt legality: SLLI/BSETI/BCLRI/BINVI (L119-122, funct3=001) and SRLI/SRAI/BEXTI/RORI (L142-145, funct3=101) decode on FULL funct7 equality, so instruction bit 25 (shamt[5]) set falls to default:o_illegal. On RV64 these must match funct7[6:1] only. This is entangled with same-funct3 encodings that keep full-funct7/rs2 decode (ORC_B 0010100+rs2=00111 at L146-149, REV8/BREV8 at L150-155, ZIP/UNZIP 0000100+rs2=01111, CLZ/CTZ/CPOP/SEXT_* under 0110000 at L123-131 which collides with RORI's 011000x range on funct3=001... actually 0110000 funct3=001 is the Zbb unary block vs RORI funct3=101) — the case restructure needs a careful collision matrix. W-form shifts (new OP-IMM-32 arm) keep 5-bit shamt with bit 25 set ILLEGAL.
  - *Action:* Restructure shift-family decode to funct7[6:1] for native forms; keep full-funct7 for W-forms and unary/byte ops
- **`hw/rtl/cpu_and_mem/cpu/id_stage/instr_decoder.sv:216`** [high] OPC_LOAD arm (L216-224) lacks funct3=011 (LD) and funct3=110 (LWU) — both currently trap illegal (loud, not silent). LW (L220) keeps its enum but its SEMANTICS change on RV64 (sign-extend 32->64), which is a load-unit/LQ change plumbed from here. LWU is the only zero-extending word load.
  - *Action:* Add LD and LWU decode; plumb size=DOUBLE and sign flags
- **`hw/rtl/cpu_and_mem/cpu/id_stage/instr_decoder.sv:227`** [high] OPC_STORE arm (L227-242) lacks funct3=011 (SD); needs the new store_op_e member (o_store_op=STD) and RS_MEM size=DOUBLE routing. Currently traps illegal.
  - *Action:* Add SD decode with new store_op_e member
- **`hw/rtl/cpu_and_mem/cpu/id_stage/instr_decoder.sv:293`** [medium] OPC_AMO gate is `if (funct3 == 3'b010)` (word forms only, L293); funct3=011 (.D forms: LR.D, SC.D, AMO*.D) traps illegal. RV64 needs the full .D set, with AMO*.W results sign-extending to 64 downstream and an 8-byte reservation-granule decision for LR/SC.
  - *Action:* Add funct3=011 arm mapping to new *_D enum members
- **`hw/rtl/cpu_and_mem/cpu/id_stage/instr_decoder.sv:94`** [high] ZEXT.H is decoded as PACK rd,rs1,x0 (L93-94) — correct for RV32 only. On RV64 ZEXT.H is PACKW rd,rs1,x0 in the new OP-32 opcode, and plain PACK becomes a 64-bit pack of 32-bit halves (semantic change in ALU). The new OP-32 arm must decode PACKW (plus CLZW/CTZW/CPOPW/ROLW/RORW/RORIW, ADD.UW/SLLI.UW/SH[123]ADD.UW, ADDW/SUBW/SLLW/SRLW/SRAW, MULW/DIVW/DIVUW/REMW/REMUW).
  - *Action:* Write complete OP-IMM-32/OP-32 case arms; today they hit default:o_illegal at L494
- **`hw/rtl/cpu_and_mem/cpu/id_stage/instr_decoder.sv:418`** [medium] FP conversion decode: FCVT arms (L417-442) only accept rs2 field 00000/00001 (W/WU); RV64 adds rs2=00010/00011 (L/LU) for all four funct7 blocks. FMV.X.D (funct7=1110001, funct3=000) is currently illegal — L461-467 only allows FCLASS_D — and FMV.D.X (funct7=1111001) is entirely absent. New FCVT.S.L/LU results must be NaN-boxed like existing single-precision producers.
  - *Action:* Add L/LU conversion arms, FMV_X_D, FMV_D_X; reserved-rm check at L503-522 already covers the FCVT funct7 blocks
- **`hw/rtl/cpu_and_mem/cpu/id_stage/instruction_type_decoder.sv:109`** [medium] o_is_lr/o_is_sc require funct3==3'b010 (L109-112), so LR.D/SC.D (funct3=011) would be is_amo=1 but is_lr=is_sc=0 — silently misrouted as a plain AMO once the .D decode is added. Must accept funct3 in {010,011}.
  - *Action:* Widen funct3 acceptance when .D atomics land

### Policy (needs a project decision)

- **`hw/rtl/cpu_and_mem/cpu/riscv_pkg.sv:667`** [low] Custom CsrMperfDataH (0xFC1) keeps the split 32-bit high-half read scheme for profiling counters. On RV64 a single 64-bit CsrMperfData read would suffice; keeping the H-half is legal (custom CSR space) but inconsistent with dropping the architectural *H CSRs.
  - *Action:* Decide: keep split custom counter reads or collapse to one 64-bit CSR

### Mechanical (width/literal/comment hygiene)

- `hw/rtl/cpu_and_mem/cpu/riscv_pkg.sv:734` [low] ExcIllegalInstr..ExcEcallMmode are bit[31:0] (L734-739). Zero-extension into a 64-bit mcause is semantically correct for these small synchronous causes (unlike the interrupt constants), so this is a width-hygiene widen to XLEN, not a behavior bug. Also new misaligned classes: 8-byte alignment checks for LD/SD/LR.D/SC.D/AMO*.D reuse the same cause codes (4/6).
- `hw/rtl/cpu_and_mem/cpu/riscv_pkg.sv:1604` [low] mem_size_e already has MEM_SIZE_DOUBLE=2'b11 (encoding is RV64-ready) but the comment '64-bit (FLD/FSD only)' goes stale: LD/SD/LWU/LR.D/SC.D/AMO*.D all map to it, and lq_alloc_req_t.sign_ext must be driven correctly for LWU (0) vs LW (1, a semantic change: LW sign-extends to 64 on RV64).
- `hw/rtl/cpu_and_mem/cpu/id_stage/instruction_type_decoder.sv:182` [low] RAS coroutine/return checks compare i_immediate_i_type ([XLEN-1:0]) against 32'b0 (L182, L189). At XLEN=64 the literal zero-extends so the comparison is still semantically correct, but it is a width-mismatch lint hit and hides intent.
- `hw/rtl/cpu_and_mem/cpu/id_stage/id_stage.sv:36` [low] parameter XLEN=32 default is correctly overridden: cpu_ooo.sv:31 declares XLEN=riscv_pkg::XLEN and passes it at cpu_ooo.sv:626, and id_stage forwards it to immediate_decoder/instruction_type_decoder/branch_target_precompute. So the package flip propagates — no dead default. PC/link-address adders (L123-126, L901-904) and WB-bypass data paths are already XLEN-parametric.
- `hw/rtl/cpu_and_mem/cpu/id_stage/branch_target_precompute.sv:74` [low] Fully XLEN-parametric (adders L74-75, subtractors L82/L88, comparator L99). The XLEN'(signed'(...)) casts become no-ops once the immediate inputs are already 64-bit — correctness is entirely contingent on immediate_decoder producing properly sign-extended values (see that file's hazard). Widening triples: 5 carry chains of 64 bits + one 64-bit equality per instance, two instances (2-wide).

## fetch front end and PC management

The fetch front end is in very good shape for RV64: all six files were read in full, and pc_controller, pc_increment_calculator, pc_reg_precompute, control_flow_tracker, and the if_stage datapath are essentially fully XLEN-parametric -- PC registers, all five fetch-advance candidates, the pc_reg precompute adders, redirect/trap/fence/PD-target muxes, halfword pending-prediction compares, link-address computation, and the served-window guard all widen correctly by flipping the parameter. Instruction-word carriers ([31:0] instr_buffer, effective_instr, assembled_instr, the 64-bit i_instr fetch window, and the [47:32]/[15:0] spanning parity selection) are correctly width-invariant and need no change. The one high-risk hazard is if_stage.sv:884, where the served-window desync guard uses pc_reg[XLEN-1] as the cached-region predicate: at XLEN=64 with the sub-4-GiB map, bit 63 is never set, so the guard silently goes dead and the exact mid-instruction-byte pc_reg corruption it was added to stop (the workqueue_init_early boot Oops) returns -- and it diverges from fetch_provider.sv, which hardcodes bit 31 and stays correct. c_ext_state.sv has the only true port bug: i_pc/i_pc_reg are hardcoded [31:0] against XLEN-wide drivers (lint-fatal truncation at 64, behaviorally benign since only bit 1 is consumed and i_pc is dead). pc_increment_calculator.sv:267's ~32'd3 mask actually evaluates correctly at 64 bits under SV context-extension rules, but it sits on a permanently dead path (mid-32bit correction is tied off) and should be rewritten or deleted. No RV64 instruction-semantics work lands in these files -- they track only instruction sizes, so the RVC recode belongs to the aligner/PD decompressor.

The remaining Phase-1 cost here is timing, not logic: seven word-index adders grow to 62 bits, while the retained pending-prediction NEQ and halfword-magnitude compares grow to 63/64 bits. `pc_increment_calculator` precomputes the +2/+4/+6/+8 instruction-PC results and selects the XLEN-wide `seq_next_pc_reg`; `pc_controller` then applies its single monolithic priority mux before the canonicalized `o_pc_reg` boundary. The compare-then-mux NEQ remains parallel to that selected value for pending bookkeeping. Decisions still needed elsewhere are the canonical region-decode idiom and BTB/RAS target-storage compression.

### Hazards (compile-clean, silently wrong at XLEN=64)

- **`hw/rtl/cpu_and_mem/cpu/if_stage/if_stage.sv:884`** [high] window_cannot_serve_pc_reg gates the served-window desync guard on pc_reg[XLEN-1] as the 'cached region (>= CACHED_BASE 0x8000_0000)' predicate. At XLEN=64 with the unchanged sub-4-GiB physical map, bit 63 is never set for DDR-region PCs, so the guard NEVER fires: the exact pc_reg-lands-on-a-mid-instruction-byte desync class it was added to prevent (the workqueue_init_early epc 0x8038d7fa boot Oops, documented at lines 800-806) silently returns. Note fetch_provider.sv uses a hardcoded [31] for the same region test (fetch_provider.sv:219,294,381,407), so the two idioms diverge at XLEN=64 -- the provider still classifies correctly while IF's guard goes dead, which is worse than both being wrong.
  - *Action:* Replace pc_reg[XLEN-1] with an explicit region decode on the physical bits (pc_reg[31] given the sub-4-GiB map, or a shared riscv_pkg CachedBase compare used by both if_stage and fetch_provider). Tie to the project-wide high-address-bit policy decision.

### Policy (needs a project decision)

- **`hw/rtl/cpu_and_mem/cpu/if_stage/pc_controller.sv:669`** [low] Reset arms drive next_pc/next_pc_reg to '0 (lines 669, 733): the reset PC remains address 0 at any XLEN, parametric and consistent. All redirect sources (i_trap_target, i_branch_target, i_fence_i_target, i_pd_redirect_target, prediction targets) are already [XLEN-1:0] ports and widen for free -- but they inherit whatever width their producers (CSR mepc/mtvec, EX target adders, PD) actually drive, so correctness of PC[63:32] is owned upstream, not here.
  - *Action:* Decide the PC[63:32] invariant (always-zero enforced at redirect producers vs. fetch-side access-fault check); pc_controller itself needs no edit either way.

### Mechanical (width/literal/comment hygiene)

- `hw/rtl/cpu_and_mem/cpu/if_stage/c_extension/c_ext_state.sv:59` [low] Ports i_pc and i_pc_reg (lines 59-60) are hardcoded [31:0] although the module takes an XLEN parameter (unused for these ports). if_stage connects XLEN-wide pc/pc_reg (if_stage.sv:637-638), so at XLEN=64 the connection implicitly truncates. Behavior is benign today -- the body consumes only i_pc_reg[1] (lines 182, 187, 209, 280) and i_pc is entirely unused -- but CI Verilator 5.050 width lint will reject the 64-to-32 port truncation, and the dead i_pc port invites future misuse.
- `hw/rtl/cpu_and_mem/cpu/if_stage/pc_increment_calculator.sv:267` [low] pc_mid_32bit_correction = ((i_pc_reg + IncC) & ~32'd3) + Inc4 uses a 32-bit-sized mask literal on what becomes a 64-bit operand. Per SV context-determined sizing the operand of unary ~ is extended to 64 bits BEFORE inversion, so it evaluates correctly (~64'd3), but this is the classic pattern tools lint on and reviewers misread; the whole expression is also currently dead logic (o_mid_32bit_correction is tied to 1'b0 at pc_controller.sv:276, seq_sel_mid_32bit can never assert), so a wrong belief about it would go untested.
- `hw/rtl/cpu_and_mem/cpu/if_stage/if_stage.sv:816` [low] ServedP1LowBits=16 split of the served-window S=P+1 compare was sized for 30-bit word addresses (16 low + 14 upper). At XLEN=64 the word address is 62 bits, so the upper equality (line 835-836) and upper increment (line 831) become 46-bit structures while the low arm stays 2 CARRY8s -- functionally correct (all slicing is XLEN-parametric and the SYNTHESIS-guarded reference model at lines 849-877 stays equivalent), but the 'two CARRY8s per arm' balance the comment promises no longer holds.
- `hw/rtl/cpu_and_mem/cpu/if_stage/if_stage.sv:962` [low] Comments encode 32-bit PC assumptions that go stale at XLEN=64: line 962 'word(pc_reg[31:2]+1)' and the spanning parity discussion around lines 955-963 describe [31:2] word indexing. Code itself is parametric; only documentation drifts.
- `hw/rtl/cpu_and_mem/cpu/if_stage/pc_controller.sv:439` [medium] Pending-prediction crossing logic uses [XLEN-2:0] halfword magnitude comparators (pc_reg_hw < pending_prediction_pc_hw, seq_next_pc_reg_hw_q >= pending_prediction_pc_hw at lines 439-448) plus full-width equality (o_pc_reg == pending_prediction_pc, lines 456-459, 537-540). All parametric and correct at 64 including the modular-arithmetic prev_pc capture (line 656, o_pc - PcIncrementCompressed wraps identically mod 2^64, and the SYNTHESIS assertions at 785-796 remain valid). Flagged because these become 63/64-bit compare trees inside a cone that already required keep/max_fanout attributes and PC-mux-local duplication for 300 MHz timing.
- `hw/rtl/cpu_and_mem/cpu/if_stage/pc_increment_calculator.sv:316` [medium] The six parallel NEQ comparators (neq_hold/mid/plus2/plus4/plus6/plus8, lines 316-323) feeding o_seq_next_pc_reg_neq_pc become 64-bit compares. This bit feeds prediction_needs_pending in pc_controller (line 417-423), a path that previously measured -1.303ns before the compare-then-mux restructure; the compare trees double in depth by one LUT level each at 64 bits. Functionally parametric and clean -- the boot-hang-critical full-compare semantics (not a bit1 proxy) are preserved at any width.
- `hw/rtl/cpu_and_mem/cpu/if_stage/pc_reg_precompute.sv:31` [medium] Comment contract 'outputs settle ~0.3 ns into the cycle, well before BRAM data arrives at ~0.9 ns' (also pc_increment_calculator.sv:195-196) is a 32-bit-era measurement. At XLEN=64 the word-index adders become 62-bit CARRY8 chains (~8 additional CARRY8 stages), eroding the settle margin that the dont_touch/keep_hierarchy timing architecture is built on. Logic itself is fully parametric.
- `hw/rtl/cpu_and_mem/cpu/if_stage/if_stage.sv:413` [low] slot2_pc_plus2_for_btb / slot2_pc_plus4_for_btb (pc_reg + 2 / + 4) become 64-bit adders driving the dual-port BTB lookup addresses combinationally, and link_address (line 1194) becomes a 64-bit adder feeding the RAS push path. Parametric and correct; flagged solely because both feed prediction structures whose index/tag/storage widths are a separate policy decision (BTB target compression) and both sit near known-critical fetch paths.

## RVC decompression + instruction-memory predecode (RV64 C-table recode blast radius)

This subsystem carries no XLEN-width-bearing datapath — instructions, parcels, and the 18-bit sideband are all fixed-width — so flipping riscv_pkg's XLEN localparam changes nothing here, which is exactly the danger: every RV64 C-table semantic shift lands as a silent misdecode. The worst hazards are the reinterpreted encodings: rvc_decompressor.sv still expands q01 funct3=001 as C.JAL (RV64: C.ADDIW), q00 funct3=011/111 as C.FLW/C.FSW (RV64: C.LD/C.SD with 8-byte immediate scaling and integer register files), and q10 funct3=011/111 as C.FLWSP/C.FSWSP (RV64: C.LDSP/C.SDSP), so RV64 binaries would execute FP loads and taken jumps in place of integer loads and ADDIWs. The same C.JAL misclassification is replicated in three more places that must be recoded in lockstep: riscv_pkg::imem_compressed_control (feeds every stored AllowsSlot2After/Pairable sideband bit across BRAM init, port-A writes, timing replicas, and L1I fill), instruction_aligner's slot1_branch_compressed (would report C.ADDIW as a branch to pc_controller), and the Python generator's compressed_control (Vivado power-up init images). imem_rvc_source_hot and its Python mirror also change for C.ADDIW (rs1/rs2 metadata is genuinely different) and need new C.SUBW/C.ADDW arms; I verified the C.LD/C.LDSP load recodes are coincidentally bit-identical in the stored {rs2[1], rs1[2:1]} because bit 1 of both the scale-4 and scale-8 immediates is constant zero, so those arms need only comment updates. New-logic design work is confined to the decompressor: C.SUBW/C.ADDW expansion to OP-32, 6-bit shamts with bit12 as shamt[5] (dropping three bit12-illegal checks), OP-IMM-32/OP-32 opcode constants, and reserved-rd checks for C.ADDIW/C.LDSP. imem_predecode.sv and imem_predecode_line.sv are structurally unaffected because they derive everything from riscv_pkg's functions, but the offline-generated init images must be regenerated and the cocotb RTL-vs-Python cross-check extended to RV64 encodings to keep the mirror honest. Policy items are the front-end PC/address port widths (only low bits are consumed under the sub-4-GiB map) and the dual-XLEN-vs-RV64-only shape of the shared C-table across its four RTL sites and one offline mirror. Timing exposure is modest: the recode slightly deepens the slot-2 decompressor case trees on the documented post-BRAM WNS cone, while the sideband recode itself is width-neutral and removes a minterm from the PC-critical compressed-control predicate.

### Hazards (compile-clean, silently wrong at XLEN=64)

- **`hw/rtl/cpu_and_mem/cpu/if_stage/c_extension/rvc_decompressor.sv:216`** [high] Quadrant-01 funct3=001 unconditionally expands to JAL x1 (C.JAL). On RV64 this encoding is C.ADDIW: expand to {imm_ci, rd_full, 3'b000, rd_full, OP-IMM-32(0011011)}, with rd=0 reserved (illegal). If XLEN flips without this recode, every C.ADDIW in an RV64 binary silently becomes a taken JAL.
  - *Action:* Recode to ADDIW expansion; add rd==0 illegal check; imm_ci already computed
- **`hw/rtl/cpu_and_mem/cpu/if_stage/c_extension/rvc_decompressor.sv:192`** [high] Quadrant-00 funct3=011 expands to C.FLW (OpcLoadFp, funct3=010, imm_lw_sw scale-4). On RV64 it is C.LD: OpcLoad (integer), funct3=011, imm_ld_sd scale-8. Silent misdecode: writes the FP regfile with a 4-byte-scaled offset instead of an 8-byte integer load.
  - *Action:* Expand as {imm_ld_sd, rs1_prime, 3'b011, rd_prime, OpcLoad}; imm_ld_sd already computed for C.FLD
- **`hw/rtl/cpu_and_mem/cpu/if_stage/c_extension/rvc_decompressor.sv:201`** [high] Quadrant-00 funct3=111 expands to C.FSW (OpcStoreFp, funct3=010, imm_lw_sw). On RV64 it is C.SD: OpcStore, funct3=011, imm_ld_sd scale-8. Silent misdecode of every C.SD.
  - *Action:* Expand as {imm_ld_sd[11:5], rs2_prime, rs1_prime, 3'b011, imm_ld_sd[4:0], OpcStore}
- **`hw/rtl/cpu_and_mem/cpu/if_stage/c_extension/rvc_decompressor.sv:314`** [high] Quadrant-10 funct3=011 expands to C.FLWSP (OpcLoadFp, funct3=010, imm_lwsp). On RV64 it is C.LDSP: OpcLoad, funct3=011, imm_ldsp scale-8, and rd=0 is reserved (currently no rd check because FP rd=0 is legal) — reserved encodings would be silently accepted.
  - *Action:* Expand as {imm_ldsp, 5'd2, 3'b011, rd_full, OpcLoad} with rd==0 illegal; imm_ldsp already computed for C.FLDSP
- **`hw/rtl/cpu_and_mem/cpu/if_stage/c_extension/rvc_decompressor.sv:346`** [high] Quadrant-10 funct3=111 expands to C.FSWSP (OpcStoreFp, funct3=010, imm_swsp scale-4). On RV64 it is C.SDSP: OpcStore, funct3=011, imm_sdsp scale-8. Silent misdecode of every C.SDSP.
  - *Action:* Expand as {imm_sdsp[11:5], rs2_full, 5'd2, 3'b011, imm_sdsp[4:0], OpcStore}; imm_sdsp already computed for C.FSDSP
- **`hw/rtl/cpu_and_mem/cpu/if_stage/c_extension/instruction_aligner.sv:516`** [high] slot1_branch_compressed counts quadrant-01 funct3=001 as a branch (comment: 'C.JAL (RV32)'). On RV64 that encoding is C.ADDIW — an ALU op would be reported as o_slot1_is_branch to pc_controller and c_ext_state, silently terminating bundles and driving branch-side state for a non-branch. This predicate is a third copy of the compressed-control class (alongside riscv_pkg::imem_compressed_control and cpu_ooo's if_stage_has_control_flow per the comment at line 488) — all copies must be recoded in lockstep.
  - *Action:* Drop funct3==3'b001 from the q01 branch set; audit the sibling copy in cpu_ooo (out of this audit's scope) and historical comments at lines 516/565
- **`hw/rtl/cpu_and_mem/cpu/riscv_pkg.sv:151`** [high] imem_compressed_control includes q01 funct3==3'b001 (C.JAL) in the compressed-control class. On RV64 that is C.ADDIW: the stored AllowsSlot2After/EvenLocalPairValid/Pairable* sideband bits silently classify every C.ADDIW as control flow (bundle-killing, and inconsistent with a recoded aligner/decompressor). Affects BRAM init, port-A writes, the block-RAM fast replicas (bit 6 of *_compressed), and the L1I fill path — all derived from this one function.
  - *Action:* Drop funct3==3'b001 from the q01 control set (RV64); keep C.J/C.BEQZ/C.BNEZ/C.JR/C.JALR
- **`hw/rtl/cpu_and_mem/cpu/riscv_pkg.sv:275`** [high] imem_rvc_source_hot lumps funct3 001 and 101 (q01) as C.JAL/C.J with rs1={5{imm_j[11]}}, rs2={imm_j[4:1],imm_j[11]}. On RV64, funct3=001 is C.ADDIW whose expansion has rs1=rd_full and rs2(imm field)=imm_ci[4:0]; the stored {rs2[1], rs1[2:1]} = {expanded[21], expanded[17:16]} would be silently wrong for every C.ADDIW, corrupting the exact-replica rename/source timing endpoints these bits replace.
  - *Action:* Split funct3=001: rs1=rd_full, rs2=imm_ci[4:0] (mirror the C.ADDI arm); keep 101 as C.J
- **`sw/common/generate_imem_predecode_init.py:93`** [high] compressed_control() includes funct3 0b001 in the q01 control set — the offline mirror of riscv_pkg::imem_compressed_control. Must change in lockstep or the Vivado power-up sideband init files silently diverge from the RTL write/fill paths (the cocotb bench cross-checks imem_predecode_line against this script, so a one-sided change is catchable there, but only if the bench runs with RV64 encodings).
  - *Action:* Drop 0b001 from the control set in lockstep with riscv_pkg
- **`sw/common/generate_imem_predecode_init.py:190`** [high] rvc_source_hot() lumps funct3 0b001/0b101 as C.JAL/C.J (rs1 from imm_j sign, rs2 from imm_j bits). RV64 C.ADDIW needs rs1=rd_full, rs2=imm_ci&0x1F — mirror of the riscv_pkg finding at line 275.
  - *Action:* Split funct3=0b001 into an ADDIW arm in lockstep with riscv_pkg::imem_rvc_source_hot

### Design work (new logic or semantics)

- **`hw/rtl/cpu_and_mem/cpu/if_stage/c_extension/rvc_decompressor.sv:169`** [high] shamt is [4:0] = parcel[6:2] ('5-bit for RV32' comment). RV64 C.SLLI/C.SRLI/C.SRAI take 6-bit shamt {parcel[12], parcel[6:2]}; the expanded instruction's bit 25 must carry shamt[5]. Fixed [4:0] here plus the bit12-illegal checks means RV64's upper-half shifts are unreachable.
  - *Action:* Widen to 6-bit; place shamt[5] at expanded[25] (funct7 becomes 0000000/0100000 with bit25=shamt[5])
- **`hw/rtl/cpu_and_mem/cpu/if_stage/c_extension/rvc_decompressor.sv:231`** [medium] C.SRLI (and C.SRAI at line 235) assert o_illegal when bit12=1. On RV64 bit12 is shamt[5] and the encoding is valid. Currently loud (traps), not silent, but must be removed with the shamt widening.
  - *Action:* Drop bit12 illegal checks for C.SRLI/C.SRAI; route bit12 into shamt[5]
- **`hw/rtl/cpu_and_mem/cpu/if_stage/c_extension/rvc_decompressor.sv:305`** [medium] C.SLLI asserts o_illegal when bit12=1 ('shamt[5] still reserved on RV32'). Valid 6-bit shamt on RV64.
  - *Action:* Drop bit12 illegal check; route bit12 into shamt[5]
- **`hw/rtl/cpu_and_mem/cpu/if_stage/c_extension/rvc_decompressor.sv:241`** [medium] Quadrant-01 funct3=100, bits[11:10]=11, bit12=1 is wholesale illegal (comment even says 'RV64-only op encodings'). On RV64, funct2=00 is C.SUBW and funct2=01 is C.ADDW, expanding to OP-32 (0111011) with funct7 0100000/0000000 funct3=000; funct2 10/11 remain reserved.
  - *Action:* Add C.SUBW/C.ADDW arms targeting a new OpcOp32 localparam; keep funct2 10/11 illegal
- **`hw/rtl/cpu_and_mem/cpu/if_stage/c_extension/rvc_decompressor.sv:54`** [low] Opcode localparam list (OpcLui..OpcOp) lacks OP-IMM-32 (0011011) and OP-32 (0111011) needed by the C.ADDIW/C.SUBW/C.ADDW expansions.
  - *Action:* Add OpcOpImm32 and OpcOp32 localparams
- **`hw/rtl/cpu_and_mem/cpu/riscv_pkg.sv:299`** [medium] imem_rvc_source_hot leaves q01 funct3=100 [11:10]=11 bit12=1 as rs1=rs2=0 ('reserved on RV32 and expands to zero'). On RV64 C.SUBW/C.ADDW (funct2 00/01) expand with rs1_prime/rs2_prime — the metadata must match the recoded decompressor output or the source-hot bits silently diverge from the literal expansion.
  - *Action:* Add C.SUBW/C.ADDW arm: rs1=rs1_prime, rs2=rs2_prime for funct2 00/01; keep 10/11 zero
- **`sw/common/generate_imem_predecode_init.py:204`** [medium] rvc_source_hot() `elif not sign` leaves bit12=1 (q01 funct3=100 subop=11) as rs1=rs2=0. RV64 C.SUBW/C.ADDW (funct2 00/01) need rs1_prime/rs2_prime — mirror of the riscv_pkg finding at line 299.
  - *Action:* Add C.SUBW/C.ADDW arm for funct2 00/01 under bit12=1

### Policy (needs a project decision)

- **`hw/rtl/cpu_and_mem/cpu/if_stage/c_extension/instruction_aligner.sv:53`** [low] i_pc_reg is hardcoded [31:0] and the module's XLEN parameter (line 42) is never referenced in the body. Only pc_reg[2:1] are consumed, so behavior is XLEN-independent, but the port width vs a 64-bit PC is a decision (keep 32-bit front-end PC under the sub-4-GiB physical map, or widen to XLEN and drop/use the dead parameter).
  - *Action:* Decide front-end PC port width; remove or wire the unused XLEN parameter
- **`hw/rtl/cpu_and_mem/imem_predecode.sv:90`** [low] i_port_a_byte_address / i_port_b_byte_address (line 98) are [31:0]. Only ADDR_WIDTH+2 low bits are consumed, so with the sub-4-GiB physical map nothing misbehaves at XLEN=64; whether these fetch/programming address ports widen to XLEN is the project-wide high-address-bit policy. Everything else in this module (sideband, fast replicas, hi_rd_is_x2, init/write paths) is derived from riscv_pkg::imem_make_sideband and inherits the recode automatically — but the Vivado init images must be regenerated with the updated Python script or power-up sideband will be stale for RV64 binaries.
  - *Action:* Decide address-port width; regenerate all *.mem init images with the recoded generator as part of the RV64 build flow

### Mechanical (width/literal/comment hygiene)

- `hw/rtl/cpu_and_mem/cpu/riscv_pkg.sv:251` [low] q00 funct3 010/011 share the C.LW/C.FLW arm (rs2=imm_lw_sw[4:0]). On RV64 funct3=011 is C.LD with rs2=imm_ld_sd[4:0]. VERIFIED coincidentally harmless: bit [1] of both imm_lw_sw and imm_ld_sd is constant 0, so {rs2[1]} is identical under both interpretations and rs1 (rs1_prime) is unchanged. Same situation at line 323 for C.LWSP/C.FLWSP→C.LDSP (imm_lwsp[1]=imm_ldsp[1]=0). Only comments/labels need updating, but this equivalence should be re-proven in the cross-check bench when the table recodes.
- `sw/common/generate_imem_predecode_init.py:181` [low] C.LW/C.FLW shared arm (and C.LWSP/C.FLWSP at line 211) — same coincidental bit-identity as riscv_pkg line 251: imm bit [1] is 0 for both scale-4 and scale-8 immediates, so the packed source-hot value is unchanged for the load recodes. Comment/label update only.

## branch prediction storage and control (BTB, bimodal direction predictor, RAS, prediction metadata tracking)

The branch-prediction subsystem is almost entirely XLEN-parametric and needs no datapath rewrites for RV64: every PC, target, and link-address carrier uses riscv_pkg::XLEN or a properly-overridden XLEN parameter, and the index hashes (BTB PC[9:2], tag PC[XLEN-1:10]++PC[1], bimodal PC[10:1]) are written XLEN-relative and keep working unchanged at 64. The single genuine RV64 bug is in ras_detector.sv:155: the C.JAL pattern (funct3=001, op=01) becomes C.ADDIW on RV64, so every C.ADDIW would silently push a garbage return address onto the RAS — functionally recoverable (RAS is checkpointed) but a severe, silent return-prediction poisoning; the module has no XLEN parameter, so an explicit gate must be added. The main policy question is storage width: TagBits = XLEN-BTB_INDEX_BITS-1 auto-grows 23 -> 55 bits across five replicated tag LUTRAMs and targets grow 32 -> 64 across three replicas, roughly doubling BTB LUTRAM (~65 Kbit total growth) for upper PC bits that are architecturally constant given the sub-4-GiB physical map; compressing tags/targets back to RV32 widths with zero-extended readout is safe only once the project fixes its high-address-bit fetch policy. Timing exposure concentrates in the widened 55-bit tag compare on the combinational BTB-lookup -> next-PC path, which this code's comments show has already been through repeated 300 MHz timing surgery. The RAS (8xXLEN LUTRAM), direction predictor (pure 10-bit indexing), prediction_metadata_tracker (pure XLEN passthrough), and controller gating logic are all clean; only stale RV32-specific comments (23-bit tag, PC[31:10], target(32)) need doc updates in the same change. One low-grade latent hazard: several modules default their XLEN parameter to 32, which current instantiations override correctly but would silently truncate 64-bit PCs if a future instantiation or testbench omits the override.

### Hazards (compile-clean, silently wrong at XLEN=64)

- **`hw/rtl/cpu_and_mem/cpu/if_stage/branch_prediction/ras_detector.sv:155`** [high] is_c_jal decodes funct3=001/op=01 as C.JAL (RAS call). On RV64 this encoding is C.ADDIW, so every C.ADDIW instruction is classified as a call (via is_call_c at line 183), pushing a garbage link address onto the RAS. Compiles and runs; silently poisons return prediction — every subsequent 'ret' pops a wrong target, mispredicts, and takes the full EX-recovery penalty. Functionally safe (RAS is a predictor with checkpoint recovery) but a severe silent performance regression on RV64 code, where C.ADDIW is extremely common. The module has no XLEN parameter at all, so nothing flips automatically; needs an explicit XLEN==32 gate (or removal for rv64-only) on is_c_jal. Header comments at lines 45 and 119 already say 'RV32 only' but the code does not enforce it.
  - *Action:* Gate is_c_jal with a generate/parameter check (XLEN==32), or delete it in an rv64-only build; add an XLEN or IS_RV64 parameter to ras_detector since it currently has none. Verify C.ADDIW-heavy code no longer perturbs RAS depth in a directed cocotb test.
- **`hw/rtl/cpu_and_mem/cpu/if_stage/branch_prediction/branch_predictor.sv:73`** [low] parameter int unsigned XLEN = 32 default. The in-tree instantiation (branch_prediction_controller.sv:201-203) overrides it with riscv_pkg::XLEN, so production RTL flips correctly — but any testbench or future instantiation that omits .XLEN() silently builds a 32-bit BTB against 64-bit PCs, truncating without error (implicit port-width coercion). Same latent default exists in direction_predictor.sv:47 and prediction_metadata_tracker.sv:37.
  - *Action:* Either change the defaults to riscv_pkg::XLEN (package import in the parameter default) or audit/grep all instantiations after the flip; a width-mismatch lint pass (Verilator -Wall WIDTHEXPAND/WIDTHTRUNC) in CI catches accidental default use.

### Policy (needs a project decision)

- **`hw/rtl/cpu_and_mem/cpu/if_stage/branch_prediction/branch_predictor.sv:126`** [medium] TagBits = XLEN - BTB_INDEX_BITS - 1 silently grows 23 -> 55 bits at XLEN=64, and the three XLEN-wide target RAMs (lines 267-301) grow 32 -> 64 bits. Tag storage is replicated across FIVE sdp_dist_ram instances (lookup, lookup_2, lookup_2_alt, update, early_update: lines 202-264) and the compressed/handoff/counter RAMs are unaffected. Net LUTRAM growth: tags 5x256x(55-23) = +40,960 bits, targets 3x256x(64-32) = +24,576 bits — roughly doubling the BTB's distributed-RAM LUT cost. Mechanically correct as written, but with the physical map fixed below 4 GiB (M/U, no MMU), PC bits [63:32] are architecturally constant for all trained branches, so full-width tags/targets buy nothing.
  - *Action:* Decide: (a) accept the growth (zero-logic change), or (b) compress — keep TagBits pinned to 32-BTB_INDEX_BITS-1 = 23 (tag from PC[31:10]++PC[1]) and store 32-bit targets zero-extended to 64 on readout. Option (b) is only sound once the project's high-address-bit policy guarantees PCs above 4 GiB can never be fetched/trained (they'd alias into the truncated tag).

### Mechanical (width/literal/comment hygiene)

- `hw/rtl/cpu_and_mem/cpu/if_stage/branch_prediction/branch_predictor.sv:451` [medium] Slot-1 BTB hit compare (lookup_tag_stored == lookup_tag) widens 23 -> 55 bits; same for the two slot-2 compares at lines 469-470 and the early/late update-read compares at lines 489 and 508. The slot-1/slot-2 compares sit on the combinational LUTRAM-read -> hit -> predicted_taken -> prediction_used -> next-PC path that this subsystem has been repeatedly timing-optimized around (per comments in branch_prediction_controller lines 361-369). A 55-bit equality adds roughly one 6-LUT compare-tree level plus wider LUTRAM read fanout.
- `hw/rtl/cpu_and_mem/cpu/if_stage/branch_prediction/branch_predictor.sv:29` [low] Header and inline documentation hardcodes the RV32 layout: 'tag (23 bits) + target (32)' (line 29), 'Compare tag (PC[31:10] ++ PC[1])' (line 51), '// 23 bits (includes PC[1])' comment on the TagBits localparam (line 126), and 'Tag: PC[31:10] concatenated with PC[1] (23 bits)' (line 162). All become stale at XLEN=64 (or should be rewritten in XLEN-relative terms).
- `hw/rtl/cpu_and_mem/cpu/if_stage/branch_prediction/branch_predictor.sv:192` [low] update_pc_2_key = i_update_pc - XLEN'(2) and update_pc_2_alt_key = i_update_pc - XLEN'(4) (line 195) become 64-bit subtractors. Update-side only (explicitly documented as off the fetch-PC recurrence), so mechanical and low timing exposure; noted because they are full-width carry chains that double in length.
- `hw/rtl/cpu_and_mem/cpu/if_stage/branch_prediction/return_address_stack.sv:188` [low] RAS storage sdp_dist_ram DATA_WIDTH(riscv_pkg::XLEN): 8x32 -> 8x64 bits. Widens automatically and correctly (i_link_address, i_push_address_after_restore, o_ras_target are all riscv_pkg::XLEN already). Growth is trivial (8 entries), but the same sub-4-GiB compression policy could apply for consistency. Pointer/count arithmetic (RAS_PTR_BITS casts, valid_count saturation at lines 109-110, 253-258, 274-280) is XLEN-independent and unaffected.
- `hw/rtl/cpu_and_mem/cpu/if_stage/branch_prediction/branch_prediction_controller.sv:522` [low] pd_redirect_kills_prediction_metadata compares o_predicted_target_r != i_pd_redirect_target — widens to a 64-bit inequality feeding the synchronous-clear terms of three holdoff/metadata flop groups (lines 541-653). Both operands are registered upstream, so this is a fresh-from-flop compare, but it fans out into control logic the comments identify as timing-sensitive.
- `hw/rtl/cpu_and_mem/cpu/if_stage/branch_prediction/direction_predictor.sv:66` [low] bim_idx(pc) = pc[BIM_BITS:1] (bits [10:1]) is XLEN-independent and correct at 64; o_pred_idx / update-index plumbing (BpDirIdxBits=10 through riscv_pkg commit-capture structs at riscv_pkg.sv:882/920/1008) carries only the 10-bit index, so commit-side training widths stay matched. The pc argument's unused upper bits grow from [31:11] to [63:11] — pre-existing unused-bit situation, may surface a new Verilator UNUSEDSIGNAL width at 64 depending on waiver style.
- `hw/rtl/cpu_and_mem/cpu/if_stage/branch_prediction/ras_detector.sv:43` [low] Header comment block (lines 43-48) documents C.JAL as 'CALL, RV32 only' and the compressed-decode comment at line 119 repeats it; once the RV64 gating is added these comments need to state the C.ADDIW recode explicitly so the gate isn't 'simplified' away later. Doc-only companion to the line-155 hazard.

## integer execute (ALU, shifter, mul, div, branch compare) + fu shims + riscv_pkg bit-manip helpers

The integer-execute subsystem splits cleanly into three tiers. Genuinely parametric and near-free at XLEN=64: branch_jump_unit (JALR masking, immediate sext, and comparators all widen correctly - timing is the only concern), divider.sv (fully WIDTH-parametric including the div-by-zero and overflow-by-wraparound behavior; latency goes 17 to 33 cycles and its per-stage double-subtract is the subsystem's biggest timing question), and dsp_tiled_multiplier_unsigned (a ready-made building block for a 65x65 multiply). The dangerous tier is alu.sv: it takes an XLEN parameter, so flipping XLEN=64 COMPILES, but roughly a dozen case arms silently misbehave - 5-bit shamt truncation on all shifts/rotates/Zbs indices, SEXT_B/SEXT_H zero-extending instead of sign-extending, ORC.B/REV8/BREV8/CLZ/CTZ/CPOP operating on only the low 32 bits via truncating helper calls, ROL's hardwired 32-shamt identity, and DIV special-case comparisons against 32-bit constants that zero-extend to wrong 64-bit values. The multiplier is fixed 33x33 and needs a ground-up 65x65->128 redesign with 1-2 extra pipeline stages; its 4-cycle latency is hardcoded a second time as MulPipeDepth=4 in int_muldiv_shim, a silent tag/value-mismatch hazard if the two drift. int_muldiv_shim also hardwires 32-bit operand muxes and a low/high result split at bit 32, and declares 32-bit wires against divider ports that would become 64-bit - all compile-and-truncate hazards. The whole W-op family (ADDW through REMUW, plus Zba .UW, Zbb/Zbkb W-forms) is new design work, best structured as a single word-op qualifier driving operand shaping plus one final sign-extend mux. riscv_pkg already has a tree-based clz64; ctz64, cpop64, 64-bit brev8, and XLEN-wide div-overflow constants must be added, while zip32/unzip32 retire to illegal on RV64. Four zero-width-replication sites ({FLEN-XLEN{1'b0}}) in the two shims become lint hazards at XLEN=64 and should become casts. The alu's dead ENABLE_MULDIV=1 legacy path duplicates the div special-case logic with 32-bit constants and should probably be deleted rather than fixed. Latency contracts to re-document precisely: multiplier 4 cycles (header + shim), divider 17 cycles = XLEN/2+1 (shim derives this correctly from XLEN, but comments hardcode 17).

### Hazards (compile-clean, silently wrong at XLEN=64)

- **`hw/rtl/cpu_and_mem/cpu/ex_stage/alu/alu.sv:159`** [high] SLL/SRL/SRA use i_operand_b[4:0] as shift amount (lines 159-162). At XLEN=64 the native shifts need shamt[5:0]; bit 5 is silently dropped, so e.g. x<<40 computes x<<8 with no compile error.
  - *Action:* Widen register-form shamt to i_operand_b[5:0] for native shifts; add SLLW/SRLW/SRAW variants that keep [4:0] and sign-extend the 32-bit result.
- **`hw/rtl/cpu_and_mem/cpu/ex_stage/alu/alu.sv:173`** [high] SLLI/SRLI/SRAI (lines 173-175) take the shamt from i_instruction.source_reg_2, a 5-bit field. RV64 immediate shifts have 6-bit shamt (instruction bit 25 = shamt[5]); it cannot be delivered through this field, so shamt 32-63 silently aliases 0-31. Same field feeds BSETI/BCLRI/BINVI/BEXTI (298-301) and RORI (320).
  - *Action:* Add a 6-bit shamt channel (widen the field or a dedicated shamt6 input from the shim/decode) plus SLLIW/SRLIW/SRAIW W-forms with 5-bit shamt and bit-25-set illegal.
- **`hw/rtl/cpu_and_mem/cpu/ex_stage/alu/alu.sv:233`** [medium] DIV/REM special cases compare 64-bit operands against 32-bit constants: SignedInt32Min (233, 235, 258), NegativeOne (234, 259), and DIVU div-by-zero returns UnsignedInt32Max (246). At XLEN=64 the 32-bit literals zero-extend, so INT_MIN/-1 detection never fires and div-by-zero returns 0x00000000FFFFFFFF instead of all-ones. Note this ENABLE_MULDIV=1 path is currently dead (only int_alu_shim instantiates alu, with ENABLE_MULDIV=0), but it compiles and would misbehave silently.
  - *Action:* Replace with XLEN-wide SignedIntMin/NegativeOne/UnsignedIntMax constants (and 32-bit versions for the W-form special cases), or delete the dead ENABLE_MULDIV=1 path entirely.
- **`hw/rtl/cpu_and_mem/cpu/ex_stage/alu/alu.sv:63`** [medium] multiplier_input_a/b are [XLEN:0] and multiplier_result is [2*XLEN-1:0], but the multiplier module has fixed 33-bit inputs / 64-bit output. At XLEN=64 the port connections silently truncate 65->33 and the result slice [127:64] reads zeros (dead ENABLE_MULDIV=1 path; also o_result = multiplier_result[31:0] at line 190 is a hardcoded 32-bit slice).
  - *Action:* Delete or fully rework the legacy in-ALU muldiv path; if kept, it needs the same 65x65 multiplier as the shim path.
- **`hw/rtl/cpu_and_mem/cpu/ex_stage/alu/alu.sv:293`** [high] Zbs BSET/BCLR/BINV/BEXT use i_operand_b[4:0] as bit index (293-296) and BSETI/etc use the 5-bit source_reg_2 (298-301). At XLEN=64 bit indices 32-63 silently alias 0-31. The 32'd1 literals are contextually widened so the shift datapath itself is fine; only the index truncates.
  - *Action:* Widen index to [5:0] for register form and route 6-bit shamt for immediate form; BEXT concat {31'd0,...} at 296/301 is a mechanical width fix.
- **`hw/rtl/cpu_and_mem/cpu/ex_stage/alu/alu.sv:315`** [high] ROR/ROL/RORI funnel rotates are hardwired for 32: shamt [4:0], ROL computes 6'd32 - shamt (318), RORI uses 5-bit source_reg_2 (320). At XLEN=64 the funnel {a,a} becomes 128-bit but the rotate amount is truncated to 5 bits and ROL's 32-shamt identity is wrong - silently wrong results.
  - *Action:* 6-bit rotate amount, ROL = ROR by (7'd64 - shamt), plus new ROLW/RORW/RORIW arms operating on the low 32 bits with sign-extended result.
- **`hw/rtl/cpu_and_mem/cpu/ex_stage/alu/alu.sv:322`** [high] CLZ/CTZ/CPOP call clz32/ctz32/cpop32; passing a 64-bit i_operand_a silently truncates the function argument to [31:0], returning counts of the low word only.
  - *Action:* Switch to clz64 (exists in riscv_pkg, returns [6:0]) and add ctz64/cpop64; add CLZW/CTZW/CPOPW arms using the 32-bit helpers with sign-extended (always non-negative, so zero-extended-equivalent) result.
- **`hw/rtl/cpu_and_mem/cpu/ex_stage/alu/alu.sv:326`** [high] SEXT_B/SEXT_H build 32-bit concats ({{24{...}},...} / {{16{...}},...}). Assigned to a 64-bit o_result these ZERO-extend, so negative bytes/halfwords lose their upper-32 sign bits - silently wrong.
  - *Action:* Replication counts become 56/48 (or XLEN-8/XLEN-16).
- **`hw/rtl/cpu_and_mem/cpu/ex_stage/alu/alu.sv:329`** [high] ORC_B covers only bytes [31:0] (329-335); at XLEN=64 operand bits [63:32] are ignored and result upper half is zero - silently wrong. REV8 (336-337) swaps only 4 bytes; RV64 REV8 is an 8-byte swap and its immediate encoding also changes (decode-side).
  - *Action:* Extend both to 8 bytes (parametrize over XLEN/8); coordinate REV8 encoding change with decode.
- **`hw/rtl/cpu_and_mem/cpu/ex_stage/alu/alu.sv:347`** [high] BREV8 calls riscv_pkg::brev8 whose argument is [31:0] - a 64-bit operand silently truncates, reversing only the low 4 bytes. ZIP/UNZIP (348-349) are RV32-only and must decode as illegal on RV64; their case arms should be removed/gated.
  - *Action:* Widen brev8 to 64-bit (8 bytes); delete or gate ZIP/UNZIP arms; decode must reject their encodings.
- **`hw/rtl/cpu_and_mem/cpu/tomasulo/fu_shims/int_muldiv_shim.sv:125`** [high] MUL operand mux is hardwired 32-bit: mul_operand_a/b are [32:0] built from src_value[31]/[31:0] (125-143). At XLEN=64 this silently computes a 32x32 multiply for 64-bit MUL/MULH operands - compiles clean, wrong results.
  - *Action:* Widen to [64:0] with sign/zero-extension per op at 64 bits; add MULW arm (sign-extend low-32 inputs is unnecessary - multiply low 32s and sext result).
- **`hw/rtl/cpu_and_mem/cpu/tomasulo/fu_shims/int_muldiv_shim.sv:162`** [high] MulPipeDepth = 4 is a hardcoded copy of the multiplier's pipeline latency (also documented at lines 28-33). The 64-bit multiplier will be deeper; if this constant is not updated in lockstep the tracker tail samples the wrong product - silent tag/value mismatch on the CDB.
  - *Action:* Export latency as a parameter/localparam from the multiplier module and derive MulPipeDepth from it; update header comments.
- **`hw/rtl/cpu_and_mem/cpu/tomasulo/fu_shims/int_muldiv_shim.sv:396`** [high] div_quotient/div_remainder are declared [31:0] (396-397) but connect to divider ports of WIDTH=riscv_pkg::XLEN (399-411). Flipping XLEN to 64 makes the divider 64-bit while these wires truncate its outputs to 32 - tools warn but typically still build; results silently lose the high 32 bits.
  - *Action:* Declare as [riscv_pkg::XLEN-1:0]; div_result_32 (516-518) likewise widens.
- **`hw/rtl/cpu_and_mem/cpu/tomasulo/fu_shims/int_muldiv_shim.sv:267`** [medium] {{(riscv_pkg::FLEN - riscv_pkg::XLEN) {1'b0}}, ...} becomes a zero-width replication when XLEN=64=FLEN (also line 518). Legal SV inside a concat only if another member exists - it does here - but this is a known per-tool lint hazard (Verilator/Yosys/Vivado disagree historically).
  - *Action:* Replace with FLEN'(value) casts or generate-guarded concat; audit pattern repo-wide.
- **`hw/rtl/cpu_and_mem/cpu/tomasulo/fu_shims/int_alu_shim.sv:72`** [high] alu_instruction.source_reg_2 = i_rs_issue.imm[4:0] delivers only a 5-bit shamt to the ALU for SLLI/SRLI/SRAI/RORI/Zbs-immediates. RV64's 6-bit shamt (imm bit 5) is silently dropped - shamt 32-63 aliases 0-31.
  - *Action:* Deliver imm[5:0] via a widened field or dedicated shamt port; W-form immediate shifts keep 5 bits with bit 5 illegal (decode-side check).
- **`hw/rtl/cpu_and_mem/cpu/tomasulo/fu_shims/int_alu_shim.sv:139`** [low] {{(riscv_pkg::FLEN - riscv_pkg::XLEN) {1'b0}}, alu_result} zero-width replication at XLEN=64 (also line 158). Value semantics become a pass-through (correct); pure lint hazard. Note: integer results are zero-extended into the FLEN=64 CDB carrier today - at XLEN=64 the full value occupies the carrier, so no NaN-boxing interaction, but new FCVT.S.L/LU results elsewhere must still NaN-box; this shim never produces FP values so it is unaffected.
  - *Action:* Replace with FLEN'() cast; also extend the non-M-op assertion list (168-172) to cover MULW/DIVW/etc so W-form M ops cannot leak into the ALU shim.
- **`hw/rtl/cpu_and_mem/cpu/riscv_pkg.sv:808`** [high] SignedInt32Min/SignedInt32Max/UnsignedInt32Max/NegativeOne are bit [31:0] constants (808-811). Any comparison against a 64-bit signal zero-extends them (NegativeOne becomes 0x00000000FFFFFFFF), silently breaking DIV overflow/div-zero detection wherever used at XLEN=64.
  - *Action:* Add XLEN-wide SignedIntMin/NegativeOne/UnsignedIntMax (and keep 32-bit ones, properly named, for W-form special cases); audit all users.

### Design work (new logic or semantics)

- **`hw/rtl/cpu_and_mem/cpu/ex_stage/alu/alu.sv:152`** [medium] The entire W-op family is absent from the case statement: ADDW/SUBW/SLLW/SRLW/SRAW/ADDIW/SLLIW/SRLIW/SRAIW, and Zba/Zbb W-forms. Every W-op must produce sext(result[31:0]).
  - *Action:* Add W-op enum arms; cleanest structure is a single is_word_op qualifier that (a) muxes 32-bit-shaped datapaths where needed (shifts, ADDW/SUBW carry chain can reuse the 64-bit adder low half) and (b) drives one final {{32{res[31]}},res[31:0]} output mux stage.
- **`hw/rtl/cpu_and_mem/cpu/ex_stage/alu/alu.sv:343`** [medium] PACK packs 16-bit halves ({b[15:0],a[15:0]}); RV64 PACK packs 32-bit halves ({b[31:0],a[31:0]}). Current code at XLEN=64 silently produces a zero-extended 32-bit pack. PACKW is a new op. PACKH (345) stays byte-based and its {16'd0,...} concat zero-extends correctly at 64, so it is only a lint/width cleanup. ZEXT.H's decode changes from PACK to PACKW on RV64 (decode-side dependency).
  - *Action:* PACK -> 32-bit halves; add PACKW arm ({b[15:0],a[15:0]} sign-extended); keep PACKH; coordinate ZEXT.H alias with decode.
- **`hw/rtl/cpu_and_mem/cpu/ex_stage/alu/alu.sv:289`** [medium] SH1ADD/SH2ADD/SH3ADD are width-parametric and fine at 64, but RV64 Zba adds ADD.UW, SLLI.UW, SH1/2/3ADD.UW (zero-extend rs1[31:0] before the shift-add), which do not exist anywhere.
  - *Action:* Add .UW arms: operand_a_uw = {32'b0, a[31:0]}, then existing shift-add; SLLI.UW uses the 6-bit shamt path.
- **`hw/rtl/cpu_and_mem/cpu/ex_stage/alu/multiplier.sv:74`** [medium] Multiplier is a fixed 33x33->64 datapath end to end: [32:0] ports (74-75), abs_33 (85-87), 17/16 split (90-91), 34/33/32-bit partial products (132-135), 66-bit final add (216-227), o_product_result[63:0] (77). RV64 MUL/MULH/MULHSU/MULHU need 65x65->128. No silent failure (ports mismatch loudly), but it is a full redesign: 65-bit magnitudes split into 4x17-bit chunks give 16 DSP tiles with a deeper reduction tree, or reuse dsp_tiled_multiplier_unsigned(A=B=65: 3x2=6 tiles of 27x35, 4 reduce stages) plus a sign-correction wrapper. Pipeline depth will grow from the current 4 cycles; the depth is a documented contract (header lines 20-63).
  - *Action:* Rebuild as 65x65 unsigned-magnitude multiply + sign fixup, likely 5-6 pipe stages at 300 MHz; consider MULW early-out through a 32-bit path (but see uniform-latency constraint in the shim tracker).
- **`hw/rtl/cpu_and_mem/cpu/ex_stage/dsp_tiled_multiplier_unsigned.sv:36`** [low] Fully parameterized (A_WIDTH/B_WIDTH/tile sizes); at 65x65 it elaborates to 6 tiles, PipelineStages=4, PaddedWidth=160-bit adder tree rows. Viable building block for the 64-bit integer multiplier; no code change needed, only instantiation. MinPipelineStages=3 floor (65) is an FP S/D latency-matching contract - do not disturb when reusing for INT.
  - *Action:* Candidate reuse for 65x65 magnitude multiply; verify 160-bit registered adds meet 300 MHz or raise ADD_CHUNK_WIDTH chunking review.
- **`hw/rtl/cpu_and_mem/cpu/ex_stage/alu/divider.sv:143`** [medium] Each pipeline stage chains TWO WIDTH-bit subtract-and-select iterations combinationally (143-164). At WIDTH=64 that is two dependent 65-bit subtracts plus muxes per 3.33 ns cycle - plausibly the tightest new arithmetic path in the subsystem.
  - *Action:* If timing fails at 300 MHz, fall back to 1 bit/stage (65-cycle latency, DivPipeDepth doubles) or restructure the stage; decide before freezing the shim's tracker depth.
- **`hw/rtl/cpu_and_mem/cpu/tomasulo/fu_shims/int_muldiv_shim.sv:265`** [medium] Result select splits the 64-bit product at bit 32: mul_result_32 = is_low ? product[31:0] : product[63:32] (265-267), and is_mul_low is a 1-bit low/high flag (72, 90). RV64 needs a 128-bit product with MUL=low64, MULH*=high64, MULW=sext(product[31:0]) - a 3-way select tracked per in-flight op.
  - *Action:* Widen product to 128, replace mul_trk_is_low with a 2-bit result-select carried through the tracker shift register, add sext mux for MULW.
- **`hw/rtl/cpu_and_mem/cpu/tomasulo/fu_shims/int_muldiv_shim.sv:416`** [medium] DivPipeDepth = riscv_pkg::XLEN/2 + 1 self-adjusts to 33 at XLEN=64 (good), but the '// 17' comment and header ('17-cycle latency', lines 29, 36-38) go stale, and the latency doubling changes the scheduling/performance contract. W-form divides (DIVW/DIVUW/REMW/REMUW) can reuse the 64-bit divider by sign/zero-extending 32-bit operands (overflow, div-by-zero, and remainder cases all fall out correctly after sext of the low 32 result), but need a per-op W flag carried through the 33-deep tracker plus a sext mux at FIFO push; op-decode case lists (76-90, 392, 466) must add the W ops.
  - *Action:* Add W ops to decode/routing, carry is_word through div tracker, sext(result[31:0]) at push; decide whether 33-cycle uniform latency is acceptable for W divides or a second 17-stage path is warranted (variable latency breaks the shift-register tracking).
- **`hw/rtl/cpu_and_mem/cpu/riscv_pkg.sv:1151`** [medium] Helper coverage for 64-bit Zbb/Zbkb is incomplete: clz32 (1151), ctz32 (1186), cpop32 (1216), brev8 (1279) are 32-bit-only; clz64 exists (1243, returns [6:0], byte-tree, FPGA-friendly - ready to use); ctz64 and cpop64 do not exist; zip32/unzip32 (1291, 1301) are RV32-only ops that must become illegal encodings on RV64. Calling any 32-bit helper with a 64-bit argument silently truncates.
  - *Action:* Add ctz64/cpop64 (mirror clz64's byte tree; cpop64 is one more adder level), widen brev8 to 64, keep 32-bit helpers for CLZW/CTZW/CPOPW, retire zip32/unzip32 from the RV64 decode.

### Policy (needs a project decision)

- **`hw/rtl/cpu_and_mem/cpu/ex_stage/alu/alu.sv:36`** [medium] alu has an XLEN parameter and partially-parametric core (ADD/SUB/logic/SLT/difference/sltu at 135-171 widen correctly), but the file mixes parametric and hardcoded-32 code so heavily that 'flip XLEN' produces a silently wrong ALU rather than a broken build. Whether to keep the XLEN parameter (dual-width support) or hard-commit to 64 is a project decision that shapes every fix above.
  - *Action:* Decide dual-XLEN parameterization vs rv64-only before starting edits; also decide fate of the dead ENABLE_MULDIV=1 legacy path (78-124, 185-275) which duplicates div special-case logic.

### Mechanical (width/literal/comment hygiene)

- `hw/rtl/cpu_and_mem/cpu/ex_stage/alu/alu.sv:163` [low] SLT/SLTI/SLTU/SLTIU results are cast 32'(...) (163, 164, 170, 171). Value is still correct (0/1 zero-extends) but the hardcoded 32 is a width-mismatch lint at XLEN=64. Same class: 32'h0000_0000 at 260, {31'd0,...} at 296/301, 32'd0 at 339/340.
- `hw/rtl/cpu_and_mem/cpu/ex_stage/alu/divider.sv:74` [low] Divider is cleanly WIDTH-parametric (restoring, 2 bits/stage, WIDTH/2 stages + 1 init). At WIDTH=64: latency goes 17 -> 33 cycles; overflow-by-wraparound argument still holds at 64 (abs(INT64_MIN)/1 negated = INT64_MIN) and div-by-zero all-ones/dividend outputs are WIDTH-wide, so no functional change needed for native 64-bit ops. Header comments hardcode '17 cycles'/'16 stages'/'32 for RV32' (65-66, 74, 105) and go stale.
- `hw/rtl/cpu_and_mem/cpu/ex_stage/branch_jump_unit.sv:83` [low] Clean-parametric: jalr_target = (rs1 + sext(imm)) & ~XLEN'(1) widens correctly (JALR LSB masking already right), i_immediate_i_type [31:0] with XLEN'(signed') cast is per-spec, comparators (90-92) are XLEN-wide. Only impact is timing: 64-bit equality/less-than compares feed branch resolution and the mispredict redirect.

## FPU - RV64F/D additions (int<->FP conversions, FMV, compare/classify int results, NaN-boxing)

The FPU conversion subsystem is in better shape than expected: fp_convert.sv is already fully parameterized on XLEN (saturation constants, exponent bounds, LZC, mantissa alignment, and the wide/narrow rounding generate all scale correctly), and the value carriers are already FLEN=64, so the widening is mostly plumbing plus new op arms rather than datapath rework. Three silent hazards dominate. First, fp_add_shim.sv:340 instantiates fpu_convert_unit without an .XLEN override, so flipping riscv_pkg::XLEN leaves the converter at 32 bits and silently truncates 64-bit int operands at the port boundary. Second, fpu_compare_unit.sv:73 NaN-boxes FEQ.S/FLT.S/FLE.S integer results with ones in [63:32]; today the shim's [XLEN-1:0] slice at line 406 strips them, but at XLEN=64 rd receives 0xFFFFFFFF_00000001. Third, fp_convert.sv:145 hardcodes sign-bit index 31, which would make FCVT.S.L/FCVT.D.L silently mishandle 64-bit signed operands. The fourth semantic trap is fp_add_shim.sv:425's zero-extension of fp->int results: on RV64 every W-form conversion result and FMV.X.W must sign-extend (WU included), so the shim needs a latched W-vs-L flag orthogonal to op_is_double. The real design work is decoupling integer width from XLEN in fp_convert so W-forms keep 32-bit bounds while L-forms get 64-bit ones, then threading the 10 new op enums through three op-classification expressions, the stage-4 case, and the shim's two routing cases. NaN-boxing infrastructure is already correct end-to-end (ones-boxing in fpu_convert_unit, fp_convert_sd, and the shim; unbox32 checking in the shim), so FCVT.S.L/LU and FMV.W.X inherit correct boxing for free, and FMV.X.D/FMV.D.X are near-free through the existing D-instance FMV path. FCLASS zero-extension is already RV64-correct. fp_convert_sd, fp_compare, fp_sign_inject, fp_result_assembler, fp_operand_unpacker, and the five arithmetic wrapper units are FLEN-neutral and unaffected. Both zero-width {(FLEN-XLEN){...}} replications live in fp_add_shim (lines 406, 425) and disappear naturally when those muxes are rewritten for RV64 semantics. Timing exposure is confined to the multi-cycle convert FSM (64-bit negate+LZC, 117-bit shifter), away from the known-critical rename/wakeup/CDB paths.

### Hazards (compile-clean, silently wrong at XLEN=64)

- **`hw/rtl/cpu_and_mem/cpu/tomasulo/fu_shims/fp_add_shim.sv:340`** [high] fpu_convert_unit is instantiated with NO .XLEN parameter override, so it stays at its default XLEN=32 even after riscv_pkg::XLEN flips to 64. The shim's own localparam XLEN (line 56) becomes 64, so i_int_operand at line 349 feeds a 64-bit expression into a 32-bit port (silent truncation of FCVT.S.L/D.L operands' upper 32 bits) and the 32-bit o_int_result implicitly zero-extends into the 64-bit convert_int_result net. Compiles with only WIDTH warnings in most tools.
  - *Action:* Pass .XLEN(riscv_pkg::XLEN) (and audit every fpu_*_unit instantiation for the same omission) as part of the widening; better, make the parameter mandatory-explicit.
- **`hw/rtl/cpu_and_mem/cpu/ex_stage/fpu/fpu_compare_unit.sv:73`** [high] o_result = valid_s ? box32(result_s) : ... unconditionally NaN-boxes single-precision results with ones in [63:32], INCLUDING the integer 0/1 results of FEQ.S/FLT.S/FLE.S (o_is_compare=1). Today the shim slices compare_result[XLEN-1:0]=[31:0] so the boxing is discarded; at XLEN=64 the slice becomes [63:0] and rd receives 0xFFFFFFFF_0000000{0,1}. Silent compile-and-misbehave.
  - *Action:* Mux the boxing on is_compare_s: box only FMIN.S/FMAX.S results; zero-extend compare results. Add a directed test asserting FEQ.S writes exactly 0 or 1 into a 64-bit rd.
- **`hw/rtl/cpu_and_mem/cpu/ex_stage/fpu/fp_convert.sv:145`** [high] is_signed_conv && int_operand_reg[31] hardcodes sign-bit index 31. If this instance's XLEN parameter is flipped to 64 for the L-form conversions, FCVT.S.L/FCVT.D.L reads bit 31 instead of bit 63: negative 64-bit operands with bit31=0 are treated as positive, positives with bit31=1 get negated. Silently wrong results, no compile error (bit 31 always exists).
  - *Action:* Change to int_operand_reg[XLEN-1]. For W-forms retained at 64-bit XLEN, pre-extend the operand at the wrapper instead (see design items).
- **`hw/rtl/cpu_and_mem/cpu/tomasulo/fu_shims/fp_add_shim.sv:425`** [high] Comment and code implement 'FP->INT: zero-extend int result to FLEN'. On RV64, FCVT.W.S/FCVT.WU.S/FCVT.W.D/FCVT.WU.D and FMV.X.W must all SIGN-extend their 32-bit result into the 64-bit rd (WU included, per spec). Zero-extension here silently produces wrong rd values for negative/W-form results. Also {(FLEN-XLEN){1'b0}} becomes a zero-width replication at XLEN=64 (legal in concat, per-tool lint hazard).
  - *Action:* Add a W-vs-L discriminator (from op_reg) and sign-extend bit 31 for all W-form fp->int and FMV.X.W results; pass L-form results through full-width. Remove/guard the zero-width replication.
- **`hw/rtl/cpu_and_mem/cpu/tomasulo/fu_shims/fp_add_shim.sv:406`** [medium] {(FLEN-XLEN){1'b0}} zero-width replication once XLEN=64 (lint hazard per tool), and compare_result[XLEN-1:0] widens to [63:0], which is what exposes the fpu_compare_unit boxing corruption (see companion finding). FEQ/FLT/FLE results must be zero-extended from the single bit, not sliced from a possibly-boxed 64-bit bus.
  - *Action:* Rewrite as {{(FLEN-1){1'b0}}, compare_result[0]} for is_compare results (after fixing the wrapper boxing), eliminating both the zero-width replication and the aliasing.

### Design work (new logic or semantics)

- **`hw/rtl/cpu_and_mem/cpu/ex_stage/fpu/fp_convert.sv:431`** [medium] move_int_result_s2_comb = fp_operand_reg[XLEN-1:0]: in the S instance (FP_WIDTH=32) with XLEN=64 this is an out-of-range part-select of a 32-bit vector (elaboration error - loud, not silent). Semantically FMV.X.W on RV64 must produce sign_extend(fp_operand[31:0]) anyway; FMV.X.D (new) needs the full 64-bit move in the D instance.
  - *Action:* Guard with generate or min(FP_WIDTH,XLEN) slice and add sign-extension for FMV.X.W when XLEN > FP_WIDTH; add FMV_X_D/FMV_D_X arms to the stage-4 case (lines 528-535).
- **`hw/rtl/cpu_and_mem/cpu/ex_stage/fpu/fp_convert.sv:141`** [high] is_signed_conv tests only FCVT_S_W/FCVT_D_W (also line 375 is_signed_conv_s2, and line 241 is_unsigned_conv tests only FCVT_WU_S/FCVT_WU_D). The new L-form ops FCVT_S_L/FCVT_D_L/FCVT_S_LU/FCVT_D_LU are absent; if enums are added but these lists are not updated, FCVT_*_LU would be classified 'signed' and FCVT_*_L 'not signed' - silently wrong conversions.
  - *Action:* Extend all three op-classification expressions (lines 141-142, 241-242, 375-376) with the L-form enums; consider deriving signed/unsigned/int-width flags once at decode and passing them as sideband bits instead of re-decoding op enums per stage.
- **`hw/rtl/cpu_and_mem/cpu/ex_stage/fpu/fp_convert.sv:475`** [high] Stage-4 unique case enumerates only FCVT_{W,WU}_{S,D}, FCVT_{S,D}_{W,WU}, FMV_X_W, FMV_W_X. FCVT_{L,LU}_{S,D}, FCVT_{S,D}_{L,LU}, FMV_X_D, FMV_D_X fall into the default arm and return all-zero results with no flags - silent if decode routes them here without new arms.
  - *Action:* Add case arms for all 10 new ops (L-form conversions in both directions plus FMV.X.D/FMV.D.X), each with correct is_fp_to_int routing.
- **`hw/rtl/cpu_and_mem/cpu/ex_stage/fpu/fp_convert.sv:44`** [high] fp_convert conflates the integer operand/result width with XLEN. On RV64 the same S-format unit must handle both W-forms (32-bit bounds: saturate at 2^31/2^32, then sign-extend to 64 - both signed and unsigned) and L-forms (64-bit bounds 2^63/2^64). The saturation constants IntMax/IntMin/UintMax (lines 84-86) and range checks MaxExpSigned/MaxExpUnsigned (lines 82-83) all key off XLEN, so a single XLEN=64 instance gets W-form bounds wrong; a kept XLEN=32 instance gets L-forms wrong. The good news: everything is already cleanly parameterized on XLEN, so an INT_WIDTH split is mostly plumbing.
  - *Action:* Either add a runtime W/L mode input selecting between two bound sets, or split the parameter into INT_WIDTH (32/64) with four converter configurations (S/D fp-width x W/L int-width) - int->fp W-forms can alternatively reuse the 64-bit datapath by pre-extending the operand (sign-extend for .W, zero-extend for .WU) at the wrapper since the numeric result is identical.
- **`hw/rtl/cpu_and_mem/cpu/tomasulo/fu_shims/fp_add_shim.sv:131`** [medium] Shim op-decode (lines 131-140) and cvt_use_s/d routing (lines 328-337) enumerate only W-form convert ops. New ops need routing, and the existing op_is_double flag (keyed to FP width, used at lines 428-429 for NaN-boxing) is orthogonal to int width: FCVT.L.S is single-FP but 64-bit int, FCVT.D.W is double-FP but 32-bit int. FMV.X.D/FMV.D.X must route with op_is_double=1 so line 428 skips boxing.
  - *Action:* Add all L-form and FMV.D ops to both case statements; introduce a separate int-width flag latched at fire so the result mux can pick sign-extend-32 vs pass-64 independently of FP-width boxing.

### Mechanical (width/literal/comment hygiene)

- `hw/rtl/cpu_and_mem/cpu/ex_stage/fpu/fp_convert.sv:425` [low] gen_move_fp_pad zero-pads FMV int->FP with {(FP_WIDTH-XLEN){1'b0}} when FP_WIDTH>XLEN. At XLEN=64 both instances take the nopad branch so no zero-width replication occurs (generate-guarded), and NaN-boxing of FMV.W.X is correctly applied downstream with ones (fpu_convert_unit box32 line 47-49, shim line 429). The pad branch simply becomes dead code. Low risk; noting per the flag-every-occurrence instruction.
- `hw/rtl/cpu_and_mem/cpu/ex_stage/fpu/fp_convert.sv:36` [low] Header comments (lines 21-26, 36) document 32-bit-int-only semantics ('24-bit mantissa for 32-bit int', FCVT.W list); the FracBits>=(XLEN-1) generate split at lines 359-370 already handles the RV64 consequence that FCVT.D.L becomes inexact-capable (52 < 63 selects the narrow/rounding path automatically), so this is doc-only.
- `hw/rtl/cpu_and_mem/cpu/ex_stage/fpu/fp_classify.sv:43` [low] o_result is hardcoded [31:0] with the 10-bit class mask zero-padded (line 113), and the shim zero-extends it to FLEN via {(FLEN-32){1'b0}} (fp_add_shim.sv:415, nonzero replication at any XLEN). Zero-extension is exactly the correct RV64 FCLASS semantics, so this path needs no change - recording as verified-correct rather than a defect.

## rename/dispatch/issue machinery (dispatch, reservation station + issue2 selector, RAT, CDB arbiter, FU-CDB adapter, dispatch-RS router)

The rename/dispatch/issue machinery is in good shape for RV64: value carriers (RS source values, CDB, RAT lookup, repair channels, bypass masks) are already FLEN=64-wide, and tag/valid/wakeup logic is width-neutral, so cdb_arbiter.sv, fu_cdb_adapter.sv, rs_issue2_selector.sv, and dispatch_rs_router.sv need zero changes. The dangerous concentrations are in dispatch.sv and one line of reservation_station.sv. The single worst hazard is the immediate path: dispatch assigns the hardcoded-[31:0] from_id_to_ex_t immediates into its [XLEN-1:0] imm (8 assignment sites across both slots), which at XLEN=64 silently ZERO-extends sign-extended I/S/U immediates — every negative immediate and every LUI/AUIPC result would be wrong until the package fields are widened with sign-extension in ID. Second, dispatch's mem_signed formula excludes word loads from sign-extension, so RV64 LW would silently stay zero-extended; the mem_size and imm-select case statements likewise default new RV64 ops (LD/SD/LWU/AMO*.D, W-form ALU immediates) to WORD-size/no-immediate — compile-and-misbehave defaults that must be updated in lockstep with the ID-stage rs_type pre-decode. Third, the RS's stage2_is_sc compares against SC_W only, so SC.D would lose its store-conditional sideband. The RAT contains all eight {{(FLEN-XLEN){1'b0}},...} zero-extension points where INT operands enter FLEN carriers; each becomes an identity extension at XLEN=64 (semantically correct) but a zero-width replication (per-tool lint hazard) — replace with FLEN'() casts. RAT rename/checkpoint storage is tag-only and does not grow. Timing exposure is confined to the XLEN-carrying sideband (imm/pc/targets/link_addr): rs_dispatch_t grows 160 bits across 13 fanned-out packets on the historically-critical ID->RS write path, and the RS payload LUTRAM widens accordingly, while the known-critical wakeup/CDB cones are structurally unchanged. csr_write_data's uimm5 zero-extension is parametric and correct as-is.

### Hazards (compile-clean, silently wrong at XLEN=64)

- **`hw/rtl/cpu_and_mem/cpu/tomasulo/dispatch/dispatch.sv:395`** [high] imm ([XLEN-1:0]) is assigned from from_id_to_ex_t.immediate_i_type which is hardcoded [31:0] in riscv_pkg (line 927). At XLEN=64 this implicit width mismatch ZERO-extends a sign-extended 12-bit immediate: ADDI x1,x0,-1 yields imm=64'h0000_0000_FFFF_FFFF. Same pattern at lines 401 (immediate_s_type), 407/412 (immediate_u_type — LUI/AUIPC must sign-extend bit 31 to 63 on RV64), and slot-2 mirrors at 565, 570, 575, 580.
  - *Action:* Widen immediate_i/s/u_type to [XLEN-1:0] in riscv_pkg with sign-extension performed in ID; the dispatch assignments then become identity. Verify no Verilator WIDTHEXPAND waiver hides the mismatch in the interim.
- **`hw/rtl/cpu_and_mem/cpu/tomasulo/dispatch/dispatch.sv:363`** [high] mem_signed = is_load && !is_load_unsigned && (is_load_byte || is_load_halfword) — word loads are excluded from sign-extension. On RV64, LW must SIGN-extend to 64 bits and LWU zero-extends; with this formula unchanged, LW silently stays zero-extended (wrong result for every negative word load) and LD gets no defined treatment. Slot-2 mirror at lines 535-537.
  - *Action:* Rework: mem_signed must cover LW (add is_load_word term or invert to !is_load_unsigned && size<DOUBLE); ID must set is_load_unsigned for LWU; LD needs no extension.
- **`hw/rtl/cpu_and_mem/cpu/tomasulo/reservation_station/reservation_station.sv:1922`** [high] stage2_is_sc <= (instr_op_e'(pl_op_bits) == riscv_pkg::SC_W) — hard equality against SC_W only. When SC_D is added, SC.D issues without the is_sc sideband flag: compiles and silently misbehaves in the MEM pipeline's store-conditional handling.
  - *Action:* Change to (op == SC_W) || (op == SC_D), or use a shared is_sc_op classification helper.
- **`hw/rtl/cpu_and_mem/cpu/tomasulo/register_alias_table/register_alias_table.sv:471`** [medium] {{(FLEN - XLEN) {1'b0}}, i_int_regfile_data1} — INT regfile value zero-extended into the FLEN-wide rat_lookup_t.value carrier. At XLEN=64 the replication count becomes ZERO: legal SV inside a concatenation but a per-tool lint/elaboration hazard (Verilator 5.050 / Yosys 0.64 / Vivado may each warn or error differently). Eight occurrences: lines 471, 475, 487, 491 (slot-1) and 537, 541, 553, 557 (slot-2). Semantically the extension becomes identity at XLEN=64, which is correct — full-width INT operand.
  - *Action:* Replace each with FLEN'(i_int_regfile_dataN) (width cast) so the expression is valid and lint-clean at both XLEN values; semantics unchanged.

### Design work (new logic or semantics)

- **`hw/rtl/cpu_and_mem/cpu/tomasulo/dispatch/dispatch.sv:347`** [high] mem_size case covers only RV32 ops: LD/SD/LR_D/SC_D/AMO*_D are absent and the default arm returns MEM_SIZE_WORD, so once decode emits the new ops they would silently dispatch as 4-byte accesses (MEM_SIZE_DOUBLE is currently reached only by FLD/FSD at line 358). LWU also missing (needs WORD). Slot-2 mirror at 519-533.
  - *Action:* Add LD/SD/LR_D/SC_D/AMO{SWAP,ADD,XOR,AND,OR,MIN,MAX,MINU,MAXU}_D -> MEM_SIZE_DOUBLE and LWU -> MEM_SIZE_WORD to both slot-1 and slot-2 case statements.
- **`hw/rtl/cpu_and_mem/cpu/tomasulo/dispatch/dispatch.sv:383`** [high] Immediate-select case lists RV32 ops only; new RV64 ops (ADDIW, SLLIW/SRLIW/SRAIW, LWU, LD -> I-type; SD -> S-type; SLLI_UW, RORIW, W-form B-ext immediates) fall into the default arm which sets use_imm=0 and imm=0 — compiles and silently dispatches with no immediate. Slot-2 mirror at 555-588.
  - *Action:* Add every new immediate-form RV64 op to the I-type and S-type arms of both slot-1 and slot-2 case statements when the ops are added to instr_op_e.
- **`hw/rtl/cpu_and_mem/cpu/tomasulo/dispatch/dispatch.sv:272`** [medium] rs_type is pre-decoded in the ID stage and carried in from_id_to_ex_t (dispatch just casts it, lines 272-273/457-458). The RS-family routing for new RV64 ops (W-ops -> RS_INT/RS_MUL, LD/SD/LWU/AMO*.D -> RS_MEM, FCVT.L forms -> RS_FP) therefore lives in id_stage, NOT in these files — but dispatch's own case(op) lists (findings above) must be updated in lockstep or they silently diverge from the ID routing.
  - *Action:* Coordinate: whoever adds ops to the ID rs_type pre-decode must update dispatch's imm/mem_size/mem_signed cases in the same change.

### Mechanical (width/literal/comment hygiene)

- `hw/rtl/cpu_and_mem/cpu/tomasulo/dispatch/dispatch.sv:1204` [low] csr_write_data = {{(XLEN - 5) {1'b0}}, csr_imm} — parametric zero-extension of the CSR uimm5; correct per spec at XLEN=64 (uimm is always zero-extended). Slot-2 mirror at 1253-1255. Non-zero replication at both XLEN values, no lint hazard. Verified clean; listed because it is an extension point the widening must not disturb.
- `hw/rtl/cpu_and_mem/cpu/tomasulo/reservation_station/reservation_station.sv:714` [low] Payload-pack width comments ('// 32 imm', '// 32 branch_target', '// 32 predicted_target', '// 32 pc', '// 32 link_addr' at lines 715, 717, 719, 727, 728 and the slot-2 pack at 739-763) document 32-bit fields; the PayloadWidth expression (lines 661-663) is already XLEN-parametric so function is unaffected, but the comments go stale at XLEN=64.
- `hw/rtl/cpu_and_mem/cpu/tomasulo/reservation_station/reservation_station.sv:661` [low] PayloadWidth grows by 5*32 = 160 bits per entry (imm, branch_target, predicted_target, pc, link_addr), doubling the XLEN share of the 2-write-port distributed-RAM payload and the stage2/stage2b registers. mem_size stays 2 bits (2'(dispatch_mem_size) at 723/749, pl_mem_size_bits at 791) — adequate since mem_size_e already encodes DOUBLE.
- `hw/rtl/cpu_and_mem/cpu/tomasulo/reservation_station/reservation_station.sv:273` [low] int_rs_writes_cdb() excludes only BEQ..BGEU from CDB writeback; RV64 adds no new branch ops, and all new W-ops correctly fall into the default (writes CDB). Verified width-neutral and RV64-correct as-is.
- `hw/rtl/cpu_and_mem/cpu/tomasulo/register_alias_table/register_alias_table.sv:214` [low] RAT storage is tag-only (RatEntryWidth = 2 + ReorderBufferTagWidth; snapshot widths at 218-225 are XLEN-independent). Checkpoint save/restore, commit-clear, and rename write paths carry no data values — fully width-neutral. Only the regfile-passthrough concatenations (separate finding) touch XLEN.
- `hw/rtl/cpu_and_mem/cpu/tomasulo/dispatch/dispatch.sv:300` [low] x0 zero-detection uses '!= 5\'b0' (also line 478) and the intra-bundle RAW compares at 1071-1083 compare 5-bit RegAddrWidth addresses — all register-address width, independent of XLEN. Wakeup/tag-match logic throughout dispatch and the RS compares ReorderBufferTagWidth tags only. Confirmed width-neutral.

## ROB, commit, branch recovery, pipeline control

This subsystem is in unusually good shape for the RV64 respin: every assigned file except reorder_buffer.sv and frontend_validity_tracker.sv is either fully XLEN-parametric or width-independent, and the value path is already FLEN=64 end to end (ROB value RAMs, commit structs, regfile write data), so the int-result slice at commit (rob_commit.value[XLEN-1:0] in commit_actions.sv:141/164) becomes exactly right at 64 with no literal-31 anywhere. I found no bit-31 sign checks, no [4:0] shamt truncations, and no addr[1:0] word-index assumptions in these files. The real hazards are three: the FLEN-XLEN zero-width replications at reorder_buffer.sv:1008/1013 (lint-fragile once XLEN=64), the ucounter_onehot addr[7] aliasing that would keep treating cycleh/timeh/instreth as legal mcounteren-gated counters when RV64 requires them to be illegal CSRs, and the IF-stage RVC classifier arm that turns C.ADDIW into phantom control flow (latent today because its aggregate is unconsumed). The NARROW_DATA_WIDTH(XLEN) narrow-port config on all 12 rob_value replicas degenerates safely (the RAM primitive guards NARROW<DATA), but the area saving it bought evaporates, doubling alloc-bank LUTRAM in the X3 congestion band. Exception plumbing is clean: o_trap_pc/o_trap_value/mepc/csr_write_data are all XLEN-parametric, and the ROB exports only the ExcCauseWidth code - the 64-bit mcause interrupt-bit-63 assembly is entirely the trap-unit/csr_file's job (cross-subsystem check listed). JALR LSB clearing is not in these files (it lives in branch_jump_unit, instantiated by branch_resolution). AMO/LR/SC serialization is class-flag-based and needs zero ROB changes for the .D forms; SC failure detection via value[0] remains correct. The dominant timing exposure is the 64-bit branch-target equality in branch_resolution's documented critical mispredict cone, followed by the commit-side 64-bit next-PC adders that are already TIMING-annotated workarounds at 32 bits. The one genuine policy fork is whether ROB PC/target storage stays full 64-bit or compresses to the sub-4GiB physical width - that decision sets the size of nearly every widened compare and RAM in this subsystem.

### Hazards (compile-clean, silently wrong at XLEN=64)

- **`hw/rtl/cpu_and_mem/cpu/tomasulo/reorder_buffer/reorder_buffer.sv:1008`** [low] alloc_value_data = {{(FLEN - XLEN) {1'b0}}, i_alloc_req.link_addr}: at XLEN=64 the replication count becomes 0. Legal SV inside a concatenation but a per-tool lint hazard (Verilator/Yosys/Vivado disagree on warnings); same pattern at line 1013 for slot 2.
  - *Action:* Replace both with FLEN'(link_addr) casts (or guard with a generate if dual-XLEN is kept) so no zero-width replication is emitted.

### Design work (new logic or semantics)

- **`hw/rtl/cpu_and_mem/cpu/tomasulo/reorder_buffer/reorder_buffer.sv:387`** [medium] ucounter_onehot deliberately ignores csr addr[7] so the RV32 high-half counters (cycleh/timeh/instreth, 0xC80-0xC82) share the mcounteren enable bits. On RV64 those CSRs must not exist: with the mcounteren bit set, a U-mode access to 0xC8x sails past the ROB's priv-fault gate and relies entirely on csr_file to fault it; the alloc-time pre-decodes at lines 1113-1116/1140-1144 bake the same aliasing into rob_f_ucounter_*.
  - *Action:* On RV64 restrict the match to addr[7]==0 (0xC00-0xC02 only) and ensure 0xC80-0xC82 / 0xB80-0xB82 raise illegal-instruction in decode/csr_file; keeping the alias silently legalizes cycleh reads.
- **`hw/rtl/cpu_and_mem/cpu/cpu_ooo/frontend_control/frontend_validity_tracker.sv:184`** [low] IF-stage compressed control-flow classifier treats quadrant-01 funct3=3'b001 as C.JAL. On RV64 that encoding is C.ADDIW, so every C.ADDIW would be misclassified as unpredicted control flow (feeds if_unpredicted_control_flow_q -> front_end_control_flow_pending; that aggregate currently has no exported consumer, so the impact is latent/perf-only - but it compiles and misclassifies silently).
  - *Action:* Remove the c_funct3==3'b001 arm for RV64 (part of the RVC recode: C.JAL disappears, becomes C.ADDIW). PD/ID classifiers are safe - they key on the decompressed opcode.
- **`hw/rtl/cpu_and_mem/cpu/tomasulo/reorder_buffer/reorder_buffer.sv:2274`** [low] Exception plumbing is width-clean but interface-coupled: o_trap_cause stays an ExcCauseWidth exc_cause_t code (RAM at 1540-1554), o_trap_pc/o_trap_value are XLEN and correct at 64 (head_value[XLEN-1:0] takes the full FLEN=64 slot, so a 64-bit faulting address reaches mtval). The 64-bit mcause form (interrupt bit 63) and mepc width must be handled by the trap-unit/csr_file consumers - nothing in the ROB touches bit 31/63.
  - *Action:* No ROB change; verify the trap-unit consumer of o_trap_cause places the interrupt bit at 63 and zero-extends the code (cross-subsystem check).

### Mechanical (width/literal/comment hygiene)

- `hw/rtl/cpu_and_mem/cpu/tomasulo/reorder_buffer/reorder_buffer.sv:1347` [medium] All 12 rob_value RAM replicas set NUM_NARROW_WRITE_PORTS(2)/NARROW_DATA_WIDTH(XLEN) against DATA_WIDTH(FLEN). At XLEN=64 narrow==full width; verified lib/ram/mwp_dist_ram.sv guards this case safely (narrow-contract checks gated by NARROW_DATA_WIDTH < DATA_WIDTH, per-port width select degenerates), but the routability optimization the comment at 1315-1322 relies on (alloc banks store only the low XLEN of FLEN) silently evaporates: alloc-bank LUTRAM doubles across 12 replicas in the documented X3 congestion band.
- `hw/rtl/cpu_and_mem/cpu/tomasulo/reorder_buffer/reorder_buffer.sv:798` [low] head_link_is_compressed = (head_value[XLEN-1:0] == (head_pc + 32'd2)): semantically correct at XLEN=64 (32'd2 zero-extends in the 64-bit self-determined context), but the literal should be XLEN-sized for clarity and the equality becomes a 64-bit compare feeding o_commit_comb.is_compressed; same 32'd2/32'd4 literals at 799, 2322, 2493 in the fallthrough/next-PC adders.
- `hw/rtl/cpu_and_mem/cpu/tomasulo/reorder_buffer/reorder_buffer.sv:2042` [low] Alloc-time JAL misprediction detect (predicted_target != branch_target, also 2054-2056 for slot 2) widens from 32- to 64-bit equality in the dispatch/allocation cycle; correctness is parametric, cost is timing.
- `hw/rtl/cpu_and_mem/cpu/tomasulo/reorder_buffer/reorder_buffer.sv:2760` [low] Sim-only retire trace prints head_value_eff[31:0] with %08x and pc with %08x: at RV64 the trace silently truncates values and PCs, corrupting the debug artifact RV64 bring-up will lean on.
- `hw/rtl/cpu_and_mem/cpu/tomasulo/reorder_buffer/reorder_buffer.sv:1726` [low] Comment 'CSR write data RAM (32-bit, written at allocation)' goes stale; the RAM itself is DATA_WIDTH(XLEN) and widens correctly, carrying 64-bit csr_write_data through the commit record to csr_file.
- `hw/rtl/cpu_and_mem/cpu/cpu_ooo/branch_recovery/branch_resolution.sv:219` [medium] Target-misprediction compare branch_target_resolved != rs_issue_int.predicted_target widens to 64-bit equality at the head of the documented 16-level stage2_op -> branch_mispredicted -> early-mispredict-capture critical cone (the file's own comments cite this path at -0.739ns historically). Operand slices at 199-200 ([XLEN-1:0] of FLEN src values) are correct at 64.
- `hw/rtl/cpu_and_mem/cpu/cpu_ooo/branch_recovery/early_misprediction_recovery.sv:180` [low] early_mispredict_is_compressed capture: (rs_issue_int.link_addr == rs_issue_int.pc + 32'd2) - the literal zero-extends correctly at 64, but the equality/add become 64-bit in the capture cycle; literal should be XLEN-sized.
- `hw/rtl/cpu_and_mem/cpu/cpu_ooo/recovery/ex_comb_synthesizer.sv:137` [low] ras_push_address_after_restore = mispredict_commit_q.pc + (is_compressed ? 32'd2 : 32'd4) (also lines 142-143): correct at 64 via zero-extension, cosmetic literal width only.

## load/store queues, forwarding, AGU, memory request routing

The entire LQ/SQ memory subsystem is architected around a 32-bit data bus with FLEN=64 payload carriers, so FLD/FSD work today via explicit two-phase (word + word) state machines; RV64's real cost here is collapsing that to a single-beat 64-bit bus, which touches load_queue, store_queue, the router, and cached_tier_adapter simultaneously. The most dangerous silent-misbehavior hazards found: (1) the hand-tiled address comparators word_addr_eq/full_addr_eq/word_addr_inc_eq in store_queue.sv and sq_forwarding_unit.sv ignore all diff bits above [29]/[31], so at XLEN=64 forwarding and ordering CAMs report false address matches; (2) lq_l0_cache's MMIO decode uses XLEN-relative bits [XLEN-1:XLEN-2], which at 64 makes MMIO cacheable; (3) NaN-boxing concats {32'hFFFF_FFFF, xlen_data} silently truncate away the box at XLEN=64 in four places in load_queue.sv; (4) cached_tier_adapter's word-select addr[2+:] would return the wrong dword from a line; (5) the AMO ALU would run AMO*.W as full 64-bit operations; and (6) sq_forwarding_unit's 2-bit store_off misplaces sub-word store bytes in the 64-bit forwarded image. load_unit needs a full rebuild (8-byte extraction, LW sign-extension semantic change, LWU, LD). sc_pending_unit only matches SC_W and compares reservations at word granule; SC.D would deadlock at the ROB head if not added. Byte-enable plumbing is 4-lane end to end (SQ gen_byte_en, router muxes and hardcoded AMO 4'b1111 strobes, adapter wstrb math) and must become 8-lane. Misalignment detection already handles the 8-byte class, and the SQ data payload/forward mirrors are already FLEN=64, so those are free. Key policy calls: high-address-bit handling for all region decodes, stored-address truncation to keep the forwarding CAM and L0 tag compares narrow (both sit on documented critical paths at 300MHz), reservation granule, and 64-bit MMIO access support (CLINT mtime). lq_issue_selector is pure control logic and is the only assigned file that is clean as-is. Coverage: all eight small/medium files read in full; load_queue.sv and store_queue.sv were grep-driven with all data-path, AMO, reservation, drain, forwarding, and response regions read directly and only control-scan/formal regions skimmed.

### Hazards (compile-clean, silently wrong at XLEN=64)

- **`hw/rtl/cpu_and_mem/cpu/tomasulo/load_queue/load_unit.sv:110`** [high] Extraction covers only data[31:0] with addr[1:0]/addr[1] selects; at XLEN=64 LB/LH with addr[2]=1 pick the wrong byte/half from the 64-bit word, and the LW fallthrough (line 125) returns the raw 64-bit bus value with no word select and no sign-extension (RV64 LW must sign-extend); no LWU or LD distinction exists.
  - *Action:* Rebuild extractor for 8-byte data: addr[2:0] byte select (8 pre-extended bytes), addr[2:1] half select, new word select on addr[2] with sign/zero mux (LW/LWU), and LD passthrough; add size/unsigned control inputs accordingly.
- **`hw/rtl/cpu_and_mem/cpu/tomasulo/load_queue/lq_l0_cache.sv:94`** [high] lookup_mmio = i_lookup_addr[XLEN-1:XLEN-2]==2'b01 tests bits [63:62] at XLEN=64, which are always 0 for the sub-4GiB map, so MMIO addresses (0x4000_0000 quadrant) silently become cacheable and MMIO loads can be served stale from L0 (formal props at 233/271 have the same relative index).
  - *Action:* Decode MMIO at fixed bits [31:30] (subject to the high-bit policy), not XLEN-relative bits.
- **`hw/rtl/cpu_and_mem/cpu/tomasulo/load_queue/load_queue.sv:1728`** [high] FLW NaN-boxing {32'hFFFF_FFFF, lq_data_lo_rd} concatenates 32 + XLEN bits; at XLEN=64 the 96-bit concat is silently truncated to FLEN=64, keeping only the data and DROPPING the NaN-box — FLW results become unboxed and downstream single-precision consumers misbehave. Same pattern at 1831, 1841, 1859.
  - *Action:* Box explicitly as {32'hFFFF_FFFF, data[31:0]} at every producer; new FCVT.S.L/LU results elsewhere must match this convention.
- **`hw/rtl/cpu_and_mem/cpu/tomasulo/load_queue/load_queue.sv:1732`** [low] {{(FLEN - XLEN){1'b0}}, ...} becomes a zero-width replication at XLEN=64 — legal SV inside a concatenation but a per-tool lint/elaboration hazard; occurrences at 1732, 1834, 1844, 1853, 1875 (and sq_forwarding_unit.sv 557/559).
  - *Action:* Replace with direct FLEN-wide assignment (identity when FLEN==XLEN) during the widening pass; audit every FLEN-XLEN replication in the tree.
- **`hw/rtl/cpu_and_mem/cpu/tomasulo/load_queue/load_queue.sv:686`** [high] amo_compute is XLEN-wide and encode_amo_kind (349-361) maps only AMO*_W ops; at XLEN=64 AMO*.W silently performs 64-bit add/min/max/logic on the full dword instead of a 32-bit operation with the old value sign-extended into rd — wrong results whenever bit 31 or high half matters.
  - *Action:* Add a width bit to amo_kind; implement 32-bit sub-ALU + sign-extension for .W forms and full 64-bit ops for new AMO*.D; widen issued_amo_rs2/amo_write_data paths (already XLEN) accordingly.
- **`hw/rtl/cpu_and_mem/cpu/tomasulo/store_queue/store_queue.sv:276`** [high] word_addr_eq hand-tiles the comparator into six 5-bit groups covering only diff[29:0]; at XLEN=64 WordAddrWidth=62 and bits [61:30] of the XOR are silently IGNORED — false address equality, wrong store-to-load ordering/forwarding. full_addr_eq (297, covers [31:0]) and word_addr_inc_eq (337-342) have the same truncation; all three are duplicated in sq_forwarding_unit.sv (139-215).
  - *Action:* Re-tile the group structure for the full compare width (or narrow stored addresses to 32-bit physical per the address-width decision, keeping the current tiling).
- **`hw/rtl/cpu_and_mem/cpu/tomasulo/store_queue/store_queue.sv:363`** [high] gen_write_data returns XLEN-wide data but the lane replication is 32-bit-bus shaped: BYTE={4{..}}, HALF={2{..}}, WORD=data[31:0]; at XLEN=64 SB/SH only populate the low 4 bytes (stores with addr[2]=1 write garbage/zero lanes) and SW is zero-extended into the wrong lane for addr[2]=1 — silent wrong store data once strobes are widened.
  - *Action:* Replicate across 8 lanes ({8{byte}}, {4{half}}, {2{word}}) and pass the full 64-bit payload for DOUBLE (INT SD and single-beat FSD).
- **`hw/rtl/cpu_and_mem/cpu/tomasulo/store_queue/sq_forwarding_unit.sv:552`** [high] Forwarded-image reconstruction shifts raw[XLEN-1:0] by {store_off,3'b000} where store_off is captured as address[1:0] (2 bits, struct field line 110, capture 476); at XLEN=64 a sub-word store at addr[2]=1 lands in the wrong byte lanes of the 64-bit memory image — silent wrong forwarded data.
  - *Action:* Capture store_off as addr[2:0] (3 bits) and shift up to 56; widen fwd_load_byte_mask (270) to 8 lanes from i_sq_check_addr[2:0].
- **`hw/rtl/cpu_and_mem/cpu/cpu_ooo/memory_if/cached_tier_adapter.sv:119`** [high] Word/line lane math hardcodes 4-byte words: read_word_sel = pending_read_addr[2+:WordSelBits] and wstrb placement addr[OffsetBits-1:2]*4+:4 (line 111). If XLEN flips to 64, WordsPerLine halves to 4 and read_word_sel picks addr[3:2] instead of the dword index addr[4:3] — the adapter silently returns the WRONG DWORD from the line as valid data; strobe placement is similarly wrong.
  - *Action:* Index by addr[3+:WordSelBits], place strobes at addr[OffsetBits-1:3]*8+:8, widen i_write_byte_en/pending_write_byte_en to [7:0]; line width (256b) and replication are otherwise parametric.

### Design work (new logic or semantics)

- **`hw/rtl/cpu_and_mem/cpu/tomasulo/load_queue/lq_l0_cache.sv:74`** [medium] Line geometry is 4-byte words (index addr[2+:IndexWidth], addr[1:0] ignored) and TagWidth = XLEN-2-IndexWidth grows to 55 bits at XLEN=64; single-beat 8-byte loads need dword-granule lines and dword-granule invalidation, and the wide tag compare sits on the historically critical lookup-hit cone.
  - *Action:* Move to dword lines (index addr[3+:], data 64b) or keep word lines with dual lookup; decide 32-bit physical-address tag truncation to keep the compare narrow.
- **`hw/rtl/cpu_and_mem/cpu/tomasulo/load_queue/load_queue.sv:1444`** [medium] Two-phase FLD machinery (sq_check_fp64_phase_q +32'd4 second beat at 1444-1451, split lo/hi XLEN data RAMs at 479-512, phase-0/1 write steering 1574-1592, phase advance 2434-2439, re-issue 2330-2338) assumes a 32-bit data bus; with a 64-bit bus it does a redundant second fetch and the hi-half plumbing becomes vestigial.
  - *Action:* Collapse FLD (and new INT LD) to a single 64-bit beat: delete fp64_phase state, merge lq_data lo/hi into one FLEN RAM, remove the +4 address leg.
- **`hw/rtl/cpu_and_mem/cpu/tomasulo/load_queue/load_queue.sv:1442`** [medium] cache_hit_fast_path gates FP loads to WORD size but admits any INT load; a new INT LD (is_fp=0, size=MEM_SIZE_DOUBLE) would pass and consume a word-granule L0 entry. All 'is_fp && MEM_SIZE_DOUBLE' conjunctions (1574, 1580, 1723, 1773, 1799, 2330, 2435) encode 'DOUBLE implies FP' and break for INT LD.
  - *Action:* Re-key DOUBLE handling on size alone (single-beat for both INT LD and FLD after the bus widening); L0 eligibility follows the new line geometry.
- **`hw/rtl/cpu_and_mem/cpu/tomasulo/load_queue/load_queue.sv:707`** [medium] Cached-line invalidation snoop compares issued_addr at word granule [XLEN-1:2]; with single-beat 8-byte accesses word-granule compares here (and the wrapper reservation snoop) miss the second word of a dword access unless moved to dword granule.
  - *Action:* Move overlap/invalidate compares to [XLEN-1:3] once accesses are dword-granular; audit every [XLEN-1:2] compare in the LQ/SQ/wrapper for the same reason.
- **`hw/rtl/cpu_and_mem/cpu/tomasulo/store_queue/store_queue.sv:349`** [high] gen_byte_en produces [3:0] strobes from addr_offset[1:0]; a 64-bit data bus needs [7:0] strobes from addr[2:0] (BYTE=1<<off, HALF=3<<{off[2:1],1'b0}, WORD=0F<<(addr[2]*4), DOUBLE=FF). Duplicated in sq_forwarding_unit.sv 218-229 (load byte-mask side).
  - *Action:* Widen strobe generation to 8 lanes and thread the 8-bit strobe through o_mem_write_byte_en (752/819), the router, and the BRAM/cached write ports.
- **`hw/rtl/cpu_and_mem/cpu/tomasulo/store_queue/store_queue.sv:761`** [medium] FSD two-phase drain (fp64_phase second beat at sq_address+32'd4, completes gate at 785-787, plain-fast excludes DOUBLE at 787) assumes 32-bit bus; INT SD would also be forced through the two-phase path and DOUBLE would stay excluded from pipelined drain.
  - *Action:* Single-beat DOUBLE drain on the 64-bit bus; delete sq_fp64_phase and the +4 leg; let DOUBLE join the plain fast-drain pipeline.
- **`hw/rtl/cpu_and_mem/cpu/tomasulo/store_queue/sq_forwarding_unit.sv:356`** [high] The overlap model is word-based: same_word at [XLEN-1:2] plus special '+4 word' terms (double_hi_match/load_double_hi at 361-366) for DOUBLE; with dword-granule 64-bit accesses the whole size-compatibility matrix (cases 1-3 at 375-409, FwdExtractLoWord/HiWord) must be reworked to dword granule with LD/LWU/SD in the matrix.
  - *Action:* Redesign forwarding qualification at 8-byte granule: dword equality, per-byte overlap masks in one 8-lane vector, full-64 exact forward for SD->LD/FLD, and covered-subset forwarding for sub-dword loads.
- **`hw/rtl/cpu_and_mem/cpu/tomasulo/tomasulo_wrapper/atomics/sc_pending_unit.sv:155`** [medium] SC allocation predicate is 'op == riscv_pkg::SC_W' only; a future SC.D would never be tracked, so an SC.D at ROB head never fires and the core deadlocks (exactly the failure mode this table was built to fix).
  - *Action:* Match both SC_W and new SC_D (and record the size if success semantics ever need it).
- **`hw/rtl/cpu_and_mem/cpu/tomasulo/tomasulo_wrapper/atomics/sc_pending_unit.sv:166`** [medium] SC success compares reservation vs SC address at word granule [XLEN-1:2]; RV64 needs at least an 8-byte reservation granule for LR.D/SC.D, and the wrapper's snoop-invalidate compare (tomasulo_wrapper.sv 1305) uses the same word granule. SC result value at 181 is already correct (0/1 zero-extended into FLEN).
  - *Action:* Move reservation compares to dword granule [XLEN-1:3] (spec permits a larger granule, so this also stays correct for LR.W/SC.W); keep snoop-invalidate granule consistent.
- **`hw/rtl/cpu_and_mem/cpu/cpu_ooo/memory_if/data_mem_request_router.sv:236`** [high] Byte-enable plumbing is 4-lane throughout (ports 54/82/83/86, muxes 235-259) and AMO writes hardcode 4'b1111 — on a 64-bit bus an AMO.W must drive a lane-shifted 4-byte strobe (addr[2] selects the half) and AMO.D an 8-byte strobe; leaving 4'b1111 silently writes the wrong/partial lanes.
  - *Action:* Widen all strobe buses to [7:0]; derive AMO strobes from AMO size + addr[2]; SQ strobes arrive pre-widened from gen_byte_en.

### Policy (needs a project decision)

- **`hw/rtl/cpu_and_mem/cpu/tomasulo/tomasulo_wrapper/store_addr/sq_early_addr_pipeline.sv:458`** [medium] is_mmio decode is a fixed-bit test addr[31:30]==2'b01 (also 463/468/480/485/490); at XLEN=64 a computed effective address with nonzero bits [63:32] (e.g. 0x1_4000_0000) still matches and aliases into the MMIO quadrant — behavior for out-of-map high bits is a project policy decision affecting every region decode (this file, lq_l0_cache, router range compares, is_cached_addr).
  - *Action:* Decide high-bit handling: access-fault on addr[63:32]!=0, architectural truncation, or full 64-bit region decode; apply uniformly to all MMIO/cached/BRAM decodes.
- **`hw/rtl/cpu_and_mem/cpu/cpu_ooo/memory_if/data_mem_request_router.sv:148`** [medium] MMIO path is 32-bit-register oriented: range decode + single-word read data mux (357) and address-equality pulse decodes (375-378); a 64-bit MMIO LD (e.g. RV64 code reading CLINT mtime in one load) has no data path, and what LD/SD to MMIO should do (support, split, or fault) is undecided.
  - *Action:* Decide MMIO access-width policy: either add a 64-bit MMIO read/write sideband (mtime as one LD) or restrict MMIO to <=32-bit accesses and document/enforce (fault or software convention).

### Mechanical (width/literal/comment hygiene)

- `hw/rtl/cpu_and_mem/cpu/tomasulo/load_queue/load_queue.sv:70` [low] CACHED_BASE/CACHED_SIZE_BYTES are 32-bit 'int unsigned' parameters later part-selected as CACHED_BASE[XLEN-1:0] (line 343-344); at XLEN=64 that is an out-of-range part-select of a 32-bit value (compile error / tool-dependent). Same pattern: store_queue.sv 63-64/776-784, data_mem_request_router.sv 39-45/131-133/149/159/181/186.
- `hw/rtl/cpu_and_mem/cpu/tomasulo/load_queue/load_queue.sv:1625` [medium] lq_data_hi_wd[1] = i_sq_forward.data[FLEN-1:XLEN] becomes the reversed/null range [63:64] at XLEN=64 — a compile error, and the lo/hi split it feeds becomes 128 bits of storage for a 64-bit payload (same range also in sq_forwarding_unit.sv 559 and its FORMAL refs 397/406).
- `hw/rtl/cpu_and_mem/cpu/tomasulo/load_queue/load_queue.sv:329` [low] is_load_misaligned already implements the 8-byte class (MEM_SIZE_DOUBLE -> |addr[2:0]), so LD/SD/LR.D/SC.D/AMO*.D misalign detection is free once INT ops carry size=DOUBLE; no change needed here.
- `hw/rtl/cpu_and_mem/cpu/tomasulo/tomasulo_wrapper/store_addr/sq_early_addr_pipeline.sv:424` [low] The four store-AGU adders (424-441) are XLEN-parametric and widen cleanly to 64-bit; imm is [XLEN-1:0] in rs_dispatch_t so base+imm widening is mechanical, but the CARRY8 chains double in length (registered inputs, so slack likely absorbs it).
- `hw/rtl/cpu_and_mem/cpu/tomasulo/load_queue/lq_issue_selector.sv:36` [low] Pure control/selection logic over valid/issued/ROB-tag masks with no address or data widths; unaffected by the XLEN flip.

## CSR file and trap unit (csr_file.sv, trap_unit.sv, plus CSR-facing perf-counter widths)

Both assigned modules are XLEN-parameterized in their port/datapath declarations, so most architectural registers (mepc, mtval, mscratch, mtvec, exception PC/cause/tval pipeline) widen for free; the danger is concentrated in literals and constants that zero-extend silently. The two highest-value hazards: (1) trap_unit assigns the riscv_pkg IntMachine* constants (bit [31:0], 32'h8000_000x) into the XLEN-wide interrupt_cause, so at XLEN=64 the mcause interrupt bit lands at bit 31 instead of 63 - every interrupt reads as a bogus synchronous exception, and the module's own case-compare and formal properties use the same zero-extended constants so nothing catches it; (2) csr_file's MisaValue (32'h4010_112F) zero-extends to give MXL=0 with a stray reserved bit 30. A third silent failure is the counter read mux, which returns cycle_counter[31:0]/i_mtime[31:0]/instret_counter[31:0] zero-extended - RV64 requires full 64-bit single-CSR reads, and the five high-half addresses (0xC80-0xC82, 0xB80, 0xB82) must newly raise illegal-instruction, which requires touching the ROB's Zicntr pre-decode (the mcounteren fault term at reorder_buffer.sv:761-763) because csr_file has no illegal-CSR path of its own - unknown CSRs currently read as 0. mstatus is composed from individual field flops via a 32-bit concat and needs the design rework: UXL=2 hardwired at [33:32], SD at 63, with the existing MIE/MPIE/MPP/MPRV bit positions and write extraction unchanged. mcounteren correctly stays a 32-bit, 3-bit-storage WARL CSR; its base-counter U-mode gate survives, only the *h address classification changes. Everything else - mepc bit-0 masking, mtvec mode handling, the interrupt hold/arming machinery, WFI, drain-wait - is width-agnostic and mechanical. The perf-counter modules are already 64-bit on their CSR-facing buses and are unaffected; only the split MperfData/MperfDataH readback is a low-stakes policy call. Remaining policy items are the high-address-bit treatment for trap/return targets under the sub-4-GiB map and whether the *h-CSR illegality ride-along becomes a general unimplemented-CSR fault. Timing exposure is modest and mostly in the already-sensitive take_trap/redirect cone and the widened CSR read mux; the instret carry-chain retime rationale is preserved as long as the counter stays 64-bit with the staged increment.

### Hazards (compile-clean, silently wrong at XLEN=64)

- **`hw/rtl/cpu_and_mem/cpu/csr/csr_file.sv:219`** [high] MisaValue = 32'h4010_112F assigned to logic [XLEN-1:0]. At XLEN=64 this zero-extends to 64'h0000_0000_4010_112F: MXL at [63:62] reads 0 (invalid) and the old RV32 MXL=1 bit lands at reserved bit 30. misa must become 64'h8000_0000_0010_112F (MXL=2, letters A/B/C/D/F/I/M/U unchanged). Compiles clean, silently reports a malformed misa.
  - *Action:* Replace literal with XLEN-conditional value: MXL=2 in [63:62], extension letters in [25:0]; drop bit 30. Update the comment block at lines 215-218 and header line 41 (0x4010_112F).
- **`hw/rtl/cpu_and_mem/cpu/control/trap_unit.sv:360`** [high] interrupt_cause_comb is assigned riscv_pkg::IntMachineExternal/Software/Timer, which are bit [31:0] constants 32'h8000_000B/3/7 (riscv_pkg.sv:742-744). At XLEN=64 they zero-extend into the 64-bit interrupt_cause, putting the mcause interrupt bit at bit 31 instead of bit 63. mcause written on interrupt entry reads as a giant synchronous-exception code; any handler testing mcause<0 (Linux does) misroutes every interrupt. The case at lines 382-386 and formal props at 550/555/560 compare the same zero-extended constants so they stay self-consistent and nothing fails in sim/formal - fully silent.
  - *Action:* Make IntMachine* constants XLEN-wide with bit XLEN-1 set (1<<63 | code) in riscv_pkg; trap_unit then inherits correct values through interrupt_cause_comb, the interrupt_latched_source_enabled case, and the formal properties.
- **`hw/rtl/cpu_and_mem/cpu/csr/csr_file.sv:538`** [high] cycle/mcycle read returns cycle_counter[31:0] (and instret/minstret return instret_counter[31:0] at 542, time returns i_mtime[31:0] at 540). At XLEN=64 these zero-extend into the 64-bit read mux: RV64 requires full 64-bit reads of cycle/time/instret/mcycle/minstret. Compiles clean; Linux timekeeping would silently see a 32-bit-wrapping counter.
  - *Action:* Return full cycle_counter, i_mtime, instret_counter (64 bits) for the base addresses.

### Design work (new logic or semantics)

- **`hw/rtl/cpu_and_mem/cpu/csr/csr_file.sv:539`** [medium] CsrCycleH/CsrMcycleH (539), CsrTimeH (541), CsrInstretH/CsrMinstretH (543-544) decode and return high halves. On RV64 addresses 0xC80/0xC81/0xC82/0xB80/0xB82 do not exist and accesses must raise illegal-instruction. csr_file has no illegal-CSR mechanism (default reads 0, line 564); the counter-CSR fault path lives in the ROB (reorder_buffer.sv:471-475, 761-763), whose Zicntr pre-decode currently classifies cycleh/timeh/instreth as mcounteren-gated U-counters and would keep them U-legal when the enable bit is set.
  - *Action:* Delete the *H arms from the read mux here AND change the ROB's Zicntr pre-decode so 0xC80-0xC82/0xB80/0xB82 fault unconditionally (all privileges), while 0xC00-0xC02 keep the CY/TM/IR mcounteren gate. Coordinate with the general illegal-CSR policy decision.
- **`hw/rtl/cpu_and_mem/cpu/csr/csr_file.sv:173`** [medium] mstatus composed as a 32-bit concat {14'b0, mprv, 4'b0, mpp, 3'b0, mpie, 3'b0, mie, 3'b0} assigned to logic [XLEN-1:0]. At XLEN=64 it zero-extends: UXL[33:32] reads 0 (reserved/illegal - RV64 with U-mode must read UXL=2) and SD stays 0 at bit 63 (acceptable while FS is unimplemented). Compiles clean, silently non-conformant.
  - *Action:* Rebuild as 64-bit: SD=0 at bit 63, WPRI padding, UXL=2'd2 hardwired at [33:32], then the existing low-32 layout; UXL read-only (write path at 422-428 already ignores it since mstatus is rebuilt from fields). MIE/MPIE/MPP/MPRV write extraction (csr_new_value[3]/[7]/[12:11]/[17]) unchanged.

### Policy (needs a project decision)

- **`hw/rtl/cpu_and_mem/cpu/csr/csr_file.sv:558`** [low] Custom mperfdata/mperfdatah keep a split 32-bit pair (reads i_perf_counter_data[31:0] / [63:32]); mperfcount (560) assigns a [31:0] input into the 64-bit mux (zero-extend, fine). The split pair is legal on RV64 (custom CSR space) but MperfData could return the full 64 bits.
  - *Action:* Decide: keep split pair (no RTL change, profiling tools unchanged) or make MperfData 64-bit and drop/alias MperfDataH. Update header comment lines 55-60 either way.
- **`hw/rtl/cpu_and_mem/cpu/csr/csr_file.sv:482`** [medium] mtvec write {csr_new_value[XLEN-1:2], 1'b0, csr_new_value[0]} and mepc write {csr_new_value[XLEN-1:1], 1'b0} (485) are cleanly parametric, but at XLEN=64 they let software install trap/return targets with bits [63:32] set, which the sub-4-GiB physical map cannot fetch. Whether these CSRs hold full 64 bits or WARL-zero the high bits is the project's high-address-bit policy.
  - *Action:* Decide unmapped-high-bit policy (full 64-bit WARL pass-through vs hardwired-zero [63:32]); apply consistently to mtvec/mepc and the fetch redirect they feed.

### Mechanical (width/literal/comment hygiene)

- `hw/rtl/cpu_and_mem/cpu/csr/csr_file.sv:467` [low] Reset literals 32'h0000_0000 assigned to XLEN-wide mtvec/mscratch/mepc/mcause/mtval (467-472). Zero-extends correctly at XLEN=64 but is a 32-vs-64 width-mismatch lint hit per tool.
- `hw/rtl/cpu_and_mem/cpu/csr/csr_file.sv:159` [low] Fixed-width zero-pad concats produce 32-bit values assigned/compared to XLEN-wide signals: fcsr {24'b0,...} (159), mie {20'b0,...} (183), mip (213), csr_current_value fflags/frm/mcounteren {27'b0}/{29'b0}/{29'b0} (242/243/249), read-mux equivalents (534/535/536/550), and the formal p_mip_reflects_inputs concat (686). All zero-extend to correct values at XLEN=64 but each is a width-mismatch lint hazard; mcounteren correctly stays a 32-bit CSR whose read zero-extends into 64-bit rd.
- `hw/rtl/cpu_and_mem/cpu/control/trap_unit.sv:459` [low] Vectored target: {i_mtvec[XLEN-1:2], 2'b00} + {26'b0, vectored_offset}. The {26'b0, offset} concat is self-determined 32 bits, zero-extended in the 64-bit addition - value correct at XLEN=64 but a fixed-width pad that no longer matches XLEN (lint hazard).
- `hw/rtl/cpu_and_mem/cpu/control/trap_unit.sv:382` [low] interrupt_latched_source_enabled case labels and formal priority/cover properties (550, 555, 560, 601) use the 32-bit IntMachine* constants against XLEN-wide interrupt_cause. Once the constants are widened (bit 63 set) these follow automatically; today both sides zero-extend identically, which is exactly why the line-360 hazard is invisible to formal.
- `hw/rtl/cpu_and_mem/cpu/control/trap_unit.sv:124` [low] All architectural datapaths (i_mstatus/i_mie/i_mtvec/i_mepc, exception cause/tval/pc registers at 287-308, o_trap_target/o_trap_pc/o_trap_cause/o_trap_value) are [XLEN-1:0] parametric; mie bit extraction uses MieM*iBit indices (172-174), XLEN-independent; mepc bit-0 masking lives in csr_file (485) and the formal assume (601) only constrains bit 0 - IALIGN=16 semantics unchanged at 64. Interrupt hold/arming/drain-wait/WFI machinery is width-agnostic.
- `hw/rtl/cpu_and_mem/cpu/csr/csr_file.sv:29` [low] Header/doc block (29-33, 41, 59) describes cycle/cycleh pairs, 'low 32 bits', and RV32 misa 0x4010_112F; all become stale with the RV64 counter and misa changes.
- `hw/rtl/cpu_and_mem/cpu/cpu_ooo/perf/perf_counter_aggregator.sv:76` [low] CSR-facing widths are XLEN-independent: perf data buses [63:0] (76, 78), select [7:0] (73, 77), count [31:0] (79); internal counters all [63:0]. No XLEN references; unaffected by the flip.
- `hw/rtl/cpu_and_mem/cpu/tomasulo/tomasulo_wrapper/perf/tomasulo_perf_counters.sv:100` [low] CSR-facing width is o_perf_counter_data [63:0] (100) with [63:0] internal counters; select [7:0]. No XLEN dependence.

## OoO top-level glue and register files (tomasulo_wrapper, cpu_ooo, ooo_register_files, generic_regfile)

This glue layer is in better shape than expected: the FLEN=64 value plumbing (CDB, ROB values, RS dispatch, bypass network, FP regfile) already moves 64-bit data, and ooo_register_files.sv plus generic_regfile.sv are verified fully clean-parametric - flipping riscv_pkg::XLEN widens them correctly with roughly 2x INT-regfile LUTRAM (mwp_dist_ram LVT primitive, 8 read ports) and 2x bypass-mux width as the only costs. The dangerous findings cluster in three places. First, the atomics glue in tomasulo_wrapper hardcodes the W-form op set: LR_W/SC_W/AMO*_W classification (2841-2850, 3046, 1377/1382) and a 4-byte reservation granule compare (1306) would let future LR.D/SC.D/AMO*.D silently bypass the atomics machinery or hold stale reservations. Second, the memory-side glue mixes XLEN-wide data buses with hardcoded [3:0] byte enables (wrapper 443, cpu_ooo 72/79/84/1038) and decodes memory tiers from bits [31:30] alone (2877/3119) - at XLEN=64 the data path widens automatically but the enables and tier decode do not, which is exactly the compile-and-misbehave class; the 32-bit CACHED_/MMIO_ parameters need a deliberate high-address-bit policy. Third, the three {(FLEN-XLEN){1'b0}} concatenations (886/946/1419) become zero-width replications - semantically identity, but a per-tool lint hazard that must be rewritten. One genuine width mismatch exists: cpu_ooo's i_served_addr port is hardcoded [31:0] against if_stage's [XLEN-1:0] declaration. The AMO ALU does not live in these files (it is in load_queue; the wrapper only forwards operands/ports), there is no pending-write FIFO between commit and regfile (direct 2-port XLEN-wide writes plus a delayed-CSR arm in commit_actions), boot-PC injection is in if_stage, and nothing here touches NaN-boxing. Timing exposure concentrates where the audit brief predicted: the CDB value replicas and wakeup fanout, the MEM_RS effective-address adders, and the regfile bypass network all sit on documented sub-nanosecond-margin paths and double in width.

### Hazards (compile-clean, silently wrong at XLEN=64)

- **`hw/rtl/cpu_and_mem/cpu/tomasulo/tomasulo_wrapper/tomasulo_wrapper.sv:886`** [medium] cdb_bus_int_rs_qualified.value = {{(FLEN - XLEN){1'b0}}, cdb_bus_int_rs_value}: at XLEN=64 this is a zero-width replication inside a concatenation. Semantically it becomes an identity copy (correct), but zero-width replication is a per-tool lint/compile hazard (Verilator/Yosys/Vivado disagree). Same pattern at line 946 (lane 1).
  - *Action:* Guard with generate (if FLEN>XLEN) or replace with FLEN'(cdb_bus_int_rs_value) cast; audit both lanes (886, 946).
- **`hw/rtl/cpu_and_mem/cpu/tomasulo/tomasulo_wrapper/tomasulo_wrapper.sv:1419`** [medium] store_misalign_fu_complete.value = {{(FLEN - XLEN){1'b0}}, sq_effective_addr}: third zero-width-replication site (parks misaligned store address for mtval). Becomes identity at XLEN=64 but same lint hazard.
  - *Action:* Same fix as lines 886/946: FLEN'() cast or generate guard.
- **`hw/rtl/cpu_and_mem/cpu/tomasulo/tomasulo_wrapper/tomasulo_wrapper.sv:2877`** [high] lq_addr_is_mmio = (lq_effective_addr[31:30] == 2'b01) (same at 3119 for stores) inspects only bits [31:30] of the now-64-bit effective address. An address with nonzero bits [63:32] but [31:30]==01 silently classifies as MMIO; any high-half garbage aliases into the 4 GiB map. MmioBase localparam (2875) is XLEN-wide from a 32-bit literal (zero-extends, currently unused in logic).
  - *Action:* Decide the [63:32] policy (fault, or require-zero and qualify tier decode with |addr[63:32]); today's quadrant decode compiles and misbehaves silently.

### Design work (new logic or semantics)

- **`hw/rtl/cpu_and_mem/cpu/tomasulo/tomasulo_wrapper/tomasulo_wrapper.sv:1306`** [high] LR/SC reservation snoop-invalidate compares sq_cache_invalidate_addr[XLEN-1:2] == lq_reservation_addr[XLEN-1:2] - a 4-byte reservation granule. With LR.D/SC.D the granule must cover 8 bytes; keeping word-granule comparison lets an SD or SW to the other word of a reserved doubleword fail to invalidate the reservation, so SC.D succeeds after an intervening store (silent atomicity violation).
  - *Action:* Widen reservation granule to at least 8 bytes ([XLEN-1:3]) or make it size-aware; decide granule size (8B vs cache line) as part of LR.D/SC.D support.
- **`hw/rtl/cpu_and_mem/cpu/tomasulo/tomasulo_wrapper/tomasulo_wrapper.sv:2841`** [high] make_lq_alloc: r.is_lr = (op == LR_W) only; r.is_amo enumerates only AMO*_W ops (lines 2842-2850). New LR_D/AMO*_D ops would allocate as plain loads and bypass the entire atomics machinery (interrupt shield, single-outstanding gate, AMO write path) - silent misbehavior once RV64A decode exists.
  - *Action:* Add LR_D and all nine AMO*_D enum values to the classification; r.amo_op = dispatch.op pass-through is fine. The AMO ALU itself lives in load_queue (not this file) and needs .D width plus AMO*.W sign-extension there.
- **`hw/rtl/cpu_and_mem/cpu/tomasulo/tomasulo_wrapper/tomasulo_wrapper.sv:3046`** [high] make_sq_alloc: r.is_sc = (op == SC_W) only; SC_W-only exclusions also at lines 1377 and 1382 (store_misalign_issue / store_issue_fire). SC.D would take the plain-store completion path instead of the sc_pending_unit hand-off - silent wrong result register value and broken atomicity.
  - *Action:* Extend all three SC_W comparisons to also match SC_D.
- **`hw/rtl/cpu_and_mem/cpu/tomasulo/tomasulo_wrapper/tomasulo_wrapper.sv:443`** [high] o_sq_mem_write_byte_en is hardcoded [3:0] while o_sq_mem_write_data (442) is [XLEN-1:0]. At XLEN=64 the data bus doubles but only 4 byte lanes exist: SD/FSD drain of the upper 4 bytes is silently impossible (today FSD double-pumps two 32-bit beats through the SQ). Mirrored in cpu_ooo.sv:1038 (sq_mem_write_byte_en), cpu_ooo.sv:72/79/84 (o_data_mem_per_byte_wr_en, o_data_mem_bram_byte_wr_en, o_data_mem_cached_byte_wr_en).
  - *Action:* Widen byte enables to [XLEN/8-1:0] end-to-end (wrapper, cpu_ooo, data_mem_request_router, BRAM/cached tiers) and rework the SQ 8-byte double-pump into single-beat 64-bit writes; likewise i_lq_mem_read_data (455) becomes single-beat for LD/FLD, obsoleting the LQ beat-assembly.

### Policy (needs a project decision)

- **`hw/rtl/cpu_and_mem/cpu/tomasulo/tomasulo_wrapper/tomasulo_wrapper.sv:52`** [medium] CACHED_BASE/CACHED_SIZE_BYTES are 'parameter int unsigned' with 32'h8000_0000 / 32'h4000_0000 literals, forwarded to load_queue/store_queue for cached-tier decode against XLEN-wide addresses. At XLEN=64 the compares zero-extend; high address bits make cached-tier decode alias (same policy question as MMIO decode). cpu_ooo.sv has the identical params at lines 33-40 (plus MMIO_ADDR/MMIO_SIZE_BYTES).
  - *Action:* Pick param type (longint unsigned or logic [XLEN-1:0]) and the high-bit policy once; apply to wrapper, cpu_ooo, and the router they feed.
- **`hw/rtl/cpu_and_mem/cpu/cpu_ooo/cpu_ooo.sv:31`** [medium] cpu_ooo declares 'parameter XLEN = riscv_pkg::XLEN' and forwards .XLEN() to if_stage/pd_stage/id_stage/ooo_register_files/commit_actions/trap_unit/csr_file/router, but tomasulo_wrapper (line 1168 instantiation) has no XLEN parameter and all riscv_pkg-typed struct ports bake in riscv_pkg::XLEN. Overriding cpu_ooo's XLEN independently of the package would elaborate mismatched widths - the dual-XLEN parameterization is illusory.
  - *Action:* Decide: rv64-only flip of riscv_pkg::XLEN (module params become aliases, simplest) vs true dual-XLEN build (requires parameterizing every riscv_pkg struct - large). Recommend documenting the package localparam as the single source of truth.
- **`hw/rtl/cpu_and_mem/cpu/cpu_ooo/cpu_ooo.sv:147`** [low] perf_counter_count is [31:0] feeding csr_file i_perf_counter_count; fixed 32-bit event count read through a CSR that becomes 64-bit. Zero-extends on read - functional, but wraps at 2^32 events.
  - *Action:* Decide whether custom perf-count CSRs stay 32-bit-wrapping on RV64 or widen; cosmetic either way.

### Mechanical (width/literal/comment hygiene)

- `hw/rtl/cpu_and_mem/cpu/tomasulo/tomasulo_wrapper/tomasulo_wrapper.sv:742` [medium] cdb_bus_int_rs_value (and cdb_bus_2_int_rs_value at 752, loads at 860/932) are deliberately XLEN-wide dont_touch/max_fanout=64 local CDB value replicas placed to fix the X3 congestion hotspot. At XLEN=64 each replica doubles to 64 live flops with full RS-snoop fanout; the comment documents these nets were among the worst failing endpoints of the routed design.
- `hw/rtl/cpu_and_mem/cpu/tomasulo/tomasulo_wrapper/tomasulo_wrapper.sv:2869` [medium] lq_effective_addr = src1_value[XLEN-1:0] + o_mem_rs_issue.imm (sq twin at 3115): rs_dispatch_t.imm is already [XLEN-1:0] so the math widens cleanly, but this is the adder the code comments call the critical RAT->dispatch->adder->SQ path (sq_early_addr_pipeline exists solely to break it at 32 bits). It becomes a 64-bit CARRY8 chain feeding the misalign check and store_misalign CDB packet.
- `hw/rtl/cpu_and_mem/cpu/tomasulo/tomasulo_wrapper/tomasulo_wrapper.sv:1252` [low] is_mem_access_misaligned already implements MEM_SIZE_DOUBLE (|addr[2:0]) for FLD/FSD; LD/SD/LR.D/SC.D/AMO*.D reuse it unchanged. No change needed - recorded so it is not re-flagged.
- `hw/rtl/cpu_and_mem/cpu/cpu_ooo/cpu_ooo.sv:50` [medium] input logic [31:0] i_served_addr is hardcoded 32-bit but if_stage.sv:104 declares the matching port [XLEN-1:0] and compares it against pc_reg_word[XLEN-3:0]; the pass-through connection at line 463 silently zero-extends at XLEN=64, truncating the fetch-window address tag the provider supplies (fetch_provider side also needs widening).
- `hw/rtl/cpu_and_mem/cpu/cpu_ooo/cpu_ooo.sv:2357` [low] interrupt_resume_pc <= rob_trap_pc + 32'd4 for the WFI mepc seed: the 32-bit literal context-extends correctly in a 64-bit addition, so behavior is right; flagged only as a width-literal cleanliness item ('d4 or XLEN'(4)).
- `hw/rtl/cpu_and_mem/cpu/cpu_ooo/cpu_ooo.sv:263` [low] The verilator public_flat_rd debug taps (dbg_commit_pc 263, dbg_commit_value 1949, dbg_port0_int_data 322, dbg_trap_cause_internal 317, etc.) are all [XLEN-1:0] and widen automatically to 64. RTL is clean, but every hang_triage/cocotb consumer that reads them as 32-bit Python ints or formats %08x (e.g. the $error strings at 2370/2376) will truncate or misprint.
- `hw/rtl/cpu_and_mem/cpu/cpu_ooo/register_files/ooo_register_files.sv:184` [low] Integer regfile: generic_regfile DATA_WIDTH=XLEN, 8 read ports, 2 write ports via mwp_dist_ram (LVT-steered distributed LUTRAM, one RAM instance per read port). At XLEN=64 the INT file's LUTRAM cost doubles (8 ports x 32 additional bits) and the 8 XLEN-wide write-back bypass 2:1 muxes plus final bypass selects (lines 254-266, 301-313) double in width on the ID/dispatch/RAT operand path.
- `hw/rtl/cpu_and_mem/cpu/cpu_ooo/register_files/ooo_register_files.sv:36` [low] Whole module audited line-by-line: every data slice is N*XLEN / N*FpW form, all compares are 5-bit addresses, no literals, no sign-extends, no FLEN-XLEN sites. Verified clean-parametric; FP side untouched (FpW=64 stays).
- `hw/rtl/cpu_and_mem/cpu/wb_stage/generic_regfile.sv:36` [low] Fully parameterized (DATA_WIDTH/NUM_READ_PORTS/NUM_WRITE_PORTS/HARDWIRE_ZERO/DEPTH); primitives sdp_dist_ram / mwp_dist_ram per read port. Only staleness: header comment (line 21) says integer file is '32-bit'.
- `hw/rtl/cpu_and_mem/cpu/tomasulo/tomasulo_wrapper/tomasulo_wrapper.sv` [resolved, timing-only] The former XLEN-sliced three-arm `cdb_arb_in_7.value` mux is gone. Both integer ALUs now retain an exact generic effective packet while splitting the full FLEN value into a raw live-shim path and a held/test-injection tree fallback. At RV64, XLEN=FLEN and both paths are naturally 64 bits; wrapper and arbiter formal assertions prove their recomposition, so there is no remaining width-specific hazard.

## SoC top, memory tiers, caches, peripherals, sim harness

This subsystem is largely address-map plumbing, and its RV64 exposure concentrates in two places: the 32-bit data tier and the physical-address policy. The core<->memory data path (cpu_and_mem.sv:234-259) is genuinely 32 bits wide today - FLD/FSD are two word-width phases in the SQ/LQ, verified in store_queue.sv:356/370 and load_queue.sv:2331 - so RV64 LD/SD/AMO*.D/LR.D need a real 64-bit tier: BRAM DATA_WIDTH, byte enables, cached_tier_adapter XLEN, and the MMIO read/write path all widen together, and phasing is not an acceptable fallback because a phased LD of mtime violates single-copy atomicity and AMO*.D cannot be split. The CLINT is the sharpest functional item: mtime/mtimecmp are 64-bit registers reachable only through 32-bit lo/hi word decodes, while RV64 Linux issues single 8-byte LD/SD against them. The nastiest silent hazards found: the FROST_XILINX_PRIMS FDRE loop hardcoded to 32 bits (hardware-only undriven upper half after widening), the sw.mem init-file format silently corrupting a 64-bit-widened BRAM via $readmemh token-width mismatch, cpu_tb's unused XLEN parameter with hardcoded [31:0] wildcard-connected taps, and bit-31 tier selects meeting RV64's sign-extended lui/auipc address constants. The recommended posture, consistent with the unchanged sub-4-GiB map, is to canonicalize 64-bit addresses to 32 bits at one documented point in the core, after which the cache hierarchy (frost_cache, hierarchy, arbiter, AXI bridge, behavioral DDR) needs essentially nothing - it is line-granular, ADDR_WIDTH-parameterized, and XLEN-free, with only the AXI bridge's hardcoded [31:0] addr_q as a latent trap if ADDR_WIDTH were ever raised. UARTs, FIFOs, and the RAM library are parameterized and unaffected, with the one caveat that tdp_bram_dc_byte_en couples its address-port and init-file format to DATA_WIDTH. Timing risk clusters on the widened BRAM write-data cascade (a previously closed WNS path) and the doubled MMIO/LQ read-data mux, not on the caches. frost.sv itself carries no PC/reset-vector logic and needs only parameter pass-through.

### Hazards (compile-clean, silently wrong at XLEN=64)

- **`hw/rtl/cpu_and_mem/cpu_and_mem.sv:1061`** [high] FROST_XILINX_PRIMS FDRE generate loop is hardcoded 'g_mmio_read_data < 32'. If mmio_read_data_reg widens to 64, bits [63:32] are silently undriven in the Vivado build only - sim (portable path, line 1074) would pass while hardware returns X/0 upper halves.
  - *Action:* Bound the loop by $bits(mmio_read_data_reg) instead of literal 32.
- **`hw/rtl/cpu_and_mem/cpu_and_mem.sv:707`** [high] Data BRAM instantiated with DATA_WIDTH(32) and INIT_FILE("sw.mem") (objcopy --verilog-data-width 4 tokens). If DATA_WIDTH is flipped to 64 for the widened tier, $readmemh loads each 4-byte token into a 64-bit row (upper half zero, depth halved) - a silently corrupt memory image. imem (line 657) must stay 32-bit-word organized for the predecode sideband, so imem and dmem would need different init formats from the same program image.
  - *Action:* If dmem goes 64-bit: emit a second init file at --verilog-data-width 8 (or keep dmem as 2 interleaved 32-bit banks), and update tests/build plumbing that shares sw.mem.
- **`hw/rtl/cpu_and_mem/cpu_and_mem.sv:542`** [high] Fetch tier select is program_counter[31] (registered at 542-546, transition detect at 557). On RV64, LUI/AUIPC/ADDIW-formed addresses are sign-extended, so a jump target built as 'li t0, 0x80000000' arrives as 0xFFFF_FFFF_8000_0000. If the widened PC is truncated to [31:0] at this seam, bit 31 still selects the cached tier correctly - but only under an explicit 'bits [63:32] ignored' policy. If instead high bits are preserved into wider compares elsewhere (fetch_provider tags), the same code would silently miss every tag compare.
  - *Action:* Adopt and document a single canonicalization point: truncate/validate the 64-bit PC and data addresses to the 32-bit physical map once (in cpu_ooo or at this boundary), so all downstream [31]-bit tier selects and 32-bit tag compares remain sound.
- **`hw/rtl/cpu_and_mem/fetch_provider.sv:222`** [medium] fetch_high = fetch_addr[31] (also ask_q[31] at 294, i_pc[31] at 381, served_addr_q[31] in the SYNTHESIS-off assertion at 407): bit 31 doubles as the cached-tier discriminator. Same sign-extended-address exposure as cpu_and_mem line 542 - correct only under a canonicalized 32-bit physical address.
  - *Action:* Covered by the single canonicalization policy; no local change if addresses are truncated before this module.
- **`hw/sim/cpu_tb.sv:22`** [high] cpu_tb declares 'parameter int unsigned XLEN = 32' but never uses it for widths: o_pc/o_data_mem_addr/o_data_mem_wr_data/i_data_mem_rd_data/o_mmio_load_addr/debug PCs are all literal [31:0] (29-37, 60, 74, 96-98) and byte enables [3:0] (35-36). The wildcard .* connection to cpu_ooo (203) will width-mismatch every widened port - Verilator errors, other tools silently truncate.
  - *Action:* Rewrite the bench taps in terms of riscv_pkg::XLEN so flipping the package parameter propagates; also widen the tb data memory (DATA_WIDTH(32) at 175) and o_pc[31:2]+1 served-word math (128) in lockstep.
- **`hw/rtl/lib/cache/line_port_axi_bridge.sv:89`** [low] ADDR_WIDTH parameter exists but addr_q, o_axi_awaddr/araddr, and BASE_ADDR are hardcoded [31:0]/logic[31:0] (35, 53, 67, 89); 'addr_q <= i_req_addr - BASE_ADDR' (134) silently truncates if ADDR_WIDTH is ever raised above 32.
  - *Action:* Either keep ADDR_WIDTH pinned at 32 by policy (and assert it in an initial check), or make addr_q/BASE_ADDR/AXI address widths follow ADDR_WIDTH.
- **`hw/rtl/lib/ram/tdp_bram_dc_byte_en.sv:36`** [medium] Byte-address port width is coupled to DATA_WIDTH ('input logic [DATA_WIDTH-1:0] i_port_a_byte_address') and $readmemh row format equals DATA_WIDTH. Widening the dmem instance to 64 changes the address port shape, ByteAddrBits (2->3), and the required init-file token width simultaneously - three coupled changes behind one parameter flip.
  - *Action:* Decouple address-port width from DATA_WIDTH (or accept and re-verify all three effects together when widening the dmem instance); regenerate init files at the matching width.

### Design work (new logic or semantics)

- **`hw/rtl/cpu_and_mem/cpu_and_mem.sv:234`** [high] Entire core<->memory data tier is 32 bits: data_memory_address/write_data/read_data are [31:0], byte enables are [3:0] (lines 234-259). Verified in cpu_ooo: FSD is drained as two word-width phases (store_queue.sv:356/370 'Each phase is word-width') and FLD is a two-phase re-issue (load_queue.sv:2331). RV64 LD/SD/LR.D/SC.D/AMO*.D need a native 8-byte access class; splitting LD of mtime into two MMIO reads violates 64-bit single-copy atomicity, and AMO*.D cannot be phased.
  - *Action:* Widen the data tier to 64 bits: data_memory_write_data/read_data/cached_write_data/cached_read_data -> [63:0], byte enables [3:0] -> [7:0] (lines 244, 249, 255), mmio_read_data_* -> 64. Alternatively keep 32+two-phase for BRAM only and add a 64-bit path for MMIO/cached, but a uniform widening is simpler.
- **`hw/rtl/cpu_and_mem/cpu_and_mem.sv:1249`** [high] mtime/mtimecmp are 64-bit registers written exclusively through paired 32-bit lo/hi MMIO word decodes (writing_mtime_low/high, and the MtimecmpLow/High + ClintMtimecmpLo/Hi cases at 1262-1266) with 32-bit data_memory_write_data_registered. RV64 Linux CLINT/SBI code does a single 8-byte SD to mtimecmp and a single 8-byte LD from mtime; if SD is phased into two word writes there is a torn-mtimecmp window (lo updated against stale hi) that RV64 software, unlike RV32, does not guard against.
  - *Action:* Add native 8-byte MMIO store/load decode for the CLINT registers (single-cycle full-width write of mtimecmp, single-copy-atomic read of mtime), while keeping the 32-bit lo/hi aliases for compatibility.
- **`hw/rtl/cpu_and_mem/cpu_and_mem.sv:1008`** [high] mmio_read_data_comb is a [31:0] mux keyed on mmio_load_addr [31:0]; every arm returns at most 32 bits (mtime[31:0]/mtime[63:32] as separate addresses, lines 1017-1020, 1034-1038). A 64-bit LD from any MMIO address has no data path; result would be a truncated/garbage upper half.
  - *Action:* Widen mmio_read_data_comb/reg and data_memory_or_peripheral_read_data (line 1085-1088) to 64 bits; define each register's 64-bit read view (CLINT mtime/mtimecmp full-width; byte-wide ns16550/UART regs zero-extended; decide FIFO semantics).
- **`hw/rtl/cpu_and_mem/cpu_and_mem.sv:718`** [medium] Instruction-programming Port A writes the data BRAM with 32-bit words and [3:0] byte enables (i_instr_mem_we & {4{...}}). With a 64-bit dmem row, the JTAG/loader path needs address-LSB-steered lane placement into [7:0] byte enables; without it the loader corrupts every odd word.
  - *Action:* Add a 32-bit-to-64-bit lane adapter on Port A (addr[2] selects upper/lower byte-enable nibble), or keep the loader 64-bit-aware.
- **`hw/rtl/cpu_and_mem/cpu_and_mem.sv:746`** [medium] cached_tier_adapter instantiated with .XLEN(32) and 32-bit read/write data ports (lines 751-758). AMO*.D and 8-byte cached LD/SD require the adapter to select/merge an 8-byte lane within the 256-bit line instead of a 4-byte lane.
  - *Action:* Flip to .XLEN(64), widen i_write_data/o_read_data and i_write_byte_en at this seam; adapter internals are another audit's scope but this instantiation is the contract.

### Policy (needs a project decision)

- **`hw/rtl/cpu_and_mem/cpu_and_mem.sv:151`** [high] All MMIO window/register addresses are 32-bit 'int unsigned' localparams (151-185) compared with == against data_memory_address_registered (e.g. 340-344, 1095, 1186, 1235-1240, 1262-1268). If the address bus widens to 64, SV zero-extends the localparams, so any address with bits [63:32] set silently misses every decode (write dropped, read returns stale mmio_read_data_reg or BRAM garbage) instead of faulting.
  - *Action:* Decide unmapped-high-bit behavior: mask addr[63:32] upstream (aliasing sign-extended addresses onto the 32-bit map - friendliest to RV64 code), or trap/complete-with-zero on nonzero high bits. Then either keep these decoders 32-bit or widen consistently.
- **`hw/rtl/cpu_and_mem/cpu_and_mem.sv:1201`** [low] o_fifo0_wr_data/o_fifo1_wr_data pass the (to-be-widened) data_memory_write_data_registered into 32-bit FIFO ports; an SD to the FIFO address would silently drop the upper half.
  - *Action:* Declare the FIFO MMIO registers 32-bit-access-only (take [31:0] explicitly) or widen the FIFOs; document in the MMIO map.
- **`hw/rtl/lib/cache/frost_cache.sv:142`** [low] Fully ADDR_WIDTH-parameterized and XLEN-free (line-granular). TagBits = ADDR_WIDTH - IndexBits - OffsetBits: raising ADDR_WIDTH to 64 would add 32 bits to every tag entry and lengthen the already timing-sensitive balanced tag compare (243-251) for zero benefit under a 32-bit physical map.
  - *Action:* Keep ADDR_WIDTH=32 at every cache instantiation; canonicalize addresses above the hierarchy.
- **`hw/rtl/cpu_and_mem/cpu_and_mem.sv:45`** [low] CACHED_BASE/CACHED_SIZE_BYTES are 32-bit 'int unsigned' parameters threaded into cpu_ooo range checks. Fine at 32-bit physical, but any future >4GiB DDR window (X3 has more DRAM) forces these and every downstream ADDR_WIDTH to grow - worth capturing as an explicit Phase-1 non-goal.
  - *Action:* Record 'physical map stays below 4 GiB' as a Phase-1 invariant in ROADMAP/docs so the 32-bit seams are a documented contract, not an accident.

### Mechanical (width/literal/comment hygiene)

- `hw/rtl/cpu_and_mem/cpu_and_mem.sv:192` [low] PC/fetch plumbing hardwired 32-bit: program_counter (192), fetch_address (197), instruction_served_addr (204), served_last_word [29:0] = addr[31:2]+1 (205, 209, 646, 686), fuzz generate ask/served regs (432-435, 486). Mechanical widening iff the fetch seam carries 64-bit addresses; unchanged under a truncate-at-core policy.
- `hw/rtl/cpu_and_mem/cpu_and_mem.sv:346` [low] Debug taps cpu_debug_commit_pc/commit_2_pc [31:0] (346-348) feed hang_triage. Fine under sub-4-GiB map if PC is canonicalized; silent truncation of a widened o_debug_commit_pc otherwise.
- `hw/rtl/cpu_and_mem/fetch_provider.sv:106` [low] LineAddrBits = 32 - OffsetBits hardcodes a 32-bit fetch address space; i_pc/o_served_addr/o_line_req_addr are [31:0] (68, 81, 94), win_addr math uses [31:2] and +32'd4 (192-193, 258), and served_last_word is [29:0] (83).
- `hw/rtl/cpu_and_mem/hang_triage.sv:61` [low] All PC taps [31:0] (i_pc 61, commit PCs 63/65), kernel filter i_pc[31] (110), histogram bucket i_pc[21:16] (104), and the emit FSM prints exactly 8 hex nibbles per field (nib_idx at 229-233). Debug-only; adequate under the sub-4-GiB map, silently truncating if fed a widened PC.
- `hw/sim/cpu_tb.sv:131` [low] One-instruction-per-cycle feed model and the TbSlot2Blocker ecall trick (140-147) are XLEN-agnostic and remain valid for RV64 W-op directed tests; only widths change. i_mtime is already 64-bit (106).
- `hw/rtl/frost.sv:87` [low] Top-level ports are already width-appropriate for the unchanged sub-4-GiB physical map: instr-mem programming [31:0] (87-88), AXI addresses [31:0] (103, 117), CACHED_BASE 32'h8000_0000 (47). No PC/reset-vector logic lives in frost.sv (reset vector is in the core). Only pass-through of cpu_and_mem changes.
- `hw/rtl/lib/cache/axi_behavioral_memory.sv:87` [low] Word-granular 32-bit array with sw_ddr.mem in 4-byte format is untouched by XLEN: the port is 256-bit line-granular and addresses are region-relative 32-bit. RV64 programs load fine since the image is byte-exact. DDR_MODEL_LATENCY/JITTER hooks are width-irrelevant.
- `hw/rtl/lib/cache/frost_cache_hierarchy.sv:45` [low] Clean ADDR_WIDTH/LINE_BYTES parameterization end-to-end (ports 69-104, both L1s, arbiter, L2); no XLEN dependence, no width literals beyond the parameter defaults.
- `hw/rtl/lib/cache/line_port_arbiter.sv:39` [low] Fully parameterized pass-through arbiter; no XLEN or width assumptions.
- `hw/rtl/peripherals/uart_tx.sv:26` [low] Byte-wide, DATA_WIDTH-parameterized, no XLEN coupling (same for uart_rx.sv).

## test infrastructure, CI, container, formal targets (config/harness code where XLEN is pinned outside RTL)

The harness pins XLEN=32 in exactly four places that matter: the arch-test suite root (test_arch_compliance.py:48 rv32i_m), the riscv-tests suite/skip tables (test_riscv_tests.py:54,85), the torture signature layout (_GPR_WORDS/_TOTAL_WORDS at test_riscv_torture.py:217-218), and the CI matrices plus Linux lane (ci.yml:209,423-476,617-620); everything else (tests/Makefile, cocotb runner mechanics, frost.py, conftest, docker_entrypoint, check_linux_boot_regression, the .sby scripts) is genuinely XLEN-agnostic because ISA strings live in sw/apps Makefiles and widths elaborate from riscv_pkg.sv. The most valuable hazards: (1) reference-path collision - an rv64i_m test resolves to the committed RV32 golden signature because get_reference_path keys only on extension name + stem (test_arch_compliance.py:196); (2) skip-list silent expiry - ISA_SKIP_TESTS keyed by rv32 suite names stops applying on re-key, while the rv32ud 'move' skip must be inverted since fmv.d.x/fmv.x.d become legal on RV64; (3) the K-extension filter would silently drop packw coverage on rv64. Both signature extractors hardwire 8-hex-char lines, coupling the harness to a 4-byte dump granularity defined in sw-side macros. Hard-verified container facts: the pinned xPack gcc 15.2.0-1 in the frost image ships rv64imafdc_zicsr_zaamo_zalrsc/lp64d multilibs (rv64 builds work today), qemu-system-riscv64 is already installed, but Spike is absent from the image - all goldens came from an unpinned host Spike, which is the reproducibility gate on regenerating every arch/torture reference at rv64. To run ONE rv64 arch test today (./test_arch_compliance.py --test rv64i_m/I/src/add-01.S): FIRST the build breaks - sw/apps/arch_test/Makefile:25 pins ARCH=rv32imafdc.../ABI=ilp32 so the assembler rejects rv64 sources (path resolution via SUITE_DIR.parent would actually find the file); SECOND, if the build were fixed, the runner silently loads the RV32 golden for the same-named test and diffs against it; THIRD, the RTL is still XLEN=32 so the sim traps or mismatches, and only then do the extractor-granularity and reference-regeneration questions surface. Formal and Yosys lanes need no textual changes but their depth/timeout budgets (SBY_TASK_TIMEOUT_S=2400, xilinx 3600 s vs ~2750 s measured) are sized for the 32-bit design and must be re-measured. CI today runs ~71 simulation jobs across the suite matrices; the dual-vs-replace XLEN decision determines whether that roughly doubles.

### Hazards (compile-clean, silently wrong at XLEN=64)

- **`tests/test_arch_compliance.py:196`** [high] get_reference_path keys references only by extension dir name + test stem (ext_name = test_src.parent.parent.name, e.g. 'I', stem 'add-01'). rv64i_m/I/src/add-01.S has the SAME stem and extension name as the rv32 test, so pointing --test at an rv64 source today silently compares against the committed RV32 golden signature and reports a plausible-looking FAIL (or, for width-insensitive tests, a false PASS). No XLEN appears anywhere in the reference namespace (references/{ext}/{stem}.reference_output).
  - *Action:* Namespace references per XLEN (references/rv64/{ext}/... or a suite-root-derived key that includes rv64i_m) and regenerate all goldens with an rv64 Spike; make run_single_test refuse a reference whose XLEN provenance does not match the build.
- **`tests/test_arch_compliance.py:81`** [medium] K-extension filter selects {pack, packh, brev8, zip, unzip}. ZIP/UNZIP are RV32-only (must decode illegal on RV64) and ZEXT.H changes encoding to PACKW on RV64; the rv64i_m/K suite instead carries packw tests that this prefix filter would exclude, so the rv64 K lane would silently run a reduced test set while looking green.
  - *Action:* Re-derive the K filter for rv64 (add packw, drop zip/unzip) when SUITE_DIR flips; likewise re-audit EXTENSION_TEST_EXCLUDES (lines 89-96) against the rv64 C/B directories (different Zcb/clmul mixes).
- **`tests/test_riscv_tests.py:85`** [high] ISA_SKIP_TESTS / ISA_SKIP_TESTS_BRAM are keyed by rv32 suite names, so on an rv64 re-key every skip silently stops applying (dict lookup misses) and previously-excluded tests (ma_data, breakpoint, pmpaddr, csr, ma_addr, instret_overflow, fence_i-in-bram) run and fail. Conversely rv32ud's 'move' skip (line 90, 'Uses fmv.d.x/fmv.x.d (RV64-only)') must be REMOVED for rv64ud - the test becomes runnable and is exactly the new FMV.X.D/FMV.D.X coverage Phase 1 needs.
  - *Action:* Re-key all skip dicts to the rv64 suite names in the same change that re-keys ISA_TEST_SUITES; delete the ud/move skip; re-validate each remaining skip's rationale at XLEN=64.

### Design work (new logic or semantics)

- **`tests/test_arch_compliance.py:312`** [medium] extract_signature accepts ONLY exactly-8-hex-char lines (len(stripped) == 8). This bakes the 4-byte signature granularity of the current custom RVMODEL_HALT UART dump into the harness. If the rv64 port's halt macro dumps 16-hex 64-bit words, every signature line is silently ignored and the test fails with the misleading 'No signature data in output'; if the macro keeps 4-byte words it works but only by convention that lives in another repo area (sw/apps/arch_test env macros).
  - *Action:* Decide the rv64 signature granularity once (recommend keeping 4-byte/8-hex, matching riscv-arch-test's 4-byte RISCOF granularity) and assert it consistently in the halt macro, this extractor, test_riscv_torture.extract_signature, and the goldens.
- **`tests/test_riscv_torture.py:191`** [low] Torture extract_signature also hardwires 8-hex-char signature lines, same coupling as the arch-test extractor; must move in lockstep with whatever granularity the rv64 footer dump uses.
  - *Action:* Apply the same one-granularity decision as test_arch_compliance.py:312.
- **`tests/test_run_cocotb.py:349`** [medium] Registry is XLEN-agnostic mechanically (it only names apps and forwards env), but the atomics entry's description 'RV32-A atomics to the cached DDR region (LR/SC, AMO)' (349) and the coverage comment citing rv32ua/rv32uc/rv32um gating (839) go stale, and no registry entries exist for RV64-only surface (LWU/LD/SD, W-ops, AMO*.D/LR.D/SC.D, FCVT.L/LU, 8-byte-alignment traps). New directed apps plus TEST_REGISTRY entries are needed or the fast cocotb lane has zero rv64-delta coverage.
  - *Action:* Add rv64 directed-test apps and registry entries (with descriptions updated); fix the two stale doc strings.

### Policy (needs a project decision)

- **`.github/workflows/ci.yml:476`** [high] The Linux lane is rv32-pinned end to end: frost_nommu_rv32_defconfig (476, cache key 454, comment 423 'compiles a full rv32 uClibc cross toolchain'), and the QEMU reference boot uses qemu-system-riscv32 with -cpu rv32,mmu=off (617-620). An rv64 core cannot boot this image; the lane goes red or must be ported (rv64 nommu is actually the better-supported upstream Linux config).
  - *Action:* Author frost_nommu_rv64_defconfig + rv64 buildroot toolchain config, switch QEMU job to qemu-system-riscv64 -cpu rv64,mmu=off (binary already in the image), update cache keys; or explicitly park the Linux lane during the transition. check_linux_boot_regression.py itself is XLEN-clean (mtimecmp already parsed as 64-bit, line 54).
- **`Dockerfile:150`** [high] Spike (riscv-isa-sim) is NOT built into the image anywhere (verified: no spike binary in the container). All golden references (arch-test via sw/apps/arch_test/generate_references.py using FROST_SPIKE/--isa=rv32imafdc_zicsr_zifencei_zba_zbb_zbs_zbkb_zicond, torture via generate_tests.py spike --isa=FROST_ISA) were generated on a host Spike and committed. The rv64 respin requires regenerating every reference with an rv64 ISA string, on a Spike whose version is currently unpinned and outside CI's reproducibility guarantee.
  - *Action:* Decide: add a pinned riscv-isa-sim build stage to the Dockerfile (so reference regeneration is containerized and CI-reproducible) vs. keep host-Spike with a documented version pin. This gates all rv64 signature suites.
- **`tests/test_run_yosys.py:105`** [medium] Xilinx synthesis timeout defaults to 3600 s while the current UltraScale+ run already measures ~2750 s (comment at line 96). Widening the integer datapath, load/store paths, and CSRs to 64 bits plausibly pushes past 3600 s and turns the synthesis lane into timeout-flaky.
  - *Action:* Budget new timeouts (FROST_YOSYS_XILINX_TIMEOUT_SEC default) after the first rv64 synthesis measurement; same review for the generic coarse 1800 s default.
- **`tests/test_run_formal.py:40`** [medium] SBY_TASK_TIMEOUT_S = 2400 is sized against RV32 solver runtimes, and the history in this very comment (ROB BMC depth cut 16 to 12 after a timing-closure change ballooned runtime) shows depth/timeout budgets are already tight. Widening PCs/addresses/CSRs 32 to 64 grows SMT bitvector state in csr_file, trap_unit, load_queue, store_queue, and lq_l0_cache targets (value carriers are already 64-bit, so ROB/RS/CDB grow less); expect re-tuning of depths (.sby files) and this timeout. The .sby scripts themselves contain no width literals - they elaborate riscv_pkg.sv, so the XLEN flip flows through automatically.
  - *Action:* After the RTL flip, re-measure every bmc/cover task, re-tune depths in formal/*.sby and possibly SBY_TASK_TIMEOUT_S; no textual .sby edits required for correctness.
- **`.github/workflows/ci.yml:151`** [medium] CI cost/shape: sim lanes today are roughly 25 arch-test jobs (14 ext x 2 tiers - 3 excludes), 22 riscv-tests, 18 benchmarks, 2 torture, 4 cocotb, plus synthesis/formal/lint/python/3 Linux jobs (~80 total). A dual rv32+rv64 matrix roughly doubles the ~71 simulation jobs; the arch lane already needs timeout-minutes: 300 and excludes F/D ddr for slowness (167-173), and rv64 suites add W-op/conversion tests on a slower 64-bit Verilator model, so even the rv64-only swap inflates wall time.
  - *Action:* Decide dual-XLEN CI vs rv64-only replacement before writing the matrix; if dual, shard further or demote one XLEN to nightly.

### Mechanical (width/literal/comment hygiene)

- `tests/test_arch_compliance.py:48` [medium] SUITE_DIR hardcodes riscv-test-suite/rv32i_m; discover_tests, extension validation (line 599), and the --test resolution examples (lines 25, 522, 542) all assume the rv32i_m tree. The rv64i_m tree in the same submodule is never enumerated.
- `tests/test_riscv_tests.py:54` [medium] ISA_TEST_SUITES is a hardcoded rv32* map (rv32ui...rv32uzbkb) and drives --all, pytest parametrization (line 421), and CI. The riscv-tests submodule's rv64ui/rv64um/... dirs exist but are unreachable via --all; --suites rv64ui only 'works' with a warning (line 603) and then breaks in the sw-side rv32 build.
- `tests/test_riscv_torture.py:218` [medium] _GPR_WORDS = 32 and _TOTAL_WORDS = 96 hardcode the RV32 signature layout (32 one-word GPRs + 32 doubles x 2 words), and compare_signatures slices the FP region as words [32:96]. With 64-bit GPRs the dump becomes 64 GPR words + 64 FP words = 128 (at 4-byte granularity); the length check at line 228 fails loudly, but the constants, the FP-slice arithmetic, and the GPR-skip rationale (lines 210-216) all need rework together with the regenerated torture tests/references.
- `tests/test_runner_helpers.py:93` [low] The fast regression fixtures encode the 8-hex format ('00000001'/'00000002' lines at 84-94) and reference stubs '00000000\n' (lines 54, 71), plus the rv32ui suite name at line 101. They will keep passing against stale rv32 assumptions and must be updated with the extractors so the guard tests actually guard the rv64 format.
- `.github/workflows/ci.yml:209` [medium] riscv-tests matrix pins suite: [rv32ui, rv32um, rv32ua, rv32uf, rv32ud, rv32uc, rv32mi, rv32uzba, rv32uzbb, rv32uzbs, rv32uzbkb]; benchmarks (240) and arch extensions (156) reuse names that survive, but every rv32* literal here must flip to rv64*.
- `Dockerfile:151` [low] The pinned xPack riscv-none-elf-gcc 15.2.0-1 is VERIFIED rv64-capable: --print-multi-lib in the current frost image lists rv64imafdc_zicsr_zaamo_zalrsc/lp64d (plus lp64/lp64f variants), so bare-metal rv64gc builds with newlib link out of the box; no toolchain change needed. B-extension march strings are accepted by the assembler and map onto the rv64imafdc multilib.
- `Dockerfile:161` [low] The Buildroot/QEMU layer comment block describes the Linux jobs as rv32 ('Buildroot compiles its own rv32 uClibc cross toolchain', 'qemu-system-riscv32'); qemu-system-misc already ships qemu-system-riscv64, so only the comments and the defconfig consumers go stale, not the package set.
- `tests/Makefile:377` [low] No XLEN pins found: file lists, -G parameter overrides (MEM_SIZE_BYTES/DDR_MODEL_BYTES etc.) and Verilator flags are width-agnostic; DDR_MODEL_BYTES=64 MiB and the sub-4-GiB map are unchanged by Phase 1. Only indirect effect is longer Verilator compile/sim times.

## cocotb verification framework (verif/): encoders, reference models, monitors, testbench config, and cocotb_tests survey

The verification framework is systematically RV32-shaped: verif/config.py declares XLEN=32 but nothing derives from it, and the real width truth lives in scattered literals (MASK32, 0xFFFFFFFC alignment masks, SHIFT_AMOUNT_MASK=0x1F, INT32 division constants) plus at least 16 private "XLEN = 32" copies inside tomasulo/ and cpu_ooo/ test files that hand-pack DUT struct bit layouts. The reference ALU (alu_model.py) is the densest hazard zone: a module-wide mask-to-32 decorator, 5-bit shamt truncation, 32-hardcoded rotates, 5-bit Zbs bit indexing, 4-byte-only orc_b/rev8/brev8, and to_signed32-based compares would all compile and silently produce wrong expected values at XLEN=64; LW's RV64 sign-extension semantic change and the missing W-op/LWU/LD/SD evaluators are the biggest model gaps. The FP model already handles NaN-boxing correctly (box32/unbox32, FLEN=64 carriers), but every FCVT.W*/FMV.X.W result returns a zero-extended 32-bit value where RV64 requires sign-extension into the 64-bit rd, and the entire FCVT.L*/FMV.X.D family is absent. The encoders need new OP-32/OP-IMM-32/LWU/LD/SD/AMO.D machinery, and make_i_shift_encoder's (sh & 0x1F)|(f7 << 5) layout silently corrupts funct7 for any 6-bit shamt. The compressed encoder has three RV64 booby traps: c.jal's encoding becomes C.ADDIW, and the C.FLW/C.FSW/C.FLWSP/C.FSWSP encodings become C.LD/C.SD/C.LDSP/C.SDSP with 8-scaled immediates — both silently execute different instructions than the model predicts; test_compressed.py drives them directly. CSR-side, op_tables.ZICNTR_CSRS and test_state.get_csr_value treat cycleh/timeh/instreth as readable, which become illegal CSRs on RV64, and mcause interrupt-bit checks pin bit 31 (loud in test_trap_unit.py, silent in test_real_program's is_irq instrumentation). Address handling truncates at 32 bits in several silent places (config alignment masks, instruction_generator MMIO check, generate_aligned_immediate), which interacts with the undecided high-address-bit policy. Monitors are mostly mechanical (RegisterFileMonitor's MASK32 compare fails loudly), while memory_model's write checker masks byte-enables to 4 bits and data to 32 — its fate depends on the data-bus-width decision. Migration cost estimate: a focused mechanical pass (config-driven masks + riscv_utils parametrization + monitor widening) is small; the design work concentrates in alu_model/op_tables/encoders (W-ops, shamt6, RVC recode) and the struct-packer synchronization across the tomasulo unit tests. The five highest-leverage files to make XLEN-parametric first: (1) verif/config.py (make every width/mask/division constant derive from XLEN), (2) verif/utils/riscv_utils.py (parametric to_signed/to_unsigned used by every model), (3) verif/models/alu_model.py (mirrors the RTL ALU; decorators are single choke points), (4) verif/encoders/op_tables.py with instruction_encode.py (shamt6 layout, W-op and RV64 load/store encoders, CSR legality), and (5) a new shared width module replacing the private XLEN=32 copies in cocotb_tests/tomasulo and cpu_ooo interface files (start from reservation_station/rs_interface.py and dispatch/dispatch_interface.py).

### Hazards (compile-clean, silently wrong at XLEN=64)

- **`verif/config.py:70`** [high] MEMORY_WORD_ALIGN_MASK = 0xFFFFFFFC (and 0xFFFFFFFE at line 73) are 32-bit-wide alignment masks; ANDing a 64-bit address with them silently clears bits [63:32]. Used by memory_model.read_word/write_word and test_state.set_reservation.
  - *Action:* Replace with ~0x3 / ~0x1 (or width-parametric masks) so upper address bits survive.
- **`verif/utils/riscv_utils.py:53`** [high] to_signed32/to_unsigned32/to_signed33 hardwire sign bit 31 and MASK32; they are the conversion primitives behind every signed compare, shift, min/max, branch, and division in the models. If riscv_pkg XLEN flips without these, all signed semantics on values with bit 63 set silently break.
  - *Action:* Add parametric to_signed(val, width)/to_unsigned(val, width) (or to_signed64 family) and migrate every model call site.
- **`verif/models/alu_model.py:75`** [high] limit_shift_amount truncates shamt with & 0x1F; at XLEN=64 a shamt of 32-63 is silently reduced mod 32 and sll/srl/sra/rol/ror all return plausible-but-wrong values.
  - *Action:* Mask to 6 bits for native ops; keep 5-bit masking only in new W-shift evaluators.
- **`verif/models/alu_model.py:170`** [high] lw() zero-extends the loaded 32-bit word; on RV64 LW sign-extends to 64 (semantic change to an existing op). lb/lh at lines 209/235 also '& MASK32' after sign_extend, killing 64-bit sign extension. LWU does not exist.
  - *Action:* Sign-extend lw/lb/lh/lbu results to XLEN; add lwu; verify ld (line 183) stays as-is.
- **`verif/models/alu_model.py:398`** [high] bset/bclr/binv/bext mask the bit index with SHIFT_AMOUNT_MASK (5 bits); on RV64 bit positions 32-63 silently alias to 0-31.
  - *Action:* Mask bit index to 6 bits at XLEN=64.
- **`verif/models/alu_model.py:503`** [high] rol/ror hardcode the complementary shift as (32 - shift_amount); at XLEN=64 rotation is silently wrong for every nonzero shamt. ROLW/RORW/RORIW do not exist.
  - *Action:* Use (XLEN - shamt); add W-rotate evaluators.
- **`verif/models/alu_model.py:587`** [high] orc_b (range(4)), rev8 (explicit byte0-byte3, lines 594-604), and brev8 (range(4), line 652) iterate over exactly 4 bytes; at XLEN=64 the upper 32 bits are silently discarded. REV8's immediate encoding also differs on RV64.
  - *Action:* Iterate XLEN/8 bytes; update rev8 encoder immediate (0b011010111000) in op_tables.
- **`verif/models/branch_model.py:45`** [high] blt/bge/bltu/bgeu compare via to_signed32/MASK32; with 64-bit register values the comparisons silently use only a 32-bit view.
  - *Action:* Switch to XLEN-parametric signed/unsigned conversions.
- **`verif/models/fp_model.py:840`** [high] fcvt_w_s/fcvt_wu_s/fcvt_w_d/fcvt_wu_d return raw 32-bit values (result & MASK32, saturations like 0x7FFFFFFF/0xFFFFFFFF); on RV64 FCVT.W*/WU* results sign-extend into the 64-bit integer rd (e.g. WU max becomes 0xFFFFFFFF_FFFFFFFF). fmv_x_w (line 886) also returns & MASK32 but sign-extends on RV64.
  - *Action:* Sign-extend all 32-bit int-conversion and FMV.X.W results to 64; same rule for future AMOW model reuse.
- **`verif/encoders/op_tables.py:323`** [high] make_i_shift_encoder packs (sh & 0x1F) | (f7 << 5); a 6-bit shamt's bit 5 lands where funct7's LSB sits, so on RV64 a shamt >= 32 silently encodes a different instruction (e.g. SRLI shamt=33 -> funct7 corrupted). Also blocks encoding legal RV64 shamts 32-63.
  - *Action:* Rework to shamt6 layout ((sh & 0x3F) | (f6 << 6)) for native shifts/rori/bseti/bclri/binvi/bexti; separate 5-bit W-shift encoders where bit 25 set is illegal.
- **`verif/encoders/op_tables.py:644`** [high] C_JUMPS registers "c.jal" (enc_c_jal); on RV64 that 16-bit encoding IS C.ADDIW, so any test emitting it executes a different instruction while the model predicts a jump — silent divergence.
  - *Action:* Remove c.jal from RV64 tables; add c.addiw/c.addw/c.subw entries.
- **`verif/encoders/compressed_encode.py:159`** [high] enc_c_flw/enc_c_fsw (159-212) and enc_c_flwsp/enc_c_fswsp (768-816) emit funct3=011/111 quadrant-0/2 encodings that on RV64 are C.LD/C.SD/C.LDSP/C.SDSP with immediates scaled by 8, not 4 — the same bytes mean different instructions with different immediate decode. test_compressed.py (lines 585-654) drives these directly.
  - *Action:* Repurpose/rename as C.LD/C.SD encoders with 8-scaled immediates on RV64; rewrite the compressed FP-word directed tests (C.FLD/C.FSD forms are unchanged and can substitute).
- **`verif/models/memory_model.py:187`** [medium] driver_and_monitor masks the byte-enable with & 0xF and write data with & MASK32; if the RV64 data interface widens to 64 bits with 8 byte-enables, upper-lane stores are silently never checked and data compares truncate.
  - *Action:* Widen mask/data handling to the chosen bus width (policy-dependent); also revisit the 4-byte-word DUT-RAM copy loop at lines 87-95 if testbench RAM organization changes.
- **`verif/utils/memory_utils.py:275`** [medium] generate_aligned_immediate computes effective_address as (base + imm) & 0xFFFFFFFF; with 64-bit random register bases the model wraps at 4 GiB while hardware computes a full 64-bit address — divergent addresses given the unmapped-high-bit policy is undecided.
  - *Action:* Mask to XLEN and constrain random bases below 4 GiB per the physical-map policy decision.
- **`verif/cocotb_tests/instruction_generator.py:195`** [high] _is_mmio_address masks to 32 bits before comparing to MMIO_BASE_ADDR: a 64-bit base like 0x1_0000_0000 aliases to 0x0 and is judged safe RAM, and _effective_address (line 201) wraps at 32 bits — random memory ops could target addresses the DUT decodes differently.
  - *Action:* Decide high-bit policy, then make address math XLEN-wide and constrain generated bases; also widen shamt generation (line 396, randint(0, SHIFT_AMOUNT_MASK)) to 6 bits for native shifts.
- **`verif/cocotb_tests/test_real_program.py:2435`** [low] Debug instrumentation classifies interrupts with (trap_cause & 0x8000_0000); on RV64 the interrupt bit is bit 63, so is_irq silently reads False for real interrupts, corrupting wedge/trap diagnostics (not pass/fail).
  - *Action:* Test bit XLEN-1; audit the file's other 0x8000_0000-style probes and :08x formatting.

### Design work (new logic or semantics)

- **`verif/config.py:143`** [high] SHIFT_AMOUNT_BITS=5 / SHIFT_AMOUNT_MASK=0x1F feed alu_model.limit_shift_amount and instruction_generator shamt generation; on RV64 native shifts take 6-bit shamt while W-shifts keep 5.
  - *Action:* Introduce SHIFT_AMOUNT_MASK_XLEN=0x3F for native ops and keep 0x1F for W-form ops; both must exist simultaneously.
- **`verif/config.py:283`** [medium] DIVISION_OVERFLOW_DIVIDEND=-0x80000000 and DIVISION_BY_ZERO_QUOTIENT=0xFFFFFFFF are INT32-shaped; RV64 DIV overflow is INT64_MIN/-1 and div-by-zero returns 2^64-1, while DIVW/REMW still need the 32-bit constants plus sign-extension.
  - *Action:* Add 64-bit variants and keep the 32-bit ones for W-form division evaluators.
- **`verif/models/alu_model.py:252`** [high] mul/mulh/mulhsu/mulhu implement 32x32 semantics (>> 32, to_signed33); RV64 needs 64x64 MUL/MULH* (128-bit product, >> 64) plus a new MULW.
  - *Action:* Widen to XLEN-parametric multiply-high with 2*XLEN products; add mulw evaluator with sign-extension.
- **`verif/models/alu_model.py:289`** [high] DivisionOperations uses to_signed32, hardcoded 0x80000000 overflow return (line 304), and 32-bit constants; DIVW/DIVUW/REMW/REMUW are absent.
  - *Action:* Parameterize to XLEN with INT64_MIN/-1 special case; add the four W-division evaluators (32-bit compute, sign-extend result; div-by-zero returns all-ones/dividend at 64 bits).
- **`verif/models/alu_model.py:516`** [medium] clz/ctz/cpop scan exactly 32 bits and return 32 for zero input; CLZW/CTZW/CPOPW absent.
  - *Action:* Widen to 64-bit scans returning 64; add W variants.
- **`verif/models/alu_model.py:625`** [medium] pack() packs 16-bit halves (RV32 PACK). On RV64, PACK packs 32-bit halves, ZEXT.H changes encoding to PACKW rd,rs1,x0, and PACKW is new; zip/unzip (lines 663-696) are RV32-only and must decode as illegal.
  - *Action:* Rework pack for 64-bit, add packw, re-encode zext.h, delete/illegal-ify zip and unzip evaluators and their op_tables/I_UNARY entries (lines 519-520).
- **`verif/models/alu_model.py:704`** [medium] AMO evaluators are .W-only and cpu_model returns lw() (zero-extended) as AMO rd; on RV64 AMO*.W rd sign-extends to 64. LR.D/SC.D/AMO*.D evaluators absent; reservation granule in test_state (word-aligned, line 266) may become 8 bytes.
  - *Action:* Sign-extend .W results, add .D evaluators/encoders, decide reservation granule.
- **`verif/models/fp_model.py:862`** [high] fcvt_s_w/fcvt_d_w test bit 0x80000000 of rs1_int; fed a 64-bit register value they misinterpret the operand. FCVT.L.S/LU.S/S.L/S.LU, FCVT.L.D/LU.D/D.L/D.LU, FMV.X.D, FMV.D.X models are absent entirely (D-path FMV currently only via fld/fsd).
  - *Action:* Mask W-conversions to low 32 bits explicitly; add the eight L-form conversion models (single-precision results must NaN-box via box32) and FMV.X.D/FMV.D.X.
- **`verif/encoders/instruction_encode.py:60`** [high] Opcode enum lacks OP-IMM-32 (0x1B) and OP-32 (0x3B); no encoders exist for LWU/LD/SD, ADDIW/SLLIW/SRLIW/SRAIW, ADDW/SUBW/SLLW/SRLW/SRAW, MULW/DIV*W/REM*W, or the Zba/Zbb/Zbkb W-forms.
  - *Action:* Add the two opcodes, W-op encoder factories, ld/sd/lwu load-store encoders (funct3 011/110), and register them in op_tables.
- **`verif/encoders/instruction_encode.py:420`** [medium] AMOType.encode hardcodes funct3=Funct3.WORD, so AMO*.D/LR.D/SC.D cannot be encoded.
  - *Action:* Add a funct3 parameter (default WORD) and .D wrapper functions.
- **`verif/encoders/instruction_encode.py:628`** [medium] CSRAddress defines CYCLEH/TIMEH/INSTRETH (0xC80-0xC82); on RV64 these CSRs must raise illegal-instruction, and cycle/time/instret become single 64-bit CSRs.
  - *Action:* Keep addresses for illegal-CSR trap tests but remove them from legal-read paths; update test_state.get_csr_value.
- **`verif/encoders/op_tables.py:495`** [high] ZICNTR_CSRS feeds random CSR-read generation with CYCLEH/TIMEH/INSTRETH, which are illegal CSRs on RV64 — random tests would inject illegal instructions expecting normal retirement.
  - *Action:* Drop the H-counters from the random pool; add directed illegal-CSR trap coverage instead.
- **`verif/encoders/compressed_encode.py:382`** [low] enc_c_srli/enc_c_srai/enc_c_slli assert 1 <= shamt <= 31 and hardcode instruction bit 12 (shamt[5]) to 0; RV64 legalizes 6-bit compressed shamts.
  - *Action:* Accept shamt 1-63 and emit shamt[5] into bit 12 (loud assert today, so not silent).
- **`verif/utils/memory_utils.py:122`** [medium] calculate_byte_mask_for_store knows only sb/sh/sw with 4-bit masks, and get_alignment_for_operation (line 182) raises on ld/sd/lwu — no 8-byte alignment class exists.
  - *Action:* Add sd (and lwu/ld alignment=4/8) plus 8-lane mask support per the bus-width decision.
- **`verif/cocotb_tests/test_state.py:296`** [medium] get_csr_value models CYCLEH/TIMEH/INSTRETH as readable high halves and masks CYCLE/INSTRET to 32 bits; on RV64 counters are single 64-bit CSRs and the H-forms trap. mcounteren modeling (returns 0x7) stays 32-bit per spec.
  - *Action:* Return full 64-bit counter values; move H-CSRs to illegal-instruction expectations.
- **`verif/cocotb_tests/test_directed_multicycle.py:457`** [low] FLD result modeled as low_word/high_word 32-bit pair mirroring the current 32-bit data bus; changes with the RV64 bus-width decision.
  - *Action:* Update split-word modeling (and test_directed_atomics init patterns at line 314) once bus width is decided.

### Policy (needs a project decision)

- **`verif/cocotb_tests/tomasulo/reservation_station/rs_interface.py:33`** [high] Local 'XLEN = 32' constant plus hand-maintained packed-struct bit-offset packers (pack_rs_dispatch lines 105-174, unpack_rs_issue 208-270) mirror riscv_pkg struct layouts field-by-field. The same private XLEN=32/FLEN=64 copies exist in at least 15 more files (dispatch_interface.py:32, sq_interface.py:30, lq_interface.py:30, lq_model.py:25, sq_model.py:25, reorder_buffer_model.py:36, rat_model.py:38, fu_shims/fp_add_shim_interface.py:31, and cpu_ooo/* tests). If riscv_pkg XLEN flips and any one copy does not, packers drive misaligned bit vectors — some fields land in don't-care positions and pass silently wrong.
  - *Action:* Centralize width constants in one module (or read DUT parameters at runtime) before flipping; then verify each packer against the actual RTL struct (e.g. whether imm stays 32-bit or becomes XLEN in rs_dispatch_t must match line 145).

### Mechanical (width/literal/comment hygiene)

- `verif/config.py:254` [high] XLEN: Final[int] = 32 is declared but nothing else in config derives from it; MASK32, SHIFT_AMOUNT_MASK, alignment masks, and division constants are all independent literals.
- `verif/models/alu_model.py:64` [high] mask_to_32_bits decorator wraps every arithmetic op result with & MASK32 — the reference-ALU-wide 32-bit truncation point.
- `verif/monitors/monitors.py:160` [medium] RegisterFileMonitor.compare masks expected values with MASK32 (and formats :08x); once the DUT regfile is 64-bit every sign-extended result mismatches. Loud failure, but it breaks every regfile-checked test on day one.
- `verif/cocotb_tests/test_helpers.py:367` [medium] initialize_registers seeds x1-x31 with randint(0, 2**32 - 1); on RV64 the upper 32 bits of every register start zero and random torture never exercises them (silent coverage hole, not a failure).
- `verif/cocotb_tests/cpu_model.py:420` [medium] JALR target computed as (rs1 + imm) & 0xFFFFFFFE & MASK32 — the clear-bit-0 mask doubles as a 32-bit truncation; all PC/link/store-address arithmetic in this file (lines 276, 379, 415-426, 516-560) is & MASK32.
- `verif/cocotb_tests/control/test_trap_unit.py:107` [low] Asserts o_trap_cause == 0x80000007 (also lines 135, 182): mcause interrupt bit is bit 31; on RV64 it moves to bit 63 (0x8000000000000007). Loud failure, purely mechanical.
- `verif/verification_types.py:27` [low] NewType docstrings pin Address/RegisterValue/ProgramCounter as 32-bit; documentation-only but part of the same change per repo doc policy.

## software tree, Linux image pipeline, FPGA build (rv64 build-axis audit)

The software/build axis is in decent shape for RV64: the C-app march/mabi flags live in exactly one place (sw/common/common.mk:91,44), the linker scripts carry no elf32 pinning and an unchanged sub-4GiB memory map, crt0's lw/sw loops are legal-if-slow on rv64, and the entire image/loader pipeline (objcopy verilog-data-width 4, xxd -g4, JTAG 32-bit AXI bursts, .mem/.txt word formats) is byte-stream-based and XLEN-independent. The hard problems are concentrated in four places. First, sw/lib/include/csr.h+trap.h: every CSR accessor is uint32_t, which on lp64 sign-extends pointer casts into mtvec/mepc writes (psABI keeps 32-bit values sign-extended in registers) and puts MCAUSE_INTERRUPT_BIT at bit 31 instead of 63 - silent misclassification of every interrupt; plus rv32-only cycleh/timeh/instreth accessors that must become single 64-bit reads. Second, the Linux pipeline is rv32 end-to-end: BR2_RISCV_32 defconfig, CONFIG_ARCH_RV32I kernel configs, an rv32 DTS/isa string generated by build_fpga_boot.py, a boot shim whose li 0x80000000 sign-extends on rv64, a post-image riscv32-*-gcc toolchain glob, kernel-byte-offset patches in patch_linux_image.py pinned to the exact rv32 build, and qemu-system-riscv32 in CI. Third, the freshly-added Zicntr counter-delta stress payload reads 0xc80-0xc82 by number and its SIGILL guard would silently report counters unavailable on rv64 while still printing the PASS token - a quiet coverage loss. Fourth, ISA-content apps (isa_test rev8/pack expectations, c_ext_test's c.jal, umode_test's cycleh gating matrix) and the FROST-local rv32 FreeRTOS port (4-byte sw/lw context frames, uint32_t port types) need semantic rewrites, and the rv32 riscv-tests/arch-test/torture suites need rv64 counterparts. Standalone-asm apps additionally hardcode ARCH/ABI in 9 Makefiles plus ld -m elf32lriscv. Minimal file set for an rv64 hello_world through cocotb: sw/common/common.mk (march/mabi) is the only strictly required sw-side edit (crt0/link.ld/uart/timer work as-is), plus the other-agent-owned generate_imem_predecode_init.py and cocotb harness; csr.h/limits.h fixes are needed the moment any test touches CSRs. Minimal set for an rv64 Buildroot boot: new rv64 defconfig + regenerated kernel base config/fragment, build_fpga_boot.py (isa strings/shim/li fix), post-image.sh glob, patch_linux_image.py re-derivation or gating, frost_stress.c counter path, sw/apps/linux_boot/Makefile defconfig name, and the CI qemu job - with README updates in the same change per project doc policy.

### Hazards (compile-clean, silently wrong at XLEN=64)

- **`sw/lib/include/csr.h:110`** [high] MCAUSE_INTERRUPT_BIT is (1U << 31); on RV64 the mcause interrupt bit is bit 63. Every `mcause & MCAUSE_INTERRUPT_BIT` check (trap handlers across apps/lib) silently classifies interrupts as exceptions. With csr_read also returning uint32_t the bit is doubly unreachable.
  - *Action:* Make it (1UL << (__riscv_xlen - 1)) and widen csr accessors to unsigned long; audit every user of mcause
- **`sw/lib/include/csr.h:142`** [high] csr_read/csr_write/csr_set/csr_clear/csr_swap/csr_read_imm/csr_write_imm all use uint32_t (lines 142, 184, 196, 208). On RV64/lp64 the RISC-V psABI keeps 32-bit values SIGN-extended in registers, so csr_write(mtvec, (uint32_t)&handler) with a DDR-resident handler (0x8000_xxxx) writes 0xFFFFFFFF_8000xxxx into mtvec/mepc/mscratch. Reads truncate 64-bit CSR values (mcause, mtval, mepc).
  - *Action:* Switch all accessor value types to unsigned long/uintptr_t; same for trap.h set_trap_handler (line 195) and disable/restore_interrupts (lines 113-127)
- **`linux/buildroot-external/board/frost/build_fpga_boot.py:177`** [high] Boot shim emits `li a1, 0x80000000` (DTB base) and `li t0, 0x80000000` (kernel entry). On an rv64 assembler li/lui sign-extends: a1/t0 become 0xFFFFFFFF_80000000. The kernel receives a sign-extended DTB pointer and the far-jump PC has bits [63:32] set - behavior depends entirely on the (undecided) high-address-bit policy of the core.
  - *Action:* Rewrite the shim address materialization to produce zero-extended sub-4GiB addresses (or define/verify the core's high-bit-ignoring policy first)
- **`linux/buildroot-external/package/frost-stress/src/frost_stress.c:116`** [high] The just-added Zicntr counter-delta code reads cycleh/timeh/instreth by number (0xc80/0xc81/0xc82, lines 116-147). On RV64 these CSRs are illegal; the payload's existing SIGILL guard (lines 149-159) longjmps out and reports counters as 'unavailable' - the stress run still prints FROST_USERSPACE_STRESS_PASS, so the new counter coverage is lost SILENTLY on an rv64 boot.
  - *Action:* Add an __riscv_xlen==64 path doing single 64-bit csrr of 0xc00/0xc01/0xc02, and make counter-unavailable a failure on FROST (keep the guard only for QEMU)
- **`sw/lib/include/limits.h:33`** [medium] LONG_MIN/LONG_MAX/ULONG_MAX hardcoded to 32-bit values (lines 33-34, 38). On lp64 `long` is 64-bit, so these constants are silently wrong for any range check or overflow guard using them.
  - *Action:* Define from __LONG_MAX__ or gate on __riscv_xlen

### Design work (new logic or semantics)

- **`sw/common/link.ld:56`** [medium] __stack_reserve = 112K was measured with ilp32 (CoreMark-PRO parser high-water). lp64 doubles pointer/long footprints on stack frames, so the reserve and the RAM-fit ASSERT (line 230) may be undersized; likewise the 96K ROM budget - rv64 code is typically a few percent larger and lp64 data larger.
  - *Action:* Re-measure stack high-water and ROM/RAM fit under lp64d; adjust reserve/regions or accept per-app MEM_CONFIG=ddr
- **`sw/lib/include/csr.h:229`** [medium] rdcycleh/rdtimeh/rdinstreth (lines 229-302) and the hi/lo/hi2 64-bit composition loops (rdcycle64/rdtime64/rdinstret64, lines 240-316) plus CSR_CYCLEH/TIMEH/INSTRETH defines (58-60) are rv32-only: the high-half CSRs MUST be illegal on RV64. Callers include isa_test.c:2789-2807 and umode_test.
  - *Action:* On rv64, rd*64 becomes a single csrr; delete/gate the *h accessors; update dependent tests
- **`sw/apps/freertos_demo/port_frost_asm.S:26`** [medium] FreeRTOS uses a FROST-local rv32 port (no upstream portable/GCC/RISC-V dir): port_frost_asm.S saves 28 GPRs + mepc + mstatus in 4-byte slots (sw/lw, lines 40-86, portCONTEXT_SIZE comment line 26 '31 words = 124 bytes'); portmacro.h:37/77/79 pin portPOINTER_SIZE_TYPE/portSTACK_TYPE/portUBASE_TYPE to uint32_t. Silent stack-frame corruption if compiled lp64 unchanged.
  - *Action:* Full port rewrite: sd/ld 8-byte slots, portCONTEXT_SIZE 256, uint64_t port types - or drop the FreeRTOS demo (decision)
- **`sw/apps/c_ext_test/c_ext_test.S:47`** [low] c.jal used throughout (47, 67-69, 139) - the encoding becomes C.ADDIW on RV64, so the test won't assemble under rv64 march and its coverage intent (RV32C recode points) inverts.
  - *Action:* Write an rv64 variant covering C.ADDIW, C.SUBW/C.ADDW, C.LD/C.SD/C.LDSP/C.SDSP and 6-bit C shamts; retire the rv32-only cases
- **`sw/apps/isa_test/isa_test.c:3028`** [medium] Zbb/Zbkb tests bake rv32 semantics: rev8 expected values for 32-bit reversal (3028-3034; REV8 immediate also differs on rv64), pack/packh 32-bit results (3211-3224), and rdcycleh/rdtimeh/rdinstreth CSR tests (2789-2807). ZEXT.H encoding changes (PACKW-based) too.
  - *Action:* Fork rv64 expected values, add W-op/LWU/LD/SD coverage, drop *h CSR tests, ensure ZIP/UNZIP (rv32-only) become illegal-instruction tests
- **`sw/apps/umode_test/main.c:172`** [medium] The mcounteren U-mode gating test (just landed) reads cycleh/timeh/instreth from U-mode (172-176, 199-201) and asserts CY-bit gating on the high-half CSRs. On RV64 those CSRs are unconditionally illegal - the test's pass criteria change semantically, not just mechanically.
  - *Action:* Rewrite the gating matrix for rv64: cycle/time/instret only, plus assert 0xC80-0xC82 trap illegal regardless of mcounteren
- **`linux/buildroot-external/configs/frost_nommu_rv32_defconfig:21`** [medium] BR2_riscv + BR2_RISCV_32 (line 22) select the rv32 uClibc/bFLT internal toolchain; filename, provenance comment (derived from qemu_riscv32_nommu_virt_defconfig) and toolchain-default note (line 15) are all rv32.
  - *Action:* New frost_nommu_rv64_defconfig with BR2_RISCV_64; re-derive from qemu_riscv64_nommu_virt_defconfig and re-validate the uClibc/elf2flt rv64-FLAT userspace path (including the vendored uclibc dl_pagesize patch)
- **`linux/buildroot-external/board/frost/linux-nommu-base.config:5`** [medium] CONFIG_ARCH_RV32I=y here and in linux-nommu-frost.config.fragment:69 (fragment prose at 4, 55, 63, 135 documents rv32). Kernel must become CONFIG_ARCH_RV64I; the whole base config was captured from an rv32 build and should be regenerated rather than sed-edited.
  - *Action:* Regenerate base config from the rv64 nommu virt defconfig; rewrite fragment deltas and comments
- **`linux/buildroot-external/board/frost/build_fpga_boot.py:122`** [medium] Generated DTS hardcodes riscv,isa-base = "rv32i", riscv,isa = "rv32imafdc...", compatible "frost,nommu-rv32" and model string (102-103); SHIM_MARCH/SHIM_MABI defaults rv32i_zicsr/ilp32 (69-70, doc 46-47). #address-cells=1 (100) stays valid for the sub-4GiB map but should be a conscious choice.
  - *Action:* Emit rv64 isa strings/compatible, default shim march rv64i_zicsr/lp64, fix the li sign-extension (separate finding), decide address-cells
- **`linux/buildroot-external/board/frost/patch_linux_image.py:94`** [medium] Kernel-image byte patches are pinned to the exact rv32 6.18.7 build: absolute addresses (PROC_GET_INODE_MODE_* 0x001071B2/0x00107220/0x0010718C, PROC_LOOKUP_* 0x0010BC82/0x0010BC7C), expected instruction bytes (lui a5,0x8 = b7 87 00 00), and cpu_relax offsets (0x1C/0x20). An rv64 kernel invalidates every offset; the byte-verify makes it fail loud, but all patch sites must be re-derived (or retired) for the rv64 image. The 4-byte word file format itself is XLEN-agnostic.
  - *Action:* Re-derive every patch offset/byte sequence against the rv64 kernel, or gate the mutations off for rv64 bring-up
- **`sw/common/common.mk:296`** [low] imem predecode init flow: common.mk lines 296-313 and fpga/build/build.py:423-452 (via hello_world's GENERATE_IMEM_INIT=1) are the two callers of generate_imem_predecode_init.py (audited by another agent). The predecode content is XLEN/RVC-sensitive (C.JAL disappears, new W-ops); callers themselves need no change beyond consuming any new sideband files.
  - *Action:* Coordinate: when the predecode script's outputs change for rv64, both call sites' file lists must track it

### Policy (needs a project decision)

- **`sw/lib/include/csr.h:85`** [low] Custom Tomasulo profiling CSR pair MPERFDATA/MPERFDATAH (0xFC0/0xFC1) is a split 32-bit high/low interface mirrored in RTL and tomasulo_profile.h consumers.
  - *Action:* Decide whether custom perf CSRs become single 64-bit reads on rv64 (RTL + sw/lib/include/tomasulo_profile.h + tools change together) or keep the split interface
- **`fpga/load_software/file_to_ddr.tcl:15`** [low] Loader/image formats (sw.txt/sw_ddr.txt one 32-bit word per line; objcopy --verilog-data-width 4; xxd -e -g4; jtag_axi M_AXI_DATA_WIDTH 32 in build_step.tcl:340) are byte-stream/bus-side and XLEN-independent - they work unchanged for rv64 ELFs. No change needed; flagged so nobody 'fixes' them to 8-byte words unnecessarily.
  - *Action:* Keep 32-bit word image formats (decision: do NOT widen); document that the format is memory-side, not XLEN-side
- **`sw/apps/riscv_tests/Makefile:17`** [medium] Suite runners target rv32 test sources (riscv-tests/isa/rv32ui, riscv-arch-test rv32i_m) per usage docs (riscv_tests:17, arch_test:17); riscv_torture generates rv32 programs. rv64 needs the rv64 suite directories and torture config - a test-matrix decision, not a flag flip.
  - *Action:* Decide the rv64 test matrix: rv64ui/rv64um/... suites, arch-test rv64i_m, torture rv64 config; decide whether rv32 suites are retired or kept for a dual-XLEN build
- **`sw/lib/include/trap.h:216`** [medium] rdmtime/set_timer_cmp use 32-bit MMIO hi/lo halves (216-242) - CORRECT on rv64 too since the CLINT-compatible MMIO registers stay 32-bit; only the max-first mtimecmp ordering comment stays valid. No change needed (flagged to prevent accidental 64-bit MMIO 'fix' that the bus may not support).
  - *Action:* Decide whether the CLINT alias gains 64-bit access on rv64 (Linux CLINT driver does sbi/mmio 32-bit pairs on rv32, single 64-bit reads on rv64 - check the kernel's rv64 clint timer path against the bus's 8-byte MMIO support)

### Mechanical (width/literal/comment hygiene)

- `sw/common/common.mk:91` [low] RISCV_FLAGS hardcodes -march=rv32imafdc_zicsr_zicntr_zifencei_zba_zbb_zbs_zicond_zbkb_zihintpause; MABI default ilp32d at line 44. This is the single central flag site for all C apps (good); comments at lines 48-65 document rv32.
- `sw/common/standalone_asm.mk:67` [low] LINK_FLAGS := -m elf32lriscv - ld emulation hardcoded; rv64 objects fail to link (loud, but must change).
- `sw/apps/branch_pred_test/Makefile:17` [medium] Hardcoded ARCH := rv32... / ABI := ilp32 is scattered across 9 standalone/suite app Makefiles: branch_pred_test:17, c_ext_test:17, ras_test:17, fpu_assembly_test:17, cf_ext_test:17, fetch_stall_repro:17, arch_test:25, riscv_tests:26, riscv_torture:26, coremark_pro:101, plus the doc template in sw/CONTRIBUTING.md:227.
- `sw/common/crt0.S:21` [low] Data-copy and BSS-zero loops use lw/sw with 4-byte strides. Functionally CORRECT on rv64 (word ops are legal; linker ALIGN(4) guarantees exact termination), just half-rate. Not a correctness change.
- `sw/common/link.ld:200` [low] __global_pointer$ = ADDR(.sdata)+0x800 and MMIO PROVIDE symbols are XLEN-agnostic; MEMORY origins/lengths (lines 41-47) unchanged under the sub-4GiB map; no OUTPUT_FORMAT/OUTPUT_ARCH pinning elf32 in either linker script - scripts work for both classes as written (only ALIGN(4) -> ALIGN(8) niceties).
- `sw/apps/linux_boot/Makefile:110` [low] Invokes Buildroot with frost_nommu_rv32_defconfig (also referenced in defconfig docs and linux/buildroot-external/README.md:93).
- `linux/buildroot-external/board/frost/post-image.sh:38` [low] Toolchain discovery globs ${HOST_DIR}/bin/riscv32-*-gcc; an rv64 Buildroot produces riscv64-* and the script exits (loud failure).
- `.github/workflows/ci.yml:617` [low] linux-boot-qemu job runs qemu-system-riscv32 with -cpu rv32,mmu=off (620). rv64 boot needs qemu-system-riscv64 / -cpu rv64,mmu=off (binary availability in the frost Docker image must be checked).
- `sw/README.md:627` [low] Docs assert ILP32D ABI, 32-bit overflow guidance (227), rv32 template in CONTRIBUTING.md:227-228/277, ISA support table 'RV32GCB'; linux/README.md:79/116 and buildroot-external/README.md (39, 63, 93, 102, 147, 199) document the rv32 pipeline.

## PD (pre-decode) stage: slot-1 RVC decompression mux, early source extraction, and the predicted-taken redirect fast path (PC+imm_b), plus its cocotb unit test

**Resolved (2026-08-10).** Native and compressed branch immediates are now
XLEN-wide, and the standalone stage derives XLEN from `riscv_pkg`. To remove
the new RV64 instruction-dependent timing floor, redirect-target arithmetic is
split exactly at bit 13. Protected native and compressed candidates each
compute their own low 13-bit sum and two-bit `carry-sign` correction choice.
The late format select chooses only those 15 bits before the existing nonstall
redirect-register edge. That edge separately captures the selected low/code
and early PC-high `H`, `H+1`, and `H-1` banks; the redirect-to-IF cycle
reconstructs the target with one shallow registered-data high mux. This
preserves the full-width modulo-XLEN result, stall/flush/redirect timing, and
cycle count while removing all full-width instruction-dependent logic from the
register D path.

The cocotb mirror now derives widths and masks from `verif/config.py`. Directed
native and compressed vectors cover all four `{sign, carry}` correction cases,
positive and negative wraparound, RV64 PCs with nonzero upper halves,
back-to-back format changes, and stall hold/release. Synthesis-excluded
equivalence assertions retain both original full-width adds and a delayed copy
of the former full-target register as references. Post-synthesis inspection
must still confirm that both candidate hierarchies survive, the format select
reaches only the 15 low/code D inputs, and the post-boundary target high path is
one mux over registered banks.

## cocotb unit tests: if_stage (aligner/decompressor/PC/branch-prediction), predecode mirrors, id_stage, ex_stage branch_jump_unit, cache

All 21 assigned test files were read in full. The cache suite (frost_cache, line_port_arbiter, fence_speed) is genuinely width-neutral - line-port protocol, byte strobes, sub-4-GiB addresses - and needs no RV64 work. The PC-side if_stage unit tests (pc_controller, pc_increment_calculator, c_ext_state, control_flow_tracker, metadata tracker, direction predictor, return_address_stack, branch_prediction_controller) are width-neutral too, with pc_controller already using the len(dut.o_pc)-derived-mask pattern the whole suite should adopt. The dangerous concentration is in the C-extension recode surface: test_rvc_decompressor.py asserts C.SUBW/C.ADDW space and C.SLLI shamt[5] are illegal (both valid on RV64) and has zero C.LD/C.SD/C.LDSP/C.SDSP/C.ADDIW vectors, so a recode that deletes the failing asserts ships the new table untested. The single worst finding is test_ras_detector.py, whose C.JAL-is-a-call assertion passes against un-recoded RTL and would actively pin RAS-corrupting behavior (C.ADDIW pushing return addresses) - an inverted, silently-green test. test_instruction_aligner.py and test_if_stage.py hardcode two C.JAL expansion constants (0xD0DFF0EF, 0x108000EF) that become wrong ADDIW rows. The predecode mirror test_imem_predecode_line.py is structurally sound - both sides derive from sw/common/generate_imem_predecode_init.py, so recoding that generator first turns four test files into automatic drift catchers - but its directed parcel list and the fast-replica bench's deliberately independent second model must gain RV64 rows (C.ADDIW non-control, C.SUBW/ADDW, OP-32/OP-IMM-32 near-misses). test_branch_jump_unit.py is the clearest vacuous-pass hazard outside the C-table: every operand fits in 32 bits, so a comparator left at [31:0] after widening would pass the entire suite; 64-bit discriminating vectors are mandatory. test_id_stage.py needs the same decode coverage (no LD/LWU/SD/W-op vectors); its widths now come from centralized `verif/config.py` and its instruction-operation ordinals are parsed from `riscv_pkg.sv`, while the hand-copied struct field tables still require mechanical tracking. Other private width-constant copies (MASK32, 0xFFFFFFFF masks, and the duplicated 18-bit sideband layout) should move to centralized verification-width definitions. Finally, two tests encode the pc[31]-anchored region assumptions (served-window guard arming, fetch-provider DDR select) that break if RTL mechanically migrates to pc[63] - the bit-31 address-map policy decision gates them.

### Hazards (compile-clean, silently wrong at XLEN=64)

- **`verif/cocotb_tests/if_stage/branch_prediction/test_ras_detector.py:176`** [high] test_compressed_call_return_and_coroutine_classification asserts the funct3=001/quadrant-01 parcel built by _make_c_jal (line 75) classifies as a RAS CALL. On RV64 that encoding is C.ADDIW (not control flow, not a call). This assertion PASSES against un-recoded RTL and actively pins the wrong behavior: an un-updated ras_detector would push a bogus RAS entry on every C.ADDIW and this test would keep it green.
  - *Action:* Flip the expectation to _assert_classification(dut) (no call/ret/coroutine) for the funct3=001 quadrant-01 parcel and add it as an explicit C.ADDIW-is-not-a-call regression; keep C.JALR/C.JR call/return vectors unchanged.
- **`verif/cocotb_tests/ex_stage/test_branch_jump_unit.py:23`** [high] MASK32/_u32 truncates every driven operand, target, and immediate to 32 bits (lines 43-45, 64-68), and all comparison vectors fit in 32 bits (e.g. 0xFFFFFFFF as -1 at lines 100-124). After widening, a comparator accidentally left at [31:0] or a sign-bit-31 index would pass every retained vector - complete vacuous-pass coverage hole for the upper 32 bits; meanwhile the 0xFFFFFFFF signed vectors change meaning (become +2^32-1) and fail confusingly.
  - *Action:* Replace MASK32 with an XLEN-derived mask; rewrite -1 vectors as 0xFFFFFFFF_FFFFFFFF; add discriminating vectors with sign bit 63 (BLT/BGE) and upper-half-only differences (BEQ/BNE/BLTU/BGEU with a=1<<32, b=0); add JALR vectors with 64-bit rs1 and bit-0 clearing above 4 GiB.
- **`verif/cocotb_tests/if_stage/test_if_stage.py:333`** [high] The served-window guard the tests depend on 'only arms in the cached region (pc_reg[XLEN-1])' per the tracker docstring. A mechanical XLEN flip moves that to bit 63, which is never set for the sub-4-GiB map: the guard goes dead, and test_fetch_window_lead_parity_plus2_desync (line 1199, served_word_offset=1) plus the workqueue_init_early +2-desync protection silently lose their RTL backstop (the test will fail loudly, but only because the guard died - the fix is in RTL policy, not the test).
  - *Action:* Pin the cached-region detect to the address-map bit (bit 31) or an explicit region-decode function in RTL; keep BASE_PC=0x80001000 vectors and assert the guard still arms there.
- **`verif/cocotb_tests/if_stage/branch_prediction/test_branch_predictor.py:124`** [medium] Slot-2 predecessor lookups mask base PCs with a hardcoded 0xFFFFFFFF (lines 124, 133, 409). At XLEN=64 with full-width BTB keys, (pc-2)&0xFFFFFFFF is the wrong predecessor for pc=0 (should borrow to 2^64-2); with compressed low-32 keys the tests pass while never exercising bits 63:32 of the key path.
  - *Action:* Replace masks with an XLEN-derived mask; decide key-width policy first (see decisions), then either rewrite wrap vectors at the 2^64 boundary or document/assert the low-32 compression.
- **`verif/cocotb_tests/id_stage/test_id_stage.py`** [resolved] Instruction-operation constants are parsed from `riscv_pkg.sv`, so insertions no longer leave hardcoded ordinals stale. All five local parser implementations accept the explicit packed enum base and still fail loudly on unrecognized entries.

### Design work (new logic or semantics)

- **`verif/cocotb_tests/if_stage/test_rvc_decompressor.py:444`** [high] test_quadrant1_alu_group_expands_and_rejects_rv64_only_ops asserts sub_raw|(1<<12) (the C.SUBW/C.ADDW encoding space) is illegal. Valid on RV64; after recode the assert fails, and if it is simply deleted, C.SUBW/C.ADDW expansion (funct7=0100000/0000000, OP-32 opcode 0b0111011) is untested.
  - *Action:* Replace with positive expansion vectors: C.SUBW -> SUBW rd',rd',rs2' and C.ADDW -> ADDW, plus the still-reserved funct2=10/11 rows as illegal.
- **`verif/cocotb_tests/if_stage/test_rvc_decompressor.py:558`** [high] test_shift_and_lwsp_rd_zero_illegal_cases asserts C.SLLI with bit12=1 (shamt[5]=1) is illegal - RV32-only reservation. On RV64 it is a valid 6-bit shamt. Deleting the vector without replacement leaves shamt6 expansion untested (the decompressor must emit shamt[5] into instruction bit 25).
  - *Action:* Convert to a positive vector: C.SLLI rd, shamt=32..63 expands to SLLI with imm[5]=1; add matching C.SRLI/C.SRAI bit12=1 vectors (quadrant-01 funct3=100). Keep the C.LWSP rd=x0 illegal case.
- **`verif/cocotb_tests/if_stage/test_rvc_decompressor.py:214`** [medium] test_all_rvc_source_hot_metadata_matches_decompressor exhaustively cross-checks all 49,152 parcels against generate_imem_predecode_init.rvc_source_hot. The recode (C.JAL->C.ADDIW, C.FLW/C.FSW->C.LD/C.SD int-register forms, C.FLWSP/C.FSWSP->C.LDSP/C.SDSP) changes source-register usage for whole encoding rows; RTL decompressor and the Python golden model must be recoded in lockstep or this test fails on every affected parcel.
  - *Action:* Recode sw/common/generate_imem_predecode_init.py rvc_source_hot alongside the decompressor; this test then serves as the drift catcher - do not weaken it.
- **`verif/cocotb_tests/if_stage/test_rvc_decompressor.py:286`** [high] Quadrant-0/quadrant-2 coverage has only C.LW/C.SW/C.LWSP/C.SWSP vectors. The RV64 rows C.LD/C.SD (funct3=011/111, 8-scaled uimm[7:3]) and C.LDSP/C.SDSP, plus C.ADDIW (old C.JAL row, rd!=0 required; rd=0 reserved-illegal), have no expansion vectors - deleting RV32-only cases would leave the whole new table vacuously untested.
  - *Action:* Add expansion vectors: C.LD->LD (funct3=011, imm helpers scaled by 8), C.SD->SD, C.LDSP->LD via x2, C.SDSP->SD via x2, C.ADDIW->ADDIW with rd=0 asserted illegal, and LWU absence (no compressed form).
- **`verif/cocotb_tests/if_stage/test_instruction_aligner.py:277`** [medium] test_high_parcel_selects_current_hi_and_next_lo_slot2 hardcodes the slot-2 effective expansion of parcel 0x3331 as 0xD0DFF0EF (C.JAL -> JAL x1). On RV64, 0x3331 is C.ADDIW and the expansion is an ADDIW encoding; the expected constant (and the driven rvc_source_hot_lo=3 at line 261) becomes wrong.
  - *Action:* Recompute the expected expansion for the RV64 decompressor (ADDIW rd, rd, imm) or switch the vector to a still-stable parcel (e.g. C.J/C.LI); update the driven source-hot value to match the new expansion.
- **`verif/cocotb_tests/if_stage/test_if_stage.py:528`** [medium] COMPRESSED_HINT=0x2221 (line 34) is expected to expand to 0x108000EF (C.JAL -> JAL x1) at lines 529 and 1124. On RV64, 0x2221 is C.ADDIW x4 - both expected-effective constants and the paired-slot control-flow assumptions become wrong.
  - *Action:* Recompute the two expected expansions as the ADDIW encoding (or substitute a truly width-stable hint parcel such as C.LI) and re-derive the source-hot value driven at line 508.
- **`verif/cocotb_tests/predecode/test_imem_predecode_line.py:170`** [high] The directed parcel list treats quadrant-01 funct3=001 as control flow ('C.JAL', lines 169-173). Expectations are derived from the generator, so the test stays green through the recode - it is the RTL-vs-Python drift catcher - but it gains no RV64-specific discrimination unless the directed list grows: no C.ADDIW-as-non-control case, no C.SUBW/C.ADDW row, no C.SLLI bit12=1, no C.LD/C.SD/C.LDSP/C.SDSP shapes, and no OP-32 (0b0111011)/OP-IMM-32 (0b0011011) native near-miss opcodes.
  - *Action:* Prerequisite: recode sw/common/generate_imem_predecode_init.py (compressed_control drops funct3=001; rvc_source_hot rows for C.ADDIW/C.LD/C.SD/C.LDSP/C.SDSP). Then extend parcels[] and NEAR_MISS_OPCODES with the RV64 rows above so the exhaustive/random tests plus directed vectors pin the new table on both the RTL and Python sides.
- **`verif/cocotb_tests/predecode/test_imem_predecode_fast_replica.py:102`** [medium] _expected_compressed_control - the deliberately independent second model - classifies quadrant-01 funct3=001 (C.JAL) as control. On RV64 it must drop 0b001 from the control set. If updated by copy-paste from the generator instead of independently from the spec, the cross-check loses its value; if not updated, every assert at lines 271-283 fails once the generator recodes.
  - *Action:* Independently re-derive _expected_compressed_control (and _expected_allows_slot2_after_hi) from the RV64 C-table: quadrant-01 control set becomes {101,110,111}; verify C.ADDIW rows now report allows-slot2.
- **`verif/cocotb_tests/id_stage/test_id_stage.py:555`** [high] Decode coverage is RV32-only: no vectors for LD/LWU/SD (mem-size-double int forms, is_load_unsigned for LWU, LW-now-sign-extends semantics), no ADDIW/SLLIW/W-ALU ops, no 6-bit shamt legality, no MULW/DIVW dispatch typing. After the decoder recode these paths ship untested unless new vectors are added - classic vacuous-pass gap.
  - *Action:* Add slot-1/slot-2 vectors: LD (funct3=011, RS_MEM, double size), LWU (funct3=110, is_load_unsigned), SD (store_operation=STD), ADDIW/ADDW/SUBW/SLLIW (OP-IMM-32/OP-32 opcodes with correct instruction_operation), SLLI with shamt bit 25 set legal, SRAIW with bit 25 set illegal.

### Mechanical (width/literal/comment hygiene)

- `verif/cocotb_tests/if_stage/test_instruction_aligner.py:31` [medium] Private copy of the full 18-bit sideband layout (SB_* indices, SIDEBAND_WIDTH=18, lines 31-45) and the _sideband() derivation logic, duplicated again in test_if_stage.py lines 39-53. Any RV64 predecode sideband change (bit growth or re-derivation) must be edited in two hand-written copies; a missed copy mispacks the bus silently.
- `verif/cocotb_tests/if_stage/test_if_stage.py:26` [medium] Private XLEN=32 constant drives every packed-struct field width (FROM_EX_FIELDS, TRAP_CTRL_FIELDS, IF_TO_PD_FIELDS, lines 65-105) and the served-window word masks (lines 339-340, 381). If riscv_pkg XLEN flips and this constant does not, all struct packing/unpacking misaligns.
- `verif/cocotb_tests/if_stage/branch_prediction/test_branch_predictor.py:663` [medium] test_shifted_slot2_alt_lookup_is_exact_across_key_wraps uses the case (actual 0x00000000 keyed by base 0xFFFFFFFC), explicitly labelled 'full XLEN wrap'. On RV64 the U-4 predecessor of 0 is 0xFFFFFFFF_FFFFFFFC; the vector silently stops testing the borrow it was written for. Same issue for second_pc=0 at line 549 via the line-124 mask.
- `verif/cocotb_tests/predecode/test_fetch_provider.py:163` [low] o_served_last_word expectation masks with hardcoded 0x3FFF_FFFF (the RV32 XLEN-2=30-bit word tag). Numerically harmless for these sub-4-GiB addresses, but it is a frozen copy of an RTL width that becomes 62 bits; also the provider's high-region select (DDR_BASE bit 31, line 38) must not migrate to bit 63 in RTL or every window in this bench stops validating.
- `verif/cocotb_tests/id_stage/test_id_stage.py` [medium] XLEN, FLEN, STORE_OP_WIDTH, and INSTR_OP_WIDTH now come from centralized `verif/config.py` (including the compact 8-bit instruction operation). The hand-copied struct tables remain a maintenance risk: any future field addition or width change must still update the mirror or packing silently misaligns.
- `verif/cocotb_tests/id_stage/test_id_stage.py:225` [resolved] `_sign_extend`
  now masks with centralized `MASK_XLEN`, matching RV32 and RV64 immediates.
- `verif/cocotb_tests/if_stage/test_pc_controller.py:139` [low] _assert_pending_predecessor_relation already derives its mask from len(dut.o_pc) - the pattern the rest of the suite should adopt; all PC vectors are sub-4-GiB and carry over unchanged.

## FP div/mul FU shims + FPU arithmetic internals (gap-fill: fp_div_shim, fp_mul_shim, 8 fpu arith primitives)

This gap-fill audit closes the question raised by the fp_add_shim findings: do fp_div_shim and fp_mul_shim share the same hazard family? They do not. Both shims were read in full (797 and 493 lines). fp_div_shim contains no reference to XLEN whatsoever — every datapath width is FLEN, TagW, or a flags width, and its 36/65-stage latency trackers are FP-pipeline properties. fp_mul_shim declares localparam XLEN = riscv_pkg::XLEN at line 58 but never uses it; it is dead code and the only finding of substance, a trivial mechanical cleanup. The specific fp_add_shim hazards were checked one-for-one: no fpu_convert_unit (or any XLEN-parameterized module) is instantiated by either shim, so there is no missing-.XLEN-override analog; the unbox32 helpers and {32'hFFFF_FFFF, result} NaN-boxing are keyed to FLEN, which stays 64, so they remain correct unchanged; there are no {(FLEN-XLEN){...}} replications; and no FP-to-integer results flow through these shims, so the RV64 sign-extension rule never applies here. The eight FPU arithmetic internals were verified rather than assumed FLEN-neutral: all derive every width from FP_WIDTH (or WIDTH/MANT_BITS/EXP_BITS parameters), and a full-body grep for [31:0], 32'h/32'd, {32{, [4:0] shamts, and stray 'd/'h literals found nothing integer-coupled — the only riscv_pkg references are fp_flags_t and rounding-mode enums. fp_lzc and fp_subnorm_shift, the shared primitives the FCVT.L rework will stretch, were read in full and are cleanly width-parametric; fp_convert already instantiates fp_lzc with .WIDTH(XLEN), so the 64-bit LZC comes for free, with only a timing watch on its linear-loop coding style at 64 bits. Net: zero hazards, zero design work, one dead localparam to delete in this subsystem; all real RV64 FP work concentrates in the convert path owned by the fp_add_shim audit.

### Design work (new logic or semantics)

- **`hw/rtl/cpu_and_mem/cpu/ex_stage/fpu/fp_lzc.sv:38`** [low] fp_lzc is fully width-parametric ($clog2(WIDTH+1) count output) and fp_convert.sv:156 already instantiates it with .WIDTH(XLEN), so the FCVT.L/LU rework gets a 64-bit LZC for free. However the implementation is a linear priority loop with an increment-per-zero chain (o_lzc = o_lzc + 1 inside a WIDTH-iteration loop); synthesis typically restructures this, but at WIDTH=64 the int-to-fp normalization stage in fp_convert plausibly deepens. Correctness is fine; this is a timing watch item, not a bug.
  - *Action:* Keep as-is for the widening; if the fp_convert s2 stage misses timing at 300 MHz with WIDTH=64, replace the linear loop with a recursive/binary LZC (drop-in, same ports).

### Mechanical (width/literal/comment hygiene)

- `hw/rtl/cpu_and_mem/cpu/tomasulo/fu_shims/fp_mul_shim.sv:58` [low] localparam int unsigned XLEN = riscv_pkg::XLEN is declared but never used anywhere in the module (grep confirms line 58 is the only XLEN occurrence in the file). It is dead code, not a live hazard: flipping riscv_pkg::XLEN to 64 changes nothing here. The critic's suspicion that fp_mul_shim shares fp_add_shim's missing-.XLEN-override family is disproven — the only subunits instantiated (fpu_mult_unit line 206, fpu_fma_unit line 233) have exactly one parameter, FP_WIDTH_D=64 (FLEN-coupled), and no XLEN parameter to forget.
- `hw/rtl/cpu_and_mem/cpu/tomasulo/fu_shims/fp_div_shim.sv:57` [low] unbox32 (lines 57-59) checks value[FLEN-1:32] and the SP result NaN-boxing at lines 271 and 279 writes {32'hFFFF_FFFF, result_s} into FLEN-wide unit_result. Both are keyed to FLEN, which stays 64 in the RV64 plan, so they remain CORRECT unchanged — verified, not assumed. fp_mul_shim's identical unbox32 (lines 61-63) and its src extraction (lines 144-149) are likewise FLEN-only. Flagging so the RV64 change explicitly leaves these alone; the only way they break is if FLEN were ever parameterized differently.
- `hw/rtl/cpu_and_mem/cpu/ex_stage/fpu/fp_subnorm_shift.sv:41` [low] fp_subnorm_shift is fully parametric over MANT_BITS/EXP_EXT_BITS (TotalBits = MANT_BITS+3, ShiftBits = $clog2(TotalBits+1), sticky loop bounded by TotalBits with a dynamic i < shift_amt compare). No hidden 24/48-bit assumptions; the convert path can reuse it unchanged. Note the planned ~117-bit FCVT shifter (ExtMantBits = MantBits + XLEN) lives in fp_convert.sv itself (line 79), not in this primitive — no change lands here.
- `hw/rtl/cpu_and_mem/cpu/tomasulo/fu_shims/fp_div_shim.sv:615` [low] o_fu_complete.value is driven from an FLEN-wide FIFO payload (sdp_dist_ram DATA_WIDTH(FLEN), line 508) into fu_complete_t.value, which is already FLEN=64 per the verified context; all tags/counters/latency trackers (DivSDepth=36, DivDDepth=65) are FP-pipeline properties independent of XLEN. Same for fp_mul_shim's fifo_value[FLEN-1:0] (line 184) and its o_fu_complete drive (line 445). The entire CDB-slot-5/6 payload path is XLEN-independent. No FCVT.L/LU, FMV.X.D or any FP-to-integer op routes through these shims (div/sqrt/mul/fma only), so none of the RV64 sign-extension semantics touch them.

## Residual sweep: zero-width-replication empirical test, unclaimed lib RTL, documentation staleness, hardware-validation scripts

The load-bearing empirical question is settled: {{(FLEN-XLEN){1'b0}}, x} with a zero replication count at XLEN=64 is accepted by every consumer of this RTL — CI's pinned Verilator 5.050 is clean even under -Wall, Yosys 0.64 read_verilog -sv is clean and a sat -verify pass proves the concat is exact pass-through (no bit loss), Verible lint/syntax are clean, Vivado 2025.2 xvlog is clean, and Vivado synth_design merely emits a benign per-site 'WARNING: [Synth 8-693] zero replication count - replication ignored' with correct netlist semantics. The ~15 sites flagged as hazards by other auditors should therefore be reclassified as cosmetics; the only reason to touch them is a warning-free Vivado log, and the rewrite is provably netlist-neutral. The unclaimed RTL is benign: cache_perf_pkg.sv is single-bit event flags (unaffected), sdp_dist_ram_2r.sv is fully width-parameterized with its sole instantiator passing explicit widths, and both cache test harnesses are line-granular with 32-bit AXI addressing that exactly matches line_port_axi_bridge's deliberately fixed [31:0] AXI ports — fine forever under the sub-4-GiB map, provided the cache-tier-keeps-ADDR_WIDTH=32 policy is recorded. The documentation sweep found the staleness concentrated in ISA strings and RV32-measured numbers: RV32GCB headlines (README.md:5/68/415, hw/rtl/README.md:4, tomasulo/README.md:5), instruction counts, rv32* test-suite names (README.md:303-306), the 977-CoreMark/3.26-per-MHz headline, the 17-stage-divider/4-stage-multiplier claims (fu_shims/README.md:47-48), the 'FSD on the 32-bit bus takes two phases' and word-granular forwarding taxonomy (store_queue/README.md:17-21/74-76), the SC 'word address' reservation-match claim (tomasulo_wrapper/README.md:81), and the mperfdata/mperfdatah 32-bit-halves protocol (perf/README.md:17-19/41-43). ROADMAP.md is already the RV64 plan and needs only phase-exit status plus the deferred rv32-fate decision. The two hardware-validation vehicles are in good shape for the X3 re-closure: both scripts judge boots purely by text tokens with no xlen/march/bus-width assumptions, linux_boot_soak.py's counter-delta gating ('counters=unavailable' → FAIL) remains valid because mcounteren stays a 32-bit CSR on RV64, and the only real landmine is hw_regression.py's BASELINE_SCORES, whose RV32-binary values under a 1% tolerance will spuriously fail (or slack-mask) the first rv64 runs unless reset to None and re-recorded at phase exit.

### Design work (new logic or semantics)

- **`hw/rtl/cpu_and_mem/cpu/tomasulo/store_queue/README.md:74`** [medium] 'FSD on the 32-bit bus takes two phases (low word at addr, high word at addr+4); the entry has a phase bit ...' (74-76) and the test-list line 244 'FSD two-phase'. On RV64, SD (and SC.D/AMO*.D stores) either join the two-phase drain or the bus widens to 64 bits — either way this text and the forwarding taxonomy at lines 17-21 ('FLD from an exact-address FSD (full 64-bit payload), or any byte/half/word load whose byte mask is a subset ... within one word (either word of a DOUBLE store counts as fully written)') describe RV32 semantics: LD/LWU as consumers and SD as a producer of 64-bit integer memory images are new cases the doc must cover.
  - *Action:* After the SQ/data-bus design lands (SD reusing the FSD phase machinery vs a 64-bit port), rewrite the forwarding-coverage and drain-phasing sections in the same change.
- **`hw/rtl/cpu_and_mem/cpu/tomasulo/tomasulo_wrapper/README.md:81`** [medium] SC state-machine doc: 'sc_success ... requires the reservation to be valid and its address to match the SC's own word address'. On RV64 with LR.D/SC.D the reservation granule becomes at least 8 bytes and the match must be size-aware (an SC.W against an LR.D address, and vice versa, per the reservation-set rules). The word-address phrasing documents RV32-only behavior.
  - *Action:* When sc_pending_unit/LQ reservation logic gains the D-granule, update this section (granule size, LR.D/SC.D pairing rules) in the same change.

### Policy (needs a project decision)

- **`hw/rtl/lib/cache/frost_cache_test_harness.sv:126`** [low] Harness internal AXI address wires are hardcoded logic [31:0] (line 126) and BASE_ADDR is parameter logic [31:0] = 32'h8000_0000 (line 37), while the upstream line-port address is ADDR_WIDTH-parameterized (default 32). This exactly matches line_port_axi_bridge.sv, whose o_axi_awaddr/o_axi_araddr are fixed [31:0] by design (lines 53/67). Everything else in the harness is LINE_BYTES-granular (line data/wstrb) with zero XLEN dependence; the cocotb cache benches drive it via -G generics.
  - *Action:* Nothing to change IF the project decision is that the cache tier keeps 32-bit physical addresses (sub-4-GiB map) and the LSU/cached_tier_adapter truncates/checks bits [63:32] above this seam. If instead ADDR_WIDTH were ever raised past 32, the [31:0] AXI wires here and in the bridge silently truncate — so record the keep-ADDR_WIDTH=32 decision explicitly.
- **`hw/rtl/lib/cache/line_port_arbiter_test_harness.sv:97`** [low] Same shape as frost_cache_test_harness: ADDR_WIDTH parameter (default 32, line 28), BASE_ADDR parameter logic [31:0] (line 30), internal AXI address wires hardcoded [31:0] (line 97) matching the bridge's fixed 32-bit AXI address ports. Line-granular data paths carry no XLEN dependence.
  - *Action:* Unchanged under the sub-4-GiB physical-map decision; covered by the same cache-tier ADDR_WIDTH=32 policy call as the sibling harness.
- **`hw/rtl/cpu_and_mem/cpu/cpu_ooo/perf/README.md:18`** [low] Custom perf CSR protocol documents mperfdata (0xFC0) = 'Selected counter, low 32 bits' and mperfdatah (0xFC1) = 'high 32 bits', with lines 41-43 promising 'the two halves are consistent without a hi/lo re-read loop'. On RV64 every CSR read returns 64 bits, so mperfdata could return the whole counter and mperfdatah becomes redundant (or is kept for sw compatibility). Whichever way csr_file goes, this README and tomasulo_profile.h software must move in the same change.
  - *Action:* Decide: keep the hi/lo pair (sw-compatible, mperfdatah reads bits 63:32 zero-extended... or full) vs collapse to a single 64-bit mperfdata read; update README + csr_file + profiling sw together.
- **`ROADMAP.md:110`** [low] ROADMAP is already RV64-aware (Phase 1 IS the widening plan; lines 94-115 match this audit's scope) and needs no staleness fix now — but lines 110-111 explicitly defer 'whether the rv32 configuration remains a maintained build or is frozen ... decided at phase exit', which is the same dual-XLEN-vs-rv64-only decision that determines the final wording of every ISA-string doc fix above.
  - *Action:* At phase exit: mark Phase 1 done, record the rv32-config decision, and phrase the README/ISA docs accordingly (RV64GCB vs configurable RV32/RV64).

### Mechanical (width/literal/comment hygiene)

- `hw/rtl/cpu_and_mem/cpu/tomasulo/register_alias_table/register_alias_table.sv:471` [low] EMPIRICAL RESULT settling the multi-auditor zero-width-replication question. A test module using the exact repo idiom {{(FLEN-XLEN){1'b0}}, x} with FLEN=XLEN=64 (assign form, always_comb form, and multi-member concat form) was run through every consumer toolchain. Verilator 5.050 (pinned CI image): lint-only CLEAN, and CLEAN under -Wall. Yosys 0.64 read_verilog -sv: CLEAN, and 'sat -verify -prove' proves o_a==i_x and o_b==i_x ('SAT proof finished - no model found: SUCCESS!') — semantics are exact pass-through, no bit loss. Verible lint + syntax: CLEAN. Vivado 2025.2 xvlog -sv: CLEAN. Vivado 2025.2 synth_design (part xcux35-vsva1365-3-e, the project's X3 part): ACCEPTS with one benign 'WARNING: [Synth 8-693] zero replication count - replication ignored' per site and a semantically correct netlist (verified via constant-propagation of the concat members). Conclusion: the ~15 sites flagged as 'per-tool lint hazard' by other auditors (this line plus register_alias_table.sv:475/487/491/537/541/553/557, reorder_buffer/reorder_buffer.sv:1008/1013, tomasulo_wrapper.sv:886/946/1419, int_muldiv_shim.sv:267/518, int_alu_shim.sv:139/158, fp_add_shim.sv:406/425, load_queue.sv:1732/1834/1844/1853/1875, sq_forwarding_unit.sv:397, cpu_ooo.sv:2308) are NOT blockers and NOT hazards — reclassify them all as cosmetic. All repo sites are concat-context with constant counts (the LRM-legal form), matching the tested pattern; cpu_ooo.sv:2418's {(XLEN-$bits(cause)){1'b0}} count stays nonzero at 64 and is not even zero-width.
- `README.md:5` [low] Headline claims 'RV32GCB (G = IMAFD) ... Machine + User (M/U) privilege modes'. Stale the moment XLEN flips.
- `README.md:13` [low] Performance headline '3.26 CoreMark/MHz (977 CoreMark at 300 MHz on UltraScale+)' is an RV32-binary measurement; the rv64 recompile plus 64-bit datapath respin will move it. fpga/hw_regression.py:121-122 explicitly cites this README figure as the source of its baseline.
- `README.md:68` [low] 'ISA: RV32GCB (G = IMAFD) ... 170+ instructions' and line 72 'RV32I | Base integer instruction set (37 instructions)'. Both the ISA string and both instruction counts change on RV64 (RV64I base has more instructions; W-ops/LWU/LD/SD/64-bit FCVT/AMO*.D/Zba-W/Zbb-W forms grow the total; ZIP/UNZIP drop).
- `README.md:305` [low] Test-matrix text is rv32-specific: line 303 'rv32ua/rv32uc riscv-tests', line 305 '126 self-checking tests ... across rv32ui, rv32um, rv32ua, rv32uf, rv32ud, rv32uc, rv32mi', line 306 '20 randomly generated RV32IMAFDC instruction sequences ... Spike'. Suite names, test counts, and the torture ISA string all change when the matrices mirror to rv64 (ROADMAP Phase 1 verification plan).
- `README.md:415` [low] Glossary entry 'RV32I | RISC-V 32-bit base integer instruction set' (and the G = IMAFD framing around it) is RV32-specific.
- `hw/rtl/README.md:4` [low] 'The current CPU is an out-of-order RV32GCB implementation ...'. Only RV32-specific claim found in this file; the memory map (all below 4 GiB), MMIO table, 64-bit fetch-window statements, and CACHED_BASE=32'h8000_0000 parameter table remain valid under the unchanged physical map.
- `hw/rtl/cpu_and_mem/cpu/tomasulo/README.md:5` [low] 'existing ISA support (RV32IMACBFD + Zbkb + Zicond + Zicntr + Zifencei + Zihintpause)' — stale ISA string. Also line 59's load_queue table entry 'FP64 phasing' and line 60's store_queue entry 'FSD phasing' describe two-phase 64-bit accesses over the 32-bit data bus; on RV64 LD/SD join that behavior (or the bus widens), so the phrasing must follow the data-bus decision.
- `hw/rtl/cpu_and_mem/cpu/tomasulo/fu_shims/README.md:47` [low] 'the multiplier is 4-stage with up to 4 in-flight multiplies, the divider is 17-stage with up to 17 in-flight divisions' — these are the 32-bit unit latencies/occupancies. A 64x64 multiplier and 64-bit divider will have different depths (the radix-constant divider roughly doubles), changing both the stage counts and the credit-based occupancy figures documented here. The NaN-boxing statements (lines 34/44/74-75) remain correct on RV64 and newly cover FCVT.S.L/LU results.
- `fpga/hw_regression.py:124` [medium] BASELINE_SCORES pins RV32-binary hardware scores (x3: coremark 977.13, coremark_pro 111.14; genesys2: 433.65/39.0) with a default 1% drop tolerance. The rv64 recompile plus 64-bit datapath will shift these; left as-is the coremark/coremark_pro stages of the X3 timing-re-closure validation runs will fail spuriously (or, if scores rise then later regress within the stale-baseline slack, mask a real regression). The None-baseline mechanism (lines 63-65, 175-180) already exists for re-arming. Everything else in the file is XLEN-agnostic: pass/fail is pure text-token parsing (<<PASS>>/<<FAIL>>/<<TRAP>>/ERROR/:fails=N, lines 192-211), the coremark score uses the mtime-derived 'Total 64-bit ticks' line (line 163) which is unchanged, and the linux stage checks only Buildroot login markers (lines 153-154).
- `fpga/linux_boot_soak.py:189` [low] UART scoring is fully XLEN-agnostic: PASS/FAIL tokens (FROST_USERSPACE_STRESS_PASS/_FAIL, lines 55-56), crash markers (58-66), and the Zicntr counter-delta check are pure string matches — the summary line is located by 'FROST_USERSPACE_STRESS:' + 'verdict=' (line 189) and counters are judged only via the substring 'counters=unavailable' (line 196). The mcounteren rationale in the docstring (lines 25-28) and comment (198-199) stays TRUE on RV64 (mcounteren remains a 32-bit CSR, reset 0x7). One cross-cutting dependency: on RV64 the userspace payload must read counters via full-width rdcycle/rdinstret only — any leftover rdcycleh/rdinstreth path becomes illegal and would trap; if the payload then degrades to counters=unavailable, this script correctly turns that into FAIL(counters-unavailable), so the detection net is already in place. No change to this file.

---

# Appendix: per-file coverage

Best coverage achieved across auditors (`full` = read line-by-line,
`targeted` = grep-driven with hot regions read, `skimmed` = structure
only). Verdict is the auditor's classification of the file's RV64 cost.

| File | Coverage | Verdict |
|---|---|---|
| `.github/workflows/ci.yml (linux-boot-qemu job)` | targeted | mechanical-only |
| `.github/workflows/ci.yml` | full | design-work |
| `Dockerfile` | full | design-work |
| `README.md` | targeted | mechanical-only |
| `ROADMAP.md` | targeted | unaffected |
| `boards/README.md` | skimmed | unaffected |
| `docker_entrypoint.py` | full | unaffected |
| `formal/README.md` | full | unaffected |
| `formal/cdb_arbiter.sby` | skimmed | unaffected |
| `formal/csr_file.sby` | full | unaffected |
| `formal/fp_add_shim.sby` | skimmed | unaffected |
| `formal/fp_div_shim.sby` | skimmed | unaffected |
| `formal/fp_mul_shim.sby` | skimmed | unaffected |
| `formal/fu_cdb_adapter.sby` | skimmed | unaffected |
| `formal/fu_cdb_adapter_payload_no_refill.sby` | skimmed | unaffected |
| `formal/load_queue.sby` | skimmed | unaffected |
| `formal/lq_l0_cache.sby` | skimmed | unaffected |
| `formal/register_alias_table.sby` | skimmed | unaffected |
| `formal/reorder_buffer.sby` | full | unaffected |
| `formal/reservation_station.sby` | skimmed | unaffected |
| `formal/rs_issue2_selector.sby` | skimmed | unaffected |
| `formal/store_queue.sby` | skimmed | unaffected |
| `formal/tomasulo_wrapper.sby` | skimmed | unaffected |
| `formal/trap_unit.sby` | full | unaffected |
| `fpga/build/build.py` | targeted | unaffected |
| `fpga/build/build_step.tcl` | targeted | unaffected |
| `fpga/common/hw_defaults.py` | full | unaffected |
| `fpga/common/hw_target.py` | skimmed | unaffected |
| `fpga/hw_regression.py` | full | mechanical-only |
| `fpga/linux_boot_soak.py` | full | unaffected |
| `fpga/load_software/file_to_bram.tcl` | targeted | unaffected |
| `fpga/load_software/file_to_ddr.tcl` | targeted | unaffected |
| `fpga/load_software/load_software.py` | targeted | unaffected |
| `fpga/load_software/load_software.tcl` | targeted | unaffected |
| `hw/rtl/README.md` | full | mechanical-only |
| `hw/rtl/cpu_and_mem/cpu/README.md` | full | unaffected |
| `hw/rtl/cpu_and_mem/cpu/control/trap_unit.sv` | full | design-work |
| `hw/rtl/cpu_and_mem/cpu/cpu_ooo/branch_recovery/branch_resolution.sv` | full | clean-parametric |
| `hw/rtl/cpu_and_mem/cpu/cpu_ooo/branch_recovery/early_misprediction_recovery.sv` | full | mechanical-only |
| `hw/rtl/cpu_and_mem/cpu/cpu_ooo/branch_recovery/misprediction_flush_controller.sv` | full | clean-parametric |
| `hw/rtl/cpu_and_mem/cpu/cpu_ooo/commit/commit_actions.sv` | full | clean-parametric |
| `hw/rtl/cpu_and_mem/cpu/cpu_ooo/cpu_ooo.sv` | targeted | design-work |
| `hw/rtl/cpu_and_mem/cpu/cpu_ooo/frontend_control/frontend_validity_tracker.sv` | full | design-work |
| `hw/rtl/cpu_and_mem/cpu/cpu_ooo/memory_if/cached_tier_adapter.sv` | full | design-work |
| `hw/rtl/cpu_and_mem/cpu/cpu_ooo/memory_if/data_mem_request_router.sv` | full | design-work |
| `hw/rtl/cpu_and_mem/cpu/cpu_ooo/perf/README.md` | targeted | design-work |
| `hw/rtl/cpu_and_mem/cpu/cpu_ooo/perf/perf_counter_aggregator.sv` | targeted | unaffected |
| `hw/rtl/cpu_and_mem/cpu/cpu_ooo/pipeline_control/ooo_pipeline_control.sv` | full | clean-parametric |
| `hw/rtl/cpu_and_mem/cpu/cpu_ooo/recovery/ex_comb_synthesizer.sv` | full | mechanical-only |
| `hw/rtl/cpu_and_mem/cpu/cpu_ooo/register_files/ooo_register_files.sv` | full | clean-parametric |
| `hw/rtl/cpu_and_mem/cpu/csr/csr_file.sv` | full | design-work |
| `hw/rtl/cpu_and_mem/cpu/ex_stage/alu/alu.sv` | full | design-work |
| `hw/rtl/cpu_and_mem/cpu/ex_stage/alu/divider.sv` | full | clean-parametric |
| `hw/rtl/cpu_and_mem/cpu/ex_stage/alu/multiplier.sv` | full | design-work |
| `hw/rtl/cpu_and_mem/cpu/ex_stage/branch_jump_unit.sv` | full | clean-parametric |
| `hw/rtl/cpu_and_mem/cpu/ex_stage/dsp_tiled_multiplier_unsigned.sv` | full | clean-parametric |
| `hw/rtl/cpu_and_mem/cpu/ex_stage/fpu/fp_adder.sv` | targeted | unaffected |
| `hw/rtl/cpu_and_mem/cpu/ex_stage/fpu/fp_classify.sv` | full | unaffected |
| `hw/rtl/cpu_and_mem/cpu/ex_stage/fpu/fp_classify_operand.sv` | full | unaffected |
| `hw/rtl/cpu_and_mem/cpu/ex_stage/fpu/fp_compare.sv` | full | unaffected |
| `hw/rtl/cpu_and_mem/cpu/ex_stage/fpu/fp_convert.sv` | full | design-work |
| `hw/rtl/cpu_and_mem/cpu/ex_stage/fpu/fp_convert_sd.sv` | full | unaffected |
| `hw/rtl/cpu_and_mem/cpu/ex_stage/fpu/fp_divider.sv` | targeted | unaffected |
| `hw/rtl/cpu_and_mem/cpu/ex_stage/fpu/fp_fma.sv` | targeted | unaffected |
| `hw/rtl/cpu_and_mem/cpu/ex_stage/fpu/fp_lzc.sv` | full | clean-parametric |
| `hw/rtl/cpu_and_mem/cpu/ex_stage/fpu/fp_multiplier.sv` | targeted | unaffected |
| `hw/rtl/cpu_and_mem/cpu/ex_stage/fpu/fp_operand_unpacker.sv` | full | unaffected |
| `hw/rtl/cpu_and_mem/cpu/ex_stage/fpu/fp_result_assembler.sv` | full | unaffected |
| `hw/rtl/cpu_and_mem/cpu/ex_stage/fpu/fp_sign_inject.sv` | full | unaffected |
| `hw/rtl/cpu_and_mem/cpu/ex_stage/fpu/fp_sqrt.sv` | targeted | unaffected |
| `hw/rtl/cpu_and_mem/cpu/ex_stage/fpu/fp_subnorm_shift.sv` | full | clean-parametric |
| `hw/rtl/cpu_and_mem/cpu/ex_stage/fpu/fpu_adder_unit.sv` | skimmed | unaffected |
| `hw/rtl/cpu_and_mem/cpu/ex_stage/fpu/fpu_classify_unit.sv` | full | unaffected |
| `hw/rtl/cpu_and_mem/cpu/ex_stage/fpu/fpu_compare_unit.sv` | full | design-work |
| `hw/rtl/cpu_and_mem/cpu/ex_stage/fpu/fpu_convert_unit.sv` | full | design-work |
| `hw/rtl/cpu_and_mem/cpu/ex_stage/fpu/fpu_div_sqrt_unit.sv` | skimmed | unaffected |
| `hw/rtl/cpu_and_mem/cpu/ex_stage/fpu/fpu_fma_unit.sv` | skimmed | unaffected |
| `hw/rtl/cpu_and_mem/cpu/ex_stage/fpu/fpu_mult_unit.sv` | skimmed | unaffected |
| `hw/rtl/cpu_and_mem/cpu/ex_stage/fpu/fpu_sign_inject_unit.sv` | skimmed | unaffected |
| `hw/rtl/cpu_and_mem/cpu/id_stage/branch_target_precompute.sv` | full | clean-parametric |
| `hw/rtl/cpu_and_mem/cpu/id_stage/id_stage.sv` | full | design-work |
| `hw/rtl/cpu_and_mem/cpu/id_stage/immediate_decoder.sv` | full | design-work |
| `hw/rtl/cpu_and_mem/cpu/id_stage/instr_decoder.sv` | full | design-work |
| `hw/rtl/cpu_and_mem/cpu/id_stage/instruction_type_decoder.sv` | full | design-work |
| `hw/rtl/cpu_and_mem/cpu/if_stage/branch_prediction/branch_prediction_controller.sv` | full | clean-parametric |
| `hw/rtl/cpu_and_mem/cpu/if_stage/branch_prediction/branch_predictor.sv` | full | mechanical-only |
| `hw/rtl/cpu_and_mem/cpu/if_stage/branch_prediction/direction_predictor.sv` | full | clean-parametric |
| `hw/rtl/cpu_and_mem/cpu/if_stage/branch_prediction/prediction_metadata_tracker.sv` | full | clean-parametric |
| `hw/rtl/cpu_and_mem/cpu/if_stage/branch_prediction/ras_detector.sv` | full | design-work |
| `hw/rtl/cpu_and_mem/cpu/if_stage/branch_prediction/return_address_stack.sv` | full | clean-parametric |
| `hw/rtl/cpu_and_mem/cpu/if_stage/c_extension/c_ext_state.sv` | full | mechanical-only |
| `hw/rtl/cpu_and_mem/cpu/if_stage/c_extension/instruction_aligner.sv` | full | design-work |
| `hw/rtl/cpu_and_mem/cpu/if_stage/c_extension/rvc_decompressor.sv` | full | design-work |
| `hw/rtl/cpu_and_mem/cpu/if_stage/control_flow_tracker.sv` | full | clean-parametric |
| `hw/rtl/cpu_and_mem/cpu/if_stage/if_stage.sv` | full | design-work |
| `hw/rtl/cpu_and_mem/cpu/if_stage/pc_controller.sv` | full | clean-parametric |
| `hw/rtl/cpu_and_mem/cpu/if_stage/pc_increment_calculator.sv` | full | mechanical-only |
| `hw/rtl/cpu_and_mem/cpu/if_stage/pc_reg_precompute.sv` | full | clean-parametric |
| `hw/rtl/cpu_and_mem/cpu/pd_stage/pd_stage.sv` | full | mechanical-only |
| `hw/rtl/cpu_and_mem/cpu/riscv_pkg.sv` | full | design-work |
| `hw/rtl/cpu_and_mem/cpu/tomasulo/README.md` | targeted | mechanical-only |
| `hw/rtl/cpu_and_mem/cpu/tomasulo/cdb_arbiter/cdb_arbiter.sv` | full | unaffected |
| `hw/rtl/cpu_and_mem/cpu/tomasulo/dispatch/README.md` | full | unaffected |
| `hw/rtl/cpu_and_mem/cpu/tomasulo/dispatch/dispatch.sv` | full | design-work |
| `hw/rtl/cpu_and_mem/cpu/tomasulo/fu_cdb_adapter/fu_cdb_adapter.sv` | full | unaffected |
| `hw/rtl/cpu_and_mem/cpu/tomasulo/fu_shims/README.md` | full | mechanical-only |
| `hw/rtl/cpu_and_mem/cpu/tomasulo/fu_shims/fp_add_shim.sv` | full | design-work |
| `hw/rtl/cpu_and_mem/cpu/tomasulo/fu_shims/fp_div_shim.sv` | full | unaffected |
| `hw/rtl/cpu_and_mem/cpu/tomasulo/fu_shims/fp_mul_shim.sv` | full | mechanical-only |
| `hw/rtl/cpu_and_mem/cpu/tomasulo/fu_shims/int_alu_shim.sv` | full | design-work |
| `hw/rtl/cpu_and_mem/cpu/tomasulo/fu_shims/int_muldiv_shim.sv` | full | design-work |
| `hw/rtl/cpu_and_mem/cpu/tomasulo/load_queue/load_queue.sv` | targeted | design-work |
| `hw/rtl/cpu_and_mem/cpu/tomasulo/load_queue/load_unit.sv` | full | design-work |
| `hw/rtl/cpu_and_mem/cpu/tomasulo/load_queue/lq_issue_selector.sv` | full | clean-parametric |
| `hw/rtl/cpu_and_mem/cpu/tomasulo/load_queue/lq_l0_cache.sv` | full | design-work |
| `hw/rtl/cpu_and_mem/cpu/tomasulo/register_alias_table/register_alias_table.sv` | full | mechanical-only |
| `hw/rtl/cpu_and_mem/cpu/tomasulo/reorder_buffer/reorder_buffer.sv` | full | design-work |
| `hw/rtl/cpu_and_mem/cpu/tomasulo/reorder_buffer/rob_serializer.sv` | full | unaffected |
| `hw/rtl/cpu_and_mem/cpu/tomasulo/reservation_station/reservation_station.sv` | targeted | design-work |
| `hw/rtl/cpu_and_mem/cpu/tomasulo/reservation_station/rs_issue2_selector.sv` | full | unaffected |
| `hw/rtl/cpu_and_mem/cpu/tomasulo/store_queue/README.md` | targeted | design-work |
| `hw/rtl/cpu_and_mem/cpu/tomasulo/store_queue/sq_forwarding_unit.sv` | full | design-work |
| `hw/rtl/cpu_and_mem/cpu/tomasulo/store_queue/store_queue.sv` | targeted | design-work |
| `hw/rtl/cpu_and_mem/cpu/tomasulo/tomasulo_wrapper/README.md` | targeted | design-work |
| `hw/rtl/cpu_and_mem/cpu/tomasulo/tomasulo_wrapper/atomics/sc_pending_unit.sv` | full | design-work |
| `hw/rtl/cpu_and_mem/cpu/tomasulo/tomasulo_wrapper/commit_bus/commit_bus_pipeline.sv` | full | clean-parametric |
| `hw/rtl/cpu_and_mem/cpu/tomasulo/tomasulo_wrapper/dispatch_routing/dispatch_rs_router.sv` | full | unaffected |
| `hw/rtl/cpu_and_mem/cpu/tomasulo/tomasulo_wrapper/perf/tomasulo_perf_counters.sv` | targeted | unaffected |
| `hw/rtl/cpu_and_mem/cpu/tomasulo/tomasulo_wrapper/store_addr/sq_early_addr_pipeline.sv` | full | mechanical-only |
| `hw/rtl/cpu_and_mem/cpu/tomasulo/tomasulo_wrapper/tomasulo_wrapper.sv` | targeted | design-work |
| `hw/rtl/cpu_and_mem/cpu/wb_stage/generic_regfile.sv` | full | clean-parametric |
| `hw/rtl/cpu_and_mem/cpu_and_mem.sv` | full | design-work |
| `hw/rtl/cpu_and_mem/fetch_provider.sv` | full | mechanical-only |
| `hw/rtl/cpu_and_mem/hang_triage.sv` | full | mechanical-only |
| `hw/rtl/cpu_and_mem/imem_predecode.sv` | full | unaffected |
| `hw/rtl/cpu_and_mem/imem_predecode_line.sv` | full | unaffected |
| `hw/rtl/frost.sv` | full | mechanical-only |
| `hw/rtl/lib/cache/axi_behavioral_memory.sv` | full | unaffected |
| `hw/rtl/lib/cache/cache_perf_pkg.sv` | full | unaffected |
| `hw/rtl/lib/cache/frost_cache.sv` | full | clean-parametric |
| `hw/rtl/lib/cache/frost_cache_hierarchy.sv` | full | clean-parametric |
| `hw/rtl/lib/cache/frost_cache_test_harness.sv` | full | unaffected |
| `hw/rtl/lib/cache/line_port_arbiter.sv` | full | clean-parametric |
| `hw/rtl/lib/cache/line_port_arbiter_test_harness.sv` | full | unaffected |
| `hw/rtl/lib/cache/line_port_axi_bridge.sv` | full | mechanical-only |
| `hw/rtl/lib/fifo/dc_fifo.sv` | skimmed | clean-parametric |
| `hw/rtl/lib/fifo/sync_dist_ram_fifo.sv` | skimmed | clean-parametric |
| `hw/rtl/lib/ram/mwp_dist_ram.sv` | skimmed | clean-parametric |
| `hw/rtl/lib/ram/mwp_dist_ram_2r.sv` | skimmed | clean-parametric |
| `hw/rtl/lib/ram/mwp_dist_ram_ohread.sv` | skimmed | clean-parametric |
| `hw/rtl/lib/ram/sdp_block_ram.sv` | skimmed | clean-parametric |
| `hw/rtl/lib/ram/sdp_block_ram_dc.sv` | skimmed | clean-parametric |
| `hw/rtl/lib/ram/sdp_dist_ram.sv` | skimmed | clean-parametric |
| `hw/rtl/lib/ram/sdp_dist_ram_2r.sv` | full | clean-parametric |
| `hw/rtl/lib/ram/sdp_ram_byte_en.sv` | skimmed | clean-parametric |
| `hw/rtl/lib/ram/tdp_bram_dc.sv` | skimmed | clean-parametric |
| `hw/rtl/lib/ram/tdp_bram_dc_byte_en.sv` | skimmed | mechanical-only |
| `hw/rtl/peripherals/uart_rx.sv` | full | unaffected |
| `hw/rtl/peripherals/uart_tx.sv` | full | unaffected |
| `hw/sim/cpu_tb.sv` | full | design-work |
| `linux/README.md` | targeted | mechanical-only |
| `linux/build/Makefile` | full | unaffected |
| `linux/buildroot-external/README.md` | targeted | mechanical-only |
| `linux/buildroot-external/board/frost/build_fpga_boot.py` | full | design-work |
| `linux/buildroot-external/board/frost/linux-nommu-base.config` | targeted | mechanical-only |
| `linux/buildroot-external/board/frost/linux-nommu-frost.config.fragment` | targeted | mechanical-only |
| `linux/buildroot-external/board/frost/patch_linux_image.py` | targeted | design-work |
| `linux/buildroot-external/board/frost/post-image.sh` | full | mechanical-only |
| `linux/buildroot-external/configs/frost_nommu_rv32_defconfig` | full | mechanical-only |
| `linux/buildroot-external/external.mk` | full | unaffected |
| `linux/buildroot-external/package/frost-stress/frost-stress.mk` | full | unaffected |
| `linux/buildroot-external/package/frost-stress/src/frost_stress.c` | targeted | design-work |
| `scripts/frost.py` | targeted | unaffected |
| `sw/CONTRIBUTING.md` | targeted | mechanical-only |
| `sw/FreeRTOS-Kernel (port wiring only)` | skimmed | unaffected |
| `sw/README.md` | targeted | mechanical-only |
| `sw/apps/* Makefiles (9 with hardcoded ARCH/ABI: branch_pred_test, c_ext_test, ras_test, fpu_assembly_test, cf_ext_test, fetch_stall_repro, arch_test, riscv_tests, riscv_torture, coremark_pro; coremark MABI)` | targeted | mechanical-only |
| `sw/apps/c_ext_test/c_ext_test.S` | targeted | design-work |
| `sw/apps/compile_app.py, build_all_apps.py, software_registry.py` | skimmed | unaffected |
| `sw/apps/freertos_demo/ (Makefile, portmacro.h, port_frost.c, port_frost_asm.S)` | targeted | design-work |
| `sw/apps/hello_world/Makefile` | full | unaffected |
| `sw/apps/isa_test/isa_test.c` | targeted | design-work |
| `sw/apps/linux_boot/Makefile` | targeted | mechanical-only |
| `sw/apps/umode_test/main.c` | targeted | design-work |
| `sw/common/common.mk` | full | mechanical-only |
| `sw/common/crt0.S` | full | clean-parametric |
| `sw/common/crt0_ddr_boot.S` | full | clean-parametric |
| `sw/common/generate_imem_predecode_init.py` | full | design-work |
| `sw/common/link.ld` | full | mechanical-only |
| `sw/common/link_ddr.ld` | full | mechanical-only |
| `sw/common/standalone_asm.mk` | full | mechanical-only |
| `sw/lib/include/csr.h` | full | design-work |
| `sw/lib/include/limits.h` | targeted | mechanical-only |
| `sw/lib/include/mmio.h` | targeted | unaffected |
| `sw/lib/include/timer.h` | targeted | unaffected |
| `sw/lib/include/trap.h` | full | design-work |
| `sw/lib/src/memory.c` | targeted | clean-parametric |
| `sw/lib/src/sprintf.c` | targeted | clean-parametric |
| `sw/lib/src/string.c` | targeted | clean-parametric |
| `tests/Makefile` | full | unaffected |
| `tests/check_linux_boot_regression.py` | full | unaffected |
| `tests/conftest.py` | full | unaffected |
| `tests/test_arch_compliance.py` | full | design-work |
| `tests/test_riscv_tests.py` | full | design-work |
| `tests/test_riscv_torture.py` | full | design-work |
| `tests/test_run_cocotb.py` | targeted | mechanical-only |
| `tests/test_run_formal.py` | full | unaffected |
| `tests/test_run_yosys.py` | full | unaffected |
| `tests/test_runner_helpers.py` | full | mechanical-only |
| `verif/cocotb_tests/cache/test_fence_speed.py` | full | unaffected |
| `verif/cocotb_tests/cache/test_frost_cache.py` | full | unaffected |
| `verif/cocotb_tests/cache/test_line_port_arbiter.py` | full | unaffected |
| `verif/cocotb_tests/control/test_trap_unit.py` | targeted | mechanical-only |
| `verif/cocotb_tests/cpu_model.py` | targeted | design-work |
| `verif/cocotb_tests/cpu_ooo/** (commit, frontend, memory, perf, pipeline_control, recovery, register_files tests)` | skimmed | mechanical-only |
| `verif/cocotb_tests/ex_stage/test_branch_jump_unit.py` | full | design-work |
| `verif/cocotb_tests/id_stage/test_id_stage.py` | full | design-work |
| `verif/cocotb_tests/if_stage/**, pd_stage/**, id_stage/**, ex_stage/**, predecode/**, cache/**` | not-read | unknown |
| `verif/cocotb_tests/if_stage/branch_prediction/test_branch_prediction_controller.py` | full | unaffected |
| `verif/cocotb_tests/if_stage/branch_prediction/test_branch_predictor.py` | full | mechanical-only |
| `verif/cocotb_tests/if_stage/branch_prediction/test_direction_predictor.py` | full | unaffected |
| `verif/cocotb_tests/if_stage/branch_prediction/test_prediction_metadata_tracker.py` | full | unaffected |
| `verif/cocotb_tests/if_stage/branch_prediction/test_ras_detector.py` | full | design-work |
| `verif/cocotb_tests/if_stage/branch_prediction/test_return_address_stack.py` | full | unaffected |
| `verif/cocotb_tests/if_stage/test_c_ext_state.py` | full | unaffected |
| `verif/cocotb_tests/if_stage/test_control_flow_tracker.py` | full | unaffected |
| `verif/cocotb_tests/if_stage/test_if_stage.py` | full | design-work |
| `verif/cocotb_tests/if_stage/test_instruction_aligner.py` | full | design-work |
| `verif/cocotb_tests/if_stage/test_pc_controller.py` | full | clean-parametric |
| `verif/cocotb_tests/if_stage/test_pc_increment_calculator.py` | full | unaffected |
| `verif/cocotb_tests/if_stage/test_rvc_decompressor.py` | full | design-work |
| `verif/cocotb_tests/instruction_executor.py` | skimmed | mechanical-only |
| `verif/cocotb_tests/instruction_generator.py` | targeted | design-work |
| `verif/cocotb_tests/pd_stage/test_pd_stage.py` | full | design-work |
| `verif/cocotb_tests/predecode/test_fetch_provider.py` | full | mechanical-only |
| `verif/cocotb_tests/predecode/test_imem_predecode_fast_replica.py` | full | design-work |
| `verif/cocotb_tests/predecode/test_imem_predecode_line.py` | full | design-work |
| `verif/cocotb_tests/test_common.py` | skimmed | mechanical-only |
| `verif/cocotb_tests/test_compressed.py` | targeted | design-work |
| `verif/cocotb_tests/test_cpu.py` | targeted | mechanical-only |
| `verif/cocotb_tests/test_directed_atomics.py` | skimmed | mechanical-only |
| `verif/cocotb_tests/test_directed_multicycle.py` | skimmed | design-work |
| `verif/cocotb_tests/test_directed_traps.py` | targeted | mechanical-only |
| `verif/cocotb_tests/test_helpers.py` | targeted | mechanical-only |
| `verif/cocotb_tests/test_real_program.py` | targeted | mechanical-only |
| `verif/cocotb_tests/test_state.py` | full | design-work |
| `verif/cocotb_tests/tomasulo/ (dispatch, store_queue, load_queue, reorder_buffer, rat, fu_shims, cdb_arbiter, fu_cdb_adapter, tomasulo_wrapper interfaces/models)` | skimmed | mechanical-only |
| `verif/cocotb_tests/tomasulo/reservation_station/rs_interface.py` | targeted | mechanical-only |
| `verif/config.py` | full | design-work |
| `verif/encoders/__init__.py` | skimmed | unaffected |
| `verif/encoders/compressed_encode.py` | full | design-work |
| `verif/encoders/instruction_encode.py` | full | design-work |
| `verif/encoders/op_tables.py` | full | design-work |
| `verif/exceptions.py` | full | unaffected |
| `verif/models/__init__.py` | skimmed | unaffected |
| `verif/models/alu_model.py` | full | design-work |
| `verif/models/branch_model.py` | full | mechanical-only |
| `verif/models/fp_model.py` | full | design-work |
| `verif/models/memory_model.py` | full | design-work |
| `verif/monitors/__init__.py` | skimmed | unaffected |
| `verif/monitors/monitors.py` | full | mechanical-only |
| `verif/utils/__init__.py` | not-read | unknown |
| `verif/utils/instruction_logger.py` | full | mechanical-only |
| `verif/utils/memory_utils.py` | full | design-work |
| `verif/utils/riscv_utils.py` | full | design-work |
| `verif/utils/validation.py` | full | unaffected |
| `verif/verification_types.py` | full | mechanical-only |
