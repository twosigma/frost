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
 * Data-side Sv39 translation between the MEM_RS address adder and LQ/SQ.
 * The wrapper bypasses this module without delay when translation is off.
 * i_active, i_sum, i_mxr, and i_eff_priv_u are registered CSR state; changes
 * are accompanied by a full flush.
 *
 * Translation uses two registered stages. S1 holds the operation
 * until its DTLB lookup, checks, and any walk complete. S2 registers the
 * result and drives every consumer pulse. Hits sustain one operation per
 * cycle. Eligible last-page hits enter S2 directly from issue.
 * Faults carry the VA for xtval instead of a PA; the wrapper routes
 * them to the LQ for loads/LR/AMOs or the store fault strobe for stores/SC.
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
    input logic i_iss_atomic,  // AMO, LR or SC: checked against the atomic PMA map
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

    // LQ look-ahead: the surviving S1 tag, or the live issue tag.
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

  localparam int unsigned PpnBits = riscv_pkg::PhysAddrBits - 12;

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
    logic atomic;
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
    iss_in.atomic = i_iss_atomic;
    iss_in.store_data = i_iss_store_data;
    iss_in.amo_rs2 = i_iss_amo_rs2;
  end

  logic s0_valid_q, s1_valid_q;
  iss_payload_t s0_q, s1_q;
  logic s1_walk_asked_q;

  // Full flush empties the pipe; partial flush kills younger operations in
  // S0, S1, S2, and at issue. MEM_RS does not gate issue on same-cycle flush
  // (reservation_station/README.md, "Flushes"). Without an issue kill, this
  // pipe could deliver an address or fault after the flushed ROB tag is reused.
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
  logic [2:0][PpnBits-1:0] tlb_ppn;
  logic [2:0] tlb_hi_nonzero;
  logic [2:0] tlb_r, tlb_w, tlb_x, tlb_u, tlb_d;
  logic [2:0] tlb_device_page;
  // Per-entry permission and atomic PMA checks. Port 0 uses S1's access type;
  // the early ports request store permissions.
  logic [2:0] tlb_perm_ok, tlb_atomic_page, tlb_clean_hit;

  assign tlb_vpn[0] = s1_q.va[38:12];

  // Walk-response bypass: resolve the held op straight from a matching
  // response (the install lands the same edge for future ops).
  logic walk_resp_for_s1;
  assign walk_resp_for_s1 = i_walk_resp_valid && s1_valid_q && (i_walk_resp.vpn == s1_q.va[38:12]);

  // Resolve TLB and walk leaves in parallel, for timing. A TLB hit wins over
  // a simultaneous walk response.
  logic [PpnBits-1:0] walk_ppn;
  always_comb begin
    unique case (i_walk_resp.level)
      2'd2: walk_ppn = {i_walk_resp.ppn[PpnBits-1:18], s1_q.va[29:12]};
      2'd1: walk_ppn = {i_walk_resp.ppn[PpnBits-1:9], s1_q.va[20:12]};
      default: walk_ppn = i_walk_resp.ppn[PpnBits-1:0];
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
  assign tlb_pa  = riscv_pkg::XLEN'({tlb_ppn[0], s1_q.va[11:0]});
  assign walk_pa = riscv_pkg::XLEN'({walk_ppn, s1_q.va[11:0]});
  logic walk_device_page;
  assign walk_device_page = riscv_pkg::pma_device_ok(walk_pa);

  // PMA permits BRAM and cached DDR for all access types, plus device windows
  // for non-atomic loads and stores. DTLB hits use per-entry checks; walk
  // responses are checked here.
  function automatic logic leaf_pma_ok(input logic [riscv_pkg::XLEN-1:0] pa,
                                       input logic device_page);
    leaf_pma_ok = riscv_pkg::pma_atomic_ok(pa) || (device_page && !s1_q.atomic);
  endfunction

  riscv_pkg::data_fault_kind_e tlb_fault, walk_fault;
  always_comb begin
    tlb_fault = riscv_pkg::DFAULT_NONE;
    if (!tlb_perm_ok[0]) begin
      tlb_fault = riscv_pkg::DFAULT_PAGE;
    end else if (tlb_hi_nonzero[0] ||
                 !(tlb_atomic_page[0] || (tlb_device_page[0] && !s1_q.atomic))) begin
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
      end else if ((|i_walk_resp.ppn[riscv_pkg::PtePpnBits-1:PpnBits]) || !leaf_pma_ok(
              walk_pa, walk_device_page
          )) begin
        walk_fault = riscv_pkg::DFAULT_ACCESS;
      end
    end
  end

  logic [riscv_pkg::XLEN-1:0] tlb_resolve_addr, walk_resolve_addr;
  assign tlb_resolve_addr  = (tlb_fault == riscv_pkg::DFAULT_NONE) ? tlb_pa : s1_q.va;
  assign walk_resolve_addr = (walk_fault == riscv_pkg::DFAULT_NONE) ? walk_pa : s1_q.va;

  // MMIO requires a fault-free device-page leaf and a non-atomic operation.
  // Compute each candidate before selecting TLB or walk response, for timing.
  (* keep = "true" *) logic tlb_is_mmio, walk_is_mmio;
  assign tlb_is_mmio = tlb_perm_ok[0] && !tlb_hi_nonzero[0] && !s1_q.atomic && tlb_device_page[0];
  assign walk_is_mmio = (i_walk_resp.fault_kind == riscv_pkg::DFAULT_NONE) && leaf_perm_ok(
      i_walk_resp.perm_r,
      i_walk_resp.perm_w,
      i_walk_resp.perm_x,
      i_walk_resp.perm_u,
      i_walk_resp.perm_d
  ) && !(|i_walk_resp.ppn[riscv_pkg::PtePpnBits-1:PpnBits]) && !s1_q.atomic && walk_device_page;
  logic resolve_is_mmio;

  // Resolution select, in architectural priority order:
  //   1. Misalignment, when i_trap_misaligned is set. It is checked on the VA
  //      before translation, so an access that traps as misaligned never
  //      walks.
  //   2. A non-canonical VA: page fault, no walk.
  //   3. A DTLB hit: the permission check with the current SUM, MXR, and
  //      effective privilege, then the PMA check on the PA, where a leaf
  //      outside the map is an access fault, and so is an AMO, LR, or SC
  //      onto the device quadrant. Loads need R, or X with MXR.
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
    resolve_is_mmio = riscv_pkg::pma_device_quadrant(s1_q.va);
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

  // Return PA only for a fault-free TLB or walk result; otherwise retain VA
  // for xtval. Store VA, PPN, and the select separately in S2, for timing.
  logic resolve_pa;
  logic [PpnBits-1:0] resolve_ppn;
  assign resolve_pa = s1_valid_q && !(i_trap_misaligned && s1_misaligned) && !s1_noncanonical &&
      (tlb_hit[0] ? (tlb_fault == riscv_pkg::DFAULT_NONE) :
                    (walk_resp_for_s1 && (walk_fault == riscv_pkg::DFAULT_NONE)));
  assign resolve_ppn = tlb_hit[0] ? tlb_ppn[0] : walk_ppn;

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

  // ---------------------------------------------------------------------------
  // Last-page translation buffer (intra-page bypass directly into S2)
  // ---------------------------------------------------------------------------
  logic last_valid_q;
  logic [riscv_pkg::Sv39VpnBits-1:0] last_vpn_q;
  logic [PpnBits-1:0] last_ppn_q;
  logic last_priv_u_q;
  logic last_sum_q;
  logic last_mxr_q;
  logic last_perm_r_q, last_perm_w_q, last_perm_x_q, last_perm_u_q, last_perm_d_q;
  logic last_is_mmio_q;
  logic last_atomic_ok_q;

  // Live incoming op qualification for bypass
  logic iss_misaligned;
  always_comb begin
    unique case (iss_in.size)
      riscv_pkg::MEM_SIZE_HALF:   iss_misaligned = iss_in.va[0];
      riscv_pkg::MEM_SIZE_WORD:   iss_misaligned = |iss_in.va[1:0];
      riscv_pkg::MEM_SIZE_DOUBLE: iss_misaligned = |iss_in.va[2:0];
      default:                    iss_misaligned = 1'b0;  // byte
    endcase
  end

  logic iss_noncanonical;
  assign iss_noncanonical = !riscv_pkg::sv39_va_canonical(iss_in.va);

  logic last_priv_match;
  assign last_priv_match = (i_eff_priv_u == last_priv_u_q) &&
                           (i_sum == last_sum_q) &&
                           (i_mxr == last_mxr_q);

  logic last_priv_ok;
  assign last_priv_ok = last_perm_u_q ? (i_eff_priv_u || i_sum) : !i_eff_priv_u;

  logic iss_perm_ok;
  assign iss_perm_ok = iss_in.store_perms ?
      (last_priv_ok && last_perm_w_q && last_perm_d_q) :
      (last_priv_ok && (last_perm_r_q || (i_mxr && last_perm_x_q)));

  logic iss_pma_ok;
  assign iss_pma_ok = last_atomic_ok_q || (last_is_mmio_q && !iss_in.atomic);

  logic iss_can_bypass;
  assign iss_can_bypass = i_iss_valid && i_active && !iss_killed && !i_tlb_invalidate &&
      !s0_valid_q && (!s1_valid_q || s1_killed) &&
      last_valid_q && last_priv_match &&
      (iss_in.va[38:12] == last_vpn_q) &&
      !(i_trap_misaligned && iss_misaligned) &&
      !iss_noncanonical &&
      iss_perm_ok && iss_pma_ok;

  // The buffer captures a clean translation. For a DTLB hit the clean check
  // is the TLB's per-entry verdict, selected with the hit, so the capture
  // enable does not wait on the fault select.
  logic last_capture;
  (* keep = "true" *) wire last_capture_qualified = s1_valid_q && !s1_killed &&
      !(i_trap_misaligned && s1_misaligned) && !s1_noncanonical;
  (* keep = "true" *) wire last_capture_walk_good =
      walk_resp_for_s1 && (walk_fault == riscv_pkg::DFAULT_NONE);
  // Apply the hit's clean verdict after request and walk qualification.
`ifdef FROST_XILINX_PRIMS
  (* dont_touch = "true" *) LUT4 #(
      .INIT(16'ha280)
  ) u_last_capture (
      .I0(last_capture_qualified),
      .I1(tlb_hit[0]),
      .I2(tlb_clean_hit[0]),
      .I3(last_capture_walk_good),
      .O (last_capture)
  );
`else
  assign last_capture = last_capture_qualified &&
      (tlb_hit[0] ? tlb_clean_hit[0] : last_capture_walk_good);
`endif
  always_ff @(posedge i_clk) begin
    if (!i_rst_n || i_flush_all || i_tlb_invalidate || !i_active) begin
      last_valid_q <= 1'b0;
    end else if (last_capture) begin
      last_valid_q  <= 1'b1;
      last_vpn_q    <= s1_q.va[38:12];
      last_ppn_q    <= resolve_ppn;
      last_priv_u_q <= i_eff_priv_u;
      last_sum_q    <= i_sum;
      last_mxr_q    <= i_mxr;
      if (tlb_hit[0]) begin
        last_perm_r_q    <= tlb_r[0];
        last_perm_w_q    <= tlb_w[0];
        last_perm_x_q    <= tlb_x[0];
        last_perm_u_q    <= tlb_u[0];
        last_perm_d_q    <= tlb_d[0];
        last_is_mmio_q   <= tlb_is_mmio;
        last_atomic_ok_q <= tlb_atomic_page[0];
      end else begin
        last_perm_r_q    <= i_walk_resp.perm_r;
        last_perm_w_q    <= i_walk_resp.perm_w;
        last_perm_x_q    <= i_walk_resp.perm_x;
        last_perm_u_q    <= i_walk_resp.perm_u;
        last_perm_d_q    <= i_walk_resp.perm_d;
        last_is_mmio_q   <= walk_is_mmio;
        last_atomic_ok_q <= riscv_pkg::pma_atomic_ok(walk_pa);
      end
    end
  end

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
          s0_valid_q <= 1'b0;
          s1_walk_asked_q <= 1'b0;
        end else if (iss_can_bypass) begin
          // Bypassed directly to S2: S1 stays empty.
          s1_valid_q <= 1'b0;
          s0_valid_q <= 1'b0;
          s1_walk_asked_q <= 1'b0;
        end else begin
          s1_valid_q <= i_iss_valid && i_active && !iss_killed;
          s0_valid_q <= 1'b0;
          s1_walk_asked_q <= 1'b0;
        end
      end else begin
        // S1 held (unresolved): one op may slip in behind it. s0_q already
        // holds it (see below).
        if (i_iss_valid && i_active && !s0_valid_q && !iss_killed) begin
          s0_valid_q <= 1'b1;
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

  // S1's payload loads on every edge where S1 can load: the skid's op, else
  // the issue's, including one that bypasses to S2 and leaves S1 empty.
  // Every use of the payload is qualified by s1_valid_q, or for the walk VPN
  // by the walk request, so only s1_valid_q waits on the bypass verdict.
  // The issue VA is the base-plus-offset sum formed before this module. The
  // skid choice selects in one LUT per bit after the full sum, and the
  // primitive keeps the choice and the load enable out of the adder's
  // operands, where they would run the whole carry chain.
  logic s1_take_s0;
  assign s1_take_s0 = s0_valid_q && !s0_killed;
  logic [riscv_pkg::XLEN-1:0] s1_load_va;
  for (genvar b = 0; b < riscv_pkg::XLEN; b++) begin : gen_s1_load_va
`ifdef FROST_XILINX_PRIMS
    // I0 ? I2 : I1.
    (* dont_touch = "true" *)
    LUT3 #(
        .INIT(8'hE4)
    ) u_s1_load_va (
        .I0(s1_take_s0),
        .I1(iss_in.va[b]),
        .I2(s0_q.va[b]),
        .O (s1_load_va[b])
    );
`else
    assign s1_load_va[b] = s1_take_s0 ? s0_q.va[b] : iss_in.va[b];
`endif
  end
  iss_payload_t s1_load;
  always_comb begin
    s1_load = s1_take_s0 ? s0_q : iss_in;
    s1_load.va = s1_load_va;
  end
  always_ff @(posedge i_clk) begin
    if (s1_can_load) s1_q <= s1_load;
  end

  // Sample issue while the skid is empty, then hold it while s0_valid_q is
  // set. Only valid skid data is consumed.
  always_ff @(posedge i_clk) begin
    if (!s0_valid_q) s0_q <= iss_in;
  end

`ifndef SYNTHESIS
  logic reset_seen_q = 1'b0;
  always_ff @(posedge i_clk) if (!i_rst_n) reset_seen_q <= 1'b1;
  always_comb
    if (reset_seen_q && i_rst_n && !$isunknown({s1_valid_q, s1_killed, last_capture}))
      p_last_capture_exact :
      assert (last_capture == (s1_move && (resolve_fault == riscv_pkg::DFAULT_NONE)));
  // Reference payload loaded only when an op slips in behind a held S1. Both
  // hold the same op whenever the skid is valid.
  iss_payload_t s0_ref_q;
  always_ff @(posedge i_clk) begin
    if (i_rst_n && !i_flush_all && !s1_can_load && i_iss_valid && i_active && !s0_valid_q &&
        !iss_killed)
      s0_ref_q <= iss_in;
    if (reset_seen_q && i_rst_n && s0_valid_q) begin
      p_s0_payload_matches_slip_in : assert (s0_q == s0_ref_q);
    end
  end
`endif

  // The registered skid-valid bit stalls MEM_RS issue.
  assign o_stall = s0_valid_q;

  // ---------------------------------------------------------------------------
  // S2 registers the resolution. Every consumer pulse fires from here.
  // ---------------------------------------------------------------------------
  logic s2_valid_q;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] s2_tag_q;
  logic [riscv_pkg::XLEN-1:0] s2_va_q;
  logic [PpnBits-1:0] s2_ppn_q;
  logic s2_pa_q;
  logic s2_is_mmio_q;
  riscv_pkg::data_fault_kind_e s2_fault_q;
  logic s2_needs_sq_q, s2_is_sc_q;
  logic [riscv_pkg::XLEN-1:0] s2_store_data_q, s2_amo_rs2_q;

  // Compute S2's next MMIO bit for both tlb_is_mmio values and select last,
  // for timing. Hold the bit when no operation resolves.
  (* keep = "true" *) logic [1:0] s2_mmio_cases;
  logic s2_mmio_next;
  for (genvar mmio = 0; mmio < 2; mmio++) begin : gen_s2_mmio_cases
    logic resolved_mmio;
    always_comb begin
      resolved_mmio = riscv_pkg::pma_device_quadrant(s1_q.va);
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

  // The TLB verdicts (hit, permission, high PPN, atomic and device page)
  // arrive together after VPN matching and winner selection. The fault
  // without the TLB leaf and the condition that applies the leaf are
  // prepared first, and the leaf, a function of those verdicts alone, is
  // applied last.
  (* keep = "true" *) logic s2_leaf_applies;
  (* keep = "true" *) riscv_pkg::data_fault_kind_e s2_fault_without_leaf;
  riscv_pkg::data_fault_kind_e s2_leaf_fault;
  logic [1:0] s2_fault_next;
  always_comb begin
    s2_fault_without_leaf = riscv_pkg::DFAULT_NONE;
    if (s1_valid_q) begin
      if (i_trap_misaligned && s1_misaligned) s2_fault_without_leaf = riscv_pkg::DFAULT_MISALIGN;
      else if (s1_noncanonical) s2_fault_without_leaf = riscv_pkg::DFAULT_PAGE;
      else if (walk_resp_for_s1) s2_fault_without_leaf = walk_fault;
    end
    s2_leaf_fault = riscv_pkg::DFAULT_NONE;
    if (!tlb_perm_ok[0]) s2_leaf_fault = riscv_pkg::DFAULT_PAGE;
    else if (tlb_hi_nonzero[0] || !(tlb_atomic_page[0] || (tlb_device_page[0] && !s1_q.atomic)))
      s2_leaf_fault = riscv_pkg::DFAULT_ACCESS;
  end
  assign s2_leaf_applies = s1_valid_q && !(i_trap_misaligned && s1_misaligned) && !s1_noncanonical;
  assign s2_fault_next   = s2_leaf_applies && tlb_hit[0] ? s2_leaf_fault : s2_fault_without_leaf;

  // The DTLB selects the clean data-access verdict with the matching entry.
  // Select that verdict directly instead of rebuilding its permission and
  // page-attribute checks after selection.
  (* keep = "true" *)wire s2_pa_leaf_selected = s2_leaf_applies && !s1_killed && tlb_hit[0];
  // verilog_format: off
  (* keep = "true" *) wire s2_pa_without_leaf =
      s1_killed || (s2_fault_without_leaf == riscv_pkg::DFAULT_NONE);
  // verilog_format: on
  wire s2_pa_next = s2_pa_leaf_selected ? tlb_clean_hit[0] : s2_pa_without_leaf;

  // S2's VA takes S1's VA when S1 advances, else the issue address, which is
  // the base-plus-offset sum formed before this module. s1_move settles after
  // the DTLB hit, so it selects in one LUT per bit after the full sum. The
  // primitive keeps the select out of the adder's operands, where it would
  // run the whole carry chain.
  logic [riscv_pkg::XLEN-1:0] s2_va_next;
  for (genvar b = 0; b < riscv_pkg::XLEN; b++) begin : gen_s2_va_next
`ifdef FROST_XILINX_PRIMS
    // I0 ? I2 : I1.
    (* dont_touch = "true" *)
    LUT3 #(
        .INIT(8'hE4)
    ) u_s2_va_next (
        .I0(s1_move),
        .I1(iss_in.va[b]),
        .I2(s1_q.va[b]),
        .O (s2_va_next[b])
    );
`else
    assign s2_va_next[b] = s1_move ? s1_q.va[b] : iss_in.va[b];
`endif
  end

`ifdef DMMU_VA_NEXT_LOCAL_PROOF
  // S1's and S2's next payloads equal the whole-payload selects, for every
  // register state and input.
  always_comb begin
    p_s1_next_exact :
    assert ((s1_can_load ? s1_load : s1_q) ==
            (s1_can_load ? (s0_valid_q && !s0_killed ? s0_q : iss_in) : s1_q));
    p_s2_va_next_exact : assert (s2_va_next == (s1_move ? s1_q.va : iss_in.va));
  end
`endif

  // S2 holds an operation for one cycle and its readers wait for s2_valid_q, so
  // the payload loads every cycle and only the valid bit reads the bypass.
  always_ff @(posedge i_clk) begin
    s2_is_mmio_q <= iss_can_bypass ? last_is_mmio_q : s2_mmio_next;
    if (!i_rst_n || i_flush_all) s2_valid_q <= 1'b0;
    else s2_valid_q <= s1_move || iss_can_bypass;
    s2_tag_q <= s1_move ? s1_q.tag : iss_in.tag;
    s2_va_q <= s2_va_next;
    s2_ppn_q <= s1_move ? resolve_ppn : last_ppn_q;
    s2_pa_q <= s2_pa_next;
    s2_fault_q <= s1_move ? riscv_pkg::data_fault_kind_e'(s2_fault_next) : riscv_pkg::DFAULT_NONE;
    s2_needs_sq_q <= s1_move ? s1_q.needs_sq : iss_in.needs_sq;
    s2_is_sc_q <= s1_move ? s1_q.is_sc : iss_in.is_sc;
    s2_store_data_q <= s1_move ? s1_q.store_data : iss_in.store_data;
    s2_amo_rs2_q <= s1_move ? s1_q.amo_rs2 : iss_in.amo_rs2;
  end

`ifndef SYNTHESIS
  // Reference the operation that advances into S2, with its resolved address.
  // A killed S1 operation cannot replace a live bypass's reference payload.
  // Every field a consumer reads matches it while S2 is valid.
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] ref_s2_tag_q;
  logic [riscv_pkg::XLEN-1:0] ref_s2_addr_q, ref_s2_store_data_q, ref_s2_amo_rs2_q;
  riscv_pkg::data_fault_kind_e ref_s2_fault_q;
  logic ref_s2_needs_sq_q, ref_s2_is_sc_q;
  always_ff @(posedge i_clk) begin
    if (s1_move) begin
      ref_s2_tag_q <= s1_q.tag;
      ref_s2_addr_q <= resolve_addr;
      ref_s2_fault_q <= resolve_fault;
      ref_s2_needs_sq_q <= s1_q.needs_sq;
      ref_s2_is_sc_q <= s1_q.is_sc;
      ref_s2_store_data_q <= s1_q.store_data;
      ref_s2_amo_rs2_q <= s1_q.amo_rs2;
    end else if (iss_can_bypass) begin
      ref_s2_tag_q <= iss_in.tag;
      ref_s2_addr_q <= riscv_pkg::XLEN'({last_ppn_q, iss_in.va[11:0]});
      ref_s2_fault_q <= riscv_pkg::DFAULT_NONE;
      ref_s2_needs_sq_q <= iss_in.needs_sq;
      ref_s2_is_sc_q <= iss_in.is_sc;
      ref_s2_store_data_q <= iss_in.store_data;
      ref_s2_amo_rs2_q <= iss_in.amo_rs2;
    end
    if (reset_seen_q && i_rst_n && s2_valid_q) begin
      p_s2_payload_exact :
      assert ({s2_tag_q, o_iss_out_addr, s2_fault_q, s2_needs_sq_q, s2_is_sc_q, s2_store_data_q,
               s2_amo_rs2_q} ==
              {ref_s2_tag_q, ref_s2_addr_q, ref_s2_fault_q, ref_s2_needs_sq_q, ref_s2_is_sc_q,
               ref_s2_store_data_q, ref_s2_amo_rs2_q});
    end
  end
`endif

  logic s2_killed;
  assign s2_killed = i_flush_en && s2_valid_q && is_younger(s2_tag_q, i_flush_tag, i_head_tag);

  assign o_iss_out_valid = s2_valid_q && !s2_killed && !i_flush_all;
  assign o_iss_out_lq_capture_valid = s2_valid_q && !s2_needs_sq_q;
  assign o_iss_out_sq_capture_valid = s2_valid_q && s2_needs_sq_q;
  assign o_iss_out_rob_tag = s2_tag_q;
  assign o_iss_out_addr = s2_pa_q ? riscv_pkg::XLEN'({s2_ppn_q, s2_va_q[11:0]}) : s2_va_q;
  assign o_iss_out_is_mmio = s2_is_mmio_q;
  assign o_iss_out_fault = s2_fault_q;
  assign o_iss_out_needs_sq = s2_needs_sq_q;
  assign o_iss_out_is_sc = s2_is_sc_q;
  assign o_iss_out_store_data = s2_store_data_q;
  assign o_iss_out_amo_rs2 = s2_amo_rs2_q;

  // A surviving S1 operation owns the next S2 packet. Otherwise only a live
  // issue can bypass into S2. The tag can precede bypass eligibility because
  // the LQ consumes its registered match only with an address-update packet.
  assign o_pre_rob_tag = (!s1_valid_q || s1_killed) ? iss_in.tag : s1_q.tag;
  assign o_pre_needs_lq = iss_can_bypass ?
      (i_iss_valid && !iss_in.needs_sq) : (s1_valid_q && !s1_q.needs_sq);

  // Request a walk once for a live, canonical S1 miss with no trapping
  // misalignment or matching response. Hold valid until accepted. Suppress
  // requests during invalidate; responses are matched by VPN.
  (* keep = "true" *) logic s1_walk_eligible;
  assign s1_walk_eligible = s1_valid_q && !(i_trap_misaligned && s1_misaligned) &&
      !s1_noncanonical && !walk_resp_for_s1 && !s1_walk_asked_q &&
      !s1_killed && !i_tlb_invalidate;
  assign o_walk_req_valid = s1_walk_eligible && !tlb_hit[0];
  assign o_walk_vpn = s1_q.va[38:12];

  // ---------------------------------------------------------------------------
  // Early opportunistic ports: VA registered, lookup, result registered.
  // ---------------------------------------------------------------------------
  // Early store ports return a PA two cycles after the request when the VA is
  // canonical and the TLB hit grants store permission with an in-map PA;
  // otherwise they drop the update without stalling or faulting. Issue
  // translates again and reports faults. SQ ignores later writes once an
  // address is valid, so translation changes must flush prefilled stores.
  // The wrapper drops delayed early packets on any flush to prevent updates
  // to correct-path stores that reuse a killed tag.
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
      v = (s == 0) ? e1_valid_q : e2_valid_q;
      va = (s == 0) ? e1_va_q : e2_va_q;
      early_pa_c[s] = riscv_pkg::XLEN'({tlb_ppn[s+1], va[11:0]});
      // The store permission check and pma_data_ok(early_pa_c[s]), both from
      // the DTLB's per-entry bits.
      early_ok_c[s] = v && riscv_pkg::sv39_va_canonical(va) && tlb_hit[s+1] && tlb_perm_ok[s+1] &&
          !tlb_hi_nonzero[s+1] && (tlb_atomic_page[s+1] || tlb_device_page[s+1]);
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
  assign o_early_is_mmio = riscv_pkg::pma_device_quadrant(early_pa_q[0]);
  assign o_early2_ok = early_ok_q[1];
  assign o_early2_pa = early_pa_q[1];
  assign o_early2_is_mmio = riscv_pkg::pma_device_quadrant(early_pa_q[1]);

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
      .o_ppn(tlb_ppn),
      .o_ppn_hi_nonzero(tlb_hi_nonzero),
      .o_perm_r(tlb_r),
      .o_perm_w(tlb_w),
      .o_perm_x(tlb_x),
      .o_perm_u(tlb_u),
      .o_perm_d(tlb_d),
      .o_level(),
      .o_device_page(tlb_device_page),
      .i_perm_store({2'b11, s1_q.store_perms}),
      .i_perm_priv_u(i_eff_priv_u),
      .i_perm_sum(i_sum),
      .i_perm_mxr(i_mxr),
      .o_perm_ok(tlb_perm_ok),
      .o_atomic_page(tlb_atomic_page),
      .i_perm_atomic({2'b00, s1_q.atomic}),
      .o_clean_hit(tlb_clean_hit),
      // The instruction MMU's leaf checks; the data side uses its own.
      .i_fetch_priv_u(1'b0),
      .o_fetch_perm_fault(),
      .o_fetch_pma_bad(),
      .o_fetch_next_pma_bad(),
      .o_fetch_next_ok(),
      .o_fetch_next_ppn(),
      .o_ppn_own(),
      .o_giga(),
      .o_mega()
  );

  // The capture proof deletes the DTLB. Its clean-hit verdict is its hit with
  // no fault, as the DTLB's own checks prove. The MMIO proof reads the DTLB.
`ifdef DMMU_CAPTURE_LOCAL_PROOF
  always_comb assume (tlb_clean_hit[0] == (tlb_hit[0] && (tlb_fault == riscv_pkg::DFAULT_NONE)));
`endif
`ifdef DMMU_MMIO_LOCAL_PROOF
  // The DTLB's per-entry device-window bit is the window decode of the PPN
  // it selects, on every port.
  logic [2:0] f_tlb_device_page_ref, f_tlb_perm_ok_ref, f_tlb_atomic_page_ref;
  always_comb begin
    for (int p = 0; p < 3; p++) begin
      f_tlb_device_page_ref[p] = riscv_pkg::pma_device_ok(riscv_pkg::XLEN'({tlb_ppn[p], 12'h000}));
      // The hit's permission check (port 0 with the S1 op's access type, the
      // early slots as stores) and atomic PMA; both are clear on a miss.
      f_tlb_perm_ok_ref[p] = tlb_hit[p] &&
          (tlb_u[p] ? (i_eff_priv_u || i_sum) : !i_eff_priv_u) &&
          (((p != 0) || s1_q.store_perms) ? (tlb_w[p] && tlb_d[p]) :
                                            (tlb_r[p] || (i_mxr && tlb_x[p])));
      f_tlb_atomic_page_ref[p] = tlb_hit[p] &&
          riscv_pkg::pma_atomic_ok(riscv_pkg::XLEN'({tlb_ppn[p], 12'h000}));
    end
  end
  always_comb begin
    logic [riscv_pkg::XLEN-1:0] f_resolve_addr_ref;
    f_resolve_addr_ref = s1_q.va;
    if (resolve_pa) f_resolve_addr_ref = riscv_pkg::XLEN'({resolve_ppn, s1_q.va[11:0]});
    p_tlb_device_page_exact : assert (tlb_device_page == f_tlb_device_page_ref);
    p_tlb_leaf_checks_exact :
    assert (tlb_perm_ok == f_tlb_perm_ok_ref && tlb_atomic_page == f_tlb_atomic_page_ref);
    p_mmio_capture_exact : assert (s2_mmio_next == (s1_resolved ? resolve_is_mmio : s2_is_mmio_q));
    p_fault_capture_exact : assert (s2_fault_next == resolve_fault);
    p_resolve_mmio_exact :
    assert (resolve_is_mmio ==
        ((resolve_fault == riscv_pkg::DFAULT_NONE) &&
         riscv_pkg::pma_device_quadrant(
        resolve_addr
    )));
    // S2's split address rebuilds the resolution's address.
    p_resolve_addr_exact : assert (f_resolve_addr_ref == resolve_addr);
  end
  // A clean walk leaf is checked with the live SUM, MXR and effective
  // privilege, never with state from the walk: SUM and MXR changes keep the
  // TLBs and the walk in flight, so no other check may cache them.
  always_comb begin
    logic f_walk_perm_ref;
    f_walk_perm_ref = (i_walk_resp.perm_u ? (i_eff_priv_u || i_sum) : !i_eff_priv_u) &&
        (s1_q.store_perms ? (i_walk_resp.perm_w && i_walk_resp.perm_d) :
                            (i_walk_resp.perm_r || (i_mxr && i_walk_resp.perm_x)));
    if (i_walk_resp.fault_kind == riscv_pkg::DFAULT_NONE)
      p_walk_leaf_perm_live : assert ((walk_fault == riscv_pkg::DFAULT_PAGE) == !f_walk_perm_ref);
  end
`endif

`ifdef DMMU_CAPTURE_LOCAL_PROOF
  // Relate the issued packet and the consumer's preceding look-ahead without
  // assumptions on issue order, flushes or permission controls, and on TLB
  // answers beyond the clean-hit relation above.
  logic f_capture_past_valid = 1'b0;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] f_pre_tag_q;
  logic f_pre_needs_lq_q;
  logic f_capture_expected_q, f_bypass_expected_q;
  iss_payload_t f_capture_op_q;
  logic [riscv_pkg::XLEN-1:0] f_capture_addr_q;
  logic f_capture_mmio_q;
  riscv_pkg::data_fault_kind_e f_capture_fault_q;
  logic f_last_clear_q;
  always_ff @(posedge i_clk) begin
    f_capture_past_valid <= 1'b1;
    if (!f_capture_past_valid) assume (!i_rst_n);
    f_pre_tag_q <= o_pre_rob_tag;
    f_pre_needs_lq_q <= o_pre_needs_lq;
    f_capture_expected_q <= i_rst_n && !i_flush_all && (s1_move || iss_can_bypass);
    f_bypass_expected_q <= i_rst_n && !i_flush_all && iss_can_bypass;
    f_capture_op_q <= s1_move ? s1_q : iss_in;
    f_capture_addr_q <= s1_move ? resolve_addr : riscv_pkg::XLEN'({last_ppn_q, iss_in.va[11:0]});
    f_capture_fault_q <= s1_move ? resolve_fault : riscv_pkg::DFAULT_NONE;
    f_capture_mmio_q <= s1_move ? resolve_is_mmio : last_is_mmio_q;
    f_last_clear_q <= !i_rst_n || i_flush_all || i_tlb_invalidate || !i_active;
    if (f_capture_past_valid) begin
      p_capture_pulse : assert (s2_valid_q == f_capture_expected_q);
      p_bypass_one_cycle : assert (!f_bypass_expected_q || s2_valid_q);
      if (s2_valid_q) begin
        p_capture_payload :
        assert ({o_iss_out_rob_tag, o_iss_out_addr, o_iss_out_fault, o_iss_out_is_mmio,
                 o_iss_out_needs_sq, o_iss_out_is_sc, o_iss_out_store_data, o_iss_out_amo_rs2} ==
                {f_capture_op_q.tag, f_capture_addr_q, f_capture_fault_q, f_capture_mmio_q,
                 f_capture_op_q.needs_sq, f_capture_op_q.is_sc, f_capture_op_q.store_data,
                 f_capture_op_q.amo_rs2});
      end
      if (o_iss_out_lq_capture_valid) begin
        p_lq_lookahead_valid : assert (f_pre_needs_lq_q);
        p_lq_lookahead_tag : assert (o_iss_out_rob_tag == f_pre_tag_q);
      end
      if (f_last_clear_q) p_last_page_invalidation : assert (!last_valid_q);
      // The last-page buffer survives SUM and MXR changes only through its
      // captured-state compare: a bypass grants an access only when the
      // live SUM, MXR and privilege equal those it captured and the raw
      // leaf permissions allow the access under them.
      if (iss_can_bypass) begin
        p_bypass_live_permission :
        assert ((i_sum == last_sum_q) && (i_mxr == last_mxr_q) &&
                (i_eff_priv_u == last_priv_u_q) &&
                (last_perm_u_q ? (i_eff_priv_u || i_sum) : !i_eff_priv_u) &&
                (iss_in.store_perms ? (last_perm_w_q && last_perm_d_q) :
                                      (last_perm_r_q || (i_mxr && last_perm_x_q))));
      end
      cover (f_bypass_expected_q && o_iss_out_lq_capture_valid);
      cover (f_bypass_expected_q && o_iss_out_sq_capture_valid);
      cover (i_rst_n && !i_flush_all && s1_resolved && s1_killed && iss_can_bypass);
    end
  end
`endif

`ifndef SYNTHESIS
`ifdef FROST_COVERAGE
  // A cached translation takes priority over a matching walker response.
  cover_tlb_hit_with_walk_response :
  cover property (@(posedge i_clk) disable iff (!reset_seen_q || !i_rst_n)
      s1_move && tlb_hit[0] && walk_resp_for_s1 &&
      !s1_noncanonical && !(i_trap_misaligned && s1_misaligned));
  // A late fault from a discarded operation cannot fault a different VPN.
  cover_stale_walk_fault_with_live_op :
  cover property (@(posedge i_clk) disable iff (!reset_seen_q || !i_rst_n)
      s1_valid_q && !s1_killed && i_walk_resp_valid && !walk_resp_for_s1 &&
      (i_walk_resp.fault_kind != riscv_pkg::DFAULT_NONE));
  // Recovery discards an operation on its matching walk-response edge.
  cover_flush_on_walk_response :
  cover property (@(posedge i_clk) disable iff (!reset_seen_q || !i_rst_n)
      s1_killed && walk_resp_for_s1);
`endif
`endif

endmodule : dmmu
