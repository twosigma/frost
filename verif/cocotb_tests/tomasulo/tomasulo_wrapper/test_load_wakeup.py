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

"""Early-load wakeup through the integer and memory stations."""

from itertools import product
from typing import Any

import cocotb
from cocotb.triggers import Timer

from cocotb_tests.tomasulo.cdb_arbiter.cdb_arbiter_interface import (
    unpack_cdb_broadcast,
)

from .test_tomasulo_wrapper import (
    FU_ALU,
    FU_MUL,
    RS_INT,
    RS_MEM,
    _parse_instr_op_enum,
    make_int_req,
    make_store_req,
    setup_test,
)

OPS = _parse_instr_op_enum()


@cocotb.test()
async def test_load_wakeup_dispatch_and_recovery(dut: Any) -> None:
    """Check dependent load/store wakeups around early and registered load results.

    Busy CDB lanes must retain their broadcasts. Recovery does not gate the
    early result: MEM_RS blocks issue during recovery, killed consumers
    never issue, and surviving consumers keep the value and issue once.
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
                # The oldest entry never completes, so nothing retires and
                # every tag stays live while both CDB copies are observed.
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


@cocotb.test()
async def test_integer_load_wakeup(dut: Any) -> None:
    """Check both integer ports, dispatch delivery, lane contention and recovery."""
    iface, _ = await setup_test(dut)
    value = 0xDEAD_BEEF_1234_5678
    for occupied, swapped in product(range(3), (False, True)):
        for delay, flush, stall in [
            *((d, "", "") for d in range(-3, 4)),
            (-3, "", "resident"),
            (-3, "", "stage2"),
            (-3, "partial", ""),
            (-3, "producer", ""),
            (-3, "survivor", ""),
            (-3, "full", ""),
        ]:
            await iface.reset_dut()
            iface.set_fu_ready(RS_MEM, True)
            iface.set_fu_ready(RS_INT, True)
            oldest = await iface.dispatch(make_int_req(rd=1))
            fillers = [await iface.dispatch(make_int_req(rd=r)) for r in (2, 3)]
            producer = await iface.dispatch(make_int_req(rd=4))
            consumers = [await iface.dispatch(make_int_req(rd=r)) for r in (5, 6)]
            iface.drive_rs_dispatch(
                rs_type=RS_MEM,
                rob_tag=producer,
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
                if iface.read_lq_mem_request()["en"]:
                    break
                await iface.step()
            else:
                raise AssertionError("producer load never launched")
            await iface.step()
            issues: dict[int, list[tuple[int, int]]] = {tag: [] for tag in consumers}
            completions: dict[int, list[int]] = {tag: [] for tag in consumers}
            for cycle in range(-4, 24):
                iface.clear_rs_dispatch()
                iface.clear_dispatch_bypasses()
                iface.clear_lq_mem_response()
                iface.clear_all_fu_completes()
                if cycle in (delay + 1, delay + 2):
                    channel = 1 + ((cycle - delay - 1) ^ swapped)
                    iface.drive_dispatch_bypass(channel, producer)
                iface.set_fu_ready(
                    RS_INT,
                    not (
                        (stall == "resident" and cycle < 5)
                        or (stall == "stage2" and 2 <= cycle < 5)
                    ),
                )
                if cycle in (delay, delay + 1):
                    index = cycle - delay
                    operation = index ^ swapped
                    iface.drive_rs_dispatch(
                        rs_type=RS_INT,
                        rob_tag=consumers[index],
                        op=OPS["ADD" if operation == 0 else "SRL"],
                        src1_ready=operation == 1,
                        src1_value=0xFEDC_BA98_7654_3210,
                        src1_tag=producer,
                        src2_ready=operation == 0,
                        src2_value=7,
                        src2_tag=producer,
                        src3_ready=True,
                    )
                if cycle == 0:
                    iface.drive_lq_mem_response(value, dword=True)
                    for slot, tag in zip((FU_ALU, FU_MUL), fillers[:occupied]):
                        iface.drive_fu_complete(slot, tag, value=0xBAD0 + tag)
                if cycle == 1 and flush:
                    if flush == "full":
                        iface.drive_flush_all()
                    else:
                        iface.drive_flush_en(
                            {
                                "partial": producer,
                                "producer": oldest,
                                "survivor": consumers[-1],
                            }[flush]
                        )
                await Timer(1, unit="ps")
                for port, issue in enumerate(
                    (iface.read_rs_issue(), iface.read_int_rs_issue_2())
                ):
                    tag = issue["rob_tag"]
                    if issue["valid"] and tag in issues:
                        assert flush in ("", "survivor")
                        operation = consumers.index(tag) ^ swapped
                        assert issue["src1_value"] == (
                            value if operation == 0 else 0xFEDC_BA98_7654_3210
                        )
                        assert issue["src2_value"] == (7 if operation == 0 else value)
                        if port == 1 and operation == 1:
                            assert (
                                int(dut.int_rs_issue_shift_amount_2.value) == value & 63
                            )
                        issues[tag].append((cycle, port))
                for signal in (dut.o_cdb, dut.o_cdb_2):
                    packet = unpack_cdb_broadcast(int(signal.value))
                    if packet.valid and packet.tag in completions:
                        assert not packet.exception
                        completions[packet.tag].append(packet.value)
                await iface.step()
                if cycle == 1:
                    iface.clear_flush_all()
                    iface.clear_flush_en()
            context = (occupied, swapped, delay, flush, stall, issues)
            for tag in consumers:
                assert len(issues[tag]) == (1 if flush in ("", "survivor") else 0), (
                    context
                )
            expected_values = [
                (value + 7) & ((1 << 64) - 1),
                0xFEDC_BA98_7654_3210 >> (value & 63),
            ]
            if swapped:
                expected_values.reverse()
            for tag, result in zip(consumers, expected_values):
                assert completions[tag] == (
                    [result] if flush in ("", "survivor") else []
                ), context
            if delay == -3 and not flush and not stall:
                expected = 2 if occupied < 2 else 3
                assert issues[consumers[0]] == [(expected, 0)], context
                assert issues[consumers[1]] == [(expected, 1)], context


@cocotb.test()
async def test_integer_load_operands_hold(dut: Any) -> None:
    """Hold both issue packets across another load and unrelated broadcasts."""
    iface, _ = await setup_test(dut)
    iface.set_fu_ready(RS_MEM, True)
    iface.set_fu_ready(RS_INT, True)
    iface.set_commit_hold(True)
    tags = [await iface.dispatch(make_int_req(rd=r)) for r in range(1, 7)]
    value = 0xDEAD_BEEF_1234_5678
    other_value = 0x0123_4567_89AB_CD03

    async def launch_load(tag: int, address: int) -> None:
        iface.drive_rs_dispatch(
            rs_type=RS_MEM,
            rob_tag=tag,
            op=OPS["LD"],
            src1_ready=True,
            src1_value=address,
            src2_ready=True,
            src3_ready=True,
            use_imm=True,
        )
        await iface.step()
        iface.clear_rs_dispatch()
        for _ in range(30):
            if iface.read_lq_mem_request()["en"]:
                await iface.step()
                return
            await iface.step()
        raise AssertionError("load never launched")

    await launch_load(tags[0], 0x2000)
    for index, tag in enumerate(tags[1:3]):
        iface.drive_rs_dispatch(
            rs_type=RS_INT,
            rob_tag=tag,
            op=OPS["ADD" if index == 0 else "SRL"],
            src1_ready=index == 1,
            src1_value=0xFEDC_BA98_7654_3210,
            src1_tag=tags[0],
            src2_ready=index == 0,
            src2_value=7,
            src2_tag=tags[0],
            src3_ready=True,
        )
        await iface.step()
    iface.clear_rs_dispatch()
    iface.drive_lq_mem_response(value, dword=True)
    await iface.step()
    iface.clear_lq_mem_response()
    await iface.step()
    assert iface.read_rs_issue()["valid"]
    assert iface.read_int_rs_issue_2()["valid"]
    iface.set_fu_ready(RS_INT, False)

    def check_held() -> None:
        for index, issue in enumerate(
            (iface.read_rs_issue(), iface.read_int_rs_issue_2())
        ):
            assert issue["rob_tag"] == tags[index + 1]
            assert issue["src1_value"] == (
                value if index == 0 else 0xFEDC_BA98_7654_3210
            )
            assert issue["src2_value"] == (7 if index == 0 else value)
        assert int(dut.int_rs_issue_shift_amount_2.value) == value & 63

    await launch_load(tags[3], 0x3000)
    iface.drive_fu_complete(FU_ALU, tags[4], value=0x1111)
    iface.drive_fu_complete(FU_MUL, tags[5], value=0x2222)
    await iface.step()
    iface.clear_all_fu_completes()
    iface.drive_lq_mem_response(other_value, dword=True)
    seen_other = False
    for cycle in range(8):
        await Timer(1, unit="ps")
        check_held()
        for signal in (dut.o_cdb, dut.o_cdb_2):
            packet = unpack_cdb_broadcast(int(signal.value))
            if packet.valid and packet.tag == tags[3]:
                assert packet.value == other_value
                seen_other = True
        await iface.step()
        if cycle == 0:
            iface.clear_lq_mem_response()
    assert seen_other
    iface.set_fu_ready(RS_INT, True)
    iface.set_commit_hold(False)
    expected = dict(
        zip(
            tags,
            [
                value,
                (value + 7) & ((1 << 64) - 1),
                0xFEDC_BA98_7654_3210 >> (value & 63),
                other_value,
                0x1111,
                0x2222,
            ],
        )
    )
    retired = []
    for _ in range(20):
        await Timer(1, unit="ps")
        for commit in (iface.read_commit(), iface.read_commit_2()):
            if commit["valid"]:
                assert commit["value"] == expected[commit["tag"]]
                retired.append(commit["tag"])
        await iface.step()
    assert retired == tags
    assert iface.rob_empty


@cocotb.test()
async def test_integer_load_recovery_and_reuse(dut: Any) -> None:
    """Kill deferred or issued operands, reuse their tags, and retire through wrap."""
    iface, _ = await setup_test(dut)
    for full, deferred in product((False, True), repeat=2):
        await iface.reset_dut()
        iface.set_fu_ready(RS_MEM, True)
        iface.set_fu_ready(RS_INT, True)
        iface.set_commit_hold(True)
        anchor, producer, consumer = [
            await iface.dispatch(make_int_req(rd=r)) for r in (1, 2, 3)
        ]

        async def launch_load(tag: int, address: int) -> None:
            iface.drive_rs_dispatch(
                rs_type=RS_MEM,
                rob_tag=tag,
                op=OPS["LD"],
                src1_ready=True,
                src1_value=address,
                src2_ready=True,
                src3_ready=True,
                use_imm=True,
            )
            await iface.step()
            iface.clear_rs_dispatch()
            for _ in range(30):
                if iface.read_lq_mem_request()["en"]:
                    await iface.step()
                    return
                await iface.step()
            raise AssertionError("load never launched")

        def dispatch_consumer(tag: int, source: int) -> None:
            iface.drive_rs_dispatch(
                rs_type=RS_INT,
                rob_tag=tag,
                op=OPS["ADD"],
                src1_ready=False,
                src1_tag=source,
                src2_ready=True,
                src2_value=7,
                src3_ready=True,
            )

        await launch_load(producer, 0x2000)
        for cycle in range(-3, 3):
            iface.clear_rs_dispatch()
            iface.clear_lq_mem_response()
            if cycle == (1 if deferred else -3):
                dispatch_consumer(consumer, producer)
            if cycle == 0:
                iface.drive_lq_mem_response(0xBAD0_0038, dword=True)
            if cycle == 2:
                iface.set_fu_ready(RS_INT, False)
                if full:
                    iface.drive_flush_all()
                else:
                    iface.drive_flush_en(anchor)
            await iface.step()
        iface.clear_flush_all()
        iface.clear_flush_en()
        iface.clear_rs_dispatch()
        iface.set_fu_ready(RS_INT, True)
        await Timer(1, unit="ps")
        reused: set[int] = set()
        for iteration in range(20):
            iface.set_commit_hold(True)
            source = await iface.dispatch(make_int_req(rd=4))
            dependent = await iface.dispatch(make_int_req(rd=5))
            reused.update((source, dependent))
            await launch_load(source, 0x3000 + 64 * iteration)
            dispatch_consumer(dependent, source)
            await iface.step()
            iface.clear_rs_dispatch()
            iface.drive_dispatch_bypass(1, source)
            await iface.step()
            iface.clear_dispatch_bypasses()
            for _ in range(6):
                assert not iface.read_rs_issue()["valid"]
                assert not iface.read_int_rs_issue_2()["valid"]
                await iface.step()
            value = 0x7654_3200 + iteration
            iface.drive_lq_mem_response(value, dword=True)
            await iface.step()
            iface.clear_lq_mem_response()
            expected = {source: value, dependent: value + 7}
            if iteration == 0 and not full:
                iface.drive_fu_complete(FU_ALU, anchor, value=0x1234)
                expected[anchor] = 0x1234
                await iface.step()
                iface.clear_all_fu_completes()
            iface.set_commit_hold(False)
            retired = {}
            for _ in range(20):
                await Timer(1, unit="ps")
                for commit in (iface.read_commit(), iface.read_commit_2()):
                    if commit["valid"]:
                        tag = commit["tag"]
                        assert tag not in retired
                        retired[tag] = commit["value"]
                await iface.step()
            assert retired == expected, (full, deferred, iteration, retired, expected)
            assert iface.rob_empty
        assert {producer, consumer} <= reused
