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
 * immu: instruction-side Sv39 translation of the fetch PC.
 *
 * Translate pc_controller's registered fetch PC (i_pc), for timing.
 *
 * With translation off (Bare mode or M-mode), the outputs are a combinational,
 * cycle-exact function of i_pc and never bubble:
 *   pa0    = i_pc[31:0]
 *   pa1    = the aligned word after i_pc, with 32-bit wrap
 *   faults = the Bare PMA check of the full-XLEN PC
 *
 * Under Sv39 the registered page result is tagged with the virtual page and
 * privilege. Intra-page fetches use the live page offset without a bubble.
 * A window that crosses a 4 KiB page boundary also requires an exact PC tag.
 * A tag mismatch hides validity and faults until the result is captured; a
 * crossing can need another cycle for its registered next-page key. A miss
 * keeps its tag and stalls IF until the shared walker answers.
 *
 * An accepted walk records the key it was issued for. Retargets, privilege
 * changes, and mode changes do not cancel it: a late response still fills the
 * ITLB or the fault memo, but it bypasses into the live result only while its
 * saved key matches the live tag. An invalidate clears the ITLB, the memo, the
 * tag, and the outstanding walk, and ignores a response in the same cycle. A
 * full pipeline flush clears the memo and registered verdicts. Refusals also
 * expire periodically, including on wrong paths that never trap (Svvptc).
 */
module immu #(
    parameter int unsigned XLEN = riscv_pkg::XLEN,
    parameter int unsigned NUM_ENTRIES = 16,
    parameter int unsigned PA_VALID_COPIES = 1
) (
    input logic i_clk,
    input logic i_rst,

    // satp.MODE == Sv39 && priv != M, and the live fetch privilege.
    input logic i_active,
    input logic i_priv_u,

    // Invalidate on SFENCE.VMA, any satp access, or an mstatus write that
    // changes MPRV (or MPP under MPRV).
    input logic i_tlb_invalidate,

    // Registered full pipeline flush (trap, xRET, or FENCE-class). It clears
    // the fault memo, so a fault from an invalid PTE never outlives the trap
    // it raises (Svvptc).
    input logic i_full_flush = 1'b0,

    // pc_controller's registered fetch PC. The page and privilege tag hides
    // unrelated translations; crossing windows require the exact PC tag.
    // The Bare outputs are formed directly from this input.
    input logic [XLEN-1:0] i_pc,

    output logic [riscv_pkg::PhysAddrBits-1:0] o_pa0,
    output logic [riscv_pkg::PhysAddrBits-1:0] o_pa1,
    output logic o_pa_valid,
    // Copies of o_pa_valid for fanout to decoded-queue shadow selects.
    output logic [PA_VALID_COPIES-1:0] o_pa_valid_copy,
    output logic o_fault0,
    output logic o_fault0_page,
    output logic o_fault1,
    output logic o_fault1_page,
    output logic o_line_after_ok,

    // Shared page-table walker port; cpu_ooo arbitrates it with the data side.
    output logic o_walk_req_valid,
    input logic i_walk_req_ready,
    output logic [riscv_pkg::Sv39VpnBits-1:0] o_walk_vpn,
    input logic i_walk_resp_valid,
    input riscv_pkg::ptw_resp_t i_walk_resp
);

`ifndef SYNTHESIS
  logic reset_seen_q = 1'b0;
  always_ff @(posedge i_clk) if (i_rst) reset_seen_q <= 1'b1;
`endif

  localparam int unsigned VpnBits = riscv_pkg::Sv39VpnBits;
  localparam int unsigned PpnBits = riscv_pkg::PhysAddrBits - 12;
  localparam int unsigned NpBits = XLEN - riscv_pkg::Sv39PageOffsetBits;
  localparam int unsigned FaultCacheEpochBits = 6;

  // A free-running epoch bounds negative caching independently of traps,
  // branch recovery, new fills, or the software's instruction stream. The
  // memo and completed registered refusals expire within 64 clocks. A refusal
  // copied from the memo on its expiry edge can remain for one further
  // epoch, so negative caching adds at most 128 clocks to visibility.
  logic [FaultCacheEpochBits-1:0] fault_cache_epoch_q;
  logic fault_cache_expire;
  assign fault_cache_expire = &fault_cache_epoch_q;
  always_ff @(posedge i_clk) begin
    if (i_rst) fault_cache_epoch_q <= '0;
    else fault_cache_epoch_q <= fault_cache_epoch_q + 1'b1;
  end

  // ---------------------------------------------------------------------------
  // Bare bypass (translation off).
  // ---------------------------------------------------------------------------
  riscv_pkg::fetch_verdict_t bare_verdict;
  logic [riscv_pkg::PhysAddrBits-1:0] bare_pc;
  logic [riscv_pkg::PhysAddrBits-1:0] bare_pc_aligned;
  logic [riscv_pkg::PhysAddrBits-1:0] bare_pa1;
  assign bare_verdict = riscv_pkg::fetch_verdict(i_pc);
  assign bare_pc = riscv_pkg::PhysAddrBits'(i_pc);
  assign bare_pc_aligned = {bare_pc[riscv_pkg::PhysAddrBits-1:2], 2'b00};
  assign bare_pa1 = bare_pc_aligned + riscv_pkg::PhysAddrBits'(4);

`ifndef SYNTHESIS
  // Sample the settled bypass at its consuming edge; continuous struct-field
  // assignments may pass through intermediate values during a PC update.
  always_ff @(posedge i_clk) begin
    if (!$isunknown(i_pc)) begin
      p_bare_verdict_matches_package : assert (bare_verdict == riscv_pkg::fetch_verdict(i_pc));
    end
  end
`endif

  // ---------------------------------------------------------------------------
  // Tag of the registered result: the {PC, privilege} it was computed for.
  // ---------------------------------------------------------------------------
  logic key_valid_q;
  logic [XLEN-1:0] key_va_q;
  // The key's page crossing, &key_va_q[11:2], loaded with the key.
  logic key_cross_q;
  logic key_priv_u_q;
  logic resolved_q;
  logic tag_match;
  logic translated_visible;
  logic capture_en;

  // The live-PC match: the page compare, and for a crossing window an exact
  // key. A crossing PC's bits 11:2 are all ones, so the key matches them
  // exactly when the key itself crosses (key_cross_q), leaving bits 1:0 to
  // compare. The terms are kept apart so that each output that takes the
  // match meets them in its last gate. A full match implies the same page,
  // so this equals same_page && (!pc_page_cross || key_va_q == i_pc).
  logic pc_page_cross;
  (* keep = "true" *) logic same_page;
  (* keep = "true" *) logic pc_cross_key_ok;
  logic pc_low_ok, pc_match;
  assign same_page = (key_va_q[XLEN-1:12] == i_pc[XLEN-1:12]);
  assign pc_cross_key_ok = key_cross_q && (key_va_q[1:0] == i_pc[1:0]);
  assign pc_low_ok = !pc_page_cross || pc_cross_key_ok;
  assign pc_match = same_page && pc_low_ok;

  assign tag_match = key_valid_q && (key_priv_u_q == i_priv_u) && pc_match;
  assign translated_visible = i_active && !i_tlb_invalidate && tag_match && resolved_q;
  assign capture_en = i_active && !i_tlb_invalidate && (!tag_match || !resolved_q);

  logic [VpnBits-1:0] pc_vpn;
  logic pc_noncanon;
  logic [NpBits-1:0] pc_np_va;
  logic [9:0] pc_plus4_lo;
  // Preserve unknown Sv39 bits above XLEN in the narrow Bare-only proof,
  // while selecting the same VPN bits for ordinary Sv39 configurations.
  assign pc_vpn = VpnBits'({{VpnBits{1'bx}}, i_pc} >> 12);
  assign pc_noncanon = !riscv_pkg::sv39_va_canonical(i_pc);
  assign pc_page_cross = &i_pc[11:2];
  assign pc_np_va = i_pc[XLEN-1:12] + 1'b1;
  assign pc_plus4_lo = i_pc[11:2] + 1'b1;

  // Register the next-page VA for timing. np_sample_matches must confirm it
  // belongs to the live PC before use.
  logic [NpBits-1:0] np_va_q;
  logic np_sample_matches;
  logic np_noncanon;
  assign np_sample_matches = key_valid_q && (key_va_q == i_pc) && (np_va_q == pc_np_va);
  assign np_noncanon = !riscv_pkg::sv39_va_canonical({np_va_q, 12'h000});

  // ---------------------------------------------------------------------------
  // Outstanding walk. Install and memo updates require walk_resp_matches.
  // ---------------------------------------------------------------------------
  logic walk_outstanding_q;
  logic [VpnBits-1:0] walk_vpn_q;
  logic [XLEN-1:0] walk_key_va_q;
  logic walk_key_priv_u_q;
  logic walk_recheck_q;
  logic walk_resp_arrived;
  logic walk_resp_matches;
  logic resp_for_live_key;

  assign walk_resp_arrived = i_walk_resp_valid && walk_outstanding_q;
  assign walk_resp_matches = walk_resp_arrived && (i_walk_resp.vpn == walk_vpn_q);
  assign resp_for_live_key = walk_resp_matches && i_active && !i_tlb_invalidate && tag_match &&
      (walk_key_va_q == key_va_q) && (walk_key_priv_u_q == key_priv_u_q);

  // ---------------------------------------------------------------------------
  // Two-port ITLB: current PC and the registered next-page sample.
  // ---------------------------------------------------------------------------
  logic [1:0][VpnBits-1:0] tlb_vpn;
  logic [1:0] tlb_hit;
  logic [1:0][PpnBits-1:0] tlb_ppn;
  logic [1:0] tlb_hi_nonzero;
  logic [1:0] tlb_r, tlb_w, tlb_x, tlb_u, tlb_d;
  logic [1:0][1:0] tlb_level;
  // ITLB permission and PMA checks are computed per entry, for timing.
  logic [1:0] tlb_fetch_perm_fault, tlb_fetch_pma_bad, tlb_fetch_next_pma_bad;
  logic [1:0] tlb_fetch_next_ok;
  logic [1:0][PpnBits-1:0] tlb_fetch_next_ppn;
  // The hit's stored PPN bits and superpage size, for the word-1 page that
  // joins its VA bits after the capture.
  logic [1:0][PpnBits-1:0] tlb_ppn_own;
  logic [1:0] tlb_giga, tlb_mega;
  logic tlb_install;

  assign tlb_vpn[0] = pc_vpn;
  assign tlb_vpn[1] = VpnBits'({{VpnBits{1'bx}}, np_va_q});
  assign tlb_install = walk_resp_matches &&
      (i_walk_resp.fault_kind == riscv_pkg::DFAULT_NONE) && !i_tlb_invalidate;

  dtlb #(
      .NUM_ENTRIES    (NUM_ENTRIES),
      .NUM_PORTS      (2),
      .FETCH_VERDICTS (1'b1),
      .DATA_VERDICTS  (1'b0),
      .PPN_SELECT_TREE(1'b1)
  ) u_itlb (
      .i_clk(i_clk),
      .i_rst_n(!i_rst),
      .i_invalidate_all(i_tlb_invalidate),
      .i_install_valid(tlb_install),
      .i_install(i_walk_resp),
      .i_lookup_vpn(tlb_vpn),
      .o_hit(tlb_hit),
      .o_ppn(tlb_ppn),
      .o_ppn_hi_nonzero(tlb_hi_nonzero),
      .o_perm_r(tlb_r),
      .o_perm_w(tlb_w),
      .o_perm_x(tlb_x),
      .o_perm_u(tlb_u),
      .o_perm_d(tlb_d),
      .o_level(tlb_level),
      .o_device_page(),  // fetch never reaches a device window
      // The data MMU's leaf checks; fetch uses its own.
      .i_perm_store('0),
      .i_perm_priv_u(1'b0),
      .i_perm_sum(1'b0),
      .i_perm_mxr(1'b0),
      .i_perm_atomic('0),
      .o_perm_ok(),
      .o_atomic_page(),
      .o_clean_hit(),
      .i_fetch_priv_u(i_priv_u),
      .o_fetch_perm_fault(tlb_fetch_perm_fault),
      .o_fetch_pma_bad(tlb_fetch_pma_bad),
      .o_fetch_next_pma_bad(tlb_fetch_next_pma_bad),
      .o_fetch_next_ok(tlb_fetch_next_ok),
      .o_fetch_next_ppn(tlb_fetch_next_ppn),
      .o_ppn_own(tlb_ppn_own),
      .o_giga(tlb_giga),
      .o_mega(tlb_mega)
  );

  // ---------------------------------------------------------------------------
  // One-entry memo of the last faulting walk (resp_refused). A walk fault
  // depends on the page tables, not on privilege, so the memo carries no
  // privilege tag. It holds a fault only until the next epoch expiry,
  // invalidate or full pipeline flush (Svvptc). Expiry also bounds the
  // lifetime of a wrong-path refusal that never causes a trap. A fetch that
  // uses the memo on the correct path traps, and that trap clears it, so a
  // memo entry raises at most one fault,
  // and the refetch after the handler walks again. A walk accepted before a
  // flush may read a PTE older than the stores the flush ordered, so its
  // fault does not fill the memo either. The xRET that returns from a
  // handler waits for committed stores to drain, so a walk accepted after
  // it observes the handler's PTE stores.
  // ---------------------------------------------------------------------------
  logic memo_valid_q;
  logic [VpnBits-1:0] memo_vpn_q;
  logic memo_page_q;
  logic resp_refused;
  logic walk_memo_ok_q;  // the walk in flight was accepted after the last full flush
  assign resp_refused = walk_resp_matches && walk_memo_ok_q &&
      (i_walk_resp.fault_kind != riscv_pkg::DFAULT_NONE) && !i_tlb_invalidate;

  always_ff @(posedge i_clk) begin
    if (i_rst || i_full_flush) walk_memo_ok_q <= 1'b0;
    else if (o_walk_req_valid && i_walk_req_ready) walk_memo_ok_q <= 1'b1;
  end

  always_ff @(posedge i_clk) begin
    if (i_rst || i_tlb_invalidate || i_full_flush || fault_cache_expire) begin
      memo_valid_q <= 1'b0;
    end else if (resp_refused) begin
      memo_valid_q <= 1'b1;
      memo_vpn_q   <= i_walk_resp.vpn;
      memo_page_q  <= (i_walk_resp.fault_kind == riscv_pkg::DFAULT_PAGE);
    end
  end

  // ---------------------------------------------------------------------------
  // Resolve one translated page. The walk response bypasses into the result
  // only when the walk's saved key matches the live tag (resp_for_live_key). A
  // stale response still fills the ITLB or memo for the recheck cycle to pick
  // up, but it cannot make another key's payload visible.
  // ---------------------------------------------------------------------------
  function automatic logic [PpnBits-1:0] ppn_from_resp(input riscv_pkg::ptw_resp_t resp,
                                                       input logic [VpnBits-1:0] vpn);
    unique case (resp.level)
      2'd2: ppn_from_resp = {resp.ppn[PpnBits-1:18], vpn[17:0]};
      2'd1: ppn_from_resp = {resp.ppn[PpnBits-1:9], vpn[8:0]};
      default: ppn_from_resp = resp.ppn[PpnBits-1:0];
    endcase
  endfunction
  // A response's stored PPN bits, zero where a superpage takes VA bits.
  function automatic logic [PpnBits-1:0] own_from_resp(input riscv_pkg::ptw_resp_t resp);
    unique case (resp.level)
      2'd2: own_from_resp = {resp.ppn[PpnBits-1:18], 18'd0};
      2'd1: own_from_resp = {resp.ppn[PpnBits-1:9], 9'd0};
      default: own_from_resp = resp.ppn[PpnBits-1:0];
    endcase
  endfunction

  typedef struct packed {
    logic resolved;
    logic fault;
    logic page;
    logic [PpnBits-1:0] ppn;
    // ppn in parts: the stored bits and the superpage size whose VA bits it
    // joins (the dtlb's o_ppn_own, o_giga and o_mega, or the response's).
    logic [PpnBits-1:0] own;
    logic giga;
    logic mega;
    logic hi_nonzero;
    logic [1:0] level;
    logic clean_hit;
  } port_res_t;

  // Hits use ITLB permission and PMA checks; walk responses are checked here.
  function automatic port_res_t resolve_port(
      input logic noncanon, input logic [VpnBits-1:0] vpn, input logic hit,
      input logic [PpnBits-1:0] ppn, input logic [PpnBits-1:0] ppn_own, input logic giga,
      input logic mega, input logic hi_nonzero, input logic tlb_perm_fault, input logic tlb_pma_bad,
      input logic [1:0] level, input logic priv_u, input logic invalidate, input logic resp_valid,
      input riscv_pkg::ptw_resp_t resp, input logic memo_valid, input logic [VpnBits-1:0] memo_vpn,
      input logic memo_page);
    port_res_t r;
    logic resp_match, use_resp_leaf, have;
    logic e_hi_nonzero;
    logic [PpnBits-1:0] e_ppn;
    logic [1:0] e_level;
    logic perm_ok, pma_bad;
    begin
      r = '0;
      resp_match = resp_valid && !invalidate && (resp.vpn == vpn);
      use_resp_leaf = resp_match && (resp.fault_kind == riscv_pkg::DFAULT_NONE);
      have = (hit && !invalidate) || use_resp_leaf;
      if (use_resp_leaf && !(hit && !invalidate)) begin
        e_hi_nonzero = |resp.ppn[riscv_pkg::PtePpnBits-1:PpnBits];
        e_ppn = ppn_from_resp(resp, vpn);
        e_level = resp.level;
        perm_ok = resp.perm_x && (resp.perm_u == priv_u);
        pma_bad = e_hi_nonzero || !riscv_pkg::pma_fetch_ok(riscv_pkg::XLEN'({e_ppn, 12'h000}));
        r.own = own_from_resp(resp);
        r.giga = resp.level == 2'd2;
        r.mega = resp.level == 2'd1;
      end else begin
        e_hi_nonzero = hi_nonzero;
        e_ppn = ppn;
        e_level = level;
        perm_ok = !tlb_perm_fault;
        pma_bad = tlb_pma_bad;
        r.own = ppn_own;
        r.giga = giga;
        r.mega = mega;
      end
      r.ppn = e_ppn;
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

  port_res_t res0, res1;
  assign res0 = resolve_port(
      pc_noncanon,
      pc_vpn,
      tlb_hit[0],
      tlb_ppn[0],
      tlb_ppn_own[0],
      tlb_giga[0],
      tlb_mega[0],
      tlb_hi_nonzero[0],
      tlb_fetch_perm_fault[0],
      tlb_fetch_pma_bad[0],
      tlb_level[0],
      i_priv_u,
      i_tlb_invalidate,
      resp_for_live_key,
      i_walk_resp,
      memo_valid_q,
      memo_vpn_q,
      memo_page_q
  );
  assign res1 = resolve_port(
      np_noncanon,
      VpnBits'({
        {VpnBits{1'bx}}, np_va_q
      }),
      tlb_hit[1],
      tlb_ppn[1],
      tlb_ppn_own[1],
      tlb_giga[1],
      tlb_mega[1],
      tlb_hi_nonzero[1],
      tlb_fetch_perm_fault[1],
      tlb_fetch_pma_bad[1],
      tlb_level[1],
      i_priv_u,
      i_tlb_invalidate,
      resp_for_live_key,
      i_walk_resp,
      memo_valid_q,
      memo_vpn_q,
      memo_page_q
  );

`ifndef SYNTHESIS
  // Per-entry checks must equal checks of the selected hit's fields.
  always_comb begin
    for (int p = 0; p < 2; p++) begin
      if (tlb_hit[p] && !$isunknown(
              {tlb_x[p], tlb_u[p], tlb_hi_nonzero[p], tlb_ppn[p], i_priv_u,
               tlb_fetch_perm_fault[p], tlb_fetch_pma_bad[p]}
          )) begin
        p_itlb_fetch_verdicts_exact :
        assert (tlb_fetch_perm_fault[p] == !(tlb_x[p] && (tlb_u[p] == i_priv_u)) &&
                tlb_fetch_pma_bad[p] ==
                (tlb_hi_nonzero[p] || !riscv_pkg::pma_fetch_ok(
            riscv_pkg::XLEN'({tlb_ppn[p], 12'h000})
        )));
      end
    end
  end
`endif

  // ITLB entries resolve superpage successors before winner selection.
  // Walk responses form a separate candidate; an ITLB hit has priority.
  // At the superpage end, port 1 resolves the successor VPN.
  logic resp_super_end;
  logic resp_super_ok;
  logic [PpnBits-1:0] resp_ppn, resp_super_ppn;
  logic super_next_ok;
  logic [PpnBits-1:0] super_next_ppn;
  logic super_next_pma_bad;
  logic resp_super_pma_bad;
  logic res0_from_tlb;
  assign res0_from_tlb = tlb_hit[0] && !i_tlb_invalidate;
  assign resp_ppn = ppn_from_resp(i_walk_resp, pc_vpn);
  always_comb begin
    unique case (i_walk_resp.level)
      2'd2: begin
        resp_super_end = &pc_vpn[17:0];
        resp_super_ppn = {resp_ppn[PpnBits-1:18], pc_vpn[17:0] + 18'd1};
      end
      2'd1: begin
        resp_super_end = &pc_vpn[8:0];
        resp_super_ppn = {resp_ppn[PpnBits-1:9], pc_vpn[8:0] + 9'd1};
      end
      default: begin
        resp_super_end = 1'b1;
        resp_super_ppn = resp_ppn;
      end
    endcase
  end
  assign resp_super_ok = resp_for_live_key && (i_walk_resp.vpn == pc_vpn) &&
      (i_walk_resp.fault_kind == riscv_pkg::DFAULT_NONE) && i_walk_resp.perm_x &&
      (i_walk_resp.perm_u == i_priv_u) && !(|i_walk_resp.ppn[riscv_pkg::PtePpnBits-1:PpnBits]) &&
      riscv_pkg::pma_fetch_ok(
      riscv_pkg::XLEN'({resp_ppn, 12'h000})
  ) && !resp_super_end;
  assign super_next_ok = !pc_noncanon && !i_tlb_invalidate &&
      (tlb_fetch_next_ok[0] || (!tlb_hit[0] && resp_super_ok));
  assign super_next_ppn = res0_from_tlb ? tlb_fetch_next_ppn[0] : resp_super_ppn;
  // super_next_ppn in parts for word 1's capture: the stored bits and the
  // superpage size whose low VA bits the next VPN supplies.
  logic [PpnBits-1:0] super_next_own;
  logic super_next_giga, super_next_mega;
  assign super_next_own = res0_from_tlb ? tlb_ppn_own[0] : own_from_resp(i_walk_resp);
  assign super_next_giga = res0_from_tlb ? tlb_giga[0] : (i_walk_resp.level == 2'd2);
  assign super_next_mega = res0_from_tlb ? tlb_mega[0] : (i_walk_resp.level == 2'd1);
  assign resp_super_pma_bad = !riscv_pkg::pma_fetch_ok(riscv_pkg::XLEN'({resp_super_ppn, 12'h000}));
  assign super_next_pma_bad = res0_from_tlb ? tlb_fetch_next_pma_bad[0] : resp_super_pma_bad;
`ifndef SYNTHESIS
  `define IMMU_CHECK_SUCCESSOR
`elsif IMMU_SUCCESSOR_LOCAL_PROOF
  `define IMMU_CHECK_SUCCESSOR
`endif
`ifdef IMMU_CHECK_SUCCESSOR
  logic ref_super_end;
  logic [PpnBits-1:0] ref_super_ppn;
  always_comb begin
    case (res0.level)
      2'd2: begin
        ref_super_end = &pc_vpn[17:0];
        ref_super_ppn = {res0.ppn[PpnBits-1:18], pc_vpn[17:0] + 18'd1};
      end
      2'd1: begin
        ref_super_end = &pc_vpn[8:0];
        ref_super_ppn = {res0.ppn[PpnBits-1:9], pc_vpn[8:0] + 9'd1};
      end
      default: begin
        ref_super_end = 1'b1;
        ref_super_ppn = res0.ppn;
      end
    endcase
  end
  always_comb begin
    if (!$isunknown({super_next_ok, res0.clean_hit, ref_super_end})) begin
      p_super_next_eligibility_exact : assert (super_next_ok == (res0.clean_hit && !ref_super_end));
    end
    if (super_next_ok && !$isunknown({super_next_pma_bad, super_next_ppn})) begin
      p_super_next_ppn_exact : assert (super_next_ppn == ref_super_ppn);
      p_super_next_pma_exact :
      assert (super_next_pma_bad == !riscv_pkg::pma_fetch_ok(
          riscv_pkg::XLEN'({super_next_ppn, 12'h000})
      ));
    end
  end
`endif
  `undef IMMU_CHECK_SUCCESSOR

  // ---------------------------------------------------------------------------
  // Tag and result capture. The key and its result always load together.
  // ---------------------------------------------------------------------------
  logic [riscv_pkg::PhysAddrBits-1:0] pa0_d;
  logic [PpnBits-1:0] pa1_own_d;
  logic pa1_giga_d, pa1_mega_d;
  logic resolved_d, f0_d, f0p_d, f1_d, f1p_d, after_ok_d;
  logic miss0_d, miss1_d;
  logic resolved1;
  logic pa1_use_va_d;

  always_comb begin
    pa0_d = res0.fault ? bare_pc : {res0.ppn, i_pc[11:0]};
    // Word 1's page for a crossing window, in parts: the read side joins
    // np_va_q's low bits for a superpage, after the capture. A key that stays
    // in its page reads pa0_q instead, so these need no page-cross select.
    pa1_own_d = super_next_ok ? super_next_own : (np_sample_matches ? res1.own : '0);
    pa1_giga_d = super_next_ok ? super_next_giga : (np_sample_matches && res1.giga);
    pa1_mega_d = super_next_ok ? super_next_mega : (np_sample_matches && res1.mega);
    f0_d = res0.fault;
    f0p_d = res0.page;
    f1_d = res0.fault;
    f1p_d = res0.page;
    after_ok_d = 1'b1;
    miss0_d = !res0.resolved;
    miss1_d = 1'b0;
    resolved1 = 1'b1;
    pa1_use_va_d = 1'b0;

    if (pc_page_cross) begin
      if (super_next_ok) begin
        f1_d  = super_next_pma_bad;
        f1p_d = 1'b0;
      end else if (np_sample_matches && res1.resolved) begin
        pa1_use_va_d = res1.fault;
        f1_d = res1.fault;
        f1p_d = res1.page;
      end else begin
        // A first-word fault determines the architectural outcome even
        // while the neighbor is missing. Use a fault-marked VA placeholder
        // for that neighbor, so no unvalidated physical read is authorized.
        // Select the fallback directly, before the late first-word verdict.
        f1_d = res0.fault;
        f1p_d = res0.page;
        pa1_use_va_d = res0.fault;
        resolved1 = res0.fault;
        miss1_d = np_sample_matches && res0.resolved && !res0.fault;
      end
    end
    resolved_d = res0.resolved && resolved1;
    after_ok_d = (pa0_d[11:5] != 7'h7F) || (pa0_d[4:2] == 3'b111);
  end

  logic [riscv_pkg::PhysAddrBits-1:0] pa0_q;
  logic [PpnBits-1:0] pa1_own_q;
  logic pa1_giga_q, pa1_mega_q;
  logic f0_q, f0p_q, f1_q, f1p_q, after_ok_q;
  logic miss0_q, miss1_q;
  // A next-page lookup fault uses its sampled VA. The address selector
  // captures with word 1's page and holds with it when visibility is
  // invalidated.
  logic pa1_use_va_q;
  // Word 1's page. A crossing key's page joins np_va_q's low 18 bits for a
  // gigapage and its low 9 for a megapage (np_va_q loads with the key, and
  // np_sample_matches leaves it unchanged); any other key's word 1 lies in
  // pa0_q's page, chosen by key_cross_q.
  logic [PpnBits-1:0] pa1_join, pa1_ppn;
  always_comb begin
    pa1_join = pa1_own_q;
    if (pa1_giga_q) pa1_join[17:0] = pa1_join[17:0] | np_va_q[17:0];
    if (pa1_mega_q) pa1_join[8:0] = pa1_join[8:0] | np_va_q[8:0];
  end
  assign pa1_ppn = !key_cross_q ? pa0_q[riscv_pkg::PhysAddrBits-1:12] :
      pa1_use_va_q ? np_va_q[PpnBits-1:0] : pa1_join;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      key_valid_q <= 1'b0;
      key_va_q <= '0;
      key_cross_q <= 1'b0;
      key_priv_u_q <= 1'b0;
      np_va_q <= '0;
      resolved_q <= 1'b0;
      miss0_q <= 1'b0;
      miss1_q <= 1'b0;
      pa0_q <= '0;
      pa1_own_q <= '0;
      pa1_giga_q <= 1'b0;
      pa1_mega_q <= 1'b0;
      pa1_use_va_q <= 1'b0;
      f0_q <= 1'b0;
      f0p_q <= 1'b0;
      f1_q <= 1'b0;
      f1p_q <= 1'b0;
      after_ok_q <= 1'b0;
    end else if (!i_active || i_tlb_invalidate) begin
      key_valid_q <= 1'b0;
      resolved_q <= 1'b0;
      miss0_q <= 1'b0;
      miss1_q <= 1'b0;
      f0_q <= 1'b0;
      f0p_q <= 1'b0;
      f1_q <= 1'b0;
      f1p_q <= 1'b0;
      after_ok_q <= 1'b0;
    end else if (capture_en) begin
      key_valid_q <= 1'b1;
      key_va_q <= i_pc;
      key_cross_q <= pc_page_cross;
      key_priv_u_q <= i_priv_u;
      np_va_q <= pc_np_va;
      resolved_q <= resolved_d;
      miss0_q <= miss0_d;
      miss1_q <= miss1_d;
      pa0_q <= pa0_d;
      pa1_own_q <= pa1_own_d;
      pa1_giga_q <= pa1_giga_d;
      pa1_mega_q <= pa1_mega_d;
      pa1_use_va_q <= pa1_use_va_d;
      f0_q <= f0_d;
      f0p_q <= f0p_d;
      f1_q <= f1_d;
      f1p_q <= f1p_d;
      after_ok_q <= after_ok_d;
    end
    // A full flush drops verdicts even when a refusal arrives on this edge.
    // Epoch expiry drops a completed refusal without disturbing held clean hits.
    // Partial fault bits do not expire: they are not visible, and clearing
    // them could discard each first-page response aligned with an expiry.
    // If a clean retarget is captured as an old refusal expires, clear wins
    // and that capture retries on the next clock.
    // Only validity and fault bits change, keeping both terms off the
    // address-capture path. Bare fetches continue to use the direct bypass.
    if (!i_rst && (i_full_flush || (fault_cache_expire && resolved_q && (f0_q || f1_q)))) begin
      resolved_q <= 1'b0;
      miss0_q <= 1'b0;
      miss1_q <= 1'b0;
      f0_q <= 1'b0;
      f0p_q <= 1'b0;
      f1_q <= 1'b0;
      f1p_q <= 1'b0;
    end
  end

  // ---------------------------------------------------------------------------
  // Walk request and outstanding-walk tracking.
  // ---------------------------------------------------------------------------
  logic walk_needed;
  assign walk_needed = tag_match && !resolved_q && (miss0_q || miss1_q);
  assign o_walk_req_valid = i_active && !i_tlb_invalidate && walk_needed &&
                            !walk_outstanding_q && !walk_recheck_q;
  assign o_walk_vpn = miss0_q ?
      VpnBits'({{VpnBits{1'bx}}, key_va_q} >> 12) :
      VpnBits'({{VpnBits{1'bx}}, np_va_q});

  always_ff @(posedge i_clk) begin
    if (i_rst || i_tlb_invalidate) begin
      walk_outstanding_q <= 1'b0;
      walk_vpn_q <= '0;
      walk_key_va_q <= '0;
      walk_key_priv_u_q <= 1'b0;
      walk_recheck_q <= 1'b0;
    end else begin
      // Wait one cycle after a walk response before requesting again. A stale
      // response needs its ITLB or fault-memo write visible to the resolver;
      // a live-key response can bypass directly.
      walk_recheck_q <= walk_resp_arrived;
      if (walk_resp_arrived) begin
        walk_outstanding_q <= 1'b0;
      end else if (o_walk_req_valid && i_walk_req_ready) begin
        walk_outstanding_q <= 1'b1;
        walk_vpn_q <= o_walk_vpn;
        walk_key_va_q <= key_va_q;
        walk_key_priv_u_q <= key_priv_u_q;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Outputs. While a translated result is invisible, the PA bits may be stale
  // and o_pa_valid and every fault bit are low, so no consumer can act on a
  // result for the wrong tag.
  // ---------------------------------------------------------------------------
  // Translation preserves the page offset and visible tags match i_pc, so
  // both modes can use the live PC's offset.
  assign o_pa0 = {
    i_active ? pa0_q[riscv_pkg::PhysAddrBits-1:12] : bare_pc[riscv_pkg::PhysAddrBits-1:12],
    i_pc[11:0]
  };
  assign o_pa1 = {
    i_active ? (pc_page_cross ? pa1_ppn :
                               pa0_q[riscv_pkg::PhysAddrBits-1:12]) :
               bare_pa1[riscv_pkg::PhysAddrBits-1:12],
    pc_plus4_lo,
    2'b00
  };
  // Apply the live-PC compare last, for timing.
  (* keep = "true" *) logic visible_before_pc_compare;
  assign visible_before_pc_compare = !i_tlb_invalidate && key_valid_q &&
                                     (key_priv_u_q == i_priv_u) && resolved_q;
  assign o_pa_valid = !i_active || (visible_before_pc_compare && pc_match);
  for (genvar copy = 0; copy < PA_VALID_COPIES; copy++) begin : gen_pa_valid_copy
    (* keep = "true", dont_touch = "true" *) logic pa_valid_copy;
`ifdef FROST_XILINX_PRIMS
    // One LUT after the page compare and the crossing test:
    // !I0 || (I1 && I2 && (!I3 || I4)).
    (* dont_touch = "true" *)
    LUT5 #(
        .INIT(32'hD5D555D5)
    ) u_pa_valid (
        .I0(i_active),
        .I1(visible_before_pc_compare),
        .I2(same_page),
        .I3(pc_page_cross),
        .I4(pc_cross_key_ok),
        .O (pa_valid_copy)
    );
`else
    assign pa_valid_copy = !i_active || (visible_before_pc_compare && pc_match);
`endif
    assign o_pa_valid_copy[copy] = pa_valid_copy;
  end
  wire  live_after_ok = (i_pc[11:5] != 7'h7F) || (i_pc[4:2] == 3'b111);
  // The fetch PC's fault reaches the branch predictor's disable, so it too
  // takes the live-PC compare last: translated_visible is i_active,
  // visible_before_pc_compare and pc_match.
  (* keep = "true" *)logic fault0_before_pc_compare;
  assign fault0_before_pc_compare = visible_before_pc_compare && f0_q;
  always_comb begin
    if (!i_active) begin
      o_fault0 = bare_verdict.bare_fault0;
      o_fault0_page = 1'b0;
      o_fault1 = bare_verdict.bare_fault1;
      o_fault1_page = 1'b0;
      o_line_after_ok = 1'b1;
    end else begin
      o_fault0 = fault0_before_pc_compare && pc_match;
      o_fault0_page = translated_visible && f0p_q;
      o_fault1 = translated_visible && (pc_page_cross ? f1_q : f0_q);
      o_fault1_page = translated_visible && (pc_page_cross ? f1p_q : f0p_q);
      o_line_after_ok = translated_visible && live_after_ok;
    end
  end

`ifndef SYNTHESIS
  // Check result visibility, timing, and tag matching.
  always_comb begin
    if (!$isunknown(
            {
              i_active,
              i_pc,
              o_pa_valid,
              o_fault0,
              o_fault0_page,
              o_fault1,
              o_fault1_page,
              o_line_after_ok
            }
        )) begin
      if (!i_active) begin
        p_bare_pa0_exact : assert (o_pa0 == bare_pc);
        p_bare_pa1_exact : assert (o_pa1 == bare_pa1);
        p_bare_valid : assert (o_pa_valid);
        p_bare_faults_exact :
        assert (o_fault0 == bare_verdict.bare_fault0 &&
                o_fault1 == bare_verdict.bare_fault1 &&
                !o_fault0_page && !o_fault1_page && o_line_after_ok);
      end else if (!translated_visible) begin
        p_invisible_invalid : assert (!o_pa_valid);
        p_invisible_faults_zero :
        assert (!o_fault0 && !o_fault0_page && !o_fault1 && !o_fault1_page);
      end else begin
        p_visible_valid : assert (o_pa_valid);
      end
    end
  end

  always_ff @(posedge i_clk) begin
    if (reset_seen_q && !i_rst && !$isunknown(
            {i_pc, i_priv_u, np_va_q, o_walk_req_valid, o_walk_vpn}
        )) begin
      p_fault0_compare_last_exact : assert (!i_active || o_fault0 == (translated_visible && f0_q));
      if (translated_visible) begin
        p_visible_pa0_ppn_exact :
        assert (o_pa0[riscv_pkg::PhysAddrBits-1:12] == pa0_q[riscv_pkg::PhysAddrBits-1:12]);
        p_visible_tag_exact :
        assert (key_valid_q && (key_va_q[XLEN-1:12] == i_pc[XLEN-1:12]) &&
                (key_priv_u_q == i_priv_u) && resolved_q);
      end
      if (np_sample_matches) begin
        p_next_page_identity : assert (np_va_q == (key_va_q[XLEN-1:12] + 1'b1));
      end
      if (o_walk_req_valid) begin
        p_walk_from_live_tag : assert (tag_match && !resolved_q);
        p_walk_vpn_exact :
        assert (o_walk_vpn ==
            (miss0_q ? VpnBits'({{VpnBits{1'bx}}, key_va_q} >> 12) :
             VpnBits'({{VpnBits{1'bx}}, np_va_q})));
      end
      if (walk_resp_arrived) begin
        p_walk_response_echo : assert (i_walk_resp.vpn == walk_vpn_q);
      end
    end
  end
`endif

`ifdef IMMU_PAGE_OFFSET_LOCAL_PROOF
  // The translation result and its VA key load together. Prove that the page
  // offset is preserved even for arbitrary ITLB answers, faults, and retargets,
  // and that visible PAs combine captured physical pages with live offsets.
  // The reference selects a fault's VA before the capture.
  logic f_offset_past_valid = 1'b0;
  logic [PpnBits-1:0] f_pa1_ppn_ref_q;
  // The dtlb gives arbitrary answers here, within its output contract (which
  // tlb.sby checks): o_ppn and o_fetch_next_ppn are the stored part with the
  // lookup VPN's or the next VPN's low bits joined for the superpage size,
  // and the stored part is zero where those bits go.
  function automatic logic [PpnBits-1:0] f_join(input logic [PpnBits-1:0] own, input logic giga,
                                                input logic mega, input logic [17:0] va);
    f_join = own;
    if (giga) f_join[17:0] = va;
    if (mega) f_join[8:0] = va[8:0];
  endfunction
  always_comb begin
    for (int p = 0; p < 2; p++) begin
      assume (!(tlb_giga[p] && tlb_mega[p]));
      assume (!tlb_giga[p] || tlb_ppn_own[p][17:0] == '0);
      assume (!tlb_mega[p] || tlb_ppn_own[p][8:0] == '0);
      assume (tlb_ppn[p] == f_join(tlb_ppn_own[p], tlb_giga[p], tlb_mega[p], tlb_vpn[p][17:0]));
    end
    assume (tlb_fetch_next_ppn[0] == f_join(
        tlb_ppn_own[0], tlb_giga[0], tlb_mega[0], tlb_vpn[0][17:0] + 18'd1
    ));
  end
  always @(posedge i_clk) begin
    if (i_rst) f_pa1_ppn_ref_q <= '0;
    else if (i_active && !i_tlb_invalidate && capture_en) begin
      if (!pc_page_cross) f_pa1_ppn_ref_q <= pa0_d[riscv_pkg::PhysAddrBits-1:12];
      else if (super_next_ok) f_pa1_ppn_ref_q <= super_next_ppn;
      else if (res0.fault && (!np_sample_matches || !res1.resolved))
        f_pa1_ppn_ref_q <= pc_np_va[PpnBits-1:0];
      else if (np_sample_matches) f_pa1_ppn_ref_q <= res1.fault ? np_va_q[PpnBits-1:0] : res1.ppn;
      else f_pa1_ppn_ref_q <= '0;
    end
  end
  always @(posedge i_clk) begin
    f_offset_past_valid <= 1'b1;
    if (!f_offset_past_valid) assume (i_rst);
    if (f_offset_past_valid) begin
      p_captured_word1_page_exact : assert (pa1_ppn == f_pa1_ppn_ref_q);
      p_key_cross_exact : assert (key_cross_q == &key_va_q[11:2]);
      p_pc_low_ok_exact : assert (pc_low_ok == (!pc_page_cross || (key_va_q[11:0] == i_pc[11:0])));
      p_key_pa0_offset : assert (!key_valid_q || pa0_q[11:0] == key_va_q[11:0]);
      p_public_pa0_exact :
      assert (!translated_visible || o_pa0 == {pa0_q[riscv_pkg::PhysAddrBits-1:12], i_pc[11:0]});
      p_public_pa1_exact :
      assert (!translated_visible || o_pa1 == {
        pc_page_cross ? f_pa1_ppn_ref_q : pa0_q[riscv_pkg::PhysAddrBits-1:12],
        pc_plus4_lo, 2'b00
      });
      p_same_page_word1_faults :
      assert (!translated_visible || pc_page_cross ||
              {o_fault1, o_fault1_page} == {o_fault0, o_fault0_page});
    end
  end
`endif

`ifdef IMMU_MEMO_LOCAL_PROOF
  // Svvptc: the fault memo never holds a fault across a full flush, and only
  // a walk accepted after the most recent flush fills it. The references
  // track flushes, walk acceptance and refused responses independently of
  // walk_memo_ok_q, for arbitrary ITLB answers and walker traffic.
  logic f_memo_past_valid = 1'b0;
  logic f_accepted_since_flush_q;  // a walk was accepted after the last flush
  logic f_flush_since_fill_q;  // a flush or invalidate followed the last fill
  logic [FaultCacheEpochBits:0] f_memo_age_q, f_fault_age_q;
  always @(posedge i_clk) begin
    if (i_rst || i_full_flush) f_accepted_since_flush_q <= 1'b0;
    else if (o_walk_req_valid && i_walk_req_ready) f_accepted_since_flush_q <= 1'b1;
    if (i_rst || i_full_flush || i_tlb_invalidate || fault_cache_expire)
      f_flush_since_fill_q <= 1'b1;
    else if (resp_refused) f_flush_since_fill_q <= 1'b0;
    if (i_rst || !memo_valid_q) f_memo_age_q <= '0;
    else f_memo_age_q <= f_memo_age_q + 1'b1;
    if (i_rst || !resolved_q || !(f0_q || f1_q)) f_fault_age_q <= '0;
    else f_fault_age_q <= f_fault_age_q + 1'b1;
  end
  always @(posedge i_clk) begin
    f_memo_past_valid <= 1'b1;
    if (!f_memo_past_valid) assume (i_rst);
    if (f_memo_past_valid && !$past(i_rst)) begin
      if ($past(i_full_flush || fault_cache_expire)) p_flush_clears_memo : assert (!memo_valid_q);
      if ($past(resp_refused && !i_full_flush && !i_tlb_invalidate && !fault_cache_expire))
        p_memo_fill_after_flush : assert ($past(f_accepted_since_flush_q) && memo_valid_q);
      p_memo_needs_fault_since_flush : assert (!memo_valid_q || !f_flush_since_fill_q);
      // A registered fault does not survive a full flush either.
      if ($past(i_full_flush || (fault_cache_expire && resolved_q && (f0_q || f1_q))))
        p_flush_drops_registered_fault : assert (!resolved_q && !f0_q && !f1_q);
      if (!i_rst)
        p_fault_epoch_step :
        assert (fault_cache_epoch_q == FaultCacheEpochBits'($past(fault_cache_epoch_q) + 1'b1));
      if (memo_valid_q) begin
        p_memo_age_bounded : assert (f_memo_age_q <= {1'b0, fault_cache_epoch_q});
        p_memo_expiry_happened : assert (fault_cache_epoch_q != '0);
      end
      if (resolved_q && (f0_q || f1_q))
        p_registered_fault_age_bounded : assert (f_fault_age_q <= {1'b0, fault_cache_epoch_q});
      if ($past(
              i_active && !i_tlb_invalidate && capture_en && res0.fault &&
                !i_full_flush && !(fault_cache_expire && resolved_q && (f0_q || f1_q))
          ))
        p_first_fault_completes_window : assert (resolved_q && f0_q);
      if ($past(
              i_active && !i_tlb_invalidate && capture_en && pc_page_cross && res0.fault &&
                !super_next_ok && (!np_sample_matches || !res1.resolved) && !i_full_flush &&
                !(fault_cache_expire && resolved_q && (f0_q || f1_q))
          ))
        p_unknown_neighbor_stays_faulted :
        assert (f1_q && (f1p_q == $past(res0.page)) && pa1_use_va_q);
    end
  end
`endif

`ifdef FROST_DEBUG_FETCH_ILA
  // Fetch ILA probes (build.py --debug-ila): marked copies that the debug core
  // samples. Nothing here feeds the design.
  (* mark_debug = "true" *)logic dbg_ila_immu_active;
  (* mark_debug = "true" *)logic dbg_ila_immu_tag_match;
  (* mark_debug = "true" *)logic dbg_ila_immu_resolved;
  (* mark_debug = "true" *)logic dbg_ila_immu_visible;
  (* mark_debug = "true" *)logic dbg_ila_immu_walk_outstanding;
  (* mark_debug = "true" *)logic dbg_ila_immu_walk_req;
  (* mark_debug = "true" *)logic dbg_ila_immu_walk_resp;
  (* mark_debug = "true" *)logic dbg_ila_immu_invalidate;
  (* mark_debug = "true" *)logic dbg_ila_immu_pa_valid;
  (* mark_debug = "true" *)logic dbg_ila_immu_fault0;
  (* mark_debug = "true" *)logic dbg_ila_immu_fault1;
  assign dbg_ila_immu_active = i_active;
  assign dbg_ila_immu_tag_match = tag_match;
  assign dbg_ila_immu_resolved = resolved_q;
  assign dbg_ila_immu_visible = translated_visible;
  assign dbg_ila_immu_walk_outstanding = walk_outstanding_q;
  assign dbg_ila_immu_walk_req = o_walk_req_valid;
  assign dbg_ila_immu_walk_resp = i_walk_resp_valid;
  assign dbg_ila_immu_invalidate = i_tlb_invalidate;
  assign dbg_ila_immu_pa_valid = o_pa_valid;
  assign dbg_ila_immu_fault0 = o_fault0;
  assign dbg_ila_immu_fault1 = o_fault1;
`endif

endmodule : immu
