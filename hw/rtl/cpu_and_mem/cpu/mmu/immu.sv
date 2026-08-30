/*
 *    Copyright 2026 Two Sigma Open Source, LLC
 *
 *    Licensed under the Apache License, Version 2.0 (the "License");
 *    you may not use this file except in compliance with the License.
 *    You may obtain a copy of the License at
 *
 *        http://www.apache.org/licenses/LICENSE-2.0
 *
 *    Unless required by applicable law or agreed to in writing, software
 *    distributed under the License is distributed on an "AS IS" BASIS,
 *    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *    See the License for the specific language governing permissions and
 *    limitations under the License.
 */

/*
 * immu -- the instruction-side Sv39 translation (Phase 3 M5, plan D5).
 *
 * Lives in if_stage beside pc_controller and translates the FETCH PC with
 * zero added hit latency: the result of translating the NEXT pc lands in PA
 * SHADOW registers clocked by the same enable as pc itself. The shadows
 * therefore describe o_pc's fetch window identity-timed with o_pc, and the
 * lookup cone ends at their D pins -- nothing of the TLB reaches the BRAM
 * address pins, the provider's window-ready cone, or the
 * fetch-progress -> PC loop (M4's registered-resolution lesson).
 *
 * A fetch window is the two words {pc, pc + 4}. Each shadow load resolves
 *   word 0: pa0 / fault0 for pc's page, and
 *   word 1: pa1 / fault1 for word 1 -- pa0 + 4 inside the page; across a
 *           4 KiB boundary (pc[11:2] all ones) a SECOND translation of the
 *           next page, resolved on the held pc (below)
 *             (a) at once when word 0 hit a superpage the next page stays
 *                 inside (the kernel's 2 MiB text), or
 *             (b) through the ITLB's second port, keyed by the registered
 *                 next-page VA once that describes the held pc.
 * Translation inactive (satp Bare or M-mode): the shadows are the VA's low
 * 32 bits and the Bare PMA verdict -- the seam is bit-identical to the
 * pre-M5 physical fetch, prefetch across pages included, and never stalls.
 *
 * TIMING SHAPE (the fetch-seam restructure). next_pc is the output of
 * pc_controller's priority selector and arrives late; everything keyed on
 * it is on the boards' worst path. So the translation is organised around
 * the pc that is already REGISTERED, and the selector's arms are judged in
 * PARALLEL with the selection:
 *   - The ITLB's port 0 is keyed on i_pc. A hit yields pc's LEAF, and a
 *     leaf covers every VA that agrees with pc above the leaf's index bits;
 *     the PPN for another VA in the leaf is rematerialised by mask-merge
 *     (it is NOT pc's materialised PPN -- inside a superpage that is a
 *     different physical page).
 *   - On a pc LOAD each arm's early value is tested for "clean fetch inside
 *     pc's leaf" (covered, canonical, X permission for the live privilege,
 *     PMA-clean, not straddling a page); the arms that are pc + d (d < 16)
 *     inherit pc's own verdict outright unless pc sits within 16 bytes of
 *     its page end. The winner's verdict is a one-hot select of 1-bit
 *     results; the data path from next_pc is one mask-merge and a +4.
 *   - Anything else -- a target outside pc's leaf (even one the ITLB
 *     holds), a non-canonical target, a permission/PMA fault, a
 *     page-straddling window, a memoised refusal, an invalidate -- DEFERS:
 *     the shadow loads unresolved, the front end stalls, and the next
 *     evaluation runs on the now-registered pc through the complete
 *     resolver (faults, refusals, the superpage next page, the second port,
 *     the walker). The result is what the same-cycle resolution would have
 *     produced, a cycle or two later. Cross-page redirects, page-straddling
 *     windows and refusals are the only fetches that pay.
 *   - Bare mode never defers: the arms' Bare verdicts (straddle, the two
 *     words' PMA faults) come predecoded -- per PC-advance candidate on the
 *     sequential arms (riscv_pkg::fetch_verdict, pc_increment_calculator),
 *     from the early operand on the others -- and are selected like the
 *     translated verdict; a straddling window's next page is pc's next
 *     page (the register's increment) or the operand's.
 *   - The hold arm (no fetch progress: next_pc = pc) leaves the shadow
 *     untouched -- it already describes pc. Reset leaves it describing
 *     pc 0's Bare window, which is what the reset pc is.
 *   - The next-page key for the second port is pc's next page computed
 *     from the REGISTER every cycle, valid once pc has held for a cycle;
 *     nothing of it depends on next_pc.
 *
 * Refusals never stall: a non-canonical VA, a permission miss (X=0, or the
 * page's U bit disagreeing with the privilege -- SUM never applies to
 * fetch), a walk refusal (PF/AF, remembered in a one-entry memo because the
 * TLB stores only leaves), or a translated PA outside the fetch PMA map
 * mark the word FAULTED (page vs access kind) in a still-valid shadow: the
 * seam forms the window without touching memory and IF delivers the
 * fault-tagged bundle (FETCH_FAULT / FETCH_PAGE_FAULT). A word-1-only
 * fault is raised only if the bundle actually consumes word 1 (a
 * page-straddling instruction, or slot 2 starting in the next page).
 *
 * ITLB misses: o_pa_valid drops and the FRONT END STALLS (cpu_ooo folds
 * the shadow bit into pipeline_ctrl.stall): IF captures the bundle being
 * presented and replays it at release, the provider parks its owed ask,
 * and the fetch lead the front end's lockstep depends on is untouched --
 * holding pc alone would let pc_reg catch up and the same window be served
 * twice. While stalled the shadow keeps re-evaluating on pc itself, the
 * walker is asked for the missing page (the data side wins the shared ptw,
 * D6), and the response installs the leaf or memoizes the refusal -- the
 * same-cycle bypass resolves the shadow from the response itself. The
 * flash invalidate (sfence.vma window / D10 pulse) clears the ITLB, the
 * memo and any pending ask; it also masks the lookup in its own cycle so a
 * shadow loaded at the flush redirect edge cannot carry the old address
 * space's translation. (A shadow that already describes a held pc keeps
 * it across the invalidate, exactly as before: the flush redirect that
 * follows reloads it.)
 */
module immu #(
    parameter int unsigned XLEN = riscv_pkg::XLEN,
    parameter int unsigned NUM_ENTRIES = 8
) (
    input logic i_clk,
    input logic i_rst,

    // Fetch translation state, combinational from csr_file's registers
    // (satp.MODE == Sv39 && priv != M; priv == U). Unregistered on purpose:
    // the trap/xret/satp-write redirect edge must load the target's shadow
    // under the NEW privilege/satp, and csr_file updates those a cycle
    // before the front-end redirect lands.
    input logic i_active,
    input logic i_priv_u,

    // Flash invalidate (sfence.vma serialized window / D10 flush pulse).
    input logic i_tlb_invalidate,

    // PC path (pc_controller): the pc/pc_reg flop enable, the next-pc mux
    // output, "next_pc holds at o_pc by mux selection", and o_pc itself.
    // A load evaluates the selector's arms (below); a hold -- a stall,
    // including the one an unresolved shadow raises -- re-evaluates pc.
    input logic i_pc_update_en,
    input logic [XLEN-1:0] i_next_pc,
    input logic i_next_pc_holds,
    input logic [XLEN-1:0] i_pc,

    // The selector's view of the same load: the one-hot arm winner, which
    // arms carry pc + d (0 <= d < 16) and those arms' predecoded fetch
    // verdicts, and each other arm's EARLY value -- the operand its
    // translation is judged on while the winner is still being chosen.
    // next_pc itself only feeds the data path.
    input logic [riscv_pkg::PcNextArms-1:0] i_npc_sel,
    input logic [riscv_pkg::PcNextArms-1:0] i_npc_seq,
    input logic [riscv_pkg::PcNextArms-1:0][XLEN-1:0] i_npc_cmp_val,
    // Each arm's actual value: the load's physical-address candidates are
    // computed per arm and selected by i_npc_sel, in parallel with next_pc.
    input logic [riscv_pkg::PcNextArms-1:0][XLEN-1:0] i_npc_val,
    input riscv_pkg::fetch_verdict_t [riscv_pkg::PcNextArms-1:0] i_npc_seq_verdict,

    // Shadows: identity-timed with o_pc.
    output logic [31:0] o_pa0,
    output logic [31:0] o_pa1,
    output logic o_pa_valid,  // both words resolved (translated or faulted)
    output logic o_fault0,
    output logic o_fault0_page,  // 1 = page fault (12), 0 = access fault (1)
    output logic o_fault1,
    output logic o_fault1_page,
    // The line after word 0's line is physically the next line (always in
    // Bare; under translation only inside the page, or when the window
    // itself straddles into it -- then it is pa1's line).
    output logic o_line_after_ok,

    // Walker seam (through cpu_ooo's requester mux; D-side wins).
    output logic o_walk_req_valid,
    input logic i_walk_req_ready,
    output logic [riscv_pkg::Sv39VpnBits-1:0] o_walk_vpn,
    input logic i_walk_resp_valid,
    input riscv_pkg::ptw_resp_t i_walk_resp
);

  localparam int unsigned VpnBits = riscv_pkg::Sv39VpnBits;
  localparam int unsigned NpBits = XLEN - riscv_pkg::Sv39PageOffsetBits;  // next-page VA[63:12]
  localparam int unsigned NArms = riscv_pkg::PcNextArms;

  // ---------------------------------------------------------------------------
  // The pc -- the held-cycle key and the leaf context of every load.
  // ---------------------------------------------------------------------------
  logic valid_q;  // the shadow is resolved (declared with the registers below)
  logic [VpnBits-1:0] pc_vpn;
  logic pc_noncanon;
  logic pc_page_cross;  // word 0 is its page's last word: word 1 lies in the next page
  logic [NpBits-1:0] pc_np_va;  // VA[63:12] of pc's next page
  logic pc_np_noncanon;
  logic [9:0] pc_plus4_lo;  // (pc + 4)[11:2] when not crossing
  assign pc_vpn = i_pc[38:12];
  assign pc_noncanon = !riscv_pkg::sv39_va_canonical(i_pc);
  assign pc_page_cross = &i_pc[11:2];
  assign pc_np_va = i_pc[XLEN-1:12] + 1'b1;
  assign pc_np_noncanon = !riscv_pkg::sv39_va_canonical({pc_np_va, 12'h000});
  assign pc_plus4_lo = i_pc[11:2] + 1'b1;

  // A pc load while the shadow is unresolved (a redirect landing during the
  // hold, or the flush that released it) pairs this evaluation's key (the
  // old pc) with the NEW pc: force one more unresolved cycle so the next
  // evaluation runs on the new pc, and never walk on the stale key.
  logic key_stale;
  assign key_stale = !valid_q && i_pc_update_en;

  // Registered next-page key for the crossing lookup: pc's next page as of
  // the previous edge, so it describes the current pc exactly when pc did
  // not move at that edge (np_key_valid_q).
  logic [NpBits-1:0] np_va_q;
  logic np_noncanon_q;
  logic np_key_valid_q;

  // ---------------------------------------------------------------------------
  // ITLB: port 0 = pc's page, port 1 = the registered next page.
  // ---------------------------------------------------------------------------
  logic [1:0][VpnBits-1:0] tlb_vpn;
  logic [1:0] tlb_hit;
  logic [1:0][19:0] tlb_ppn20;
  logic [1:0] tlb_hi_nonzero;
  logic [1:0] tlb_r, tlb_w, tlb_x, tlb_u, tlb_d;
  logic [1:0][1:0] tlb_level;
  assign tlb_vpn[0] = pc_vpn;
  assign tlb_vpn[1] = np_va_q[VpnBits-1:0];

  logic tlb_install;
  assign tlb_install = i_walk_resp_valid &&
      (i_walk_resp.fault_kind == riscv_pkg::DFAULT_NONE) && !i_tlb_invalidate;

  dtlb #(
      .NUM_ENTRIES(NUM_ENTRIES),
      .NUM_PORTS  (2)
  ) u_itlb (
      .i_clk(i_clk),
      .i_rst_n(!i_rst),
      .i_invalidate_all(i_tlb_invalidate),
      .i_install_valid(tlb_install),
      .i_install(i_walk_resp),
      .i_lookup_vpn(tlb_vpn),
      .o_hit(tlb_hit),
      .o_ppn20(tlb_ppn20),
      .o_ppn_hi_nonzero(tlb_hi_nonzero),
      .o_perm_r(tlb_r),
      .o_perm_w(tlb_w),
      .o_perm_x(tlb_x),
      .o_perm_u(tlb_u),
      .o_perm_d(tlb_d),
      .o_level(tlb_level)
  );

  // ---------------------------------------------------------------------------
  // Walk-refusal memo (one entry: the TLB stores leaves only). Walk
  // refusals are privilege-independent facts about the page tables, so the
  // memo lives until the next invalidate (a stale memo is the same class as
  // a stale TLB entry -- software's sfence.vma obligation).
  // ---------------------------------------------------------------------------
  logic memo_valid_q;
  logic [VpnBits-1:0] memo_vpn_q;
  logic memo_page_q;

  logic resp_refused;
  assign resp_refused = i_walk_resp_valid && (i_walk_resp.fault_kind != riscv_pkg::DFAULT_NONE);

  always_ff @(posedge i_clk) begin
    if (i_rst || i_tlb_invalidate) begin
      memo_valid_q <= 1'b0;
    end else if (resp_refused) begin
      memo_valid_q <= 1'b1;
      memo_vpn_q   <= i_walk_resp.vpn;
      memo_page_q  <= (i_walk_resp.fault_kind == riscv_pkg::DFAULT_PAGE);
    end
  end

  // ---------------------------------------------------------------------------
  // Per-port resolution (translated): {resolved, fault, page, pa[31:12],
  // level, superpage-derivable}. The walk response bypasses the TLB in its
  // own cycle; the invalidate masks everything in its cycle.
  // ---------------------------------------------------------------------------
  function automatic logic [19:0] ppn20_from_resp(input riscv_pkg::ptw_resp_t resp,
                                                  input logic [VpnBits-1:0] vpn);
    unique case (resp.level)
      2'd2: ppn20_from_resp = {resp.ppn[19:18], vpn[17:0]};
      2'd1: ppn20_from_resp = {resp.ppn[19:9], vpn[8:0]};
      default: ppn20_from_resp = resp.ppn[19:0];
    endcase
  endfunction

  typedef struct packed {
    logic resolved;  // translated or faulted (else: needs a walk / the second port)
    logic fault;
    logic page;  // fault kind
    logic [19:0] ppn20;
    logic hi_nonzero;
    logic [1:0] level;
    logic clean_hit;  // a permission-clean, in-map leaf (for the superpage next page)
  } port_res_t;

  function automatic port_res_t resolve_port(
      input logic noncanon, input logic [VpnBits-1:0] vpn, input logic hit,
      input logic [19:0] ppn20, input logic hi_nonzero, input logic perm_x, input logic perm_u,
      input logic [1:0] level, input logic priv_u, input logic invalidate, input logic resp_valid,
      input riscv_pkg::ptw_resp_t resp, input logic memo_valid, input logic [VpnBits-1:0] memo_vpn,
      input logic memo_page);
    port_res_t r;
    logic resp_match, use_resp_leaf, have;
    logic e_x, e_u, e_hi_nonzero;
    logic [19:0] e_ppn20;
    logic [ 1:0] e_level;
    logic perm_ok, pma_bad;
    begin
      r = '0;
      resp_match = resp_valid && !invalidate && (resp.vpn == vpn);
      use_resp_leaf = resp_match && (resp.fault_kind == riscv_pkg::DFAULT_NONE);
      have = (hit && !invalidate) || use_resp_leaf;
      if (use_resp_leaf && !(hit && !invalidate)) begin
        e_x = resp.perm_x;
        e_u = resp.perm_u;
        e_hi_nonzero = |resp.ppn[riscv_pkg::PtePpnBits-1:20];
        e_ppn20 = ppn20_from_resp(resp, vpn);
        e_level = resp.level;
      end else begin
        e_x = perm_x;
        e_u = perm_u;
        e_hi_nonzero = hi_nonzero;
        e_ppn20 = ppn20;
        e_level = level;
      end
      // Fetch permission: X, and the page's U bit must match the privilege
      // (U code only from U, S/kernel code only from S; SUM is data-only).
      perm_ok = e_x && (e_u == priv_u);
      pma_bad = e_hi_nonzero || !riscv_pkg::pma_fetch_ok({32'b0, e_ppn20, 12'h000});
      r.ppn20 = e_ppn20;
      r.hi_nonzero = e_hi_nonzero;
      r.level = e_level;
      if (noncanon) begin
        r.resolved = 1'b1;
        r.fault = 1'b1;
        r.page = 1'b1;
      end else if (have) begin
        r.resolved = 1'b1;
        if (!perm_ok) begin
          r.fault = 1'b1;
          r.page  = 1'b1;
        end else if (pma_bad) begin
          r.fault = 1'b1;
          r.page  = 1'b0;
        end else begin
          r.clean_hit = 1'b1;
        end
      end else if (resp_match) begin
        // The walk itself was refused.
        r.resolved = 1'b1;
        r.fault = 1'b1;
        r.page = (resp.fault_kind == riscv_pkg::DFAULT_PAGE);
      end else if (memo_valid && !invalidate && (memo_vpn == vpn)) begin
        r.resolved = 1'b1;
        r.fault = 1'b1;
        r.page = memo_page;
      end
      resolve_port = r;
    end
  endfunction

  // ---------------------------------------------------------------------------
  // LOAD cycle: the selector's arms judged against pc's leaf, in parallel
  // with the selection.
  // ---------------------------------------------------------------------------
  // Index bits the leaf's level leaves to the VA (0 for 4 KiB, 9 for 2 MiB,
  // 18 for 1 GiB). The PPN[19:0] and VPN index bits sit at the same offsets,
  // so one mask serves both the coverage compare and the rematerialisation.
  logic [19:0] lvl_mask;
  always_comb begin
    unique case (tlb_level[0])
      2'd2: lvl_mask = 20'h3_FFFF;
      2'd1: lvl_mask = 20'h0_01FF;
      default: lvl_mask = 20'h0_0000;
    endcase
  end

  // pc's leaf, judged for the live privilege: present, executable from
  // here, and inside the 32-bit physical map.
  logic pc_leaf_ok;  // usable leaf (coverage, canonicality and PMA still per target)
  logic pc_leaf_clean;  // ... and pc's own page is a clean fetch
  assign pc_leaf_ok = tlb_hit[0] && !i_tlb_invalidate && tlb_x[0] && (tlb_u[0] == i_priv_u) &&
      !tlb_hi_nonzero[0];
  // pc's own canonicality is part of its verdict: the CAM matches on
  // VA[38:12] alone, so a NON-canonical pc (a faulted shadow, still being
  // delivered) can alias a clean leaf -- its sequential successors must
  // fault exactly as it did, not fetch from the aliased page.
  assign pc_leaf_clean = pc_leaf_ok && !pc_noncanon && riscv_pkg::pma_fetch_ok(
      {32'b0, tlb_ppn20[0], 12'h000}
  );

  // pc + d (d < 16) stays in pc's page -- same leaf, same permission, same
  // PMA, same canonical half -- unless pc is within 16 bytes of the page
  // end; there the arm simply defers to the held-cycle resolver.
  logic seq_near_end;
  logic seq_clean;
  assign seq_near_end = &i_pc[11:4];
  assign seq_clean = pc_leaf_clean && !seq_near_end;

  // A leaf covers a VA iff they agree above the level's index bits. The
  // leaf's own index bits are zero (the walker's alignment check), so the
  // VA's index bits OR-ed into the masked PPN is that VA's physical page.
  function automatic logic [19:0] leaf_ppn20(input logic [XLEN-1:0] va, input logic [19:0] mask,
                                             input logic [19:0] ppn20);
    leaf_ppn20 = (ppn20 & ~mask) | (va[31:12] & mask);
  endfunction

  // Clean same-cycle fetch of an arbitrary VA from pc's leaf: covered,
  // canonical (a [38:12]-only match would alias non-canonical VAs),
  // PMA-clean for ITS physical page, and not straddling a page (word 1
  // would need the next page's leaf).
  function automatic logic leaf_clean_for(input logic [XLEN-1:0] va, input logic leaf_ok,
                                          input logic [VpnBits-1:0] pcv, input logic [19:0] mask,
                                          input logic [19:0] ppn20);
    logic covered, canon, pma_ok, straddle;
    begin
      covered = (((va[38:12] ^ pcv) & ~{{(VpnBits - 20) {1'b0}}, mask}) == '0);
      canon = riscv_pkg::sv39_va_canonical(va);
      pma_ok = riscv_pkg::pma_fetch_ok({32'b0, leaf_ppn20(va, mask, ppn20), 12'h000});
      straddle = &va[11:2];
      leaf_clean_for = leaf_ok && covered && canon && pma_ok && !straddle;
    end
  endfunction

  // Per arm: the translated verdict, the Bare/window verdict (predecoded
  // for the sequential arms, from the operand for the rest), and the next
  // page a straddling Bare window continues into (pc's for a sequential
  // arm: its value is in pc's page whenever it straddles).
  logic [NArms-1:0] arm_clean;
  riscv_pkg::fetch_verdict_t [NArms-1:0] arm_verdict;
  logic [NArms-1:0][19:0] arm_np20;
  logic load_clean;
  riscv_pkg::fetch_verdict_t load_verdict;
  logic [19:0] load_np20;
  always_comb begin
    for (int unsigned k = 0; k < NArms; k++) begin
      arm_clean[k] = i_npc_seq[k] ? seq_clean :
          leaf_clean_for(i_npc_cmp_val[k], pc_leaf_ok, pc_vpn, lvl_mask, tlb_ppn20[0]);
      arm_verdict[k] = i_npc_seq[k] ? i_npc_seq_verdict[k] :
          riscv_pkg::fetch_verdict(i_npc_cmp_val[k]);
      arm_np20[k] = i_npc_seq[k] ? pc_np_va[19:0] : (i_npc_cmp_val[k][31:12] + 20'd1);
    end
    load_clean = 1'b0;
    load_verdict = '0;
    load_np20 = '0;
    for (int unsigned k = 0; k < NArms; k++) begin
      load_clean |= i_npc_sel[k] & arm_clean[k];
      load_verdict |= {riscv_pkg::FetchVerdictBits{i_npc_sel[k]}} & arm_verdict[k];
      load_np20 |= {20{i_npc_sel[k]}} & arm_np20[k];
    end
  end

  // The load's data path: next_pc's page offset; its physical page -- the
  // leaf's PPN mask-merged with the offset's index bits under translation,
  // the VA itself in Bare, one mask/or per bit either way; and the
  // following word's page (the next page when the Bare window straddles --
  // a translated load never straddles -- and the +4 wraps to its base on
  // its own).
  //
  // TIMING: next_pc is the one-hot select of the arm values, so the page
  // merge, the straddle mux, and the +4 increment are computed per arm from
  // the arm values (all early: registered targets or pc's carry chains) and
  // the winner is selected once, in parallel with next_pc itself, instead of
  // serially after it. Exact for a one-hot select; the oracle below pins it.
  logic [19:0] load_hi_mask, load_hi_or, load_pa0_hi, load_pa1_hi;
  logic [9:0] load_plus4_lo;
  logic [NArms-1:0][19:0] arm_pa0_hi, arm_pa1_hi;
  logic [NArms-1:0][9:0] arm_plus4_lo;
  assign load_hi_mask = i_active ? lvl_mask : 20'hF_FFFF;
  assign load_hi_or   = i_active ? (tlb_ppn20[0] & ~lvl_mask) : 20'h0_0000;
  always_comb begin
    for (int unsigned k = 0; k < NArms; k++) begin
      arm_pa0_hi[k]   = (i_npc_val[k][31:12] & load_hi_mask) | load_hi_or;
      arm_pa1_hi[k]   = arm_verdict[k].straddle ? arm_np20[k] : arm_pa0_hi[k];
      arm_plus4_lo[k] = i_npc_val[k][11:2] + 1'b1;
    end
    load_pa0_hi   = '0;
    load_pa1_hi   = '0;
    load_plus4_lo = '0;
    for (int unsigned k = 0; k < NArms; k++) begin
      load_pa0_hi |= {20{i_npc_sel[k]}} & arm_pa0_hi[k];
      load_pa1_hi |= {20{i_npc_sel[k]}} & arm_pa1_hi[k];
      load_plus4_lo |= {10{i_npc_sel[k]}} & arm_plus4_lo[k];
    end
  end

`ifndef SYNTHESIS
  // The per-arm candidates must equal the serial form on the selected value.
  logic [19:0] load_pa0_hi_ref, load_pa1_hi_ref;
  logic [9:0] load_plus4_lo_ref;
  logic [XLEN-1:0] next_pc_ref;
  always_comb begin
    load_pa0_hi_ref = (i_next_pc[31:12] & load_hi_mask) | load_hi_or;
    load_pa1_hi_ref = load_verdict.straddle ? load_np20 : load_pa0_hi_ref;
    load_plus4_lo_ref = i_next_pc[11:2] + 1'b1;
    next_pc_ref = '0;
    for (int unsigned k = 0; k < NArms; k++) next_pc_ref |= {XLEN{i_npc_sel[k]}} & i_npc_val[k];
    if (!$isunknown(
            {i_npc_sel, i_next_pc, i_npc_val, load_hi_mask, load_hi_or, load_verdict, load_np20}
        )) begin
      p_npc_val_selects_next_pc : assert ($onehot(i_npc_sel) && (next_pc_ref == i_next_pc));
      p_load_pa_per_arm_exact :
      assert ((load_pa0_hi == load_pa0_hi_ref) && (load_pa1_hi == load_pa1_hi_ref) &&
              (load_plus4_lo == load_plus4_lo_ref));
    end
  end
`endif

  // ---------------------------------------------------------------------------
  // HELD cycle: the complete resolver on pc (port 0) and its next page
  // (port 1).
  // ---------------------------------------------------------------------------
  port_res_t res0, res1;
  assign res0 = resolve_port(
      pc_noncanon,
      pc_vpn,
      tlb_hit[0],
      tlb_ppn20[0],
      tlb_hi_nonzero[0],
      tlb_x[0],
      tlb_u[0],
      tlb_level[0],
      i_priv_u,
      i_tlb_invalidate,
      i_walk_resp_valid,
      i_walk_resp,
      memo_valid_q,
      memo_vpn_q,
      memo_page_q
  );
  assign res1 = resolve_port(
      np_noncanon_q,
      np_va_q[VpnBits-1:0],
      tlb_hit[1],
      tlb_ppn20[1],
      tlb_hi_nonzero[1],
      tlb_x[1],
      tlb_u[1],
      tlb_level[1],
      i_priv_u,
      i_tlb_invalidate,
      i_walk_resp_valid,
      i_walk_resp,
      memo_valid_q,
      memo_vpn_q,
      memo_page_q
  );

  // Superpage next page: word 0 hit a clean 2 MiB / 1 GiB leaf and the next
  // 4 KiB page is still inside it -- derive its PPN by incrementing the
  // VA-supplied index bits (no carry into the entry's bits by construction).
  logic super_end;
  logic super_next_ok;
  logic [19:0] super_next_ppn20;
  always_comb begin
    unique case (res0.level)
      2'd2: begin
        super_end = &pc_vpn[17:0];
        super_next_ppn20 = {res0.ppn20[19:18], pc_vpn[17:0] + 18'd1};
      end
      2'd1: begin
        super_end = &pc_vpn[8:0];
        super_next_ppn20 = {res0.ppn20[19:9], pc_vpn[8:0] + 9'd1};
      end
      default: begin
        super_end = 1'b1;
        super_next_ppn20 = res0.ppn20;
      end
    endcase
  end
  assign super_next_ok = res0.clean_hit && (res0.level != 2'd0) && !super_end;
  logic super_next_pma_bad;
  assign super_next_pma_bad = !riscv_pkg::pma_fetch_ok({32'b0, super_next_ppn20, 12'h000});

  // ---------------------------------------------------------------------------
  // Shadow next-state
  // ---------------------------------------------------------------------------
  logic [31:0] pa0_d, pa1_d;
  logic valid_d, f0_d, f0p_d, f1_d, f1p_d, after_ok_d;
  logic miss0_d, miss1_d;  // the walk the shadow is waiting for
  logic resolved1;
  always_comb begin
    // Defaults (every branch below overrides what it decides).
    pa0_d = i_pc[31:0];
    pa1_d = {i_pc[31:12], pc_plus4_lo, 2'b00};
    f0_d = 1'b0;
    f0p_d = 1'b0;
    f1_d = 1'b0;
    f1p_d = 1'b0;
    valid_d = 1'b1;
    after_ok_d = 1'b1;
    miss0_d = 1'b0;
    miss1_d = 1'b0;
    resolved1 = 1'b1;
    if (valid_q) begin
      // -----------------------------------------------------------------
      // LOAD: next_pc becomes pc. (When pc does not load the registers are
      // not enabled and this branch is don't-care.)
      // -----------------------------------------------------------------
      if (!i_active) begin
        // Bare / M-mode: the physical fetch of pre-M5, verdict included.
        pa0_d = {load_pa0_hi, i_next_pc[11:0]};
        f0_d = load_verdict.bare_fault0;
        f0p_d = 1'b0;
        pa1_d = {load_pa1_hi, load_plus4_lo, 2'b00};
        f1_d = load_verdict.bare_fault1;
        f1p_d = 1'b0;
        valid_d = 1'b1;
        after_ok_d = 1'b1;
      end else begin
        // A clean fetch inside pc's leaf, or defer to the held pc.
        pa0_d = {load_pa0_hi, i_next_pc[11:0]};
        pa1_d = {load_pa1_hi, load_plus4_lo, 2'b00};
        f0_d = 1'b0;
        f0p_d = 1'b0;
        f1_d = 1'b0;
        f1p_d = 1'b0;
        valid_d = load_clean;
        // Prefetching past the page needs a translation this window does
        // not carry -- unless the window itself straddles into that line.
        after_ok_d = load_verdict.line_after_in_page;
      end
    end else begin
      // -----------------------------------------------------------------
      // HELD: pc is the key (the front end is stalled on this shadow).
      // -----------------------------------------------------------------
      if (!i_active) begin
        pa0_d = i_pc[31:0];
        f0_d  = !riscv_pkg::pma_fetch_ok(i_pc);
        f0p_d = 1'b0;
        if (pc_page_cross) begin
          pa1_d = {pc_np_va[19:0], 12'h000};
          f1_d  = !riscv_pkg::pma_fetch_ok({pc_np_va, 12'h000});
        end else begin
          pa1_d = {i_pc[31:12], pc_plus4_lo, 2'b00};
          f1_d  = f0_d;
        end
        f1p_d = 1'b0;
        valid_d = 1'b1;
        after_ok_d = 1'b1;
      end else begin
        // Word 0.
        pa0_d = res0.fault ? i_pc[31:0] : {res0.ppn20, i_pc[11:0]};
        f0_d = res0.fault;
        f0p_d = res0.page;
        miss0_d = !res0.resolved;
        // Word 1.
        if (!pc_page_cross) begin
          pa1_d = {pa0_d[31:12], pc_plus4_lo, 2'b00};
          f1_d  = f0_d;
          f1p_d = f0p_d;
        end else if (super_next_ok) begin
          pa1_d = {super_next_ppn20, 12'h000};
          f1_d  = super_next_pma_bad;
          f1p_d = 1'b0;
        end else if (np_key_valid_q) begin
          // The registered next-page key describes pc's next page.
          pa1_d = res1.fault ? {np_va_q[19:0], 12'h000} : {res1.ppn20, 12'h000};
          f1_d = res1.fault;
          f1p_d = res1.page;
          resolved1 = res1.resolved;
          miss1_d = res0.resolved && !res1.resolved;
        end else begin
          // The next-page key does not describe this pc yet: word 1 is not
          // looked up this cycle.
          pa1_d = '0;
          f1_d = 1'b0;
          f1p_d = 1'b0;
          resolved1 = 1'b0;
        end
        valid_d = res0.resolved && resolved1;
        after_ok_d = (pa0_d[11:5] != 7'h7F) || (pa0_d[4:2] == 3'b111);
      end
      if (key_stale) begin
        valid_d = 1'b0;
        miss0_d = 1'b0;
        miss1_d = 1'b0;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Shadow registers: reload whenever pc loads -- except on the hold arm,
  // where next_pc is pc and the shadow already describes it (an invalidate
  // in that cycle still reloads, unresolved, so the shadow cannot outlive
  // the address space it was translated in) -- and every cycle while the
  // shadow is unresolved (the front end is stalled on it; the key is pc).
  // ---------------------------------------------------------------------------
  logic [31:0] pa0_q, pa1_q;
  logic f0_q, f0p_q, f1_q, f1p_q, after_ok_q;
  logic miss0_q, miss1_q;
  logic shadow_hold;
  logic shadow_en;
  assign shadow_hold = valid_q && i_next_pc_holds && !i_tlb_invalidate;
  assign shadow_en   = (i_pc_update_en && !shadow_hold) || !valid_q;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      valid_q <= 1'b1;
      f0_q <= 1'b0;
      f0p_q <= 1'b0;
      f1_q <= 1'b0;
      f1p_q <= 1'b0;
      after_ok_q <= 1'b1;
      miss0_q <= 1'b0;
      miss1_q <= 1'b0;
      pa0_q <= '0;
      pa1_q <= 32'd4;
    end else if (shadow_en) begin
      pa0_q <= pa0_d;
      pa1_q <= pa1_d;
      valid_q <= valid_d;
      f0_q <= f0_d;
      f0p_q <= f0p_d;
      f1_q <= f1_d;
      f1p_q <= f1p_d;
      after_ok_q <= after_ok_d;
      miss0_q <= miss0_d;
      miss1_q <= miss1_d;
    end
  end

  // The next-page key: pc's next page from the register, every cycle. It
  // describes the current pc once pc has held across an edge (a load of the
  // same value -- the hold arm -- counts as holding).
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      np_va_q <= '0;
      np_noncanon_q <= 1'b0;
      np_key_valid_q <= 1'b0;
    end else begin
      np_va_q <= pc_np_va;
      np_noncanon_q <= pc_np_noncanon;
      np_key_valid_q <= !(i_pc_update_en && !i_next_pc_holds);
    end
  end

  assign o_pa0 = pa0_q;
  assign o_pa1 = pa1_q;
  assign o_pa_valid = valid_q;
  assign o_fault0 = f0_q;
  assign o_fault0_page = f0p_q;
  assign o_fault1 = f1_q;
  assign o_fault1_page = f1p_q;
  assign o_line_after_ok = after_ok_q;

  // ---------------------------------------------------------------------------
  // Walk request: the held pc's missing page (word 0 first, then the next
  // page of a crossing window). Level until the walker accepts, asked once
  // per miss; a response (ours, by cpu_ooo's owner steering) or an
  // invalidate re-arms it.
  // ---------------------------------------------------------------------------
  logic asked_q;
  always_ff @(posedge i_clk) begin
    if (i_rst || i_tlb_invalidate) asked_q <= 1'b0;
    else if (i_walk_resp_valid) asked_q <= 1'b0;
    else if (o_walk_req_valid && i_walk_req_ready) asked_q <= 1'b1;
  end

  assign o_walk_req_valid = i_active && (miss0_q || miss1_q) && !asked_q && !i_tlb_invalidate;
  assign o_walk_vpn = miss0_q ? i_pc[38:12] : np_va_q[VpnBits-1:0];

`ifndef SYNTHESIS
`ifndef FORMAL
  // The shadow is o_pc's: a walk is only ever asked for the page o_pc is
  // held at (or its successor), and the registered next-page key tracks it.
  always_ff @(posedge i_clk) begin
    if (!i_rst && o_walk_req_valid && !$isunknown({i_pc, np_va_q})) begin
      if (miss0_q)
        assert (o_walk_vpn == i_pc[38:12]);
        else assert (np_va_q == (i_pc[XLEN-1:12] + 1'b1));
    end
  end

  // ---------------------------------------------------------------------------
  // Equivalence oracle for the restructure. A second ITLB, installed and
  // invalidated in lockstep, is looked up (a) on next_pc, (b) on pc, (c) on
  // the ORIGINAL design's registered next-page key -- kept here under the
  // original rule -- and (d) on pc's next page directly, and feeds that
  // design's complete resolver, verbatim. Every cycle:
  //   * a resolved LOAD is exactly what the reference resolves for next_pc
  //     (deferral -- unresolved where the reference resolved -- is the only
  //     permitted difference, and only on a load);
  //   * a resolved HELD cycle is exactly the reference's for pc, word-0
  //     walk arming included (the word-1 walk may arm a cycle later);
  //   * whenever the shadow is VALID it equals a fresh resolution of pc,
  //     word 1 through pc's next page, under the privilege and mode it was
  //     loaded with -- so a shadow that failed to reload, or an untouched
  //     hold-arm shadow, cannot describe anything but pc;
  //   * Bare never defers; the predecoded next-page PMA rewrite is exact.
  // Nothing of this is synthesized.
  // ---------------------------------------------------------------------------
  localparam int unsigned RefPorts = 4;
  logic [RefPorts-1:0][VpnBits-1:0] ref_vpn;
  logic [RefPorts-1:0] ref_hit;
  logic [RefPorts-1:0][19:0] ref_ppn20;
  logic [RefPorts-1:0] ref_hi_nonzero;
  logic [RefPorts-1:0] ref_r, ref_w, ref_x, ref_u, ref_d;
  logic [RefPorts-1:0][1:0] ref_level;
  logic [NpBits-1:0] ref_np_va_q;  // the original design's next-page key ...
  logic ref_np_noncanon_q;
  logic ref_np_key_valid_q;  // ... and its validity, under the original rule
  logic ref_priv_u_q, ref_active_q;  // the state the shadow was loaded under
  assign ref_vpn[0] = i_next_pc[38:12];
  assign ref_vpn[1] = pc_vpn;
  assign ref_vpn[2] = ref_np_va_q[VpnBits-1:0];
  assign ref_vpn[3] = pc_np_va[VpnBits-1:0];

  dtlb #(
      .NUM_ENTRIES(NUM_ENTRIES),
      .NUM_PORTS  (RefPorts)
  ) u_itlb_reference (
      .i_clk(i_clk),
      .i_rst_n(!i_rst),
      .i_invalidate_all(i_tlb_invalidate),
      .i_install_valid(tlb_install),
      .i_install(i_walk_resp),
      .i_lookup_vpn(ref_vpn),
      .o_hit(ref_hit),
      .o_ppn20(ref_ppn20),
      .o_ppn_hi_nonzero(ref_hi_nonzero),
      .o_perm_r(ref_r),
      .o_perm_w(ref_w),
      .o_perm_x(ref_x),
      .o_perm_u(ref_u),
      .o_perm_d(ref_d),
      .o_level(ref_level)
  );

  // The original design's next-page bookkeeping: loaded with the shadow
  // (its enable, i_pc_update_en || !valid_q) from the key it evaluated.
  logic [XLEN-1:0] ref_key;
  assign ref_key = valid_q ? i_next_pc : i_pc;
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      ref_np_va_q <= '0;
      ref_np_noncanon_q <= 1'b0;
      ref_np_key_valid_q <= 1'b0;
      ref_priv_u_q <= 1'b0;
      ref_active_q <= 1'b0;
    end else begin
      if (i_pc_update_en || !valid_q) begin
        ref_np_va_q <= ref_key[XLEN-1:12] + 1'b1;
        ref_np_noncanon_q <= !riscv_pkg::sv39_va_canonical({ref_key[XLEN-1:12] + 1'b1, 12'h000});
        ref_np_key_valid_q <= !key_stale;
      end
      if (shadow_en) begin
        ref_priv_u_q <= i_priv_u;
        ref_active_q <= i_active;
      end
    end
  end

  // The original resolver for a key on port p0, with word 1 through port
  // p1 keyed on np (which describes the key's next page iff np_ok), under
  // privilege priv_u and mode active.
  typedef struct packed {
    logic valid;
    logic [31:0] pa0;
    logic [31:0] pa1;
    logic f0, f0p, f1, f1p, after_ok, miss0, miss1;
  } ref_shadow_t;

  function automatic ref_shadow_t ref_resolve(
      input logic [XLEN-1:0] key, input logic [NpBits-1:0] np, input logic np_noncanon,
      input logic np_ok, input logic active, input logic priv_u, input int unsigned p0,
      input int unsigned p1);
    ref_shadow_t s;
    port_res_t r0, r1;
    logic page_cross, s_end, s_ok, resolved1;
    logic [19:0] s_ppn20;
    logic [NpBits-1:0] np_c;
    logic [9:0] plus4_lo;
    begin
      r0 = resolve_port(
          !riscv_pkg::sv39_va_canonical(
              key
          ),
          key[38:12],
          ref_hit[p0],
          ref_ppn20[p0],
          ref_hi_nonzero[p0],
          ref_x[p0],
          ref_u[p0],
          ref_level[p0],
          priv_u,
          i_tlb_invalidate,
          i_walk_resp_valid,
          i_walk_resp,
          memo_valid_q,
          memo_vpn_q,
          memo_page_q
      );
      r1 = resolve_port(
          np_noncanon,
          np[VpnBits-1:0],
          ref_hit[p1],
          ref_ppn20[p1],
          ref_hi_nonzero[p1],
          ref_x[p1],
          ref_u[p1],
          ref_level[p1],
          priv_u,
          i_tlb_invalidate,
          i_walk_resp_valid,
          i_walk_resp,
          memo_valid_q,
          memo_vpn_q,
          memo_page_q
      );
      page_cross = &key[11:2];
      np_c = key[XLEN-1:12] + 1'b1;
      plus4_lo = key[11:2] + 1'b1;
      unique case (r0.level)
        2'd2: begin
          s_end   = &key[29:12];
          s_ppn20 = {r0.ppn20[19:18], key[29:12] + 18'd1};
        end
        2'd1: begin
          s_end   = &key[20:12];
          s_ppn20 = {r0.ppn20[19:9], key[20:12] + 9'd1};
        end
        default: begin
          s_end   = 1'b1;
          s_ppn20 = r0.ppn20;
        end
      endcase
      s_ok = r0.clean_hit && (r0.level != 2'd0) && !s_end;
      s = '0;
      s.valid = 1'b1;
      s.after_ok = 1'b1;
      resolved1 = 1'b1;
      if (!active) begin
        s.pa0 = key[31:0];
        s.f0  = !riscv_pkg::pma_fetch_ok(key);
        if (page_cross) begin
          s.pa1 = {np_c[19:0], 12'h000};
          s.f1  = !riscv_pkg::pma_fetch_ok({np_c, 12'h000});
        end else begin
          s.pa1 = {key[31:12], plus4_lo, 2'b00};
          s.f1  = s.f0;
        end
      end else begin
        s.pa0 = r0.fault ? key[31:0] : {r0.ppn20, key[11:0]};
        s.f0 = r0.fault;
        s.f0p = r0.page;
        s.miss0 = !r0.resolved;
        if (!page_cross) begin
          s.pa1 = {s.pa0[31:12], plus4_lo, 2'b00};
          s.f1  = s.f0;
          s.f1p = s.f0p;
        end else if (s_ok) begin
          s.pa1 = {s_ppn20, 12'h000};
          s.f1  = !riscv_pkg::pma_fetch_ok({32'b0, s_ppn20, 12'h000});
        end else if (np_ok) begin
          s.pa1 = r1.fault ? {np[19:0], 12'h000} : {r1.ppn20, 12'h000};
          s.f1 = r1.fault;
          s.f1p = r1.page;
          resolved1 = r1.resolved;
          s.miss1 = r0.resolved && !r1.resolved;
        end else begin
          resolved1 = 1'b0;
        end
        s.valid = r0.resolved && resolved1;
        s.after_ok = (s.pa0[11:5] != 7'h7F) || (s.pa0[4:2] == 3'b111);
      end
      ref_resolve = s;
    end
  endfunction

  // (a) the original's resolution of next_pc on a load (its np rule: the
  //     registered key applies when next_pc holds), (b) of pc on a held
  //     cycle (registered key when valid), (c) of pc for the invariant
  //     (pc's next page directly, always applicable).
  ref_shadow_t ref_load, ref_held, ref_now;
  assign ref_load = ref_resolve(
      i_next_pc, ref_np_va_q, ref_np_noncanon_q, i_next_pc_holds, i_active, i_priv_u, 0, 2
  );
  assign ref_held = ref_resolve(
      i_pc, ref_np_va_q, ref_np_noncanon_q, ref_np_key_valid_q, i_active, i_priv_u, 1, 2
  );
  assign ref_now = ref_resolve(
      i_pc, pc_np_va, pc_np_noncanon, 1'b1, ref_active_q, ref_priv_u_q, 1, 3
  );

  function automatic logic shadow_d_matches(input ref_shadow_t s);
    shadow_d_matches = (pa0_d == s.pa0) && (pa1_d == s.pa1) && (f0_d == s.f0) &&
        (f0p_d == s.f0p) && (f1_d == s.f1) && (f1p_d == s.f1p) && (after_ok_d == s.after_ok);
  endfunction

  logic oracle_armed_q;
  always_ff @(posedge i_clk) begin
    if (i_rst) oracle_armed_q <= 1'b0;
    else oracle_armed_q <= 1'b1;
  end

  always_ff @(posedge i_clk) begin
    if (!i_rst && oracle_armed_q && !$isunknown(
            {i_active, i_priv_u, i_tlb_invalidate, i_pc_update_en, i_next_pc, i_next_pc_holds,
             i_pc, i_npc_sel, i_npc_seq, i_walk_resp_valid, valid_q}
        )) begin
      // The predecoded next-page PMA rewrite is exact.
      p_pma_next_page_rewrite_exact :
      assert (riscv_pkg::pma_fetch_next_page_ok(
          i_next_pc
      ) == riscv_pkg::pma_fetch_ok(
          {i_next_pc[XLEN-1:12] + 1'b1, 12'h000}
      ));

      if (shadow_en) begin
        if (valid_q) begin
          if (valid_d) begin
            p_load_resolved_matches_reference :
            assert (ref_load.valid && shadow_d_matches(ref_load))
            else
              $error(
                  "immu: load %h: dut/ref pa0=%h/%h pa1=%h/%h f=%b%b%b%b/%b%b%b%b rv=%b",
                  i_next_pc,
                  pa0_d,
                  ref_load.pa0,
                  pa1_d,
                  ref_load.pa1,
                  f0_d,
                  f0p_d,
                  f1_d,
                  f1p_d,
                  ref_load.f0,
                  ref_load.f0p,
                  ref_load.f1,
                  ref_load.f1p,
                  ref_load.valid
              );
          end
          p_bare_load_never_defers : assert (i_active || valid_d);
          p_load_walk_unarmed : assert (!miss0_d && !miss1_d);
        end else begin
          p_held_resolved_matches_reference :
          assert (!valid_d || (ref_held.valid && shadow_d_matches(ref_held)))
          else
            $error(
                "immu: held %h: dut/ref pa0=%h/%h pa1=%h/%h f=%b%b%b%b/%b%b%b%b rv=%b",
                i_pc,
                pa0_d,
                ref_held.pa0,
                pa1_d,
                ref_held.pa1,
                f0_d,
                f0p_d,
                f1_d,
                f1p_d,
                ref_held.f0,
                ref_held.f0p,
                ref_held.f1,
                ref_held.f1p,
                ref_held.valid
            );
          // (A pc load during the hold -- key_stale -- never walks the stale
          // key; the reference resolver has no such override.)
          p_held_word0_walk_matches_reference : assert (miss0_d == (ref_held.miss0 && !key_stale));
          p_held_word1_walk_not_early : assert (!miss1_d || ref_held.miss1);
        end
      end
      // A valid shadow is a fresh resolution of pc (under the state it was
      // loaded with; a TLB that has since lost the leaf cannot judge it).
      if (valid_q && ref_now.valid) begin
        p_valid_shadow_describes_pc :
        assert ((pa0_q == ref_now.pa0) && (pa1_q == ref_now.pa1) && (f0_q == ref_now.f0) &&
                (f0p_q == ref_now.f0p) && (f1_q == ref_now.f1) && (f1p_q == ref_now.f1p) &&
                (after_ok_q == ref_now.after_ok))
        else
          $error(
              "immu: valid shadow != pc %h: pa0=%h/%h pa1=%h/%h f=%b%b%b%b/%b%b%b%b ok=%b/%b",
              i_pc,
              pa0_q,
              ref_now.pa0,
              pa1_q,
              ref_now.pa1,
              f0_q,
              f0p_q,
              f1_q,
              f1p_q,
              ref_now.f0,
              ref_now.f0p,
              ref_now.f1,
              ref_now.f1p,
              after_ok_q,
              ref_now.after_ok
          );
      end
    end
  end
`endif
`endif

endmodule : immu
