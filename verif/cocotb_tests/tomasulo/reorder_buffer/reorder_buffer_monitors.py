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

"""Monitors for Reorder Buffer verification.

Monitors run as background coroutines that continuously verify hardware
outputs against expected values from the software model.

Monitors:
- CommitMonitor: Verifies commit outputs match expected values
- AllocationMonitor: Verifies allocation responses
- StatusMonitor: Verifies status signals (full, empty, count)
"""

import cocotb
from cocotb.triggers import RisingEdge, ReadOnly
from collections import deque
from typing import Any

from .reorder_buffer_model import ExpectedCommit
from .reorder_buffer_interface import (
    unpack_commit,
    unpack_alloc_response,
    ALLOC_REQ_WIDTH,
)


class CommitMonitor:
    """Monitor for commit output verification.

    This monitor runs continuously, checking each cycle if a commit occurs.
    When the DUT commits an entry, it pops the expected commit from the queue
    and compares all fields.

    Usage:
        expected_commits = deque()
        monitor = CommitMonitor(dut, expected_commits)
        cocotb.start_soon(monitor.run())

        # In test:
        expected_commits.append(ExpectedCommit(...))
    """

    def __init__(
        self,
        dut: Any,
        expected_queue: deque[ExpectedCommit],
        check_value: bool = True,
        check_serializing: bool = True,
    ):
        """Initialize commit monitor.

        Args:
            dut: Device under test.
            expected_queue: Queue of expected commit outputs.
            check_value: Whether to check result value (may skip for stores).
            check_serializing: Whether to check serializing instruction flags.
        """
        self.dut = dut
        self.expected_queue = expected_queue
        self.check_value = check_value
        self.check_serializing = check_serializing

        self.commits_seen = 0
        self.errors: list[str] = []

    async def run(self) -> None:
        """Run the monitor continuously."""
        while True:
            await RisingEdge(self.dut.i_clk)
            await ReadOnly()

            # Check if DUT is committing
            if not self.dut.i_rst_n.value:
                continue

            # Unpack the commit struct (Verilator flattens packed structs)
            commit_val = int(self.dut.o_commit.value)
            commit = unpack_commit(commit_val)

            if commit["valid"]:
                self.commits_seen += 1

                if not self.expected_queue:
                    error = (
                        f"Commit {self.commits_seen}: Unexpected commit (queue empty)"
                    )
                    self.errors.append(error)
                    cocotb.log.error(error)
                    continue

                expected = self.expected_queue.popleft()
                self._check_commit_dict(commit, expected)

    def _check_commit_dict(self, commit: dict, expected: ExpectedCommit) -> None:
        """Check commit output (unpacked dict) against expected."""
        errors = []

        # Check tag
        if commit["tag"] != expected.tag:
            errors.append(f"tag: got {commit['tag']}, expected {expected.tag}")

        # Check destination
        if commit["dest_rf"] != expected.dest_rf:
            errors.append(
                f"dest_rf: got {commit['dest_rf']}, expected {expected.dest_rf}"
            )

        if commit["dest_reg"] != expected.dest_reg:
            errors.append(
                f"dest_reg: got {commit['dest_reg']}, expected {expected.dest_reg}"
            )

        if commit["dest_valid"] != expected.dest_valid:
            errors.append(
                f"dest_valid: got {commit['dest_valid']}, expected {expected.dest_valid}"
            )

        # Check value (if enabled and has destination)
        if self.check_value and expected.dest_valid:
            if commit["value"] != expected.value:
                errors.append(
                    f"value: got {commit['value']:016x}, expected {expected.value:016x}"
                )

        # Check store flags
        if commit["is_store"] != expected.is_store:
            errors.append(
                f"is_store: got {commit['is_store']}, expected {expected.is_store}"
            )

        if commit["is_fp_store"] != expected.is_fp_store:
            errors.append(
                f"is_fp_store: got {commit['is_fp_store']}, expected {expected.is_fp_store}"
            )

        # Check exception
        if commit["exception"] != expected.exception:
            errors.append(
                f"exception: got {commit['exception']}, expected {expected.exception}"
            )

        if expected.exception:
            if commit["exc_cause"] != expected.exc_cause:
                errors.append(
                    f"exc_cause: got {commit['exc_cause']}, expected {expected.exc_cause}"
                )

        # Check PC
        if commit["pc"] != expected.pc:
            errors.append(f"pc: got {commit['pc']:08x}, expected {expected.pc:08x}")

        # Check FP flags
        if commit["fp_flags"] != expected.fp_flags:
            errors.append(
                f"fp_flags: got {commit['fp_flags']:05b}, expected {expected.fp_flags:05b}"
            )

        # Check misprediction
        if commit["misprediction"] != expected.misprediction:
            errors.append(
                f"misprediction: got {commit['misprediction']}, expected {expected.misprediction}"
            )

        if expected.misprediction or expected.is_mret:
            if commit["redirect_pc"] != expected.redirect_pc:
                errors.append(
                    f"redirect_pc: got {commit['redirect_pc']:08x}, expected {expected.redirect_pc:08x}"
                )

        # Check checkpoint
        if commit["has_checkpoint"] != expected.has_checkpoint:
            errors.append(
                f"has_checkpoint: got {commit['has_checkpoint']}, expected {expected.has_checkpoint}"
            )

        if expected.has_checkpoint:
            if commit["checkpoint_id"] != expected.checkpoint_id:
                errors.append(
                    f"checkpoint_id: got {commit['checkpoint_id']}, expected {expected.checkpoint_id}"
                )

        # Check serializing flags (if enabled)
        if self.check_serializing:
            for flag in [
                "is_csr",
                "is_fence",
                "is_fence_i",
                "is_wfi",
                "is_mret",
                "is_amo",
                "is_lr",
                "is_sc",
            ]:
                actual = commit[flag]
                expected_val = getattr(expected, flag)
                if actual != expected_val:
                    errors.append(f"{flag}: got {actual}, expected {expected_val}")

        if errors:
            error_msg = f"Commit {self.commits_seen} mismatch:\n  " + "\n  ".join(
                errors
            )
            self.errors.append(error_msg)
            cocotb.log.error(error_msg)

    def check_complete(self) -> None:
        """Check that all expected commits have been seen.

        Raises AssertionError if queue is not empty or errors occurred.
        """
        if self.expected_queue:
            raise AssertionError(
                f"CommitMonitor: {len(self.expected_queue)} expected commits not seen"
            )
        if self.errors:
            raise AssertionError(
                f"CommitMonitor: {len(self.errors)} errors:\n" + "\n".join(self.errors)
            )


class AllocationMonitor:
    """Monitor for allocation response verification.

    Verifies that allocation responses (ready, tag) match expected values.

    Usage:
        expected_allocs = deque()
        monitor = AllocationMonitor(dut, expected_allocs)
        cocotb.start_soon(monitor.run())

        # In test:
        expected_allocs.append((True, expected_tag))
    """

    def __init__(
        self,
        dut: Any,
        expected_queue: deque[tuple[bool, int]],
    ):
        """Initialize allocation monitor.

        Args:
            dut: Device under test.
            expected_queue: Queue of (ready, tag) tuples.
        """
        self.dut = dut
        self.expected_queue = expected_queue

        self.allocations_seen = 0
        self.errors: list[str] = []

    async def run(self) -> None:
        """Run the monitor continuously."""
        while True:
            await RisingEdge(self.dut.i_clk)
            await ReadOnly()

            if not self.dut.i_rst_n.value:
                continue

            # Check if allocation request was made (alloc_valid is MSB of packed struct)
            alloc_req_val = int(self.dut.i_alloc_req.value)
            alloc_valid = bool((alloc_req_val >> (ALLOC_REQ_WIDTH - 1)) & 1)

            if alloc_valid:
                self.allocations_seen += 1

                if not self.expected_queue:
                    error = (
                        f"Allocation {self.allocations_seen}: Unexpected (queue empty)"
                    )
                    self.errors.append(error)
                    cocotb.log.error(error)
                    continue

                expected_ready, expected_tag = self.expected_queue.popleft()
                self._check_allocation(expected_ready, expected_tag)

    def _check_allocation(self, expected_ready: bool, expected_tag: int) -> None:
        """Check allocation response against expected."""
        resp_val = int(self.dut.o_alloc_resp.value)
        actual_ready, actual_tag, _ = unpack_alloc_response(resp_val)

        errors = []

        if actual_ready != expected_ready:
            errors.append(f"alloc_ready: got {actual_ready}, expected {expected_ready}")

        if expected_ready and actual_tag != expected_tag:
            errors.append(f"alloc_tag: got {actual_tag}, expected {expected_tag}")

        if errors:
            error_msg = (
                f"Allocation {self.allocations_seen} mismatch:\n  "
                + "\n  ".join(errors)
            )
            self.errors.append(error_msg)
            cocotb.log.error(error_msg)

    def check_complete(self) -> None:
        """Check that all expected allocations have been seen."""
        if self.expected_queue:
            raise AssertionError(
                f"AllocationMonitor: {len(self.expected_queue)} expected allocations not seen"
            )
        if self.errors:
            raise AssertionError(
                f"AllocationMonitor: {len(self.errors)} errors:\n"
                + "\n".join(self.errors)
            )


class StatusMonitor:
    """Monitor for status signal verification.

    Continuously checks that full, empty, and count signals are consistent.

    Usage:
        monitor = StatusMonitor(dut)
        cocotb.start_soon(monitor.run())
    """

    def __init__(self, dut: Any, depth: int = 32):
        """Initialize status monitor.

        Args:
            dut: Device under test.
            depth: Reorder buffer depth (for count validation).
        """
        self.dut = dut
        self.depth = depth
        self.errors: list[str] = []
        self.cycles = 0

    async def run(self) -> None:
        """Run the monitor continuously."""
        while True:
            await RisingEdge(self.dut.i_clk)
            await ReadOnly()

            if not self.dut.i_rst_n.value:
                continue

            self.cycles += 1
            self._check_status()

    def _check_status(self) -> None:
        """Check status signal consistency."""
        full = bool(self.dut.o_full.value)
        empty = bool(self.dut.o_empty.value)
        count = int(self.dut.o_count.value)

        errors = []

        # Count should match full/empty
        if empty and count != 0:
            errors.append(f"empty=True but count={count}")

        if full and count != self.depth:
            errors.append(f"full=True but count={count} (expected {self.depth})")

        if not full and not empty:
            if count == 0:
                errors.append("count=0 but empty=False")
            if count == self.depth:
                errors.append(f"count={self.depth} but full=False")

        # Can't be both full and empty
        if full and empty:
            errors.append("Both full and empty are True")

        # Count should be in valid range
        if count > self.depth:
            errors.append(f"count={count} exceeds depth={self.depth}")

        if errors:
            error_msg = f"Cycle {self.cycles} status error:\n  " + "\n  ".join(errors)
            self.errors.append(error_msg)
            cocotb.log.error(error_msg)

    def check_complete(self) -> None:
        """Check that no errors occurred."""
        if self.errors:
            raise AssertionError(
                f"StatusMonitor: {len(self.errors)} errors:\n" + "\n".join(self.errors)
            )


async def commit_monitor(
    dut: Any,
    expected_queue: deque[ExpectedCommit],
    check_value: bool = True,
) -> None:
    """Coroutine wrapper for CommitMonitor.

    For compatibility with existing test patterns.
    """
    monitor = CommitMonitor(dut, expected_queue, check_value)
    await monitor.run()


async def allocation_monitor(
    dut: Any,
    expected_queue: deque[tuple[bool, int]],
) -> None:
    """Coroutine wrapper for AllocationMonitor.

    For compatibility with existing test patterns.
    """
    monitor = AllocationMonitor(dut, expected_queue)
    await monitor.run()


async def status_monitor(dut: Any, depth: int = 32) -> None:
    """Coroutine wrapper for StatusMonitor.

    For compatibility with existing test patterns.
    """
    monitor = StatusMonitor(dut, depth)
    await monitor.run()
