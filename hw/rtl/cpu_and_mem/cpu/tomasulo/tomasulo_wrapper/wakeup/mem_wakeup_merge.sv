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

// An accepted load completion may wake MEM_RS ahead of the registered CDB.
// Preserve every registered broadcast, and use at most one idle lane. The
// following cycle's registered copy is harmless: source-ready and pending
// delivery bits already protect the captured value. No ROB completion is
// generated here. Outside recovery, the caller must establish that the early
// packet really broadcasts this cycle.
//
// Contract: an early packet never carries the tag of a valid registered lane.
// In-flight ROB tags are unique, and an accepted load leaves LQ staging
// before its registered broadcast. Simulation asserts this requirement;
// formal assumes it standalone and asserts it after reset when integrated.
// The caller does not gate enable with reset; consumers reset too.
module mem_wakeup_merge #(
    parameter bit FORMAL_STANDALONE_ENV = 1'b1
) (
    input logic i_enable,
    input riscv_pkg::fu_complete_t i_load,
    input riscv_pkg::cdb_broadcast_t i_registered_0,
    input riscv_pkg::cdb_broadcast_t i_registered_1,
    output riscv_pkg::cdb_broadcast_t o_wakeup_0,
    output riscv_pkg::cdb_broadcast_t o_wakeup_1,
    output logic o_injected
);
  riscv_pkg::cdb_broadcast_t early_packet;
  logic eligible;
  always_comb begin
    early_packet = '0;
    early_packet.valid = 1'b1;
    early_packet.tag = i_load.tag;
    early_packet.value = i_load.value;
    early_packet.fu_type = riscv_pkg::FU_MEM;
    eligible = i_enable && i_load.valid && !i_load.exception;
    o_wakeup_0 = i_registered_0;
    o_wakeup_1 = i_registered_1;
    o_injected = 1'b0;
    // Registered occupancy alone selects the lane; enable, load validity and
    // the exception bit qualify only valid. Invalid payloads are unspecified.
    if (!i_registered_0.valid) begin
      o_wakeup_0 = early_packet;
      o_wakeup_0.valid = eligible;
      o_injected = eligible;
    end else if (!i_registered_1.valid) begin
      o_wakeup_1 = early_packet;
      o_wakeup_1.valid = eligible;
      o_injected = eligible;
    end
  end

`ifndef SYNTHESIS
  logic duplicates_registered_lane;
  assign duplicates_registered_lane = i_enable && i_load.valid &&
      ((i_registered_0.valid && i_registered_0.tag == i_load.tag) ||
       (i_registered_1.valid && i_registered_1.tag == i_load.tag));
`ifdef FORMAL
  always_comb begin
    if (FORMAL_STANDALONE_ENV) begin
      assume (!duplicates_registered_lane);
    end else if (!$initstate) begin
      // Caller registers are arbitrary before the first reset edge.
      assert (!duplicates_registered_lane);
    end
  end
`else
  always_comb begin
    if (!$isunknown(duplicates_registered_lane)) begin
      p_early_load_tag_not_registered : assert (!duplicates_registered_lane);
    end
  end
`endif
`endif

`ifdef FORMAL
  always_comb begin
    if (i_registered_0.valid) assert (o_wakeup_0 == i_registered_0);
    if (i_registered_1.valid) assert (o_wakeup_1 == i_registered_1);
    assert (!(o_wakeup_0.valid != i_registered_0.valid &&
              o_wakeup_1.valid != i_registered_1.valid));
    if (!o_injected) begin
      assert (o_wakeup_0.valid == i_registered_0.valid);
      assert (o_wakeup_1.valid == i_registered_1.valid);
    end else begin
      assert (i_enable && i_load.valid && !i_load.exception);
      assert (!i_registered_0.valid || !i_registered_1.valid);
      assert ((o_wakeup_0.valid && o_wakeup_0.tag == i_load.tag &&
               o_wakeup_0.value == i_load.value) ||
              (o_wakeup_1.valid && o_wakeup_1.tag == i_load.tag &&
               o_wakeup_1.value == i_load.value));
      if (FORMAL_STANDALONE_ENV || !$initstate)
        assert (!(o_wakeup_0.valid && o_wakeup_1.valid && o_wakeup_0.tag == o_wakeup_1.tag));
    end
    if (i_enable && i_load.valid && !i_load.exception &&
        (!i_registered_0.valid || !i_registered_1.valid))
      assert (o_injected);
  end
`endif
endmodule
