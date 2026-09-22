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

"""Accepted-load wakeup through the production MEM reservation station.

Sweep dispatch across the early and registered copies, with either CDB lane
occupied, and check address/data capture and exactly-once issue. Recovery
tests suppress the early copy while killing a waiting dependent instruction.
"""

from typing import Any

import cocotb
from cocotb.triggers import Timer

from .test_tomasulo_wrapper import (
    FU_ALU,
    FU_MUL,
    RS_MEM,
    _parse_instr_op_enum,
    make_int_req,
    make_store_req,
    setup_test,
)

OPS = _parse_instr_op_enum()


@cocotb.test()
async def test_load_wakeup_dispatch_and_recovery(dut: Any) -> None:
    """An early load wakes dependent loads/stores without losing registered CDBs.

    Recovery does not qualify the early token: MEM_RS cannot issue in a
    recovery cycle, and a flushed consumer must never issue afterwards,
    whether recovery keeps the producer ("partial") or discards it too
    ("producer", "full"). A consumer that survives recovery ("survivor")
    keeps the early value and issues exactly once, after recovery.
    """
    iface, _ = await setup_test(dut)
    for store in (False, True):
        for occupied in range(3):
            for delay, flush in [(d, "") for d in range(-3, 3)] + [
                (-3, "partial"),
                (-3, "producer"),
                (-3, "survivor"),
                (-3, "full"),
            ]:
                await iface.reset_dut()
                iface.set_fu_ready(RS_MEM, True)
                # Keep results unretired while observing both copies of the CDB.
                oldest_tag = await iface.dispatch(make_int_req(rd=1))
                fillers = [await iface.dispatch(make_int_req(rd=r)) for r in (2, 3)]
                load_tag = await iface.dispatch(make_int_req(rd=4))
                dependent_tag = await iface.dispatch(
                    make_store_req() if store else make_int_req(rd=5)
                )
                iface.drive_rs_dispatch(
                    rs_type=RS_MEM,
                    rob_tag=load_tag,
                    op=OPS["LD"],
                    src1_ready=True,
                    src1_value=0x2000,
                    src2_ready=True,
                    src3_ready=True,
                    use_imm=True,
                    imm=0,
                )
                await iface.step()
                iface.clear_rs_dispatch()
                for _ in range(30):
                    request = iface.read_lq_mem_request()
                    if request["en"]:
                        break
                    await iface.step()
                else:
                    raise AssertionError("producer load never launched")
                assert request["addr"] == 0x2000
                await iface.step()  # establish the outstanding request
                value = 0xDEAD_BEEF_1234_5678 if store else 0x3000
                issues = []
                for cycle in range(-4, 40):
                    iface.clear_rs_dispatch()
                    iface.clear_lq_mem_response()
                    iface.clear_all_fu_completes()
                    if cycle == delay:
                        iface.drive_rs_dispatch(
                            rs_type=RS_MEM,
                            rob_tag=dependent_tag,
                            op=OPS["SD" if store else "LD"],
                            src1_ready=store,
                            src1_value=0x4000,
                            src1_tag=load_tag,
                            src2_ready=not store,
                            src2_tag=load_tag,
                            src3_ready=True,
                            use_imm=True,
                            imm=0,
                        )
                    if cycle == 0:
                        iface.drive_lq_mem_response(value, dword=True)
                        for slot, tag in zip((FU_ALU, FU_MUL), fillers[:occupied]):
                            iface.drive_fu_complete(slot, tag, value=0xBAD0 + tag)
                    if cycle == 1 and flush:
                        if flush == "full":
                            iface.drive_flush_all()
                        elif flush == "producer":
                            iface.drive_flush_en(oldest_tag)
                        elif flush == "survivor":
                            iface.drive_flush_en(dependent_tag)
                        else:
                            iface.drive_flush_en(load_tag)
                    await Timer(1, unit="ps")
                    if cycle == 1:
                        assert bool(dut.mem_rs_early_load_injected.value) == (
                            occupied < 2
                        ), (store, occupied, delay, flush)
                    issue = iface.read_rs_issue_for(RS_MEM)
                    if issue["valid"] and issue["rob_tag"] == dependent_tag:
                        assert flush in ("", "survivor")
                        assert not (flush and cycle <= 1)
                        assert issue["src2_value" if store else "src1_value"] == value
                        issues.append(cycle)
                    await iface.step()
                    if cycle == 1:
                        iface.clear_flush_all()
                        iface.clear_flush_en()
                assert len(issues) == (1 if flush in ("", "survivor") else 0), (
                    store,
                    occupied,
                    delay,
                    flush,
                    issues,
                )
