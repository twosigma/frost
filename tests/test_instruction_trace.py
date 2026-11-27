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

"""Binary-bound retirement capture, dependency reconstruction, and fail-closed input."""

import gzip
import importlib
import json
from pathlib import Path
from typing import Any

import pytest

from test_calibration_trace import CORE, _Node, cpu_structs, packed_structs
from test_perf_model import _load

stream_api = _load("instruction_stream.py", "instruction_stream_tests")
recorder = importlib.import_module("cocotb_tests.instruction_trace")


def row(index: int, pc: int, instruction: int = 0x00108093) -> dict[str, Any]:
    """Return an ADDI x1,x1,1 record, with explicit architectural operands."""
    return {
        "id": index,
        "pc": pc,
        "bytes": instruction.to_bytes(4, "little").hex(),
        "length": 4,
        "instruction": instruction,
        "kind": "alu",
        "sources": [1],
        "destination": 1,
        "address": None,
        "memory_bytes": 0,
        "taken": False,
        "next_pc": pc + 4,
        "prediction": None,
    }


def write_stream(path: Path, rows: list[dict[str, Any]], sealed: bool = True) -> None:
    """Write a small independent instruction fixture."""
    records = [
        {
            "schema": "frost-instructions-v1",
            "benchmark": "coremark",
            "rtl_commit": "a" * 40,
            "memory_tier": "bram",
            "run_number": 1,
            "start_pc": 0,
            "stop_pc": 16,
            "artifacts": {"sw.elf_sha256": "b" * 64, "sw.bin_sha256": "c" * 64},
        },
        *rows,
    ]
    if sealed:
        records.append({"end": True, "instructions": len(rows)})
    path.write_text("".join(json.dumps(r) + "\n" for r in records))


def test_dependency_renaming_and_zero_register(tmp_path: Path) -> None:
    """RAW edges use the preceding writer; x0 and WAW are not dependencies."""
    rows = [row(0, 0), row(1, 4), row(2, 8), row(3, 12)]
    rows[1].update(sources=[0], destination=0)
    rows[2].update(sources=[0, 1], destination=1)
    rows[3].update(sources=[1], destination=None)
    path = tmp_path / "i.jsonl"
    write_stream(path, rows)
    ops = stream_api.read_stream(path).instructions
    assert [op.depends_on for op in ops] == [(), (), (0,), (2,)]


@pytest.mark.parametrize(
    "change,reason",
    [
        ({"id": 4}, "consecutive"),
        ({"pc": 3}, "discontinuous"),
        ({"length": 2}, "length"),
        ({"instruction": 0}, "expanded"),
        ({"sources": [True]}, "source register"),
        ({"destination": 32}, "destination"),
        ({"kind": "load"}, "data address"),
        ({"taken": True}, "non-branch"),
        ({"next_pc": 8}, "fall-through"),
        ({"prediction": {}}, "non-branch"),
    ],
)
def test_malformed_instruction_fails(
    tmp_path: Path, change: dict[str, Any], reason: str
) -> None:
    """Invalid evidence cannot silently change the replayed workload."""
    path = tmp_path / "i.jsonl"
    write_stream(path, [{**row(0, 0), **change}])
    with pytest.raises(ValueError, match=reason):
        stream_api.read_stream(path)


def test_truncated_and_aggregate_streams_fail(tmp_path: Path) -> None:
    """An interrupted capture and an aggregate trace both fail closed."""
    path = tmp_path / "i.jsonl"
    write_stream(path, [row(0, 0)], sealed=False)
    with pytest.raises(ValueError, match="footer"):
        stream_api.read_stream(path)
    path.write_text('{"event":"retire","uops":2}\n')
    with pytest.raises(ValueError, match="aggregate"):
        stream_api.read_stream(path)


def test_manifest_binds_binary_window_and_run(tmp_path: Path) -> None:
    """A valid stream cannot be substituted for a different binary or window."""
    path = tmp_path / "i.jsonl"
    write_stream(path, [row(0, 0)])
    stream = stream_api.read_stream(path)
    manifest = {
        "instruction_stream": {"sha256": stream.sha256, "instructions": 1},
        "artifacts": stream.metadata["artifacts"].copy(),
        "git_commit": "a" * 40,
        "benchmark": "coremark",
        "memory_configuration": {"tier": "bram"},
        "run_number": 1,
        "timed_region": {"start_pc": "0x0", "stop_pc": "0x10"},
    }
    assert len(stream_api.read_stream(path, manifest).instructions) == 1
    manifest["artifacts"]["sw.bin_sha256"] = "d" * 64
    with pytest.raises(ValueError, match="binary"):
        stream_api.read_stream(path, manifest)
    manifest["artifacts"] = stream.metadata["artifacts"]
    manifest["timed_region"]["start_pc"] = "0x4"
    with pytest.raises(ValueError, match="window"):
        stream_api.read_stream(path, manifest)


def make_recorder(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Any:
    """Bind packed signal doubles with the same widths as production."""
    layouts = {
        "from_id_to_ex": cpu_structs.ID_TO_EX_FIELDS,
        "decoded_packet": cpu_structs.ID_TO_EX_FIELDS,
        "from_pd_to_id": cpu_structs.PD_TO_ID_FIELDS,
        "rob_alloc_req": cpu_structs.ROB_ALLOC_REQ_FIELDS,
        "rob_commit_comb": cpu_structs.COMMIT_FIELDS,
    }
    widths = {
        f"{CORE}.{name}{suffix}": sum(w for _, w in layout)
        for name, layout in layouts.items()
        for suffix in ("", "_2")
    }
    dut = _Node("", set(), widths)
    # LUI x1,1; ADDI x1,x1,-8; LD x2,0(x1).
    code = b"".join(i.to_bytes(4, "little") for i in (0x10B7, 0xFF808093, 0xB103))
    (tmp_path / "sw.elf").write_bytes(code)
    (tmp_path / "sw.bin").write_bytes(code)
    monkeypatch.setattr(recorder, "elf_segments", lambda _path: [(0, code)])
    return recorder.InstructionTrace(
        dut,
        tmp_path / "i.jsonl.gz",
        tmp_path,
        {
            "benchmark": "coremark",
            "rtl_commit": "a" * 40,
            "memory_tier": "bram",
            "run_number": 1,
            "start_pc": 0,
            "stop_pc": 8,
        },
    )


def drive(capture: Any, **values: int) -> None:
    """Clear old bus pulses before driving the next observation cycle."""
    for name, handle in capture.handles.items():
        handle.value = values.get(name, 0)


def allocate(capture: Any, pc: int, insn: int, tag: int, **extra: int) -> None:
    """Allocate one integer instruction without committing it yet."""
    packet = {
        "program_counter": pc,
        "instruction": insn,
        "insn_bits": insn,
        "is_real": 1,
        "has_int_dest": 1,
        **extra,
    }
    drive(
        capture,
        from_pd_to_id=packed_structs.pack_struct(cpu_structs.PD_TO_ID_FIELDS, packet),
    )
    capture.sample(False)
    drive(capture, **bundle_signals([packet], [tag]))
    capture.sample(False)


def bundle_signals(packets: list[dict[str, int]], tags: list[int]) -> dict[str, int]:
    """Accept and dispatch a bundle through the empty queue bypass."""
    values = {"gen_decoded_queue.u_queue.accept": 1}
    for slot, (packet, tag) in enumerate(zip(packets, tags, strict=True)):
        suffix = "_2" if slot else ""
        encoded = packed_structs.pack_struct(cpu_structs.ID_TO_EX_FIELDS, packet)
        values.update(
            {
                f"decoded_packet{suffix}": encoded,
                f"from_id_to_ex{suffix}": encoded,
                f"rob_alloc_req{suffix}": packed_structs.pack_struct(
                    cpu_structs.ROB_ALLOC_REQ_FIELDS,
                    {"alloc_valid": 1, "pc": packet["program_counter"]},
                ),
                f"rob_alloc_resp{suffix}": (1 << (cpu_structs.ROB_TAG_WIDTH + 1))
                | tag << 1,
            }
        )
    return values


def commit(pc: int, tag: int, reg: int, value: int) -> int:
    """Build a retiring integer writeback."""
    return packed_structs.pack_struct(
        cpu_structs.COMMIT_FIELDS,
        {
            "valid": 1,
            "pc": pc,
            "tag": tag,
            "dest_valid": 1,
            "dest_reg": reg,
            "value": value,
        },
    )


def test_retirement_resolves_signed_addresses_and_same_cycle_writes(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Slot 2 sees slot 1's architectural write; warm-up establishes its base."""
    cap = make_recorder(tmp_path, monkeypatch)
    allocate(cap, 0, 0x10B7, 0)
    drive(cap, rob_commit_comb=commit(0, 0, 1, 4096))
    cap.sample(False)
    allocate(cap, 4, 0xFF808093, 1, uses_int_rs1=1)
    allocate(cap, 8, 0xB103, 2, uses_int_rs1=1, is_load_instruction=1)
    drive(
        cap,
        rob_commit_comb=commit(4, 1, 1, 4088),
        rob_commit_comb_2=commit(8, 2, 2, 42),
    )
    cap.sample(True)
    cap.finish(2)
    stream = stream_api.read_stream(tmp_path / "i.jsonl.gz")
    assert stream.instructions[1].address == 4088
    assert stream.instructions[1].depends_on == (0,)
    assert cap.registers[2] == 42
    with gzip.open(cap.path, "rt") as file:
        assert "cycle" not in file.read()


def test_capture_rejects_binary_mismatch_and_missing_allocation(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A corrupt packet or wrong tag must not manufacture instruction evidence."""
    cap = make_recorder(tmp_path, monkeypatch)
    allocate(cap, 0, 0x13, 0)
    drive(cap, rob_commit_comb=commit(0, 0, 1, 4096))
    with pytest.raises(AssertionError, match="binary mismatch"):
        cap.sample(True)
    cap.file.close()
    drive(cap, rob_commit_comb=commit(4, 7, 1, 4096))
    with pytest.raises(AssertionError, match="allocation"):
        cap.sample(False)


@pytest.mark.parametrize(
    "slot,tier", [(0, "pd_direction"), (1, "pd_backing"), (1, "pd_ittage")]
)
def test_prediction_annotations_follow_allocation_and_flush(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    slot: int,
    tier: str,
) -> None:
    """PD events belong to their dynamic allocation and are cleared on recovery."""
    cap = make_recorder(tmp_path, monkeypatch)
    suffix = "_2" if slot else ""
    values = {
        "pd_redirect": 1,
        "pd_redirect_slot2": slot,
        "pd_redirect_taken": 1,
        "pd_redirect_target": 64,
        f"from_pd_to_id{suffix}": packed_structs.pack_struct(
            cpu_structs.PD_TO_ID_FIELDS, {"program_counter": 4}
        ),
    }
    if tier != "pd_direction":
        name = "backing" if tier == "pd_backing" else "itt"
        values[f"pd_stage_inst.pd_{name}_redirect{suffix}_r"] = 1
    drive(cap, **values)
    cap.sample(False)
    packet = {
        "program_counter": 4,
        "is_real": 1,
        "is_branch_or_jump": 1,
        "btb_predicted_taken": 1,
        "btb_predicted_target": 64,
    }
    packets = [{"program_counter": 0, "is_real": 1}, packet] if slot else [packet]
    drive(cap, **bundle_signals(packets, [1, 2] if slot else [2]))
    cap.sample(False)
    assert cap.allocated[2]["prediction"]["pd_tier"] == tier
    assert not cap.allocated[2]["prediction"]["f0_taken"]
    drive(cap, **values)
    cap.sample(False)
    drive(cap, flush_pipeline=1)
    cap.sample(False)
    assert not cap.decoded
    assert not cap.producer
    # A surviving older branch retains its tag annotation through a partial flush.
    assert cap.allocated[2]["prediction"]["pd_tier"] == tier
    allocate(cap, 4, 0x0400006F, 2, is_branch_or_jump=1)
    assert cap.allocated[2]["prediction"]["pd_tier"] == "none"


def test_same_pc_iterations_keep_prediction_lineage(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A younger PD override cannot annotate an older same-PC allocation."""
    cap = make_recorder(tmp_path, monkeypatch)
    packet = {"program_counter": 4, "is_real": 1, "is_branch_or_jump": 1}
    pd = packed_structs.pack_struct(cpu_structs.PD_TO_ID_FIELDS, packet)
    drive(cap, from_pd_to_id=pd)
    cap.sample(False)
    # Queue the older iteration while ID stalls: the producer must be held.
    values = bundle_signals([packet], [1])
    drive(
        cap,
        **{k: v for k, v in values.items() if not k.startswith("rob_alloc")},
        dbg_pipeline_stall=1,
    )
    cap.sample(False)
    for _ in range(3):
        drive(cap, dbg_pipeline_stall=1)
        cap.sample(False)
    # Allocate the old queue head as the younger override enters ID.
    drive(
        cap,
        **{k: v for k, v in values.items() if k != "gen_decoded_queue.u_queue.accept"},
        from_pd_to_id=pd,
        pd_redirect=1,
        pd_redirect_taken=1,
        pd_redirect_target=64,
    )
    cap.sample(False)
    assert cap.allocated[1]["prediction"]["pd_tier"] == "none"
    younger = {**packet, "btb_predicted_taken": 1, "btb_predicted_target": 64}
    drive(cap, **bundle_signals([younger], [2]))
    cap.sample(False)
    assert cap.allocated[2]["prediction"]["pd_tier"] == "pd_direction"
    assert not cap.decoded


def test_annotation_mismatch_fails_closed(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A missing override cannot silently turn into a different tier."""
    cap = make_recorder(tmp_path, monkeypatch)
    drive(
        cap,
        from_pd_to_id=packed_structs.pack_struct(
            cpu_structs.PD_TO_ID_FIELDS, {"program_counter": 4}
        ),
    )
    cap.sample(False)
    drive(
        cap,
        **bundle_signals(
            [{"program_counter": 4, "is_real": 1, "btb_predicted_taken": 1}], [0]
        ),
    )
    with pytest.raises(AssertionError, match="lineage mismatch"):
        cap.sample(False)
