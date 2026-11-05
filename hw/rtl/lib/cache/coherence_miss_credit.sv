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

// Shared acquisition credits are selected by read kind.
module coherence_miss_credit #(
    parameter int unsigned SLOTS = 4
) (
    input logic i_clk,
    input logic [SLOTS-1:0] i_grant_valid,
    input logic [SLOTS-1:0] i_store,
    input logic [1:0] i_wb_live,
    input logic i_wb_free,
    input logic i_request_live,
    input logic i_any_live,
    input logic i_load_ep_free,
    input logic i_atomic,
    input logic i_drain,
    output logic o_load_grant_waiting,
    output logic o_zero_wb_ok,
    output logic [3:0] o_retry
);
  (* keep = "true" *) logic load_grant_waiting;
  if (SLOTS > 1) begin : gen_load_grants
    assign load_grant_waiting = |(i_grant_valid[SLOTS-1:1] & ~i_store[SLOTS-1:1]);
  end else begin : gen_no_load_grants
    assign load_grant_waiting = 1'b0;
  end
  (* keep = "true" *) wire zero_wb_ok =
      i_wb_free && !(load_grant_waiting && |i_wb_live);
  (* keep = "true" *) wire lr_base =
      !i_request_live && i_wb_free && !i_atomic && !i_drain;
  (* keep = "true" *) logic [3:0] retry;
  if (SLOTS == 1) begin : gen_single
    assign retry = {4{!i_request_live && i_wb_free}};
  end else begin : gen_multi
    assign retry[0] = i_load_ep_free && !i_atomic && !i_drain;
    assign retry[1] = lr_base && !(load_grant_waiting && |i_wb_live);
    assign retry[2] = !i_any_live && i_wb_free;
    assign retry[3] = retry[2];
  end
  assign o_load_grant_waiting = load_grant_waiting;
  assign o_zero_wb_ok = zero_wb_ok;
  assign o_retry = retry;
`ifndef SYNTHESIS
  logic ref_waiting, ref_zero, ref_block;
  logic [3:0] ref_retry;
  always_comb begin
    ref_waiting = 1'b0;
    for (int ep = 1; ep < SLOTS; ep++)
      ref_waiting |= i_grant_valid[ep] && !i_store[ep];
    ref_zero = i_wb_free && !(ref_waiting && !(&(~i_wb_live)));
    ref_block = SLOTS > 1 && (i_atomic || i_drain);
    for (int kind = 0; kind < 4; kind++) begin
      if (SLOTS == 1) ref_retry[kind] = !i_request_live && i_wb_free;
      else if (kind == 0) ref_retry[kind] = i_load_ep_free && !ref_block;
      else if (kind == 1) ref_retry[kind] = !i_request_live && ref_zero && !ref_block;
      else ref_retry[kind] = !i_any_live && i_wb_free;
    end
  end
`ifdef FORMAL
  always_comb begin
`else
  always @(posedge i_clk)
    if (!$isunknown({i_grant_valid, i_store, i_wb_live, i_wb_free, i_request_live,
                     i_any_live, i_load_ep_free, i_atomic, i_drain})) begin
`endif
    p_miss_credit_exact : assert ({o_load_grant_waiting, o_zero_wb_ok, o_retry} ==
        {ref_waiting, ref_zero, ref_retry});
  end
`endif
endmodule
