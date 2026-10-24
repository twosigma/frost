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
 * cached_tier_adapter: converts the data-memory request router's 64-bit beats
 * into line requests on the data-side upstream port of the hart's caches
 * (frost_hart_cache).
 *
 * The router side moves one MemDataBits beat per transaction with MemStrbBits
 * byte strobes, as defined under "Data-tier bus contract" in hw/rtl/README.md.
 * The line side carries LINE_BYTES-byte lines.
 *
 * Router-side protocol:
 *   - i_read_req: a one-cycle pulse for an accepted cached-region load, with
 *     the load queue's slot id on i_read_id, the address on i_req_addr, and
 *     i_read_no_merge set for an LR or AMO read. It completes any number of
 *     cycles later with o_read_valid, o_read_id, and o_read_data (the
 *     addressed beat), held until i_read_ready. Up to READ_SLOTS reads may be
 *     outstanding, one per slot id, and they complete in any order. With
 *     SPLIT_READ_REQ the request also arrives as a select between two early
 *     terms, i_read_req_sel ? i_read_req_if_sel : i_read_req_if_clear, which
 *     must equal i_read_req; the accept state takes the select at its last
 *     LUT.
 *   - i_write_byte_en != 0: a cached-region store fired this cycle, with its
 *     address on i_req_addr and its data on i_write_data, completed by an
 *     o_write_done pulse. One store is in flight at a time. o_write_inflight
 *     is high from the cycle after the store fires until the done pulse. The
 *     router ORs it into write_port_busy with its own write enables, which
 *     cover the fire cycle, so no load reaches the port while a cached store
 *     is pending.
 *
 * Reads of one line share a line request. A read that finds no open group
 * for its line opens one: its slot number becomes the group's line id, and
 * one full-line read goes out for the group. A later read of the same line
 * joins the open group instead, while the group's response is still owed,
 * and takes its own beat from that response. A store firing closes every
 * group, so a read accepted after a store never joins a request that went
 * out before it. An LR or AMO read opens a group that nobody joins and never
 * joins one. The decision is registered on the accepting edge; a read that
 * joins a group in the cycle its response arrives takes its beat from that
 * response.
 *
 * A write becomes a line write with the beat replicated across every lane and
 * the strobes on the addressed lane (the cache merges on a miss). It uses
 * WriteId. Pending requests go out as soon as the cache is ready, the store
 * first, so several may be in flight; the cache orders same-line requests by
 * acceptance.
 *
 * A line response completes every read of its group. A slot that holds no
 * beat takes the beat on the response port every cycle, at its own address,
 * or at the request's while it is free, so the response id reaches no beat
 * register's enable. The group's reads become ready on the next edge, named
 * by the registered response id, and their beats stay until they move to the
 * output register, which takes the ready slots in rotation. When none is
 * ready, the beat of the slot that opened the arriving response's group goes
 * straight to the output register.
 */
module cached_tier_adapter #(
    parameter int unsigned XLEN = riscv_pkg::XLEN,
    parameter int unsigned LINE_BYTES = 32,
    // Line-port transaction id width and the number of read slots. A group's
    // line id is the slot that opened it (0..READ_SLOTS-1); the single store
    // uses id READ_SLOTS.
    parameter int unsigned LINE_ID_BITS = 4,
    parameter int unsigned READ_SLOTS = riscv_pkg::CachedLoadSlots,
    // Take the request's late term as the last select before each accept-state
    // flop, for timing. The split inputs are unused when this is clear.
    parameter bit SPLIT_READ_REQ = 1'b0,
    localparam int unsigned SlotBits = (READ_SLOTS > 1) ? $clog2(READ_SLOTS) : 1
) (
    input logic i_clk,
    input logic i_rst,

    // Router-facing request side (one aligned beat per transaction).
    input logic                              i_read_req,
    input logic                              i_read_req_sel,
    input logic                              i_read_req_if_sel,
    input logic                              i_read_req_if_clear,
    input logic [              SlotBits-1:0] i_read_id,
    input logic                              i_read_no_merge,
    input logic [                  XLEN-1:0] i_req_addr,
    input logic [riscv_pkg::MemStrbBits-1:0] i_write_byte_en,
    input logic [riscv_pkg::MemDataBits-1:0] i_write_data,

    // Router-facing completion side.
    output logic [riscv_pkg::MemDataBits-1:0] o_read_data,
    output logic [              SlotBits-1:0] o_read_id,
    output logic                              o_read_valid,
    output logic                              o_read_error,
    input  logic                              i_read_ready,
    output logic                              o_write_done,
    output logic                              o_write_inflight,

    // Line port master (to the cache hierarchy).
    output logic                    o_line_req_valid,
    input  logic                    i_line_req_ready,
    output logic                    o_line_req_write,
    output logic [        XLEN-1:0] o_line_req_addr,
    output logic [LINE_BYTES*8-1:0] o_line_req_wdata,
    output logic [  LINE_BYTES-1:0] o_line_req_wstrb,
    output logic [LINE_ID_BITS-1:0] o_line_req_id,
    input  logic                    i_line_resp_valid,
    input  logic                    i_line_resp_error = 1'b0,
    input  logic [LINE_ID_BITS-1:0] i_line_resp_id,
    input  logic [LINE_BYTES*8-1:0] i_line_resp_rdata
);

  localparam int unsigned BeatBits = riscv_pkg::MemDataBits;
  localparam int unsigned BeatStrbBits = riscv_pkg::MemStrbBits;
  localparam int unsigned BeatOffBits = $clog2(BeatStrbBits);  // addr bits below the beat index
  localparam int unsigned BeatsPerLine = LINE_BYTES / BeatStrbBits;
  localparam int unsigned BeatSelBits = $clog2(BeatsPerLine);
  localparam int unsigned OffsetBits = $clog2(LINE_BYTES);
  localparam logic [LINE_ID_BITS-1:0] WriteId = LINE_ID_BITS'(READ_SLOTS);

  initial begin
    if ((1 << LINE_ID_BITS) <= READ_SLOTS)
      $fatal(1, "cached_tier_adapter: LINE_ID_BITS cannot address the store id");
    // The output rotation wraps slot numbers modulo 2**SlotBits.
    if ((1 << SlotBits) != READ_SLOTS)
      $fatal(1, "cached_tier_adapter: READ_SLOTS must be a power of two");
  end

  // ---- Read slots and groups ----------------------------------------------------
  // A slot is valid from acceptance until its beat moves to the output
  // register; it is ready while its beat waits in rd_data_q. A group is live
  // from the read that opens it until its line response, and only its opening
  // slot's index names it, so a live group's opening slot is always valid.
  logic [  READ_SLOTS-1:0] rd_valid_q;
  logic [  READ_SLOTS-1:0] rd_ready_q;
  logic [  READ_SLOTS-1:0] rd_error_q;
  logic [  READ_SLOTS-1:0] rd_group_oh_q                                   [READ_SLOTS];
  logic [    BeatBits-1:0] rd_data_q                                       [READ_SLOTS];
  // Use flops because all free slots sample i_req_addr on each edge. A valid
  // slot holds its address until its beat leaves. This captures each launched
  // address without putting i_read_req on the address enables; idle data is
  // unused.
  (* ram_style = "registers" *)
  logic [        XLEN-1:0] rd_addr_q                                       [READ_SLOTS];
  logic [  READ_SLOTS-1:0] grp_live_q;  // line response owed
  logic [  READ_SLOTS-1:0] grp_sent_q;  // line request fired
  logic [  READ_SLOTS-1:0] grp_open_q;  // later reads of the line may join

  // ---- Pending store ------------------------------------------------------------
  logic                    pending_write_valid;
  logic                    pending_write_sent;
  logic [        XLEN-1:0] pending_write_addr;
  logic [    BeatBits-1:0] pending_write_data;
  logic [BeatStrbBits-1:0] pending_write_byte_en;

  logic                    write_fire;
  assign write_fire = |i_write_byte_en;

  // ---- Issue: the store first, then the lowest unsent group --------------------
  logic                issue_write;
  logic                issue_read_any;
  logic [SlotBits-1:0] issue_read_sel;
  always_comb begin
    issue_read_any = 1'b0;
    issue_read_sel = '0;
    for (int g = int'(READ_SLOTS) - 1; g >= 0; g--) begin
      if (grp_live_q[g] && !grp_sent_q[g]) begin
        issue_read_any = 1'b1;
        issue_read_sel = SlotBits'(g);
      end
    end
  end
  assign issue_write = pending_write_valid && !pending_write_sent;

  assign o_line_req_valid = issue_write || issue_read_any;
  assign o_line_req_write = issue_write;
  assign o_line_req_addr = issue_write ?
      {pending_write_addr[XLEN-1:OffsetBits], {OffsetBits{1'b0}}} :
      {rd_addr_q[issue_read_sel][XLEN-1:OffsetBits], {OffsetBits{1'b0}}};
  // Beat replicated across every lane; the strobes select the addressed lanes.
  assign o_line_req_wdata = {BeatsPerLine{pending_write_data}};
  always_comb begin
    o_line_req_wstrb = '0;
    o_line_req_wstrb[pending_write_addr[OffsetBits-1:BeatOffBits]*BeatStrbBits+:BeatStrbBits] =
        pending_write_byte_en;
  end
  assign o_line_req_id = issue_write ? WriteId : LINE_ID_BITS'(issue_read_sel);

  logic line_req_fire;
  assign line_req_fire = o_line_req_valid && i_line_req_ready;

  // ---- Responses ----------------------------------------------------------------
  logic resp_is_write, resp_is_read;
  logic [SlotBits-1:0] resp_group;
  assign resp_is_write = i_line_resp_valid && (i_line_resp_id == WriteId);
  assign resp_is_read  = i_line_resp_valid && (i_line_resp_id != WriteId);
  assign resp_group    = SlotBits'(i_line_resp_id);

  // The members of the answered group, and each slot's beat of the response.
  // Each slot holds its group one-hot, so membership is one bit of it.
  logic [READ_SLOTS-1:0] resp_member;
  logic [  BeatBits-1:0] resp_beat   [READ_SLOTS];
  always_comb begin
    for (int s = 0; s < int'(READ_SLOTS); s++) begin
      resp_member[s] = resp_is_read && rd_valid_q[s] && !rd_ready_q[s] &&
          rd_group_oh_q[s][resp_group];
      resp_beat[s] = i_line_resp_rdata[rd_addr_q[s][BeatOffBits+:BeatSelBits]*BeatBits+:BeatBits];
    end
  end
  // The group's opening slot, which the response id names, is always a
  // member; its beat is the one that can bypass to the output register.
  logic [BeatSelBits-1:0] bypass_beat_sel;
  logic [   BeatBits-1:0] bypass_beat;
  assign bypass_beat_sel = rd_addr_q[resp_group][BeatOffBits+:BeatSelBits];
  assign bypass_beat = i_line_resp_rdata[bypass_beat_sel*BeatBits+:BeatBits];

  // The previous cycle's read response: its members become ready now, and
  // their beats, taken on the response edge, hold from now on.
  logic                  resp_read_q;
  logic [  SlotBits-1:0] resp_group_q;
  logic [READ_SLOTS-1:0] answered;
  always_comb begin
    for (int s = 0; s < int'(READ_SLOTS); s++) begin
      answered[s] = resp_read_q && rd_valid_q[s] && !rd_ready_q[s] &&
          rd_group_oh_q[s][resp_group_q];
    end
  end

  // ---- Join decision for an accepted read --------------------------------------
  // A group can be joined while it is open. Only one group of a line is ever
  // open, since a read opens a group only when none of its line is, so the
  // match vector is already one-hot. A read that joins the group being
  // answered on its accepting edge takes its beat from that response.
  logic [READ_SLOTS-1:0] attach_match;
  logic                  attach_any;
  logic                  attach_answered;
  logic [  BeatBits-1:0] accept_beat;
  always_comb begin
    for (int g = 0; g < int'(READ_SLOTS); g++) begin
      attach_match[g] = grp_open_q[g] &&
          (rd_addr_q[g][XLEN-1:OffsetBits] == i_req_addr[XLEN-1:OffsetBits]);
    end
    attach_any = (|attach_match) && !i_read_no_merge;
  end
  assign attach_answered = attach_any && resp_is_read && attach_match[resp_group];
  assign accept_beat = i_line_resp_rdata[i_req_addr[BeatOffBits+:BeatSelBits]*BeatBits+:BeatBits];

  // ---- Output: the waiting slots in rotation, else an arriving beat ------------
  logic                out_take;
  logic                ready_any;
  logic [SlotBits-1:0] ready_pick;
  logic [SlotBits-1:0] rr_q;  // the slot the rotation starts from
  logic                bypass;
  logic [SlotBits-1:0] bypass_slot;
  assign out_take  = !o_read_valid || i_read_ready;
  assign ready_any = |rd_ready_q;
  always_comb begin
    ready_pick = '0;
    for (int n = int'(READ_SLOTS) - 1; n >= 0; n--) begin
      if (rd_ready_q[SlotBits'(rr_q+SlotBits'(n))]) ready_pick = SlotBits'(rr_q + SlotBits'(n));
    end
  end
  assign bypass_slot = resp_group;
  assign bypass = out_take && !ready_any && resp_is_read;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      rd_ready_q          <= '0;
      rr_q                <= '0;
      pending_write_valid <= 1'b0;
      pending_write_sent  <= 1'b0;
      o_write_done        <= 1'b0;
      o_read_valid        <= 1'b0;
      resp_read_q         <= 1'b0;
    end else begin
      o_write_done <= 1'b0;
      resp_read_q  <= resp_is_read;

      // Launch.
      if (line_req_fire && issue_write) pending_write_sent <= 1'b1;

      // Line responses: a read response completes its group, and on the next
      // edge its members are ready, but for one bypassed to the output
      // register, which is no longer valid by then.
      if (resp_is_write) begin
        pending_write_valid <= 1'b0;
        o_write_done        <= 1'b1;
      end
      for (int s = 0; s < int'(READ_SLOTS); s++) begin
        if (answered[s]) rd_ready_q[s] <= 1'b1;
      end

      // Output.
      if (out_take) begin
        o_read_valid <= ready_any || resp_is_read;
        if (ready_any) begin
          rd_ready_q[ready_pick] <= 1'b0;
          rr_q                   <= ready_pick + 1'b1;
        end
      end
      if (write_fire && !pending_write_valid) begin
        pending_write_valid   <= 1'b1;
        pending_write_sent    <= 1'b0;
        pending_write_addr    <= i_req_addr;
        pending_write_data    <= i_write_data;
        pending_write_byte_en <= i_write_byte_en;
      end
    end
  end

  // Address capture and beat payloads (no reset).
  // ---- Accept state: slot valid and the slot's group bits ------------------------
  // The request's select and each slot's line-port term (the response that
  // answers or bypasses it, or the line request that sends its group) are the
  // late inputs, so they meet only at the last LUT before each flop. With
  // SPLIT_READ_REQ the select is the router's live-launch bit; without it, the
  // request itself. The other inputs come from registers or early terms. An
  // accepted slot was free, so neither the output nor a response concerns it in
  // its accept cycle. A read that joins a group leaves its slot's group bits
  // alone. A store closes every group; no read is accepted while it fires.
  logic                  read_sel;
  logic                  read_if_sel;
  logic                  read_if_clear;
  logic                  open_new;
  logic [READ_SLOTS-1:0] slot_hit;
  // The slot is accepted if the select is set, or clear, and opens a group.
  logic [READ_SLOTS-1:0] acc_if_sel, acc_if_clear, open_if_sel, open_if_clear;
  // Late per-slot line-port terms.
  logic [READ_SLOTS-1:0] resp_hit, bypass_hit, sent_hit;
  logic [READ_SLOTS-1:0] valid_keep, open_keep;
  logic [READ_SLOTS-1:0] valid_next, live_next, sent_next, open_next;
  assign read_sel      = SPLIT_READ_REQ ? i_read_req_sel : i_read_req;
  assign read_if_sel   = SPLIT_READ_REQ ? i_read_req_if_sel : 1'b1;
  assign read_if_clear = SPLIT_READ_REQ ? i_read_req_if_clear : 1'b0;
  assign open_new      = !i_read_no_merge;
  always_comb begin
    for (int s = 0; s < int'(READ_SLOTS); s++) begin
      slot_hit[s] = i_read_id == SlotBits'(s);
      acc_if_sel[s] = read_if_sel && slot_hit[s];
      acc_if_clear[s] = read_if_clear && slot_hit[s];
      open_if_sel[s] = acc_if_sel[s] && !attach_any;
      open_if_clear[s] = acc_if_clear[s] && !attach_any;
      resp_hit[s] = resp_is_read && (resp_group == SlotBits'(s));
      bypass_hit[s] = bypass && (bypass_slot == SlotBits'(s));
      sent_hit[s] = line_req_fire && !issue_write && (issue_read_sel == SlotBits'(s));
      valid_keep[s] = rd_valid_q[s] && !(out_take && ready_any && (ready_pick == SlotBits'(s)));
      open_keep[s] = grp_open_q[s] && !write_fire;
    end
  end

  // Final LUT functions, inputs listed I4 (or I5) down to I0:
  //   valid: sel, acc_if_sel, acc_if_clear, valid_keep, bypass_hit
  //          (sel ? acc_if_sel : acc_if_clear) | (valid_keep & !bypass_hit)
  //   live:  sel, open_if_sel, open_if_clear, grp_live_q, resp_hit
  //          (sel ? open_if_sel : open_if_clear) | (grp_live_q & !resp_hit)
  //   sent:  sel, open_if_sel, open_if_clear, grp_sent_q, sent_hit
  //          (sel ? open_if_sel : open_if_clear) ? 0 : (grp_sent_q | sent_hit)
  //   open:  sel, open_if_sel, open_if_clear, open_new, open_keep, resp_hit
  //          (sel ? open_if_sel : open_if_clear) ? open_new : (open_keep & !resp_hit)
  localparam logic [31:0] ValidInit = 32'hff44f4f4;
  localparam logic [31:0] LiveInit  = 32'hff44f4f4;
  localparam logic [31:0] SentInit  = 32'h00ee0e0e;
  localparam logic [63:0] OpenInit  = 64'hf0f04444f044f044;
  for (genvar s = 0; s < int'(READ_SLOTS); s++) begin : gen_accept_slot
`ifdef FROST_XILINX_PRIMS
    (* dont_touch = "true" *)
    LUT5 #(
        .INIT(ValidInit)
    ) u_valid (
        .I0(bypass_hit[s]),
        .I1(valid_keep[s]),
        .I2(acc_if_clear[s]),
        .I3(acc_if_sel[s]),
        .I4(read_sel),
        .O (valid_next[s])
    );
    (* dont_touch = "true" *)
    LUT5 #(
        .INIT(LiveInit)
    ) u_live (
        .I0(resp_hit[s]),
        .I1(grp_live_q[s]),
        .I2(open_if_clear[s]),
        .I3(open_if_sel[s]),
        .I4(read_sel),
        .O (live_next[s])
    );
    (* dont_touch = "true" *)
    LUT5 #(
        .INIT(SentInit)
    ) u_sent (
        .I0(sent_hit[s]),
        .I1(grp_sent_q[s]),
        .I2(open_if_clear[s]),
        .I3(open_if_sel[s]),
        .I4(read_sel),
        .O (sent_next[s])
    );
    (* dont_touch = "true" *)
    LUT6 #(
        .INIT(OpenInit)
    ) u_open (
        .I0(resp_hit[s]),
        .I1(open_keep[s]),
        .I2(open_new),
        .I3(open_if_clear[s]),
        .I4(open_if_sel[s]),
        .I5(read_sel),
        .O (open_next[s])
    );
`else
    logic opens;
    assign opens = read_sel ? open_if_sel[s] : open_if_clear[s];
    assign valid_next[s] = (read_sel ? acc_if_sel[s] : acc_if_clear[s]) ||
        (valid_keep[s] && !bypass_hit[s]);
    assign live_next[s] = opens || (grp_live_q[s] && !resp_hit[s]);
    assign sent_next[s] = !opens && (grp_sent_q[s] || sent_hit[s]);
    assign open_next[s] = opens ? open_new : (open_keep[s] && !resp_hit[s]);
`endif
  end

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      rd_valid_q <= '0;
      grp_live_q <= '0;
      grp_sent_q <= '0;
      grp_open_q <= '0;
    end else begin
      rd_valid_q <= valid_next;
      grp_live_q <= live_next;
      grp_sent_q <= sent_next;
      grp_open_q <= open_next;
    end
  end

`ifndef SYNTHESIS
  // The accept state follows its unsplit definition, and each final LUT's INIT
  // gives the same bit as the portable form above.
  always_comb begin
    for (int s = 0; s < int'(READ_SLOTS); s++) begin
      logic acc, opens, valid_ref, live_ref, sent_ref, open_ref, known;
      logic [4:0] valid_idx, live_idx, sent_idx;
      logic [5:0] open_idx;
      acc = i_read_req && slot_hit[s];
      opens = acc && !attach_any;
      valid_ref = acc || (rd_valid_q[s] && !bypass_hit[s] &&
                          !(out_take && ready_any && (ready_pick == SlotBits'(s))));
      live_ref = opens || (grp_live_q[s] && !resp_hit[s]);
      sent_ref = !opens && (grp_sent_q[s] || sent_hit[s]);
      open_ref = opens ? open_new : (grp_open_q[s] && !write_fire && !resp_hit[s]);
      // LUT inputs, I4 (or I5) down to I0.
      valid_idx = {read_sel, acc_if_sel[s], acc_if_clear[s], valid_keep[s], bypass_hit[s]};
      live_idx = {read_sel, open_if_sel[s], open_if_clear[s], grp_live_q[s], resp_hit[s]};
      sent_idx = {read_sel, open_if_sel[s], open_if_clear[s], grp_sent_q[s], sent_hit[s]};
      open_idx = {read_sel, open_if_sel[s], open_if_clear[s], open_new, open_keep[s], resp_hit[s]};
      known = !$isunknown(
          {
            i_read_req,
            read_if_sel,
            read_if_clear,
            attach_any,
            rd_valid_q[s],
            grp_live_q[s],
            grp_sent_q[s],
            grp_open_q[s],
            write_fire,
            valid_idx,
            live_idx,
            sent_idx,
            open_idx
          }
      );
      if (!i_rst && known && ((read_sel ? read_if_sel : read_if_clear) == i_read_req)) begin
        p_accept_state_exact :
        assert ({valid_next[s], live_next[s], sent_next[s], open_next[s]} ==
                {valid_ref, live_ref, sent_ref, open_ref});
        p_accept_lut_inits :
        assert ({ValidInit[valid_idx], LiveInit[live_idx], SentInit[sent_idx],
                 OpenInit[open_idx]} == {valid_ref, live_ref, sent_ref, open_ref});
      end
    end
  end
`endif

  always_ff @(posedge i_clk) begin
    resp_group_q <= resp_group;
    // The LQ launches only into a free slot. Sampling free addresses and join
    // groups captures the request on its accepting edge; a free slot's group
    // is never read, since every use qualifies it with rd_valid_q. A slot that
    // is neither ready nor just
    // answered takes the response port's beat every cycle, so a waiting read
    // has its group's beat on the response edge, and a read that joins the
    // group answered on its accepting edge has it too. No enable waits for
    // i_read_req or the response id.
    for (int s = 0; s < int'(READ_SLOTS); s++) begin
      if (!rd_valid_q[s]) begin
        rd_addr_q[s] <= i_req_addr;
        rd_group_oh_q[s] <= attach_any ? attach_match : READ_SLOTS'(1) << s;
      end
      if (!rd_ready_q[s] && !answered[s]) begin
        rd_data_q[s]  <= rd_valid_q[s] ? resp_beat[s] : accept_beat;
        rd_error_q[s] <= i_line_resp_error;
      end
    end
    if (out_take) begin
      o_read_data <= ready_any ? rd_data_q[ready_pick] : bypass_beat;
      o_read_id <= ready_any ? ready_pick : bypass_slot;
      o_read_error <= ready_any ? rd_error_q[ready_pick] : i_line_resp_error;
    end
  end

  assign o_write_inflight = pending_write_valid;

`ifndef SYNTHESIS
  logic reset_seen_q = 1'b0;
  always_ff @(posedge i_clk) if (i_rst) reset_seen_q <= 1'b1;
  logic                  launch_check_q;
  logic [  SlotBits-1:0] launch_id_q;
  logic [      XLEN-1:0] launch_addr_q;
  logic [READ_SLOTS-1:0] launch_group_q;
  always_ff @(posedge i_clk) begin
    if (i_rst) launch_check_q <= 1'b0;
    if (reset_seen_q && !i_rst) begin
      if (i_read_req && rd_valid_q[i_read_id])
        $error("cached_tier_adapter: read request on slot %0d while it is pending", i_read_id);
      if (SPLIT_READ_REQ &&
          i_read_req !== (i_read_req_sel ? i_read_req_if_sel : i_read_req_if_clear))
        $error("cached_tier_adapter: split read request disagrees with i_read_req");
      if (i_read_req && write_fire)
        $error("cached_tier_adapter: read request in the cycle a store fires");
      if (i_read_req && !$onehot0(attach_match))
        $error("cached_tier_adapter: two open groups of one line: %b", attach_match);
      // The free-slot sampling above captures the launched address and join
      // group exactly.
      launch_check_q <= i_read_req;
      launch_id_q    <= i_read_id;
      launch_addr_q  <= i_req_addr;
      launch_group_q <= attach_any ? attach_match : READ_SLOTS'(1) << i_read_id;
      if (launch_check_q && rd_addr_q[launch_id_q] !== launch_addr_q)
        $error("cached_tier_adapter: slot %0d did not capture its launch address", launch_id_q);
      if (launch_check_q && rd_group_oh_q[launch_id_q] !== launch_group_q)
        $error("cached_tier_adapter: slot %0d did not capture its join group", launch_id_q);
      if (write_fire && pending_write_valid)
        $error("cached_tier_adapter: write request while a write is already pending");
      if (resp_is_write && !pending_write_sent)
        $error("cached_tier_adapter: write response with no write in flight");
      if (resp_is_read && !(grp_live_q[resp_group] && grp_sent_q[resp_group]))
        $error("cached_tier_adapter: read response for group %0d not in flight", resp_group);
      if (resp_is_read && !(|resp_member))
        $error("cached_tier_adapter: read response for group %0d with no reads", resp_group);
      for (int g = 0; g < int'(READ_SLOTS); g++) begin
        // A live group's opening slot waits on it.
        if (grp_live_q[g] && !(rd_valid_q[g] && !rd_ready_q[g] && rd_group_oh_q[g][g]))
          $error("cached_tier_adapter: live group %0d without its opening read", g);
      end
      for (int s = 0; s < int'(READ_SLOTS); s++) begin
        // A waiting read names exactly one group, and that group is live
        // unless its response arrived on the last edge.
        if (rd_valid_q[s] && !rd_ready_q[s] && !$onehot(rd_group_oh_q[s]))
          $error("cached_tier_adapter: slot %0d waits on group set %b", s, rd_group_oh_q[s]);
        if (rd_valid_q[s] && !rd_ready_q[s] && !answered[s] && !(|(rd_group_oh_q[s] & grp_live_q)))
          $error(
              "cached_tier_adapter: slot %0d waits on group set %b, which is not live",
              s,
              rd_group_oh_q[s]
          );
        if (rd_ready_q[s] && !rd_valid_q[s])
          $error("cached_tier_adapter: slot %0d ready but not valid", s);
      end
    end
  end

  // Each beat that reaches the output register must be the beat its slot's
  // group response carried for the slot's address: a reference copy taken on
  // the response edge must match the beat when it leaves.
  logic [BeatBits-1:0] ref_beat_q[READ_SLOTS];
  logic [BeatBits-1:0] ref_out_data_q;
  logic [SlotBits-1:0] ref_out_id_q;
  always_ff @(posedge i_clk) begin
    if (reset_seen_q && !i_rst) begin
      for (int s = 0; s < int'(READ_SLOTS); s++) begin
        if (resp_member[s]) ref_beat_q[s] <= resp_beat[s];
      end
      if (i_read_req && attach_answered) ref_beat_q[i_read_id] <= accept_beat;
      if (out_take && ready_any) begin
        ref_out_data_q <= ref_beat_q[ready_pick];
        ref_out_id_q   <= ready_pick;
      end else if (out_take && bypass) begin
        ref_out_data_q <= bypass_beat;
        ref_out_id_q   <= bypass_slot;
      end
      if (o_read_valid) begin
        p_read_beat_exact : assert ({o_read_data, o_read_id} == {ref_out_data_q, ref_out_id_q});
      end
    end
  end
`endif

endmodule : cached_tier_adapter
