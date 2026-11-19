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

"""Fast regression tests for Python-side verification helpers."""

import importlib
import asyncio
import logging
import re
import sys
from pathlib import Path
from types import SimpleNamespace
from typing import Any

import pytest

VERIF_DIR = Path(__file__).resolve().parents[1] / "verif"
if str(VERIF_DIR) not in sys.path:
    sys.path.insert(0, str(VERIF_DIR))

alu_model = importlib.import_module("models.alu_model")
packed_structs = importlib.import_module("utils.packed_structs")
cpu_structs = importlib.import_module("cocotb_tests.cpu_structs")
compressed_encode = importlib.import_module("encoders.compressed_encode")
lq_model = importlib.import_module("cocotb_tests.tomasulo.load_queue.lq_model")
rat_interface = importlib.import_module(
    "cocotb_tests.tomasulo.register_alias_table.rat_interface"
)
tomasulo_interface = importlib.import_module(
    "cocotb_tests.tomasulo.tomasulo_wrapper.tomasulo_interface"
)
rob_interface = importlib.import_module(
    "cocotb_tests.tomasulo.reorder_buffer.reorder_buffer_interface"
)
config = importlib.import_module("config")


@pytest.mark.parametrize("top", ("frost", "soc_top"))
def test_simulation_assertions_require_system_control(
    monkeypatch: pytest.MonkeyPatch, top: str
) -> None:
    """A missing control fails the system bench; standalone checks stay active."""
    control = importlib.import_module("cocotb_tests.sim_assertions")
    monkeypatch.setattr(
        control.cocotb, "top", SimpleNamespace(_name=top), raising=False
    )
    monkeypatch.setattr(control.ctypes, "CDLL", lambda _: SimpleNamespace())
    monkeypatch.delenv("FROST_STARTUP_BASELINE", raising=False)
    if top == "frost":
        with pytest.raises(AttributeError, match="frost_sim_assertions_enable"):
            control.enable_simulation_assertions()
    else:
        control.enable_simulation_assertions()


@pytest.mark.parametrize("nics", (0, 1, 2))
@pytest.mark.parametrize("reset_asserted", (False, True))
@pytest.mark.parametrize("direct_platform", (False, True))
@pytest.mark.parametrize("reset_arrives", (False, True))
def test_program_start_clears_checker_history_before_driven_reset(
    monkeypatch: pytest.MonkeyPatch,
    nics: int,
    reset_asserted: bool,
    direct_platform: bool,
    reset_arrives: bool,
) -> None:
    """Discard initial-edge history, then require a driven reset before checking."""
    real_program = importlib.import_module("cocotb_tests.test_real_program")

    class Signal:
        def __init__(self, value: int, width: int = 1) -> None:
            self.value = value
            self.width = width

        def __len__(self) -> int:
            return self.width

    monkeypatch.setattr(real_program, "Immediate", int)
    clocks = {
        name: Signal(1)
        for name in (
            "i_clk",
            "i_cpu_clk",
            "i_clk_div4",
            "i_jtag_tck",
            "i_nic_tx_clk",
            "i_nic_rx_clk",
            "i_nic_1g_tx_clk",
            "i_nic_1g_rx_clk",
        )
    }
    fronts = [SimpleNamespace(reset_seen_q=Signal(0)) for _ in range(nics)]
    soc = SimpleNamespace(
        reset_request_soc=Signal(int(reset_asserted)),
        rst_core=Signal(0),
        production_state=Signal(0xA5),
    )
    if direct_platform:
        soc.rst_core_next = soc.reset_request_soc
        del soc.reset_request_soc
    if nics:
        soc.gen_cached_tier = SimpleNamespace(nic=SimpleNamespace(u_front=fronts[0]))
        if nics == 2:
            soc.gen_cached_tier.gen_nic_1g = SimpleNamespace(
                nic_1g=SimpleNamespace(u_front=fronts[1])
            )
    dut = SimpleNamespace(
        **clocks,
        i_rst_n=Signal(1),
        i_instr_mem_en=Signal(1),
        i_power_on_rst=Signal(1),
        reset_synchronizer_shift_register=Signal(0, 3),
        reset_synchronized=Signal(0),
        reset_div4_synchronizer_shift_register=Signal(0, 3),
        cpu_and_memory_subsystem=soc if direct_platform else SimpleNamespace(soc=soc),
    )
    settled = False

    async def initial_evaluation(delay: int, *, unit: str) -> None:
        nonlocal settled
        assert (delay, unit) == (1, "ps")
        assert all(clock.value == 0 for clock in clocks.values())
        assert dut.i_rst_n.value == dut.i_instr_mem_en.value == 0
        assert dut.i_power_on_rst.value == 0
        assert dut.reset_synchronized.value == 1
        for front in fronts:
            front.reset_seen_q.value = 1
        settled = True

    monkeypatch.setattr(real_program, "Timer", initial_evaluation)
    if nics and not reset_asserted:
        with pytest.raises(AssertionError, match="NIC startup requires system reset"):
            asyncio.run(real_program.prepare_program_start(dut))
    else:
        asyncio.run(real_program.prepare_program_start(dut))
    assert all(front.reset_seen_q.value == 0 for front in fronts)
    assert settled
    assert soc.rst_core.value == 0
    assert soc.production_state.value == 0xA5
    if nics and not reset_asserted:
        return
    dut.i_power_on_rst.value = 1
    events = ["settled", "cleared"]

    async def driven_reset(clock: Any) -> None:
        assert clock is dut.i_clk
        assert events == ["settled", "cleared"]
        assert all(front.reset_seen_q.value == 0 for front in fronts)
        assert all(signal.value == 0 for signal in clocks.values())
        events.append("reset")
        for front in fronts:
            front.reset_seen_q.value = int(reset_arrives)
        dut.i_power_on_rst.value = 0

    monkeypatch.setattr(real_program, "RisingEdge", driven_reset)
    if nics and not reset_arrives:
        with pytest.raises(
            AssertionError, match="NIC response checker did not observe reset"
        ):
            asyncio.run(real_program.wait_for_power_on_reset(dut))
    else:
        asyncio.run(real_program.wait_for_power_on_reset(dut))
    events.append("checked")
    assert events == ["settled", "cleared", "reset", "checked"]


@pytest.mark.parametrize("direct_platform", (False, True))
@pytest.mark.parametrize(
    "nics, missing", [(0, None), (1, None), (1, 0), (2, None), (2, 0), (2, 1)]
)
def test_cold_reset_requires_each_nic_checker_history(
    monkeypatch: pytest.MonkeyPatch,
    direct_platform: bool,
    nics: int,
    missing: int | None,
) -> None:
    """Cold reset must reach each NIC on both system hierarchy layouts."""
    program = importlib.import_module("cocotb_tests.test_real_program")
    history = [SimpleNamespace(value=0) for _ in range(nics)]
    soc = SimpleNamespace()
    if nics:
        soc.gen_cached_tier = SimpleNamespace(
            nic=SimpleNamespace(u_front=SimpleNamespace(reset_seen_q=history[0]))
        )
        if nics == 2:
            soc.gen_cached_tier.gen_nic_1g = SimpleNamespace(
                nic_1g=SimpleNamespace(u_front=SimpleNamespace(reset_seen_q=history[1]))
            )
    dut = SimpleNamespace(
        i_power_on_rst=SimpleNamespace(value=1),
        i_clk=object(),
        cpu_and_memory_subsystem=soc if direct_platform else SimpleNamespace(soc=soc),
    )

    async def reset_edge(clock: Any) -> None:
        assert clock is dut.i_clk
        dut.i_power_on_rst.value = 0
        for index, seen in enumerate(history):
            seen.value = int(index != missing)

    monkeypatch.setattr(program, "RisingEdge", reset_edge)
    if missing is None:
        asyncio.run(program.wait_for_power_on_reset(dut))
    else:
        with pytest.raises(
            AssertionError, match="NIC response checker did not observe reset"
        ):
            asyncio.run(program.wait_for_power_on_reset(dut))
        assert history[missing].value == 0


def test_cold_reset_postcondition_allows_standalone_top() -> None:
    """A standalone boundary bench has no system NIC history to check."""
    program = importlib.import_module("cocotb_tests.test_real_program")
    asyncio.run(
        program.wait_for_power_on_reset(
            SimpleNamespace(i_power_on_rst=SimpleNamespace(value=0))
        )
    )


def test_pack_struct_keeps_declaration_order_and_wide_values() -> None:
    """The first declared field is the MSB, including on wide RV64 packets."""
    fields = [("op", 3), ("valid", 1), ("value", 64), ("tail", 4)]
    values = {"op": 5, "valid": True, "value": 0xFEDC_BA98_7654_3210, "tail": 10}

    assert packed_structs.pack_struct(fields, values) == 0xB_FEDC_BA98_7654_3210_A
    assert packed_structs.pack_struct(fields, {"tail": 5, "unused": 123}) == 5


def test_pack_struct_masks_signed_and_oversized_fields() -> None:
    """Each field truncates independently; one-bit integers use their low bit."""
    fields = [("signed", 4), ("flag", 1), ("byte", 8)]

    assert (
        packed_structs.pack_struct(fields, {"signed": -2, "flag": 2, "byte": 0x1FF})
        == 0b1110_0_11111111
    )
    assert packed_structs.pack_struct(fields, {"signed": 16, "flag": -1}) == 0x100


def test_unpack_struct_keeps_bool_types_and_ignores_high_bits() -> None:
    """Unpacking preserves every value bit and returns only one-bit fields as bool."""
    fields = [("op", 3), ("valid", 1), ("value", 64), ("tail", 4)]
    unpacked = packed_structs.unpack_struct(fields, 0xFB_FEDC_BA98_7654_3210_A)

    assert unpacked == {
        "op": 5,
        "valid": True,
        "value": 0xFEDC_BA98_7654_3210,
        "tail": 10,
    }
    assert unpacked["valid"] is True
    assert type(unpacked["op"]) is int
    assert packed_structs.unpack_struct(fields, 0)["valid"] is False


def test_empty_struct_has_no_bits() -> None:
    """Empty schemas neither consume values nor expose bits from the input."""
    assert packed_structs.pack_struct([], {"unused": 1}) == 0
    assert packed_structs.unpack_struct([], -1) == {}


def test_rob_allocation_schema_matches_manual_driver() -> None:
    """Check every allocation field against the independently written ROB packer."""
    assert sum(width for _, width in cpu_structs.ROB_ALLOC_REQ_FIELDS) == (
        rob_interface.ALLOC_REQ_WIDTH
    )
    for name, default in vars(rob_interface.AllocationRequest()).items():
        for pattern in (1, -1, 0x12345_FEDC_BA98_7654_3210):
            request = rob_interface.AllocationRequest()
            setattr(
                request, name, bool(pattern) if isinstance(default, bool) else pattern
            )
            expected = packed_structs.pack_struct(
                cpu_structs.ROB_ALLOC_REQ_FIELDS,
                {"alloc_valid": True, **vars(request)},
            )
            assert rob_interface.pack_alloc_request(request) == expected, name


@pytest.mark.parametrize(
    ("operation", "old_value", "rs2_value", "expected"),
    (
        ("amoswap", 0xAAAA_AAAA_0000_0001, 0xBBBB_BBBB_8765_4321, 0x8765_4321),
        ("amoadd", 0xAAAA_AAAA_FFFF_FFFF, 0xBBBB_BBBB_0000_0001, 0),
        ("amoxor", 0xAAAA_AAAA_FFFF_0000, 0xBBBB_BBBB_00FF_00FF, 0xFF00_00FF),
        ("amoand", 0xAAAA_AAAA_FFFF_0000, 0xBBBB_BBBB_00FF_00FF, 0x00FF_0000),
        ("amoor", 0xAAAA_AAAA_FFFF_0000, 0xBBBB_BBBB_00FF_00FF, 0xFFFF_00FF),
        ("amomin", 0xAAAA_AAAA_FFFF_FFFF, 0xBBBB_BBBB_0000_0001, 0xFFFF_FFFF),
        ("amomax", 0xAAAA_AAAA_FFFF_FFFF, 0xBBBB_BBBB_0000_0001, 1),
        ("amominu", 0xAAAA_AAAA_0000_0001, 0xBBBB_BBBB_0000_0002, 1),
        ("amomaxu", 0xAAAA_AAAA_0000_0001, 0xBBBB_BBBB_0000_0002, 2),
    ),
)
def test_amo_word_evaluators_return_a_word(
    operation: str, old_value: int, rs2_value: int, expected: int
) -> None:
    """Every .W evaluator returns only the low 32-bit memory result."""
    evaluator = getattr(alu_model, operation)
    assert evaluator(old_value, rs2_value) == expected


@pytest.mark.parametrize(("rd", "nzimm"), ((0, 1), (1, 0)))
def test_c_addi_encoder_rejects_hint_encodings(rd: int, nzimm: int) -> None:
    """C.ADDI excludes the x0 and zero-immediate HINT encodings."""
    with pytest.raises(AssertionError):
        compressed_encode.enc_c_addi(rd, nzimm)


def test_c_nop_has_a_dedicated_encoder() -> None:
    """C.NOP (C.ADDI x0, 0) has its own encoder."""
    assert compressed_encode.enc_c_nop() == 0x0001


def test_lq_model_gives_rob_head_lr_priority_over_physical_order() -> None:
    """The model's head shortcut includes LR, matching the RTL selector."""
    model = lq_model.LQModel()
    assert model.alloc(
        rob_tag=5, is_fp=False, size=lq_model.MEM_SIZE_WORD, sign_ext=False
    )
    assert model.alloc(
        rob_tag=1,
        is_fp=False,
        size=lq_model.MEM_SIZE_WORD,
        sign_ext=False,
        is_lr=True,
    )
    model.addr_update(rob_tag=5, address=0x5000)
    model.addr_update(rob_tag=1, address=0x1000)

    request = model.issue_to_memory(
        all_older_known=True,
        sq_forward=lq_model.SQForwardResult(),
        rob_head_tag=1,
    )

    assert request == {"addr": 0x1000, "size": lq_model.MEM_SIZE_WORD}


def test_lq_model_keeps_the_whole_doubleword_for_lr_d() -> None:
    """LR.D completes with the whole beat, like LD, and sets the reservation."""
    model = lq_model.LQModel()
    assert model.alloc(
        rob_tag=1,
        is_fp=False,
        size=lq_model.MEM_SIZE_DOUBLE,
        sign_ext=False,
        is_lr=True,
    )
    model.addr_update(rob_tag=1, address=0x8000_7800)
    request = model.issue_to_memory(
        all_older_known=True,
        sq_forward=lq_model.SQForwardResult(),
        rob_head_tag=1,
    )
    assert request == {"addr": 0x8000_7800, "size": lq_model.MEM_SIZE_DOUBLE}

    model.mem_response(0xABCD_EF01_2345_6789)

    result = model.get_fu_complete()
    assert result.valid and result.tag == 1
    assert result.value == 0xABCD_EF01_2345_6789
    assert model.reservation_valid and model.reservation_addr == 0x8000_7800


class _Signal:
    """Minimal writable cocotb-signal stand-in."""

    def __init__(self) -> None:
        self.value = 0


class _RatLookupDut:
    """Signal subset used by the RAT source-lookup setters."""

    def __init__(self) -> None:
        self.i_int_src1_addr = _Signal()
        self.i_int_src2_addr = _Signal()
        self.i_int_src1_addr_2 = _Signal()
        self.i_int_src2_addr_2 = _Signal()
        self.i_int_regfile_data1 = _Signal()
        self.i_int_regfile_data2 = _Signal()
        self.i_int_regfile_data1_2 = _Signal()
        self.i_int_regfile_data2_2 = _Signal()


@pytest.mark.parametrize(
    "interface_type",
    (rat_interface.RATInterface, tomasulo_interface.TomasuloInterface),
)
def test_rat_interfaces_preserve_rv64_regfile_values(interface_type: Any) -> None:
    """Both direct and integration RAT drivers must retain bits 63:32."""
    dut = _RatLookupDut()
    interface = interface_type(dut)
    values = (
        0x0123_4567_89AB_CDEF,
        0xFEDC_BA98_7654_3210,
        0x1357_9BDF_2468_ACE0,
        0xF0E1_D2C3_B4A5_9687,
    )

    interface.set_int_src1(1, values[0])
    interface.set_int_src2(2, values[1])
    interface.set_int_src1_2(3, values[2])
    interface.set_int_src2_2(4, values[3])

    assert dut.i_int_regfile_data1.value == values[0]
    assert dut.i_int_regfile_data2.value == values[1]
    assert dut.i_int_regfile_data1_2.value == values[2]
    assert dut.i_int_regfile_data2_2.value == values[3]


class _VectorValue:
    """Resolvable stand-in for a cocotb vector value."""

    is_resolvable = True

    def __init__(self, value: int) -> None:
        self._value = value

    def __int__(self) -> int:
        return self._value


class _VectorHandle:
    """Stand-in for a VPI handle of a packed struct: a width and a value."""

    def __init__(self, width: int, value: int) -> None:
        self._width = width
        self.value = _VectorValue(value)

    def __len__(self) -> int:
        return self._width


def test_fefuzz_requires_each_activity_in_the_generated_code(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Stalls, losing redirects and UART code cannot satisfy a seed's floors."""
    bench = importlib.import_module("cocotb_tests.test_real_program")
    monkeypatch.setattr(
        bench.subprocess, "check_output", lambda *a, **kw: "100 20 T fe_run\n"
    )
    monkeypatch.setattr(bench.cocotb, "log", logging.getLogger(__name__), raising=False)
    monkeypatch.setenv("FE_SEED", "4")
    layout = cpu_structs.IF_TO_PD_FIELDS

    def packet(pc: int) -> _VectorHandle:
        bits = packed_structs.pack_struct(layout, {"program_counter": pc})
        return _VectorHandle(sum(width for _, width in layout), bits)

    pd = SimpleNamespace(
        i_from_if_to_pd=packet(0x100),
        i_from_if_to_pd_2=packet(0x120),
        i_itt_hit=_Signal(),
        o_itt_eligible=_Signal(),
        o_pd_redirect=_Signal(),
        pd_chk_pc=_Signal(),
        pd_itt_target_select_r=_Signal(),
        o_pd_backing_refresh=_Signal(),
        pd_dir_redirect_1_r=_Signal(),
        pd_dir_redirect_2_r=_Signal(),
    )
    pc = SimpleNamespace(o_pc_update_en=_Signal(), o_npc_sel=_Signal())
    cpu = SimpleNamespace(
        pd_stage_inst=pd,
        if_stage_inst=SimpleNamespace(pc_controller_inst=pc),
        i_rst=_Signal(),
        tage_pd_accept=_Signal(),
        early_mispredict_active=_Signal(),
        early_mispredict_pc=_Signal(),
    )
    dut = SimpleNamespace(
        cpu_and_memory_subsystem=SimpleNamespace(
            cpu=SimpleNamespace(hart=SimpleNamespace(cpu_inst=cpu))
        )
    )
    activity = bench.FefuzzActivity(dut)
    pd.i_itt_hit.value = 3
    pd.o_pd_redirect.value = 1
    pd.pd_chk_pc.value = 0x110
    pd.pd_dir_redirect_1_r.value = 1
    cpu.early_mispredict_active.value = 1
    cpu.early_mispredict_pc.value = 0x120
    pc.o_npc_sel.value = 1 << 4
    activity.sample()  # Held PC and unaccepted ITT lookup.
    pc.o_pc_update_en.value = 1
    pc.o_npc_sel.value = 1 << 3
    activity.sample()  # An older redirect won.
    assert not any(activity.counts.values())

    cpu.tage_pd_accept.value = 1
    pd.o_pd_redirect.value = 0
    pd.o_itt_eligible.value = 2
    activity.sample()  # The in-range slot has a raw hit but no eligible JALR.
    assert not any(activity.counts.values())
    pd.o_itt_eligible.value = 3
    activity.sample()  # Only the first of two qualified hits is in range.
    cpu.tage_pd_accept.value = 0
    pd.o_pd_redirect.value = 1
    pc.o_npc_sel.value = 1 << 4
    cpu.early_mispredict_pc.value = 0x108
    activity.sample()
    cpu.early_mispredict_active.value = 0
    pd.pd_dir_redirect_1_r.value = 0
    pd.pd_dir_redirect_2_r.value = 1
    activity.sample()
    pd.pd_dir_redirect_2_r.value = 0
    pd.o_pd_backing_refresh.value = 1
    activity.sample()
    pd.pd_itt_target_select_r.value = 1
    activity.sample()  # A same-slot indirect override wins over the backing hit.
    assert list(activity.counts.values()) == [1] * 6

    output = "fefuzz seed 4 rounds 1 sig 1234 want 1234\n<<PASS>>\n"
    activity.verify(1, output)
    with pytest.raises(AssertionError, match="requested fefuzz seed 4"):
        activity.verify(1, output.replace("seed 4", "seed 1"))
    for name in activity.counts:
        activity.counts[name] = 0
        with pytest.raises(AssertionError, match=rf"(?m)missing {name}$"):
            activity.verify(2, output)
        activity.counts[name] = 1


def test_packed_struct_reads_fields_through_the_whole_vector() -> None:
    """Fields come out of the packed value at their cpu_structs positions."""
    real_program = importlib.import_module("cocotb_tests.test_real_program")
    layout = cpu_structs.ID_TO_EX_FIELDS
    width = sum(field_width for _, field_width in layout)
    packed = packed_structs.pack_struct(
        layout,
        {
            "program_counter": 0x8000_0000_0000_0B8C,
            "instruction": 0x00A5_8593,
            "is_real": 1,
        },
    )
    struct = real_program._PackedStruct(_VectorHandle(width, packed), layout, "slot2")

    value = struct.read()
    assert value == packed
    assert struct.field(value, "program_counter") == 0x8000_0000_0000_0B8C
    assert struct.field(value, "instruction") == 0x00A5_8593
    assert struct.field(value, "is_real") == 1
    assert struct.field(value, "is_compressed") == 0


def test_packed_struct_rejects_a_layout_of_another_width() -> None:
    """A layout that no longer matches the RTL struct fails at setup."""
    real_program = importlib.import_module("cocotb_tests.test_real_program")
    layout = cpu_structs.COMMIT_FIELDS
    width = sum(field_width for _, field_width in layout)

    with pytest.raises(AssertionError, match="bits wide"):
        real_program._PackedStruct(_VectorHandle(width + 1, 0), layout, "commit")


def test_required_signals_name_every_missing_handle() -> None:
    """An opt-in check fails at setup and names the handles it could not find."""
    real_program = importlib.import_module("cocotb_tests.test_real_program")

    real_program._require_signals("CHECK", {"present": object()})
    with pytest.raises(AssertionError, match="CHECK needs .*: a, b$"):
        real_program._require_signals(
            "CHECK", {"b": None, "present": object(), "a": None}
        )


def test_signal_reads_resolve_like_cocotb() -> None:
    """A value reads as an int exactly when cocotb calls it resolvable."""
    real_program = importlib.import_module("cocotb_tests.test_real_program")
    from cocotb.types import Logic, LogicArray

    for text in ("0", "1", "0110", "LH10", "lh01", "1" * 64, "X", "10Z1", "U0", "W1"):
        value = LogicArray(text)
        expected = int(value) if value.is_resolvable else None
        assert real_program._resolved_int(value) == expected, text
    for text in "01LHXZUW-":
        bit = Logic(text)
        expected = int(bit) if bit.is_resolvable else None
        assert real_program._resolved_int(bit) == expected, text


def test_low_bram_words_take_the_upper_half_of_odd_words() -> None:
    """A word whose address has bit 2 set is the upper half of its dword row."""
    real_program = importlib.import_module("cocotb_tests.test_real_program")
    rows = [_VectorHandle(64, ((2 * n + 1) << 32) | (2 * n)) for n in range(4)]
    dut = SimpleNamespace(
        cpu_and_memory_subsystem=SimpleNamespace(
            soc=SimpleNamespace(data_memory=SimpleNamespace(memory=rows))
        )
    )

    assert real_program.read_low_bram_words(dut, 4, 5) == [1, 2, 3, 4, 5]


def test_tomasulo_rs_mem_dispatch_requires_explicit_size_and_load_sign() -> None:
    """Folded RS_MEM operations reject omitted mem_size or LOAD mem_signed."""
    iface = tomasulo_interface.TomasuloInterface(SimpleNamespace())
    ops = tomasulo_interface._INSTR_OPS

    for name in (
        "LOAD",
        "STORE",
        "LOAD_FP",
        "STORE_FP",
        "LR",
        "SC",
        "AMOSWAP",
        "AMOADD",
    ):
        with pytest.raises(ValueError, match="mem_size"):
            iface._rs_dispatch_kwargs(
                tomasulo_interface.RS_MEM, True, {"op": ops[name]}
            )

    with pytest.raises(ValueError, match="mem_signed"):
        iface._rs_dispatch_kwargs(
            tomasulo_interface.RS_MEM, True, {"op": ops["LOAD"], "mem_size": 2}
        )

    load_pkt = iface._rs_dispatch_kwargs(
        tomasulo_interface.RS_MEM,
        True,
        {"op": ops["LOAD"], "mem_size": 1, "mem_signed": True},
    )
    assert load_pkt["mem_size"] == 1
    assert load_pkt["mem_signed"] is True

    lr_pkt = iface._rs_dispatch_kwargs(
        tomasulo_interface.RS_MEM, True, {"op": ops["LR"], "mem_size": 2}
    )
    assert lr_pkt["mem_size"] == 2
    assert lr_pkt["mem_signed"] is True


def _parse_riscv_pkg_packed_struct(struct_name: str) -> list[tuple[str, int]]:
    """Extract (field_name, bit_width) pairs in declaration order from riscv_pkg.sv."""
    pkg_path = (
        Path(__file__).resolve().parents[1] / "hw/rtl/cpu_and_mem/cpu/riscv_pkg.sv"
    )
    text = re.sub(r"//.*", "", pkg_path.read_text(encoding="utf-8"))
    params: dict[str, int] = {}
    for m in re.finditer(r"localparam\s+int\s+unsigned\s+(\w+)\s*=\s*([^;]+);", text):
        expr = m.group(2).strip()
        if re.fullmatch(r"[0-9A-Za-z_+\-*/ ()]+", expr):
            try:
                params[m.group(1)] = int(eval(expr, {"__builtins__": {}}, params))
            except Exception:
                pass
    enum_widths = {
        m.group(3): int(m.group(1)) - int(m.group(2)) + 1
        for m in re.finditer(
            r"typedef\s+enum\s+logic\s*\[(\d+):(\d+)\]\s*\{[^}]*\}\s*(\w+)\s*;",
            text,
        )
    }
    block = re.search(
        rf"typedef\s+struct\s+packed\s*\{{([^}}]*)\}}\s*{re.escape(struct_name)}\s*;",
        text,
    )
    assert block is not None, f"{struct_name} not found in riscv_pkg.sv"
    fields: list[tuple[str, int]] = []
    for raw_member in block.group(1).split(";"):
        member = raw_member.strip()
        if not member:
            continue
        vec = re.fullmatch(r"logic\s*\[([^:\]]+):([^:\]]+)\]\s*(\w+)", member)
        if vec:
            hi = int(eval(vec.group(1), {"__builtins__": {}}, params))
            lo = int(eval(vec.group(2), {"__builtins__": {}}, params))
            fields.append((vec.group(3), hi - lo + 1))
            continue
        scalar = re.fullmatch(r"(\w+)\s+(\w+)", member)
        assert scalar is not None, f"unparsed struct member: {member}"
        typ, name = scalar.groups()
        width = 1 if typ == "logic" else enum_widths[typ]
        fields.append((name, width))
    return fields


def test_assert_port_width_and_mmu_schemas_match_riscv_pkg() -> None:
    """PTW_RESP_FIELDS and TLB_FLUSH_FIELDS match riscv_pkg.sv and enforce port widths."""
    for schema, sv_name in (
        (cpu_structs.PTW_RESP_FIELDS, "ptw_resp_t"),
        (cpu_structs.TLB_FLUSH_FIELDS, "tlb_flush_t"),
    ):
        assert schema == _parse_riscv_pkg_packed_struct(sv_name)
        width = packed_structs.struct_width(schema)
        packed_structs.assert_port_width(_VectorHandle(width, 0), schema)
        for bad_width in (width - 1, width + 1):
            with pytest.raises(AssertionError, match="schema width"):
                packed_structs.assert_port_width(_VectorHandle(bad_width, 0), schema)
