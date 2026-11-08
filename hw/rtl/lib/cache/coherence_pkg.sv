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

package coherence_pkg;
  localparam int unsigned QBits = 9;
  localparam int unsigned TidBits = 6;
  localparam int unsigned SectorBytes = 32;
  localparam int unsigned DataBits = 256;
  // Prefetch identities: source 3, class 3, IDs 0 to PrefetchIds - 1.
  localparam int unsigned PrefetchIds = 4;

  typedef struct packed {
    logic [1:0] src;
    logic [1:0] port_class;
    logic [3:0] id;
    logic epoch;
  } q_t;

  typedef enum logic [3:0] {
    GetS = 0,
    GetM = 1,
    LoadReserved = 2,
    Atomic = 3,
    StoreConditional = 4,
    ReadOnceIF = 5,
    ReadOncePTW = 6,
    DMARead = 7,
    DMAWrite = 8,
    Prefetch = 9,
    // A GetM from the lower record of a cbo.zero block, which writes zeros to
    // the whole 64-byte block. A home miss installs the line as dirty zeros
    // without reading memory; otherwise it is a GetM.
    GetMZero = 10
  } d_opcode_t;
  typedef enum logic [1:0] {
    ProbeRead = 0,
    ProbeInvalidate = 1,
    CheckSC = 2
  } p_opcode_t;
  typedef enum logic [1:0] {
    ProbeAck  = 0,
    ProbeData = 1,
    CheckAck  = 2
  } r_opcode_t;
  typedef enum logic [2:0] {
    GrantS = 0,
    GrantE = 1,
    GrantM = 2,
    GrantData = 3,
    GrantAck = 4,
    GrantFail = 5,
    // A GrantM for a GetMZero whose home miss installed its 64-byte line as
    // zeros: the upper sector's zeros are already performed at the home.
    GrantMZero = 6
  } g_opcode_t;
  typedef enum logic [1:0] {
    Invalid = 0,
    Exclusive = 1,
    Shared = 2,
    Modified = 3
  } mesi_t;
  typedef enum logic [1:0] {
    Consumed = 0,
    Killed = 1,
    Error = 2
  } c_status_t;
  typedef enum logic [1:0] {
    Read = 0,
    Write = 1,
    Replace = 2,
    Check = 3
  } reason_t;

  // Twelve identities per hart, eight DMA credits and the prefetch
  // identities, each with a completion slot of its own.
  function automatic integer completion_count(input integer harts);
    completion_count = harts * 12 + 8 + coherence_pkg::PrefetchIds;
  endfunction
  function automatic integer fill_base(input integer harts);
    fill_base = coherence_pkg::completion_count(harts);
  endfunction
  function automatic integer put_base(input integer harts, input integer fills);
    put_base = coherence_pkg::fill_base(harts) + fills;
  endfunction
  function automatic integer home_count(input integer harts, input integer fills);
    home_count = coherence_pkg::put_base(harts, fills) + 2 * harts;
  endfunction
  // GetM and GetMZero both acquire Modified permission with data.
  function automatic logic is_getm(input logic [3:0] opcode);
    is_getm = opcode == coherence_pkg::GetM || opcode == coherence_pkg::GetMZero;
  endfunction
  // GrantM and GrantMZero both grant Modified permission with data.
  function automatic logic is_grantm(input logic [2:0] opcode);
    is_grantm = opcode == coherence_pkg::GrantM || opcode == coherence_pkg::GrantMZero;
  endfunction
  function automatic logic irrevocable(input logic [3:0] opcode);
    irrevocable = coherence_pkg::is_getm(opcode) || opcode == coherence_pkg::Atomic ||
        opcode == coherence_pkg::StoreConditional;
  endfunction
  function automatic logic legal_q(input q_t q);
    if (q.src < 2) begin
      legal_q = (q.port_class == 0 && q.id < 8) ||
          (q.port_class == 1 && q.id < 2) || (q.port_class == 2 && q.id < 2);
    end else begin
      legal_q = q.port_class == 3 && (q.src == 2 || int'(q.id) < coherence_pkg::PrefetchIds);
    end
  endfunction
  function automatic logic legal_opcode(input q_t q, input logic [3:0] opcode);
    if (q.src < 2) begin
      legal_opcode = (q.port_class == 0 &&
          (opcode <= coherence_pkg::StoreConditional || opcode == coherence_pkg::GetMZero)) ||
          (q.port_class == 1 && opcode == coherence_pkg::ReadOnceIF) ||
          (q.port_class == 2 && opcode == coherence_pkg::ReadOncePTW);
    end else begin
      legal_opcode = (q.src == 2 && (opcode == coherence_pkg::DMARead ||
          opcode == coherence_pkg::DMAWrite)) || (q.src == 3 && opcode == coherence_pkg::Prefetch);
    end
  endfunction
endpackage
