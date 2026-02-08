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

/*
 * Data Memory Arbiter - Muxes data memory interface signals from multiple sources
 *
 * This module arbitrates the data memory interface between four sources:
 *   1. FP64 load/store sequencer (highest priority - FLD/FSD high-word access)
 *   2. AMO unit write phase (atomic read-modify-write completion)
 *   3. AMO unit read phase (initial atomic load, uses registered EX-to-MA address)
 *   4. Normal EX stage combinational path (regular loads/stores, lowest priority)
 *
 * Priority Encoding (address mux):
 *   fp_mem_addr_override > amo.write_enable > amo_stall_for_amo > default (EX comb)
 *
 * Also generates:
 *   - Read enable: gated by pipeline stall, with FP64 high-word read override
 *   - MMIO load address/valid: from registered EX-to-MA path
 *   - fp_mem_write_active: indicates FP store is driving the bus (used by L0 cache)
 *
 * Related Modules:
 *   - cpu.sv: Instantiates this module
 *   - ex_stage.sv: Provides EX combinational memory signals
 *   - ma_stage.sv: Provides FP64 sequencer signals and registered EX-to-MA data
 *   - amo_unit.sv: Provides atomic memory operation write signals
 *   - l0_cache.sv: Consumes fp_mem_write_active for cache coherence
 */
module data_mem_arbiter #(
    parameter int unsigned XLEN = riscv_pkg::XLEN
) (
    // EX stage combinational path (normal loads/stores)
    input logic [XLEN-1:0] i_ex_comb_data_memory_address,
    input logic [XLEN-1:0] i_ex_comb_data_memory_write_data,
    input logic [     3:0] i_ex_comb_data_memory_byte_write_enable,

    // EX-to-MA registered path (for read enable gating and MMIO)
    input logic [XLEN-1:0] i_ex_to_ma_data_memory_address,
    input logic            i_ex_to_ma_is_load_instruction,
    input logic            i_ex_to_ma_is_lr,
    input logic            i_ex_to_ma_is_fp_load,

    // AMO unit interface
    input logic            i_amo_write_enable,
    input logic [XLEN-1:0] i_amo_write_data,
    input logic [XLEN-1:0] i_amo_write_address,
    input logic            i_amo_stall_for_amo,

    // FP64 load/store sequencer (from MA stage)
    input logic            i_fp_mem_addr_override,
    input logic [XLEN-1:0] i_fp_mem_address,
    input logic [XLEN-1:0] i_fp_mem_write_data,
    input logic [     3:0] i_fp_mem_byte_write_enable,

    // Stall signals
    input logic i_stall_for_mem_write,
    input logic i_pipeline_stall,

    // Data memory interface outputs
    output logic [XLEN-1:0] o_data_mem_addr,
    output logic [XLEN-1:0] o_data_mem_wr_data,
    output logic [     3:0] o_data_mem_per_byte_wr_en,
    output logic            o_data_mem_read_enable,

    // MMIO interface outputs
    output logic [XLEN-1:0] o_mmio_load_addr,
    output logic            o_mmio_load_valid,

    // FP write active indicator (needed by L0 cache)
    output logic o_fp_mem_write_active
);

  // FP store active when any byte write enable is set from FP sequencer
  assign o_fp_mem_write_active = |i_fp_mem_byte_write_enable;

  // Data memory address mux
  // During AMO stall, use from_ex_to_ma (current AMO address for read)
  // During AMO write, use captured address (stable even if from_ex_to_ma changes)
  // Otherwise use EX stage combinational signals for normal loads/stores
  assign o_data_mem_addr = i_fp_mem_addr_override ? i_fp_mem_address :
                           i_amo_write_enable ? i_amo_write_address :
                           i_amo_stall_for_amo ? i_ex_to_ma_data_memory_address :
                           i_ex_comb_data_memory_address;

  // Data memory write data mux
  assign o_data_mem_wr_data = o_fp_mem_write_active ? i_fp_mem_write_data :
                              i_amo_write_enable ? i_amo_write_data :
                              i_ex_comb_data_memory_write_data;

  // Use stall_for_mem_write (excludes CSR stall, no trap/mret gating) for memory
  // write enable. This avoids the trap_taken->stall critical path.
  // Functionally safe: non-store instructions have byte_write_enable = 0 anyway,
  // and using stall_sources is more conservative (blocks writes during any stall).
  assign o_data_mem_per_byte_wr_en = o_fp_mem_write_active ? i_fp_mem_byte_write_enable :
                                     i_amo_write_enable ? 4'b1111 :
                                     (i_ex_comb_data_memory_byte_write_enable &
                                      {4{~i_stall_for_mem_write}});

  // Allow FP64 high-word reads during FP mem stalls (FLD sequencing).
  logic fp_mem_read_enable;
  assign fp_mem_read_enable = i_fp_mem_addr_override && !o_fp_mem_write_active;
  assign o_data_mem_read_enable = ((i_ex_to_ma_is_load_instruction | i_ex_to_ma_is_lr) &
                                   ~i_pipeline_stall) |
                                  fp_mem_read_enable;

  // MMIO load interface (always from registered EX-to-MA path)
  assign o_mmio_load_addr = i_ex_to_ma_data_memory_address;
  assign o_mmio_load_valid = i_ex_to_ma_is_load_instruction |
                             i_ex_to_ma_is_lr |
                             i_ex_to_ma_is_fp_load;

  // ===========================================================================
  // Formal Verification Properties
  // ===========================================================================
`ifdef FORMAL

  always_comb begin
    // FP override highest priority: when FP addr override is active,
    // data memory address must be FP address.
    p_fp_highest_priority :
    assert (!i_fp_mem_addr_override || (o_data_mem_addr == i_fp_mem_address));

    // AMO write second priority: when no FP override but AMO write is active.
    p_amo_write_priority :
    assert (!(!i_fp_mem_addr_override && i_amo_write_enable) ||
        (o_data_mem_addr == i_amo_write_address));

    // AMO stall third priority: when no FP, no AMO write, but AMO stall.
    p_amo_stall_priority :
    assert (!(!i_fp_mem_addr_override && !i_amo_write_enable &&
        i_amo_stall_for_amo) ||
        (o_data_mem_addr == i_ex_to_ma_data_memory_address));

    // Default path: when none of the above, use EX comb address.
    p_default_path :
    assert (!(!i_fp_mem_addr_override && !i_amo_write_enable &&
        !i_amo_stall_for_amo) ||
        (o_data_mem_addr == i_ex_comb_data_memory_address));

    // FP write active = any FP byte enable set.
    p_fp_write_active : assert (o_fp_mem_write_active == |i_fp_mem_byte_write_enable);

    // Stall gates store byte enables: when stall and no FP/AMO override,
    // byte write enables must be zero.
    p_stall_gates_store :
    assert (!(i_stall_for_mem_write && !o_fp_mem_write_active &&
        !i_amo_write_enable) || (o_data_mem_per_byte_wr_en == 4'b0000));

    // AMO write gets all byte enables (when FP is not overriding).
    p_amo_all_bytes :
    assert (!(i_amo_write_enable && !o_fp_mem_write_active) ||
        (o_data_mem_per_byte_wr_en == 4'b1111));
  end

  // Cover properties
  always_comb begin
    cover_fp_priority : cover (i_fp_mem_addr_override);
    cover_amo_write : cover (!i_fp_mem_addr_override && i_amo_write_enable);
    cover_amo_stall : cover (!i_fp_mem_addr_override && !i_amo_write_enable && i_amo_stall_for_amo);
    cover_default : cover (!i_fp_mem_addr_override && !i_amo_write_enable && !i_amo_stall_for_amo);
    cover_read_enable : cover (o_data_mem_read_enable);
    cover_read_stalled : cover (!o_data_mem_read_enable && i_pipeline_stall);
  end

`endif  // FORMAL

endmodule : data_mem_arbiter
