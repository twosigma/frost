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
  Pipeline control unit managing stalls, flushes, and hazard resolution.
  This module orchestrates the overall pipeline flow by detecting and resolving hazards,
  particularly load-use dependencies and multi-cycle multiply/divide operations. It generates
  stall signals when hazards are detected, manages pipeline flushing on branches/traps/MRET,
  and coordinates reset operations including cache resets. The unit handles trap-related
  control: WFI stalls (broken by interrupts), trap entry flush, and MRET flush. It maintains
  pipeline state during stalls by preserving instruction and data values that would otherwise
  be lost due to memory read latencies. It also generates validation signals for testbench
  verification to track instruction flow through the pipeline stages.

  F extension support:
  - FP load-use hazard detection (FLW followed by FP instruction using that register)
  - Stall for multi-cycle FPU operations (FDIV.S, FSQRT.S)

  TIMING OPTIMIZATION: Load-use hazard detection is split into two parts to break the
  critical path. The "potential hazard" (dest matches source) is computed from fast
  registered signals, while cache_hit_on_load (which has a long path through forwarding,
  address calculation, and cache lookup) is registered separately. The final hazard
  decision combines these registered signals with minimal logic.
*/
module hazard_resolution_unit #(
    parameter int unsigned XLEN = 32,
    parameter int unsigned NUM_PIPELINE_STAGES = 6,
    // PC becomes valid at ID stage (stage index 2 in 0-indexed 6-stage pipeline:
    // IF=0, PD=1, ID=2...)
    // This offset from the final stage determines when o_pc_vld asserts
    parameter int unsigned PC_VALID_STAGE_OFFSET = 4,
    parameter int unsigned MMIO_ADDR = 32'h4000_0000,
    parameter int unsigned MMIO_SIZE_BYTES = 32'h28
) (
    input logic i_clk,
    input logic i_rst,
    // inputs
    input riscv_pkg::from_pd_to_id_t i_from_pd_to_id,
    input riscv_pkg::from_id_to_ex_t i_from_id_to_ex,
    input riscv_pkg::from_ex_comb_t i_from_ex_comb,
    input riscv_pkg::from_ex_to_ma_t i_from_ex_to_ma,
    input riscv_pkg::from_cache_t i_from_cache,
    // A extension: stall for AMO read-modify-write operations
    input logic i_stall_for_amo,
    // A extension: delayed AMO write enable for regfile bypass
    input logic i_amo_write_enable_delayed,
    // F extension: stall for multi-cycle FPU operations (FDIV, FSQRT)
    input logic i_stall_for_fpu,
    // FP64 load/store sequencing stall
    input logic i_stall_for_fp_mem,
    // FP forwarding pipeline stall (extra cycle for timing)
    input logic i_stall_for_fp_forward_pipeline,
    // Trap handling - lint suppression for false loop detection (see comment at o_pipeline_ctrl)
    /* verilator lint_off UNOPTFLAT */
    input logic i_trap_taken,
    input logic i_mret_taken,
    /* verilator lint_on UNOPTFLAT */
    input logic i_stall_for_wfi,
    // outputs
    // LINT SUPPRESSION: Some simulators report false combinational loops for packed structs
    // because they treat all fields as potentially interdependent. The actual logic has no
    // loop: stall_for_trap_check is computed WITHOUT trap/mret, breaking the dependency.
    /* verilator lint_off UNOPTFLAT */
    output riscv_pkg::pipeline_ctrl_t o_pipeline_ctrl,
    /* verilator lint_on UNOPTFLAT */
    // Separate output to break AMO combinational loop (not through packed struct).
    // This one IS needed as a separate port because o_stall_excluding_amo computation
    // doesn't include i_stall_for_amo, breaking: stall → AMO check → stall_for_amo → stall
    output logic o_stall_excluding_amo,
    // Stall signal for FPU that excludes FPU in-flight hazard.
    // The FPU must continue computing during a RAW hazard stall to resolve the hazard.
    output logic o_stall_for_fpu_input,
    // One-cycle pulse to trigger MMIO read side-effects (UART RX/FIFO pop).
    output logic o_mmio_read_pulse,
    // Stall signal for memory write path (same as stall_sources_for_trap, excludes CSR stall).
    output logic o_stall_for_mem_write,
    output logic o_rst_done,
    output logic o_vld,
    output logic o_pc_vld
);

  // ===========================================================================
  // Internal Pipeline Control Signals
  // ===========================================================================
  // These internal signals are used throughout the module and then assigned
  // to o_pipeline_ctrl at the end.
  // Lint suppression: False loop detection due to packed struct field interdependency.
  logic pipeline_reset;  // Combined reset (i_rst OR cache_reset_in_progress)
  /* verilator lint_off UNOPTFLAT */
  logic pipeline_stall;  // Final stall signal (gated by trap/mret)
  logic pipeline_flush;  // Flush signal for branch/trap/mret
  /* verilator lint_on UNOPTFLAT */

  // Registered control signals from previous cycle
  logic stall_registered;  // Stall signal from previous cycle
  logic is_load_registered;  // Was previous instruction an integer load/AMO?
  logic branch_taken_registered;  // Was a branch taken in previous cycle?
  logic trap_taken_registered;  // Was a trap taken in previous cycle?
  logic mret_taken_registered;  // Was MRET executed in previous cycle?

  // TIMING OPTIMIZATION: Register multiply "completing next cycle" signal to break critical path.
  // The multiplier exposes o_completing_next_cycle which is 1 when multiply starts.
  // Registering this gives us a signal that becomes 1 on the same cycle as valid_output,
  // allowing us to end the stall early without combinational dependency on multiplier_valid_output.
  logic multiply_completing_reg;
  logic stall_for_multiply_divide_optimized;

  // Load-use hazard detection - split into potential hazard (fast) and cache hit (slow)
  // to break critical timing path. See detailed comments below.
  logic load_potential_hazard;  // Combinational: load might cause hazard (fast path)
  logic amo_potential_hazard;  // Combinational: AMO might cause hazard (fast path)
  logic fp_load_potential_hazard;  // Combinational: FLW might cause hazard (F extension)
  logic load_potential_hazard_reg;  // Registered: potential hazard from previous cycle
  logic amo_potential_hazard_reg;  // Registered: potential hazard from previous cycle
  // FP load-use hazards are handled with an early, single-cycle stall.
  logic fpu_inflight_hazard_reg;  // Registered: FPU pipeline hazard
  logic load_use_hazard_detected;  // Current instruction uses data from load
  logic stall_for_load_use_hazard;  // Need to stall due to load-use dependency
  logic fp_load_use_hazard_early;  // Early stall for FP load-use (one-cycle bubble)
  logic fp_load_ma_hazard;  // FP load in MA hazards (multi-cycle FP ops)
  logic fp_load_ma_hazard_stall;  // One-cycle stall when FP load is in MA
  logic fp_load_hazard_seen;  // Tracks FP load-use stall to avoid repeats
  logic cache_hit_on_load_reg;

  // Track load/AMO instructions to detect back-to-back load-use hazards
  // This prevents consecutive hazards from causing issues and ends hazard stalls
  always_ff @(posedge i_clk)
    if (pipeline_reset) begin
      is_load_registered <= 1'b0;
    end else if (~pipeline_stall | stall_for_load_use_hazard) begin
      is_load_registered <= (i_from_ex_to_ma.is_load_instruction |
                             i_from_ex_to_ma.is_amo_instruction) &
                           ~is_load_registered &
                            stall_for_load_use_hazard;
    end

  // Register multiply "completing next cycle" signal to predict completion
  // This breaks the critical timing path from multiplier to stall logic
  always_ff @(posedge i_clk)
    if (pipeline_reset) multiply_completing_reg <= 1'b0;
    else multiply_completing_reg <= i_from_ex_comb.multiply_completing_next_cycle;

  // Optimized stall for multiply/divide:
  // - Multiply: use registered prediction signal (breaks critical path, 1-cycle stall)
  // - Divide: use ALU's stall signal (takes 17+ cycles)
  assign stall_for_multiply_divide_optimized =
      (i_from_id_to_ex.is_multiply & ~multiply_completing_reg) |
      (i_from_id_to_ex.is_divide & i_from_ex_comb.stall_for_multiply_divide);

  // Hazard detection and stall generation
  // Priority: multiply/divide stalls take precedence over load-use stalls
  // Use optimized multiply stall for correct behavior with timing optimization
  //
  // CACHE-HIT OPTIMIZATION: Only stall on load-use hazard when the cache misses.
  //
  // When a potential load-use hazard is detected (load dest matches a following
  // instruction's source), the registered cache_hit_on_load_reg signal is checked.
  // If the cache hit, the load data is already available for forwarding and no
  // stall is needed. If the cache missed, a one-cycle stall is inserted to wait
  // for the memory data to become available.
  logic load_use_hazard_int_amo;
  assign load_use_hazard_int_amo = load_potential_hazard_reg || amo_potential_hazard_reg;

  assign cache_hit_on_load_reg = i_from_cache.cache_hit_on_load_reg;
  assign load_use_hazard_detected =
      load_use_hazard_int_amo && ~is_load_registered && ~cache_hit_on_load_reg;
  assign stall_for_load_use_hazard = load_use_hazard_detected &
                                     ~stall_for_multiply_divide_optimized;
  // FP load-use: insert a one-cycle bubble so the load data is stable before EX capture.
  assign fp_load_use_hazard_early = fp_load_potential_hazard && ~fp_load_hazard_seen;
  assign fp_load_ma_hazard_stall = fp_load_ma_hazard && ~fp_load_hazard_seen;

  // Track FP load hazards even during the bubble so we don't stall repeatedly.
  always_ff @(posedge i_clk)
    if (pipeline_reset) begin
      fp_load_hazard_seen <= 1'b0;
    end else if (~pipeline_stall || fp_load_use_hazard_early || fp_load_ma_hazard_stall) begin
      fp_load_hazard_seen <= fp_load_potential_hazard | fp_load_ma_hazard;
    end

  // Gate the FPU stall by whether the instruction in EX is an FP compute operation.
  // This matches the integer multiply/divide pattern where stall is gated by is_divide.
  // Without this gating, the FPU stall would block pipeline advancement even for non-FP
  // instructions, preventing results in MA/WB from being written to the regfile.
  // Use is_fp_compute (not fpu_entering_is_pipelined) to include ALL FP ops that use the
  // FPU including single-cycle operations like FMV.W.X which still need a few cycles.
  logic fpu_stall_gated;
  assign fpu_stall_gated = i_from_id_to_ex.is_fp_compute & i_stall_for_fpu;

  // ===========================================================================
  // CSR Read Stall (for timing optimization)
  // ===========================================================================
  // CSR read data is registered in csr_file.sv to break timing path.
  // This requires a one-cycle stall for CSR instructions to wait for data.
  // The csr_read_waiting flag tracks whether we've waited one cycle for this
  // CSR instruction. It's set when we first see a CSR and cleared when the
  // instruction advances (stall releases).
  logic csr_read_waiting;
  logic stall_for_csr_read;

  always_ff @(posedge i_clk)
    if (pipeline_reset) csr_read_waiting <= 1'b0;
    else if (i_from_id_to_ex.is_csr_instruction && ~csr_read_waiting) csr_read_waiting <= 1'b1;
    else csr_read_waiting <= 1'b0;

  // Stall on the first cycle of CSR instruction (before data is ready)
  assign stall_for_csr_read = i_from_id_to_ex.is_csr_instruction && ~csr_read_waiting;

  // MMIO load handling: insert a two-cycle bubble and pulse read side-effects once.
  logic mmio_load_in_ma;
  logic mmio_load_stall;
  logic mmio_read_pulse;
  logic [1:0] mmio_stall_count;
  assign mmio_load_in_ma =
      (i_from_ex_to_ma.is_load_instruction | i_from_ex_to_ma.is_lr |
       i_from_ex_to_ma.is_fp_load) &&
      (i_from_ex_to_ma.data_memory_address >= MMIO_ADDR) &&
      (i_from_ex_to_ma.data_memory_address < (MMIO_ADDR + MMIO_SIZE_BYTES));
  assign mmio_load_stall = mmio_load_in_ma && (mmio_stall_count < 2);
  assign mmio_read_pulse = mmio_load_in_ma && (mmio_stall_count == 2'b0);

  always_ff @(posedge i_clk)
    if (pipeline_reset || pipeline_flush) begin
      mmio_stall_count <= 2'b0;
    end else if (~pipeline_stall) begin
      mmio_stall_count <= 2'b0;
    end else if (mmio_load_in_ma && (mmio_stall_count < 2)) begin
      mmio_stall_count <= mmio_stall_count + 1'b1;
    end

  // Combine all stall sources (before trap/mret gating, for trap unit to use without loop)
  // Use optimized multiply stall for correct behavior with timing optimization
  // F extension: fpu_inflight_hazard uses combinational signal since it compares registered values
  // and needs to clear immediately when the FPU operation completes
  //
  // stall_sources_for_trap excludes CSR read stall - used for trap check and memory write path.
  // When a trap fires, the CSR instruction will be flushed anyway, so blocking
  // the trap for CSR read data is unnecessary. This allows traps to fire
  // immediately when interrupt_pending becomes 1, without waiting for a
  // potentially stalling CSR instruction to complete.
  //
  // Use reduction-OR to encourage a balanced tree and trim OR-chain depth.
  // Forward declarations (moved before first use to avoid Vivado warnings)
  logic fpu_inflight_hazard;
  logic fpu_single_to_pipelined_hazard;
  logic fp_to_int_to_int_to_fp_hazard;
  logic csr_fflags_read_hazard;

  logic stall_sources_for_trap;
  assign stall_sources_for_trap = |{
      stall_for_multiply_divide_optimized,
      stall_for_load_use_hazard,
      fp_load_use_hazard_early,
      fp_load_ma_hazard_stall,
      i_stall_for_amo,
      i_stall_for_fp_mem,
      i_stall_for_fp_forward_pipeline,
      fpu_stall_gated,
      fpu_inflight_hazard,
      fpu_single_to_pipelined_hazard,
      fp_to_int_to_int_to_fp_hazard,
      csr_fflags_read_hazard,
      mmio_load_stall,
      i_stall_for_wfi
  };

  // Full stall sources including CSR read stall (for pipeline stall generation)
  logic stall_sources;
  assign stall_sources = stall_sources_for_trap | stall_for_csr_read;

  // Memory write path uses stall_sources_for_trap (same logic, no replication needed)
  assign o_stall_for_mem_write = stall_sources_for_trap;

  // ===========================================================================
  // Internal Pipeline Control Signal Generation
  // ===========================================================================
  // Generate internal signals first, then assign to output struct at the end.
  // Note: WFI stall is included but trap_taken/mret_taken override it (break WFI on interrupt)
  assign pipeline_reset = i_rst | i_from_cache.cache_reset_in_progress;
  assign pipeline_stall = stall_sources & ~i_trap_taken & ~i_mret_taken;

  // Reset is complete when cache initialization finishes
  assign o_rst_done = ~i_from_cache.cache_reset_in_progress;

  /*
    Preserve fetched instruction and data during stalls.
    Required due to one-cycle memory read latency - when pipeline stalls,
    we must maintain the same instruction/data for multiple cycles.
    Clear on flush to prevent just_unstalled from triggering after a flush -
    after flush, we should use live values, not saved values from before flush.
  */
  always_ff @(posedge i_clk)
    stall_registered <= (pipeline_reset || pipeline_flush) ? 1'b0 : pipeline_stall;

  // Register branch taken signal for pipeline flush control
  // With 6-stage pipeline, flush for 2 cycles and observe in both PD and ID stages
  //
  // CRITICAL: Clear registered signals during stall to prevent spurious flush after stall.
  // Problem scenario without this fix:
  //   1. Misprediction in cycle N, branch_taken=1, flush=1
  //   2. Stall begins in N+1, flush blocked by ~stall, but branch_taken_registered=1 held
  //   3. Stall ends in N+3, stale branch_taken_registered=1 causes flush=1
  //   4. Correct instruction arriving from memory is incorrectly discarded!
  // Fix: Clear registered signals during stall so they don't persist and cause late flushes.
  always_ff @(posedge i_clk)
    if (pipeline_reset) begin
      branch_taken_registered <= 1'b0;
    end else if (pipeline_stall) begin
      // Clear during stall to prevent stale flush after stall ends
      branch_taken_registered <= 1'b0;
    end else begin
      branch_taken_registered <= i_from_ex_comb.branch_taken;
    end

  // Register trap/mret signals to extend flush (same as branches)
  // Without this, instructions in IF/PD stages when trap/mret occurs can proceed through
  // the pipeline and incorrectly write to registers after the trap returns
  // Clear during stall (same fix as branch_taken_registered above)
  always_ff @(posedge i_clk)
    if (pipeline_reset) begin
      trap_taken_registered <= 1'b0;
      mret_taken_registered <= 1'b0;
    end else if (pipeline_stall) begin
      // Clear during stall to prevent stale flush after stall ends
      trap_taken_registered <= 1'b0;
      mret_taken_registered <= 1'b0;
    end else begin
      trap_taken_registered <= i_trap_taken;
      mret_taken_registered <= i_mret_taken;
    end

  // Need to flush pipeline for 2 cycles following a taken branch/jump, trap, or MRET
  // This clears out instructions that were fetched before the branch/jump/trap resolved
  // All branches and jumps (JAL, JALR, conditional) are now resolved in EX stage
  // Trap/MRET also cause flush: need to discard instructions in PD and ID stages
  // Flush is observed in both PD and ID stages
  assign pipeline_flush = (i_from_ex_comb.branch_taken | branch_taken_registered |
                           i_trap_taken | i_mret_taken |
                           trap_taken_registered | mret_taken_registered) &
                          ~pipeline_stall;

  // ===========================================================================
  // Load-use and AMO-use Hazard Detection (Timing-Optimized)
  // ===========================================================================
  // CRITICAL PATH OPTIMIZATION:
  // The original implementation computed cache_hit_on_load and combined it with
  // hazard conditions in a single cycle, creating a long combinational path:
  //   rs1 → regfile → forwarding → address_calc → cache_lookup →
  //   cache_hit → hazard_detect → register
  //
  // The optimized approach splits this into:
  //   Cycle N: Compute potential_hazard (fast) and cache_hit (slow) in PARALLEL, register both
  //   Cycle N+1: Combine registered values: actual_hazard = potential_hazard_reg && ~cache_hit_reg
  //
  // This breaks the critical path because:
  //   - potential_hazard uses only registered signals (is_load, dest_reg, source_reg_early)
  //   - cache_hit_on_load (the slow signal) ends at a register, not feeding into more logic
  //   - The final hazard decision in cycle N+1 is just one AND gate
  //
  // Behavior is preserved: stall decision happens at the same time, just computed differently.
  // ===========================================================================

  // Potential hazard detection (FAST PATH - uses only registered signals)
  // These signals are available early in the cycle because they come from pipeline registers.
  logic dest_matches_source;
  assign dest_matches_source =
      i_from_id_to_ex.instruction.dest_reg == i_from_pd_to_id.source_reg_1_early ||
      i_from_id_to_ex.instruction.dest_reg == i_from_pd_to_id.source_reg_2_early;

  assign load_potential_hazard =
      i_from_id_to_ex.is_load_instruction &&
      i_from_id_to_ex.instruction.dest_reg != 0 &&
      dest_matches_source;

  assign amo_potential_hazard =
      i_from_id_to_ex.is_amo_instruction &&
      i_from_id_to_ex.instruction.dest_reg != 0 &&
      dest_matches_source;

  // ===========================================================================
  // FP Hazard Detection (submodule)
  // ===========================================================================

  hru_fp_hazards u_fp_hazards (
      .i_from_pd_to_id,
      .i_from_id_to_ex,
      .i_from_ex_comb,
      .i_from_ex_to_ma,
      .i_stall_registered(stall_registered),
      .o_fp_load_potential_hazard(fp_load_potential_hazard),
      .o_fpu_inflight_hazard(fpu_inflight_hazard),
      .o_fpu_single_to_pipelined_hazard(fpu_single_to_pipelined_hazard),
      .o_fp_to_int_to_int_to_fp_hazard(fp_to_int_to_int_to_fp_hazard),
      .o_fp_load_ma_hazard(fp_load_ma_hazard),
      .o_csr_fflags_read_hazard(csr_fflags_read_hazard)
  );

  // Register the potential hazards for timing optimization.
  // The actual hazard decision combines these with the combinational cache_hit_on_load.
  always_ff @(posedge i_clk) begin
    if (pipeline_reset || pipeline_flush) begin
      load_potential_hazard_reg <= 1'b0;
      amo_potential_hazard_reg  <= 1'b0;
      fpu_inflight_hazard_reg   <= 1'b0;
    end else if (~pipeline_stall) begin
      load_potential_hazard_reg <= load_potential_hazard;
      amo_potential_hazard_reg  <= amo_potential_hazard;
      fpu_inflight_hazard_reg   <= fpu_inflight_hazard;
    end
  end

  // Validation signals for testbench - track instruction progress through pipeline
  // This shift register moves a '1' through each stage, indicating valid instruction flow.
  // Uses explicit shift operator for clarity: shifts left, inserting 1 at LSB each cycle.
  logic [NUM_PIPELINE_STAGES-1:0] validation_shift_register;
  always_ff @(posedge i_clk)
    if (pipeline_reset) validation_shift_register <= '0;
    else if (~pipeline_stall)
      validation_shift_register <= {validation_shift_register[NUM_PIPELINE_STAGES-2:0], 1'b1};

  // Output valid when instruction reaches final stage and pipeline not stalled
  assign o_vld = validation_shift_register[NUM_PIPELINE_STAGES-1] & ~pipeline_stall;
  // PC valid occurs earlier in pipeline (at ID stage)
  assign o_pc_vld = validation_shift_register[NUM_PIPELINE_STAGES-PC_VALID_STAGE_OFFSET] &
                   ~pipeline_stall;

  // ===========================================================================
  // Output Struct Assignment
  // ===========================================================================
  // Assign internal signals to output struct. This keeps all output assignments
  // in one place and avoids Verilator UNOPTFLAT warnings from using output
  // struct fields within the same module.
  assign o_pipeline_ctrl.reset = pipeline_reset;
  assign o_pipeline_ctrl.stall = pipeline_stall;
  assign o_pipeline_ctrl.flush = pipeline_flush;
  assign o_pipeline_ctrl.stall_registered = stall_registered;
  assign o_pipeline_ctrl.stall_for_load_use_hazard = stall_for_load_use_hazard;
  assign o_pipeline_ctrl.stall_for_fp_load_ma_hazard = fp_load_ma_hazard_stall;
  // F extension: expose FPU inflight hazard for EX stage to detect stall exit
  assign o_pipeline_ctrl.stall_for_fpu_inflight_hazard = fpu_inflight_hazard;
  // Stall check for trap unit - doesn't include trap/mret gating to break combinatorial loop.
  // Uses stall_sources_for_trap which excludes CSR stall (CSR will be flushed on trap anyway).
  assign o_pipeline_ctrl.stall_for_trap_check = stall_sources_for_trap;
  // Expose raw hazard detection for forwarding unit.
  assign o_pipeline_ctrl.load_use_hazard_detected = load_use_hazard_detected;
  // Stall sources excluding AMO - breaks combinational loop with AMO unit.
  // AMO unit checks this to see if there are other stalls before starting an AMO operation.
  // This excludes i_stall_for_amo, preventing: stall → AMO check → stall_for_amo → stall
  // NOTE: This is a separate output port (not through packed struct) to avoid false loop detection.
  assign o_stall_excluding_amo = stall_for_multiply_divide_optimized |
                                  stall_for_load_use_hazard |
                                  fp_load_use_hazard_early |
                                  fp_load_ma_hazard_stall |
                                  i_stall_for_fp_mem |
                                  i_stall_for_fp_forward_pipeline |
                                  fpu_stall_gated |
                                  fpu_inflight_hazard |
                                  fpu_single_to_pipelined_hazard |
                                  fp_to_int_to_int_to_fp_hazard |
                                  csr_fflags_read_hazard |
                                  stall_for_csr_read |
                                  mmio_load_stall |
                                  i_stall_for_wfi;

  // Stall for FPU input - excludes fpu_inflight_hazard so FPU can continue computing
  // to resolve the hazard. Similar to how integer multiply continues during multiply stall.
  // Note: Do NOT gate by trap/mret to avoid combinational loop. FPU will be reset on flush anyway.
  assign o_stall_for_fpu_input = stall_for_multiply_divide_optimized |
                                  stall_for_load_use_hazard |
                                  fp_load_use_hazard_early |
                                  fp_load_ma_hazard_stall |
                                  i_stall_for_amo |
                                  i_stall_for_fp_mem |
                                  i_stall_for_fpu |
                                  fp_to_int_to_int_to_fp_hazard |
                                  stall_for_csr_read |
                                  mmio_load_stall |
                                  i_stall_for_wfi;
  // MMIO read pulse for side-effecting registers (UART RX, FIFO).
  assign o_mmio_read_pulse = mmio_read_pulse;
  // Force regfile write when AMO result is ready (bypass stall_registered)
  assign o_pipeline_ctrl.amo_wb_write_enable = i_amo_write_enable_delayed;
  // Expose registered trap/mret signals for IF stage timing optimization
  assign o_pipeline_ctrl.trap_taken_registered = trap_taken_registered;
  assign o_pipeline_ctrl.mret_taken_registered = mret_taken_registered;

  // ===========================================================================
  // Formal Verification Properties
  // ===========================================================================
  // Only compiled when FORMAL is defined (SymbiYosys sets this automatically).
  // These assertions are invisible to synthesis and simulation.
`ifdef FORMAL

  // Assume reset is active at startup so registers start in known state.
  initial assume (i_rst);

  // Track whether we've had at least 2 clock edges (for $past safety)
  reg f_past_valid;
  initial f_past_valid = 1'b0;
  always @(posedge i_clk) f_past_valid <= 1'b1;

  // Count consecutive unstalled, non-reset cycles for shift register fill contract
  reg [3:0] f_unstalled_count;
  initial f_unstalled_count = 4'd0;
  always @(posedge i_clk)
    if (i_rst || pipeline_reset || pipeline_stall) f_unstalled_count <= 4'd0;
    else if (f_unstalled_count < 4'd15) f_unstalled_count <= f_unstalled_count + 4'd1;

  always @(posedge i_clk) begin
    // =====================================================================
    // Sequential properties (need valid $past) - KEPT (non-tautological)
    // =====================================================================
    if (f_past_valid && !i_rst && $past(!i_rst)) begin
      // Property 2: Reset clears all registered hazard state.
      if ($past(pipeline_reset)) begin
        p2a_reset_load_hazard : assert (!load_potential_hazard_reg);
        p2b_reset_amo_hazard : assert (!amo_potential_hazard_reg);
        p2c_reset_branch_reg : assert (!branch_taken_registered);
        p2d_reset_trap_reg : assert (!trap_taken_registered);
        p2e_reset_mret_reg : assert (!mret_taken_registered);
        p2f_reset_stall_reg : assert (!stall_registered);
        p2g_reset_validation : assert (validation_shift_register == '0);
        p2h_reset_is_load_reg : assert (!is_load_registered);
      end

      // Property 3: Flush clears hazard registers.
      if ($past(pipeline_flush) && !$past(pipeline_reset)) begin
        p3a_flush_clears_load : assert (!load_potential_hazard_reg);
        p3b_flush_clears_amo : assert (!amo_potential_hazard_reg);
      end

      // Property 4: Stale flush prevention (critical documented fix).
      // During a stall, branch/trap/mret registered signals must be cleared
      // to prevent spurious flushes when the stall ends.
      if ($past(pipeline_stall) && !$past(pipeline_reset)) begin
        p4a_stall_clears_branch : assert (!branch_taken_registered);
        p4b_stall_clears_trap : assert (!trap_taken_registered);
        p4c_stall_clears_mret : assert (!mret_taken_registered);
      end

      // =====================================================================
      // Contract-style properties (replace tautological p1/p5-p11)
      // =====================================================================

      // Load-use stall contract: If a load was in EX with dest != 0 matching
      // a PD source reg (registered as potential hazard), and no cache hit or
      // back-to-back prevention or multiply/divide precedence, then pipeline stalls.
      // Falsifiable: changing hazard detection logic would break this.
      if ($past(
              load_potential_hazard
          ) && !$past(
              pipeline_stall
          ) && !$past(
              pipeline_reset
          ) && !$past(
              pipeline_flush
          )) begin
        p_load_use_stall_contract :
        assert (load_use_hazard_detected ||  // hazard detected (will stall unless mul/div)
        is_load_registered ||  // back-to-back prevention fired
        cache_hit_on_load_reg  // cache hit avoided the stall
        );
      end

      // Branch flush duration contract: If branch_taken fires and no stall,
      // pipeline_flush is asserted. Tests the 2-cycle flush requirement.
      if ($past(
              i_from_ex_comb.branch_taken
          ) && !$past(
              pipeline_stall
          ) && !$past(
              pipeline_reset
          )) begin
        p_branch_flush_contract : assert (pipeline_flush || pipeline_stall);
      end

      // MMIO stall bounded contract: When the counter is at its max (2),
      // mmio_load_stall is guaranteed to be false, ending the stall.
      p_mmio_terminates : assert (!(mmio_stall_count == 2'd2) || !mmio_load_stall);

      // CSR stall bounded contract: After one cycle of CSR stall,
      // csr_read_waiting is set and the stall ends.
      if ($past(stall_for_csr_read) && !$past(pipeline_reset)) begin
        p_csr_bounded : assert (csr_read_waiting);
      end
    end

    // =====================================================================
    // Combinational contract properties (active outside reset)
    // =====================================================================
    if (!i_rst) begin
      // Stall-flush mutex contract: pipeline cannot both stall and flush.
      // Not tautological because flush has a ~pipeline_stall term that could
      // be incorrectly removed during refactoring.
      p_stall_flush_mutex : assert (!(pipeline_stall && pipeline_flush));

      // Trap override contract: If stall sources are active this cycle but
      // trap_taken fires this cycle, pipeline_stall must be deasserted.
      // Same-cycle check (all signals are current-cycle combinational).
      p_trap_override_contract : assert (!(stall_sources && i_trap_taken) || !pipeline_stall);

      // MMIO counter bounded contract: counter never exceeds 2.
      p_mmio_bounded : assert (mmio_stall_count <= 2'd2);

      // Valid output contract: o_vld requires pipeline not stalled AND
      // shift register full. Falsifiable: changing o_vld assign breaks it.
      p_vld_contract :
      assert (!o_vld || (!pipeline_stall && validation_shift_register[NUM_PIPELINE_STAGES-1]));

      // FP load hazard no-repeat contract: once we've seen the hazard,
      // the early stall doesn't re-fire.
      p_fp_no_repeat_contract : assert (!fp_load_hazard_seen || !fp_load_use_hazard_early);
    end

    // Validation shift register fill contract: After NUM_PIPELINE_STAGES
    // unstalled cycles post-reset, o_vld can assert.
    if (!i_rst && f_unstalled_count >= NUM_PIPELINE_STAGES[3:0]) begin
      p_shift_reg_fill : assert (validation_shift_register == '1);
    end
  end

  // Cover properties - prove these scenarios are reachable
  always @(posedge i_clk) begin
    if (!i_rst) begin
      cover_load_use_stall : cover (stall_for_load_use_hazard);
      cover_branch_flush : cover (pipeline_flush && branch_taken_registered);
      cover_trap_flush : cover (pipeline_flush && i_trap_taken);
      cover_mret_flush : cover (pipeline_flush && i_mret_taken);
      cover_multiply_stall : cover (stall_for_multiply_divide_optimized);
      cover_mmio_pulse : cover (mmio_read_pulse);
      cover_csr_stall : cover (stall_for_csr_read);
      cover_vld_asserts : cover (o_vld);
      cover_fpu_stall : cover (fpu_stall_gated);
      cover_cache_hit_avoids_stall :
      cover (cache_hit_on_load_reg && load_potential_hazard_reg && !load_use_hazard_detected);
      cover_trap_overrides_stall : cover (stall_sources && i_trap_taken && !pipeline_stall);
      cover_mmio_terminates : cover (mmio_stall_count == 2'd2 && !mmio_load_stall);
    end
  end

`endif  // FORMAL

endmodule : hazard_resolution_unit
