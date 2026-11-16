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
