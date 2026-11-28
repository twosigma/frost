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

"""Directed vec_unit tests for off-head completion, flushes, and commit staging.

Covers:
  - Full speculative flush (i_flush_spec) in every off-head state
    (OV_IDLE..OV_OUT) and while committed work is staged in cpush_q.
  - Partial flush (i_flush_en / i_flush_tag) in every off-head state for both
    younger-squashed and older-preserved tags, including head advancement on
    the flush cycle, ROB tag wraparound, and staged work in cpush_q.
  - Nearly full VIQ (count_q == 7/8) with staged committed work in cpush_q and
    concurrent flushes, plus port-4 handoff between u_head_mmu/u_vmu and
    off-head OV_RD0 (including ov_s2_cap_q capture across VMU contention) and
    CDB backpressure.
"""

from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge, Timer

ROB_DEPTH = 32
MASK64 = (1 << 64) - 1

OV_IDLE = 0
OV_CHK = 1
OV_CAP_MV = 2
OV_RD0 = 3
OV_ST1 = 4
OV_ST2 = 5
OV_REDUCE = 6
OV_OUT = 7


def enc_vmv_vx(vd: int, rs1: int = 1) -> int:
    """Encode vmv.v.x vd, rs1 (unmasked OPIVX move)."""
    return (
        (0x17 << 26)
        | (1 << 25)
        | (0 << 20)
        | (rs1 << 15)
        | (4 << 12)
        | (vd << 7)
        | 0x57
    )


def enc_vadd_vx(vd: int, vs2: int, rs1: int = 1) -> int:
    """Encode vadd.vx vd, vs2, rs1 (unmasked OPIVX add)."""
    return (
        (0x00 << 26)
        | (1 << 25)
        | (vs2 << 20)
        | (rs1 << 15)
        | (4 << 12)
        | (vd << 7)
        | 0x57
    )


def enc_vdivu_vv(vd: int, vs2: int, vs1: int) -> int:
    """Encode vdivu.vv vd, vs2, vs1 (multi-cycle vec_int_exec divide)."""
    return (
        (0x20 << 26)
        | (1 << 25)
        | (vs2 << 20)
        | (vs1 << 15)
        | (2 << 12)
        | (vd << 7)
        | 0x57
    )


def enc_vmv_xs(vs2: int, rd: int = 1) -> int:
    """Encode vmv.x.s rd, vs2."""
    return (
        (0x10 << 26)
        | (1 << 25)
        | (vs2 << 20)
        | (0 << 15)
        | (2 << 12)
        | (rd << 7)
        | 0x57
    )


def enc_vfmv_fs(vs2: int, fd: int = 1) -> int:
    """Encode vfmv.f.s fd, vs2."""
    return (
        (0x10 << 26)
        | (1 << 25)
        | (vs2 << 20)
        | (0 << 15)
        | (1 << 12)
        | (fd << 7)
        | 0x57
    )


def enc_vcpop_m(vs2: int, *, vm: int = 1, rd: int = 1) -> int:
    """Encode vcpop.m rd, vs2[, v0.t]."""
    return (
        (0x10 << 26)
        | (vm << 25)
        | (vs2 << 20)
        | (0x10 << 15)
        | (2 << 12)
        | (rd << 7)
        | 0x57
    )


def enc_vfirst_m(vs2: int, *, vm: int = 1, rd: int = 1) -> int:
    """Encode vfirst.m rd, vs2[, v0.t]."""
    return (
        (0x10 << 26)
        | (vm << 25)
        | (vs2 << 20)
        | (0x11 << 15)
        | (2 << 12)
        | (rd << 7)
        | 0x57
    )


def enc_vse32(vs3: int, rs1: int = 10) -> int:
    """Encode vse32.v vs3, (rs1) (unmasked unit-stride store)."""
    return (
        (0x00 << 26)
        | (1 << 25)
        | (0 << 20)
        | (rs1 << 15)
        | (6 << 12)
        | (vs3 << 7)
        | 0x27
    )


def enc_vle32(vd: int, rs1: int = 10) -> int:
    """Encode vle32.v vd, (rs1) (unmasked unit-stride load)."""
    return (
        (0x00 << 26)
        | (1 << 25)
        | (0 << 20)
        | (rs1 << 15)
        | (6 << 12)
        | (vd << 7)
        | 0x07
    )


def make_vtype(sew: int, lmul_code: int = 0) -> int:
    """Pack {vill=0, vtype[7:0]} for SEW in {8, 16, 32, 64}."""
    sew_code = {8: 0, 16: 1, 32: 2, 64: 3}[sew]
    return (sew_code << 3) | (lmul_code & 0x7)


def unpack_fu_complete(raw: int) -> dict[str, int]:
    """Unpack riscv_pkg::fu_complete_t (81 bits, MSB first)."""
    return {
        "valid": (raw >> 80) & 1,
        "tag": (raw >> 75) & 0x1F,
        "value": (raw >> 11) & MASK64,
        "exception": (raw >> 10) & 1,
        "exc_cause": (raw >> 5) & 0x1F,
        "fp_flags": raw & 0x1F,
    }


def mask_from_elems(vlen: int, sew: int, elem_val: int) -> int:
    """Replicate a single SEW-bit element across a VLEN-bit vector register."""
    mask = (1 << sew) - 1
    e = elem_val & mask
    out = 0
    for i in range(vlen // sew):
        out |= e << (i * sew)
    return out


class VecUnitBench:
    """Cycle-accurate driver for standalone vec_unit verification."""

    def __init__(self, dut: Any) -> None:
        """Attach to the vec_unit DUT and initialize default port values."""
        self.dut = dut
        self.vlen = len(dut.u_engine.o_xr_data)
        self.state: dict[str, int] = {
            "i_rst": 0,
            "i_fatal_stop": 0,
            "i_head_tag": 0,
            "i_rob_empty": 1,
            "i_head_safe": 1,
            "i_csr_wb_pending": 0,
            "i_sq_committed_empty": 1,
            "i_int_take_armed": 0,
            "i_vl": self.vlen // 32,
            "i_vtype": make_vtype(32),
            "i_vstart": 0,
            "i_vxrm": 0,
            "i_frm": 0,
            "i_fp_read_data": 0,
            "i_rf_read_data": 0x80000100,
            "i_translate": 0,
            "i_eff_priv_u": 0,
            "i_sum": 0,
            "i_mxr": 0,
            "i_pm_mode": 0,
            "i_tlb_invalidate": 0,
            "i_walk_req_ready": 1,
            "i_walk_resp_valid": 0,
            "i_walk_resp": 0,
            "i_lc_req_ready": 1,
            "i_grant": 1,
        }
        self.pulse_defaults: dict[str, int] = {
            "i_lc_resp_valid": 0,
            "i_lc_resp_id": 0,
            "i_lc_resp_data": 0,
            "i_lc_resp_error": 0,
            "i_alloc": 0,
            "i_alloc_tag": 0,
            "i_alloc_is_varith": 0,
            "i_alloc_is_vtox": 0,
            "i_alloc_is_vmem": 0,
            "i_alloc_is_vload": 0,
            "i_alloc_is_vcfg": 0,
            "i_alloc_vtype": 0,
            "i_alloc_vmt_idx": 0,
            "i_alloc_insn": 0,
            "i_alloc_is_vfscalar": 0,
            "i_alloc_2": 0,
            "i_alloc_tag_2": 0,
            "i_commit_valid": 0,
            "i_commit_tag": 0,
            "i_commit_exception": 0,
            "i_commit_value": 0,
            "i_vcfg_commit_valid": 0,
            "i_flush_all": 0,
            "i_flush_spec": 0,
            "i_flush_en": 0,
            "i_flush_tag": 0,
        }

    def set_state(self, **kwargs: int) -> None:
        """Update persistent input signals."""
        for k, v in kwargs.items():
            assert k in self.state, f"unknown persistent signal {k}"
            self.state[k] = v

    async def tick(self, **pulses: int) -> dict[str, Any]:
        """Drive persistent + one-cycle pulse inputs, sample before posedge, then clock."""
        dut = self.dut
        await FallingEdge(dut.i_clk)
        vals = {**self.state, **self.pulse_defaults}
        for k, v in pulses.items():
            if k in self.state:
                self.state[k] = v
            vals[k] = v
        for name, value in vals.items():
            getattr(dut, name).value = value
        await Timer(1, unit="ns")
        comp = unpack_fu_complete(int(dut.o_vtox_complete.value))
        sample: dict[str, Any] = {
            "comp": comp,
            "o_idle": int(dut.o_idle.value),
            "o_commit_hold": int(dut.o_commit_hold.value),
            "o_vtox_commit": int(dut.o_vtox_commit.value),
            "o_varith_commit": int(dut.o_varith_commit.value),
            "o_vstore_commit": int(dut.o_vstore_commit.value),
            "o_lc_req_valid": int(dut.o_lc_req_valid.value),
            "o_lc_req_id": int(dut.o_lc_req_id.value),
            "ov_state": int(dut.ov_state_q.value),
            "ov_pend": int(dut.ov_pend_q.value),
            "ov_s2_cap": int(dut.ov_s2_cap_q.value),
            "cpush_valid": int(dut.cpush_valid_q.value),
            "count": int(dut.count_q.value),
            "flush_spec_d1": int(dut.flush_spec_d1_q.value),
            "vmu_busy": int(dut.vmu_busy_q.value),
            "vhead_port_claim": int(dut.vhead_port_claim_q.value),
            "vmu_done": int(dut.vmu_done.value),
            "vmu_idle": int(dut.vmu_idle.value),
            "vmu_cmd_valid": int(dut.vmu_cmd_valid.value),
            "vmem_desc_valid": int(dut.vmem_desc_valid_q.value),
            "vec_backend_idle_q": int(dut.vec_backend_idle_q.value),
            "hm_state": int(dut.u_head_mmu.state_q.value),
            "hm_vec_idle": int(dut.u_head_mmu.i_vec_idle.value),
        }
        await RisingEdge(dut.i_clk)
        await ReadOnly()
        return sample

    async def reset(self) -> None:
        """Reset vec_unit cleanly and verify idle state."""
        assert len(self.dut.o_vtox_complete) == 81
        self.set_state(
            i_rst=1,
            i_head_tag=0,
            i_rob_empty=1,
            i_head_safe=1,
            i_vl=self.vlen // 32,
            i_vtype=make_vtype(32),
            i_vstart=0,
            i_grant=1,
            i_lc_req_ready=1,
        )
        await self.tick()
        await self.tick()
        self.set_state(i_rst=0)
        s = await self.tick()
        assert s["o_idle"] == 1
        assert s["ov_state"] == OV_IDLE

    async def wait_idle(self, limit: int = 400) -> None:
        """Tick until vec_unit reports completely idle."""
        for _ in range(limit):
            s = await self.tick()
            if s["o_idle"] == 1 and s["ov_state"] == OV_IDLE and s["cpush_valid"] == 0:
                return
        raise AssertionError(
            f"vec_unit did not reach idle: ov_state={int(self.dut.ov_state_q.value)}, "
            f"count={int(self.dut.count_q.value)}, cpush={int(self.dut.cpush_valid_q.value)}"
        )

    async def write_vreg_splat(
        self, vd: int, value64: int, *, sew: int = 64, tag: int = 0
    ) -> None:
        """Initialize vector register vd by retiring vmv.v.x with SEW=sew."""
        vtype = make_vtype(sew)
        vl = self.vlen // sew
        self.set_state(i_head_tag=tag, i_rob_empty=0, i_vl=vl, i_vtype=vtype)
        await self.tick(
            i_alloc=1,
            i_alloc_tag=tag,
            i_alloc_is_varith=1,
            i_alloc_vtype=vtype,
            i_alloc_insn=enc_vmv_vx(vd),
        )
        # Allow alloc_q to populate before retirement (matches ROB dispatch->commit).
        await self.tick()
        await self.tick(
            i_commit_valid=1,
            i_commit_tag=tag,
            i_commit_value=value64 & MASK64,
            i_head_tag=(tag + 1) % ROB_DEPTH,
            i_rob_empty=1,
        )
        await self.wait_idle()

    async def run_vtox_expect(
        self, insn: int, *, sew: int, vl: int, tag: int = 0, limit: int = 80
    ) -> int:
        """Allocate and execute one off-head VTOX/VTOF op and return its CDB value."""
        vtype = make_vtype(sew)
        self.set_state(i_head_tag=tag, i_rob_empty=0, i_vl=vl, i_vtype=vtype, i_grant=1)
        await self.tick(
            i_alloc=1,
            i_alloc_tag=tag,
            i_alloc_is_vtox=1,
            i_alloc_vtype=vtype,
            i_alloc_insn=insn,
        )
        for _ in range(limit):
            s = await self.tick()
            if s["comp"]["valid"]:
                assert s["comp"]["tag"] == tag
                assert s["comp"]["exception"] == 0
                val = int(s["comp"]["value"])
                # Retire the completed VTOX/VTOF op so ROB empties cleanly.
                s_ret = await self.tick(
                    i_commit_valid=1,
                    i_commit_tag=tag,
                    i_head_tag=(tag + 1) % ROB_DEPTH,
                    i_rob_empty=1,
                )
                assert s_ret["o_vtox_commit"] == 1
                await self.wait_idle()
                return val
        raise AssertionError(f"off-head op did not complete (tag={tag})")

    async def reach_ov_state(
        self,
        target_state: int,
        *,
        head_tag: int,
        ov_tag: int,
        insn: int,
        sew: int = 32,
        vl: int | None = None,
        older_blocker_tag: int | None = None,
        older_blocker_vd: int = 2,
        extra_vtox_tags: tuple[int, ...] = (),
        grant: int = 0,
    ) -> None:
        """Drive an off-head instruction into target_state (OV_IDLE..OV_OUT)."""
        vtype = make_vtype(sew)
        eff_vl = self.vlen if vl is None else vl
        self.set_state(
            i_head_tag=head_tag,
            i_rob_empty=0,
            i_vl=eff_vl,
            i_vtype=vtype,
            i_grant=grant,
        )
        if older_blocker_tag is not None:
            await self.tick(
                i_alloc=1,
                i_alloc_tag=older_blocker_tag,
                i_alloc_is_varith=1,
                i_alloc_vtype=vtype,
                i_alloc_insn=enc_vadd_vx(older_blocker_vd, older_blocker_vd),
            )
        await self.tick(
            i_alloc=1,
            i_alloc_tag=ov_tag,
            i_alloc_is_vtox=1,
            i_alloc_vtype=vtype,
            i_alloc_insn=insn,
        )
        for etag in extra_vtox_tags:
            await self.tick(
                i_alloc=1,
                i_alloc_tag=etag,
                i_alloc_is_vtox=1,
                i_alloc_vtype=vtype,
                i_alloc_insn=enc_vmv_xs(2),
            )
        if target_state == OV_IDLE:
            # Wait one cycle for alloc_q to populate ov_pend_q while ov_state_q
            # is still OV_IDLE (ov_accept fires on the following posedge).
            if not extra_vtox_tags:
                await self.tick()
            assert int(self.dut.ov_state_q.value) == OV_IDLE
            assert (int(self.dut.ov_pend_q.value) >> ov_tag) & 1 == 1
            return
        for _ in range(30):
            if int(self.dut.ov_state_q.value) == target_state:
                return
            await self.tick()
        raise AssertionError(
            f"failed to reach ov_state {target_state}, at {int(self.dut.ov_state_q.value)}"
        )


@cocotb.test()
async def test_full_flush_every_offhead_and_cpush_state(dut: Any) -> None:
    """Full speculative flush clears every off-head state while preserving cpush_q."""
    Clock(dut.i_clk, 10, unit="ns").start()
    b = VecUnitBench(dut)
    await b.reset()
    await b.write_vreg_splat(0, 0xAAAA_AAAA_5555_5555, sew=64, tag=0)
    await b.write_vreg_splat(2, 0x1234_5678_9ABC_DEF0, sew=64, tag=1)

    # Sweep every off-head FSM state: OV_IDLE (live ov_pend_q), OV_CHK (stalled
    # on older ROB write), OV_CAP_MV (vmv.x.s & vfmv.f.s), OV_RD0 (masked
    # vcpop.m), OV_ST1 (masked & unmasked), OV_ST2, OV_REDUCE, and OV_OUT.
    cases: tuple[tuple[int, int, int | None, str], ...] = (
        (OV_IDLE, enc_vmv_xs(2), None, "OV_IDLE_pend"),
        (OV_CHK, enc_vmv_xs(2), 4, "OV_CHK_hazard"),
        (OV_CAP_MV, enc_vmv_xs(2), None, "OV_CAP_MV_int"),
        (OV_CAP_MV, enc_vfmv_fs(2), None, "OV_CAP_MV_fp"),
        (OV_RD0, enc_vcpop_m(2, vm=0), None, "OV_RD0_masked"),
        (OV_ST1, enc_vcpop_m(2, vm=0), None, "OV_ST1_masked"),
        (OV_ST1, enc_vfirst_m(2, vm=1), None, "OV_ST1_unmasked"),
        (OV_ST2, enc_vcpop_m(2, vm=0), None, "OV_ST2"),
        (OV_REDUCE, enc_vfirst_m(2, vm=0), None, "OV_REDUCE"),
        (OV_OUT, enc_vcpop_m(2, vm=0), None, "OV_OUT_backpressured"),
    )
    for target, insn, blocker, label in cases:
        await b.reach_ov_state(
            target,
            head_tag=4,
            ov_tag=5,
            insn=insn,
            sew=32,
            older_blocker_tag=blocker,
            older_blocker_vd=2,
            grant=0,
        )
        if target == OV_OUT:
            # Hold CDB backpressure for two cycles before full flush.
            s_bp = await b.tick(i_grant=0)
            assert s_bp["comp"]["valid"] == 1 and s_bp["comp"]["tag"] == 5, label
            s_bp2 = await b.tick(i_grant=0)
            assert s_bp2["comp"]["valid"] == 1 and s_bp2["ov_state"] == OV_OUT, label
        # Full flush cycle: ROB empties on this edge while CDB arbiter kills
        # slot 6 (i_grant=0); i_rob_empty rises on the next cycle alongside
        # flush_spec_d1_q.
        await b.tick(i_flush_spec=1, i_flush_all=1, i_rob_empty=0, i_grant=0)
        # Delayed cleanup cycle (flush_spec_d1_q == 1): even with i_grant=1,
        # no completion may surface and ov_state_q clears to OV_IDLE.
        s_d1 = await b.tick(i_rob_empty=1, i_grant=1)
        assert s_d1["flush_spec_d1"] == 1, label
        assert s_d1["comp"]["valid"] == 0, (label, s_d1)
        assert s_d1["ov_pend"] == 0, (label, s_d1)
        assert s_d1["o_idle"] == 1, (label, s_d1)
        assert int(dut.ov_state_q.value) == OV_IDLE, label

    # Full flush while alloc_q holds a newly allocated VTOX op.
    b.set_state(
        i_head_tag=6, i_rob_empty=0, i_vl=b.vlen, i_vtype=make_vtype(32), i_grant=1
    )
    await b.tick(
        i_alloc=1,
        i_alloc_tag=6,
        i_alloc_is_vtox=1,
        i_alloc_vtype=make_vtype(32),
        i_alloc_insn=enc_vmv_xs(2),
    )
    # Next cycle: alloc_q_valid is high; i_flush_spec must kill alloc_q_live.
    await b.tick(i_flush_spec=1, i_flush_all=1, i_rob_empty=0, i_grant=0)
    s_clean = await b.tick(i_rob_empty=1, i_grant=1)
    assert s_clean["ov_pend"] == 0 and s_clean["comp"]["valid"] == 0
    assert int(dut.ov_state_q.value) == OV_IDLE

    # Full flush on the exact cycle committed work is staged in cpush_q.
    expected = 0xCAFE_BABE_1234_5678
    vtype64 = make_vtype(64)
    b.set_state(
        i_head_tag=8, i_rob_empty=0, i_vl=b.vlen // 64, i_vtype=vtype64, i_grant=0
    )
    await b.tick(
        i_alloc=1,
        i_alloc_tag=8,
        i_alloc_is_varith=1,
        i_alloc_vtype=vtype64,
        i_alloc_insn=enc_vmv_vx(5),
    )
    await b.tick(
        i_alloc=1,
        i_alloc_tag=9,
        i_alloc_is_vtox=1,
        i_alloc_vtype=vtype64,
        i_alloc_insn=enc_vmv_xs(5),
    )
    await b.tick()
    # Commit tag 8; cpush_valid_q rises on the next cycle.
    await b.tick(
        i_commit_valid=1,
        i_commit_tag=8,
        i_commit_value=expected,
        i_head_tag=9,
        i_rob_empty=0,
    )
    s_cpush = await b.tick(i_flush_spec=1, i_flush_all=1, i_rob_empty=0, i_grant=0)
    assert s_cpush["cpush_valid"] == 1, "expected staged committed work in cpush_q"
    await b.tick(i_rob_empty=1, i_grant=1)
    # Verify staged committed write survives the flush and reaches the VRF.
    await b.wait_idle()
    got = await b.run_vtox_expect(enc_vmv_xs(5), sew=64, vl=b.vlen // 64, tag=10)
    assert got == expected, (
        f"cpush_q write lost on full flush: {got:#x} != {expected:#x}"
    )
    dut._log.info(
        "Full flush verified across all 10 off-head cases, alloc_q, and cpush_q"
    )


@cocotb.test()
async def test_partial_flush_every_offhead_wrap_and_cpush(dut: Any) -> None:
    """Partial flush squashes younger and preserves older ops in every state and across wrap."""
    Clock(dut.i_clk, 10, unit="ns").start()
    b = VecUnitBench(dut)
    await b.reset()
    v0_pat = 0xF0F0_0F0F_AAAA_5555
    v2_pat = 0x0123_4567_89AB_CDEF
    await b.write_vreg_splat(0, v0_pat, sew=64, tag=0)
    await b.write_vreg_splat(2, v2_pat, sew=64, tag=1)

    v0_full = mask_from_elems(b.vlen, 64, v0_pat)
    v2_full = mask_from_elems(b.vlen, 64, v2_pat)
    exp_mv32 = (
        ((v2_pat & 0xFFFF_FFFF) | (0xFFFF_FFFF << 32))
        if (v2_pat >> 31) & 1
        else (v2_pat & 0xFFFF_FFFF)
    )
    exp_fmv32 = 0xFFFF_FFFF_0000_0000 | (v2_pat & 0xFFFF_FFFF)
    exp_cpop_m = (v0_full & v2_full).bit_count()
    exp_first_u = ((v2_full) & -(v2_full)).bit_length() - 1
    active_m = v0_full & v2_full
    exp_first_m = (active_m & -active_m).bit_length() - 1

    # (a) Younger-squashed partial flush in every off-head state, including
    # simultaneous ROB head advancement (head_tag_q=2, i_head_tag=3, flush_tag=3, ov_tag=4).
    younger_cases: tuple[tuple[int, int, int | None, str], ...] = (
        (OV_IDLE, enc_vmv_xs(2), None, "younger_OV_IDLE"),
        (OV_CHK, enc_vmv_xs(2), 3, "younger_OV_CHK"),
        (OV_CAP_MV, enc_vmv_xs(2), None, "younger_OV_CAP_MV"),
        (OV_RD0, enc_vcpop_m(2, vm=0), None, "younger_OV_RD0"),
        (OV_ST1, enc_vcpop_m(2, vm=0), None, "younger_OV_ST1"),
        (OV_ST2, enc_vcpop_m(2, vm=0), None, "younger_OV_ST2"),
        (OV_REDUCE, enc_vfirst_m(2, vm=0), None, "younger_OV_REDUCE"),
        (OV_OUT, enc_vcpop_m(2, vm=0), None, "younger_OV_OUT"),
    )
    for target, insn, blocker, label in younger_cases:
        await b.reach_ov_state(
            target,
            head_tag=2,
            ov_tag=4,
            insn=insn,
            sew=32,
            older_blocker_tag=blocker,
            older_blocker_vd=2,
            grant=0,
        )
        # Advance i_head_tag 2 -> 3 on the flush cycle to exercise head_tag_q
        # vs i_head_tag agreement on partial flush.
        s_fl = await b.tick(
            i_flush_en=1, i_flush_tag=3, i_head_tag=3, i_rob_empty=0, i_grant=1
        )
        assert s_fl["comp"]["valid"] == 0, (label, s_fl)
        assert int(dut.ov_state_q.value) == OV_IDLE, label
        assert ((int(dut.ov_pend_q.value) >> 4) & 1) == 0, label
        # Clean out any blocker at tag 3 by issuing a full flush before next case.
        await b.tick(i_flush_spec=1, i_flush_all=1, i_rob_empty=0, i_grant=0)
        await b.tick(i_rob_empty=1, i_grant=1)
        await b.wait_idle()

    # (b) Older-preserved partial flush in every off-head state (head=2, ov_tag=3,
    # flush_tag=4, younger pending vtox at tag=5 squashed while tag=3 completes!).
    older_cases: tuple[tuple[int, int, int, str], ...] = (
        (OV_IDLE, enc_vmv_xs(2), exp_mv32, "older_OV_IDLE"),
        (OV_CAP_MV, enc_vfmv_fs(2), exp_fmv32, "older_OV_CAP_MV"),
        (OV_RD0, enc_vcpop_m(2, vm=0), exp_cpop_m, "older_OV_RD0"),
        (OV_ST1, enc_vfirst_m(2, vm=1), exp_first_u, "older_OV_ST1"),
        (OV_ST2, enc_vcpop_m(2, vm=0), exp_cpop_m, "older_OV_ST2"),
        (OV_REDUCE, enc_vfirst_m(2, vm=0), exp_first_m, "older_OV_REDUCE"),
        (OV_OUT, enc_vcpop_m(2, vm=0), exp_cpop_m, "older_OV_OUT"),
    )
    for target, insn, exp_val, label in older_cases:
        extra = () if target == OV_IDLE else (5,)
        await b.reach_ov_state(
            target,
            head_tag=2,
            ov_tag=3,
            insn=insn,
            sew=32,
            extra_vtox_tags=extra,
            grant=0,
        )
        if target == OV_IDLE:
            # Tag 3 is already in ov_pend_q (and will enter OV_CHK on this edge);
            # tag 5 sits in alloc_q on a separate test below. Flush at tag 4.
            pass
        # Flush everything younger than tag 4; tag 3 MUST survive and complete!
        await b.tick(i_flush_en=1, i_flush_tag=4, i_grant=0)
        assert ((int(dut.ov_pend_q.value) >> 5) & 1) == 0, (
            f"{label}: younger tag 5 survived"
        )
        got: int | None = None
        for _ in range(30):
            s = await b.tick(i_grant=1)
            if s["comp"]["valid"]:
                assert s["comp"]["tag"] == 3, (label, s["comp"])
                got = int(s["comp"]["value"])
                break
        assert got == exp_val, f"{label}: {got:#x} != {exp_val:#x}"
        # Ensure no second (squashed tag 5) completion ever surfaces.
        for _ in range(6):
            s_post = await b.tick(i_grant=1)
            assert s_post["comp"]["valid"] == 0, (label, s_post)
        await b.tick(i_commit_valid=1, i_commit_tag=3, i_head_tag=4, i_rob_empty=1)
        await b.wait_idle()

    # Older-preserved OV_CHK (stalled on older varith at tag 2, ov_tag=3, flush_tag=4).
    vtype64 = make_vtype(64)
    val_chk = 0x55AA_1122_3344_6677
    b.set_state(
        i_head_tag=2, i_rob_empty=0, i_vl=b.vlen // 64, i_vtype=vtype64, i_grant=0
    )
    await b.tick(
        i_alloc=1,
        i_alloc_tag=2,
        i_alloc_is_varith=1,
        i_alloc_vtype=vtype64,
        i_alloc_insn=enc_vmv_vx(6),
    )
    await b.tick(
        i_alloc=1,
        i_alloc_tag=3,
        i_alloc_is_vtox=1,
        i_alloc_vtype=vtype64,
        i_alloc_insn=enc_vmv_xs(6),
    )
    await b.tick(
        i_alloc=1,
        i_alloc_tag=5,
        i_alloc_is_vtox=1,
        i_alloc_vtype=vtype64,
        i_alloc_insn=enc_vmv_xs(2),
    )
    # Tag 3 enters OV_CHK and stalls on older varith tag 2.
    for _ in range(5):
        if int(dut.ov_state_q.value) == OV_CHK:
            break
        await b.tick()
    assert int(dut.ov_state_q.value) == OV_CHK
    # Commit tag 2 while tag 3 waits in OV_CHK; on the cpush_valid_q == 1 cycle,
    # issue a partial flush at tag 4 (squashes tag 5, preserves cpush_q and tag 3!).
    await b.tick(
        i_commit_valid=1,
        i_commit_tag=2,
        i_commit_value=val_chk,
        i_head_tag=3,
        i_rob_empty=0,
    )
    s_cp = await b.tick(i_flush_en=1, i_flush_tag=4, i_grant=1)
    assert s_cp["cpush_valid"] == 1
    assert s_cp["ov_state"] == OV_CHK
    got_chk: int | None = None
    for _ in range(40):
        s = await b.tick(i_grant=1)
        if s["comp"]["valid"]:
            assert s["comp"]["tag"] == 3
            got_chk = int(s["comp"]["value"])
            break
    assert got_chk == val_chk, (
        f"older OV_CHK+cpush mismatch: {got_chk:#x} != {val_chk:#x}"
    )
    await b.tick(i_commit_valid=1, i_commit_tag=3, i_head_tag=4, i_rob_empty=1)
    await b.wait_idle()

    # (c) ROB tag wraparound: head=30, older varith at tag 31, off-head vmv.x.s
    # at tag 1 (wrapped!), branch at tag 2, younger vmv.x.s at tag 3 (squashed!).
    wrap_val = 0xFEED_FACE_DEAD_BEEF
    b.set_state(
        i_head_tag=30, i_rob_empty=0, i_vl=b.vlen // 64, i_vtype=vtype64, i_grant=1
    )
    await b.tick(
        i_alloc=1,
        i_alloc_tag=31,
        i_alloc_is_varith=1,
        i_alloc_vtype=vtype64,
        i_alloc_insn=enc_vmv_vx(7),
    )
    await b.tick(
        i_alloc=1,
        i_alloc_tag=1,
        i_alloc_is_vtox=1,
        i_alloc_vtype=vtype64,
        i_alloc_insn=enc_vmv_xs(7),
    )
    await b.tick(
        i_alloc=1,
        i_alloc_tag=3,
        i_alloc_is_vtox=1,
        i_alloc_vtype=vtype64,
        i_alloc_insn=enc_vmv_xs(2),
    )
    # Tag 1 (oldest pending in circular order from head=30) must be picked and
    # stalled in OV_CHK by older tag 31.
    for _ in range(6):
        s_w = await b.tick()
        assert s_w["comp"]["valid"] == 0, (
            "tag 1 bypassed older wrap-around write at tag 31"
        )
    assert int(dut.ov_state_q.value) == OV_CHK
    assert int(dut.ov_tag_q.value) == 1
    # Partial flush at tag 2 squashes younger tag 3, keeps tag 31 and tag 1.
    await b.tick(i_flush_en=1, i_flush_tag=2, i_head_tag=31)
    assert ((int(dut.ov_pend_q.value) >> 3) & 1) == 0
    assert int(dut.ov_state_q.value) == OV_CHK
    # Retire tag 31 across the 31 -> 0 wrap boundary.
    await b.tick(
        i_commit_valid=1,
        i_commit_tag=31,
        i_commit_value=wrap_val,
        i_head_tag=0,
        i_rob_empty=0,
    )
    got_wrap: int | None = None
    for _ in range(40):
        s = await b.tick(i_head_tag=1)
        if s["comp"]["valid"]:
            assert s["comp"]["tag"] == 1
            got_wrap = int(s["comp"]["value"])
            break
    assert got_wrap == wrap_val, f"wraparound value {got_wrap:#x} != {wrap_val:#x}"
    for _ in range(6):
        s_after = await b.tick()
        assert s_after["comp"]["valid"] == 0, "squashed wrapped tag 3 completed"
    await b.tick(i_commit_valid=1, i_commit_tag=1, i_head_tag=2, i_rob_empty=1)
    await b.wait_idle()
    dut._log.info(
        "Partial flush verified across all off-head states, cpush_q, and ROB wrap"
    )


@cocotb.test()
async def test_nearly_full_viq_staged_commit_and_port_handoff(dut: Any) -> None:
    """Nearly full VIQ with staged cpush_q, port-4 handoff across OV_RD0, and all VTOX/VTOF formats."""
    Clock(dut.i_clk, 10, unit="ns").start()
    b = VecUnitBench(dut)
    await b.reset()

    # Initialize operands for slow divider (v10 / v11 -> v13) and accumulator (v12 = 1).
    vtype32 = make_vtype(32)
    vl32 = b.vlen // 32
    await b.write_vreg_splat(10, 0x0000_0064_0000_0064, sew=64, tag=0)
    await b.write_vreg_splat(11, 0x0000_0007_0000_0007, sew=64, tag=1)
    await b.write_vreg_splat(12, 0x0000_0001_0000_0001, sew=64, tag=2)

    # Part A: Fill VIQ to count_q == 7/8 with staged committed work in cpush_q
    # while vec_int_exec runs a multi-cycle vdivu.vv (vl=2 keeps runtime short
    # across all VLENs while still holding u_engine busy >120 cycles). Model
    # the 1-cycle registered commit bus between o_commit_hold and i_commit_valid.
    num_adds = 10
    b.set_state(i_head_tag=0, i_rob_empty=0, i_vl=2, i_vtype=vtype32, i_grant=1)
    # Tag 0: vdivu.vv v13, v10, v11 (holds u_engine busy while VIQ fills).
    await b.tick(
        i_alloc=1,
        i_alloc_tag=0,
        i_alloc_is_varith=1,
        i_alloc_vtype=vtype32,
        i_alloc_insn=enc_vdivu_vv(13, 10, 11),
    )
    # Tags 1..10: vadd.vx v12, v12, x1 (each adds +1).
    for t in range(1, num_adds + 1):
        await b.tick(
            i_alloc=1,
            i_alloc_tag=t,
            i_alloc_is_varith=1,
            i_alloc_vtype=vtype32,
            i_alloc_insn=enc_vadd_vx(12, 12),
        )
    # Speculative younger vmv.x.s at tag 12 behind branch at tag 11 (will be
    # partially flushed right when VIQ is nearly full and cpush_q is live).
    await b.tick(
        i_alloc=1,
        i_alloc_tag=12,
        i_alloc_is_vtox=1,
        i_alloc_vtype=vtype32,
        i_alloc_insn=enc_vmv_xs(12),
    )
    await b.tick()

    next_retire = 0
    pending_commit: tuple[int, int] | None = None
    max_count = 0
    saw_commit_hold = False
    saw_near_full_cpush = False
    flushed_near_full = False

    for _ in range(600):
        pulses: dict[str, int] = {}
        if pending_commit is not None:
            ctag, cval = pending_commit
            pulses["i_commit_valid"] = 1
            pulses["i_commit_tag"] = ctag
            pulses["i_commit_value"] = cval
            pulses["i_head_tag"] = ctag + 1
            pending_commit = None

        # Peek current state to trigger a partial flush right when VIQ is nearly
        # full (count_q >= 6) with staged committed work in cpush_q!
        cur_count = int(dut.count_q.value)
        cur_cpush = int(dut.cpush_valid_q.value)
        if not flushed_near_full and cur_count >= 6 and cur_cpush == 1:
            pulses["i_flush_en"] = 1
            pulses["i_flush_tag"] = 11
            flushed_near_full = True
            saw_near_full_cpush = True

        s = await b.tick(**pulses)
        max_count = max(max_count, s["count"])
        if s["o_commit_hold"]:
            saw_commit_hold = True
        assert s["comp"]["valid"] == 0, "speculative tag 12 completed prematurely"

        # ROB retirement decision for the NEXT cycle (1-cycle registered commit bus):
        # ROB checks o_commit_hold on this cycle and, if low, commits next_retire.
        if next_retire <= num_adds and s["o_commit_hold"] == 0:
            pending_commit = (next_retire, 0 if next_retire == 0 else 1)
            next_retire += 1

        if next_retire > num_adds and pending_commit is None and s["o_idle"] == 1:
            break
    else:
        raise AssertionError(
            f"VIQ stress burst did not drain (next_retire={next_retire}, "
            f"count={int(dut.count_q.value)}, ov_state={int(dut.ov_state_q.value)}, "
            f"cpush={int(dut.cpush_valid_q.value)}, o_idle={int(dut.o_idle.value)})"
        )

    assert saw_commit_hold, "expected o_commit_hold to assert under nearly full VIQ"
    assert max_count >= 7, f"expected VIQ count_q to reach >= 7, got {max_count}"
    assert saw_near_full_cpush, (
        "expected partial flush with count_q >= 6 and cpush_valid_q == 1"
    )

    # Read v12 via off-head vmv.x.s: must equal 1 + num_adds == 11 (all staged
    # committed ops executed exactly once despite backpressure and partial flush).
    got_sum = await b.run_vtox_expect(enc_vmv_xs(12), sew=32, vl=vl32, tag=13)
    assert got_sum == 1 + num_adds, f"v12 mismatch: {got_sum} != {1 + num_adds}"

    # Part B: Port-4 handoff between u_head_mmu / u_vmu (unit-stride vector store
    # vse32.v of v19 at tag 0) and masked vcpop.m of v16 at tag 1 (pauses in
    # OV_CHK across vhead_port_claim_q and in OV_RD0 with ov_s2_cap_q == 1
    # across vmu_busy_q!). Distinct store data in v19 ensures an overwrite of
    # ov_s2_q during OV_RD0 changes the popcount.
    v0_pat = 0x5555_AAAA_3333_555F
    v16_pat = 0xFFFF_00FF_0F0F_F0FD
    v19_pat = 0x0000_0000_0000_0000
    await b.write_vreg_splat(0, v0_pat, sew=64, tag=14)
    await b.write_vreg_splat(16, v16_pat, sew=64, tag=15)
    await b.write_vreg_splat(19, v19_pat, sew=64, tag=16)
    vl_mask = (1 << vl32) - 1
    exp_pop = (
        mask_from_elems(b.vlen, 64, v0_pat)
        & mask_from_elems(b.vlen, 64, v16_pat)
        & vl_mask
    ).bit_count()
    store_pop = (
        mask_from_elems(b.vlen, 64, v0_pat)
        & mask_from_elems(b.vlen, 64, v19_pat)
        & vl_mask
    ).bit_count()
    assert exp_pop > 0 and store_pop != exp_pop

    b.set_state(
        i_head_tag=0,
        i_rob_empty=0,
        i_vl=vl32,
        i_vtype=vtype32,
        i_rf_read_data=0x80000100,
        i_translate=0,
        i_lc_req_ready=0,
        i_grant=1,
    )
    await b.tick(
        i_alloc=1,
        i_alloc_tag=0,
        i_alloc_is_vmem=1,
        i_alloc_is_vload=0,
        i_alloc_vmt_idx=0,
        i_alloc_vtype=vtype32,
        i_alloc_insn=enc_vse32(19),
    )
    await b.tick(
        i_alloc=1,
        i_alloc_tag=1,
        i_alloc_is_vtox=1,
        i_alloc_vtype=vtype32,
        i_alloc_insn=enc_vcpop_m(16, vm=0),
    )

    store_cdb_done = False
    store_cdb_wait = 0
    store_retired = False
    saw_vhead_claim = False
    saw_vmu_busy = False
    saw_rd0_hold = False
    got_pop: int | None = None
    lc_pending: list[int] = []
    lc_stall_cycles = 0

    for _ in range(150):
        pulses = {}
        # Wait 2 cycles after vhead CDB grant before retiring tag 0 (matches ROB).
        if store_cdb_done and not store_retired:
            store_cdb_wait += 1
            if store_cdb_wait == 2:
                pulses["i_commit_valid"] = 1
                pulses["i_commit_tag"] = 0
                pulses["i_head_tag"] = 1
                store_retired = True
        if lc_pending:
            pulses["i_lc_resp_valid"] = 1
            pulses["i_lc_resp_id"] = lc_pending.pop(0)
        # Hold u_vmu busy for a few cycles so OV_RD0/OV_CHK visibly contend on port 4.
        lc_ready = 1 if lc_stall_cycles >= 4 else 0
        pulses["i_lc_req_ready"] = lc_ready

        s = await b.tick(**pulses)
        if s["o_lc_req_valid"]:
            if lc_ready:
                lc_pending.append(int(s["o_lc_req_id"]))
            else:
                lc_stall_cycles += 1
        if s["vhead_port_claim"]:
            saw_vhead_claim = True
        if s["vmu_busy"]:
            saw_vmu_busy = True
        if s["ov_state"] == OV_RD0 and s["ov_s2_cap"] == 1 and s["vmu_busy"] == 1:
            saw_rd0_hold = True

        if s["comp"]["valid"]:
            if s["comp"]["tag"] == 0:
                assert not store_cdb_done
                store_cdb_done = True
            elif s["comp"]["tag"] == 1:
                assert s["comp"]["exception"] == 0
                got_pop = int(s["comp"]["value"])
                break

    assert store_cdb_done and store_retired
    assert saw_vhead_claim and saw_vmu_busy and saw_rd0_hold
    assert got_pop == exp_pop, f"port-4 handoff vcpop.m: {got_pop} != {exp_pop}"
    await b.tick(
        i_commit_valid=1, i_commit_tag=1, i_head_tag=2, i_rob_empty=1, i_lc_req_ready=1
    )
    # Finish any remaining store line-client traffic cleanly.
    for _ in range(30):
        pulses = {"i_lc_req_ready": 1}
        if lc_pending:
            pulses["i_lc_resp_valid"] = 1
            pulses["i_lc_resp_id"] = lc_pending.pop(0)
        s = await b.tick(**pulses)
        if s["o_lc_req_valid"]:
            lc_pending.append(int(s["o_lc_req_id"]))
        if s["o_idle"] == 1 and not lc_pending:
            break
    assert int(dut.o_idle.value) == 1

    # Part C: Verify sign-extension (vmv.x.s SEW 8/16/32/64), NaN-boxing
    # (vfmv.f.s SEW 16/32/64), and vfirst.m not-found (-1).
    await b.write_vreg_splat(17, 0x0123_4567_89AB_CDEF, sew=64, tag=2)
    await b.write_vreg_splat(18, 0, sew=64, tag=3)
    assert (
        await b.run_vtox_expect(enc_vmv_xs(17), sew=8, vl=4, tag=4)
        == 0xFFFF_FFFF_FFFF_FFEF
    )
    assert (
        await b.run_vtox_expect(enc_vmv_xs(17), sew=16, vl=4, tag=5)
        == 0xFFFF_FFFF_FFFF_CDEF
    )
    assert (
        await b.run_vtox_expect(enc_vmv_xs(17), sew=32, vl=4, tag=6)
        == 0xFFFF_FFFF_89AB_CDEF
    )
    assert (
        await b.run_vtox_expect(enc_vmv_xs(17), sew=64, vl=2, tag=7)
        == 0x0123_4567_89AB_CDEF
    )
    assert (
        await b.run_vtox_expect(enc_vfmv_fs(17), sew=16, vl=4, tag=8)
        == 0xFFFF_FFFF_FFFF_CDEF
    )
    assert (
        await b.run_vtox_expect(enc_vfmv_fs(17), sew=32, vl=4, tag=9)
        == 0xFFFF_FFFF_89AB_CDEF
    )
    assert (
        await b.run_vtox_expect(enc_vfmv_fs(17), sew=64, vl=2, tag=10)
        == 0x0123_4567_89AB_CDEF
    )
    assert (
        await b.run_vtox_expect(enc_vfirst_m(18, vm=1), sew=32, vl=b.vlen, tag=11)
        == MASK64
    )
    dut._log.info(
        f"VLEN={b.vlen}: near-full VIQ (max_count={max_count}), port-4 handoff "
        f"(rd0_hold={saw_rd0_hold}), and all VTOX/VTOF formats verified"
    )


@cocotb.test()
async def test_vmu_done_idle_handoff(dut: Any) -> None:
    """Verify zero-bubble vmu_done -> vec_backend_idle_q handoff and hazard gating."""
    Clock(dut.i_clk, 10, unit="ns").start()
    b = VecUnitBench(dut)
    await b.reset()

    vl32 = b.vlen // 32
    vtype32 = make_vtype(32)
    b.set_state(
        i_head_tag=0,
        i_rob_empty=0,
        i_vl=vl32,
        i_vtype=vtype32,
        i_rf_read_data=0x80000100,
        i_translate=0,
        i_lc_req_ready=1,
        i_grant=1,
    )

    def _check_invariants(s: dict[str, int]) -> None:
        assert not (s["vmu_done"] and s["vmu_idle"]), "vmu_done overlapped vmu_idle"
        assert not (s["vmu_done"] and s["vmu_cmd_valid"]), (
            "vmu_done overlapped vmu_cmd_valid"
        )
        if s["vec_backend_idle_q"]:
            assert s["vmu_idle"] == 1, "vec_backend_idle_q set while VMU active"
            assert s["vmem_desc_valid"] == 0, (
                "vec_backend_idle_q set while VMU descriptor pending"
            )

    # Part A: Back-to-back vle32.v (tag 0) -> vse32.v (tag 1).
    # On the cycle after tag 0 pulses vmu_done, vec_backend_idle_q must rise
    # immediately with vmu_idle so u_head_mmu enters HM_WAIT without a bubble.
    await b.tick(
        i_alloc=1,
        i_alloc_tag=0,
        i_alloc_is_vmem=1,
        i_alloc_is_vload=1,
        i_alloc_vmt_idx=0,
        i_alloc_vtype=vtype32,
        i_alloc_insn=enc_vle32(4),
    )
    await b.tick(
        i_alloc=1,
        i_alloc_tag=1,
        i_alloc_is_vmem=1,
        i_alloc_is_vload=0,
        i_alloc_vmt_idx=1,
        i_alloc_vtype=vtype32,
        i_alloc_insn=enc_vse32(4),
    )

    lc_pending: list[int] = []
    t0_cdb = False
    t0_wait = 0
    t0_ret = False
    t1_cdb = False
    t1_wait = 0
    t1_ret = False
    saw_t0_done = False
    after_t0_done = 0

    for _ in range(150):
        pulses: dict[str, int] = {}
        if t0_cdb and not t0_ret:
            t0_wait += 1
            if t0_wait == 2:
                pulses["i_commit_valid"] = 1
                pulses["i_commit_tag"] = 0
                pulses["i_head_tag"] = 1
                t0_ret = True
        elif t1_cdb and not t1_ret:
            t1_wait += 1
            if t1_wait == 2:
                pulses["i_commit_valid"] = 1
                pulses["i_commit_tag"] = 1
                pulses["i_head_tag"] = 2
                pulses["i_rob_empty"] = 1
                t1_ret = True
        if lc_pending:
            pulses["i_lc_resp_valid"] = 1
            pulses["i_lc_resp_id"] = lc_pending.pop(0)
            pulses["i_lc_resp_data"] = 0x11223344_55667788

        s = await b.tick(**pulses)
        _check_invariants(s)
        if s["o_lc_req_valid"]:
            lc_pending.append(int(s["o_lc_req_id"]))

        if saw_t0_done and after_t0_done == 1:
            assert s["vmu_idle"] == 1
            assert s["vec_backend_idle_q"] == 1, (
                "vec_backend_idle_q delayed after vmu_done"
            )
            assert s["hm_vec_idle"] == 1
            assert s["hm_state"] == 0  # HM_IDLE launching transition this edge
            after_t0_done = 2
        elif saw_t0_done and after_t0_done == 2:
            assert s["hm_state"] == 1, (
                f"expected HM_WAIT (1) on vmu_done+2, got {s['hm_state']}"
            )
            after_t0_done = 3

        if t0_ret and not saw_t0_done and s["vmu_done"]:
            assert s["vmu_idle"] == 0
            assert s["vmu_cmd_valid"] == 0
            assert s["vec_backend_idle_q"] == 0
            saw_t0_done = True
            after_t0_done = 1

        if s["comp"]["valid"]:
            if s["comp"]["tag"] == 0:
                t0_cdb = True
            elif s["comp"]["tag"] == 1:
                t1_cdb = True

        if t1_ret and s["o_idle"] == 1 and not lc_pending:
            break

    assert saw_t0_done and after_t0_done == 3 and t1_ret
    assert int(dut.o_idle.value) == 1

    # Part B: Committed varith arriving on the exact vmu_done cycle must keep
    # vec_backend_idle_q low so the following vle32.v waits for it to finish.
    b.set_state(i_head_tag=2, i_rob_empty=0)
    await b.tick(
        i_alloc=1,
        i_alloc_tag=2,
        i_alloc_is_vmem=1,
        i_alloc_is_vload=0,
        i_alloc_vmt_idx=0,
        i_alloc_vtype=vtype32,
        i_alloc_insn=enc_vse32(4),
    )
    await b.tick(
        i_alloc=1,
        i_alloc_tag=3,
        i_alloc_is_varith=1,
        i_alloc_vtype=vtype32,
        i_alloc_insn=enc_vadd_vx(5, 4),
    )
    await b.tick(
        i_alloc=1,
        i_alloc_tag=4,
        i_alloc_is_vmem=1,
        i_alloc_is_vload=1,
        i_alloc_vmt_idx=1,
        i_alloc_vtype=vtype32,
        i_alloc_insn=enc_vle32(6),
    )

    t2_cdb = False
    t2_wait = 0
    t2_ret = False
    t3_committed = False
    t4_cdb = False
    t4_wait = 0
    t4_ret = False
    checked_blocked_cycle = False

    for _ in range(200):
        pulses = {}
        if t2_cdb and not t2_ret:
            t2_wait += 1
            if t2_wait == 2:
                pulses["i_commit_valid"] = 1
                pulses["i_commit_tag"] = 2
                pulses["i_head_tag"] = 3
                t2_ret = True
        elif t2_ret and not t3_committed and int(dut.vmu_done.value) == 1:
            # Commit varith tag 3 on the exact vmu_done cycle of tag 2!
            pulses["i_commit_valid"] = 1
            pulses["i_commit_tag"] = 3
            pulses["i_commit_value"] = 7
            pulses["i_head_tag"] = 4
            t3_committed = True
        elif t4_cdb and not t4_ret:
            t4_wait += 1
            if t4_wait == 2:
                pulses["i_commit_valid"] = 1
                pulses["i_commit_tag"] = 4
                pulses["i_head_tag"] = 5
                pulses["i_rob_empty"] = 1
                t4_ret = True
        if lc_pending:
            pulses["i_lc_resp_valid"] = 1
            pulses["i_lc_resp_id"] = lc_pending.pop(0)
            pulses["i_lc_resp_data"] = 0

        was_t3_commit = t3_committed and not checked_blocked_cycle
        s = await b.tick(**pulses)
        _check_invariants(s)
        if s["o_lc_req_valid"]:
            lc_pending.append(int(s["o_lc_req_id"]))

        if was_t3_commit:
            # On the cycle immediately following (vmu_done && varith_commit_only),
            # vmu_idle is 1 but cpush_valid_q holds tag 3 so vec_backend_idle_q
            # MUST remain 0 and tag 4 must stay in HM_IDLE.
            if s["cpush_valid"] == 1:
                assert s["vmu_idle"] == 1
                assert s["vec_backend_idle_q"] == 0, (
                    "vec_backend_idle_q falsely asserted while varith staged"
                )
                assert s["hm_vec_idle"] == 0
                assert s["hm_state"] == 0
                checked_blocked_cycle = True

        if s["comp"]["valid"]:
            if s["comp"]["tag"] == 2:
                t2_cdb = True
            elif s["comp"]["tag"] == 4:
                t4_cdb = True

        if t4_ret and s["o_idle"] == 1 and not lc_pending:
            break

    assert t3_committed and checked_blocked_cycle and t4_ret
    assert int(dut.o_idle.value) == 1
    dut._log.info(
        f"VLEN={b.vlen}: zero-bubble vmu_done handoff and varith-on-vmu_done block verified"
    )
