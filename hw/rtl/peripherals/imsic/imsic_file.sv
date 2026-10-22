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
 * One interrupt file of an Incoming MSI Controller (RISC-V AIA 1.0, chapter
 * 3): the pending (eip) and enable (eie) bits of interrupt identities 1 to
 * NUM_IDS, eithreshold, eidelivery, and the file's top external interrupt.
 * imsic.sv holds one machine-level and one supervisor-level file per hart;
 * README.md beside this file describes both.
 *
 * MSI side: i_msi_valid sets the pending bit of identity i_msi_id. An
 * identity the file does not implement (0, or above NUM_IDS) is ignored.
 *
 * Hart side, for the hart's CSR file (miselect, mireg and mtopei at machine
 * level; siselect, sireg and stopei at supervisor level). Reads are
 * combinational from the registers and report the state before this cycle's
 * updates.
 *   i_iselect is the *iselect value of a *ireg access:
 *     0x70        eidelivery
 *     0x72        eithreshold
 *     0x80 + 2w   eip word w: the pending bits of identities 64w to 64w+63
 *                 (the RV64 register eip2w)
 *     0xC0 + 2w   eie word w: the enable bits of the same identities
 *   o_ireg is the selected register. The odd selects 0x81-0xBF and 0xC1-0xFF
 *   name eip1, eip3, ... and eie1, eie3, ..., which do not exist at XLEN 64:
 *   o_ireg_illegal tells the CSR file to raise an illegal-instruction
 *   exception, and they read zero and ignore writes here. Every other select
 *   reads zero and ignores writes: the reserved 0x71 and 0x73-0x7F, words
 *   above the implemented identities, and the selects below 0x70, which the
 *   CSR file decodes itself. o_ireg_illegal depends on i_iselect alone.
 *   i_ireg_we writes the selected register with the Zicsr update the CSR file
 *   forms from funct3: the next value is (value & i_ireg_keep) | i_ireg_set.
 *   Bits of identities the file does not implement stay zero.
 *   o_topei is *topei: the lowest pending and enabled identity, below
 *   eithreshold when that is nonzero, in bits 26:16 and again in bits 10:0
 *   as its priority, or zero when there is none. It is registered and always
 *   equals that function of the current registers. i_topei_claim is a write
 *   to *topei (a csrrw, or a csrrs or csrrc with a nonzero rs1 field): it
 *   clears the pending bit of the identity o_topei reports in the same cycle,
 *   so a csrrw reads and claims atomically; with o_topei zero it changes
 *   nothing.
 *
 * Updates in one cycle take effect in this order: the claim, the *ireg
 * write, then the MSI. An MSI that arrives with the claim or a clear of its
 * identity therefore leaves the identity pending, as if it came a cycle
 * later; a read in that cycle does not see it.
 *
 * eidelivery holds 0 (delivery off), 1 (the file delivers) or, with
 * APLIC_DELIVERY, 0x40000000: an APLIC in direct delivery mode supplies the
 * hart's external interrupt at this level, on i_aplic_eip, and the file
 * acts as if eidelivery were 0. A write keeps 0x40000000 when bit 30 of the
 * new value is set and APLIC_DELIVERY allows it, and otherwise bit 0. Reset
 * leaves 0x40000000 with APLIC_DELIVERY, else 0, and clears the rest of the
 * file.
 *
 * o_eip, registered, is the interrupt line for mip.MEIP or mip.SEIP: with
 * eidelivery 1 it is set while o_topei is nonzero, with 0x40000000 it is
 * i_aplic_eip one cycle later, and with 0 it is clear.
 */
module imsic_file #(
    // Implemented identities 1..NUM_IDS: one less than a multiple of 64, 63 to 2047.
    parameter int unsigned NUM_IDS = 63,
    // eidelivery supports 0x40000000, delivery by an APLIC in direct mode.
    parameter bit APLIC_DELIVERY = 1'b1
) (
    input logic i_clk,
    input logic i_rst,

    // MSI: set the pending bit of one identity.
    input logic        i_msi_valid,
    input logic [10:0] i_msi_id,

    // Hart side: *iselect/*ireg and *topei.
    input  logic [ 7:0] i_iselect,
    output logic [63:0] o_ireg,
    output logic        o_ireg_illegal,
    input  logic        i_ireg_we,
    input  logic [63:0] i_ireg_keep,
    input  logic [63:0] i_ireg_set,
    output logic [31:0] o_topei,
    input  logic        i_topei_claim,

    // The APLIC's direct-mode interrupt line for this hart and level.
    input  logic i_aplic_eip,
    // Registered external interrupt line.
    output logic o_eip
);

  localparam int unsigned IdBits = $clog2(NUM_IDS + 1);
  // 64-bit eip and eie words; word w holds identities 64w to 64w+63.
  localparam int unsigned NumWords = (NUM_IDS + 1) / 64;
  localparam int unsigned NumBits = 64 * NumWords;  // bit i is identity i

  localparam logic [7:0] SelEidelivery = 8'h70;
  localparam logic [7:0] SelEithreshold = 8'h72;
  localparam logic [63:0] EideliveryAplic = 64'h4000_0000;

`ifndef SYNTHESIS
  initial begin
    if (NUM_IDS < 63 || NUM_IDS > 2047 || (NUM_IDS % 64) != 63)
      $fatal(1, "imsic_file: NUM_IDS must be one less than a multiple of 64, from 63 to 2047");
  end
`endif

  // ---------------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------------
  // Pending and enable bits by identity; bit 0, identity 0, stays zero.
  // eidelivery is deliver_q (1) or aplic_q (0x40000000), never both. top_q is
  // the identity o_topei reports.
  logic [NumBits-1:0] eip_q, eie_q;
  logic [IdBits-1:0] eithreshold_q;
  logic deliver_q, aplic_q;
  logic [IdBits-1:0] top_q;
  logic              eip_line_q;

  logic [      63:0] eidelivery;
  assign eidelivery = aplic_q ? EideliveryAplic : 64'(deliver_q);

  // ---------------------------------------------------------------------------
  // *ireg reads
  // ---------------------------------------------------------------------------
  // An eip or eie word: an even select from 0x80 up, word number in bits 5:1
  // and bit 6 choosing eie.
  logic       sel_array;
  logic [4:0] sel_word;
  assign sel_array = i_iselect[7] && !i_iselect[0];
  assign sel_word  = i_iselect[5:1];

  always_comb begin
    o_ireg = '0;
    if (i_iselect == SelEidelivery) o_ireg = eidelivery;
    if (i_iselect == SelEithreshold) o_ireg = 64'(eithreshold_q);
    for (int w = 0; w < int'(NumWords); w++) begin
      if (sel_array && (sel_word == 5'(w)))
        o_ireg = i_iselect[6] ? eie_q[64*w+:64] : eip_q[64*w+:64];
    end
  end

  assign o_ireg_illegal = i_iselect[7] && i_iselect[0];

  // ---------------------------------------------------------------------------
  // Next state: the claim, then the *ireg write, then the MSI.
  // ---------------------------------------------------------------------------
  logic [NumWords-1:0] wr_eip, wr_eie;
  logic wr_eidelivery, wr_eithreshold;
  always_comb begin
    for (int w = 0; w < int'(NumWords); w++) begin
      wr_eip[w] = i_ireg_we && sel_array && !i_iselect[6] && (sel_word == 5'(w));
      wr_eie[w] = i_ireg_we && sel_array && i_iselect[6] && (sel_word == 5'(w));
    end
  end
  assign wr_eidelivery  = i_ireg_we && (i_iselect == SelEidelivery);
  assign wr_eithreshold = i_ireg_we && (i_iselect == SelEithreshold);

  logic [NumBits-1:0] eip_claimed, eip_d, eie_d;
  always_comb begin
    for (int i = 0; i < int'(NumBits); i++) begin
      eip_claimed[i] = eip_q[i] && !(i_topei_claim && (top_q == IdBits'(i)));
      eip_d[i] = (wr_eip[i/64] ? ((eip_claimed[i] && i_ireg_keep[i%64]) || i_ireg_set[i%64]) :
                  eip_claimed[i]) || (i_msi_valid && (i_msi_id == 11'(i)));
      eie_d[i] = wr_eie[i/64] ? ((eie_q[i] && i_ireg_keep[i%64]) || i_ireg_set[i%64]) : eie_q[i];
    end
    eip_d[0] = 1'b0;
    eie_d[0] = 1'b0;
  end

  // eithreshold is WLRL; it keeps IdBits bits, enough for 0 to NUM_IDS.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [63:0] eithreshold_new, eidelivery_new;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [IdBits-1:0] eithreshold_d;
  logic deliver_d, aplic_d;
  assign eithreshold_new = (64'(eithreshold_q) & i_ireg_keep) | i_ireg_set;
  assign eithreshold_d = wr_eithreshold ? eithreshold_new[IdBits-1:0] : eithreshold_q;
  // eidelivery is WARL: bit 30 selects the APLIC where supported, else bit 0
  // the file.
  assign eidelivery_new = (eidelivery & i_ireg_keep) | i_ireg_set;
  assign aplic_d = wr_eidelivery ? (APLIC_DELIVERY && eidelivery_new[30]) : aplic_q;
  assign deliver_d = wr_eidelivery ? (eidelivery_new[0] && !aplic_d) : deliver_q;

  // ---------------------------------------------------------------------------
  // Top identity and interrupt line of the next state
  // ---------------------------------------------------------------------------
  // Candidates: pending, enabled, and below a nonzero threshold.
  logic [NumBits-1:0] cand_d;
  always_comb begin
    for (int i = 0; i < int'(NumBits); i++) begin
      cand_d[i] = eip_d[i] && eie_d[i] && ((eithreshold_d == '0) || (IdBits'(i) < eithreshold_d));
    end
  end

  // The lowest set bit of 64, by a prefix OR rather than a priority chain,
  // for timing: seen[i] is set when bit i or a lower one is.
  function automatic logic [5:0] lowest_of_64(input logic [63:0] v);
    logic [63:0] seen;
    logic [63:0] first;
    seen = v;
    for (int s = 1; s < 64; s = s * 2) seen = seen | (seen << s);
    first = v & ~(seen << 1);
    lowest_of_64 = '0;
    for (int b = 0; b < 6; b++) begin
      for (int i = 0; i < 64; i++) begin
        if (((i >> b) & 1) == 1) lowest_of_64[b] = lowest_of_64[b] | first[i];
      end
    end
  endfunction

  // The lowest candidate: the lowest word that holds one, then the lowest
  // bit in that word. The words find their lowest bits in parallel, which
  // also keeps a wide file's logic linear in its size.
  logic [63:0] word_any_d;  // bit w: word w holds a candidate
  logic [6*NumWords-1:0] word_low_d;  // bits 6w+5:6w: word w's lowest one
  logic [5:0] top_word_d, top_bit_d;
  always_comb begin
    word_any_d = '0;
    for (int w = 0; w < int'(NumWords); w++) begin
      word_any_d[w] = |cand_d[64*w+:64];
      word_low_d[6*w+:6] = lowest_of_64(cand_d[64*w+:64]);
    end
    top_word_d = lowest_of_64(word_any_d);
    top_bit_d  = '0;
    for (int w = 0; w < int'(NumWords); w++) begin
      if (top_word_d == 6'(w)) top_bit_d = word_low_d[6*w+:6];
    end
  end

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      eip_q <= '0;
      eie_q <= '0;
      eithreshold_q <= '0;
      deliver_q <= 1'b0;
      aplic_q <= APLIC_DELIVERY;
      top_q <= '0;
      eip_line_q <= 1'b0;
    end else begin
      eip_q <= eip_d;
      eie_q <= eie_d;
      eithreshold_q <= eithreshold_d;
      deliver_q <= deliver_d;
      aplic_q <= aplic_d;
      top_q <= IdBits'({top_word_d[4:0], top_bit_d});
      eip_line_q <= (deliver_d && (|cand_d)) || (aplic_d && i_aplic_eip);
    end
  end

  assign o_topei = {5'b0, 11'(top_q), 5'b0, 11'(top_q)};
  assign o_eip   = eip_line_q;

`ifdef FORMAL
  // ---------------------------------------------------------------------------
  // Formal properties (formal/imsic.sby). Reset is held in the first cycle;
  // inputs are arbitrary afterwards. The register map and the update rules
  // are written out again here from the spec, apart from the logic above.
  // ---------------------------------------------------------------------------
  logic f_past_valid;
  initial f_past_valid = 1'b0;
  always_ff @(posedge i_clk) f_past_valid <= 1'b1;
  always_comb if (!f_past_valid) assume (i_rst);

  // f_cand[i]: identity i is pending and enabled and, with a nonzero
  // eithreshold, below it.
  logic [NumBits-1:0] f_cand;
  logic f_top_is_cand;
  always_comb begin
    f_top_is_cand = 1'b0;
    for (int i = 0; i < int'(NumBits); i++) begin
      f_cand[i] = (i != 0) && (i <= int'(NUM_IDS)) && eip_q[i] && eie_q[i] &&
          ((eithreshold_q == '0) || (i < int'(eithreshold_q)));
      if ((int'(top_q) == i) && f_cand[i]) f_top_is_cand = 1'b1;
    end
  end

  // The value of the register a select names, from the spec's map.
  function automatic logic [63:0] f_ireg(input logic [7:0] sel);
    f_ireg = '0;
    if (sel == 8'h70) f_ireg = aplic_q ? 64'h4000_0000 : 64'(deliver_q);
    if (sel == 8'h72) f_ireg = 64'(eithreshold_q);
    for (int i = 1; i <= int'(NUM_IDS); i++) begin
      if (sel == 8'(8'h80 + 2 * (i / 64))) f_ireg[i%64] = eip_q[i];
      if (sel == 8'(8'hC0 + 2 * (i / 64))) f_ireg[i%64] = eie_q[i];
    end
  endfunction

  // Last cycle's state, inputs and the events they make.
  logic f_rst_p, f_deliver_p, f_aplic_p, f_aplic_eip_p;
  logic [NumBits-1:0] f_eip_p, f_eie_p;
  logic [IdBits-1:0] f_thr_p, f_top_p;
  logic f_msi_p, f_we_p, f_claim_p;
  logic [10:0] f_msi_id_p;
  logic [ 7:0] f_sel_p;
  logic [63:0] f_keep_p, f_set_p;
  always_ff @(posedge i_clk) begin
    f_rst_p <= i_rst;
    {f_deliver_p, f_aplic_p, f_aplic_eip_p} <= {deliver_q, aplic_q, i_aplic_eip};
    {f_eip_p, f_eie_p, f_thr_p, f_top_p} <= {eip_q, eie_q, eithreshold_q, top_q};
    {f_msi_p, f_msi_id_p, f_claim_p} <= {i_msi_valid, i_msi_id, i_topei_claim};
    {f_we_p, f_sel_p, f_keep_p, f_set_p} <= {i_ireg_we, i_iselect, i_ireg_keep, i_ireg_set};
  end

  // Per identity, last cycle: the claim reported and cleared it, a write
  // reached its eip or eie word, an MSI named it.
  logic [NumBits-1:0] f_claimed_p, f_eip_wr_p, f_eie_wr_p, f_msi_hit_p, f_after_claim_p;
  always_comb begin
    for (int i = 0; i < int'(NumBits); i++) begin
      f_claimed_p[i] = f_claim_p && (int'(f_top_p) == i) && (i != 0);
      f_eip_wr_p[i] = f_we_p && (f_sel_p == 8'(8'h80 + 2 * (i / 64)));
      f_eie_wr_p[i] = f_we_p && (f_sel_p == 8'(8'hC0 + 2 * (i / 64)));
      f_msi_hit_p[i] = f_msi_p && (int'(f_msi_id_p) == i) && (i != 0) && (i <= int'(NUM_IDS));
      f_after_claim_p[i] = f_eip_p[i] && !f_claimed_p[i];
    end
  end
  logic [63:0] f_eidelivery_new_p, f_thr_new_p;
  assign f_eidelivery_new_p = ((f_aplic_p ? 64'h4000_0000 : 64'(f_deliver_p)) & f_keep_p) | f_set_p;
  assign f_thr_new_p = (64'(f_thr_p) & f_keep_p) | f_set_p;

  // Reset: everything clear, eidelivery 0x40000000 or 0.
  always_comb begin
    if (f_past_valid && f_rst_p) begin
      assert ((eip_q == '0) && (eie_q == '0) && (eithreshold_q == '0) && (top_q == '0));
      assert (!deliver_q && (aplic_q == APLIC_DELIVERY) && !o_eip);
    end
  end

  // Invariants: identity 0 is never pending or enabled, and eidelivery holds
  // one of its legal values.
  always_comb begin
    if (f_past_valid) begin
      assert (!eip_q[0] && !eie_q[0]);
      assert (!(deliver_q && aplic_q));
      assert (APLIC_DELIVERY || !aplic_q);
    end
  end

  // *topei: zero, or a candidate; no candidate is lower. The value repeats
  // the identity as its priority.
  always_comb begin
    if (f_past_valid) begin
      assert ((top_q == '0) || f_top_is_cand);
      for (int i = 1; i < int'(NumBits); i++) begin
        if (f_cand[i]) assert ((top_q != '0) && (int'(top_q) <= i));
      end
      assert (o_topei == ((top_q == '0) ? 32'b0 : ((32'(top_q) << 16) | 32'(top_q))));
    end
  end

  // The interrupt line: with eidelivery 1, a candidate exists; with
  // 0x40000000, the APLIC's line a cycle earlier.
  always_comb begin
    if (f_past_valid && !f_rst_p) begin
      assert (o_eip == ((deliver_q && (|f_cand)) || (aplic_q && f_aplic_eip_p)));
    end
  end

  // *ireg reads and the illegal selects.
  always_comb begin
    if (f_past_valid) assert (o_ireg == f_ireg(i_iselect));
    assert (o_ireg_illegal == ((i_iselect >= 8'h80) && i_iselect[0]));
  end

  // One-cycle updates.
  always_comb begin
    if (f_past_valid && !f_rst_p) begin
      for (int i = 1; i <= int'(NUM_IDS); i++) begin
        // eip: the claim, then a write to its word, then an MSI.
        assert (eip_q[i] == (f_msi_hit_p[i] || (f_eip_wr_p[i] ?
            ((f_after_claim_p[i] && f_keep_p[i%64]) || f_set_p[i%64]) : f_after_claim_p[i])));
        assert (eie_q[i] == (f_eie_wr_p[i] ?
            ((f_eie_p[i] && f_keep_p[i%64]) || f_set_p[i%64]) : f_eie_p[i]));
        // The same rules case by case: an MSI sets exactly its bit; a claim
        // clears exactly the reported bit; nothing else changes a bit.
        if (f_msi_hit_p[i]) assert (eip_q[i]);
        if (f_claimed_p[i] && !f_msi_hit_p[i] && !f_eip_wr_p[i]) assert (!eip_q[i]);
        if (!f_msi_hit_p[i] && !f_claimed_p[i] && !f_eip_wr_p[i]) assert (eip_q[i] == f_eip_p[i]);
        if (!f_eie_wr_p[i]) assert (eie_q[i] == f_eie_p[i]);
      end
      // eithreshold keeps IdBits bits of a write to select 0x72.
      if (f_we_p && (f_sel_p == 8'h72)) begin
        assert (eithreshold_q == f_thr_new_p[IdBits-1:0]);
      end else begin
        assert (eithreshold_q == f_thr_p);
      end
      // eidelivery: bit 30 selects the APLIC where supported, else bit 0.
      if (f_we_p && (f_sel_p == 8'h70)) begin
        assert (aplic_q == (APLIC_DELIVERY && f_eidelivery_new_p[30]));
        assert (deliver_q ==
                (f_eidelivery_new_p[0] && !(APLIC_DELIVERY && f_eidelivery_new_p[30])));
      end else begin
        assert ((aplic_q == f_aplic_p) && (deliver_q == f_deliver_p));
      end
    end
  end

  // Reachability.
  always_comb begin
    if (f_past_valid && !i_rst) begin
      cover (o_eip && deliver_q);
      // Claims of the highest identity, and of one racing an MSI for it.
      cover (i_topei_claim && (int'(top_q) == int'(NUM_IDS)));
      cover (i_topei_claim && (top_q != '0) && i_msi_valid && (i_msi_id == 11'(top_q)));
      // An MSI with a write to the word holding its identity.
      cover (i_msi_valid && (i_msi_id == 11'd1) && wr_eip[0]);
      // A threshold that hides a pending and enabled identity.
      cover ((eithreshold_q != '0) && (top_q == '0) && (|(eip_q & eie_q)));
    end
  end
  if (APLIC_DELIVERY) begin : gen_aplic_cover
    // The APLIC's line delivered, and eidelivery switched from the APLIC to
    // the file.
    always_comb begin
      if (f_past_valid && !i_rst) begin
        cover (o_eip && aplic_q);
        cover (wr_eidelivery && aplic_q && deliver_d);
      end
    end
  end
`endif

endmodule : imsic_file
