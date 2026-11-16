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
  Vector memory unit using the hart coherence line client.

  Splits a translated contiguous vector (or single-row matrix) byte span into
  32-byte sector requests on the hart's coherence line client using six
  dedicated request identities (hart line-client IDs 2..7).

  Coordinates are Page-0-relative starting from i_page_offset (va_first[11:0])
  at element i_first_elem through element i_last_elem:
    - Sectors whose active byte mask is all-zero (all elements masked off) are
      skipped without issuing a line-client request.
    - Store sectors gather their active VRF bytes across 1..3 VRF read beats
      before issuing a masked 32-byte sector write.
    - Load sectors issue up to 6 concurrent 32-byte sector reads, buffer out-of-
      order responses per identity, and write active bytes into the VRF through
      registered write-port flops (preserving undisturbed prestart, masked-off,
      and tail bytes).
    - Any line-client response error (load or store, retired or Case-C partial
      Page-0) raises a sticky hart fatal error with no VRF write.
*/
module vec_vmu #(
    parameter int unsigned VLEN = 256,
    localparam int unsigned NumSlots = 6,
    localparam int unsigned SlotBits = 3,
    localparam int unsigned LineIdBase = 2,
    localparam int unsigned LineIdBits = 4,
    localparam int unsigned SectorBytes = 32,
    localparam int unsigned SectorBits = 256,
    localparam int unsigned VlenBytes = VLEN / 8,
    localparam int unsigned Log2VlenBytes = $clog2(VlenBytes),
    localparam int unsigned PhysAddrBits = riscv_pkg::PhysAddrBits,
    localparam int unsigned VmtPpnBits = riscv_pkg::VmtPpnBits,
    localparam int unsigned VmtIdxW = $clog2(riscv_pkg::VmtDepth),
    localparam int unsigned SegW = 1 + VmtPpnBits + 14
) (
    input logic i_clk,
    input logic i_rst,
    input logic i_fatal_stop,

    // Command launch (accepted in a single cycle while o_idle is 1)
    input logic                  i_cmd_valid,
    input logic [VmtPpnBits-1:0] i_ppn0,
    input logic [VmtPpnBits-1:0] i_ppn1,
    input logic [          11:0] i_page_offset,
    input logic [          15:0] i_first_elem,
    input logic [          15:0] i_last_elem,
    input logic [           1:0] i_eew_log2,
    input logic [          63:0] i_row_stride,
    input logic [          15:0] i_row_count,
    input logic [      VLEN-1:0] i_active_mask,
    input logic                  i_is_store,
    input logic [           4:0] i_vd_vs3,
    input logic [   VmtIdxW-1:0] i_vmt_idx,
    input logic                  i_free_vmt_on_done,
    input logic [      SegW-1:0] i_dbg_seg0,
    input logic [      SegW-1:0] i_dbg_seg1,

    // Status & VMT completion
    output logic               o_idle,
    output logic               o_done,
    output logic               o_vmt_done_valid,
    output logic [VmtIdxW-1:0] o_vmt_done_idx,

    // VRF read port (1-cycle registered read)
    output logic            o_xr_en,
    output logic [     4:0] o_xr_addr,
    input  logic [VLEN-1:0] i_xr_data,

    // VRF write port
    output logic                 o_xw_en,
    output logic [          4:0] o_xw_addr,
    output logic [     VLEN-1:0] o_xw_data,
    output logic [VlenBytes-1:0] o_xw_be,

    // Line-client port (identities 2..7)
    output logic                    o_lc_req_valid,
    input  logic                    i_lc_req_ready,
    output logic                    o_lc_req_write,
    output logic [PhysAddrBits-1:0] o_lc_req_addr,
    output logic [  SectorBits-1:0] o_lc_req_data,
    output logic [ SectorBytes-1:0] o_lc_req_mask,
    output logic [  LineIdBits-1:0] o_lc_req_id,
    input  logic                    i_lc_resp_valid,
    input  logic [  LineIdBits-1:0] i_lc_resp_id,
    input  logic [  SectorBits-1:0] i_lc_resp_data,
    input  logic                    i_lc_resp_error,

    // Sticky post-retirement / Case-C bus error
    output logic                    o_fatal,
    output logic [PhysAddrBits-1:0] o_fatal_addr
);

  initial begin
    if (VLEN != 128 && VLEN != 256 && VLEN != 512)
      $fatal(1, "vec_vmu: VLEN must be 128, 256 or 512");
  end

  typedef enum logic [3:0] {
    VMU_IDLE,
    VMU_SEC_BASE,
    VMU_SEC_MASK,
    VMU_SEC_ALLOC,
    VMU_ST_ADDR,
    VMU_ST_CAP,
    VMU_ISSUE,
    VMU_DRAIN,
    VMU_DONE,
    VMU_FATAL
  } issue_state_e;

  typedef enum logic [0:0] {
    WB_IDLE,
    WB_BEAT
  } wb_state_e;

  issue_state_e issue_state_q;
  wb_state_e wb_state_q;

  // Latched command parameters
  logic [VmtPpnBits-1:0] ppn0_q, ppn1_q;
  logic [11:0] page_offset_q;
  logic [12:0] first_vrf_byte_q, last_vrf_byte_q;
  logic [1:0] eew_log2_q;
  (* max_fanout = 64 *) logic [VLEN-1:0] active_mask_q;
  logic is_store_q;
  logic [4:0] vd_vs3_q;
  logic [VmtIdxW-1:0] vmt_idx_q;
  logic free_vmt_on_done_q;
  riscv_pkg::vmt_seg_t dbg_seg0_q, dbg_seg1_q;

  // Sector stepping & slot allocation
  logic [8:0] cur_sec_q, end_sec_q;
  logic [SlotBits-1:0] alloc_ptr_q;

  // Pipelined sector-preparation registers
  logic signed [14:0] prep_vrf_base_q;
  (* dont_touch = "true" *) logic [3:0][14:0] prep_vrf_base_rep_q;
  logic [2:0] prep_reg_lo_q, prep_reg_hi_q;
  logic [PhysAddrBits-1:0] prep_pa_q;
  logic [SectorBytes-1:0] prep_byte_mask_q;
  logic [3:0] prep_byte_any_grp_q;

  // Per-identity sector buffers (slots 0..5 -> hart IDs 2..7)
  logic [NumSlots-1:0] buf_valid_q, buf_ready_q;
  logic [SectorBits-1:0] buf_data_q[NumSlots];
  logic [SectorBytes-1:0] buf_mask_q[NumSlots];
  logic signed [14:0] buf_vrf_base_q[NumSlots];
  logic [2:0] buf_reg_lo_q[NumSlots], buf_reg_hi_q[NumSlots];
  logic [PhysAddrBits-1:0] buf_pa_q[NumSlots];

  // Store-gather & request staging registers
  logic [2:0] st_reg_cur_q, st_reg_hi_q;
  (* max_fanout = 32 *) logic signed [14:0] st_vrf_base_q;
  logic [SectorBytes-1:0] st_sec_mask_q;
  logic [PhysAddrBits-1:0] st_sec_pa_q;
  logic [SectorBits-1:0] st_sec_data_q;

  logic [SlotBits-1:0] req_slot_q;
  logic [PhysAddrBits-1:0] req_addr_q;
  logic [SectorBytes-1:0] req_mask_q;
  logic [SectorBits-1:0] req_data_q;

  // Load VRF writeback staging & output registers
  logic [SlotBits-1:0] wb_slot_q;
  logic [2:0] wb_reg_cur_q, wb_reg_hi_q;
  (* max_fanout = 32 *) logic signed [14:0] wb_vrf_base_q;
  logic [SectorBytes-1:0] wb_mask_q;
  logic [SectorBits-1:0] wb_data_q;

  logic xw_en_q;
  logic [4:0] xw_addr_q;
  logic [VLEN-1:0] xw_data_q;
  logic [VlenBytes-1:0] xw_be_q;

  logic fatal_q;
  logic [PhysAddrBits-1:0] fatal_addr_q;

  // --------------------------------------------------------------------------
  // Command start & current sector coordinate computation
  // --------------------------------------------------------------------------
  logic [12:0] cmd_first_vrf_byte, cmd_last_vrf_byte;
  logic [13:0] cmd_p0_start, cmd_p0_end;

  assign cmd_first_vrf_byte = {3'b000, i_first_elem[9:0]} << i_eew_log2;
  assign cmd_last_vrf_byte  = ({3'b000, i_last_elem[9:0]} << i_eew_log2) +
                              (13'd1 << i_eew_log2) - 13'd1;
  assign cmd_p0_start = {2'b00, i_page_offset};
  assign cmd_p0_end = cmd_p0_start + 14'(cmd_last_vrf_byte - cmd_first_vrf_byte);

  logic signed [14:0] prep_vrf_base_d, prep_vrf_end_d;
  logic [12:0] prep_vrf_lo_d, prep_vrf_hi_d;
  logic [2:0] prep_reg_lo_d, prep_reg_hi_d;
  logic [PhysAddrBits-1:0] prep_pa_d;
  logic [ SectorBytes-1:0] prep_byte_mask_d;

  assign prep_vrf_base_d = $signed(
      {1'b0, cur_sec_q, 5'b00000}
  ) - $signed(
      {3'b000, page_offset_q}
  ) + $signed(
      {2'b00, first_vrf_byte_q}
  );
  assign prep_vrf_end_d = prep_vrf_base_d + 15'sd31;
  assign prep_vrf_lo_d = (prep_vrf_base_d < $signed(
      {2'b00, first_vrf_byte_q}
  )) ? first_vrf_byte_q : prep_vrf_base_d[12:0];
  assign prep_vrf_hi_d = (prep_vrf_end_d > $signed(
      {2'b00, last_vrf_byte_q}
  )) ? last_vrf_byte_q : prep_vrf_end_d[12:0];
  assign prep_reg_lo_d = prep_vrf_lo_d[Log2VlenBytes+:3];
  assign prep_reg_hi_d = prep_vrf_hi_d[Log2VlenBytes+:3];
  assign prep_pa_d = {(cur_sec_q[7] ? ppn1_q : ppn0_q), cur_sec_q[6:0], 5'b00000};

  always_comb begin
    for (int j = 0; j < SectorBytes; j++) begin
      logic signed [14:0] b_vrf;
      logic in_bounds;
      logic [9:0] elem_idx;
      b_vrf = $signed(prep_vrf_base_rep_q[j/8]) + $signed({10'd0, 5'(j)});
      in_bounds = (b_vrf >= $signed({2'b00, first_vrf_byte_q})) &&
          (b_vrf <= $signed({2'b00, last_vrf_byte_q}));
      elem_idx = b_vrf[9:0] >> eew_log2_q;
      prep_byte_mask_d[j] = in_bounds && active_mask_q[elem_idx[$clog2(VLEN)-1:0]];
    end
  end

  // Store-beat byte accumulation from VRF read port
  logic [SectorBits-1:0] st_sec_data_next;
  always_comb begin
    st_sec_data_next = st_sec_data_q;
    for (int j = 0; j < SectorBytes; j++) begin
      logic signed [14:0] b_vrf;
      logic [2:0] b_reg;
      logic [Log2VlenBytes-1:0] b_off;
      b_vrf = st_vrf_base_q + $signed({10'd0, 5'(j)});
      b_reg = b_vrf[Log2VlenBytes+:3];
      b_off = b_vrf[Log2VlenBytes-1:0];
      if ((b_vrf >= 15'sd0) && (b_reg == st_reg_cur_q) && st_sec_mask_q[j]) begin
        st_sec_data_next[8*j+:8] = i_xr_data[8*b_off+:8];
      end
    end
  end

  // Load-writeback slot selection & beat alignment
  logic wb_pick_valid;
  logic [SlotBits-1:0] wb_pick_slot;
  always_comb begin
    wb_pick_valid = 1'b0;
    wb_pick_slot  = '0;
    for (int s = 0; s < NumSlots; s++) begin
      if (!wb_pick_valid && buf_valid_q[s] && buf_ready_q[s]) begin
        wb_pick_valid = 1'b1;
        wb_pick_slot  = SlotBits'(s);
      end
    end
  end

  logic [VLEN-1:0] wb_beat_data;
  logic [VlenBytes-1:0] wb_beat_be;
  always_comb begin
    for (int m = 0; m < VlenBytes; m++) begin
      logic [9:0] g_byte;
      logic signed [14:0] s_off;
      g_byte = ({7'd0, wb_reg_cur_q} << Log2VlenBytes) | 10'(m);
      s_off  = $signed({5'd0, g_byte}) - wb_vrf_base_q;
      if ((s_off >= 15'sd0) && (s_off < 15'sd32)) begin
        wb_beat_be[m]        = wb_mask_q[s_off[4:0]];
        wb_beat_data[8*m+:8] = wb_data_q[8*s_off[4:0]+:8];
      end else begin
        wb_beat_be[m]        = 1'b0;
        wb_beat_data[8*m+:8] = 8'h00;
      end
    end
  end

  // Response decoding
  logic [LineIdBits-1:0] resp_id_rel;
  logic [SlotBits-1:0] resp_slot;
  logic resp_error_now;

  assign resp_id_rel    = i_lc_resp_id - LineIdBits'(LineIdBase);
  assign resp_slot      = resp_id_rel[SlotBits-1:0];
  assign resp_error_now = i_lc_resp_valid && i_lc_resp_error;

  logic [SlotBits-1:0] alloc_ptr_next;
  assign alloc_ptr_next = (alloc_ptr_q == SlotBits'(NumSlots - 1)) ? '0 : (alloc_ptr_q + 3'd1);

  // --------------------------------------------------------------------------
  // Unified sequential state machine
  // --------------------------------------------------------------------------
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      issue_state_q <= VMU_IDLE;
      wb_state_q    <= WB_IDLE;
      alloc_ptr_q   <= '0;
      buf_valid_q   <= '0;
      buf_ready_q   <= '0;
      xw_en_q       <= 1'b0;
      fatal_q       <= 1'b0;
      fatal_addr_q  <= '0;
    end else begin
      xw_en_q <= 1'b0;

      if (i_fatal_stop || resp_error_now || fatal_q) begin
        issue_state_q <= VMU_FATAL;
        wb_state_q    <= WB_IDLE;
        if (resp_error_now && !fatal_q) begin
          fatal_q      <= 1'b1;
          fatal_addr_q <= buf_pa_q[resp_slot];
        end
        if (i_lc_resp_valid) begin
          buf_valid_q[resp_slot] <= 1'b0;
          buf_ready_q[resp_slot] <= 1'b0;
        end
      end else begin
        // 1. Line-client responses
        if (i_lc_resp_valid) begin
          if (is_store_q) begin
            buf_valid_q[resp_slot] <= 1'b0;
            buf_ready_q[resp_slot] <= 1'b0;
          end else begin
            buf_data_q[resp_slot]  <= i_lc_resp_data;
            buf_ready_q[resp_slot] <= 1'b1;
          end
        end

        // 2. Load VRF writeback FSM
        unique case (wb_state_q)
          WB_IDLE: begin
            if (wb_pick_valid) begin
              wb_slot_q     <= wb_pick_slot;
              wb_reg_cur_q  <= buf_reg_lo_q[wb_pick_slot];
              wb_reg_hi_q   <= buf_reg_hi_q[wb_pick_slot];
              wb_vrf_base_q <= buf_vrf_base_q[wb_pick_slot];
              wb_mask_q     <= buf_mask_q[wb_pick_slot];
              wb_data_q     <= buf_data_q[wb_pick_slot];
              wb_state_q    <= WB_BEAT;
            end
          end
          WB_BEAT: begin
            xw_en_q   <= |wb_beat_be;
            xw_addr_q <= vd_vs3_q + {2'b00, wb_reg_cur_q};
            xw_data_q <= wb_beat_data;
            xw_be_q   <= wb_beat_be;
            if (wb_reg_cur_q == wb_reg_hi_q) begin
              buf_valid_q[wb_slot_q] <= 1'b0;
              buf_ready_q[wb_slot_q] <= 1'b0;
              wb_state_q             <= WB_IDLE;
            end else begin
              wb_reg_cur_q <= wb_reg_cur_q + 3'd1;
            end
          end
          default: wb_state_q <= WB_IDLE;
        endcase

        // 3. Sector issue FSM
        unique case (issue_state_q)
          VMU_IDLE: begin
            if (i_cmd_valid) begin
              ppn0_q             <= i_ppn0;
              ppn1_q             <= i_ppn1;
              page_offset_q      <= i_page_offset;
              first_vrf_byte_q   <= cmd_first_vrf_byte;
              last_vrf_byte_q    <= cmd_last_vrf_byte;
              eew_log2_q         <= i_eew_log2;
              active_mask_q      <= i_active_mask;
              is_store_q         <= i_is_store;
              vd_vs3_q           <= i_vd_vs3;
              vmt_idx_q          <= i_vmt_idx;
              free_vmt_on_done_q <= i_free_vmt_on_done;
              dbg_seg0_q         <= i_dbg_seg0;
              dbg_seg1_q         <= i_dbg_seg1;
              cur_sec_q          <= cmd_p0_start[13:5];
              end_sec_q          <= cmd_p0_end[13:5];
              issue_state_q      <= VMU_SEC_BASE;
            end
          end

          VMU_SEC_BASE: begin
            prep_vrf_base_q <= prep_vrf_base_d;
            for (int r = 0; r < 4; r++) begin
              prep_vrf_base_rep_q[r] <= prep_vrf_base_d;
            end
            prep_reg_lo_q <= prep_reg_lo_d;
            prep_reg_hi_q <= prep_reg_hi_d;
            prep_pa_q     <= prep_pa_d;
            issue_state_q <= VMU_SEC_MASK;
          end

          VMU_SEC_MASK: begin
            prep_byte_mask_q <= prep_byte_mask_d;
            for (int g = 0; g < 4; g++) begin
              prep_byte_any_grp_q[g] <= |prep_byte_mask_d[8*g+:8];
            end
            issue_state_q <= VMU_SEC_ALLOC;
          end

          VMU_SEC_ALLOC: begin
            if (prep_byte_any_grp_q == 4'b0000) begin
              // Skip sectors whose elements are all masked off.
              if (cur_sec_q == end_sec_q) begin
                issue_state_q <= VMU_DRAIN;
              end else begin
                cur_sec_q     <= cur_sec_q + 9'd1;
                issue_state_q <= VMU_SEC_BASE;
              end
            end else if (!buf_valid_q[alloc_ptr_q]) begin
              if (!is_store_q) begin
                buf_valid_q[alloc_ptr_q]    <= 1'b1;
                buf_ready_q[alloc_ptr_q]    <= 1'b0;
                buf_mask_q[alloc_ptr_q]     <= prep_byte_mask_q;
                buf_vrf_base_q[alloc_ptr_q] <= prep_vrf_base_q;
                buf_reg_lo_q[alloc_ptr_q]   <= prep_reg_lo_q;
                buf_reg_hi_q[alloc_ptr_q]   <= prep_reg_hi_q;
                buf_pa_q[alloc_ptr_q]       <= prep_pa_q;
                req_slot_q                  <= alloc_ptr_q;
                req_addr_q                  <= prep_pa_q;
                req_mask_q                  <= '0;
                req_data_q                  <= '0;
                alloc_ptr_q                 <= alloc_ptr_next;
                issue_state_q               <= VMU_ISSUE;
              end else begin
                st_reg_cur_q  <= prep_reg_lo_q;
                st_reg_hi_q   <= prep_reg_hi_q;
                st_vrf_base_q <= prep_vrf_base_q;
                st_sec_mask_q <= prep_byte_mask_q;
                st_sec_pa_q   <= prep_pa_q;
                st_sec_data_q <= '0;
                issue_state_q <= VMU_ST_ADDR;
              end
            end
          end

          VMU_ST_ADDR: begin
            // o_xr_addr presents vd_vs3_q + st_reg_cur_q on this edge.
            issue_state_q <= VMU_ST_CAP;
          end

          VMU_ST_CAP: begin
            st_sec_data_q <= st_sec_data_next;
            if (st_reg_cur_q == st_reg_hi_q) begin
              // Slot alloc_ptr_q remained free because only VMU_SEC_ALLOC/VMU_ST_CAP allocate.
              buf_valid_q[alloc_ptr_q] <= 1'b1;
              buf_ready_q[alloc_ptr_q] <= 1'b0;
              buf_pa_q[alloc_ptr_q]    <= st_sec_pa_q;
              req_slot_q               <= alloc_ptr_q;
              req_addr_q               <= st_sec_pa_q;
              req_mask_q               <= st_sec_mask_q;
              req_data_q               <= st_sec_data_next;
              alloc_ptr_q              <= alloc_ptr_next;
              issue_state_q            <= VMU_ISSUE;
            end else begin
              st_reg_cur_q  <= st_reg_cur_q + 3'd1;
              issue_state_q <= VMU_ST_ADDR;
            end
          end

          VMU_ISSUE: begin
            if (i_lc_req_ready) begin
              if (cur_sec_q == end_sec_q) begin
                issue_state_q <= VMU_DRAIN;
              end else begin
                cur_sec_q     <= cur_sec_q + 9'd1;
                issue_state_q <= VMU_SEC_BASE;
              end
            end
          end

          VMU_DRAIN: begin
            if ((buf_valid_q == '0) && (wb_state_q == WB_IDLE) && !xw_en_q) begin
              issue_state_q <= VMU_DONE;
            end
          end

          VMU_DONE: begin
            issue_state_q <= VMU_IDLE;
          end

          default: ;  // VMU_FATAL holds until reset
        endcase
      end
    end
  end

  // --------------------------------------------------------------------------
  // Outputs
  // --------------------------------------------------------------------------
  assign o_idle = (issue_state_q == VMU_IDLE);
  assign o_done = !i_fatal_stop && !resp_error_now && (issue_state_q == VMU_DONE);
  assign o_vmt_done_valid = o_done && free_vmt_on_done_q;
  assign o_vmt_done_idx = vmt_idx_q;

  assign o_xr_en = (issue_state_q == VMU_ST_ADDR);
  assign o_xr_addr = vd_vs3_q + {2'b00, st_reg_cur_q};

  assign o_xw_en = xw_en_q && !i_fatal_stop && !resp_error_now && !fatal_q;
  assign o_xw_addr = xw_addr_q;
  assign o_xw_data = xw_data_q;
  assign o_xw_be = xw_be_q;

  assign o_lc_req_valid = !i_fatal_stop && !resp_error_now && !fatal_q &&
                          (issue_state_q == VMU_ISSUE);
  assign o_lc_req_write = is_store_q;
  assign o_lc_req_addr = req_addr_q;
  assign o_lc_req_data = req_data_q;
  assign o_lc_req_mask = req_mask_q;
  assign o_lc_req_id = LineIdBits'(LineIdBase) + LineIdBits'(req_slot_q);

  assign o_fatal = fatal_q;
  assign o_fatal_addr = fatal_addr_q;

`ifndef SYNTHESIS
`ifndef FORMAL
  logic vmu_reset_seen_q = 1'b0;
  logic pa_in_seg0, pa_in_seg1;
  assign pa_in_seg0 = dbg_seg0_q.valid &&
                      (o_lc_req_addr[12+:VmtPpnBits] == dbg_seg0_q.ppn) &&
                      (o_lc_req_addr[11:5] >= dbg_seg0_q.s_lo) &&
                      (o_lc_req_addr[11:5] <= dbg_seg0_q.s_hi);
  assign pa_in_seg1 = dbg_seg1_q.valid &&
                      (o_lc_req_addr[12+:VmtPpnBits] == dbg_seg1_q.ppn) &&
                      (o_lc_req_addr[11:5] >= dbg_seg1_q.s_lo) &&
                      (o_lc_req_addr[11:5] <= dbg_seg1_q.s_hi);

  always @(posedge i_clk) begin
    if (i_rst) vmu_reset_seen_q <= 1'b1;
    if (vmu_reset_seen_q && !i_rst) begin
      // The descriptor supports one contiguous row; its row stride is zero.
      assert (!i_cmd_valid || ((i_row_count == 16'd1) && (i_row_stride == 64'd0)));
      // Command only fires when idle.
      assert (!i_cmd_valid || o_idle);
      // Every response delivered to vec_vmu must target an outstanding slot in IDs 2..7.
      assert (!i_lc_resp_valid ||
              ((i_lc_resp_id >= LineIdBits'(LineIdBase)) &&
               (i_lc_resp_id < LineIdBits'(LineIdBase + NumSlots)) &&
               buf_valid_q[resp_slot] && !buf_ready_q[resp_slot]));
      // Store requests always have a non-zero byte mask; read requests have zero mask.
      assert (!o_lc_req_valid || (o_lc_req_write ? (o_lc_req_mask != '0) : (o_lc_req_mask == '0)));
      // Every sector request falls within the VMT range registered for this op.
      assert (!o_lc_req_valid || pa_in_seg0 || pa_in_seg1);
    end
  end
`endif
`endif


`ifdef VEC_VMU_PROOF
  logic f_past_valid = 1'b0;
  logic [5:0] f_pending = '0;
  logic [4:0] f_issued = '0;
  logic f_started = 1'b0;
`ifdef VEC_VMU_COVER_PROOF
  // A concrete fair schedule makes the reachability checks inexpensive:
  // return responses promptly or after filling all six slots. Safety
  // checks do not use this schedule and allow arbitrary response order.
  (* anyconst *) logic f_delay_responses;
  logic [6:0] f_cycle = '0;
  logic [2:0] f_reply_id = 3'd2;
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      f_cycle <= '0;
      f_reply_id <= 3'd2;
    end else begin
      if (f_cycle != 127) f_cycle <= f_cycle + 1'b1;
      if (i_lc_resp_valid) f_reply_id <= f_reply_id == 7 ? 3'd2 : f_reply_id + 1'b1;
    end
    assume (i_lc_req_ready);
    assume (i_lc_resp_id == f_reply_id);
    assume (i_lc_resp_valid == ((!f_delay_responses || f_cycle >= 32) && f_pending[f_reply_id-2]));
  end
`endif
  always_ff @(posedge i_clk) begin
    f_past_valid <= 1'b1;
    if (!f_past_valid)
      assume (i_rst);
      else assume (!i_rst);
    assume (!i_fatal_stop && !i_lc_resp_error);
    assume (i_cmd_valid == (f_past_valid && !f_started));
    assume (i_ppn0 == 20'h83000 && i_ppn1 == 20'h83100);
    assume (i_page_offset == 12'd1 && i_first_elem == 0 && i_last_elem == 192);
    assume (i_eew_log2 == 0 && i_active_mask == '1 && !i_is_store);
    assume (i_vd_vs3 == 8 && i_vmt_idx == 0 && i_free_vmt_on_done);
    assume (i_row_stride == 0 && i_row_count == 1);
    if (i_lc_resp_valid) begin
      assume (i_lc_resp_id >= 2 && i_lc_resp_id < 8);
      assume (f_pending[i_lc_resp_id-2]);
    end
    if (i_rst) begin
      f_pending <= '0;
      f_issued  <= '0;
      f_started <= 1'b0;
    end else begin
      if (i_cmd_valid) f_started <= 1'b1;
      if (i_lc_resp_valid) f_pending[i_lc_resp_id-2] <= 1'b0;
      if (o_lc_req_valid && i_lc_req_ready) begin
        p_identity_range : assert (o_lc_req_id >= 2 && o_lc_req_id < 8);
        p_identity : assert (!f_pending[o_lc_req_id-2]);
        p_sector_order :
        assert (o_lc_req_addr == PhysAddrBits'(32'h83000000) + (PhysAddrBits'(f_issued) << 5));
        p_sector_count : assert (f_issued < 7);
        f_pending[o_lc_req_id-2] <= 1'b1;
        f_issued <= f_issued + 1'b1;
      end
      if (o_done) begin
        p_all_sectors : assert (f_issued == 7 && f_pending == 0);
      end
      if (f_past_valid && !$past(i_rst)) begin
        if ($past(issue_state_q == VMU_SEC_ALLOC && buf_valid_q[alloc_ptr_q])) begin
          p_prepare_stable :
          assert ($stable(
              {
                prep_vrf_base_q,
                prep_vrf_base_rep_q,
                prep_reg_lo_q,
                prep_reg_hi_q,
                prep_pa_q,
                prep_byte_mask_q,
                prep_byte_any_grp_q
              }
          ));
        end
        if ($past(o_lc_req_valid && !i_lc_req_ready)) begin
          p_request_stable :
          assert (o_lc_req_valid && $stable(
              {o_lc_req_addr, o_lc_req_id, o_lc_req_mask, o_lc_req_data}
          ));
        end
      end
      c_full_slot : cover (issue_state_q == VMU_SEC_ALLOC && buf_valid_q[alloc_ptr_q]);
      c_complete : cover (o_done);
    end
  end
`endif

endmodule : vec_vmu
