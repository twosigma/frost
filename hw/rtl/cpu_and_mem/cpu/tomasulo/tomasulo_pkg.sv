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
 * Tomasulo Out-of-Order Execution Package
 *
 * This package contains all type definitions, enumerations, parameters,
 * and data structures for the Tomasulo OOO execution engine in FROST.
 *
 * Contents:
 * =========
 *   Section 1: Core Parameters (ROB, RS, LQ, SQ, Checkpoint depths)
 *   Section 2: Functional Unit Enumeration and RS Assignment
 *   Section 3: ROB Entry Structure (including rob_branch_update_t)
 *   Section 4: RAT Entry and Checkpoint Structures
 *   Section 4b: Memory Operation Size Encoding (mem_size_e)
 *   Section 5: Reservation Station Entry Structure
 *   Section 6: Load Queue Entry Structure
 *   Section 7: Store Queue Entry Structure
 *   Section 8: CDB (Common Data Bus) Structures
 *   Section 9: Dispatch Interface Structures
 *   Section 11: Instruction Routing Table (get_rs_type, has_*_dest, uses_fp_rs*)
 *   Section 12: Control Flow Classification Helpers
 *   Section 13: Predicted Target Policy Documentation
 *
 * Design Notes:
 * =============
 *   - All widths are parameterized for flexibility
 *   - FLEN (64-bit) used for operand/result widths to support D extension
 *   - Unified INT/FP ROB design with dest_rf flag
 *   - Separate INT RAT and FP RAT with shared checkpoint storage
 *
 * Usage:
 * ======
 *   All Tomasulo modules should import this package:
 *     import tomasulo_pkg::*;
 *   Or reference specific types:
 *     tomasulo_pkg::rob_entry_t entry;
 */
package tomasulo_pkg;

  import riscv_pkg::*;

  // ===========================================================================
  // Section 1: Core Parameters
  // ===========================================================================
  // Configurable depths for all major structures. Power-of-2 sizes simplify
  // circular buffer pointer arithmetic.

  // Reorder Buffer parameters
  localparam int unsigned RobDepth = 32;  // Number of ROB entries (power of 2)
  localparam int unsigned RobTagWidth = $clog2(RobDepth);  // 5 bits for 32-entry ROB

  // Reservation Station depths (per RS type)
  localparam int unsigned IntRsDepth = 8;  // Integer ALU operations
  localparam int unsigned MulRsDepth = 4;  // Multiply/divide operations
  localparam int unsigned MemRsDepth = 8;  // Load/store operations
  localparam int unsigned FpRsDepth = 6;  // FP add/sub/cmp/cvt/classify/sgnj
  localparam int unsigned FmulRsDepth = 4;  // FP multiply/FMA (3 sources)
  localparam int unsigned FdivRsDepth = 2;  // FP divide/sqrt (long latency)

  // Memory queue depths
  localparam int unsigned LqDepth = 8;  // Load queue entries
  localparam int unsigned SqDepth = 8;  // Store queue entries

  // Checkpoint parameters
  localparam int unsigned NumCheckpoints = 4;  // For branch speculation recovery
  localparam int unsigned CheckpointIdWidth = $clog2(NumCheckpoints);  // 2 bits

  // Register file sizes
  localparam int unsigned NumIntRegs = 32;  // x0-x31
  localparam int unsigned NumFpRegs = 32;  // f0-f31
  localparam int unsigned RegAddrWidth = 5;  // $clog2(32)

  // Data widths (from riscv_pkg)
  // XLEN = 32, FpWidth = 64 (FLEN)
  localparam int unsigned FLEN = FpWidth;  // 64 bits for D extension

  // CDB parameters
  localparam int unsigned NumCdbLanes = 1;  // Single CDB (future expansion)
  localparam int unsigned NumFus = 7;  // ALU, MUL, DIV, MEM, FP_ADD, FP_MUL, FP_DIV

  // ===========================================================================
  // Section 2: Functional Unit Enumeration and RS Assignment
  // ===========================================================================
  // Identifies which functional unit an instruction uses. Used for RS routing
  // at dispatch and CDB arbitration at completion.

  // Functional unit identifier (for RS routing and CDB arbitration)
  typedef enum logic [2:0] {
    FU_ALU    = 3'd0,  // Integer ALU (ADD, SUB, AND, OR, XOR, SLT, branches)
    FU_MUL    = 3'd1,  // Integer multiplier
    FU_DIV    = 3'd2,  // Integer divider
    FU_MEM    = 3'd3,  // Load/store unit (both INT and FP)
    FU_FP_ADD = 3'd4,  // FP adder (add/sub/cmp/cvt/classify/sgnj)
    FU_FP_MUL = 3'd5,  // FP multiplier (mul/FMA)
    FU_FP_DIV = 3'd6   // FP divider/sqrt (long latency)
  } fu_type_e;

  // Reservation station type (for dispatch routing)
  typedef enum logic [2:0] {
    RS_INT  = 3'd0,  // INT_RS: Integer ALU ops, branches, CSR
    RS_MUL  = 3'd1,  // MUL_RS: MUL/DIV
    RS_MEM  = 3'd2,  // MEM_RS: All loads/stores (INT and FP)
    RS_FP   = 3'd3,  // FP_RS: FP add/sub/cmp/cvt/classify/sgnj
    RS_FMUL = 3'd4,  // FMUL_RS: FP mul/FMA (3 sources)
    RS_FDIV = 3'd5,  // FDIV_RS: FP div/sqrt
    RS_NONE = 3'd6   // No RS needed (e.g., WFI, FENCE dispatches to ROB only)
  } rs_type_e;

  // ===========================================================================
  // Section 3: ROB Entry Structure
  // ===========================================================================
  // Unified ROB entry supporting both integer and floating-point instructions.
  // ~120 bits per entry.

  // Exception cause codes specific to Tomasulo (extends riscv_pkg causes)
  // Width: 5 bits covers synchronous exception causes 0-31 (RISC-V max is 11 for ecall M-mode)
  // NOTE: Interrupts are handled separately by the trap unit, not stored in ROB.
  // The ROB only tracks synchronous exceptions from instruction execution.
  //
  // Mapping from riscv_pkg 32-bit constants to ROB 5-bit cause:
  //   exc_cause = riscv_pkg::Exc*[4:0]  (low 5 bits)
  //   Examples: ExcBreakpoint (3) -> 5'd3, ExcLoadAddrMisalign (4) -> 5'd4
  // The mcause CSR's interrupt bit (bit 31) is never set for ROB-tracked exceptions.
  // When committing an exception, the trap unit constructs the full mcause value.
  localparam int unsigned ExcCauseWidth = 5;

  // Typedef for exception cause to make the encoding explicit
  typedef logic [ExcCauseWidth-1:0] exc_cause_t;

  // ROB entry structure
  typedef struct packed {
    // Core fields
    logic       valid;      // Entry is allocated
    logic       done;       // Execution complete
    logic       exception;  // Exception occurred
    exc_cause_t exc_cause;  // Exception cause code

    // Instruction identification
    logic [XLEN-1:0] pc;  // Instruction PC (for mepc)

    // Destination register
    logic dest_rf;  // 0=INT (x-reg), 1=FP (f-reg)
    logic [RegAddrWidth-1:0] dest_reg;  // Architectural destination (rd)
    logic dest_valid;  // Has destination register (not stores/branches w/o link)

    // Result value (FLEN-wide to support FP double)
    // For JAL: set to zero-extended link_addr at dispatch with done=1 (target known)
    // For JALR: set to zero-extended link_addr at dispatch with done=0, marked done=1 via rob_branch_update_t
    // For other instructions: set by CDB broadcast (rob_cdb_write_t) when execution completes
    // NOTE: When storing XLEN values, zero-extend to FLEN: value = {{FLEN-XLEN{1'b0}}, xlen_result}
    logic [FLEN-1:0] value;  // Result value

    // Store tracking
    logic is_store;     // Is store instruction
    logic is_fp_store;  // Is FP store (FSW/FSD)

    // Branch tracking (for speculation recovery)
    // NOTE: is_branch should be set for conditional branches AND JAL/JALR
    // so checkpoint allocation and misprediction recovery apply uniformly
    logic            is_branch;         // Is branch/jump instruction (BEQ/BNE/.../JAL/JALR)
    logic            branch_taken;      // Actual branch outcome
    logic [XLEN-1:0] branch_target;     // Actual branch target
    logic            predicted_taken;   // BTB prediction (for misprediction detection)
    logic [XLEN-1:0] predicted_target;  // BTB/RAS predicted target
    logic            is_call;           // Is call (for RAS recovery)
    logic            is_return;         // Is return (for RAS recovery)
    logic            is_jal;            // JAL instruction (can mark done=1 at dispatch)
    logic            is_jalr;           // JALR instruction (must wait for execute)

    // Checkpoint index (for branches that allocated a checkpoint)
    logic                         has_checkpoint;  // This branch has a checkpoint
    logic [CheckpointIdWidth-1:0] checkpoint_id;   // Checkpoint index

    // FP exception flags (accumulated at commit)
    fp_flags_t fp_flags;  // NV, DZ, OF, UF, NX

    // Serializing instruction flags
    logic is_csr;      // CSR instruction (execute at commit)
    logic is_fence;    // FENCE (drain SQ at commit)
    logic is_fence_i;  // FENCE.I (drain SQ, flush pipeline)
    logic is_wfi;      // WFI (stall at head until interrupt)
    logic is_mret;     // MRET (restore mstatus, redirect to mepc)
    logic is_amo;      // AMO (execute at head with SQ empty)
    logic is_lr;       // LR (sets reservation)
    logic is_sc;       // SC (checks reservation at head)
  } rob_entry_t;

  // ROB interface signals (for module ports)
  typedef struct packed {
    logic                    alloc_valid;       // Request ROB allocation
    logic [XLEN-1:0]         pc;
    logic                    dest_rf;
    logic [RegAddrWidth-1:0] dest_reg;
    logic                    dest_valid;
    logic                    is_store;
    logic                    is_fp_store;
    logic                    is_branch;
    logic                    predicted_taken;
    logic [XLEN-1:0]         predicted_target;  // BTB/RAS predicted target
    logic                    is_call;
    logic                    is_return;
    // JAL/JALR: link_addr is the pre-computed PC+2/PC+4 result for rd
    // - JAL: dispatch sets value={{FLEN-XLEN{1'b0}}, link_addr}, done=1 (target known)
    // - JALR: dispatch sets value={{FLEN-XLEN{1'b0}}, link_addr}, done=0 (target resolved in execute)
    // NOTE: link_addr is XLEN (32-bit), must be zero-extended to FLEN (64-bit) when assigning to value
    logic [XLEN-1:0]         link_addr;
    logic                    is_jal;            // JAL: can mark done=1 at dispatch
    logic                    is_jalr;           // JALR: must wait for execute to resolve target
    logic                    is_csr;
    logic                    is_fence;
    logic                    is_fence_i;
    logic                    is_wfi;
    logic                    is_mret;
    logic                    is_amo;
    logic                    is_lr;
    logic                    is_sc;
  } rob_alloc_req_t;

  typedef struct packed {
    logic                   alloc_ready;  // ROB can accept allocation
    logic [RobTagWidth-1:0] alloc_tag;    // Allocated ROB entry index
    logic                   full;         // ROB is full
  } rob_alloc_resp_t;

  // CDB write to ROB (for ALU, FPU, load results - NOT for branches/jumps)
  // NOTE: Branch/jump completion uses rob_branch_update_t, not this interface.
  typedef struct packed {
    logic                   valid;
    logic [RobTagWidth-1:0] tag;
    logic [FLEN-1:0]        value;      // Result value to write to ROB entry
    logic                   exception;
    exc_cause_t             exc_cause;
    fp_flags_t              fp_flags;
  } rob_cdb_write_t;

  // Branch resolution update to ROB (separate from CDB)
  // Sent by branch unit when a branch/jump resolves in execute stage.
  // This is the ONLY path for branch/jump completion - do NOT use rob_cdb_write_t for branches.
  typedef struct packed {
    logic                   valid;         // Branch resolution valid
    logic [RobTagWidth-1:0] tag;           // ROB entry of the branch
    logic                   taken;         // Actual branch outcome
    logic [XLEN-1:0]        target;        // Actual branch target
    // Misprediction flag (AUTHORITATIVE - computed by branch unit, not recomputed by ROB):
    // - If taken != predicted_taken: direction misprediction
    // - If taken && predicted_taken && target != predicted_target: target misprediction
    // - Target comparison only meaningful when both taken and predicted_taken are true
    // The branch unit is the single source of truth for misprediction to avoid divergence.
    logic                   mispredicted;
    // Completion behavior:
    // - JAL: entry was already marked done=1 at dispatch (this update only records branch info)
    // - JALR: marks entry done=1 (value already contains link_addr from dispatch)
    // - Conditional branches: marks entry done=1 (no result value needed)
  } rob_branch_update_t;

  // ROB commit signals
  // NOTE: Exposes all serializing instruction flags so outer control logic can react
  typedef struct packed {
    logic valid;  // Commit this cycle
    logic [RobTagWidth-1:0] tag;  // ROB entry being committed
    logic dest_rf;  // 0=INT, 1=FP
    logic [RegAddrWidth-1:0] dest_reg;
    logic dest_valid;  // Has destination register to write
    logic [FLEN-1:0] value;
    logic is_store;
    logic is_fp_store;
    logic exception;
    logic [XLEN-1:0] pc;  // For mepc
    exc_cause_t exc_cause;
    fp_flags_t fp_flags;  // FP flags to accumulate
    // Branch misprediction recovery
    logic misprediction;  // Branch mispredicted
    logic has_checkpoint;
    logic [CheckpointIdWidth-1:0] checkpoint_id;
    logic [XLEN-1:0] redirect_pc;  // Correct target on misprediction
    // Serializing instruction flags (for outer control logic)
    logic is_csr;  // CSR instruction (ROB executes at commit)
    logic is_fence;  // FENCE (SQ must be drained)
    logic is_fence_i;  // FENCE.I (SQ drained, pipeline flush)
    logic is_wfi;  // WFI (stall until interrupt)
    logic is_mret;  // MRET (restore mstatus, redirect to mepc)
    // Atomic operation flags (for memory ordering and reservation handling)
    logic is_amo;  // AMO instruction (executed at head with SQ empty)
    logic is_lr;  // LR (load-reserved, sets reservation)
    logic is_sc;  // SC (store-conditional, checks reservation)
  } rob_commit_t;

  // ===========================================================================
  // Section 4: RAT Entry and Checkpoint Structures
  // ===========================================================================
  // Separate INT and FP RATs, each with checkpoint storage for speculation.

  // RAT entry (per architectural register)
  typedef struct packed {
    logic                   valid;  // Register is renamed (has in-flight producer)
    logic [RobTagWidth-1:0] tag;    // ROB tag of producer
  } rat_entry_t;

  // RAT lookup result (returned on source register read)
  typedef struct packed {
    logic                   renamed;  // Source is renamed (wait for ROB tag)
    logic [RobTagWidth-1:0] tag;      // ROB tag if renamed
    logic [FLEN-1:0]        value;    // Value from regfile if not renamed
  } rat_lookup_t;

  // Full RAT state (for checkpointing)
  // Note: x0 entry is included for simplicity but always returns 0/not-renamed
  typedef struct packed {rat_entry_t [NumIntRegs-1:0] entries;} int_rat_state_t;

  typedef struct packed {rat_entry_t [NumFpRegs-1:0] entries;} fp_rat_state_t;

  // Checkpoint structure (stores RAT state for branch recovery)
  typedef struct packed {
    logic                   valid;            // Checkpoint is active
    logic [RobTagWidth-1:0] branch_tag;       // ROB tag of associated branch
    int_rat_state_t         int_rat;          // INT RAT snapshot
    fp_rat_state_t          fp_rat;           // FP RAT snapshot
    // RAS state for recovery
    logic [RasPtrBits-1:0]  ras_tos;          // RAS top-of-stack pointer
    logic [RasPtrBits:0]    ras_valid_count;  // RAS valid entry count
  } checkpoint_t;

  // ===========================================================================
  // Section 4b: Memory Operation Size Encoding
  // ===========================================================================
  // Size encoding for memory operations. Defined early for use in RS/LQ/SQ structs.

  typedef enum logic [1:0] {
    MEM_SIZE_BYTE   = 2'b00,  // 8-bit
    MEM_SIZE_HALF   = 2'b01,  // 16-bit
    MEM_SIZE_WORD   = 2'b10,  // 32-bit
    MEM_SIZE_DOUBLE = 2'b11   // 64-bit (FLD/FSD only)
  } mem_size_e;

  // ===========================================================================
  // Section 5: Reservation Station Entry Structure
  // ===========================================================================
  // Generic RS entry supporting up to 3 source operands (for FMA).
  // All values are FLEN-wide to support FP double precision.

  // RS entry structure (generic, used by all RS types)
  typedef struct packed {
    logic                   valid;    // Entry is allocated
    logic [RobTagWidth-1:0] rob_tag;  // Destination ROB entry
    instr_op_e              op;       // Operation to perform

    // Source operand 1
    logic                   src1_ready;  // Operand 1 is available
    logic [RobTagWidth-1:0] src1_tag;    // ROB tag if not ready
    logic [FLEN-1:0]        src1_value;  // Value if ready

    // Source operand 2
    logic                   src2_ready;  // Operand 2 is available
    logic [RobTagWidth-1:0] src2_tag;    // ROB tag if not ready
    logic [FLEN-1:0]        src2_value;  // Value if ready

    // Source operand 3 (for FMA: rs3/fs3)
    logic                   src3_ready;  // Operand 3 is available
    logic [RobTagWidth-1:0] src3_tag;    // ROB tag if not ready
    logic [FLEN-1:0]        src3_value;  // Value if ready

    // Immediate value (for immediate instructions)
    logic [XLEN-1:0] imm;      // Immediate value
    logic            use_imm;  // Use imm instead of src2

    // FP rounding mode (resolved from instruction rm or fcsr.frm at dispatch)
    logic [2:0] rm;  // Rounding mode (FRM_RNE, etc.)

    // For branches: pre-computed target from ID stage and BTB/RAS prediction
    logic [XLEN-1:0] branch_target;     // Pre-computed PC + imm (for branches/JAL)
    logic            predicted_taken;   // BTB predicted taken
    logic [XLEN-1:0] predicted_target;  // BTB/RAS predicted target

    // For memory operations: additional info
    logic      is_fp_mem;   // FP load/store (for LQ/SQ routing)
    mem_size_e mem_size;    // Memory operation size
    logic      mem_signed;  // Sign-extend on load

    // For CSR: address and immediate
    logic [11:0] csr_addr;  // CSR address
    logic [4:0]  csr_imm;   // Zero-extended CSR immediate
  } rs_entry_t;

  // RS dispatch request (from dispatch unit to RS)
  typedef struct packed {
    logic                   valid;             // Dispatch request valid
    rs_type_e               rs_type;           // Which RS to dispatch to
    logic [RobTagWidth-1:0] rob_tag;
    instr_op_e              op;
    // Source 1
    logic                   src1_ready;
    logic [RobTagWidth-1:0] src1_tag;
    logic [FLEN-1:0]        src1_value;
    // Source 2
    logic                   src2_ready;
    logic [RobTagWidth-1:0] src2_tag;
    logic [FLEN-1:0]        src2_value;
    // Source 3 (FMA only)
    logic                   src3_ready;
    logic [RobTagWidth-1:0] src3_tag;
    logic [FLEN-1:0]        src3_value;
    // Immediate
    logic [XLEN-1:0]        imm;
    logic                   use_imm;
    // FP rounding mode
    logic [2:0]             rm;
    // Branch info
    logic [XLEN-1:0]        branch_target;
    logic                   predicted_taken;
    logic [XLEN-1:0]        predicted_target;  // BTB/RAS predicted target
    // Memory info
    logic                   is_fp_mem;
    mem_size_e              mem_size;
    logic                   mem_signed;
    // CSR info
    logic [11:0]            csr_addr;
    logic [4:0]             csr_imm;
  } rs_dispatch_t;

  // RS issue signals (from RS to functional unit)
  typedef struct packed {
    logic                   valid;
    logic [RobTagWidth-1:0] rob_tag;
    instr_op_e              op;
    logic [FLEN-1:0]        src1_value;
    logic [FLEN-1:0]        src2_value;
    logic [FLEN-1:0]        src3_value;        // For FMA
    logic [XLEN-1:0]        imm;
    logic                   use_imm;
    logic [2:0]             rm;                // Rounding mode
    logic [XLEN-1:0]        branch_target;     // Pre-computed target
    logic                   predicted_taken;
    logic [XLEN-1:0]        predicted_target;  // BTB/RAS predicted target
    // Memory info (for MEM_RS)
    logic                   is_fp_mem;
    mem_size_e              mem_size;
    logic                   mem_signed;
    // CSR info
    logic [11:0]            csr_addr;
    logic [4:0]             csr_imm;
  } rs_issue_t;

  // ===========================================================================
  // Section 6: Load Queue Entry Structure
  // ===========================================================================
  // Supports INT and FP loads, including 2-phase FLD (64-bit double on 32-bit bus).

  // Load queue entry
  typedef struct packed {
    logic                   valid;       // Entry allocated
    logic [RobTagWidth-1:0] rob_tag;     // Associated ROB entry
    logic                   is_fp;       // FP load (FLW/FLD)
    logic                   addr_valid;  // Address has been calculated
    logic [XLEN-1:0]        address;     // Load address
    mem_size_e              size;        // Memory operation size (FLD uses MEM_SIZE_DOUBLE)
    logic                   sign_ext;    // Sign extend result (INT only)
    logic                   is_mmio;     // MMIO address (non-speculative only)
    logic                   fp64_phase;  // FLD phase: 0=low word, 1=high word
    logic                   issued;      // Sent to memory
    logic                   data_valid;  // Data received
    logic [FLEN-1:0]        data;        // Loaded data (FLEN for FLD)
    logic                   forwarded;   // Data from store queue forward
  } lq_entry_t;

  // LQ allocation request (from MEM_RS)
  typedef struct packed {
    logic                   valid;
    logic [RobTagWidth-1:0] rob_tag;
    logic                   is_fp;
    mem_size_e              size;
    logic                   sign_ext;
  } lq_alloc_req_t;

  // LQ address update (from address calculation)
  typedef struct packed {
    logic                   valid;
    logic [RobTagWidth-1:0] rob_tag;
    logic [XLEN-1:0]        address;
    logic                   is_mmio;
  } lq_addr_update_t;

  // ===========================================================================
  // Section 7: Store Queue Entry Structure
  // ===========================================================================
  // Supports INT and FP stores, including 2-phase FSD.

  // Store queue entry
  typedef struct packed {
    logic                   valid;       // Entry allocated
    logic [RobTagWidth-1:0] rob_tag;     // Associated ROB entry
    logic                   is_fp;       // FP store (FSW/FSD)
    logic                   addr_valid;  // Address has been calculated
    logic [XLEN-1:0]        address;     // Store address
    logic                   data_valid;  // Data is available
    logic [FLEN-1:0]        data;        // Store data (FLEN for FSD)
    mem_size_e              size;        // Memory operation size (FSD uses MEM_SIZE_DOUBLE)
    logic                   is_mmio;     // MMIO address (bypass cache)
    logic                   fp64_phase;  // FSD phase: 0=low word, 1=high word
    logic                   committed;   // ROB has committed this store
    logic                   sent;        // Written to memory
  } sq_entry_t;

  // SQ allocation request (from MEM_RS)
  typedef struct packed {
    logic                   valid;
    logic [RobTagWidth-1:0] rob_tag;
    logic                   is_fp;
    mem_size_e              size;
  } sq_alloc_req_t;

  // SQ address update (from address calculation)
  typedef struct packed {
    logic                   valid;
    logic [RobTagWidth-1:0] rob_tag;
    logic [XLEN-1:0]        address;
    logic                   is_mmio;
  } sq_addr_update_t;

  // SQ data update (from RS operand becoming ready)
  typedef struct packed {
    logic                   valid;
    logic [RobTagWidth-1:0] rob_tag;
    logic [FLEN-1:0]        data;
  } sq_data_update_t;

  // Store-to-load forwarding check result
  typedef struct packed {
    logic            match;        // Address match found
    logic            can_forward;  // Size compatible, can forward
    logic [FLEN-1:0] data;         // Forwarded data
  } sq_forward_result_t;

  // ===========================================================================
  // Section 8: CDB (Common Data Bus) Structures
  // ===========================================================================
  // FLEN-wide CDB to support FP double precision results.

  // CDB broadcast (from functional unit to RS/ROB/RAT)
  typedef struct packed {
    logic                   valid;      // Broadcast valid
    logic [RobTagWidth-1:0] tag;        // ROB tag of producing instruction
    logic [FLEN-1:0]        value;      // Result value (FLEN for FP double)
    logic                   exception;  // Exception occurred
    exc_cause_t             exc_cause;  // Exception cause
    fp_flags_t              fp_flags;   // FP exception flags
    fu_type_e               fu_type;    // Which FU produced this result
  } cdb_broadcast_t;

  // FU completion request (from FU to CDB arbiter)
  typedef struct packed {
    logic                   valid;      // FU has result ready
    logic [RobTagWidth-1:0] tag;
    logic [FLEN-1:0]        value;
    logic                   exception;
    exc_cause_t             exc_cause;
    fp_flags_t              fp_flags;
  } fu_complete_t;

  // CDB arbiter grant (to FU)
  typedef struct packed {
    logic granted;  // FU can broadcast this cycle
  } cdb_grant_t;

  // ===========================================================================
  // Section 9: Dispatch Interface Structures
  // ===========================================================================
  // Signals between decode stage and dispatch unit.

  // Decoded instruction info (from ID stage to dispatch)
  typedef struct packed {
    logic            valid;  // Valid instruction
    logic [XLEN-1:0] pc;
    instr_op_e       op;

    // Destination register
    logic                    has_dest;  // Has destination register
    logic                    dest_rf;   // 0=INT, 1=FP
    logic [RegAddrWidth-1:0] dest_reg;

    // Source registers
    logic                    uses_rs1;
    logic                    rs1_rf;    // 0=INT, 1=FP
    logic [RegAddrWidth-1:0] rs1_addr;
    logic                    uses_rs2;
    logic                    rs2_rf;    // 0=INT, 1=FP
    logic [RegAddrWidth-1:0] rs2_addr;
    logic                    uses_rs3;  // For FMA
    logic [RegAddrWidth-1:0] rs3_addr;  // Always FP

    // Immediate
    logic [XLEN-1:0] imm;
    logic            use_imm;

    // FP rounding mode (from instruction or DYN)
    logic [2:0] rm;
    logic       rm_is_dyn;  // Use fcsr.frm instead

    // Instruction classification
    rs_type_e rs_type;      // Which RS to use
    logic     is_branch;
    logic     is_call;
    logic     is_return;
    logic     is_store;
    logic     is_fp_store;
    logic     is_load;
    logic     is_fp_load;
    logic     is_csr;
    logic     is_fence;
    logic     is_fence_i;
    logic     is_wfi;
    logic     is_amo;
    logic     is_lr;
    logic     is_sc;

    // Memory operation info
    mem_size_e mem_size;
    logic      mem_signed;

    // Branch prediction info (passed through from IF)
    logic            predicted_taken;
    logic [XLEN-1:0] predicted_target;  // BTB/RAS predicted target
    logic [XLEN-1:0] branch_target;     // Pre-computed PC + imm

    // JAL/JALR link address (pre-computed PC+2 or PC+4 from IF)
    logic [XLEN-1:0] link_addr;
    logic            is_jal;     // JAL instruction
    logic            is_jalr;    // JALR instruction
    logic            is_mret;    // MRET instruction

    // CSR info
    logic [11:0] csr_addr;
    logic [4:0]  csr_imm;
  } decoded_instr_t;

  // Dispatch status (from dispatch to front-end)
  typedef struct packed {
    logic stall;            // Stall decode (ROB/RS/LQ/SQ full)
    logic rob_full;
    logic rs_full;          // Target RS is full
    logic lq_full;
    logic sq_full;
    logic checkpoint_full;  // All checkpoints in use (branch)
  } dispatch_status_t;


  // ===========================================================================
  // Section 11: Instruction Routing Table
  // ===========================================================================
  // Helper function to determine RS assignment from instruction operation.
  // This implements the routing table from DESIGN.md.

  function automatic rs_type_e get_rs_type(instr_op_e op);
    case (op)
      // Integer ALU operations -> INT_RS
      ADD, SUB, AND, OR, XOR, SLL, SRL, SRA, SLT, SLTU,
      ADDI, ANDI, ORI, XORI, SLTI, SLTIU, SLLI, SRLI, SRAI,
      LUI, AUIPC, JAL, JALR,
      BEQ, BNE, BLT, BGE, BLTU, BGEU,
      // Zba/Zbb/Zbs/Zbkb/Zicond -> INT_RS (all 1-cycle ALU ops)
      SH1ADD, SH2ADD, SH3ADD,
      BSET, BCLR, BINV, BEXT, BSETI, BCLRI, BINVI, BEXTI,
      ANDN, ORN, XNOR, CLZ, CTZ, CPOP, MAX, MAXU, MIN, MINU,
      SEXT_B, SEXT_H, ROL, ROR, RORI, ORC_B, REV8,
      CZERO_EQZ, CZERO_NEZ,
      PACK, PACKH, BREV8, ZIP, UNZIP,
      // CSR instructions -> INT_RS (execute at ROB head)
      CSRRW, CSRRS, CSRRC, CSRRWI, CSRRSI, CSRRCI,
      // Privileged (exceptions) -> INT_RS
      ECALL, EBREAK:
      get_rs_type = RS_INT;

      // Multiply/divide -> MUL_RS
      MUL, MULH, MULHSU, MULHU, DIV, DIVU, REM, REMU: get_rs_type = RS_MUL;

      // Memory operations -> MEM_RS (both INT and FP)
      LB, LH, LW, LBU, LHU, SB, SH, SW,
      FLW, FSW, FLD, FSD,
      LR_W, SC_W,
      AMOSWAP_W, AMOADD_W, AMOXOR_W, AMOAND_W, AMOOR_W,
      AMOMIN_W, AMOMAX_W, AMOMINU_W, AMOMAXU_W,
      FENCE, FENCE_I:
      get_rs_type = RS_MEM;

      // FP add/sub/cmp/cvt/classify/sgnj -> FP_RS
      FADD_S, FSUB_S, FADD_D, FSUB_D,
      FMIN_S, FMAX_S, FMIN_D, FMAX_D,
      FEQ_S, FLT_S, FLE_S, FEQ_D, FLT_D, FLE_D,
      FCVT_W_S, FCVT_WU_S, FCVT_S_W, FCVT_S_WU,
      FCVT_W_D, FCVT_WU_D, FCVT_D_W, FCVT_D_WU,
      FCVT_S_D, FCVT_D_S,
      FMV_X_W, FMV_W_X,
      FCLASS_S, FCLASS_D,
      FSGNJ_S, FSGNJN_S, FSGNJX_S,
      FSGNJ_D, FSGNJN_D, FSGNJX_D:
      get_rs_type = RS_FP;

      // FP multiply/FMA -> FMUL_RS (3 sources for FMA)
      FMUL_S, FMUL_D, FMADD_S, FMSUB_S, FNMADD_S, FNMSUB_S, FMADD_D, FMSUB_D, FNMADD_D, FNMSUB_D:
      get_rs_type = RS_FMUL;

      // FP divide/sqrt -> FDIV_RS (long latency)
      FDIV_S, FSQRT_S, FDIV_D, FSQRT_D: get_rs_type = RS_FDIV;

      // Instructions that don't need RS (dispatch directly to ROB)
      WFI, MRET, PAUSE: get_rs_type = RS_NONE;

      default: get_rs_type = RS_INT;  // Default fallback
    endcase
  endfunction

  // Helper function to determine if instruction has integer destination
  function automatic logic has_int_dest(instr_op_e op);
    case (op)
      // Integer ALU ops with rd
      ADD, SUB, AND, OR, XOR, SLL, SRL, SRA, SLT, SLTU,
      ADDI, ANDI, ORI, XORI, SLTI, SLTIU, SLLI, SRLI, SRAI,
      LUI, AUIPC, JAL, JALR,
      // B-extension
      SH1ADD, SH2ADD, SH3ADD,
      BSET, BCLR, BINV, BEXT, BSETI, BCLRI, BINVI, BEXTI,
      ANDN, ORN, XNOR, CLZ, CTZ, CPOP, MAX, MAXU, MIN, MINU,
      SEXT_B, SEXT_H, ROL, ROR, RORI, ORC_B, REV8,
      CZERO_EQZ, CZERO_NEZ, PACK, PACKH, BREV8, ZIP, UNZIP,
      // M-extension
      MUL, MULH, MULHSU, MULHU, DIV, DIVU, REM, REMU,
      // Integer loads
      LB, LH, LW, LBU, LHU,
      // Atomics (return old value to rd)
      LR_W, SC_W,
      AMOSWAP_W, AMOADD_W, AMOXOR_W, AMOAND_W, AMOOR_W,
      AMOMIN_W, AMOMAX_W, AMOMINU_W, AMOMAXU_W,
      // CSR (return old CSR value to rd)
      CSRRW, CSRRS, CSRRC, CSRRWI, CSRRSI, CSRRCI,
      // FP compare -> INT rd
      FEQ_S, FLT_S, FLE_S, FEQ_D, FLT_D, FLE_D,
      // FP classify -> INT rd
      FCLASS_S, FCLASS_D,
      // FP to INT conversion -> INT rd
      FCVT_W_S, FCVT_WU_S, FCVT_W_D, FCVT_WU_D,
      // FP to INT bit move -> INT rd
      FMV_X_W:
      has_int_dest = 1'b1;

      default: has_int_dest = 1'b0;
    endcase
  endfunction

  // Helper function to determine if instruction has FP destination
  function automatic logic has_fp_dest(instr_op_e op);
    case (op)
      // FP loads
      FLW, FLD,
      // FP compute ops
      FADD_S, FSUB_S, FMUL_S, FDIV_S, FSQRT_S,
      FADD_D, FSUB_D, FMUL_D, FDIV_D, FSQRT_D,
      FMADD_S, FMSUB_S, FNMADD_S, FNMSUB_S,
      FMADD_D, FMSUB_D, FNMADD_D, FNMSUB_D,
      FMIN_S, FMAX_S, FMIN_D, FMAX_D,
      FSGNJ_S, FSGNJN_S, FSGNJX_S,
      FSGNJ_D, FSGNJN_D, FSGNJX_D,
      // INT to FP conversion -> FP fd
      FCVT_S_W, FCVT_S_WU, FCVT_D_W, FCVT_D_WU,
      // FP format conversion
      FCVT_S_D, FCVT_D_S,
      // INT to FP bit move -> FP fd
      FMV_W_X:
      has_fp_dest = 1'b1;

      default: has_fp_dest = 1'b0;
    endcase
  endfunction

  // Helper function to determine if instruction uses FP rs1
  function automatic logic uses_fp_rs1(instr_op_e op);
    case (op)
      // FP compute ops (fs1)
      FADD_S, FSUB_S, FMUL_S, FDIV_S, FSQRT_S,
      FADD_D, FSUB_D, FMUL_D, FDIV_D, FSQRT_D,
      FMADD_S, FMSUB_S, FNMADD_S, FNMSUB_S,
      FMADD_D, FMSUB_D, FNMADD_D, FNMSUB_D,
      FMIN_S, FMAX_S, FMIN_D, FMAX_D,
      FSGNJ_S, FSGNJN_S, FSGNJX_S,
      FSGNJ_D, FSGNJN_D, FSGNJX_D,
      // FP compare (fs1, fs2) -> INT rd
      FEQ_S, FLT_S, FLE_S, FEQ_D, FLT_D, FLE_D,
      // FP classify (fs1) -> INT rd
      FCLASS_S, FCLASS_D,
      // FP to INT conversion (fs1) -> INT rd
      FCVT_W_S, FCVT_WU_S, FCVT_W_D, FCVT_WU_D,
      // FP to INT bit move (fs1) -> INT rd
      FMV_X_W,
      // FP format conversion
      FCVT_S_D, FCVT_D_S:
      uses_fp_rs1 = 1'b1;

      default: uses_fp_rs1 = 1'b0;
    endcase
  endfunction

  // Helper function to determine if instruction uses FP rs2
  function automatic logic uses_fp_rs2(instr_op_e op);
    case (op)
      // FP compute ops with 2+ sources
      FADD_S, FSUB_S, FMUL_S,
      FADD_D, FSUB_D, FMUL_D,
      FMADD_S, FMSUB_S, FNMADD_S, FNMSUB_S,
      FMADD_D, FMSUB_D, FNMADD_D, FNMSUB_D,
      FMIN_S, FMAX_S, FMIN_D, FMAX_D,
      FSGNJ_S, FSGNJN_S, FSGNJX_S,
      FSGNJ_D, FSGNJN_D, FSGNJX_D,
      // FP compare (fs1, fs2)
      FEQ_S, FLT_S, FLE_S, FEQ_D, FLT_D, FLE_D,
      // FP stores (base=INT rs1, data=FP rs2)
      FSW, FSD:
      uses_fp_rs2 = 1'b1;

      default: uses_fp_rs2 = 1'b0;
    endcase
  endfunction

  // Helper function to determine if instruction uses FP rs3 (FMA only)
  function automatic logic uses_fp_rs3(instr_op_e op);
    case (op)
      FMADD_S, FMSUB_S, FNMADD_S, FNMSUB_S, FMADD_D, FMSUB_D, FNMADD_D, FNMSUB_D:
      uses_fp_rs3 = 1'b1;

      default: uses_fp_rs3 = 1'b0;
    endcase
  endfunction

  // ===========================================================================
  // Section 12: Control Flow Classification Helpers
  // ===========================================================================
  // Unified classification functions to prevent flag drift between is_branch,
  // is_jal, is_jalr, is_call, is_return. Use these in decode to ensure consistency.

  // Is this a branch or jump instruction? (needs checkpoint, can mispredict)
  // Includes: conditional branches (BEQ, BNE, etc.) AND unconditional jumps (JAL, JALR)
  function automatic logic is_branch_or_jump_op(instr_op_e op);
    case (op)
      BEQ, BNE, BLT, BGE, BLTU, BGEU,  // Conditional branches
      JAL, JALR:  // Unconditional jumps
      is_branch_or_jump_op = 1'b1;
      default: is_branch_or_jump_op = 1'b0;
    endcase
  endfunction

  // Is this a JAL instruction? (target known at decode, can mark done=1 at dispatch)
  function automatic logic is_jal_op(instr_op_e op);
    is_jal_op = (op == JAL);
  endfunction

  // Is this a JALR instruction? (target depends on rs1, resolved in execute)
  function automatic logic is_jalr_op(instr_op_e op);
    is_jalr_op = (op == JALR);
  endfunction

  // Is this a call instruction? (pushes to RAS)
  // RISC-V convention: JAL or JALR with rd in {x1, x5} (ra or t0)
  // Note: This function only checks the opcode; caller must also check rd
  function automatic logic is_potential_call_op(instr_op_e op);
    is_potential_call_op = (op == JAL) || (op == JALR);
  endfunction

  // Is this a return instruction? (pops from RAS)
  // RISC-V convention: JALR with rs1 in {x1, x5}, rd=x0, imm=0
  // Note: This function only checks the opcode; caller must also check rs1/rd/imm
  function automatic logic is_potential_return_op(instr_op_e op);
    is_potential_return_op = (op == JALR);
  endfunction

  // Is this a conditional branch? (not JAL/JALR)
  function automatic logic is_conditional_branch_op(instr_op_e op);
    case (op)
      BEQ, BNE, BLT, BGE, BLTU, BGEU: is_conditional_branch_op = 1'b1;
      default: is_conditional_branch_op = 1'b0;
    endcase
  endfunction

  // ===========================================================================
  // Section 13: Predicted Target Policy Documentation
  // ===========================================================================
  // The predicted_target field is populated for ALL predicted-taken branches and jumps,
  // not just JALR. This enables misprediction detection for:
  //
  //   - Conditional branches (BEQ, BNE, etc.): Compare actual_target vs predicted_target
  //     when branch is taken. For not-taken predictions, target comparison is N/A.
  //
  //   - JAL: Target is PC+imm (known at decode). Misprediction only if BTB entry was

  //     stale/wrong. Compare jal_target_precomputed vs predicted_target.
  //
  //   - JALR: Target is rs1+imm (known at execute). Compare computed target vs
  //     predicted_target. This is the primary use case for target misprediction.
  //
  // Population rules:
  //   - If BTB hit and predicted taken: predicted_target = BTB target
  //   - If RAS prediction used: predicted_target = RAS target (for returns)
  //   - If no prediction: predicted_target can be 0 (misprediction if actually taken)

endpackage : tomasulo_pkg
