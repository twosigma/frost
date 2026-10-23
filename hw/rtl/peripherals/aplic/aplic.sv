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
 * Advanced Platform-Level Interrupt Controller (RISC-V AIA 1.0, chapter 4)
 * in direct delivery mode, with two interrupt domains: the machine-level root
 * domain and one supervisor-level child domain. The root domain drives each
 * hart's MEIP and the supervisor domain each hart's SEIP. README.md beside
 * this file gives the register map and the implementation choices.
 *
 * Window (byte offsets inside the 4 MiB SoC window):
 *   0x0000_0000  root domain control region, 32 KiB
 *   0x0000_8000  supervisor domain control region, 32 KiB
 * The rest of the window reads zero and ignores writes.
 *
 * Domain control region (offsets inside a region):
 *   0x0000         domaincfg     bits 31:24 read 0x80, bit 8 IE; DM and BE
 *                                read zero (direct delivery, little-endian)
 *   0x0000 + 4*i   sourcecfg[i]  i = 1..NUM_SOURCES
 *   0x1C00 + 4*k   setip[k]      k = 0..31, bit i % 32 is source i
 *   0x1CDC         setipnum
 *   0x1D00 + 4*k   in_clrip[k]   reads rectified inputs
 *   0x1DDC         clripnum
 *   0x1E00 + 4*k   setie[k]
 *   0x1EDC         setienum
 *   0x1F00 + 4*k   clrie[k]      reads zero
 *   0x1FDC         clrienum
 *   0x2000         setipnum_le
 *   0x2004         setipnum_be   byte-swapped setipnum
 *   0x3000         genmsi        reads zero (DM is zero)
 *   0x3000 + 4*i   target[i]     hart index bits 31:18, IPRIO bits 7:0
 *   0x4000 + 32*h  IDC of hart index h = 0..NUM_HARTS-1: idelivery +0x00,
 *                  iforce +0x04, ithreshold +0x08, topi +0x18, claimi +0x1C
 * Every other offset, including the MSI address configuration registers and
 * the IDCs of hart indices at or above NUM_HARTS, reads zero and ignores
 * writes. The number registers (setipnum and the like) read zero.
 *
 * Each source is active in at most one domain, so its state is held once:
 * the root's delegate bit, the source mode of the domain that holds it, the
 * pending and enable bits, and the target. A domain sees the sources it does
 * not hold as inactive (the root sees D = 1 for a delegated one) or, in the
 * supervisor domain, as not implemented. Delegating a source in the root
 * leaves it inactive in the supervisor domain until that domain configures
 * it, as the spec requires. A write that makes a source inactive, or moves it
 * between domains, clears its enable bit and its pending bit, and a move
 * resets its target; in the new mode the pending bit then follows the input
 * (level modes) or is set by the write when it raises the rectified input
 * (edge modes).
 *
 * Pending bits (AIA 1.0, 4.7):
 *   Detached  set by setip/setipnum writes; cleared by a claim or by
 *             in_clrip/clripnum writes
 *   Edge1/0   as Detached, and also set by a rising edge of the wire,
 *             rectified, and by a sourcecfg write that raises the rectified
 *             input (the spec allows either choice for such a write)
 *   Level1/0  the rectified input of the previous cycle, under the mode
 *             in force from this cycle; writes and claims neither set nor
 *             clear it
 * A set wins over a clear in the same cycle, so an edge that coincides with
 * a claim stays pending. A claim read is ordered before a register write in
 * the same cycle.
 *
 * Source wires are synchronous to i_clk. topi is combinational from the
 * registers, so a claim's value and its side effect use the same state; the
 * interrupt lines are registered. The delivery mode is a per-domain choice
 * in the spec: MSI delivery mode would add the MSI address configuration,
 * genmsi, the MSI format of target, the MSI-mode rules for level-sensitive
 * pending bits, and a forwarder beside the direct-mode IDCs below.
 */
module aplic #(
    parameter int unsigned NUM_SOURCES = 5,  // source IDs 1..NUM_SOURCES (at most 1023)
    parameter int unsigned NUM_HARTS   = 1,  // hart indices 0..NUM_HARTS-1 (at most 512)
    parameter int unsigned IPRIOLEN    = 3   // implemented priority bits (1 to 8)
) (
    input logic i_clk,
    input logic i_rst,

    // Source wires, index 0 = source ID 1.
    input logic [NUM_SOURCES-1:0] i_src,

    // Register write beat (registered MMIO write, 32-bit lane already
    // selected): byte offset inside the window. Assert it only for a
    // naturally aligned 32-bit store; the spec requires other access sizes
    // to be ignored.
    input logic        i_wr_en,
    input logic [21:0] i_wr_offset,  // bits [1:0] ignored
    input logic [31:0] i_wr_data,

    // Combinational register read: the {offset+4, offset} register pair of
    // the dword at i_rd_offset, for the 64-bit MMIO read mux. i_rd_capture
    // pulses once per performed naturally aligned 32-bit read, on the edge
    // that captures the pair into the MMIO response; a read of a claimi word
    // (i_rd_offset[2] selects the word) then takes the claim's side effect.
    input  logic [21:0] i_rd_offset,  // bits [1:0] ignored
    output logic [63:0] o_rd_pair,
    input  logic        i_rd_capture,

    // Registered external-interrupt-pending lines, by hart index.
    output logic [NUM_HARTS-1:0] o_meip,
    output logic [NUM_HARTS-1:0] o_seip
);

  localparam int unsigned HartBits = (NUM_HARTS > 1) ? $clog2(NUM_HARTS) : 1;
  // IDC c serves domain c / NUM_HARTS (0 = root) and hart index c % NUM_HARTS.
  localparam int unsigned NumIdcs = 2 * NUM_HARTS;

  // sourcecfg.SM. Bit 2 marks the wire-driven modes, bit 1 level over edge,
  // and bit 0 an inverted wire.
  localparam logic [2:0] SmInactive = 3'd0;
  localparam logic [2:0] SmDetached = 3'd1;

  // Register offsets inside a domain control region.
  localparam logic [14:0] DomaincfgOff = 15'h0000;
  localparam logic [14:0] SetipOff = 15'h1C00;
  localparam logic [14:0] SetipnumOff = 15'h1CDC;
  localparam logic [14:0] InClripOff = 15'h1D00;
  localparam logic [14:0] ClripnumOff = 15'h1DDC;
  localparam logic [14:0] SetieOff = 15'h1E00;
  localparam logic [14:0] SetienumOff = 15'h1EDC;
  localparam logic [14:0] ClrieOff = 15'h1F00;
  localparam logic [14:0] ClrienumOff = 15'h1FDC;
  localparam logic [14:0] SetipnumLeOff = 15'h2000;
  localparam logic [14:0] SetipnumBeOff = 15'h2004;
  localparam logic [14:0] TargetOff = 15'h3000;
  // IDC registers, by word inside the 32-byte IDC.
  localparam logic [2:0] IdeliveryWord = 3'd0;
  localparam logic [2:0] IforceWord = 3'd1;
  localparam logic [2:0] IthresholdWord = 3'd2;
  localparam logic [2:0] TopiWord = 3'd6;
  localparam logic [2:0] ClaimiWord = 3'd7;

`ifndef SYNTHESIS
  initial begin
    if (NUM_SOURCES < 1 || NUM_SOURCES > 1023) $fatal(1, "aplic: NUM_SOURCES must be 1 to 1023");
    if (NUM_HARTS < 1 || NUM_HARTS > 512) $fatal(1, "aplic: NUM_HARTS must be 1 to 512");
    if (IPRIOLEN < 1 || IPRIOLEN > 8) $fatal(1, "aplic: IPRIOLEN must be 1 to 8");
  end
`endif

  // A window offset is inside a domain control region when its bits [21:16]
  // are zero; bit 15 then names the domain (0 = root) and bits [14:0] the
  // offset inside it.
  function automatic logic in_region(input logic [21:16] off_high);
    in_region = (off_high == '0);
  endfunction

  // The offset of word k of a bitmap register array (setip and the like).
  function automatic logic [14:0] bitmap_word(input logic [14:0] base, input int unsigned s);
    bitmap_word = base + 15'(4 * (s / 32));
  endfunction

  // sourcecfg.SM is WARL; the reserved encodings 2 and 3 write as Inactive.
  function automatic logic [2:0] legal_sm(input logic [2:0] sm);
    legal_sm = (sm[2:1] == 2'b01) ? SmInactive : sm;
  endfunction

  // ---------------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------------
  // Per source, indexed by source ID: the root's sourcecfg.D (delegated to
  // the supervisor domain), the source mode in the domain that holds it, the
  // pending and enable bits, the previous cycle's wire rectified under the
  // current source mode, and the target.
  logic [NUM_SOURCES:1] deleg_q, ip_q, ie_q, rect_q;
  logic [2:0] sm_q[1:NUM_SOURCES];
  logic [HartBits-1:0] tgt_hart_q[1:NUM_SOURCES];
  logic [IPRIOLEN-1:0] tgt_prio_q[1:NUM_SOURCES];

  // Per domain: domaincfg.IE. Per IDC: idelivery, iforce, ithreshold.
  logic [1:0] dom_ie_q;
  logic [NumIdcs-1:0] idelivery_q, iforce_q;
  logic [IPRIOLEN-1:0] ithreshold_q[NumIdcs];

  logic [ NumIdcs-1:0] eip_q;

  // ---------------------------------------------------------------------------
  // Source modes and rectified inputs
  // ---------------------------------------------------------------------------
  logic [NUM_SOURCES:1] src, rect, latched, edge_rise;
  always_comb begin
    for (int s = 1; s <= NUM_SOURCES; s++) begin
      src[s] = i_src[s-1];
      // Zero for Inactive and Detached sources.
      rect[s] = sm_q[s][2] && (src[s] ^ sm_q[s][0]);
      // A pending bit that holds until a claim or a write clears it, and that
      // writes can set: Detached and the edge modes.
      latched[s] = (sm_q[s] == SmDetached) || (sm_q[s][2] && !sm_q[s][1]);
      // A rising edge of the wire, rectified under the current mode.
      edge_rise[s] = sm_q[s][2] && !sm_q[s][1] && rect[s] && !rect_q[s];
    end
  end

  // ---------------------------------------------------------------------------
  // Top interrupt per IDC: the pending and enabled source of the IDC's domain
  // targeting its hart with the smallest priority number below a nonzero
  // threshold; ties go to the lowest source ID. Zero when there is none.
  // ---------------------------------------------------------------------------
  logic [9:0] top_id[NumIdcs];
  logic [IPRIOLEN-1:0] top_prio[NumIdcs];
  logic [31:0] topi[NumIdcs];
  always_comb begin
    for (int c = 0; c < NumIdcs; c++) begin
      top_id[c]   = '0;
      top_prio[c] = '1;
      // Descending with <= keeps the lowest ID on equal priority.
      for (int s = NUM_SOURCES; s >= 1; s--) begin
        if (ip_q[s] && ie_q[s] && (deleg_q[s] == 1'(c / NUM_HARTS)) &&
            (tgt_hart_q[s] == HartBits'(c % NUM_HARTS)) &&
            ((ithreshold_q[c] == '0) || (tgt_prio_q[s] < ithreshold_q[c])) &&
            (tgt_prio_q[s] <= top_prio[c])) begin
          top_id[c]   = 10'(s);
          top_prio[c] = tgt_prio_q[s];
        end
      end
      topi[c] = (top_id[c] != '0) ? {6'b0, top_id[c], 8'b0, 8'(top_prio[c])} : 32'b0;
    end
  end

  // ---------------------------------------------------------------------------
  // Register writes
  // ---------------------------------------------------------------------------
  // Accesses are whole words, so the byte offset inside the word is unused.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [3:0] byte_offsets_unused;
  /* verilator lint_on UNUSEDSIGNAL */
  assign byte_offsets_unused = {i_wr_offset[1:0], i_rd_offset[1:0]};

  logic wr_hit, wr_dom;
  logic [14:0] wr_off;
  logic [31:0] wr_data_swapped;
  assign wr_hit = i_wr_en && in_region(i_wr_offset[21:16]);
  assign wr_dom = i_wr_offset[15];
  assign wr_off = {i_wr_offset[14:2], 2'b00};
  // setipnum_be holds its source number in big-endian byte order.
  assign wr_data_swapped = {i_wr_data[7:0], i_wr_data[15:8], i_wr_data[23:16], i_wr_data[31:24]};

  // Per source: whether it is active in the written domain, and the writes
  // that name it. A write naming a source that is not active in the written
  // domain has no effect on it.
  logic [NUM_SOURCES:1] wr_active, wr_cfg, wr_target;
  logic [NUM_SOURCES:1] wr_set_ip, wr_clr_ip, wr_set_ie, wr_clr_ie;
  always_comb begin
    for (int s = 1; s <= NUM_SOURCES; s++) begin
      wr_active[s] = (sm_q[s] != SmInactive) && (deleg_q[s] == wr_dom);
      wr_cfg[s] = wr_hit && (wr_off == 15'(4 * s));
      wr_target[s] = wr_hit && (wr_off == TargetOff + 15'(4 * s));
      wr_set_ip[s] = wr_hit &&
          (((wr_off == bitmap_word(SetipOff, s)) && i_wr_data[s%32]) ||
           (((wr_off == SetipnumOff) || (wr_off == SetipnumLeOff)) && (i_wr_data == 32'(s))) ||
           ((wr_off == SetipnumBeOff) && (wr_data_swapped == 32'(s))));
      wr_clr_ip[s] = wr_hit && (((wr_off == bitmap_word(InClripOff, s)) && i_wr_data[s%32]) ||
                                ((wr_off == ClripnumOff) && (i_wr_data == 32'(s))));
      wr_set_ie[s] = wr_hit && (((wr_off == bitmap_word(SetieOff, s)) && i_wr_data[s%32]) ||
                                ((wr_off == SetienumOff) && (i_wr_data == 32'(s))));
      wr_clr_ie[s] = wr_hit && (((wr_off == bitmap_word(ClrieOff, s)) && i_wr_data[s%32]) ||
                                ((wr_off == ClrienumOff) && (i_wr_data == 32'(s))));
    end
  end

  // Claims: a performed read of IDC c's claimi word.
  logic [  NumIdcs-1:0] claim;
  logic [NUM_SOURCES:1] claim_clr;  // the source a claim reports
  always_comb begin
    claim_clr = '0;
    for (int c = 0; c < NumIdcs; c++) begin
      claim[c] = i_rd_capture && in_region(i_rd_offset[21:16]) &&
          (i_rd_offset[15] == 1'(c / NUM_HARTS)) && i_rd_offset[14] &&
          (i_rd_offset[13:5] == 9'(c % NUM_HARTS)) && (i_rd_offset[4:2] == ClaimiWord);
      for (int s = 1; s <= NUM_SOURCES; s++) begin
        if (claim[c] && (top_id[c] == 10'(s))) claim_clr[s] = 1'b1;
      end
    end
  end

  // Next source configuration. cfg_clear marks a write that leaves the source
  // inactive, or moves it between domains: its pending and enable bits clear.
  // level_d and rect_d give the next mode's level sensitivity and rectified
  // input. cfg_raise marks a write that leaves the source in an edge mode and
  // raises its rectified input, which sets the pending bit at the write.
  logic [NUM_SOURCES:1] deleg_d, cfg_clear, level_d, rect_d, cfg_raise;
  logic [2:0] sm_d[1:NUM_SOURCES];
  always_comb begin
    for (int s = 1; s <= NUM_SOURCES; s++) begin
      deleg_d[s] = deleg_q[s];
      sm_d[s] = sm_q[s];
      cfg_clear[s] = 1'b0;
      if (wr_cfg[s] && !wr_dom) begin
        // Root domain. D = 1 delegates to the one child (child index 0,
        // read-only zero); the child's sourcecfg starts at zero. Writing
        // D = 1 again leaves the child's configuration alone.
        if (i_wr_data[10]) begin
          if (!deleg_q[s]) begin
            deleg_d[s] = 1'b1;
            sm_d[s] = SmInactive;
            cfg_clear[s] = 1'b1;
          end
        end else begin
          deleg_d[s] = 1'b0;
          sm_d[s] = legal_sm(i_wr_data[2:0]);
          cfg_clear[s] = deleg_q[s] || (legal_sm(i_wr_data[2:0]) == SmInactive);
        end
      end else if (wr_cfg[s] && deleg_q[s]) begin
        // Supervisor domain, a leaf: D = 1 writes the register as zero. A
        // source not delegated to it is read-only zero.
        sm_d[s] = i_wr_data[10] ? SmInactive : legal_sm(i_wr_data[2:0]);
        cfg_clear[s] = (sm_d[s] == SmInactive);
      end
      level_d[s] = sm_d[s][2] && sm_d[s][1];
      rect_d[s] = sm_d[s][2] && (src[s] ^ sm_d[s][0]);
      cfg_raise[s] = sm_d[s][2] && !sm_d[s][1] && rect_d[s] && !rect[s];
    end
  end

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      deleg_q <= '0;
      ip_q <= '0;
      ie_q <= '0;
      rect_q <= '0;
      for (int s = 1; s <= NUM_SOURCES; s++) begin
        sm_q[s] <= SmInactive;
        tgt_hart_q[s] <= '0;
        tgt_prio_q[s] <= IPRIOLEN'(1);
      end
    end else begin
      // The edge history follows the next mode, so a mode change is never
      // seen as an edge a cycle later.
      rect_q <= rect_d;
      for (int s = 1; s <= NUM_SOURCES; s++) begin
        deleg_q[s] <= deleg_d[s];
        sm_q[s] <= sm_d[s];
        // The pending bit. A level-sensitive source's follows its rectified
        // input under the mode it has from the next cycle, so a mode change
        // leaves no stale bit. One that is inactive or level-sensitive now
        // and Detached or edge-sensitive next takes this cycle's rectified
        // input under the current mode, and then the write's raise.
        if (level_d[s]) ip_q[s] <= rect_d[s];
        else if (cfg_clear[s]) ip_q[s] <= cfg_raise[s];
        else if (latched[s])
          ip_q[s] <= (ip_q[s] && !(wr_clr_ip[s] && wr_active[s]) && !claim_clr[s]) ||
              (wr_set_ip[s] && wr_active[s]) || edge_rise[s] || cfg_raise[s];
        else ip_q[s] <= rect[s] || cfg_raise[s];
        if (cfg_clear[s]) ie_q[s] <= 1'b0;
        else if (wr_set_ie[s] && wr_active[s]) ie_q[s] <= 1'b1;
        else if (wr_clr_ie[s] && wr_active[s]) ie_q[s] <= 1'b0;
        // target: Hart Index is WLRL over clog2(NUM_HARTS) bits; IPRIO is
        // WARL, with zero written as 1. It reads zero while the source is
        // inactive, but a write from the domain holding the source still
        // lands, and the source uses it once active (the spec leaves the
        // value at activation unspecified). A move between domains resets it.
        if (deleg_d[s] != deleg_q[s]) begin
          tgt_hart_q[s] <= '0;
          tgt_prio_q[s] <= IPRIOLEN'(1);
        end else if (wr_target[s] && (deleg_q[s] == wr_dom)) begin
          tgt_hart_q[s] <= (NUM_HARTS > 1) ? i_wr_data[18+:HartBits] : '0;
          tgt_prio_q[s] <= (i_wr_data[IPRIOLEN-1:0] == '0) ? IPRIOLEN'(1) : i_wr_data[IPRIOLEN-1:0];
        end
      end
    end
  end

  // Domain configuration and IDCs. A claim that reports zero clears iforce; a
  // write to iforce in the same cycle lands after it.
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      dom_ie_q <= '0;
      idelivery_q <= '0;
      iforce_q <= '0;
      for (int c = 0; c < NumIdcs; c++) ithreshold_q[c] <= '0;
    end else begin
      if (wr_hit && (wr_off == DomaincfgOff)) dom_ie_q[wr_dom] <= i_wr_data[8];
      for (int c = 0; c < NumIdcs; c++) begin
        if (claim[c] && (top_id[c] == '0)) iforce_q[c] <= 1'b0;
        if (wr_hit && (wr_dom == 1'(c / NUM_HARTS)) && wr_off[14] &&
            (wr_off[13:5] == 9'(c % NUM_HARTS))) begin
          if (wr_off[4:2] == IdeliveryWord) idelivery_q[c] <= i_wr_data[0];
          if (wr_off[4:2] == IforceWord) iforce_q[c] <= i_wr_data[0];
          if (wr_off[4:2] == IthresholdWord) ithreshold_q[c] <= i_wr_data[IPRIOLEN-1:0];
        end
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Interrupt delivery: a domain's line to a hart is asserted while its IE,
  // the hart's idelivery, and either iforce or a nonzero topi are set.
  // ---------------------------------------------------------------------------
  always_ff @(posedge i_clk) begin
    if (i_rst) eip_q <= '0;
    else begin
      for (int c = 0; c < NumIdcs; c++) begin
        eip_q[c] <= dom_ie_q[c/NUM_HARTS] && idelivery_q[c] && (iforce_q[c] || (top_id[c] != '0));
      end
    end
  end
  assign o_meip = eip_q[NUM_HARTS-1:0];
  assign o_seip = eip_q[NumIdcs-1:NUM_HARTS];

  // ---------------------------------------------------------------------------
  // Register reads
  // ---------------------------------------------------------------------------
  function automatic logic [31:0] read_word(input logic [21:2] word_off);
    logic dom;
    logic [14:0] r;
    dom = word_off[15];
    r = {word_off[14:2], 2'b00};
    read_word = '0;
    if (in_region(word_off[21:16])) begin
      if (r == DomaincfgOff) read_word = {8'h80, 15'b0, dom_ie_q[dom], 8'b0};
      for (int s = 1; s <= NUM_SOURCES; s++) begin
        if (r == 15'(4 * s)) begin
          if (!dom) read_word = deleg_q[s] ? 32'h0000_0400 : 32'(sm_q[s]);
          else if (deleg_q[s]) read_word = 32'(sm_q[s]);
        end
        // A domain sees the bits and target of only the sources it holds.
        if (deleg_q[s] == dom) begin
          if (r == bitmap_word(SetipOff, s)) read_word[s%32] = ip_q[s];
          if (r == bitmap_word(InClripOff, s)) read_word[s%32] = rect[s];
          if (r == bitmap_word(SetieOff, s)) read_word[s%32] = ie_q[s];
          if ((r == TargetOff + 15'(4 * s)) && (sm_q[s] != SmInactive))
            read_word = {14'(tgt_hart_q[s]), 10'b0, 8'(tgt_prio_q[s])};
        end
      end
      for (int c = 0; c < NumIdcs; c++) begin
        if ((dom == 1'(c / NUM_HARTS)) && r[14] && (r[13:5] == 9'(c % NUM_HARTS))) begin
          case (r[4:2])
            IdeliveryWord: read_word = 32'(idelivery_q[c]);
            IforceWord: read_word = 32'(iforce_q[c]);
            IthresholdWord: read_word = 32'(ithreshold_q[c]);
            TopiWord, ClaimiWord: read_word = topi[c];
            default: ;
          endcase
        end
      end
    end
  endfunction

  // always_comb, so the read also follows the state read_word reads.
  always_comb begin
    o_rd_pair = {read_word({i_rd_offset[21:3], 1'b1}), read_word({i_rd_offset[21:3], 1'b0})};
  end

`ifdef FORMAL
  // ---------------------------------------------------------------------------
  // Formal properties (formal/aplic.sby). Inputs are arbitrary on every
  // cycle; reset is held in the first cycle and arbitrary after it. The
  // register offsets, the read values and the pending-bit rules are written
  // out again here from the spec, apart from the logic above.
  // ---------------------------------------------------------------------------
  logic f_past_valid;
  initial f_past_valid = 1'b0;
  always_ff @(posedge i_clk) f_past_valid <= 1'b1;
  always_comb if (!f_past_valid) assume (i_rst);

  localparam logic [14:0] FSetip = 15'h1C00;
  localparam logic [14:0] FSetipnum = 15'h1CDC;
  localparam logic [14:0] FInClrip = 15'h1D00;
  localparam logic [14:0] FClripnum = 15'h1DDC;
  localparam logic [14:0] FSetie = 15'h1E00;
  localparam logic [14:0] FSetienum = 15'h1EDC;
  localparam logic [14:0] FClrie = 15'h1F00;
  localparam logic [14:0] FClrienum = 15'h1FDC;
  localparam logic [14:0] FSetipnumLe = 15'h2000;
  localparam logic [14:0] FSetipnumBe = 15'h2004;
  localparam logic [14:0] FTarget = 15'h3000;
  localparam logic [14:0] FIdc = 15'h4000;

  // The rectified input: the wire, inverted for Edge0 and Level0, and zero
  // for Inactive and Detached.
  function automatic logic f_rectified(input logic [2:0] mode, input logic wire_value);
    case (mode)
      3'd4, 3'd6: f_rectified = wire_value;
      3'd5, 3'd7: f_rectified = !wire_value;
      default: f_rectified = 1'b0;
    endcase
  endfunction

  // Source mode classes: Detached or an edge mode (pending held until
  // cleared), an edge mode, a level mode.
  function automatic logic f_held(input logic [2:0] mode);
    f_held = (mode == 3'd1) || (mode == 3'd4) || (mode == 3'd5);
  endfunction
  function automatic logic f_edge_mode(input logic [2:0] mode);
    f_edge_mode = (mode == 3'd4) || (mode == 3'd5);
  endfunction
  function automatic logic f_level_mode(input logic [2:0] mode);
    f_level_mode = (mode == 3'd6) || (mode == 3'd7);
  endfunction

  // sourcecfg.SM as a domain reads it back: the reserved 2 and 3 are
  // Inactive.
  function automatic logic [2:0] f_legal_sm(input logic [2:0] sm);
    f_legal_sm = (sm == 3'd2 || sm == 3'd3) ? 3'd0 : sm;
  endfunction

  // The bitmap word (setip and the like) holding source s.
  function automatic logic [14:0] f_bitmap(input logic [14:0] base, input int s);
    f_bitmap = base + 15'(4 * (s / 32));
  endfunction

  // A register of the IDC of IDC index c, by word.
  function automatic logic [14:0] f_idc(input int c, input int word);
    f_idc = FIdc + 15'(32 * (c % NUM_HARTS)) + 15'(4 * word);
  endfunction

  // This cycle's write and performed read, as {valid, word offset}, and
  // the same form for word r of domain d's control region.
  logic [20:0] f_wr, f_cap;
  assign f_wr  = {i_wr_en, i_wr_offset[21:2]};
  assign f_cap = {i_rd_capture, i_rd_offset[21:2]};
  function automatic logic [20:0] f_w(input logic d, input logic [14:0] r);
    f_w = {1'b1, 6'b0, d, r[14:2]};
  endfunction

  // f_cand[c][s]: source s is a candidate for IDC c, pending, enabled, in
  // the IDC's domain, aimed at its hart, and under a nonzero threshold.
  logic [NUM_SOURCES:1] f_cand[NumIdcs];
  always_comb begin
    for (int c = 0; c < NumIdcs; c++) begin
      for (int s = 1; s <= NUM_SOURCES; s++) begin
        f_cand[c][s] = ip_q[s] && ie_q[s] && (deleg_q[s] == 1'(c / NUM_HARTS)) &&
            (tgt_hart_q[s] == HartBits'(c % NUM_HARTS)) &&
            ((ithreshold_q[c] == '0) || (tgt_prio_q[s] < ithreshold_q[c]));
      end
    end
  end

  // The word a read of word r of domain d's control region returns: the
  // register map of the AIA, with every other word zero.
  logic [NUM_SOURCES:1] f_rect;
  function automatic logic [31:0] f_expected(input logic d, input logic [14:0] r);
    f_expected = '0;
    if (r == 15'h0) f_expected = {8'h80, 15'b0, dom_ie_q[d], 8'b0};
    for (int s = 1; s <= NUM_SOURCES; s++) begin
      // sourcecfg: the root sees D for a delegated source; the supervisor
      // domain sees only the sources delegated to it.
      if (r == 15'(4 * s)) begin
        if (!d) f_expected = deleg_q[s] ? 32'h400 : 32'(sm_q[s]);
        else f_expected = deleg_q[s] ? 32'(sm_q[s]) : 32'b0;
      end
      // target, and the bitmap bits, of a source the domain holds.
      if ((r == FTarget + 15'(4 * s)) && (deleg_q[s] == d) && (sm_q[s] != SmInactive))
        f_expected = {14'(tgt_hart_q[s]), 10'b0, 8'(tgt_prio_q[s])};
      if ((r == f_bitmap(FSetip, s)) && (deleg_q[s] == d)) f_expected[s%32] = ip_q[s];
      if ((r == f_bitmap(FInClrip, s)) && (deleg_q[s] == d)) f_expected[s%32] = f_rect[s];
      if ((r == f_bitmap(FSetie, s)) && (deleg_q[s] == d)) f_expected[s%32] = ie_q[s];
    end
    // The IDCs of the domain's harts; claimi reads as topi.
    for (int c = 0; c < NumIdcs; c++) begin
      if (d == 1'(c / NUM_HARTS)) begin
        if (r == f_idc(c, 0)) f_expected = 32'(idelivery_q[c]);
        if (r == f_idc(c, 1)) f_expected = 32'(iforce_q[c]);
        if (r == f_idc(c, 2)) f_expected = 32'(ithreshold_q[c]);
        if ((r == f_idc(c, 6)) || (r == f_idc(c, 7)))
          f_expected = (top_id[c] != '0) ? {6'b0, top_id[c], 8'b0, 8'(top_prio[c])} : 32'b0;
      end
    end
  endfunction

  // This cycle's events per source, in the domain that holds it, and per
  // IDC; registered below for the next cycle's checks.
  logic [31:0] f_data_be;  // the written value read big-endian
  logic [NUM_SOURCES:1] f_edge, f_set, f_clr, f_set_ie, f_clr_ie;
  logic [NUM_SOURCES:1] f_claimed, f_cfg_root, f_cfg_s, f_tgt;
  logic [NumIdcs-1:0] f_any, f_zero_claim, f_idelivery_wr, f_iforce_wr, f_ithreshold_wr;
  logic [1:0] f_domaincfg_wr;
  logic [NUM_SOURCES-1:0] f_src_p;  // last cycle's wires
  assign f_data_be = {i_wr_data[7:0], i_wr_data[15:8], i_wr_data[23:16], i_wr_data[31:24]};
  always_comb begin
    f_claimed = '0;
    for (int s = 1; s <= NUM_SOURCES; s++) begin
      f_rect[s] = f_rectified(sm_q[s], i_src[s-1]);
      // A rising edge of the wire, both cycles rectified under this mode.
      f_edge[s] = f_edge_mode(sm_q[s]) && f_rect[s] && !f_rectified(sm_q[s], f_src_p[s-1]);
      f_set[s] = ((f_wr == f_w(deleg_q[s], f_bitmap(FSetip, s))) && i_wr_data[s%32]) ||
          ((f_wr == f_w(deleg_q[s], FSetipnum)) && (i_wr_data == 32'(s))) ||
          ((f_wr == f_w(deleg_q[s], FSetipnumLe)) && (i_wr_data == 32'(s))) ||
          ((f_wr == f_w(deleg_q[s], FSetipnumBe)) && (f_data_be == 32'(s)));
      f_clr[s] = ((f_wr == f_w(deleg_q[s], f_bitmap(FInClrip, s))) && i_wr_data[s%32]) ||
          ((f_wr == f_w(deleg_q[s], FClripnum)) && (i_wr_data == 32'(s)));
      f_set_ie[s] = ((f_wr == f_w(deleg_q[s], f_bitmap(FSetie, s))) && i_wr_data[s%32]) ||
          ((f_wr == f_w(deleg_q[s], FSetienum)) && (i_wr_data == 32'(s)));
      f_clr_ie[s] = ((f_wr == f_w(deleg_q[s], f_bitmap(FClrie, s))) && i_wr_data[s%32]) ||
          ((f_wr == f_w(deleg_q[s], FClrienum)) && (i_wr_data == 32'(s)));
      f_cfg_root[s] = (f_wr == f_w(1'b0, 15'(4 * s)));
      f_cfg_s[s] = (f_wr == f_w(1'b1, 15'(4 * s)));
      f_tgt[s] = (f_wr == f_w(deleg_q[s], FTarget + 15'(4 * s)));
    end
    for (int c = 0; c < NumIdcs; c++) begin
      f_any[c] = |f_cand[c];
      f_zero_claim[c] = 1'b0;
      if (f_cap == f_w(1'(c / NUM_HARTS), f_idc(c, 7))) begin
        f_zero_claim[c] = (top_id[c] == '0);
        for (int s = 1; s <= NUM_SOURCES; s++) if (top_id[c] == 10'(s)) f_claimed[s] = 1'b1;
      end
      f_idelivery_wr[c] = (f_wr == f_w(1'(c / NUM_HARTS), f_idc(c, 0)));
      f_iforce_wr[c] = (f_wr == f_w(1'(c / NUM_HARTS), f_idc(c, 1)));
      f_ithreshold_wr[c] = (f_wr == f_w(1'(c / NUM_HARTS), f_idc(c, 2)));
    end
    for (int d = 0; d < 2; d++) f_domaincfg_wr[d] = (f_wr == f_w(1'(d), 15'h0));
  end

  // Last cycle's state and events.
  logic f_rst_p;
  logic [1:0] f_wr_dom_p;  // last cycle wrote inside domain d's region
  logic [31:0] f_wr_data_p;
  logic [1:0] f_dom_ie_p, f_domaincfg_wr_p;
  logic [NUM_SOURCES:1] f_deleg_p, f_ip_p, f_ie_p, f_edge_p, f_set_p, f_clr_p;
  logic [NUM_SOURCES:1] f_set_ie_p, f_clr_ie_p, f_claimed_p, f_cfg_root_p, f_cfg_s_p, f_tgt_p;
  logic [2:0] f_sm_p[1:NUM_SOURCES];
  logic [HartBits-1:0] f_hart_p[1:NUM_SOURCES];
  logic [IPRIOLEN-1:0] f_prio_p[1:NUM_SOURCES];
  logic [NumIdcs-1:0] f_idelivery_p, f_iforce_p, f_any_p, f_zero_claim_p;
  logic [NumIdcs-1:0] f_idelivery_wr_p, f_iforce_wr_p, f_ithreshold_wr_p;
  logic [IPRIOLEN-1:0] f_ithreshold_p[NumIdcs];
  always_ff @(posedge i_clk) begin
    f_rst_p <= i_rst;
    f_src_p <= i_src;
    f_wr_dom_p <= {
      i_wr_en && (i_wr_offset[21:15] == 7'd1), i_wr_en && (i_wr_offset[21:15] == 7'd0)
    };
    f_wr_data_p <= i_wr_data;
    {f_dom_ie_p, f_domaincfg_wr_p} <= {dom_ie_q, f_domaincfg_wr};
    {f_deleg_p, f_ip_p, f_ie_p, f_edge_p} <= {deleg_q, ip_q, ie_q, f_edge};
    {f_set_p, f_clr_p, f_set_ie_p, f_clr_ie_p} <= {f_set, f_clr, f_set_ie, f_clr_ie};
    {f_claimed_p, f_cfg_root_p, f_cfg_s_p, f_tgt_p} <= {f_claimed, f_cfg_root, f_cfg_s, f_tgt};
    {f_idelivery_p, f_iforce_p, f_any_p} <= {idelivery_q, iforce_q, f_any};
    f_zero_claim_p <= f_zero_claim;
    {f_idelivery_wr_p, f_iforce_wr_p, f_ithreshold_wr_p} <= {
      f_idelivery_wr, f_iforce_wr, f_ithreshold_wr
    };
    for (int s = 1; s <= NUM_SOURCES; s++) begin
      f_sm_p[s]   <= sm_q[s];
      f_hart_p[s] <= tgt_hart_q[s];
      f_prio_p[s] <= tgt_prio_q[s];
    end
    for (int c = 0; c < NumIdcs; c++) f_ithreshold_p[c] <= ithreshold_q[c];
  end

  // Reset: every source inactive and undelegated with target hart 0 and
  // priority 1, IE, idelivery, iforce and ithreshold zero, both lines low.
  always_comb begin
    if (f_past_valid && f_rst_p) begin
      assert ((deleg_q == '0) && (ip_q == '0) && (ie_q == '0) && (dom_ie_q == '0));
      assert ((idelivery_q == '0) && (iforce_q == '0) && (o_meip == '0) && (o_seip == '0));
      for (int s = 1; s <= NUM_SOURCES; s++)
      assert ((sm_q[s] == SmInactive) && (tgt_hart_q[s] == '0) && (tgt_prio_q[s] == IPRIOLEN'(1)));
      for (int c = 0; c < NumIdcs; c++) assert (ithreshold_q[c] == '0);
    end
  end

  // State invariants, from the first cycle after the initial reset.
  always_comb begin
    if (f_past_valid) begin
      for (int s = 1; s <= NUM_SOURCES; s++) begin
        // The edge history is last cycle's wire rectified under this mode.
        assert (rect_q[s] == f_rectified(sm_q[s], f_src_p[s-1]));
        // Only an active source has pending and enable bits; SM and IPRIO
        // hold legal values.
        assert (!ip_q[s] || (sm_q[s] != SmInactive));
        assert (!ie_q[s] || (sm_q[s] != SmInactive));
        assert (sm_q[s][2:1] != 2'b01);
        assert (tgt_prio_q[s] != '0);
        assert ((NUM_HARTS > 1) || (tgt_hart_q[s] == '0));
      end
    end
  end

  // topi: the reported source is a candidate with its own priority, and no
  // candidate has a smaller priority number, or the same one and a lower ID.
  always_comb begin
    for (int c = 0; c < NumIdcs; c++) begin
      assert (top_id[c] <= 10'(NUM_SOURCES));
      for (int s = 1; s <= NUM_SOURCES; s++) begin
        if (top_id[c] == 10'(s)) assert (f_cand[c][s] && (top_prio[c] == tgt_prio_q[s]));
        if (f_cand[c][s])
          assert ((top_id[c] != '0) &&
                  ((top_prio[c] < tgt_prio_q[s]) ||
                   ((top_prio[c] == tgt_prio_q[s]) && (top_id[c] <= 10'(s)))));
      end
    end
  end

  // One-cycle effects, against last cycle's state and events.
  always_comb begin
    if (f_past_valid && !f_rst_p) begin
      for (int s = 1; s <= NUM_SOURCES; s++) begin
        // The source configuration changes only by a sourcecfg write; a
        // change of domain or a move to Inactive clears the enable bit.
        if ((deleg_q[s] != f_deleg_p[s]) || (sm_q[s] != f_sm_p[s]))
          assert (f_cfg_root_p[s] || f_cfg_s_p[s]);
        if (deleg_q[s] != f_deleg_p[s]) assert (!ie_q[s]);
        // The root's D = 1 delegates to the one child: a newly delegated
        // source starts Inactive there, one already delegated is untouched.
        // Its D = 0 takes the source back with the written SM.
        if (f_cfg_root_p[s] && f_wr_data_p[10]) begin
          assert (deleg_q[s] && (sm_q[s] == (f_deleg_p[s] ? f_sm_p[s] : SmInactive)));
        end
        if (f_cfg_root_p[s] && !f_wr_data_p[10]) begin
          assert (!deleg_q[s] && (sm_q[s] == f_legal_sm(f_wr_data_p[2:0])));
        end
        // The supervisor domain, a leaf, writes only the sources delegated to
        // it, and D = 1 writes zero.
        if (f_cfg_s_p[s]) begin
          assert (deleg_q[s] == f_deleg_p[s]);
          assert (sm_q[s] == (!f_deleg_p[s] ? f_sm_p[s] : f_wr_data_p[10] ? SmInactive : f_legal_sm(
              f_wr_data_p[2:0]
          )));
        end
        // Level modes: the pending bit is last cycle's wire rectified under
        // the current mode, also in the cycle after a change of mode.
        if (f_level_mode(sm_q[s])) assert (ip_q[s] == f_rectified(sm_q[s], f_src_p[s-1]));
        // Detached and edge modes, unchanged: set by a set write or an edge,
        // cleared by a clear write or a claim, a set winning over a clear.
        if ((deleg_q[s] == f_deleg_p[s]) && (sm_q[s] == f_sm_p[s]) && f_held(sm_q[s]))
          assert (ip_q[s] == (f_set_p[s] || f_edge_p[s] ||
                              (f_ip_p[s] && !f_clr_p[s] && !f_claimed_p[s])));
        // A sourcecfg write that leaves the source in Detached or an edge
        // mode: a write that raises an edge mode's rectified input sets the
        // pending bit; otherwise a move between domains or from Inactive
        // leaves it zero, from a level mode it takes the old mode's
        // rectified input that cycle, and from Detached or an edge mode a
        // claim in the same cycle clears it and an edge sets it.
        if (((deleg_q[s] != f_deleg_p[s]) || (sm_q[s] != f_sm_p[s])) && f_held(sm_q[s])) begin
          if ((deleg_q[s] != f_deleg_p[s]) || (f_sm_p[s] == SmInactive)) begin
            assert (ip_q[s] == f_raise[s]);
          end
          if ((deleg_q[s] == f_deleg_p[s]) && f_level_mode(f_sm_p[s])) begin
            assert (ip_q[s] == (f_rectified(f_sm_p[s], f_src_p[s-1]) || f_raise[s]));
          end
          if ((deleg_q[s] == f_deleg_p[s]) && f_held(f_sm_p[s])) begin
            assert (ip_q[s] == (f_edge_p[s] || (f_ip_p[s] && !f_claimed_p[s]) || f_raise[s]));
          end
        end
        // Enable bits of a source active in an unchanged domain follow
        // setie and clrie for an active source; activation leaves them zero.
        if ((deleg_q[s] == f_deleg_p[s]) && (sm_q[s] != SmInactive))
          assert (ie_q[s] == ((f_set_ie_p[s] && (f_sm_p[s] != SmInactive)) ||
                              (f_ie_p[s] && !f_clr_ie_p[s])));
        // target: a move between domains resets it to hart 0, priority 1.
        // Otherwise it changes only by a write in the domain holding the
        // source, active or not, which sets the hart index from bits 31:18
        // and IPRIO, a zero written as 1.
        if (deleg_q[s] != f_deleg_p[s]) begin
          assert ((tgt_hart_q[s] == '0) && (tgt_prio_q[s] == IPRIOLEN'(1)));
        end
        if ((deleg_q[s] == f_deleg_p[s]) &&
            ((tgt_hart_q[s] != f_hart_p[s]) || (tgt_prio_q[s] != f_prio_p[s]))) begin
          assert (f_tgt_p[s]);
        end
        if ((deleg_q[s] == f_deleg_p[s]) && f_tgt_p[s]) begin
          assert (tgt_prio_q[s] == ((f_wr_data_p[IPRIOLEN-1:0] == '0) ?
                                    IPRIOLEN'(1) : f_wr_data_p[IPRIOLEN-1:0]));
          assert ((NUM_HARTS == 1) || (tgt_hart_q[s] == f_wr_data_p[18+:HartBits]));
        end
        // Only the root's writes reach a source the root holds, and only
        // writes to the two domains reach any source.
        if ((!f_wr_dom_p[0] && !f_deleg_p[s]) || (f_wr_dom_p == 2'b00))
          assert ((deleg_q[s] == f_deleg_p[s]) && (sm_q[s] == f_sm_p[s]) &&
                  (ie_q[s] == f_ie_p[s]) && (tgt_hart_q[s] == f_hart_p[s]) &&
                  (tgt_prio_q[s] == f_prio_p[s]));
      end
      // domaincfg: only IE is writable.
      for (int d = 0; d < 2; d++) begin
        assert (dom_ie_q[d] == (f_domaincfg_wr_p[d] ? f_wr_data_p[8] : f_dom_ie_p[d]));
      end
      for (int c = 0; c < NumIdcs; c++) begin
        // idelivery and iforce keep bit 0 of a write, ithreshold IPRIOLEN
        // bits; a claim that reports zero clears iforce, and a write in the
        // same cycle lands after it.
        assert (idelivery_q[c] == (f_idelivery_wr_p[c] ? f_wr_data_p[0] : f_idelivery_p[c]));
        assert (ithreshold_q[c] == (f_ithreshold_wr_p[c] ?
                                    f_wr_data_p[IPRIOLEN-1:0] : f_ithreshold_p[c]));
        assert (iforce_q[c] == (f_iforce_wr_p[c] ?
                                f_wr_data_p[0] : (f_iforce_p[c] && !f_zero_claim_p[c])));
        // Writes to the other domain, or outside both, leave a domain's IE
        // and IDCs alone.
        if (!f_wr_dom_p[c/NUM_HARTS])
          assert ((idelivery_q[c] == f_idelivery_p[c]) &&
                  (ithreshold_q[c] == f_ithreshold_p[c]) &&
                  (dom_ie_q[c/NUM_HARTS] == f_dom_ie_p[c/NUM_HARTS]) &&
                  ((iforce_q[c] == f_iforce_p[c]) || f_zero_claim_p[c]));
      end
      // The interrupt pins: a domain's IE, the hart's idelivery, and iforce
      // or a candidate, a cycle earlier.
      for (int h = 0; h < NUM_HARTS; h++) begin
        assert (o_meip[h] == (f_dom_ie_p[0] && f_idelivery_p[h] && (f_iforce_p[h] || f_any_p[h])));
        assert (o_seip[h] == (f_dom_ie_p[1] && f_idelivery_p[NUM_HARTS+h] &&
                              (f_iforce_p[NUM_HARTS+h] || f_any_p[NUM_HARTS+h])));
      end
    end
  end

  // f_raise[s]: a sourcecfg write in the last cycle left source s in an
  // edge mode and raised its rectified input.
  logic [NUM_SOURCES:1] f_raise;
  always_comb begin
    for (int s = 1; s <= NUM_SOURCES; s++)
    f_raise[s] = f_edge_mode(sm_q[s]) && f_rectified(sm_q[s], f_src_p[s-1]) &&
        !f_rectified(f_sm_p[s], f_src_p[s-1]);
  end

  // Every read, at whatever offset i_rd_offset holds; outside both control
  // regions the window reads zero.
  logic [63:0] f_expected_pair;
  always_comb begin
    f_expected_pair = '0;
    if (i_rd_offset[21:16] == '0) begin
      f_expected_pair[63:32] = f_expected(i_rd_offset[15], {i_rd_offset[14:3], 3'b100});
      f_expected_pair[31:0]  = f_expected(i_rd_offset[15], {i_rd_offset[14:3], 3'b000});
    end
    assert (o_rd_pair == f_expected_pair);
  end

  // Reachability.
  always_comb begin
    if (f_past_valid && !i_rst) begin
      cover (o_meip[NUM_HARTS-1]);
      cover (o_seip[NUM_HARTS-1]);
      // A claim of each kind: a supervisor edge source on the last hart, and
      // a root level source.
      cover (claim[NumIdcs-1] && (top_id[NumIdcs-1] == 10'(NUM_SOURCES)) &&
             (sm_q[NUM_SOURCES] == 3'd5));
      cover (claim[0] && (top_id[0] == 10'd1) && (sm_q[1] == 3'd7));
      // A spurious interrupt from iforce, and the zero claim that ends it.
      cover (eip_q[NumIdcs-1] && iforce_q[NumIdcs-1] && !f_any[NumIdcs-1]);
      cover (claim[NUM_HARTS] && (top_id[NUM_HARTS] == '0) && iforce_q[NUM_HARTS]);
      // The root takes back an active delegated source.
      cover (wr_cfg[1] && !wr_dom && !i_wr_data[10] && deleg_q[1] && (sm_q[1] != SmInactive));
      // A set write, an edge, or a raising sourcecfg write, in the same
      // cycle as a claim of the source.
      cover (claim_clr[1] && wr_set_ip[1] && wr_active[1]);
      cover (claim_clr[1] && edge_rise[1]);
      cover (claim_clr[1] && cfg_raise[1]);
    end
  end
`endif

endmodule : aplic
