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
 * parcel_consume_engine -- the stage-2 front end's consume side
 * (PARCEL_QUEUE_DESIGN.md section 2.3).  Combinational: it reads the parcel
 * queue's first-word-fall-through presented view (head + head+1) and forms the
 * two IF->PD packets plus the dequeue count.
 *
 * BUNDLE FORMER: slot-1 = head; slot-2 = head+1 iff both are valid and
 * `e0.allows_slot2_after && e1.slot2_start_ok && !e0.predicted_taken`.  The
 * `!predicted_taken` term preserves the downstream invariant "slot-2 PC =
 * slot-1 PC + size(slot-1)" -- after a taken branch the next entry is the
 * target, discontiguous.
 *
 * PACKET FORMATION: every `from_if_to_pd_t` field is a pure function of the
 * entry fields (design 2.3): program_counter and link_address from the entry PC
 * and size, raw_parcel/effective_instr from the assembled bytes (slot-2 RVC is
 * expanded here by the single consume-side rvc_decompressor; slot-1 RVC is
 * expanded in PD from raw_parcel as today), and the btb and bp_dir metadata
 * straight from the bound entry.
 *
 * QUEUE EMPTY (or flush) => sel_nop with zeroed prediction metadata -- the ONLY
 * bubble source at consume (redirect latency / L1I miss / fill shuffles all
 * manifest identically as an empty queue).
 *
 * STALL: dequeue is gated by `!i_stall`.  The head entries do not move, so the
 * identical bundle is re-presented on release by construction (no _sc replay).
 *
 * DEFERRED (a later integration phase): the consume-side RAS (design 2.4) --
 * `ras_detector` on the head entry, edge-triggered on dequeue-fire, driving the
 * ras_* packet fields and the return redirect.  Those fields are zeroed here.
 */
module parcel_consume_engine #(
    parameter int unsigned XLEN = 32
) (
    // ---- Parcel-queue presented view (FWFT-aware, combinational) ----
    input logic                 [1:0] i_entry_valid,  // [0]=head valid, [1]=head+1 valid
    input riscv_pkg::pq_entry_t       i_entry0,       // head
    input riscv_pkg::pq_entry_t       i_entry1,       // head+1

    // ---- Control ----
    input logic i_stall,  // front-end stall: freeze the head (deq_count = 0)
    input logic i_flush,  // flush: present NOP bubbles this cycle

    // ---- Slot-1 RAS metadata (from parcel_consume_ras, design 2.4) ----
    input logic                             i_slot1_ras_predicted,
    input logic [                 XLEN-1:0] i_slot1_ras_predicted_target,
    input logic [riscv_pkg::RasPtrBits-1:0] i_slot1_ras_checkpoint_tos,
    input logic [  riscv_pkg::RasPtrBits:0] i_slot1_ras_checkpoint_valid_count,

    // ---- IF->PD packets ----
    output riscv_pkg::from_if_to_pd_t o_slot1,
    output riscv_pkg::from_if_to_pd_t o_slot2,

    // ---- Dequeue count back to the queue ----
    output logic [1:0] o_deq_count
);

  localparam logic [XLEN-1:0] NopWord = riscv_pkg::NOP;

  // ===========================================================================
  // Bundle former (design 2.3)
  // ===========================================================================
  logic slot1_valid, slot2_pair, slot2_valid;
  assign slot1_valid = i_entry_valid[0] && !i_flush;
  assign slot2_pair = i_entry_valid[1] && i_entry0.allows_slot2_after &&
                      i_entry1.slot2_start_ok && !i_entry0.predicted_taken;
  assign slot2_valid = slot1_valid && slot2_pair;

  // Dequeue IS delivery; a stall freezes the head so the same bundle re-presents.
  assign o_deq_count = i_stall ? 2'd0 : (slot2_valid ? 2'd2 : (slot1_valid ? 2'd1 : 2'd0));

  // ===========================================================================
  // Slot-2 RVC decompression (the single consume-side decompressor)
  // ===========================================================================
  logic [31:0] slot2_expanded;
  logic        slot2_decomp_illegal_raw;
  logic        slot2_rvc_is_compressed_unused;  // entry carries is_compressed already
  rvc_decompressor u_slot2_rvc (
      .i_instr_compressed(i_entry1.instr_bytes[15:0]),
      .o_instr_expanded  (slot2_expanded),
      .o_is_compressed   (slot2_rvc_is_compressed_unused),
      .o_illegal         (slot2_decomp_illegal_raw)
  );

  // e0 is read as slot-1 (its allows_slot2_after gates pairing) and e1 as slot-2
  // (its slot2_start_ok gates pairing); the cross fields matter only when an
  // entry occupies the other slot on a later consume cycle.  Sink the bits
  // unused in this position so lint stays clean.
  wire _unused = &{1'b0, slot2_rvc_is_compressed_unused, i_entry0.slot2_start_ok,
                   i_entry1.allows_slot2_after, i_entry1.dir_taken};

  // ===========================================================================
  // Packet formation
  // ===========================================================================
  logic [XLEN-1:0] slot1_pc, slot2_pc;
  assign slot1_pc = {i_entry0.pc, 1'b0};
  assign slot2_pc = {i_entry1.pc, 1'b0};

  always_comb begin
    o_slot1 = '0;
    o_slot1.sel_nop = !slot1_valid;
    o_slot1.effective_instr = riscv_pkg::instr_t'(NopWord);
    if (slot1_valid) begin
      o_slot1.program_counter = slot1_pc;
      o_slot1.raw_parcel = i_entry0.instr_bytes[15:0];
      o_slot1.sel_compressed = i_entry0.is_compressed;
      // Slot-1 RVC is expanded in PD from raw_parcel; pass the entry bytes.
      o_slot1.effective_instr = i_entry0.instr_bytes;
      o_slot1.link_address = slot1_pc +
          (i_entry0.is_compressed ? riscv_pkg::PcIncrementCompressed
                                  : riscv_pkg::PcIncrement32bit);
      o_slot1.btb_hit = i_entry0.btb_hit;
      o_slot1.btb_predicted_taken = i_entry0.predicted_taken;
      o_slot1.btb_predicted_target = {i_entry0.predicted_target, 1'b0};
      o_slot1.bp_dir_taken = i_entry0.dir_taken;
      o_slot1.bp_dir_idx = i_entry0.dir_idx;
      // RAS metadata from the consume-side RAS (design 2.4).
      o_slot1.ras_predicted = i_slot1_ras_predicted;
      o_slot1.ras_predicted_target = i_slot1_ras_predicted_target;
      o_slot1.ras_checkpoint_tos = i_slot1_ras_checkpoint_tos;
      o_slot1.ras_checkpoint_valid_count = i_slot1_ras_checkpoint_valid_count;
    end
  end

  always_comb begin
    o_slot2 = '0;
    o_slot2.sel_nop = !slot2_valid;
    o_slot2.effective_instr = riscv_pkg::instr_t'(NopWord);
    if (slot2_valid) begin
      o_slot2.program_counter = slot2_pc;
      o_slot2.raw_parcel = i_entry1.instr_bytes[15:0];
      o_slot2.sel_compressed = i_entry1.is_compressed;
      // Slot-2 RVC is pre-expanded here (as today's aligner did for slot-2).
      o_slot2.effective_instr = i_entry1.is_compressed ?
          riscv_pkg::instr_t'(slot2_expanded) : i_entry1.instr_bytes;
      o_slot2.link_address = slot2_pc +
          (i_entry1.is_compressed ? riscv_pkg::PcIncrementCompressed
                                  : riscv_pkg::PcIncrement32bit);
      o_slot2.btb_hit = i_entry1.btb_hit;
      o_slot2.btb_predicted_taken = i_entry1.predicted_taken;
      o_slot2.btb_predicted_target = {i_entry1.predicted_target, 1'b0};
      // PD consumes the decoupled direction hint only on slot-1, so slot-2's
      // bp_dir_taken is held 0 (matching HEAD); the index still rides for
      // commit-time training.
      o_slot2.bp_dir_taken = 1'b0;
      o_slot2.bp_dir_idx = i_entry1.dir_idx;
      o_slot2.decomp_illegal = i_entry1.is_compressed && slot2_decomp_illegal_raw;
      // Slot-2 has no return prediction; its checkpoints mirror slot-1's
      // (matching HEAD) so recovery sees the pre-bundle RAS state.
      o_slot2.ras_checkpoint_tos = i_slot1_ras_checkpoint_tos;
      o_slot2.ras_checkpoint_valid_count = i_slot1_ras_checkpoint_valid_count;
    end
  end

`ifndef SYNTHESIS
  // Whenever a bundle forms, slot-2 must be the contiguous successor of slot-1.
  always_comb begin
    if (slot2_valid) begin
      p_slot2_contiguous :
      assert (i_entry1.pc == (i_entry0.pc + (i_entry0.is_compressed ? 31'd1 : 31'd2)))
      else $error("parcel_consume_engine: slot-2 not contiguous with slot-1");
    end
  end
`endif

endmodule : parcel_consume_engine
