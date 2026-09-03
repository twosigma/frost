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
 * Platform-Level Interrupt Controller (RISC-V PLIC spec 1.0, Phase 3 M6,
 * plan D11), memory-mapped in the device quadrant at 0x4400_0000. The
 * contexts are {hart0 M, hart0 S} today, and the context array is
 * parameterized for the harts Phase 5 adds.
 *
 * Sources (1-based per the spec; source 0 means "none"):
 *   1 = ns16550 UART interrupt (the meip OR-tap that used to feed mip.MEIP
 *       directly moves in here),
 *   2 = the board's i_external_interrupt pin.
 *
 * Gateways carry level semantics: a source is requestable while its level
 * is high and it has no claim in flight; the claim clears its pending bit,
 * and completion re-opens the gateway so a still-high level re-raises on
 * the next cycle (the "level-gateway re-raise" directed case).
 *
 * Register map (offsets inside the PLIC window; 32-bit registers, 32-bit
 * accesses):
 *   0x000000 + 4*s          priority[s], WARL to PRIO_BITS
 *   0x001000                pending bitmap word 0 (read-only)
 *   0x002000 + 0x80*c       enable bitmap word 0 for context c
 *   0x200000 + 0x1000*c     threshold for context c
 *   0x200004 + 0x1000*c     claim (read) / complete (write) for context c
 * Everything else in the window reads zero and ignores writes.
 *
 * The claim read is destructive, which is why the PLIC lives in the device
 * quadrant: the router's device-read interrupt shield and drain ordering
 * make the read-beat unique and architecturally performed before the
 * consume pulse fires (see data_mem_request_router's UART-RX precedent).
 * i_claim_pulse[c] must be exactly that once-per-performed-read pulse; the
 * register read data itself is combinational and captured by the MMIO beat
 * in the same cycle the pulse is decoded from.
 *
 * o_eip[c] is the registered per-context "external interrupt pending" line:
 * the maximum-priority enabled pending source strictly exceeds the
 * context's threshold. Ties select the lowest source ID (spec rule).
 */
module plic #(
    parameter int unsigned NUM_SOURCES  = 2,  // IDs 1..NUM_SOURCES
    parameter int unsigned NUM_CONTEXTS = 2,  // 0 = hart0 M, 1 = hart0 S
    parameter int unsigned PRIO_BITS    = 3   // WARL priority width (0..7)
) (
    input logic i_clk,
    input logic i_rst,

    // Source levels, index 0 = source ID 1.
    input logic [NUM_SOURCES-1:0] i_src_level,

    // Register write beat (registered MMIO write, 32-bit lane already
    // selected by the byte enables): offset inside the PLIC window.
    input logic        i_wr_en,
    input logic [21:0] i_wr_offset,
    input logic [31:0] i_wr_data,

    // Combinational register read by 8-byte-aligned window offset: the MMIO
    // read mux consumes one 64-bit beat, so the PLIC returns the
    // {offset+4, offset} register pair for it.
    input  logic [21:0] i_rd_offset,  // bits [2:0] ignored
    output logic [63:0] o_rd_pair,

    // Once-per-performed-read claim pulse per context (the destructive
    // side effect of reading claim/complete at that context).
    input logic [NUM_CONTEXTS-1:0] i_claim_pulse,

    // Registered per-context external-interrupt-pending lines.
    output logic [NUM_CONTEXTS-1:0] o_eip
);

  // Source state. Index [s] carries source ID s+1.
  logic [NUM_SOURCES-1:0] ip;  // gateway pending (claimable)
  logic [NUM_SOURCES-1:0] claimed;  // claim in flight, gateway closed
  logic [PRIO_BITS-1:0] prio[NUM_SOURCES];
  logic [NUM_SOURCES-1:0] enable[NUM_CONTEXTS];
  logic [PRIO_BITS-1:0] threshold[NUM_CONTEXTS];

  // -------------------------------------------------------------------------
  // Per-context selection: maximum-priority enabled pending source, ties to
  // the lowest ID. best_id is the 1-based source ID (0 = none). A source
  // competes only with priority > 0 (spec: priority 0 means "never
  // interrupt").
  // -------------------------------------------------------------------------
  logic [31:0] best_id[NUM_CONTEXTS];
  logic [PRIO_BITS-1:0] best_prio[NUM_CONTEXTS];
  always_comb begin
    for (int c = 0; c < NUM_CONTEXTS; c++) begin
      best_id[c]   = 32'd0;
      best_prio[c] = '0;
      for (int s = NUM_SOURCES - 1; s >= 0; s--) begin
        // Descending loop with >= keeps the lowest ID on priority ties.
        if (ip[s] && enable[c][s] && prio[s] != '0 && prio[s] >= best_prio[c]) begin
          best_id[c]   = 32'(s + 1);
          best_prio[c] = prio[s];
        end
      end
    end
  end

  // -------------------------------------------------------------------------
  // Register file
  // -------------------------------------------------------------------------
  // Offset decode helpers (32-bit register granularity).
  localparam logic [21:0] OffPendingW0 = 22'h00_1000;
  function automatic logic is_priority(input logic [21:0] off, output int unsigned s);
    is_priority = 1'b0;
    s = 0;
    if (off[21:12] == '0 && off[1:0] == 2'b00 && off != '0) begin
      s = int'(off[11:2]);
      is_priority = (s >= 1) && (s <= NUM_SOURCES);
    end
  endfunction

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      claimed <= '0;
      for (int s = 0; s < NUM_SOURCES; s++) prio[s] <= '0;
      for (int c = 0; c < NUM_CONTEXTS; c++) begin
        enable[c] <= '0;
        threshold[c] <= '0;
      end
    end else begin
      // Claim: close the winning source's gateway. The pulse is
      // once-per-performed-read; a claim with no pending source (best_id
      // 0) is a spurious claim and changes nothing (the read returned 0).
      for (int c = 0; c < NUM_CONTEXTS; c++) begin
        if (i_claim_pulse[c] && best_id[c] != 32'd0) begin
          claimed[best_id[c]-1] <= 1'b1;
        end
      end

      // Register writes.
      if (i_wr_en) begin
        automatic int unsigned ps;
        if (is_priority(i_wr_offset, ps)) begin
          prio[ps-1] <= i_wr_data[PRIO_BITS-1:0];
        end
        for (int c = 0; c < NUM_CONTEXTS; c++) begin
          if (i_wr_offset == 22'h00_2000 + 22'h80 * c[21:0]) begin
            // Spec bitmaps index by source ID: source s lives at bit s
            // (bit 0 is the nonexistent source 0). Internal ip/enable
            // arrays stay 0-based (index s-1).
            enable[c] <= i_wr_data[NUM_SOURCES:1];
          end
          if (i_wr_offset == 22'h20_0000 + 22'h1000 * c[21:0]) begin
            threshold[c] <= i_wr_data[PRIO_BITS-1:0];
          end
          // Complete: re-open the gateway for the written source ID. A
          // completion for a source that was never claimed is silently
          // ignored (spec allows it).
          if (i_wr_offset == 22'h20_0004 + 22'h1000 * c[21:0]) begin
            if (i_wr_data >= 1 && i_wr_data <= NUM_SOURCES) begin
              claimed[i_wr_data[$clog2(NUM_SOURCES+1)-1:0]-1] <= 1'b0;
            end
          end
        end
      end
    end
  end

  // A claim pulse for context c consumes its winning source this cycle.
  function automatic logic claim_consumes(input int unsigned s);
    claim_consumes = 1'b0;
    for (int c = 0; c < NUM_CONTEXTS; c++) begin
      if (i_claim_pulse[c] && best_id[c] == 32'(s + 1)) claim_consumes = 1'b1;
    end
  endfunction

  // Gateway pending: a level-high source with an open gateway is pending;
  // the claim consumes it. Registered so eip and the claim value derive
  // from the same stable view the MMIO read captured.
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      ip <= '0;
    end else begin
      for (int s = 0; s < NUM_SOURCES; s++) begin
        if (claim_consumes(s)) ip[s] <= 1'b0;
        else if (!claimed[s]) ip[s] <= i_src_level[s];
        else ip[s] <= 1'b0;
      end
    end
  end

  // Combinational read decode: one 32-bit register, by exact word offset.
  function automatic logic [31:0] read_word(input logic [21:0] off);
    int unsigned rs;
    read_word = 32'd0;
    if (is_priority(off, rs)) read_word = 32'(prio[rs-1]);
    if (off == OffPendingW0) read_word = 32'(ip) << 1;  // bit s = source s
    for (int c = 0; c < NUM_CONTEXTS; c++) begin
      if (off == 22'h00_2000 + 22'h80 * c[21:0]) read_word = 32'(enable[c]) << 1;
      if (off == 22'h20_0000 + 22'h1000 * c[21:0]) read_word = 32'(threshold[c]);
      if (off == 22'h20_0004 + 22'h1000 * c[21:0]) read_word = best_id[c];
    end
  endfunction

  assign o_rd_pair = {
    read_word({i_rd_offset[21:3], 3'b100}), read_word({i_rd_offset[21:3], 3'b000})
  };

  // Registered per-context EIP.
  always_ff @(posedge i_clk) begin
    if (i_rst) o_eip <= '0;
    else begin
      for (int c = 0; c < NUM_CONTEXTS; c++) begin
        o_eip[c] <= (best_id[c] != 32'd0) && (best_prio[c] > threshold[c]);
      end
    end
  end

endmodule
