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
  registers; an entry with its block bit set, cbo.zero, is widened to its
  aligned block). The overlap of each (entry, table entry) pair and whether it
  is valid (entry address and table range both known) are registered together
  from the same registered sectors and known bit, so a hold never uses an
  overlap computed from older ones. An entry's address is written once (both
  queues update only entries without one).

    o_hold_d[i] = valid[i] && |(row[i] & live & (atomic[i] | ~ovl_valid[i] | ovl[i]))

  Atomic entries (AMO, LR) wait for every older live entry. With the table
  idle every hold is 0.
*/
module vec_hold_rows #(
    parameter int unsigned DEPTH = 8,
    parameter bit DIRECT_ADDR = 1'b0,
    // Table entries (riscv_pkg::VmtDepth; fewer only in proofs)
    parameter int unsigned VMT = riscv_pkg::VmtDepth,
    // DIRECT_ADDR: log2 of the block an entry with its i_block_flat bit set
    // writes (cbo.zero), at least 5 and at most 12
    parameter int unsigned BLOCK_LSB = 6,
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
    input  logic [              $clog2(DEPTH)-1:0] i_upd_idx,
    input  logic [                       XLEN-1:0] i_upd_addr,
    input  logic [                            1:0] i_upd_size,
    // DIRECT_ADDR: every entry's address, log2 size and address-valid bit
    input  logic [                 DEPTH*XLEN-1:0] i_addr_flat = '0,
    input  logic [                    DEPTH*2-1:0] i_size_flat = '0,
    input  logic [                      DEPTH-1:0] i_addr_valid = '0,
    input  logic [                      DEPTH-1:0] i_block_flat = '0,
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
  logic [DEPTH-1:0][SecW-1:0] sec_lo_q, sec_hi_q;
  logic [DEPTH-1:0] addr_known_q;
  logic [DEPTH-1:0][VMT-1:0] ovl_q, ovl_valid_q;

  // Sectors of the access [addr, addr + size - 1].
  logic [SecW-1:0] upd_lo, upd_hi;
  // Physical-address bits only: the low bits of the sum do not depend on the
  // high ones.
  logic [PA-1:0] upd_last;
  assign upd_last = i_upd_addr[PA-1:0] + PA'(size_minus1(i_upd_size));
  assign upd_lo   = i_upd_addr[riscv_pkg::PhysAddrBits-1:5];
  assign upd_hi   = upd_last[riscv_pkg::PhysAddrBits-1:5];

  logic [DEPTH-1:0][SecW-1:0] direct_lo, direct_hi;
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

  logic [DEPTH-1:0][VMT-1:0] row_d;
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
      ovl_valid_q <= '0;
    end else begin
      mirror_q <= i_valid;
      head_q   <= i_head_tag;
      for (int i = 0; i < DEPTH; i++) begin
        for (int t = 0; t < VMT; t++) begin
          row_q[i][t] <= row_d[i][t];
          ovl_q[i][t] <= seg_covers(
              sv[t][0], sppn[t][0], slo[t][0], shi[t][0], sec_lo_q[i]
          ) || seg_covers(
              sv[t][1], sppn[t][1], slo[t][1], shi[t][1], sec_lo_q[i]
          ) || seg_covers(
              sv[t][0], sppn[t][0], slo[t][0], shi[t][0], sec_hi_q[i]
          ) || seg_covers(
              sv[t][1], sppn[t][1], slo[t][1], shi[t][1], sec_hi_q[i]
          );
          // Valid-qualified: on the edge after a free, addr_known_q still has
          // the old generation's value, and the new entry's first cycle must
          // see an unknown address.
          ovl_valid_q[i][t] <= i_valid[i] && addr_known_q[i] && range_known[t];
        end
        if (DIRECT_ADDR) begin
          addr_known_q[i] <= i_valid[i] && i_addr_valid[i];
          sec_lo_q[i] <= direct_lo[i];
          sec_hi_q[i] <= direct_hi[i];
        end else if (!i_valid[i]) addr_known_q[i] <= 1'b0;
        else if (i_upd_valid && i_upd_idx == $clog2(DEPTH)'(i)) addr_known_q[i] <= 1'b1;
      end
      if (!DIRECT_ADDR && i_upd_valid) begin
        sec_lo_q[i_upd_idx] <= upd_lo;
        sec_hi_q[i_upd_idx] <= upd_hi;
      end
    end
  end

  always_comb begin
    for (int i = 0; i < DEPTH; i++)
    o_hold_d[i] = i_valid[i] && |(row_d[i] & (i_atomic[i] ? '1 : (~ovl_valid_q[i] | ovl_q[i])));
  end

endmodule
