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

"""Compare sector records with an ordered scalar-store reference."""

import random
from typing import Any

import cocotb
from cocotb.triggers import Timer


@cocotb.test()
async def records_preserve_scalar_bytes_and_credit(dut: Any) -> None:
    """Exercise partial masks, contributor limits, sealing and circular reuse."""
    rng = random.Random(7316)
    records: list[dict[str, Any]] = []
    accepted = retired = 0
    launch_credit = False
    head = 0

    async def step(**values: int) -> None:
        for name, value in values.items():
            getattr(dut, name).value = value
        dut.i_clk.value = 0
        await Timer(1, unit="ns")
        dut.i_clk.value = 1
        await Timer(1, unit="ns")
        dut.i_clk.value = 0
        await Timer(1, unit="ns")

    def get(name: str) -> int:
        return int(getattr(dut, name).value)

    for signal in dut:
        if signal._name.startswith("i_"):
            signal.value = 0
    await step(i_rst=1)
    await step(i_rst=0)
    for cycle in range(3000):
        assert get("o_count") == len(records)
        assert get("o_head") == head
        assert sum(len(r["writes"]) for r in records) == accepted - retired <= 128
        for age, record in enumerate(records):
            slot = (head + age) % 4
            assert (get("o_valid") >> slot) & 1
            assert (get("o_sealed") >> slot) & 1 == record["sealed"]
            assert (get("o_acquired") >> slot) & 1 == record["acquired"]
            assert (get("o_addr") >> (32 * slot)) & 0xFFFFFFFF == record["addr"]
            expected = {}
            for address, data, mask in record["writes"]:
                for byte in range(8):
                    if mask & (1 << byte):
                        expected[(address & 24) + byte] = (data >> (8 * byte)) & 255
            assert (get("o_mask") >> (32 * slot)) & 0xFFFFFFFF == sum(
                1 << b for b in expected
            )
            for byte, value in expected.items():
                assert (get("o_data") >> (256 * slot + 8 * byte)) & 255 == value
            assert (get("o_contributors") >> (6 * slot)) & 63 == len(record["writes"])
        # The initial burst reaches the 32-contributor limit without a seal.
        push = launch_credit and (cycle < 100 or rng.randrange(4) != 0)
        addr = (
            0x80000000
            + (0 if cycle < 100 else rng.randrange(5) * 32)
            + rng.randrange(4) * 8
        )
        data = rng.getrandbits(64)
        mask = rng.randrange(1, 256)
        pop = bool(records and records[0]["sealed"] and rng.randrange(3) == 0)
        seal_age = rng.randrange(len(records)) if records and cycle >= 100 else None
        seal = (
            seal_age is not None
            and rng.randrange(3) == 0
            and not (pop and seal_age == 0)
        )
        acquire_age = rng.randrange(len(records)) if records else None
        acquire = (
            acquire_age is not None
            and not records[acquire_age]["acquired"]
            and not (pop and acquire_age == 0)
        )
        sealed_record = records[seal_age] if seal and seal_age is not None else None
        acquired_record = (
            records[acquire_age] if acquire and acquire_age is not None else None
        )
        merge = bool(
            records
            and not records[-1]["sealed"]
            and records[-1]["addr"] == (addr & ~31)
        )
        # Credit samples the arriving pulse and never borrows a simultaneous pop.
        expect_ready = len(records) < 4 and not (len(records) == 3 and push)
        values = dict(
            i_push=int(push),
            i_addr=addr,
            i_data=data,
            i_mask=mask,
            i_tag=cycle % 128,
            i_pop=int(pop),
            i_seal=int(seal),
            i_seal_index=(head + (seal_age or 0)) % 4,
            i_acquire=int(acquire),
            i_acquire_index=(head + (acquire_age or 0)) % 4,
            i_acquire_ep=cycle % 8,
        )
        for name, value in values.items():
            getattr(dut, name).value = value
        await Timer(1, unit="ns")
        assert get("o_ready") == expect_ready
        if records:
            dut.i_addr.value = records[-1]["addr"]
            await Timer(1, unit="ns")
            assert get("o_ready") == expect_ready
            dut.i_addr.value = records[-1]["addr"] ^ 32
            await Timer(1, unit="ns")
            assert get("o_ready") == expect_ready
            dut.i_addr.value = addr
            await Timer(1, unit="ns")
        launch_credit = bool(get("o_ready"))
        if push:
            accepted += 1
            if not merge:
                records.append(
                    dict(addr=addr & ~31, writes=[], sealed=False, acquired=False)
                )
            records[-1]["writes"].append((addr, data, mask))
            if len(records[-1]["writes"]) == 32:
                records[-1]["sealed"] = True
        if sealed_record is not None:
            sealed_record["sealed"] = True
        if acquired_record is not None:
            acquired_record["acquired"] = True
        if pop:
            retired += len(records.pop(0)["writes"])
            head = (head + 1) % 4
        await step()
        assert get("o_done") == push
    assert accepted > 500 and retired > 400
