/*
 *    Copyright (c) 2026 John Goodacre.
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
 * l2tlb: second-level translation cache between the L1 TLBs and the walker.
 *
 * It sits on the walker's request path and speaks the walker's protocol: the
 * request handshake, a one-cycle response pulse with the requested VPN echoed,
 * and a discard input. A request looks up a 4-way, 128-set array (512 entries,
 * 2 MiB of 4 KiB pages) held in block RAM. A hit answers two cycles after the
 * request fires with the stored {PPN, RWXUD, G}; a miss goes to the walker, and
 * the clean 4 KiB translation it returns is stored on its way back. Superpage,
 * faulting and discarded walks are never stored: the L1 TLBs and the walker's
 * pointer cache already serve superpages in one read, and a PTE that changes
 * from invalid to valid is then seen by the next walk without SFENCE.VMA
 * (Svvptc), because this array holds no negative entries.
 *
 * Entries carry the ASID they were filled under and the leaf's global bit
 * (the walker ORs the bit over the levels it descended). A lookup matches an
 * entry of its own ASID or a global entry of any ASID, as in the L1 TLBs. The
 * stored permissions are the PTE's own bits; SUM, MXR and the privilege level
 * are applied by the requesting MMU on every use, so changing them needs no
 * flush here.
 *
 * Flushes arrive as riscv_pkg::tlb_flush_t (see its comment for the forms).
 * Flush-all clears every valid bit in one cycle. A page flush reads the page's
 * set and clears the matching ways. An ASID flush, with or without a page,
 * scans the sets, two cycles for the first and one for each next, and clears
 * ways of that ASID that are not global. While a flush runs the array accepts
 * no request, so no stale entry can answer. A flush that arrives during
 * another flush becomes a flush-all. A flush or discard aborts a lookup in
 * flight; the requester's own invalidate already drops that response.
 */
module l2tlb #(
    parameter int unsigned SETS = 128,
    parameter int unsigned WAYS = 4,
    localparam int unsigned SetBits = $clog2(SETS),
    localparam int unsigned WayBits = $clog2(WAYS),
    localparam int unsigned VpnBits = riscv_pkg::Sv39VpnBits,
    localparam int unsigned TagBits = VpnBits - SetBits,
    localparam int unsigned AsidW = riscv_pkg::AsidBits,
    localparam int unsigned PpnBits = riscv_pkg::PtePpnBits,
    // g, ASID, VPN tag, PPN, R W X U D
    localparam int unsigned EntryBits = 1 + AsidW + TagBits + PpnBits + 5
) (
    input logic i_clk,
    input logic i_rst,

    // The ASID that lookups and fills use (satp.ASID), and the flush command.
    input logic [AsidW-1:0] i_asid,
    input riscv_pkg::tlb_flush_t i_flush,
    // The translation changed (SFENCE.VMA, satp, MPRV): drop any lookup.
    input logic i_discard,

    // Requester side: the walker's protocol.
    input  logic                               i_req_valid,
    output logic                               o_req_ready,
    input  logic                 [VpnBits-1:0] i_req_vpn,
    output logic                               o_resp_valid,
    output riscv_pkg::ptw_resp_t               o_resp,

    // Walker side.
    output logic                               o_ptw_req_valid,
    input  logic                               i_ptw_req_ready,
    output logic                 [VpnBits-1:0] o_ptw_req_vpn,
    input  logic                               i_ptw_resp_valid,
    input  riscv_pkg::ptw_resp_t               i_ptw_resp
);

  typedef enum logic [3:0] {
    S_IDLE,
    S_CMP,    // the set was read at the request; compare the four ways
    S_RESP,   // present the registered hit
    S_FWD,    // ask the walker
    S_WAIT,   // the walker is working; its response fills the array
    S_FL_RD,  // flush: first set read
    S_FL_CMP  // flush: compare, clear, and read the next set
  } state_e;

  state_e state_q;

  logic [VpnBits-1:0] vpn_q;
  logic [AsidW-1:0] asid_q;
  logic [SetBits-1:0] set_q;

  // Valid bits live in flops so a flush-all is one cycle and the fill can look
  // for a free way; the entries themselves are in block RAM.
  logic [WAYS-1:0][SETS-1:0] valid_q;
  logic [EntryBits-1:0] rd_q[WAYS];
  logic [SetBits-1:0] rd_addr;
  logic [EntryBits-1:0] fill_entry;
  logic fill_en;
  logic [WayBits-1:0] victim;

  // ---------------------------------------------------------------------------
  // Entry packing
  // ---------------------------------------------------------------------------
  function automatic logic [EntryBits-1:0] pack_entry(input riscv_pkg::ptw_resp_t r,
                                                      input logic [AsidW-1:0] asid);
    pack_entry = {
      r.perm_g,
      asid,
      r.vpn[VpnBits-1:SetBits],
      r.ppn,
      r.perm_r,
      r.perm_w,
      r.perm_x,
      r.perm_u,
      r.perm_d
    };
  endfunction

  function automatic logic ent_g(input logic [EntryBits-1:0] e);
    ent_g = e[EntryBits-1];
  endfunction
  function automatic logic [AsidW-1:0] ent_asid(input logic [EntryBits-1:0] e);
    ent_asid = e[EntryBits-2-:AsidW];
  endfunction
  function automatic logic [TagBits-1:0] ent_tag(input logic [EntryBits-1:0] e);
    ent_tag = e[EntryBits-2-AsidW-:TagBits];
  endfunction

  // ---------------------------------------------------------------------------
  // Flush command capture
  // ---------------------------------------------------------------------------
  logic flush_en_q;
  logic flush_start;
  always_ff @(posedge i_clk) begin
    if (i_rst) flush_en_q <= 1'b0;
    else flush_en_q <= i_flush.en;
  end
  assign flush_start = i_flush.en && !flush_en_q;

  riscv_pkg::tlb_flush_t fl_q;  // the flush operation being run
  logic fl_scan_q;  // the operation visits every set
  logic flush_busy;
  assign flush_busy = (state_q == S_FL_RD) || (state_q == S_FL_CMP);
  logic flush_all_now;  // clear everything: no filter, or a flush that overlaps another
  assign flush_all_now = flush_start && (!(i_flush.use_va || i_flush.use_asid) || flush_busy);

  // ---------------------------------------------------------------------------
  // Array read: while idle, the offered request's set index feeds the block
  // RAMs, so the set is read in the cycle the request fires and answers in the
  // next. A flush scan reads the following set while comparing this one.
  // ---------------------------------------------------------------------------
  assign rd_addr = (state_q == S_IDLE) ? i_req_vpn[SetBits-1:0] :
                   (state_q == S_FL_CMP && fl_scan_q) ? set_q + 1'b1 : set_q;
  for (genvar w = 0; w < WAYS; w++) begin : g_way
    (* ram_style = "block" *) logic [EntryBits-1:0] mem[SETS];
    always_ff @(posedge i_clk) begin
      if (fill_en && victim == WayBits'(w)) mem[set_q] <= fill_entry;
      rd_q[w] <= mem[rd_addr];
    end
  end

  // ---------------------------------------------------------------------------
  // Lookup compare (state S_CMP)
  // ---------------------------------------------------------------------------
  logic [WAYS-1:0] way_hit;
  always_comb begin
    for (int w = 0; w < WAYS; w++) begin
      way_hit[w] = valid_q[w][set_q] && (ent_tag(rd_q[w]) == vpn_q[VpnBits-1:SetBits]) &&
          (ent_g(rd_q[w]) || (ent_asid(rd_q[w]) == asid_q));
    end
  end
  logic any_hit;
  assign any_hit = |way_hit;

  // Two entries can match one lookup only when a page's global bit changed
  // between fills; the lowest way answers.
  logic [EntryBits-1:0] hit_entry;
  always_comb begin
    hit_entry = '0;
    for (int w = WAYS - 1; w >= 0; w--) if (way_hit[w]) hit_entry = rd_q[w];
  end

  riscv_pkg::ptw_resp_t hit_resp_q;
  logic hit_resp_valid_q;

  // ---------------------------------------------------------------------------
  // Flush compare (state S_FL_CMP)
  // ---------------------------------------------------------------------------
  logic [WAYS-1:0] fl_kill;
  always_comb begin
    for (int w = 0; w < WAYS; w++) begin
      fl_kill[w] = valid_q[w][set_q] &&
          (!fl_q.use_va || ent_tag(rd_q[w]) == fl_q.vpn[VpnBits-1:SetBits]) &&
          (!fl_q.use_asid || (ent_asid(rd_q[w]) == fl_q.asid && !ent_g(rd_q[w])));
    end
  end

  // ---------------------------------------------------------------------------
  // Fill (state S_WAIT, clean 4 KiB response, no discard or flush this cycle)
  // ---------------------------------------------------------------------------
  assign fill_en = (state_q == S_WAIT) && i_ptw_resp_valid &&
                   (i_ptw_resp.fault_kind == riscv_pkg::DFAULT_NONE) &&
                   (i_ptw_resp.level == 2'd0) && !i_discard && !flush_start && !i_flush.en;
  // The entry takes the ASID the walk was requested under.
  assign fill_entry = pack_entry(i_ptw_resp, asid_q);

  logic [WayBits-1:0] rr_q;
  always_comb begin
    victim = rr_q;
    for (int w = WAYS - 1; w >= 0; w--) if (!valid_q[w][set_q]) victim = WayBits'(w);
  end

  // ---------------------------------------------------------------------------
  // Control
  // ---------------------------------------------------------------------------
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      state_q <= S_IDLE;
      valid_q <= '0;
      rr_q <= '0;
      hit_resp_valid_q <= 1'b0;
      fl_scan_q <= 1'b0;
    end else begin
      hit_resp_valid_q <= 1'b0;

      if (fill_en) begin
        valid_q[victim][set_q] <= 1'b1;
        rr_q <= rr_q + 1'b1;
      end

      case (state_q)
        S_IDLE: begin
          if (i_req_valid && o_req_ready) begin
            vpn_q   <= i_req_vpn;
            asid_q  <= i_asid;
            set_q   <= i_req_vpn[SetBits-1:0];
            state_q <= S_CMP;
          end
        end
        S_CMP: begin
          if (any_hit) begin
            hit_resp_q.fault_kind <= riscv_pkg::DFAULT_NONE;
            hit_resp_q.vpn <= vpn_q;
            hit_resp_q.ppn <= hit_entry[PpnBits+4:5];
            hit_resp_q.level <= 2'd0;
            hit_resp_q.perm_r <= hit_entry[4];
            hit_resp_q.perm_w <= hit_entry[3];
            hit_resp_q.perm_x <= hit_entry[2];
            hit_resp_q.perm_u <= hit_entry[1];
            hit_resp_q.perm_d <= hit_entry[0];
            hit_resp_q.perm_g <= ent_g(hit_entry);
            hit_resp_valid_q <= 1'b1;
            state_q <= S_RESP;
          end else begin
            // A miss asks the walker in this same cycle.
            state_q <= i_ptw_req_ready ? S_WAIT : S_FWD;
          end
        end
        S_RESP:  state_q <= S_IDLE;
        S_FWD:   if (i_ptw_req_ready) state_q <= S_WAIT;
        S_WAIT:  if (i_ptw_resp_valid) state_q <= S_IDLE;
        S_FL_RD: state_q <= S_FL_CMP;
        S_FL_CMP: begin
          for (int w = 0; w < WAYS; w++) if (fl_kill[w]) valid_q[w][set_q] <= 1'b0;
          if (fl_scan_q && set_q != SetBits'(SETS - 1)) begin
            set_q   <= set_q + 1'b1;
            state_q <= S_FL_CMP;
          end else begin
            state_q <= S_IDLE;
          end
        end
        default: state_q <= S_IDLE;
      endcase

      // A discard drops the lookup. The walker is discarded alongside, so a
      // walk already running ends silently.
      if (i_discard && !flush_busy) begin
        state_q <= S_IDLE;
        hit_resp_valid_q <= 1'b0;
      end

      // Flushes win over everything above.
      if (flush_all_now) begin
        valid_q <= '0;
        state_q <= S_IDLE;
        hit_resp_valid_q <= 1'b0;
      end else if (flush_start) begin
        fl_q <= i_flush;
        fl_scan_q <= !i_flush.use_va;
        set_q <= i_flush.use_va ? i_flush.vpn[SetBits-1:0] : '0;
        state_q <= S_FL_RD;
        hit_resp_valid_q <= 1'b0;
      end
    end
  end

  assign o_req_ready = (state_q == S_IDLE) && !i_discard && !i_flush.en && !flush_busy;

  assign o_ptw_req_valid = (state_q == S_FWD) || ((state_q == S_CMP) && !any_hit);
  assign o_ptw_req_vpn = vpn_q;

  // The walker's response passes straight through; a hit answers from its register.
  // A discard in the response's own cycle suppresses it, as at the walker.
  assign o_resp_valid = (hit_resp_valid_q || ((state_q == S_WAIT) && i_ptw_resp_valid)) &&
                        !i_discard;
  assign o_resp = hit_resp_valid_q ? hit_resp_q : i_ptw_resp;

`ifdef FORMAL
  // Reference: for one watched page and lookup ASID, shadow the entries the
  // array may legitimately hold (one non-global entry filled under the lookup
  // ASID, one global entry), kill them with the same rules the privileged spec
  // gives each flush form, and check every hit against them. The array's
  // multi-cycle flush engine must finish before the next lookup, so a shadow
  // that dies at the flush's first cycle bounds every later hit.
  logic f_past_valid;
  initial f_past_valid = 1'b0;
  always_ff @(posedge i_clk) f_past_valid <= 1'b1;

  initial assume (i_rst);

  (* anyconst *)logic [VpnBits-1:0] f_vpn;
  (* anyconst *)logic [  AsidW-1:0] f_la;

  // The translation-changed discard accompanies every flush, the command holds
  // steady while it is raised, and a walker response echoes the request.
  always_comb begin
    if (i_flush.en) assume (i_discard);
    if ((state_q == S_WAIT) && i_ptw_resp_valid) assume (i_ptw_resp.vpn == vpn_q);
  end
  always_ff @(posedge i_clk) begin
    if (f_past_valid && $past(i_flush.en) && i_flush.en) assume ($stable(i_flush));
  end

  logic f_live_ng, f_live_g;
  logic [PpnBits-1:0] f_ng_ppn, f_g_ppn;
  logic [4:0] f_ng_perm, f_g_perm;

  logic f_kills_ng, f_kills_g;
  assign f_kills_ng = i_flush.en && (!i_flush.use_va || i_flush.vpn == f_vpn) &&
                      (!i_flush.use_asid || i_flush.asid == f_la);
  // An ASID filter, with or without a page, never removes a global entry.
  assign f_kills_g = i_flush.en && !i_flush.use_asid && (!i_flush.use_va || i_flush.vpn == f_vpn);

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      f_live_ng <= 1'b0;
      f_live_g  <= 1'b0;
    end else begin
      if (f_kills_ng) f_live_ng <= 1'b0;
      if (f_kills_g) f_live_g <= 1'b0;
      if (fill_en && i_ptw_resp.vpn == f_vpn) begin
        if (i_ptw_resp.perm_g) begin
          f_live_g <= 1'b1;
          f_g_ppn <= i_ptw_resp.ppn;
          f_g_perm <= {
            i_ptw_resp.perm_r,
            i_ptw_resp.perm_w,
            i_ptw_resp.perm_x,
            i_ptw_resp.perm_u,
            i_ptw_resp.perm_d
          };
        end else if (asid_q == f_la) begin
          f_live_ng <= 1'b1;
          f_ng_ppn <= i_ptw_resp.ppn;
          f_ng_perm <= {
            i_ptw_resp.perm_r,
            i_ptw_resp.perm_w,
            i_ptw_resp.perm_x,
            i_ptw_resp.perm_u,
            i_ptw_resp.perm_d
          };
        end
      end
    end
  end

  logic f_target;  // the lookup being compared is the watched one
  assign f_target = (state_q == S_CMP) && (vpn_q == f_vpn) && (asid_q == f_la);

  logic f_hit_ng_data, f_hit_g_data;
  assign f_hit_ng_data = f_live_ng && (hit_entry[PpnBits+4:5] == f_ng_ppn) &&
                         (hit_entry[4:0] == f_ng_perm) && !ent_g(
      hit_entry
  );
  assign f_hit_g_data = f_live_g && (hit_entry[PpnBits+4:5] == f_g_ppn) &&
                        (hit_entry[4:0] == f_g_perm) && ent_g(
      hit_entry
  );

  // The registered hit response, one cycle after the compare: nothing fills or
  // flushes between the two, so it carries the shadow's PPN, permissions and
  // global bit, and echoes the requested VPN.
  logic f_resp_target;
  assign f_resp_target = (state_q == S_RESP) && (vpn_q == f_vpn) && (asid_q == f_la) && !i_discard;
  logic [4:0] f_resp_perm;
  assign f_resp_perm = {
    hit_resp_q.perm_r, hit_resp_q.perm_w, hit_resp_q.perm_x, hit_resp_q.perm_u, hit_resp_q.perm_d
  };
  logic f_resp_ng_ok, f_resp_g_ok;
  assign f_resp_ng_ok = f_live_ng && (hit_resp_q.ppn == f_ng_ppn) && (f_resp_perm == f_ng_perm) &&
                        !hit_resp_q.perm_g;
  assign f_resp_g_ok = f_live_g && (hit_resp_q.ppn == f_g_ppn) && (f_resp_perm == f_g_perm) &&
                       hit_resp_q.perm_g;

  always_ff @(posedge i_clk) begin
    if (f_past_valid && !i_rst) begin
      p_resp_data : assert (!f_resp_target || f_resp_ng_ok || f_resp_g_ok);
      p_resp_vpn : assert (state_q != S_RESP || hit_resp_q.vpn == vpn_q);
      p_resp_level : assert (state_q != S_RESP || hit_resp_q.level == 2'd0);
      // Soundness: a hit on the watched page and ASID is backed by a live
      // shadow, so no flushed or never-filled entry answers.
      p_hit_sound : assert (!(f_target && any_hit) || f_live_ng || f_live_g);
      // The answer is one of the entries the shadow holds, bit for bit.
      p_hit_data : assert (!(f_target && any_hit) || f_hit_ng_data || f_hit_g_data);
      // No lookup runs, and none is accepted, while a flush runs.
      p_no_lookup_in_flush : assert (!flush_busy || (!o_req_ready && state_q != S_CMP));
      p_no_ready_with_flush : assert (!i_flush.en || !o_req_ready);
      // Only clean 4 KiB translations fill.
      p_fill_clean :
      assert (!fill_en || (i_ptw_resp.fault_kind == riscv_pkg::DFAULT_NONE &&
                                          i_ptw_resp.level == 2'd0));
      // No response leaves with a discard raised.
      p_no_resp_on_discard : assert (!i_discard || !o_resp_valid);
      // A flush that names no page or ASID empties the array.
      if ($past(flush_all_now) && !$past(i_rst)) p_flush_all_empties : assert (valid_q == '0);
    end
  end

  always_ff @(posedge i_clk) begin
    if (f_past_valid && !i_rst) begin
      c_fill_ng :
      cover (fill_en && i_ptw_resp.vpn == f_vpn && !i_ptw_resp.perm_g && asid_q == f_la);
      c_fill_g : cover (fill_en && i_ptw_resp.vpn == f_vpn && i_ptw_resp.perm_g);
      c_hit_ng : cover (f_target && any_hit && f_live_ng);
      c_hit_g : cover (f_target && any_hit && f_live_g && !f_live_ng);
      c_flush_all : cover (flush_all_now && f_live_ng);
      c_flush_asid : cover (f_kills_ng && i_flush.use_asid && !i_flush.use_va && f_live_ng);
      c_flush_page : cover (f_kills_ng && i_flush.use_va && !i_flush.use_asid && f_live_ng);
      c_flush_page_asid : cover (f_kills_ng && i_flush.use_va && i_flush.use_asid && f_live_ng);
      c_asid_flush_spares_g : cover (i_flush.en && i_flush.use_asid && f_live_g && !f_kills_g);
      c_miss_after_flush : cover (f_target && !any_hit && !f_live_ng && !f_live_g);
    end
  end
`endif

endmodule : l2tlb
