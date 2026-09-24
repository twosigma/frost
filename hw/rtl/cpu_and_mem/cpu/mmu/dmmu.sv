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
 * dmmu: data-side Sv39 translation, between the MEM_RS address adder and the
 * LQ/SQ address updates. It is used only while data translation is on
 * (satp.MODE is Sv39 and the effective data privilege is below M); otherwise
 * the wrapper bypasses it, with no added latency. i_active, i_sum, i_mxr, and
 * i_eff_priv_u are registered CSR state that changes only with a full flush.
 *
 * Each op passes two registered stages, and DTLB hits flow at one op per
 * cycle. S1 holds the op while the DTLB lookup, the checks, and any walk
 * complete; S2 registers the result. Every consumer pulse fires from S2 (the
 * LQ packet, the SQ address and data packets, the ROB store completion, the
 * store fault strobe, and the SC-table address fill), which keeps the TLB
 * lookup off the issue-ready, ROB-done, and queue-CAM paths. A faulting op
 * carries its VA (for xtval) in place of the PA, and the wrapper routes the
 * fault to the LQ entry (loads, LR, AMOs) or the store fault strobe (stores,
 * SC).
 */
module dmmu (
    input logic i_clk,
    input logic i_rst_n,

    // Registered translation state from csr_file.
    input logic i_active,
    input logic i_sum,
    input logic i_mxr,
    input logic i_eff_priv_u, // effective data privilege == U

    // Misaligned accesses trap only while this is set (mtvec's base is
    // nonzero). The LQ and wrapper alignment checks use the same input.
    input logic i_trap_misaligned,

    // Clears every DTLB entry: SFENCE.VMA, or the CSR file's translation
    // invalidate. The walker discards its walk in flight on the same signal.
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
    // The S2 pulse split into LQ and SQ ops, without the flush kills. The SQ
    // uses its pulse only to write payload. The LQ uses its pulse as the
    // address-update valid, which is safe because a flush clears the target
    // LQ entry on the same edge. Everything else uses o_iss_out_valid.
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

    // Pre-issue look-ahead for the LQ: the op held in S1.
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

    // Page-table walker port.
    output logic o_walk_req_valid,
    input logic i_walk_req_ready,
    output logic [riscv_pkg::Sv39VpnBits-1:0] o_walk_vpn,
    input logic i_walk_resp_valid,
    input riscv_pkg::ptw_resp_t i_walk_resp
);

  // Partial-flush age test used throughout the back end: entry_tag is younger
  // than flush_tag, both measured from the ROB head.
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

  // Kills. A full flush empties the pipe. A partial flush drops ops younger
  // than the flush tag from S0, S1, and S2, and from the issue port itself:
  // MEM_RS presents an issue without checking a same-cycle flush
  // (hw/rtl/cpu_and_mem/cpu/tomasulo/reservation_station/README.md,
  // "Flushes"). Untranslated, such an op is harmless because the LQ or SQ
  // entry it names dies on that edge, but this pipe would deliver it cycles
  // later, after its ROB tag was reused on the correct path, and its fault or
  // address would land on the wrong op. vm_test case W covers this.
  logic iss_killed;
  assign iss_killed = i_flush_en && is_younger(iss_in.tag, i_flush_tag, i_head_tag);

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

  // Resolve the TLB leaf and the walk-response leaf in parallel, then select
  // between the finished results. Selecting their raw PPN and permission
  // fields first would put the late TLB hit ahead of the PMA check, fault
  // classification, and the VA/PA mux. A TLB hit still wins over a
  // simultaneous walk response.
  logic [19:0] walk_ppn20;
  always_comb begin
    unique case (i_walk_resp.level)
      2'd2: walk_ppn20 = {i_walk_resp.ppn[19:18], s1_q.va[29:12]};
      2'd1: walk_ppn20 = {i_walk_resp.ppn[19:9], s1_q.va[20:12]};
      default: walk_ppn20 = i_walk_resp.ppn[19:0];
    endcase
  end

  function automatic logic leaf_perm_ok(input logic r, input logic w, input logic x, input logic u,
                                        input logic d);
    // Privilege dimension: U pages need U-mode or SUM; S pages refuse U.
    logic priv_ok;
    priv_ok = u ? (i_eff_priv_u || i_sum) : !i_eff_priv_u;
    if (s1_q.store_perms) leaf_perm_ok = priv_ok && w && d;
    else leaf_perm_ok = priv_ok && (r || (i_mxr && x));
  endfunction

  logic [riscv_pkg::XLEN-1:0] tlb_pa, walk_pa;
  assign tlb_pa  = {32'b0, tlb_ppn20[0], s1_q.va[11:0]};
  assign walk_pa = {32'b0, walk_ppn20, s1_q.va[11:0]};

  riscv_pkg::data_fault_kind_e tlb_fault, walk_fault;
  always_comb begin
    tlb_fault = riscv_pkg::DFAULT_NONE;
    if (!leaf_perm_ok(tlb_r[0], tlb_w[0], tlb_x[0], tlb_u[0], tlb_d[0])) begin
      tlb_fault = riscv_pkg::DFAULT_PAGE;
    end else if (tlb_hi_nonzero[0] || !riscv_pkg::pma_data_ok(tlb_pa)) begin
      tlb_fault = riscv_pkg::DFAULT_ACCESS;
    end

    walk_fault = i_walk_resp.fault_kind;
    if (i_walk_resp.fault_kind == riscv_pkg::DFAULT_NONE) begin
      if (!leaf_perm_ok(
              i_walk_resp.perm_r,
              i_walk_resp.perm_w,
              i_walk_resp.perm_x,
              i_walk_resp.perm_u,
              i_walk_resp.perm_d
          )) begin
        walk_fault = riscv_pkg::DFAULT_PAGE;
      end else if ((|i_walk_resp.ppn[riscv_pkg::PtePpnBits-1:20]) || !riscv_pkg::pma_data_ok(
              walk_pa
          )) begin
        walk_fault = riscv_pkg::DFAULT_ACCESS;
      end
    end
  end

  logic [riscv_pkg::XLEN-1:0] tlb_resolve_addr, walk_resolve_addr;
  assign tlb_resolve_addr  = (tlb_fault == riscv_pkg::DFAULT_NONE) ? tlb_pa : s1_q.va;
  assign walk_resolve_addr = (walk_fault == riscv_pkg::DFAULT_NONE) ? walk_pa : s1_q.va;

  // MMIO class of each candidate, computed before the TLB/walk selection. A
  // zero-extended PA in the 01 quadrant always passes pma_data_ok, so the
  // class needs only the permission check and the high PPN bits, not the
  // full fault and address mux. DMMU_MMIO_LOCAL_PROOF (formal target
  // dmmu_mmio) checks it against the class of the complete resolution.
  (* keep = "true" *) logic tlb_is_mmio, walk_is_mmio;
  assign tlb_is_mmio = leaf_perm_ok(
      tlb_r[0], tlb_w[0], tlb_x[0], tlb_u[0], tlb_d[0]
  ) && !tlb_hi_nonzero[0] && (tlb_ppn20[0][19:18] == 2'b01);
  assign walk_is_mmio = (i_walk_resp.fault_kind == riscv_pkg::DFAULT_NONE) && leaf_perm_ok(
      i_walk_resp.perm_r,
      i_walk_resp.perm_w,
      i_walk_resp.perm_x,
      i_walk_resp.perm_u,
      i_walk_resp.perm_d
  ) && !(|i_walk_resp.ppn[riscv_pkg::PtePpnBits-1:20]) && (i_walk_resp.ppn[19:18] == 2'b01);
  logic resolve_is_mmio;

  // Resolution select, in architectural priority order:
  //   1. Misalignment, when i_trap_misaligned is set. It is checked on the VA
  //      before translation, so an access that traps as misaligned never
  //      walks.
  //   2. A non-canonical VA: page fault, no walk.
  //   3. A DTLB hit: the permission check with the current SUM, MXR, and
  //      effective privilege, then the PMA check on the PA, where a leaf
  //      outside the map is an access fault. Loads need R, or X with MXR.
  //      Stores, SC, and AMOs need W and D (Svade: a store to a D=0 page is a
  //      page fault). A U page accessed from S needs SUM, and an S page
  //      accessed from U faults.
  //   4. A walk response for S1's VPN, matched by the VPN echo because the op
  //      that asked may have been flushed and replaced. A clean leaf goes
  //      through the same checks (and installs in the DTLB on the same edge),
  //      and a refused walk resolves as its fault.
  // Otherwise the op waits in S1 and asks for a walk (o_walk_req_valid).
  logic resolve_now;
  riscv_pkg::data_fault_kind_e resolve_fault;
  logic [riscv_pkg::XLEN-1:0] resolve_addr;
  always_comb begin
    resolve_now = 1'b0;
    resolve_fault = riscv_pkg::DFAULT_NONE;
    resolve_addr = s1_q.va;
    resolve_is_mmio = (s1_q.va[31:30] == 2'b01);
    if (s1_valid_q) begin
      if (i_trap_misaligned && s1_misaligned) begin
        resolve_now = 1'b1;
        resolve_fault = riscv_pkg::DFAULT_MISALIGN;
        resolve_is_mmio = 1'b0;
      end else if (s1_noncanonical) begin
        resolve_now = 1'b1;
        resolve_fault = riscv_pkg::DFAULT_PAGE;
        resolve_is_mmio = 1'b0;
      end else if (tlb_hit[0]) begin
        resolve_now = 1'b1;
        resolve_fault = tlb_fault;
        resolve_addr = tlb_resolve_addr;
        resolve_is_mmio = tlb_is_mmio;
      end else if (walk_resp_for_s1) begin
        resolve_now = 1'b1;
        resolve_fault = walk_fault;
        resolve_addr = walk_resolve_addr;
        resolve_is_mmio = walk_is_mmio;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Pipe advance
  // ---------------------------------------------------------------------------
  // While S1 holds an unresolved op, one more op may issue into the S0 skid
  // behind it. On a run of hits S1 hands its op to S2 every cycle and new ops
  // load S1 directly, with the skid empty.
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
          s1_valid_q <= i_iss_valid && i_active && !iss_killed;
          s1_q <= iss_in;
          s0_valid_q <= 1'b0;
          s1_walk_asked_q <= 1'b0;
        end
      end else begin
        // S1 held (unresolved): one op may slip in behind it.
        if (i_iss_valid && i_active && !s0_valid_q && !iss_killed) begin
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

  // The skid's valid bit holds MEM_RS issue, so the MEM_RS ready logic sees
  // one register and nothing of the TLB.
  assign o_stall = s0_valid_q;

  // ---------------------------------------------------------------------------
  // S2 registers the resolution. Every consumer pulse fires from here.
  // ---------------------------------------------------------------------------
  logic s2_valid_q;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] s2_tag_q;
  logic [riscv_pkg::XLEN-1:0] s2_addr_q;
  logic s2_is_mmio_q;
  riscv_pkg::data_fault_kind_e s2_fault_q;
  logic s2_needs_sq_q, s2_is_sc_q;
  logic [riscv_pkg::XLEN-1:0] s2_store_data_q, s2_amo_rs2_q;

  // tlb_is_mmio arrives after the resolution qualifiers, so the next S2 MMIO
  // bit is computed for both of its values (including the hold when nothing
  // resolves) and tlb_is_mmio selects last. The other S2 fields use enables.
  (* keep = "true" *) logic [1:0] s2_mmio_cases;
  logic s2_mmio_next;
  for (genvar mmio = 0; mmio < 2; mmio++) begin : gen_s2_mmio_cases
    logic resolved_mmio;
    always_comb begin
      resolved_mmio = (s1_q.va[31:30] == 2'b01);
      if (s1_valid_q) begin
        if (i_trap_misaligned && s1_misaligned) resolved_mmio = 1'b0;
        else if (s1_noncanonical) resolved_mmio = 1'b0;
        else if (tlb_hit[0]) resolved_mmio = (mmio != 0);
        else if (walk_resp_for_s1) resolved_mmio = walk_is_mmio;
      end
    end
    assign s2_mmio_cases[mmio] = s1_resolved ? resolved_mmio : s2_is_mmio_q;
  end
  assign s2_mmio_next = tlb_is_mmio ? s2_mmio_cases[1] : s2_mmio_cases[0];

  always_ff @(posedge i_clk) begin
    s2_is_mmio_q <= s2_mmio_next;
    if (!i_rst_n || i_flush_all) begin
      s2_valid_q <= 1'b0;
    end else begin
      s2_valid_q <= s1_move;
    end
    // A killed resolution leaves s2_valid_q clear, so its payload is never
    // seen. Capturing it anyway keeps the flush age compare off every S2
    // payload enable.
    if (s1_resolved) begin
      s2_tag_q <= s1_q.tag;
      s2_addr_q <= resolve_addr;
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

  // S1 holds each op through the cycle before its S2 pulse, so S1's tag is
  // the one-cycle look-ahead the LQ needs, however long a walk takes.
  assign o_pre_rob_tag = s1_q.tag;
  assign o_pre_needs_lq = s1_valid_q && !s1_q.needs_sq;

  // Walk request: the op in S1 is live, is neither a trapping misaligned
  // access nor non-canonical, is not resolved by a matching walk response,
  // has not asked yet, and missed the DTLB. The request is built from these
  // terms directly, not from the resolution mux, and the late TLB hit gates
  // only the finished request, which keeps the path from the lookup to the
  // walker's state enable short. Valid stays high until the walker accepts,
  // and an op asks once (a second ask would be harmless, since responses are
  // matched by VPN, but wasteful). No request is made during a TLB
  // invalidate.
  (* keep = "true" *) logic s1_walk_eligible;
  assign s1_walk_eligible = s1_valid_q && !(i_trap_misaligned && s1_misaligned) &&
      !s1_noncanonical && !walk_resp_for_s1 && !s1_walk_asked_q &&
      !s1_killed && !i_tlb_invalidate;
  assign o_walk_req_valid = s1_walk_eligible && !tlb_hit[0];
  assign o_walk_vpn = s1_q.va[38:12];

  // ---------------------------------------------------------------------------
  // Early opportunistic ports: VA registered, lookup, result registered.
  // ---------------------------------------------------------------------------
  // These translate the two store early-address pipelines' addresses so an SQ
  // entry can get its PA before MEM_RS issues the store. They never stall and
  // never fault: a hit with full store permission on a canonical VA and an
  // in-map PA gives the PA two cycles after the request, and anything else
  // drops the early update. The issue port translates every store again and
  // reports every fault. Once an SQ entry's address is valid, later address
  // writes to it are ignored, so a stale prefill would stick. None can: every
  // translation change comes with a full flush, which kills every store that
  // could have been prefilled under the old translation, and the wrapper
  // drops the delayed early packets on any flush, so a killed store's prefill
  // cannot reach a correct-path store that reuses its tag.
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

`ifdef DMMU_MMIO_LOCAL_PROOF
  always_comb begin
    p_mmio_capture_exact : assert (s2_mmio_next == (s1_resolved ? resolve_is_mmio : s2_is_mmio_q));
    p_resolve_mmio_exact :
    assert (resolve_is_mmio ==
        ((resolve_fault == riscv_pkg::DFAULT_NONE) && (resolve_addr[31:30] == 2'b01)));
  end
`endif

endmodule : dmmu
