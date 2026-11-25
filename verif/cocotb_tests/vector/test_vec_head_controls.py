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
STRIDE_RD, STRIDE_CAP = 29, 30
RUN_SEEK, RUN_ADDR, RUN_SPLIT = 31, 32, 33
RUN_ARM, RUN_SETTLE, RUN_LAUNCH, RUN_WAIT = 34, 35, 36, 37
RUN_IDX, RUN_IDX_CAP = 38, 39
RUN_TRIM, RUN_TRIM_SETTLE = 40, 41


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
            i_pm_mode=0,
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


@cocotb.test()
async def test_run_async_boundary_and_settle_flush(dut: Any) -> None:
    """Mid-run element boundaries drop the shield, report vstart, and clear cleanly on flush."""
    Clock(dut.i_clk, 10, unit="ns").start()
    b = Bench(dut)
    # vlse32.v v8, (x1), x2: unmasked strided load, vl=3.
    vlse32 = (2 << 26) | (1 << 25) | (2 << 20) | (1 << 15) | (6 << 12) | (8 << 7) | 0x07
    vle32ff = (
        (0 << 26) | (1 << 25) | (0x10 << 20) | (1 << 15) | (6 << 12) | (8 << 7) | 0x07
    )

    async def start_run(
        insn: int, *, translate: int = 0, base: int = 0x80000100
    ) -> None:
        await b.reset(fault=bool(translate))
        await b.tick(
            i_rst=1,
            i_head_insn=insn,
            i_vl=3,
            i_vtype=0x10,
            i_vstart=0,
            i_rf_read_data=base,
            i_translate=translate,
        )
        await b.tick(i_rst=0)

    # 1. Complete element 0 of vlse32.v -> shield drops, vstart=1 advertised;
    #    armed interrupt holds RUN_ARM without launching; flush returns to IDLE cleanly.
    await start_run(vlse32)
    for _ in range(60):
        state = int(dut.state_q.value)
        if state == RUN_WAIT:
            await b.tick(i_vmu_done=1)
            break
        rf_data = 8 if int(dut.o_rf_read_addr.value) == 2 else 0x80000100
        await b.tick(i_rf_read_data=rf_data, i_vmu_done=0)
    else:
        raise AssertionError("vlse32 did not reach RUN_WAIT")

    assert int(dut.o_vmem_head_shield.value) == 0
    assert int(dut.o_vmem_fault_vstart_valid.value) == 1
    assert int(dut.o_vmem_fault_vstart.value) == 1

    # Reach RUN_ARM for element 1 with interrupt armed -> no launch, shield stays low.
    for _ in range(10):
        sample = await b.tick(i_vmu_done=0, i_int_take_armed=1)
        assert sample["o_desc_valid"] == 0
        if int(dut.state_q.value) == RUN_ARM:
            break
    assert int(dut.state_q.value) == RUN_ARM
    assert int(dut.o_vmem_head_shield.value) == 0
    assert int(dut.o_vmem_fault_vstart_valid.value) == 1
    assert int(dut.o_vmem_fault_vstart.value) == 1

    # Flush edge simulates interrupt taken: sideband stays available on the
    # trap-taking edge, then clears with local state on the next edge.
    sample = await b.tick(i_flush_all=1, i_head_safe=0, i_int_take_armed=0)
    no_publication(sample)
    assert sample["o_vmem_fault_vstart_valid"] == 1
    assert sample["o_vmem_fault_vstart"] == 1
    sample = await b.tick(i_flush_all=0, i_rob_empty=1, i_head_is_vmem=0)
    no_publication(sample)
    assert int(dut.state_q.value) == IDLE
    assert int(dut.run_started_q.value) == 0
    assert sample["o_vmem_fault_vstart_valid"] == 0
    assert int(dut.o_vmem_fault_vstart_valid.value) == 0

    # 2. One-cycle flush arriving on the RUN_ARM -> RUN_LAUNCH transition after element 0.
    await start_run(vlse32)
    elem0_done = False
    for _ in range(80):
        state = int(dut.state_q.value)
        if state == RUN_WAIT and not elem0_done:
            await b.tick(i_vmu_done=1)
            elem0_done = True
            continue
        if elem0_done and state == RUN_ARM:
            break
        rf_data = 8 if int(dut.o_rf_read_addr.value) == 2 else 0x80000100
        await b.tick(i_rf_read_data=rf_data, i_vmu_done=0)
    else:
        raise AssertionError("vlse32 did not reach RUN_ARM for element 1")
    no_publication(await b.tick(i_flush_all=1))
    assert int(dut.state_q.value) == RUN_LAUNCH
    no_publication(await b.tick(i_flush_all=0, i_rob_empty=1, i_head_is_vmem=0))
    assert int(dut.state_q.value) == IDLE
    assert int(dut.run_started_q.value) == 0

    # 3. One-cycle flush arriving on RUN_TRIM -> CDB_OK (FoF element 1 faults).
    await start_run(vle32ff, translate=1, base=0x80000FFC)
    elem0_done = False
    for _ in range(100):
        state = int(dut.state_q.value)
        if state == RUN_TRIM:
            break
        resp = state in (WALK_WAIT_P0, WALK_WAIT_P1)
        vpn = int(dut.o_walk_vpn.value)
        leaf = pack_struct(
            PTW_RESP_FIELDS,
            {
                "vpn": vpn,
                "ppn": 0x80000,
                "level": 0,
                "fault_kind": 2 if elem0_done else 0,
                "perm_r": 1,
                "perm_w": 1,
                "perm_d": 1,
            },
        )
        done = int(state == RUN_WAIT)
        if done:
            elem0_done = True
        await b.tick(
            i_walk_resp_valid=int(resp),
            i_walk_resp=leaf,
            i_vmu_done=done,
            i_rf_read_data=0x80000FFC,
        )
    else:
        raise AssertionError("vle32ff did not reach RUN_TRIM")
    no_publication(
        await b.tick(i_flush_all=1, i_walk_resp_valid=0, i_vmu_done=0, i_grant=1)
    )
    assert int(dut.state_q.value) == CDB_OK
    no_publication(
        await b.tick(i_flush_all=0, i_rob_empty=1, i_head_is_vmem=0, i_grant=1)
    )
    assert int(dut.state_q.value) == IDLE
    assert int(dut.run_started_q.value) == 0


@cocotb.test()
async def test_fault_arm_irq_pause_after_started_elem(dut: Any) -> None:
    """An interrupt armed in HM_FAULT_ARM after started elements pauses unshielded."""
    Clock(dut.i_clk, 10, unit="ns").start()
    b = Bench(dut)
    # vlse32.v v8, (x1), x2: unmasked strided load, vl=3, stride=0x1000.
    # Element 0 is on page 0x80000 (valid); element 1 is on page 0x80001 (fault).
    vlse32 = (2 << 26) | (1 << 25) | (2 << 20) | (1 << 15) | (6 << 12) | (8 << 7) | 0x07

    async def reach_elem1_fault_arm() -> None:
        await b.reset(fault=True)
        await b.tick(
            i_rst=1,
            i_head_insn=vlse32,
            i_vl=3,
            i_vtype=0x10,
            i_vstart=0,
            i_rf_read_data=0x80000100,
            i_translate=1,
        )
        await b.tick(i_rst=0)
        elem0_done = False
        for _ in range(100):
            state = int(dut.state_q.value)
            if elem0_done and state == FAULT_ARM:
                return
            resp = state in (WALK_WAIT_P0, WALK_WAIT_P1)
            vpn = int(dut.o_walk_vpn.value)
            leaf = pack_struct(
                PTW_RESP_FIELDS,
                {
                    "vpn": vpn,
                    "ppn": 0x80000,
                    "level": 0,
                    "fault_kind": 2 if elem0_done else 0,
                    "perm_r": 1,
                    "perm_w": 1,
                    "perm_d": 1,
                },
            )
            done = int(state == RUN_WAIT)
            if done:
                elem0_done = True
            rf_data = 0x1000 if int(dut.o_rf_read_addr.value) == 2 else 0x80000100
            await b.tick(
                i_walk_resp_valid=int(resp),
                i_walk_resp=leaf,
                i_vmu_done=done,
                i_rf_read_data=rf_data,
                i_int_take_armed=0,
            )
        raise AssertionError(
            f"vlse32 did not reach FAULT_ARM for element 1, at {int(dut.state_q.value)}"
        )

    # 1. Pause in HM_FAULT_ARM while interrupt is armed, then take and flush to IDLE.
    await reach_elem1_fault_arm()
    assert int(dut.run_started_q.value) == 1
    for _ in range(3):
        sample = await b.tick(
            i_walk_resp_valid=0,
            i_vmu_done=0,
            i_int_take_armed=1,
            i_grant=1,
        )
        no_publication(sample)
        assert sample["o_vmem_fault_vstart_valid"] == 1
        assert sample["o_vmem_fault_vstart"] == 1
        assert int(dut.state_q.value) == FAULT_ARM
        assert int(dut.o_vmem_head_shield.value) == 0
        assert int(dut.run_started_q.value) == 1

    # Flush edge simulates interrupt take: sideband stays valid on the take edge,
    # then clears with local state on the cleanup edge.
    sample = await b.tick(i_flush_all=1, i_head_safe=0, i_int_take_armed=0, i_grant=1)
    no_publication(sample)
    assert sample["o_vmem_fault_vstart_valid"] == 1
    assert sample["o_vmem_fault_vstart"] == 1
    sample = await b.tick(i_flush_all=0, i_rob_empty=1, i_head_is_vmem=0, i_grant=1)
    no_publication(sample)
    assert int(dut.state_q.value) == IDLE
    assert int(dut.run_started_q.value) == 0
    assert int(dut.o_vmem_head_shield.value) == 0
    assert sample["o_vmem_fault_vstart_valid"] == 0
    assert int(dut.o_vmem_fault_vstart_valid.value) == 0

    # 2. Pause in HM_FAULT_ARM, then withdraw interrupt -> shield rises and
    #    synchronous fault completes on CDB with vstart == 1.
    await reach_elem1_fault_arm()
    for _ in range(2):
        sample = await b.tick(
            i_walk_resp_valid=0, i_vmu_done=0, i_int_take_armed=1, i_grant=1
        )
        no_publication(sample)
        assert int(dut.state_q.value) == FAULT_ARM
        assert int(dut.o_vmem_head_shield.value) == 0
        assert sample["o_vmem_fault_vstart_valid"] == 1
        assert sample["o_vmem_fault_vstart"] == 1

    # Withdraw interrupt: FAULT_ARM -> FAULT_SETTLE (shield rises) -> CDB_FAULT.
    no_publication(await b.tick(i_int_take_armed=0, i_grant=1))
    assert int(dut.state_q.value) == FAULT_SETTLE
    assert int(dut.o_vmem_head_shield.value) == 1
    no_publication(await b.tick(i_int_take_armed=0, i_grant=1))
    assert int(dut.state_q.value) == CDB_FAULT
    assert int(dut.o_vmem_head_shield.value) == 1
    sample = await b.tick(i_int_take_armed=0, i_grant=1)
    assert sample["o_cdb_done"] == 1
    assert sample["o_vmem_fault_vstart_valid"] == 1
    assert sample["o_vmem_fault_vstart"] == 1
    # Next cycle moves to WAIT_TRAP; synchronous trap flush clears back to IDLE.
    sample = await b.tick(i_grant=0)
    assert int(dut.state_q.value) == WAIT_TRAP
    assert int(dut.o_vmem_head_shield.value) == 1
    sample = await b.tick(i_flush_all=1, i_head_safe=0)
    no_publication(sample)
    assert sample["o_vmem_fault_vstart_valid"] == 1
    assert sample["o_vmem_fault_vstart"] == 1
    no_publication(await b.tick(i_flush_all=0, i_rob_empty=1, i_head_is_vmem=0))
    assert int(dut.state_q.value) == IDLE
    assert int(dut.run_started_q.value) == 0
    assert int(dut.o_vmem_head_shield.value) == 0
