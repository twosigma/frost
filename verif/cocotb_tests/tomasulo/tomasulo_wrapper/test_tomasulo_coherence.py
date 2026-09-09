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

"""Directed DMA-coherence tests at the Tomasulo wrapper.

The bench plays the cache hierarchy's coherence sequencer on the wrapper's
``i_coh_*`` / ``o_coh_*`` handshake (admit a line, invalidate it, release
it) against the core-side machinery in ``coherence/lq_coherence_port.sv``,
the load queue and the SC pending unit. Every race here is a cycle race
between an admission and an atomic, so each test sweeps the admission's
presentation cycle across the atomic's dispatch-to-launch window and
checks the order that results:

- an AMO never launches its read between the admission of its line and the
  release, whichever side comes first (an AMO already in flight refuses the
  admission until its write has completed);
- an SC never fires between the admission of its line and the release
  (an SC that fired first keeps the admission refused until its store has
  drained);
- a full flush landing on an SC's fire or on its window's opening cycle
  leaves the line admittable;
- a load that took its value from the store queue is validated like any
  other memory observation: a DMA write to its line flags it for replay.
"""

from typing import Any

import cocotb

from cocotb_tests.tomasulo.reorder_buffer.reorder_buffer_model import AllocationRequest
from cocotb_tests.tomasulo.tomasulo_wrapper.test_tomasulo_wrapper import (
    FU_FP_ADD,
    OP_ADD,
    OP_AMOSWAP_W,
    OP_LR_W,
    OP_LW,
    OP_SC_W,
    OP_SW,
    RS_INT,
    RS_MEM,
    make_int_req,
    make_store_req,
    setup_test,
    wait_for_cdb,
    wait_for_commit,
)
from cocotb_tests.tomasulo.tomasulo_wrapper.tomasulo_interface import TomasuloInterface

# A cached-tier line (coherence applies to cached lines only) and a word in it.
LINE = 0x8000_4000
WORD = LINE + 8
SLOT = 0
EXC_MEM_REPLAY = 24
OBSERVE_CYCLES = 20


def _mem_rs(tag: int, op: int, addr: int, value: int = 0) -> dict[str, Any]:
    return dict(
        rs_type=RS_MEM,
        rob_tag=tag,
        op=op,
        src1_ready=True,
        src1_value=addr,
        src2_ready=True,
        src2_value=value,
        src3_ready=True,
        imm=0,
        use_imm=True,
        mem_size=2,
        mem_signed=False,
    )


def _present_admit(dut: Any, addr: int = LINE) -> None:
    dut.i_coh_admit_valid.value = 1
    dut.i_coh_admit_slot.value = SLOT
    dut.i_coh_admit_addr.value = addr


def _drop_admit(dut: Any) -> None:
    dut.i_coh_admit_valid.value = 0


async def _release(dut: Any, dut_if: TomasuloInterface) -> None:
    dut.i_coh_release_valid.value = 1
    dut.i_coh_release_slot.value = SLOT
    await dut_if.step()
    dut.i_coh_release_valid.value = 0


def _mirror_holds(dut: Any) -> bool:
    return bool((int(dut.u_coherence_port.adm_valid_q.value) >> SLOT) & 1)


async def _wait_admitted(
    dut: Any, dut_if: TomasuloInterface, max_cycles: int = 16
) -> None:
    """With the admission presented, return with it dropped in the cycle after it fired.

    A fire the caller did not watch for shows in the port's mirror; presenting
    the slot any longer would re-admit a held line (the port asserts on it).
    """
    for _ in range(max_cycles):
        if _mirror_holds(dut):
            _drop_admit(dut)
            return
        if int(dut.o_coh_admit_ready.value):
            await dut_if.step()  # the fire edge
            _drop_admit(dut)
            return
        await dut_if.step()
    raise AssertionError("line never admitted")


async def _admit_now(dut: Any, dut_if: TomasuloInterface, max_cycles: int = 16) -> None:
    """Present an admission for LINE and return in the cycle after it fired."""
    _present_admit(dut)
    await dut_if.step()
    await _wait_admitted(dut, dut_if, max_cycles)


async def _invalidate_now(
    dut: Any, dut_if: TomasuloInterface, max_cycles: int = 16
) -> None:
    dut.i_coh_inval_valid.value = 1
    dut.i_coh_inval_slot.value = SLOT
    for _ in range(max_cycles):
        await dut_if.step()
        if int(dut.o_coh_inval_done.value):
            await dut_if.step()
            dut.i_coh_inval_valid.value = 0
            return
    raise AssertionError("invalidation never done")


async def _dispatch_amo(dut_if: TomasuloInterface) -> int:
    req = AllocationRequest(pc=0xA000, dest_reg=8, dest_valid=True, is_amo=True)
    tag = await dut_if.dispatch(req)
    dut_if.drive_rs_dispatch(**_mem_rs(tag, OP_AMOSWAP_W, WORD, value=1))
    await dut_if.step()
    dut_if.clear_rs_dispatch()
    return tag


async def _serve_amo(
    dut: Any, dut_if: TomasuloInterface, *, admit_presented: bool
) -> None:
    """Answer the AMO's read and complete its write.

    With the admission presented, prove it stays refused until the write has
    completed.
    """
    dut_if.drive_lq_mem_response(0x0)
    for label in ("before the AMO's response", "in the AMO's response cycle"):
        if admit_presented:
            assert not (
                int(dut.o_coh_admit_ready.value) or _mirror_holds(dut)
            ), f"admitted {label}"
        await dut_if.step()
    dut_if.clear_lq_mem_response()
    for _ in range(12):
        if admit_presented:
            assert not (
                int(dut.o_coh_admit_ready.value) or _mirror_holds(dut)
            ), "admitted with the AMO in flight"
        if dut_if.read_amo_mem_write()["en"]:
            break
        await dut_if.step()
    else:
        raise AssertionError("AMO never requested its write")
    for _ in range(3):  # the write phase also refuses the admission
        await dut_if.step()
        if admit_presented:
            assert not (
                int(dut.o_coh_admit_ready.value) or _mirror_holds(dut)
            ), "admitted in the AMO's write phase"
    dut_if.drive_amo_mem_write_done()
    await dut_if.step()
    dut_if.clear_amo_mem_write_done()


async def _finish_amo(
    dut_if: TomasuloInterface, tag: int, seen_cdb: bool = False
) -> None:
    """See the AMO through to retirement.

    It is the only instruction, so an empty ROB is its commit, however many
    cycles ago that happened.
    """
    if not seen_cdb:
        cdb = await wait_for_cdb(dut_if)
        assert cdb.tag == tag
    for _ in range(20):
        if dut_if.rob_empty:
            return
        await dut_if.step()
    raise AssertionError("AMO never retired")


async def _amo_admission_trial(dut: Any, dut_if: TomasuloInterface, offset: int) -> str:
    await dut_if.reset_dut()
    dut_if.set_fu_ready(
        RS_MEM, True
    )  # stays up: the AMO issues to the queue on its own
    tag = await _dispatch_amo(dut_if)

    presented = False
    dropped = False
    admit_seen: int | None = None  # ready seen in this cycle: fires at the next edge
    launched_at: int | None = (
        None  # read presented in this cycle: accepted at the next edge
    )
    for cyc in range(OBSERVE_CYCLES):
        if cyc == offset:
            _present_admit(dut)
            presented = True
        await dut_if.step()
        if presented and admit_seen is None:
            if _mirror_holds(dut):  # fired on this step's edge
                admit_seen = cyc
                _drop_admit(dut)
                dropped = True
            elif int(dut.o_coh_admit_ready.value):
                admit_seen = cyc  # fires on the next edge
        elif admit_seen is not None and not dropped:
            _drop_admit(dut)  # the fire edge has passed: present nothing further
            dropped = True
        if launched_at is None and dut_if.read_lq_mem_request()["en"]:
            launched_at = cyc
        if launched_at is not None and (admit_seen is None or dropped):
            break

    if launched_at is not None and (admit_seen is None or launched_at < admit_seen):
        # The AMO won: admission must wait for its write to complete.
        if admit_seen is not None:
            raise AssertionError(
                f"offset {offset}: admitted at {admit_seen} with the AMO in flight"
            )
        await _serve_amo(dut, dut_if, admit_presented=presented)
        if not presented:
            _present_admit(dut)
            await dut_if.step()
        # The write has completed: the admission may fire any cycle now, and
        # the AMO's completion may pass on the CDB meanwhile.
        seen_cdb = False
        for _ in range(16):
            cdb = dut_if.read_cdb_output()
            seen_cdb = seen_cdb or (cdb.valid and cdb.tag == tag)
            if _mirror_holds(dut) or int(dut.o_coh_admit_ready.value):
                break
            await dut_if.step()
        else:
            raise AssertionError(
                f"offset {offset}: never admitted after the AMO completed"
            )
        await _wait_admitted(dut, dut_if)
        await _release(dut, dut_if)
        await _finish_amo(dut_if, tag, seen_cdb)
        return "amo-first"

    assert admit_seen is not None, f"offset {offset}: nothing happened"
    assert (
        launched_at != admit_seen
    ), f"offset {offset}: AMO launched on the admission edge"
    assert (
        launched_at is None
    ), f"offset {offset}: AMO launched at {launched_at} after admission at {admit_seen}"
    # Admitted first: the AMO stays staged until the release.
    if not dropped:
        await dut_if.step()  # the fire edge
        _drop_admit(dut)
    for _ in range(OBSERVE_CYCLES):
        await dut_if.step()
        assert not dut_if.read_lq_mem_request()[
            "en"
        ], f"offset {offset}: AMO launched on an admitted line"
    await _release(dut, dut_if)
    for _ in range(12):
        await dut_if.step()
        if dut_if.read_lq_mem_request()["en"]:
            break
    else:
        raise AssertionError(f"offset {offset}: AMO never launched after the release")
    await _serve_amo(dut, dut_if, admit_presented=False)
    await _finish_amo(dut_if, tag)
    return "admit-first"


@cocotb.test()
async def test_amo_never_splits_across_admission(dut: Any) -> None:
    """Sweep the admission across the AMO's dispatch-to-launch window."""
    dut_if, _ = await setup_test(dut)
    outcomes = []
    for offset in range(0, 10):
        outcomes.append(await _amo_admission_trial(dut, dut_if, offset))
    cocotb.log.info(f"outcomes by offset: {outcomes}")
    assert "admit-first" in outcomes and "amo-first" in outcomes, outcomes


async def _lr_then_sc(
    dut: Any, dut_if: TomasuloInterface, admit_before: int = 0
) -> int:
    """Run an LR to WORD to completion and dispatch an SC to it; return the SC's tag.

    With admit_before > 0 the admission is presented that many cycles before
    the SC's dispatch (after the LR retired).
    """
    dut_if.set_fu_ready(RS_MEM, True)
    req_lr = AllocationRequest(pc=0x8000, dest_reg=5, dest_valid=True, is_lr=True)
    tag_lr = await dut_if.dispatch(req_lr)
    dut_if.drive_rs_dispatch(**_mem_rs(tag_lr, OP_LR_W, WORD))
    await dut_if.step()
    dut_if.clear_rs_dispatch()
    for _ in range(12):
        if dut_if.read_lq_mem_request()["en"]:
            break
        await dut_if.step()
    else:
        raise AssertionError("LR never launched")
    dut_if.drive_lq_mem_response(0x5)
    cdb = await wait_for_cdb(dut_if)
    dut_if.clear_lq_mem_response()
    assert cdb.tag == tag_lr
    commit = await wait_for_commit(dut_if)
    assert commit["tag"] == tag_lr
    if admit_before:
        _present_admit(dut)
        for _ in range(admit_before):
            await dut_if.step()

    req_sc = AllocationRequest(
        pc=0x8004, dest_reg=6, dest_valid=True, is_sc=True, is_store=True
    )
    dut_if.drive_alloc_request(req_sc)
    _, tag_sc, _ = dut_if.read_alloc_response()
    dut_if.drive_rat_rename(req_sc.dest_rf, req_sc.dest_reg, tag_sc)
    dut_if.drive_rs_dispatch(**_mem_rs(tag_sc, OP_SC_W, WORD, value=0x7))
    await dut_if.step()
    dut_if.clear_alloc_request()
    dut_if.clear_rat_rename()
    dut_if.clear_rs_dispatch()
    return tag_sc


async def _drain_one_store(
    dut: Any, dut_if: TomasuloInterface, max_cycles: int = 16
) -> None:
    for _ in range(max_cycles):
        if (
            dut_if.read_sq_mem_write()["en"]
            or int(dut.u_sq.write_inflight_cnt.value) != 0
        ):
            break
        await dut_if.step()
    else:
        raise AssertionError("store never drained")
    if int(dut.u_sq.write_inflight_cnt.value) == 0:
        await dut_if.step()
    dut_if.drive_sq_mem_write_done()
    await dut_if.step()
    dut_if.clear_sq_mem_write_done()
    await dut_if.step()


async def _sc_admission_trial(dut: Any, dut_if: TomasuloInterface, offset: int) -> str:
    """Run one SC trial with the admission presented at the given offset.

    A negative offset presents the admission that many cycles before the SC
    is dispatched, so the line can be admitted while the SC's address is not
    yet known at the head.
    """
    await dut_if.reset_dut()
    tag_sc = await _lr_then_sc(dut, dut_if, admit_before=max(0, -offset))

    presented = offset < 0
    dropped = False
    admit_seen: int | None = None
    fired_at: int | None = (
        None  # the SC's completion shows on the CDB the cycle after its fire
    )
    if presented and _mirror_holds(dut):
        admit_seen = -1  # admitted before the SC was even dispatched
        _drop_admit(dut)
        dropped = True
    for cyc in range(OBSERVE_CYCLES):
        if cyc == offset:
            _present_admit(dut)
            presented = True
        await dut_if.step()
        if presented and admit_seen is None:
            if _mirror_holds(dut):
                admit_seen = cyc
                _drop_admit(dut)
                dropped = True
            elif int(dut.o_coh_admit_ready.value):
                admit_seen = cyc
        elif admit_seen is not None and not dropped:
            _drop_admit(dut)
            dropped = True
        cdb = dut_if.read_cdb_output()
        if fired_at is None and cdb.valid and cdb.tag == tag_sc:
            fired_at = cyc - 1
        if fired_at is not None and (admit_seen is None or dropped):
            break

    if fired_at is not None and (admit_seen is None or fired_at < admit_seen):
        # The SC won: its window keeps the line refused until its store drains.
        if admit_seen is not None:
            raise AssertionError(
                f"offset {offset}: admitted at {admit_seen} inside the SC window"
            )
        commit = await wait_for_commit(dut_if)
        assert commit["tag"] == tag_sc
        if not presented:
            _present_admit(dut)
        for _ in range(4):
            await dut_if.step()
            assert not int(
                dut.o_coh_admit_ready.value
            ), f"offset {offset}: admitted before the SC's store drained"
        await _drain_one_store(dut, dut_if)
        await _wait_admitted(dut, dut_if)
        await _release(dut, dut_if)
        return "sc-first"

    assert admit_seen is not None, f"offset {offset}: nothing happened"
    assert fired_at != admit_seen, f"offset {offset}: SC fired on the admission edge"
    assert (
        fired_at is None
    ), f"offset {offset}: SC fired at {fired_at} after admission at {admit_seen}"
    if not dropped:
        await dut_if.step()  # the fire edge
        _drop_admit(dut)
    for _ in range(OBSERVE_CYCLES):
        await dut_if.step()
        cdb = dut_if.read_cdb_output()
        assert not (
            cdb.valid and cdb.tag == tag_sc
        ), f"offset {offset}: SC fired on an admitted line"
    await _release(dut, dut_if)
    cdb = await wait_for_cdb(dut_if)
    assert (
        cdb.tag == tag_sc and cdb.value == 0
    ), "SC should still succeed after the release"
    commit = await wait_for_commit(dut_if)
    assert commit["tag"] == tag_sc
    await _drain_one_store(dut, dut_if)
    return "admit-first"


@cocotb.test()
async def test_sc_never_fires_across_admission(dut: Any) -> None:
    """Sweep the admission across the SC's dispatch-to-fire window."""
    dut_if, _ = await setup_test(dut)
    outcomes = []
    for offset in range(-4, 12):
        outcomes.append(await _sc_admission_trial(dut, dut_if, offset))
    cocotb.log.info(f"outcomes by offset: {outcomes}")
    assert "admit-first" in outcomes and "sc-first" in outcomes, outcomes


@cocotb.test()
async def test_flushed_sc_leaves_line_admittable(dut: Any) -> None:
    """A full flush at any cycle around an SC's fire never leaves its window stuck open."""
    dut_if, _ = await setup_test(dut)
    for delay in range(0, 12):
        await dut_if.reset_dut()
        tag_sc = await _lr_then_sc(dut, dut_if)
        committed = False
        for _ in range(delay):
            await dut_if.step()
            if dut_if.read_commit()["valid"] and dut_if.read_commit()["tag"] == tag_sc:
                committed = True
        dut_if.drive_flush_all()
        await dut_if.step()
        dut_if.clear_flush_all()
        dut_if.set_fu_ready(RS_MEM, False)

        # An SC that committed before the flush owns a store that must drain;
        # a squashed one owns nothing. Either way the line is admittable soon.
        _present_admit(dut)
        for _ in range(40):
            if (
                dut_if.read_sq_mem_write()["en"]
                and int(dut.u_sq.write_inflight_cnt.value) == 0
            ):
                await dut_if.step()
                dut_if.drive_sq_mem_write_done()
                await dut_if.step()
                dut_if.clear_sq_mem_write_done()
            if _mirror_holds(dut) or int(dut.o_coh_admit_ready.value):
                break
            await dut_if.step()
        else:
            raise AssertionError(
                f"flush delay {delay} (committed={committed}): line never admittable"
            )
        await _wait_admitted(dut, dut_if)
        await _release(dut, dut_if)


@cocotb.test()
async def test_forwarded_load_is_validated(dut: Any) -> None:
    """A load that took its value from the store queue is replayed by a DMA write to its line."""
    dut_if, _ = await setup_test(dut)
    dut_if.set_fu_ready(RS_MEM, True)

    # An SW to WORD that stays uncommitted in the store queue ...
    tag_sw = await dut_if.dispatch(make_store_req(pc=0x3000))
    dut_if.drive_rs_dispatch(**_mem_rs(tag_sw, OP_SW, WORD, value=0x1111_2222))
    await dut_if.step()
    dut_if.clear_rs_dispatch()
    for _ in range(6):
        if dut_if.read_rs_issue_for(RS_MEM)["valid"]:
            break
        await dut_if.step()
    else:
        raise AssertionError("SW never issued")

    # ... and a younger LW to WORD that forwards from it, never touching memory.
    # Commits are held so both stay in flight while the DMA write lands.
    dut_if.set_commit_hold(True)
    tag_lw = await dut_if.dispatch(make_int_req(pc=0x3004, rd=7))
    dut_if.drive_rs_dispatch(**_mem_rs(tag_lw, OP_LW, WORD))
    await dut_if.step()
    dut_if.clear_rs_dispatch()
    for _ in range(20):
        await dut_if.step()
        assert not dut_if.read_lq_mem_request()[
            "en"
        ], "the load should forward, not launch"
        cdb = dut_if.read_cdb_output()
        if cdb.valid and cdb.tag == tag_lw:
            assert cdb.value == 0x1111_2222
            break
    else:
        raise AssertionError("forwarded load never completed")

    # A DMA write to the line: the forwarded load must be flagged for replay.
    await _admit_now(dut, dut_if)
    await _invalidate_now(dut, dut_if)
    assert (int(dut.u_rob.rob_replay.value) >> tag_lw) & 1, "forwarded load not flagged"
    assert (
        int(dut.u_rob.rob_exception.value) >> tag_lw
    ) & 1, "flag did not make the entry exceptional"
    await _release(dut, dut_if)

    # Let the store commit and drain; the load then reaches the head as a replay.
    dut_if.set_commit_hold(False)
    if not dut_if.head_done:
        dut_if.drive_fu_complete(FU_FP_ADD, tag=tag_sw, value=0)
        await dut_if.step()
        dut_if.clear_fu_complete(FU_FP_ADD)
    commit = await wait_for_commit(dut_if)
    assert commit["tag"] == tag_sw
    await _drain_one_store(dut, dut_if)
    for _ in range(20):
        if int(dut.o_trap_pending.value):
            break
        await dut_if.step()
    else:
        raise AssertionError("replay never reached the trap output")
    assert int(dut.o_trap_cause.value) == EXC_MEM_REPLAY


@cocotb.test()
async def test_flushed_forward_is_not_observed(dut: Any) -> None:
    """A forward killed by a partial flush in its own cycle leaves no table entry for its tag.

    The tag is reused right away by a load to another line; a DMA write to
    the flushed load's line must not flag it. The flush is swept across the
    forward's cycle.
    """
    dut_if, _ = await setup_test(dut)
    for offset in range(0, 5):
        await dut_if.reset_dut()
        dut_if.set_fu_ready(RS_MEM, True)
        dut_if.set_commit_hold(True)
        tag_sw = await dut_if.dispatch(make_store_req(pc=0x3000))
        dut_if.drive_rs_dispatch(**_mem_rs(tag_sw, OP_SW, WORD, value=0x3333_4444))
        await dut_if.step()
        dut_if.clear_rs_dispatch()
        for _ in range(6):
            if dut_if.read_rs_issue_for(RS_MEM)["valid"]:
                break
            await dut_if.step()
        tag_lw = await dut_if.dispatch(make_int_req(pc=0x3004, rd=7))
        dut_if.drive_rs_dispatch(**_mem_rs(tag_lw, OP_LW, WORD))
        await dut_if.step()
        dut_if.clear_rs_dispatch()
        for _ in range(offset):
            await dut_if.step()
        dut_if.drive_flush_en(tag_sw)  # kills everything younger than the store
        await dut_if.step()
        dut_if.clear_flush_en()
        await dut_if.step()

        # The freed tag is reused by an ALU op, which observes no memory: a
        # stale entry for the tag would flag it (a load would have replaced
        # the entry with its own observation and hidden the stale one).
        tag_new = await dut_if.dispatch(make_int_req(pc=0x3008, rd=8))
        assert tag_new == tag_lw, f"offset {offset}: expected tag reuse, got {tag_new}"
        dut_if.drive_rs_dispatch(
            rs_type=RS_INT,
            rob_tag=tag_new,
            op=OP_ADD,
            src1_ready=True,
            src1_value=1,
            src2_ready=True,
            src2_value=2,
            src3_ready=True,
        )
        await dut_if.step()
        dut_if.clear_rs_dispatch()
        await dut_if.step()

        await _admit_now(dut, dut_if)
        await _invalidate_now(dut, dut_if)
        assert not (
            (int(dut.u_rob.rob_replay.value) >> tag_new) & 1
        ), f"offset {offset}: the flushed forward's observation flagged the reused tag"
        await _release(dut, dut_if)
        dut_if.set_commit_hold(False)
        dut_if.set_fu_ready(RS_MEM, False)


@cocotb.test()
async def test_surviving_forward_is_observed(dut: Any) -> None:
    """A forward completing in the cycle a partial flush kills a younger op is still validated.

    Store S, load L (forwards from S), ALU op B; a partial flush at L's tag
    kills B only, swept across L's forward cycle. A DMA write to L's line
    must flag L whichever cycle the flush landed in.
    """
    dut_if, _ = await setup_test(dut)
    for offset in range(0, 5):
        await dut_if.reset_dut()
        dut_if.set_fu_ready(RS_MEM, True)
        dut_if.set_commit_hold(True)
        tag_sw = await dut_if.dispatch(make_store_req(pc=0x3000))
        dut_if.drive_rs_dispatch(**_mem_rs(tag_sw, OP_SW, WORD, value=0x5555_6666))
        await dut_if.step()
        dut_if.clear_rs_dispatch()
        for _ in range(6):
            if dut_if.read_rs_issue_for(RS_MEM)["valid"]:
                break
            await dut_if.step()
        tag_lw = await dut_if.dispatch(make_int_req(pc=0x3004, rd=7))
        dut_if.drive_rs_dispatch(**_mem_rs(tag_lw, OP_LW, WORD))
        await dut_if.step()
        dut_if.clear_rs_dispatch()
        tag_b = await dut_if.dispatch(make_int_req(pc=0x3008, rd=8))
        assert tag_b != tag_lw

        def _lw_completed() -> bool:
            cdb = dut_if.read_cdb_output()
            if cdb.valid and cdb.tag == tag_lw:
                assert cdb.value == 0x5555_6666
                return True
            return False

        # The load may complete before, during or after the flush cycle.
        completed = _lw_completed()
        for _ in range(offset):
            await dut_if.step()
            completed = completed or _lw_completed()
        dut_if.drive_flush_en(tag_lw)  # kills B, L survives
        await dut_if.step()
        completed = completed or _lw_completed()
        dut_if.clear_flush_en()
        for _ in range(20):
            if completed:
                break
            await dut_if.step()
            completed = completed or _lw_completed()
        else:
            raise AssertionError(f"offset {offset}: the surviving load never completed")

        await _admit_now(dut, dut_if)
        await _invalidate_now(dut, dut_if)
        assert (
            int(dut.u_rob.rob_replay.value) >> tag_lw
        ) & 1, f"offset {offset}: the surviving forwarded load was not validated"
        await _release(dut, dut_if)
        dut_if.set_commit_hold(False)
        dut_if.set_fu_ready(RS_MEM, False)
