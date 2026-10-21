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

"""Run actual instructions against only cpu_top's documented external ports."""

from typing import Any

from collections import deque

import cocotb
from cocotb.triggers import Timer


def addi(rd: int, rs: int, imm: int) -> int:
    """Encode an ADDI instruction."""
    return ((imm & 0xFFF) << 20) | (rs << 15) | (rd << 7) | 0x13


def load(rd: int, rs: int, offset: int, size: int) -> int:
    """Encode a load instruction."""
    return ((offset & 0xFFF) << 20) | (rs << 15) | (size << 12) | (rd << 7) | 3


def store(rs: int, base: int, offset: int, size: int) -> int:
    """Encode a store instruction."""
    return (
        (((offset >> 5) & 0x7F) << 25)
        | (rs << 20)
        | (base << 15)
        | (size << 12)
        | ((offset & 31) << 7)
        | 0x23
    )


class System:
    """Drive the public interfaces and track external transactions."""

    def __init__(self, dut: Any, boot: int = 0x1000) -> None:
        """Initialize the interface and scoreboard."""
        self.dut = dut
        self.boot = boot
        self.cycle = 0
        self.memory: dict[int, int] = {}
        self.aw: deque[tuple[int, int, int, int]] = deque()
        self.w: deque[tuple[int, int]] = deque()
        self.reads: list[tuple[int, int, int, int]] = []
        self.replies: list[tuple[int, int, int, int]] = []
        self.r: tuple[int, int, int, int] | None = None
        self.b: tuple[int, int, int, int] | None = None
        self.transactions: list[tuple[int, str, int, int, int, int]] = []
        self.completed_writes: list[tuple[int, int]] = []
        self.effects: list[tuple[int, int, int]] = []
        self.error_reads: set[int] = set()
        self.error_writes: set[int] = set()
        self.pops = 0
        self.held: dict[str, tuple[int, ...]] = {}
        self.allow_fatal = False
        self.device_base = 0x40000000

    def program(self, instructions: list[int], addr: int | None = None) -> None:
        """Write instruction words into the external memory model."""
        addr = self.boot if addr is None else addr
        for instruction in instructions:
            for byte in instruction.to_bytes(4, "little"):
                self.memory[addr] = byte
                addr += 1

    async def reset(self) -> None:
        """Reset the device and initialize its inputs."""
        inputs = dict(
            rst=1,
            axi_rst=1,
            boot_addr=self.boot,
            interrupts=0,
            seip=0,
            mtime=0,
            disable_branch_prediction=0,
            dbg_haltreq=0,
            dbg_go=0,
            dbg_go_addr=0,
            dbg_data=0,
            coherent_req_valid=1,
            coherent_req_write=1,
            coherent_req_addr=0x80004000,
            coherent_req_wdata=123,
            coherent_req_wstrb=0xFFFFFFFF,
            coherent_req_id=3,
            axi_rvalid=0,
            axi_rid=0,
            axi_rdata=0,
            axi_rresp=0,
            axi_rlast=1,
            axi_ruser=0,
            axi_bvalid=0,
            axi_bid=0,
            axi_bresp=0,
            axi_buser=0,
            axi_arready=0,
            axi_awready=0,
            axi_wready=0,
        )
        for name, value in inputs.items():
            getattr(self.dut, "i_" + name).value = value
        for _ in range(5):
            await self.step(reset=True)
        self.dut.i_rst.value = 0
        self.dut.i_axi_rst.value = 0

    async def step(self, reset: bool = False) -> None:
        """Advance one clock edge and sample the interface."""
        d = self.dut
        d.i_clk.value = 0
        self.cycle += 1
        for name, period in (("ar", 5), ("aw", 7), ("w", 3)):
            getattr(d, f"i_axi_{name}ready").value = int(
                not reset and self.cycle % period == 0
            )
        if self.r is None:
            due = [r for r in self.reads if r[0] <= self.cycle]
            if due:
                self.r = max(due)  # Allow different IDs to complete out of order.
                self.reads.remove(self.r)
        if self.b is None and self.replies and self.replies[0][0] <= self.cycle:
            self.b = self.replies.pop(0)
        d.i_axi_rvalid.value = int(self.r is not None)
        if self.r:
            _, ident, value, status = self.r
            d.i_axi_rid.value = ident
            d.i_axi_rdata.value = value
            d.i_axi_rresp.value = status
        d.i_axi_bvalid.value = int(self.b is not None)
        if self.b:
            _, ident, status, _ = self.b
            d.i_axi_bid.value = ident
            d.i_axi_bresp.value = status
        await Timer(5, unit="ns")
        assert not int(d.o_coherent_req_ready.value)
        assert not int(d.o_coherent_resp_valid.value)
        assert not int(d.o_coherent_resp_error.value)
        assert self.allow_fatal or not int(d.o_fatal_error.value)
        for channel, fields in (
            ("ar", ("id", "addr", "len", "size", "cache", "prot")),
            ("aw", ("id", "addr", "len", "size", "cache", "prot")),
            ("w", ("data", "strb", "last")),
        ):
            valid = int(getattr(d, f"o_axi_{channel}valid").value)
            ready = int(getattr(d, f"i_axi_{channel}ready").value)
            payload = tuple(
                int(getattr(d, f"o_axi_{channel}{f}").value) for f in fields
            )
            if not reset and channel in self.held:
                assert valid and payload == self.held[channel], channel
            if valid and not ready:
                self.held[channel] = payload
            else:
                self.held.pop(channel, None)
            if not valid or not ready:
                continue
            if channel == "ar":
                ident, addr, length, size, cache, prot = payload
                assert length == 0
                self.transactions.append((self.cycle, "read", addr, size, cache, prot))
                value = sum(
                    self.memory.get((addr & ~63) + n, 0) << (8 * n) for n in range(64)
                )
                if addr == self.device_base + 4:
                    assert size == 0 and cache == 0
                    self.pops += 1
                    value = 0xA5 << 32
                status = 2 if addr in self.error_reads else 0
                self.reads.append((self.cycle + 9 + ident % 11, ident, value, status))
            elif channel == "aw":
                ident, addr, length, size, cache, prot = payload
                assert length == 0
                self.transactions.append((self.cycle, "write", addr, size, cache, prot))
                self.aw.append((ident, addr, size, cache))
            else:
                assert payload[2] == 1
                self.w.append((payload[0], payload[1]))
        if self.aw and self.w:
            ident, addr, size, cache = self.aw.popleft()
            value, strb = self.w.popleft()
            expected = ((1 << (1 << size)) - 1) << (addr & 63)
            assert (strb & ~expected) == 0, (hex(addr), strb, expected)
            if cache != 15:
                assert strb == expected, (hex(addr), strb, expected)
            scalar = (value >> (8 * (addr & 63))) & ((1 << (8 << size)) - 1)
            self.effects.append((self.cycle, addr, scalar))
            status = 2 if addr in self.error_writes else 0
            if status == 0 and cache != 0:
                for n in range(64):
                    if (strb >> n) & 1:
                        self.memory[(addr & ~63) + n] = (value >> (8 * n)) & 255
            self.replies.append((self.cycle + 43, ident, status, addr))
        if self.r and int(d.o_axi_rready.value):
            self.r = None
        if self.b and int(d.o_axi_bready.value):
            self.completed_writes.append((self.cycle, self.b[3]))
            self.b = None
        d.i_clk.value = 1
        await Timer(5, unit="ns")

    async def until_write(self, address: int, timeout: int = 20000) -> Any:
        """Check until write."""
        for _ in range(timeout):
            await self.step()
            found = [value for _, addr, value in self.effects if addr == address]
            if found:
                return found[-1]
        raise AssertionError(
            f"CPU did not write {address:#x}; transactions={self.transactions[-20:]}"
        )


@cocotb.test()
async def boot_cache_narrow_mmio_fence_and_inactive_coherence(dut: Any) -> None:
    """Check boot cache narrow mmio fence and inactive coherence."""
    s = System(dut)
    s.program(
        [
            0x400000B7,
            addi(2, 0, 0x5A),
            store(2, 1, 0, 0),
            0x0FF0000F,
            load(3, 1, 4, 4),
            store(3, 1, 0x10, 0),
            0x80000237,
            (32 << 20) | (4 << 15) | (1 << 12) | (4 << 7) | 0x13,
            (32 << 20) | (4 << 15) | (5 << 12) | (4 << 7) | 0x13,
            load(5, 4, 0, 3),
            store(5, 1, 0x18, 3),
            addi(6, 0, 1),
            store(6, 1, 8, 0),
            0x0000006F,
        ]
    )
    cached_value = 0x8877665544332211
    for n in range(8):
        s.memory[0x80000000 + n] = (cached_value >> (8 * n)) & 255
    await s.reset()
    assert await s.until_write(0x40000008) == 1
    assert s.pops == 1
    values = {addr: value for _, addr, value in s.effects}
    assert values[0x40000000] == 0x5A
    assert values[0x40000010] == 0xA5
    assert values[0x40000018] == cached_value
    pop_cycle = next(
        cycle
        for cycle, kind, addr, *_ in s.transactions
        if kind == "read" and addr == 0x40000004
    )
    first_b = next(cycle for cycle, addr in s.completed_writes if addr == 0x40000000)
    assert pop_cycle > first_b
    assert any(
        addr == 0x80000000 and size == 6 and cache == 15
        for _, kind, addr, size, cache, _ in s.transactions
        if kind == "read"
    )
    assert any(
        addr == s.boot and size == 3 and cache == 2 and prot & 4
        for _, kind, addr, size, cache, prot in s.transactions
        if kind == "read"
    )


def csr(rd: int, rs: int, number: int, operation: int = 1) -> int:
    """Encode a CSR instruction."""
    return (number << 20) | (rs << 15) | (operation << 12) | (rd << 7) | 0x73


def trap_program(s: System, body: list[int]) -> int:
    """Set mtvec and report architectural mcause, mepc and mtval through MMIO."""
    setup = [0x00000517, addi(10, 10, 0x100), csr(0, 10, 0x305), 0x400000B7]
    s.program(setup + body + [addi(2, 0, 0xEE), store(2, 1, 8, 0), 0x0000006F])
    s.program(
        [
            csr(7, 0, 0x342, 2),
            store(7, 1, 0x10, 3),
            csr(8, 0, 0x341, 2),
            store(8, 1, 0x18, 3),
            csr(9, 0, 0x343, 2),
            store(9, 1, 0x20, 3),
            0x0000006F,
        ],
        s.boot + 0x100,
    )
    return s.boot + 4 * len(setup)


@cocotb.test()
async def misaligned_accesses_trap_before_mtvec_is_installed(dut: Any) -> None:
    """Reset mtvec=0 must not permit a misaligned load/store onto AXI."""
    for instruction, cause in ((load(3, 1, 1, 3), 4), (store(3, 1, 1, 3), 6)):
        s = System(dut)
        s.program([addi(1, 0, 0x58), instruction, 0x0000006F])
        s.program(
            [
                0x400000B7,
                csr(7, 0, 0x342, 2),
                store(7, 1, 0x10, 3),
                csr(8, 0, 0x341, 2),
                store(8, 1, 0x18, 3),
                csr(9, 0, 0x343, 2),
                store(9, 1, 0x20, 3),
                0x0000006F,
            ],
            0,
        )
        await s.reset()
        await s.until_write(0x40000020)
        values = {addr: value for _, addr, value in s.effects}
        assert values[0x40000010] == cause
        assert values[0x40000018] == s.boot + 4
        assert values[0x40000020] == 0x59
        assert not any(addr == 0x59 for _, _, addr, *_ in s.transactions)


@cocotb.test()
async def device_read_error_is_precise_access_fault(dut: Any) -> None:
    """Check device read error is precise access fault."""
    s = System(dut)
    fault_pc = trap_program(s, [load(3, 1, 4, 4)])
    s.error_reads.add(0x40000004)
    await s.reset()
    assert await s.until_write(0x40000020) == 0
    values = {addr: value for _, addr, value in s.effects}
    assert values[0x40000010] == 5
    assert values[0x40000018] == fault_pc
    assert 0x40000008 not in values
    assert s.pops == 1


@cocotb.test()
async def device_write_error_is_precise_access_fault(dut: Any) -> None:
    """Check device write error is precise access fault."""
    s = System(dut)
    fault_pc = trap_program(s, [store(0, 1, 0, 0)])
    s.error_writes.add(0x40000000)
    await s.reset()
    assert await s.until_write(0x40000020) == 0
    values = {addr: value for _, addr, value in s.effects}
    assert values[0x40000010] == 7
    assert values[0x40000018] == fault_pc
    assert 0x40000008 not in values
    assert sum(addr == 0x40000000 for _, addr, _ in s.effects) == 1


@cocotb.test()
async def cached_read_error_reaches_the_pipeline(dut: Any) -> None:
    """Check cached read error reaches the pipeline."""
    s = System(dut)
    body = [
        0x80000237,
        (32 << 20) | (4 << 15) | (1 << 12) | (4 << 7) | 0x13,
        (32 << 20) | (4 << 15) | (5 << 12) | (4 << 7) | 0x13,
        load(5, 4, 0, 3),
    ]
    fault_pc = trap_program(s, body) + 12
    s.error_reads.add(0x80000000)
    await s.reset()
    assert await s.until_write(0x40000020) == 0
    values = {addr: value for _, addr, value in s.effects}
    assert values[0x40000010] == 5
    assert values[0x40000018] == fault_pc
    assert 0x40000008 not in values


@cocotb.test()
async def instruction_bus_error_is_instruction_access_fault(dut: Any) -> None:
    """Check instruction bus error is instruction access fault."""
    s = System(dut)
    # Jump to another uncached block, after mtvec and the reporting base exist.
    target = s.boot + 0x200
    trap_program(s, [0x00000617, addi(12, 12, 0x1F0), (12 << 15) | 0x67])
    s.error_reads.add(target)
    await s.reset()
    await s.until_write(0x40000020)
    values = {addr: value for _, addr, value in s.effects}
    assert values[0x40000010] == 1
    assert values[0x40000018] == target
    assert 0x40000008 not in values


@cocotb.test()
async def interrupt_waits_for_side_effecting_read_to_retire(dut: Any) -> None:
    """Check interrupt waits for side effecting read to retire."""
    s = System(dut)
    trap_program(
        s,
        [
            addi(2, 0, 8),
            csr(0, 2, 0x304),
            csr(0, 2, 0x300),
            load(3, 1, 4, 4),
            0x0000006F,
        ],
    )
    s.program(
        [csr(7, 0, 0x342, 2), store(7, 1, 0x10, 3), store(3, 1, 0x28, 0), 0x0000006F],
        s.boot + 0x100,
    )
    await s.reset()
    for _ in range(5000):
        await s.step()
        if s.pops:
            break
    else:
        raise AssertionError("device read did not start")
    # The device has been consumed but its R response is still outstanding.
    dut.i_interrupts.value = 1  # MSIP
    assert await s.until_write(0x40000028) == 0xA5
    values = {addr: value for _, addr, value in s.effects}
    assert values[0x40000010] == (1 << 63) | 3
    assert s.pops == 1


@cocotb.test()
async def interrupt_waits_for_device_store_response(dut: Any) -> None:
    """Check that an IRQ waits for B and does not replay a completed side effect."""
    s = System(dut)
    first_body_pc = trap_program(
        s,
        [
            addi(2, 0, 8),
            csr(0, 2, 0x304),
            csr(0, 2, 0x300),
            store(2, 1, 0, 0),
            0x0000006F,
        ],
    )
    await s.reset()
    assert await s.until_write(0x40000000) == 8
    assert not s.completed_writes
    dut.i_interrupts.value = 1  # MSIP while B is still outstanding.
    await s.until_write(0x40000020)
    values = {addr: value for _, addr, value in s.effects}
    assert values[0x40000010] == (1 << 63) | 3
    assert values[0x40000018] == first_body_pc + 16
    assert sum(addr == 0x40000000 for _, addr, _ in s.effects) == 1
    first_b = next(cycle for cycle, addr in s.completed_writes if addr == 0x40000000)
    handler_write = next(cycle for cycle, addr, _ in s.effects if addr == 0x40000010)
    assert handler_write > first_b


@cocotb.test()
async def core_reset_drains_old_epoch_and_samples_new_boot(dut: Any) -> None:
    """Check core reset drains old epoch and samples new boot."""
    s = System(dut)
    s.program([0x400000B7, load(3, 1, 4, 4), 0x0000006F])
    s.program(
        [
            0x400000B7,
            addi(3, 0, 0x42),
            store(3, 1, 0x10, 0),
            addi(2, 0, 0x77),
            store(2, 1, 8, 0),
            0x0000006F,
        ],
        0x1800,
    )
    await s.reset()
    for _ in range(5000):
        await s.step()
        if s.pops:
            break
    else:
        raise AssertionError("old-epoch read did not start")
    dut.i_rst.value = 1
    dut.i_boot_addr.value = 0x1800
    for _ in range(3):
        await s.step()
    dut.i_rst.value = 0
    assert await s.until_write(0x40000008) == 0x77
    assert s.pops == 1
    assert next(value for _, addr, value in s.effects if addr == 0x40000010) == 0x42


@cocotb.test()
async def buffered_store_refill_error_stops_retirement(dut: Any) -> None:
    """Check buffered store refill error stops retirement."""
    s = System(dut)
    s.allow_fatal = True
    s.program(
        [
            0x400000B7,
            0x80000237,
            (32 << 20) | (4 << 15) | (1 << 12) | (4 << 7) | 0x13,
            (32 << 20) | (4 << 15) | (5 << 12) | (4 << 7) | 0x13,
            store(0, 4, 0, 3),
            0x0FF0000F,
            addi(2, 0, 1),
            store(2, 1, 8, 0),
            0x0000006F,
        ]
    )
    s.error_reads.add(0x80000000)
    await s.reset()
    for _ in range(5000):
        await s.step()
        if int(dut.o_fatal_error.value):
            break
    else:
        raise AssertionError("buffered store failure did not assert fatal")
    assert int(dut.o_fatal_addr.value) == 0x80000000
    effects_after_drain = None
    for cycle in range(50):
        await s.step()
        assert int(dut.o_fatal_error.value)
        if cycle > 3:
            assert not int(dut.o_commit_valid.value)
        # Requests accepted before the asynchronous failure remain obligations.
        # Once those channels drain, no later CPU side effect may appear.
        if cycle == 20:
            effects_after_drain = len(s.effects)
        elif cycle > 20:
            assert len(s.effects) == effects_after_drain
