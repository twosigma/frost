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

// Collapse the integrated fast-BRAM/MMIO/cached response into one payload.
// cached_read_ready is the router's inverse registered fast-response owner.
module data_mem_response_mux #(
    parameter int unsigned DATA_WIDTH = 64
) (
    input  logic [DATA_WIDTH-1:0] i_bram_read_data,
    input  logic [DATA_WIDTH-1:0] i_mmio_read_data,
    input  logic [DATA_WIDTH-1:0] i_cached_read_data,
    input  logic                  i_mmio_read_valid,
    input  logic                  i_cached_read_ready,
    output logic [DATA_WIDTH-1:0] o_read_data
);
`ifdef FROST_XILINX_PRIMS
  // Express each late data selection in one LUT primitive. Cover all selector
  // combinations, including stale MMIO-valid while the cached tier owns it.
  for (genvar bit_index = 0; bit_index < DATA_WIDTH; bit_index++) begin : g_response_lut
    LUT5 #(
        .INIT(32'hF0F0CCAA)
    ) response_lut (
        .I0(i_bram_read_data[bit_index]),
        .I1(i_mmio_read_data[bit_index]),
        .I2(i_cached_read_data[bit_index]),
        .I3(i_mmio_read_valid),
        .I4(i_cached_read_ready),
        .O (o_read_data[bit_index])
    );
  end
`else
  // Preserve the original procedural MMIO selection even for an unknown
  // MMIO-valid in four-state simulation. The outer ternary matches the
  // router's fast-first mux with cached_read_ready = !fast_read_valid.
  logic [DATA_WIDTH-1:0] fast_read_data;
  always_comb begin
    fast_read_data = i_bram_read_data;
    if (i_mmio_read_valid) fast_read_data = i_mmio_read_data;
  end
  assign o_read_data = i_cached_read_ready ? i_cached_read_data : fast_read_data;
`endif

`ifdef FORMAL
`ifdef DATA_MEM_RESPONSE_MUX_LOCAL_PROOF
  logic [DATA_WIDTH-1:0] reference_fast_data;
  logic [DATA_WIDTH-1:0] reference_router_data;
  always_comb begin
    reference_fast_data = i_bram_read_data;
    if (i_mmio_read_valid) reference_fast_data = i_mmio_read_data;
    reference_router_data = !i_cached_read_ready ? reference_fast_data : i_cached_read_data;
    assert (o_read_data == reference_router_data);
  end
`endif
`endif
endmodule : data_mem_response_mux
