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
from utils.packed_structs import pack_struct, unpack_struct

FU_COMPLETE_FIELDS = [
    ("valid", 1),
    ("tag", 5),
    ("value", 64),
    ("exception", 1),
    ("exc_cause", 5),
    ("fp_flags", 5),
]


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


async def _uncached_case(
    dut: Any,
    *,
    insn: int,
    base: int,
    vl: int,
    eew_log2: int,
    store: int,
    stride: int = 0,
    vstart: int = 0,
    vlmul: int = 0,
    vsew_log2: int | None = None,
    mask: int | None = None,
    indices: list[int] | None = None,
    ieew_log2: int = 0,
    translate: int = 0,
    page_map: dict[int, dict[str, int]] | None = None,
    eff_priv_u: int = 0,
    bus_err_beat: int | None = None,
    port_ready_mod: int = 1,
    irq_at_beat: int | None = None,
    irq_withdraw_cycles: int | None = None,
    store_vregs: dict[int, int] | None = None,
    read_fn: Any = None,
) -> dict[str, Any]:
    """Run one vector memory instruction through cached and/or uncached ports."""
    vlen = len(dut.i_vrf_read_data)
    sew_code = eew_log2 if vsew_log2 is None else vsew_log2
    regs = {10: base & ((1 << 64) - 1), 11: stride & ((1 << 64) - 1)}
    vregs: dict[int, int] = {0: ((1 << vlen) - 1) if mask is None else mask}
    if indices is not None:
        image = b"".join(v.to_bytes(1 << ieew_log2, "little") for v in indices)
        for k in range(8):
            chunk = image[k * vlen // 8 : (k + 1) * vlen // 8]
            vregs[16 + k] = int.from_bytes(chunk.ljust(vlen // 8, b"\0"), "little")
    if store_vregs:
        vregs.update(store_vregs)
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
        vtype=(sew_code << 3) | vlmul,
        vstart=vstart,
        rf_read_data=0,
        vrf_read_data=vregs[0],
        translate=translate,
        eff_priv_u=eff_priv_u,
        sum=0,
        mxr=0,
        pm_mode=0,
        tlb_invalidate=0,
        walk_req_ready=1,
        walk_resp_valid=0,
        walk_resp=0,
        grant=0,
        vmu_done=0,
        vmu_fatal=0,
        unc_port_ready=1,
        unc_resp_valid=0,
        unc_resp_data=0,
        unc_resp_error=0,
    )
    await edge(dut)
    await edge(dut)
    put(dut, rst=0)

    unc_beats: list[dict[str, int]] = []
    cached_descs: list[dict[str, int]] = []
    vrf_writes: list[dict[str, int]] = []
    vrf_pending = 0
    shield_prev = False
    bus_hold_prev = False
    walk_resp_at: tuple[int, int] | None = None
    vmu_done_at: int | None = None
    unc_resp_at: tuple[int, int, int] | None = None
    completion: int | None = None
    commit_at: int | None = None
    freed = False
    dirty = 0
    vl_trim: int | None = None
    irq_boundary_seen: int | None = None
    irq_flushed = False
    exc_info: tuple[int, int, int, int] | None = None
    vmt_range_writes = 0

    for cycle in range(2500):
        armed = 0
        if irq_at_beat is not None and len(unc_beats) >= irq_at_beat:
            if irq_withdraw_cycles is None:
                armed = 0 if irq_flushed else 1
            elif (
                irq_boundary_seen is None
                or cycle < irq_boundary_seen + irq_withdraw_cycles
            ):
                armed = 1
        do_flush = (
            irq_at_beat is not None
            and irq_withdraw_cycles is None
            and irq_boundary_seen is not None
            and cycle == irq_boundary_seen + 2
        )
        port_rdy = int(
            bus_hold_prev and unc_resp_at is None and (cycle % port_ready_mod == 0)
        )
        put(
            dut,
            walk_resp_valid=0,
            sq_committed_empty=int(cycle >= 20),
            grant=0,
            commit_valid=0,
            vmu_done=0,
            unc_port_ready=port_rdy,
            unc_resp_valid=0,
            unc_resp_data=0,
            unc_resp_error=0,
            int_take_armed=armed,
            flush_all=int(do_flush),
            head_safe=0 if (do_flush or irq_flushed) else 1,
            head_is_vmem=0 if irq_flushed else 1,
            vrf_read_data=vregs.get(vrf_pending, 0),
        )
        if do_flush:
            irq_flushed = True
        await Timer(1, unit="ns")
        put(dut, rf_read_data=regs.get(int(dut.o_rf_read_addr.value), 0))
        if int(dut.o_vrf_read_en.value):
            vrf_pending = int(dut.o_vrf_read_addr.value)
        if walk_resp_at is not None and cycle == walk_resp_at[0]:
            vpn = walk_resp_at[1]
            info = (page_map or {}).get(
                vpn,
                {"ppn": 0x83000 + (vpn & 0xFFF), "perm_r": 1, "perm_w": 1, "perm_d": 1},
            )
            fields = {
                "vpn": vpn,
                "ppn": info.get("ppn", 0),
                "level": info.get("level", 0),
                "pbmt": info.get("pbmt", 0),
                "perm_r": info.get("perm_r", 1),
                "perm_w": info.get("perm_w", 1),
                "perm_x": info.get("perm_x", 0),
                "perm_u": info.get("perm_u", 0),
                "perm_d": info.get("perm_d", 1),
                "fault_kind": info.get("fault_kind", 0),
            }
            put(dut, walk_resp_valid=1, walk_resp=pack_struct(PTW_RESP_FIELDS, fields))
            walk_resp_at = None
        if vmu_done_at == cycle:
            put(dut, vmu_done=1)
            vmu_done_at = None
        if unc_resp_at is not None and cycle == unc_resp_at[0]:
            put(
                dut,
                unc_resp_valid=1,
                unc_resp_data=unc_resp_at[1],
                unc_resp_error=unc_resp_at[2],
            )
            unc_resp_at = None
        if commit_at == cycle:
            put(dut, commit_valid=1)
        if completion is not None and cycle == completion + 2:
            put(dut, grant=1)
        await Timer(1, unit="ns")

        if int(dut.o_walk_req_valid.value):
            assert walk_resp_at is None
            walk_resp_at = (cycle + 2, int(dut.o_walk_vpn.value))
        if int(dut.o_vmt_range_valid.value):
            vmt_range_writes += 1
        if int(dut.o_vmem_vs_dirty.value):
            dirty += 1
        shield = bool(int(dut.o_vmem_head_shield.value))
        bus_hold = bool(int(dut.o_unc_bus_hold.value))

        if int(dut.o_desc_valid.value):
            assert shield, "cached desc without shield"
            assert not bus_hold, "uncached bus hold asserted during cached desc"
            assert cycle >= 20, "cached desc before SQ drain"
            cached_descs.append(
                {
                    "first": int(dut.o_desc_first_elem.value),
                    "last": int(dut.o_desc_last_elem.value),
                    "ppn0": int(dut.o_desc_ppn0.value),
                    "off": int(dut.o_desc_page_offset.value),
                    "vd": int(dut.o_desc_vd_vs3.value),
                }
            )
            vmu_done_at = cycle + 3

        if int(dut.o_unc_req_valid.value):
            assert shield and shield_prev, "uncached beat lacked settled head shield"
            assert bus_hold and bus_hold_prev, "uncached beat lacked prior bus hold"
            assert cycle >= 20, "uncached beat bypassed SQ drain"
            assert unc_resp_at is None, "overlapping uncached beat"
            assert not int(dut.o_desc_valid.value), "uncached beat overlapped VMU desc"
            beat_idx = len(unc_beats)
            addr = int(dut.o_unc_req_addr.value)
            write = int(dut.o_unc_req_write.value)
            size = int(dut.o_unc_req_size.value)
            wdata = int(dut.o_unc_req_wdata.value)
            wstrb = int(dut.o_unc_req_wstrb.value)
            assert write == store
            unc_beats.append(
                {
                    "addr": addr,
                    "write": write,
                    "size": size,
                    "wdata": wdata,
                    "wstrb": wstrb,
                }
            )
            rdata = 0 if write else (read_fn(addr, beat_idx) if read_fn else 0)
            err = int(bus_err_beat is not None and beat_idx == bus_err_beat)
            unc_resp_at = (cycle + 3, rdata, err)

        if int(dut.o_vrf_write_en.value):
            assert not store, "VRF write on store"
            vrf_writes.append(
                {
                    "addr": int(dut.o_vrf_write_addr.value),
                    "data": int(dut.o_vrf_write_data.value),
                    "be": int(dut.o_vrf_write_be.value),
                }
            )

        pkt = unpack_struct(FU_COMPLETE_FIELDS, int(dut.o_vhead_complete.value))
        if pkt["valid"] and completion is None:
            completion = cycle
            if pkt["exception"]:
                vs_en = int(dut.o_vmem_fault_vstart_valid.value)
                vs_val = int(dut.o_vmem_fault_vstart.value)
                exc_info = (pkt["exc_cause"], pkt["value"], vs_en, vs_val)
            else:
                commit_at = cycle + 4
        if int(dut.i_commit_valid.value) and int(dut.o_vl_trim_valid.value):
            vl_trim = int(dut.o_vl_trim.value)
        if int(dut.o_zero_vmt_done_valid.value):
            freed = True

        if (
            irq_at_beat is not None
            and irq_boundary_seen is None
            and len(unc_beats) >= irq_at_beat
            and not shield
        ):
            assert int(dut.o_vmem_fault_vstart_valid.value) == 1
            irq_boundary_seen = cycle
        if (
            irq_flushed
            and irq_boundary_seen is not None
            and cycle >= irq_boundary_seen + 4
        ):
            assert not shield
            assert int(dut.o_vmem_fault_vstart_valid.value) == 0
            assert completion is None
            break
        if completion is not None and cycle == completion + 8:
            break
        shield_prev = shield
        bus_hold_prev = bus_hold
        await edge(dut)
    else:
        raise AssertionError("uncached case did not complete")

    return {
        "unc_beats": unc_beats,
        "cached_descs": cached_descs,
        "vrf_writes": vrf_writes,
        "exc": exc_info,
        "freed": freed,
        "dirty": dirty,
        "vl_trim": vl_trim,
        "vmt_range_writes": vmt_range_writes,
        "irq_boundary_seen": irq_boundary_seen,
    }


@cocotb.test()
async def test_uncached_all_forms_and_widths(dut: Any) -> None:
    """Every vector load/store form executes in element order on low BRAM and MMIO."""
    vlen = len(dut.i_vrf_read_data)
    vlenb = vlen // 8
    # 1. Unit-stride load & store to low BRAM across EEW 8/16/32/64 (span fallback).
    for eew_log2, width in ((0, 0), (1, 5), (2, 6), (3, 7)):
        eew = 1 << eew_log2
        vle = (1 << 25) | (10 << 15) | (width << 12) | (8 << 7) | 0x07
        vse = (1 << 25) | (10 << 15) | (width << 12) | (8 << 7) | 0x27
        res = await _uncached_case(
            dut,
            insn=vle,
            base=0x18000,
            vl=4,
            eew_log2=eew_log2,
            store=0,
            port_ready_mod=3,
            read_fn=lambda a, k: 0x88776655_44332211 ^ (k * 0x01010101_01010101),
        )
        assert res["exc"] is None and res["freed"] and res["vmt_range_writes"] == 0
        assert [b["addr"] for b in res["unc_beats"]] == [
            0x18000 + i * eew for i in range(4)
        ]
        assert all(b["size"] == eew_log2 for b in res["unc_beats"])
        assert len(res["vrf_writes"]) == 4 and res["dirty"] == 4

        pat = int.from_bytes(bytes(range(0x10, 0x10 + vlenb)), "little")
        res_s = await _uncached_case(
            dut,
            insn=vse,
            base=0x40000008,
            vl=3,
            eew_log2=eew_log2,
            store=1,
            store_vregs={8: pat},
        )
        assert res_s["exc"] is None and res_s["freed"] and res_s["dirty"] == 0
        assert [b["addr"] for b in res_s["unc_beats"]] == [
            0x40000008 + i * eew for i in range(3)
        ]
        # Verify sub-dword lane replication on MMIO (e.g. FIFO1 at 0x4000000C).
        if eew == 4:
            w1 = int.from_bytes(bytes(range(0x14, 0x18)), "little")
            assert res_s["unc_beats"][1]["addr"] == 0x4000000C
            assert res_s["unc_beats"][1]["wstrb"] == 0xF0
            assert res_s["unc_beats"][1]["wdata"] == ((w1 << 32) | w1)

    # 2. Whole-register vl1re32.v and vs1r.v on low BRAM.
    vl1re32 = (1 << 25) | (0x08 << 20) | (10 << 15) | (6 << 12) | (8 << 7) | 0x07
    res_w = await _uncached_case(
        dut, insn=vl1re32, base=0x18040, vl=0, eew_log2=2, store=0
    )
    assert res_w["exc"] is None and len(res_w["unc_beats"]) == vlenb // 4
    vs1r = (1 << 25) | (0x08 << 20) | (10 << 15) | (0 << 12) | (8 << 7) | 0x27
    res_ws = await _uncached_case(
        dut, insn=vs1r, base=0x18041, vl=0, eew_log2=0, store=1
    )
    assert res_ws["exc"] is None and len(res_ws["unc_beats"]) == vlenb

    # 3. Mask vlm.v and vsm.v on low BRAM.
    vlm = (1 << 25) | (0x0B << 20) | (10 << 15) | (0 << 12) | (8 << 7) | 0x07
    vsm = (1 << 25) | (0x0B << 20) | (10 << 15) | (0 << 12) | (8 << 7) | 0x27
    res_m = await _uncached_case(
        dut, insn=vlm, base=0x18003, vl=17, eew_log2=0, store=0
    )
    assert res_m["exc"] is None and len(res_m["unc_beats"]) == 3
    res_ms = await _uncached_case(
        dut, insn=vsm, base=0x18003, vl=17, eew_log2=0, store=1
    )
    assert res_ms["exc"] is None and len(res_ms["unc_beats"]) == 3

    # 4. Strided stride-0 read of a side-effecting device register (FIFO0) in exact order.
    vlse32 = (
        (2 << 26) | (1 << 25) | (11 << 20) | (10 << 15) | (6 << 12) | (8 << 7) | 0x07
    )
    res_st = await _uncached_case(
        dut,
        insn=vlse32,
        base=0x40000008,
        stride=0,
        vl=4,
        eew_log2=2,
        store=0,
        read_fn=lambda a, k: 0xA0000000 + k,
    )
    assert (
        res_st["exc"] is None
        and [b["addr"] for b in res_st["unc_beats"]] == [0x40000008] * 4
    )
    assert len(res_st["vrf_writes"]) == 4

    # 5. Indexed ordered & unordered mixing cached DDR, low BRAM, and MMIO in one op.
    for ordered in (0, 1):
        vlxei = (
            ((3 if ordered else 1) << 26)
            | (1 << 25)
            | (16 << 20)
            | (10 << 15)
            | (7 << 12)
            | (8 << 7)
            | 0x07
        )
        res_ix = await _uncached_case(
            dut,
            insn=vlxei,
            base=0,
            vl=4,
            eew_log2=2,
            store=0,
            indices=[0x80001000, 0x00018010, 0x40000008, 0x80001004],
            ieew_log2=3,
        )
        assert res_ix["exc"] is None and res_ix["freed"]
        assert [d["first"] for d in res_ix["cached_descs"]] == [0, 3]
        assert [b["addr"] for b in res_ix["unc_beats"]] == [0x00018010, 0x40000008]

    # 6. Segment crossing Sv39 cached Page 0 -> uncached Page 1 (aligned).
    vlseg4 = (3 << 29) | (1 << 25) | (10 << 15) | (6 << 12) | (8 << 7) | 0x07
    res_seg = await _uncached_case(
        dut,
        insn=vlseg4,
        base=0x400FF8,
        vl=1,
        eew_log2=2,
        store=0,
        translate=1,
        page_map={
            0x400: {"ppn": 0x83000},
            0x401: {"ppn": 0x00019},  # low BRAM
        },
    )
    assert res_seg["exc"] is None and res_seg["freed"]
    assert [d["vd"] for d in res_seg["cached_descs"]] == [8, 9]
    assert [b["addr"] for b in res_seg["unc_beats"]] == [0x19000, 0x19004]
    assert [w["addr"] for w in res_seg["vrf_writes"]] == [10, 11]


@cocotb.test()
async def test_uncached_faults_svpbmt_and_irq(dut: Any) -> None:
    """Alignment, PMA, Svpbmt, bus-error, FoF trim, and mid-run IRQ on uncached ops."""
    vle32 = (1 << 25) | (10 << 15) | (6 << 12) | (8 << 7) | 0x07
    vse32 = (1 << 25) | (10 << 15) | (6 << 12) | (8 << 7) | 0x27
    vle32ff = (1 << 25) | (0x10 << 20) | (10 << 15) | (6 << 12) | (8 << 7) | 0x07

    # 1. Misaligned low BRAM & MMIO raise cause 4 / 6 with zero uncached beats.
    for insn, st, want_cause in ((vle32, 0, 4), (vse32, 1, 6)):
        for addr in (0x18002, 0x4000000A):
            res = await _uncached_case(
                dut, insn=insn, base=addr, vl=4, eew_log2=2, store=st
            )
            assert res["unc_beats"] == []
            assert res["exc"] == (want_cause, addr, 1, 0), res["exc"]

    # 2. Bare access to unmapped PA and to Svpbmt alias window -> access fault (5/7).
    for addr in (0x00040000, 0x40040000, 0xC0000000):
        res = await _uncached_case(
            dut, insn=vle32, base=addr, vl=2, eew_log2=2, store=0
        )
        assert res["unc_beats"] == []
        assert res["exc"] == (5, addr, 1, 0), res["exc"]

    # 3. Svpbmt NC DDR alias: aligned succeeds on uncached port; misaligned -> access fault (5);
    #    U-mode permission failure -> page fault (13).
    alias_map = {0x400: {"ppn": 0xC0010, "pbmt": 1, "perm_u": 0}}
    res_nc = await _uncached_case(
        dut,
        insn=vle32,
        base=0x400000,
        vl=2,
        eew_log2=2,
        store=0,
        translate=1,
        page_map=alias_map,
    )
    assert res_nc["exc"] is None and [b["addr"] for b in res_nc["unc_beats"]] == [
        0xC0010000,
        0xC0010004,
    ]
    res_nc_ma = await _uncached_case(
        dut,
        insn=vle32,
        base=0x400002,
        vl=2,
        eew_log2=2,
        store=0,
        translate=1,
        page_map=alias_map,
    )
    assert res_nc_ma["unc_beats"] == [] and res_nc_ma["exc"] == (5, 0x400002, 1, 0)
    res_nc_perm = await _uncached_case(
        dut,
        insn=vle32,
        base=0x400000,
        vl=2,
        eew_log2=2,
        store=0,
        translate=1,
        eff_priv_u=1,
        page_map=alias_map,
    )
    assert res_nc_perm["unc_beats"] == [] and res_nc_perm["exc"] == (13, 0x400000, 1, 0)

    # 4. Mixed cached Page 0 -> uncached Page 1 misaligned straddle:
    #    Page-0 elements complete via VMU, straddling element 2 traps cause 4 with vstart=2.
    res_mix = await _uncached_case(
        dut,
        insn=vle32,
        base=0x400FF6,
        vl=4,
        eew_log2=2,
        store=0,
        translate=1,
        page_map={0x400: {"ppn": 0x83000}, 0x401: {"ppn": 0x00018}},
    )
    assert [d["first"] for d in res_mix["cached_descs"]] == [0, 1]
    assert res_mix["unc_beats"] == []
    assert res_mix["exc"] == (4, 0x400FFE, 1, 2), res_mix["exc"]

    # 5. Bus error on uncached element 1: precise load/store access fault, no VRF write;
    #    and FoF trims vl=1 without trapping.
    res_lerr = await _uncached_case(
        dut, insn=vle32, base=0x40000008, vl=3, eew_log2=2, store=0, bus_err_beat=1
    )
    assert len(res_lerr["unc_beats"]) == 2 and len(res_lerr["vrf_writes"]) == 1
    assert res_lerr["exc"] == (5, 0x4000000C, 1, 1), res_lerr["exc"]
    res_serr = await _uncached_case(
        dut, insn=vse32, base=0x40000008, vl=3, eew_log2=2, store=1, bus_err_beat=1
    )
    assert len(res_serr["unc_beats"]) == 2
    assert res_serr["exc"] == (7, 0x4000000C, 1, 1), res_serr["exc"]
    res_fof = await _uncached_case(
        dut, insn=vle32ff, base=0x40000008, vl=4, eew_log2=2, store=0, bus_err_beat=2
    )
    assert res_fof["exc"] is None and res_fof["vl_trim"] == 2
    assert len(res_fof["unc_beats"]) == 3 and len(res_fof["vrf_writes"]) == 2

    # 6. Mid-run interrupt on uncached unit-stride (span fallback): flush and withdraw.
    res_irq_stop = await _uncached_case(
        dut, insn=vle32, base=0x40000008, vl=4, eew_log2=2, store=0, irq_at_beat=2
    )
    assert res_irq_stop["irq_boundary_seen"] is not None
    assert len(res_irq_stop["unc_beats"]) == 2 and len(res_irq_stop["vrf_writes"]) == 2
    res_irq_res = await _uncached_case(
        dut,
        insn=vle32,
        base=0x40000008,
        vl=4,
        eew_log2=2,
        store=0,
        irq_at_beat=2,
        irq_withdraw_cycles=15,
    )
    assert res_irq_res["exc"] is None and res_irq_res["freed"]
    assert len(res_irq_res["unc_beats"]) == 4 and len(res_irq_res["vrf_writes"]) == 4
