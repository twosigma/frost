#!/usr/bin/env python3

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

"""Unit tests for hw_regression's Linux stage and ordered UART stimuli.

The board is not needed: the stage's predicates, judge, and stimulus
sequencing are exercised against a console transcript captured from the MMU
lane's image booting in QEMU (login as root, ``perf stat`` over the SBI PMU
counters), with the CRLF pairs the getty and busybox shell emit.
"""

import importlib.util
import sys
from types import ModuleType
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
FPGA_DIR = REPO_ROOT / "fpga"
for extra in (
    FPGA_DIR,
    FPGA_DIR / "common",
    FPGA_DIR / "load_software",
    REPO_ROOT / "sw" / "apps",
):
    if str(extra) not in sys.path:
        sys.path.insert(0, str(extra))


def _load_hw_regression() -> ModuleType:
    """Import fpga/hw_regression.py by path (it is a script, not a package)."""
    spec = importlib.util.spec_from_file_location(
        "hw_regression", FPGA_DIR / "hw_regression.py"
    )
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


hw = _load_hw_regression()

# Captured from qemu-system-riscv64 booting fw_jump + the frost_rv64_defconfig
# image (2026-09-05), trimmed to the lines the stage cares about; the counts
# are QEMU's, not FROST's.
BOOT_TO_LOGIN = (
    "[    0.000000] Linux version 6.18.7 (buildroot)\r\r\n"
    "[    0.000000] SBI implementation ID=0x1 Version=0x10007\r\r\n"
    "Starting crond: OK\r\r\n"
    "FROST_USERSPACE_STRESS: starting\r\r\n"
    "FROST_USERSPACE_STRESS: forks=2 pages=256 ticks=60 vforks=12 futex=64 "
    "atomics=40000 cycles=4764560 instret=3473800 time=7499 ipc_x1000=729 verdict=PASS\r\r\n"
    "FROST_USERSPACE_STRESS_PASS\r\r\n"
    "\r\r\r\n"
    "Welcome to Buildroot\r\r\n"
    "\rbuildroot login: "
)
LOGIN_TO_SHELL = "root\r\r\nlogin[79]: root login on 'console'\r\r\n# "
PERF_ECHO = "perf stat -x, -e cycles,instructions /bin/true\r\r\r\n"
PERF_ROWS = "422523756,,cycles,105848600,100.00,,\r\r\n421771240,,instructions,106473200,100.00,1.00,insn per cycle\r\r\n# "
FULL_MMU_TRANSCRIPT = BOOT_TO_LOGIN + LOGIN_TO_SHELL + PERF_ECHO + PERF_ROWS


def test_mmu_lane_passes_on_token_login_and_perf_rows() -> None:
    """The full QEMU transcript satisfies the MMU lane: token, login, both perf rows."""
    stage = hw.linux_stage("mmu")
    assert stage.success_done(FULL_MMU_TRANSCRIPT)
    assert not stage.failure_done(FULL_MMU_TRANSCRIPT)
    ok, note = stage.judge(FULL_MMU_TRANSCRIPT)
    assert ok, note
    assert "cycles=422523756" in note and "instructions=421771240" in note


def test_mmu_lane_is_not_done_at_the_login_prompt() -> None:
    """The MMU lane keeps capturing until perf stat has printed both rows."""
    stage = hw.linux_stage("mmu")
    assert not stage.success_done(BOOT_TO_LOGIN)
    assert not stage.success_done(BOOT_TO_LOGIN + LOGIN_TO_SHELL + PERF_ECHO)
    ok, note = stage.judge(BOOT_TO_LOGIN + LOGIN_TO_SHELL + PERF_ECHO)
    assert not ok and "no perf stat row" in note


def test_mmu_lane_requires_the_token_before_the_prompt() -> None:
    """A boot that reaches login without the stress token fails."""
    transcript = FULL_MMU_TRANSCRIPT.replace("FROST_USERSPACE_STRESS_PASS\r\r\n", "")
    stage = hw.linux_stage("mmu")
    ok, note = stage.judge(transcript)
    assert not ok and "FROST_USERSPACE_STRESS_PASS" in note


def test_mmu_lane_fails_on_the_stress_fail_token() -> None:
    """The stress payload's FAIL token ends capture and fails the stage."""
    transcript = FULL_MMU_TRANSCRIPT.replace("STRESS_PASS", "STRESS_FAIL")
    stage = hw.linux_stage("mmu")
    assert stage.failure_done(transcript)
    ok, note = stage.judge(transcript)
    assert not ok and "FROST_USERSPACE_STRESS_FAIL" in note


@pytest.mark.parametrize(
    "count,expect",
    [
        ("<not supported>", "cycles: <not supported>"),
        ("<not counted>", "cycles: <not counted>"),
        ("0", "cycles: 0"),
    ],
)
def test_mmu_lane_rejects_unsupported_or_zero_counts(count: str, expect: str) -> None:
    """A perf row without a positive count fails the stage."""
    transcript = FULL_MMU_TRANSCRIPT.replace("422523756,,cycles,", f"{count},,cycles,")
    stage = hw.linux_stage("mmu")
    assert stage.success_done(transcript)  # a printed row ends capture ...
    ok, note = stage.judge(transcript)  # ... and the judge rejects it
    assert not ok and expect in note


def test_perf_rows_are_not_matched_inside_the_command_echo() -> None:
    """The typed command names both events; only real CSV rows count."""
    assert hw.perf_counts(BOOT_TO_LOGIN + LOGIN_TO_SHELL + PERF_ECHO) == {}


def test_nommu_lane_passes_at_the_login_prompt_without_stimuli() -> None:
    """The no-MMU lane is unchanged: login prompt, nothing typed."""
    stage = hw.linux_stage("nommu")
    assert stage.stimuli == ()
    assert stage.success_done(BOOT_TO_LOGIN)
    ok, note = stage.judge(BOOT_TO_LOGIN)
    assert ok, note
    assert not stage.success_done("Welcome to Buildroot\r\n")


def test_nommu_lane_still_fails_on_panic() -> None:
    """A kernel panic fails the no-MMU lane as before."""
    stage = hw.linux_stage("nommu")
    transcript = BOOT_TO_LOGIN + "[    1.0] Kernel panic - not syncing\r\r\n"
    assert stage.failure_done(transcript)
    assert not stage.judge(transcript)[0]


def test_stimuli_fire_in_order_after_their_triggers() -> None:
    """Each stimulus fires once, in order, only after the previous trigger."""
    stage = hw.linux_stage("mmu")
    assert stage.stimuli == (
        ("buildroot login:", "root\r"),
        ("# ", hw.LINUX_PERF_COMMAND + "\r"),
    )
    # Nothing to type before the prompt, even though "# " could occur in a log.
    assert hw.next_stimulus(stage, "[    0.1] # not a prompt\r\n", 0, 0) is None
    text, after = hw.next_stimulus(stage, BOOT_TO_LOGIN, 0, 0)
    assert text == "root\r"
    assert (
        after == len(BOOT_TO_LOGIN) - 1
    )  # the prompt's trailing space follows the trigger
    # The shell prompt is only searched after the login trigger.
    assert hw.next_stimulus(stage, BOOT_TO_LOGIN, 1, after) is None
    text2, after2 = hw.next_stimulus(stage, BOOT_TO_LOGIN + LOGIN_TO_SHELL, 1, after)
    assert text2 == hw.LINUX_PERF_COMMAND + "\r"
    assert after2 == len(BOOT_TO_LOGIN + LOGIN_TO_SHELL)
    assert hw.next_stimulus(stage, FULL_MMU_TRANSCRIPT, 2, after2) is None


def test_uart_echo_stage_keeps_its_single_probe() -> None:
    """uart_echo still types its one probe at the prompt."""
    stage = hw.build_stage("uart_echo", "x3", 1.0)
    assert stage.stimuli == ((hw.ECHO_PROMPT, hw.ECHO_PROBE + "\r"),)
    assert hw.next_stimulus(stage, "boot\r\nfrost> ", 0, 0) == (
        hw.ECHO_PROBE + "\r",
        len("boot\r\nfrost> "),
    )


def test_linux_lane_reads_the_environment(monkeypatch: pytest.MonkeyPatch) -> None:
    """The lane comes from FROST_LINUX_LANE, defaulting to nommu."""
    monkeypatch.delenv(hw.LINUX_LANE_ENV, raising=False)
    assert hw.linux_lane() == "nommu"
    monkeypatch.setenv(hw.LINUX_LANE_ENV, "mmu")
    assert hw.linux_lane() == "mmu"
