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
        s1_pc = int(stage.s1_pc.value)
        if (
            int(cpu.next_pc_check_armed_q.value)
            and int(cpu.rob_commit_valid_raw.value)
            and retirement_errors < 32
        ):
            actual = int(cpu.dbg_commit_pc.value)
            expected = int(cpu.next_pc_expected_q.value)
            if actual != expected:
                dut._log.info("WALK NEXT-PC actual=%#x expected=%#x", actual, expected)
                retirement_errors += 1
        if start <= s1_pc < end and lines < 256:
            dut._log.info(
                "WALK pc=%#x s1_pc=%#x next=%#x f0_launch=%d f1_accept=%d "
                "f0_btb=%d false_btb=%d resteer=%d stop=%d s1_valid=%d",
                int(stage.pc.value),
                s1_pc,
                int(pc_control.next_pc.value),
                int(stage.f0_launch.value),
                int(stage.f1_accept.value),
                int(stage.f0_btb_valid.value),
                int(stage.f1_false_btb.value),
                int(stage.f1_resteer.value),
                int(stage.q_stop_fetch.value),
                int(stage.s1_valid.value),
            )
            lines += 1
