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
 * ptw: Sv39 page-table walker.
 *
 * One walk at a time. A request latches its VPN, and the FSM descends the
 * three levels with dependent full-line reads. The production walk bridge
 * issues ReadOncePTW to the home, which probes L1D and merges dirty data.
 * A walk can observe ordered page-table stores without an sfence.vma
 * (see hw/rtl/lib/cache/README.md "The page-table walker port").
 * The PTE is extracted from the line response by the address's dword offset,
 * the way cached_tier_adapter extracts a beat.
 *
 * The walker only reads (Svade). A leaf with A=0 is a page fault instead of a
 * PTE update, and so is a store to a leaf with D=0, which the data MMU checks
 * at lookup. Nothing in the fabric writes PTEs.
 *
 * Walk faults, in the order they are found:
 *   - a PTE address outside the cached-DDR window => DFAULT_ACCESS, which
 *     the requester turns into the access fault of the original access type.
 *     Page tables must be in cached DDR because the walk path cannot reach
 *     uncached memory or devices. With ENABLE_RESPONSE_ERRORS, a failed
 *     PTE read also returns DFAULT_ACCESS without interpreting its data.
 *   - reserved bits, V=0, W&!R, a non-leaf with D, A, or U set, a non-leaf
 *     at level 0, a misaligned superpage, or A=0 => DFAULT_PAGE.
 * A clean leaf answers DFAULT_NONE with {ppn, level, RWXUD} and echoes the
 * VPN. The requesting MMU checks permissions at lookup, because SUM, MXR, and
 * the effective privilege are live CSR state, not walk state.
 *
 * i_discard (SFENCE.VMA, a satp access, or an mstatus write that changes MPRV,
 * or MPP under MPRV) poisons the walk in flight: every outstanding line read
 * is still consumed, but no response fires. That keeps a translation read from
 * the old page tables from installing after the invalidate. The requester's
 * own pipeline flushes do not discard: a walk for a killed instruction still
 * returns a correct translation, and the VPN echo keeps a late fault from
 * landing on the wrong instruction.
 *
 * satp.PPN may name any 44-bit root. The same address check refuses a bad root
 * pointer before the walk's first read and a bad interior pointer before the
 * next level's read.
 *
 * Walk cache. Two small fully associative arrays hold upper-level pointers:
 * PWC_L1_ENTRIES level-1 pointers tagged by VPN[26:9] (the level-0 table for
 * a 2 MiB region) and PWC_ROOT_ENTRIES root pointers tagged by VPN[26:18]
 * (the level-1 table for a 1 GiB region). A walk spends two registered cycles
 * (PTW_PWC compares the tags, PTW_PWC_SEL selects the pointer) looking both
 * up, then starts at level 0 on a level-1 hit, at
 * level 1 on a root hit, and at the root otherwise, so a hit saves two or one
 * dependent line reads. Only a pointer that the walk descended through fills
 * an entry: a valid non-leaf PTE with no reserved bits, at an address the
 * cached-DDR check accepts, read by a walk that was not poisoned. Invalid and
 * faulting PTEs never fill, so a PTE changed from invalid to valid is seen by
 * the next walk without sfence.vma (Svvptc). Leaves are never cached here.
 * i_discard clears both arrays, as SFENCE.VMA and satp accesses require; a
 * valid pointer changed in memory is seen after the next SFENCE.VMA, which
 * the privileged spec requires software to execute. Fills happen only on a
 * miss of the same tag, so each tag occupies at most one entry; replacement
 * is round robin. The cache sits entirely on the miss path: the TLB lookups
 * and the request handshake are unchanged. Zero entries disable an array;
 * with both zero the walker issues its first read straight from idle.
 */
module ptw #(
    parameter bit ENABLE_RESPONSE_ERRORS = 1'b0,
    parameter int unsigned LINE_BYTES = 32,
    parameter int unsigned WALK_ID_BITS = 2,
    parameter int unsigned PWC_L1_ENTRIES = 16,
    parameter int unsigned PWC_ROOT_ENTRIES = 4,
    localparam int unsigned LineAddrLow = $clog2(LINE_BYTES)
) (
`ifdef COH_MAINT_OWNED
    output logic [                       2:0] o_maint_state,
    output logic [riscv_pkg::Sv39VpnBits-1:0] o_maint_vpn,
    output logic                              o_maint_error,
    output logic                              o_maint_poison,
`endif
    input  logic                              i_clk,
    input  logic                              i_rst,
    // Root PPN, sampled at walk start. Committed satp access also raises
    // i_discard, preventing an older walk from answering across the change.
    input  logic [ riscv_pkg::PtePpnBits-1:0] i_root_ppn,
    // Walk request. Ready is a level: the FSM is idle and no discard is
    // arriving. The walker loads the request payload on every idle edge, so a
    // requester may change or withdraw a request that has not fired.
    input  logic                              i_req_valid,
    output logic                              o_req_ready,
    input  logic [riscv_pkg::Sv39VpnBits-1:0] i_req_vpn,
    // Poison the walk in flight (and any response about to fire).
    input  logic                              i_discard,

    // A walk is in progress (the FSM is not idle), for the HPM walk-busy
    // event. Registered state only.
    output logic o_busy,

    // One-cycle response pulse.
    output logic                                               o_resp_valid,
    output riscv_pkg::ptw_resp_t                               o_resp,
    // Line port (master, read-only): to the hierarchy's wup port.
    output logic                                               o_line_req_valid,
    input  logic                                               i_line_req_ready,
    output logic                 [riscv_pkg::PhysAddrBits-1:0] o_line_req_addr,
    output logic                 [           WALK_ID_BITS-1:0] o_line_req_id,
    input  logic                                               i_line_resp_valid,
    input  logic                                               i_line_resp_error = 1'b0,
    input  logic                 [           WALK_ID_BITS-1:0] i_line_resp_id,
    input  logic                 [           LINE_BYTES*8-1:0] i_line_resp_rdata
);
`ifndef SYNTHESIS
  logic reset_seen_q = 1'b0;
  always_ff @(posedge i_clk) if (i_rst) reset_seen_q <= 1'b1;
`endif
  // ---------------------------------------------------------------------------
  // Walk state
  // ---------------------------------------------------------------------------
  typedef enum logic [2:0] {
    PTW_IDLE,    // no walk; accept a request
    PTW_ISSUE,   // present the current level's line read until it fires
    PTW_WAIT,    // wait for the line response; capture this level's PTE
    PTW_DECODE,  // classify the captured PTE: answer, or descend a level
    PTW_RESP,    // fire the response pulse (one cycle)
    PTW_PWC,     // compare the walk cache tags with the VPN
    PTW_PWC_SEL  // apply the registered match: choose the starting level
  } ptw_state_e;
  ptw_state_e state_q;
  logic [riscv_pkg::Sv39VpnBits-1:0] vpn_q;
  logic [1:0] level_q;  // 2 -> 1 -> 0
  logic [riscv_pkg::PtePpnBits-1:0] ptr_ppn_q;  // current table's PPN
  logic discard_q;  // walk poisoned; consume the read, answer nothing
  riscv_pkg::ptw_resp_t resp_q;
  // ---------------------------------------------------------------------------
  // Current PTE address and its PMA check
  // ---------------------------------------------------------------------------
  // pte_pa = {ptr_ppn, 12'h000} + (vpn[level] << 3), a 56-bit quantity.
  // Retain the full PPN until the configured cached-DDR range accepts it.
  logic [8:0] vpn_field;
  always_comb begin
    unique case (level_q)
      2'd2:    vpn_field = vpn_q[26:18];
      2'd1:    vpn_field = vpn_q[17:9];
      default: vpn_field = vpn_q[8:0];
    endcase
  end
  logic [riscv_pkg::PtePpnBits+11:0] pte_pa;
  assign pte_pa = {ptr_ppn_q, 12'h000} | {{riscv_pkg::PtePpnBits{1'b0}}, vpn_field, 3'b000};
  logic pte_addr_ok;
  assign pte_addr_ok = riscv_pkg::pma_cached_ok(riscv_pkg::XLEN'(pte_pa));
  // Register the address check with ptr_ppn_q, for timing. VPN changes only
  // PA[11:3], so the range check depends solely on the table PPN.
  logic ptr_addr_ok_q;
  function automatic logic ppn_addr_ok(input logic [riscv_pkg::PtePpnBits-1:0] ppn);
    // Assign-to-name form: Yosys (read -formal) rejects return expressions.
    begin
      ppn_addr_ok = riscv_pkg::pma_cached_ok({8'b0, ppn, 12'h000});
    end
  endfunction
  // ---------------------------------------------------------------------------
  // Line request (read-only, single id, one walk in flight)
  // ---------------------------------------------------------------------------
  // A poisoned walk issues no further reads. Unaccepted requests may be
  // withdrawn because the walk path changes state only on acceptance.
  // An outstanding read is still consumed in PTW_WAIT.
  //
  // Registered valid equals PTW_ISSUE && ptr_addr_ok_q && !discard_q. It is not
  // gated by live i_discard, for timing. A read accepted in the discard cycle
  // is poisoned at that edge; consume its response without answering.
  (* keep = "true" *) logic line_req_valid_q;
  assign o_line_req_valid = line_req_valid_q;
  assign o_line_req_addr = {pte_pa[riscv_pkg::PhysAddrBits-1:LineAddrLow], {LineAddrLow{1'b0}}};
  assign o_line_req_id = '0;
  // PTE extraction: dword index inside the line, captured at issue.
  localparam int unsigned PteSelBits = LineAddrLow - 3;
  logic [PteSelBits-1:0] pte_dword_sel_q;
  // Register the selected PTE before classification, for timing. This adds
  // one cycle per walk level.
  logic [63:0] pte_live, pte_q, pte;
  assign pte_live = i_line_resp_rdata[pte_dword_sel_q*64+:64];
  assign pte = pte_q;
  // ---------------------------------------------------------------------------
  // PTE checks
  // ---------------------------------------------------------------------------
  logic pte_v, pte_r, pte_w, pte_x, pte_u, pte_a, pte_d;
  logic [riscv_pkg::PtePpnBits-1:0] pte_ppn;
  assign pte_v   = pte[riscv_pkg::PteFlagV];
  assign pte_r   = pte[riscv_pkg::PteFlagR];
  assign pte_w   = pte[riscv_pkg::PteFlagW];
  assign pte_x   = pte[riscv_pkg::PteFlagX];
  assign pte_u   = pte[riscv_pkg::PteFlagU];
  assign pte_a   = pte[riscv_pkg::PteFlagA];
  assign pte_d   = pte[riscv_pkg::PteFlagD];
  assign pte_ppn = pte[53:10];
  logic pte_reserved_bad;  // bits 63:54 must be zero (no Svnapot/Svpbmt)
  assign pte_reserved_bad = |pte[63:54];
  logic pte_is_leaf;
  assign pte_is_leaf = pte_r || pte_x;
  // V=0, the reserved W&!R encoding, or a non-leaf with D, A, or U set. The
  // privileged spec reserves those three bits in a non-leaf PTE, and a walk
  // that finds a reserved bit set raises a page fault.
  logic pte_invalid;
  assign pte_invalid = !pte_v || (!pte_r && pte_w) || (!pte_is_leaf && (pte_d || pte_a || pte_u));
  logic superpage_misaligned;
  always_comb begin
    unique case (level_q)
      2'd2:    superpage_misaligned = |pte_ppn[17:0];
      2'd1:    superpage_misaligned = |pte_ppn[8:0];
      default: superpage_misaligned = 1'b0;
    endcase
  end
  // ---------------------------------------------------------------------------
  // Walk cache (upper-level pointers)
  // ---------------------------------------------------------------------------
  // Entries keep the configured physical PPN width. A pointer with nonzero
  // bits above it is never cached; the cached-DDR window lies below it.
  localparam bit PwcEnabled = (PWC_L1_ENTRIES != 0) || (PWC_ROOT_ENTRIES != 0);
  localparam int unsigned PwcL1N = (PWC_L1_ENTRIES != 0) ? PWC_L1_ENTRIES : 1;
  localparam int unsigned PwcRootN = (PWC_ROOT_ENTRIES != 0) ? PWC_ROOT_ENTRIES : 1;
  localparam int unsigned PwcL1IdxBits = (PwcL1N > 1) ? $clog2(PwcL1N) : 1;
  localparam int unsigned PwcRootIdxBits = (PwcRootN > 1) ? $clog2(PwcRootN) : 1;
  localparam int unsigned PwcPpnBits = riscv_pkg::PhysAddrBits - 12;

  logic [PwcL1N-1:0] pwc_l1_valid_q;
  logic [17:0] pwc_l1_tag_q[PwcL1N];  // VPN[26:9]
  logic [PwcPpnBits-1:0] pwc_l1_ppn_q[PwcL1N];  // the level-0 table
  logic [PwcL1IdxBits-1:0] pwc_l1_repl_q;
  logic [PwcRootN-1:0] pwc_root_valid_q;
  logic [8:0] pwc_root_tag_q[PwcRootN];  // VPN[26:18]
  logic [PwcPpnBits-1:0] pwc_root_ppn_q[PwcRootN];  // the level-1 table
  logic [PwcRootIdxBits-1:0] pwc_root_repl_q;
  // G accumulated from the pointers above (a G on a non-leaf PTE makes every
  // mapping below it global); a hit resumes the walk with it.
  logic [PwcL1N-1:0] pwc_l1_g_q;
  logic [PwcRootN-1:0] pwc_root_g_q;
  logic g_acc_q;

  // Lookup in two registered steps, for timing: PTW_PWC compares the tags
  // with the registered VPN and registers the one-hot match; PTW_PWC_SEL
  // reduces it and selects the pointer with an AND-OR mux. Neither the VPN
  // nor the arrays change between the two (no walk fills, and a discard ends
  // the walk), so the registered match describes the arrays SEL reads.
  logic [PwcL1N-1:0] pwc_l1_match_c, pwc_l1_match_q;
  logic [PwcRootN-1:0] pwc_root_match_c, pwc_root_match_q;
  logic pwc_l1_hit, pwc_root_hit;
  logic [PwcPpnBits-1:0] pwc_l1_ppn, pwc_root_ppn;
  logic pwc_l1_g, pwc_root_g;
  always_comb begin
    for (int e = 0; e < PwcL1N; e++) begin
      pwc_l1_match_c[e] = (PWC_L1_ENTRIES != 0) && pwc_l1_valid_q[e] &&
          (pwc_l1_tag_q[e] == vpn_q[26:9]);
    end
    for (int e = 0; e < PwcRootN; e++) begin
      pwc_root_match_c[e] = (PWC_ROOT_ENTRIES != 0) && pwc_root_valid_q[e] &&
          (pwc_root_tag_q[e] == vpn_q[26:18]);
    end
  end
  always_ff @(posedge i_clk) begin
    pwc_l1_match_q   <= pwc_l1_match_c;
    pwc_root_match_q <= pwc_root_match_c;
  end
  always_comb begin
    pwc_l1_ppn   = '0;
    pwc_root_ppn = '0;
    pwc_l1_g     = 1'b0;
    pwc_root_g   = 1'b0;
    for (int e = 0; e < PwcL1N; e++) begin
      pwc_l1_ppn |= {PwcPpnBits{pwc_l1_match_q[e]}} & pwc_l1_ppn_q[e];
      pwc_l1_g |= pwc_l1_match_q[e] & pwc_l1_g_q[e];
    end
    for (int e = 0; e < PwcRootN; e++) begin
      pwc_root_ppn |= {PwcPpnBits{pwc_root_match_q[e]}} & pwc_root_ppn_q[e];
      pwc_root_g |= pwc_root_match_q[e] & pwc_root_g_q[e];
    end
  end
  assign pwc_l1_hit   = |pwc_l1_match_q;
  assign pwc_root_hit = |pwc_root_match_q;

  // Fill when a walk that is not poisoned descends through a pointer: the
  // pointer read at level 2 into the root array, at level 1 into the level-1
  // array. PTW_DECODE records the descent (pwc_*_sel_q); the fill lands
  // on the next edge, from the registered pointer and its registered address
  // check, for timing. The pointer passed the reference classification and
  // the address check, which is why PTW_PWC_SEL may set ptr_addr_ok_q for a
  // hit. A discard on either cycle cancels the fill: it clears the valid
  // bits with priority. PTW_DECODE registers the target entry one-hot
  // (pwc_*_sel_q) with the pointer's address and high-bit checks, so each
  // entry's write enable is a register, for timing. A select is set only
  // when no discard is pending, and a discard in the fill cycle clears the
  // valid bits with priority, so a cancelled write leaves an invalid entry.
  logic [  PwcL1N-1:0] pwc_l1_sel_q;
  logic [PwcRootN-1:0] pwc_root_sel_q;
  logic pwc_fill_root, pwc_fill_l1;
  assign pwc_fill_l1   = |pwc_l1_sel_q;
  assign pwc_fill_root = |pwc_root_sel_q;

  always_ff @(posedge i_clk) begin
    if (i_rst || i_discard) begin
      pwc_l1_valid_q   <= '0;
      pwc_root_valid_q <= '0;
    end else begin
      pwc_l1_valid_q   <= pwc_l1_valid_q | pwc_l1_sel_q;
      pwc_root_valid_q <= pwc_root_valid_q | pwc_root_sel_q;
    end
  end

  always_ff @(posedge i_clk) begin
    for (int e = 0; e < PwcL1N; e++) begin
      if (pwc_l1_sel_q[e]) begin
        pwc_l1_tag_q[e] <= vpn_q[26:9];
        pwc_l1_ppn_q[e] <= ptr_ppn_q[PwcPpnBits-1:0];
        pwc_l1_g_q[e]   <= g_acc_q;
      end
    end
    for (int e = 0; e < PwcRootN; e++) begin
      if (pwc_root_sel_q[e]) begin
        pwc_root_tag_q[e] <= vpn_q[26:18];
        pwc_root_ppn_q[e] <= ptr_ppn_q[PwcPpnBits-1:0];
        pwc_root_g_q[e]   <= g_acc_q;
      end
    end
    if (i_rst) begin
      pwc_l1_repl_q   <= '0;
      pwc_root_repl_q <= '0;
    end else begin
      if (pwc_fill_l1)
        pwc_l1_repl_q <= (32'(pwc_l1_repl_q) == PwcL1N - 1) ? '0 : pwc_l1_repl_q + 1'b1;
      if (pwc_fill_root)
        pwc_root_repl_q <= (32'(pwc_root_repl_q) == PwcRootN - 1) ? '0 : pwc_root_repl_q + 1'b1;
    end
  end

  // ---------------------------------------------------------------------------
  // FSM
  // ---------------------------------------------------------------------------
  assign o_req_ready = (state_q == PTW_IDLE) && !i_discard;
  assign o_resp_valid = (state_q == PTW_RESP) && !discard_q && !i_discard;
  assign o_resp = resp_q;
  assign o_busy = (state_q != PTW_IDLE);

  // Capture the selected PTE on every cycle in PTW_WAIT: the response cycle
  // is the last one, so PTW_DECODE sees the response's PTE. The enable is a
  // state decode only, for timing.
  always_ff @(posedge i_clk) begin
    if (state_q == PTW_WAIT) pte_q <= pte_live;
  end

  // PTW_DECODE descends through a pointer: select the entry that the fill
  // writes on the next edge (PTW_ISSUE always follows a descent).
  logic pwc_descend;
  assign pwc_descend = (state_q == PTW_DECODE) && !discard_q && !i_discard &&
      !pte_reserved_bad && !pte_invalid && !pte_is_leaf && (level_q != 2'd0) &&
      ppn_addr_ok(
      pte_ppn
  ) && !(|pte_ppn[riscv_pkg::PtePpnBits-1:PwcPpnBits]);
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      pwc_l1_sel_q   <= '0;
      pwc_root_sel_q <= '0;
    end else begin
      for (int e = 0; e < PwcL1N; e++) begin
        pwc_l1_sel_q[e] <= pwc_descend && (level_q == 2'd1) && (PWC_L1_ENTRIES != 0) &&
            (32'(pwc_l1_repl_q) == e);
      end
      for (int e = 0; e < PwcRootN; e++) begin
        pwc_root_sel_q[e] <= pwc_descend && (level_q == 2'd2) && (PWC_ROOT_ENTRIES != 0) &&
            (32'(pwc_root_repl_q) == e);
      end
    end
  end

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      state_q <= PTW_IDLE;
      discard_q <= 1'b0;
      line_req_valid_q <= 1'b0;
    end else begin
      if (i_discard) discard_q <= 1'b1;
      // Only entry into ISSUE or a held ISSUE can present a read next cycle.
      line_req_valid_q <= 1'b0;
      unique case (state_q)
        PTW_IDLE: begin
          discard_q     <= 1'b0;
          // Sample payload on every idle edge. It is unused until a request fires,
          // whose accepting edge captures the requested VPN and root.
          vpn_q         <= i_req_vpn;
          level_q       <= 2'd2;
          g_acc_q       <= 1'b0;
          ptr_ppn_q     <= i_root_ppn;
          ptr_addr_ok_q <= ppn_addr_ok(i_root_ppn);
          if (i_req_valid && !i_discard) begin
            if (PwcEnabled) begin
              state_q <= PTW_PWC;
            end else begin
              state_q <= PTW_ISSUE;
              line_req_valid_q <= ppn_addr_ok(i_root_ppn);
            end
          end
        end

        PTW_PWC: begin
          // vpn_q, the root and its address check were captured on accept;
          // the tag compare registers this cycle. A discard ends the walk
          // before any read; the arrays clear on the same edge.
          state_q <= (discard_q || i_discard) ? PTW_IDLE : PTW_PWC_SEL;
        end

        PTW_PWC_SEL: begin
          // A discard now ends the walk too, so no match registered before
          // it is used.
          if (discard_q || i_discard) begin
            state_q <= PTW_IDLE;
          end else begin
            state_q <= PTW_ISSUE;
            if (pwc_l1_hit) begin
              ptr_ppn_q        <= riscv_pkg::PtePpnBits'(pwc_l1_ppn);
              ptr_addr_ok_q    <= 1'b1;
              level_q          <= 2'd0;
              g_acc_q          <= pwc_l1_g;
              line_req_valid_q <= 1'b1;
            end else if (pwc_root_hit) begin
              ptr_ppn_q        <= riscv_pkg::PtePpnBits'(pwc_root_ppn);
              ptr_addr_ok_q    <= 1'b1;
              level_q          <= 2'd1;
              g_acc_q          <= pwc_root_g;
              line_req_valid_q <= 1'b1;
            end else begin
              line_req_valid_q <= ptr_addr_ok_q;
            end
          end
        end
        PTW_ISSUE: begin
          line_req_valid_q <= ptr_addr_ok_q && !discard_q && !i_discard && !i_line_req_ready;
          // A walk poisoned on an earlier cycle has nothing in flight and
          // ends here. A discard arriving this cycle cannot stop a read that
          // fires now, because the presented valid is registered: the walk
          // continues into PTW_WAIT poisoned, consumes its response, and
          // answers nothing.
          if (discard_q) begin
            state_q <= PTW_IDLE;
          end else if (!ptr_addr_ok_q) begin
            // A bad PTE address never issues a read: answer DFAULT_ACCESS here.
            resp_q            <= '0;
            resp_q.fault_kind <= riscv_pkg::DFAULT_ACCESS;
            resp_q.vpn        <= vpn_q;
            state_q           <= PTW_RESP;
          end else if (i_line_req_ready) begin
            pte_dword_sel_q <= pte_pa[LineAddrLow-1:3];
            state_q         <= PTW_WAIT;
          end
        end
        PTW_WAIT: begin
          if (i_line_resp_valid) begin
            // Single-id master with one read in flight, so any response
            // belongs to this walk. Capture this level's PTE; PTW_DECODE
            // classifies it.
            if (ENABLE_RESPONSE_ERRORS && i_line_resp_error) begin
              resp_q <= '0;
              resp_q.fault_kind <= riscv_pkg::DFAULT_ACCESS;
              resp_q.vpn <= vpn_q;
              state_q <= PTW_RESP;
            end else begin
              state_q <= PTW_DECODE;
            end
          end
        end
        PTW_DECODE: begin
          begin
            resp_q     <= '0;
            resp_q.vpn <= vpn_q;
            if (pte_reserved_bad || pte_invalid) begin
              resp_q.fault_kind <= riscv_pkg::DFAULT_PAGE;
              state_q           <= PTW_RESP;
            end else if (pte_is_leaf) begin
              if (superpage_misaligned || !pte_a) begin
                resp_q.fault_kind <= riscv_pkg::DFAULT_PAGE;
              end else begin
                resp_q.fault_kind <= riscv_pkg::DFAULT_NONE;
                resp_q.ppn        <= pte_ppn;
                resp_q.level      <= level_q;
                resp_q.perm_r     <= pte_r;
                resp_q.perm_w     <= pte_w;
                resp_q.perm_x     <= pte_x;
                resp_q.perm_u     <= pte_u;
                resp_q.perm_d     <= pte_d;
                resp_q.perm_g     <= g_acc_q || pte[riscv_pkg::PteFlagG];
              end
              state_q <= PTW_RESP;
            end else if (level_q == 2'd0) begin
              // Non-leaf at the last level: no level below it.
              resp_q.fault_kind <= riscv_pkg::DFAULT_PAGE;
              state_q           <= PTW_RESP;
            end else begin
              ptr_ppn_q <= pte_ppn;
              ptr_addr_ok_q <= ppn_addr_ok(pte_ppn);
              g_acc_q <= g_acc_q || pte[riscv_pkg::PteFlagG];
              level_q <= level_q - 2'd1;
              state_q <= PTW_ISSUE;
              line_req_valid_q <= ppn_addr_ok(pte_ppn) && !discard_q && !i_discard;
            end
          end
        end
        PTW_RESP: begin
          // One-cycle pulse, suppressed when poisoned.
          state_q <= PTW_IDLE;
        end
        default: state_q <= PTW_IDLE;
      endcase
    end
  end
`ifndef SYNTHESIS
  // Check the registered valid against its state-derived reference, including
  // a cycle in which a live discard coincides with a legal final request fire.
  always_ff @(posedge i_clk) begin
    if (reset_seen_q && !i_rst) begin
      p_line_req_valid_twin_exact :
      assert (o_line_req_valid == ((state_q == PTW_ISSUE) && ptr_addr_ok_q && !discard_q));
    end
  end
`endif
`ifndef SYNTHESIS
`ifndef FORMAL
  // ptr_addr_ok_q equals the live address check in every cycle the FSM uses it
  // (PTW_ISSUE).
  always_ff @(posedge i_clk) begin
    if (reset_seen_q && !i_rst && (state_q == PTW_ISSUE)) begin
      p_ptr_addr_ok_twin_exact : assert (ptr_addr_ok_q == pte_addr_ok);
    end
  end
`endif
`endif
`ifndef SYNTHESIS
`ifndef FORMAL
  // A response while idle, or a second response mid-walk, means the port
  // delivered something this walker never asked for.
  always_ff @(posedge i_clk) begin
    if (reset_seen_q && !i_rst && i_line_resp_valid && (state_q != PTW_WAIT))
      $error("ptw: line response in state %0d (id=%0d)", state_q, i_line_resp_id);
  end
`endif
`endif
`ifdef FORMAL
  // Compare PTE classification with a reference. The line port may respond
  // only while a read is outstanding.
  logic f_past_valid;
  initial f_past_valid = 1'b0;
  always_ff @(posedge i_clk) f_past_valid <= 1'b1;
  initial assume (i_rst);
  logic f_outstanding;  // a line read has fired and not yet answered
  always_ff @(posedge i_clk) begin
    if (i_rst) f_outstanding <= 1'b0;
    else if (o_line_req_valid && i_line_req_ready) f_outstanding <= 1'b1;
    else if (i_line_resp_valid) f_outstanding <= 1'b0;
  end
  always_comb if (i_line_resp_valid) assume (f_outstanding);
  // Request bookkeeping: the accepted VPN, and the last PTE read and its level.
  logic [riscv_pkg::Sv39VpnBits-1:0] f_req_vpn;
  always_ff @(posedge i_clk) begin
    if (i_req_valid && o_req_ready) f_req_vpn <= i_req_vpn;
  end
  logic [63:0] f_pte;
  logic [1:0] f_level;
  logic f_pte_seen;
  always_ff @(posedge i_clk) begin
    if (i_rst) f_pte_seen <= 1'b0;
    else if ((state_q == PTW_WAIT) && i_line_resp_valid) begin
      f_pte <= pte_live;
      f_level <= level_q;
      f_pte_seen <= 1'b1;
    end else if (state_q == PTW_IDLE) f_pte_seen <= 1'b0;
  end
  // Reference classification of the last PTE read.
  logic f_g_reserved, f_g_invalid, f_g_leaf, f_g_misaligned, f_g_a0;
  always_comb begin
    f_g_reserved = |f_pte[63:54];
    f_g_leaf = f_pte[1] || f_pte[3];
    // D (7), A (6), and U (4) are reserved in a non-leaf PTE.
    f_g_invalid = !f_pte[0] || (!f_pte[1] && f_pte[2]) ||
                  (!f_g_leaf && (f_pte[7] || f_pte[6] || f_pte[4]));
    unique case (f_level)
      2'd2: f_g_misaligned = |f_pte[27:10];
      2'd1: f_g_misaligned = |f_pte[18:10];
      default: f_g_misaligned = 1'b0;
    endcase
    f_g_a0 = !f_pte[6];
  end
  always_ff @(posedge i_clk) begin
    if (f_past_valid && !i_rst) begin
      // Ready rises only in idle, no read is presented while one is
      // outstanding, and every presented read targets cached DDR.
      p_ready_idle : assert (!o_req_ready || (state_q == PTW_IDLE));
      p_single_read : assert (!(o_line_req_valid && f_outstanding));
      if (o_line_req_valid)
        p_read_in_ddr : assert (riscv_pkg::pma_cached_ok(riscv_pkg::XLEN'(o_line_req_addr)));
      // A poisoned walk never answers.
      if (discard_q || i_discard) p_discard_silent : assert (!o_resp_valid);
      // A walk descends only through a pointer the reference classification
      // accepts. DECODE moves to ISSUE only to descend, and f_pte still holds
      // the PTE that DECODE classified.
      if (!$past(i_rst) && ($past(state_q) == PTW_DECODE) && (state_q == PTW_ISSUE)) begin
        p_descend_valid_pointer :
        assert (f_pte_seen && !f_g_reserved && !f_g_invalid && !f_g_leaf && (f_level != 2'd0));
      end
      // Response contents against the reference classification.
      if (o_resp_valid) begin
        p_resp_vpn_echo : assert (o_resp.vpn == f_req_vpn);
        if (o_resp.fault_kind == riscv_pkg::DFAULT_NONE) begin
          p_ok_is_clean_leaf :
          assert (f_pte_seen && !f_g_reserved && !f_g_invalid && f_g_leaf &&
                  !f_g_misaligned && !f_g_a0);
          p_ok_payload :
          assert (o_resp.ppn == f_pte[53:10] && o_resp.level == f_level &&
                  o_resp.perm_r == f_pte[1] && o_resp.perm_w == f_pte[2] &&
                  o_resp.perm_x == f_pte[3] && o_resp.perm_u == f_pte[4] &&
                  o_resp.perm_d == f_pte[7]);
        end
        if (o_resp.fault_kind == riscv_pkg::DFAULT_PAGE) begin
          p_page_has_reason :
          assert (f_pte_seen && (f_g_reserved || f_g_invalid ||
                                 (f_g_leaf && (f_g_misaligned || f_g_a0)) ||
                                 (!f_g_leaf && (f_level == 2'd0))));
        end
        // ACCESS needs no PTE: the pointer address was refused.
        p_no_misalign_kind : assert (o_resp.fault_kind != riscv_pkg::DFAULT_MISALIGN);
      end
    end
  end
  always_ff @(posedge i_clk) begin
    if (f_past_valid && !i_rst) begin
      c_ok_1g :
      cover (o_resp_valid && o_resp.fault_kind == riscv_pkg::DFAULT_NONE && o_resp.level == 2'd2);
      c_ok_4k :
      cover (o_resp_valid && o_resp.fault_kind == riscv_pkg::DFAULT_NONE && o_resp.level == 2'd0);
      c_page : cover (o_resp_valid && o_resp.fault_kind == riscv_pkg::DFAULT_PAGE);
      c_access : cover (o_resp_valid && o_resp.fault_kind == riscv_pkg::DFAULT_ACCESS);
      c_discarded_walk : cover ($past(discard_q) && (state_q == PTW_IDLE));
    end
  end

  // Walk cache. The line port answers reads of one watched line with fixed
  // data (an arbitrary but stable memory line). Every cached pointer read
  // from that line must equal the pointer the line holds and be a valid
  // non-leaf PTE: the cache never returns an invalid PTE or a value memory
  // does not hold. The other properties: a discard empties the cache, only a
  // walk accepted after the last discard fills it, a fill is a pointer the
  // reference classification accepts at the walk's level, each tag occupies
  // at most one entry, and a hit starts the walk at the level below with the
  // cached table.
  (* anyconst *) logic [riscv_pkg::PhysAddrBits-1:0] f_watch_line;
  (* anyconst *) logic [LINE_BYTES*8-1:0] f_watch_data;
  logic [riscv_pkg::PhysAddrBits-1:0] f_read_addr;
  always_ff @(posedge i_clk) begin
    if (o_line_req_valid && i_line_req_ready) f_read_addr <= o_line_req_addr;
  end
  always_comb begin
    if (i_line_resp_valid && (f_read_addr == f_watch_line))
      assume (i_line_resp_rdata == f_watch_data);
    assume (f_watch_line[LineAddrLow-1:0] == '0);
  end

  logic f_discard_since_accept;
  always_ff @(posedge i_clk) begin
    if (i_rst || i_discard) f_discard_since_accept <= 1'b1;
    else if (i_req_valid && o_req_ready) f_discard_since_accept <= 1'b0;
  end

  // The PTE address each entry was filled from: the address PTW_DECODE
  // classified, one cycle before the fill.
  logic [riscv_pkg::PhysAddrBits-1:0] f_decode_src_q;
  logic [riscv_pkg::PhysAddrBits-1:0] f_l1_src[PwcL1N];
  logic [riscv_pkg::PhysAddrBits-1:0] f_root_src[PwcRootN];
  always_ff @(posedge i_clk) begin
    if (state_q == PTW_DECODE) f_decode_src_q <= pte_pa[riscv_pkg::PhysAddrBits-1:0];
    if (pwc_fill_l1 && !i_rst) f_l1_src[pwc_l1_repl_q] <= f_decode_src_q;
    if (pwc_fill_root && !i_rst) f_root_src[pwc_root_repl_q] <= f_decode_src_q;
  end

  function automatic logic [63:0] f_watched_pte(input logic [riscv_pkg::PhysAddrBits-1:0] pa);
    begin
      f_watched_pte = f_watch_data[pa[LineAddrLow-1:3]*64+:64];
    end
  endfunction
  function automatic logic f_valid_pointer(input logic [63:0] p);
    begin
      f_valid_pointer = p[0] && !p[1] && !p[2] && !p[3] && !p[4] && !p[6] && !p[7] && !(|p[63:54]);
    end
  endfunction

  // Independent walk-address reference. Shadow entries are populated from
  // the accepted request and the response line's independently selected PTE,
  // rather than the DUT's VPN, pointer mux, level, or selected PTE register.
  // Every issued read must follow this root-to-leaf path. This also checks
  // the tag association and mux selection of a cached pointer.
  logic [17:0] f_l1_tag  [  PwcL1N];
  logic [ 8:0] f_root_tag[PwcRootN];
  logic [riscv_pkg::PtePpnBits-1:0] f_l1_pointer[PwcL1N], f_root_pointer[PwcRootN];
  logic [riscv_pkg::PtePpnBits-1:0] f_start_table, f_table_q;
  logic [1:0] f_start_level, f_ref_level_q;
  logic [riscv_pkg::PtePpnBits+11:0] f_ref_pa, f_last_pa_q;
  logic [8:0] f_ref_index;
  logic [63:0] f_ref_pte, f_last_pte_q;
  logic f_context_valid_q;
  logic [riscv_pkg::PtePpnBits-1:0] f_context_root_q;
  logic f_replaced_l1_q, f_replaced_root_q;

  always_comb begin
    f_start_table = i_root_ppn;
    f_start_level = 2'd2;
    for (int e = 0; e < PwcRootN; e++) begin
      if ((PWC_ROOT_ENTRIES != 0) && pwc_root_valid_q[e] &&
          (f_root_tag[e] == i_req_vpn[26:18])) begin
        f_start_table = f_root_pointer[e];
        f_start_level = 2'd1;
      end
    end
    for (int e = 0; e < PwcL1N; e++) begin
      if ((PWC_L1_ENTRIES != 0) && pwc_l1_valid_q[e] && (f_l1_tag[e] == i_req_vpn[26:9])) begin
        f_start_table = f_l1_pointer[e];
        f_start_level = 2'd0;
      end
    end
    case (f_ref_level_q)
      2'd2: f_ref_index = f_req_vpn[26:18];
      2'd1: f_ref_index = f_req_vpn[17:9];
      default: f_ref_index = f_req_vpn[8:0];
    endcase
    f_ref_pa  = {f_table_q, 12'b0} + {{riscv_pkg::PtePpnBits{1'b0}}, f_ref_index, 3'b0};
    f_ref_pte = i_line_resp_rdata[f_ref_pa[LineAddrLow-1:3]*64+:64];
  end

  always_ff @(posedge i_clk) begin
    if (i_rst || i_discard) f_context_valid_q <= 1'b0;
    else if (i_req_valid && o_req_ready) begin
      // The port contract requires a satp/root change to discard cached
      // translations. Root values may otherwise vary between idle cycles.
      if (f_context_valid_q) assume (i_root_ppn == f_context_root_q);
      f_context_valid_q <= 1'b1;
      f_context_root_q  <= i_root_ppn;
    end
    if (i_req_valid && o_req_ready) begin
      f_table_q <= f_start_table;
      f_ref_level_q <= f_start_level;
    end else if (i_line_resp_valid && f_outstanding) begin
      f_last_pa_q <= f_ref_pa;
      f_last_pte_q <= f_ref_pte;
      f_table_q <= f_ref_pte[53:10];
      if (f_ref_level_q != 0) f_ref_level_q <= f_ref_level_q - 1'b1;
    end
    for (int e = 0; e < PwcL1N; e++) begin
      if (pwc_l1_sel_q[e]) begin
        f_l1_tag[e] <= f_req_vpn[26:9];
        f_l1_pointer[e] <= f_last_pte_q[53:10];
      end
    end
    for (int e = 0; e < PwcRootN; e++) begin
      if (pwc_root_sel_q[e]) begin
        f_root_tag[e] <= f_req_vpn[26:18];
        f_root_pointer[e] <= f_last_pte_q[53:10];
      end
    end
    if (i_rst) begin
      f_replaced_l1_q   <= 1'b0;
      f_replaced_root_q <= 1'b0;
    end else begin
      if (!i_discard && |(pwc_l1_sel_q & pwc_l1_valid_q)) f_replaced_l1_q <= 1'b1;
      if (!i_discard && |(pwc_root_sel_q & pwc_root_valid_q)) f_replaced_root_q <= 1'b1;
    end
  end

  always_ff @(posedge i_clk) begin
    if (f_past_valid && !i_rst) begin
      if (o_line_req_valid) begin
        p_cached_read_level : assert (level_q == f_ref_level_q);
        p_cached_read_address :
        assert (o_line_req_addr ==
                {f_ref_pa[riscv_pkg::PhysAddrBits-1:LineAddrLow], {LineAddrLow{1'b0}}});
      end
      if (state_q == PTW_DECODE) begin
        p_reference_pte : assert (pte_q == f_last_pte_q);
        p_reference_pte_address : assert (pte_pa == f_last_pa_q);
      end
      c_pwc_l1_replacement : cover (f_replaced_l1_q && o_resp_valid && o_resp.fault_kind == 0);
      c_pwc_root_replacement : cover (f_replaced_root_q && o_resp_valid && o_resp.fault_kind == 0);
    end
  end
  // Name the per-entry scopes, leaving assertion names to the frontend.
  // The builtin formal frontend duplicates explicit assertion labels even
  // inside a generate loop.
  for (genvar e = 0; e < PwcL1N; e++) begin : gen_ref_l1_provenance
    always_ff @(posedge i_clk) begin
      if (f_past_valid && !i_rst && pwc_l1_valid_q[e])
        assert (pwc_l1_tag_q[e] == f_l1_tag[e] &&
                riscv_pkg::PtePpnBits'(pwc_l1_ppn_q[e]) == f_l1_pointer[e]);
    end
  end
  for (genvar e = 0; e < PwcRootN; e++) begin : gen_ref_root_provenance
    always_ff @(posedge i_clk) begin
      if (f_past_valid && !i_rst && pwc_root_valid_q[e])
        assert (pwc_root_tag_q[e] == f_root_tag[e] &&
                riscv_pkg::PtePpnBits'(pwc_root_ppn_q[e]) == f_root_pointer[e]);
    end
  end

  // Every valid entry read from the watched line holds that line's pointer;
  // no two valid entries of an array share a tag.
  logic f_pwc_memory_ok, f_pwc_unique;
  always_comb begin
    logic [63:0] p;
    f_pwc_memory_ok = 1'b1;
    f_pwc_unique = 1'b1;
    for (int e = 0; e < PwcL1N; e++) begin
      p = f_watched_pte(f_l1_src[e]);
      if ((PWC_L1_ENTRIES != 0) && pwc_l1_valid_q[e] &&
          (f_l1_src[e][riscv_pkg::PhysAddrBits-1:LineAddrLow] ==
           f_watch_line[riscv_pkg::PhysAddrBits-1:LineAddrLow]) &&
          !(f_valid_pointer(
              p
          ) && (p[53:10] == 44'(pwc_l1_ppn_q[e]))))
        f_pwc_memory_ok = 1'b0;
      for (int o = 0; o < PwcL1N; o++) begin
        if ((o > e) && pwc_l1_valid_q[e] && pwc_l1_valid_q[o] &&
            (pwc_l1_tag_q[e] == pwc_l1_tag_q[o]))
          f_pwc_unique = 1'b0;
      end
    end
    for (int e = 0; e < PwcRootN; e++) begin
      p = f_watched_pte(f_root_src[e]);
      if ((PWC_ROOT_ENTRIES != 0) && pwc_root_valid_q[e] &&
          (f_root_src[e][riscv_pkg::PhysAddrBits-1:LineAddrLow] ==
           f_watch_line[riscv_pkg::PhysAddrBits-1:LineAddrLow]) &&
          !(f_valid_pointer(
              p
          ) && (p[53:10] == 44'(pwc_root_ppn_q[e]))))
        f_pwc_memory_ok = 1'b0;
      for (int o = 0; o < PwcRootN; o++) begin
        if ((o > e) && pwc_root_valid_q[e] && pwc_root_valid_q[o] &&
            (pwc_root_tag_q[e] == pwc_root_tag_q[o]))
          f_pwc_unique = 1'b0;
      end
    end
  end

  always_ff @(posedge i_clk) begin
    if (f_past_valid && !i_rst) begin
      if ($past(i_discard) && !$past(i_rst)) begin
        p_pwc_discard_clears : assert (!(|pwc_l1_valid_q) && !(|pwc_root_valid_q));
      end
      if (pwc_fill_l1 || pwc_fill_root) begin
        p_pwc_fill_after_discard : assert (!f_discard_since_accept);
        p_pwc_fill_valid_pointer :
        assert (f_pte_seen && !f_g_reserved && !f_g_invalid && !f_g_leaf &&
                (f_level == level_q + 2'd1) && (f_level != 2'd0) && (f_pte[53:10] == ptr_ppn_q));
      end
      p_pwc_matches_memory : assert (f_pwc_memory_ok);
      p_pwc_unique : assert (f_pwc_unique);
      // The match registered in PTW_PWC still describes the arrays and VPN
      // that PTW_PWC_SEL reads.
      if (state_q == PTW_PWC_SEL) begin
        p_pwc_match_current :
        assert ((pwc_l1_match_q == pwc_l1_match_c) && (pwc_root_match_q == pwc_root_match_c));
      end
      if (!$past(i_rst) && ($past(state_q) == PTW_PWC_SEL) && (state_q == PTW_ISSUE)) begin
        if ($past(pwc_l1_hit)) begin
          p_pwc_l1_hit_start :
          assert (level_q == 2'd0 && ptr_ppn_q == riscv_pkg::PtePpnBits'($past(pwc_l1_ppn)));
        end else if ($past(pwc_root_hit)) begin
          p_pwc_root_hit_start :
          assert (level_q == 2'd1 && ptr_ppn_q == riscv_pkg::PtePpnBits'($past(pwc_root_ppn)));
        end else begin
          p_pwc_miss_start : assert (level_q == 2'd2);
        end
      end
      c_pwc_l1_hit : cover ((state_q == PTW_PWC_SEL) && pwc_l1_hit && !i_discard);
      c_pwc_root_hit :
      cover ((state_q == PTW_PWC_SEL) && !pwc_l1_hit && pwc_root_hit && !i_discard);
      c_pwc_hit_leaf :
      cover (o_resp_valid && (o_resp.fault_kind == riscv_pkg::DFAULT_NONE) &&
             (o_resp.level == 2'd0) && (f_level == 2'd0) && !f_discard_since_accept &&
             (|pwc_l1_valid_q));
    end
  end
`endif
`ifndef SYNTHESIS
`ifdef FROST_COVERAGE
  // Discard cannot withdraw a registered read accepted on this edge.
  cover_discard_on_read_accept :
  cover property (@(posedge i_clk) disable iff (!reset_seen_q || i_rst)
      i_discard && o_line_req_valid && i_line_req_ready);
  // A response on the discard edge must drain without installing a leaf.
  cover_discard_on_read_response :
  cover property (@(posedge i_clk) disable iff (!reset_seen_q || i_rst)
      i_discard && (state_q == PTW_WAIT) && i_line_resp_valid);
  // A valid parent PTE can lead to a bus error at an interior table.
  cover_interior_pte_read_error :
  cover property (@(posedge i_clk) disable iff (!reset_seen_q || i_rst)
      ENABLE_RESPONSE_ERRORS && (state_q == PTW_WAIT) && (level_q != 2) &&
      i_line_resp_valid && i_line_resp_error && !discard_q && !i_discard);
`endif
`endif
`ifdef COH_MAINT_OWNED
  // The maintenance composition supplies a fixed root and valid leaf images.
  // Its tasks prove these context facts; standalone walker tasks omit them.
  logic f_maint_error = 0;
  assign o_maint_state = state_q;
  assign o_maint_vpn = vpn_q;
  assign o_maint_error = f_maint_error;
  assign o_maint_poison = discard_q;
  always_ff @(posedge i_clk) begin
    if (i_rst) f_maint_error <= 0;
    else begin
      if (i_req_valid && o_req_ready) f_maint_error <= 0;
      if (i_line_resp_valid) f_maint_error <= i_line_resp_error;
      p_maint_ptw_state : assert (state_q <= PTW_RESP);
      if (state_q == PTW_ISSUE)
        p_maint_ptw_issue_valid : assert (line_req_valid_q == (ptr_addr_ok_q && !discard_q));
      if (line_req_valid_q) p_maint_ptw_valid_issue : assert (state_q == PTW_ISSUE);
      if (state_q != PTW_IDLE)
        p_maint_ptw_root :
        assert (level_q == 2 && ptr_ppn_q == i_root_ppn && ptr_addr_ok_q && vpn_q[26:18] == 0);
      if (state_q == PTW_DECODE)
        p_maint_ptw_pte : assert ((pte_q & 64'hfffffffffffffcdf) == 64'h200000cf);
      if (state_q == PTW_RESP) begin
        p_maint_ptw_vpn : assert (resp_q.vpn == vpn_q);
        p_maint_ptw_fault :
        assert (resp_q.fault_kind == (f_maint_error ?
            riscv_pkg::DFAULT_ACCESS : riscv_pkg::DFAULT_NONE));
      end
    end
  end
`endif
endmodule : ptw
