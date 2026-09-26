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
 * three levels with dependent full-line reads on the hierarchy's walker port
 * (wup). That port sits between the L1D and the L1I in arbiter priority and is
 * coherent with the L1D: the hierarchy probes the L1D before each read reaches
 * the shared level, so a walk sees page-table stores still dirty there without
 * an sfence.vma (see hw/rtl/lib/cache/README.md "The page-table walker port").
 * The PTE is extracted from the 256-bit line response by the address's dword
 * offset, the way cached_tier_adapter extracts a beat.
 *
 * The walker only reads (Svade). A leaf with A=0 is a page fault instead of a
 * PTE update, and so is a store to a leaf with D=0, which the data MMU checks
 * at lookup. Nothing in the fabric writes PTEs.
 *
 * Walk faults, in the order they are found:
 *   - a PTE address outside the cached-DDR window => DFAULT_ACCESS, which
 *     the requester turns into the access fault of the original access type.
 *     Page tables must be in cached DDR because the walk path cannot reach
 *     BRAM or devices.
 *   - reserved bits, V=0, W&!R, a non-leaf at level 0, a misaligned
 *     superpage, or A=0 => DFAULT_PAGE.
 * A clean leaf answers DFAULT_NONE with {ppn, level, RWXUD} and echoes the
 * VPN. The requesting MMU checks permissions at lookup, because SUM, MXR, and
 * the effective privilege are live CSR state, not walk state.
 *
 * i_discard (SFENCE.VMA, a satp access, or an mstatus/sstatus write that
 * changes translation) poisons the walk in flight: every outstanding line read
 * is still consumed, but no response fires. That keeps a translation read from
 * the old page tables from installing after the invalidate. The requester's
 * own pipeline flushes do not discard: a walk for a killed instruction still
 * returns a correct translation, and the VPN echo keeps a late fault from
 * landing on the wrong instruction.
 *
 * satp.PPN may name any 44-bit root. The same address check refuses a bad root
 * pointer before the walk's first read and a bad interior pointer before the
 * next level's read.
 */
module ptw #(
    parameter  int unsigned LINE_BYTES   = 32,
    parameter  int unsigned WALK_ID_BITS = 2,
    localparam int unsigned LineAddrLow  = $clog2(LINE_BYTES)
) (
    input logic i_clk,
    input logic i_rst,

    // Root of the current address space (satp.PPN), sampled when a walk
    // starts. satp changes only through a committed, serialized CSR
    // instruction, and that access also raises i_discard, so no walk in flight
    // across the change answers.
    input logic [riscv_pkg::PtePpnBits-1:0] i_root_ppn,

    // Walk request. Ready is a level: the FSM is idle and no discard is
    // arriving. The walker loads the request payload on every idle edge, so a
    // requester may change or withdraw a request that has not fired.
    input  logic                              i_req_valid,
    output logic                              o_req_ready,
    input  logic [riscv_pkg::Sv39VpnBits-1:0] i_req_vpn,

    // Poison the walk in flight (and any response about to fire).
    input logic i_discard,

    // One-cycle response pulse.
    output logic                 o_resp_valid,
    output riscv_pkg::ptw_resp_t o_resp,

    // Line port (master, read-only): to the hierarchy's wup port.
    output logic                    o_line_req_valid,
    input  logic                    i_line_req_ready,
    output logic [            31:0] o_line_req_addr,
    output logic [WALK_ID_BITS-1:0] o_line_req_id,
    input  logic                    i_line_resp_valid,
    input  logic [WALK_ID_BITS-1:0] i_line_resp_id,
    input  logic [LINE_BYTES*8-1:0] i_line_resp_rdata
);

  // ---------------------------------------------------------------------------
  // Walk state
  // ---------------------------------------------------------------------------
  typedef enum logic [2:0] {
    PTW_IDLE,    // no walk; accept a request
    PTW_ISSUE,   // present the current level's line read until it fires
    PTW_WAIT,    // wait for the line response; capture this level's PTE
    PTW_DECODE,  // classify the captured PTE: answer, or descend a level
    PTW_RESP     // fire the response pulse (one cycle)
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
  // pte_pa = {ptr_ppn, 12'h000} + (vpn[level] << 3), a 56-bit quantity. Only
  // the 32-bit cached-DDR window is reachable, so the check is: upper PPN
  // bits zero and the composed 32-bit address decodes to DDR.
  logic [8:0] vpn_field;
  always_comb begin
    unique case (level_q)
      2'd2:    vpn_field = vpn_q[26:18];
      2'd1:    vpn_field = vpn_q[17:9];
      default: vpn_field = vpn_q[8:0];
    endcase
  end

  logic [31:0] pte_pa32;
  logic pte_pa_hi_nonzero;
  assign pte_pa32 = {ptr_ppn_q[19:0], 12'h000} | {20'b0, vpn_field, 3'b000};
  assign pte_pa_hi_nonzero = |ptr_ppn_q[riscv_pkg::PtePpnBits-1:20];

  logic pte_addr_ok;
  // Cached DDR is [0x8000_0000, 0xC000_0000), where pa[31:30] == 2'b10.
  assign pte_addr_ok = !pte_pa_hi_nonzero && (pte_pa32[31:30] == 2'b10);

  // Registered copy of pte_addr_ok, computed from the value being written at
  // the two places that write ptr_ppn_q (idle and descend). The check depends
  // on ptr_ppn_q alone: vpn_field ORs into pa32[11:3] and cannot reach
  // [31:30], which are ptr_ppn_q[19:18]. The precompute is therefore exact,
  // and it keeps a 24-bit reduction of the high PPN bits out of
  // o_line_req_valid, which fans through the hierarchy's walker-port
  // arbitration into the L2 capture enables.
  logic ptr_addr_ok_q;

  function automatic logic ppn_addr_ok(input logic [riscv_pkg::PtePpnBits-1:0] ppn);
    // Assign-to-name form: Yosys (read -formal) rejects return expressions.
    begin
      ppn_addr_ok = !(|ppn[riscv_pkg::PtePpnBits-1:20]) && (ppn[19:18] == 2'b10);
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Line request (read-only, single id, one walk in flight)
  // ---------------------------------------------------------------------------
  // A poisoned walk never fires a new read. Retracting an unfired request is
  // safe in this fabric, because every slave on the walk path is stateless
  // before the fire. A read already outstanding is consumed in PTW_WAIT.
  //
  // The request valid is computed with each FSM transition and registered. It
  // always equals PTW_ISSUE && ptr_addr_ok_q && !discard_q, so the state decode
  // and the poison and address gates stay off the hierarchy's shared
  // capture-enable path. Do not gate it with the live i_discard: that would put
  // the ROB and CSR invalidate decode on walker arbitration and L2 capture. A
  // read that fires in the discard cycle belongs to a poisoned walk: discard_q
  // is set at that edge, the response is consumed in PTW_WAIT like any other,
  // and nothing is answered (p_discard_silent).
  (* keep = "true" *) logic line_req_valid_q;
  assign o_line_req_valid = line_req_valid_q;
  assign o_line_req_addr = {pte_pa32[31:LineAddrLow], {LineAddrLow{1'b0}}};
  assign o_line_req_id = '0;

  // PTE extraction: dword index inside the 32-byte line.
  logic [1:0] pte_dword_sel_q;  // captured at issue (pa[4:3])
  // This level's PTE: the selected dword of the line response, registered
  // before it is classified. The response arrives through the L2's MSHR state
  // and response mux, and classifying it in the same cycle would put that whole
  // path in front of resp_q. The register adds one cycle per level to a walk.
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

  logic pte_invalid;  // V=0 or the reserved R/W combination
  assign pte_invalid = !pte_v || (!pte_r && pte_w);

  logic superpage_misaligned;
  always_comb begin
    unique case (level_q)
      2'd2:    superpage_misaligned = |pte_ppn[17:0];
      2'd1:    superpage_misaligned = |pte_ppn[8:0];
      default: superpage_misaligned = 1'b0;
    endcase
  end

  // ---------------------------------------------------------------------------
  // FSM
  // ---------------------------------------------------------------------------
  assign o_req_ready = (state_q == PTW_IDLE) && !i_discard;
  assign o_resp_valid = (state_q == PTW_RESP) && !discard_q && !i_discard;
  assign o_resp = resp_q;

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
          // These registers are unobservable while idle, so they load on every
          // idle edge and only state_q and line_req_valid_q wait for a request
          // to fire. The accepting edge loads the same request and root that a
          // fire-gated load would, without putting the request valid on every
          // payload register's enable.
          vpn_q         <= i_req_vpn;
          level_q       <= 2'd2;
          ptr_ppn_q     <= i_root_ppn;
          ptr_addr_ok_q <= ppn_addr_ok(i_root_ppn);
          if (i_req_valid && !i_discard) begin
            state_q <= PTW_ISSUE;
            line_req_valid_q <= ppn_addr_ok(i_root_ppn);
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
            pte_dword_sel_q <= pte_pa32[4:3];
            state_q         <= PTW_WAIT;
          end
        end

        PTW_WAIT: begin
          if (i_line_resp_valid) begin
            // Single-id master with one read in flight, so any response
            // belongs to this walk. Capture this level's PTE; PTW_DECODE
            // classifies it.
            pte_q   <= pte_live;
            state_q <= PTW_DECODE;
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
              end
              state_q <= PTW_RESP;
            end else if (level_q == 2'd0) begin
              // Non-leaf at the last level: no level below it.
              resp_q.fault_kind <= riscv_pkg::DFAULT_PAGE;
              state_q           <= PTW_RESP;
            end else begin
              ptr_ppn_q <= pte_ppn;
              ptr_addr_ok_q <= ppn_addr_ok(pte_ppn);
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
    if (!i_rst) begin
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
    if (!i_rst && (state_q == PTW_ISSUE)) begin
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
    if (!i_rst && i_line_resp_valid && (state_q != PTW_WAIT))
      $error("ptw: line response in state %0d (id=%0d)", state_q, i_line_resp_id);
  end
`endif
`endif

`ifdef FORMAL
  // Walk FSM against a reference PTE classification, bounded (ptw.sby). The
  // line port's responses are unconstrained except for one assumption that the
  // fabric guarantees: a response arrives only while a read is outstanding.
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
    f_g_invalid = !f_pte[0] || (!f_pte[1] && f_pte[2]);
    f_g_leaf = f_pte[1] || f_pte[3];
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
      if (o_line_req_valid) p_read_in_ddr : assert (o_line_req_addr[31:30] == 2'b10);
      // A poisoned walk never answers.
      if (discard_q || i_discard) p_discard_silent : assert (!o_resp_valid);
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
`endif

endmodule : ptw
