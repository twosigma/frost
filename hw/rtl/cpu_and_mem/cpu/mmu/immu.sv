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
 * zero added hit latency: the ITLB (an 8-entry instance of the generic
 * dtlb) looks up the NEXT-pc mux output combinationally, and the result
 * lands in PA SHADOW registers clocked by the same enable as pc itself.
 * The shadows therefore describe o_pc's fetch window identity-timed with
 * o_pc, and the lookup cone ends at their D pins -- nothing of the TLB
 * reaches the BRAM address pins, the provider's window-ready cone, or the
 * fetch-progress -> PC loop (M4's registered-resolution lesson).
 *
 * A fetch window is the two words {pc, pc + 4}. Each shadow load resolves
 *   word 0: pa0 / fault0 for pc's page, and
 *   word 1: pa1 / fault1 for word 1 -- pa0 + 4 inside the page; across a
 *           4 KiB boundary (pc[11:2] all ones) a SECOND translation of the
 *           next page, resolved
 *             (a) at once when word 0 hit a superpage the next page stays
 *                 inside (the kernel's 2 MiB text), or
 *             (b) one cycle later through the ITLB's second port, keyed by
 *                 the registered next-page VA: the first cycle at a
 *                 crossing PC leaves the shadow unresolved (a one-cycle
 *                 front-end stall) and the reload sees the second port --
 *                 one bubble per 4 KiB of straight-line 4 KiB-mapped code.
 * Translation inactive (satp Bare or M-mode): the shadows are the VA's low
 * 32 bits and the Bare PMA verdict -- the seam is bit-identical to the
 * pre-M5 physical fetch, prefetch across pages included.
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
 * twice. While stalled the shadow keeps re-evaluating on pc itself (the
 * lookup key follows the flop enable: next_pc when pc loads, pc when it
 * holds), the walker is asked for the missing page (the data side wins
 * the shared ptw, D6), and the response installs the leaf or memoizes the
 * refusal -- the same-cycle bypass resolves the shadow from the response
 * itself. The flash invalidate (sfence.vma window / D10 pulse) clears the
 * ITLB, the memo and any pending ask; it also masks the lookup in its own
 * cycle so a shadow loaded at the flush redirect edge cannot carry the old
 * address space's translation.
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
    // The lookup key is next_pc whenever pc loads (any enable, redirects
    // included) and pc itself while pc holds (a stall -- including the one
    // an unresolved shadow raises), so the shadow always describes pc.
    input logic i_pc_update_en,
    input logic [XLEN-1:0] i_next_pc,
    input logic i_next_pc_holds,
    input logic [XLEN-1:0] i_pc,

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

  // ---------------------------------------------------------------------------
  // Next-pc decomposition
  // ---------------------------------------------------------------------------
  logic valid_q;  // the shadow is resolved (declared with the registers below)
  logic [XLEN-1:0] key_va;  // the VA the shadow describes after this edge
  logic [VpnBits-1:0] vpn0;
  logic noncanon0;
  logic page_cross;  // word 0 is its page's last word: word 1 lies in the next page
  logic [NpBits-1:0] np_va_c;  // VA[63:12] of the next page
  logic noncanon_np_c;
  logic [9:0] plus4_lo;  // (pc + 4)[11:2] when not crossing
  // Resolved shadows reload only when pc loads (key = next_pc); an
  // unresolved one re-evaluates every cycle on the held pc. The select is a
  // register bit, so the stall cone never reaches the lookup key.
  assign key_va = valid_q ? i_next_pc : i_pc;
  // A pc load while the shadow is unresolved (a redirect landing during the
  // hold, or the flush that released it) pairs this reload's key (the old
  // pc) with the NEW pc: force one more unresolved cycle so the next reload
  // re-keys on the new pc, and never walk on the stale key.
  logic key_stale;
  assign key_stale = !valid_q && i_pc_update_en;
  assign vpn0 = key_va[38:12];
  assign noncanon0 = !riscv_pkg::sv39_va_canonical(key_va);
  assign page_cross = &key_va[11:2];
  assign np_va_c = key_va[XLEN-1:12] + 1'b1;
  assign noncanon_np_c = !riscv_pkg::sv39_va_canonical({np_va_c, 12'h000});
  assign plus4_lo = key_va[11:2] + 1'b1;

  // The registered next-page key describes the key of the previous reload;
  // it is the current key's next page exactly when the key did not move:
  // pc holding (no enable) with a key that was not stale, or the
  // no-progress hold arm on a loading pc.
  logic np_key_valid_q;
  logic use_np;
  assign use_np = i_pc_update_en ? i_next_pc_holds : np_key_valid_q;

  // Registered next-page key for the crossing lookup (loaded with o_pc).
  logic [NpBits-1:0] np_va_q;
  logic np_noncanon_q;

  // ---------------------------------------------------------------------------
  // ITLB: port 0 = next_pc's page, port 1 = the registered next page.
  // ---------------------------------------------------------------------------
  logic [1:0][VpnBits-1:0] tlb_vpn;
  logic [1:0] tlb_hit;
  logic [1:0][19:0] tlb_ppn20;
  logic [1:0] tlb_hi_nonzero;
  logic [1:0] tlb_r, tlb_w, tlb_x, tlb_u, tlb_d;
  logic [1:0][1:0] tlb_level;
  assign tlb_vpn[0] = vpn0;
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
      input logic [19:0] ppn20, input logic hi_nonzero, input logic perm_x,
      input logic perm_u, input logic [1:0] level, input logic priv_u,
      input logic invalidate, input logic resp_valid, input riscv_pkg::ptw_resp_t resp,
      input logic memo_valid, input logic [VpnBits-1:0] memo_vpn, input logic memo_page);
    port_res_t r;
    logic resp_match, use_resp_leaf, have;
    logic e_x, e_u, e_hi_nonzero;
    logic [19:0] e_ppn20;
    logic [1:0] e_level;
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
          r.page = 1'b1;
        end else if (pma_bad) begin
          r.fault = 1'b1;
          r.page = 1'b0;
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

  port_res_t res0, res1;
  assign res0 = resolve_port(noncanon0, vpn0, tlb_hit[0], tlb_ppn20[0], tlb_hi_nonzero[0],
                             tlb_x[0], tlb_u[0], tlb_level[0], i_priv_u, i_tlb_invalidate,
                             i_walk_resp_valid, i_walk_resp, memo_valid_q, memo_vpn_q,
                             memo_page_q);
  assign res1 = resolve_port(np_noncanon_q, np_va_q[VpnBits-1:0], tlb_hit[1], tlb_ppn20[1],
                             tlb_hi_nonzero[1], tlb_x[1], tlb_u[1], tlb_level[1], i_priv_u,
                             i_tlb_invalidate, i_walk_resp_valid, i_walk_resp, memo_valid_q,
                             memo_vpn_q, memo_page_q);

  // Superpage next page: word 0 hit a clean 2 MiB / 1 GiB leaf and the next
  // 4 KiB page is still inside it -- derive its PPN by incrementing the
  // VA-supplied index bits (no carry into the entry's bits by construction).
  logic super_end;
  logic super_next_ok;
  logic [19:0] super_next_ppn20;
  always_comb begin
    unique case (res0.level)
      2'd2: begin
        super_end = &vpn0[17:0];
        super_next_ppn20 = {res0.ppn20[19:18], vpn0[17:0] + 18'd1};
      end
      2'd1: begin
        super_end = &vpn0[8:0];
        super_next_ppn20 = {res0.ppn20[19:9], vpn0[8:0] + 9'd1};
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
    pa0_d = key_va[31:0];
    pa1_d = {key_va[31:12], plus4_lo, 2'b00};
    f0_d = 1'b0;
    f0p_d = 1'b0;
    f1_d = 1'b0;
    f1p_d = 1'b0;
    valid_d = 1'b1;
    after_ok_d = 1'b1;
    miss0_d = 1'b0;
    miss1_d = 1'b0;
    resolved1 = 1'b1;
    if (!i_active) begin
      // Bare / M-mode: the physical fetch of pre-M5, verdict included.
      pa0_d = key_va[31:0];
      f0_d = !riscv_pkg::pma_fetch_ok(key_va);
      f0p_d = 1'b0;
      if (page_cross) begin
        pa1_d = {np_va_c[19:0], 12'h000};
        f1_d  = !riscv_pkg::pma_fetch_ok({np_va_c, 12'h000});
      end else begin
        pa1_d = {key_va[31:12], plus4_lo, 2'b00};
        f1_d  = f0_d;
      end
      f1p_d = 1'b0;
      valid_d = 1'b1;
      after_ok_d = 1'b1;
    end else begin
      // Word 0.
      pa0_d = res0.fault ? key_va[31:0] : {res0.ppn20, key_va[11:0]};
      f0_d = res0.fault;
      f0p_d = res0.page;
      miss0_d = !res0.resolved;
      // Word 1.
      if (!page_cross) begin
        pa1_d = {pa0_d[31:12], plus4_lo, 2'b00};
        f1_d  = f0_d;
        f1p_d = f0p_d;
      end else if (super_next_ok) begin
        pa1_d = {super_next_ppn20, 12'h000};
        f1_d  = super_next_pma_bad;
        f1p_d = 1'b0;
      end else if (use_np) begin
        // Second cycle at the crossing PC: the registered next-page key.
        pa1_d = res1.fault ? {np_va_q[19:0], 12'h000} : {res1.ppn20, 12'h000};
        f1_d = res1.fault;
        f1p_d = res1.page;
        resolved1 = res1.resolved;
        miss1_d = res0.resolved && !res1.resolved;
      end else begin
        // First cycle at a crossing PC: word 1 is not looked up yet.
        pa1_d = '0;
        f1_d = 1'b0;
        f1p_d = 1'b0;
        resolved1 = 1'b0;
      end
      valid_d = res0.resolved && resolved1;
      // Prefetching past the page needs a translation this window does not
      // carry -- unless the window itself straddles into that line.
      after_ok_d = (pa0_d[11:5] != 7'h7F) || (pa0_d[4:2] == 3'b111);
    end
    if (key_stale) begin
      valid_d = 1'b0;
      miss0_d = 1'b0;
      miss1_d = 1'b0;
    end
  end

  // ---------------------------------------------------------------------------
  // Shadow registers: reload whenever pc loads, and every cycle while the
  // shadow is unresolved (the front end is stalled on it; the key is pc).
  // ---------------------------------------------------------------------------
  logic [31:0] pa0_q, pa1_q;
  logic f0_q, f0p_q, f1_q, f1p_q, after_ok_q;
  logic miss0_q, miss1_q;

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
      np_va_q <= '0;
      np_noncanon_q <= 1'b0;
      np_key_valid_q <= 1'b0;
    end else if (i_pc_update_en || !valid_q) begin
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
      np_va_q <= np_va_c;
      np_noncanon_q <= noncanon_np_c;
      np_key_valid_q <= !key_stale;
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
      if (miss0_q) assert (o_walk_vpn == i_pc[38:12]);
      else assert (np_va_q == (i_pc[XLEN-1:12] + 1'b1));
    end
  end
`endif
`endif

endmodule : immu
