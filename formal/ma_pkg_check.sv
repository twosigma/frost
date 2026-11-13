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

// Check ma_pkg's geometry, outcome and load-value functions against direct
// references for an arbitrary virtual address, access size and part verdicts,
// and check that the sector split agrees with line_align's crossing flag.
module ma_pkg_check (
    input logic [63:0] va,
    input riscv_pkg::mem_size_e size,
    input ma_pkg::ma_part_e lower,
    input ma_pkg::ma_part_e upper,
    input logic store,
    input logic is_unsigned,
    input logic is_fp,
    input logic [63:0] raw,
    input logic [43:0] ppn,
    input logic [1:0] level,
    input logic [4:0] rwxud,
    input logic eff_priv_u,
    input logic sum,
    input logic mxr
);
  logic [3:0] nbytes;
  assign nbytes = ma_pkg::size_bytes(size);

  logic [64:0] last_byte;
  assign last_byte = {1'b0, va} + 65'(nbytes) - 65'd1;

  logic line_crosses;
  line_align #(
      .LINE_BYTES(32),
      .DATA_BYTES(8)
  ) geometry (
      .i_offset (va[4:0]),
      .i_nbytes (nbytes),
      .i_lo_line('0),
      .i_hi_line('0),
      .o_extract(),
      .i_data   ('0),
      .o_lo_data(),
      .o_hi_data(),
      .o_lo_mask(),
      .o_hi_mask(),
      .o_crosses(line_crosses)
  );

  ma_pkg::ma_outcome_t o;
  assign o = ma_pkg::outcome(lower, upper, ma_pkg::crosses_sector(size, va), store, va);

  logic [63:0] ref_value;
  always_comb begin
    unique case (size)
      riscv_pkg::MEM_SIZE_HALF: ref_value = is_unsigned ? 64'(raw[15:0]) : 64'($signed(raw[15:0]));
      riscv_pkg::MEM_SIZE_WORD:
      ref_value = is_fp ?
          {32'hFFFF_FFFF, raw[31:0]} : (is_unsigned ? 64'(raw[31:0]) : 64'($signed(raw[31:0])));
      riscv_pkg::MEM_SIZE_DOUBLE: ref_value = raw;
      default: ref_value = is_unsigned ? 64'(raw[7:0]) : 64'($signed(raw[7:0]));
    endcase
  end

  always_comb begin
    p_widths :
    assert (ma_pkg::XLEN == riscv_pkg::XLEN && ma_pkg::CauseBits == riscv_pkg::ExcCauseWidth &&
                       ma_pkg::PtePpnBits == riscv_pkg::PtePpnBits);
    p_nbytes : assert (nbytes == (4'd1 << size));
    p_misaligned : assert (ma_pkg::is_misaligned(size, va) == ((va & 64'(nbytes - 4'd1)) != 0));
    p_sector : assert (ma_pkg::crosses_sector(size, va) == (last_byte[63:5] != {1'b0, va[63:5]}));
    p_page : assert (ma_pkg::crosses_page(size, va) == (last_byte[63:12] != {1'b0, va[63:12]}));
    p_line_align_split : assert (ma_pkg::crosses_sector(size, va) == line_crosses);
    p_page_implies_sector :
    assert (!ma_pkg::crosses_page(size, va) || ma_pkg::crosses_sector(size, va));
    // The upper part of a page crossing starts at the next page base.
    if (ma_pkg::crosses_page(size, va)) begin
      p_upper_page_base : assert (ma_pkg::upper_va(va) == {va[63:12] + 52'd1, 12'h000});
    end
    if (ma_pkg::crosses_sector(size, va)) begin
      // The upper part starts inside the access (addresses wrap at 2^64).
      p_upper_in_access :
      assert ((ma_pkg::upper_va(va) - va) != 64'd0 && (ma_pkg::upper_va(va) - va) < 64'(nbytes));
    end

    // Translation helpers.
    p_leaf_ppn :
    assert (ma_pkg::leaf_ppn(
        ppn, level, va
    ) == ((level == 2'd2) ? ((ppn & ~44'h3FFFF) | 44'(va[29:12])) : (level == 2'd1) ?
          ((ppn & ~44'h1FF) | 44'(va[20:12])) : ppn));
    p_leaf_pa :
    assert (ma_pkg::leaf_pa(ppn, level, va) == 64'({ma_pkg::leaf_ppn(ppn, level, va), va[11:0]}));
    p_ppn_range :
    assert (ma_pkg::leaf_ppn_out_of_range(
        ppn
    ) == (ppn >= (44'd1 << (riscv_pkg::PhysAddrBits - 12))));
    // Permission truth: user pages need U mode or SUM, supervisor pages refuse
    // U mode; stores need W and D, loads R, or X with MXR.
    p_leaf_perm :
    assert (ma_pkg::leaf_perm_ok(
        store, rwxud[4], rwxud[3], rwxud[2], rwxud[1], rwxud[0], eff_priv_u, sum, mxr
    ) == ((rwxud[1] ? (eff_priv_u | sum) : ~eff_priv_u) &
          (store ? (rwxud[3] & rwxud[0]) : (rwxud[4] | (mxr & rwxud[2])))));
    p_value : assert (ma_pkg::load_value(raw, size, is_unsigned, is_fp) == ref_value);

    // Outcome: the lower part decides first; an unsplit access ignores the
    // upper verdict; only an upper page or access fault reports the upper VA.
    if (lower != ma_pkg::MaPartOk) begin
      p_lower_first : assert (!o.ok && o.tval == va && o.cause == ma_pkg::part_cause(lower, store));
    end else if (ma_pkg::crosses_sector(size, va) && upper != ma_pkg::MaPartOk) begin
      p_upper_fault :
      assert (!o.ok && o.cause == ma_pkg::part_cause(
          upper, store
      ) && o.tval == ((upper == ma_pkg::MaPartMisalign) ? va : ma_pkg::upper_va(
          va
      )));
    end else begin
      p_ok : assert (o.ok);
    end
    p_cause_family :
    assert (ma_pkg::part_cause(
        ma_pkg::MaPartPage, store
    ) == (store ? 5'd15 : 5'd13) && ma_pkg::part_cause(
        ma_pkg::MaPartAccess, store
    ) == (store ? 5'd7 : 5'd5) && ma_pkg::part_cause(
        ma_pkg::MaPartMisalign, store
    ) == (store ? 5'd6 : 5'd4));
  end
endmodule
