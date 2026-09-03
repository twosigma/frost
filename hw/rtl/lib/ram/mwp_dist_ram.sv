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
 * Multi-write-port distributed RAM using a live-value table (LVT). Each write
 * port owns one RAM bank; the per-address LVT selects the newest bank for the
 * asynchronous read. Among ordinary same-cycle writes, the highest-numbered
 * port wins. Duplicate the module with shared writes for additional reads.
 *
 * Ports [NUM_STAGED_LVT_PORTS-1:0] may stage their LVT update by one cycle.
 * Their bank still writes immediately. An effective-LVT override preserves
 * cycle-exact reads during the gap while keeping late write enables out of the
 * per-entry LVT decode.
 *
 * Ports [NUM_NARROW_WRITE_PORTS-1:0] store only NARROW_DATA_WIDTH low bits;
 * their checked-zero upper bits are reconstructed on read. ROB allocation
 * ports use this for zero-extended XLEN link addresses.
 *
 * Staged ports must have the lowest indices. Their collision rules differ:
 *   - A same-cycle staged/live collision is legal and the staged write wins.
 *     The ROB relies on allocation beating a stale CDB completion.
 *   - A live write in the following drain cycle wins and therefore must be
 *     architecturally newer. The ROB guarantees no completion one cycle after
 *     allocation; other users must provide the equivalent invariant.
 */
module mwp_dist_ram #(
    parameter int unsigned ADDR_WIDTH             = 5,          // Address width in bits
    parameter int unsigned DATA_WIDTH             = 32,         // Data width in bits
    parameter int unsigned NUM_WRITE_PORTS        = 2,          // Number of write ports (>= 2)
    // Ports [NUM_STAGED_LVT_PORTS-1:0] update the LVT one cycle late from
    // staging registers (banks still write same-cycle).  See header.
    parameter int unsigned NUM_STAGED_LVT_PORTS   = 0,
    // Ports [NUM_NARROW_WRITE_PORTS-1:0] only ever write data that is zero
    // above NARROW_DATA_WIDTH; their banks store just the low bits and reads
    // reconstruct the zero upper bits.  See header.
    parameter int unsigned NUM_NARROW_WRITE_PORTS = 0,
    parameter int unsigned NARROW_DATA_WIDTH      = DATA_WIDTH
) (
    input logic i_clk,

    // Write ports (active-high enables, independent addresses and data)
    input logic [NUM_WRITE_PORTS-1:0]                 i_write_enable,
    input logic [NUM_WRITE_PORTS-1:0][ADDR_WIDTH-1:0] i_write_address,
    input logic [NUM_WRITE_PORTS-1:0][DATA_WIDTH-1:0] i_write_data,

    // Read port (asynchronous / combinational)
    input  logic [ADDR_WIDTH-1:0] i_read_address,
    output logic [DATA_WIDTH-1:0] o_read_data
);

  localparam int unsigned RamDepth = 2 ** ADDR_WIDTH;
  localparam int unsigned SelWidth = $clog2(NUM_WRITE_PORTS);
  // Signed mirror for loop-bound comparisons (loop vars are signed int;
  // comparing against the unsigned parameter is a constant-comparison
  // lint warning when NUM_STAGED_LVT_PORTS=0).
  localparam int StagedLvtPorts = int'(NUM_STAGED_LVT_PORTS);

  // ---------------------------------------------------------------------------
  // RAM bank per write port.  Narrow ports get a NARROW_DATA_WIDTH bank; the
  // static cast zero-extends their read data back to DATA_WIDTH, so the read
  // mux sees constant upper bits and synthesis collapses those bit lanes to
  // the wide banks only.
  // ---------------------------------------------------------------------------
  logic [NUM_WRITE_PORTS-1:0][DATA_WIDTH-1:0] bank_read_data;

  for (genvar wp = 0; wp < NUM_WRITE_PORTS; wp++) begin : g_banks
    localparam int unsigned BankWidth =
        (wp < int'(NUM_NARROW_WRITE_PORTS)) ? NARROW_DATA_WIDTH : DATA_WIDTH;
    logic [BankWidth-1:0] bank_read_data_raw;
    sdp_dist_ram #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(BankWidth)
    ) u_bank (
        .i_clk,
        .i_write_enable (i_write_enable[wp]),
        .i_write_address(i_write_address[wp]),
        .i_read_address (i_read_address),
        .i_write_data   (i_write_data[wp][BankWidth-1:0]),
        .o_read_data    (bank_read_data_raw)
    );
    assign bank_read_data[wp] = DATA_WIDTH'(bank_read_data_raw);
  end : g_banks

  // ---------------------------------------------------------------------------
  // Live Value Table (register-based)
  //
  // Tracks which bank holds the most recent write for each address.
  // Highest-indexed write port wins on simultaneous same-address writes.
  //
  // Staged ports (indices < NUM_STAGED_LVT_PORTS): the LVT update runs one
  // cycle late from the staging registers below, so the port's (late) enable
  // only loads the staging flops' D pins instead of every per-entry LVT
  // CE/D cone.  Staged drains apply first so a live port writing the same
  // address in the drain cycle wins (it is the architecturally newer write).
  // ---------------------------------------------------------------------------
  logic [SelWidth-1:0] lvt[RamDepth];

  initial for (int i = 0; i < RamDepth; ++i) lvt[i] = '0;

  // Staged-LVT state: bit wp mirrors write port wp, held one cycle.  Bits at
  // or above NUM_STAGED_LVT_PORTS are tied 0 and synthesize away, which is the
  // all-live configuration when NUM_STAGED_LVT_PORTS=0.
  // Initialized at declaration rather than in an initial block: IEEE 1800
  // 9.2.2.4 forbids an always_ff variable being written by another process but
  // permits declaration initialization (Verilator >=5.050 enforces this;
  // yosys formal needs the pinned init value either way).
  // Timing: do not put max_fanout on these staging registers.  A 24-cap
  // experiment made synthesis replicate them and re-expand each replica's
  // per-entry lvt_eff override cone in every read-port instance.  The ROB
  // value head grew 1,505 -> 4,991 cells (3.3x, +3,486 cells, the whole
  // design's LUT delta), and that wiring sits in the operand-delivery
  // neighborhood of the int-RS capture fabric, which collapsed the X3 placer
  // sweep to congestion-level-5 vetoes.  The staged registers' routed-timing
  // family sat below the WNS pin with or without the cap, so the replication
  // bought nothing measurable.
  logic [NUM_WRITE_PORTS-1:0] staged_lvt_we_q = '0;
  logic [NUM_WRITE_PORTS-1:0][ADDR_WIDTH-1:0] staged_lvt_addr_q;

  always_ff @(posedge i_clk) begin
    for (int wp = 0; wp < NUM_WRITE_PORTS; wp++) begin
      if (wp < StagedLvtPorts) begin
        staged_lvt_we_q[wp]   <= i_write_enable[wp];
        staged_lvt_addr_q[wp] <= i_write_address[wp];
      end else begin
        staged_lvt_we_q[wp]   <= 1'b0;
        staged_lvt_addr_q[wp] <= '0;
      end
    end
  end

  always_ff @(posedge i_clk) begin
    // Staged drains first: a live same-address write below overrides.
    for (int wp = 0; wp < NUM_WRITE_PORTS; wp++) begin
      if (staged_lvt_we_q[wp]) lvt[staged_lvt_addr_q[wp]] <= SelWidth'(wp);
    end
    for (int wp = 0; wp < NUM_WRITE_PORTS; wp++) begin
      if (wp >= StagedLvtPorts) begin
        if (i_write_enable[wp]) lvt[i_write_address[wp]] <= SelWidth'(wp);
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Read mux: select the bank indicated by the effective LVT
  //
  // lvt_eff overrides the staged entries' still-stale LVT bits during the
  // one-cycle drain gap.  The override terms are pure functions of staging
  // registers, so they fold into the early side of the select cone; the late
  // read address sees the same RamDepth-to-1 depth as the unstaged module.
  // The staged port's bank was written in the enable cycle, so the corrected
  // select returns the new data.  Reads are cycle-exact against the unstaged
  // module.
  // ---------------------------------------------------------------------------
  logic [SelWidth-1:0] lvt_eff[RamDepth];

  always_comb begin
    for (int i = 0; i < RamDepth; i++) begin
      lvt_eff[i] = lvt[i];
      for (int wp = 0; wp < NUM_WRITE_PORTS; wp++) begin
        if ((wp < StagedLvtPorts) && staged_lvt_we_q[wp] &&
            (staged_lvt_addr_q[wp] == ADDR_WIDTH'(i))) begin
          lvt_eff[i] = SelWidth'(wp);
        end
      end
    end
  end

  assign o_read_data = bank_read_data[lvt_eff[i_read_address]];

`ifndef SYNTHESIS
`ifndef FORMAL
  // Staged ports must be the lowest indices: the drain-cycle override rule
  // (live beats staged) matches "highest port wins" only in that layout.
  initial begin
    if (NUM_STAGED_LVT_PORTS > NUM_WRITE_PORTS) begin
      $fatal(1, "mwp_dist_ram: NUM_STAGED_LVT_PORTS (%0d) > NUM_WRITE_PORTS (%0d)",
             NUM_STAGED_LVT_PORTS, NUM_WRITE_PORTS);
    end
    if (NUM_NARROW_WRITE_PORTS > NUM_WRITE_PORTS) begin
      $fatal(1, "mwp_dist_ram: NUM_NARROW_WRITE_PORTS (%0d) > NUM_WRITE_PORTS (%0d)",
             NUM_NARROW_WRITE_PORTS, NUM_WRITE_PORTS);
    end
    if (NARROW_DATA_WIDTH > DATA_WIDTH) begin
      $fatal(1, "mwp_dist_ram: NARROW_DATA_WIDTH (%0d) > DATA_WIDTH (%0d)", NARROW_DATA_WIDTH,
             DATA_WIDTH);
    end
  end

  // Narrow write ports must be given zero-extended data.  A nonzero upper half
  // here would be silently dropped by the narrow bank, so treat it as an error
  // at the write edge.
  if (NUM_NARROW_WRITE_PORTS > 0 && NARROW_DATA_WIDTH < DATA_WIDTH) begin : g_narrow_write_check
    localparam int NarrowPorts = int'(NUM_NARROW_WRITE_PORTS);
    always @(posedge i_clk) begin
      for (int wp = 0; wp < NarrowPorts; wp++) begin
        if (!$isunknown(
                i_write_enable[wp]
            ) && i_write_enable[wp] && !$isunknown(
                i_write_data[wp][DATA_WIDTH-1:NARROW_DATA_WIDTH]
            ) && (i_write_data[wp][DATA_WIDTH-1:NARROW_DATA_WIDTH] != '0)) begin
          $error("mwp_dist_ram: narrow write port %0d carries nonzero upper bits (0x%0h)", wp,
                 i_write_data[wp][DATA_WIDTH-1:NARROW_DATA_WIDTH]);
        end
      end
    end
  end : g_narrow_write_check

  // Same-cycle staged+live writes to one address are legal and resolve
  // staged-wins (see header), so there is no check here.  The dangerous
  // arrival is a live write in the staged address's drain cycle.  The reorder
  // buffer is the only staged-port user with live write ports.  It excludes
  // and checks that window at the ROB level, where allocation context
  // distinguishes a stale completion from a current one.
`endif
`endif

endmodule : mwp_dist_ram
