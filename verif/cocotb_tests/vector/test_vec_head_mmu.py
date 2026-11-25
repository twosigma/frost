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

"""Head translation, precommit shield, and precise partial-fault descriptors."""

from typing import Any

import cocotb
from cocotb.triggers import Timer

from cocotb_tests.cpu_structs import PTW_RESP_FIELDS
from cocotb_tests.vector.test_vec_vmu import edge, put
from utils.packed_structs import pack_struct


@cocotb.test()
async def test_translation_and_commit(dut: Any) -> None:
    """A stalled walk or SQ prevents launch, and Case C stops before page one."""
    vlen = len(dut.i_vrf_read_data)
    for store in (0, 1):
        for fault_page, offset in ((-1, 4088), (0, 4088), (1, 4088), (1, 4094)):
            insn = (
                (1 << 25)
                | (10 << 15)
                | (6 << 12)
                | (8 << 7)
                | (0x27 if store else 0x07)
            )
            put(
                dut,
                clk=0,
                rst=1,
                head_tag=3,
                rob_empty=0,
                head_safe=1,
                head_is_vmem=1,
                head_insn=insn,
                head_vmt_idx=1,
                flush_all=0,
                fatal_stop=0,
                commit_valid=0,
                commit_tag=3,
                commit_exception=0,
                vec_idle=1,
                csr_wb_pending=0,
                sq_committed_empty=0,
                int_take_armed=0,
                vl=4,
                vtype=0x10,
                vstart=0,
                rf_read_data=0x00400000 + offset,
                vrf_read_data=(1 << vlen) - 1,
                translate=1,
                eff_priv_u=0,
                sum=0,
                mxr=0,
                pm_mode=0,
                tlb_invalidate=0,
                walk_req_ready=0,
                walk_resp_valid=0,
                walk_resp=0,
                grant=0,
                vmu_done=0,
                vmu_fatal=0,
            )
            await edge(dut)
            await edge(dut)
            put(dut, rst=0)
            walks = 0
            response = None
            launched = False
            shield_previous = False
            completion = None
            commit_at = None
            partial_at = None
            for cycle in range(300):
                put(
                    dut,
                    walk_resp_valid=0,
                    walk_req_ready=cycle % 7 == 0,
                    sq_committed_empty=cycle >= 90,
                    grant=0,
                    commit_valid=0,
                    vmu_done=0,
                )
                if response is not None and cycle == response[0]:
                    _, page, vpn = response
                    put(
                        dut,
                        walk_resp_valid=1,
                        walk_resp=pack_struct(
                            PTW_RESP_FIELDS,
                            {
                                "vpn": vpn,
                                "ppn": 0x83000 + page * 16,
                                "perm_r": 1,
                                "perm_w": 1,
                                "perm_d": 1,
                                "fault_kind": 2 if page == fault_page else 0,
                            },
                        ),
                    )
                    response = None
                if commit_at == cycle:
                    put(dut, commit_valid=1)
                if partial_at is not None and cycle == partial_at + 8:
                    put(dut, vmu_done=1)
                if completion is not None and cycle == completion + 5:
                    put(dut, grant=1)
                    commit_at = cycle + 2 if fault_page < 0 else None
                await Timer(1, unit="ns")
                if int(dut.o_walk_req_valid.value) and cycle % 7 == 0:
                    assert response is None
                    vpn = int(dut.o_walk_vpn.value)
                    page = vpn - 0x400
                    assert page == walks
                    walks += 1
                    response = (cycle + 12, page, vpn)
                valid = int(dut.o_vhead_complete.value) >> (
                    len(dut.o_vhead_complete) - 1
                )
                shield = bool(int(dut.o_vmem_head_shield.value))
                if int(dut.o_desc_valid.value):
                    assert shield, "partial descriptor lacks its interrupt shield"
                if valid:
                    assert shield_previous and shield, (
                        "side effect preceded the registered shield"
                    )
                if int(dut.o_desc_valid.value):
                    assert cycle >= 90, "descriptor bypassed the older-store drain"
                    assert walks == 2 and response is None, (
                        "access before both page translations"
                    )
                    assert not launched, "duplicate descriptor"
                    launched = True
                    assert int(dut.o_desc_first_elem.value) == 0
                    if fault_page < 0:
                        assert commit_at == cycle
                        assert int(dut.o_desc_last_elem.value) == 3
                        assert int(dut.o_desc_free_vmt_on_done.value)
                    else:
                        assert fault_page == 1 and offset == 4088
                        assert int(dut.o_desc_last_elem.value) == 1
                        assert int(dut.o_desc_seg1.value) == 0
                        assert not int(dut.o_desc_free_vmt_on_done.value)
                        partial_at = cycle
                if valid and completion is None:
                    completion = cycle
                    if fault_page >= 0:
                        assert int(dut.o_vmem_fault_vstart_valid.value)
                        expect = 2 if fault_page == 1 and offset == 4088 else 0
                        assert int(dut.o_vmem_fault_vstart.value) == expect
                        assert launched == (expect == 2)
                shield_previous = shield
                if completion is not None and cycle == completion + 8:
                    assert launched == (
                        fault_page < 0 or (fault_page == 1 and offset == 4088)
                    )
                    break
                await edge(dut)
            else:
                raise AssertionError("head translation did not complete")


def _pm_transform(address: int, pm_mode: int, translate: int) -> int:
    """Ssnpm's ignore transformation (riscv_pkg::pm_tval) of a 64-bit address."""
    if pm_mode not in (2, 3):
        return address
    width = 64 - (7 if pm_mode == 2 else 16)
    low = address & ((1 << width) - 1)
    if translate and (low >> (width - 1)) & 1:
        low |= ((1 << 64) - 1) ^ ((1 << width) - 1)
    return low


def _ppn_of(vpn: int) -> int:
    """Map a virtual page to the bench's frame; each page has its own."""
    return 0x83000 + (vpn & 0xFFF)


async def _strided_case(
    dut: Any,
    *,
    store: int,
    eew_log2: int,
    base: int,
    stride: int = 0,
    vl: int,
    vstart: int = 0,
    mask: int | None = None,
    fault_vpn: int | None = None,
    pm_mode: int = 0,
    indices: list[int] | None = None,
    ieew_log2: int = 0,
    ordered: int = 0,
    vlmul: int = 0,
    nf: int = 1,
    unit: bool = False,
    ff: bool = False,
    irq_at_launch: int | None = None,
    irq_withdraw_cycles: int | None = None,
) -> None:
    """Run one strided or indexed instruction; check every descriptor, fault and pulse.

    With indices, the instruction is an indexed form whose index group v16
    holds indices at EEW 2**ieew_log2 bytes; eew_log2 is then the data SEW.
    With nf > 1 it is a segment form (unit selects unit-stride addressing):
    each segment of nf fields is one element, and each field gets its own
    descriptor, for register group v8 + field * EMUL.
    """
    vlen = len(dut.i_vrf_read_data)
    eew = 1 << eew_log2
    width = (0, 5, 6, 7)[eew_log2]
    vm = 1 if mask is None else 0
    if unit or ff:
        insn = (
            ((nf - 1) << 29)
            | (vm << 25)
            | ((16 if ff else 0) << 20)
            | (10 << 15)
            | (width << 12)
            | (8 << 7)
            | (0x27 if store else 0x07)
        )
        stride = nf * eew
    elif indices is None:
        insn = (
            ((nf - 1) << 29)
            | (2 << 26)
            | (vm << 25)
            | (11 << 20)
            | (10 << 15)
            | (width << 12)
            | (8 << 7)
            | (0x27 if store else 0x07)
        )
    else:
        insn = (
            ((nf - 1) << 29)
            | ((3 if ordered else 1) << 26)
            | (vm << 25)
            | (16 << 20)
            | (10 << 15)
            | ((0, 5, 6, 7)[ieew_log2] << 12)
            | (8 << 7)
            | (0x27 if store else 0x07)
        )
    regs = {10: base & ((1 << 64) - 1), 11: stride & ((1 << 64) - 1)}
    # The VRF as the unit reads it: v0 (the mask) and the index group v16...
    vregs = {0: ((1 << vlen) - 1) if mask is None else mask}
    if indices is not None:
        image = b"".join(v.to_bytes(1 << ieew_log2, "little") for v in indices)
        for k in range(8):
            chunk = image[k * vlen // 8 : (k + 1) * vlen // 8]
            vregs[16 + k] = int.from_bytes(chunk.ljust(vlen // 8, b"\0"), "little")
    # The expected run: active elements in order until the first one whose
    # pages include a faulting one.
    expected = []
    fault = None
    for i in range(vstart, vl):
        if mask is not None and not (mask >> i) & 1:
            continue
        ea = base + (i * stride if indices is None else indices[i])
        va = _pm_transform(ea & ((1 << 64) - 1), pm_mode, 1)
        last = _pm_transform((ea + nf * eew - 1) & ((1 << 64) - 1), pm_mode, 1)
        pages = [va >> 12] + ([last >> 12] if (last >> 12) != (va >> 12) else [])
        if fault_vpn is not None and (pages[0] & ((1 << 27) - 1)) == fault_vpn:
            fault = (i, va)
            break
        if (
            fault_vpn is not None
            and len(pages) == 2
            and (pages[1] & ((1 << 27) - 1)) == fault_vpn
        ):
            fault = (i, (last >> 12) << 12)
            break
        for f in range(nf):
            fva = (va + f * eew) & ((1 << 64) - 1)
            fpages = [fva >> 12]
            if ((fva + eew - 1) >> 12) != (fva >> 12):
                fpages.append((fva + eew - 1) >> 12)
            expected.append((i, fva, fpages, 8 + f * (1 << vlmul)))
    trim = None
    if ff and fault is not None and fault[0] > 0:
        trim, fault = fault[0], None
    put(
        dut,
        clk=0,
        rst=1,
        head_tag=3,
        rob_empty=0,
        head_safe=1,
        head_is_vmem=1,
        head_insn=insn,
        head_vmt_idx=2,
        flush_all=0,
        fatal_stop=0,
        commit_valid=0,
        commit_tag=3,
        commit_exception=0,
        vec_idle=1,
        csr_wb_pending=0,
        sq_committed_empty=0,
        int_take_armed=0,
        vl=vl,
        vtype=(eew_log2 << 3) | vlmul,
        vstart=vstart,
        rf_read_data=0,
        vrf_read_data=((1 << vlen) - 1) if mask is None else mask,
        translate=1,
        eff_priv_u=0,
        sum=0,
        mxr=0,
        pm_mode=pm_mode,
        tlb_invalidate=0,
        walk_req_ready=0,
        walk_resp_valid=0,
        walk_resp=0,
        grant=0,
        vmu_done=0,
        vmu_fatal=0,
    )
    await edge(dut)
    # A previous case leaves its pages in the unit's registers, and the second
    # page's has no reset: poison it, so a descriptor can match only a page
    # translated in this case.
    dut.ppn1_q.value = (1 << len(dut.ppn1_q)) - 1
    await edge(dut)
    put(dut, rst=0)
    launches: list[int] = []
    # The pages walked for the element now running: every page of a launched
    # field must be among them.
    walked: set[int] = set()
    launched_since_walk = False
    vrf_pending = 0
    dirty = 0
    response = None
    done_at = None
    completion = None
    commit_at = None
    freed = False
    irq_boundary_seen = None
    irq_flushed = False
    completed_fields = 0
    for cycle in range(40 * (vl + 4) + 200):
        armed = 0
        if irq_at_launch is not None and len(launches) >= irq_at_launch:
            if irq_withdraw_cycles is None:
                armed = 0 if irq_flushed else 1
            elif (
                irq_boundary_seen is None
                or cycle < irq_boundary_seen + irq_withdraw_cycles
            ):
                armed = 1
        do_flush = (
            irq_at_launch is not None
            and irq_withdraw_cycles is None
            and irq_boundary_seen is not None
            and cycle == irq_boundary_seen + 2
        )
        put(
            dut,
            walk_resp_valid=0,
            walk_req_ready=cycle % 3 == 0,
            sq_committed_empty=cycle >= 25,
            grant=0,
            commit_valid=0,
            vmu_done=0,
            int_take_armed=armed,
            flush_all=int(do_flush),
            head_safe=0 if (do_flush or irq_flushed) else 1,
            head_is_vmem=0 if irq_flushed else 1,
        )
        if do_flush:
            irq_flushed = True
        # The VRF read port answers the previous cycle's address.
        put(dut, vrf_read_data=vregs.get(vrf_pending, 0))
        # The extra read port reads combinationally.
        await Timer(1, unit="ns")
        put(dut, rf_read_data=regs.get(int(dut.o_rf_read_addr.value), 0))
        if int(dut.o_vrf_read_en.value):
            vrf_pending = int(dut.o_vrf_read_addr.value)
        if response is not None and cycle == response[0]:
            vpn = response[1]
            put(
                dut,
                walk_resp_valid=1,
                walk_resp=pack_struct(
                    PTW_RESP_FIELDS,
                    {
                        "vpn": vpn,
                        "ppn": _ppn_of(vpn),
                        "perm_r": 1,
                        "perm_w": 1,
                        "perm_d": 1,
                        "fault_kind": 2 if vpn == fault_vpn else 0,
                    },
                ),
            )
            response = None
        if done_at == cycle:
            put(dut, vmu_done=1)
            done_at = None
            completed_fields += 1
        if commit_at == cycle:
            put(dut, commit_valid=1)
        if completion is not None and cycle == completion + 3:
            put(dut, grant=1)
        await Timer(1, unit="ns")
        if int(dut.o_walk_req_valid.value) and cycle % 3 == 0:
            assert response is None
            response = (cycle + 4, int(dut.o_walk_vpn.value))
            # A walk after a launch starts the next element's translation.
            if launched_since_walk:
                walked = set()
                launched_since_walk = False
            walked.add(int(dut.o_walk_vpn.value))
        if int(dut.o_vmem_vs_dirty.value):
            dirty += 1
        assert not int(dut.o_vmt_range_valid.value), "a strided run wrote a VMT range"
        if int(dut.o_desc_valid.value):
            assert int(dut.o_vmem_head_shield.value), (
                "element launched without the shield"
            )
            assert cycle >= 25, "element access before older stores drained"
            assert done_at is None, "a second element before the first completed"
            k = len(launches)
            assert k < len(expected), "launch past the expected elements"
            elem, va, pages, vd = expected[k]
            assert int(dut.o_desc_vd_vs3.value) == vd, (
                int(dut.o_desc_vd_vs3.value),
                vd,
            )
            first = int(dut.o_desc_first_elem.value)
            assert first == elem and int(dut.o_desc_last_elem.value) == elem, (
                first,
                elem,
            )
            assert int(dut.o_desc_page_offset.value) == va & 0xFFF
            missing = {p & ((1 << 27) - 1) for p in pages} - walked
            assert not missing, (
                f"element {elem}'s field at {va:#x} launched before its pages "
                f"{sorted(hex(p) for p in missing)} were translated"
            )
            launched_since_walk = True
            assert int(dut.o_desc_ppn0.value) == _ppn_of(pages[0] & ((1 << 27) - 1))
            if len(pages) == 2:
                assert int(dut.o_desc_ppn1.value) == _ppn_of(pages[1] & ((1 << 27) - 1))
            assert int(dut.o_desc_is_store.value) == store
            assert not int(dut.o_desc_free_vmt_on_done.value)
            launches.append(elem)
            done_at = cycle + 6
        valid = int(dut.o_vhead_complete.value) >> (len(dut.o_vhead_complete) - 1)
        if valid and completion is None:
            completion = cycle
            assert [e for e, _, _, _ in expected] == launches, (expected, launches)
            if fault is None:
                assert not int(dut.o_vmem_fault_vstart_valid.value)
            else:
                assert int(dut.o_vmem_fault_vstart_valid.value)
                assert int(dut.o_vmem_fault_vstart.value) == fault[0]
                # The completion carries this register as xtval.
                assert int(dut.fault_tval_q.value) == fault[1], (
                    hex(int(dut.fault_tval_q.value)),
                    hex(fault[1]),
                )
        if completion is not None and cycle == completion + 3 and fault is None:
            commit_at = cycle + 2
        if int(dut.i_commit_valid.value):
            assert int(dut.o_vl_trim_valid.value) == (trim is not None)
            if trim is not None:
                assert int(dut.o_vl_trim.value) == trim, (
                    int(dut.o_vl_trim.value),
                    trim,
                )
        if int(dut.o_zero_vmt_done_valid.value):
            assert commit_at is not None and cycle == commit_at + 1
            assert int(dut.o_zero_vmt_done_idx.value) == 2
            freed = True
        if (
            irq_at_launch is not None
            and irq_boundary_seen is None
            and len(launches) >= irq_at_launch
            and not int(dut.o_vmem_head_shield.value)
        ):
            # The shield drops only after all fields of the in-flight segment finish.
            assert completed_fields % nf == 0, (completed_fields, nf)
            assert len(launches) == completed_fields
            last_done_elem = launches[-1]
            assert int(dut.o_vmem_fault_vstart_valid.value) == 1
            assert int(dut.o_vmem_fault_vstart.value) == last_done_elem + 1, (
                int(dut.o_vmem_fault_vstart.value),
                last_done_elem + 1,
            )
            irq_boundary_seen = cycle
        if (
            irq_flushed
            and irq_boundary_seen is not None
            and cycle >= irq_boundary_seen + 4
        ):
            assert int(dut.o_vmem_head_shield.value) == 0
            assert int(dut.o_vmem_fault_vstart_valid.value) == 0
            assert completion is None, "flushed run must not complete on CDB"
            break
        if completion is not None and cycle == completion + 12:
            break
        await edge(dut)
    else:
        raise AssertionError("strided run did not complete")
    if irq_at_launch is not None and irq_withdraw_cycles is None:
        assert irq_flushed and irq_boundary_seen is not None
        assert not freed
        assert dirty == (0 if store else len(launches)), (dirty, launches)
        return
    if irq_at_launch is not None and irq_withdraw_cycles is not None:
        assert irq_boundary_seen is not None
    assert freed == (fault is None), "the VMT entry is freed exactly at retirement"
    assert dirty == (0 if store else len(launches)), (dirty, launches)


@cocotb.test()
async def test_strided_runs(dut: Any) -> None:
    """Strided elements run in order, one descriptor each, with precise faults."""
    vlen = len(dut.i_vrf_read_data)
    for store in (0, 1):
        # Positive stride with elements straddling pages, then a fault on the
        # third page: the elements before it are performed, vstart is exact.
        await _strided_case(
            dut, store=store, eew_log2=2, base=0x400FFE, stride=0x800, vl=4
        )
        await _strided_case(
            dut,
            store=store,
            eew_log2=2,
            base=0x400FFE,
            stride=0x800,
            vl=4,
            fault_vpn=0x402,
        )
        # Fault in the second page of the first element: nothing is performed.
        await _strided_case(
            dut,
            store=store,
            eew_log2=2,
            base=0x400FFE,
            stride=0x800,
            vl=4,
            fault_vpn=0x401,
        )
        # Negative, zero and misaligned strides, a mask and vstart.
        await _strided_case(
            dut, store=store, eew_log2=3, base=0x402010, stride=-0x1008, vl=3, vlmul=1
        )
        await _strided_case(dut, store=store, eew_log2=0, base=0x400FFF, stride=0, vl=5)
        await _strided_case(
            dut,
            store=store,
            eew_log2=1,
            base=0x400F01,
            stride=0x33,
            vl=min(vlen // 16, 12),
            vstart=2,
            mask=0b101101101101,
        )
        # Pointer masking: a tagged base is translated after masking.
        await _strided_case(
            dut,
            store=store,
            eew_log2=2,
            base=(0x5A << 57) | 0x400FF0,
            stride=0x10,
            vl=4,
            pm_mode=2,
        )
        await _strided_case(
            dut,
            store=store,
            eew_log2=2,
            base=(0x1234 << 48) | 0x400FF0,
            stride=0x10,
            vl=4,
            pm_mode=3,
            fault_vpn=0x401,
        )


@cocotb.test()
async def test_indexed_runs(dut: Any) -> None:
    """Indexed elements read their index, then run like strided ones."""
    vlen = len(dut.i_vrf_read_data)
    for store in (0, 1):
        for ordered in (0, 1):
            # 8-bit indices under SEW 32, crossing pages and repeating.
            await _strided_case(
                dut,
                store=store,
                eew_log2=2,
                base=0x400F00,
                vl=4,
                indices=[0xFE, 0x10, 0xFE, 0x00],
                ieew_log2=0,
                ordered=ordered,
            )
        # 64-bit indices with a fault on the third element's page.
        await _strided_case(
            dut,
            store=store,
            eew_log2=3,
            base=0x400000,
            vl=4,
            indices=[0x0FFC, 0x1008, 0x2000, 0x10],
            ieew_log2=3,
            fault_vpn=0x402,
            vlmul=1,
        )
        # 16-bit indices spanning two index registers, masked, from vstart.
        n = min(vlen // 16 + 4, 20)
        await _strided_case(
            dut,
            store=store,
            eew_log2=0,
            base=0x400FF0,
            vl=n,
            vstart=1,
            mask=0b1011_0110_1101_1011_0111,
            indices=[(i * 0x123) & 0xFFF for i in range(n)],
            ieew_log2=1,
        )
        # Pointer masking: the tagged base plus the index is masked.
        await _strided_case(
            dut,
            store=store,
            eew_log2=2,
            base=(0x2A << 57) | 0x400800,
            vl=3,
            indices=[0x7FE, 0x0, 0x804],
            ieew_log2=2,
            pm_mode=2,
        )


@cocotb.test()
async def test_segment_runs(dut: Any) -> None:
    """Each segment's fields launch one at a time after the segment is translated."""
    for store in (0, 1):
        # Unit-stride segments of three 32-bit fields; segment 1 straddles
        # the page, so its last field starts on the second page.
        await _strided_case(
            dut, store=store, eew_log2=2, base=0x400FEC, vl=4, nf=3, unit=True
        )
        # Strided segments of two 64-bit fields at LMUL 2, a fault on the
        # third page: the first two segments are performed, nothing of the
        # third.
        await _strided_case(
            dut,
            store=store,
            eew_log2=3,
            base=0x400FF8,
            stride=0x808,
            vl=4,
            nf=2,
            vlmul=1,
            fault_vpn=0x402,
        )
        # Indexed segments of eight bytes, masked, from vstart.
        await _strided_case(
            dut,
            store=store,
            eew_log2=0,
            base=0x400F00,
            vl=6,
            vstart=1,
            mask=0b110111,
            indices=[0xFC, 0x00, 0x1F8, 0x80, 0xFF, 0x40],
            ieew_log2=1,
            nf=8,
        )


@cocotb.test()
async def test_fault_only_first_runs(dut: Any) -> None:
    """A fault past element 0 ends the load with vl trimmed; element 0 traps."""
    # Element 2 straddles into the faulting page: vl becomes 2.
    await _strided_case(
        dut, store=0, eew_log2=2, base=0x401FF6, vl=4, fault_vpn=0x402, ff=True
    )
    # Element 0 faults: an exception as for any load.
    await _strided_case(
        dut, store=0, eew_log2=2, base=0x402000, vl=4, fault_vpn=0x402, ff=True
    )
    # From vstart 3, element 3 faults first: vl becomes 3 with nothing loaded.
    await _strided_case(
        dut,
        store=0,
        eew_log2=3,
        base=0x401FE8,
        vl=6,
        vstart=3,
        fault_vpn=0x402,
        ff=True,
        vlmul=1,
    )
    # Segment form: two-field segments; segment 3 is the first on the page.
    await _strided_case(
        dut, store=0, eew_log2=1, base=0x401FF4, vl=5, nf=2, fault_vpn=0x402, ff=True
    )


@cocotb.test()
async def test_run_interrupt_boundaries(dut: Any) -> None:
    """Armed interrupts drop the shield at element/segment boundaries with exact vstart."""
    for store in (0, 1):
        # Strided: stop after element 0 and flush, and stop then withdraw to resume.
        await _strided_case(
            dut,
            store=store,
            eew_log2=2,
            base=0x400FFE,
            stride=0x800,
            vl=4,
            irq_at_launch=1,
        )
        await _strided_case(
            dut,
            store=store,
            eew_log2=2,
            base=0x400FFE,
            stride=0x800,
            vl=4,
            irq_at_launch=1,
            irq_withdraw_cycles=20,
        )
        # Indexed with nonzero vstart and mask: stop after first active element.
        await _strided_case(
            dut,
            store=store,
            eew_log2=2,
            base=0x400F00,
            vl=5,
            vstart=1,
            mask=0b11011,
            indices=[0x00, 0x10, 0x20, 0x30, 0x40],
            ieew_log2=1,
            irq_at_launch=1,
        )
        # Segment (nf=3): armed during field 0 of segment 0; finishes fields 0..2
        # under the shield, then drops the shield with vstart = 1 (next segment).
        await _strided_case(
            dut,
            store=store,
            eew_log2=2,
            base=0x400FEC,
            vl=4,
            nf=3,
            unit=True,
            irq_at_launch=1,
        )
        await _strided_case(
            dut,
            store=store,
            eew_log2=2,
            base=0x400FEC,
            vl=4,
            nf=3,
            unit=True,
            irq_at_launch=1,
            irq_withdraw_cycles=20,
        )
    # Fault-only-first: stop after element 0 before reaching faulting element 2,
    # and yield at HM_RUN_TRIM then withdraw to retire with vl trimmed.
    await _strided_case(
        dut,
        store=0,
        eew_log2=2,
        base=0x401FF6,
        vl=4,
        fault_vpn=0x402,
        ff=True,
        irq_at_launch=1,
    )
    await _strided_case(
        dut,
        store=0,
        eew_log2=2,
        base=0x401FF6,
        vl=4,
        fault_vpn=0x402,
        ff=True,
        irq_at_launch=2,
        irq_withdraw_cycles=20,
    )
