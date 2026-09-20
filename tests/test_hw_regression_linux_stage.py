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
sequencing are exercised against a console transcript captured from Debian's
kernel booting the test initramfs in QEMU (the NIC module's load, login as
root, ``frost_stress --counters`` over the SBI PMU counters), with the CRLF
pairs the getty and busybox shell emit. QEMU has no frost,net10g device, so the
``frost_nettest`` lines that follow are written in the program's output format
rather than captured.
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
    REPO_ROOT / "linux",
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

# Captured from qemu-system-riscv64 booting fw_jump + Debian's kernel with the
# test initramfs (2026-09-19), trimmed to the lines the stage cares about; the
# counts are QEMU's, not FROST's.
BOOT_TO_LOGIN = (
    f"[    0.000000] {hw.KERNEL_BANNER}"
    "(debian-kernel@debian) (riscv64-linux-gnu-gcc-14 (Debian 14.2.0-19) "
    "14.2.0, GNU ld (GNU Binutils for Debian) 2.44) #1 SMP Debian "
    "6.12.107-1 (2026-08-29)\r\r\n"
    "[    0.000000] SBI implementation ID=0x1 Version=0x10007\r\r\n"
    "[    1.049415] frost_net10g: loading out-of-tree module taints kernel.\r\r\n"
    f"{hw.LINUX_MODULE_LINE}\r\r\n"
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
COUNTER_ECHO = "frost_stress --counters\r\r\r\n"
COUNTER_LINE = (
    "FROST_COUNTERS: scope=exec-child cycles=4433680 instret=3275440 time=42321 "
    "ipc_x1000=1012 verdict=PASS\r\r\n# "
)
# What the program prints when perf_event_open on the child fails.
COUNTER_FAIL_LINE = (
    "FROST_COUNTERS: scope=exec-child counters=unavailable verdict=FAIL\r\r\n# "
)
COUNTER_TRANSCRIPT = BOOT_TO_LOGIN + LOGIN_TO_SHELL + COUNTER_ECHO + COUNTER_LINE
# frost_nettest's first and last lines around its verdict (trimmed).
NET_ECHO = "frost_nettest\r\r\r\n"
NET_START = (
    "FROST_NET_LOOPBACK: eth0: driver frost_net10g, address 02:11:22:33:44:55, "
    "loopback feature bit 42, run 5b3f1d07; down\r\r\n"
)
NET_PASS = (
    "FROST_NET_LOOPBACK: eth0 down, loopback off\r\r\n"
    "FROST_NET_LOOPBACK_PASS\r\r\n# "
)
NET_FAIL = (
    "FROST_NET_LOOPBACK_FAIL burst: expected frame 250, received frame 251 "
    "(lost or reordered)\r\r\n# "
)
FULL_MMU_TRANSCRIPT = COUNTER_TRANSCRIPT + NET_ECHO + NET_START + NET_PASS


def test_mmu_lane_passes_on_tokens_login_counters_and_nettest() -> None:
    """The full transcript passes: tokens, login, both counters, nettest's pass."""
    stage = hw.linux_stage()
    assert stage.success_done(FULL_MMU_TRANSCRIPT)
    assert not stage.failure_done(FULL_MMU_TRANSCRIPT)
    ok, note = stage.judge(FULL_MMU_TRANSCRIPT)
    assert ok, note
    assert "cycles=4433680" in note and "instret=3275440" in note
    assert hw.KERNEL_RELEASE in note
    assert "frost_nettest" in note


def test_counters_no_longer_end_the_stage() -> None:
    """The counters-only transcript is not terminal: nettest has not passed yet."""
    stage = hw.linux_stage()
    for transcript in (COUNTER_TRANSCRIPT, COUNTER_TRANSCRIPT + NET_ECHO + NET_START):
        assert not stage.success_done(transcript)
        assert not stage.failure_done(transcript)
    ok, note = stage.judge(COUNTER_TRANSCRIPT)
    assert not ok and "FROST_NET_LOOPBACK_PASS" in note


def test_mmu_lane_is_not_done_at_the_login_prompt() -> None:
    """The MMU lane keeps capturing until the counter line has printed."""
    stage = hw.linux_stage()
    assert not stage.success_done(BOOT_TO_LOGIN)
    assert not stage.success_done(BOOT_TO_LOGIN + LOGIN_TO_SHELL + COUNTER_ECHO)
    ok, note = stage.judge(BOOT_TO_LOGIN + LOGIN_TO_SHELL + COUNTER_ECHO)
    assert not ok and "no FROST_COUNTERS: count" in note


def test_mmu_lane_requires_the_boot_lines_before_the_prompt() -> None:
    """A boot that reaches login without a sysinit line fails."""
    stage = hw.linux_stage()
    for line in (hw.LINUX_TOKEN, hw.LINUX_MODULE_LINE):
        transcript = FULL_MMU_TRANSCRIPT.replace(line + "\r\r\n", "")
        ok, note = stage.judge(transcript)
        assert not ok and line.split()[0] in note


def test_mmu_lane_requires_the_module_line_to_name_the_pinned_release() -> None:
    """The module loading is not enough: its line must name the running kernel.

    The pin sets CONFIG_MODVERSIONS, and with symbol CRCs present Linux skips
    vermagic's release field, so this module loads into any ABI-compatible
    kernel. The release the init script read from ``uname -r`` is the evidence.
    """
    stage = hw.linux_stage()
    assert hw.LINUX_MODULE_LINE.endswith(hw.KERNEL_RELEASE)
    other = FULL_MMU_TRANSCRIPT.replace(
        hw.LINUX_MODULE_LINE, f"{hw.LINUX_MODULE_LINE}-debug"
    )
    # The bare token is still there, and the release is still a prefix: neither
    # may be enough.
    assert hw.LINUX_MODULE_LINE.split()[0] in other
    ok, note = stage.judge(other)
    assert not ok and "not printed before the login prompt" in note


@pytest.mark.parametrize(
    "banner",
    ["Linux version 6.18.7 ", f"Linux version {hw.KERNEL_RELEASE}-debug "],
    ids=["other-kernel", "release-with-a-suffix"],
)
def test_mmu_lane_requires_the_kernel_banner(banner: str) -> None:
    """Booting any kernel but the pinned Debian one fails, userspace markers or not.

    The marker ends in a space, so a release the pinned one is a prefix of --
    a -debug build of the same version, say -- does not satisfy it.
    """
    stage = hw.linux_stage()
    assert hw.KERNEL_BANNER == f"Linux version {hw.KERNEL_RELEASE} "
    transcript = FULL_MMU_TRANSCRIPT.replace(hw.KERNEL_BANNER, banner)
    assert not stage.success_done(transcript)
    ok, note = stage.judge(transcript)
    assert not ok and hw.KERNEL_BANNER in note


def test_mmu_lane_fails_on_the_module_fail_token() -> None:
    """A module that will not load into the booted kernel ends capture and fails."""
    stage = hw.linux_stage()
    transcript = BOOT_TO_LOGIN.replace(
        hw.LINUX_MODULE_LINE,
        f"{hw.LINUX_MODULE_TOKEN_FAIL} insmod "
        f"/lib/modules/{hw.KERNEL_RELEASE}/frost_net10g.ko",
    )
    assert stage.failure_done(transcript)
    ok, note = stage.judge(transcript)
    assert not ok and hw.LINUX_MODULE_TOKEN_FAIL in note


def test_mmu_lane_fails_on_the_stress_fail_token() -> None:
    """The stress payload's FAIL token ends capture and fails the stage."""
    transcript = FULL_MMU_TRANSCRIPT.replace("STRESS_PASS", "STRESS_FAIL")
    stage = hw.linux_stage()
    assert stage.failure_done(transcript)
    ok, note = stage.judge(transcript)
    assert not ok and "FROST_USERSPACE_STRESS_FAIL" in note


def test_mmu_lane_rejects_a_zero_count() -> None:
    """A counter line without a positive count fails the stage."""
    transcript = FULL_MMU_TRANSCRIPT.replace("cycles=4433680", "cycles=0")
    stage = hw.linux_stage()
    assert stage.success_done(transcript)  # a printed line ends capture ...
    ok, note = stage.judge(transcript)  # ... and the judge rejects it
    assert not ok and "cycles: 0" in note


def test_mmu_lane_ends_the_capture_on_an_unavailable_counter_run() -> None:
    """A failed counter verdict is terminal, not something to wait out.

    It matches no success predicate, so without being a failure predicate too it
    ran the stage to its whole deadline and then reported nothing terminal. The
    capture predicates are what this checks, not only the judge.
    """
    stage = hw.linux_stage()
    transcript = BOOT_TO_LOGIN + LOGIN_TO_SHELL + COUNTER_ECHO + COUNTER_FAIL_LINE
    assert not stage.success_done(transcript)
    assert stage.failure_done(transcript), "the stage would run to the timeout"
    ok, note = stage.judge(transcript)
    assert not ok
    assert "counters=unavailable" in note and "verdict=FAIL" in note


def test_mmu_lane_requires_the_child_through_exec_scope() -> None:
    """The counters must cover a child measured from its exec, as perf stat did.

    A narrower measurement is a failure rather than a silent loss of coverage.
    """
    stage = hw.linux_stage()
    assert hw.LINUX_COUNTER_SCOPE == "exec-child"
    assert hw.counter_values(FULL_MMU_TRANSCRIPT)["scope"] == "exec-child"
    transcript = FULL_MMU_TRANSCRIPT.replace("scope=exec-child", "scope=self")
    assert stage.success_done(transcript)  # the counts are there ...
    ok, note = stage.judge(transcript)  # ... but not the scope
    assert not ok and "scope: self is not exec-child" in note


def test_counters_are_not_matched_in_the_echo_or_the_boot_summary() -> None:
    """Only the counter run's own line counts.

    The typed command and the boot payload's summary line, which carries
    ``cycles=`` and ``instret=`` of its own, must not stand in for it.
    """
    assert hw.counter_values(BOOT_TO_LOGIN + LOGIN_TO_SHELL + COUNTER_ECHO) == {}
    assert "cycles=" in BOOT_TO_LOGIN and "instret=" in BOOT_TO_LOGIN


def test_nettest_fail_token_fails_the_stage_and_wins_over_pass() -> None:
    """frost_nettest's fail token ends capture and fails the stage, pass token or not."""
    stage = hw.linux_stage()
    failed = COUNTER_TRANSCRIPT + NET_ECHO + NET_START + NET_FAIL
    assert stage.failure_done(failed)
    assert not stage.success_done(failed)
    ok, note = stage.judge(failed)
    assert not ok and "FROST_NET_LOOPBACK_FAIL" in note
    both = FULL_MMU_TRANSCRIPT + NET_FAIL
    assert stage.success_done(both) and stage.failure_done(both)
    ok, note = stage.judge(both)
    assert not ok and "FROST_NET_LOOPBACK_FAIL" in note


def test_nettest_pass_cannot_bypass_the_boot_tokens_or_the_counters() -> None:
    """frost_nettest's pass token does not excuse a failed earlier check."""
    stage = hw.linux_stage()
    no_token = FULL_MMU_TRANSCRIPT.replace("FROST_USERSPACE_STRESS_PASS\r\r\n", "")
    ok, note = stage.judge(no_token)
    assert not ok and "FROST_USERSPACE_STRESS_PASS" in note
    no_counts = (
        BOOT_TO_LOGIN
        + LOGIN_TO_SHELL
        + COUNTER_ECHO
        + "# "
        + NET_ECHO
        + NET_START
        + NET_PASS
    )
    assert not stage.success_done(no_counts)
    ok, note = stage.judge(no_counts)
    assert not ok and "no FROST_COUNTERS: count" in note


def test_kernel_panic_fails_the_stage() -> None:
    """A kernel panic fails the stage however far the boot got."""
    stage = hw.linux_stage()
    transcript = BOOT_TO_LOGIN + "[    1.0] Kernel panic - not syncing\r\r\n"
    assert stage.failure_done(transcript)
    assert not stage.judge(transcript)[0]


@pytest.mark.parametrize(
    "line,marker",
    [
        ("[   41.2] Oops - illegal instruction [#1]\r\r\n", "Oops"),
        (
            "[   41.2] BUG: scheduling while atomic: frost_nettest/97/0x00000101\r\r\n",
            "BUG:",
        ),
        (
            "[   12.345678] kernel BUG at lib/dynamic_queue_limits.c:99!\r\r\n"
            "[   12.345700] Kernel BUG [#1]\r\r\n",
            "Kernel BUG",
        ),
    ],
    ids=["oops", "bug", "kernel-bug"],
)
def test_kernel_oops_or_bug_fails_an_otherwise_passing_stage(
    line: str, marker: str
) -> None:
    """A kernel Oops, BUG: or Kernel BUG report fails an otherwise passing stage."""
    stage = hw.linux_stage()
    assert stage.judge(FULL_MMU_TRANSCRIPT)[0]
    transcript = FULL_MMU_TRANSCRIPT.replace(NET_START, NET_START + line)
    assert stage.success_done(transcript)
    assert stage.failure_done(transcript)
    ok, note = stage.judge(transcript)
    assert not ok and note == f"failure marker: {marker}"


def test_stimuli_fire_in_order_after_their_triggers() -> None:
    """Each stimulus fires once, in order, only after the previous trigger."""
    stage = hw.linux_stage()
    assert stage.stimuli == (
        ("buildroot login:", "root\r"),
        ("# ", hw.LINUX_COUNTER_COMMAND + "\r"),
        ("# ", "frost_nettest\r"),
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
    assert text2 == hw.LINUX_COUNTER_COMMAND + "\r"
    assert after2 == len(BOOT_TO_LOGIN + LOGIN_TO_SHELL)
    text3, after3 = hw.next_stimulus(stage, COUNTER_TRANSCRIPT, 2, after2)
    assert text3 == "frost_nettest\r"
    assert after3 == len(COUNTER_TRANSCRIPT)
    assert hw.next_stimulus(stage, FULL_MMU_TRANSCRIPT, 3, after3) is None


def test_nettest_waits_for_the_prompt_after_the_counter_run() -> None:
    """The prompt that took the counter command cannot also fire frost_nettest."""
    stage = hw.linux_stage()
    login_and_shell = BOOT_TO_LOGIN + LOGIN_TO_SHELL
    _, after_login = hw.next_stimulus(stage, BOOT_TO_LOGIN, 0, 0)
    _, after_counters = hw.next_stimulus(stage, login_and_shell, 1, after_login)
    assert hw.next_stimulus(stage, login_and_shell, 2, after_counters) is None
    # The counter run is still going: neither its echo nor its line is a prompt.
    running = login_and_shell + COUNTER_ECHO + COUNTER_LINE[: -len("# ")]
    assert hw.next_stimulus(stage, running, 2, after_counters) is None
    assert hw.next_stimulus(stage, COUNTER_TRANSCRIPT, 2, after_counters) == (
        "frost_nettest\r",
        len(COUNTER_TRANSCRIPT),
    )


def test_default_stages_skip_debugger_driven_apps() -> None:
    """debug_target stays loadable but cannot pass unattended, so it is no stage."""
    stages = hw.regression_stages()
    assert "debug_target" in hw.VALID_APPS
    assert "debug_target" not in stages
    # nic_echo needs a link partner sending the cocotb wire peer's frames.
    assert "nic_echo" in hw.VALID_APPS
    assert "nic_echo" not in stages
    assert "nic_loopback" in stages
    assert stages[0] == "hello_world"
    assert stages[-2:] == [hw.SWEEP_STAGE, hw.LINUX_STAGE]
    assert not set(hw.COREMARK_PRO_APP_NAMES) & set(stages)
    assert len(stages) == len(set(stages))


def test_uart_echo_stage_keeps_its_single_probe() -> None:
    """uart_echo still types its one probe at the prompt."""
    stage = hw.build_stage("uart_echo", "x3", 1.0)
    assert stage.stimuli == ((hw.ECHO_PROMPT, hw.ECHO_PROBE + "\r"),)
    assert hw.next_stimulus(stage, "boot\r\nfrost> ", 0, 0) == (
        hw.ECHO_PROBE + "\r",
        len("boot\r\nfrost> "),
    )


def test_cpu_clock_override_reaches_the_loader_and_skips_score_checks() -> None:
    """FROST_CPU_CLK_HZ names a functional-validation bitstream's clock.

    The loader builds apps for it and the regression skips the CoreMark
    baseline check, whose scores are recorded at the rated clock.
    """
    hw = _load_hw_regression()
    rated, overridden = hw.board_clock_freq("x3", {})
    assert (rated, overridden) == (300_000_000, False)
    assert hw.board_clock_freq("x3", {"FROST_CPU_CLK_HZ": "150000000"}) == (
        150_000_000,
        True,
    )
    with pytest.raises(ValueError):
        hw.board_clock_freq("x3", {"FROST_CPU_CLK_HZ": "fast"})
    with pytest.raises(ValueError):
        hw.board_clock_freq("x3", {"FROST_CPU_CLK_HZ": "0"})

    baseline = hw.BASELINE_SCORES.get("x3", {}).get("coremark")
    if baseline is None:
        pytest.skip("no x3 CoreMark baseline recorded")
    ok, note = hw.check_score("x3", "coremark", baseline * 0.4, 5.0)
    assert not ok
    old = dict(hw.os.environ)
    try:
        hw.os.environ["FROST_CPU_CLK_HZ"] = "150000000"
        ok, note = hw.check_score("x3", "coremark", baseline * 0.4, 5.0)
        assert ok
        assert "clock override" in note
    finally:
        hw.os.environ.clear()
        hw.os.environ.update(old)


def test_counters_absent_stage_follows_the_bitstream_perf_configuration(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    """perf_off_test is loadable and a stage, but only at the rated clock.

    The production netlist leaves the profiling counters out, which is what
    the app checks; a ``--cpu-clock-div`` bitstream includes them by default,
    so the stage is dropped rather than failed there.
    """
    assert "perf_off_test" in hw.VALID_APPS
    assert "perf_off_test" in hw.regression_stages()
    assert hw.PERF_COUNTERS_ABSENT_APPS == frozenset({"perf_off_test"})
    monkeypatch.setenv("FROST_CPU_CLK_HZ", "150000000")
    monkeypatch.setattr(
        hw.sys, "argv", ["hw_regression.py", "--board", "x3", "perf_off_test"]
    )
    with pytest.raises(SystemExit) as rejected:
        hw.main()
    assert rejected.value.code == 2
    assert "requires the rated-clock netlist" in capsys.readouterr().err
