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

"""Bounded diagnostics for overlapping instruction starts in walk_past_test."""

from typing import Any

from cocotb.triggers import FallingEdge


async def watch(dut: Any, clock: Any, start: int, end: int) -> None:
    """Observe explicit front-end signals without changing fetch inputs."""
    cpu = dut.cpu_and_memory_subsystem.cpu.hart.cpu_inst
    stage = cpu.if_stage_inst
    pc_control = stage.pc_controller_inst
    lines = 0
    retirement_errors = 0
    while True:
        await FallingEdge(clock)
        pc_reg = int(stage.pc_reg.value)
        if (int(cpu.next_pc_check_armed_q.value) and
                int(cpu.rob_commit_valid_raw.value) and retirement_errors < 32):
            actual = int(cpu.dbg_commit_pc.value)
            expected = int(cpu.next_pc_expected_q.value)
            if actual != expected:
                dut._log.info("WALK NEXT-PC actual=%#x expected=%#x", actual, expected)
                retirement_errors += 1
        if start <= pc_reg < end and lines < 256:
            dut._log.info(
                "WALK pc=%#x reg=%#x next=%#x pending=%d owner=%#x after=%d "
                "stall=%d progress=%d holdoff=%d nop=%d wcs=%d pred=%d selr=%d",
                int(stage.pc.value), pc_reg, int(pc_control.next_pc_reg.value),
                int(pc_control.pending_prediction_valid.value),
                int(stage.pending_prediction_pc.value),
                int(pc_control.pc_reg_after_pending.value),
                int(stage.if_stage_stall.value), int(stage.fetch_progress.value),
                int(stage.prediction_holdoff.value), int(stage.sel_nop.value),
                int(stage.window_cannot_serve_pc_reg.value),
                int(stage.prediction_used.value), int(pc_control.sel_prediction_r.value),
            )
            lines += 1
