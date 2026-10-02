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
 * dtlb: fully associative Sv39 TLB with superpages. The data MMU uses it as
 * the 16-entry DTLB and the instruction MMU (mmu/immu) as the 8-entry ITLB.
 *
 * Each flop entry holds one leaf PTE at its own level, and the compare is
 * masked by level: a 1 GiB entry matches on VPN2 alone, a 2 MiB entry on VPN2
 * and VPN1, a 4 KiB entry on all 27 VPN bits. Replacement uses a rotating
 * pointer. Entries carry no ASID, so SFENCE.VMA and the CSR file's
 * translation invalidate (hw/rtl/cpu_and_mem/cpu/README.md, "CSR writes") both
 * clear every entry through i_invalidate_all. An invalidate in the same cycle
 * as an install wins, because the install belongs to the old address space.
 *
 * The physical map is 32-bit, so an entry keeps only PPN[19:0] and one bit
 * that is set when PPN[43:20] is nonzero. A lookup returns PA[31:12] and that
 * bit, and the MMU raises an access fault for a leaf outside the map. It also
 * returns whether PA[31:12] is in a device window
 * (riscv_pkg::pma_device_page_ok), computed for every entry beside the
 * compare so that the data MMU's MMIO class does not wait for the PPN mux.
 * The MMU also checks permissions; this module only reports the stored R, W,
 * X, U, and D bits.
 *
 * Lookups are combinational, one per port: the data side's issue port and
 * its two early-store ports, or the instruction side's current-PC and
 * next-page ports. The hardware never creates duplicate entries: the one
 * walker installs only for a lookup that missed, keyed by the walk's VPN
 * echo. Software that changes a mapping without SFENCE.VMA sees one of the
 * prior translations, which the privileged spec permits.
 */
module dtlb #(
    parameter int unsigned NUM_ENTRIES    = 16,
    parameter int unsigned NUM_PORTS      = 3,
    // Form the instruction MMU's per-entry fetch verdicts (o_fetch_*). The
    // data MMU leaves this off, which keeps its lookup netlist free of them.
    parameter bit          FETCH_VERDICTS = 1'b0
) (
    input logic i_clk,
    input logic i_rst_n,

    input logic i_invalidate_all,

    // Install a walked leaf (fault-free ptw response).
    input logic                 i_install_valid,
    input riscv_pkg::ptw_resp_t i_install,

    // Combinational lookup ports.
    input  logic [NUM_PORTS-1:0][riscv_pkg::Sv39VpnBits-1:0] i_lookup_vpn,
    output logic [NUM_PORTS-1:0]                             o_hit,
    output logic [NUM_PORTS-1:0][                      19:0] o_ppn20,              // PA[31:12]
    output logic [NUM_PORTS-1:0]                             o_ppn_hi_nonzero,
    output logic [NUM_PORTS-1:0]                             o_perm_r,
    output logic [NUM_PORTS-1:0]                             o_perm_w,
    output logic [NUM_PORTS-1:0]                             o_perm_x,
    output logic [NUM_PORTS-1:0]                             o_perm_u,
    output logic [NUM_PORTS-1:0]                             o_perm_d,
    // Level of the hit entry (0 = 4 KiB, 1 = 2 MiB, 2 = 1 GiB): lets the
    // ITLB derive the next page's PA inside a superpage without a second
    // lookup.
    output logic [NUM_PORTS-1:0][                       1:0] o_level,
    // o_ppn20 is a device-window page (riscv_pkg::pma_device_page_ok).
    output logic [NUM_PORTS-1:0]                             o_device_page,
    // The data MMU's leaf checks of each port's hit, formed per entry before
    // the select so that no permission or PMA logic follows it. o_perm_ok is
    // the permission check: i_perm_store asks for W and D, otherwise R, or X
    // with i_perm_mxr; a U page needs U mode (i_perm_priv_u) or i_perm_sum, and
    // an S page needs S mode. o_atomic_page is riscv_pkg::pma_atomic_ok of the
    // hit's zero-extended PA. The ITLB ties the inputs off and leaves these
    // outputs open.
    input  logic [NUM_PORTS-1:0]                             i_perm_store,
    input  logic                                             i_perm_priv_u,
    input  logic                                             i_perm_sum,
    input  logic                                             i_perm_mxr,
    output logic [NUM_PORTS-1:0]                             o_perm_ok,
    output logic [NUM_PORTS-1:0]                             o_atomic_page,
    // With FETCH_VERDICTS, the instruction MMU's leaf checks of each port's
    // hit, likewise formed per entry before the select. o_fetch_perm_fault:
    // the hit lacks X or its U bit differs from the fetch privilege
    // (i_fetch_priv_u). o_fetch_pma_bad: the hit's PA has nonzero high PPN
    // bits or fails riscv_pkg::pma_fetch_ok. o_fetch_next_pma_bad: the same
    // PMA check of the aligned next page inside the hit's superpage (the
    // entry's high PPN bits over the lookup VPN plus one; meaningful for
    // levels 1 and 2). All three are 0 on a miss, and 0 without
    // FETCH_VERDICTS. The data MMU ties the input off and leaves these
    // outputs open.
    input  logic                                             i_fetch_priv_u,
    output logic [NUM_PORTS-1:0]                             o_fetch_perm_fault,
    output logic [NUM_PORTS-1:0]                             o_fetch_pma_bad,
    output logic [NUM_PORTS-1:0]                             o_fetch_next_pma_bad
);

  localparam int unsigned EntryIdxBits = (NUM_ENTRIES > 1) ? $clog2(NUM_ENTRIES) : 1;

  logic [NUM_ENTRIES-1:0] e_valid;
  logic [riscv_pkg::Sv39VpnBits-1:0] e_vpn[NUM_ENTRIES];
  logic [1:0] e_level[NUM_ENTRIES];
  logic [19:0] e_ppn20[NUM_ENTRIES];
  logic [NUM_ENTRIES-1:0] e_ppn_hi_nonzero;
  logic [NUM_ENTRIES-1:0] e_r, e_w, e_x, e_u, e_d;

  // ---------------------------------------------------------------------------
  // Lookup: level-masked compare, lowest matching index wins.
  // ---------------------------------------------------------------------------
  // TIMING: each entry's three VPN chunk compares are kept as nets, and the
  // lowest match is found as a one-hot select before an AND-OR mux, so the
  // lookup is a shallow tree instead of a compare chain feeding a priority
  // chain.
  (* keep = "true" *)logic [NUM_PORTS-1:0][NUM_ENTRIES-1:0] vpn2_eq;
  (* keep = "true" *)logic [NUM_PORTS-1:0][NUM_ENTRIES-1:0] vpn1_eq;
  (* keep = "true" *)logic [NUM_PORTS-1:0][NUM_ENTRIES-1:0] vpn0_eq;
  logic [NUM_PORTS-1:0][NUM_ENTRIES-1:0] match;
  logic [NUM_PORTS-1:0][NUM_ENTRIES-1:0] lowest_match;
  always_comb begin
    for (int p = 0; p < NUM_PORTS; p++) begin
      for (int e = 0; e < NUM_ENTRIES; e++) begin
        vpn2_eq[p][e] = (i_lookup_vpn[p][26:18] == e_vpn[e][26:18]);
        vpn1_eq[p][e] = (i_lookup_vpn[p][17:9] == e_vpn[e][17:9]);
        vpn0_eq[p][e] = (i_lookup_vpn[p][8:0] == e_vpn[e][8:0]);
        unique case (e_level[e])
          2'd2:    match[p][e] = e_valid[e] && vpn2_eq[p][e];
          2'd1:    match[p][e] = e_valid[e] && vpn2_eq[p][e] && vpn1_eq[p][e];
          default: match[p][e] = e_valid[e] && vpn2_eq[p][e] && vpn1_eq[p][e] && vpn0_eq[p][e];
        endcase
      end
      for (int e = 0; e < NUM_ENTRIES; e++) begin
        lowest_match[p][e] = match[p][e] && !(|(match[p] & ((NUM_ENTRIES'(1) << e) - 1'b1)));
      end
    end
  end

  function automatic logic leaf_perm_ok(input logic store, input logic r, input logic w,
                                        input logic x, input logic u, input logic d);
    logic priv_ok;
    priv_ok = u ? (i_perm_priv_u || i_perm_sum) : !i_perm_priv_u;
    leaf_perm_ok = priv_ok && (store ? (w && d) : (r || (i_perm_mxr && x)));
  endfunction

  // The aligned next page inside a superpage: the lookup VPN's low field
  // plus one, shared by every entry of a port (o_fetch_next_pma_bad).
  logic [NUM_PORTS-1:0][17:0] next_vpn_low18;
  logic [NUM_PORTS-1:0][ 8:0] next_vpn_low9;
  always_comb begin
    for (int p = 0; p < NUM_PORTS; p++) begin
      next_vpn_low18[p] = FETCH_VERDICTS ? i_lookup_vpn[p][17:0] + 18'd1 : '0;
      next_vpn_low9[p]  = FETCH_VERDICTS ? i_lookup_vpn[p][8:0] + 9'd1 : '0;
    end
  end

  always_comb begin
    for (int p = 0; p < NUM_PORTS; p++) begin
      o_hit[p] = |match[p];
      o_ppn20[p] = '0;
      o_device_page[p] = 1'b0;
      o_perm_ok[p] = 1'b0;
      o_atomic_page[p] = 1'b0;
      o_ppn_hi_nonzero[p] = 1'b0;
      o_perm_r[p] = 1'b0;
      o_perm_w[p] = 1'b0;
      o_perm_x[p] = 1'b0;
      o_perm_u[p] = 1'b0;
      o_perm_d[p] = 1'b0;
      o_level[p] = 2'd0;
      o_fetch_perm_fault[p] = 1'b0;
      o_fetch_pma_bad[p] = 1'b0;
      o_fetch_next_pma_bad[p] = 1'b0;
      for (int e = 0; e < NUM_ENTRIES; e++) begin
        logic [19:0] ppn20, next_ppn20;
        // For a superpage the low PPN bits come from the VA, as Sv39
        // specifies. The walker faults a misaligned superpage, so the
        // entry's own low PPN bits are zero.
        unique case (e_level[e])
          2'd2: begin
            ppn20 = {e_ppn20[e][19:18], i_lookup_vpn[p][17:0]};
            next_ppn20 = {e_ppn20[e][19:18], next_vpn_low18[p]};
          end
          2'd1: begin
            ppn20 = {e_ppn20[e][19:9], i_lookup_vpn[p][8:0]};
            next_ppn20 = {e_ppn20[e][19:9], next_vpn_low9[p]};
          end
          default: begin
            ppn20 = e_ppn20[e];
            next_ppn20 = e_ppn20[e];
          end
        endcase
        o_ppn20[p] |= {20{lowest_match[p][e]}} & ppn20;
        o_device_page[p] |= lowest_match[p][e] && riscv_pkg::pma_device_page_ok(ppn20);
        o_perm_ok[p] |= lowest_match[p][e] && leaf_perm_ok(
            i_perm_store[p], e_r[e], e_w[e], e_x[e], e_u[e], e_d[e]
        );
        o_atomic_page[p] |= lowest_match[p][e] && riscv_pkg::pma_atomic_ok({32'b0, ppn20, 12'h000});
        o_ppn_hi_nonzero[p] |= lowest_match[p][e] && e_ppn_hi_nonzero[e];
        o_perm_r[p] |= lowest_match[p][e] && e_r[e];
        o_perm_w[p] |= lowest_match[p][e] && e_w[e];
        o_perm_x[p] |= lowest_match[p][e] && e_x[e];
        o_perm_u[p] |= lowest_match[p][e] && e_u[e];
        o_perm_d[p] |= lowest_match[p][e] && e_d[e];
        o_level[p] |= {2{lowest_match[p][e]}} & e_level[e];
        if (FETCH_VERDICTS) begin
          o_fetch_perm_fault[p] |= lowest_match[p][e] && !(e_x[e] && (e_u[e] == i_fetch_priv_u));
          o_fetch_pma_bad[p] |= lowest_match[p][e] &&
              (e_ppn_hi_nonzero[e] || !riscv_pkg::pma_fetch_ok(
              {32'b0, ppn20, 12'h000}
          ));
          o_fetch_next_pma_bad[p] |= lowest_match[p][e] && !riscv_pkg::pma_fetch_ok(
              {32'b0, next_ppn20, 12'h000}
          );
        end
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Install / invalidate. Rotating replacement pointer.
  // ---------------------------------------------------------------------------
  logic [EntryIdxBits-1:0] repl_ptr_q;

  always_ff @(posedge i_clk) begin
    if (!i_rst_n) begin
      e_valid <= '0;
      repl_ptr_q <= '0;
    end else if (i_invalidate_all) begin
      e_valid <= '0;
    end else if (i_install_valid) begin
      e_valid[repl_ptr_q] <= 1'b1;
      e_vpn[repl_ptr_q] <= i_install.vpn;
      e_level[repl_ptr_q] <= i_install.level;
      e_ppn20[repl_ptr_q] <= i_install.ppn[19:0];
      e_ppn_hi_nonzero[repl_ptr_q] <= |i_install.ppn[riscv_pkg::PtePpnBits-1:20];
      e_r[repl_ptr_q] <= i_install.perm_r;
      e_w[repl_ptr_q] <= i_install.perm_w;
      e_x[repl_ptr_q] <= i_install.perm_x;
      e_u[repl_ptr_q] <= i_install.perm_u;
      e_d[repl_ptr_q] <= i_install.perm_d;
      repl_ptr_q <= repl_ptr_q + 1'b1;
    end
  end

`ifndef SYNTHESIS
  // Reference lookup: the priority chain in which the lowest matching index
  // wins. The select tree above must give the same result for every lookup.
  for (genvar gp = 0; gp < NUM_PORTS; gp++) begin : gen_lookup_reference
    logic [19:0] ref_ppn20, ref_next_ppn20;
    logic ref_device_page, ref_ppn_hi_nonzero, ref_r, ref_w, ref_x, ref_u, ref_d;
    logic ref_perm_ok, ref_atomic_page;
    logic ref_fetch_perm_fault, ref_fetch_pma_bad, ref_fetch_next_pma_bad;
    logic [1:0] ref_level;
    always_comb begin
      ref_ppn20 = '0;
      ref_next_ppn20 = '0;
      ref_device_page = 1'b0;
      ref_ppn_hi_nonzero = 1'b0;
      {ref_r, ref_w, ref_x, ref_u, ref_d} = '0;
      ref_perm_ok = 1'b0;
      ref_atomic_page = 1'b0;
      ref_level = 2'd0;
      ref_fetch_perm_fault = 1'b0;
      ref_fetch_pma_bad = 1'b0;
      ref_fetch_next_pma_bad = 1'b0;
      for (int e = NUM_ENTRIES - 1; e >= 0; e--) begin
        if (match[gp][e]) begin
          unique case (e_level[e])
            2'd2: begin
              ref_ppn20 = {e_ppn20[e][19:18], i_lookup_vpn[gp][17:0]};
              ref_next_ppn20 = {e_ppn20[e][19:18], 18'(i_lookup_vpn[gp][17:0] + 18'd1)};
            end
            2'd1: begin
              ref_ppn20 = {e_ppn20[e][19:9], i_lookup_vpn[gp][8:0]};
              ref_next_ppn20 = {e_ppn20[e][19:9], 9'(i_lookup_vpn[gp][8:0] + 9'd1)};
            end
            default: begin
              ref_ppn20 = e_ppn20[e];
              ref_next_ppn20 = e_ppn20[e];
            end
          endcase
          ref_device_page = riscv_pkg::pma_device_page_ok(ref_ppn20);
          ref_ppn_hi_nonzero = e_ppn_hi_nonzero[e];
          {ref_r, ref_w, ref_x, ref_u, ref_d} = {e_r[e], e_w[e], e_x[e], e_u[e], e_d[e]};
          ref_perm_ok = (e_u[e] ? (i_perm_priv_u || i_perm_sum) : !i_perm_priv_u) &&
              (i_perm_store[gp] ? (e_w[e] && e_d[e]) : (e_r[e] || (i_perm_mxr && e_x[e])));
          ref_atomic_page = riscv_pkg::pma_atomic_ok({32'b0, ref_ppn20, 12'h000});
          ref_level = e_level[e];
          // The fetch verdicts, from the selected fields as the ITLB computed
          // them before they were formed per entry.
          ref_fetch_perm_fault = !(e_x[e] && (e_u[e] == i_fetch_priv_u));
          ref_fetch_pma_bad = e_ppn_hi_nonzero[e] ||
              !riscv_pkg::pma_fetch_ok({32'b0, ref_ppn20, 12'h000});
          ref_fetch_next_pma_bad = !riscv_pkg::pma_fetch_ok({32'b0, ref_next_ppn20, 12'h000});
        end
      end
    end
    always_ff @(posedge i_clk) begin
      assert ({o_ppn20[gp], o_device_page[gp], o_ppn_hi_nonzero[gp], o_perm_r[gp], o_perm_w[gp],
               o_perm_x[gp], o_perm_u[gp], o_perm_d[gp], o_level[gp], o_perm_ok[gp],
               o_atomic_page[gp]} ==
              {ref_ppn20, ref_device_page, ref_ppn_hi_nonzero, ref_r, ref_w, ref_x, ref_u, ref_d,
               ref_level, ref_perm_ok, ref_atomic_page});
      if (FETCH_VERDICTS) begin
        p_fetch_verdicts_exact :
        assert ({o_fetch_perm_fault[gp], o_fetch_pma_bad[gp], o_fetch_next_pma_bad[gp]} ==
                {ref_fetch_perm_fault, ref_fetch_pma_bad, ref_fetch_next_pma_bad});
      end
    end
  end
`endif

`ifdef FORMAL
  // Formal target tlb: an arbitrary watched slot holds exactly what the last
  // install wrote until the slot is overwritten or the TLB is invalidated, a
  // lookup that matches it at its level always hits, and invalidate-all
  // leaves no valid entry.
  logic f_past_valid;
  initial f_past_valid = 1'b0;
  always_ff @(posedge i_clk) f_past_valid <= 1'b1;

  initial assume (!i_rst_n);

  (* anyconst *) logic [EntryIdxBits-1:0] f_slot;
  logic f_watch_live;  // f_slot holds a tracked install
  riscv_pkg::ptw_resp_t f_watch;

  always_ff @(posedge i_clk) begin
    if (!i_rst_n || i_invalidate_all) begin
      f_watch_live <= 1'b0;
    end else if (i_install_valid && (repl_ptr_q == f_slot)) begin
      f_watch_live <= 1'b1;
      f_watch <= i_install;
    end
  end

  // Level-masked match of a lookup vpn against the watched payload.
  function automatic logic f_masked_match(input logic [riscv_pkg::Sv39VpnBits-1:0] vpn);
    unique case (f_watch.level)
      2'd2: f_masked_match = (vpn[26:18] == f_watch.vpn[26:18]);
      2'd1: f_masked_match = (vpn[26:9] == f_watch.vpn[26:9]);
      default: f_masked_match = (vpn == f_watch.vpn);
    endcase
  endfunction

  always_ff @(posedge i_clk) begin
    if (f_past_valid && i_rst_n) begin
      // Conservation: the watched slot stores exactly the tracked install.
      if (f_watch_live) begin
        p_watch_valid : assert (e_valid[f_slot]);
        p_watch_vpn : assert (e_vpn[f_slot] == f_watch.vpn);
        p_watch_level : assert (e_level[f_slot] == f_watch.level);
        p_watch_ppn : assert (e_ppn20[f_slot] == f_watch.ppn[19:0]);
        p_watch_perms :
        assert (e_r[f_slot] == f_watch.perm_r && e_w[f_slot] == f_watch.perm_w &&
                e_x[f_slot] == f_watch.perm_x && e_u[f_slot] == f_watch.perm_u &&
                e_d[f_slot] == f_watch.perm_d);
      end
      // Invalidate leaves nothing valid (and therefore nothing can hit).
      if ($past(i_invalidate_all) && $past(i_rst_n)) begin
        p_inval_clears : assert (e_valid == '0);
      end
    end
  end

  // Per-port checks aggregated into single named properties (yosys refuses
  // repeated procedural assertion labels, loops and generates included).
  logic f_watch_match_missed;  // some port masked-matches the live watch but misses
  logic f_hit_without_valid;  // some port hits with no valid entry anywhere
  always_comb begin
    f_watch_match_missed = 1'b0;
    f_hit_without_valid  = 1'b0;
    for (int p = 0; p < NUM_PORTS; p++) begin
      if (f_watch_live && f_masked_match(i_lookup_vpn[p]) && !o_hit[p]) f_watch_match_missed = 1'b1;
      if (o_hit[p] && !(|e_valid)) f_hit_without_valid = 1'b1;
    end
  end

  always_ff @(posedge i_clk) begin
    if (f_past_valid && i_rst_n) begin
      // Hit completeness: a masked match on the live watched entry hits.
      p_watch_hits : assert (!f_watch_match_missed);
      // Soundness: a hit implies some valid entry exists.
      p_hit_sound : assert (!f_hit_without_valid);
    end
  end

  // Reachability: an install that later hits, and a flash invalidate.
  always_ff @(posedge i_clk) begin
    if (f_past_valid && i_rst_n) begin
      c_watch_hit : cover (f_watch_live && o_hit[0] && f_masked_match(i_lookup_vpn[0]));
      c_super_1g : cover (f_watch_live && (f_watch.level == 2'd2) && o_hit[0]);
      c_inval : cover ($past(i_invalidate_all));
    end
  end
`endif

endmodule : dtlb
