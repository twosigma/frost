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

"""Serve the simulated frost SoC to TestRIG as an RVFI-DII implementation.

The test listens on 127.0.0.1:FROST_RVFI_DII_PORT and accepts one
verification engine (QuickCheckVEngine). For each instruction trace it
receives, it resets the SoC, loads FROST's reset preamble and the trace into
hw/sim/frost_rvfi_dii.sv, runs until every instruction has retired or
trapped, and answers with one RVFI record per instruction and a halt token.
The simulator waits while the engine thinks, so simulated time only covers
the tests. The run ends when the engine closes the connection.

tests/test_testrig.py starts this test, the Sail model, and the engine. Build
it with the rvfi_dii entry of tests/test_run_cocotb.py, which defines
FROST_RVFI_DII.
"""

import os
import socket
from pathlib import Path
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge

from cocotb_tests.test_real_program import (
    CLK_PERIOD_NS,
    RESET_CYCLES,
    generate_divided_clock,
    hold_nic_without_mac_clocks,
    start_nic_mac_clocks,
)
from testrig.preamble import reset_preamble
from testrig.rvfi_dii import (
    CMD_END_OF_TRACE,
    CMD_INSTRUCTION,
    CMD_SET_VERSION,
    DII_PACKET_BYTES,
    DiiPacket,
    PacketReader,
    RvfiRecord,
    version_ack,
    version_query_response,
)

# frost_rvfi_dii's capacities (MaxInsns, MaxEvents).
MAX_STREAM_WORDS = 8192
MAX_EVENTS = MAX_STREAM_WORDS + 16
# Log every record, the preamble's included.
DEBUG = os.environ.get("FROST_RVFI_DII_DEBUG", "0") == "1"
# Cycles without a retirement after which a test counts as hung.
HANG_CYCLES = int(os.environ.get("FROST_RVFI_DII_HANG_CYCLES", "20000"))

# frost_rvfi_dii's error_flags bits.
HARNESS_ERRORS = {
    0: "interrupt taken",
    1: "record overflow",
    2: "store write without a pending store",
    3: "CSR write-back without a pending CSR",
    4: "AMO retired without a write",
    5: "fetch redirect from a prediction arm",
    6: "retirement in an early-recovery cycle",
    7: "two control events in one cycle",
    8: "misprediction redirect not loaded into the fetch PC",
    9: "PD redirect from a PC outside the layout",
}


def _bits(value: int, low: int, width: int) -> int:
    return (value >> low) & ((1 << width) - 1)


def decode_record(value: int) -> tuple[RvfiRecord, int, bool]:
    """Unpack frost_rvfi_dii's rvfi_record_t.

    Returns the record, the next PC the retirement reported, and whether the
    record's data is complete (written, with no store or CSR value pending).
    """
    record = RvfiRecord(
        pc_rdata=_bits(value, 0, 64),
        rd_wdata=_bits(value, 128, 64),
        mem_addr=_bits(value, 192, 64),
        mem_wdata=_bits(value, 256, 64),
        insn=_bits(value, 320, 32),
        mem_wmask=_bits(value, 352, 8),
        rd_addr=_bits(value, 360, 8),
        trap=_bits(value, 368, 1),
        mode=_bits(value, 369, 2),
    )
    complete = (
        _bits(value, 371, 1) == 1
        and _bits(value, 372, 1) == 0
        and _bits(value, 373, 1) == 0
    )
    return record, _bits(value, 64, 64), complete


class FrostRvfiDii:
    """Run instruction traces on the simulated SoC through frost_rvfi_dii."""

    def __init__(self, dut: Any) -> None:
        """Bind the frost toplevel and its harness instance."""
        self.dut = dut
        self.harness = dut.cpu_and_memory_subsystem.u_rvfi_dii
        self.preamble = reset_preamble()
        self.errors: list[str] = []

    async def run(self, trace: list[int]) -> list[RvfiRecord]:
        """Reset, run the preamble and the trace, and return the trace's records.

        A record list shorter than the trace means the SoC hung: each record
        needs the event after it, which shows where the core went next.
        """
        dut = self.dut
        harness = self.harness
        stream = self.preamble + trace
        if len(stream) >= MAX_STREAM_WORDS:
            raise ValueError(
                f"trace of {len(trace)} instructions exceeds the harness capacity"
            )

        dut.i_rst_n.value = 0
        for index, word in enumerate(stream):
            harness.dii_insn[index].value = word
        harness.dii_count.value = len(stream)
        # One record past the trace gives the last instruction's next PC.
        harness.event_target.value = len(stream) + 1
        harness.hang_limit.value = HANG_CYCLES
        await ClockCycles(dut.i_clk, RESET_CYCLES)
        dut.i_rst_n.value = 1
        await RisingEdge(harness.done)
        await RisingEdge(dut.i_clk)

        error_flags = int(harness.error_flags.value)
        for bit, meaning in HARNESS_ERRORS.items():
            if error_flags & (1 << bit):
                self.errors.append(meaning)
                cocotb.log.error(f"frost_rvfi_dii: {meaning}")

        event_count = min(int(harness.event_count.value), MAX_EVENTS)
        decoded = [
            decode_record(int(harness.rvfi_record[index].value))
            for index in range(event_count)
        ]
        if bool(int(harness.hung.value)):
            cocotb.log.warning(
                f"no retirement for {HANG_CYCLES} cycles after "
                f"{max(0, event_count - len(self.preamble))} of {len(trace)} instructions"
            )

        if DEBUG:
            for index in range(event_count):
                record, next_pc, complete = decoded[index]
                cocotb.log.info(
                    f"event {index}: pc {record.pc_rdata:#x} next {next_pc:#x} "
                    f"insn {record.insn:#010x} trap {record.trap} rd x{record.rd_addr}="
                    f"{record.rd_wdata:#x} mem {record.mem_addr:#x}/{record.mem_wmask:#x}="
                    f"{record.mem_wdata:#x} mode {record.mode} complete {complete}"
                )

        records: list[RvfiRecord] = []
        first = len(self.preamble)
        for index in range(first, min(event_count, len(stream))):
            record, next_pc, complete = decoded[index]
            if not complete or index + 1 >= event_count:
                cocotb.log.warning(f"instruction {index - first}: record incomplete")
                break
            record.order = index - first
            actual_next_pc = decoded[index + 1][0].pc_rdata
            if actual_next_pc != next_pc:
                cocotb.log.warning(
                    f"instruction {index - first} at {record.pc_rdata:#x}: "
                    f"next PC {actual_next_pc:#x}, retirement said {next_pc:#x}"
                )
            record.pc_wdata = actual_next_pc
            records.append(record)
        return records


@cocotb.test()
async def test_rvfi_dii(dut: Any) -> None:
    """Serve RVFI-DII traces until the verification engine disconnects."""
    Clock(dut.i_clk, CLK_PERIOD_NS, unit="ns").start()
    cocotb.start_soon(generate_divided_clock(dut))
    if os.environ.get("FROST_NIC_MAC_CLOCKS", "1") == "0":
        # Device reads use the harness RAM. Guard both NIC write enables,
        # which the platform holds low even for stores in the NIC's window.
        platform = dut.cpu_and_memory_subsystem
        hold_nic_without_mac_clocks(dut, (platform.nic_wr_en, platform.nic_wr64_en))
    else:
        start_nic_mac_clocks(dut)
    dut.i_uart_rx.value = 1
    dut.i_external_interrupt.value = 0
    dut.i_instr_mem_en.value = 0
    dut.i_rst_n.value = 0

    port_text = os.environ.get("FROST_RVFI_DII_PORT")
    assert port_text, (
        "FROST_RVFI_DII_PORT is unset; tests/test_testrig.py runs this test"
    )
    listener = socket.create_server(("127.0.0.1", int(port_text)))
    cocotb.log.info(f"RVFI-DII: listening on 127.0.0.1:{port_text}")
    # The runner starts the engine once this file exists: a probe connection
    # would take the one accept below.
    ready_file = os.environ.get("FROST_RVFI_DII_READY_FILE")
    if ready_file:
        Path(ready_file).touch()
    # The simulator waits here (and in every read below) for the engine.
    connection, _ = listener.accept()
    listener.close()
    connection.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    reader = PacketReader(connection)
    frost = FrostRvfiDii(dut)
    trace_version = 1
    trace: list[int] = []
    traces_run = 0
    try:
        while True:
            try:
                packet = DiiPacket.decode(reader.read(DII_PACKET_BYTES))
            except (EOFError, ConnectionResetError):
                break
            if packet.is_version_query:
                connection.sendall(version_query_response())
            elif packet.cmd == CMD_SET_VERSION:
                if packet.insn not in (1, 2):
                    raise ValueError(f"unsupported trace version {packet.insn}")
                trace_version = packet.insn
                connection.sendall(version_ack(trace_version))
            elif packet.cmd == CMD_INSTRUCTION:
                trace.append(packet.insn)
            elif packet.cmd == CMD_END_OF_TRACE:
                records = await frost.run(trace) if trace else []
                records.append(RvfiRecord.halt_token())
                encode = (
                    RvfiRecord.encode_v2 if trace_version == 2 else RvfiRecord.encode_v1
                )
                connection.sendall(b"".join(encode(record) for record in records))
                trace = []
                traces_run += 1
            else:
                raise ValueError(f"unknown RVFI-DII command {packet.cmd:#x}")
    finally:
        connection.close()
    cocotb.log.info(f"RVFI-DII: served {traces_run} traces")
    assert not frost.errors, f"harness errors: {sorted(set(frost.errors))}"
