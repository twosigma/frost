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
 * cpu_ooo_pkg — type definitions shared between cpu_ooo and the glue submodules
 * extracted from it (branch resolution, misprediction recovery, flush control,
 * from_ex_comb synthesis, commit). These structs capture committed-branch and
 * mispredicted-branch metadata for the front-end recovery path; they are
 * internal to the OOO core and intentionally kept out of the global riscv_pkg.
 *
 * Widths use riscv_pkg::XLEN directly (cpu_ooo's XLEN parameter always resolves
 * to riscv_pkg::XLEN), so the package types match the module's usage exactly.
 */

package cpu_ooo_pkg;

  // Captured at the cycle a mispredicted branch is detected; drives the
  // commit-time recovery redirect, BTB update, and RAS restore.
  typedef struct packed {
    logic [riscv_pkg::ReorderBufferTagWidth-1:0] tag;
    logic has_checkpoint;
    logic [riscv_pkg::CheckpointIdWidth-1:0] checkpoint_id;
    logic [riscv_pkg::XLEN-1:0] redirect_pc;
    logic [riscv_pkg::XLEN-1:0] pc;
    logic [riscv_pkg::XLEN-1:0] branch_target;
    logic branch_taken;
    logic is_branch;
    logic is_call;
    logic is_return;
    logic is_jal;
    logic is_jalr;
    logic is_compressed;
  } mispredict_commit_capture_t;

  // Captured for a correctly-predicted branch commit; drives the BTB update
  // (no PC redirect) using registered commit data.
  typedef struct packed {
    logic [riscv_pkg::ReorderBufferTagWidth-1:0] tag;
    logic [riscv_pkg::CheckpointIdWidth-1:0] checkpoint_id;
    logic [riscv_pkg::XLEN-1:0] pc;
    logic [riscv_pkg::XLEN-1:0] branch_target;
    logic branch_taken;
    logic is_branch;
    logic is_jal;
    logic is_jalr;
    logic is_compressed;
  } correct_branch_commit_capture_t;

endpackage : cpu_ooo_pkg
