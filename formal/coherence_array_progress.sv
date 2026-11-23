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

// Compare the controller on two real arrays with independently offered loads.
// One way has no replacement choice. With four ways the second tree replays
// the first hit port's touches so a miss sees the same victim and dirty state.
module coherence_array_progress #(
    parameter int unsigned WAYS = 1,
    parameter int unsigned ADDR_WIDTH = 32,
    localparam int unsigned WayBits = WAYS > 1 ? $clog2(WAYS) : 1,
    localparam int unsigned CountBits = 3
) (
    input logic i_clk,
    i_rst,
    input logic i_req_valid,
    i_update_valid,
    i_resp_ready,
    input logic [ADDR_WIDTH-1:0] i_req_addr,
    i_update_addr,
    input logic [WayBits-1:0] i_req_way,
    i_update_way,
    input logic [WAYS-1:0] i_req_exclude,
    input logic i_req_visit,
    i_req_skip_data_on_hit,
    i_req_tags_only,
    i_req_no_bank,
    input logic i_req_data_if_hit,
    i_req_data_if_victim_modified,
    i_req_data_if_modified,
    input logic i_req_no_touch,
    i_update_touch,
    i_update_insert,
    input logic [1:0] i_update_state,
    input logic [31:0] i_update_mask,
    input logic [255:0] i_update_data,
    input logic [1:0] i_hp_valid,
    input logic [2*ADDR_WIDTH-1:0] i_hp_addr
);
  logic [1:0] ready, update_ready, valid, hit, hp_ready, hp_hit, touch, set_id, no_bank;
  logic [WayBits-1:0] way[2], touch_way[2];
  logic [3:0] phase[2];
  logic [CountBits-1:0] count[2];
  logic [1:0] state_out[2];
  logic [ADDR_WIDTH-1:0] address_out[2];

  for (genvar n = 0; n < 2; n++) begin : gen_copy
    coherence_array #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .CACHE_BYTES(64 * WAYS),
        .WAYS(WAYS),
        .BIMODAL_INSERT(1'b1),
        .HIT_PORT(1'b1)
    ) array (
        .i_clk,
        .i_rst,
        .o_init_done(),
        .i_req_valid,
        .o_req_ready(ready[n]),
        .i_req_addr,
        .i_req_exclude,
        .i_req_way(WAYS == 1 ? '0 : i_req_way),
        .i_req_visit,
        .i_req_skip_data_on_hit,
        .i_req_tags_only,
        .i_req_no_bank,
        .i_req_data_if_hit,
        .i_req_data_if_modified,
        .i_req_data_if_victim_modified,
        .i_req_no_touch,
        .o_resp_valid(valid[n]),
        .i_resp_ready,
        .o_resp_hit(hit[n]),
        .o_resp_available(),
        .o_resp_way(way[n]),
        .o_resp_addr(address_out[n]),
        .o_resp_state(state_out[n]),
        .o_resp_no_bank(no_bank[n]),
        .o_resp_data_valid(),
        .o_resp_data(),
        .i_update_valid,
        .o_update_ready(update_ready[n]),
        .i_update_addr,
        .i_update_way(WAYS == 1 ? '0 : i_update_way),
        .i_update_state,
        .i_update_touch,
        .i_update_insert,
        .i_update_mask,
        .i_update_data,
        .i_hp_valid(i_hp_valid[n]),
        .i_hp_addr(i_hp_addr[n*ADDR_WIDTH+:ADDR_WIDTH]),
        .o_hp_ready(hp_ready[n]),
        .o_hp_hit(hp_hit[n]),
        .o_hp_data(),
        .o_f_phase(phase[n]),
        .o_f_count(count[n]),
        .o_f_touch(touch[n]),
        .o_f_set(set_id[n]),
        .o_f_way(touch_way[n]),
        .i_f_replay(n == 1 && WAYS > 1),
        .i_f_touch(touch[0]),
        .i_f_set(set_id[0]),
        .i_f_way(touch_way[0])
    );
  end

  // Follow a hit-port read from the store's Tags edge to its registered
  // answer. The store's tag result is available one edge before the load hit.
  logic store_request_q, overlap_q, beside_modified_q, beside_miss_q;
  logic banked_q, after_banked_reply_q, next_lookup_q;
  logic [ADDR_WIDTH-1:0] lookup_addr_q;
  wire store_take = phase[0] == 4'd2 && store_request_q && no_bank[0] &&
      hp_ready[0] && i_hp_valid[0];
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      store_request_q <= 1'b0;
      lookup_addr_q <= '0;
      overlap_q <= 1'b0;
      beside_modified_q <= 1'b0;
      beside_miss_q <= 1'b0;
      banked_q <= 1'b0;
      after_banked_reply_q <= 1'b0;
      next_lookup_q <= 1'b0;
    end else begin
      if (ready[0] && i_req_valid) begin
        store_request_q <= i_req_no_bank && i_req_skip_data_on_hit;
        lookup_addr_q   <= i_req_addr;
      end
      overlap_q <= store_take;
      beside_modified_q <= overlap_q && hit[0] && state_out[0] == 2'b11;
      beside_miss_q <= overlap_q && !hit[0];
      if (phase[0] == 4'd2) banked_q <= !hp_ready[0];
      after_banked_reply_q <= valid[0] && i_resp_ready && banked_q;
      next_lookup_q <= after_banked_reply_q && ready[0] && i_req_valid;
    end
  end

  logic started = 1'b0;
`ifdef PROGRESS_INDUCT
  // Compare the controller registers and the metadata they read on the two
  // real arrays. Each equality is an induction goal with its own reset base.
  `define PROGRESS_REGS(path) {path.phase_q, path.count_q, path.init_set_q, path.init_done_q, \
    path.set_q, path.tag_q, path.visit_q, path.skip_data_q, path.modified_data_q, \
    path.no_touch_q, path.hit_data_q, path.victim_data_q, path.tags_only_q, path.bank_owner_q, \
    path.visit_way_q, path.exclude_q, path.plru_q, path.nru_q, path.nru_clear_q, \
    path.insert_lfsr_q, path.plru_hit_q, \
    path.resp_valid_q, path.data_valid_q, path.o_resp_hit, path.o_resp_available, path.o_resp_way, \
    path.o_resp_addr, path.o_resp_state}
  always_ff @(posedge i_clk)
    if (started) begin
      p_induct_controller :
      assert (`PROGRESS_REGS(gen_copy[0].array) == `PROGRESS_REGS(gen_copy[1].array));
      p_induct_plru_read :
      assert (gen_copy[0].array.nru_read == gen_copy[1].array.nru_read &&
          gen_copy[0].array.plru_read == gen_copy[1].array.plru_read);
    end
  `undef PROGRESS_REGS
  for (genvar w = 0; w < WAYS; w++) begin : gen_induct_way
    always_ff @(posedge i_clk)
      if (started) begin
        p_induct_tag_read :
        assert (gen_copy[0].array.gen_tag_block.gen_way[w].tags.o_read_data ==
          gen_copy[1].array.gen_tag_block.gen_way[w].tags.o_read_data);
      end
    for (genvar s = 0; s < 2; s++) begin : gen_set
      always_ff @(posedge i_clk)
        if (started) begin
          p_induct_tag :
          assert (gen_copy[0].array.gen_tag_block.gen_way[w].tags.ram[s] ==
            gen_copy[1].array.gen_tag_block.gen_way[w].tags.ram[s]);
        end
    end
  end
  if (WAYS > 1) begin : gen_induct_nru
    for (genvar w = 0; w < WAYS; w++) begin : gen_induct_node
      for (genvar s = 0; s < 2; s++) begin : gen_set
        always_ff @(posedge i_clk)
          if (started) begin
            p_induct_plru :
            assert (gen_copy[0].array.gen_nru_replacement.gen_nru[w].replacement.ram[s] ==
              gen_copy[1].array.gen_nru_replacement.gen_nru[w].replacement.ram[s]);
          end
      end
    end
  end
`endif

  always_ff @(posedge i_clk) begin
    started <= 1'b1;
    if (!started) assume (i_rst);
    if (started) begin
      p_progress_control :
      assert (ready[0] == ready[1] && update_ready[0] == update_ready[1] &&
          valid[0] == valid[1] && phase[0] == phase[1] && count[0] == count[1]);
      if (valid[0]) begin
        p_progress_response :
        assert (hit[0] == hit[1] && state_out[0] == state_out[1] &&
            address_out[0] == address_out[1] && (!hit[0] || way[0] == way[1]));
      end
      if (!i_rst) begin
        c_progress_split_take :
        cover (phase[0] == 4'd2 && no_bank[0] && (hp_ready & i_hp_valid) == 2'b01);
        c_progress_consecutive :
        cover (hp_ready[0] && i_hp_valid[0] && $past(hp_ready[0] && i_hp_valid[0] && !i_rst));
        c_progress_held :
        cover (valid[0] && !i_resp_ready && $past(valid[0] && !i_resp_ready && !i_rst));
        c_progress_modified_load_hit : cover (beside_modified_q && hp_hit[0]);
        c_progress_modified_load_miss : cover (beside_modified_q && !hp_hit[0]);
        c_progress_miss_load_hit : cover (beside_miss_q && hp_hit[0]);
        c_progress_miss_load_miss : cover (beside_miss_q && !hp_hit[0]);
        c_progress_other_tag :
        cover (store_take && lookup_addr_q[5] == i_hp_addr[5] &&
            lookup_addr_q[ADDR_WIDTH-1:6] != i_hp_addr[ADDR_WIDTH-1:6]);
        c_progress_sibling :
        cover (store_take && lookup_addr_q[5] != i_hp_addr[5] &&
            lookup_addr_q[ADDR_WIDTH-1:6] == i_hp_addr[ADDR_WIDTH-1:6]);
        c_progress_write_refusal :
        cover (i_hp_valid[0] && !hp_ready[0] && update_ready[0] && i_update_valid &&
            i_update_addr[5] == i_hp_addr[5]);
        c_progress_next_claim : cover (next_lookup_q && phase[0] == 4'd2 && !hp_ready[0]);
        c_progress_split_touch : cover (touch == 2'b01);
      end
    end
  end
endmodule
