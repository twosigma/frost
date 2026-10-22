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
    parameter bit APLIC_DELIVERY = 1'b1,
    // The hart can register the select decode alongside *iselect.
    parameter bit PREDECODED_SELECT = 1'b0,
    // The hart can expand its narrow ingress before the file's state update.
    parameter bit PREDECODED_MSI = 1'b0
) (
    input logic i_clk,
    input logic i_rst,

    // MSI: set the pending bit of one identity.
    input logic             i_msi_valid,
    input logic [     10:0] i_msi_id,
    input logic [NUM_IDS:0] i_msi_onehot = '0,

    // Hart side: *iselect/*ireg and *topei.
    input  logic [                   7:0] i_iselect,
    // {eie words, eip words, eithreshold, eidelivery}, least word first.
    input  logic [2*((NUM_IDS+1)/64)+1:0] i_select_onehot = '0,
    output logic [                  63:0] o_ireg,
    output logic                          o_ireg_illegal,
    input  logic                          i_ireg_we,
    input  logic [                  63:0] i_ireg_keep,
    input  logic [                  63:0] i_ireg_set,
    output logic [                  31:0] o_topei,
    input  logic                          i_topei_claim,

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
  logic [ IdBits-1:0] top_q;
  logic [NumBits-1:0] top_onehot_q;
  logic               eip_line_q;

  logic [       63:0] eidelivery;
  assign eidelivery = aplic_q ? EideliveryAplic : 64'(deliver_q);

  // ---------------------------------------------------------------------------
  // *ireg reads
  // ---------------------------------------------------------------------------
  logic [2*NumWords+1:0] select_onehot, select_decode;
  always_comb begin
    select_decode = '0;
    select_decode[0] = i_iselect == SelEidelivery;
    select_decode[1] = i_iselect == SelEithreshold;
    for (int w = 0; w < int'(NumWords); w++) begin
      select_decode[2+w] = i_iselect == 8'(8'h80 + 2 * w);
      select_decode[2+NumWords+w] = i_iselect == 8'(8'hC0 + 2 * w);
    end
  end
  assign select_onehot = PREDECODED_SELECT ? i_select_onehot : select_decode;
  always_comb begin
    o_ireg = ({64{select_onehot[0]}} & eidelivery) | ({64{select_onehot[1]}} & 64'(eithreshold_q));
    for (int w = 0; w < int'(NumWords); w++) begin
      o_ireg |= ({64{select_onehot[2+w]}} & eip_q[64*w+:64]) |
          ({64{select_onehot[2+NumWords+w]}} & eie_q[64*w+:64]);
    end
  end
  assign o_ireg_illegal = i_iselect[7] && i_iselect[0];

  // ---------------------------------------------------------------------------
  // Next state: the claim, then the *ireg write, then the MSI.
  // ---------------------------------------------------------------------------
  logic [NumWords-1:0] wr_eip, wr_eie;
  logic wr_eidelivery, wr_eithreshold;
  assign wr_eip = {NumWords{i_ireg_we}} & select_onehot[2+:NumWords];
  assign wr_eie = {NumWords{i_ireg_we}} & select_onehot[2+NumWords+:NumWords];
  assign wr_eidelivery = i_ireg_we && select_onehot[0];
  assign wr_eithreshold = i_ireg_we && select_onehot[1];

  logic [NumBits-1:0] msi_onehot;
  for (genvar i = 0; i < int'(NumBits); i++) begin : gen_msi_decode
    assign msi_onehot[i] = (i != 0) && (PREDECODED_MSI ? i_msi_onehot[i] :
        (i_msi_valid && (i_msi_id == 11'(i))));
  end

  logic [NumBits-1:0] eip_claimed, eip_d, eie_d;
  always_comb begin
    for (int i = 0; i < int'(NumBits); i++) begin
      eip_claimed[i] = eip_q[i] && !(i_topei_claim && top_onehot_q[i]);
      eip_d[i] = (wr_eip[i/64] ? ((eip_claimed[i] && i_ireg_keep[i%64]) || i_ireg_set[i%64]) :
                  eip_claimed[i]) || msi_onehot[i];
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
  // Each strobe case computes its candidates and winner independently. The
  // late claim/write strobes select only the finished results. MSI and RMW
  // operands arrive from registers, and the claim identity is already decoded.
  function automatic logic [63:0] first_of_64(input logic [63:0] v);
    logic [63:0] seen;
    seen = v;
    for (int s = 1; s < 64; s = s * 2) seen |= seen << s;
    first_of_64 = v & ~(seen << 1);
  endfunction

  logic [IdBits-1:0] top_case[4];
  logic [NumBits-1:0] first_case[4];
  logic [3:0] line_case;
  for (genvar c = 0; c < 4; c++) begin : gen_top_case
    localparam bit Claim = (c & 1) != 0;
    localparam bit Write = (c & 2) != 0;
    logic [NumBits-1:0] pending, enabled, candidates;
    logic [IdBits-1:0] threshold;
    logic delivery, aplic;
    logic [63:0] word_any, first_word;
    logic [NumBits-1:0] word_first;
    assign threshold = (Write && select_onehot[1]) ? eithreshold_new[IdBits-1:0] : eithreshold_q;
    assign aplic = (Write && select_onehot[0]) ? (APLIC_DELIVERY && eidelivery_new[30]) : aplic_q;
    assign delivery = (Write && select_onehot[0]) ? (eidelivery_new[0] && !aplic) : deliver_q;
    always_comb begin
      for (int i = 0; i < int'(NumBits); i++) begin
        pending[i] = eip_q[i] && !(Claim && top_onehot_q[i]);
        if (Write && select_onehot[2+i/64])
          pending[i] = (pending[i] && i_ireg_keep[i%64]) || i_ireg_set[i%64];
        pending[i] |= msi_onehot[i];
        enabled[i] = (Write && select_onehot[2+NumWords+i/64]) ?
            ((eie_q[i] && i_ireg_keep[i%64]) || i_ireg_set[i%64]) : eie_q[i];
        candidates[i] = (i != 0) && pending[i] && enabled[i] &&
            ((threshold == '0) || (IdBits'(i) < threshold));
      end
      word_any = '0;
      for (int w = 0; w < int'(NumWords); w++) begin
        word_any[w] = |candidates[64*w+:64];
        word_first[64*w+:64] = first_of_64(candidates[64*w+:64]);
      end
      first_word = first_of_64(word_any);
      for (int w = 0; w < int'(NumWords); w++)
      first_case[c][64*w+:64] = word_first[64*w+:64] & {64{first_word[w]}};
      top_case[c] = '0;
      for (int i = 1; i < int'(NumBits); i++)
      top_case[c] |= IdBits'(i) & {IdBits{first_case[c][i]}};
      line_case[c] = (delivery && (|word_any)) || (aplic && i_aplic_eip);
    end
  end
  logic [1:0] strobe_case;
  assign strobe_case = {i_ireg_we, i_topei_claim};

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      eip_q <= '0;
      eie_q <= '0;
      eithreshold_q <= '0;
      deliver_q <= 1'b0;
      aplic_q <= APLIC_DELIVERY;
      top_q <= '0;
      top_onehot_q <= '0;
      eip_line_q <= 1'b0;
    end else begin
      eip_q <= eip_d;
      eie_q <= eie_d;
      eithreshold_q <= eithreshold_d;
      deliver_q <= deliver_d;
      aplic_q <= aplic_d;
      top_q <= top_case[strobe_case];
      top_onehot_q <= first_case[strobe_case];
      eip_line_q <= line_case[strobe_case];
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

  // Registered input decodes are an interface contract of the hart.
  always_comb begin
    if (PREDECODED_SELECT) assume (i_select_onehot == select_decode);
    if (PREDECODED_MSI) begin
      for (int i = 1; i < int'(NumBits); i++)
      assume (i_msi_onehot[i] == (i_msi_valid && (i_msi_id == 11'(i))));
    end
  end

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
      for (int i = 0; i < int'(NumBits); i++)
      assert (top_onehot_q[i] == ((i != 0) && (top_q == IdBits'(i))));
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

`ifdef IMSIC_TOP_EQUIV
  logic [NumBits-1:0] f_pending_next, f_enabled_next;
  logic [IdBits-1:0] f_threshold_next, f_top_next;
  logic [63:0] f_delivery_next;
  logic f_line_next;
  always_comb begin
    f_pending_next   = eip_q;
    f_enabled_next   = eie_q;
    f_threshold_next = eithreshold_q;
    f_delivery_next  = eidelivery;
    if (i_topei_claim) f_pending_next[top_q] = 1'b0;
    if (i_ireg_we) begin
      if (i_iselect == 8'h70) f_delivery_next = (eidelivery & i_ireg_keep) | i_ireg_set;
      if (i_iselect == 8'h72)
        f_threshold_next = IdBits'((64'(eithreshold_q) & i_ireg_keep) | i_ireg_set);
      for (int w = 0; w < int'(NumWords); w++) begin
        if (i_iselect == 8'(8'h80 + 2 * w))
          f_pending_next[64*w+:64] = (f_pending_next[64*w+:64] & i_ireg_keep) | i_ireg_set;
        if (i_iselect == 8'(8'hC0 + 2 * w))
          f_enabled_next[64*w+:64] = (eie_q[64*w+:64] & i_ireg_keep) | i_ireg_set;
      end
    end
    if (i_msi_valid && (i_msi_id <= 11'(NUM_IDS))) f_pending_next[i_msi_id] = 1'b1;
    f_pending_next[0] = 1'b0;
    f_enabled_next[0] = 1'b0;
    f_top_next = '0;
    for (int i = int'(NUM_IDS); i > 0; i--) begin
      if (f_pending_next[i] && f_enabled_next[i] &&
          ((f_threshold_next == '0) || (i < int'(f_threshold_next))))
        f_top_next = IdBits'(i);
    end
    f_line_next = (APLIC_DELIVERY && f_delivery_next[30]) ? i_aplic_eip :
        (f_delivery_next[0] && (f_top_next != '0));
    if (f_past_valid) begin
      assert (top_case[strobe_case] == f_top_next);
      assert (line_case[strobe_case] == f_line_next);
      assert (eip_d == f_pending_next);
      assert (eie_d == f_enabled_next);
    end
  end
`endif

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
