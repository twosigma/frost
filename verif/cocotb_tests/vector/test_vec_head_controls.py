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

"""Head translation cancellation, admission and retirement edge cases."""

from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge, Timer
from cocotb_tests.cpu_structs import PTW_RESP_FIELDS
from utils.packed_structs import pack_struct

IDLE, WAIT, DECODE = 0, 1, 2
WALK_WAIT_P0, WALK_WAIT_P1 = 13, 16
PARTIAL_ARM, PARTIAL_SETTLE, PARTIAL_RUN = 17, 18, 19
FAULT_ARM, FAULT_SETTLE, CDB_FAULT, WAIT_TRAP = 20, 21, 22, 23
COMMIT_ARM, COMMIT_SETTLE, CDB_OK, WAIT_RETIRE, FATAL = 24, 25, 26, 27, 28


class Bench:
    """Drive the head unit with an architectural head and an Sv39 walker."""

    def __init__(self, dut: Any) -> None:
        """Attach the input driver to the unit."""
        self.dut = dut

    async def tick(self, **values: int) -> dict[str, int]:
        """Return the externally visible requests sampled on this edge."""
        dut = self.dut
        await FallingEdge(dut.i_clk)
        for name, value in values.items():
            getattr(dut, name).value = value
        await Timer(1, unit="ns")
        observed = {
            name: int(getattr(dut, name).value)
            for name in (
                "o_walk_req_valid",
                "o_vmt_range_valid",
                "o_desc_valid",
                "o_cdb_done",
                "o_rf_read_en",
                "o_vmem_fault_vstart_valid",
                "o_vmem_fault_vstart",
                "o_retire_vload",
                "o_retire_vstore",
            )
        }
        await RisingEdge(dut.i_clk)
        await ReadOnly()
        return observed

    async def reset(self, *, split: bool = False, fault: bool = False) -> None:
        """Reset with a cached-memory vector instruction at the head."""
        values = dict(
            i_rst=1,
            i_head_tag=3,
            i_rob_empty=0,
            i_head_safe=1,
            i_head_is_vmem=1,
            i_head_insn=0x02008407,
            i_head_vmt_idx=0,
            i_flush_all=0,
            i_fatal_stop=0,
            i_commit_valid=0,
            i_commit_tag=3,
            i_commit_exception=0,
            i_vec_idle=1,
            i_csr_wb_pending=0,
            i_sq_committed_empty=1,
            i_int_take_armed=0,
            i_vl=4,
            i_vtype=0,
            i_vstart=0,
            i_rf_read_data=0x80000FFE if split else 0x80000100,
            i_vrf_read_data=0,
            i_translate=int(fault),
            i_eff_priv_u=0,
            i_sum=0,
            i_mxr=0,
            i_tlb_invalidate=0,
            i_walk_req_ready=1,
            i_walk_resp_valid=0,
            i_walk_resp=0,
            i_grant=0,
            i_vmu_done=0,
            i_vmu_fatal=0,
        )
        await self.tick(**values)
        await self.tick(i_rst=1)
        await self.tick(i_rst=0)

    async def reach(
        self, target: int, *, fault: bool = False, split: bool = False
    ) -> None:
        """Run the real state transitions, including successful and faulting walks."""
        await self.reset(fault=fault, split=split)
        for _ in range(100):
            state = int(self.dut.state_q.value)
            if state == target:
                return
            response = state in (WALK_WAIT_P0, WALK_WAIT_P1)
            vpn = int(self.dut.o_walk_vpn.value)
            leaf = pack_struct(
                PTW_RESP_FIELDS,
                {
                    "vpn": vpn,
                    "ppn": 0x80000,
                    "level": 0,
                    "fault_kind": 2
                    if fault and (not split or state == WALK_WAIT_P1)
                    else 0,
                    "perm_r": 1,
                    "perm_w": 1,
                    "perm_d": 1,
                },
            )
            await self.tick(
                i_walk_resp_valid=int(response),
                i_walk_resp=leaf,
                i_grant=int(target == WAIT_TRAP),
                i_vmu_done=int(state == PARTIAL_RUN and target != PARTIAL_RUN),
            )
        raise AssertionError(
            f"did not reach state {target}, at {int(self.dut.state_q.value)}"
        )


def no_publication(sample: dict[str, int]) -> None:
    """Check that a cancelled instruction cannot request or publish work."""
    for name in ("o_walk_req_valid", "o_vmt_range_valid", "o_desc_valid", "o_cdb_done"):
        assert sample[name] == 0, (name, sample)


@cocotb.test()
async def test_flush_each_precommit_state(dut: Any) -> None:
    """Flush pulses inhibit the sampling edge and the delayed cleanup cycle."""
    Clock(dut.i_clk, 10, unit="ns").start()
    b = Bench(dut)
    for target in range(WAIT_RETIRE):
        fault = target in range(11, 24)
        split = target in range(7, 11) or target in range(14, 20)
        await b.reach(target, fault=fault, split=split)
        no_publication(await b.tick(i_flush_all=1, i_head_safe=0, i_grant=1))
        no_publication(await b.tick(i_flush_all=0, i_rob_empty=1, i_head_is_vmem=0))
        assert int(dut.state_q.value) == IDLE, target
    dut._log.info("flush checked in all 27 pre-retirement states")


@cocotb.test()
async def test_flush_settle_window(dut: Any) -> None:
    """A one-cycle cancellation must survive until an armed launch is discarded."""
    Clock(dut.i_clk, 10, unit="ns").start()
    b = Bench(dut)
    for arm, settle, fault, split in (
        (COMMIT_ARM, COMMIT_SETTLE, False, False),
        (PARTIAL_ARM, PARTIAL_SETTLE, True, True),
        (FAULT_ARM, FAULT_SETTLE, True, False),
    ):
        await b.reach(arm, fault=fault, split=split)
        no_publication(await b.tick(i_flush_all=1))
        # The local state receives the flush on the following edge.
        assert int(dut.state_q.value) == settle
        no_publication(await b.tick(i_flush_all=0))
        assert int(dut.state_q.value) == IDLE


@cocotb.test()
async def test_head_move_and_interrupt_at_admission(dut: Any) -> None:
    """Head moves and interrupts cannot publish a stale candidate."""
    Clock(dut.i_clk, 10, unit="ns").start()
    b = Bench(dut)
    for target, settled in (
        (WAIT, False),
        (WAIT, True),
        (DECODE, False),
        (COMMIT_ARM, False),
        (PARTIAL_ARM, False),
        (FAULT_ARM, False),
    ):
        for event in ("head", "interrupt"):
            await b.reach(
                target,
                fault=target in (PARTIAL_ARM, FAULT_ARM),
                split=target == PARTIAL_ARM,
            )
            if settled:
                await b.tick()
            change = (
                dict(i_head_tag=4, i_head_is_vmem=0)
                if event == "head"
                else dict(
                    i_int_take_armed=1,
                    i_head_safe=0,
                )
            )
            no_publication(await b.tick(**change))
            for _ in range(30):
                no_publication(await b.tick())
            assert int(dut.state_q.value) == IDLE, (target, event)


@cocotb.test()
async def test_trap_sideband_and_retired_head_move(dut: Any) -> None:
    """The trap consumes vstart on its flush edge; retirement uses the saved tag."""
    Clock(dut.i_clk, 10, unit="ns").start()
    b = Bench(dut)
    for acknowledged in (False, True):
        await b.reach(CDB_FAULT, fault=True, split=True)
        sample = await b.tick(i_grant=1)
        assert sample["o_cdb_done"] == 1
        if acknowledged:
            sample = await b.tick()
            assert sample["o_cdb_done"] == 0
            assert int(dut.state_q.value) == WAIT_TRAP
        # Exercise the acknowledgement cycle and the settled trap wait.
        sample = await b.tick(i_flush_all=1, i_head_safe=0)
        assert sample["o_vmem_fault_vstart_valid"] == 1
        assert sample["o_vmem_fault_vstart"] == 2
        no_publication(sample)
        await b.tick(i_flush_all=0, i_head_tag=4, i_head_is_vmem=0)
        assert int(dut.state_q.value) == IDLE
    await b.reach(CDB_OK)
    sample = await b.tick(i_grant=1)
    assert sample["o_cdb_done"] == 1
    assert int(dut.state_q.value) == CDB_OK
    sample = await b.tick(i_head_tag=4, i_head_is_vmem=0)
    assert sample["o_cdb_done"] == 0, (
        "acknowledgement must suppress duplicate completion"
    )
    assert int(dut.state_q.value) == WAIT_RETIRE
    sample = await b.tick(i_commit_valid=1, i_grant=0)
    assert sample["o_desc_valid"] == 1 and sample["o_retire_vload"] == 1
    assert int(dut.state_q.value) == IDLE


@cocotb.test()
async def test_fatal_in_settle(dut: Any) -> None:
    """A fatal input suppresses publication before the local state stops."""
    Clock(dut.i_clk, 10, unit="ns").start()
    b = Bench(dut)
    for stop in ("i_fatal_stop", "i_vmu_fatal"):
        await b.reach(PARTIAL_SETTLE, fault=True, split=True)
        no_publication(await b.tick(**{stop: 1}))
        no_publication(await b.tick(**{stop: 0}))
        assert int(dut.state_q.value) == FATAL


@cocotb.test()
async def test_head_snapshot_keeps_tag_and_instruction_together(dut: Any) -> None:
    """Reject a candidate whose head moves between sampling and admission."""
    Clock(dut.i_clk, 10, unit="ns").start()
    b = Bench(dut)
    await b.reset()
    await b.tick(i_rst=1, i_head_is_vmem=0)
    await b.tick(i_rst=0, i_head_is_vmem=1, i_head_tag=3)
    assert int(dut.state_q.value) == IDLE, "admission uses the sampled candidate"
    await b.tick(i_head_is_vmem=0, i_head_tag=4, i_head_insn=0)
    assert int(dut.state_q.value) == WAIT
    for _ in range(6):
        sample = await b.tick()
        assert sample["o_rf_read_en"] == 0, (
            "tag and instruction came from different heads"
        )
        no_publication(sample)
    assert int(dut.state_q.value) == IDLE
