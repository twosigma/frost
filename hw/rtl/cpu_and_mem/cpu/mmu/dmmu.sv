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
 * dmmu -- the data-side Sv39 translation stage (Phase 3 M4, plan D4).
 *
 * Sits between the AGU adds and the LQ/SQ address-update writes, USED ONLY
 * while data translation is active (satp.MODE = Sv39 and the effective
 * data privilege is below M). The wrapper bypasses it combinationally when
 * translation is inactive, so the M-mode/Bare timing paths are exactly the
 * historical ones; every input that decides activity is registered,
 * quasi-static CSR state whose changes ride a D10 (or trap/xret) flush.
 *
 * ISSUE PIPE (+2 registered cycles when active, full throughput): S1
 * captures the issued op {tag, VA, size, routing/permission class,
 * store data, amo_rs2}; the DTLB lookup and every check run
 * combinationally on S1 during the next cycle; the RESOLUTION is then
 * registered into S2, and every consumer pulse (LQ packet, SQ address and
 * data packets, the ROB store-done, the store fault strobe, the SC-table
 * PA fill) fires from S2's registers — the TLB cone is flop-bounded on
 * both sides and never reaches the issue-ready, ROB-done, or queue-CAM
 * cones (the Genesys2 opt probe put an 18-level lookup-to-rob_done path
 * at WNS when these fired combinationally).
 *
 * Resolution order on S1:
 *   1. VA-domain misalignment (mtvec-armed qualifier, BEFORE translation:
 *      a misaligned access never walks);
 *   2. non-canonical VA => page fault, no walk;
 *   3. DTLB hit => permission check on live SUM/MXR/effective-privilege
 *      (loads: R or MXR&X; store-family: W and D -- Svade makes a store
 *      to D=0 a page fault; U-page from S needs SUM, S-page from U
 *      faults), then the PMA check on the composed PA (out-of-map leaf =>
 *      access fault) -- launched-implies-in-map extends through
 *      translation;
 *   4. DTLB miss => ask the walker; the response is matched by its vpn
 *      echo (the asking op may have been flushed and replaced), a clean
 *      leaf installs and resolves through the same permission path, a
 *      refused walk resolves as its fault.
 * A fault resolution carries the VA (xtval) in place of the PA; the owner
 * routes it to the LQ entry (loads/AMOs/LR) or the store fault strobe
 * (stores/SC).
 *
 * Flow control: while S1 holds an unresolved op, one more op may issue
 * behind it into the S0 skid; o_stall is simply the skid's REGISTERED
 * valid bit, so the MEM_RS ready cone sees one flop and nothing of the
 * TLB. On a hit stream S1 hands off to S2 every cycle and new ops load
 * S1 directly (the skid stays empty and ready stays high). S1 holds its
 * op through every cycle before the delivery, which makes S1's own
 * {tag, needs-LQ} THE pre-issue look-ahead the load queue pairs with the
 * packet — presented one cycle before the S2 pulse by construction, for
 * hits and arbitrary-length misses alike.
 *
 * EARLY PORTS (opportunistic, never stall, never fault): the two
 * early-store-pipeline addresses look up on a registered VA and the
 * RESULT is registered again; a full-permission hit on an in-map PA
 * yields the PA two cycles after the request so the SQ entry can be
 * prefilled early. Anything else just drops the early update: the issue
 * port re-translates the same store and owns every fault and stall
 * (first-writer-wins in the SQ makes the drop free). A translation
 * change cannot leak through a prefilled PA: satp/sfence/D10 flushes
 * kill every store that could straddle it.
 *
 * The DTLB invalidates (flash) on sfence.vma's serialized window and on
 * the D10 satp/translation CSR flush pulse; the same signal poisons the
 * walk in flight (ptw complete-and-discard).
 */
module dmmu (
    input logic i_clk,
    input logic i_rst_n,

    // Registered quasi-static translation state (csr_file exports).
    input logic i_active,
    input logic i_sum,
    input logic i_mxr,
    input logic i_eff_priv_u, // effective data privilege == U

    // Live misalign-trap qualifier (same input the LQ/wrapper checks use).
    input logic i_trap_misaligned,

    // Flash-invalidate the DTLB (sfence window / D10 translation flush).
    input logic i_tlb_invalidate,

    // Pipeline kills.
    input logic i_flush_all,
    input logic i_flush_en,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_flush_tag,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_head_tag,

    // Issue port in (fires with the wrapper's MEM_RS issue while active).
    input logic i_iss_valid,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_iss_rob_tag,
    input logic [riscv_pkg::XLEN-1:0] i_iss_va,
    input riscv_pkg::mem_size_e i_iss_size,
    input logic i_iss_needs_sq,  // routing: SQ-resident (stores + SC)
    input logic i_iss_store_perms,  // permission class: stores + SC + AMOs
    input logic i_iss_is_sc,
    input logic [riscv_pkg::XLEN-1:0] i_iss_store_data,
    input logic [riscv_pkg::XLEN-1:0] i_iss_amo_rs2,

    // Issue port out: one pulse per resolved op, from the S2 registers.
    output logic o_iss_out_valid,
    // Payload-only capture pulses before recovery/full-flush kills.  The LQ
    // and SQ may accept these pulses on a kill edge because their
    // entry/control state is cleared on that same edge; architectural
    // visibility and every other side effect keep using o_iss_out_valid.
    output logic o_iss_out_lq_capture_valid,
    output logic o_iss_out_sq_capture_valid,
    output logic [riscv_pkg::ReorderBufferTagWidth-1:0] o_iss_out_rob_tag,
    output logic [riscv_pkg::XLEN-1:0] o_iss_out_addr,  // PA, or VA on fault
    output logic o_iss_out_is_mmio,
    output riscv_pkg::data_fault_kind_e o_iss_out_fault,
    output logic o_iss_out_needs_sq,
    output logic o_iss_out_is_sc,
    output logic [riscv_pkg::XLEN-1:0] o_iss_out_store_data,
    output logic [riscv_pkg::XLEN-1:0] o_iss_out_amo_rs2,

    // The pre-issue pair for the LQ while active: S1's held op.
    output logic [riscv_pkg::ReorderBufferTagWidth-1:0] o_pre_rob_tag,
    output logic o_pre_needs_lq,

    // Skid occupied: the wrapper holds MEM_RS issue (registered term only).
    output logic o_stall,

    // Early opportunistic ports (VA in; {ok, PA} two cycles later).
    input logic i_early_valid,
    input logic [riscv_pkg::XLEN-1:0] i_early_va,
    input logic i_early2_valid,
    input logic [riscv_pkg::XLEN-1:0] i_early2_va,
    output logic o_early_ok,
    output logic [riscv_pkg::XLEN-1:0] o_early_pa,
    output logic o_early_is_mmio,
    output logic o_early2_ok,
    output logic [riscv_pkg::XLEN-1:0] o_early2_pa,
    output logic o_early2_is_mmio,

    // Walker seam.
    output logic o_walk_req_valid,
    input logic i_walk_req_ready,
    output logic [riscv_pkg::Sv39VpnBits-1:0] o_walk_vpn,
    input logic i_walk_resp_valid,
    input riscv_pkg::ptw_resp_t i_walk_resp
);

  // Same age rule as every other tomasulo kill site.
  function automatic logic is_younger(input logic [riscv_pkg::ReorderBufferTagWidth-1:0] entry_tag,
                                      input logic [riscv_pkg::ReorderBufferTagWidth-1:0] flush_tag,
                                      input logic [riscv_pkg::ReorderBufferTagWidth-1:0] head);
    logic [riscv_pkg::ReorderBufferTagWidth:0] entry_age;
    logic [riscv_pkg::ReorderBufferTagWidth:0] flush_age;
    begin
      entry_age  = {1'b0, entry_tag} - {1'b0, head};
      flush_age  = {1'b0, flush_tag} - {1'b0, head};
      is_younger = entry_age > flush_age;
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Issue payload bundle (S0 skid and S1 stage carry the same shape)
  // ---------------------------------------------------------------------------
  typedef struct packed {
    logic [riscv_pkg::ReorderBufferTagWidth-1:0] tag;
    logic [riscv_pkg::XLEN-1:0] va;
    riscv_pkg::mem_size_e size;
    logic needs_sq;
    logic store_perms;
    logic is_sc;
    logic [riscv_pkg::XLEN-1:0] store_data;
    logic [riscv_pkg::XLEN-1:0] amo_rs2;
  } iss_payload_t;

  iss_payload_t iss_in;
  always_comb begin
    iss_in.tag = i_iss_rob_tag;
    iss_in.va = i_iss_va;
    iss_in.size = i_iss_size;
    iss_in.needs_sq = i_iss_needs_sq;
    iss_in.store_perms = i_iss_store_perms;
    iss_in.is_sc = i_iss_is_sc;
    iss_in.store_data = i_iss_store_data;
    iss_in.amo_rs2 = i_iss_amo_rs2;
  end

  logic s0_valid_q, s1_valid_q;
  iss_payload_t s0_q, s1_q;
  logic s1_walk_asked_q;

  logic s0_killed, s1_killed;
  assign s0_killed = i_flush_all || (i_flush_en && s0_valid_q && is_younger(
      s0_q.tag, i_flush_tag, i_head_tag
  ));
  assign s1_killed = i_flush_all || (i_flush_en && s1_valid_q && is_younger(
      s1_q.tag, i_flush_tag, i_head_tag
  ));

  // ---------------------------------------------------------------------------
  // Resolution of the S1 op (combinational on the S1 registers)
  // ---------------------------------------------------------------------------
  logic s1_misaligned;
  always_comb begin
    unique case (s1_q.size)
      riscv_pkg::MEM_SIZE_HALF:   s1_misaligned = s1_q.va[0];
      riscv_pkg::MEM_SIZE_WORD:   s1_misaligned = |s1_q.va[1:0];
      riscv_pkg::MEM_SIZE_DOUBLE: s1_misaligned = |s1_q.va[2:0];
      default:                    s1_misaligned = 1'b0;  // byte
    endcase
  end

  logic s1_noncanonical;
  assign s1_noncanonical = !riscv_pkg::sv39_va_canonical(s1_q.va);

  // DTLB port 0 = issue, ports 1/2 = early slots.
  logic [2:0][riscv_pkg::Sv39VpnBits-1:0] tlb_vpn;
  logic [2:0] tlb_hit;
  logic [2:0][19:0] tlb_ppn20;
  logic [2:0] tlb_hi_nonzero;
  logic [2:0] tlb_r, tlb_w, tlb_x, tlb_u, tlb_d;

  assign tlb_vpn[0] = s1_q.va[38:12];

  // Walk-response bypass: resolve the held op straight from a matching
  // response (the install lands the same edge for future ops).
  logic walk_resp_for_s1;
  assign walk_resp_for_s1 = i_walk_resp_valid && s1_valid_q && (i_walk_resp.vpn == s1_q.va[38:12]);

  logic eval_use_walk;
  logic eval_have;
  logic eval_r, eval_w, eval_x, eval_u, eval_d, eval_hi_nonzero;
  logic [19:0] eval_ppn20;
  always_comb begin
    eval_use_walk = walk_resp_for_s1 && (i_walk_resp.fault_kind == riscv_pkg::DFAULT_NONE);
    eval_have = tlb_hit[0] || eval_use_walk;
    if (eval_use_walk && !tlb_hit[0]) begin
      eval_r = i_walk_resp.perm_r;
      eval_w = i_walk_resp.perm_w;
      eval_x = i_walk_resp.perm_x;
      eval_u = i_walk_resp.perm_u;
      eval_d = i_walk_resp.perm_d;
      eval_hi_nonzero = |i_walk_resp.ppn[riscv_pkg::PtePpnBits-1:20];
      unique case (i_walk_resp.level)
        2'd2: eval_ppn20 = {i_walk_resp.ppn[19:18], s1_q.va[29:12]};
        2'd1: eval_ppn20 = {i_walk_resp.ppn[19:9], s1_q.va[20:12]};
        default: eval_ppn20 = i_walk_resp.ppn[19:0];
      endcase
    end else begin
      eval_r = tlb_r[0];
      eval_w = tlb_w[0];
      eval_x = tlb_x[0];
      eval_u = tlb_u[0];
      eval_d = tlb_d[0];
      eval_hi_nonzero = tlb_hi_nonzero[0];
      eval_ppn20 = tlb_ppn20[0];
    end
  end

  logic eval_perm_ok;
  always_comb begin
    // Privilege dimension: U pages need U-mode or SUM; S pages refuse U.
    logic priv_ok;
    priv_ok = eval_u ? (i_eff_priv_u || i_sum) : !i_eff_priv_u;
    if (s1_q.store_perms) eval_perm_ok = priv_ok && eval_w && eval_d;
    else eval_perm_ok = priv_ok && (eval_r || (i_mxr && eval_x));
  end

  logic [riscv_pkg::XLEN-1:0] eval_pa;
  assign eval_pa = {32'b0, eval_ppn20, s1_q.va[11:0]};

  logic eval_pma_bad;
  assign eval_pma_bad = eval_hi_nonzero || !riscv_pkg::pma_data_ok(eval_pa);

  // Resolution select, in architectural priority order.
  logic resolve_now;
  riscv_pkg::data_fault_kind_e resolve_fault;
  logic [riscv_pkg::XLEN-1:0] resolve_addr;
  always_comb begin
    resolve_now   = 1'b0;
    resolve_fault = riscv_pkg::DFAULT_NONE;
    resolve_addr  = s1_q.va;
    if (s1_valid_q) begin
      if (i_trap_misaligned && s1_misaligned) begin
        resolve_now   = 1'b1;
        resolve_fault = riscv_pkg::DFAULT_MISALIGN;
      end else if (s1_noncanonical) begin
        resolve_now   = 1'b1;
        resolve_fault = riscv_pkg::DFAULT_PAGE;
      end else if (eval_have) begin
        resolve_now = 1'b1;
        if (!eval_perm_ok) resolve_fault = riscv_pkg::DFAULT_PAGE;
        else if (eval_pma_bad) resolve_fault = riscv_pkg::DFAULT_ACCESS;
        else begin
          resolve_fault = riscv_pkg::DFAULT_NONE;
          resolve_addr  = eval_pa;
        end
      end else if (walk_resp_for_s1) begin
        // The walk itself was refused (PAGE or ACCESS).
        resolve_now   = 1'b1;
        resolve_fault = i_walk_resp.fault_kind;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Pipe advance
  // ---------------------------------------------------------------------------
  logic s1_resolved, s1_move;
  assign s1_resolved = s1_valid_q && resolve_now;
  assign s1_move = s1_resolved && !s1_killed;

  logic s1_can_load;
  assign s1_can_load = !s1_valid_q || s1_move || s1_killed;

  always_ff @(posedge i_clk) begin
    if (!i_rst_n || i_flush_all) begin
      s0_valid_q <= 1'b0;
      s1_valid_q <= 1'b0;
      s1_walk_asked_q <= 1'b0;
    end else begin
      // S1 loads from the skid first, else from a live issue fire.
      if (s1_can_load) begin
        if (s0_valid_q && !s0_killed) begin
          s1_valid_q <= 1'b1;
          s1_q <= s0_q;
          s0_valid_q <= 1'b0;
          s1_walk_asked_q <= 1'b0;
        end else begin
          s1_valid_q <= i_iss_valid && i_active;
          s1_q <= iss_in;
          s0_valid_q <= 1'b0;
          s1_walk_asked_q <= 1'b0;
        end
      end else begin
        // S1 held (unresolved): one op may slip in behind it.
        if (i_iss_valid && i_active && !s0_valid_q) begin
          s0_valid_q <= 1'b1;
          s0_q <= iss_in;
        end else if (s0_killed) begin
          s0_valid_q <= 1'b0;
        end
        if (s1_killed) begin
          s1_valid_q <= 1'b0;
          s1_walk_asked_q <= 1'b0;
        end else if (o_walk_req_valid && i_walk_req_ready) begin
          s1_walk_asked_q <= 1'b1;
        end
      end
    end
  end

  // The MEM_RS ready cone sees exactly one registered bit.
  assign o_stall = s0_valid_q;

  // ---------------------------------------------------------------------------
  // S2: registered resolution — every consumer pulse fires from here.
  // ---------------------------------------------------------------------------
  logic s2_valid_q;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] s2_tag_q;
  logic [riscv_pkg::XLEN-1:0] s2_addr_q;
  logic s2_is_mmio_q;
  riscv_pkg::data_fault_kind_e s2_fault_q;
  logic s2_needs_sq_q, s2_is_sc_q;
  logic [riscv_pkg::XLEN-1:0] s2_store_data_q, s2_amo_rs2_q;

  always_ff @(posedge i_clk) begin
    if (!i_rst_n || i_flush_all) begin
      s2_valid_q <= 1'b0;
    end else begin
      s2_valid_q <= s1_move;
    end
    // A killed resolution keeps s2_valid_q clear, so its payload is
    // unobservable.  Capturing it anyway keeps the recovery/age compare off
    // every S2 payload enable while preserving the valid pipeline exactly.
    if (s1_resolved) begin
      s2_tag_q <= s1_q.tag;
      s2_addr_q <= resolve_addr;
      s2_is_mmio_q <= (resolve_fault == riscv_pkg::DFAULT_NONE) && (resolve_addr[31:30] == 2'b01);
      s2_fault_q <= resolve_fault;
      s2_needs_sq_q <= s1_q.needs_sq;
      s2_is_sc_q <= s1_q.is_sc;
      s2_store_data_q <= s1_q.store_data;
      s2_amo_rs2_q <= s1_q.amo_rs2;
    end
  end

  logic s2_killed;
  assign s2_killed = i_flush_en && s2_valid_q && is_younger(s2_tag_q, i_flush_tag, i_head_tag);

  assign o_iss_out_valid = s2_valid_q && !s2_killed && !i_flush_all;
  assign o_iss_out_lq_capture_valid = s2_valid_q && !s2_needs_sq_q;
  assign o_iss_out_sq_capture_valid = s2_valid_q && s2_needs_sq_q;
  assign o_iss_out_rob_tag = s2_tag_q;
  assign o_iss_out_addr = s2_addr_q;
  assign o_iss_out_is_mmio = s2_is_mmio_q;
  assign o_iss_out_fault = s2_fault_q;
  assign o_iss_out_needs_sq = s2_needs_sq_q;
  assign o_iss_out_is_sc = s2_is_sc_q;
  assign o_iss_out_store_data = s2_store_data_q;
  assign o_iss_out_amo_rs2 = s2_amo_rs2_q;

  // Pre-issue pair: S1 holds the op through every cycle before its S2
  // delivery, so S1 IS the look-ahead the LQ pairs with the packet.
  assign o_pre_rob_tag = s1_q.tag;
  assign o_pre_needs_lq = s1_valid_q && !s1_q.needs_sq;

  // Walk request: the held op missed every locally resolving case.  For a
  // valid S1 op, !resolve_now is exactly the conjunction below: misalignment
  // and noncanonicality resolve before lookup, while either a TLB hit or any
  // matching walk response resolves afterward.  Keeping this narrow form off
  // the full resolution mux prevents its late VA bit from reaching the PTW
  // state enable.  Valid stays high until the walker accepts, and the op is
  // never re-asked (the vpn echo makes a second ask harmless but wasteful).
  logic s1_needs_walk;
  assign s1_needs_walk = s1_valid_q && !(i_trap_misaligned && s1_misaligned) &&
      !s1_noncanonical && !tlb_hit[0] && !walk_resp_for_s1;
  assign o_walk_req_valid = s1_needs_walk && !s1_walk_asked_q && !s1_killed && !i_tlb_invalidate;
  assign o_walk_vpn = s1_q.va[38:12];

  // ---------------------------------------------------------------------------
  // Early opportunistic ports: VA registered, lookup, RESULT registered.
  // ---------------------------------------------------------------------------
  logic e1_valid_q, e2_valid_q;
  logic [riscv_pkg::XLEN-1:0] e1_va_q, e2_va_q;
  always_ff @(posedge i_clk) begin
    if (!i_rst_n) begin
      e1_valid_q <= 1'b0;
      e2_valid_q <= 1'b0;
    end else begin
      e1_valid_q <= i_early_valid && i_active;
      e2_valid_q <= i_early2_valid && i_active;
      e1_va_q <= i_early_va;
      e2_va_q <= i_early2_va;
    end
  end

  assign tlb_vpn[1] = e1_va_q[38:12];
  assign tlb_vpn[2] = e2_va_q[38:12];

  logic [1:0] early_ok_c;
  logic [riscv_pkg::XLEN-1:0] early_pa_c[2];
  always_comb begin
    for (int s = 0; s < 2; s++) begin
      logic v;
      logic [riscv_pkg::XLEN-1:0] va;
      logic priv_ok;
      v = (s == 0) ? e1_valid_q : e2_valid_q;
      va = (s == 0) ? e1_va_q : e2_va_q;
      early_pa_c[s] = {32'b0, tlb_ppn20[s+1], va[11:0]};
      priv_ok = tlb_u[s+1] ? (i_eff_priv_u || i_sum) : !i_eff_priv_u;
      early_ok_c[s] = v && riscv_pkg::sv39_va_canonical(va) && tlb_hit[s+1] && priv_ok &&
          tlb_w[s+1] && tlb_d[s+1] && !tlb_hi_nonzero[s+1] && riscv_pkg::pma_data_ok(early_pa_c[s]);
    end
  end

  logic [1:0] early_ok_q;
  logic [riscv_pkg::XLEN-1:0] early_pa_q[2];
  always_ff @(posedge i_clk) begin
    if (!i_rst_n) begin
      early_ok_q <= '0;
    end else begin
      early_ok_q <= early_ok_c;
    end
    early_pa_q[0] <= early_pa_c[0];
    early_pa_q[1] <= early_pa_c[1];
  end

  assign o_early_ok = early_ok_q[0];
  assign o_early_pa = early_pa_q[0];
  assign o_early_is_mmio = (early_pa_q[0][31:30] == 2'b01);
  assign o_early2_ok = early_ok_q[1];
  assign o_early2_pa = early_pa_q[1];
  assign o_early2_is_mmio = (early_pa_q[1][31:30] == 2'b01);

  // ---------------------------------------------------------------------------
  // DTLB
  // ---------------------------------------------------------------------------
  logic tlb_install;
  assign tlb_install = i_walk_resp_valid &&
      (i_walk_resp.fault_kind == riscv_pkg::DFAULT_NONE) && !i_tlb_invalidate;

  dtlb #(
      .NUM_ENTRIES(16),
      .NUM_PORTS  (3)
  ) u_dtlb (
      .i_clk(i_clk),
      .i_rst_n(i_rst_n),
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
      .o_level()
  );

endmodule : dmmu
