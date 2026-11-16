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

// Ssnpm pointer masking applied to operand terms. For every base, 64-bit
// immediate, mode (the never-produced 01 included) and other input:
//   - coherent_store_pm_select's store PMA verdict and untranslated
//     completion at issue equal those of the transformed base: the store
//     page decoder below (coherent_store_pma_transformed, which takes the
//     transformed base) on pm_base_transform(base, mode), and the completion
//     regions on the transformed base plus the immediate. Instances cover
//     both settings of MEM_RESPONSE_ERRORS and CACHE_NORMAL_MEMORY, the
//     configured cached DDR range, a smaller range, and a range above bit
//     46, which keeps the completion test on the transformed sum.
// Combinational, so one BMC step covers every input.
module pm_mode_select (
    input logic                [63:0] base,
    input logic                [63:0] imm,
    input riscv_pkg::pm_mode_t        mode,
    input logic                       page_carry,
    input logic                       atomic,
    input logic                       cmo,
    input logic                       issue_without_pma
);
  localparam int unsigned XLEN = riscv_pkg::XLEN;

  // Store verdicts with the transform applied first.
  logic [XLEN-1:0] base_t, sum_t;
  logic ref_pma_ok;
  assign base_t = riscv_pkg::pm_base_transform(base, mode);
  assign sum_t  = base_t + imm;
  coherent_store_pma_transformed ref_pma (
      .i_base(base_t),
      .i_effective_addr(sum_t),
      .i_imm_negative(imm[11]),
      .i_page_carry(page_carry),
      .i_atomic(atomic),
      .o_pma_ok(ref_pma_ok)
  );

  // {MEM_RESPONSE_ERRORS, CACHE_NORMAL_MEMORY, cached base, cached size}.
  localparam int Cases = 6;
  localparam logic [Cases-1:0] CaseErrors = 6'b11_1010;
  localparam logic [Cases-1:0] CaseNormal = 6'b11_1100;
  localparam logic [Cases*64-1:0] CaseCachedBase = {
    64'h0,
    64'h4000_0000,
    64'(riscv_pkg::DdrBase),
    64'(riscv_pkg::DdrBase),
    64'(riscv_pkg::DdrBase),
    64'(riscv_pkg::DdrBase)
  };
  localparam logic [Cases*64-1:0] CaseCachedSize = {
    64'h4_0000_0000_0000,
    64'h10_0000,
    64'(riscv_pkg::DdrCapacityBytes),
    64'(riscv_pkg::DdrCapacityBytes),
    64'(riscv_pkg::DdrCapacityBytes),
    64'(riscv_pkg::DdrCapacityBytes)
  };

  for (genvar c = 0; c < Cases; c++) begin : gen_case
    localparam bit Errors = CaseErrors[c];
    localparam bit Normal = CaseNormal[c];
    localparam longint unsigned CachedBase = CaseCachedBase[c*64+:64];
    localparam longint unsigned CachedSize = CaseCachedSize[c*64+:64];
    logic pma_ok, complete, ref_complete;
    coherent_store_pm_select #(
        .MEM_RESPONSE_ERRORS(Errors),
        .CACHE_NORMAL_MEMORY(Normal),
        .CACHED_BASE(CachedBase),
        .CACHED_SIZE_BYTES(CachedSize)
    ) dut (
        .i_base(base),
        .i_imm(imm),
        .i_effective_addr(sum_t),
        .i_pm_mode(mode),
        .i_page_carry(page_carry),
        .i_atomic(atomic),
        .i_cmo(cmo),
        .i_issue_without_pma(issue_without_pma),
        .o_pma_ok(pma_ok),
        .o_complete(complete)
    );
    // The wrapper's completion with the transformed sum.
    assign ref_complete = issue_without_pma &&
        (!Errors || cmo || (Normal && riscv_pkg::pma_writethrough_ok(
        sum_t
    )) || ((sum_t >= XLEN'(CachedBase)) && (sum_t < XLEN'(CachedBase) + XLEN'(CachedSize)))) &&
        ref_pma_ok;
    // Unlabeled: a label would repeat in every gen_case scope.
    always_comb begin
      assert (pma_ok == ref_pma_ok);
      assert (complete == ref_complete);
    end
  end
endmodule

// The store page decoder taking the base after the pointer-masking transform,
// as the reference for coherent_store_pma.
module coherent_store_pma_transformed (
    input logic [riscv_pkg::XLEN-1:0] i_base,
    input logic [riscv_pkg::XLEN-1:0] i_effective_addr,
    input logic i_imm_negative,
    input logic i_page_carry,
    input logic i_atomic,
    output logic o_pma_ok
);
  logic store_cmp_base_z18;
  logic store_cmp_base_z19;
  logic store_cmp_base_z30;
  logic store_cmp_base_z32;
  logic store_cmp_base_ddr_ok;
  logic store_cmp_base_page_lo6_zero;
  logic store_cmp_base_page_lo6_ones;
  logic store_cmp_base_page_tail_zero;
  logic store_cmp_base_page_tail_ones;
  logic store_cmp_base_pma_ok;
  logic store_cmp_base_page_eq_0;
  logic store_cmp_base_page_eq_3f;
  logic store_cmp_base_page_eq_40;
  logic store_cmp_base_page_eq_3ffff;
  logic store_cmp_base_page_eq_40000;
  logic store_cmp_base_page_eq_ddr_before;
  logic store_cmp_base_page_eq_ddr_first;
  logic store_cmp_base_page_eq_ddr_last;
  logic store_cmp_base_page_eq_ddr_end;
  logic store_cmp_base_page_eq_max;
  logic store_cmp_page_inc_toggle;
  logic store_cmp_page_dec_toggle;
  (* keep = "true" *)logic store_cmp_pma_no_carry;
  (* keep = "true" *)logic store_cmp_pma_carry;

  // Decode the bounded map before its high-address qualifier arrives. Other
  // configurations retain the original full-address decoder.
  localparam bit StorePmaLowCofactor = riscv_pkg::PmaUsesFrostMap &&
      riscv_pkg::DdrLimit < 64'h2_0000_0000;
  localparam int StorePmaHighBits = riscv_pkg::XLEN - 33;
  localparam int StorePmaHighGroups = (StorePmaHighBits + 5) / 6;
  logic [riscv_pkg::XLEN-1:0] store_pma_compare_address;
  (* keep = "true" *) logic store_pma_compared_ok;

  assign store_pma_compare_address = StorePmaLowCofactor ?
      {{(riscv_pkg::XLEN-33){1'b0}}, i_base[32:0]} :
      i_base;

  assign store_cmp_base_z18 = !(|store_pma_compare_address[riscv_pkg::XLEN-1:18]);
  assign store_cmp_base_z19 = !(|store_pma_compare_address[riscv_pkg::XLEN-1:19]);
  assign store_cmp_base_z30 = !(|store_pma_compare_address[riscv_pkg::XLEN-1:30]);
  assign store_cmp_base_z32 = !(|store_pma_compare_address[riscv_pkg::XLEN-1:32]);
  assign store_cmp_base_ddr_ok = riscv_pkg::pma_cached_ok(
      store_pma_compare_address[riscv_pkg::XLEN-1:0]
  );
  assign store_cmp_base_page_lo6_zero = !(|store_pma_compare_address[17:12]);
  assign store_cmp_base_page_lo6_ones = &store_pma_compare_address[17:12];
  assign store_cmp_base_page_tail_zero = !(|store_pma_compare_address[29:12]);
  assign store_cmp_base_page_tail_ones = &store_pma_compare_address[29:12];

  assign store_cmp_base_pma_ok = store_cmp_base_z18 || store_cmp_base_ddr_ok ||
      (store_cmp_base_z32 && (store_pma_compare_address[31:30] == 2'b01) &&
       !i_atomic);
  assign store_cmp_base_page_eq_0 = store_cmp_base_z18 && store_cmp_base_page_lo6_zero;
  assign store_cmp_base_page_eq_3f = store_cmp_base_z18 && store_cmp_base_page_lo6_ones;
  assign store_cmp_base_page_eq_40 = store_cmp_base_z19 && store_pma_compare_address[18] &&
      store_cmp_base_page_lo6_zero;
  assign store_cmp_base_page_eq_3ffff = store_cmp_base_z30 && store_cmp_base_page_tail_ones;
  assign store_cmp_base_page_eq_40000 = store_cmp_base_z32 &&
      (store_pma_compare_address[31:30] == 2'b01) && store_cmp_base_page_tail_zero;
  assign store_cmp_base_page_eq_ddr_before =
      store_pma_compare_address[riscv_pkg::XLEN-1:12] ==
      (riscv_pkg::XLEN-12)'((riscv_pkg::DdrBase - 4096) >> 12);
  assign store_cmp_base_page_eq_ddr_first =
      store_pma_compare_address[riscv_pkg::XLEN-1:12] ==
      (riscv_pkg::XLEN-12)'(riscv_pkg::DdrBase >> 12);
  assign store_cmp_base_page_eq_ddr_last =
      store_pma_compare_address[riscv_pkg::XLEN-1:12] ==
      (riscv_pkg::XLEN-12)'((riscv_pkg::DdrLimit - 4096) >> 12);
  assign store_cmp_base_page_eq_ddr_end =
      store_pma_compare_address[riscv_pkg::XLEN-1:12] ==
      (riscv_pkg::XLEN-12)'(riscv_pkg::DdrLimit >> 12);
  assign store_cmp_base_page_eq_max = &store_pma_compare_address[riscv_pkg::XLEN-1:12];

  assign store_cmp_page_inc_toggle = store_cmp_base_page_eq_max || store_cmp_base_page_eq_3f ||
      (!i_atomic && store_cmp_base_page_eq_3ffff) || store_cmp_base_page_eq_ddr_last ||
      (i_atomic && store_cmp_base_page_eq_ddr_before);
  assign store_cmp_page_dec_toggle = store_cmp_base_page_eq_0 || store_cmp_base_page_eq_40 ||
      (!i_atomic && store_cmp_base_page_eq_40000) || store_cmp_base_page_eq_ddr_end ||
      (i_atomic && store_cmp_base_page_eq_ddr_first);
  // Without a carry, only a negative immediate changes the page. With a
  // carry, only a nonnegative immediate does. Select between both cases.
  assign store_cmp_pma_no_carry = store_cmp_base_pma_ok ^
      (i_imm_negative && store_cmp_page_dec_toggle);
  assign store_cmp_pma_carry = store_cmp_base_pma_ok ^
      (!i_imm_negative && store_cmp_page_inc_toggle);
  // The reduced page-carry decoder is specific to FROST's map. Other
  // integrations use the full configured PMA predicate on the effective PA.
  assign store_pma_compared_ok = riscv_pkg::PmaUsesFrostMap ?
      (i_page_carry ? store_cmp_pma_carry : store_cmp_pma_no_carry) :
      (i_atomic ? riscv_pkg::pma_atomic_ok(
      i_effective_addr
  ) : riscv_pkg::pma_store_ok(
      i_effective_addr
  ));
  if (StorePmaLowCofactor) begin : gen_store_pma_cofactor
    (* keep = "true" *) wire [StorePmaHighGroups-1:0] high_zero_groups;
    (* keep = "true" *) wire [StorePmaHighGroups-1:0] high_one_groups;
    (* keep = "true" *) wire high_zero;
    (* keep = "true" *) wire high_ones;
    wire low_page_ones;
    wire positive_carry;
    for (genvar group_index = 0; group_index < StorePmaHighGroups; group_index++) begin : gen_high
      localparam int GroupBits = (StorePmaHighBits - group_index * 6) < 6 ?
          StorePmaHighBits - group_index * 6 : 6;
      localparam logic [5:0] OneMatch = 6'((1 << GroupBits) - 1);
      wire [5:0] terms;
      for (genvar bit_index = 0; bit_index < 6; bit_index++) begin : gen_bit
        if (bit_index < GroupBits) assign terms[bit_index] = i_base[33+group_index*6+bit_index];
        else assign terms[bit_index] = 1'b0;
      end
`ifdef FROST_XILINX_PRIMS
      (* dont_touch = "true" *) LUT6 #(
          .INIT(64'h1)
      ) u_zero (
          .I0(terms[0]),
          .I1(terms[1]),
          .I2(terms[2]),
          .I3(terms[3]),
          .I4(terms[4]),
          .I5(terms[5]),
          .O (high_zero_groups[group_index])
      );
      (* dont_touch = "true" *) LUT6 #(
          .INIT(64'h1 << OneMatch)
      ) u_one (
          .I0(terms[0]),
          .I1(terms[1]),
          .I2(terms[2]),
          .I3(terms[3]),
          .I4(terms[4]),
          .I5(terms[5]),
          .O (high_one_groups[group_index])
      );
`else
      assign high_zero_groups[group_index] = terms == 6'b0;
      assign high_one_groups[group_index]  = terms == OneMatch;
`endif
    end
    assign high_zero = &high_zero_groups;
    assign high_ones = &high_one_groups;
    assign low_page_ones = &i_base[32:12];
    assign positive_carry = !i_imm_negative && i_page_carry;
    // A positive move from the last full-width page wraps into legal page0.
`ifdef FROST_XILINX_PRIMS
    (* dont_touch = "true" *) LUT5 #(
        .INIT(32'hf8888888)
    ) u_allow (
        .I0(store_pma_compared_ok),
        .I1(high_zero),
        .I2(high_ones),
        .I3(low_page_ones),
        .I4(positive_carry),
        .O (o_pma_ok)
    );
`else
    assign o_pma_ok = (high_zero && store_pma_compared_ok) ||
        (high_ones && low_page_ones && positive_carry);
`endif
  end else begin : gen_store_pma_full_address
    assign o_pma_ok = store_pma_compared_ok;
  end
endmodule
