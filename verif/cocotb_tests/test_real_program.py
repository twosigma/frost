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

"""Run complete programs on the simulated CPU and memories.

The test watches the CPU's UART output for success and failure markers:
- Test programs print "<<PASS>>" on success or "<<FAIL>>" on failure.
- hello_world passes once it prints "Hello, world!".
- CoreMark builds with ITERATIONS=1 in simulation and must print "<<PASS>>".

By default each program runs twice with a reset between runs to check that it
tolerates reset and reinitializes all state.
"""

import os
import random
from pathlib import Path
import re
from collections import Counter
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge
from cocotb.utils import get_sim_time
from typing import Any, TextIO

from config import XLEN
from cocotb_tests.cpu_structs import COMMIT_FIELDS, ID_TO_EX_FIELDS

CLK_PERIOD_NS = 3
UART_BAUD_RATE = 115200
UART_DATA_BITS = 8
CHECKPOINT_TRACE_WIDTH = 8
UART_CLK_FREQ_HZ_DEFAULT = 322_265_625
UART_RX_DATA_MMIO_ADDR = 0x4000_0004
UART_RX_STATUS_MMIO_ADDR = 0x4000_0024
# mcause bit XLEN-1 marks an interrupt.
MCAUSE_INTERRUPT_BIT = 1 << (XLEN - 1)
# High in the cycle a mispredicted branch retires at the ROB head and starts
# commit-time recovery; a branch that early recovery already redirected at
# execute does not raise it.
COMMIT_MISPREDICTION_PATH = (
    "cpu_and_memory_subsystem.cpu_inst.misprediction_flush_controller_inst."
    "commit_is_misprediction"
)

# Success/failure markers that programs print
PASS_MARKER = "<<PASS>>"
FAIL_MARKER = "<<FAIL>>"

_OBJDUMP_RE = re.compile(r"^\s*([0-9a-f]+):\s+([0-9a-f ]+)\s+\s*.*$")


def _load_symbol_machine_code(
    symbol_name: str, app_name: str | None = None
) -> dict[int, tuple[int, int]]:
    """Load raw instruction words for a symbol from the compiled app objdump."""
    sw_s_path: Path | None = None

    sw_mem_path = Path("sw.mem")
    if sw_mem_path.is_symlink():
        sw_s_candidate = sw_mem_path.resolve().with_name("sw.S")
        if sw_s_candidate.exists():
            sw_s_path = sw_s_candidate

    if sw_s_path is None and app_name is not None:
        repo_root = Path(__file__).resolve().parents[2]
        sw_s_candidate = repo_root / "sw" / "apps" / app_name / "sw.S"
        if sw_s_candidate.exists():
            sw_s_path = sw_s_candidate

    if sw_s_path is None:
        return {}

    expected: dict[int, tuple[int, int]] = {}
    inside_symbol = False
    with sw_s_path.open() as sw_s_file:
        for line in sw_s_file:
            if f"<{symbol_name}>:" in line:
                inside_symbol = True
                continue
            if inside_symbol and re.match(r"^[0-9a-f]+ <.*>:$", line):
                break
            if not inside_symbol:
                continue
            match = _OBJDUMP_RE.match(line)
            if match is None:
                continue
            addr = int(match.group(1), 16)
            insn_hex = match.group(2).replace(" ", "")
            if len(insn_hex) not in {4, 8}:
                continue
            expected[addr] = (int(insn_hex, 16), 16 if len(insn_hex) == 4 else 32)

    return expected


def _load_symbol_ranges(
    symbol_names: list[str], app_name: str | None = None
) -> dict[str, tuple[int, int]]:
    """Load half-open [start, end) address ranges for symbols from sw.S."""
    sw_s_path: Path | None = None

    sw_mem_path = Path("sw.mem")
    if sw_mem_path.is_symlink():
        sw_s_candidate = sw_mem_path.resolve().with_name("sw.S")
        if sw_s_candidate.exists():
            sw_s_path = sw_s_candidate

    if sw_s_path is None and app_name is not None:
        repo_root = Path(__file__).resolve().parents[2]
        sw_s_candidate = repo_root / "sw" / "apps" / app_name / "sw.S"
        if sw_s_candidate.exists():
            sw_s_path = sw_s_candidate

    if sw_s_path is None:
        return {}

    wanted = set(symbol_names)
    symbol_starts: dict[str, int] = {}
    ordered_symbols: list[tuple[str, int]] = []
    symbol_header_re = re.compile(r"^([0-9a-f]+) <([^>]+)>:$")

    with sw_s_path.open() as sw_s_file:
        for line in sw_s_file:
            match = symbol_header_re.match(line.strip())
            if match is None:
                continue
            symbol_addr = int(match.group(1), 16)
            symbol_name = match.group(2)
            ordered_symbols.append((symbol_name, symbol_addr))
            if symbol_name in wanted:
                symbol_starts[symbol_name] = symbol_addr

    symbol_ranges: dict[str, tuple[int, int]] = {}
    for idx, (symbol_name, symbol_addr) in enumerate(ordered_symbols):
        if symbol_name not in wanted:
            continue
        end_addr = 0xFFFF_FFFF
        if idx + 1 < len(ordered_symbols):
            end_addr = ordered_symbols[idx + 1][1]
        symbol_ranges[symbol_name] = (symbol_addr, end_addr)

    return symbol_ranges


async def generate_divided_clock(dut: Any) -> None:
    """Generate i_clk_div4 as a 4:1 divided clock from i_clk.

    The dc_fifo clock domain crossing assumes both clocks come from one source
    (an MMCM on hardware) and crosses binary pointers without Gray coding, so
    the two clocks must keep a fixed phase relationship. Toggling i_clk_div4
    every second rising edge of i_clk gives a clock with four times the period
    whose rising edges always coincide with rising edges of i_clk.
    """
    counter = 0
    dut.i_clk_div4.value = 0
    while True:
        await RisingEdge(dut.i_clk)
        counter += 1
        if counter == 2:
            counter = 0
            dut.i_clk_div4.value = 0 if int(dut.i_clk_div4.value) else 1


# The NIC's MAC clock period (frost.sv i_nic_tx_clk and i_nic_rx_clk): 1.75
# core periods (5.25 ns against the 3 ns core clock), unrelated to the core
# clock. The X3 build clocks the MAC from its transceiver at 161.13 MHz.
NIC_MAC_CLK_PERIOD_PS = 2 * int(CLK_PERIOD_NS * 875)


def start_nic_mac_clocks(dut: Any) -> None:
    """Start both NIC MAC clocks with identical edges and drive the PHY levels.

    frost.sv builds the NIC's raw loopback (RAW_LOOPBACK = 1), which feeds the
    raw TX word into the RX PCS with no crossing logic, so the TX and RX
    clocks must be one clock: both start in the same step with one period,
    and check_nic_mac_clocks_aligned, run from each clock toward the other,
    confirms they toggle together. The port defaults in frost.sv apply to
    instantiations that omit the ports, not to a simulation top, so every
    level is driven here: both clocks present, PHY status "clock shared,
    transceiver ready", no wire (the raw loopback carries frames for
    nic_loopback; nic_echo's peer drives the wire).
    """
    for mac_clock in (dut.i_nic_tx_clk, dut.i_nic_rx_clk):
        Clock(mac_clock, NIC_MAC_CLK_PERIOD_PS, unit="ps").start()
    dut.i_nic_tx_clk_ok.value = 1
    dut.i_nic_rx_clk_ok.value = 1
    dut.i_nic_phy_status.value = 0b01111
    dut.i_nic_rx_raw_data.value = 0
    dut.i_nic_rx_raw_valid.value = 0
    dut.i_nic_rx_signal_ok.value = 0
    cocotb.start_soon(check_nic_mac_clocks_aligned(dut.i_nic_tx_clk, dut.i_nic_rx_clk))
    cocotb.start_soon(check_nic_mac_clocks_aligned(dut.i_nic_rx_clk, dut.i_nic_tx_clk))


async def check_nic_mac_clocks_aligned(
    watched: Any, other: Any, cycles: int = 16
) -> None:
    """Fail unless the other clock changes in the same evaluation as the watched one.

    An edge callback runs after the evaluation that moved the watched clock,
    so a clock that moves in a later evaluation of the same step still reads
    its old level here. Run once from each clock, the pair also catches a
    clock that moves in an earlier evaluation. Both clocks have a fixed
    period, so the first cycles decide.
    """
    for _ in range(cycles):
        for edge, level in ((RisingEdge, 1), (FallingEdge, 0)):
            await edge(watched)
            other_level = int(other.value)
            assert other_level == level, (
                f"one NIC MAC clock is {other_level} at the other's edge to "
                f"{level}: the raw loopback needs one clock edge for both "
                "directions"
            )


# Cycle cap per run, so a hung program fails instead of running forever.
# COCOTB_MAX_CYCLES raises it for tests that need more (e.g. the arch tests).
MAX_CYCLES = int(os.environ.get("COCOTB_MAX_CYCLES", 500000))

# Number of runs (reset-and-rerun cycles) per test invocation. The default of 2
# checks that programs survive a reset and rerun.
# Set to 1 for ISA tests that modify .text-resident data (e.g. riscv-tests rvc).
NUM_RUNS = int(os.environ.get("COCOTB_NUM_RUNS", 2))

# CoreMark-style benchmarks run the real benchmark body even with ITERATIONS=1.
# The memory-heavy list and matrix phases exceed the generic program budget,
# so they get a larger default with an env override.
COREMARK_MAX_CYCLES = int(os.environ.get("COCOTB_COREMARK_MAX_CYCLES", 15000000))
# nic_loopback and nic_echo share this budget. Each bring-up waits out the
# PCS's BER window before CARRIER (about 35k cycles at the simulated clock
# ratio), frames are checked or copied byte by byte, and nic_loopback also
# resets the NIC with traffic in flight.
NIC_LOOPBACK_MAX_CYCLES = int(os.environ.get("COCOTB_NIC_LOOPBACK_MAX_CYCLES", 1500000))

# sprintf_test's FP formatting cases need more than the generic budget.
SPRINTF_TEST_MAX_CYCLES = 2000000

# Cover the complete lookup/cache-churn and store-forwarding sweep.
PDE_RETURN_HAZARD_MAX_CYCLES = 2000000

# The 3000-iteration sweep includes DDR cold-fetch and per-tick latency.
WFI_LOST_TICK_MAX_CYCLES = 800000

# Cover 800 restore-window iterations with cold-DDR frame eviction.
RESTORE_WINDOW_STRESS_MAX_CYCLES = 1000000

# DDR boot and BSS clearing exceed the generic budget before the first banner.
# This budget also covers the jitter variant.
AMO_IRQ_TORTURE_MAX_CYCLES = int(
    os.environ.get("COCOTB_AMO_TORTURE_MAX_CYCLES", 6000000)
)

# Cover DDR BSS clearing and the simulation-scale timer-torture workset.
TICK_TORTURE_MAX_CYCLES = int(os.environ.get("COCOTB_TICK_TORTURE_MAX_CYCLES", 6000000))

# mem_divergence_probe sweeps evict/refill rounds over cached DDR; the
# registry entries pin a sim-scale round count via EXTRA_CFLAGS, and this
# budget covers it with headroom (the app prints <<PASS>>/<<FAIL>> itself).
MEM_DIVERGENCE_PROBE_MAX_CYCLES = int(
    os.environ.get("COCOTB_MEM_DIVERGENCE_PROBE_MAX_CYCLES", 20000000)
)

# i_clk cycles to hold i_rst_n low, before the first run and between runs.
# frost.sv needs at least 20 (five i_clk_div4 cycles) so that each dual-clock
# FIFO applies reset on its i_clk_div4 side while its i_clk side is still held.
RESET_CYCLES = 20


class UartMonitor:
    """Monitor UART output from the CPU and collect characters."""

    def __init__(self, dut: Any) -> None:
        """Initialize the UART monitor with the DUT handle."""
        self.dut = dut
        self.output_buffer = ""
        self._running = True

    async def start(self) -> None:
        """Start monitoring UART output in the background."""
        cocotb.start_soon(self._monitor_uart())

    def stop(self) -> None:
        """Stop the monitor."""
        self._running = False

    def clear(self) -> None:
        """Clear the output buffer for a new run."""
        self.output_buffer = ""

    async def _monitor_uart(self) -> None:
        """Monitor UART write signals and collect characters."""
        while self._running:
            await RisingEdge(self.dut.i_clk)
            try:
                uart_wr_en = self.dut.cpu_and_memory_subsystem.o_uart_wr_en.value
                if uart_wr_en.is_resolvable and uart_wr_en == 1:
                    uart_data = self.dut.cpu_and_memory_subsystem.o_uart_wr_data.value
                    if uart_data.is_resolvable:
                        char = chr(int(uart_data))
                        self.output_buffer += char
                        print(char, end="", flush=True)
            except AttributeError:
                # The UART signals may be optimized out in some simulators.
                pass

    def contains(self, text: str) -> bool:
        """Check if the output buffer contains the given text."""
        return text in self.output_buffer

    def get_output(self) -> str:
        """Get the complete output buffer."""
        return self.output_buffer


def _get_signal(dut: Any, path: str) -> Any | None:
    """Get a nested signal by dotted path, or None if not found."""
    obj = dut
    for part in path.split("."):
        if not hasattr(obj, part):
            return None
        obj = getattr(obj, part)
    return obj


def _first_signal(dut: Any, paths: list[str]) -> Any | None:
    """Return the first resolvable signal from a list of dotted paths."""
    for path in paths:
        sig = _get_signal(dut, path)
        if sig is not None:
            return sig
    return None


def _read_int(signal: Any) -> int | None:
    """Read a signal as int, return None if not resolvable."""
    if signal is None:
        return None
    if isinstance(signal, int):
        return signal
    try:
        value = signal.value
    except AttributeError:
        return None
    if value.is_resolvable:
        return int(value)
    return None


def _read_bool(signal: Any) -> bool | None:
    """Read a signal as bool, return None if not resolvable."""
    value = _read_int(signal)
    if value is None:
        return None
    return bool(value)


def _require_signals(check: str, handles: dict[str, Any]) -> None:
    """Fail an opt-in check whose signal handles did not all resolve.

    Args:
        check: The environment variable that enabled the check
        handles: Signal path to the handle _get_signal returned for it

    Raises:
        AssertionError: If any handle is None.
    """
    missing = sorted(path for path, handle in handles.items() if handle is None)
    if missing:
        raise AssertionError(
            f"{check} needs signals this build does not expose: {', '.join(missing)}"
        )


class _PackedStruct:
    """Named fields of a packed struct, read through its whole-vector handle.

    Verilator's VPI exposes a packed struct as one vector, with no handles for
    its members. The layout is a cocotb_tests.cpu_structs list of (name,
    width) pairs, MSB first, and its widths must add up to the vector's width.
    """

    def __init__(self, handle: Any, layout: list[tuple[str, int]], path: str) -> None:
        """Map each field to its bit slice, checking the layout's total width."""
        total = sum(width for _, width in layout)
        if len(handle) != total:
            raise AssertionError(
                f"{path} is {len(handle)} bits wide, but its cpu_structs layout "
                f"adds up to {total}"
            )
        self.handle = handle
        self.slices: dict[str, tuple[int, int]] = {}
        for name, width in layout:
            total -= width
            self.slices[name] = (total, (1 << width) - 1)

    def read(self) -> int | None:
        """Return the whole struct as an int, or None if unresolvable."""
        return _read_int(self.handle)

    def field(self, packed: int, name: str) -> int:
        """Extract one field from a value that read() returned."""
        lsb, mask = self.slices[name]
        return (packed >> lsb) & mask


def _packed_struct(
    dut: Any, path: str, layout: list[tuple[str, int]], check: str
) -> _PackedStruct:
    """Look up a packed-struct signal that an opt-in check needs.

    Raises:
        AssertionError: If the signal is missing or its width does not
            match the layout.
    """
    handle = _get_signal(dut, path)
    _require_signals(check, {path: handle})
    return _PackedStruct(handle, layout, path)


async def ddr_write_watch(dut: Any) -> None:
    """Log every behavioral-DDR line write landing in a watched window.

    Enabled by FROST_DDR_WATCH_LO/FROST_DDR_WATCH_HI (hex, region-relative
    model addresses: absolute 0x8xxxxxxx minus 0x80000000). Each AW address is
    queued on the AW handshake and paired with the next W beat; in-window beats
    log sim time, the line address (relative and absolute), the strobe mask,
    and the full line data. Debug instrumentation only: match a logged
    timestamp against a retire trace to see what the core was running when
    the line reached DDR.
    """
    lo = int(os.environ.get("FROST_DDR_WATCH_LO", "0"), 16)
    hi = int(os.environ.get("FROST_DDR_WATCH_HI", "0"), 16)
    if hi <= lo:
        return
    base = "cpu_and_memory_subsystem.gen_cached_tier.gen_behavioral_ddr.ddr_model"
    awv = _get_signal(dut, f"{base}.i_axi_awvalid")
    awr = _get_signal(dut, f"{base}.o_axi_awready")
    awa = _get_signal(dut, f"{base}.i_axi_awaddr")
    wv = _get_signal(dut, f"{base}.i_axi_wvalid")
    wr = _get_signal(dut, f"{base}.o_axi_wready")
    wd = _get_signal(dut, f"{base}.i_axi_wdata")
    ws = _get_signal(dut, f"{base}.i_axi_wstrb")
    if None in (awv, awr, awa, wv, wr, wd, ws):
        cocotb.log.warning("ddr_write_watch: model signals not resolvable; disabled")
        return
    cocotb.log.info(f"ddr_write_watch: armed for [{lo:#x}, {hi:#x}) (region-relative)")
    pending: list[int] = []
    hits = 0
    while True:
        await RisingEdge(dut.i_clk)
        if _read_bool(awv) and _read_bool(awr):
            addr = _read_int(awa) or 0
            pending.append(addr)
        if _read_bool(wv) and _read_bool(wr) and pending:
            addr = pending.pop(0)
            if lo <= addr < hi:
                hits += 1
                data = _read_int(wd) or 0
                strb = _read_int(ws) or 0
                cocotb.log.info(
                    f"DDRWATCH t={get_sim_time('ns')} "
                    f"addr={addr:#010x} abs={addr + 0x80000000:#010x} "
                    f"strb={strb:#010x} data={data:#066x}"
                )
                if hits > 4000:
                    cocotb.log.warning("ddr_write_watch: hit cap reached; muting")
                    return


async def l0_hit_watch(dut: Any) -> None:
    """Log every L0 fast-path hit served inside a watched absolute window.

    Enabled by FROST_L0_WATCH_LO/FROST_L0_WATCH_HI (hex, absolute addresses).
    Pairs with ddr_write_watch: joining the two logs offline tracks the
    window's DDR contents over time and can expose a hit that returned stale
    data.
    """
    lo = int(os.environ.get("FROST_L0_WATCH_LO", "0"), 16)
    hi = int(os.environ.get("FROST_L0_WATCH_HI", "0"), 16)
    if hi <= lo:
        return
    lq = "cpu_and_memory_subsystem.cpu_inst.u_tomasulo.u_lq"
    hit = _get_signal(dut, f"{lq}.cache_hit_fast_path")
    addr = _get_signal(dut, f"{lq}.u_l0_cache.i_lookup_addr")
    data = _get_signal(dut, f"{lq}.u_l0_cache.o_lookup_data")
    if None in (hit, addr, data):
        cocotb.log.warning("l0_hit_watch: signals not resolvable; disabled")
        return
    cocotb.log.info(f"l0_hit_watch: armed for [{lo:#x}, {hi:#x}) (absolute)")
    hits = 0
    while True:
        await RisingEdge(dut.i_clk)
        if _read_bool(hit):
            a = _read_int(addr) or 0
            if lo <= a < hi:
                hits += 1
                d = _read_int(data) or 0
                cocotb.log.info(
                    f"L0HIT t={get_sim_time('ns')} addr={a:#010x} data={d:#018x}"
                )
                if hits > 6000:
                    cocotb.log.warning("l0_hit_watch: hit cap reached; muting")
                    return


async def wedge_monitor(dut: Any, uart_monitor: "UartMonitor | None") -> None:
    """Sample trap, MRET, flush, IRQ, and store-drain state to debug a hang.

    Enabled with FROST_WEDGE_MONITOR=1. Samples the state every clock and
    emits an aggregated snapshot every FROST_WEDGE_DUMP_INTERVAL cycles
    (default 2000). It also logs a one-shot "STALL DETECTED" banner once UART
    output stops advancing for FROST_WEDGE_STALL_CYCLES cycles (default 20000),
    and it stops logging after FROST_WEDGE_POST_STALL_DUMPS (default 16)
    snapshots taken while UART is stalled (the simulation keeps running to the
    cycle cap).

    Taps whose signals do not resolve read as 0 (1-bit) or print as None
    (multi-bit), and the armed log line names the missing bool_sig and val_sig
    taps. The monitor drives no signals.
    """
    dump_interval = int(os.environ.get("FROST_WEDGE_DUMP_INTERVAL", "2000"))
    stall_cycles = int(os.environ.get("FROST_WEDGE_STALL_CYCLES", "20000"))
    post_stall_dump_limit = int(os.environ.get("FROST_WEDGE_POST_STALL_DUMPS", "16"))

    def g(path: str) -> Any:
        return _get_signal(dut, path)

    cpu = "cpu_and_memory_subsystem.cpu_inst"
    mem = "cpu_and_memory_subsystem"

    # 1-bit signals: aggregated as cycles-high + 0->1 edge counts per interval.
    bool_sig = {
        "trap_taken": g(f"{cpu}.trap_taken"),
        "trap_taken_reg": _first_signal(
            dut, [f"{cpu}.trap_taken_reg", f"{cpu}.dbg_trap_taken_q"]
        ),
        "mret_taken": g(f"{cpu}.mret_taken"),
        "mret_taken_reg": g(f"{cpu}.mret_taken_reg"),
        "flush_all": g(f"{cpu}.flush_all"),
        "flush_en": g(f"{cpu}.flush_en"),
        "trap_pending": g(f"{cpu}.trap_pending"),
        "mret_start": g(f"{cpu}.mret_start"),
        "trap_drain_wait": g(f"{cpu}.trap_drain_wait"),
        "sq_committed_empty": g(f"{cpu}.sq_committed_empty"),
        "commit_hold_q": g(f"{cpu}.trap_mret_commit_hold_q"),
        "mispredict_recovery_pending": g(f"{cpu}.mispredict_recovery_pending"),
        "interrupt_pending": g(f"{cpu}.interrupt_pending"),
        "csr_mstatus_mie_direct": g(f"{cpu}.csr_mstatus_mie_direct"),
        "rob_head_is_wfi": g(f"{cpu}.rob_head_is_wfi"),
        "head_valid": g(f"{cpu}.head_valid"),
        "dbg_commit_valid": g(f"{cpu}.dbg_commit_valid"),
        # CLINT / store-drain taps live in the cpu_and_mem parent scope.
        "mtip_registered": g(f"{mem}.mtip_registered"),
        "mtip_comparison": g(f"{mem}.mtip_comparison"),
        "mtimecmp_write_pulse": g(f"{mem}.mtimecmp_write_pulse"),
        "cached_write_inflight": g(f"{mem}.data_memory_cached_write_inflight"),
    }
    # Load-address taps: show which addresses the core reads while it spins,
    # which separates a clobbered base register from a lost store.
    mem_addr_sig = g(f"{cpu}.o_data_mem_addr")
    mem_rd_en_sig = g(f"{cpu}.o_data_mem_read_enable")
    mem_cached_rd_en_sig = g(f"{cpu}.o_data_mem_cached_read_enable")

    # Multi-bit signals: sampled at dump time (steady-state snapshot value).
    val_sig = {
        "dbg_commit_pc": g(f"{cpu}.dbg_commit_pc"),
        "head_pc": g(f"{cpu}.u_tomasulo.u_rob.head_pc"),
        "head_idx": g(f"{cpu}.u_tomasulo.u_rob.head_idx"),
        "sq_count": g(f"{cpu}.sq_count"),
        "rob_count": g(f"{cpu}.rob_count"),
        "csr_priv": g(f"{cpu}.csr_priv"),
        "csr_mstatus": g(f"{cpu}.csr_mstatus"),
        "csr_mie": g(f"{cpu}.csr_mie"),
        "csr_mepc": g(f"{cpu}.csr_mepc"),
        "resume_pc": _first_signal(
            dut,
            [f"{cpu}.dbg_interrupt_resume_pc", f"{cpu}.interrupt_resume_pc"],
        ),
        "o_pc": g(f"{cpu}.o_pc"),
        "mtime": g(f"{mem}.mtime"),
        "mtimecmp": g(f"{mem}.mtimecmp"),
    }

    missing = sorted(k for k, v in {**bool_sig, **val_sig}.items() if v is None)
    cocotb.log.info(
        f"WEDGE monitor armed: dump_interval={dump_interval} "
        f"stall_cycles={stall_cycles} post_stall_dumps={post_stall_dump_limit} "
        f"missing_taps={missing}"
    )

    bool_keys = list(bool_sig.keys())
    hi = {k: 0 for k in bool_keys}
    edges = {k: 0 for k in bool_keys}
    prev = {k: 0 for k in bool_keys}
    head_pc_ctr: Counter[int] = Counter()
    commit_pc_ctr: Counter[int] = Counter()
    read_addr_ctr: Counter[int] = Counter()
    commit_count = 0
    interval_start = 0

    def hx(name: str) -> str:
        v = _read_int(val_sig.get(name))
        return "None" if v is None else f"0x{v:08x}"

    def hx64(name: str) -> str:
        v = _read_int(val_sig.get(name))
        return "None" if v is None else f"0x{v:016x}"

    def iv(name: str) -> str:
        v = _read_int(val_sig.get(name))
        return "None" if v is None else str(v)

    def topn(ctr: Counter[int], n: int = 5) -> str:
        if not ctr:
            return "{}"
        return "{" + ", ".join(f"0x{pc:08x}:{c}" for pc, c in ctr.most_common(n)) + "}"

    def emit(mc: int, length: int, stalled: bool, uart_len: int) -> None:
        committed_pending = length - hi["sq_committed_empty"]
        cocotb.log.info(
            f"WEDGE mc={mc} ilen={length} stalled={stalled} uart_len={uart_len}\n"
            f"  COMMIT: valid_cyc={hi['dbg_commit_valid']} commits={commit_count} "
            f"distinct_pc={len(commit_pc_ctr)} top={topn(commit_pc_ctr)} o_pc={hx('o_pc')}\n"
            f"  HEAD: head_valid_cyc={hi['head_valid']} distinct_head_pc={len(head_pc_ctr)} "
            f"top={topn(head_pc_ctr)} head_idx={iv('head_idx')} wfi_cyc={hi['rob_head_is_wfi']} "
            f"rob_count={iv('rob_count')} sq_count={iv('sq_count')}\n"
            f"  LOAD: read_addrs={topn(read_addr_ctr)}\n"
            f"  FLUSH: flush_all_hi={hi['flush_all']} flush_en_hi={hi['flush_en']} "
            f"trap_taken(hi={hi['trap_taken']},edges={edges['trap_taken']}) "
            f"trap_taken_reg_hi={hi['trap_taken_reg']} "
            f"mret_taken(hi={hi['mret_taken']},edges={edges['mret_taken']}) "
            f"mret_taken_reg_hi={hi['mret_taken_reg']} "
            f"mispred_recov_hi={hi['mispredict_recovery_pending']}\n"
            f"  GATE: trap_pending_hi={hi['trap_pending']} mret_start_hi={hi['mret_start']} "
            f"drain_wait_hi={hi['trap_drain_wait']} commit_hold_hi={hi['commit_hold_q']} "
            f"sq_committed_pending_cyc={committed_pending} "
            f"cached_inflight_hi={hi['cached_write_inflight']}\n"
            f"  IRQ: int_pending_hi={hi['interrupt_pending']} mtip_reg_hi={hi['mtip_registered']} "
            f"mtip_cmp_hi={hi['mtip_comparison']} mtimecmp_writes={hi['mtimecmp_write_pulse']} "
            f"mtime={hx64('mtime')} mtimecmp={hx64('mtimecmp')}\n"
            f"  CSR: priv={iv('csr_priv')} mstatus={hx('csr_mstatus')} mie={hx('csr_mie')} "
            f"mstatus_mie_hi={hi['csr_mstatus_mie_direct']} mepc={hx('csr_mepc')} "
            f"resume_pc={hx('resume_pc')}"
        )

    def reset_interval(mc: int) -> None:
        nonlocal commit_count, interval_start
        for k in bool_keys:
            hi[k] = 0
            edges[k] = 0
        head_pc_ctr.clear()
        commit_pc_ctr.clear()
        read_addr_ctr.clear()
        commit_count = 0
        interval_start = mc

    mc = 0
    last_uart_len = 0
    last_uart_change = 0
    stall_announced = False
    post_stall_dumps = 0

    while True:
        await RisingEdge(dut.i_clk)
        mc += 1
        for k in bool_keys:
            raw = _read_int(bool_sig[k])
            v = 1 if raw else 0
            hi[k] += v
            if v and not prev[k]:
                edges[k] += 1
            prev[k] = v
        if prev["head_valid"] and len(head_pc_ctr) < 256:
            hp = _read_int(val_sig["head_pc"])
            if hp is not None:
                head_pc_ctr[hp] += 1
        if prev["dbg_commit_valid"]:
            cp = _read_int(val_sig["dbg_commit_pc"])
            if cp is not None:
                commit_count += 1
                if len(commit_pc_ctr) < 256:
                    commit_pc_ctr[cp] += 1
        rd = _read_int(mem_rd_en_sig)
        crd = _read_int(mem_cached_rd_en_sig)
        if (rd or crd) and len(read_addr_ctr) < 256:
            ra = _read_int(mem_addr_sig)
            if ra is not None:
                read_addr_ctr[ra] += 1

        uart_len = len(uart_monitor.get_output()) if uart_monitor is not None else 0
        if uart_len != last_uart_len:
            last_uart_len = uart_len
            last_uart_change = mc
        stalled = (mc - last_uart_change) >= stall_cycles
        if stalled and not stall_announced:
            cocotb.log.info(
                f"WEDGE STALL DETECTED at mc={mc}: no UART progress for "
                f"{stall_cycles} cycles (uart_len={uart_len})"
            )
            stall_announced = True

        if mc % dump_interval == 0:
            emit(mc, mc - interval_start, stalled, uart_len)
            if stalled:
                post_stall_dumps += 1
                if post_stall_dumps >= post_stall_dump_limit:
                    cocotb.log.info(
                        "WEDGE monitor: post-stall snapshot budget reached; "
                        "stopping further logging (sim continues to cap)."
                    )
                    return
            reset_interval(mc)


class UartRxDriver:
    """Drive UART RX serial input to the DUT (8N1)."""

    def __init__(self, dut: Any) -> None:
        """Initialize UART RX driver."""
        self.dut = dut
        if not hasattr(dut, "i_uart_rx"):
            raise RuntimeError("UART RX signal not found on DUT")
        if not hasattr(dut, "i_clk_div4"):
            raise RuntimeError("UART RX driver requires i_clk_div4 on DUT")
        self.bit_cycles = self._compute_bit_cycles()
        # Idle high
        self.dut.i_uart_rx.value = 1

    def _compute_bit_cycles(self) -> int:
        """Match uart_rx.sv prescaler math to compute cycles per bit.

        uart_rx uses CLK_FREQ_HZ/4 (since it runs on clk_div4) and computes:
        ClockCyclesPerBit = (CLK_FREQ_HZ/4) / BAUD_RATE.
        """
        clk_freq = _read_u64(getattr(self.dut, "CLK_FREQ_HZ", None))
        if clk_freq is None:
            clk_freq = UART_CLK_FREQ_HZ_DEFAULT
        uart_clk_freq = clk_freq // 4
        bit_cycles = uart_clk_freq // UART_BAUD_RATE
        cocotb.log.info(
            f"UartRxDriver: clk_freq={clk_freq}, uart_clk_freq={uart_clk_freq}, "
            f"bit_cycles={bit_cycles}"
        )
        return max(1, bit_cycles)

    async def _wait_cycles(self, cycles: int) -> None:
        """Wait for a number of i_clk_div4 cycles."""
        for _ in range(cycles):
            await RisingEdge(self.dut.i_clk_div4)

    async def _wait_bit_edges(self, cycles: int) -> None:
        """Wait bit-time cycles using the non-sampling edge for UART transitions."""
        for _ in range(cycles):
            await FallingEdge(self.dut.i_clk_div4)

    async def send_byte(self, value: int) -> None:
        """Send a single byte over UART RX (LSB first)."""
        await FallingEdge(self.dut.i_clk_div4)
        # Start bit
        self.dut.i_uart_rx.value = 0
        await self._wait_bit_edges(self.bit_cycles)
        # Data bits
        for bit in range(UART_DATA_BITS):
            self.dut.i_uart_rx.value = (value >> bit) & 0x1
            await self._wait_bit_edges(self.bit_cycles)
        # Stop bit
        self.dut.i_uart_rx.value = 1
        await self._wait_bit_edges(self.bit_cycles)

    async def send(self, data: bytes, inter_byte_cycles: int = 0) -> None:
        """Send a byte string over UART RX."""
        # Hold the line idle for four bit times first so the receiver can
        # resynchronize after any glitch.
        self.dut.i_uart_rx.value = 1
        await self._wait_cycles(self.bit_cycles * 4)
        for byte in data:
            await self.send_byte(byte)
            if inter_byte_cycles > 0:
                await self._wait_cycles(inter_byte_cycles)


async def wait_for_uart_text(
    dut: Any,
    uart_monitor: UartMonitor,
    text: str,
    max_cycles: int,
    start_index: int = 0,
) -> None:
    """Wait until UART output contains text after start_index."""
    for cycle in range(max_cycles):
        await RisingEdge(dut.i_clk)
        if text in uart_monitor.get_output()[start_index:]:
            return
    raise AssertionError(
        f"Timed out waiting for UART text '{text}' within {max_cycles} cycles"
    )


def _read_u64(signal: Any) -> int | None:
    """Read a 64-bit counter from a cocotb signal, return None if not resolvable."""
    if signal is None:
        return None
    if isinstance(signal, int):
        return signal
    try:
        value = signal.value
    except AttributeError:
        return None
    if value.is_resolvable:
        return int(value)
    return None


class UartMmioDebugMonitor:
    """Capture MMIO/UART RX activity for debugging uart_echo."""

    def __init__(self, dut: Any, max_events: int = 200) -> None:
        """Initialize the debug monitor with the DUT and event buffer size."""
        self.dut = dut
        self.max_events = max_events
        self.events: list[str] = []
        self._running = True
        self.cycle = 0
        self.count_mmio_status = 0
        self.count_mmio_data = 0
        self.count_uart_ready = 0
        self.count_uart_valid_rise = 0

        # Try multiple paths in case of optimizer differences
        self.mmio_read_pulse = _first_signal(
            dut,
            [
                "cpu_and_memory_subsystem.cpu_inst.o_mmio_read_pulse",
                "cpu_and_memory_subsystem.mmio_read_pulse",
            ],
        )
        self.mmio_load_addr = _first_signal(
            dut,
            [
                "cpu_and_memory_subsystem.cpu_inst.o_mmio_load_addr",
                "cpu_and_memory_subsystem.mmio_load_addr",
            ],
        )
        self.mmio_load_valid = _first_signal(
            dut,
            [
                "cpu_and_memory_subsystem.cpu_inst.o_mmio_load_valid",
                "cpu_and_memory_subsystem.mmio_load_valid",
            ],
        )
        self.uart_rx_ready = _get_signal(
            dut, "cpu_and_memory_subsystem.o_uart_rx_ready"
        )
        self.uart_rx_valid = _get_signal(
            dut, "cpu_and_memory_subsystem.i_uart_rx_valid"
        )
        self.uart_rx_data = _get_signal(dut, "cpu_and_memory_subsystem.i_uart_rx_data")
        # Top-level UART RX CDC signals (inside frost)
        self.uart_rx_ready_top = _get_signal(dut, "uart_rx_data_ready_from_cpu")
        self.uart_rx_valid_top = _get_signal(dut, "uart_rx_data_valid_to_cpu")
        self.uart_rx_data_top = _get_signal(dut, "uart_rx_data_to_cpu")
        # uart_rx module signals (before CDC FIFO)
        self.uart_rx_module_valid = _get_signal(dut, "uart_receiver.o_valid")
        self.uart_rx_module_data = _get_signal(dut, "uart_receiver.o_data")
        self.uart_rx_module_ready = _get_signal(dut, "uart_receiver.i_ready")
        self.mmio_read_data_reg = _get_signal(
            dut, "cpu_and_memory_subsystem.mmio_read_data_reg"
        )
        self.mmio_read_data_comb = _get_signal(
            dut, "cpu_and_memory_subsystem.mmio_read_data_comb"
        )
        self.data_mem_or_periph = _get_signal(
            dut, "cpu_and_memory_subsystem.data_memory_response_data"
        )
        # dc_fifo pointers and state
        self.fifo_read_ptr = _get_signal(
            dut, "uart_rx_cdc_fifo.read_pointer_in_output_domain"
        )
        self.fifo_write_ptr_synced = _get_signal(
            dut, "uart_rx_cdc_fifo.write_pointer_synchronized_stage2"
        )
        self.fifo_valid_reg = _get_signal(
            dut, "uart_rx_cdc_fifo.read_data_valid_registered"
        )
        self.fifo_o_data = _get_signal(dut, "uart_rx_cdc_fifo.o_data")

    async def start(self) -> None:
        """Start the background monitoring coroutine."""
        cocotb.start_soon(self._run())

    def stop(self) -> None:
        """Stop the monitoring coroutine."""
        self._running = False

    def _record(self, msg: str) -> None:
        self.events.append(msg)
        if len(self.events) > self.max_events:
            self.events.pop(0)

    def reset_events(self, reset_counts: bool = False) -> None:
        """Clear captured events (and optionally counters)."""
        self.events = []
        if reset_counts:
            self.count_mmio_status = 0
            self.count_mmio_data = 0
            self.count_uart_ready = 0
            self.count_uart_valid_rise = 0

    def dump_recent(self) -> None:
        """Log the most recent captured events and summary statistics."""
        if not self.events:
            cocotb.log.info("UART/MMIO debug: no events captured")
            return
        cocotb.log.info(
            "UART/MMIO debug summary: "
            f"mmio_status={self.count_mmio_status} "
            f"mmio_data={self.count_mmio_data} "
            f"uart_ready={self.count_uart_ready} "
            f"uart_valid_rise={self.count_uart_valid_rise}"
        )
        cocotb.log.info("UART/MMIO debug (most recent events):")
        for line in self.events:
            cocotb.log.info(line)

    async def _run(self) -> None:
        prev_uart_valid = False
        while self._running:
            await RisingEdge(self.dut.i_clk)
            self.cycle += 1

            mmio_pulse = _read_bool(self.mmio_read_pulse)
            uart_valid = _read_bool(self.uart_rx_valid)
            uart_ready = _read_bool(self.uart_rx_ready)
            mmio_addr = _read_int(self.mmio_load_addr)
            mmio_valid = _read_bool(self.mmio_load_valid)
            uart_data = _read_int(self.uart_rx_data)
            uart_valid_top = _read_bool(self.uart_rx_valid_top)
            uart_ready_top = _read_bool(self.uart_rx_ready_top)
            uart_data_top = _read_int(self.uart_rx_data_top)
            mmio_data_reg = _read_int(self.mmio_read_data_reg)
            mmio_data_comb = _read_int(self.mmio_read_data_comb)
            data_mem_or_periph = _read_int(self.data_mem_or_periph)

            if mmio_pulse and mmio_addr is not None:
                if mmio_addr == UART_RX_STATUS_MMIO_ADDR:
                    self.count_mmio_status += 1
                if mmio_addr == UART_RX_DATA_MMIO_ADDR:
                    self.count_mmio_data += 1

                status_bit = (mmio_data_reg or 0) & 0x1
                should_record = False
                if mmio_addr == UART_RX_DATA_MMIO_ADDR:
                    should_record = True
                elif mmio_addr == UART_RX_STATUS_MMIO_ADDR and (
                    status_bit or uart_valid
                ):
                    should_record = True
                elif uart_ready or uart_valid:
                    should_record = True

                if should_record:
                    self._record(
                        f"cycle={self.cycle} mmio_pulse=1 addr=0x{mmio_addr:08x} "
                        f"mmio_valid={mmio_valid} uart_valid={uart_valid} "
                        f"uart_ready={uart_ready} uart_data=0x{(uart_data or 0):02x} "
                        f"uart_valid_top={uart_valid_top} uart_ready_top={uart_ready_top} "
                        f"uart_data_top=0x{(uart_data_top or 0):02x} "
                        f"mmio_data_reg=0x{(mmio_data_reg or 0):08x} "
                        f"mmio_data_comb=0x{(mmio_data_comb or 0):08x} "
                        f"mem_or_periph=0x{(data_mem_or_periph or 0):08x}"
                    )
            if uart_ready:
                self.count_uart_ready += 1
                fifo_rptr = _read_int(self.fifo_read_ptr)
                fifo_wptr_sync = _read_int(self.fifo_write_ptr_synced)
                fifo_valid = _read_bool(self.fifo_valid_reg)
                fifo_data = _read_int(self.fifo_o_data)
                self._record(
                    f"cycle={self.cycle} uart_ready=1 addr=0x{(mmio_addr or 0):08x} "
                    f"uart_valid={uart_valid} uart_data=0x{(uart_data or 0):02x} "
                    f"fifo_rptr={fifo_rptr} fifo_wptr_sync={fifo_wptr_sync} "
                    f"fifo_valid={fifo_valid} fifo_data=0x{(fifo_data or 0):02x}"
                )
            if uart_valid and not prev_uart_valid:
                self.count_uart_valid_rise += 1
                fifo_rptr = _read_int(self.fifo_read_ptr)
                fifo_wptr_sync = _read_int(self.fifo_write_ptr_synced)
                fifo_data = _read_int(self.fifo_o_data)
                self._record(
                    f"cycle={self.cycle} uart_valid_rise data=0x{(uart_data or 0):02x} "
                    f"fifo_rptr={fifo_rptr} fifo_wptr_sync={fifo_wptr_sync} "
                    f"fifo_data=0x{(fifo_data or 0):02x}"
                )

            # Monitor uart_rx module output (before CDC FIFO)
            uart_rx_mod_valid = _read_bool(self.uart_rx_module_valid)
            uart_rx_mod_data = _read_int(self.uart_rx_module_data)
            uart_rx_mod_ready = _read_bool(self.uart_rx_module_ready)
            if uart_rx_mod_valid and not getattr(
                self, "_prev_uart_rx_mod_valid", False
            ):
                self._record(
                    f"cycle={self.cycle} UART_RX_MODULE valid_rise data=0x{(uart_rx_mod_data or 0):02x} "
                    f"ready={uart_rx_mod_ready}"
                )
            self._prev_uart_rx_mod_valid = bool(uart_rx_mod_valid)

            prev_uart_valid = bool(uart_valid)


def read_ras_stats(dut: Any) -> dict[str, int] | None:
    """Read RAS stats counters from the DUT if available."""
    try:
        cpu = dut.cpu_and_memory_subsystem.cpu_inst
    except AttributeError:
        return None

    ras_predicted = _read_u64(getattr(cpu, "ras_predicted_count", None))
    if ras_predicted is None:
        return None
    ras_return = _read_u64(getattr(cpu, "ras_return_count", None))
    if ras_return is None:
        return None
    ras_correct = _read_u64(getattr(cpu, "ras_correct_count", None))
    if ras_correct is None:
        return None
    ras_mispred = _read_u64(getattr(cpu, "ras_mispred_count", None))
    if ras_mispred is None:
        return None

    return {
        "ras_predicted": ras_predicted,
        "ras_return": ras_return,
        "ras_correct": ras_correct,
        "ras_mispred": ras_mispred,
    }


def log_ras_stats(run_number: int, stats: dict[str, int] | None) -> None:
    """Log RAS stats in a compact format."""
    if stats is None:
        return

    predicted = stats["ras_predicted"]
    returns = stats["ras_return"]
    correct = stats["ras_correct"]
    mispred = stats["ras_mispred"]

    acc = (correct / predicted) if predicted else 0.0
    use = (predicted / returns) if returns else 0.0

    cocotb.log.info(
        f"Run {run_number} RAS stats: predicted={predicted}, returns={returns}, "
        f"correct={correct}, mispred={mispred}, "
        f"predicted/returns={use:.3f}, correct/predicted={acc:.3f}"
    )


class NicEchoPeer:
    """The wire-side peer of the NIC for the nic_echo app.

    Feeds a continuous 10GBASE-R stream (idles with frames spliced in, one
    scrambler state for the run) into the raw RX interface on the RX MAC
    clock, decodes the raw TX stream on the TX MAC clock with the net10g
    software receiver (restarted at every gap in valid: the PCS TX emits
    continuously once out of reset), and checks that every frame the app
    should echo comes back intact. The plan is fixed and known to the app
    (sw/apps/nic_echo/main.c): 24 frames that land in the ring, two of them
    longer than the buffers (truncated, not echoed), plus two frames for
    another station (filtered).
    """

    STATION = bytes([0x02, 0x11, 0x22, 0x33, 0x44, 0x55])
    OTHER = bytes([0x02, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE])
    BROADCAST = bytes([0xFF] * 6)
    MULTICAST = bytes([0x01, 0x00, 0x5E, 0x01, 0x02, 0x03])
    PEER = bytes([0x02, 0x66, 0x77, 0x88, 0x99, 0xAA])
    IDLE = (0x0707070707070707, 0xFF)

    def __init__(self, dut: Any, uart_monitor: "UartMonitor") -> None:
        """Start the wire in both directions; the plan waits for the app."""
        from collections import deque

        from net10g.test_codec import encode_reference
        from net10g.test_integration import WireReceiver, frame_words
        from net10g.test_scrambler import SerialReference

        self._encode = encode_reference
        self._frame_words = frame_words
        self._receiver_cls = WireReceiver
        self._scrambler_cls = SerialReference
        self.dut = dut
        self.uart = uart_monitor
        self.rng = random.Random(0x5EED)
        self.incoming: Any = deque()
        self.words: Any = deque()
        self.frames: list[bytes] = []
        self.expected: list[bytes] = []
        self._scrambler = SerialReference()
        self._reservoir = 0
        self._count = 0
        self._receiver = WireReceiver()
        self._streaming = False
        self._driver: Any = None
        dut.i_nic_rx_signal_ok.value = 1
        cocotb.start_soon(self._feed())
        cocotb.start_soon(self._collect())

    def _frame(self, da: bytes, length: int) -> bytes:
        body = bytes(self.rng.getrandbits(8) for _ in range(length - 12))
        return da + self.PEER + body

    def plan(self) -> list[tuple[bytes, str]]:
        """Return the frames in order with their fate: echo, trunc or filtered."""
        items: list[tuple[bytes, str]] = []
        # Singles of every class, spaced out.
        for da, n in (
            (self.STATION, 60),
            (self.STATION, 61),
            (self.BROADCAST, 100),
            (self.MULTICAST, 200),
            (self.STATION, 1518),
            (self.STATION, 20),
        ):
            items.append((self._frame(da, n), "echo"))
        items.append((self._frame(self.OTHER, 300), "filtered"))
        # A burst larger than the RX ring: frames wait in the MAC while the
        # app reposts descriptors.
        for k in range(12):
            items.append((self._frame(self.STATION, 64 + 23 * k), "echo"))
        # Jumbo frames longer than the buffers, another foreign frame, then the last ones.
        items.append((self._frame(self.STATION, 9000), "trunc"))
        items.append((self._frame(self.OTHER, 200), "filtered"))
        items.append((self._frame(self.STATION, 9000), "trunc"))
        for n in (500, 1518, 77, 1000):
            items.append((self._frame(self.STATION, n), "echo"))
        return items

    def _encode_next(self) -> None:
        data, ctrl = self.words.popleft() if self.words else self.IDLE
        payload, header, error = self._encode(list(data.to_bytes(8, "little")), ctrl)
        assert not error
        block = (self._scrambler.word(payload) << 2) | header
        self._reservoir |= block << self._count
        self._count += 66
        while self._count >= 64:
            self.incoming.append(self._reservoir & ((1 << 64) - 1))
            self._reservoir >>= 64
            self._count -= 64

    async def _feed(self) -> None:
        dut = self.dut
        while True:
            await FallingEdge(dut.i_nic_rx_clk)
            if not self.incoming:
                self._encode_next()
            dut.i_nic_rx_raw_data.value = self.incoming.popleft()
            dut.i_nic_rx_raw_valid.value = 1

    async def _collect(self) -> None:
        dut = self.dut
        while True:
            await FallingEdge(dut.i_nic_tx_clk)
            if int(dut.o_nic_tx_raw_valid.value):
                if not self._streaming:
                    self._receiver = self._receiver_cls()
                    self._streaming = True
                self._receiver.word(int(dut.o_nic_tx_raw_data.value))
                if self._receiver.frames:
                    self.frames += self._receiver.frames
                    self._receiver.frames = []
            else:
                self._streaming = False

    def start_run(self) -> None:
        """Arm the plan for one program run (the app announces readiness)."""
        self.frames = []
        self.expected = []
        if self._driver is not None:
            self._driver.cancel()
        self._driver = cocotb.start_soon(self._drive())

    async def _drive(self) -> None:
        dut = self.dut
        while not self.uart.contains("echo ready"):
            for _ in range(200):
                await RisingEdge(dut.i_clk)
        items = self.plan()
        self.expected = [f.ljust(60, b"\0") for f, fate in items if fate == "echo"]
        burst = False
        for f, fate in items:
            self.words.extend(self._frame_words(f))
            burst = 64 <= len(f) < 400 and fate == "echo"
            if not burst:
                # Space the singles: let the app take each one before the next.
                for _ in range(300):
                    await RisingEdge(dut.i_clk)

    def verify(self) -> None:
        """Every frame the app should have echoed came back, in order and intact."""
        assert self.frames == self.expected, (
            f"echoed {len(self.frames)} frames, expected {len(self.expected)}"
            + ("" if len(self.frames) != len(self.expected) else ": contents differ")
        )


def get_expected_behavior() -> tuple[str | None, str | None, bool, str | None]:
    """Determine expected behavior based on the program being tested.

    Returns:
        Tuple of (success_marker, initial_text, has_defined_endpoint, app_name)
        - success_marker: Text that indicates test passed (None for open-ended tests)
        - initial_text: Text that must appear for test to pass (for open-ended tests)
        - has_defined_endpoint: True if test has a clear pass/fail endpoint
        - app_name: Name of the application being tested (for timeout selection)
    """
    # The sw.mem symlink identifies the program under test. It lives in the
    # current working directory (tests/), not next to this file.
    sw_mem_path = "sw.mem"

    if os.path.islink(sw_mem_path):
        target = os.readlink(sw_mem_path)
        # Extract app name from path like "../sw/apps/hello_world/sw.mem"
        parts = target.split("/")
        if "apps" in parts:
            app_idx = parts.index("apps")
            if app_idx + 1 < len(parts):
                app_name = parts[app_idx + 1]

                if app_name == "hello_world":
                    # Passes once the first hello message appears.
                    return (None, "Hello, world!", False, app_name)
                if app_name == "uart_echo":
                    # Interactive test handled separately (UART input injection)
                    return (None, None, False, app_name)
                else:
                    # All other tests (including coremark) have pass/fail markers
                    return (PASS_MARKER, None, True, app_name)

    # Default: expect pass marker
    return (PASS_MARKER, None, True, None)


async def run_until_complete(
    dut: Any,
    uart_monitor: UartMonitor,
    success_marker: str | None,
    initial_text: str | None,
    has_defined_endpoint: bool,
    max_cycles: int,
    run_number: int,
    app_name: str | None = None,
) -> None:
    """Run the program until it passes, fails, or times out.

    Args:
        dut: Device under test
        uart_monitor: UART monitor instance (should already be started)
        success_marker: Text that indicates test passed
        initial_text: Text that must appear for open-ended tests
        has_defined_endpoint: True if test has a clear pass/fail endpoint
        max_cycles: Maximum cycles before timeout
        run_number: 1-based run index, for logging
        app_name: Program under test; selects per-app tracing and diagnostics

    Raises:
        AssertionError: If test fails or times out
    """
    test_passed = False
    test_failed = False
    cycle = 0
    retired_count = 0
    last_progress_retired = 0
    is_coremark_like = app_name is not None and app_name.startswith("coremark")
    progress_interval = 0
    if os.environ.get("COCOTB_PROGRESS_INTERVAL") is not None:
        progress_interval = int(os.environ["COCOTB_PROGRESS_INTERVAL"])
    elif is_coremark_like:
        progress_interval = int(
            os.environ.get("COCOTB_COREMARK_PROGRESS_INTERVAL", 500_000)
        )
    # FROST_IRQ_PRECISION_CHECK logs each interrupt take (up to
    # FROST_IRQ_PRECISION_EVENT_LIMIT) and fails a run that takes none.
    # FROST_IRQ_PRECISION_STRICT also fails a take in whose cycle the
    # registered commit bus writes x1 or x2 at the saved PC, and a take inside
    # FROST_IRQ_CALLEE_SYMBOL (default irq_stack_slot_callee), past its first
    # instruction, while x2 was last written outside that function.
    irq_precision_check = os.environ.get("FROST_IRQ_PRECISION_CHECK") == "1"
    irq_precision_strict = os.environ.get("FROST_IRQ_PRECISION_STRICT") == "1"
    irq_low_ra_assert = os.environ.get("FROST_IRQ_LOW_RA_ASSERT") == "1"
    irq_precision_event_limit = int(
        os.environ.get("FROST_IRQ_PRECISION_EVENT_LIMIT", "64")
    )
    irq_precision_events: list[str] = []
    irq_take_count = 0
    external_irq_symbol = os.environ.get("FROST_EXTERNAL_IRQ_SYMBOL")
    external_irq_enabled = bool(external_irq_symbol)
    external_irq_offset = int(os.environ.get("FROST_EXTERNAL_IRQ_OFFSET", "0"), 0)
    external_irq_max_pulses = int(os.environ.get("FROST_EXTERNAL_IRQ_MAX_PULSES", "1"))
    external_irq_hold_cycles = int(
        os.environ.get("FROST_EXTERNAL_IRQ_HOLD_CYCLES", "1")
    )
    retire_sig = None
    pc_sig = None
    pc_vld_sig = None
    mem_rd_en_sig = None
    mem_addr_sig = None
    mem_wr_en_sig = None
    sq_count_sig = None
    sq_full_sig = None
    rob_count_sig = None
    dispatch_stall_sig = None
    retire_pc_sig = None
    retire_mispredict_sig = None
    branch_pred_off_sig = None
    if_btb_pred_sig = None
    if_ras_pred_sig = None
    pd_btb_pred_sig = None
    pd_ras_pred_sig = None
    id_btb_pred_sig = None
    id_ras_pred_sig = None
    lq_issue_mem_found_sig = None
    lq_sq_check_valid_sig = None
    lq_sq_can_issue_sig = None
    lq_sq_do_forward_sig = None
    lq_cache_hit_fast_path_sig = None
    lq_mem_outstanding_sig = None
    btb_hit_sig = None
    btb_pred_taken_sig = None
    pred_used_sig = None
    pred_holdoff_sig = None
    if_ras_pred_sig = None
    pd_ras_pred_sig = None
    id_ras_pred_sig = None
    if_pc_sig = None
    if_sel_nop_sig = None
    if_sel_compressed_sig = None
    if_raw_parcel_sig = None
    if_effective_instr_sig = None
    pd_pc_sig = None
    pd_instr_sig = None
    id_pc_sig = None
    id_instr_sig = None
    id_op_sig = None
    int_rf_write_enable_sig = None
    int_rf_write_addr_sig = None
    int_rf_write_data_sig = None
    issue_valid_sig = None
    issue_pc_sig = None
    issue_pred_taken_sig = None
    control_flow_trace_label = None
    control_flow_trace_ranges: list[tuple[int, int]] | None = None
    control_flow_trace_env = os.environ.get("FROST_CONTROL_FLOW_TRACE_RANGES")
    branch_taken_live_sig = None
    branch_target_live_sig = None
    btb_update_sig = None
    btb_update_pc_sig = None
    btb_update_target_sig = None
    btb_update_taken_sig = None
    btb_update_compressed_sig = None
    if_control_flow_holdoff_sig = None
    if_stall_sig = None
    if_stall_registered_sig = None
    front_end_cf_serialize_stall_sig = None
    front_end_stall_q_sig = None
    replay_after_dispatch_stall_q_sig = None
    replay_after_serialize_stall_q_sig = None
    if_ras_ckpt_tos_sig = None
    if_ras_ckpt_vc_sig = None
    pd_ras_ckpt_tos_sig = None
    pd_ras_ckpt_vc_sig = None
    id_ras_ckpt_tos_sig = None
    id_ras_ckpt_vc_sig = None
    ras_misprediction_live_sig = None
    ras_restore_tos_live_sig = None
    ras_restore_valid_count_live_sig = None
    ras_pop_after_restore_live_sig = None
    commit_valid_live_sig = None
    commit_pc_live_sig = None
    commit0_dest_valid_sig = None
    commit0_dest_rf_sig = None
    commit0_dest_reg_sig = None
    commit0_value_sig = None
    commit1_valid_sig = None
    commit1_pc_sig = None
    commit1_dest_valid_sig = None
    commit1_dest_rf_sig = None
    commit1_dest_reg_sig = None
    commit1_value_sig = None
    commit_is_return_live_sig = None
    commit_is_call_live_sig = None
    commit_checkpoint_id_live_sig = None
    commit_has_checkpoint_live_sig = None
    commit_predicted_taken_live_sig = None
    commit_branch_taken_live_sig = None
    checkpoint_save_sig = None
    checkpoint_id_sig = None
    checkpoint_restore_sig = None
    checkpoint_restore_id_sig = None
    checkpoint_free_sig = None
    checkpoint_free_id_sig = None
    checkpoint_in_use_sig = None
    checkpoint_available_sig = None
    checkpoint_alloc_id_sig = None
    checkpoint_flush_pending_sig = None
    early_mispredict_pending_sig = None
    mispredict_recovery_pending_sig = None
    correct_branch_commit_pending_sig = None
    flush_en_live_sig = None
    flush_tag_live_sig = None
    if_valid_live_sig = None
    pd_valid_live_sig = None
    id_valid_live_sig = None
    post_flush_holdoff_live_sig = None
    csr_in_flight_live_sig = None
    pipeline_stall_live_sig = None
    pipeline_stall_registered_live_sig = None
    rob_full_live_sig = None
    int_rs_full_live_sig = None
    mul_rs_full_live_sig = None
    mem_rs_full_live_sig = None
    fp_rs_full_live_sig = None
    fmul_rs_full_live_sig = None
    fdiv_rs_full_live_sig = None
    lq_full_live_sig = None
    sq_full_live_sig = None
    head_tag_live_sig = None
    head_valid_live_sig = None
    head_done_live_sig = None
    head_pc_live_sig = None
    head_is_branch_live_sig = None
    head_is_store_live_sig = None
    head_has_checkpoint_live_sig = None
    checkpoint_available_live_sig = None
    issue_valid_live_sig = None
    issue_pc_live_sig = None
    rs_dispatch_valid_live_sig = None
    rs_dispatch_pc_live_sig = None
    rs_dispatch_rob_tag_live_sig = None
    rs_dispatch_src1_ready_live_sig = None
    rs_dispatch_src1_tag_live_sig = None
    rs_dispatch_src2_ready_live_sig = None
    rs_dispatch_src2_tag_live_sig = None
    rat_a0_valid_sig = None
    rat_a0_tag_sig = None
    rat_a0_commit_hit_sig = None
    rat_a0_commit_tag_match_sig = None
    rat_a0_alloc_hit_sig = None
    rat_alloc_valid_sig = None
    rat_alloc_dest_rf_sig = None
    rat_alloc_dest_reg_sig = None
    rat_alloc_rob_tag_sig = None
    last_a0_alloc_pc_sig = None
    last_a0_alloc_tag_sig = None
    rob_alloc_valid_live_sig = None
    rob_alloc_pc_live_sig = None
    rob_alloc_is_csr_live_sig = None
    rob_alloc_is_mret_live_sig = None
    id_instruction_live_sig = None
    trap_taken_live_sig = None
    trap_taken_reg_dbg_sig = None
    trap_cause_internal_live_sig = None
    mret_taken_live_sig = None
    trap_target_live_sig = None
    trap_pending_live_sig = None
    rob_trap_pc_live_sig = None
    trap_pc_internal_live_sig = None
    interrupt_resume_pc_live_sig = None
    csr_commit_fire_live_sig = None
    csr_mepc_live_sig = None
    flush_all_live_sig = None
    port0_int_we_sig = None
    port0_int_addr_sig = None
    port0_int_data_sig = None
    port1_int_we_sig = None
    port1_int_addr_sig = None
    port1_int_data_sig = None
    rob_commit0_reg_valid_sig = None
    rob_commit0_reg_pc_sig = None
    rob_commit0_reg_dest_valid_sig = None
    rob_commit0_reg_dest_rf_sig = None
    rob_commit0_reg_dest_reg_sig = None
    rob_commit1_reg_valid_sig = None
    rob_commit1_reg_pc_sig = None
    rob_commit1_reg_dest_valid_sig = None
    rob_commit1_reg_dest_rf_sig = None
    rob_commit1_reg_dest_reg_sig = None
    coremark_cf_debug_enabled = (
        is_coremark_like and os.environ.get("FROST_COREMARK_CF_DEBUG") == "1"
    )
    coremark_if_check_enabled = (
        is_coremark_like and os.environ.get("FROST_COREMARK_IF_CHECK") == "1"
    )
    coremark_matrix_expected: dict[int, tuple[int, int]] = {}
    coremark_symbol_ranges: dict[str, tuple[int, int]] = {}
    # The IF check and the retire trace each cover one function, found by
    # name in sw.S; a name missing from sw.S fails the run. The default,
    # calc_func, holds the matrix and state kernels in the default build,
    # whose LTO inlines core_bench_matrix and core_bench_state into it. An
    # untuned build (APP_TUNE_FLAGS=) keeps core_bench_matrix as a function of
    # its own. The range list below also asks for kernel names that inlining
    # removes; missing names there are skipped.
    coremark_if_check_symbol = os.environ.get(
        "FROST_COREMARK_IF_CHECK_SYMBOL", "calc_func"
    )
    coremark_if_check_count = 0
    coremark_if_check_alloc_sig = None
    coremark_if_check_slot2: _PackedStruct | None = None
    coremark_if_check_lo = 0
    coremark_if_check_hi = 0
    coremark_retire_trace_path = (
        os.environ.get("FROST_COREMARK_RETIRE_TRACE_PATH") if is_coremark_like else None
    )
    coremark_retire_trace_symbol = os.environ.get(
        "FROST_COREMARK_RETIRE_TRACE_SYMBOL", "calc_func"
    )
    coremark_matrix_base_pc: int | None = None
    coremark_matrix_last_pc: int | None = None
    coremark_retire_trace_file: TextIO | None = None
    coremark_retire_trace_count = 0
    coremark_retire_trace_limit = 20000
    coremark_retire_commits: tuple[_PackedStruct, _PackedStruct] | None = None
    coremark_retire_slot2_valid_sig = None
    coremark_retire_slot2_pc_sig = None
    if control_flow_trace_env:
        parsed_ranges: list[tuple[int, int]] = []
        for raw_range in control_flow_trace_env.split(","):
            raw_range = raw_range.strip()
            if not raw_range:
                continue
            if "-" not in raw_range:
                raise ValueError(
                    "FROST_CONTROL_FLOW_TRACE_RANGES entries must be start-end"
                )
            start_text, end_text = raw_range.split("-", 1)
            parsed_ranges.append((int(start_text, 0), int(end_text, 0)))
        control_flow_trace_ranges = parsed_ranges
        control_flow_trace_label = os.environ.get(
            "FROST_CONTROL_FLOW_TRACE_LABEL", f"{app_name or 'program'} trace"
        )
    if (
        progress_interval
        or irq_precision_check
        or external_irq_enabled
        or coremark_if_check_enabled
        or coremark_retire_trace_path is not None
    ):
        retire_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_commit_valid"
        )
        retire_pc_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_commit_pc"
        )
        retire_mispredict_sig = _get_signal(dut, COMMIT_MISPREDICTION_PATH)
        pc_sig = _get_signal(dut, "cpu_and_memory_subsystem.cpu_inst.o_pc")
        pc_vld_sig = _get_signal(dut, "cpu_and_memory_subsystem.cpu_inst.o_pc_vld")
        mem_rd_en_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.o_data_mem_read_enable"
        )
        mem_addr_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.o_data_mem_addr"
        )
        mem_wr_en_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.o_data_mem_per_byte_wr_en"
        )
        sq_count_sig = _get_signal(dut, "cpu_and_memory_subsystem.cpu_inst.sq_count")
        sq_full_sig = _get_signal(dut, "cpu_and_memory_subsystem.cpu_inst.sq_full")
        rob_count_sig = _get_signal(dut, "cpu_and_memory_subsystem.cpu_inst.rob_count")
        dispatch_stall_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_dispatch_stall"
        )
        head_tag_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.head_tag"
        )
        head_valid_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.head_valid"
        )
        head_done_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.head_done"
        )
        head_pc_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.u_tomasulo.u_rob.head_pc"
        )
        head_is_branch_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.u_tomasulo.u_rob.head_is_branch"
        )
        head_is_store_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.u_tomasulo.u_rob.head_is_store"
        )
        head_has_checkpoint_live_sig = _get_signal(
            dut,
            "cpu_and_memory_subsystem.cpu_inst.u_tomasulo.u_rob.head_has_checkpoint",
        )
        checkpoint_available_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.checkpoint_available"
        )
        issue_valid_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_issue_valid"
        )
        issue_pc_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_issue_pc"
        )
        rs_dispatch_valid_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_rs_dispatch_valid"
        )
        rs_dispatch_pc_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_rs_dispatch_pc"
        )
        rs_dispatch_rob_tag_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_rs_dispatch_rob_tag"
        )
        rs_dispatch_src1_ready_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_rs_dispatch_src1_ready"
        )
        rs_dispatch_src1_tag_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_rs_dispatch_src1_tag"
        )
        rs_dispatch_src2_ready_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_rs_dispatch_src2_ready"
        )
        rs_dispatch_src2_tag_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_rs_dispatch_src2_tag"
        )
        rat_a0_valid_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.u_tomasulo.u_rat.dbg_int_a0_valid"
        )
        rat_a0_tag_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.u_tomasulo.u_rat.dbg_int_a0_tag"
        )
        rat_a0_commit_hit_sig = _get_signal(
            dut,
            "cpu_and_memory_subsystem.cpu_inst.u_tomasulo.u_rat.dbg_int_a0_commit_hit",
        )
        rat_a0_commit_tag_match_sig = _get_signal(
            dut,
            "cpu_and_memory_subsystem.cpu_inst.u_tomasulo.u_rat.dbg_int_a0_commit_tag_match",
        )
        rat_a0_alloc_hit_sig = _get_signal(
            dut,
            "cpu_and_memory_subsystem.cpu_inst.u_tomasulo.u_rat.dbg_int_a0_alloc_hit",
        )
        rat_alloc_valid_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_rat_alloc_valid"
        )
        rat_alloc_dest_rf_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_rat_alloc_dest_rf"
        )
        rat_alloc_dest_reg_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_rat_alloc_dest_reg"
        )
        rat_alloc_rob_tag_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_rat_alloc_rob_tag"
        )
        last_a0_alloc_pc_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_last_a0_alloc_pc"
        )
        last_a0_alloc_tag_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_last_a0_alloc_tag"
        )
        branch_pred_off_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.disable_branch_prediction_ooo"
        )
        if_stall_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_pipeline_stall"
        )
        if_stall_registered_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_pipeline_stall_registered"
        )
        front_end_cf_serialize_stall_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_front_end_cf_serialize_stall"
        )
        front_end_stall_q_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_stall_q"
        )
        replay_after_dispatch_stall_q_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_replay_after_dispatch_stall_q"
        )
        if coremark_cf_debug_enabled:
            if_btb_pred_sig = _get_signal(
                dut,
                "cpu_and_memory_subsystem.cpu_inst.from_if_to_pd.btb_predicted_taken",
            )
            if_ras_pred_sig = _get_signal(
                dut, "cpu_and_memory_subsystem.cpu_inst.dbg_if_ras_predicted"
            )
            pd_btb_pred_sig = _get_signal(
                dut,
                "cpu_and_memory_subsystem.cpu_inst.from_pd_to_id.btb_predicted_taken",
            )
            pd_ras_pred_sig = _get_signal(
                dut, "cpu_and_memory_subsystem.cpu_inst.dbg_pd_ras_predicted"
            )
            id_btb_pred_sig = _get_signal(
                dut,
                "cpu_and_memory_subsystem.cpu_inst.from_id_to_ex.btb_predicted_taken",
            )
            id_ras_pred_sig = _get_signal(
                dut, "cpu_and_memory_subsystem.cpu_inst.dbg_id_ras_predicted"
            )
        lq_issue_mem_found_sig = _get_signal(
            dut,
            "cpu_and_memory_subsystem.cpu_inst.u_tomasulo.u_lq.issue_mem_found",
        )
        lq_sq_check_valid_sig = _get_signal(
            dut,
            "cpu_and_memory_subsystem.cpu_inst.u_tomasulo.sq_check_valid",
        )
        lq_sq_can_issue_sig = _get_signal(
            dut,
            "cpu_and_memory_subsystem.cpu_inst.u_tomasulo.u_lq.sq_can_issue",
        )
        lq_sq_do_forward_sig = _get_signal(
            dut,
            "cpu_and_memory_subsystem.cpu_inst.u_tomasulo.u_lq.sq_do_forward",
        )
        lq_cache_hit_fast_path_sig = _get_signal(
            dut,
            "cpu_and_memory_subsystem.cpu_inst.u_tomasulo.u_lq.cache_hit_fast_path",
        )
        lq_mem_outstanding_sig = _get_signal(
            dut,
            "cpu_and_memory_subsystem.cpu_inst.u_tomasulo.u_lq.mem_outstanding",
        )
        if_pc_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.from_if_to_pd.program_counter"
        )
        if_sel_nop_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.from_if_to_pd.sel_nop"
        )
        if_sel_compressed_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.from_if_to_pd.sel_compressed"
        )
        if_raw_parcel_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.from_if_to_pd.raw_parcel"
        )
        if_effective_instr_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.from_if_to_pd.effective_instr"
        )
        pd_pc_sig = _get_signal(dut, "cpu_and_memory_subsystem.cpu_inst.dbg_pd_pc")
        pd_instr_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_pd_instr"
        )
        id_pc_sig = _get_signal(dut, "cpu_and_memory_subsystem.cpu_inst.dbg_id_pc")
        id_instr_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_id_instr"
        )
        id_op_sig = _get_signal(
            dut,
            "cpu_and_memory_subsystem.cpu_inst.from_id_to_ex.instruction_operation",
        )
        issue_valid_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_issue_valid"
        )
        issue_pc_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_issue_pc"
        )
        if coremark_if_check_enabled:
            coremark_matrix_expected = _load_symbol_machine_code(
                coremark_if_check_symbol, app_name
            )
            if not coremark_matrix_expected:
                raise AssertionError(
                    f"FROST_COREMARK_IF_CHECK_SYMBOL={coremark_if_check_symbol!r} "
                    "has no code in sw.S; name a function this build contains"
                )
            coremark_if_check_lo = min(coremark_matrix_expected)
            coremark_if_check_hi = max(coremark_matrix_expected) + 4
            coremark_if_check_alloc_sig = _get_signal(
                dut, "cpu_and_memory_subsystem.cpu_inst.dbg_rob_alloc_valid"
            )
            _require_signals(
                "FROST_COREMARK_IF_CHECK",
                {
                    "cpu_inst.dbg_rob_alloc_valid": coremark_if_check_alloc_sig,
                    "cpu_inst.dbg_id_pc": id_pc_sig,
                    "cpu_inst.dbg_id_instr": id_instr_sig,
                },
            )
            coremark_if_check_slot2 = _packed_struct(
                dut,
                "cpu_and_memory_subsystem.cpu_inst.from_id_to_ex_2",
                ID_TO_EX_FIELDS,
                "FROST_COREMARK_IF_CHECK",
            )
        coremark_symbol_ranges = _load_symbol_ranges(
            [
                "core_bench_list",
                "calc_func",
                "matrix_test",
                "core_bench_matrix",
                "core_state_transition",
                "core_bench_state",
                "crc16",
                "crcu16",
            ],
            app_name,
        )
        if coremark_retire_trace_path is not None:
            retire_trace_range = _load_symbol_ranges(
                [coremark_retire_trace_symbol], app_name
            ).get(coremark_retire_trace_symbol)
            if retire_trace_range is None:
                raise AssertionError(
                    "FROST_COREMARK_RETIRE_TRACE_SYMBOL="
                    f"{coremark_retire_trace_symbol!r} is not in sw.S; name a "
                    "function this build contains"
                )
            coremark_matrix_base_pc = retire_trace_range[0]
            coremark_matrix_last_pc = retire_trace_range[1] - 1
            coremark_retire_slot2_valid_sig = _get_signal(
                dut, "cpu_and_memory_subsystem.cpu_inst.dbg_commit_2_valid"
            )
            coremark_retire_slot2_pc_sig = _get_signal(
                dut, "cpu_and_memory_subsystem.cpu_inst.dbg_commit_2_pc"
            )
            _require_signals(
                "FROST_COREMARK_RETIRE_TRACE_PATH",
                {
                    "cpu_inst.dbg_commit_valid": retire_sig,
                    "cpu_inst.dbg_commit_pc": retire_pc_sig,
                    "cpu_inst.dbg_commit_2_valid": coremark_retire_slot2_valid_sig,
                    "cpu_inst.dbg_commit_2_pc": coremark_retire_slot2_pc_sig,
                },
            )
            coremark_retire_commits = (
                _packed_struct(
                    dut,
                    "cpu_and_memory_subsystem.cpu_inst.rob_commit_comb",
                    COMMIT_FIELDS,
                    "FROST_COREMARK_RETIRE_TRACE_PATH",
                ),
                _packed_struct(
                    dut,
                    "cpu_and_memory_subsystem.cpu_inst.rob_commit_comb_2",
                    COMMIT_FIELDS,
                    "FROST_COREMARK_RETIRE_TRACE_PATH",
                ),
            )
            # Every run appends its samples under a "# run N" line; the first
            # run starts a new file. Line buffering keeps the samples a
            # failing run wrote.
            coremark_retire_trace_file = Path(coremark_retire_trace_path).open(
                "w" if run_number == 1 else "a", buffering=1
            )
            coremark_retire_trace_file.write(f"# run {run_number}\n")
    elif (
        app_name in {"branch_pred_test", "ras_stress_test"}
        or control_flow_trace_ranges
        or os.environ.get("FROST_CHECKPOINT_TRACE") == "1"
    ):
        retire_sig = _get_signal(dut, "cpu_and_memory_subsystem.cpu_inst.o_vld")
        retire_pc_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_commit_pc"
        )
        retire_mispredict_sig = _get_signal(dut, COMMIT_MISPREDICTION_PATH)
        pc_sig = _get_signal(dut, "cpu_and_memory_subsystem.cpu_inst.o_pc")
        pc_vld_sig = _get_signal(dut, "cpu_and_memory_subsystem.cpu_inst.o_pc_vld")
        branch_pred_off_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.disable_branch_prediction_ooo"
        )
        dispatch_stall_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_dispatch_stall"
        )
        if_stall_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_pipeline_stall"
        )
        if_stall_registered_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_pipeline_stall_registered"
        )
        front_end_cf_serialize_stall_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_front_end_cf_serialize_stall"
        )
        front_end_stall_q_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_stall_q"
        )
        replay_after_dispatch_stall_q_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_replay_after_dispatch_stall_q"
        )
        replay_after_serialize_stall_q_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_replay_after_serialize_stall_q"
        )
        btb_hit_sig = _get_signal(
            dut,
            "cpu_and_memory_subsystem.cpu_inst.if_stage_inst.branch_prediction_controller_inst.btb_hit",
        )
        btb_pred_taken_sig = _get_signal(
            dut,
            "cpu_and_memory_subsystem.cpu_inst.if_stage_inst.branch_prediction_controller_inst.btb_predicted_taken",
        )
        pred_used_sig = _get_signal(
            dut,
            "cpu_and_memory_subsystem.cpu_inst.if_stage_inst.branch_prediction_controller_inst.o_prediction_used",
        )
        pred_holdoff_sig = _get_signal(
            dut,
            "cpu_and_memory_subsystem.cpu_inst.if_stage_inst.branch_prediction_controller_inst.o_prediction_holdoff",
        )
        if_ras_pred_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_if_ras_predicted"
        )
        pd_ras_pred_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_pd_ras_predicted"
        )
        id_ras_pred_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_id_ras_predicted"
        )
        if_pc_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.from_if_to_pd.program_counter"
        )
        if_sel_nop_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.from_if_to_pd.sel_nop"
        )
        if_raw_parcel_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.from_if_to_pd.raw_parcel"
        )
        if_ras_ckpt_tos_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_if_ras_checkpoint_tos"
        )
        if_ras_ckpt_vc_sig = _get_signal(
            dut,
            "cpu_and_memory_subsystem.cpu_inst.dbg_if_ras_checkpoint_valid_count",
        )
        pd_pc_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.from_pd_to_id.program_counter"
        )
        pd_instr_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.from_pd_to_id.instruction"
        )
        pd_ras_ckpt_tos_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_pd_ras_checkpoint_tos"
        )
        pd_ras_ckpt_vc_sig = _get_signal(
            dut,
            "cpu_and_memory_subsystem.cpu_inst.dbg_pd_ras_checkpoint_valid_count",
        )
        id_pc_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.from_id_to_ex.program_counter"
        )
        id_ras_ckpt_tos_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_id_ras_checkpoint_tos"
        )
        id_ras_ckpt_vc_sig = _get_signal(
            dut,
            "cpu_and_memory_subsystem.cpu_inst.dbg_id_ras_checkpoint_valid_count",
        )
        id_op_sig = _get_signal(
            dut,
            "cpu_and_memory_subsystem.cpu_inst.from_id_to_ex.instruction_operation",
        )
        int_rf_write_enable_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.int_rf_write_enable"
        )
        int_rf_write_addr_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.int_rf_write_addr"
        )
        int_rf_write_data_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.int_rf_write_data"
        )
        # tomasulo_wrapper exposes the issue payload as one packed `o_rs_issue`
        # struct, so use the flat debug taps cpu_ooo maintains for it. There is
        # no debug tap for the issue source operands, so src1/src2 are not
        # traced.
        issue_valid_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_issue_valid"
        )
        issue_pc_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_issue_pc"
        )
        issue_pred_taken_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_issue_predicted_taken"
        )
        redirect_pc_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.misprediction_redirect_pc"
        )
        btb_update_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_btb_update"
        )
        btb_update_pc_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_btb_update_pc"
        )
        btb_update_target_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_btb_update_target"
        )
        btb_update_taken_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_btb_update_taken"
        )
        btb_update_compressed_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_btb_update_compressed"
        )
        if_pc_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.if_stage_inst.pc"
        )
        if_pc_reg_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.if_stage_inst.pc_reg"
        )
        if_raw_parcel_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.if_stage_inst.raw_parcel"
        )
        if_effective_instr_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.if_stage_inst.effective_instr"
        )
        if_sel_nop_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.if_stage_inst.sel_nop"
        )
        if_sel_compressed_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.if_stage_inst.sel_compressed"
        )
        pending_prediction_active_sig = _get_signal(
            dut,
            "cpu_and_memory_subsystem.cpu_inst.if_stage_inst.pending_prediction_active",
        )
        pending_prediction_fetch_holdoff_sig = _get_signal(
            dut,
            "cpu_and_memory_subsystem.cpu_inst.if_stage_inst.pending_prediction_fetch_holdoff",
        )
        if_is_32bit_spanning_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.if_stage_inst.is_32bit_spanning"
        )
        if_spanning_wait_sig = _get_signal(
            dut,
            "cpu_and_memory_subsystem.cpu_inst.if_stage_inst.spanning_wait_for_fetch",
        )
        if_spanning_in_progress_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.if_stage_inst.spanning_in_progress"
        )
        if_use_instr_buffer_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.if_stage_inst.use_instr_buffer"
        )
        if_prev_compressed_lo_sig = _get_signal(
            dut,
            "cpu_and_memory_subsystem.cpu_inst.if_stage_inst.prev_was_compressed_at_lo",
        )
        pc_seq_next_pc_reg_sig = _get_signal(
            dut,
            "cpu_and_memory_subsystem.cpu_inst.if_stage_inst.pc_controller_inst.seq_next_pc_reg",
        )
        pc_next_pc_reg_sig = _get_signal(
            dut,
            "cpu_and_memory_subsystem.cpu_inst.if_stage_inst.pc_controller_inst.next_pc_reg",
        )
        pc_prev_was_32bit_sig = _get_signal(
            dut,
            "cpu_and_memory_subsystem.cpu_inst.if_stage_inst.pc_controller_inst.prev_was_32bit",
        )
        ras_tos_sig = _get_signal(
            dut,
            "cpu_and_memory_subsystem.cpu_inst.if_stage_inst.branch_prediction_controller_inst.ras_inst.tos",
        )
        ras_valid_count_sig = _get_signal(
            dut,
            "cpu_and_memory_subsystem.cpu_inst.if_stage_inst.branch_prediction_controller_inst.ras_inst.valid_count",
        )
        ras_write_enable_sig = _get_signal(
            dut,
            "cpu_and_memory_subsystem.cpu_inst.if_stage_inst.branch_prediction_controller_inst.ras_inst.ras_write_enable",
        )
        ras_write_data_sig = _get_signal(
            dut,
            "cpu_and_memory_subsystem.cpu_inst.if_stage_inst.branch_prediction_controller_inst.ras_inst.ras_write_data",
        )
        ras_do_pop_sig = _get_signal(
            dut,
            "cpu_and_memory_subsystem.cpu_inst.if_stage_inst.branch_prediction_controller_inst.ras_inst.do_pop",
        )
        ras_do_push_sig = _get_signal(
            dut,
            "cpu_and_memory_subsystem.cpu_inst.if_stage_inst.branch_prediction_controller_inst.ras_inst.do_push",
        )
        ras_capture_inputs_sig = _get_signal(
            dut,
            "cpu_and_memory_subsystem.cpu_inst.if_stage_inst.branch_prediction_controller_inst.ras_inst.capture_op_inputs",
        )
        ras_target_live_sig = _get_signal(
            dut,
            "cpu_and_memory_subsystem.cpu_inst.if_stage_inst.branch_prediction_controller_inst.ras_target",
        )
        ras_is_call_sig = _get_signal(
            dut,
            "cpu_and_memory_subsystem.cpu_inst.if_stage_inst.branch_prediction_controller_inst.ras_is_call",
        )
        ras_is_return_sig = _get_signal(
            dut,
            "cpu_and_memory_subsystem.cpu_inst.if_stage_inst.branch_prediction_controller_inst.ras_is_return",
        )
        ras_link_address_sig = _get_signal(
            dut,
            "cpu_and_memory_subsystem.cpu_inst.if_stage_inst.branch_prediction_controller_inst.i_link_address",
        )
        ras_misprediction_live_sig = _get_signal(
            dut,
            "cpu_and_memory_subsystem.cpu_inst.from_ex_comb_synth.ras_misprediction",
        )
        ras_restore_tos_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.from_ex_comb_synth.ras_restore_tos"
        )
        ras_restore_valid_count_live_sig = _get_signal(
            dut,
            "cpu_and_memory_subsystem.cpu_inst.from_ex_comb_synth.ras_restore_valid_count",
        )
        ras_pop_after_restore_live_sig = _get_signal(
            dut,
            "cpu_and_memory_subsystem.cpu_inst.from_ex_comb_synth.ras_pop_after_restore",
        )
        commit_valid_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_commit_valid"
        )
        commit_pc_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_commit_pc"
        )
        commit0_dest_valid_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_commit_dest_valid"
        )
        commit0_dest_rf_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_commit_dest_rf"
        )
        commit0_dest_reg_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_commit_dest_reg"
        )
        commit0_value_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_commit_value"
        )
        commit1_valid_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_commit_2_valid"
        )
        commit1_pc_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_commit_2_pc"
        )
        commit1_dest_valid_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_commit_2_dest_valid"
        )
        commit1_dest_rf_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_commit_2_dest_rf"
        )
        commit1_dest_reg_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_commit_2_dest_reg"
        )
        commit1_value_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_commit_2_value"
        )
        commit_is_return_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_commit_is_return"
        )
        commit_is_call_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_commit_is_call"
        )
        commit_checkpoint_id_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_commit_checkpoint_id"
        )
        commit_has_checkpoint_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_commit_has_checkpoint"
        )
        commit_predicted_taken_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_commit_predicted_taken"
        )
        commit_branch_taken_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_commit_branch_taken"
        )
        checkpoint_save_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.checkpoint_save"
        )
        checkpoint_id_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.checkpoint_id"
        )
        checkpoint_restore_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.checkpoint_restore"
        )
        checkpoint_restore_id_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.checkpoint_restore_id"
        )
        checkpoint_free_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.checkpoint_free"
        )
        checkpoint_free_id_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.checkpoint_free_id"
        )
        checkpoint_in_use_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.checkpoint_in_use"
        )
        checkpoint_available_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.checkpoint_available"
        )
        checkpoint_alloc_id_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.checkpoint_alloc_id"
        )
        checkpoint_flush_pending_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.checkpoint_flush_pending"
        )
        early_mispredict_pending_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.early_mispredict_pending"
        )
        mispredict_recovery_pending_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.mispredict_recovery_pending"
        )
        correct_branch_commit_pending_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.correct_branch_commit_pending"
        )
        flush_en_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.flush_en"
        )
        flush_tag_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.flush_tag"
        )
        commit_is_mret_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.rob_commit.is_mret"
        )
        branch_taken_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.from_ex_comb_synth.branch_taken"
        )
        branch_target_live_sig = _get_signal(
            dut,
            "cpu_and_memory_subsystem.cpu_inst.from_ex_comb_synth.branch_target_address",
        )
        trap_taken_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.trap_taken"
        )
        trap_taken_reg_dbg_sig = _first_signal(
            dut,
            [
                "cpu_and_memory_subsystem.cpu_inst.dbg_trap_taken_q",
                "cpu_and_memory_subsystem.cpu_inst.trap_taken_reg",
            ],
        )
        trap_cause_internal_live_sig = _first_signal(
            dut,
            [
                "cpu_and_memory_subsystem.cpu_inst.dbg_trap_cause_internal",
                "cpu_and_memory_subsystem.cpu_inst.trap_cause_internal",
            ],
        )
        mret_taken_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.mret_taken"
        )
        trap_target_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.trap_target"
        )
        trap_pending_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.trap_pending"
        )
        rob_trap_pc_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.rob_trap_pc"
        )
        trap_pc_internal_live_sig = _first_signal(
            dut,
            [
                "cpu_and_memory_subsystem.cpu_inst.dbg_trap_pc_internal",
                "cpu_and_memory_subsystem.cpu_inst.rob_trap_pc",
            ],
        )
        interrupt_resume_pc_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_interrupt_resume_pc"
        )
        rob_trap_cause_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.rob_trap_cause"
        )
        mret_start_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.mret_start"
        )
        csr_commit_fire_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.csr_commit_fire"
        )
        csr_mtvec_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.csr_mtvec"
        )
        csr_mepc_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.csr_mepc"
        )
        flush_all_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.flush_all"
        )
        port0_int_we_sig = _first_signal(
            dut,
            [
                "cpu_and_memory_subsystem.cpu_inst.dbg_port0_int_we",
                "cpu_and_memory_subsystem.cpu_inst.port0_int_we",
            ],
        )
        port0_int_addr_sig = _first_signal(
            dut,
            [
                "cpu_and_memory_subsystem.cpu_inst.dbg_port0_int_addr",
                "cpu_and_memory_subsystem.cpu_inst.port0_int_addr",
            ],
        )
        port0_int_data_sig = _first_signal(
            dut,
            [
                "cpu_and_memory_subsystem.cpu_inst.dbg_port0_int_data",
                "cpu_and_memory_subsystem.cpu_inst.port0_int_data",
            ],
        )
        port1_int_we_sig = _first_signal(
            dut,
            [
                "cpu_and_memory_subsystem.cpu_inst.dbg_port1_int_we",
                "cpu_and_memory_subsystem.cpu_inst.port1_int_we",
            ],
        )
        port1_int_addr_sig = _first_signal(
            dut,
            [
                "cpu_and_memory_subsystem.cpu_inst.dbg_port1_int_addr",
                "cpu_and_memory_subsystem.cpu_inst.port1_int_addr",
            ],
        )
        port1_int_data_sig = _first_signal(
            dut,
            [
                "cpu_and_memory_subsystem.cpu_inst.dbg_port1_int_data",
                "cpu_and_memory_subsystem.cpu_inst.port1_int_data",
            ],
        )
        rob_commit0_reg_valid_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_rob_commit_reg_valid"
        )
        rob_commit0_reg_pc_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_rob_commit_reg_pc"
        )
        rob_commit0_reg_dest_valid_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_rob_commit_reg_dest_valid"
        )
        rob_commit0_reg_dest_rf_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_rob_commit_reg_dest_rf"
        )
        rob_commit0_reg_dest_reg_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_rob_commit_reg_dest_reg"
        )
        rob_commit1_reg_valid_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_rob_commit_2_reg_valid"
        )
        rob_commit1_reg_pc_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_rob_commit_2_reg_pc"
        )
        rob_commit1_reg_dest_valid_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_rob_commit_2_reg_dest_valid"
        )
        rob_commit1_reg_dest_rf_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_rob_commit_2_reg_dest_rf"
        )
        rob_commit1_reg_dest_reg_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_rob_commit_2_reg_dest_reg"
        )
        flush_pipeline_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.flush_pipeline"
        )
        commit_is_misprediction_live_sig = _get_signal(dut, COMMIT_MISPREDICTION_PATH)
        pd_final_instruction_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_pd_instr"
        )
        pd_program_counter_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_pd_pc"
        )
        id_program_counter_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_id_pc"
        )
        id_is_mret_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_id_is_mret"
        )
        id_instruction_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_id_instr"
        )
        if_valid_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_if_valid_q"
        )
        pd_valid_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_pd_valid_q"
        )
        id_valid_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_id_valid"
        )
        post_flush_holdoff_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_post_flush_holdoff_q"
        )
        csr_in_flight_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_csr_in_flight"
        )
        pipeline_stall_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_pipeline_stall"
        )
        pipeline_stall_registered_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_pipeline_stall_registered"
        )
        rob_full_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.rob_full"
        )
        int_rs_full_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.int_rs_full"
        )
        mul_rs_full_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.mul_rs_full"
        )
        mem_rs_full_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.mem_rs_full"
        )
        fp_rs_full_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.fp_rs_full"
        )
        fmul_rs_full_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.fmul_rs_full"
        )
        fdiv_rs_full_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.fdiv_rs_full"
        )
        lq_full_live_sig = _get_signal(dut, "cpu_and_memory_subsystem.cpu_inst.lq_full")
        sq_full_live_sig = _get_signal(dut, "cpu_and_memory_subsystem.cpu_inst.sq_full")
        rob_alloc_valid_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_rob_alloc_valid"
        )
        rob_alloc_pc_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_rob_alloc_pc"
        )
        rob_alloc_is_csr_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_rob_alloc_is_csr"
        )
        rob_alloc_is_mret_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_rob_alloc_is_mret"
        )
        if_control_flow_holdoff_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.if_stage_inst.control_flow_holdoff"
        )
        if app_name == "branch_pred_test":
            if control_flow_trace_label is None:
                control_flow_trace_label = "Branch_pred_test"
            if control_flow_trace_ranges is None:
                control_flow_trace_ranges = [(0x352, 0x358)]
        elif app_name == "ras_stress_test":
            if control_flow_trace_label is None:
                control_flow_trace_label = "RAS_stress_test"
            if control_flow_trace_ranges is None:
                control_flow_trace_ranges = [
                    (0x315C, 0x3194),
                    (0x3196, 0x32C2),
                    (0x353C, 0x35DC),
                ]

    if irq_precision_check:
        trap_taken_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.trap_taken"
        )
        trap_taken_reg_dbg_sig = _first_signal(
            dut,
            [
                "cpu_and_memory_subsystem.cpu_inst.dbg_trap_taken_q",
                "cpu_and_memory_subsystem.cpu_inst.trap_taken_reg",
            ],
        )
        # The unregistered commit bus, for the event log.
        commit_valid_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_commit_valid"
        )
        commit_pc_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_commit_pc"
        )
        commit0_dest_valid_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_commit_dest_valid"
        )
        commit0_dest_rf_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_commit_dest_rf"
        )
        commit0_dest_reg_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_commit_dest_reg"
        )
        commit0_value_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_commit_value"
        )
        commit1_valid_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_commit_2_valid"
        )
        commit1_pc_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_commit_2_pc"
        )
        commit1_dest_valid_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_commit_2_dest_valid"
        )
        commit1_dest_rf_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_commit_2_dest_rf"
        )
        commit1_dest_reg_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_commit_2_dest_reg"
        )
        commit1_value_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_commit_2_value"
        )
        trap_cause_internal_live_sig = _first_signal(
            dut,
            [
                "cpu_and_memory_subsystem.cpu_inst.dbg_trap_cause_internal",
                "cpu_and_memory_subsystem.cpu_inst.trap_cause_internal",
            ],
        )
        rob_trap_pc_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.rob_trap_pc"
        )
        trap_pc_internal_live_sig = _first_signal(
            dut,
            [
                "cpu_and_memory_subsystem.cpu_inst.dbg_trap_pc_internal",
                "cpu_and_memory_subsystem.cpu_inst.rob_trap_pc",
            ],
        )
        interrupt_resume_pc_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_interrupt_resume_pc"
        )
        csr_commit_fire_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.csr_commit_fire"
        )
        csr_mepc_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.csr_mepc"
        )
        flush_all_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.flush_all"
        )
        port0_int_we_sig = _first_signal(
            dut,
            [
                "cpu_and_memory_subsystem.cpu_inst.dbg_port0_int_we",
                "cpu_and_memory_subsystem.cpu_inst.port0_int_we",
            ],
        )
        port0_int_addr_sig = _first_signal(
            dut,
            [
                "cpu_and_memory_subsystem.cpu_inst.dbg_port0_int_addr",
                "cpu_and_memory_subsystem.cpu_inst.port0_int_addr",
            ],
        )
        port0_int_data_sig = _first_signal(
            dut,
            [
                "cpu_and_memory_subsystem.cpu_inst.dbg_port0_int_data",
                "cpu_and_memory_subsystem.cpu_inst.port0_int_data",
            ],
        )
        port1_int_we_sig = _first_signal(
            dut,
            [
                "cpu_and_memory_subsystem.cpu_inst.dbg_port1_int_we",
                "cpu_and_memory_subsystem.cpu_inst.port1_int_we",
            ],
        )
        port1_int_addr_sig = _first_signal(
            dut,
            [
                "cpu_and_memory_subsystem.cpu_inst.dbg_port1_int_addr",
                "cpu_and_memory_subsystem.cpu_inst.port1_int_addr",
            ],
        )
        port1_int_data_sig = _first_signal(
            dut,
            [
                "cpu_and_memory_subsystem.cpu_inst.dbg_port1_int_data",
                "cpu_and_memory_subsystem.cpu_inst.port1_int_data",
            ],
        )
        rob_commit0_reg_valid_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_rob_commit_reg_valid"
        )
        rob_commit0_reg_pc_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_rob_commit_reg_pc"
        )
        rob_commit0_reg_dest_valid_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_rob_commit_reg_dest_valid"
        )
        rob_commit0_reg_dest_rf_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_rob_commit_reg_dest_rf"
        )
        rob_commit0_reg_dest_reg_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_rob_commit_reg_dest_reg"
        )
        rob_commit1_reg_valid_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_rob_commit_2_reg_valid"
        )
        rob_commit1_reg_pc_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_rob_commit_2_reg_pc"
        )
        rob_commit1_reg_dest_valid_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_rob_commit_2_reg_dest_valid"
        )
        rob_commit1_reg_dest_rf_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_rob_commit_2_reg_dest_rf"
        )
        rob_commit1_reg_dest_reg_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_rob_commit_2_reg_dest_reg"
        )
        _require_signals(
            "FROST_IRQ_PRECISION_CHECK",
            {
                "trap_taken": trap_taken_live_sig,
                "dbg_trap_taken_q": trap_taken_reg_dbg_sig,
                "dbg_trap_cause_internal": trap_cause_internal_live_sig,
                "dbg_trap_pc_internal": trap_pc_internal_live_sig,
                "rob_trap_pc": rob_trap_pc_live_sig,
                "dbg_interrupt_resume_pc": interrupt_resume_pc_live_sig,
                "csr_commit_fire": csr_commit_fire_live_sig,
                "csr_mepc": csr_mepc_live_sig,
                "flush_all": flush_all_live_sig,
                "dbg_commit_valid": commit_valid_live_sig,
                "dbg_commit_pc": commit_pc_live_sig,
                "dbg_commit_dest_valid": commit0_dest_valid_sig,
                "dbg_commit_dest_rf": commit0_dest_rf_sig,
                "dbg_commit_dest_reg": commit0_dest_reg_sig,
                "dbg_commit_value": commit0_value_sig,
                "dbg_commit_2_valid": commit1_valid_sig,
                "dbg_commit_2_pc": commit1_pc_sig,
                "dbg_commit_2_dest_valid": commit1_dest_valid_sig,
                "dbg_commit_2_dest_rf": commit1_dest_rf_sig,
                "dbg_commit_2_dest_reg": commit1_dest_reg_sig,
                "dbg_commit_2_value": commit1_value_sig,
                "dbg_port0_int_we": port0_int_we_sig,
                "dbg_port0_int_addr": port0_int_addr_sig,
                "dbg_port0_int_data": port0_int_data_sig,
                "dbg_port1_int_we": port1_int_we_sig,
                "dbg_port1_int_addr": port1_int_addr_sig,
                "dbg_port1_int_data": port1_int_data_sig,
                "dbg_rob_commit_reg_valid": rob_commit0_reg_valid_sig,
                "dbg_rob_commit_reg_pc": rob_commit0_reg_pc_sig,
                "dbg_rob_commit_reg_dest_valid": rob_commit0_reg_dest_valid_sig,
                "dbg_rob_commit_reg_dest_rf": rob_commit0_reg_dest_rf_sig,
                "dbg_rob_commit_reg_dest_reg": rob_commit0_reg_dest_reg_sig,
                "dbg_rob_commit_2_reg_valid": rob_commit1_reg_valid_sig,
                "dbg_rob_commit_2_reg_pc": rob_commit1_reg_pc_sig,
                "dbg_rob_commit_2_reg_dest_valid": rob_commit1_reg_dest_valid_sig,
                "dbg_rob_commit_2_reg_dest_rf": rob_commit1_reg_dest_rf_sig,
                "dbg_rob_commit_2_reg_dest_reg": rob_commit1_reg_dest_reg_sig,
            },
        )

    retired_pc_hist: Counter[int] = Counter()
    retired_mispredicts = 0
    last_progress_mispredicts = 0
    control_flow_debug_events: list[str] = []
    checkpoint_debug_events: list[str] = []
    special_issue_events: list[str] = []
    btb_update_events: list[str] = []
    coremark_return_events: list[str] = []
    coremark_matrix_events: list[str] = []
    special_issue_limit = 80
    control_flow_debug_limit = int(
        os.environ.get(
            "FROST_CONTROL_FLOW_TRACE_LIMIT",
            "260" if app_name == "ras_stress_test" else "260",
        )
    )
    coremark_return_limit = 32
    coremark_matrix_limit = 160
    target_pc_trace = (
        int(os.environ["FROST_TARGET_PC_TRACE"], 0)
        if os.environ.get("FROST_TARGET_PC_TRACE")
        else None
    )
    target_pc_events: list[str] = []
    checkpoint_trace_enabled = os.environ.get("FROST_CHECKPOINT_TRACE") == "1"
    checkpoint_trace_limit = int(os.environ.get("FROST_CHECKPOINT_TRACE_LIMIT", "320"))
    trace_start_cycle = int(os.environ.get("FROST_TRACE_START_CYCLE", "0"))
    last_checkpoint_in_use = None
    last_rat_a0_state = None
    last_x2_commit = None
    last_x2_commit_pc = None
    last_x2_raw_commit = None
    last_x2_raw_commit_pc = None
    last_x5_commit = None
    last_x8_commit = None
    last_x9_commit = None
    last_x10_commit = None
    last_x11_commit = None
    last_x18_commit = None
    last_x19_commit = None
    control_flow_trace_enabled = True
    retire_only_trace = os.environ.get("FROST_CONTROL_FLOW_RETIRE_ONLY") == "1"
    ras_transition_trace_active = True
    irq_precision_callee_range: tuple[int, int] | None = None
    irq_precision_callee_body = 0
    external_irq_range: tuple[int, int] | None = None
    external_irq_active = False
    external_irq_hold_remaining = 0
    external_irq_pulses = 0
    external_irq_armed = True
    if irq_precision_check:
        irq_callee_symbol = os.environ.get(
            "FROST_IRQ_CALLEE_SYMBOL", "irq_stack_slot_callee"
        )
        irq_symbol_ranges = _load_symbol_ranges([irq_callee_symbol], app_name)
        irq_precision_callee_range = irq_symbol_ranges.get(irq_callee_symbol)
        if irq_precision_callee_range is not None:
            lo, hi = irq_precision_callee_range
            # The stack-pointer rule starts after the callee's first
            # instruction, its sp adjustment, which may be compressed.
            callee_code = _load_symbol_machine_code(irq_callee_symbol, app_name)
            irq_precision_callee_body = lo + callee_code.get(lo, (0, 32))[1] // 8
            cocotb.log.info(
                f"IRQ precision callee window {irq_callee_symbol}: "
                f"[0x{lo:08x}, 0x{hi:08x}), body from "
                f"0x{irq_precision_callee_body:08x}"
            )
    if external_irq_enabled and external_irq_symbol is not None:
        external_symbol_ranges = _load_symbol_ranges([external_irq_symbol], app_name)
        external_irq_range = external_symbol_ranges.get(external_irq_symbol)
        if external_irq_range is None:
            raise AssertionError(
                f"FROST_EXTERNAL_IRQ_SYMBOL={external_irq_symbol!r} not found"
            )
        lo, hi = external_irq_range
        cocotb.log.info(
            f"External IRQ injector armed for {external_irq_symbol}: "
            f"[0x{lo:08x}, 0x{hi:08x}) offset=0x{external_irq_offset:x} "
            f"max_pulses={external_irq_max_pulses}"
        )

    def in_trace_window(pc: int | None) -> bool:
        if pc is None or control_flow_trace_ranges is None:
            return False
        return any(lo <= pc <= hi for lo, hi in control_flow_trace_ranges)

    def in_coremark_matrix_window(pc: int | None) -> bool:
        if pc is None:
            return False
        return any(lo <= pc < hi for lo, hi in coremark_symbol_ranges.values())

    def coremark_symbol_name_for_pc(pc: int | None) -> str:
        if pc is None:
            return "-"
        for symbol_name, (lo, hi) in coremark_symbol_ranges.items():
            if lo <= pc < hi:
                return symbol_name
        return "-"

    def commit_writes_x1_x2_at_pc(
        valid_sig: Any | None,
        pc_sig: Any | None,
        dest_valid_sig: Any | None,
        dest_rf_sig: Any | None,
        dest_reg_sig: Any | None,
        trap_pc: int | None,
    ) -> bool:
        if trap_pc is None:
            return False
        dest_reg = _read_int(dest_reg_sig)
        return (
            bool(_read_bool(valid_sig))
            and bool(_read_bool(dest_valid_sig))
            and not bool(_read_bool(dest_rf_sig))
            and dest_reg in {1, 2}
            and _read_int(pc_sig) == trap_pc
        )

    def sample_coremark_retire_trace(cycle_number: int, slot1_pc: int) -> None:
        """Write one line per commit this cycle inside the traced function.

        Slot 1 is the ROB head, and slot 2 (head+1) retires only together with
        it. mispred marks a mispredicted branch, whichever recovery redirected
        it, and early marks one that early recovery redirected at execute.
        Slot 2 never holds a mispredicted branch, so the ROB zeroes its
        misprediction and predicted_taken fields; a slot-2 branch went the way
        it was predicted, so its pred_taken is its branch_taken.
        """
        nonlocal coremark_retire_trace_count
        assert coremark_retire_trace_file is not None
        assert coremark_retire_commits is not None
        assert coremark_matrix_base_pc is not None
        assert coremark_matrix_last_pc is not None
        commits = [(1, slot1_pc)]
        if _read_bool(coremark_retire_slot2_valid_sig):
            slot2_pc = _read_int(coremark_retire_slot2_pc_sig)
            if slot2_pc is not None:
                commits.append((2, slot2_pc))
        for slot, pc in commits:
            if (
                not coremark_matrix_base_pc <= pc <= coremark_matrix_last_pc
                or coremark_retire_trace_count >= coremark_retire_trace_limit
            ):
                continue
            commit = coremark_retire_commits[slot - 1]
            packed = commit.read()
            if packed is None:
                raise AssertionError(
                    f"Retire trace: the slot-{slot} commit bus is unresolvable "
                    f"at cycle={cycle_number}"
                )
            branch_taken = commit.field(packed, "branch_taken")
            predicted_taken = (
                commit.field(packed, "predicted_taken") if slot == 1 else branch_taken
            )
            coremark_retire_trace_file.write(
                f"cycle={cycle_number} slot={slot} pc=0x{pc:08x} "
                f"off=0x{(pc - coremark_matrix_base_pc):04x} "
                f"mispred={commit.field(packed, 'misprediction')} "
                f"early={commit.field(packed, 'early_recovered')} "
                f"pred_taken={predicted_taken} branch_taken={branch_taken}\n"
            )
            coremark_retire_trace_count += 1

    def close_coremark_retire_trace() -> None:
        if coremark_retire_trace_file is None:
            return
        coremark_retire_trace_file.close()
        cocotb.log.info(
            f"Run {run_number}: wrote {coremark_retire_trace_count} retire samples "
            f"of {coremark_retire_trace_symbol} to {coremark_retire_trace_path}"
        )

    for cycle in range(max_cycles):
        await RisingEdge(dut.i_clk)
        if external_irq_enabled and hasattr(dut, "i_external_interrupt"):
            if external_irq_active:
                if external_irq_hold_remaining > 0:
                    external_irq_hold_remaining -= 1
                if trap_taken_live_sig is not None and bool(
                    _read_bool(trap_taken_live_sig)
                ):
                    external_irq_hold_remaining = 0
                if external_irq_hold_remaining == 0:
                    dut.i_external_interrupt.value = 0
                    external_irq_active = False
                    external_irq_armed = False

            if (
                not external_irq_active
                and external_irq_armed
                and external_irq_range is not None
                and external_irq_pulses < external_irq_max_pulses
            ):
                retire_valid = bool(_read_bool(retire_sig))
                retire_pc = _read_int(retire_pc_sig)
                lo, hi = external_irq_range
                trigger_pc = lo + external_irq_offset
                if (
                    retire_valid
                    and retire_pc is not None
                    and trigger_pc <= retire_pc < hi
                ):
                    dut.i_external_interrupt.value = 1
                    external_irq_active = True
                    external_irq_hold_remaining = max(1, external_irq_hold_cycles)
                    external_irq_pulses += 1
                    cocotb.log.info(
                        f"External IRQ pulse {external_irq_pulses} at "
                        f"cycle={cycle + 1} retire_pc=0x{retire_pc:08x}"
                    )

            if (
                not external_irq_armed
                and external_irq_range is not None
                and external_irq_pulses < external_irq_max_pulses
            ):
                retire_pc = _read_int(retire_pc_sig)
                lo, hi = external_irq_range
                if retire_pc is None or not (lo <= retire_pc < hi):
                    external_irq_armed = True

        if irq_precision_check:
            raw_x2_events = []
            for (
                valid_sig,
                pc_sig,
                dest_valid_sig,
                dest_rf_sig,
                dest_reg_sig,
                value_sig,
            ) in (
                (
                    commit_valid_live_sig,
                    commit_pc_live_sig,
                    commit0_dest_valid_sig,
                    commit0_dest_rf_sig,
                    commit0_dest_reg_sig,
                    commit0_value_sig,
                ),
                (
                    commit1_valid_sig,
                    commit1_pc_sig,
                    commit1_dest_valid_sig,
                    commit1_dest_rf_sig,
                    commit1_dest_reg_sig,
                    commit1_value_sig,
                ),
            ):
                if (
                    bool(_read_bool(valid_sig))
                    and bool(_read_bool(dest_valid_sig))
                    and not bool(_read_bool(dest_rf_sig))
                    and _read_int(dest_reg_sig) == 2
                ):
                    value = _read_int(value_sig)
                    pc = _read_int(pc_sig)
                    last_x2_raw_commit = value
                    last_x2_raw_commit_pc = pc
                    raw_x2_events.append(f"0x{(value or 0):08x}@0x{(pc or 0):08x}")

            current_x2_commit = last_x2_commit
            current_x2_commit_pc = last_x2_commit_pc
            wb_x2_events = []
            for port_name, we_sig, addr_sig, data_sig, pc_sig in (
                (
                    "p0",
                    port0_int_we_sig,
                    port0_int_addr_sig,
                    port0_int_data_sig,
                    rob_commit0_reg_pc_sig,
                ),
                (
                    "p1",
                    port1_int_we_sig,
                    port1_int_addr_sig,
                    port1_int_data_sig,
                    rob_commit1_reg_pc_sig,
                ),
            ):
                if bool(_read_bool(we_sig)) and _read_int(addr_sig) == 2:
                    value = _read_int(data_sig)
                    pc = _read_int(pc_sig)
                    current_x2_commit = value
                    current_x2_commit_pc = pc
                    wb_x2_events.append(
                        f"{port_name}=0x{(value or 0):08x}@0x{(pc or 0):08x}"
                    )

            # The take-cycle state is read only when an interrupt is taken,
            # which keeps the check's per-cycle cost to a few handles.
            trap = bool(_read_bool(trap_taken_live_sig))
            trap_cause = _read_int(trap_cause_internal_live_sig) if trap else None
            is_irq = bool((trap_cause or 0) & MCAUSE_INTERRUPT_BIT)
            if is_irq:
                irq_take_count += 1
                trap_q = bool(_read_bool(trap_taken_reg_dbg_sig))
                flush_all = bool(_read_bool(flush_all_live_sig))
                trap_pc = _read_int(trap_pc_internal_live_sig)
                rob_trap_pc = _read_int(rob_trap_pc_live_sig)
                interrupt_resume_pc = _read_int(interrupt_resume_pc_live_sig)
                c0_valid = bool(_read_bool(commit_valid_live_sig))
                c1_valid = bool(_read_bool(commit1_valid_sig))
                c0_pc = _read_int(commit_pc_live_sig)
                c1_pc = _read_int(commit1_pc_sig)
                reg0_sensitive = commit_writes_x1_x2_at_pc(
                    rob_commit0_reg_valid_sig,
                    rob_commit0_reg_pc_sig,
                    rob_commit0_reg_dest_valid_sig,
                    rob_commit0_reg_dest_rf_sig,
                    rob_commit0_reg_dest_reg_sig,
                    trap_pc,
                )
                reg1_sensitive = commit_writes_x1_x2_at_pc(
                    rob_commit1_reg_valid_sig,
                    rob_commit1_reg_pc_sig,
                    rob_commit1_reg_dest_valid_sig,
                    rob_commit1_reg_dest_rf_sig,
                    rob_commit1_reg_dest_reg_sig,
                    trap_pc,
                )

                stale_sp_body = False
                if trap_pc is not None and irq_precision_callee_range:
                    callee_lo, callee_hi = irq_precision_callee_range
                    x2_from_callee = (
                        current_x2_commit_pc is not None
                        and callee_lo <= current_x2_commit_pc < callee_hi
                    )
                    stale_sp_body = (
                        irq_precision_callee_body <= trap_pc < callee_hi
                        and not x2_from_callee
                    )

                event = (
                    f"IRQ precision event cycle={cycle + 1} "
                    f"cause=0x{(trap_cause or 0):08x} trap_pc=0x{(trap_pc or 0):08x} "
                    f"rob_pc=0x{(rob_trap_pc or 0):08x} "
                    f"resume_pc=0x{(interrupt_resume_pc or 0):08x} "
                    f"c0={int(c0_valid)} pc0=0x{(c0_pc or 0):08x} "
                    f"rd0={_read_int(commit0_dest_reg_sig)} "
                    f"c1={int(c1_valid)} pc1=0x{(c1_pc or 0):08x} "
                    f"rd1={_read_int(commit1_dest_reg_sig)} "
                    f"p0we={int(bool(_read_bool(port0_int_we_sig)))} "
                    f"p0a={_read_int(port0_int_addr_sig)} "
                    f"p0d=0x{(_read_int(port0_int_data_sig) or 0):08x} "
                    f"p0pc=0x{(_read_int(rob_commit0_reg_pc_sig) or 0):08x} "
                    f"p1we={int(bool(_read_bool(port1_int_we_sig)))} "
                    f"p1a={_read_int(port1_int_addr_sig)} "
                    f"p1d=0x{(_read_int(port1_int_data_sig) or 0):08x} "
                    f"p1pc=0x{(_read_int(rob_commit1_reg_pc_sig) or 0):08x} "
                    f"csr_fire={int(bool(_read_bool(csr_commit_fire_live_sig)))} "
                    f"trap_q={int(trap_q)} flush_all={int(flush_all)} "
                    f"mepc=0x{(_read_int(csr_mepc_live_sig) or 0):08x} "
                    f"last_x2_arch=0x{(current_x2_commit or 0):08x} "
                    f"last_x2_arch_pc=0x{(current_x2_commit_pc or 0):08x} "
                    f"last_x2_raw=0x{(last_x2_raw_commit or 0):08x} "
                    f"last_x2_raw_pc=0x{(last_x2_raw_commit_pc or 0):08x} "
                    f"raw_x2_now={','.join(raw_x2_events) or '-'} "
                    f"wb_x2_now={','.join(wb_x2_events) or '-'}"
                )
                if len(irq_precision_events) < irq_precision_event_limit:
                    irq_precision_events.append(event)
                    cocotb.log.info(event)

                # Only the registered commit bus counts. An unregistered
                # commit can share the take cycle; the full flush that follows
                # masks it on the registered bus (commit_bus_pipeline), and
                # the instruction at the saved PC runs again after the handler.
                # A registered commit has already advanced
                # interrupt_resume_pc, so the rule also flags a correct take
                # inside a one- or two-instruction loop whose first
                # instruction writes x1 or x2.
                sensitive_pc_write = reg0_sensitive or reg1_sensitive
                if irq_precision_strict and (sensitive_pc_write or stale_sp_body):
                    raise AssertionError(
                        "IRQ precision violation: "
                        f"x1_x2_same_pc={sensitive_pc_write} "
                        f"stale_sp_body={stale_sp_body}; {event}"
                    )

            if irq_low_ra_assert:
                low_ra_events = []
                for port_name, we_sig, addr_sig, data_sig in (
                    ("p0", port0_int_we_sig, port0_int_addr_sig, port0_int_data_sig),
                    ("p1", port1_int_we_sig, port1_int_addr_sig, port1_int_data_sig),
                ):
                    if bool(_read_bool(we_sig)) and _read_int(addr_sig) == 1:
                        data_value = _read_int(data_sig)
                        if data_value is not None and data_value < 0x1000:
                            low_ra_events.append(f"{port_name}=0x{data_value:08x}")
                if low_ra_events:
                    cause_now = _read_int(trap_cause_internal_live_sig) or 0
                    raise AssertionError(
                        "Low RA writeback under IRQ monitor: "
                        f"cycle={cycle + 1} {' '.join(low_ra_events)} "
                        f"trap={int(trap)} "
                        f"irq={int(bool(cause_now & MCAUSE_INTERRUPT_BIT))} "
                        f"cause=0x{cause_now:08x} "
                        f"trap_pc=0x{(_read_int(trap_pc_internal_live_sig) or 0):08x} "
                        f"mepc=0x{(_read_int(csr_mepc_live_sig) or 0):08x}"
                    )

        for we_sig, addr_sig, data_sig, pc_sig in (
            (
                port0_int_we_sig,
                port0_int_addr_sig,
                port0_int_data_sig,
                rob_commit0_reg_pc_sig,
            ),
            (
                port1_int_we_sig,
                port1_int_addr_sig,
                port1_int_data_sig,
                rob_commit1_reg_pc_sig,
            ),
        ):
            if bool(_read_bool(we_sig)) and _read_int(addr_sig) == 2:
                last_x2_commit = _read_int(data_sig)
                last_x2_commit_pc = _read_int(pc_sig)

        if _read_bool(int_rf_write_enable_sig):
            commit_addr = _read_int(int_rf_write_addr_sig)
            commit_data = _read_int(int_rf_write_data_sig)
            if commit_addr == 2:
                last_x2_commit = commit_data
            elif commit_addr == 5:
                last_x5_commit = commit_data
            elif commit_addr == 8:
                last_x8_commit = commit_data
            elif commit_addr == 9:
                last_x9_commit = commit_data
            elif commit_addr == 10:
                last_x10_commit = commit_data
            elif commit_addr == 11:
                last_x11_commit = commit_data
            elif commit_addr == 18:
                last_x18_commit = commit_data
            elif commit_addr == 19:
                last_x19_commit = commit_data
            if (
                control_flow_trace_label is not None
                and commit_addr == 13
                and len(control_flow_debug_events) < control_flow_debug_limit
            ):
                commit_pc = _read_int(commit_pc_live_sig)
                if in_trace_window(commit_pc):
                    control_flow_debug_events.append(
                        "wrx13  "
                        f"cycle={cycle + 1} "
                        f"data=0x{(commit_data or 0):08x} "
                        f"commit_pc=0x{(commit_pc or 0):08x} "
                        f"commit_v={int(bool(_read_bool(commit_valid_live_sig)))}"
                    )
        if _read_bool(retire_sig):
            retired_count += 1
            retire_pc = _read_int(retire_pc_sig)
            if retire_pc is not None:
                retired_pc_hist[retire_pc] += 1
                if (
                    coremark_retire_trace_file is not None
                    and coremark_retire_trace_count < coremark_retire_trace_limit
                ):
                    sample_coremark_retire_trace(cycle + 1, retire_pc)
                if (
                    is_coremark_like
                    and len(coremark_return_events) < coremark_return_limit
                ):
                    return_name = coremark_symbol_name_for_pc(retire_pc)
                    if return_name != "-":
                        coremark_return_events.append(
                            f"cycle={cycle + 1} sym={return_name} "
                            f"pc=0x{retire_pc:08x} "
                            f"a0=0x{(last_x10_commit or 0):08x} "
                            f"a1=0x{(last_x11_commit or 0):08x} "
                            f"x19=0x{(last_x19_commit or 0):08x}"
                        )
            if _read_bool(retire_mispredict_sig):
                retired_mispredicts += 1
            if target_pc_trace is not None and len(target_pc_events) < 128:
                if retire_pc == target_pc_trace:
                    target_pc_events.append(
                        "retire   "
                        f"cycle={cycle + 1} pc=0x{target_pc_trace:08x} "
                        f"mispred={_read_bool(retire_mispredict_sig)} "
                        f"a0_valid={_read_bool(rat_a0_valid_sig)} "
                        f"a0_tag={_read_int(rat_a0_tag_sig)}"
                    )
                if (
                    _read_bool(head_valid_live_sig)
                    and _read_int(head_pc_live_sig) == target_pc_trace
                ):
                    target_pc_events.append(
                        "head     "
                        f"cycle={cycle + 1} pc=0x{target_pc_trace:08x} "
                        f"done={_read_bool(head_done_live_sig)} "
                        f"tag={_read_int(head_tag_live_sig)} "
                        f"a0_valid={_read_bool(rat_a0_valid_sig)} "
                        f"a0_tag={_read_int(rat_a0_tag_sig)}"
                    )
            if (
                control_flow_trace_label is not None
                and control_flow_trace_enabled
                and ras_transition_trace_active
                and in_trace_window(retire_pc)
                and len(control_flow_debug_events) < control_flow_debug_limit
            ):
                pc = _read_int(pc_sig)
                control_flow_debug_events.append(
                    "retire "
                    f"cycle={cycle + 1} "
                    f"x2={last_x2_commit} "
                    f"x5={last_x5_commit} "
                    f"x8={last_x8_commit} "
                    f"x9={last_x9_commit} "
                    f"x10={last_x10_commit} "
                    f"x11={last_x11_commit} "
                    f"x19={last_x19_commit} "
                    f"retire_pc=0x{retire_pc:08x} "
                    f"fetch_pc=0x{(pc or 0):08x} "
                    f"pred_off={_read_bool(branch_pred_off_sig)} "
                    f"cf_hold={_read_bool(if_control_flow_holdoff_sig)} "
                    f"br_taken={_read_bool(branch_taken_live_sig)} "
                    f"br_target=0x{(_read_int(branch_target_live_sig) or 0):08x} "
                    f"btb_hit={_read_bool(btb_hit_sig)} "
                    f"btb_pred_taken={_read_bool(btb_pred_taken_sig)} "
                    f"pred_used={_read_bool(pred_used_sig)} "
                    f"pred_holdoff={_read_bool(pred_holdoff_sig)} "
                    f"if_ras={_read_bool(if_ras_pred_sig)} "
                    f"pd_ras={_read_bool(pd_ras_pred_sig)} "
                    f"id_ras={_read_bool(id_ras_pred_sig)} "
                    f"mispredict={_read_bool(retire_mispredict_sig)} "
                    f"redirect_pc=0x{(_read_int(redirect_pc_sig) or 0):08x}"
                )

        if target_pc_trace is not None and len(target_pc_events) < 128:
            rat_a0_state = (
                _read_bool(rat_a0_valid_sig),
                _read_int(rat_a0_tag_sig),
            )
            if cycle + 1 >= trace_start_cycle and rat_a0_state != last_rat_a0_state:
                target_pc_events.append(
                    "a0state  "
                    f"cycle={cycle + 1} "
                    f"a0_valid={rat_a0_state[0]} "
                    f"a0_tag={rat_a0_state[1]} "
                    f"last_alloc_pc=0x{(_read_int(last_a0_alloc_pc_sig) or 0):08x} "
                    f"last_alloc_tag={_read_int(last_a0_alloc_tag_sig)}"
                )
            last_rat_a0_state = rat_a0_state
            if _read_bool(rs_dispatch_valid_live_sig):
                dispatch_pc = _read_int(rs_dispatch_pc_live_sig)
                if dispatch_pc == target_pc_trace:
                    target_pc_events.append(
                        "dispatch "
                        f"cycle={cycle + 1} "
                        f"pc=0x{dispatch_pc:08x} "
                        f"rob_tag={_read_int(rs_dispatch_rob_tag_live_sig)} "
                        f"s1_ready={_read_bool(rs_dispatch_src1_ready_live_sig)} "
                        f"s1_tag={_read_int(rs_dispatch_src1_tag_live_sig)} "
                        f"s2_ready={_read_bool(rs_dispatch_src2_ready_live_sig)} "
                        f"s2_tag={_read_int(rs_dispatch_src2_tag_live_sig)} "
                        f"a0_valid={_read_bool(rat_a0_valid_sig)} "
                        f"a0_tag={_read_int(rat_a0_tag_sig)}"
                    )
            if (
                _read_bool(issue_valid_live_sig)
                and _read_int(issue_pc_live_sig) == target_pc_trace
            ):
                target_pc_events.append(
                    "issue    "
                    f"cycle={cycle + 1} pc=0x{target_pc_trace:08x} "
                    f"a0_valid={_read_bool(rat_a0_valid_sig)} "
                    f"a0_tag={_read_int(rat_a0_tag_sig)}"
                )
            if cycle + 1 >= trace_start_cycle:
                if _read_bool(rat_a0_alloc_hit_sig):
                    target_pc_events.append(
                        "a0alloc  "
                        f"cycle={cycle + 1} "
                        f"pc=0x{(_read_int(rob_alloc_pc_live_sig) or 0):08x} "
                        f"rat_v={_read_bool(rat_alloc_valid_sig)} "
                        f"rat_rf={_read_bool(rat_alloc_dest_rf_sig)} "
                        f"rat_reg={_read_int(rat_alloc_dest_reg_sig)} "
                        f"rat_tag={_read_int(rat_alloc_rob_tag_sig)} "
                        f"a0_valid={_read_bool(rat_a0_valid_sig)} "
                        f"a0_tag={_read_int(rat_a0_tag_sig)}"
                    )
                if _read_bool(rat_a0_commit_hit_sig):
                    target_pc_events.append(
                        "a0commit "
                        f"cycle={cycle + 1} "
                        f"tag_match={_read_bool(rat_a0_commit_tag_match_sig)} "
                        f"a0_valid={_read_bool(rat_a0_valid_sig)} "
                        f"a0_tag={_read_int(rat_a0_tag_sig)}"
                    )

        if (
            coremark_if_check_enabled
            and coremark_if_check_slot2 is not None
            and _read_bool(coremark_if_check_alloc_sig)
        ):
            # Compare each instruction as it dispatches: the decoded bundle
            # queue pops its head bundle when ROB allocation fires, and slot
            # 2 dispatches with slot 1 exactly when its is_not_nop bit is
            # set. A slot-2 instruction follows slot 1 sequentially (a slot-1
            # branch ends the bundle), so slot 2 is read only near the
            # function. A compressed instruction reaches decode expanded, so
            # 16-bit parcels are skipped. CoreMark takes no fetch faults, so
            # every dispatched packet holds the word fetched from its PC.
            slot1_pc = _read_int(id_pc_sig)
            dispatched = [(1, slot1_pc, _read_int(id_instr_sig))]
            if (
                slot1_pc is not None
                and coremark_if_check_lo - 4 <= slot1_pc < coremark_if_check_hi
            ):
                slot2 = coremark_if_check_slot2
                packet_2 = slot2.read()
                if packet_2 is None:
                    raise AssertionError(
                        f"CoreMark IF check: from_id_to_ex_2 is unresolvable at "
                        f"cycle={cycle + 1}"
                    )
                if slot2.field(packet_2, "is_not_nop"):
                    dispatched.append(
                        (
                            2,
                            slot2.field(packet_2, "program_counter"),
                            slot2.field(packet_2, "instruction"),
                        )
                    )
            for slot, dispatch_pc, dispatch_instr in dispatched:
                if dispatch_pc is None:
                    continue
                expected = coremark_matrix_expected.get(dispatch_pc)
                if expected is None or expected[1] != 32:
                    continue
                coremark_if_check_count += 1
                if dispatch_instr != expected[0]:
                    raise AssertionError(
                        f"CoreMark IF check mismatch at cycle={cycle + 1}: "
                        f"dispatch slot {slot} pc=0x{dispatch_pc:08x} holds "
                        f"0x{(dispatch_instr or 0):08x}, sw.S has "
                        f"0x{expected[0]:08x}"
                    )

        if is_coremark_like and len(coremark_matrix_events) < coremark_matrix_limit:
            if_pc = _read_int(if_pc_sig)
            pd_pc = _read_int(pd_pc_sig)
            id_pc = _read_int(id_pc_sig)
            issue_pc = _read_int(issue_pc_sig) if _read_bool(issue_valid_sig) else None
            retire_pc = _read_int(retire_pc_sig) if _read_bool(retire_sig) else None
            if any(
                in_coremark_matrix_window(stage_pc)
                for stage_pc in (if_pc, pd_pc, id_pc, issue_pc, retire_pc)
            ):
                coremark_matrix_events.append(
                    f"cycle={cycle + 1} "
                    f"if={coremark_symbol_name_for_pc(if_pc)}:0x{(if_pc or 0):08x} "
                    f"nop={int(bool(_read_bool(if_sel_nop_sig)))} "
                    f"raw=0x{(_read_int(if_raw_parcel_sig) or 0):04x} "
                    f"pd={coremark_symbol_name_for_pc(pd_pc)}:0x{(pd_pc or 0):08x} "
                    f"insn=0x{(_read_int(pd_instr_sig) or 0):08x} "
                    f"id={coremark_symbol_name_for_pc(id_pc)}:0x{(id_pc or 0):08x} "
                    f"op={_read_int(id_op_sig)} "
                    f"issue_v={int(bool(_read_bool(issue_valid_sig)))} "
                    f"issue={coremark_symbol_name_for_pc(issue_pc)}:0x{(issue_pc or 0):08x} "
                    f"retire_v={int(bool(_read_bool(retire_sig)))} "
                    f"retire={coremark_symbol_name_for_pc(retire_pc)}:0x{(retire_pc or 0):08x} "
                    f"x10=0x{(last_x10_commit or 0):08x} "
                    f"x11=0x{(last_x11_commit or 0):08x}"
                )

        if (
            app_name == "ras_stress_test"
            and ras_transition_trace_active
            and _read_bool(issue_valid_sig)
            and _read_int(issue_pc_sig)
            in {
                0x3174,
                0x3176,
                0x317C,
                0x318E,
                0x3194,
                0x31C2,
                0x31CA,
                0x31DE,
                0x31F2,
                0x3204,
                0x3218,
                0x322C,
                0x3240,
                0x3254,
                0x3266,
                0x327A,
                0x3290,
                0x32A2,
                0x353C,
                0x3542,
                0x3552,
                0x3562,
                0x3572,
            }
            and len(special_issue_events) < special_issue_limit
        ):
            special_issue_events.append(
                "issue* "
                f"cycle={cycle + 1} "
                f"x2={last_x2_commit} "
                f"x5={last_x5_commit} "
                f"x8={last_x8_commit} "
                f"x9={last_x9_commit} "
                f"x10={last_x10_commit} "
                f"x11={last_x11_commit} "
                f"x19={last_x19_commit} "
                f"pc=0x{(_read_int(issue_pc_sig) or 0):08x} "
                f"pred_taken={_read_bool(issue_pred_taken_sig)}"
            )

        if app_name == "ras_stress_test" and _read_bool(btb_update_sig):
            update_pc = _read_int(btb_update_pc_sig)
            if update_pc in {
                0x3174,
                0x3176,
                0x317C,
                0x318E,
                0x3194,
                0x31C2,
                0x31CA,
                0x31DE,
                0x31F2,
                0x3204,
                0x3218,
                0x322C,
                0x3240,
                0x3254,
                0x3266,
                0x327A,
                0x3290,
                0x32A2,
                0x353C,
                0x3542,
                0x3546,
                0x3550,
                0x3552,
                0x3556,
                0x3558,
                0x3562,
            }:
                btb_update_events.append(
                    "btbupd* "
                    f"cycle={cycle + 1} "
                    f"x8={last_x8_commit} "
                    f"x9={last_x9_commit} "
                    f"pc=0x{(update_pc or 0):08x} "
                    f"tgt=0x{(_read_int(btb_update_target_sig) or 0):08x} "
                    f"taken={_read_bool(btb_update_taken_sig)} "
                    f"comp={_read_bool(btb_update_compressed_sig)}"
                )

        if (
            checkpoint_trace_enabled
            and cycle + 1 >= trace_start_cycle
            and len(checkpoint_debug_events) < checkpoint_trace_limit
        ):
            checkpoint_in_use = _read_int(checkpoint_in_use_sig)
            checkpoint_event = (
                _read_bool(checkpoint_save_sig)
                or _read_bool(checkpoint_restore_sig)
                or _read_bool(checkpoint_free_sig)
                or (checkpoint_in_use != last_checkpoint_in_use)
            )
            if checkpoint_event:
                event = (
                    "ckpt   "
                    f"cycle={cycle + 1} "
                    f"in_use=0b{(checkpoint_in_use or 0):0{CHECKPOINT_TRACE_WIDTH}b} "
                    f"avail={_read_bool(checkpoint_available_sig)} "
                    f"alloc_id={_read_int(checkpoint_alloc_id_sig)} "
                    f"save={_read_bool(checkpoint_save_sig)} "
                    f"save_id={_read_int(checkpoint_id_sig)} "
                    f"restore={_read_bool(checkpoint_restore_sig)} "
                    f"restore_id={_read_int(checkpoint_restore_id_sig)} "
                    f"free={_read_bool(checkpoint_free_sig)} "
                    f"free_id={_read_int(checkpoint_free_id_sig)} "
                    f"flush_pend=0b{(_read_int(checkpoint_flush_pending_sig) or 0):0{CHECKPOINT_TRACE_WIDTH}b} "
                    f"early_recov={_read_bool(early_mispredict_pending_sig)} "
                    f"commit_recov={_read_bool(mispredict_recovery_pending_sig)} "
                    f"correct_commit={_read_bool(correct_branch_commit_pending_sig)} "
                    f"flush_en={_read_bool(flush_en_live_sig)} "
                    f"flush_tag={_read_int(flush_tag_live_sig)} "
                    f"commit_pc=0x{(_read_int(commit_pc_live_sig) or 0):08x} "
                    f"commit_ckpt={_read_int(commit_checkpoint_id_live_sig)} "
                    f"commit_has_ckpt={_read_bool(commit_has_checkpoint_live_sig)}"
                )
                checkpoint_debug_events.append(event)
                cocotb.log.info(event)
            last_checkpoint_in_use = checkpoint_in_use

        if (
            control_flow_trace_label is not None
            and control_flow_trace_enabled
            and ras_transition_trace_active
            and len(control_flow_debug_events) < control_flow_debug_limit
            and not retire_only_trace
        ):
            issue_pc = _read_int(issue_pc_sig) if _read_bool(issue_valid_sig) else None
            if in_trace_window(issue_pc):
                control_flow_debug_events.append(
                    "issue  "
                    f"cycle={cycle + 1} "
                    f"x2={last_x2_commit} "
                    f"x5={last_x5_commit} "
                    f"x8={last_x8_commit} "
                    f"x9={last_x9_commit} "
                    f"x10={last_x10_commit} "
                    f"x11={last_x11_commit} "
                    f"x19={last_x19_commit} "
                    f"pc=0x{(issue_pc or 0):08x} "
                    f"pred_taken={_read_bool(issue_pred_taken_sig)}"
                )
            update_pc = _read_int(btb_update_pc_sig)
            if _read_bool(btb_update_sig) and in_trace_window(update_pc):
                control_flow_debug_events.append(
                    "btbupd "
                    f"cycle={cycle + 1} "
                    f"x8={last_x8_commit} "
                    f"x9={last_x9_commit} "
                    f"pc=0x{(update_pc or 0):08x} "
                    f"tgt=0x{(_read_int(btb_update_target_sig) or 0):08x} "
                    f"taken={_read_bool(btb_update_taken_sig)} "
                    f"comp={_read_bool(btb_update_compressed_sig)}"
                )
            pc = _read_int(pc_sig)
            if in_trace_window(pc):
                control_flow_debug_events.append(
                    "fetch  "
                    f"cycle={cycle + 1} "
                    f"x2={last_x2_commit} "
                    f"x5={last_x5_commit} "
                    f"x8={last_x8_commit} "
                    f"x9={last_x9_commit} "
                    f"x10={last_x10_commit} "
                    f"x11={last_x11_commit} "
                    f"x19={last_x19_commit} "
                    f"fetch_pc=0x{pc:08x} "
                    f"pc_vld={_read_bool(pc_vld_sig)} "
                    f"if_pc=0x{(_read_int(if_pc_live_sig) or 0):08x} "
                    f"if_pc_reg=0x{(_read_int(if_pc_reg_live_sig) or 0):08x} "
                    f"raw=0x{(_read_int(if_raw_parcel_live_sig) or 0):04x} "
                    f"eff=0x{(_read_int(if_effective_instr_sig) or 0):08x} "
                    f"sel_nop={_read_bool(if_sel_nop_live_sig)} "
                    f"sel_comp={_read_bool(if_sel_compressed_sig)} "
                    f"is32span={_read_bool(if_is_32bit_spanning_sig)} "
                    f"span_wait={_read_bool(if_spanning_wait_sig)} "
                    f"span_run={_read_bool(if_spanning_in_progress_sig)} "
                    f"use_buf={_read_bool(if_use_instr_buffer_sig)} "
                    f"prev_lo={_read_bool(if_prev_compressed_lo_sig)} "
                    f"prev32={_read_bool(pc_prev_was_32bit_sig)} "
                    f"seq_next_pc_reg=0x{(_read_int(pc_seq_next_pc_reg_sig) or 0):08x} "
                    f"next_pc_reg=0x{(_read_int(pc_next_pc_reg_sig) or 0):08x} "
                    f"pred_off={_read_bool(branch_pred_off_sig)} "
                    f"stall={_read_bool(if_stall_sig)} "
                    f"stall_r={_read_bool(if_stall_registered_sig)} "
                    f"dispatch_stall={_read_bool(dispatch_stall_sig)} "
                    f"fe_ser_stall={_read_bool(front_end_cf_serialize_stall_sig)} "
                    f"stall_q={_read_bool(front_end_stall_q_sig)} "
                    f"replay_q={_read_bool(replay_after_dispatch_stall_q_sig)} "
                    f"replay_ser_q={_read_bool(replay_after_serialize_stall_q_sig)} "
                    f"cf_hold={_read_bool(if_control_flow_holdoff_sig)} "
                    f"br_taken={_read_bool(branch_taken_live_sig)} "
                    f"br_target=0x{(_read_int(branch_target_live_sig) or 0):08x} "
                    f"btb_hit={_read_bool(btb_hit_sig)} "
                    f"btb_pred_taken={_read_bool(btb_pred_taken_sig)} "
                    f"pred_used={_read_bool(pred_used_sig)} "
                    f"pred_holdoff={_read_bool(pred_holdoff_sig)} "
                    f"pend_active={_read_bool(pending_prediction_active_sig)} "
                    f"pend_fetch_hold={_read_bool(pending_prediction_fetch_holdoff_sig)} "
                    f"if_ras={_read_bool(if_ras_pred_sig)} "
                    f"if_ckpt={_read_int(if_ras_ckpt_tos_sig)}/{_read_int(if_ras_ckpt_vc_sig)} "
                    f"pd_ckpt={_read_int(pd_ras_ckpt_tos_sig)}/{_read_int(pd_ras_ckpt_vc_sig)} "
                    f"id_ckpt={_read_int(id_ras_ckpt_tos_sig)}/{_read_int(id_ras_ckpt_vc_sig)} "
                    f"ras_call={_read_bool(ras_is_call_sig)} "
                    f"ras_ret={_read_bool(ras_is_return_sig)} "
                    f"ras_tgt=0x{(_read_int(ras_target_live_sig) or 0):08x} "
                    f"ras_tos={_read_int(ras_tos_sig)} "
                    f"ras_vc={_read_int(ras_valid_count_sig)} "
                    f"ras_do_pop={_read_bool(ras_do_pop_sig)} "
                    f"ras_do_push={_read_bool(ras_do_push_sig)} "
                    f"ras_cap={_read_bool(ras_capture_inputs_sig)} "
                    f"ras_wen={_read_bool(ras_write_enable_sig)} "
                    f"ras_wdata=0x{(_read_int(ras_write_data_sig) or 0):08x} "
                    f"link=0x{(_read_int(ras_link_address_sig) or 0):08x} "
                    f"ras_restore={_read_bool(ras_misprediction_live_sig)} "
                    f"ras_rt_tos={_read_int(ras_restore_tos_live_sig)} "
                    f"ras_rt_vc={_read_int(ras_restore_valid_count_live_sig)} "
                    f"ras_rt_pop={_read_bool(ras_pop_after_restore_live_sig)} "
                    f"commit_v={_read_bool(commit_valid_live_sig)} "
                    f"commit_pc=0x{(_read_int(commit_pc_live_sig) or 0):08x} "
                    f"commit_ret={_read_bool(commit_is_return_live_sig)} "
                    f"commit_call={_read_bool(commit_is_call_live_sig)} "
                    f"commit_ckpt={_read_int(commit_checkpoint_id_live_sig)} "
                    f"commit_has_ckpt={_read_bool(commit_has_checkpoint_live_sig)} "
                    f"commit_pred={_read_bool(commit_predicted_taken_live_sig)} "
                    f"commit_taken={_read_bool(commit_branch_taken_live_sig)} "
                    f"commit_misp={_read_bool(retire_mispredict_sig)} "
                    f"commit_mret={_read_bool(commit_is_mret_live_sig)} "
                    f"trap_pend={_read_bool(trap_pending_live_sig)} "
                    f"trap_pc=0x{(_read_int(rob_trap_pc_live_sig) or 0):08x} "
                    f"trap_cause=0x{(_read_int(rob_trap_cause_live_sig) or 0):08x} "
                    f"trap_taken={_read_bool(trap_taken_live_sig)} "
                    f"mret_start={_read_bool(mret_start_live_sig)} "
                    f"mret_taken={_read_bool(mret_taken_live_sig)} "
                    f"trap_tgt=0x{(_read_int(trap_target_live_sig) or 0):08x} "
                    f"csr_fire={_read_bool(csr_commit_fire_live_sig)} "
                    f"mtvec=0x{(_read_int(csr_mtvec_live_sig) or 0):08x} "
                    f"mepc=0x{(_read_int(csr_mepc_live_sig) or 0):08x} "
                    f"flush={_read_bool(flush_pipeline_live_sig)} "
                    f"commit_flush={_read_bool(commit_is_misprediction_live_sig)} "
                    f"pd_pc=0x{(_read_int(pd_program_counter_live_sig) or 0):08x} "
                    f"pd_instr=0x{(_read_int(pd_final_instruction_live_sig) or 0):08x} "
                    f"id_pc=0x{(_read_int(id_program_counter_live_sig) or 0):08x} "
                    f"id_instr=0x{(_read_int(id_instruction_live_sig) or 0):08x} "
                    f"id_mret={_read_bool(id_is_mret_live_sig)} "
                    f"if_v={_read_bool(if_valid_live_sig)} "
                    f"pd_v={_read_bool(pd_valid_live_sig)} "
                    f"id_v={_read_bool(id_valid_live_sig)} "
                    f"post_flush={_read_int(post_flush_holdoff_live_sig)} "
                    f"csr_in_flight={_read_bool(csr_in_flight_live_sig)} "
                    f"pipe_stall={_read_bool(pipeline_stall_live_sig)} "
                    f"pipe_stall_r={_read_bool(pipeline_stall_registered_live_sig)} "
                    f"rob_full={_read_bool(rob_full_live_sig)} "
                    f"int_full={_read_bool(int_rs_full_live_sig)} "
                    f"mul_full={_read_bool(mul_rs_full_live_sig)} "
                    f"mem_full={_read_bool(mem_rs_full_live_sig)} "
                    f"fp_full={_read_bool(fp_rs_full_live_sig)} "
                    f"fmul_full={_read_bool(fmul_rs_full_live_sig)} "
                    f"fdiv_full={_read_bool(fdiv_rs_full_live_sig)} "
                    f"lq_full={_read_bool(lq_full_live_sig)} "
                    f"sq_full={_read_bool(sq_full_live_sig)} "
                    f"ckpt_avail={_read_bool(checkpoint_available_sig)} "
                    f"alloc_v={_read_bool(rob_alloc_valid_live_sig)} "
                    f"alloc_pc=0x{(_read_int(rob_alloc_pc_live_sig) or 0):08x} "
                    f"alloc_csr={_read_bool(rob_alloc_is_csr_live_sig)} "
                    f"alloc_mret={_read_bool(rob_alloc_is_mret_live_sig)}"
                )
            if_pc = _read_int(if_pc_sig)
            if in_trace_window(if_pc):
                control_flow_debug_events.append(
                    "ifpd   "
                    f"cycle={cycle + 1} "
                    f"x2={last_x2_commit} "
                    f"x8={last_x8_commit} "
                    f"x9={last_x9_commit} "
                    f"x10={last_x10_commit} "
                    f"x19={last_x19_commit} "
                    f"if_pc=0x{if_pc:08x} "
                    f"sel_nop={_read_bool(if_sel_nop_sig)} "
                    f"raw=0x{(_read_int(if_raw_parcel_sig) or 0):04x} "
                    f"ras={_read_bool(if_ras_pred_sig)}"
                )
            pd_pc = _read_int(pd_pc_sig)
            if in_trace_window(pd_pc):
                control_flow_debug_events.append(
                    "pdid   "
                    f"cycle={cycle + 1} "
                    f"x2={last_x2_commit} "
                    f"x8={last_x8_commit} "
                    f"x9={last_x9_commit} "
                    f"x10={last_x10_commit} "
                    f"x19={last_x19_commit} "
                    f"pd_pc=0x{pd_pc:08x} "
                    f"instr=0x{(_read_int(pd_instr_sig) or 0):08x} "
                    f"ras={_read_bool(pd_ras_pred_sig)}"
                )
            id_pc = _read_int(id_pc_sig)
            if in_trace_window(id_pc):
                control_flow_debug_events.append(
                    "id     "
                    f"cycle={cycle + 1} "
                    f"x2={last_x2_commit} "
                    f"x8={last_x8_commit} "
                    f"x9={last_x9_commit} "
                    f"x10={last_x10_commit} "
                    f"x19={last_x19_commit} "
                    f"id_pc=0x{id_pc:08x} "
                    f"op={_read_int(id_op_sig)} "
                    f"ras={_read_bool(id_ras_pred_sig)}"
                )
            issue_pc = _read_int(issue_pc_sig)
            if _read_bool(issue_valid_sig) and in_trace_window(issue_pc):
                control_flow_debug_events.append(
                    "issue  "
                    f"cycle={cycle + 1} "
                    f"x2={last_x2_commit} "
                    f"x8={last_x8_commit} "
                    f"x9={last_x9_commit} "
                    f"x10={last_x10_commit} "
                    f"x19={last_x19_commit} "
                    f"pc=0x{issue_pc:08x} "
                    f"pred_taken={_read_bool(issue_pred_taken_sig)}"
                )
        if progress_interval and (cycle + 1) % progress_interval == 0:
            pc = _read_int(pc_sig)
            pc_vld = _read_bool(pc_vld_sig)
            mem_rd_en = _read_bool(mem_rd_en_sig)
            mem_addr = _read_int(mem_addr_sig)
            mem_wr_en = _read_int(mem_wr_en_sig)
            sq_count = _read_int(sq_count_sig)
            sq_full = _read_bool(sq_full_sig)
            rob_count = _read_int(rob_count_sig)
            dispatch_stall = _read_bool(dispatch_stall_sig)
            branch_pred_off = _read_bool(branch_pred_off_sig)
            lq_issue_mem_found = _read_bool(lq_issue_mem_found_sig)
            lq_sq_check_valid = _read_bool(lq_sq_check_valid_sig)
            lq_sq_can_issue = _read_bool(lq_sq_can_issue_sig)
            lq_sq_do_forward = _read_bool(lq_sq_do_forward_sig)
            lq_cache_hit_fast_path = _read_bool(lq_cache_hit_fast_path_sig)
            lq_mem_outstanding = _read_bool(lq_mem_outstanding_sig)
            cf_debug_suffix = ""
            if coremark_cf_debug_enabled:
                if_pc = _read_int(if_pc_sig)
                pd_pc = _read_int(pd_pc_sig)
                id_pc = _read_int(id_pc_sig)
                if_btb_pred = _read_bool(if_btb_pred_sig)
                if_ras_pred = _read_bool(if_ras_pred_sig)
                pd_btb_pred = _read_bool(pd_btb_pred_sig)
                pd_ras_pred = _read_bool(pd_ras_pred_sig)
                id_btb_pred = _read_bool(id_btb_pred_sig)
                id_ras_pred = _read_bool(id_ras_pred_sig)
                pd_instr = _read_int(pd_instr_sig)
                id_op = _read_int(id_op_sig)
                cf_debug_suffix = (
                    f" if_pc=0x{(if_pc or 0):08x}"
                    f" pd_pc=0x{(pd_pc or 0):08x}"
                    f" id_pc=0x{(id_pc or 0):08x}"
                    f" if_btb={if_btb_pred}"
                    f" if_ras={if_ras_pred}"
                    f" pd_btb={pd_btb_pred}"
                    f" pd_ras={pd_ras_pred}"
                    f" id_btb={id_btb_pred}"
                    f" id_ras={id_ras_pred}"
                    f" pd_instr=0x{(pd_instr or 0):08x}"
                    f" id_op={id_op}"
                )
            cocotb.log.info(
                f"Run {run_number} coremark progress: cycle={cycle + 1} "
                f"retired={retired_count} "
                f"delta_retired={retired_count - last_progress_retired} "
                f"mispredicts={retired_mispredicts} "
                f"delta_mispredicts={retired_mispredicts - last_progress_mispredicts} "
                f"pc=0x{(pc or 0):08x} pc_vld={pc_vld} "
                f"mem_rd_en={mem_rd_en} mem_addr=0x{(mem_addr or 0):08x} "
                f"mem_wr_en=0x{(mem_wr_en or 0):x} "
                f"sq_count={sq_count} sq_full={sq_full} "
                f"rob_count={rob_count} dispatch_stall={dispatch_stall} "
                f"head_tag={_read_int(head_tag_live_sig)} "
                f"head_valid={_read_bool(head_valid_live_sig)} "
                f"head_done={_read_bool(head_done_live_sig)} "
                f"head_pc=0x{(_read_int(head_pc_live_sig) or 0):08x} "
                f"head_is_branch={_read_bool(head_is_branch_live_sig)} "
                f"head_is_store={_read_bool(head_is_store_live_sig)} "
                f"head_has_ckpt={_read_bool(head_has_checkpoint_live_sig)} "
                f"issue_v={_read_bool(issue_valid_live_sig)} "
                f"issue_pc=0x{(_read_int(issue_pc_live_sig) or 0):08x} "
                f"ckpt_avail={_read_bool(checkpoint_available_live_sig)} "
                f"branch_pred_off={branch_pred_off} "
                f"lq_issue_mem_found={lq_issue_mem_found} "
                f"lq_sq_check_valid={lq_sq_check_valid} "
                f"lq_sq_can_issue={lq_sq_can_issue} "
                f"lq_sq_do_forward={lq_sq_do_forward} "
                f"lq_cache_hit_fast_path={lq_cache_hit_fast_path} "
                f"lq_mem_outstanding={lq_mem_outstanding}"
                f"{cf_debug_suffix}"
            )
            cocotb.log.info(
                f"Run {run_number} CLINT/serial: cycle={cycle + 1} "
                f"mtime=0x{(_read_u64(_get_signal(dut, 'cpu_and_memory_subsystem.mtime')) or 0):016x} "
                f"mtimecmp=0x{(_read_u64(_get_signal(dut, 'cpu_and_memory_subsystem.mtimecmp')) or 0):016x} "
                f"mtip={_read_bool(_get_signal(dut, 'cpu_and_memory_subsystem.mtip_registered'))} "
                # Sstc: the S-mode timer compare an Sstc kernel or firmware
                # re-arms (opensbi_smoke drives it from its S-mode payload).
                f"stimecmp=0x{(_read_u64(_get_signal(dut, 'cpu_and_memory_subsystem.cpu_inst.csr_file_inst.stimecmp')) or 0):016x} "
                f"priv={_read_int(_get_signal(dut, 'cpu_and_memory_subsystem.cpu_inst.csr_priv'))} "
                f"mstatus=0x{(_read_int(_get_signal(dut, 'cpu_and_memory_subsystem.cpu_inst.csr_mstatus')) or 0):08x}"
            )
            last_progress_retired = retired_count
            last_progress_mispredicts = retired_mispredicts

        # The failure marker is checked first, so it wins if both appear.
        if uart_monitor.contains(FAIL_MARKER):
            cocotb.log.error(f"Run {run_number} FAILED: Program printed failure marker")
            test_failed = True
            break

        if has_defined_endpoint:
            # Test suite: look for pass marker
            if success_marker and uart_monitor.contains(success_marker):
                cocotb.log.info(
                    f"Run {run_number} PASSED: Program printed success marker"
                )
                test_passed = True
                break
        else:
            # Open-ended test: look for initial text
            if initial_text and uart_monitor.contains(initial_text):
                cocotb.log.info(
                    f"Run {run_number} PASSED: Found expected text '{initial_text}'"
                )
                test_passed = True
                # Continue running a bit more to let output complete
                for _ in range(10000):
                    await RisingEdge(dut.i_clk)
                break

    close_coremark_retire_trace()
    print("\n")  # Newline after UART output
    cocotb.log.info(f"Run {run_number} completed after {cycle + 1} cycles")

    if not test_failed and os.environ.get("FROST_EXPECT_PERF_COUNTERS") == "1":
        # Profiling entries (-GPERF_COUNTERS=1) must not pass on zero data:
        # the report's presence line carries the hardware's mperfcount.
        presence = re.search(r"Profiling counters: (\d+)", uart_monitor.get_output())
        if presence is None or int(presence.group(1)) == 0:
            raise AssertionError(
                f"Run {run_number}: FROST_EXPECT_PERF_COUNTERS=1 but the program "
                "did not report present profiling counters"
            )
    if test_failed:
        if is_coremark_like and coremark_return_events:
            cocotb.log.error(
                "Coremark return trace:\n" + "\n".join(coremark_return_events)
            )
        if is_coremark_like and coremark_retire_trace_path is not None:
            cocotb.log.error(
                "Coremark retire samples captured for "
                + str(coremark_retire_trace_symbol)
                + ": "
                + str(coremark_retire_trace_count)
            )
        if is_coremark_like and coremark_matrix_events:
            cocotb.log.error(
                "Coremark matrix window trace:\n" + "\n".join(coremark_matrix_events)
            )
        if target_pc_events:
            cocotb.log.error("Target PC trace:\n" + "\n".join(target_pc_events))
        if control_flow_trace_label is not None and retired_pc_hist:
            top_retired_pcs = ", ".join(
                f"0x{pc:08x}:{count}" for pc, count in retired_pc_hist.most_common(12)
            )
            cocotb.log.error(
                f"{control_flow_trace_label} retired PC histogram (top 12): "
                + top_retired_pcs
            )
        if control_flow_trace_label is not None and control_flow_debug_events:
            cocotb.log.error(
                f"{control_flow_trace_label} loop trace:\n"
                + "\n".join(control_flow_debug_events)
            )
        if checkpoint_trace_enabled and checkpoint_debug_events:
            cocotb.log.error("Checkpoint trace:\n" + "\n".join(checkpoint_debug_events))
        if app_name == "ras_stress_test" and special_issue_events:
            cocotb.log.error(
                "RAS_stress_test special issue trace:\n"
                + "\n".join(special_issue_events)
            )
        if app_name == "ras_stress_test" and btb_update_events:
            cocotb.log.error(
                "RAS_stress_test BTB update trace:\n" + "\n".join(btb_update_events)
            )
        cocotb.log.error(f"UART output:\n{uart_monitor.get_output()}")
        raise AssertionError(
            f"Run {run_number} failed: program printed <<FAIL>> marker"
        )

    if not test_passed:
        if is_coremark_like and retired_pc_hist:
            top_retired_pcs = ", ".join(
                f"0x{pc:08x}:{count}" for pc, count in retired_pc_hist.most_common(12)
            )
            cocotb.log.error(
                "Coremark retired PC histogram (top 12): " + top_retired_pcs
            )
        if target_pc_events:
            cocotb.log.error("Target PC trace:\n" + "\n".join(target_pc_events))
        if control_flow_trace_label is not None and retired_pc_hist:
            top_retired_pcs = ", ".join(
                f"0x{pc:08x}:{count}" for pc, count in retired_pc_hist.most_common(12)
            )
            cocotb.log.error(
                f"{control_flow_trace_label} retired PC histogram (top 12): "
                + top_retired_pcs
            )
        if control_flow_trace_label is not None and control_flow_debug_events:
            cocotb.log.error(
                f"{control_flow_trace_label} loop trace:\n"
                + "\n".join(control_flow_debug_events)
            )
        if checkpoint_trace_enabled and checkpoint_debug_events:
            cocotb.log.error("Checkpoint trace:\n" + "\n".join(checkpoint_debug_events))
        if app_name == "ras_stress_test" and special_issue_events:
            cocotb.log.error(
                "RAS_stress_test special issue trace:\n"
                + "\n".join(special_issue_events)
            )
        if app_name == "ras_stress_test":
            if btb_update_events:
                cocotb.log.error(
                    "RAS_stress_test BTB update trace:\n" + "\n".join(btb_update_events)
                )
            cocotb.log.error(
                "RAS_stress_test last architectural commits: "
                f"x8/s0={last_x8_commit} x18/s2={last_x18_commit}"
            )
        cocotb.log.error(f"UART output:\n{uart_monitor.get_output()}")
        if has_defined_endpoint:
            raise AssertionError(
                f"Run {run_number} failed: program did not print success marker "
                f"'{success_marker}' within {max_cycles} cycles"
            )
        else:
            raise AssertionError(
                f"Run {run_number} failed: program did not print expected text "
                f"'{initial_text}' within {max_cycles} cycles"
            )

    if coremark_if_check_enabled:
        if coremark_if_check_count == 0:
            raise AssertionError(
                f"Run {run_number}: FROST_COREMARK_IF_CHECK=1 compared no "
                f"instructions of {coremark_if_check_symbol}"
            )
        cocotb.log.info(
            f"Run {run_number}: CoreMark IF check compared "
            f"{coremark_if_check_count} dispatched instructions of "
            f"{coremark_if_check_symbol} with sw.S"
        )
    if irq_precision_check:
        if irq_take_count == 0:
            raise AssertionError(
                f"Run {run_number}: FROST_IRQ_PRECISION_CHECK=1 saw no interrupt taken"
            )
        cocotb.log.info(
            f"Run {run_number}: IRQ precision check saw {irq_take_count} "
            f"interrupt{'' if irq_take_count == 1 else 's'} taken"
        )


async def run_uart_echo_interaction(
    dut: Any,
    uart_monitor: UartMonitor,
    uart_driver: UartRxDriver,
    debug_monitor: UartMmioDebugMonitor | None,
    max_cycles: int,
    run_number: int,
) -> None:
    """Run uart_echo by injecting UART RX input and checking echoed response."""
    prompt = "frost> "
    test_line = "xyz"
    expected_echo = f"{prompt}{test_line}"
    expected_response = f'You typed: "{test_line}"'

    try:
        await wait_for_uart_text(
            dut, uart_monitor, prompt, max_cycles=max_cycles, start_index=0
        )
    except AssertionError:
        if debug_monitor:
            debug_monitor.dump_recent()
        raise

    send_idx = len(uart_monitor.get_output())
    if debug_monitor:
        debug_monitor.reset_events(reset_counts=True)
    await uart_driver.send((test_line + "\r").encode("ascii"))

    try:
        await wait_for_uart_text(
            dut, uart_monitor, expected_echo, max_cycles=max_cycles, start_index=0
        )
        await wait_for_uart_text(
            dut,
            uart_monitor,
            expected_response,
            max_cycles=max_cycles,
            start_index=send_idx,
        )
    except AssertionError:
        if debug_monitor:
            debug_monitor.dump_recent()
        raise

    cocotb.log.info(f"Run {run_number} PASSED: uart_echo echoed '{test_line}'")


@cocotb.test()
async def test_real_program(dut: Any) -> None:
    """Reset the system and run the program NUM_RUNS times, checking each run.

    The test watches UART output for success and failure markers. Test suites
    (isa_test, strings_test, ...) and CoreMark must print "<<PASS>>";
    hello_world must print "Hello, world!". The default of two runs with a
    reset in between checks that programs tolerate reset and reinitialize all
    their state.
    """
    Clock(dut.i_clk, CLK_PERIOD_NS, unit="ns").start()
    # i_clk_div4 exists only in frost.sv, not in the cpu_tb.sv testbench. It is
    # derived from i_clk rather than started as an independent Clock because the
    # dc_fifo clock domain crossing needs a fixed phase relationship.
    if hasattr(dut, "i_clk_div4"):
        cocotb.start_soon(generate_divided_clock(dut))
        # frost.sv always has the NIC's ports. They are driven without a
        # per-port check, so a renamed port fails here instead of silently
        # leaving the MAC unclocked.
        start_nic_mac_clocks(dut)

    disable_branch_prediction = int(
        os.environ.get("FROST_DISABLE_BRANCH_PREDICTION", "0")
    )
    if hasattr(dut, "i_disable_branch_prediction"):
        dut.i_disable_branch_prediction.value = disable_branch_prediction
    elif hasattr(dut, "cpu_and_memory_subsystem") and hasattr(
        dut.cpu_and_memory_subsystem, "i_disable_branch_prediction"
    ):
        dut.cpu_and_memory_subsystem.i_disable_branch_prediction.value = (
            disable_branch_prediction
        )

    success_marker, initial_text, has_defined_endpoint, app_name = (
        get_expected_behavior()
    )

    # Per-app cycle budgets. Match the is_coremark_like convention (startswith)
    # so coremark_pro workloads get the CoreMark budget too, not just the exact
    # "coremark" app.
    if app_name is not None and app_name.startswith("coremark"):
        max_cycles = COREMARK_MAX_CYCLES
    elif app_name == "sprintf_test":
        max_cycles = SPRINTF_TEST_MAX_CYCLES
    elif app_name == "pde_return_hazard":
        max_cycles = PDE_RETURN_HAZARD_MAX_CYCLES
    elif app_name == "wfi_lost_tick":
        max_cycles = WFI_LOST_TICK_MAX_CYCLES
    elif app_name == "restore_window_stress":
        max_cycles = RESTORE_WINDOW_STRESS_MAX_CYCLES
    elif app_name == "amo_irq_torture":
        max_cycles = AMO_IRQ_TORTURE_MAX_CYCLES
    elif app_name in ("nic_loopback", "nic_echo"):
        max_cycles = NIC_LOOPBACK_MAX_CYCLES
    elif app_name == "tick_torture":
        max_cycles = TICK_TORTURE_MAX_CYCLES
    elif app_name == "mem_divergence_probe":
        max_cycles = MEM_DIVERGENCE_PROBE_MAX_CYCLES
    elif app_name == "linux_irq_active_ddr_test":
        # 72 timer ticks and the 30k-iteration sentinel spin-waits run just
        # past the generic budget.
        max_cycles = int(os.environ.get("COCOTB_MAX_CYCLES", 2000000))
    else:
        max_cycles = MAX_CYCLES

    cocotb.log.info(
        f"Expected behavior: success_marker={success_marker}, "
        f"initial_text={initial_text}, has_defined_endpoint={has_defined_endpoint}, "
        f"app_name={app_name}, max_cycles={max_cycles}"
    )

    # Start UART monitor (runs across every program run)
    uart_monitor = UartMonitor(dut)
    await uart_monitor.start()

    # Optional trap/MRET deadlock wedge observer (pure instrumentation).
    if os.environ.get("FROST_WEDGE_MONITOR") == "1":
        cocotb.start_soon(wedge_monitor(dut, uart_monitor))
    cocotb.start_soon(ddr_write_watch(dut))
    cocotb.start_soon(l0_hit_watch(dut))

    uart_driver = None
    debug_monitor = None
    if app_name == "uart_echo":
        uart_driver = UartRxDriver(dut)
        debug_monitor = UartMmioDebugMonitor(dut)
        await debug_monitor.start()
    elif app_name == "fs_off_test":
        # fs_off_test checks that a trapping FS=Off FP load leaves a waiting
        # UART RX byte unread; the bench sends it (0x5A) once per run.
        uart_driver = UartRxDriver(dut)
    nic_peer = NicEchoPeer(dut, uart_monitor) if app_name == "nic_echo" else None

    for run_number in range(1, NUM_RUNS + 1):
        if run_number > 1:
            # Reset between runs
            cocotb.log.info(f"=== Asserting reset for {RESET_CYCLES} cycles ===")
            uart_monitor.clear()
            dut.i_rst_n.value = 0
            if hasattr(dut, "i_uart_rx"):
                dut.i_uart_rx.value = 1
            if hasattr(dut, "i_external_interrupt"):
                dut.i_external_interrupt.value = 0
            for _ in range(RESET_CYCLES):
                await RisingEdge(dut.i_clk)
            dut.i_rst_n.value = 1
        else:
            # Apply initial reset
            dut.i_instr_mem_en.value = 0
            dut.i_rst_n.value = 0
            if hasattr(dut, "i_uart_rx"):
                dut.i_uart_rx.value = 1
            if hasattr(dut, "i_external_interrupt"):
                dut.i_external_interrupt.value = 0
            for _ in range(RESET_CYCLES):
                await RisingEdge(dut.i_clk)
            dut.i_rst_n.value = 1

        cocotb.log.info(f"=== Starting run {run_number} of {NUM_RUNS} ===")

        if app_name == "uart_echo":
            assert uart_driver is not None
            await run_uart_echo_interaction(
                dut,
                uart_monitor,
                uart_driver,
                debug_monitor,
                max_cycles,
                run_number=run_number,
            )
        else:
            if nic_peer is not None:
                nic_peer.start_run()
            if app_name == "fs_off_test":
                assert uart_driver is not None
                cocotb.start_soon(uart_driver.send(b"\x5a"))
            await run_until_complete(
                dut,
                uart_monitor,
                success_marker,
                initial_text,
                has_defined_endpoint,
                max_cycles,
                run_number=run_number,
                app_name=app_name,
            )
            if nic_peer is not None:
                nic_peer.verify()
        log_ras_stats(run_number, read_ras_stats(dut))

    uart_monitor.stop()
    if debug_monitor:
        debug_monitor.stop()

    cocotb.log.info(f"=== All {NUM_RUNS} run(s) completed successfully ===")
