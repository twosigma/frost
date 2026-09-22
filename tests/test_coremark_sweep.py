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

"""CoreMark evidence validation must reject partial, wrong-seed or corrupt runs."""

import pytest

from scripts.coremark_sweep import CRCS, SOURCES, link_orders, parse_reports


def report(seed_set: str = "performance") -> str:
    """Build a complete one-iteration UART report with independent CRCs."""
    seed, listing, matrix, state = CRCS[seed_set]
    return (
        "CoreMark Size    : 666\nTotal ticks : 285189\nIterations : 1\n"
        "Compiler version : GCC 15.3.0\nCompiler flags : -O3\n"
        "Memory location : STACK\n"
        f"seedcrc : 0x{seed}\n[0]crclist : 0x{listing}\n"
        f"[0]crcmatrix : 0x{matrix}\n[0]crcstate : 0x{state}\n"
        "Correct operation validated.\n"
    )


@pytest.mark.parametrize("seed_set", CRCS)
def test_reports_preserve_run_order_and_disclaim_official_length(seed_set: str) -> None:
    """Cold/warm runs remain separate; a synthetic timer cannot confer official status."""
    log = report(seed_set) + report(seed_set).replace("285189", "284100")
    result = parse_reports(log, seed_set, 2)
    assert [run["ticks"] for run in result] == [285189, 284100]
    assert all(not run["official_length"] for run in result)


@pytest.mark.parametrize(
    "log,seeds,runs",
    [
        ("", "performance", 1),
        (report(), "performance", 2),
        (report("validation"), "performance", 1),
        (report().replace("0x1fd7", "0x0000"), "performance", 1),
        (report().replace("Correct operation validated.", ""), "performance", 1),
        (report().replace("Iterations : 1", "Iterations : 0"), "performance", 1),
        (report().replace("285189", "0"), "performance", 1),
    ],
)
def test_reject_bad_measurements(log: str, seeds: str, runs: int) -> None:
    """Fail closed instead of publishing a plausible score from invalid evidence."""
    with pytest.raises(ValueError):
        parse_reports(log, seeds, runs)


def test_ensemble_is_deterministic_and_contains_all_sources() -> None:
    """Order changes preserve the benchmark and remain reproducible."""
    orders = link_orders(120)
    assert orders == link_orders(120)
    assert orders[0] == SOURCES
    assert len(set(orders)) == 120
    assert all(set(order) == set(SOURCES) for order in orders)
