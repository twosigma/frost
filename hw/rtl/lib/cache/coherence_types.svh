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

// Packed payloads use the caller's physical address width.
`ifndef FROST_COHERENCE_TYPES_SVH
`define FROST_COHERENCE_TYPES_SVH
`define FROST_COHERENCE_TYPES(P) \
  typedef struct packed { \
    logic [3:0] opcode; \
    coherence_pkg::q_t q; \
    logic [P-1:0] addr; \
    logic [4:0] offset; \
    logic [2:0] size; \
    logic [31:0] mask; \
    logic aq; \
    logic rl; \
    logic maintenance; \
    logic [255:0] wdata; \
  } coh_d_t; \
  typedef struct packed { \
    logic [1:0] opcode; \
    logic [5:0] tid; \
    logic epoch; \
    logic [P-1:0] addr; \
    logic [1:0] requester; \
    logic [1:0] reason; \
    coherence_pkg::q_t check_q; \
    logic [4:0] offset; \
    logic [2:0] size; \
  } coh_p_t; \
  typedef struct packed { \
    logic [1:0] opcode; \
    logic [5:0] tid; \
    logic epoch; \
    logic hart; \
    logic [P-1:0] addr; \
    logic [1:0] state; \
    logic clear; \
    logic data_valid; \
    logic [255:0] data; \
    logic absorbed; \
    logic put_id; \
    logic put_epoch; \
    logic sc_valid; \
    logic error; \
  } coh_r_t; \
  typedef struct packed { \
    logic hart; \
    logic put_id; \
    logic epoch; \
    logic [P-1:0] addr; \
    logic [255:0] data; \
    logic maintenance; \
  } coh_w_t; \
  typedef struct packed { \
    logic hart; \
    logic put_id; \
    logic epoch; \
    logic [P-1:0] addr; \
    logic absorbed; \
    logic [5:0] tid; \
    logic error; \
  } coh_wa_t; \
  typedef struct packed { \
    logic [2:0] opcode; \
    coherence_pkg::q_t q; \
    logic [5:0] tid; \
    logic [P-1:0] addr; \
    logic [255:0] data; \
    logic error; \
  } coh_g_t; \
  typedef struct packed { \
    coherence_pkg::q_t q; \
    logic [5:0] tid; \
    logic [P-1:0] addr; \
    logic [1:0] status; \
    logic write_done; \
  } coh_c_t; \
  typedef struct packed { \
    coherence_pkg::q_t q; \
    logic [5:0] tid; \
    logic [P-1:0] addr; \
  } coh_u_t;
`endif
