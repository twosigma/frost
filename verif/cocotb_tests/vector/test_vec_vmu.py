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

"""Byte-accurate VMU checks with delayed, reordered responses and request stalls."""

import random
from typing import Any

import cocotb
from cocotb.triggers import Timer


async def edge(dut: Any) -> None:
    """Advance one edge, leaving the clock low for input changes."""
    dut.i_clk.value = 1
    await Timer(1, unit="ns")
    dut.i_clk.value = 0
    await Timer(1, unit="ns")


def put(dut: Any, **values: int) -> None:
    """Write the named input ports."""
    for name, value in values.items():
        getattr(dut, "i_" + name).value = value


@cocotb.test()
async def test_sectors_and_writeback(dut: Any) -> None:
    """Check active bytes, unique ordered sectors, and stalled preparation."""
    rng = random.Random(0x4C)
    vlen = len(dut.i_active_mask)
    regbytes = vlen // 8
    stalled_slots = 0
    reordered = 0
    for case in range(36):
        store = case % 2
        eew = (case // 2) % 4
        first = case % 3
        last = min(vlen - 1, regbytes * 8 // (1 << eew) - 1)
        offset = [0, 1, 31, 4093][(case // 8) % 4]
        active = sum(1 << e for e in range(first, last + 1) if case < 8 or e % 3 != 1)
        if case >= 32:
            # A partial page-fault descriptor ends at element one even though
            # the original instruction's mask enables the faulting suffix.
            eew, first, last, offset = 2, 0, 1, 4088
            active = (1 << vlen) - 1
            if case >= 34:
                # Element one would straddle the page boundary. Its first
                # byte shares the last issued sector and must stay untouched.
                eew, last, offset = 3, 0, 4087
        regs = [bytearray(rng.randbytes(regbytes)) for _ in range(32)]
        original = [bytes(r) for r in regs]
        # Model the descriptor as a byte interval; page one is deliberately
        # non-contiguous with page zero.
        expected: dict[int, dict[int, int]] = {}
        for e in range(first, last + 1):
            if not (active >> e) & 1:
                continue
            for b in range(1 << eew):
                vb = (e << eew) + b
                linear = offset + vb - (first << eew)
                pa = ((0x83100 if linear >= 4096 else 0x83000) << 12) + (linear & 4095)
                expected.setdefault(pa & ~31, {})[pa & 31] = vb
        addresses = sorted(expected)
        wanted = [bytearray(r) for r in regs]
        for pa, mapping in expected.items():
            for b, vb in mapping.items():
                if not store:
                    wanted[8 + vb // regbytes][vb % regbytes] = (
                        (pa + b) * 13 + 7
                    ) & 255
        segbits = len(dut.i_dbg_seg0)
        ppnbits = segbits - 15
        seg0 = (1 << (ppnbits + 14)) | (0x83000 << 14) | 127
        seg1 = (1 << (ppnbits + 14)) | (0x83100 << 14) | 127
        put(
            dut,
            clk=0,
            rst=1,
            fatal_stop=0,
            cmd_valid=0,
            ppn0=0x83000,
            ppn1=0x83100,
            page_offset=offset,
            first_elem=first,
            last_elem=last,
            eew_log2=eew,
            row_stride=0,
            row_count=1,
            active_mask=active,
            is_store=store,
            vd_vs3=8,
            vmt_idx=2,
            free_vmt_on_done=case % 3 != 0,
            dbg_seg0=seg0,
            dbg_seg1=seg1,
            xr_data=0,
            lc_req_ready=0,
            lc_resp_valid=0,
            lc_resp_id=2,
            lc_resp_data=0,
            lc_resp_error=0,
        )
        await edge(dut)
        await edge(dut)
        put(dut, rst=0, cmd_valid=1)
        await edge(dut)
        put(dut, cmd_valid=0)
        pending: dict[int, tuple[int, int]] = {}
        issued: list[int] = []
        previous_prep = None
        previous_request = None
        for cycle in range(3000):
            ready = cycle % 13 >= 5
            put(dut, lc_req_ready=ready, lc_resp_valid=0)
            if pending and cycle > 180 and rng.randrange(3) != 0:
                ids = list(pending)
                rid = rng.choice(ids)
                reordered += rid != ids[0]
                pa, _ = pending.pop(rid)
                data = int.from_bytes(
                    bytes(((pa + b) * 13 + 7) & 255 for b in range(32)), "little"
                )
                put(dut, lc_resp_valid=1, lc_resp_id=rid, lc_resp_data=data)
            await Timer(1, unit="ns")
            prep = tuple(
                int(getattr(dut, n).value)
                for n in (
                    "prep_vrf_base_q",
                    "prep_vrf_base_rep_q",
                    "prep_reg_lo_q",
                    "prep_reg_hi_q",
                    "prep_pa_q",
                    "prep_byte_mask_q",
                    "prep_byte_any_grp_q",
                )
            )
            if previous_prep is not None:
                assert prep == previous_prep, (
                    "sector preparation changed while its slot was full"
                )
            full = int(dut.buf_valid_q.value) >> int(dut.alloc_ptr_q.value) & 1
            previous_prep = prep if int(dut.issue_state_q.value) == 3 and full else None
            stalled_slots += previous_prep is not None
            request = tuple(
                int(getattr(dut, "o_lc_req_" + n).value)
                for n in ("addr", "data", "mask", "id", "write")
            )
            if previous_request is not None:
                assert int(dut.o_lc_req_valid.value) and request == previous_request
            previous_request = (
                request if int(dut.o_lc_req_valid.value) and not ready else None
            )
            if int(dut.o_lc_req_valid.value) and ready:
                pa, data, mask, rid, write = request
                assert write == store and rid not in pending and 2 <= rid <= 7
                assert len(issued) < len(addresses) and pa == addresses[len(issued)], (
                    "sector duplicated, skipped or reordered"
                )
                issued.append(pa)
                if store:
                    assert mask == sum(1 << b for b in expected[pa])
                    for b, vb in expected[pa].items():
                        assert (data >> (8 * b)) & 255 == original[8 + vb // regbytes][
                            vb % regbytes
                        ]
                pending[rid] = (pa, cycle)
            if int(dut.o_xw_en.value):
                assert not store
                addr, be, data = (
                    int(getattr(dut, "o_xw_" + n).value) for n in ("addr", "be", "data")
                )
                for b in range(regbytes):
                    if be >> b & 1:
                        vb = (addr - 8) * regbytes + b
                        assert (
                            first <= (vb >> eew) <= last and active >> (vb >> eew) & 1
                        ), "write beyond active/fault boundary"
                        regs[addr][b] = data >> (8 * b) & 255
            xr = (
                int.from_bytes(regs[int(dut.o_xr_addr.value)], "little")
                if int(dut.o_xr_en.value)
                else 0
            )
            done = int(dut.o_done.value)
            if done:
                assert not pending and issued == addresses
                assert int(dut.o_vmt_done_valid.value) == (case % 3 != 0)
                assert regs == wanted
                break
            await edge(dut)
            put(dut, xr_data=xr)
        else:
            raise AssertionError("VMU did not release all identities")
    if vlen >= 256:
        assert stalled_slots > 0
    assert reordered > 0
    cocotb.log.info(
        "slot-stall cycles=%d reordered replies=%d", stalled_slots, reordered
    )


@cocotb.test()
async def test_response_error_is_fatal(dut: Any) -> None:
    """An errored sector cannot update the VRF or release its VMT entry."""
    ppnbits = len(dut.i_dbg_seg0) - 15
    put(
        dut,
        clk=0,
        rst=1,
        fatal_stop=0,
        cmd_valid=0,
        ppn0=0x83000,
        ppn1=0x83100,
        page_offset=0,
        first_elem=0,
        last_elem=15,
        eew_log2=0,
        row_stride=0,
        row_count=1,
        active_mask=0xFFFF,
        is_store=0,
        vd_vs3=8,
        vmt_idx=2,
        free_vmt_on_done=1,
        dbg_seg0=(1 << (ppnbits + 14)) | (0x83000 << 14),
        dbg_seg1=0,
        xr_data=0,
        lc_req_ready=1,
        lc_resp_valid=0,
        lc_resp_id=2,
        lc_resp_data=0,
        lc_resp_error=0,
    )
    await edge(dut)
    put(dut, rst=0, cmd_valid=1)
    await edge(dut)
    put(dut, cmd_valid=0)
    for _ in range(30):
        if int(dut.o_lc_req_valid.value):
            rid = int(dut.o_lc_req_id.value)
            break
        await edge(dut)
    else:
        raise AssertionError("no request to fault")
    await edge(dut)
    put(dut, lc_resp_valid=1, lc_resp_id=rid, lc_resp_error=1)
    await edge(dut)
    put(dut, lc_resp_valid=0, lc_resp_error=0)
    for _ in range(20):
        assert int(dut.o_fatal.value)
        assert int(dut.o_fatal_addr.value) == 0x83000000
        assert not int(dut.o_xw_en.value)
        assert not int(dut.o_vmt_done_valid.value)
        assert not int(dut.o_done.value)
        await edge(dut)
    put(dut, rst=1)
    await edge(dut)
    assert int(dut.o_idle.value) and not int(dut.o_fatal.value)
