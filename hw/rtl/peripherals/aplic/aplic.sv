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
 * Advanced Platform-Level Interrupt Controller (RISC-V AIA 1.0, chapter 4),
 * with a machine-level root domain and one supervisor-level child. Each
 * domain selects direct delivery or, with MSI_ENABLE, MSI forwarding.
 * README.md beside this file gives the register map and implementation choices.
 *
 * Window (byte offsets inside the 4 MiB SoC window):
 *   0x0000_0000  root domain control region, 32 KiB
 *   0x0000_8000  supervisor domain control region, 32 KiB
 * The rest of the window reads zero and ignores writes.
 *
 * Domain control region (offsets inside a region):
 *   0x0000         domaincfg     bits 31:24 read 0x80, bit 8 IE, bit 2 DM;
 *                                BE reads zero (little-endian)
 *   0x0000 + 4*i   sourcecfg[i]  i = 1..NUM_SOURCES
 *   0x1BC0..1BCC   MSI address configuration (root only, when implemented)
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
 *   0x3000         genmsi        hart, Busy and EIID in MSI mode; otherwise zero
 *   0x3000 + 4*i   target[i]     hart and IPRIO (direct) or EIID (MSI), no guests
 *   0x4000 + 32*h  IDC of hart index h = 0..NUM_HARTS-1: idelivery +0x00,
 *                  iforce +0x04, ithreshold +0x08, topi +0x18, claimi +0x1C
 * Every other offset reads zero and ignores writes. IDCs read zero and
 * ignore accesses in MSI mode. Number registers (setipnum, etc.) read zero.
 *
 * Each source is held by one domain. Moving it clears its pending and enable
 * bits and resets its target. The root can delegate to its one child; sources
 * not delegated to the supervisor domain are inaccessible to that domain.
 *
 * Detached and edge sources latch pending until a claim, accepted MSI or
 * software clear. Direct-mode level sources follow the rectified wire. In
 * MSI mode, a level source latches a rising rectified input or a software set
 * while that input is high; a low input, accepted MSI or software clear ends
 * pending. A simultaneous set wins over a clear, subject to the level input.
 * A sourcecfg write that raises a rectified edge or MSI-level input sets pending.
 *
 * Source wires are synchronous to i_clk. topi is combinational; interrupt
 * lines are registered. Claims and accepted MSIs precede simultaneous writes.
 * An MSI offer snapshots eligibility, address and data and stays stable until
 * ready. Later writes cannot retract it. One pending episode is retired on
 * acceptance; a later episode created after a clear, deactivation, domain
 * change or level deassertion is unaffected by that old transaction.
 */
module aplic #(
    parameter int unsigned NUM_SOURCES = 5,  // source IDs 1..NUM_SOURCES (at most 1023)
    parameter int unsigned NUM_HARTS = 1,  // hart indices 0..NUM_HARTS-1 (at most 512)
    parameter int unsigned IPRIOLEN = 3,  // implemented priority bits (1 to 8)
    parameter bit MSI_ENABLE = 1'b0,
    parameter int unsigned MSI_ADDR_WIDTH = 56,  // physical address bits, 32 to 64
    parameter logic [31:0] MMSIADDRCFG_RESET = 32'b0,
    parameter logic [31:0] MMSIADDRCFGH_RESET = 32'b0,
    parameter logic [31:0] SMSIADDRCFG_RESET = 32'b0,
    parameter logic [31:0] SMSIADDRCFGH_RESET = 32'b0
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
    output logic [NUM_HARTS-1:0] o_seip,

    // One little-endian 32-bit MSI store. The request stays stable until
    // accepted. The receiver must preserve acceptance order to the IMSICs.
    output logic o_msi_valid,
    input logic i_msi_ready,
    output logic [MSI_ADDR_WIDTH-1:0] o_msi_addr,
    output logic [31:0] o_msi_data
);

  localparam int unsigned HartBits = (NUM_HARTS > 1) ? $clog2(NUM_HARTS) : 1;
  // IDC c serves domain c / NUM_HARTS (0 = root) and hart index c % NUM_HARTS.
  localparam int unsigned NumIdcs = 2 * NUM_HARTS;
  localparam int unsigned NumMsiSlots = NUM_SOURCES + 2;
  localparam int unsigned MsiSlotBits = $clog2(NumMsiSlots);
  localparam int unsigned MaxHhxs = (MSI_ADDR_WIDTH < 62) ? MSI_ADDR_WIDTH - 31 : 31;
  localparam logic [43:0] BasePpnMask = 44'((64'd1 << (MSI_ADDR_WIDTH - 12)) - 1);

  // sourcecfg.SM. Bit 2 marks the wire-driven modes, bit 1 level over edge,
  // and bit 0 an inverted wire.
  localparam logic [2:0] SmInactive = 3'd0;
  localparam logic [2:0] SmDetached = 3'd1;

  // Register offsets inside a domain control region.
  localparam logic [14:0] DomaincfgOff = 15'h0000;
  localparam logic [14:0] MmsiaddrcfgOff = 15'h1BC0;
  localparam logic [14:0] MmsiaddrcfghOff = 15'h1BC4;
  localparam logic [14:0] SmsiaddrcfgOff = 15'h1BC8;
  localparam logic [14:0] SmsiaddrcfghOff = 15'h1BCC;
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
    if (MSI_ADDR_WIDTH < 32 || MSI_ADDR_WIDTH > 64)
      $fatal(1, "aplic: MSI_ADDR_WIDTH must be 32 to 64");
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

  // Keep the implemented PPN bits and fields. Bound HHXS so even all seven
  // high hart-index bits fit in the master address, without truncation.
  function automatic logic [31:0] legal_msicfgh(input logic [31:0] data, input logic supervisor);
    legal_msicfgh = data & (supervisor ? 32'h0070_0FFF : 32'h9F77_FFFF);
    legal_msicfgh[11:0] = data[11:0] & BasePpnMask[43:32];
    if (!supervisor && (data[28:24] > 5'(MaxHhxs))) legal_msicfgh[28:24] = 5'(MaxHhxs);
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
  logic [10:0] tgt_eiid_q[1:NUM_SOURCES];

  // Per domain: domaincfg.IE/DM and genmsi. The root owns the four address
  // configuration registers. Per IDC: idelivery, iforce, ithreshold.
  logic [1:0] dom_ie_q;
  logic [1:0] dom_dm_q, dom_dm_d;
  logic [31:0] mmsiaddrcfg_q, mmsiaddrcfgh_q, smsiaddrcfg_q, smsiaddrcfgh_q;
  logic [1:0] gen_busy_q;
  logic [HartBits-1:0] gen_hart_q[2];
  logic [10:0] gen_eiid_q[2];
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
      // Detached, edge and MSI-level pending bits latch. An MSI-level bit
      // additionally clears whenever its rectified input is low.
      latched[s] = (sm_q[s] == SmDetached) || (sm_q[s][2] && (!sm_q[s][1] || dom_dm_q[deleg_q[s]]));
      // A rising edge of the wire, rectified under the current mode.
      edge_rise[s] = sm_q[s][2] && (!sm_q[s][1] || dom_dm_q[deleg_q[s]]) && rect[s] && !rect_q[s];
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
        if (!dom_dm_q[c/NUM_HARTS] && ip_q[s] && ie_q[s] && (deleg_q[s] == 1'(c / NUM_HARTS)) &&
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
  always_comb begin
    dom_dm_d = dom_dm_q;
    if (wr_hit && (wr_off == DomaincfgOff)) dom_dm_d[wr_dom] = MSI_ENABLE && i_wr_data[2];
  end

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
      claim[c] = !dom_dm_q[c/NUM_HARTS] && i_rd_capture && in_region(i_rd_offset[21:16]) &&
          (i_rd_offset[15] == 1'(c / NUM_HARTS)) && i_rd_offset[14] &&
          (i_rd_offset[13:5] == 9'(c % NUM_HARTS)) && (i_rd_offset[4:2] == ClaimiWord);
      for (int s = 1; s <= NUM_SOURCES; s++) begin
        if (claim[c] && (top_id[c] == 10'(s))) claim_clr[s] = 1'b1;
      end
    end
  end

  // Next source configuration. cfg_clear marks a write that leaves the source
  // inactive, or moves it between domains: its pending and enable bits clear.
  // level_d and rect_d describe the next mode. cfg_raise marks a write that
  // raises an edge or MSI-level rectified input, setting pending at the write.
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
      cfg_raise[s] = sm_d[s][2] && (!sm_d[s][1] || dom_dm_d[deleg_d[s]]) && rect_d[s] && !rect[s];
    end
  end

  // ---------------------------------------------------------------------------
  // MSI forwarder. Sources and the two genmsi registers share a round-robin
  // ring. Once offered, a transaction cannot be retracted by configuration
  // writes. The pending episode it represents may end before acceptance;
  // msi_live_q prevents that old transaction from clearing a later episode.
  // ---------------------------------------------------------------------------
  logic [NumMsiSlots-1:0] msi_req;
  logic msi_pick_valid, msi_valid_q, msi_live_q, msi_fire;
  logic [MsiSlotBits-1:0] msi_pick, msi_slot_q, msi_rr_q;
  logic [MSI_ADDR_WIDTH-1:0] msi_addr_q;
  logic [31:0] msi_data_q;
  logic [NUM_SOURCES:1] msi_clear, msi_invalidate;
  logic msi_pick_dom;
  logic [HartBits-1:0] msi_pick_hart;
  logic [10:0] msi_pick_eiid;

  function automatic logic [MSI_ADDR_WIDTH-1:0] msi_address(input logic dom,
                                                            input logic [HartBits-1:0] hart);
    logic [63:0] ppn, high_index, low_index;
    logic [2:0] low_shift;
    ppn = dom ? {20'b0, smsiaddrcfgh_q[11:0], smsiaddrcfg_q} :
        {20'b0, mmsiaddrcfgh_q[11:0], mmsiaddrcfg_q};
    low_shift = dom ? smsiaddrcfgh_q[22:20] : mmsiaddrcfgh_q[22:20];
    low_index = 64'(hart) & ((64'd1 << mmsiaddrcfgh_q[15:12]) - 1);
    high_index = (64'(hart) >> mmsiaddrcfgh_q[15:12]) & ((64'd1 << mmsiaddrcfgh_q[18:16]) - 1);
    msi_address = MSI_ADDR_WIDTH'((ppn | (low_index << low_shift) |
        (high_index << (int'(mmsiaddrcfgh_q[28:24]) + 12))) << 12);
  endfunction

  always_comb begin
    for (int s = 1; s <= NUM_SOURCES; s++) begin
      msi_req[s-1] = MSI_ENABLE && dom_dm_q[deleg_q[s]] && dom_ie_q[deleg_q[s]] &&
          (sm_q[s] != SmInactive) && ip_q[s] && ie_q[s];
      msi_invalidate[s] = cfg_clear[s] || (dom_dm_d[deleg_q[s]] != dom_dm_q[deleg_q[s]]) ||
          (latched[s] && wr_clr_ip[s] && wr_active[s]) ||
          (sm_q[s][2] && sm_q[s][1] && dom_dm_q[deleg_q[s]] && !rect[s]) ||
          (level_d[s] && dom_dm_d[deleg_d[s]] && !rect_d[s]);
      msi_clear[s] = msi_fire && (msi_slot_q == MsiSlotBits'(s - 1)) && msi_live_q;
    end
    for (int d = 0; d < 2; d++) msi_req[NUM_SOURCES+d] = MSI_ENABLE && dom_dm_q[d] && gen_busy_q[d];
    msi_pick_valid = |msi_req;
    msi_pick = '0;
    for (int k = NumMsiSlots - 1; k >= 0; k--) if (msi_req[k]) msi_pick = MsiSlotBits'(k);
    for (int k = NumMsiSlots - 1; k >= 0; k--)
    if (msi_req[k] && (MsiSlotBits'(k) >= msi_rr_q)) msi_pick = MsiSlotBits'(k);
    msi_pick_dom  = 1'b0;
    msi_pick_hart = '0;
    msi_pick_eiid = '0;
    for (int s = 1; s <= NUM_SOURCES; s++) begin
      if (msi_pick == MsiSlotBits'(s - 1)) begin
        msi_pick_dom  = deleg_q[s];
        msi_pick_hart = tgt_hart_q[s];
        msi_pick_eiid = tgt_eiid_q[s];
      end
    end
    for (int d = 0; d < 2; d++) begin
      if (msi_pick == MsiSlotBits'(NUM_SOURCES + d)) begin
        msi_pick_dom  = 1'(d);
        msi_pick_hart = gen_hart_q[d];
        msi_pick_eiid = gen_eiid_q[d];
      end
    end
  end

  assign o_msi_valid = MSI_ENABLE && msi_valid_q && !i_rst;
  assign o_msi_addr = msi_addr_q;
  assign o_msi_data = msi_data_q;
  assign msi_fire = o_msi_valid && i_msi_ready;
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      msi_valid_q <= 1'b0;
      msi_live_q <= 1'b0;
      msi_slot_q <= '0;
      msi_rr_q <= '0;
      msi_addr_q <= '0;
      msi_data_q <= '0;
    end else begin
      if (msi_fire) begin
        msi_valid_q <= 1'b0;
        msi_rr_q <= (msi_slot_q == MsiSlotBits'(NumMsiSlots - 1)) ? '0 : msi_slot_q + 1'b1;
      end
      if (!msi_valid_q && msi_pick_valid) begin
        msi_valid_q <= 1'b1;
        msi_slot_q  <= msi_pick;
        msi_addr_q  <= msi_address(msi_pick_dom, msi_pick_hart);
        msi_data_q  <= {21'b0, msi_pick_eiid};
        msi_live_q  <= 1'b1;
        for (int s = 1; s <= NUM_SOURCES; s++)
        if ((msi_pick == MsiSlotBits'(s - 1)) && msi_invalidate[s]) msi_live_q <= 1'b0;
      end else begin
        for (int s = 1; s <= NUM_SOURCES; s++)
        if ((msi_slot_q == MsiSlotBits'(s - 1)) && msi_invalidate[s]) msi_live_q <= 1'b0;
      end
    end
  end

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      mmsiaddrcfg_q <= MSI_ENABLE ? MMSIADDRCFG_RESET & BasePpnMask[31:0] : '0;
      mmsiaddrcfgh_q <= MSI_ENABLE ? legal_msicfgh(MMSIADDRCFGH_RESET, 1'b0) : '0;
      smsiaddrcfg_q <= MSI_ENABLE ? SMSIADDRCFG_RESET & BasePpnMask[31:0] : '0;
      smsiaddrcfgh_q <= MSI_ENABLE ? legal_msicfgh(SMSIADDRCFGH_RESET, 1'b1) : '0;
      gen_busy_q <= '0;
      for (int d = 0; d < 2; d++) begin
        gen_hart_q[d] <= '0;
        gen_eiid_q[d] <= '0;
      end
    end else begin
      if (MSI_ENABLE && wr_hit && !wr_dom && !mmsiaddrcfgh_q[31]) begin
        case (wr_off)
          MmsiaddrcfgOff: mmsiaddrcfg_q <= i_wr_data & BasePpnMask[31:0];
          MmsiaddrcfghOff: mmsiaddrcfgh_q <= legal_msicfgh(i_wr_data, 1'b0);
          SmsiaddrcfgOff: smsiaddrcfg_q <= i_wr_data & BasePpnMask[31:0];
          SmsiaddrcfghOff: smsiaddrcfgh_q <= legal_msicfgh(i_wr_data, 1'b1);
          default: ;
        endcase
      end
      for (int d = 0; d < 2; d++) begin
        if (msi_fire && (msi_slot_q == MsiSlotBits'(NUM_SOURCES + d))) gen_busy_q[d] <= 1'b0;
        if (wr_hit && (wr_dom == 1'(d)) && (wr_off == TargetOff) &&
            dom_dm_q[d] && !gen_busy_q[d]) begin
          gen_busy_q[d] <= 1'b1;
          gen_hart_q[d] <= (NUM_HARTS > 1) ? i_wr_data[18+:HartBits] : '0;
          gen_eiid_q[d] <= i_wr_data[10:0];
        end
      end
    end
  end

  logic [NUM_SOURCES:1] ip_d;
  always_comb begin
    for (int s = 1; s <= NUM_SOURCES; s++) begin
      if (latched[s])
        ip_d[s] = (ip_q[s] && !(wr_clr_ip[s] && wr_active[s]) && !claim_clr[s] && !msi_clear[s]) ||
            (wr_set_ip[s] && wr_active[s]) || edge_rise[s];
      else ip_d[s] = rect[s];
      if (sm_q[s][2] && sm_q[s][1] && dom_dm_q[deleg_q[s]] && !rect[s]) ip_d[s] = 1'b0;
      if (cfg_clear[s]) ip_d[s] = 1'b0;
      if (cfg_raise[s]) ip_d[s] = 1'b1;
      if (level_d[s] && !dom_dm_d[deleg_d[s]]) ip_d[s] = rect_d[s];
      if (level_d[s] && dom_dm_d[deleg_d[s]] && !rect_d[s]) ip_d[s] = 1'b0;
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
        tgt_eiid_q[s] <= 11'd1;
      end
    end else begin
      // The edge history follows the next mode, so a mode change is never
      // seen as an edge a cycle later.
      rect_q <= rect_d;
      for (int s = 1; s <= NUM_SOURCES; s++) begin
        deleg_q[s] <= deleg_d[s];
        sm_q[s] <= sm_d[s];
        // Input events and retirement precede configuration writes; direct
        // level sources then follow the new mode's rectified input.
        ip_q[s] <= ip_d[s];
        if (cfg_clear[s]) ie_q[s] <= 1'b0;
        else if (wr_set_ie[s] && wr_active[s]) ie_q[s] <= 1'b1;
        else if (wr_clr_ie[s] && wr_active[s]) ie_q[s] <= 1'b0;
        // target: Hart Index is WLRL over clog2(NUM_HARTS) bits; IPRIO is
        // WARL, with zero written as 1. It reads zero while the source is
        // inactive, but a write from the domain holding the source still
        // lands, and the source uses it once active (the spec leaves the
        // value at activation unspecified). A move between domains resets it.
        // MSI writes keep all 11 EIID bits; Guest Index is read-only zero.
        if (deleg_d[s] != deleg_q[s]) begin
          tgt_hart_q[s] <= '0;
          tgt_prio_q[s] <= IPRIOLEN'(1);
          tgt_eiid_q[s] <= 11'd1;
        end else if (wr_target[s] && (deleg_q[s] == wr_dom)) begin
          tgt_hart_q[s] <= (NUM_HARTS > 1) ? i_wr_data[18+:HartBits] : '0;
          if (dom_dm_q[wr_dom]) tgt_eiid_q[s] <= i_wr_data[10:0];
          else if (i_wr_data[IPRIOLEN-1:0] == '0) tgt_prio_q[s] <= IPRIOLEN'(1);
          else tgt_prio_q[s] <= i_wr_data[IPRIOLEN-1:0];
        end
      end
    end
  end

  // Domain configuration and IDCs. A claim that reports zero clears iforce; a
  // write to iforce in the same cycle lands after it.
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      dom_ie_q <= '0;
      dom_dm_q <= '0;
      idelivery_q <= '0;
      iforce_q <= '0;
      for (int c = 0; c < NumIdcs; c++) ithreshold_q[c] <= '0;
    end else begin
      dom_dm_q <= dom_dm_d;
      if (wr_hit && (wr_off == DomaincfgOff)) dom_ie_q[wr_dom] <= i_wr_data[8];
      for (int c = 0; c < NumIdcs; c++) begin
        if (claim[c] && (top_id[c] == '0)) iforce_q[c] <= 1'b0;
        if (!dom_dm_q[c/NUM_HARTS] && wr_hit && (wr_dom == 1'(c / NUM_HARTS)) && wr_off[14] &&
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
        eip_q[c] <= !dom_dm_q[c/NUM_HARTS] && dom_ie_q[c/NUM_HARTS] && idelivery_q[c] &&
            (iforce_q[c] || (top_id[c] != '0));
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
      if (r == DomaincfgOff) read_word = {8'h80, 15'b0, dom_ie_q[dom], 5'b0, dom_dm_q[dom], 2'b0};
      if (MSI_ENABLE && !dom) begin
        case (r)
          MmsiaddrcfgOff: read_word = mmsiaddrcfg_q;
          MmsiaddrcfghOff: read_word = mmsiaddrcfgh_q;
          SmsiaddrcfgOff: read_word = smsiaddrcfg_q;
          SmsiaddrcfghOff: read_word = smsiaddrcfgh_q;
          default: ;
        endcase
      end
      if ((r == TargetOff) && dom_dm_q[dom])
        read_word = {14'(gen_hart_q[dom]), 5'b0, gen_busy_q[dom], 1'b0, gen_eiid_q[dom]};
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
            read_word = dom_dm_q[dom] ? {14'(tgt_hart_q[s]), 7'b0, tgt_eiid_q[s]} :
                {14'(tgt_hart_q[s]), 10'b0, 8'(tgt_prio_q[s])};
        end
      end
      for (int c = 0; c < NumIdcs; c++) begin
        if (!dom_dm_q[dom] && (dom == 1'(c / NUM_HARTS)) && r[14] &&
            (r[13:5] == 9'(c % NUM_HARTS))) begin
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
        f_cand[c][s] = !dom_dm_q[c/NUM_HARTS] && ip_q[s] && ie_q[s] &&
            (deleg_q[s] == 1'(c / NUM_HARTS)) &&
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
    if (r == 15'h0) f_expected = 32'h8000_0000 | (32'(dom_ie_q[d]) << 8) | (32'(dom_dm_q[d]) << 2);
    if (!d && MSI_ENABLE) begin
      if (r == 15'h1BC0) f_expected = mmsiaddrcfg_q;
      if (r == 15'h1BC4) f_expected = mmsiaddrcfgh_q;
      if (r == 15'h1BC8) f_expected = smsiaddrcfg_q;
      if (r == 15'h1BCC) f_expected = smsiaddrcfgh_q;
    end
    if ((r == 15'h3000) && dom_dm_q[d])
      f_expected = (32'(gen_hart_q[d]) << 18) | (32'(gen_busy_q[d]) << 12) | 32'(gen_eiid_q[d]);
    for (int s = 1; s <= NUM_SOURCES; s++) begin
      // sourcecfg: the root sees D for a delegated source; the supervisor
      // domain sees only the sources delegated to it.
      if (r == 15'(4 * s)) begin
        if (!d) f_expected = deleg_q[s] ? 32'h400 : 32'(sm_q[s]);
        else f_expected = deleg_q[s] ? 32'(sm_q[s]) : 32'b0;
      end
      // target, and the bitmap bits, of a source the domain holds.
      if ((r == FTarget + 15'(4 * s)) && (deleg_q[s] == d) && (sm_q[s] != SmInactive))
        f_expected = (32'(tgt_hart_q[s]) << 18) |
            (dom_dm_q[d] ? 32'(tgt_eiid_q[s]) : 32'(tgt_prio_q[s]));
      if ((r == f_bitmap(FSetip, s)) && (deleg_q[s] == d)) f_expected[s%32] = ip_q[s];
      if ((r == f_bitmap(FInClrip, s)) && (deleg_q[s] == d)) f_expected[s%32] = f_rect[s];
      if ((r == f_bitmap(FSetie, s)) && (deleg_q[s] == d)) f_expected[s%32] = ie_q[s];
    end
    // The IDCs of the domain's harts; claimi reads as topi.
    for (int c = 0; c < NumIdcs; c++) begin
      if (!dom_dm_q[d] && (d == 1'(c / NUM_HARTS))) begin
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
      f_edge[s] = (f_edge_mode(sm_q[s]) || (f_level_mode(sm_q[s]) && dom_dm_q[deleg_q[s]])) &&
          f_rect[s] && !f_rectified(sm_q[s], f_src_p[s-1]);
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
      if (!dom_dm_q[c/NUM_HARTS] && (f_cap == f_w(1'(c / NUM_HARTS), f_idc(c, 7)))) begin
        f_zero_claim[c] = (top_id[c] == '0);
        for (int s = 1; s <= NUM_SOURCES; s++) if (top_id[c] == 10'(s)) f_claimed[s] = 1'b1;
      end
      f_idelivery_wr[c] = !dom_dm_q[c/NUM_HARTS] && (f_wr == f_w(1'(c / NUM_HARTS), f_idc(c, 0)));
      f_iforce_wr[c] = !dom_dm_q[c/NUM_HARTS] && (f_wr == f_w(1'(c / NUM_HARTS), f_idc(c, 1)));
      f_ithreshold_wr[c] = !dom_dm_q[c/NUM_HARTS] && (f_wr == f_w(1'(c / NUM_HARTS), f_idc(c, 2)));
    end
    for (int d = 0; d < 2; d++) f_domaincfg_wr[d] = (f_wr == f_w(1'(d), 15'h0));
  end

  // Last cycle's state and events.
  logic f_rst_p;
  logic [1:0] f_wr_dom_p;  // last cycle wrote inside domain d's region
  logic [31:0] f_wr_data_p;
  logic [1:0] f_dom_ie_p, f_dom_dm_p, f_domaincfg_wr_p;
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
    f_dom_dm_p <= dom_dm_q;
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
        if (!MSI_ENABLE) begin
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
          assert (tgt_prio_q[s] == (f_dom_dm_p[f_deleg_p[s]] ? f_prio_p[s] :
                                  (f_wr_data_p[IPRIOLEN-1:0] == '0) ?
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
      // domaincfg: IE and, when implemented, DM are writable.
      for (int d = 0; d < 2; d++) begin
        assert (dom_ie_q[d] == (f_domaincfg_wr_p[d] ? f_wr_data_p[8] : f_dom_ie_p[d]));
        assert (dom_dm_q[d] == (MSI_ENABLE &&
            (f_domaincfg_wr_p[d] ? f_wr_data_p[2] : f_dom_dm_p[d])));
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
        assert (o_meip[h] == (!f_dom_dm_p[0] && f_dom_ie_p[0] && f_idelivery_p[h] &&
            (f_iforce_p[h] || f_any_p[h])));
        assert (o_seip[h] == (!f_dom_dm_p[1] && f_dom_ie_p[1] && f_idelivery_p[NUM_HARTS+h] &&
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

  // MSI properties include arbitrary writes during a stalled offer. Eligibility
  // and payload are sampled when the request is offered; an offer already on
  // the master cannot be retracted. Retirement belongs to its pending episode.
  if (MSI_ENABLE) begin : gen_msi_formal
    logic [NumMsiSlots-1:0] f_eligible;
    logic [NUM_SOURCES:1] f_invalid, f_invalid_p, f_retired_p;
    logic f_valid_p, f_ready_p, f_live_p, f_pick_valid_p;
    logic [MsiSlotBits-1:0] f_slot_p, f_rr_p, f_pick_p;
    logic [MSI_ADDR_WIDTH-1:0] f_address_p, f_offer_address_p;
    logic [31:0] f_payload_p, f_offer_payload_p;
    logic [10:0] f_eiid_p[1:NUM_SOURCES];
    logic [31:0] f_cfg_q[4], f_cfg_next[4], f_cfg_expected_p[4];
    logic [31:0] f_gen_q[2], f_gen_next[2], f_gen_expected_p[2];
    logic f_locked_p, f_stalled_q;

    // Field-by-field WARL rules, independent of the write decoder and helper.
    function automatic logic [31:0] f_cfg_value(input int regnum, input logic [31:0] data);
      logic [31:0] value;
      value = '0;
      if ((regnum == 0) || (regnum == 2)) begin
        for (int b = 0; b < 32; b++) if (b + 12 < MSI_ADDR_WIDTH) value[b] = data[b];
      end else begin
        for (int b = 0; b < 12; b++) if (b + 44 < MSI_ADDR_WIDTH) value[b] = data[b];
        value[22:20] = data[22:20];
        if (regnum == 1) begin
          value[31] = data[31];
          value[18:12] = data[18:12];
          value[28:24] = (int'(data[28:24]) + 31 > MSI_ADDR_WIDTH) ?
              5'(MSI_ADDR_WIDTH - 31) : data[28:24];
        end
      end
      f_cfg_value = value;
    endfunction

    // Place each hart-index bit at its specified byte-address position. This
    // checks the PPN formula without using msi_address or its split indices.
    function automatic logic [MSI_ADDR_WIDTH-1:0] f_address(input logic d,
                                                            input logic [HartBits-1:0] hart);
      logic [63:0] address_value;
      logic [31:0] high_cfg;
      high_cfg = d ? smsiaddrcfgh_q : mmsiaddrcfgh_q;
      address_value = {8'b0, high_cfg[11:0], d ? smsiaddrcfg_q : mmsiaddrcfg_q, 12'b0};
      for (int b = 0; b < HartBits; b++) begin
        if (b < int'(mmsiaddrcfgh_q[15:12]))
          address_value = address_value | (64'(hart[b]) << (12 + int'(high_cfg[22:20]) + b));
        if ((b >= int'(mmsiaddrcfgh_q[15:12])) &&
            (b < int'(mmsiaddrcfgh_q[15:12]) + int'(mmsiaddrcfgh_q[18:16])))
          address_value = address_value | (64'(hart[b]) <<
              (24 + int'(mmsiaddrcfgh_q[28:24]) + b - int'(mmsiaddrcfgh_q[15:12])));
      end
      f_address = MSI_ADDR_WIDTH'(address_value);
    endfunction

    always_comb begin
      for (int s = 1; s <= NUM_SOURCES; s++) begin
        f_eligible[s-1] = (sm_q[s] != 3'd0) && ip_q[s] && ie_q[s] &&
            dom_dm_q[deleg_q[s]] && dom_ie_q[deleg_q[s]];
        f_invalid[s] =
            (f_cfg_root[s] && ((i_wr_data[10] && !deleg_q[s]) ||
                (!i_wr_data[10] && (deleg_q[s] || (f_legal_sm(i_wr_data[2:0]) == 3'd0))))) ||
            (f_cfg_s[s] && deleg_q[s] && (i_wr_data[10] || (f_legal_sm(i_wr_data[2:0]) == 3'd0))) ||
            (f_domaincfg_wr[deleg_q[s]] && (i_wr_data[2] != dom_dm_q[deleg_q[s]])) ||
            (f_clr[s] && (f_held(sm_q[s]) || (f_level_mode(sm_q[s]) && dom_dm_q[deleg_q[s]]))) ||
            (f_level_mode(sm_q[s]) && dom_dm_q[deleg_q[s]] && !f_rect[s]);
        if ((f_cfg_root[s] && !i_wr_data[10]) || (f_cfg_s[s] && deleg_q[s] && !i_wr_data[10])) begin
          if (f_level_mode(
                  i_wr_data[2:0]
              ) && dom_dm_q[f_cfg_s[s]] && !f_rectified(
                  i_wr_data[2:0], i_src[s-1]
              ))
            f_invalid[s] = 1'b1;
        end
      end
      for (int d = 0; d < 2; d++) f_eligible[NUM_SOURCES+d] = dom_dm_q[d] && gen_busy_q[d];
      f_cfg_q[0] = mmsiaddrcfg_q;
      f_cfg_q[1] = mmsiaddrcfgh_q;
      f_cfg_q[2] = smsiaddrcfg_q;
      f_cfg_q[3] = smsiaddrcfgh_q;
      for (int r = 0; r < 4; r++) begin
        f_cfg_next[r] = f_cfg_q[r];
        if (!mmsiaddrcfgh_q[31] && (f_wr == f_w(1'b0, 15'h1BC0 + 15'(4 * r))))
          f_cfg_next[r] = f_cfg_value(r, i_wr_data);
      end
      for (int d = 0; d < 2; d++) begin
        f_gen_q[d] = (32'(gen_hart_q[d]) << 18) | (32'(gen_busy_q[d]) << 12) | 32'(gen_eiid_q[d]);
        f_gen_next[d] = f_gen_q[d];
        if (o_msi_valid && i_msi_ready && (msi_slot_q == MsiSlotBits'(NUM_SOURCES + d)))
          f_gen_next[d][12] = 1'b0;
        if (dom_dm_q[d] && !gen_busy_q[d] && (f_wr == f_w(1'(d), 15'h3000))) begin
          f_gen_next[d] = (32'(i_wr_data[10:0])) | 32'h1000;
          if (NUM_HARTS > 1) f_gen_next[d] = f_gen_next[d] | (32'(i_wr_data[18+:HartBits]) << 18);
        end
      end
    end

    always_ff @(posedge i_clk) begin
      f_valid_p <= msi_valid_q;
      f_ready_p <= i_msi_ready;
      f_live_p <= msi_live_q;
      f_slot_p <= msi_slot_q;
      f_rr_p <= msi_rr_q;
      f_pick_p <= msi_pick;
      f_pick_valid_p <= |f_eligible;
      f_invalid_p <= f_invalid;
      f_address_p <= o_msi_addr;
      f_payload_p <= o_msi_data;
      f_locked_p <= mmsiaddrcfgh_q[31];
      f_offer_address_p <= '0;
      f_offer_payload_p <= '0;
      for (int s = 1; s <= NUM_SOURCES; s++) begin
        f_eiid_p[s] <= tgt_eiid_q[s];
        f_retired_p[s] <= o_msi_valid && i_msi_ready && msi_live_q &&
            (msi_slot_q == MsiSlotBits'(s-1));
        if (msi_pick == MsiSlotBits'(s - 1)) begin
          f_offer_address_p <= f_address(deleg_q[s], tgt_hart_q[s]);
          f_offer_payload_p <= 32'(tgt_eiid_q[s]);
        end
      end
      for (int d = 0; d < 2; d++) begin
        f_gen_expected_p[d] <= f_gen_next[d];
        if (msi_pick == MsiSlotBits'(NUM_SOURCES + d)) begin
          f_offer_address_p <= f_address(1'(d), gen_hart_q[d]);
          f_offer_payload_p <= 32'(gen_eiid_q[d]);
        end
      end
      for (int r = 0; r < 4; r++) f_cfg_expected_p[r] <= f_cfg_next[r];
      if (i_rst || !msi_valid_q) f_stalled_q <= 1'b0;
      else if (!i_msi_ready) f_stalled_q <= 1'b1;
    end

    // Cyclic rank proves the next eligible slot wins and that the pointer
    // advances past each accepted slot. With eventual ready, a continuously
    // eligible slot cannot be bypassed by a second turn of another slot.
    function automatic int unsigned f_rank(input int slot, input logic [MsiSlotBits-1:0] start);
      f_rank = (slot >= int'(start)) ? slot - int'(start) : slot + NumMsiSlots - int'(start);
    endfunction
    always_comb begin
      if (f_past_valid) begin
        assert (int'(msi_rr_q) < NumMsiSlots);
        assert (int'(msi_slot_q) < NumMsiSlots);
        for (int s = 1; s <= NUM_SOURCES; s++)
        if (msi_valid_q && msi_live_q && (msi_slot_q == MsiSlotBits'(s - 1)))
          assert (ip_q[s] && (sm_q[s] != 3'd0) && dom_dm_q[deleg_q[s]]);
        assert (msi_pick_valid == (|f_eligible));
        if (msi_pick_valid) begin
          assert (f_eligible[msi_pick]);
          for (int k = 0; k < NumMsiSlots; k++)
          if (f_eligible[k]) assert (f_rank(int'(msi_pick), msi_rr_q) <= f_rank(k, msi_rr_q));
        end
        assert (o_msi_valid == (msi_valid_q && !i_rst));
        if (o_msi_valid) assert ((o_msi_addr[11:0] == '0) && (o_msi_data[31:11] == '0));
        if (f_rst_p) begin
          assert (!msi_valid_q && !msi_live_q && (msi_rr_q == '0) && (dom_dm_q == '0));
          assert ((o_msi_addr == '0) && (o_msi_data == '0));
          assert (mmsiaddrcfg_q == f_cfg_value(0, MMSIADDRCFG_RESET));
          assert (mmsiaddrcfgh_q == f_cfg_value(1, MMSIADDRCFGH_RESET));
          assert (smsiaddrcfg_q == f_cfg_value(2, SMSIADDRCFG_RESET));
          assert (smsiaddrcfgh_q == f_cfg_value(3, SMSIADDRCFGH_RESET));
          for (int d = 0; d < 2; d++) assert (f_gen_q[d] == '0);
          for (int s = 1; s <= NUM_SOURCES; s++) assert (tgt_eiid_q[s] == 11'd1);
        end else begin
          for (int r = 0; r < 4; r++) assert (f_cfg_q[r] == f_cfg_expected_p[r]);
          if (f_locked_p) assert (mmsiaddrcfgh_q[31]);
          for (int d = 0; d < 2; d++) assert (f_gen_q[d] == f_gen_expected_p[d]);
          assert (msi_valid_q == (f_valid_p ? !f_ready_p : f_pick_valid_p));
          assert (msi_rr_q == ((f_valid_p && f_ready_p) ?
              ((f_slot_p == MsiSlotBits'(NumMsiSlots-1)) ? '0 : f_slot_p + 1'b1) : f_rr_p));
          if (!f_valid_p && f_pick_valid_p) begin
            assert (msi_slot_q == f_pick_p);
            assert ((o_msi_addr == f_offer_address_p) && (o_msi_data == f_offer_payload_p));
            for (int k = 0; k < NumMsiSlots; k++) begin
              if (msi_slot_q == MsiSlotBits'(k)) begin
                if (k < NUM_SOURCES)
                  assert (msi_live_q == !f_invalid_p[k+1]);
                  else assert (msi_live_q);
              end
            end
          end else begin
            assert ((msi_slot_q == f_slot_p) && (o_msi_addr == f_address_p) &&
                (o_msi_data == f_payload_p));
            for (int k = 0; k < NumMsiSlots; k++) begin
              if (msi_slot_q == MsiSlotBits'(k)) begin
                if (k < NUM_SOURCES)
                  assert (msi_live_q == (f_live_p && !f_invalid_p[k+1]));
                  else assert (msi_live_q == f_live_p);
              end
            end
          end
          for (int s = 1; s <= NUM_SOURCES; s++) begin
            if (deleg_q[s] != f_deleg_p[s])
              assert (tgt_eiid_q[s] == 11'd1);
              else
                assert (tgt_eiid_q[s] == ((f_tgt_p[s] && f_dom_dm_p[f_deleg_p[s]]) ?
                f_wr_data_p[10:0] : f_eiid_p[s]));
          end
        end
      end
    end

    // Complete pending transition, including mode changes and simultaneous
    // input, software and retirement events. Only an accepted live offer is
    // a retirement; a set or edge on that edge wins over its clear.
    logic [NUM_SOURCES:1] f_pending;
    always_comb begin
      for (int s = 1; s <= NUM_SOURCES; s++) begin
        if (f_held(f_sm_p[s]) || (f_level_mode(f_sm_p[s]) && f_dom_dm_p[f_deleg_p[s]]))
          f_pending[s] = f_edge_p[s] || (f_set_p[s] && (f_sm_p[s] != 3'd0)) ||
              (f_ip_p[s] && !f_clr_p[s] && !f_claimed_p[s] && !f_retired_p[s]);
        else f_pending[s] = f_rectified(f_sm_p[s], f_src_p[s-1]);
        if (f_level_mode(
                f_sm_p[s]
            ) && f_dom_dm_p[f_deleg_p[s]] && !f_rectified(
                f_sm_p[s], f_src_p[s-1]
            ))
          f_pending[s] = 1'b0;
        if ((deleg_q[s] != f_deleg_p[s]) || (sm_q[s] == 3'd0)) f_pending[s] = 1'b0;
        if ((f_edge_mode(
                sm_q[s]
            ) || (f_level_mode(
                sm_q[s]
            ) && dom_dm_q[deleg_q[s]])) && f_rectified(
                sm_q[s], f_src_p[s-1]
            ) && !f_rectified(
                f_sm_p[s], f_src_p[s-1]
            ))
          f_pending[s] = 1'b1;
        if (f_level_mode(sm_q[s])) begin
          if (!dom_dm_q[deleg_q[s]] || !f_rectified(sm_q[s], f_src_p[s-1]))
            f_pending[s] = f_rectified(sm_q[s], f_src_p[s-1]);
        end
        if (f_past_valid && !f_rst_p) assert (ip_q[s] == f_pending[s]);
      end
    end

    always_comb begin
      if (f_past_valid && !i_rst) begin
        for (int d = 0; d < 2; d++) begin
          cover (msi_fire && (msi_slot_q == MsiSlotBits'(NUM_SOURCES + d)) && !dom_ie_q[d]);
          for (int mode = 4; mode < 8; mode++)
          cover (msi_fire && msi_live_q && (msi_slot_q == '0) &&
                (deleg_q[1] == 1'(d)) && (sm_q[1] == 3'(mode)));
        end
        cover (msi_fire && f_stalled_q);
        cover (msi_fire && msi_live_q && (msi_slot_q == '0) && (sm_q[1] == 3'd1));
        cover (msi_fire && msi_live_q && (msi_slot_q == '0) && f_set[1]);
        cover (msi_fire && msi_live_q && (msi_slot_q == '0) && f_edge[1]);
        cover (msi_fire && !msi_live_q && (msi_slot_q == '0) && deleg_q[1] && ip_q[1]);
        cover (msi_fire && (o_msi_addr[12]) && (o_msi_data == 32'h7FF));
        cover (mmsiaddrcfgh_q[31] && (smsiaddrcfg_q != '0) && (f_wr == f_w(
            1'b0, 15'h1BC8
        )) && (i_wr_data != smsiaddrcfg_q));
      end
    end
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
