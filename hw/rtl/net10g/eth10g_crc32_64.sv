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

// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Two Sigma Open Source, LLC

// Seed with all ones; complement the final result for the transmitted FCS.
module eth10g_crc32_64 (
    input  logic [31:0] i_crc,
    input  logic [63:0] i_data,
    input  logic [ 7:0] i_keep,
    output logic [31:0] o_crc
);
  assign o_crc = eth10g_crc_pkg::crc32_update(i_crc, i_data, i_keep);
endmodule
