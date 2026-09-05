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

// Reflected Ethernet CRC. Bytes and bits are consumed least significant first.
package eth10g_crc_pkg;
  function automatic logic [31:0] crc32_byte(input logic [31:0] crc, input logic [7:0] data);
    logic [31:0] value;
    value = crc;
    for (int bit_index = 0; bit_index < 8; bit_index++) begin
      value = (value >> 1) ^ ((value[0] ^ data[bit_index]) ? 32'hedb88320 : 32'b0);
    end
    return value;
  endfunction

  function automatic logic [31:0] crc32_update(input logic [31:0] crc, input logic [63:0] data,
                                               input logic [7:0] keep);
    logic [31:0] value;
    value = crc;
    for (int lane = 0; lane < 8; lane++) begin
      if (keep[lane]) value = crc32_byte(value, data[lane*8+:8]);
    end
    return value;
  endfunction
endpackage
