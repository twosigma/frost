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
// generated here. The caller must establish that the early packet really
// broadcasts this cycle, and suppress it during recovery.
module mem_wakeup_merge (
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
    eligible = i_enable && i_load.valid && !i_load.exception &&
        !(i_registered_0.valid && i_registered_0.tag == i_load.tag) &&
        !(i_registered_1.valid && i_registered_1.tag == i_load.tag);
    o_wakeup_0 = i_registered_0;
    o_wakeup_1 = i_registered_1;
    o_injected = 1'b0;
    // Choose the payload using registered lane occupancy alone. Recovery
    // and acceptance qualify only valid; routing them through the wide tag
    // mux would put them ahead of every RS tag comparator and issue selector.
    // An invalid lane's payload is unspecified, just like the normal CDB.
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
      assert (!(o_wakeup_0.valid && o_wakeup_1.valid && o_wakeup_0.tag == o_wakeup_1.tag));
    end
    if (i_enable && i_load.valid && !i_load.exception &&
        (!i_registered_0.valid || !i_registered_1.valid) &&
        !(i_registered_0.valid && i_registered_0.tag == i_load.tag) &&
        !(i_registered_1.valid && i_registered_1.tag == i_load.tag))
      assert (o_injected);
  end
`endif
endmodule
