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

"""Decoupled F0/F1, parcel storage, PD/ID, and decoded bundles for replay.

Structure follows if_stage.sv, fetch_pc_decoupled.sv and fetch_parcel_queue.sv.
Predictions come from the instruction capture, not from measured cycle gaps.
Only the architectural path has instruction semantics. On an incorrect
prediction, useful fetch waits for PD or execution recovery; wrong-path cache
pollution and execution contention are outside this approximation.
"""

from __future__ import annotations

from collections import Counter, deque
from collections.abc import Callable
from dataclasses import dataclass

from instruction_stream import Instruction

REDIRECT_PRIORITY = ("trap", "fence", "execute", "pd", "f1_tag", "f1_false_btb")


@dataclass(frozen=True)
class Parcel:
    """One halfword, carrying instruction and window ownership."""

    instruction: int
    half: int
    window: int
    last: bool = False


class ParcelQueue:
    """16 parcels / eight metadata records, with registered 8/7 stop thresholds."""

    def __init__(self) -> None:
        """Start with empty parcel and metadata rings."""
        self.parcels: deque[Parcel] = deque()
        self.stop = False
        self.max_parcels = 0
        self.max_metadata = 0

    @property
    def metadata_count(self) -> int:
        """A window remains live through its final parcel, including span tails."""
        return sum(p.last for p in self.parcels)

    def push(self, incoming: list[Parcel]) -> None:
        """Expose the arriving window to drain before registering occupancy."""
        if incoming:
            if len(incoming) > 4 or not incoming[-1].last:
                raise ValueError("a fetch push must end one window of 1..4 parcels")
            if len(self.parcels) + len(incoming) > 16 or self.metadata_count == 8:
                raise OverflowError("fetch parcel or metadata capacity exceeded")
            self.parcels.extend(incoming)

    def clock(self) -> None:
        """Register stop from occupancy after the simultaneous push and pop."""
        self.stop = len(self.parcels) >= 8 or self.metadata_count >= 7
        self.max_parcels = max(self.max_parcels, len(self.parcels))
        self.max_metadata = max(self.max_metadata, self.metadata_count)

    def flush(self) -> None:
        """Flush also clears the registered stop bit."""
        self.parcels.clear()
        self.stop = False


@dataclass
class FetchRequest:
    """Provider word tag and predictor snapshot travelling together in F1."""

    pc: int
    epoch: int
    cursor: tuple[int, int]
    parcels: list[Parcel]
    next_cursor: tuple[int, int]
    barrier: int | None
    data_cycle: int
    prediction_cycle: int
    served_pc: int
    collapsed: bool
    false_prediction: bool = False


class FetchFrontend:
    """A fetch cursor independent of decode and backend acceptance.

    ``provider_latency`` is launch-to-data availability (one cycle for BRAM).
    Predictor lookup takes one cycle concurrently. A miss holds its predictor
    result and consumes returning data immediately, as collapsed_armed_q does.
    ``redirect`` models the registered provider retarget, in addition to the
    ordinary F0/F1 and PD/ID stages; callers schedule execution feedback.
    """

    def __init__(
        self,
        program: list[Instruction],
        decoded_depth: int = 4,
        provider_latency: Callable[[int], int] | None = None,
    ) -> None:
        """Start an empty production front end at the stream's first PC."""
        if decoded_depth < 1:
            raise ValueError("instruction replay requires a decoded bundle queue")
        self.program = program
        self.decoded_depth = decoded_depth
        self.provider_latency = provider_latency or (lambda _pc: 1)
        self.queue = ParcelQueue()
        self.cursor = (0, 0)
        self.epoch = 0
        self.window = 0
        self.f1: FetchRequest | None = None
        self.barrier: int | None = None
        self.pd: tuple[Instruction, ...] = ()
        self.id: tuple[Instruction, ...] = ()
        self.decoded: deque[tuple[Instruction, ...]] = deque()
        self.retarget_until = 0
        self.redirects: list[tuple[str, int]] = []
        self.stats: Counter[str] = Counter()
        self.max_decoded = 0

    def request_redirect(self, kind: str, next_instruction: int) -> None:
        """Queue a redirect; arbitration follows fetch_pc_decoupled's arms 1..5."""
        if kind not in REDIRECT_PRIORITY:
            raise ValueError(f"unknown redirect class: {kind}")
        self.redirects.append((kind, next_instruction))

    def redirect(self, kind: str, target: int, cycle: int) -> None:
        """Apply a redirect, preserving older packets on PD/F1 recovery."""
        self.stats[f"redirect_{kind}"] += 1
        self.epoch += 1
        self.f1 = None
        self.cursor = (target, 0)
        self.barrier = None
        # F1 validation rejects the arriving window, not the older queue.
        if not kind.startswith("f1_"):
            self.queue.flush()
        if kind in {"trap", "fence", "execute"}:
            self.pd = self.id = ()
            self.decoded.clear()
        self.retarget_until = cycle + 1

    def _window(self, cycle: int) -> FetchRequest:
        index, half = self.cursor
        pc = self.program[index].pc + 2 * half
        end = (pc & ~3) + 8
        parcels: list[Parcel] = []
        barrier = None
        self.window += 1
        while index < len(self.program):
            insn = self.program[index]
            address = insn.pc + half * 2
            if address >= end:
                break
            parcels.append(Parcel(index, half, self.window))
            half += 1
            if half * 2 < insn.length:
                continue
            half = 0
            index += 1
            pred = insn.prediction
            if pred is not None:
                predicted_pc = (
                    pred.f0_target if pred.f0_taken else insn.pc + insn.length
                )
                if predicted_pc != insn.next_pc:
                    barrier = insn.index
                    break
                if pred.f0_taken:
                    self.stats["f0_taken"] += 1
                    break
            if index < len(self.program) and self.program[index].pc != address + 2:
                raise ValueError(
                    "stream changes PC without a taken prediction or recovery"
                )
        if not parcels:
            raise ValueError("empty fetch window")
        last = parcels[-1]
        parcels[-1] = Parcel(last.instruction, last.half, last.window, True)
        latency = self.provider_latency(pc)
        if latency < 1:
            raise ValueError("provider latency must be positive")
        return FetchRequest(
            pc,
            self.epoch,
            self.cursor,
            parcels,
            (index, half),
            barrier,
            cycle + latency,
            cycle + 1,
            pc & ~3,
            latency > 1,
        )

    def _drain(self) -> tuple[Instruction, ...]:
        bundle: list[Instruction] = []
        used = 0
        view = list(self.queue.parcels)[:4]
        while used < len(view) and len(bundle) < 2:
            p = view[used]
            insn = self.program[p.instruction]
            count = insn.length // 2
            if p.half != 0:
                raise AssertionError(
                    "drain lost the first parcel of a spanning instruction"
                )
            if used + count > len(view):
                break
            for half in range(count):
                other = view[used + half]
                if (other.instruction, other.half) != (insn.index, half):
                    raise AssertionError("noncontiguous instruction parcels")
            if bundle and insn.serializing:
                break
            bundle.append(insn)
            used += count
            if not insn.allows_pair:
                break
        for _ in range(used):
            self.queue.parcels.popleft()
        self.stats["drained_parcels"] += used
        return tuple(bundle)

    def step(self, cycle: int, decode_ready: bool = True) -> None:
        """Advance fetch every cycle; only drain and PD/ID obey decode stall."""
        if self.redirects:
            kind, target = min(
                self.redirects, key=lambda r: REDIRECT_PRIORITY.index(r[0])
            )
            self.redirects.clear()
            self.redirect(kind, target, cycle)
            return
        advance = decode_ready and len(self.decoded) < self.decoded_depth
        if advance:
            if self.id:
                self.decoded.append(self.id)
            self.id = self.pd
            self.pd = ()
            # A registered PD redirect does not discard its own branch or
            # older decoded work, but flushes younger fetch state.
            for insn in self.id:
                pred = insn.prediction
                if pred is not None and pred.pd_tier != "none":
                    self.redirect("pd", insn.index + 1, cycle)
                    self.stats[pred.pd_tier] += 1
                    if pred.execute_redirect:
                        self.barrier = insn.index
                    self.queue.clock()
                    return
        else:
            self.stats["decode_backpressure"] += 1
        stop = self.queue.stop
        before = len(self.queue.parcels)
        collapsed_accept = False
        if self.f1 is not None:
            req = self.f1
            if req.epoch != self.epoch:
                self.stats["stale_provider_reply"] += 1
                self.f1 = None
            elif cycle >= max(req.data_cycle, req.prediction_cycle):
                if req.served_pc != req.pc & ~3:
                    cursor = req.cursor
                    self.redirect("f1_tag", cursor[0], cycle)
                    self.cursor = cursor
                    self.stats["stale_provider_reply"] += 1
                    return
                # A collapsed lead waits for registered queue headroom.
                if not req.collapsed or not stop:
                    self.queue.push(req.parcels)
                    self.stats["windows"] += 1
                    collapsed_accept = req.collapsed
                    if collapsed_accept:
                        self.stats["refill_predictor_overlap"] += 1
                    self.f1 = None
                    if req.false_prediction:
                        # False fast-BTB hits still push the validated bytes,
                        # with prediction removed; only younger fetch resteers.
                        self.redirect("f1_false_btb", req.next_cursor[0], cycle)
                        self.cursor = req.next_cursor
                        if advance:
                            self.pd = self._drain()
                        self.queue.clock()
                        return
            else:
                self.stats["provider_wait"] += 1
        if advance:
            self.pd = self._drain()
            if self.pd and before == 0:
                self.stats["empty_bypass"] += 1
            elif self.pd and sum(i.length // 2 for i in self.pd) > before:
                self.stats["partial_bypass"] += 1
        if (
            self.f1 is None
            and not collapsed_accept
            and not stop
            and self.barrier is None
            and cycle >= self.retarget_until
            and self.cursor[0] < len(self.program)
        ):
            self.f1 = self._window(cycle)
            self.cursor = self.f1.next_cursor
            self.barrier = self.f1.barrier
            self.stats["f0_launches"] += 1
            if not advance:
                self.stats["run_ahead_launches"] += 1
        elif stop:
            self.stats["queue_backpressure"] += 1
        self.queue.clock()
        self.max_decoded = max(self.max_decoded, len(self.decoded))

    def consume(self, count: int) -> None:
        """Consume the backend's accepted prefix of the oldest decoded bundle."""
        bundle = self.decoded.popleft()
        if not 0 < count <= len(bundle):
            raise ValueError("invalid decoded bundle consumption")
        if count < len(bundle):
            self.decoded.appendleft(bundle[count:])

    def summary(self) -> dict[str, object]:
        """Expose occupancy and causally counted front-end stalls."""
        return {
            "stats": dict(self.stats),
            "max_parcels": self.queue.max_parcels,
            "max_metadata": self.queue.max_metadata,
            "max_decoded": self.max_decoded,
        }
