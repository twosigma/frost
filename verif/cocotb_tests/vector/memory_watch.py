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

"""Observe fence drains and simultaneous vector/SoC-DMA line traffic."""

from typing import Any
import os

import cocotb
from cocotb.triggers import RisingEdge, ReadOnly

from cocotb_tests.test_real_program import cpu_clock


class VectorMemoryWatch:
    """Account for requests and responses at both coherent clients."""

    def __init__(self, dut: Any) -> None:
        """Bind the two clients and the ROB serializer explicitly."""
        self.dut = dut
        self.cpu = dut.cpu_and_memory_subsystem.cpu.hart.cpu_inst
        self.serializer = self.cpu.u_tomasulo.u_rob.rob_serializer_inst
        self.dma = dut.cpu_and_memory_subsystem.soc.gen_cached_tier.dma_engine.engine
        self.check_waits = os.environ.get("FROST_VEC_ORDER_CHECK_WAITS", "1") != "0"
        self.clear()

    def clear(self) -> None:
        """Begin one program run with no outstanding requests."""
        self.vector: dict[int, tuple[int, bool]] = {}
        self.device: dict[int, tuple[int, bool]] = {}
        self.count = dict(
            vector_req=0,
            vector_resp=0,
            dma_read=0,
            dma_write=0,
            dma_resp=0,
            overlap=0,
            shared=0,
            separate=0,
            fence=0,
            fence_i=0,
            sfence=0,
        )
        for vector_kind in ("load", "store"):
            for dma_kind in ("read", "write"):
                self.count[f"{vector_kind}_dma_{dma_kind}"] = 0
                self.count[f"{vector_kind}_dma_{dma_kind}_shared"] = 0

    async def run(self) -> None:
        """Sample explicit signal paths; never enumerate the SoC hierarchy."""
        c, d, s = self.cpu, self.dma, self.serializer
        while True:
            await RisingEdge(cpu_clock(self.dut))
            await ReadOnly()
            if int(c.i_rst.value):
                self.clear()
                continue
            if not int(c.vec_vmem_quiet.value):
                kind = (
                    "sfence"
                    if int(s.head_is_sfence.value)
                    else "fence_i"
                    if int(s.head_is_fence_i.value)
                    else "fence"
                    if int(s.head_is_fence.value)
                    else None
                )
                if kind:
                    self.count[kind] += 1
                    assert not self.check_waits or int(s.o_commit_stall.value), (
                        f"{kind} passed live vector memory"
                    )
                assert not self.check_waits or not int(s.o_fence_i_sync_req.value), (
                    "cache synchronization passed live vector memory"
                )
            if (
                int(c.i_ma_line_resp_valid.value)
                and int(c.i_ma_line_resp_id.value) >= 2
            ):
                rid = int(c.i_ma_line_resp_id.value)
                assert rid in self.vector, f"unexpected vector completion {rid}"
                del self.vector[rid]
                self.count["vector_resp"] += 1
            if int(c.vec_lc_req_valid.value) and int(c.vec_lc_req_ready.value):
                rid = int(c.vec_lc_req_id.value)
                assert rid not in self.vector, f"vector identity reused {rid}"
                self.vector[rid] = (
                    int(c.vec_lc_req_addr.value) >> 5,
                    bool(int(c.vec_lc_req_write.value)),
                )
                self.count["vector_req"] += 1
            if int(d.i_dma_resp_valid.value):
                rid = int(d.i_dma_resp_id.value)
                assert rid in self.device, f"unexpected DMA completion {rid}"
                del self.device[rid]
                self.count["dma_resp"] += 1
            if int(d.o_dma_req_valid.value) and int(d.i_dma_req_ready.value):
                rid = int(d.o_dma_req_id.value)
                assert rid not in self.device, f"DMA identity reused {rid}"
                self.device[rid] = (
                    int(d.o_dma_req_addr.value) >> 5,
                    bool(int(d.o_dma_req_write.value)),
                )
                self.count[
                    "dma_write" if int(d.o_dma_req_write.value) else "dma_read"
                ] += 1
            if self.vector and self.device:
                self.count["overlap"] += 1
                v = {pa for pa, _ in self.vector.values()}
                dma = {pa for pa, _ in self.device.values()}
                self.count["shared"] += bool(v & dma)
                self.count["separate"] += any(a != b for a in v for b in dma)
                for write, vector_kind in enumerate(("load", "store")):
                    va = {pa for pa, w in self.vector.values() if w == write}
                    for dma_write, dma_kind in enumerate(("read", "write")):
                        da = {pa for pa, w in self.device.values() if w == dma_write}
                        key = f"{vector_kind}_dma_{dma_kind}"
                        self.count[key] += bool(va and da)
                        self.count[key + "_shared"] += bool(va & da)

    def verify(self) -> None:
        """Require exercised ordering waits, concurrency, and balanced completions."""
        cocotb.log.info("Vector/DMA evidence: %s", self.count)
        assert not self.vector and not self.device, "unfinished coherent requests"
        assert self.count["vector_req"] == self.count["vector_resp"] > 0
        assert (
            self.count["dma_read"] + self.count["dma_write"] == self.count["dma_resp"]
        )
        kinds = [
            "overlap",
            "shared",
            "separate",
            "load_dma_write_shared",
            "store_dma_read_shared",
        ]
        kinds += [f"{v}_dma_{d}" for v in ("load", "store") for d in ("read", "write")]
        if self.check_waits:
            kinds += ["fence", "fence_i", "sfence"]
        for kind in kinds:
            assert self.count[kind] > 0, f"did not exercise {kind}"
