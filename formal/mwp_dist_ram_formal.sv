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

// Formal harness for mwp_dist_ram and mwp_dist_ram_ohread.
// Exercises multi-port live and staged LVT updates, same-cycle staged-over-live
// collision priority, drain-cycle live-over-staged priority, narrow-port zero
// extension, MSB-split and unsplit read muxes, and one-hot / zero-select reads.
module mwp_dist_ram_formal #(
    parameter int unsigned ADDR_WIDTH             = 3,
    parameter int unsigned DATA_WIDTH             = 8,
    parameter int unsigned NUM_WRITE_PORTS        = 4,
    parameter int unsigned NUM_STAGED_LVT_PORTS   = 2,
    parameter int unsigned NUM_NARROW_WRITE_PORTS = 2,
    parameter int unsigned NARROW_DATA_WIDTH      = 4
) (
    input logic                                       i_clk,
    input logic [NUM_WRITE_PORTS-1:0]                 i_write_enable,
    input logic [NUM_WRITE_PORTS-1:0][ADDR_WIDTH-1:0] i_write_address,
    input logic [NUM_WRITE_PORTS-1:0][DATA_WIDTH-1:0] i_write_data,
    input logic [     ADDR_WIDTH-1:0]                 i_read_address,
    input logic [  2**ADDR_WIDTH-1:0]                 i_read_onehot
);

  localparam int unsigned RamDepth    = 2 ** ADDR_WIDTH;
  localparam int          StagedPorts = int'(NUM_STAGED_LVT_PORTS);
  localparam int          NarrowPorts = int'(NUM_NARROW_WRITE_PORTS);

  // Universally quantified watched address.
  (* anyconst *) logic [ADDR_WIDTH-1:0] watch_addr;

  // Documented caller contracts:
  // 1. Narrow write ports receive zero-extended upper bits above NARROW_DATA_WIDTH.
  // 2. One-hot read select is either (1 << i_read_address) or all-zero (unused read).
  always_comb begin
    for (int wp = 0; wp < NarrowPorts; wp++) begin
      if ((NARROW_DATA_WIDTH < DATA_WIDTH) && i_write_enable[wp]) begin
        assume (i_write_data[wp][DATA_WIDTH-1:NARROW_DATA_WIDTH] == '0);
      end
    end
    assume ((i_read_onehot == '0) || (i_read_onehot == (RamDepth'(1) << i_read_address)));
  end

  logic [DATA_WIDTH-1:0] o_read_data_bin;
  logic [DATA_WIDTH-1:0] o_read_data_oh;

  mwp_dist_ram #(
      .ADDR_WIDTH            (ADDR_WIDTH),
      .DATA_WIDTH            (DATA_WIDTH),
      .NUM_WRITE_PORTS       (NUM_WRITE_PORTS),
      .NUM_STAGED_LVT_PORTS  (NUM_STAGED_LVT_PORTS),
      .NUM_NARROW_WRITE_PORTS(NUM_NARROW_WRITE_PORTS),
      .NARROW_DATA_WIDTH     (NARROW_DATA_WIDTH)
  ) u_bin (
      .i_clk          (i_clk),
      .i_write_enable (i_write_enable),
      .i_write_address(i_write_address),
      .i_write_data   (i_write_data),
      .i_read_address (i_read_address),
      .o_read_data    (o_read_data_bin)
  );

  mwp_dist_ram_ohread #(
      .ADDR_WIDTH            (ADDR_WIDTH),
      .DATA_WIDTH            (DATA_WIDTH),
      .NUM_WRITE_PORTS       (NUM_WRITE_PORTS),
      .NUM_STAGED_LVT_PORTS  (NUM_STAGED_LVT_PORTS),
      .NUM_NARROW_WRITE_PORTS(NUM_NARROW_WRITE_PORTS),
      .NARROW_DATA_WIDTH     (NARROW_DATA_WIDTH)
  ) u_oh (
      .i_clk          (i_clk),
      .i_write_enable (i_write_enable),
      .i_write_address(i_write_address),
      .i_write_data   (i_write_data),
      .i_read_address (i_read_address),
      .i_read_onehot  (i_read_onehot),
      .o_read_data    (o_read_data_oh)
  );

  // Golden reference word and bank-0 word for the watched address.
  // Both sdp_dist_ram and the reference start zero-initialized at step 0.
  logic [DATA_WIDTH-1:0] ref_watch_mem = '0;
  logic [DATA_WIDTH-1:0] ref_watch_bank0 = '0;
  logic [DATA_WIDTH-1:0] ref_watch_next;

  always_comb begin
    logic has_staged;
    has_staged     = 1'b0;
    ref_watch_next = ref_watch_mem;
    for (int wp = 0; wp < StagedPorts; wp++) begin
      if (i_write_enable[wp] && (i_write_address[wp] == watch_addr)) begin
        has_staged     = 1'b1;
        ref_watch_next = i_write_data[wp];
      end
    end
    if (!has_staged) begin
      for (int wp = StagedPorts; wp < int'(NUM_WRITE_PORTS); wp++) begin
        if (i_write_enable[wp] && (i_write_address[wp] == watch_addr)) begin
          ref_watch_next = i_write_data[wp];
        end
      end
    end
  end

  always_ff @(posedge i_clk) begin
    ref_watch_mem <= ref_watch_next;
    if (i_write_enable[0] && (i_write_address[0] == watch_addr)) begin
      ref_watch_bank0 <= (NarrowPorts > 0) ?
          DATA_WIDTH'(i_write_data[0][NARROW_DATA_WIDTH-1:0]) : i_write_data[0];
    end
  end

  logic f_past_valid = 1'b0;
  always_ff @(posedge i_clk) f_past_valid <= 1'b1;

  always_comb begin
    // Binary-read mwp_dist_ram returns the architectural reference value at watch_addr.
    if (i_read_address == watch_addr) begin
      p_bin_matches_ref : assert (o_read_data_bin == ref_watch_mem);
    end

    // One-hot read matches mwp_dist_ram for every valid one-hot select,
    // and selects bank 0 when i_read_onehot is all-zero.
    if (i_read_onehot != '0) begin
      p_oh_matches_bin : assert (o_read_data_oh == o_read_data_bin);
    end else if (i_read_address == watch_addr) begin
      p_oh_zero_reads_bank0 : assert (o_read_data_oh == ref_watch_bank0);
    end
  end

  // Collision event helpers for reachability covers on watch_addr.
  wire staged_live_same_cycle = (StagedPorts > 0) && i_write_enable[0] &&
      i_write_enable[NUM_WRITE_PORTS-1] && (i_write_address[0] == watch_addr) &&
      (i_write_address[NUM_WRITE_PORTS-1] == watch_addr) &&
      (i_write_data[0] != i_write_data[NUM_WRITE_PORTS-1]);
  wire dual_narrow_staged_same_cycle = (StagedPorts >= 2) && (NarrowPorts >= 2) &&
      i_write_enable[0] && i_write_enable[1] && (i_write_address[0] == watch_addr) &&
      (i_write_address[1] == watch_addr) && (i_write_data[0] != i_write_data[1]);

  always_ff @(posedge i_clk) begin
    if (f_past_valid) begin
      if (StagedPorts > 0) begin
        // Reach same-cycle staged vs live collision followed by immediate read of winning staged value.
        c_staged_beats_live_same_cycle :
        cover ($past(
            staged_live_same_cycle
        ) && (i_read_address == watch_addr) && (i_read_onehot != '0));

        // Reach drain-cycle live write overriding the previous cycle's staged write.
        c_live_beats_staged_drain_cycle :
        cover ($past(
            i_write_enable[0] && (i_write_address[0] == watch_addr)
        ) && i_write_enable[NUM_WRITE_PORTS-1] && !i_write_enable[0] &&
            (i_write_address[NUM_WRITE_PORTS-1] == watch_addr));
      end

      if ((StagedPorts >= 2) && (NarrowPorts >= 2)) begin
        // Reach same-cycle collision between both narrow staged ports where port 1 wins.
        c_narrow_staged_port1_beats_port0 :
        cover ($past(
            dual_narrow_staged_same_cycle
        ) && (i_read_address == watch_addr) && (i_read_onehot != '0));
      end

      // Reach all-zero one-hot unused read after bank 0 holds nonzero narrow data.
      c_oh_zero_select :
      cover ((i_read_onehot == '0) && (i_read_address == watch_addr) && (ref_watch_bank0 != '0));
    end
  end

endmodule
