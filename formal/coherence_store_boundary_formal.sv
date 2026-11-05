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

`include "coherence_types.svh"

// Reduced ordered dispatch/commit environment with the production SQ, router,
// L1D, LQ and selected-atomic guard. Channel stalls are independent.
module coherence_store_boundary_formal #(
    parameter bit COVER_MODE = 1'b0,
    parameter bit COVER_BOUNDARIES = 1'b0,
    parameter bit LOCAL_PROGRESS = 1'b0,
    parameter bit COVER_LOCAL = 1'b0,
    parameter bit COVER_AMO_HOME = 1'b0,
    parameter int unsigned MODE = 0,
    parameter int unsigned SECTOR_CASE = 2
) (
    input logic i_clk
);
  localparam int unsigned ReorderBufferTagWidth = riscv_pkg::ReorderBufferTagWidth;
  localparam int unsigned AddrWidth = 32, TagBits = ReorderBufferTagWidth;
  localparam int unsigned Misses = LOCAL_PROGRESS ? 3 : 1, DEPTH = 4, XLEN = riscv_pkg::XLEN;
  localparam int unsigned LqDepth = 2;
  localparam int unsigned RsDepth = riscv_pkg::MemRsDepth;
  `FROST_COHERENCE_TYPES(AddrWidth)
  logic past_q = 0;
  wire  rst = !past_q;
  always_ff @(posedge i_clk) past_q <= 1;
  (* anyseq *) logic offer_normal_load, permit_d, permit_g, permit_c, permit_u, observe_drain;
  // Dispatch and commit form one back-to-back program. Normal-load issue
  // and home-channel stalls are independent choices.
  wire advance = 1'b1;
  wire different_sector;
  if (SECTOR_CASE == 2) begin : gen_sector_choice
    (* anyconst *) logic choice;
    assign different_sector = choice;
  end else begin : gen_sector_constant
    assign different_sector = 1'(SECTOR_CASE);
  end
  localparam logic [1:0] Mode = 2'(MODE);
  localparam bit LocalLR = LOCAL_PROGRESS && MODE == 2;
  localparam logic [ReorderBufferTagWidth-1:0] AtomicTag = LocalLR ? 3 : 2;
  localparam logic [ReorderBufferTagWidth-1:0] YoungerTag = AtomicTag + 1'b1;
  // Atomic and old-response programs issue at the first dispatch opportunity.
  wire offer_load = Mode == 0 ? offer_normal_load : 1'b1;
  (* anyconst *) logic [7:0] first_byte, second_byte;
  // The second older store may share the first store's sector, leaving a
  // different-sector AMO target absent from the cache.
  (* anyconst *) logic amo_prefix_same_sector;
  logic [3:0] step_q;
  logic atomic_complete_q, sc_written_q, guard_retired;
  wire retire_atomic = step_q == 6 && (Mode == 1 || Mode == 2) && atomic_complete_q &&
      advance && (!LOCAL_PROGRESS || !commit_hold);
  wire commit_store =
      (step_q == 4 || step_q == 9 || (retire_atomic && Mode == 2)) && commit_advance;
  wire [ReorderBufferTagWidth-1:0] commit_tag =
      step_q == 4 ? 0 : step_q == 9 ? YoungerTag : AtomicTag;
  logic addressed_q, load_update_q, load_second_update_q;
  logic lr_addressed_q, lr_complete_q;
  logic old_request_q, old_complete_q, fresh_addressed_q;
  logic [1:0] fresh_stage_q;
  wire fresh_alloc = Mode == 3 && fresh_stage_q == 1 && advance;
  wire fresh_issue = Mode == 3 && fresh_stage_q >= 2 && offer_load && !fresh_addressed_q;
  wire retirement_hold = coherent_retire_hold;
  wire coherent_atomic_active = protected_q, coherent_atomic_retired = guard_retired;
  wire i_coherent_atomic_live = l1_atomic_live;
  wire coherent_head_protected, coherent_retire_hold;
  assign coherent_head_protected = coherent_atomic_active && !coherent_atomic_retired;
  assign coherent_retire_hold = coherent_atomic_active && coherent_atomic_retired &&
      i_coherent_atomic_live;
  wire csr_commit_fire = 0, mispredict_recovery_pending = 0, i_fatal_stop = 0;
  wire commit_hold = csr_commit_fire || trap_mret_commit_hold_q ||
      mispredict_recovery_pending || i_fatal_stop || coherent_retire_hold;
  (* anyseq *) logic control_pending;
  wire i_rst = rst, flush_all = 0, trap_pending = 0, mret_start = 0;
  wire trap_drain_wait = control_pending, step_done_set = 0, step_done_q = 0;
  logic trap_mret_commit_hold_q;
  always_ff @(posedge i_clk) begin
    if (i_rst || flush_all) trap_mret_commit_hold_q <= 1'b0;
    // A drain holds younger retirement. The protected cached SC retires
    // before its pending write can complete.
    else
      trap_mret_commit_hold_q <= trap_pending || mret_start ||
      (trap_drain_wait && !coherent_head_protected) ||
      // Single step: after the stepped instruction retires, hold the next
      // head until the debug halt lands (registered: the first retirement
      // decides this cycle, the hold blocks the next one).
      step_done_set || step_done_q;
  end
  wire commit_advance = advance && (Mode != 3 || step_q != 4 || old_request_q) &&
      (step_q != 9 || !retirement_hold);
  wire pre_issue = (step_q >= 2 && offer_load &&
      (LocalLR ? !lr_addressed_q : (!addressed_q && Mode != 2))) || fresh_issue;
  wire [ReorderBufferTagWidth-1:0] pre_issue_tag = fresh_issue ? 3 : 2;
  wire [RsDepth-1:0] pre_issue_ready = RsDepth'(pre_issue);
  wire [RsDepth*ReorderBufferTagWidth-1:0] pre_issue_entry_tags =
      (RsDepth*ReorderBufferTagWidth)'(pre_issue_tag);
  wire [63:0] address0 = 64'h80000000;
  wire [63:0] address1 = address0 + (different_sector ? 64'd32 : 64'd0);
  wire [ReorderBufferTagWidth-1:0] head =
      step_q < 5 ? 7'd0 : step_q == 5 ? 7'd1 :
      step_q == 6 ? ((LocalLR && !lr_complete_q) ? 7'd2 : AtomicTag) : YoungerTag;
  riscv_pkg::sq_alloc_req_t alloc0, alloc1;
  riscv_pkg::sq_data_update_t store_data;
  riscv_pkg::lq_alloc_req_t load_alloc;
  riscv_pkg::lq_addr_update_t load_addr;
  riscv_pkg::rs_issue_t sc_issue;
  always_comb begin
    alloc0 = '0;
    alloc0.valid = (step_q == 1 || step_q == 7 || (step_q == 2 && Mode == 2)) && advance;
    alloc0.rob_tag = step_q == 7 ? YoungerTag : step_q == 2 ? AtomicTag : 0;
    alloc0.is_sc = step_q == 2;
    alloc0.size = Mode == 3 ? riscv_pkg::MEM_SIZE_WORD : riscv_pkg::MEM_SIZE_DOUBLE;
    alloc0.addr_valid = 1;
    alloc0.address = (step_q == 1 ? address0 : address1) + (Mode == 3 ? 4 : 0);
    alloc1 = alloc0;
    alloc1.valid = step_q == 1 && advance;
    alloc1.rob_tag = 1;
    alloc1.address = (Mode == 1 && !LOCAL_PROGRESS && amo_prefix_same_sector ?
        address0 : address1) + (Mode == 3 ? 4 : 0);
    store_data = '0;
    store_data.valid = (step_q == 2 || step_q == 3 || step_q == 8 ||
        (step_q == 4 && Mode == 2)) && advance;
    store_data.rob_tag = step_q == 2 ? 0 : step_q == 3 ? 1 : step_q == 4 ? AtomicTag : YoungerTag;
    store_data.data = {8{step_q == 2 ? first_byte : second_byte}};
    load_alloc = '0;
    load_alloc.valid = (step_q == 1 && advance && (Mode != 2 || LocalLR)) || fresh_alloc;
    load_alloc.rob_tag = fresh_alloc ? 3 : 2;
    load_alloc.size = Mode == 3 ? riscv_pkg::MEM_SIZE_WORD : riscv_pkg::MEM_SIZE_DOUBLE;
    load_alloc.sign_ext = 0;
    load_alloc.is_amo = Mode == 1;
    load_alloc.is_lr = LocalLR;
    load_alloc.amo_op = riscv_pkg::AMOADD_D;
    load_addr = '0;
    load_addr.valid = load_update_q;
    load_addr.rob_tag = load_second_update_q ? 3 : 2;
    load_addr.address = Mode == 3 ? address0 + (load_second_update_q ? 4 : 0) : address1;
    load_addr.amo_rs2 = 1;
    sc_issue = '0;
    sc_issue.valid = step_q >= 2 && offer_load && !addressed_q && Mode == 2;
    sc_issue.rob_tag = AtomicTag;
    sc_issue.op = riscv_pkg::SC_D;
    sc_issue.src1_value = address1;
  end
  always_ff @(posedge i_clk) begin
    if (Mode == 3) assume (different_sector);
    if (rst) begin
      step_q <= 0;
      addressed_q <= 0;
      lr_addressed_q <= 0;
      lr_complete_q <= 0;
      load_update_q <= 0;
      atomic_complete_q <= 0;
      sc_written_q <= 0;
      load_second_update_q <= 0;
      old_request_q <= 0;
      old_complete_q <= 0;
      fresh_stage_q <= 0;
      fresh_addressed_q <= 0;
    end else begin
      if (commit_advance && (step_q < 6 || (step_q > 6 && step_q < 10) || retire_atomic))
        step_q <= step_q + 1'b1;
      if (LOCAL_PROGRESS ? (dependency_result.valid && dependency_result.tag == AtomicTag) :
          ((Mode == 1 && lq_fu_complete.valid) || (Mode == 2 && sc_sc_fu_complete.valid)))
        atomic_complete_q <= 1;
      if (l1_sc_write_done) sc_written_q <= 1;
      load_update_q <= pre_issue;
      load_second_update_q <= fresh_issue;
      if (lq_mem_read_en) old_request_q <= 1;
      if (lq_fu_complete.valid && lq_fu_complete.tag == 2) old_complete_q <= 1;
      if (Mode == 3 && old_complete_q && advance && fresh_stage_q == 0) fresh_stage_q <= 1;
      if (fresh_alloc) fresh_stage_q <= 2;
      if (fresh_issue) fresh_addressed_q <= 1;
      if (pre_issue) lr_addressed_q <= 1;
      if (dependency_result.valid && dependency_result.tag == 2) lr_complete_q <= 1;
      if ((pre_issue && !LocalLR) || sc_issue.valid) addressed_q <= 1;
    end
  end
  if (COVER_MODE) begin : gen_cover_schedule
    logic [6:0] cycle_q = 0;
    logic full_seen_q = 0, tail_drain_seen_q = 0, selected_seen_q = 0;
    logic retired_seen_q = 0, written_seen_q = 0, released_seen_q = 0;
    logic local_seen_q = 0, home_write_seen_q = 0;
    logic load_seen_q = 0, old_seen_q = 0, fresh_seen_q = 0;
    always_ff @(posedge i_clk) begin
      if (cycle_q != 127) cycle_q <= cycle_q + 1'b1;
      assume (advance && permit_d && permit_c && observe_drain);
      assume (first_byte == 8'h11 && second_byte == 8'h22);
      if (COVER_AMO_HOME) assume (amo_prefix_same_sector);
      assume (permit_g == (Mode != 3 || demand_q.opcode != coherence_pkg::GetS || accepted_q == 2));
      assume (permit_u == !((Mode == 1 || Mode == 2) && demand_q.opcode != coherence_pkg::GetM &&
          cycle_q < 105));
      assume (offer_load == (Mode != 0 || cycle_q == 30));
      if (!rst) begin
        full_seen_q <= full_seen_q || (l1_block_valid == 3 && acknowledged_q == 2);
        tail_drain_seen_q <= tail_drain_seen_q ||
            (observe_drain && accepted_q == 2 && l1_block_valid == 1);
        selected_seen_q <= selected_seen_q || (l1_atomic_live && accepted_q == 2);
        local_seen_q <= local_seen_q || local_owner;
        home_write_seen_q <= home_write_seen_q || home_atomic_write_lookup;
        retired_seen_q <= retired_seen_q || (guard_retired && selected_seen_q);
        written_seen_q <= written_seen_q || ((sc_written_q || l1_sc_write_done) && guard_retired);
        released_seen_q <= released_seen_q || (accepted_q == 3 && !l1_atomic_live);
        load_seen_q <= load_seen_q || (lq_fu_complete.valid && accepted_q == 2 &&
            lq_fu_complete.value == {8{second_byte}});
        old_seen_q <= old_seen_q || (rt_lq_mem_read_valid && accepted_q == 2 && !old_complete_q);
        fresh_seen_q <= fresh_seen_q || (lq_fu_complete.valid && lq_fu_complete.tag == 3 &&
            lq_fu_complete.value == {32'b0, {4{first_byte}}});
        if (cycle_q >= ((Mode == 0 || Mode == 3) ? 70 : 120) &&
            full_seen_q && tail_drain_seen_q) begin
          p_load_lifecycle : cover (Mode == 0 && load_seen_q);
          p_old_lifecycle : cover (Mode == 3 && old_seen_q && fresh_seen_q);
          p_amo_lifecycle :
          cover (Mode == 1 && selected_seen_q && retired_seen_q && released_seen_q);
          if (Mode == 1 && SECTOR_CASE == 0)
            p_amo_same_local : cover (local_seen_q && retired_seen_q && released_seen_q);
          if (COVER_AMO_HOME)
            p_amo_home_write : cover (home_write_seen_q && retired_seen_q && released_seen_q);
          p_sc_lifecycle :
          cover (Mode == 2 && selected_seen_q && retired_seen_q &&
              written_seen_q && released_seen_q);
        end
      end
    end
  end
  if (COVER_BOUNDARIES) begin : gen_boundary_covers
    logic [3:0] staged_q = 0;
    always_ff @(posedge i_clk) begin
      assume (permit_d && permit_g && permit_c && permit_u);
      assume (first_byte == 8'h11 && second_byte == 8'h22);
      if (!rst) begin
        if (load_update_q) begin
          staged_q[0] <= |rt_data_mem_cached_byte_wr_en &&
              !rt_coherent_write_atomic && rt_data_mem_addr[63:5] == address1[63:5];
          staged_q[1] <= l1_write_done && accepted_q == 2;
          staged_q[2] <= $past(l1_block_valid == 3) && l1_block_valid == 1;
          staged_q[3] <= $past(l1_pending_store) && !l1_pending_store;
        end
        if (lq_fu_complete.valid && lq_fu_complete.value == {8{second_byte}}) begin
          p_stage_capture : cover (staged_q[0]);
          p_stage_acknowledge : cover (staged_q[1]);
          p_stage_promotion : cover (staged_q[2]);
          p_stage_drain : cover (staged_q[3]);
        end
      end
    end
  end
  logic protected_q;
  logic local_owner;
  logic home_atomic_write_lookup;
  logic [3:0] local_phase;
  logic extra_sent_q, extra_granted_q, probe_offered_q, probe_accepted_q;
  coh_d_t extra_demand_q;
  coh_g_t extra_grant;
  coh_p_t local_probe;
  wire extra_read = LOCAL_PROGRESS && step_q == 3;
  wire extra_g_valid = LOCAL_PROGRESS && local_owner && extra_sent_q && !extra_granted_q;
  always_comb begin
    extra_grant = '0;
    extra_grant.q = extra_demand_q.q;
    extra_grant.addr = extra_demand_q.addr;
    extra_grant.tid = 7;
    extra_grant.opcode = coherence_pkg::GrantS;
    local_probe = '0;
    local_probe.addr = address1[31:0];
    local_probe.opcode = coherence_pkg::ProbeInvalidate;
  end
  always_ff @(posedge i_clk) begin
    if (rst) begin
      extra_sent_q <= 0;
      extra_granted_q <= 0;
      extra_demand_q <= '0;
      probe_offered_q <= 0;
      probe_accepted_q <= 0;
    end else if (LOCAL_PROGRESS) begin
      for (int ep = 1; ep < Misses; ep++)
      if (l1_d_valid[ep]) begin
        extra_sent_q   <= 1;
        extra_demand_q <= l1_d[ep];
      end
      if (extra_g_valid && l1_g_ready) extra_granted_q <= 1;
      if (local_owner) probe_offered_q <= 1;
      if (probe_offered_q && l1_p_ready) probe_accepted_q <= 1;
    end
  end
  logic dependency_lq_accepted, dependency_mem_pending, dependency_sc_pending;
  logic dependency_clear_reservation, dependency_snoop_invalidate;
  logic [3:0] competing_results_q;
  riscv_pkg::fu_complete_t completion_lq;
  riscv_pkg::fu_complete_t dependency_result;
  if (LOCAL_PROGRESS) begin : gen_completion
    (* anyseq *) logic offer_competing_result;
    wire competing_result = local_owner && competing_results_q < 8 && offer_competing_result &&
        !lq_fu_complete.valid && !dependency_sc_pending && !dependency_mem_pending;
    always_comb begin
      completion_lq = lq_fu_complete;
      if (competing_result) begin
        completion_lq = '0;
        completion_lq.valid = 1'b1;
        completion_lq.tag = YoungerTag + ReorderBufferTagWidth'(competing_results_q);
      end
    end
    always_ff @(posedge i_clk) begin
      if (rst) competing_results_q <= 0;
      else if (competing_result && dependency_lq_accepted)
        competing_results_q <= competing_results_q + 1'b1;
    end
    riscv_pkg::reorder_buffer_commit_t commit_bus_q;
    logic commit_bus_q_valid, commit_q_is_sc;
    always_ff @(posedge i_clk) begin
      commit_bus_q_valid <= !rst && retire_atomic;
      commit_q_is_sc <= Mode == 2;
      commit_bus_q <= '0;
      commit_bus_q.tag <= AtomicTag;
    end
    coherent_local_reservation_formal reservation (
        .commit_bus_q_valid,
        .commit_q_is_sc,
        .commit_q_sc_failed(1'b0),
        .commit_bus_q,
        .i_coherent_atomic_live(l1_atomic_live),
        .o_coherent_sc_tag(sc_coherent_tag),
        .i_coherent_sc_write_done(l1_sc_write_done),
        .sq_cache_invalidate_valid,
        .lq_reservation_valid,
        .o_coherent_write_sc(sq_coherent_write_sc),
        .o_sq_mem_write_is_cached(sq_mem_write_is_cached),
        .sq_cache_invalidate_addr,
        .lq_reservation_addr,
        .sc_clear_reservation(dependency_clear_reservation),
        .reservation_snoop_invalidate(dependency_snoop_invalidate),
        .sc_discard()
    );
    coherent_local_completion_formal completion (
        .i_clk,
        .i_rst_n(!rst),
        .lq_fu_complete(completion_lq),
        .sc_fu_complete(sc_sc_fu_complete),
        .store_misalign_fu_complete_reg('0),
        .uncached_store_complete('0),
        .lq_result_accepted(dependency_lq_accepted),
        .mem_adapter_result_pending(dependency_mem_pending),
        .sc_pending(dependency_sc_pending),
        .result(dependency_result)
    );
  end else begin : gen_direct_completion
    assign completion_lq = '0;
    assign competing_results_q = 0;
    assign dependency_clear_reservation = 1'b0;
    assign dependency_snoop_invalidate = 1'b0;
    assign dependency_result = '0;
    assign dependency_lq_accepted = 1'b1;
    assign dependency_mem_pending = 1'b0;
    assign dependency_sc_pending = 1'b0;
  end
  logic [ReorderBufferTagWidth-1:0] guard_tag;
  coherent_atomic_guard #(
      .TAG_BITS(ReorderBufferTagWidth)
  ) guard (
      .i_clk,
      .i_rst(rst),
      .i_arm_valid(lq_coherent_arm_valid || sc_coherent_arm_valid),
      .i_arm_tag(AtomicTag),
      .i_head_valid(1'b1),
      .i_head_tag(head),
      .i_entry_wins(1'b0),
      .i_commit_valid(retire_atomic),
      .i_commit_tag(AtomicTag),
      .i_home_live(l1_atomic_live),
      .i_own_fault(1'b0),
      .o_active(protected_q),
      .o_retired(guard_retired),
      .o_tag(guard_tag)
  );
  logic home_live_q, granted_q, complete_q;
  coh_d_t demand, demand_q;
  coh_g_t grant;
  coh_u_t release_message;
  assign demand = l1_d[0];
  always_comb begin
    grant = '0;
    grant.q = demand_q.q;
    grant.addr = demand_q.addr;
    grant.opcode = demand_q.opcode == coherence_pkg::GetS ?
        coherence_pkg::GrantS : coherence_pkg::GrantM;
    grant.data = demand_q.opcode == coherence_pkg::Atomic ? {32{second_byte}} : '0;
    release_message = '0;
    release_message.q = demand_q.q;
    release_message.addr = demand_q.addr;
  end
  always_ff @(posedge i_clk) begin
    if (rst) begin
      home_live_q <= 0;
      granted_q <= 0;
      complete_q <= 0;
      demand_q <= '0;
    end else begin
      if (l1_d_valid[0] && !home_live_q && permit_d) begin
        home_live_q <= 1;
        granted_q <= 0;
        demand_q <= demand;
      end
      if (home_live_q && !granted_q && permit_g && l1_g_ready) granted_q <= 1;
      if (l1_c_valid[0] && permit_c) complete_q <= 1;
      if (complete_q && permit_u && l1_u_ready) begin
        home_live_q <= 0;
        complete_q  <= 0;
      end
    end
  end
  wire ordinary_write = |rt_data_mem_cached_byte_wr_en && !rt_coherent_write_atomic;
  logic [2:0] accepted_q, acknowledged_q;
  always_ff @(posedge i_clk) begin
    if (rst) begin
      accepted_q <= 0;
      acknowledged_q <= 0;
    end else begin
      if (ordinary_write) accepted_q <= accepted_q + 1'b1;
      if (rt_sq_mem_write_done && !l1_sc_write_done) acknowledged_q <= acknowledged_q + 1'b1;
      p_no_buffered_atomic : assert (!(l1_pending_store && l1_atomic_live));
      p_no_buffered_guard : assert (!(l1_pending_store && protected_q));
      p_no_fatal : assert (!l1_fatal);
      assert (acknowledged_q <= accepted_q);
      assert (accepted_q - acknowledged_q <= 1);
      if (ordinary_write) begin
        assert ($past(l1_store_ready));
        assert (l1_block_valid != 3);
      end
      if (l1_pending_store || (sq_mem_write_en && sq_mem_write_is_cached))
        assert (!sq_committed_empty && !sq_committed_empty_trap && !sq_committed_empty_lq);
      if (!$past(rst) && $past(ordinary_write)) begin
        assert (l1_write_done && rt_sq_mem_write_done);
        assert (l1_pending_store);
      end
      if (Mode == 0 && lq_fu_complete.valid) begin
        assert (!lq_fu_complete.exception);
        p_load_value : assert (lq_fu_complete.value == {8{second_byte}});
      end
      if (Mode == 3 && lq_fu_complete.valid) begin
        assert (!lq_fu_complete.exception);
        p_old_value :
        assert (lq_fu_complete.value == (lq_fu_complete.tag == 2 ? 0 : {32'b0, {4{first_byte}}}));
      end
      if (Mode == 3 && rt_lq_mem_read_valid && accepted_q == 2 && !old_complete_q)
        assert (!lq_l0_fill);
    end
  end

  logic sq_coherent_write_sc;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] sq_coherent_write_tag;
  logic sq_full;
  logic sq_full_for_2;
  logic sq_dispatch_full;
  logic sq_dispatch_full_for_2;
  logic sq_sq_all_older_addrs_known;
  riscv_pkg::sq_forward_result_t sq_sq_forward;
  logic sq_mem_write_en;
  logic [riscv_pkg::XLEN-1:0] sq_mem_write_addr;
  logic [riscv_pkg::MemDataBits-1:0] sq_mem_write_data;
  logic [riscv_pkg::MemStrbBits-1:0] sq_mem_write_byte_en;
  riscv_pkg::mem_size_e sq_mem_write_size;
  logic sq_mem_write_buffered;
  logic sq_mem_write_is_mmio;
  logic sq_mem_write_is_cached;
  logic sq_uncached_store_pending;
  riscv_pkg::fu_complete_t sq_uncached_store_complete;
  logic sq_cache_invalidate_valid;
  logic [riscv_pkg::XLEN-1:0] sq_cache_invalidate_addr;
  logic sq_empty;
  logic sq_dispatch_empty;
  logic sq_committed_empty;
  logic sq_committed_empty_rob;
  logic sq_committed_empty_trap;
  logic sq_committed_empty_lq;
  logic [$clog2(DEPTH+1)-1:0] sq_count;
  logic [$clog2(DEPTH+1)-1:0] sq_dispatch_count;
  store_queue #(
      .DEPTH(4),
      .CACHE_NORMAL_MEMORY(1'b1)
  ) sq (
      .i_coherent_store_pending(l1_pending_store),
      .i_coherent_store_ready(l1_store_ready),
      .i_coherent_sc_pending(l1_sc_write_pending),
      .i_coherent_sc_tag(l1_sc_write_tag),
      .o_coherent_write_sc(sq_coherent_write_sc),
      .o_coherent_write_tag(sq_coherent_write_tag),
      .i_clk(i_clk),
      .i_rst_n(!rst),
      .i_alloc(alloc0),
      .i_alloc_2(alloc1),
      .o_full(sq_full),
      .o_full_for_2(sq_full_for_2),
      .o_dispatch_full(sq_dispatch_full),
      .o_dispatch_full_for_2(sq_dispatch_full_for_2),
      .i_early_addr_update('0),
      .i_early_addr_update_2('0),
      .i_early_addr_capture_valid('0),
      .i_early_addr_capture_valid_2('0),
      .i_addr_update('0),
      .i_addr_update_capture_valid('0),
      .i_data_update(store_data),
      .i_data_update_capture_valid(store_data.valid),
      .i_commit_valid(commit_store),
      .i_commit_rob_tag(commit_tag),
      .i_commit_valid_comb(commit_store),
      .i_commit_valid_2(step_q == 5 && advance),
      .i_commit_rob_tag_2(7'd1),
      .i_commit_valid_comb_2(step_q == 5 && advance),
      .i_commit_valid_scan(commit_store),
      .i_commit_valid_scan_2(step_q == 5 && advance),
      .i_sq_check_capture_valid(lq_sq_check_capture_valid),
      .i_sq_check_addr(lq_sq_check_addr),
      .i_sq_check_addr_b(lq_sq_check_addr_b),
      .i_sq_check_addr_c(lq_sq_check_addr_c),
      .i_sq_check_addr_d(lq_sq_check_addr_d),
      .i_sq_check_rob_tag(lq_sq_check_rob_tag),
      .i_sq_check_size(lq_sq_check_size),
      .o_sq_all_older_addrs_known(sq_sq_all_older_addrs_known),
      .o_sq_forward(sq_sq_forward),
      .o_mem_write_en(sq_mem_write_en),
      .o_mem_write_addr(sq_mem_write_addr),
      .o_mem_write_data(sq_mem_write_data),
      .o_mem_write_byte_en(sq_mem_write_byte_en),
      .o_mem_write_size(sq_mem_write_size),
      .o_mem_write_buffered(sq_mem_write_buffered),
      .o_mem_write_is_mmio(sq_mem_write_is_mmio),
      .o_mem_write_is_cached(sq_mem_write_is_cached),
      .i_mem_write_done(rt_sq_mem_write_done),
      .i_mem_write_error('0),
      .o_uncached_store_pending(sq_uncached_store_pending),
      .i_uncached_store_shield('0),
      .i_head_side_effects_allowed('0),
      .i_uncached_sc_success('0),
      .i_uncached_sc_tag('0),
      .o_uncached_store_complete(sq_uncached_store_complete),
      .i_uncached_store_result_ready('0),
      .o_cache_invalidate_valid(sq_cache_invalidate_valid),
      .o_cache_invalidate_addr(sq_cache_invalidate_addr),
      .i_rob_head_tag(head),
      .i_flush_en('0),
      .i_flush_tag('0),
      .i_flush_all('0),
      .i_flush_after_head_commit('0),
      .i_sc_discard('0),
      .i_sc_discard_rob_tag('0),
      .o_empty(sq_empty),
      .o_dispatch_empty(sq_dispatch_empty),
      .o_committed_empty(sq_committed_empty),
      .o_committed_empty_rob(sq_committed_empty_rob),
      .o_committed_empty_trap(sq_committed_empty_trap),
      .o_committed_empty_lq(sq_committed_empty_lq),
      .o_count(sq_count),
      .o_dispatch_count(sq_dispatch_count)
  );
  logic lq_coherent_arm_valid;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] lq_coherent_arm_tag;
  logic [1:0] lq_coherent_read_kind;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] lq_coherent_read_tag;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] lq_coherent_write_tag;
  logic [2:0] lq_reservation_size;
  logic lq_full;
  logic lq_full_for_2;
  logic lq_dispatch_full;
  logic lq_dispatch_full_for_2;
  logic lq_sq_check_valid;
  logic lq_sq_check_capture_valid;
  logic [riscv_pkg::XLEN-1:0] lq_sq_check_addr;
  logic [riscv_pkg::XLEN-1:0] lq_sq_check_addr_b;
  logic [riscv_pkg::XLEN-1:0] lq_sq_check_addr_c;
  logic [riscv_pkg::XLEN-1:0] lq_sq_check_addr_d;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] lq_sq_check_rob_tag;
  riscv_pkg::mem_size_e lq_sq_check_size;
  logic lq_mem_read_en;
  logic lq_mem_addr_valid;
  logic [riscv_pkg::XLEN-1:0] lq_mem_read_addr;
  riscv_pkg::mem_size_e lq_mem_read_size;
  logic [riscv_pkg::CachedLoadSlotBits-1:0] lq_mem_read_id;
  logic lq_mem_read_no_merge;
  riscv_pkg::fu_complete_t lq_fu_complete;
  logic lq_fu_complete_staged;
  logic lq_reservation_valid;
  logic [riscv_pkg::XLEN-1:0] lq_reservation_addr;
  logic lq_amo_mem_write_en;
  logic [riscv_pkg::XLEN-1:0] lq_amo_mem_write_addr;
  logic [riscv_pkg::MemDataBits-1:0] lq_amo_mem_write_data;
  logic lq_amo_mem_write_is_dword;
  logic lq_amo_mem_write_is_cached;
  logic lq_coh_query_busy;
  logic lq_coh_query_held;
  logic lq_coh_observe_valid;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] lq_coh_observe_rob_tag;
  logic [riscv_pkg::XLEN-1:0] lq_coh_observe_addr;
  logic lq_empty;
  logic lq_dispatch_empty;
  logic [$clog2(LqDepth+1)-1:0] lq_count;
  logic [$clog2(LqDepth+1)-1:0] lq_dispatch_count;
  logic lq_l0_hit;
  logic lq_l0_fill;
  logic lq_mem_outstanding;
  logic lq_head_load_addr_pending;
  logic lq_head_load_sq_disambig;
  logic lq_head_load_bus_blocked;
  logic lq_head_load_cdb_wait;
  logic lq_head_load_post_lq;
  logic lq_head_load_bb_bus_busy;
  logic lq_head_load_bb_sq_wait;
  logic lq_head_load_bb_staging;
  logic lq_head_load_bbs_other_in_staging;
  logic lq_head_load_bbs_launch_gated;
  logic lq_head_load_bbs_capture_gap;
  load_queue #(
      .DEPTH(LqDepth),
      .L0_CACHE_DEPTH(8),
      .CACHE_NORMAL_MEMORY(1'b1),
      .PREISSUE_CANDIDATES(1'b1),
      .PREISSUE_READY_PICK(1'b1),
      .PREISSUE_SEL_WIDTH(3),
      .PREISSUE_RS_DEPTH(RsDepth),
      .ENABLE_SQ_FORWARD_FAST_PATH(1'b1)
  ) lq (
      .i_coherent_cut_hold(LOCAL_PROGRESS && l1_cut_hold),
      .i_coherent_cut_addr({32'b0, l1_cut_address}),
      .i_coherent_block_valid(l1_block_valid),
      .i_coherent_block_addr({32'b0, l1_block_addr[1], 32'b0, l1_block_addr[0]}),
      .i_coherent_atomic_protected(protected_q),
      .o_coherent_arm_valid(lq_coherent_arm_valid),
      .o_coherent_arm_tag(lq_coherent_arm_tag),
      .o_coherent_read_kind(lq_coherent_read_kind),
      .o_coherent_read_tag(lq_coherent_read_tag),
      .o_coherent_write_tag(lq_coherent_write_tag),
      .o_reservation_size(lq_reservation_size),
      .i_clk(i_clk),
      .i_rst_n(!rst),
      .i_alloc(load_alloc),
      .i_alloc_2('0),
      .o_full(lq_full),
      .o_full_for_2(lq_full_for_2),
      .o_dispatch_full(lq_dispatch_full),
      .o_dispatch_full_for_2(lq_dispatch_full_for_2),
      .i_addr_update(load_addr),
      .i_pre_issue_rob_tag(pre_issue_tag),
      .i_pre_issue_rob_tags({8{pre_issue_tag}}),
      .i_pre_issue_sel('0),
      .i_pre_issue_needs_lq(pre_issue),
      .i_pre_issue_ready({8{pre_issue_ready}}),
      .i_pre_issue_entry_tags(pre_issue_entry_tags),
      .i_pre_issue_direct('0),
      .i_pre_issue_direct_tag('0),
      .o_sq_check_valid(lq_sq_check_valid),
      .o_sq_check_capture_valid(lq_sq_check_capture_valid),
      .o_sq_check_addr(lq_sq_check_addr),
      .o_sq_check_addr_b(lq_sq_check_addr_b),
      .o_sq_check_addr_c(lq_sq_check_addr_c),
      .o_sq_check_addr_d(lq_sq_check_addr_d),
      .o_sq_check_rob_tag(lq_sq_check_rob_tag),
      .o_sq_check_size(lq_sq_check_size),
      .i_sq_all_older_addrs_known(sq_sq_all_older_addrs_known),
      .i_sq_forward(sq_sq_forward),
      .i_sq_commit_pending(commit_store || (step_q == 5 && advance)),
      .o_mem_read_en(lq_mem_read_en),
      .o_mem_addr_valid(lq_mem_addr_valid),
      .o_mem_read_addr(lq_mem_read_addr),
      .o_mem_read_size(lq_mem_read_size),
      .o_mem_read_id(lq_mem_read_id),
      .o_mem_read_no_merge(lq_mem_read_no_merge),
      .i_mem_read_data(rt_lq_mem_read_data),
      .i_mem_read_valid(rt_lq_mem_read_valid),
      .i_mem_read_error(rt_lq_mem_read_error),
      .i_mem_read_is_cached(rt_lq_mem_read_is_cached),
      .i_mem_read_id(rt_lq_mem_read_id),
      .i_mem_bus_busy(sq_mem_write_en || lq_amo_mem_write_en || l1_write_inflight ||
          rt_lq_mem_request_valid),
      .i_mem_request_pending(rt_lq_mem_request_valid),
      .i_cached_resp_held(rt_cached_read_held),
      .o_fu_complete(lq_fu_complete),
      .o_fu_complete_staged(lq_fu_complete_staged),
      .i_adapter_result_pending(dependency_mem_pending || dependency_sc_pending),
      .i_result_accepted(dependency_lq_accepted),
      .i_rob_head_tag(head),
      .o_reservation_valid(lq_reservation_valid),
      .o_reservation_addr(lq_reservation_addr),
      .i_sc_clear_reservation(dependency_clear_reservation),
      .i_reservation_snoop_invalidate(dependency_snoop_invalidate),
      .i_sq_empty(sq_empty),
      .i_sq_committed_empty(sq_committed_empty_lq),
      .i_trap_misaligned_accesses('0),
      .o_amo_mem_write_en(lq_amo_mem_write_en),
      .o_amo_mem_write_addr(lq_amo_mem_write_addr),
      .o_amo_mem_write_data(lq_amo_mem_write_data),
      .o_amo_mem_write_is_dword(lq_amo_mem_write_is_dword),
      .o_amo_mem_write_is_cached(lq_amo_mem_write_is_cached),
      .i_amo_mem_write_done(rt_amo_mem_write_done),
      .i_amo_mem_write_error('0),
      .i_flush_en('0),
      .i_flush_tag('0),
      .i_flush_all('0),
      .i_full_flush('0),
      .i_early_recovery_flush('0),
      .i_cache_invalidate_valid(sq_cache_invalidate_valid),
      .i_cache_invalidate_addr(sq_cache_invalidate_addr),
      .i_cache_store_data('0),
      .i_cache_store_strb('0),
      .i_l0_hit_allowed(!((sq_mem_write_en && !sq_mem_write_buffered) ||
          lq_amo_mem_write_en || rt_lq_mem_request_valid)),
      .i_coh_inval_valid(LOCAL_PROGRESS && l1_cut_inval_valid),
      .i_coh_inval_addr({32'b0, l1_cut_address}),
      .i_coh_block_valid('0),
      .i_coh_block_addr('0),
      .i_coh_admit_pulse('0),
      .i_coh_query_addr('0),
      .o_coh_query_busy(lq_coh_query_busy),
      .o_coh_query_held(lq_coh_query_held),
      .o_coh_observe_valid(lq_coh_observe_valid),
      .o_coh_observe_rob_tag(lq_coh_observe_rob_tag),
      .o_coh_observe_addr(lq_coh_observe_addr),
      .o_empty(lq_empty),
      .o_dispatch_empty(lq_dispatch_empty),
      .o_count(lq_count),
      .o_dispatch_count(lq_dispatch_count),
      .o_l0_hit(lq_l0_hit),
      .o_l0_fill(lq_l0_fill),
      .o_mem_outstanding(lq_mem_outstanding),
      .o_head_load_addr_pending(lq_head_load_addr_pending),
      .o_head_load_sq_disambig(lq_head_load_sq_disambig),
      .o_head_load_bus_blocked(lq_head_load_bus_blocked),
      .o_head_load_cdb_wait(lq_head_load_cdb_wait),
      .o_head_load_post_lq(lq_head_load_post_lq),
      .o_head_load_bb_bus_busy(lq_head_load_bb_bus_busy),
      .o_head_load_bb_sq_wait(lq_head_load_bb_sq_wait),
      .o_head_load_bb_staging(lq_head_load_bb_staging),
      .o_head_load_bbs_other_in_staging(lq_head_load_bbs_other_in_staging),
      .o_head_load_bbs_launch_gated(lq_head_load_bbs_launch_gated),
      .o_head_load_bbs_capture_gap(lq_head_load_bbs_capture_gap)
  );
  logic [1:0] rt_coherent_read_kind;
  logic [2:0] rt_coherent_read_size;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] rt_coherent_read_tag;
  logic rt_coherent_write_atomic;
  logic rt_coherent_write_sc;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] rt_coherent_write_tag;
  logic rt_cached_read_ready;
  logic rt_cached_read_held;
  logic rt_uncached_read_enable;
  riscv_pkg::mem_size_e rt_uncached_read_size;
  logic rt_uncached_read_ready;
  logic [riscv_pkg::MemStrbBits-1:0] rt_uncached_write_byte_en;
  riscv_pkg::mem_size_e rt_uncached_write_size;
  logic rt_uncached_write_buffered;
  logic [XLEN-1:0] rt_data_mem_addr;
  logic [riscv_pkg::MemDataBits-1:0] rt_data_mem_wr_data;
  logic [riscv_pkg::MemStrbBits-1:0] rt_data_mem_per_byte_wr_en;
  logic [riscv_pkg::MemStrbBits-1:0] rt_data_mem_bram_byte_wr_en;
  logic rt_data_mem_bram_write_any;
  logic rt_data_mem_read_enable;
  logic [riscv_pkg::MemStrbBits-1:0] rt_data_mem_cached_byte_wr_en;
  logic [riscv_pkg::MemDataBits-1:0] rt_data_mem_cached_wr_data;
  logic rt_data_mem_cached_read_enable;
  logic rt_data_mem_cached_read_sel;
  logic rt_data_mem_cached_read_if_sel;
  logic rt_data_mem_cached_read_if_clear;
  logic [riscv_pkg::CachedLoadSlotBits-1:0] rt_data_mem_cached_read_id;
  logic rt_data_mem_cached_read_no_merge;
  logic rt_mmio_read_pulse;
  logic [XLEN-1:0] rt_mmio_load_addr;
  logic rt_mmio_load_valid;
  logic rt_mmio_fifo0_read_pulse;
  logic rt_mmio_fifo1_read_pulse;
  logic rt_mmio_uart_rx_ready_pulse;
  logic rt_sq_mem_write_done;
  logic rt_sq_mem_write_error;
  logic rt_amo_mem_write_done;
  logic rt_amo_mem_write_error;
  logic rt_lq_mem_request_valid;
  logic rt_device_request_pending;
  logic [riscv_pkg::MemDataBits-1:0] rt_lq_mem_read_data;
  logic rt_lq_mem_read_valid;
  logic rt_lq_mem_read_error;
  logic rt_lq_mem_read_is_cached;
  logic [riscv_pkg::CachedLoadSlotBits-1:0] rt_lq_mem_read_id;
  data_mem_request_router rt (
      .i_coherent_read_kind(lq_coherent_read_kind),
      .i_coherent_read_tag(lq_coherent_read_tag),
      .i_coherent_sq_sc(sq_coherent_write_sc),
      .i_coherent_sq_tag(sq_coherent_write_tag),
      .i_coherent_amo_tag(lq_coherent_write_tag),
      .o_coherent_read_kind(rt_coherent_read_kind),
      .o_coherent_read_size(rt_coherent_read_size),
      .o_coherent_read_tag(rt_coherent_read_tag),
      .o_coherent_write_atomic(rt_coherent_write_atomic),
      .o_coherent_write_sc(rt_coherent_write_sc),
      .o_coherent_write_tag(rt_coherent_write_tag),
      .i_clk(i_clk),
      .i_rst(rst),
      .i_block_new_requests('0),
      .i_flush_all('0),
      .i_sq_mem_write_en(sq_mem_write_en),
      .i_sq_mem_write_addr(sq_mem_write_addr),
      .i_sq_mem_write_data(sq_mem_write_data),
      .i_sq_mem_write_byte_en(sq_mem_write_byte_en),
      .i_sq_mem_write_size(sq_mem_write_size),
      .i_sq_mem_write_is_mmio(sq_mem_write_is_mmio),
      .i_sq_mem_write_buffered(sq_mem_write_buffered),
      .i_sq_mem_write_is_cached(sq_mem_write_is_cached),
      .i_amo_mem_write_en(lq_amo_mem_write_en),
      .i_amo_mem_write_addr(lq_amo_mem_write_addr),
      .i_amo_mem_write_data(lq_amo_mem_write_data),
      .i_amo_mem_write_is_dword(lq_amo_mem_write_is_dword),
      .i_amo_mem_write_is_cached(lq_amo_mem_write_is_cached),
      .i_lq_mem_read_en(lq_mem_read_en),
      .i_lq_mem_read_addr(lq_mem_read_addr),
      .i_lq_mem_addr_valid(lq_mem_addr_valid),
      .i_lq_mem_read_id(lq_mem_read_id),
      .i_lq_mem_read_no_merge(lq_mem_read_no_merge),
      .i_lq_mem_read_size(lq_mem_read_size),
      .i_sq_committed_empty(sq_committed_empty),
      .i_data_mem_rd_data('0),
      .i_cached_read_data(l1_read_data),
      .i_cached_read_id(l1_read_id),
      .i_cached_read_valid(l1_read_valid),
      .i_cached_read_error(l1_read_error),
      .o_cached_read_ready(rt_cached_read_ready),
      .o_cached_read_held(rt_cached_read_held),
      .i_cached_write_done(l1_write_done),
      .i_cached_write_inflight(l1_write_inflight),
      .i_uncached_read_request_ready('0),
      .o_uncached_read_enable(rt_uncached_read_enable),
      .o_uncached_read_size(rt_uncached_read_size),
      .i_uncached_read_valid('0),
      .o_uncached_read_ready(rt_uncached_read_ready),
      .i_uncached_read_data('0),
      .i_uncached_read_status('0),
      .o_uncached_write_byte_en(rt_uncached_write_byte_en),
      .o_uncached_write_size(rt_uncached_write_size),
      .o_uncached_write_buffered(rt_uncached_write_buffered),
      .i_uncached_write_done('0),
      .i_uncached_write_status('0),
      .i_uncached_write_inflight('0),
      .o_data_mem_addr(rt_data_mem_addr),
      .o_data_mem_wr_data(rt_data_mem_wr_data),
      .o_data_mem_per_byte_wr_en(rt_data_mem_per_byte_wr_en),
      .o_data_mem_bram_byte_wr_en(rt_data_mem_bram_byte_wr_en),
      .o_data_mem_bram_write_any(rt_data_mem_bram_write_any),
      .o_data_mem_read_enable(rt_data_mem_read_enable),
      .o_data_mem_cached_byte_wr_en(rt_data_mem_cached_byte_wr_en),
      .o_data_mem_cached_wr_data(rt_data_mem_cached_wr_data),
      .o_data_mem_cached_read_enable(rt_data_mem_cached_read_enable),
      .o_data_mem_cached_read_sel(rt_data_mem_cached_read_sel),
      .o_data_mem_cached_read_if_sel(rt_data_mem_cached_read_if_sel),
      .o_data_mem_cached_read_if_clear(rt_data_mem_cached_read_if_clear),
      .o_data_mem_cached_read_id(rt_data_mem_cached_read_id),
      .o_data_mem_cached_read_no_merge(rt_data_mem_cached_read_no_merge),
      .o_mmio_read_pulse(rt_mmio_read_pulse),
      .o_mmio_load_addr(rt_mmio_load_addr),
      .o_mmio_load_valid(rt_mmio_load_valid),
      .o_mmio_fifo0_read_pulse(rt_mmio_fifo0_read_pulse),
      .o_mmio_fifo1_read_pulse(rt_mmio_fifo1_read_pulse),
      .o_mmio_uart_rx_ready_pulse(rt_mmio_uart_rx_ready_pulse),
      .o_sq_mem_write_done(rt_sq_mem_write_done),
      .o_sq_mem_write_error(rt_sq_mem_write_error),
      .o_amo_mem_write_done(rt_amo_mem_write_done),
      .o_amo_mem_write_error(rt_amo_mem_write_error),
      .o_lq_mem_request_valid(rt_lq_mem_request_valid),
      .o_device_request_pending(rt_device_request_pending),
      .o_lq_mem_read_data(rt_lq_mem_read_data),
      .o_lq_mem_read_valid(rt_lq_mem_read_valid),
      .o_lq_mem_read_error(rt_lq_mem_read_error),
      .o_lq_mem_read_is_cached(rt_lq_mem_read_is_cached),
      .o_lq_mem_read_id(rt_lq_mem_read_id)
  );
  logic l1_read_valid;
  logic [2:0] l1_read_id;
  logic [63:0] l1_read_data;
  logic l1_read_error;
  logic l1_write_done;
  logic l1_write_inflight;
  logic l1_store_ready;
  logic l1_pending_store;
  logic l1_sc_write_pending;
  logic l1_atomic_live;
  logic [1:0] l1_block_valid;
  logic [1:0][AddrWidth-1:0] l1_block_addr;
  logic l1_sc_ready;
  logic l1_sc_result_valid;
  logic l1_sc_success;
  logic l1_sc_error;
  logic l1_sc_write_done;
  logic [TagBits-1:0] l1_sc_write_tag;
  logic l1_maint_done;
  logic l1_cut_hold;
  logic l1_cut_admit_valid;
  logic [AddrWidth-1:0] l1_cut_address;
  logic l1_cut_inval_valid;
  logic l1_cut_release;
  logic [Misses-1:0] l1_d_valid;
  logic [Misses-1:0][AddrWidth+311:0] l1_d;
  logic l1_p_ready;
  logic l1_r_valid;
  logic [AddrWidth+274:0] l1_r;
  logic l1_w_valid;
  logic [AddrWidth+259:0] l1_w;
  logic l1_wa_ready;
  logic l1_g_ready;
  logic [Misses-1:0] l1_c_valid;
  logic [Misses-1:0] l1_c_selected;
  logic [Misses-1:0][AddrWidth+17:0] l1_c;
  logic l1_u_ready;
  cache_perf_pkg::cache_instance_perf_events_t l1_perf_events;
  logic l1_fatal;
  logic [AddrWidth-1:0] l1_fatal_addr;
  coherence_l1d #(
      .CACHE_BYTES(64),
      .WAYS(1),
      .MISSES(Misses),
      .TAG_BITS(ReorderBufferTagWidth)
  ) l1 (
      .i_clk(i_clk),
      .i_rst(rst),
      .i_fatal_stop('0),
      .i_read_valid(rt_data_mem_cached_read_enable || extra_read),
      .i_read_id(extra_read ? 3'd1 : rt_data_mem_cached_read_id),
      .i_read_kind(extra_read ? 2'd0 : rt_coherent_read_kind),
      .i_read_size(rt_coherent_read_size),
      .i_read_tag(rt_coherent_read_tag),
      .i_address(extra_read ? address0[31:0] + 32'd64 : rt_data_mem_addr[31:0]),
      .o_read_valid(l1_read_valid),
      .i_read_ready(rt_cached_read_ready),
      .o_read_id(l1_read_id),
      .o_read_data(l1_read_data),
      .o_read_error(l1_read_error),
      .i_write_mask(rt_data_mem_cached_byte_wr_en),
      .i_write_data(rt_data_mem_cached_wr_data),
      .i_write_atomic(rt_coherent_write_atomic),
      .i_write_sc(rt_coherent_write_sc),
      .i_write_tag(rt_coherent_write_tag),
      .o_write_done(l1_write_done),
      .o_write_inflight(l1_write_inflight),
      .o_store_ready(l1_store_ready),
      .o_pending_store(l1_pending_store),
      .o_sc_write_pending(l1_sc_write_pending),
      .o_atomic_live(l1_atomic_live),
      .o_block_valid(l1_block_valid),
      .o_block_addr(l1_block_addr),
      .i_atomic_protected(protected_q),
      .i_sc_valid(sc_coherent_valid),
      .o_sc_ready(l1_sc_ready),
      .i_sc_address(sc_coherent_addr[31:0]),
      .i_sc_size(sc_coherent_size),
      .i_sc_tag(sc_coherent_tag),
      .i_sc_commit(retire_atomic && Mode == 2),
      .o_sc_result_valid(l1_sc_result_valid),
      .i_sc_result_ready(sc_coherent_result_ready),
      .o_sc_success(l1_sc_success),
      .o_sc_error(l1_sc_error),
      .o_sc_write_done(l1_sc_write_done),
      .o_sc_write_tag(l1_sc_write_tag),
      .i_reservation_valid(LocalLR ? lq_reservation_valid : 1'b1),
      .i_reservation_addr(LocalLR ? lq_reservation_addr[31:0] : address1[31:0]),
      .i_reservation_size(LocalLR ? lq_reservation_size : 3'd3),
      .i_maint_valid('0),
      .i_maint_line('0),
      .i_maint_address('0),
      .o_maint_done(l1_maint_done),
      .o_cut_hold(l1_cut_hold),
      .o_cut_admit_valid(l1_cut_admit_valid),
      .i_cut_admit_ready(LOCAL_PROGRESS),
      .i_cut_admit_clean(LOCAL_PROGRESS),
      .o_cut_address(l1_cut_address),
      .o_cut_inval_valid(l1_cut_inval_valid),
      .i_cut_inval_done(LOCAL_PROGRESS),
      .o_cut_release(l1_cut_release),
      .o_d_valid(l1_d_valid),
      .i_d_ready({{(Misses - 1) {1'b1}}, (!home_live_q && permit_d)}),
      .o_d(l1_d),
      .i_p_valid(LOCAL_PROGRESS && probe_offered_q && !probe_accepted_q),
      .o_p_ready(l1_p_ready),
      .i_p(local_probe),
      .o_r_valid(l1_r_valid),
      .i_r_ready(LOCAL_PROGRESS),
      .o_r(l1_r),
      .o_w_valid(l1_w_valid),
      .i_w_ready('0),
      .o_w(l1_w),
      .i_wa_valid('0),
      .o_wa_ready(l1_wa_ready),
      .i_wa('0),
      .i_g_valid(extra_g_valid || (home_live_q && !granted_q && permit_g)),
      .o_g_ready(l1_g_ready),
      .i_g(extra_g_valid ? extra_grant : grant),
      .o_c_valid(l1_c_valid),
      .o_c_selected(l1_c_selected),
      .i_c_ready(permit_c),
      .o_c(l1_c),
      .i_u_valid(complete_q && permit_u),
      .o_u_ready(l1_u_ready),
      .i_u(release_message),
      .o_perf_events(l1_perf_events),
`ifdef LOCAL_ATOMIC_DEPENDENCY
      .o_formal_local(local_owner),
      .o_formal_phase(local_phase),
      .o_formal_home_write(home_atomic_write_lookup),
`endif
      .o_fatal(l1_fatal),
      .o_fatal_addr(l1_fatal_addr)
  );
`ifndef LOCAL_ATOMIC_DEPENDENCY
  assign local_owner = 0;
  assign local_phase = 0;
  assign home_atomic_write_lookup = 0;
`endif
  logic sc_coherent_arm_valid;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] sc_coherent_arm_tag;
  logic sc_coherent_valid;
  logic [riscv_pkg::XLEN-1:0] sc_coherent_addr;
  logic [2:0] sc_coherent_size;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] sc_coherent_tag;
  logic sc_coherent_result_ready;
  logic sc_sc_value_zero;
  logic sc_sc_head_query_match;
  logic sc_sc_head_addr_valid;
  logic [riscv_pkg::XLEN-1:0] sc_sc_head_addr;
  logic sc_sc_head_is_cached;
  logic sc_sc_fire_success;
  logic sc_sc_pending;
  riscv_pkg::fu_complete_t sc_sc_fu_complete;
  sc_pending_unit sc (
      .i_atomic_protected(protected_q),
      .i_reservation_size(LocalLR ? lq_reservation_size : 3'd3),
      .o_coherent_arm_valid(sc_coherent_arm_valid),
      .o_coherent_arm_tag(sc_coherent_arm_tag),
      .o_coherent_valid(sc_coherent_valid),
      .i_coherent_ready(l1_sc_ready),
      .o_coherent_addr(sc_coherent_addr),
      .o_coherent_size(sc_coherent_size),
      .o_coherent_tag(sc_coherent_tag),
      .i_coherent_result_valid(l1_sc_result_valid),
      .o_coherent_result_ready(sc_coherent_result_ready),
      .i_coherent_success(l1_sc_success),
      .i_coherent_error(l1_sc_error),
      .o_sc_value_zero(sc_sc_value_zero),
      .i_clk(i_clk),
      .i_rst_n(!rst),
      .i_flush_en('0),
      .i_flush_tag('0),
      .i_head_tag(head),
      .i_sq_committed_empty(sq_committed_empty),
      .i_lq_reservation_valid(LocalLR ? lq_reservation_valid : 1'b1),
      .i_lq_reservation_addr(LocalLR ? lq_reservation_addr : address1),
      .i_mem_adapter_result_pending(dependency_mem_pending),
      .i_lq_fu_complete(completion_lq),
      .i_sc_completion_pending(dependency_sc_pending),
      .i_store_misalign_fu_complete_reg('0),
      .i_mem_rs_issue(sc_issue),
      .i_sq_effective_addr(address1),
      .i_sct_alloc_addr_valid(1'b1),
      .i_sct_addr_fill_valid('0),
      .i_sct_addr_fill_tag('0),
      .i_sct_addr_fill_addr('0),
      .i_speculative_flush_all('0),
      .i_speculative_flush_en('0),
      .i_coh_sc_hold(LOCAL_PROGRESS && l1_cut_hold),
      .i_coh_query_addr('0),
      .o_sc_head_query_match(sc_sc_head_query_match),
      .o_sc_head_addr_valid(sc_sc_head_addr_valid),
      .o_sc_head_addr(sc_sc_head_addr),
      .o_sc_head_is_cached(sc_sc_head_is_cached),
      .o_sc_fire_success(sc_sc_fire_success),
      .o_sc_pending(sc_sc_pending),
      .o_sc_fu_complete(sc_sc_fu_complete)
  );
  if (LOCAL_PROGRESS) begin : gen_local_progress
    logic [5:0] owner_age_q = 0;
    logic [2:0] probe_age_q = 0;
    logic owner_seen_q = 0, write_seen_q = 0, released_q = 0;
    logic [15:0] interrupt_seen_q = 0;
    always_ff @(posedge i_clk) begin
      // Prefix stores use ready home channels. The separate boundary tasks
      // check their arbitrary stalls; the unrelated load keeps U withheld.
      assume (permit_d && permit_g && permit_c && permit_u);
      if (rst) begin
        owner_age_q <= 0;
        probe_age_q <= 0;
        owner_seen_q <= 0;
        write_seen_q <= 0;
        released_q <= 0;
        interrupt_seen_q <= 0;
      end else begin
        // The interval begins after translation and protected selection.
        if (!protected_q) assume (!control_pending);
        if (local_owner) begin
          owner_age_q  <= owner_age_q + 1'b1;
          owner_seen_q <= 1;
          p_owner_bound : assert (owner_age_q < 32);
          p_local_protection : assert (protected_q);
          p_no_late_store : assert (!ordinary_write && !l1_pending_store);
          p_no_local_demand : assert (!l1_d_valid[0]);
          if (l1_write_done) write_seen_q <= 1;
          if (!guard_retired)
            p_protected_head_can_retire :
            assert (!commit_hold);
            else p_younger_retirement_held : assert (commit_hold);
        end else begin
          owner_age_q <= 0;
          if (owner_seen_q) released_q <= 1;
        end
        if (owner_seen_q && !local_owner && !probe_accepted_q) begin
          probe_age_q <= probe_age_q + 1'b1;
          p_offered_probe_bound : assert (probe_age_q < 4);
        end else probe_age_q <= 0;
        if (released_q) p_installed_before_release : assert (write_seen_q);
        if (LocalLR && local_owner && !write_seen_q && !l1_write_done) begin
          p_local_sc_reservation :
          assert (lq_reservation_valid &&
              lq_reservation_addr == address1 && lq_reservation_size == 3);
          p_local_sc_after_lr : assert (lr_complete_q);
        end
        if (LocalLR && $past(l1_sc_write_done))
          p_local_sc_clears_reservation : assert (!lq_reservation_valid);
        if (lq_fu_complete.valid && Mode == 1)
          p_local_old_value : assert (lq_fu_complete.value == {8{second_byte}});
        if (protected_q && control_pending) interrupt_seen_q[local_phase] <= 1;
        if (COVER_LOCAL) begin
          assume (permit_d && permit_g && permit_c && permit_u);
          assume (first_byte == 8'h11 && second_byte == 8'h22);
          cover (released_q && probe_accepted_q && extra_granted_q && |interrupt_seen_q);
          p_competing_mem_results : cover (released_q && competing_results_q == 8);
          p_sc_local_retired : cover (local_owner && guard_retired && Mode == 2 && control_pending);
          p_amo_local_released :
          cover (owner_seen_q && !local_owner && !guard_retired && Mode == 1);
        end
      end
    end
    if (COVER_LOCAL) begin : gen_irq_stages
      localparam logic [15:0] Stages = MODE == 1 ? 16'h3e66 : 16'h3a66;
      always_ff @(posedge i_clk)
        p_control_all_local_stages :
        cover (released_q && probe_accepted_q && extra_granted_q &&
            (interrupt_seen_q & Stages) == Stages);
    end
  end
`ifdef FATAL_STICKY_PROOF
  always_ff @(posedge i_clk)
    if (!rst && !$past(rst))
      p_fatal_sticky : assert (!$past(l1_fatal) || l1_fatal);
`endif
endmodule
