#    Copyright 2026 Two Sigma Open Source, LLC
#
#    Licensed under the Apache License, Version 2.0 (the "License");
#    you may not use this file except in compliance with the License.
#    You may obtain a copy of the License at
#
#        http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS,
#    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#    See the License for the specific language governing permissions and
#    limitations under the License.

"""Shared CPU port layouts in SystemVerilog declaration order (MSB first).

These handwritten schemas describe packed structs in riscv_pkg.sv. Treat the
lists as read-only; bench-specific defaults and signal timing stay in each
interface. XLEN, FLEN, and INSTR_OP_WIDTH come from the verification
configuration; the other widths are written out here.
"""

from config import FLEN, INSTR_OP_WIDTH, XLEN

ROB_TAG_WIDTH = 5
REG_ADDR_WIDTH = 5
CHECKPOINT_ID_WIDTH = 3
RAS_PTR_BITS = 3
BP_DIR_IDX_BITS = 10
MEM_SIZE_WIDTH = 2

# pipeline_ctrl_t
PIPELINE_CTRL_FIELDS = [
    ("reset", 1),
    ("stall", 1),
    ("stall_registered", 1),
    ("stall_for_trap_check", 1),
    ("flush", 1),
    ("trap_taken_registered", 1),
    ("mret_taken_registered", 1),
]

# from_if_to_pd_t
IF_TO_PD_FIELDS = [
    ("program_counter", XLEN),
    ("raw_parcel", 16),
    ("sel_nop", 1),
    ("sel_compressed", 1),
    ("effective_instr", 32),
    ("source_hot_predecoded", 3),
    ("bits24_20_predecoded", 5),
    ("rs1_rest_predecoded", 3),
    ("rvc_extra_predecoded", 23),
    ("btb_predicted_taken", 1),
    ("btb_predicted_target", XLEN),
    ("ras_checkpoint_tos", RAS_PTR_BITS),
    ("ras_checkpoint_valid_count", RAS_PTR_BITS + 1),
    ("ras_checkpoint_top", XLEN),
    ("bp_dir_taken", 1),
    ("bp_dir_idx", BP_DIR_IDX_BITS),
    ("fetch_fault", 1),
    ("fetch_fault_page", 1),
    ("fetch_fault_hi", 1),
    ("decomp_illegal", 1),
]

# from_pd_to_id_t
PD_TO_ID_FIELDS = [
    ("program_counter", XLEN),
    ("instruction", 32),
    ("inject_nop", 1),
    ("is_compressed", 1),
    ("source_reg_1_early", 5),
    ("source_reg_2_early", 5),
    ("illegal_instruction", 1),
    ("fetch_fault", 1),
    ("fetch_fault_page", 1),
    ("fetch_fault_hi", 1),
    ("btb_predicted_taken", 1),
    ("btb_predicted_target", XLEN),
    ("ras_checkpoint_tos", RAS_PTR_BITS),
    ("ras_checkpoint_valid_count", RAS_PTR_BITS + 1),
    ("ras_checkpoint_top", XLEN),
    ("bp_dir_idx", BP_DIR_IDX_BITS),
]

# from_id_to_ex_t
ID_TO_EX_FIELDS = [
    ("program_counter", XLEN),
    ("immediate_i_type", XLEN),
    ("immediate_s_type", XLEN),
    ("immediate_u_type", XLEN),
    ("is_load_instruction", 1),
    ("is_load_unsigned", 1),
    ("instruction_operation", INSTR_OP_WIDTH),
    ("rs_type", 3),
    ("is_int_store", 1),
    ("is_branch_or_jump", 1),
    ("is_fence", 1),
    ("is_fence_i", 1),
    ("is_csr_imm", 1),
    ("has_fp_flags", 1),
    ("needs_lq", 1),
    ("needs_sq", 1),
    ("is_jump_and_link", 1),
    ("is_jump_and_link_register", 1),
    ("is_csr_instruction", 1),
    ("csr_address", 12),
    ("csr_imm", 5),
    ("is_amo_instruction", 1),
    ("is_lr", 1),
    ("is_sc", 1),
    ("is_mret", 1),
    ("is_sret", 1),
    ("is_dret", 1),
    ("is_sfence_vma", 1),
    ("is_wfi", 1),
    ("is_illegal_instruction", 1),
    ("is_fetch_fault", 1),
    ("is_fetch_fault_page", 1),
    ("is_fp_instruction", 1),
    ("is_fp_load", 1),
    ("is_fp_store", 1),
    ("fp_rm", 3),
    ("link_address", XLEN),
    ("is_compressed", 1),
    ("branch_target_precomputed", XLEN),
    ("jal_target_precomputed", XLEN),
    ("instruction", 32),
    ("btb_predicted_taken", 1),
    ("btb_predicted_target", XLEN),
    ("ras_checkpoint_tos", RAS_PTR_BITS),
    ("ras_checkpoint_valid_count", RAS_PTR_BITS + 1),
    ("ras_checkpoint_top", XLEN),
    ("bp_dir_idx", BP_DIR_IDX_BITS),
    ("is_ras_return", 1),
    ("is_ras_call", 1),
    ("btb_correct_non_jalr", 1),
    ("pc_relative_precomputed", XLEN),
    # Dispatch consumes these registered operand classifications.
    ("has_int_dest", 1),
    ("has_fp_dest", 1),
    ("uses_int_rs1", 1),
    ("uses_int_rs2", 1),
    ("uses_fp_rs1", 1),
    ("uses_fp_rs2", 1),
    ("uses_fp_rs3", 1),
    ("is_real", 1),
]

# from_ex_comb_t
FROM_EX_FIELDS = [
    ("branch_taken", 1),
    ("branch_target_address", XLEN),
    ("btb_update", 1),
    ("btb_update_pc", XLEN),
    ("btb_update_target", XLEN),
    ("btb_update_taken", 1),
    ("btb_update_compressed", 1),
    ("btb_update_call", 1),
    ("btb_update_return", 1),
    ("ras_misprediction", 1),
    ("ras_restore_tos", RAS_PTR_BITS),
    ("ras_restore_valid_count", RAS_PTR_BITS + 1),
    ("ras_restore_top", XLEN),
    ("ras_pop_after_restore", 1),
    ("ras_push_after_restore", 1),
    ("ras_push_address_after_restore", XLEN),
]

# reorder_buffer_alloc_req_t
ROB_ALLOC_REQ_FIELDS = [
    ("alloc_valid", 1),
    ("pc", XLEN),
    ("rs_type", 3),
    ("dest_rf", 1),
    ("dest_reg", REG_ADDR_WIDTH),
    ("dest_valid", 1),
    ("is_store", 1),
    ("is_fp_store", 1),
    ("is_fp_instruction", 1),
    ("fp_dyn_rm", 1),
    ("is_branch", 1),
    ("predicted_taken", 1),
    ("predicted_target", XLEN),
    ("branch_target", XLEN),
    ("is_call", 1),
    ("is_return", 1),
    ("link_addr", XLEN),
    ("is_jal", 1),
    ("is_jalr", 1),
    ("is_csr", 1),
    ("is_fence", 1),
    ("is_fence_i", 1),
    ("is_wfi", 1),
    ("is_mret", 1),
    ("is_sret", 1),
    ("is_dret", 1),
    ("is_sfence_vma", 1),
    ("is_amo", 1),
    ("is_lr", 1),
    ("is_sc", 1),
    ("is_compressed", 1),
    ("csr_write_intent", 1),
    ("csr_addr", 12),
    ("csr_op", 3),
    ("csr_write_data", XLEN),
    ("has_fp_flags", 1),
]

# reorder_buffer_commit_t
COMMIT_FIELDS = [
    ("valid", 1),
    ("tag", ROB_TAG_WIDTH),
    ("dest_rf", 1),
    ("dest_reg", 5),
    ("dest_valid", 1),
    ("value", FLEN),
    ("is_store", 1),
    ("is_fp_store", 1),
    ("exception", 1),
    ("pc", XLEN),
    ("exc_cause", 5),
    ("fp_flags", 5),
    ("has_fp_flags", 1),
    ("misprediction", 1),
    ("early_recovered", 1),
    ("has_checkpoint", 1),
    ("checkpoint_id", 3),
    ("redirect_pc", XLEN),
    ("predicted_taken", 1),
    ("branch_taken", 1),
    ("branch_target", XLEN),
    ("is_branch", 1),
    ("is_call", 1),
    ("is_return", 1),
    ("is_jal", 1),
    ("is_jalr", 1),
    ("csr_addr", 12),
    ("csr_op", 3),
    ("csr_write_data", XLEN),
    ("is_csr", 1),
    ("is_fence", 1),
    ("is_fence_i", 1),
    ("is_wfi", 1),
    ("is_mret", 1),
    ("is_amo", 1),
    ("is_lr", 1),
    ("is_sc", 1),
    ("is_compressed", 1),
]

# mispredict_commit_capture_t
MISPREDICT_COMMIT_FIELDS = [
    ("tag", ROB_TAG_WIDTH),
    ("has_checkpoint", 1),
    ("checkpoint_id", CHECKPOINT_ID_WIDTH),
    ("redirect_pc", XLEN),
    ("pc", XLEN),
    ("branch_target", XLEN),
    ("branch_taken", 1),
    ("is_branch", 1),
    ("is_call", 1),
    ("is_return", 1),
    ("is_jal", 1),
    ("is_jalr", 1),
    ("is_compressed", 1),
]

# correct_branch_commit_capture_t
CORRECT_BRANCH_COMMIT_FIELDS = [
    ("tag", ROB_TAG_WIDTH),
    ("checkpoint_id", CHECKPOINT_ID_WIDTH),
    ("pc", XLEN),
    ("branch_target", XLEN),
    ("branch_taken", 1),
    ("is_branch", 1),
    ("is_jal", 1),
    ("is_jalr", 1),
    ("is_compressed", 1),
]

# reorder_buffer_branch_update_t
BRANCH_UPDATE_FIELDS = [
    ("valid", 1),
    ("tag", ROB_TAG_WIDTH),
    ("taken", 1),
    ("target", XLEN),
    ("mispredicted", 1),
]

# rs_issue_t
RS_ISSUE_FIELDS = [
    ("valid", 1),
    ("rob_tag", ROB_TAG_WIDTH),
    ("op", INSTR_OP_WIDTH),
    ("src1_value", FLEN),
    ("src2_value", FLEN),
    ("src3_value", FLEN),
    ("imm", XLEN),
    ("use_imm", 1),
    ("jalr_imm", 12),
    ("rm", 3),
    ("predicted_taken", 1),
    ("predicted_target", XLEN),
    ("predicted_target_ok", 1),
    ("is_compressed", 1),
    ("is_fp_mem", 1),
    ("mem_needs_lq", 1),
    ("mem_needs_sq", 1),
    ("mem_size", MEM_SIZE_WIDTH),
    ("mem_signed", 1),
    ("csr_addr", 12),
    ("csr_imm", 5),
    ("pc", XLEN),
    ("link_addr", XLEN),
    ("has_checkpoint", 1),
    ("checkpoint_id", CHECKPOINT_ID_WIDTH),
    ("is_call", 1),
    ("is_return", 1),
    ("is_branch_class", 1),
    ("is_jal", 1),
    ("is_jalr", 1),
    ("branch_op", 3),
]
