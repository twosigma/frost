#    Copyright (c) 2026 John Goodacre.
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

"""Check Zicbom write-backs against the behavioral DDR model.

A program opens a window by writing sscratch with

    bits 63:48  0xCB0C (the window marker)
    bits 47:40  a sequence number (a new value opens a new window)
    bits 39:38  the expectation: 1 the window must write the line to DDR,
                0 it must not, 2 either
    bits 35:0   the 64-byte line's physical address

and closes it by writing any value without the marker. The program fences
before closing a window, so a CMO's write-back, which precedes its completion,
lands inside it. The watch pairs the DDR model's accepted AW addresses with W
beats, attributes each write of a window's line to that window, and verify()
fails a window whose writes break its expectation. FROST_CMO_DDR_MIN_WINDOWS
(default 1) is the number of windows the program must open.
"""

import os
from typing import Any

import cocotb
from cocotb.triggers import RisingEdge

MARKER = 0xCB0C
DDR_BASE = 0x80000000
EXPECT_NAME = {0: "none", 1: "write-back", 2: "either"}


class CmoDdrWatch:
    """Attribute behavioral-DDR writes to the program's CMO windows."""

    def __init__(self, dut: Any) -> None:
        """Resolve the DDR model's write channel and the hart's sscratch."""
        base = "cpu_and_memory_subsystem.soc.gen_behavioral_ddr.ddr_model"
        cpu = "cpu_and_memory_subsystem.cpu.hart.cpu_inst"
        self.dut = dut
        self.signals = {}
        for name, path in (
            ("awv", f"{base}.i_axi_awvalid"),
            ("awr", f"{base}.o_axi_awready"),
            ("awa", f"{base}.i_axi_awaddr"),
            ("wv", f"{base}.i_axi_wvalid"),
            ("wr", f"{base}.o_axi_wready"),
            ("ss", f"{cpu}.csr_file_inst.sscratch"),
        ):
            handle = dut
            for part in path.split("."):
                handle = getattr(handle, part)
            self.signals[name] = handle
        self.min_windows = int(os.environ.get("FROST_CMO_DDR_MIN_WINDOWS", "1"))
        self.clear()

    def clear(self) -> None:
        """Forget every window (a new run)."""
        # window: [sequence, expectation, line, writes]
        self.windows: list[list[int]] = []
        self.current: list[int] | None = None
        self.pending: list[int] = []
        self.marker = 0

    def _read(self, name: str) -> int:
        value = self.signals[name].value
        return int(value) if value.is_resolvable else 0

    async def run(self) -> None:
        """Watch every clock edge."""
        while True:
            await RisingEdge(self.dut.i_clk)
            mark = self._read("ss")
            if mark != self.marker:
                self.marker = mark
                if (mark >> 48) == MARKER:
                    self.current = [
                        (mark >> 40) & 0xFF,
                        (mark >> 38) & 3,
                        mark & ((1 << 36) - 1) & ~63,
                        0,
                    ]
                    self.windows.append(self.current)
                else:
                    self.current = None
            if self._read("awv") and self._read("awr"):
                self.pending.append(self._read("awa"))
            if self._read("wv") and self._read("wr") and self.pending:
                # The model takes a whole line in one W beat.
                addr = self.pending.pop(0)
                line = (addr + DDR_BASE) & ~63
                if self.current is not None and line == self.current[2]:
                    self.current[3] += 1

    def verify(self) -> None:
        """Fail any window whose DDR writes break its expectation."""
        bad = []
        for seq, expect, line, writes in self.windows:
            if (expect == 1 and writes == 0) or (expect == 0 and writes != 0):
                bad.append(
                    f"window {seq} line {line:#x}: expected {EXPECT_NAME[expect]}, "
                    f"{writes} DDR write beat(s)"
                )
        cocotb.log.info(
            f"cmo_ddr_watch: {len(self.windows)} window(s), "
            f"{sum(1 for w in self.windows if w[3])} with a write of the line"
        )
        assert len(self.windows) >= self.min_windows, (
            f"cmo_ddr_watch: {len(self.windows)} window(s) < {self.min_windows}"
        )
        assert not bad, "cmo_ddr_watch: " + "; ".join(bad)
