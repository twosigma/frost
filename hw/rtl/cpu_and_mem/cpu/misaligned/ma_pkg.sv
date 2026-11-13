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
 * Checks for an access that the misaligned-access engine splits into a lower
 * and an upper part. An access is split at the first 32-byte sector boundary
 * it crosses; the upper part starts at that boundary, which is also the page
 * base when the access crosses a page.
 *
 * Each part receives a verdict in architectural order: a page fault
 * (translation), then an access fault (a physical address outside the map),
 * then the region class. Only cached DDR is served by the engine; any other
 * mapped region keeps the address-misaligned exception, which firmware
 * emulates. The lower part's verdict is decided first. The trap value is the
 * original virtual address, except for a page or access fault of the upper
 * part, which reports the upper part's first byte.
 */
//
// Package-scope declarations use literal widths (RV64 addresses, Sv39's
// 44-bit PTE PPN, a 5-bit ROB cause) because some tools do not resolve
// another package's parameters at package scope; function bodies refer to
// riscv_pkg directly.
package ma_pkg;

  localparam int unsigned XLEN = 64;
  localparam int unsigned PtePpnBits = 44;
  localparam int unsigned CauseBits = 5;
  localparam int unsigned SectorBytes = 32;
  localparam int unsigned SectorOffsetBits = $clog2(SectorBytes);

  // Verdict for one part of an access. Plain constants rather than an enum,
  // so that the package's functions can name them in every tool.
  typedef logic [1:0] ma_part_e;
  localparam ma_part_e MaPartOk = 2'd0;  // cached DDR: the engine performs it
  localparam ma_part_e MaPartMisalign = 2'd1;  // mapped outside cached DDR: misaligned exception
  localparam ma_part_e MaPartPage = 2'd2;  // page fault
  localparam ma_part_e MaPartAccess = 2'd3;  // access fault

  // The outcome of both parts: whether the engine may perform the access,
  // and otherwise the exception and its trap value.
  typedef struct packed {
    logic                 ok;
    logic [CauseBits-1:0] cause;
    logic [XLEN-1:0]      tval;
  } ma_outcome_t;

  function automatic logic [3:0] size_bytes(input riscv_pkg::mem_size_e size);
    unique case (size)
      riscv_pkg::MEM_SIZE_HALF:   size_bytes = 4'd2;
      riscv_pkg::MEM_SIZE_WORD:   size_bytes = 4'd4;
      riscv_pkg::MEM_SIZE_DOUBLE: size_bytes = 4'd8;
      default:                    size_bytes = 4'd1;
    endcase
  endfunction

  function automatic logic is_misaligned(input riscv_pkg::mem_size_e size,
                                         input logic [XLEN-1:0] va);
    unique case (size)
      riscv_pkg::MEM_SIZE_HALF:   is_misaligned = va[0];
      riscv_pkg::MEM_SIZE_WORD:   is_misaligned = |va[1:0];
      riscv_pkg::MEM_SIZE_DOUBLE: is_misaligned = |va[2:0];
      default:                    is_misaligned = 1'b0;
    endcase
  endfunction

  // The access's last byte lies in the next sector, or the next page.
  function automatic logic crosses_sector(input riscv_pkg::mem_size_e size,
                                          input logic [XLEN-1:0] va);
    crosses_sector = ({1'b0, va[SectorOffsetBits-1:0]} + (SectorOffsetBits + 1)'(size_bytes(size)))
        > (SectorOffsetBits + 1)'(SectorBytes);
  endfunction

  function automatic logic crosses_page(input riscv_pkg::mem_size_e size,
                                        input logic [XLEN-1:0] va);
    crosses_page = ({1'b0, va[11:0]} + 13'(size_bytes(size))) > 13'd4096;
  endfunction

  // First byte of the upper part: the next sector boundary after va.
  function automatic logic [XLEN-1:0] upper_va(input logic [XLEN-1:0] va);
    upper_va = {va[XLEN-1:SectorOffsetBits] + 1'b1, {SectorOffsetBits{1'b0}}};
  endfunction

  // Leaf permission, as the data MMU checks it: U pages need U mode or SUM,
  // S pages refuse U mode; stores need W and D, loads R, or X with MXR.
  function automatic logic leaf_perm_ok(input logic store, input logic r, input logic w,
                                        input logic x, input logic u, input logic d,
                                        input logic eff_priv_u, input logic sum, input logic mxr);
    logic priv_ok;
    priv_ok = u ? (eff_priv_u || sum) : !eff_priv_u;
    leaf_perm_ok = store ? (priv_ok && w && d) : (priv_ok && (r || (mxr && x)));
  endfunction

  // Physical page of va under a leaf of the given level (0 = 4 KiB,
  // 1 = 2 MiB, 2 = 1 GiB). The walker refuses misaligned superpages, so the
  // leaf's low PPN bits are zero for a superpage.
  function automatic logic [PtePpnBits-1:0] leaf_ppn(
      input logic [PtePpnBits-1:0] ppn, input logic [1:0] level, input logic [XLEN-1:0] va);
    unique case (level)
      2'd2:    leaf_ppn = {ppn[PtePpnBits-1:18], va[29:12]};
      2'd1:    leaf_ppn = {ppn[PtePpnBits-1:9], va[20:12]};
      default: leaf_ppn = ppn;
    endcase
  endfunction

  // A leaf PPN with bits above the physical address width maps outside the
  // physical map: an access fault, as in the data MMU.
  function automatic logic leaf_ppn_out_of_range(input logic [PtePpnBits-1:0] ppn);
    leaf_ppn_out_of_range = (ppn >> (riscv_pkg::PhysAddrBits - 12)) != '0;
  endfunction

  // Physical address of va under a leaf; meaningful when the PPN is in range.
  function automatic logic [XLEN-1:0] leaf_pa(input logic [PtePpnBits-1:0] ppn,
                                              input logic [1:0] level, input logic [XLEN-1:0] va);
    logic [PtePpnBits+11:0] pa;
    pa = {leaf_ppn(ppn, level, va), va[11:0]};
    leaf_pa = XLEN'(pa);
  endfunction

  // Region class of a physical address. quadrant_store marks an untranslated
  // store, which the core admits anywhere in the device quadrant.
  function automatic ma_part_e region(input logic [XLEN-1:0] pa, input logic quadrant_store);
    if (riscv_pkg::pma_cached_ok(pa)) region = MaPartOk;
    else if (riscv_pkg::pma_memory_ok(
            pa
        ) || riscv_pkg::pma_device_ok(
            pa
        ) || (quadrant_store && riscv_pkg::pma_device_quadrant(
            pa
        )))
      region = MaPartMisalign;
    else region = MaPartAccess;
  endfunction

  function automatic logic [CauseBits-1:0] part_cause(input ma_part_e part, input logic store);
    logic [XLEN-1:0] cause;
    case (part)
      MaPartPage: cause = store ? riscv_pkg::ExcStorePageFault : riscv_pkg::ExcLoadPageFault;
      MaPartAccess: cause = store ? riscv_pkg::ExcStoreAccessFault : riscv_pkg::ExcLoadAccessFault;
      default: cause = store ? riscv_pkg::ExcStoreAddrMisalign : riscv_pkg::ExcLoadAddrMisalign;
    endcase
    part_cause = cause[CauseBits-1:0];
  endfunction

  // Combine the two parts' verdicts. split is clear for an access inside one
  // sector, whose upper verdict is ignored.
  function automatic ma_outcome_t outcome(input ma_part_e lower, input ma_part_e upper,
                                          input logic split, input logic store,
                                          input logic [XLEN-1:0] va);
    ma_outcome_t o;
    o.ok   = 1'b0;
    o.tval = va;
    if (lower != MaPartOk) begin
      o.cause = part_cause(lower, store);
    end else if (split && (upper != MaPartOk)) begin
      o.cause = part_cause(upper, store);
      if (upper != MaPartMisalign) o.tval = upper_va(va);
    end else begin
      o.ok = 1'b1;
      o.cause = '0;
    end
    outcome = o;
  endfunction

  // Register value of a load: sign or zero extension, and NaN boxing for FLW.
  function automatic logic [63:0] load_value(input logic [63:0] raw,
                                             input riscv_pkg::mem_size_e size,
                                             input logic is_unsigned, input logic is_fp);
    unique case (size)
      riscv_pkg::MEM_SIZE_HALF:
      load_value = is_unsigned ? {48'b0, raw[15:0]} : {{48{raw[15]}}, raw[15:0]};
      riscv_pkg::MEM_SIZE_WORD:
      load_value = is_fp ? {32'hFFFF_FFFF, raw[31:0]} :
          is_unsigned ? {32'b0, raw[31:0]} : {{32{raw[31]}}, raw[31:0]};
      riscv_pkg::MEM_SIZE_DOUBLE: load_value = raw;
      default: load_value = is_unsigned ? {56'b0, raw[7:0]} : {{56{raw[7]}}, raw[7:0]};
    endcase
  endfunction

endpackage
