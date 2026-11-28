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

"""Back-to-back split-issue (SPLIT_ISSUE=1) checks for vec_engine.

Drives vec_engine the same way vec_unit does: group-ALU instructions issue on
the first cycle o_grp_ready is high without waiting for o_idle, exercising the
R1/E0/E1/E2/W/MWR RAW hazard logic, pipe_tail_wr_mask_q, group skipping past
vl, mask-destination compare serialization, v0 hazards, and split i_int_valid
handoff (including multi-beat single-width and widening multiply-accumulate).
All 32 architectural vector registers are checked against the element-level
reference model after each burst.
"""

import random
from dataclasses import dataclass
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge

from cocotb_tests.vector.test_vec_engine import OPS, UIMM, UNARY, Model

NAME_TO_FUNCT6: dict[str, int] = {name: f6 for f6, (name, _) in OPS.items()}
UNARY_TO_CODE: dict[str, int] = {name: code for code, name in UNARY.items()}


@dataclass(frozen=True)
class EngineOp:
    """One encoded vec_engine instruction and its model inputs."""

    kind: str  # "grp" or "int"
    name: str
    form: str
    sew: int
    lmul_code: int
    vl: int
    vstart: int
    vm: int
    vd: int
    vs1: int
    vs2: int
    scalar: int
    rs1: int
    insn: int


def encode_grp_op(
    name: str,
    form: str,
    sew: int,
    lmul_code: int,
    vl: int,
    vstart: int,
    vm: int,
    vd: int,
    vs1: int,
    vs2: int,
    rs1: int = 0,
    imm5: int = 0,
    imm6_hi: int = 0,
) -> EngineOp:
    """Encode a group-ALU instruction for vec_engine."""
    if name in UNARY_TO_CODE:
        funct6 = 0b010010
        f3 = 0b010
        field15 = UNARY_TO_CODE[name]
        scalar = 0
    elif name == "mv":
        funct6 = 0b010111
        vm = 1
        vs2 = 0
        f3 = {"vv": 0b000, "vx": 0b100, "vi": 0b011}[form]
        if form == "vi":
            scalar = (imm5 - 32 if imm5 & 16 else imm5) & ((1 << sew) - 1)
            field15 = imm5 & 0x1F
        else:
            scalar = rs1 & ((1 << sew) - 1)
            field15 = vs1
    else:
        funct6 = NAME_TO_FUNCT6[name]
        if name == "merge":
            vm = 0
        f3 = {"vv": 0b000, "vx": 0b100, "vi": 0b011}[form]
        if form == "vi":
            if name in UIMM:
                scalar = imm5 & 0x1F
                if name == "ror" and imm6_hi:
                    scalar |= 32
                    funct6 = 0b010101
            else:
                scalar = imm5 - 32 if imm5 & 16 else imm5
            scalar &= (1 << sew) - 1
            field15 = imm5 & 0x1F
        else:
            scalar = rs1 & ((1 << sew) - 1)
            field15 = vs1
    insn = (
        (funct6 << 26)
        | (vm << 25)
        | (vs2 << 20)
        | (field15 << 15)
        | (f3 << 12)
        | (vd << 7)
        | 0b1010111
    )
    return EngineOp(
        kind="grp",
        name=name,
        form=form,
        sew=sew,
        lmul_code=lmul_code,
        vl=vl,
        vstart=vstart,
        vm=vm,
        vd=vd,
        vs1=vs1,
        vs2=vs2,
        scalar=scalar,
        rs1=rs1,
        insn=insn,
    )


def encode_vmacc_vv(
    sew: int, lmul_code: int, vl: int, vstart: int, vm: int, vd: int, vs1: int, vs2: int
) -> EngineOp:
    """Encode vmacc.vv (OPMVV, funct6=101101, funct3=010) for split i_int_valid."""
    insn = (
        (0b101101 << 26)
        | (vm << 25)
        | (vs2 << 20)
        | (vs1 << 15)
        | (0b010 << 12)
        | (vd << 7)
        | 0b1010111
    )
    return EngineOp(
        kind="int",
        name="vmacc",
        form="vv",
        sew=sew,
        lmul_code=lmul_code,
        vl=vl,
        vstart=vstart,
        vm=vm,
        vd=vd,
        vs1=vs1,
        vs2=vs2,
        scalar=0,
        rs1=0,
        insn=insn,
    )


def encode_vwmacc_vv(
    sew: int, lmul_code: int, vl: int, vstart: int, vm: int, vd: int, vs1: int, vs2: int
) -> EngineOp:
    """Encode vwmacc.vv (OPMVV, funct6=111101, funct3=010) for split i_int_valid."""
    insn = (
        (0b111101 << 26)
        | (vm << 25)
        | (vs2 << 20)
        | (vs1 << 15)
        | (0b010 << 12)
        | (vd << 7)
        | 0b1010111
    )
    return EngineOp(
        kind="int",
        name="vwmacc",
        form="vv",
        sew=sew,
        lmul_code=lmul_code,
        vl=vl,
        vstart=vstart,
        vm=vm,
        vd=vd,
        vs1=vs1,
        vs2=vs2,
        scalar=0,
        rs1=0,
        insn=insn,
    )


def apply_model(model: Model, op: EngineOp) -> None:
    """Apply either a group-ALU op, vmacc.vv or vwmacc.vv to the architectural model."""
    if op.kind == "grp":
        model.execute(
            op.name,
            op.form,
            op.sew,
            op.vl,
            op.vstart,
            op.vm,
            op.vd,
            op.vs1,
            op.vs2,
            op.scalar,
        )
        return
    v0 = model.regs[0]
    if op.name == "vmacc":
        mask = (1 << op.sew) - 1
        updates = []
        for i in range(op.vstart, op.vl):
            if op.vm or ((v0 >> i) & 1):
                a = model.elem(op.vs2, i, op.sew)
                b = model.elem(op.vs1, i, op.sew)
                acc = model.elem(op.vd, i, op.sew)
                updates.append((i, (acc + a * b) & mask))
        for i, val in updates:
            model.set_elem(op.vd, i, op.sew, val)
        return
    assert op.name == "vwmacc"
    dsew = 2 * op.sew
    dmask = (1 << dsew) - 1
    sign_bit = 1 << (op.sew - 1)
    updates = []
    for i in range(op.vstart, op.vl):
        if op.vm or ((v0 >> i) & 1):
            a = model.elem(op.vs2, i, op.sew)
            b = model.elem(op.vs1, i, op.sew)
            sa = a - (1 << op.sew) if (a & sign_bit) else a
            sb = b - (1 << op.sew) if (b & sign_bit) else b
            acc = model.elem(op.vd, i, dsew)
            updates.append((i, (acc + sa * sb) & dmask))
    for i, val in updates:
        model.set_elem(op.vd, i, dsew, val)


async def reset_and_load(dut: Any, vlen: int, rng: random.Random) -> Model:
    """Reset vec_engine and populate all 32 vector registers with random values."""
    for sig in (
        "i_valid",
        "i_int_valid",
        "i_fp_valid",
        "i_crypto_valid",
        "i_insn",
        "i_vsew",
        "i_vlmul",
        "i_vl",
        "i_vstart",
        "i_rs1",
        "i_xr_addr",
        "i_xw_en",
        "i_xw_addr",
        "i_xw_data",
        "i_xw_be",
    ):
        getattr(dut, sig).value = 0
    dut.i_rst.value = 1
    for _ in range(3):
        await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)
    dut.i_rst.value = 0

    model = Model(vlen)
    full_be = (1 << (vlen // 8)) - 1
    for r in range(32):
        val = rng.getrandbits(vlen)
        model.regs[r] = val
        dut.i_xw_en.value = 1
        dut.i_xw_addr.value = r
        dut.i_xw_data.value = val
        dut.i_xw_be.value = full_be
        await FallingEdge(dut.i_clk)
    dut.i_xw_en.value = 0
    await FallingEdge(dut.i_clk)
    return model


async def run_burst(
    dut: Any, model: Model, ops: list[EngineOp], label: str
) -> tuple[int, int, int]:
    """Stream ops back to back using SPLIT_ISSUE handshakes, then verify all 32 regs."""
    sew_code = {8: 0, 16: 1, 32: 2, 64: 3}
    overlapped = 0
    stalls = 0
    cycles = 0
    issued_aux = False

    idx = 0
    while idx < len(ops):
        assert int(dut.o_unsupported.value) == 0, f"{label}: unexpected o_unsupported"
        op = ops[idx]
        can_issue = False
        if op.kind == "grp":
            can_issue = (not issued_aux) and bool(int(dut.o_grp_ready.value))
        else:
            can_issue = (not issued_aux) and bool(int(dut.o_idle.value))

        if can_issue:
            if not int(dut.o_idle.value):
                overlapped += 1
            dut.i_valid.value = 1 if op.kind == "grp" else 0
            dut.i_int_valid.value = 1 if op.kind == "int" else 0
            dut.i_insn.value = op.insn
            dut.i_vsew.value = sew_code[op.sew]
            dut.i_vlmul.value = op.lmul_code
            dut.i_vl.value = op.vl
            dut.i_vstart.value = op.vstart
            dut.i_rs1.value = op.rs1
            apply_model(model, op)
            issued_aux = op.kind == "int"
            idx += 1
        else:
            dut.i_valid.value = 0
            dut.i_int_valid.value = 0
            issued_aux = False
            stalls += 1

        await FallingEdge(dut.i_clk)
        cycles += 1
        assert cycles < 4000, f"{label}: stalled at op {idx}/{len(ops)}"

    dut.i_valid.value = 0
    dut.i_int_valid.value = 0

    for _ in range(2000):
        assert int(dut.o_unsupported.value) == 0, (
            f"{label}: unexpected o_unsupported during drain"
        )
        if int(dut.o_idle.value) and not issued_aux:
            break
        issued_aux = False
        await FallingEdge(dut.i_clk)
        cycles += 1
    else:
        raise AssertionError(f"{label}: engine did not return to o_idle")

    assert int(dut.o_wr_mask.value) == 0, (
        f"{label}: o_wr_mask {int(dut.o_wr_mask.value):#x} non-zero while o_idle"
    )

    for r in range(32):
        dut.i_xr_addr.value = r
        await FallingEdge(dut.i_clk)
        got = int(dut.o_xr_data.value)
        if got != model.regs[r]:
            raise AssertionError(f"{label}: v{r} got {got:#x}, want {model.regs[r]:#x}")
    return overlapped, stalls, cycles


def rand_grp_op(rng: random.Random, vlen: int, narrow_pool: bool) -> EngineOp:
    """Build one legal random group-ALU op; narrow_pool biases toward RAW hazards."""
    funct6 = rng.choice(list(OPS) + [0b010010] * 2)
    sew = 8 << rng.randrange(4)
    lmul_code = rng.choice(
        [0, 0, 1, 2, 3, 5, 6, 7] if narrow_pool else [0, 1, 2, 3, 5, 6, 7]
    )
    lmul = 1 << lmul_code if lmul_code < 4 else 1
    frac = {5: 8, 6: 4, 7: 2}.get(lmul_code, 1)
    if sew * frac > 64:
        lmul_code, frac = 0, 1
    vlmax = (vlen // sew) * lmul // frac
    vl = rng.choice([vlmax, rng.randrange(vlmax + 1), min(4, vlmax), 1, 0])
    vstart = rng.randrange(vl + 1) if rng.random() < 0.15 else 0
    vm = rng.getrandbits(1)

    if funct6 == 0b010010:
        name = UNARY[rng.choice(list(UNARY))]
        form = "vv"
    else:
        name, forms = OPS[funct6]
        form = rng.choice(forms.split())
        if funct6 == 0b010111:
            name = "merge" if vm == 0 else "mv"

    groups = lmul
    reg_limit = 8 if (narrow_pool and groups <= 4) else 32
    slots = max(1, reg_limit // groups)
    vs2 = rng.randrange(slots) * groups
    vs1 = rng.randrange(slots) * groups
    if name.startswith("ms"):
        # Include v0 as a legal compare destination to stress v0 MWR hazards.
        vd = rng.randrange(reg_limit)
        while vs2 < vd < vs2 + groups or (form == "vv" and vs1 < vd < vs1 + groups):
            vd = rng.randrange(reg_limit)
    else:
        # Allow v0 as destination when unmasked to stress v0 RAW hazards.
        start_slot = 0 if (vm == 1 and name != "merge" and groups == 1) else 1
        if start_slot >= slots:
            start_slot = 0
        vd = rng.randrange(start_slot, slots) * groups
    if name == "mv":
        vs2 = 0
        vm = 1
    return encode_grp_op(
        name=name,
        form=form,
        sew=sew,
        lmul_code=lmul_code,
        vl=vl,
        vstart=vstart,
        vm=vm,
        vd=vd,
        vs1=vs1,
        vs2=vs2,
        rs1=rng.getrandbits(64),
        imm5=rng.getrandbits(5),
        imm6_hi=rng.getrandbits(1),
    )


@cocotb.test()
async def test_vec_engine_split_directed(dut: Any) -> None:
    """Directed split-issue back-to-back hazard, chaining, skip, v0 and aux tests."""
    vlen = len(dut.o_xr_data)
    epr32 = vlen // 32
    rng = random.Random(9001 + vlen)
    Clock(dut.i_clk, 2, unit="ns").start()
    model = await reset_and_load(dut, vlen, rng)

    # 1. Independent back-to-back stream proves o_grp_ready streams at 1 op/cycle.
    indep = [
        encode_grp_op("add", "vv", 32, 0, epr32, 0, 1, 1 + i, 16 + i, 24 + i)
        for i in range(8)
    ]
    ov, st, cyc = await run_burst(dut, model, indep, "indep_stream")
    assert ov == 7, f"expected 7 overlapped issues in 8 independent ops, got {ov}"
    assert st == 0, f"expected 0 stall cycles for independent ops, got {st}"
    assert cyc < 20, f"expected pipelined completion (<20 cycles), took {cyc}"

    # 2. RAW distances 0..5 on vs2 and vs1 (hits R1, E0, E1, E2, W and clean).
    raw_ops: list[EngineOp] = []
    for dist in range(6):
        raw_ops.append(encode_grp_op("add", "vv", 32, 0, epr32, 0, 1, 2, 10, 11))
        for pad in range(dist):
            raw_ops.append(
                encode_grp_op("xor", "vv", 32, 0, epr32, 0, 1, 20 + pad, 12, 13)
            )
        # Read v2 on vs2, then immediately on vs1.
        raw_ops.append(encode_grp_op("sub", "vv", 32, 0, epr32, 0, 1, 3, 14, 2))
        raw_ops.append(encode_grp_op("add", "vv", 32, 0, epr32, 0, 1, 4, 3, 15))
    ov, st, _ = await run_burst(dut, model, raw_ops, "raw_distances")
    assert ov > 0 and st > 0, (
        f"raw_distances must exercise both overlap ({ov}) and stalls ({st})"
    )

    # 3. Multi-group LMUL=4 chaining + skip-beyond-vl + vl=0 interleaved.
    lmul4_ops = [
        encode_grp_op("add", "vv", 32, 2, 4 * epr32, 0, 1, 4, 8, 12),
        encode_grp_op("xor", "vv", 32, 2, 4 * epr32, 0, 1, 16, 4, 20),
        # Skip groups beyond vl=2 at m8, followed by full m4 consumer reading v8..v11.
        encode_grp_op("sub", "vv", 32, 3, 2, 0, 1, 8, 16, 24),
        encode_grp_op("or", "vv", 32, 2, 4 * epr32, 0, 1, 24, 8, 16),
        # Zero-body op interleaved between active writers/readers.
        encode_grp_op("add", "vv", 32, 2, 0, 0, 1, 8, 16, 24),
        encode_grp_op("and", "vv", 32, 2, 4 * epr32, 0, 1, 28, 24, 8),
    ]
    ov, st, _ = await run_burst(dut, model, lmul4_ops, "lmul4_chain_skip")
    assert ov > 0 and st > 0

    # 4. v0 and old-vd compare RAW distances 0..5 (covers R1..W and MWR).
    v0_ops: list[EngineOp] = []
    for dist in range(6):
        # Producer writes v0, followed by `dist` independent pads, then masked add + vmerge.
        v0_ops.append(encode_grp_op("xor", "vv", 32, 0, epr32, 0, 1, 0, 6, 7))
        for pad in range(dist):
            v0_ops.append(
                encode_grp_op("or", "vv", 32, 0, epr32, 0, 1, 20 + pad, 10, 11)
            )
        v0_ops.append(encode_grp_op("add", "vv", 32, 0, epr32, 0, 0, 5, 8, 9))
        v0_ops.append(encode_grp_op("merge", "vv", 32, 0, epr32, 0, 0, 6, 12, 13))
        # Producer writes v7, followed by `dist` pads, then compare reads old v7.
        v0_ops.append(encode_grp_op("add", "vv", 32, 0, epr32, 0, 1, 7, 14, 15))
        for pad in range(dist):
            v0_ops.append(
                encode_grp_op("sub", "vv", 32, 0, epr32, 0, 1, 20 + pad, 16, 17)
            )
        v0_ops.append(encode_grp_op("mseq", "vv", 32, 0, epr32, 0, 1, 7, 8, 9))
        v0_ops.append(encode_grp_op("add", "vv", 32, 0, epr32, 0, 1, 18, 7, 10))
    # Compare writes v0 directly, then masked op + vmerge read v0.
    v0_ops.extend(
        [
            encode_grp_op("mslt", "vv", 32, 1, 2 * epr32, 0, 1, 0, 8, 10),
            encode_grp_op("sub", "vv", 32, 1, 2 * epr32, 0, 0, 12, 14, 16),
            encode_grp_op("merge", "vi", 32, 0, epr32, 0, 0, 18, 0, 19, imm5=7),
        ]
    )
    await run_burst(dut, model, v0_ops, "v0_and_compare_hazards")

    # 5. Zvbb unary vs2->r_vs1 hazard, VI_MV (vs2 ignored), and split i_int_valid
    #    handoff (single-beat, multi-beat, and widening vwmacc at m1 and m2).
    mixed_ops = [
        encode_grp_op("add", "vv", 32, 0, epr32, 0, 1, 0, 1, 2),
        # vmv.v.x encodes vs2=0; should not falsely stall or misread while v0 writes.
        encode_grp_op("mv", "vx", 32, 0, epr32, 0, 1, 3, 0, 0, rs1=0x123456789ABCDEF0),
        # Unary Zvbb consumes v3 (just written by mv).
        encode_grp_op("rev8", "vv", 32, 0, epr32, 0, 1, 5, 0, 3),
        encode_grp_op("clz", "vv", 32, 0, epr32, 0, 1, 6, 0, 5),
        # Split i_int_valid vmacc.vv (partial beat, full reg, and LMUL=2).
        encode_vmacc_vv(32, 0, min(3, epr32), 0, 1, 7, 5, 6),
        encode_vmacc_vv(32, 0, epr32, 0, 1, 7, 5, 6),
        encode_vmacc_vv(32, 1, 2 * epr32 - 1, 0, 0, 10, 12, 14),
        # Widening vwmacc.vv: single-beat (<=64b), two-beat (<=128b), and full m1/m2.
        encode_vwmacc_vv(32, 0, min(2, epr32), 0, 1, 16, 5, 6),
        encode_vwmacc_vv(32, 0, min(4, epr32), 0, 1, 16, 5, 6),
        encode_vwmacc_vv(32, 0, epr32, 0, 1, 18, 5, 6),
        encode_vwmacc_vv(32, 1, 2 * epr32, 0, 0, 20, 12, 14),
        encode_grp_op("add", "vv", 32, 0, epr32, 0, 1, 8, 16, 17),
        encode_grp_op("xor", "vv", 32, 0, epr32, 0, 1, 9, 18, 19),
    ]
    await run_burst(dut, model, mixed_ops, "unary_mv_and_int_handoff")
    dut._log.info(f"Directed split-issue suites passed at VLEN={vlen}")


@cocotb.test()
async def test_vec_engine_split_random(dut: Any) -> None:
    """Randomized back-to-back split-issue bursts against the reference model."""
    vlen = len(dut.o_xr_data)
    rng = random.Random(20400 + vlen)
    Clock(dut.i_clk, 2, unit="ns").start()
    model = await reset_and_load(dut, vlen, rng)

    total_ops = 0
    total_overlapped = 0
    total_stalls = 0
    for burst_idx in range(40):
        narrow = (burst_idx % 2) == 0
        burst_len = rng.randint(12, 18)
        ops = [rand_grp_op(rng, vlen, narrow_pool=narrow) for _ in range(burst_len)]
        if burst_idx % 8 == 7:
            epr32 = vlen // 32
            ops.insert(
                burst_len // 2,
                encode_vmacc_vv(
                    32, 0, rng.randint(0, epr32), 0, rng.getrandbits(1), 5, 6, 7
                ),
            )
        ov, st, _ = await run_burst(dut, model, ops, f"rand_burst_{burst_idx}")
        total_ops += len(ops)
        total_overlapped += ov
        total_stalls += st

    assert total_overlapped > total_ops // 2, (
        f"expected frequent back-to-back overlap, got {total_overlapped}/{total_ops}"
    )
    assert total_stalls > 0, "expected RAW/compare stalls in randomized split bursts"
    dut._log.info(
        f"VLEN={vlen}: {total_ops} split-issue ops across 40 bursts matched model "
        f"({total_overlapped} overlapped, {total_stalls} stall cycles)"
    )
