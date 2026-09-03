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
 * immu: instruction-side Sv39 translation.
 *
 * The translation key is pc_controller's registered fetch PC.  No
 * combinational next-PC selector payload enters this module.  That boundary
 * keeps the branch/redirect selector out of the ITLB, permission, PMA and
 * physical-result cones.
 *
 * Bare mode is a combinational, cycle-exact bypass from i_pc.  It never
 * bubbles and preserves the pre-translation physical-fetch contract:
 *   pa0 = i_pc[31:0]
 *   pa1 = the aligned word after i_pc, with 32-bit wrap
 *   faults = the full-XLEN Bare PMA verdict
 *
 * Sv39 state is tagged with {i_pc, i_priv_u}.  A tag mismatch is immediately
 * invisible (valid and all fault bits are zero), then the stable registered PC
 * is captured and resolved.  A warm non-crossing fetch therefore has one
 * translation bubble after PC movement.  A 4 KiB crossing can have a second
 * bubble while the registered next-page lookup key catches up.  Misses retain
 * the tag and stall IF until the shared walker returns.
 *
 * An accepted walk records its owner: the tagged key at acceptance.  Retargets,
 * privilege changes and mode changes do not cancel that owner: a late response
 * may still populate the ITLB or the refusal memo, but it may bypass into the
 * live result only when its saved owner tag still matches.  A one-cycle recheck
 * after every response lets a stale installation become visible before a new
 * request can issue.  Flash invalidate clears both translation state and walk
 * ownership and suppresses a simultaneous response.
 */
module immu #(
    parameter int unsigned XLEN = riscv_pkg::XLEN,
    parameter int unsigned NUM_ENTRIES = 8
) (
    input logic i_clk,
    input logic i_rst,

    // satp.MODE == Sv39 && priv != M, and the live fetch privilege.
    input logic i_active,
    input logic i_priv_u,

    // sfence.vma / satp-write flash invalidate.
    input logic i_tlb_invalidate,

    // pc_controller's registered PC. Exact tag comparison makes any result
    // captured for a pre-load value invisible as soon as this register moves;
    // Bare output is always formed directly from i_pc.
    input logic [XLEN-1:0] i_pc,

    output logic [31:0] o_pa0,
    output logic [31:0] o_pa1,
    output logic o_pa_valid,
    output logic o_fault0,
    output logic o_fault0_page,
    output logic o_fault1,
    output logic o_fault1_page,
    output logic o_line_after_ok,

    // Shared page-table walker seam; D-side arbitration is outside this unit.
    output logic o_walk_req_valid,
    input logic i_walk_req_ready,
    output logic [riscv_pkg::Sv39VpnBits-1:0] o_walk_vpn,
    input logic i_walk_resp_valid,
    input riscv_pkg::ptw_resp_t i_walk_resp
);

  localparam int unsigned VpnBits = riscv_pkg::Sv39VpnBits;
  localparam int unsigned NpBits = XLEN - riscv_pkg::Sv39PageOffsetBits;

  // ---------------------------------------------------------------------------
  // Bare bypass: this is the default low-memory/CoreMark path.
  // ---------------------------------------------------------------------------
  riscv_pkg::fetch_verdict_t bare_verdict;
  logic [31:0] bare_pa1;
  assign bare_verdict = riscv_pkg::fetch_verdict(i_pc);
  assign bare_pa1 = {i_pc[31:2] + 30'd1, 2'b00};

  // ---------------------------------------------------------------------------
  // Registered selected-VA identity.
  // ---------------------------------------------------------------------------
  logic key_valid_q;
  logic [XLEN-1:0] key_va_q;
  logic key_priv_u_q;
  logic resolved_q;
  logic tag_match;
  logic translated_visible;
  logic capture_en;

  assign tag_match = key_valid_q && (key_va_q == i_pc) && (key_priv_u_q == i_priv_u);
  assign translated_visible = i_active && !i_tlb_invalidate && tag_match && resolved_q;
  assign capture_en = i_active && !i_tlb_invalidate && (!tag_match || !resolved_q);

  logic [VpnBits-1:0] pc_vpn;
  logic pc_noncanon;
  logic pc_page_cross;
  logic [NpBits-1:0] pc_np_va;
  logic [9:0] pc_plus4_lo;
  assign pc_vpn = i_pc[38:12];
  assign pc_noncanon = !riscv_pkg::sv39_va_canonical(i_pc);
  assign pc_page_cross = &i_pc[11:2];
  assign pc_np_va = i_pc[XLEN-1:12] + 1'b1;
  assign pc_plus4_lo = i_pc[11:2] + 1'b1;

  // Port 1 uses a registered sample so no increment/canonicality cone is
  // serial with the ITLB.  Its full identity is checked before use.
  logic [NpBits-1:0] np_va_q;
  logic np_sample_matches;
  logic np_noncanon;
  assign np_sample_matches = key_valid_q && (key_va_q == i_pc) && (np_va_q == pc_np_va);
  assign np_noncanon = !riscv_pkg::sv39_va_canonical({np_va_q, 12'h000});

  // ---------------------------------------------------------------------------
  // Walker ownership.  Declared before the ITLB because an install or a memo
  // update requires a response for the outstanding walk (walk_resp_matches).
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
  logic [1:0][19:0] tlb_ppn20;
  logic [1:0] tlb_hi_nonzero;
  logic [1:0] tlb_r, tlb_w, tlb_x, tlb_u, tlb_d;
  logic [1:0][1:0] tlb_level;
  logic tlb_install;

  assign tlb_vpn[0] = pc_vpn;
  assign tlb_vpn[1] = np_va_q[VpnBits-1:0];
  assign tlb_install = walk_resp_matches &&
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
  // One-entry walk-refusal memo.  A refusal is an address-space fact, not a
  // privilege fact, and remains valid until the same invalidate as the ITLB.
  // ---------------------------------------------------------------------------
  logic memo_valid_q;
  logic [VpnBits-1:0] memo_vpn_q;
  logic memo_page_q;
  logic resp_refused;
  assign resp_refused = walk_resp_matches &&
      (i_walk_resp.fault_kind != riscv_pkg::DFAULT_NONE) && !i_tlb_invalidate;

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
  // Resolve one translated page.  The response bypass is enabled only when the
  // saved owner tag matches the live tagged state (resp_for_live_key); a stale
  // response still installs, for the recheck cycle to pick up, but cannot make
  // unrelated payload visible.
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
    logic resolved;
    logic fault;
    logic page;
    logic [19:0] ppn20;
    logic hi_nonzero;
    logic [1:0] level;
    logic clean_hit;
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
      tlb_ppn20[0],
      tlb_hi_nonzero[0],
      tlb_x[0],
      tlb_u[0],
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
      np_va_q[VpnBits-1:0],
      tlb_hit[1],
      tlb_ppn20[1],
      tlb_hi_nonzero[1],
      tlb_x[1],
      tlb_u[1],
      tlb_level[1],
      i_priv_u,
      i_tlb_invalidate,
      resp_for_live_key,
      i_walk_resp,
      memo_valid_q,
      memo_vpn_q,
      memo_page_q
  );

  // The aligned successor word can be derived inside the same 2 MiB/1 GiB
  // leaf. At the superpage end the carry enters the entry key, so port 1 must
  // resolve the exact next VPN instead.
  logic super_end;
  logic super_next_ok;
  logic [19:0] super_next_ppn20;
  logic super_next_pma_bad;
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
  assign super_next_pma_bad = !riscv_pkg::pma_fetch_ok({32'b0, super_next_ppn20, 12'h000});

  // ---------------------------------------------------------------------------
  // Atomic tagged-state capture.
  // ---------------------------------------------------------------------------
  logic [31:0] pa0_d, pa1_d;
  logic resolved_d, f0_d, f0p_d, f1_d, f1p_d, after_ok_d;
  logic miss0_d, miss1_d;
  logic resolved1;

  always_comb begin
    pa0_d = res0.fault ? i_pc[31:0] : {res0.ppn20, i_pc[11:0]};
    pa1_d = {pa0_d[31:12], pc_plus4_lo, 2'b00};
    f0_d = res0.fault;
    f0p_d = res0.page;
    f1_d = res0.fault;
    f1p_d = res0.page;
    after_ok_d = 1'b1;
    miss0_d = !res0.resolved;
    miss1_d = 1'b0;
    resolved1 = 1'b1;

    if (pc_page_cross) begin
      if (super_next_ok) begin
        pa1_d = {super_next_ppn20, 12'h000};
        f1_d  = super_next_pma_bad;
        f1p_d = 1'b0;
      end else if (np_sample_matches) begin
        pa1_d = res1.fault ? {np_va_q[19:0], 12'h000} : {res1.ppn20, 12'h000};
        f1_d = res1.fault;
        f1p_d = res1.page;
        resolved1 = res1.resolved;
        miss1_d = res0.resolved && !res1.resolved;
      end else begin
        pa1_d = '0;
        f1_d = 1'b0;
        f1p_d = 1'b0;
        resolved1 = 1'b0;
      end
    end

    resolved_d = res0.resolved && resolved1;
    after_ok_d = (pa0_d[11:5] != 7'h7F) || (pa0_d[4:2] == 3'b111);
  end

  logic [31:0] pa0_q, pa1_q;
  logic f0_q, f0p_q, f1_q, f1p_q, after_ok_q;
  logic miss0_q, miss1_q;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      key_valid_q <= 1'b0;
      key_va_q <= '0;
      key_priv_u_q <= 1'b0;
      np_va_q <= '0;
      resolved_q <= 1'b0;
      miss0_q <= 1'b0;
      miss1_q <= 1'b0;
      pa0_q <= '0;
      pa1_q <= '0;
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
      key_priv_u_q <= i_priv_u;
      np_va_q <= pc_np_va;
      resolved_q <= resolved_d;
      miss0_q <= miss0_d;
      miss1_q <= miss1_d;
      pa0_q <= pa0_d;
      pa1_q <= pa1_d;
      f0_q <= f0_d;
      f0p_q <= f0p_d;
      f1_q <= f1_d;
      f1p_q <= f1p_d;
      after_ok_q <= after_ok_d;
    end
  end

  // ---------------------------------------------------------------------------
  // Walk request and owner lifetime.
  // ---------------------------------------------------------------------------
  logic walk_needed;
  assign walk_needed = tag_match && !resolved_q && (miss0_q || miss1_q);
  assign o_walk_req_valid = i_active && !i_tlb_invalidate && walk_needed &&
                            !walk_outstanding_q && !walk_recheck_q;
  assign o_walk_vpn = miss0_q ? key_va_q[38:12] : np_va_q[VpnBits-1:0];

  always_ff @(posedge i_clk) begin
    if (i_rst || i_tlb_invalidate) begin
      walk_outstanding_q <= 1'b0;
      walk_vpn_q <= '0;
      walk_key_va_q <= '0;
      walk_key_priv_u_q <= 1'b0;
      walk_recheck_q <= 1'b0;
    end else begin
      // High for exactly the cycle following an owned response.  A current
      // response normally resolves through bypass; a stale response needs
      // this quiet cycle for its ITLB/memo write to reach the resolver.
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
  // Visibility boundary.  Invalid translated payload may be stale/arbitrary;
  // fault bits are forced low so no consumer can observe a mismatched tag.
  // ---------------------------------------------------------------------------
  always_comb begin
    if (!i_active) begin
      o_pa0 = i_pc[31:0];
      o_pa1 = bare_pa1;
      o_pa_valid = 1'b1;
      o_fault0 = bare_verdict.bare_fault0;
      o_fault0_page = 1'b0;
      o_fault1 = bare_verdict.bare_fault1;
      o_fault1_page = 1'b0;
      o_line_after_ok = 1'b1;
    end else begin
      o_pa0 = pa0_q;
      o_pa1 = pa1_q;
      o_pa_valid = translated_visible;
      o_fault0 = translated_visible && f0_q;
      o_fault0_page = translated_visible && f0p_q;
      o_fault1 = translated_visible && f1_q;
      o_fault1_page = translated_visible && f1p_q;
      o_line_after_ok = translated_visible && after_ok_q;
    end
  end

`ifndef SYNTHESIS
  // Simulation assertions.  Directed cocotb tests provide the independent
  // translation model; these pin the timing and ownership boundary above.
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
        p_bare_pa0_exact : assert (o_pa0 == i_pc[31:0]);
        p_bare_pa1_exact : assert (o_pa1 == {i_pc[31:2] + 30'd1, 2'b00});
        p_bare_valid : assert (o_pa_valid);
        p_bare_faults_exact :
        assert (o_fault0 == bare_verdict.bare_fault0 &&
                o_fault1 == bare_verdict.bare_fault1 &&
                !o_fault0_page && !o_fault1_page && o_line_after_ok);
      end else if (!translated_visible) begin
        p_invisible_invalid : assert (!o_pa_valid);
        p_invisible_faults_zero :
        assert (!o_fault0 && !o_fault0_page && !o_fault1 && !o_fault1_page);
      end
    end
  end

  always_ff @(posedge i_clk) begin
    if (!i_rst && !$isunknown({i_pc, i_priv_u, np_va_q, o_walk_req_valid, o_walk_vpn})) begin
      if (translated_visible) begin
        p_visible_tag_exact :
        assert (key_valid_q && (key_va_q == i_pc) && (key_priv_u_q == i_priv_u) && resolved_q);
      end
      if (np_sample_matches) begin
        p_next_page_identity : assert (np_va_q == (key_va_q[XLEN-1:12] + 1'b1));
      end
      if (o_walk_req_valid) begin
        p_walk_from_live_tag : assert (tag_match && !resolved_q);
        p_walk_vpn_exact :
        assert (o_walk_vpn == (miss0_q ? key_va_q[38:12] : np_va_q[VpnBits-1:0]));
      end
      if (walk_resp_arrived) begin
        p_walk_response_echo : assert (i_walk_resp.vpn == walk_vpn_q);
      end
    end
  end
`endif

endmodule : immu
