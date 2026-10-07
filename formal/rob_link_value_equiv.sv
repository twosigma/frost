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
 * Formal equivalence harness: rob_link_value_ram against the current
 * production mwp_dist_ram / mwp_dist_ram_ohread value configuration
 * (4 ports, ports 0/1 staged and narrow at LINK_WIDTH).
 *
 * Both sides receive identical, otherwise unconstrained writes.  The reference
 * gets the ROB's allocation data `branch ? zext(link) : 0`.  Assumptions:
 *   - SINGLE_BRANCH_CONTRACT: two enabled branch allocations in one cycle
 *     target the same address (weaker than "at most one per cycle").
 *   - ONEHOT_READ: i_read_onehot == 1 << i_read_address (head-port contract,
 *     proved for the ROB's head masks by p_head_mask_onehot and
 *     p_head_next_mask_onehot).
 *   - WATCH_READ: the read address is one arbitrary constant for the whole
 *     trace.  Reads do not change state, so this covers every read address.
 * No assumption touches CDB enables, addresses or data, or internal state.
 */
module rob_link_value_equiv #(
    parameter int unsigned ADDR_WIDTH             = 5,
    parameter int unsigned DATA_WIDTH             = 64,
    parameter int unsigned LINK_WIDTH             = DATA_WIDTH,
    parameter bit          ONEHOT_READ            = 1'b0,
    parameter bit          WATCH_READ             = 1'b1,
    parameter bit          SINGLE_BRANCH_CONTRACT = 1'b1
) (
    input logic                                     i_clk,
    input logic [              1:0]                 i_alloc_enable,
    input logic [              1:0][ADDR_WIDTH-1:0] i_alloc_address,
    input logic [              1:0]                 i_alloc_branch,
    input logic [              1:0][LINK_WIDTH-1:0] i_alloc_link,
    input logic [              1:0]                 i_cdb_enable,
    input logic [              1:0][ADDR_WIDTH-1:0] i_cdb_address,
    input logic [              1:0][DATA_WIDTH-1:0] i_cdb_data,
    input logic [   ADDR_WIDTH-1:0]                 i_read_address,
    input logic [2**ADDR_WIDTH-1:0]                 i_read_onehot
);

  localparam int unsigned RamDepth = 2 ** ADDR_WIDTH;

  logic [1:0][DATA_WIDTH-1:0] alloc_value_data;
  always_comb begin
    for (int s = 0; s < 2; s++) begin
      alloc_value_data[s] = i_alloc_branch[s] ? DATA_WIDTH'(i_alloc_link[s]) : '0;
    end
  end

  logic [3:0]                 ref_we;
  logic [3:0][ADDR_WIDTH-1:0] ref_wa;
  logic [3:0][DATA_WIDTH-1:0] ref_wd;
  assign ref_we = {i_cdb_enable[1], i_cdb_enable[0], i_alloc_enable[1], i_alloc_enable[0]};
  assign ref_wa = {i_cdb_address[1], i_cdb_address[0], i_alloc_address[1], i_alloc_address[0]};
  assign ref_wd = {i_cdb_data[1], i_cdb_data[0], alloc_value_data[1], alloc_value_data[0]};

  logic [DATA_WIDTH-1:0] ref_read_data;
  logic [DATA_WIDTH-1:0] new_read_data;

  if (ONEHOT_READ) begin : g_ref_onehot
    mwp_dist_ram_ohread #(
        .ADDR_WIDTH            (ADDR_WIDTH),
        .DATA_WIDTH            (DATA_WIDTH),
        .NUM_WRITE_PORTS       (4),
        .NUM_STAGED_LVT_PORTS  (2),
        .NUM_NARROW_WRITE_PORTS(2),
        .NARROW_DATA_WIDTH     (LINK_WIDTH)
    ) u_ref (
        .i_clk,
        .i_write_enable (ref_we),
        .i_write_address(ref_wa),
        .i_write_data   (ref_wd),
        .i_read_address,
        .i_read_onehot,
        .o_read_data    (ref_read_data)
    );
  end else begin : g_ref_binary
    mwp_dist_ram #(
        .ADDR_WIDTH            (ADDR_WIDTH),
        .DATA_WIDTH            (DATA_WIDTH),
        .NUM_WRITE_PORTS       (4),
        .NUM_STAGED_LVT_PORTS  (2),
        .NUM_NARROW_WRITE_PORTS(2),
        .NARROW_DATA_WIDTH     (LINK_WIDTH)
    ) u_ref (
        .i_clk,
        .i_write_enable (ref_we),
        .i_write_address(ref_wa),
        .i_write_data   (ref_wd),
        .i_read_address,
        .o_read_data    (ref_read_data)
    );
  end

  rob_link_value_ram #(
      .ADDR_WIDTH (ADDR_WIDTH),
      .DATA_WIDTH (DATA_WIDTH),
      .LINK_WIDTH (LINK_WIDTH),
      .ONEHOT_READ(ONEHOT_READ)
  ) u_new (
      .i_clk,
      .i_alloc_enable,
      .i_alloc_address,
      .i_alloc_branch,
      .i_alloc_link,
      .i_cdb_enable,
      .i_cdb_address,
      .i_cdb_data,
      .i_read_address,
      .i_read_onehot,
      .o_read_data(new_read_data)
  );

  (* anyconst *) logic [ADDR_WIDTH-1:0] f_watch_address;

  always_comb begin
    if (SINGLE_BRANCH_CONTRACT) begin
      assume (!(i_alloc_enable[0] && i_alloc_branch[0] && i_alloc_enable[1] &&
                i_alloc_branch[1] && (i_alloc_address[0] != i_alloc_address[1])));
    end
    if (ONEHOT_READ) assume (i_read_onehot == (RamDepth'(1) << i_read_address));
    if (WATCH_READ) assume (i_read_address == f_watch_address);

    p_read_equivalent : assert (new_read_data == ref_read_data);
  end

  // Reachability witnesses for the cases the task list names (cover tasks).
  logic f_past_alloc0_at_read;
  logic f_past_cdb_at_read;
  logic f_past_branch0_at_read;
  logic f_past_branch1_at_read;
  logic f_past_valid = 1'b0;
  always_ff @(posedge i_clk) begin
    f_past_valid <= 1'b1;
    f_past_alloc0_at_read <= i_alloc_enable[0] && (i_alloc_address[0] == i_read_address);
    f_past_cdb_at_read <= (i_cdb_enable[0] && (i_cdb_address[0] == i_read_address)) ||
                          (i_cdb_enable[1] && (i_cdb_address[1] == i_read_address));
    f_past_branch0_at_read <= i_alloc_enable[0] && i_alloc_branch[0] &&
                              (i_alloc_address[0] == i_read_address);
    f_past_branch1_at_read <= i_alloc_enable[1] && i_alloc_branch[1] &&
                              (i_alloc_address[1] == i_read_address);
  end

  always_comb begin
    if (f_past_valid) begin
      // Staging-gap read of a slot-1 link (the JAL alloc+1 read).
      c_gap_link0 : cover (f_past_branch0_at_read && (ref_read_data != '0));
      // Staging-gap read of a slot-2 link.
      c_gap_link1 : cover (f_past_branch1_at_read && (ref_read_data != '0));
      // Same-cycle stale CDB plus allocation at the read address; staged wins.
      c_stale_cdb_same_cycle : cover (f_past_alloc0_at_read && f_past_cdb_at_read);
      // CDB write to the read address in a staged address's drain cycle.
      c_drain_cycle_cdb :
      cover (f_past_alloc0_at_read && (i_cdb_enable[0] || i_cdb_enable[1]) &&
                                 ((i_cdb_address[0] == i_read_address) ||
                                  (i_cdb_address[1] == i_read_address)));
      // Both slots and both lanes write the read address in one cycle.
      c_all_ports_same_address :
      cover (&{i_alloc_enable, i_cdb_enable} &&
                                        (i_alloc_address[0] == i_read_address) &&
                                        (i_alloc_address[1] == i_read_address) &&
                                        (i_cdb_address[0] == i_read_address) &&
                                        (i_cdb_address[1] == i_read_address));
      // Duplicate-tag CDB lanes.
      c_duplicate_cdb_tag :
      cover (&i_cdb_enable && (i_cdb_address[0] == i_cdb_address[1]) &&
                                   (i_cdb_data[0] != i_cdb_data[1]));
      // Zero link value read back through the link code.
      c_zero_link : cover (f_past_branch0_at_read && (ref_read_data == '0));
    end
  end

endmodule : rob_link_value_equiv
