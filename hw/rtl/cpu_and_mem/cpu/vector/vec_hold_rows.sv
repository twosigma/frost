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
  Range-ordering holds for one scalar queue (the load queue or the store
  queue) against the vector memory table: a scalar entry is held while an
  older live vector memory instruction overlaps it, or has an unknown range,
  or the entry's own address is not known yet.

  Each entry has a row with one bit per table entry. In the entry's first
  valid cycle (valid, valid mirror clear) the row is formed combinationally
  from the table entries that are live and either retired (always older than
  anything in the ROB; their tags may already be reused, so they are never
  compared) or older by ROB tag against the head of the previous cycle, and
  registered; the hold therefore covers the entry from its first valid cycle,
  as the load queue's older-AMO rows do. A row bit then only clears, when its
  table entry is no longer live; the table never reuses an index in the cycle
  it frees it, and a reused index belongs to a younger instruction.

  The entry's first and last 32-byte sector are captured from the queue's
  address update, or, with DIRECT_ADDR, registered every cycle from per-entry
  address, size and address-valid inputs (the store queue keeps those in
  registers; cbo.zero and Zicbom use the full aligned physical block).
  The overlap of each (entry, table entry) pair and whether it
  is valid (entry address and table range both known) are registered together
  from the same registered sectors and known bit, so a hold never uses an
  overlap computed from older ones. An entry's address is written once (both
  queues update only entries without one).

  With CURSOR_ONLY=1 (used by the store queue, which only drains at its
  cursor), every entry keeps its older-VMT row (initialized with two age
  comparators for up to two newly-valid entries per cycle), while sector
  derivation and VMT range overlap run only for i_cursor_idx. Non-cursor
  entries hold conservatively while any older VMT entry is live and release
  immediately once no older VMT entry is live; the cursor releases once its
  own two-stage overlap pipeline settles with no match.

    o_hold_d[i] = valid[i] && |(row[i] & live & (atomic[i] | ~ovl_valid[i] | ovl[i]))

  Atomic entries (AMO, LR) wait for every older live entry. With the table
  idle every hold is 0.
*/
module vec_hold_rows #(
    parameter int unsigned DEPTH = 8,
    parameter bit DIRECT_ADDR = 1'b0,
    parameter bit CURSOR_ONLY = 1'b0,
    // Table entries (riscv_pkg::VmtDepth; fewer only in proofs)
    parameter int unsigned VMT = riscv_pkg::VmtDepth,
    // DIRECT_ADDR: log2 of the block compared for cbo.zero and Zicbom when
    // i_block_flat is set, at least 5 and at most 12
    parameter int unsigned BLOCK_LSB = 6,
    localparam int unsigned IdxW = DEPTH > 1 ? $clog2(DEPTH) : 1,
    localparam int unsigned TagW = riscv_pkg::ReorderBufferTagWidth,
    localparam int unsigned XLEN = riscv_pkg::XLEN,
    localparam int unsigned PA = riscv_pkg::PhysAddrBits,
    localparam int unsigned SecW = riscv_pkg::PhysAddrBits - 5,
    localparam int unsigned PpnW = riscv_pkg::VmtPpnBits
) (
    input  logic                                   i_clk,
    input  logic                                   i_rst,
    input  logic [                      DEPTH-1:0] i_valid,
    input  logic [                 DEPTH*TagW-1:0] i_tag_flat,
    input  logic [                      DEPTH-1:0] i_atomic,
    input  logic [                       TagW-1:0] i_head_tag,
    // Address update: entry index, address (physical) and log2 of the size
    input  logic                                   i_upd_valid,
    input  logic [                       IdxW-1:0] i_upd_idx,
    input  logic [                       XLEN-1:0] i_upd_addr,
    input  logic [                            1:0] i_upd_size,
    // DIRECT_ADDR: every entry's address, log2 size and address-valid bit
    input  logic [                 DEPTH*XLEN-1:0] i_addr_flat = '0,
    input  logic [                    DEPTH*2-1:0] i_size_flat = '0,
    input  logic [                      DEPTH-1:0] i_addr_valid = '0,
    input  logic [                      DEPTH-1:0] i_block_flat = '0,
    // CURSOR_ONLY: single entry evaluated for range overlap
    input  logic [                       IdxW-1:0] i_cursor_idx = '0,
    input  logic [VMT*riscv_pkg::VmtEntryBits-1:0] i_vmt,
    output logic [                      DEPTH-1:0] o_hold_d
);

  function automatic logic is_older_than(input logic [TagW-1:0] source_tag,
                                         input logic [TagW-1:0] dest_tag,
                                         input logic [TagW-1:0] head);
    logic [TagW:0] source_age, dest_age;
    source_age = {1'b0, source_tag} - {1'b0, head};
    dest_age = {1'b0, dest_tag} - {1'b0, head};
    is_older_than = source_age < dest_age;
  endfunction

  // Bytes in an access of 2**s bytes, minus one (0, 1, 3 or 7).
  function automatic logic [2:0] size_minus1(input logic [1:0] s);
    size_minus1 = {s == 2'd3, s >= 2'd2, s != 2'd0};
  endfunction

  // A segment covers a sector when it is valid, the page matches and the
  // index is in [lo, hi].
  function automatic logic seg_covers(input logic valid, input logic [PpnW-1:0] ppn,
                                      input logic [6:0] lo, input logic [6:0] hi,
                                      input logic [SecW-1:0] sec);
    seg_covers = valid && (ppn == sec[SecW-1:7]) && (sec[6:0] >= lo) && (sec[6:0] <= hi);
  endfunction

  // Table fields by bit offset in riscv_pkg::vmt_entry_t (Yosys does not
  // select struct members of array elements).
  localparam int unsigned EntW = riscv_pkg::VmtEntryBits;
  localparam int unsigned SegW = 1 + PpnW + 14;
  logic [VMT-1:0] live, retired, range_known;
  logic [VMT-1:0][TagW-1:0] vtag;
  logic [VMT-1:0][1:0] sv;
  logic [VMT-1:0][1:0][PpnW-1:0] sppn;
  logic [VMT-1:0][1:0][6:0] slo, shi;
  for (genvar t = 0; t < VMT; t++) begin : gen_vmt
    assign live[t] = i_vmt[EntW*t+2*SegW+TagW+2];
    assign retired[t] = i_vmt[EntW*t+2*SegW+TagW+1];
    assign vtag[t] = i_vmt[EntW*t+2*SegW+1+:TagW];
    assign range_known[t] = i_vmt[EntW*t+2*SegW];
    for (genvar g = 0; g < 2; g++) begin : gen_seg
      assign sv[t][g]   = i_vmt[EntW*t+SegW*g+14+PpnW];
      assign sppn[t][g] = i_vmt[EntW*t+SegW*g+14+:PpnW];
      assign slo[t][g]  = i_vmt[EntW*t+SegW*g+7+:7];
      assign shi[t][g]  = i_vmt[EntW*t+SegW*g+:7];
    end
  end

  logic [DEPTH-1:0] mirror_q;
  logic [TagW-1:0] head_q;
  logic [DEPTH-1:0][VMT-1:0] row_q;
  logic [DEPTH-1:0][VMT-1:0] row_d;

  if (CURSOR_ONLY) begin : gen_cursor_only
    // At most two scalar entries allocate per cycle, so i_valid & ~mirror_q
    // has at most two set bits (lowest and highest). Evaluate is_older_than
    // for those two indices instead of all DEPTH entries.
    logic [DEPTH-1:0] new_mask;
    logic [IdxW-1:0] new_idx_lo, new_idx_hi;
    logic new_found_lo;
    logic [TagW-1:0] new_tag_lo, new_tag_hi;
    logic [VMT-1:0] row_init_lo, row_init_hi;
    always_comb begin
      new_mask = i_valid & ~mirror_q;
      new_idx_lo = '0;
      new_idx_hi = '0;
      new_found_lo = 1'b0;
      for (int i = 0; i < DEPTH; i++) begin
        if (new_mask[i]) begin
          if (!new_found_lo) begin
            new_idx_lo = IdxW'(i);
            new_found_lo = 1'b1;
          end
          new_idx_hi = IdxW'(i);
        end
      end
      new_tag_lo = i_tag_flat[TagW*new_idx_lo+:TagW];
      new_tag_hi = i_tag_flat[TagW*new_idx_hi+:TagW];
      for (int t = 0; t < VMT; t++) begin
        row_init_lo[t] = live[t] && (retired[t] || is_older_than(vtag[t], new_tag_lo, head_q));
        row_init_hi[t] = live[t] && (retired[t] || is_older_than(vtag[t], new_tag_hi, head_q));
      end
      for (int i = 0; i < DEPTH; i++) begin
        for (int t = 0; t < VMT; t++) begin
          if (!i_valid[i]) row_d[i][t] = 1'b0;
          else if (!mirror_q[i])
            row_d[i][t] = (IdxW'(i) == new_idx_lo) ? row_init_lo[t] : row_init_hi[t];
          else row_d[i][t] = row_q[i][t] && live[t];
        end
      end
    end

    logic [SecW-1:0] cur_direct_lo, cur_direct_hi;
    always_comb begin
      logic [PA-1:0] a, last;
      a = i_addr_flat[XLEN*i_cursor_idx+:PA];
      last = a + PA'(size_minus1(i_size_flat[2*i_cursor_idx+:2]));
      if (i_block_flat[i_cursor_idx]) begin
        a = {a[PA-1:BLOCK_LSB], BLOCK_LSB'(0)};
        last = {a[PA-1:BLOCK_LSB], {BLOCK_LSB{1'b1}}};
      end
      cur_direct_lo = a[PA-1:5];
      cur_direct_hi = last[PA-1:5];
    end

    logic [SecW-1:0] cur_sec_lo_q, cur_sec_hi_q;
    logic cur_addr_known_q;
    logic [IdxW-1:0] cur_sec_idx_q, cur_ovl_idx_q;
    logic [VMT-1:0] cur_ovl_q, cur_ovl_valid_q;

    always_ff @(posedge i_clk) begin
      if (i_rst) begin
        mirror_q <= '0;
        row_q <= '0;
        cur_addr_known_q <= 1'b0;
        cur_ovl_valid_q <= '0;
      end else begin
        mirror_q <= i_valid;
        row_q <= row_d;
        cur_addr_known_q <= i_valid[i_cursor_idx] && i_addr_valid[i_cursor_idx];
        for (int t = 0; t < VMT; t++) begin
          cur_ovl_valid_q[t] <= i_valid[cur_sec_idx_q] && mirror_q[cur_sec_idx_q] &&
              cur_addr_known_q && (cur_sec_idx_q == i_cursor_idx) && range_known[t];
        end
      end
    end

    always_ff @(posedge i_clk) begin
      head_q <= i_head_tag;
      cur_sec_idx_q <= i_cursor_idx;
      cur_sec_lo_q <= cur_direct_lo;
      cur_sec_hi_q <= cur_direct_hi;
      cur_ovl_idx_q <= cur_sec_idx_q;
      for (int t = 0; t < VMT; t++) begin
        cur_ovl_q[t] <= seg_covers(sv[t][0], sppn[t][0], slo[t][0], shi[t][0], cur_sec_lo_q) ||
            seg_covers(sv[t][1], sppn[t][1], slo[t][1], shi[t][1], cur_sec_lo_q) ||
            seg_covers(sv[t][0], sppn[t][0], slo[t][0], shi[t][0], cur_sec_hi_q) ||
            seg_covers(sv[t][1], sppn[t][1], slo[t][1], shi[t][1], cur_sec_hi_q);
      end
    end

    wire cur_ovl_match = (cur_ovl_idx_q == i_cursor_idx) && mirror_q[i_cursor_idx];
    always_comb begin
      for (int i = 0; i < DEPTH; i++) begin
        logic [VMT-1:0] eff_ovl_valid;
        eff_ovl_valid = ((IdxW'(i) == i_cursor_idx) && cur_ovl_match) ? cur_ovl_valid_q : '0;
        o_hold_d[i] = i_valid[i] &&
            |(row_d[i] & (i_atomic[i] ? '1 : (~eff_ovl_valid | cur_ovl_q)));
      end
    end
  end else begin : gen_all_entries
    logic [SecW-1:0] sec_lo_q[DEPTH];
    logic [SecW-1:0] sec_hi_q[DEPTH];
    logic [DEPTH-1:0] addr_known_q;
    logic [VMT-1:0] ovl_q[DEPTH];
    logic [VMT-1:0] ovl_valid_q[DEPTH];

    // Sectors of the access [addr, addr + size - 1].
    logic [SecW-1:0] upd_lo, upd_hi;
    // Physical-address bits only: the low bits of the sum do not depend on the
    // high ones.
    logic [PA-1:0] upd_last;
    assign upd_last = i_upd_addr[PA-1:0] + PA'(size_minus1(i_upd_size));
    assign upd_lo   = i_upd_addr[riscv_pkg::PhysAddrBits-1:5];
    assign upd_hi   = upd_last[riscv_pkg::PhysAddrBits-1:5];

    logic [SecW-1:0] direct_lo[DEPTH];
    logic [SecW-1:0] direct_hi[DEPTH];
    always_comb begin
      for (int i = 0; i < DEPTH; i++) begin
        logic [PA-1:0] a, last;
        a = i_addr_flat[XLEN*i+:PA];
        last = a + PA'(size_minus1(i_size_flat[2*i+:2]));
        // A block entry (cbo.zero) is recorded with a byte size but writes its
        // whole aligned block.
        if (i_block_flat[i]) begin
          a = {a[PA-1:BLOCK_LSB], BLOCK_LSB'(0)};
          last = {a[PA-1:BLOCK_LSB], {BLOCK_LSB{1'b1}}};
        end
        direct_lo[i] = a[riscv_pkg::PhysAddrBits-1:5];
        direct_hi[i] = last[riscv_pkg::PhysAddrBits-1:5];
      end
    end

    always_comb begin
      for (int i = 0; i < DEPTH; i++) begin
        for (int t = 0; t < VMT; t++) begin
          if (!i_valid[i]) row_d[i][t] = 1'b0;
          else if (!mirror_q[i])
            row_d[i][t] = live[t] && (retired[t] || is_older_than(
              vtag[t], i_tag_flat[TagW*i+:TagW], head_q
            ));
          else row_d[i][t] = row_q[i][t] && live[t];
        end
      end
    end

    always_ff @(posedge i_clk) begin
      if (i_rst) begin
        mirror_q <= '0;
        row_q <= '0;
        addr_known_q <= '0;
        for (int i = 0; i < DEPTH; i++) ovl_valid_q[i] <= '0;
      end else begin
        mirror_q <= i_valid;
        for (int i = 0; i < DEPTH; i++) begin
          for (int t = 0; t < VMT; t++) begin
            row_q[i][t] <= row_d[i][t];
            // Valid-qualified: on the edge after a free, addr_known_q still has
            // the old generation's value, and the new entry's first cycle must
            // see an unknown address.
            ovl_valid_q[i][t] <= i_valid[i] && addr_known_q[i] && range_known[t];
          end
          if (DIRECT_ADDR) begin
            addr_known_q[i] <= i_valid[i] && i_addr_valid[i];
          end else if (!i_valid[i]) addr_known_q[i] <= 1'b0;
          else if (i_upd_valid && i_upd_idx == IdxW'(i)) addr_known_q[i] <= 1'b1;
        end
      end
    end

    // Payload and overlap registers stay off the reset net; mirror_q, row_q,
    // addr_known_q, and ovl_valid_q gate every use.
    always_ff @(posedge i_clk) begin
      head_q <= i_head_tag;
      for (int i = 0; i < DEPTH; i++) begin
        for (int t = 0; t < VMT; t++) begin
          ovl_q[i][t] <= seg_covers(sv[t][0], sppn[t][0], slo[t][0], shi[t][0], sec_lo_q[i]) ||
              seg_covers(sv[t][1], sppn[t][1], slo[t][1], shi[t][1], sec_lo_q[i]) ||
              seg_covers(sv[t][0], sppn[t][0], slo[t][0], shi[t][0], sec_hi_q[i]) ||
              seg_covers(sv[t][1], sppn[t][1], slo[t][1], shi[t][1], sec_hi_q[i]);
        end
        if (DIRECT_ADDR) begin
          sec_lo_q[i] <= direct_lo[i];
          sec_hi_q[i] <= direct_hi[i];
        end
      end
      if (!DIRECT_ADDR && i_upd_valid) begin
        sec_lo_q[i_upd_idx] <= upd_lo;
        sec_hi_q[i_upd_idx] <= upd_hi;
      end
    end

    always_comb begin
      for (int i = 0; i < DEPTH; i++)
      o_hold_d[i] = i_valid[i] && |(row_d[i] & (i_atomic[i] ? '1 : (~ovl_valid_q[i] | ovl_q[i])));
    end
  end

endmodule
