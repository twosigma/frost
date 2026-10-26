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

// Read completion sets dominate response and allocation clears.
module coherence_read_flags (
    input logic [7:0] i_ready,
    input logic [7:0] i_error,
    input logic i_allocate_valid,
    input logic [2:0] i_allocate_id,
    input logic i_response_valid,
    input logic [2:0] i_response_id,
    input logic i_failure_valid,
    input logic [2:0] i_acquisition_id,
    input logic i_failure_error,
    input logic i_hit_valid,
    input logic [2:0] i_hit_id,
    input logic i_fill_valid,
    output logic [7:0] o_ready,
    output logic [7:0] o_error
);
  logic [7:0] allocate_mask, response_mask, failure_mask, hit_mask, fill_mask;
  (* keep = "true" *) logic [7:0] complete_mask, ready_preserved, error_preserved, error_set;
  assign allocate_mask = i_allocate_valid ? 8'h01 << i_allocate_id : '0;
  assign response_mask = i_response_valid ? 8'h01 << i_response_id : '0;
  assign failure_mask = i_failure_valid ? 8'h01 << i_acquisition_id : '0;
  assign hit_mask = i_hit_valid ? 8'h01 << i_hit_id : '0;
  assign fill_mask = i_fill_valid ? 8'h01 << i_acquisition_id : '0;
  assign complete_mask = failure_mask | hit_mask | fill_mask;
  assign ready_preserved = i_ready & ~response_mask;
  assign error_preserved = i_error & ~failure_mask;
  assign error_set = failure_mask & {8{i_failure_error}};
  assign o_ready = complete_mask | (ready_preserved & ~allocate_mask);
  assign o_error = error_set | (error_preserved & ~allocate_mask);

`ifndef SYNTHESIS
  logic [7:0] reference_ready, reference_error;
  always_comb begin
    reference_ready = i_ready;
    reference_error = i_error;
    if (i_response_valid) reference_ready[i_response_id] = 1'b0;
    if (i_allocate_valid) begin
      reference_ready[i_allocate_id] = 1'b0;
      reference_error[i_allocate_id] = 1'b0;
    end
    if (i_failure_valid) begin
      reference_ready[i_acquisition_id] = 1'b1;
      reference_error[i_acquisition_id] = i_failure_error;
    end
    if (i_hit_valid) reference_ready[i_hit_id] = 1'b1;
    if (i_fill_valid) reference_ready[i_acquisition_id] = 1'b1;
    p_read_flags_exact : assert ({o_ready, o_error} == {reference_ready, reference_error});
  end
`endif
endmodule
