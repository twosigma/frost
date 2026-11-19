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

"""Tests for asic/orfs.py, which runs the OpenROAD flow in its pinned image."""

import contextlib
import json
import math
import os
import re
import signal
import subprocess
import sys
import time
from collections import Counter
from pathlib import Path

import pytest
import yaml  # type: ignore[import-untyped]

import asic.orfs as orfs

ASIC_DIRECTORY = orfs.REPOSITORY_ROOT / "asic"


def test_orfs_image_is_pinned_by_digest() -> None:
    """The flow runs one exact image, whatever the tag later points to."""
    assert re.fullmatch(r"openroad/orfs:[\w.-]+@sha256:[0-9a-f]{64}", orfs.ORFS_IMAGE)


def _check_pin_access_reuse(config: str) -> None:
    """Check literal Make settings before allowing saved pin access to be reused."""
    guarded = {
        "DETAILED_ROUTE_ARGS",
        "SKIP_INCREMENTAL_REPAIR",
        "SKIP_ANTENNA_REPAIR",
        "SKIP_ANTENNA_REPAIR_POST_DRT",
        "RECOVER_POWER",
    }
    settings: dict[str, str] = {}
    depth = 0
    definitions = 0
    for raw in re.sub(r"\\\r?\n", " ", config).splitlines():
        line = raw.partition("#")[0].strip()
        if re.match(r"^(ifeq|ifneq|ifdef|ifndef)\b", line):
            depth += 1
        if re.match(r"^(?:(?:export|override)\s+)*define\b", line):
            definitions += 1
        if guarded.intersection(re.findall(r"\b\w+\b", line)):
            assert not re.search(r"\boverride\b", line), (
                f"guarded setting in an override directive: {line}"
            )
            assert depth == 0, f"guarded setting in a conditional: {line}"
            assert definitions == 0 and not raw.startswith("\t"), (
                f"cannot evaluate guarded setting: {line}"
            )
            assignment = re.fullmatch(
                r"(?:export\s+)?(\w+)\s*(::=|:=|\?=|=)\s*([-\w. \t]*)", line
            )
            assert assignment and assignment[1] in guarded, (
                f"cannot evaluate guarded setting: {line}"
            )
            name, _, value = assignment.groups()
            assert name not in settings, f"duplicate assignment to {name}"
            settings[name] = value.strip()
        if re.match(r"^endif\b", line):
            depth -= 1
            assert depth >= 0, "unmatched endif"
        if re.match(r"^endef\b", line):
            definitions -= 1
            assert definitions >= 0, "unmatched endef"
    assert depth == 0, "unterminated conditional"
    assert definitions == 0, "unterminated define"
    if "-no_pin_access" not in settings.get("DETAILED_ROUTE_ARGS", "").split():
        return

    for setting in (
        "SKIP_INCREMENTAL_REPAIR",
        "SKIP_ANTENNA_REPAIR",
        "SKIP_ANTENNA_REPAIR_POST_DRT",
    ):
        assert settings.get(setting) == "1", (
            f"-no_pin_access requires {setting}=1 so repairs cannot invalidate "
            "the saved pin access"
        )
    assert settings.get("RECOVER_POWER", "0") == "0", (
        "-no_pin_access requires RECOVER_POWER=0 so power recovery cannot resize cells"
    )
    assert orfs.ORFS_IMAGE == (
        "openroad/orfs:26Q3-705-gecb3cfdeb"
        "@sha256:6da005d1c3447799f7401215174196c75ba9ec7e28417624d0c20225f85d594c"
    ), (
        "ORFS_IMAGE changed: recheck detail_route.tcl's default arguments and "
        "pin access assumptions before updating DETAILED_ROUTE_ARGS and this guard"
    )


def test_pin_access_reuse_requires_disabled_repairs_and_pinned_defaults() -> None:
    """Pin access is reusable only while cells and their placement stay unchanged."""
    _check_pin_access_reuse((ASIC_DIRECTORY / "config.mk").read_text())


@pytest.mark.parametrize(
    ("change", "error"),
    [
        ("", None),
        ("export RECOVER_POWER := 20", "requires RECOVER_POWER=0"),
        ("SKIP_INCREMENTAL_REPAIR = 0", "requires SKIP_INCREMENTAL_REPAIR=1"),
        ("SKIP_ANTENNA_REPAIR = 1", "duplicate assignment"),
        ("DETAILED_ROUTE_ARGS += -no_pin_access", "cannot evaluate"),
        ("override RECOVER_POWER = 0", "override directive"),
        ("export override RECOVER_POWER = 0", "override directive"),
        ("ifdef OPTIONAL\nRECOVER_POWER = 0\nendif", "conditional"),
        ("ifdef RECOVER_POWER\nendif", "conditional"),
        ("RECOVER_POWER = $(POWER)", "cannot evaluate"),
        ("RECOVER_POWER != echo 0", "cannot evaluate"),
        ("route: RECOVER_POWER = 0", "cannot evaluate"),
        ("define RECOVER_POWER\n0\nendef", "cannot evaluate"),
        ("define OPTIONS\nRECOVER_POWER = 0\nendef", "cannot evaluate"),
        ("route:\n\tRECOVER_POWER = 0", "cannot evaluate"),
    ],
)
def test_pin_access_guard_checks_make_assignments(
    change: str, error: str | None
) -> None:
    """Assignment syntax cannot hide settings that invalidate saved pin access."""
    config = (
        "export DETAILED_ROUTE_ARGS := -verbose 1 \\\n  -no_pin_access # reuse\n"
        "SKIP_INCREMENTAL_REPAIR = 1\n"
        "export SKIP_ANTENNA_REPAIR ::= 1\n"
        "SKIP_ANTENNA_REPAIR_POST_DRT ?= 1\n"
    )
    if change == "SKIP_INCREMENTAL_REPAIR = 0":
        config = config.replace("SKIP_INCREMENTAL_REPAIR = 1", change)
    else:
        config += change
    if error is None:
        _check_pin_access_reuse(config)
    else:
        with pytest.raises(AssertionError, match=error):
            _check_pin_access_reuse(config)


def _asic_workflow() -> dict[object, object]:
    """Return .github/workflows/asic.yml as YAML reads it."""
    loaded = yaml.safe_load(
        (orfs.REPOSITORY_ROOT / ".github" / "workflows" / "asic.yml").read_text()
    )
    assert isinstance(loaded, dict)
    return loaded


def _asic_steps(job: str) -> dict[str, dict[str, object]]:
    """Return a job's steps by name, in order."""
    jobs = _asic_workflow()["jobs"]
    assert isinstance(jobs, dict)
    return {step["name"]: step for step in jobs[job]["steps"]}


def test_asic_workflow_triggers_and_concurrency() -> None:
    """Pushes to main, the run-asic label, and manual runs; no run cancels main's."""
    workflow = _asic_workflow()
    # PyYAML reads the "on" key as True.
    assert workflow[True] == {
        "push": {"branches": ["main"]},
        "pull_request": {"branches": ["main"], "types": ["labeled"]},
        "workflow_dispatch": None,
    }
    assert workflow["concurrency"] == {
        "group": (
            "${{ github.workflow }}-${{ github.event.pull_request.number || "
            "github.ref }}${{ github.event.action == 'labeled' && "
            "github.event.label.name != 'run-asic' && '-label' || '' }}"
        ),
        "cancel-in-progress": "${{ github.event_name == 'pull_request' }}",
    }
    assert workflow["permissions"] == {"contents": "read"}


@pytest.mark.parametrize(
    ("event", "added", "labeled", "runs"),
    [
        ("push", "", "false", "true"),
        ("workflow_dispatch", "", "false", "true"),
        ("pull_request", "run-asic", "true", "true"),
        ("pull_request", "documentation", "true", "false"),
        ("pull_request", "documentation", "false", "false"),
    ],
)
def test_asic_workflow_gate_runs_the_flow_for_the_run_asic_label(
    tmp_path: Path, event: str, added: str, labeled: str, runs: str
) -> None:
    """Another label starts only the gate, which skips the image and the flow."""
    gate = _asic_steps("gate")["Decide whether the flow runs"]
    output = tmp_path / "output"
    environment = {
        **os.environ,
        "EVENT": event,
        "ACTION": "labeled" if event == "pull_request" else "",
        "ADDED": added,
        "LABELED": labeled,
        "GITHUB_OUTPUT": str(output),
    }
    subprocess.run(["bash", "-e", "-c", str(gate["run"])], env=environment, check=True)
    assert output.read_text() == f"run={runs}\n"


# The longest that each setup step took in four earlier runs of the job, in
# seconds; each step's limit is at least three times that.
MEASURED_SETUP_SECONDS = {
    "Checkout repository": 5,
    "Free disk space": 165,
    "Download Docker image": 98,
    "Load Docker image": 49,
}


def test_asic_workflow_runs_one_flow_job_within_its_limits() -> None:
    """One flow job, with a limit for each step and the job's limit their sum."""
    jobs = _asic_workflow()["jobs"]
    assert isinstance(jobs, dict)
    assert set(jobs) == {"gate", "build-docker", "asic-flow-synth"}
    assert jobs["build-docker"]["needs"] == "gate"
    assert jobs["build-docker"]["if"] == "${{ needs.gate.outputs.run == 'true' }}"
    job = jobs["asic-flow-synth"]
    assert job["needs"] == "build-docker" and "if" not in job
    steps = _asic_steps("asic-flow-synth")
    assert list(steps) == [
        "Checkout repository",
        "Free disk space",
        "Download Docker image",
        "Load Docker image",
        "Run synthesis and floorplanning",
        "Remove the flow's containers",
        "Show disk and memory use",
        "Publish the summary",
        "Upload logs and reports",
    ]
    run = steps["Run synthesis and floorplanning"]
    assert " ".join(str(run["run"]).replace("\\\n", " ").split()) == (
        "exec ./asic/orfs.py run --frost-image frost-dev:latest --target floorplan "
        "--memory-limit 75%"
    )
    # The run step took 133 to 181 minutes in four runs, the others seconds.
    limits: dict[str, int] = {}
    for name, step in steps.items():
        limit = step["timeout-minutes"]
        assert isinstance(limit, int), name
        limits[name] = limit
    assert limits.pop("Run synthesis and floorplanning") == 265
    assert all(1 <= limit <= 10 for limit in limits.values())
    for name, seconds in MEASURED_SETUP_SECONDS.items():
        assert limits[name] * 60 >= 3 * seconds, name
    # Four minutes for the runner's own setup and completion.
    assert job["timeout-minutes"] == 265 + sum(limits.values()) + 4
    for name in list(steps)[5:]:
        assert steps[name]["if"] == "always()", name
    sweep = str(steps["Remove the flow's containers"]["run"])
    assert sweep.startswith("set -euo pipefail\n")
    assert f"--filter label={orfs.CONTAINER_LABEL})" in sweep
    upload = steps["Upload logs and reports"]["with"]
    assert isinstance(upload, dict) and upload["name"] == "asic-flow-results"


@pytest.mark.parametrize("number", [signal.SIGINT, signal.SIGTERM])
def test_asic_workflow_run_step_passes_the_runners_signals_to_orfs(
    tmp_path: Path, number: int
) -> None:
    """The runner signals only the step's process, which exec makes orfs.py.

    The step runs as the runner runs it, with bash -e, and with a stand-in
    for asic/orfs.py that records the signal it receives.
    """
    received, pid_file = tmp_path / "received", tmp_path / "pid"
    driver = tmp_path / "asic" / "orfs.py"
    driver.parent.mkdir()
    driver.write_text(
        f"#!{sys.executable}\n"
        "import os, signal, sys, time\n"
        f"open({str(pid_file)!r}, 'w').write(str(os.getpid()))\n"
        "def stop(number, frame):\n"
        f"    open({str(received)!r}, 'w').write(f'{{number}} {{os.getpid()}}')\n"
        "    sys.exit(128 + number)\n"
        "signal.signal(signal.SIGINT, stop)\n"
        "signal.signal(signal.SIGTERM, stop)\n"
        "print('ready', flush=True)\n"
        "time.sleep(60)\n"
    )
    driver.chmod(0o755)
    step = tmp_path / "step.sh"
    step.write_text(
        str(_asic_steps("asic-flow-synth")["Run synthesis and floorplanning"]["run"])
    )
    process = subprocess.Popen(
        ["bash", "-e", str(step)], cwd=tmp_path, stdout=subprocess.PIPE, text=True
    )
    try:
        assert process.stdout is not None
        assert process.stdout.readline() == "ready\n"
        os.kill(process.pid, number)
        process.wait(timeout=20)
    finally:
        process.kill()
        process.wait()
        if pid_file.exists():
            with contextlib.suppress(ProcessLookupError):
                os.kill(int(pid_file.read_text()), signal.SIGKILL)
    assert received.read_text() == f"{number} {process.pid}"
    assert process.returncode == 128 + number


def test_orfs_runs_as_host_user_with_checkout_mounted() -> None:
    """ORFS writes only into asic/build, as the invoking user."""
    command = orfs.orfs_command(["NUM_CORES=4", "finish"], uid=1234, gid=5678)

    assert command[:3] == ["docker", "run", "--rm"]
    assert command[3:5] == ["--label", f"org.frost.asic-flow={orfs.REPOSITORY_ROOT}"]
    assert command[5:7] == ["--init", "--oom-score-adj=1000"]
    assert ["--user", "1234:5678"] == command[7:9]
    assert ["--volume", f"{orfs.REPOSITORY_ROOT}:/workspace"] == command[11:13]
    assert ["--workdir", "/workspace/asic/build"] == command[13:15]
    assert command[15] == orfs.ORFS_IMAGE
    assert command[16:] == [
        "make",
        "--file=/OpenROAD-flow-scripts/flow/Makefile",
        "DESIGN_CONFIG=/workspace/asic/config.mk",
        "WORK_HOME=/workspace/asic/build",
        "NUM_CORES=4",
        "finish",
    ]
    assert not any(argument.startswith("--memory") for argument in command)


def test_memory_limit_keeps_the_container_in_its_ram_with_the_hosts_swap(
    tmp_path: Path,
) -> None:
    """The limit caps RAM only; the kept, named container can be asked about memory."""
    cidfile = tmp_path / "container"
    command = orfs.orfs_command(
        ["do-grt"],
        uid=1,
        gid=1,
        name="frost-asic-flow-1-feed",
        memory_limit=12 * orfs.GIB,
        cidfile=cidfile,
    )

    assert "--rm" not in command
    assert f"--cidfile={cidfile}" in command
    assert command[command.index("--name") + 1] == "frost-asic-flow-1-feed"
    assert "--oom-score-adj=1000" in command
    assert f"--memory={12 * orfs.GIB}" in command
    assert "--memory-swap=-1" in command
    assert command.index("--memory-swap=-1") < command.index(orfs.ORFS_IMAGE)


def test_memory_limit_option_takes_gib_or_a_share_of_ram(
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A share of RAM follows the host; a size in GiB does not."""
    share = orfs._memory_limit("75%")
    assert share.size(lambda: 16 * orfs.GIB) == 12 * orfs.GIB
    assert share.size(lambda: 64 * orfs.GIB) == 48 * orfs.GIB

    # A size needs no RAM figure from the host.
    def unreported() -> int:
        raise RuntimeError("no MemTotal")

    assert orfs._memory_limit("11.5").size(unreported) == int(11.5 * orfs.GIB)
    assert orfs._memory_limit("100%").size(lambda: 8 * orfs.GIB) == 8 * orfs.GIB
    for limit in ("0", "0%", "101%", "-4", "12G", "75 %", "%", ""):
        with pytest.raises(SystemExit):
            orfs.main(["run", "--memory-limit", limit])
        assert "expected a size in GiB or a percentage" in capsys.readouterr().err
    # A size that rounds to no bytes would be no limit at all.
    with pytest.raises(SystemExit):
        orfs.main(["run", "--memory-limit", "0.0000000001"])
    assert "at least 6 MiB" in capsys.readouterr().err
    assert orfs._memory_limit("0.006").size(unreported) == int(0.006 * orfs.GIB)
    with pytest.raises(ValueError, match="below Docker's smallest"):
        orfs._memory_limit("0.0000001%").size(lambda: 16 * orfs.GIB)


def test_run_refuses_a_share_of_ram_below_dockers_smallest_limit(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A share of a host's RAM that comes to under 6 MiB stops run before Docker."""
    _write_synthesized_build(tmp_path, "3.1030")
    monkeypatch.setattr(orfs, "BUILD_DIRECTORY", tmp_path)
    monkeypatch.setattr(orfs, "host_ram", lambda: 16 * orfs.GIB)
    monkeypatch.setattr(orfs, "run_logged", pytest.fail)
    assert orfs.main(["run", "--from", "grt", "--memory-limit", "0.0000001%"]) == 2
    assert "below Docker's smallest, 6 MiB" in capsys.readouterr().err


def _write_memory_files(proc: Path, cgroups: Path | None, container: str) -> None:
    """Leave the kernel's memory files of a host running a container."""
    (proc / "pressure").mkdir(parents=True)
    (proc / "meminfo").write_text(
        "MemTotal:       16384000 kB\n"
        "MemFree:          204800 kB\n"
        "MemAvailable:    4096000 kB\n"
        "SwapTotal:      28311552 kB\n"
        "SwapFree:       18874368 kB\n"
        "HugePages_Total:       0\n"
    )
    (proc / "pressure" / "memory").write_text(
        "some avg10=31.50 avg60=24.75 avg300=10.00 total=123456\n"
        "full avg10=12.00 avg60=9.40 avg300=3.00 total=65432\n"
    )
    if cgroups is not None:
        directory = cgroups / "system.slice" / f"docker-{container}.scope"
        directory.mkdir(parents=True)
        (directory / "memory.current").write_text(f"{int(11.5 * orfs.GIB)}\n")
        (directory / "memory.max").write_text(f"{12 * orfs.GIB}\n")
        (directory / "memory.swap.current").write_text(f"{9 * orfs.GIB}\n")
        (directory / "memory.stat").write_text(
            f"anon {int(10.5 * orfs.GIB)}\nfile {orfs.GIB}\nkernel 0\n"
        )
        (directory / "memory.pressure").write_text(
            "some avg10=70.00 avg60=61.20 avg300=20.00 total=99\n"
            "full avg10=60.00 avg60=55.00 avg300=18.00 total=77\n"
        )


def test_memory_report_describes_the_host_and_the_flow_container(
    tmp_path: Path,
) -> None:
    """One line gives RAM, swap, the container against its limit, and stalls."""
    container = "c0ffee" * 10
    proc, cgroups = tmp_path / "proc", tmp_path / "cgroup"
    _write_memory_files(proc, cgroups, container)
    cidfile = tmp_path / "container"
    cidfile.write_text(container)

    line = orfs.MemoryReport(cidfile, proc, cgroups)()

    assert line is not None
    assert line.startswith("Memory after 0:00:00: ")
    assert line.endswith(
        "host RAM 11.7 of 15.6 GiB in use, swap 9.0 of 27.0 GiB, waiting for "
        "memory 25% of the last minute, every task 9%; flow container 11.5 of "
        "12.0 GiB (10.5 GiB anonymous), swap 9.0 GiB, waiting for memory 61% "
        "of the last minute, every task 55%"
    )

    # Before Docker names the container, and on a host without its group,
    # the line describes the host alone.
    assert "flow container" not in (orfs.MemoryReport(tmp_path / "none", proc)() or "")
    other = tmp_path / "other"
    _write_memory_files(other, None, container)
    assert orfs.MemoryReport(cidfile, other, other / "cgroup")() == (
        "Memory after 0:00:00: host RAM 11.7 of 15.6 GiB in use, "
        "swap 9.0 of 27.0 GiB, waiting for memory 25% of the last minute, "
        "every task 9%"
    )
    # A kernel without memory stall reports leaves them out.
    (other / "pressure" / "memory").unlink()
    assert orfs.MemoryReport(None, other)() == (
        "Memory after 0:00:00: host RAM 11.7 of 15.6 GiB in use, swap 9.0 of 27.0 GiB"
    )
    assert orfs.MemoryReport(None, tmp_path / "missing")() is None


def test_run_logged_kills_a_command_that_ignores_the_stop(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A command that ignores the watchdog's SIGTERM is killed after a while."""
    monkeypatch.setattr(orfs, "STOP_SECONDS", 0.5)
    child = (
        "import signal, time\n"
        "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
        "print('        0 |   0.9993 |  3.078199e+07 |   +0.00% |  1.95e-17 |', flush=True)\n"
        "print('      550 |   0.2604 |  1.177593e+09 |  +29.49% |  3.61e-07 |', flush=True)\n"
        "time.sleep(600)\n"
    )
    start = time.monotonic()
    status = orfs.run_logged(
        [sys.executable, "-c", child],
        tmp_path / "orfs.log",
        watchdog=orfs.PlacementWatchdog(),
    )
    assert status == 1
    assert time.monotonic() - start < 30


def test_run_logged_leaves_no_command_behind_when_interrupted(tmp_path: Path) -> None:
    """An exception in run_logged, as a signal raises, stops the command's group.

    The command ignores SIGINT and has started a process of its own, as
    frost.py starts a docker client; both are gone within the bounded waits.
    """
    pid_file = tmp_path / "pids"
    child = (
        "import os, signal, subprocess, sys, time\n"
        "signal.signal(signal.SIGINT, signal.SIG_IGN)\n"
        "grandchild = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(600)'])\n"
        f"open({str(pid_file)!r}, 'w').write(f'{{os.getpid()}} {{grandchild.pid}}')\n"
        "print('started', flush=True)\n"
        "time.sleep(600)\n"
    )

    class Interrupt:
        def check(self, line: str) -> str | None:
            raise KeyboardInterrupt

    start = time.monotonic()
    with pytest.raises(KeyboardInterrupt):
        orfs.run_logged(
            [sys.executable, "-c", child],
            tmp_path / "orfs.log",
            watchdog=Interrupt(),  # type: ignore[arg-type]
        )
    assert time.monotonic() - start < orfs.INTERRUPT_SECONDS + 10
    command, grandchild = (int(pid) for pid in pid_file.read_text().split())
    with pytest.raises(ProcessLookupError):
        os.kill(command, 0)
    # The grandchild, killed with its group, waits for init to reap it.
    for _ in range(100):
        state = Path(f"/proc/{grandchild}/stat")
        if not state.exists() or state.read_text().split(") ")[1].startswith("Z"):
            break
        time.sleep(0.05)
    else:
        pytest.fail(f"process {grandchild} outlived its group")


def test_signals_raise_outside_a_cleanup_and_wait_until_after_one() -> None:
    """SIGINT and SIGTERM unwind run; during a cleanup they wait for its end."""
    signals = orfs._Signals()
    with pytest.raises(KeyboardInterrupt):
        signals(signal.SIGINT, None)
    with pytest.raises(SystemExit) as stop:
        signals(signal.SIGTERM, None)
    assert stop.value.code == 143
    signals.deferring = True
    signals(signal.SIGTERM, None)
    signals(signal.SIGINT, None)
    signals.deferring = False
    with pytest.raises(SystemExit) as stop:
        signals.honor()
    assert stop.value.code == 143
    # Without a signal during the cleanup, nothing happens after it.
    orfs._Signals().honor()


def test_docker_calls_that_hang_are_abandoned(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    """Inspection and removal give up after STOP_SECONDS instead of hanging."""
    timeouts: list[object] = []

    def hang(command: list[str], *, timeout: float, **kwargs: object) -> object:
        timeouts.append(timeout)
        raise subprocess.TimeoutExpired(command, timeout)

    monkeypatch.setattr(orfs.subprocess, "run", hang)
    assert orfs.stopped_for_memory("feed") is None
    assert orfs.remove_container("feed") == (
        f"Docker did not remove container feed: it did not finish within "
        f"{orfs.STOP_SECONDS} seconds"
    )
    assert timeouts == [orfs.STOP_SECONDS, orfs.STOP_SECONDS]

    # Nor does a Docker client that cannot start raise.
    def missing(command: list[str], **kwargs: object) -> object:
        raise FileNotFoundError(2, "No such file or directory", "docker")

    monkeypatch.setattr(orfs.subprocess, "run", missing)
    assert orfs.stopped_for_memory("feed") is None
    reason = orfs.remove_container("feed")
    assert reason is not None and "could not start" in reason


def test_run_removes_the_container_when_interrupted(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A signal during the flow still removes its container, without asking why."""
    _write_synthesized_build(tmp_path, "3.1030")
    monkeypatch.setattr(orfs, "BUILD_DIRECTORY", tmp_path)
    names: list[str] = []
    removed: list[str] = []
    inspected: list[str] = []

    def interrupted(command: list[str], *args: object, **kwargs: object) -> int:
        names.append(command[command.index("--name") + 1])
        raise SystemExit(143)

    monkeypatch.setattr(orfs, "run_logged", interrupted)
    monkeypatch.setattr(orfs, "stopped_for_memory", inspected.append)
    monkeypatch.setattr(orfs, "remove_container", removed.append)
    with pytest.raises(SystemExit):
        orfs.main(["run", "--from", "grt"])
    assert names[0].startswith(f"frost-asic-flow-{os.getpid()}-")
    assert removed == names
    assert inspected == []


def test_run_logged_reports_while_the_command_is_silent(tmp_path: Path) -> None:
    """Report lines reach the log between the command's own lines."""
    child = (
        "import time\n"
        "print('first', flush=True)\n"
        "time.sleep(1.0)\n"
        "print('last', flush=True)\n"
    )
    log = tmp_path / "orfs.log"
    reports = iter(range(1000))

    def report() -> str:
        return f"Memory report {next(reports)}"

    status = orfs.run_logged(
        [sys.executable, "-c", child], log, report=report, report_seconds=0.1
    )

    assert status == 0
    lines = log.read_text().splitlines()
    # A last report can follow the command's last line.
    between = lines[lines.index("first") + 1 : lines.index("last")]
    assert len(between) >= 3
    assert all(line.startswith("Memory report ") for line in between)
    assert all(
        line.startswith("Memory report ") for line in lines[lines.index("last") + 1 :]
    )


def test_run_names_a_container_stopped_for_memory(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A flow that the kernel stopped for memory says so, with its limit."""
    _write_synthesized_build(tmp_path, "3.1030")
    monkeypatch.setattr(orfs, "BUILD_DIRECTORY", tmp_path)
    monkeypatch.setattr(orfs, "host_ram", lambda: 16 * orfs.GIB)
    commands: list[list[str]] = []
    removed: list[str] = []

    def stopped(command: list[str], *args: object, **kwargs: object) -> int:
        commands.append(command)
        return 2

    monkeypatch.setattr(orfs, "run_logged", stopped)
    monkeypatch.setattr(orfs, "stopped_for_memory", lambda container: True)
    monkeypatch.setattr(orfs, "remove_container", removed.append)
    monkeypatch.setattr(orfs, "summarize", lambda **kwargs: 0)

    assert orfs.main(["run", "--from", "grt", "--memory-limit", "75%"]) == 2
    assert f"--memory={12 * orfs.GIB}" in commands[0]
    assert removed == [commands[0][commands[0].index("--name") + 1]]
    message = (
        "Error: the kernel stopped the flow for lack of memory; its container "
        "may use 12.0 GiB of RAM and the host's swap space"
    )
    assert message in capsys.readouterr().err
    assert message in (tmp_path / "orfs.log").read_text()

    monkeypatch.setattr(orfs, "stopped_for_memory", lambda container: False)
    assert orfs.main(["run", "--from", "grt"]) == 2
    assert "lack of memory" not in capsys.readouterr().err
    assert not any(argument.startswith("--memory=") for argument in commands[1])


# A stand-in docker client. Each container is a file in FAKE_DOCKER_STATE,
# and environment variables set what each command does. FAKE_DOCKER_FLOW and
# FAKE_DOCKER_SUMMARY hold words: "exit <status>" last; "sleep"; "no-id",
# which leaves the --cidfile unwritten; "keep", which leaves the container
# as a client that fails after Docker made it does; and "signal", which
# sends SIGTERM to the caller. FAKE_DOCKER_RM is "ok", "fail", "hang", or
# "signal"; FAKE_DOCKER_OOM is what inspect reports, or "garbled" for bytes
# that are not UTF-8; FAKE_DOCKER_PS "fail" fails the listing; and
# FAKE_DOCKER_BREAK_LOG names a file that the flow turns into a directory,
# as a full disk refuses writes.
FAKE_DOCKER = r"""
import json, os, pathlib, signal, sys, time
state = pathlib.Path(os.environ["FAKE_DOCKER_STATE"])
args = sys.argv[1:]
with (state / "calls").open("a") as calls:
    calls.write(json.dumps(args) + "\n")


def option(flag):
    for index, argument in enumerate(args):
        if argument == flag:
            return args[index + 1]
        if argument.startswith(flag + "="):
            return argument.partition("=")[2]
    return None


if args[0] == "run":
    name = option("--name")
    role = "SUMMARY" if "elapsed" in args else "FLOW"
    behavior = os.environ.get(f"FAKE_DOCKER_{role}", "exit 0").split()
    if name:
        (state / f"container-{name}").write_text("")
    cidfile = option("--cidfile")
    if cidfile and "no-id" not in behavior:
        pathlib.Path(cidfile).write_text(f"id-{name}\n")
    print("created", flush=True)
    if "sleep" in behavior:
        time.sleep(600)
    if "signal" in behavior:
        os.kill(os.getppid(), signal.SIGTERM)
        time.sleep(5)
    broken = os.environ.get("FAKE_DOCKER_BREAK_LOG")
    if broken and role == "FLOW":
        pathlib.Path(broken).unlink()
        pathlib.Path(broken).mkdir()
    if "--rm" in args and name and "keep" not in behavior:
        (state / f"container-{name}").unlink()
    sys.exit(int(behavior[-1]))
if args[0] == "rm":
    mode = os.environ.get("FAKE_DOCKER_RM", "ok")
    if mode == "signal":
        os.kill(os.getppid(), signal.SIGTERM)
        time.sleep(0.5)
    if mode == "hang":
        time.sleep(600)
    if mode == "fail":
        print("Error response from daemon: removal failed", file=sys.stderr)
        sys.exit(1)
    for name in args[2:]:
        container = state / f"container-{name}"
        if container.exists():
            container.unlink()
            print(name)
        else:
            print(f"Error response from daemon: No such container: {name}", file=sys.stderr)
    sys.exit(0)
if args[0] == "inspect":
    answer = os.environ.get("FAKE_DOCKER_OOM", "false")
    if answer == "garbled":
        sys.stdout.buffer.write(b"\xff\xfe\xfa\n")
    else:
        print(answer)
    sys.exit(0)
if args[0] == "ps":
    if os.environ.get("FAKE_DOCKER_PS") == "fail":
        print("Cannot connect to the Docker daemon", file=sys.stderr)
        sys.exit(42)
    for container in sorted(state.glob("container-*")):
        print(container.name.removeprefix("container-"))
    sys.exit(0)
sys.exit(f"fake docker: unexpected {args}")
"""


@pytest.fixture
def fake_docker(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    """Put the stand-in docker client first on PATH; return its state directory.

    The build directory holds a synthesized build, so that run --from grt
    goes straight to the flow.
    """
    state = tmp_path / "docker"
    state.mkdir()
    client = tmp_path / "bin" / "docker"
    client.parent.mkdir()
    client.write_text(f"#!{sys.executable}\n{FAKE_DOCKER}")
    client.chmod(0o755)
    monkeypatch.setenv("PATH", f"{client.parent}{os.pathsep}{os.environ['PATH']}")
    monkeypatch.setenv("FAKE_DOCKER_STATE", str(state))
    build = tmp_path / "build"
    _write_synthesized_build(build, "3.1030")
    monkeypatch.setattr(orfs, "BUILD_DIRECTORY", build)
    return state


def _containers(state: Path) -> list[str]:
    """Return the names of the stand-in Docker's containers."""
    return sorted(
        path.name.removeprefix("container-") for path in state.glob("container-*")
    )


def _docker_calls(state: Path) -> list[list[str]]:
    """Return the arguments of each call to the stand-in Docker client."""
    return [json.loads(line) for line in (state / "calls").read_text().splitlines()]


@pytest.mark.parametrize(
    ("flow", "oom", "status"),
    [("exit 0", "false", 0), ("exit 2", "false", 2), ("exit 2", "true", 2)],
)
def test_run_removes_its_container_and_keeps_the_flows_status(
    fake_docker: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    flow: str,
    oom: str,
    status: int,
) -> None:
    """Success, a failed make, and a stop for memory each remove the container."""
    monkeypatch.setenv("FAKE_DOCKER_FLOW", flow)
    monkeypatch.setenv("FAKE_DOCKER_OOM", oom)
    assert orfs.main(["run", "--from", "grt"]) == status
    assert _containers(fake_docker) == []
    assert ("for lack of memory" in capsys.readouterr().err) == (oom == "true")


@pytest.mark.parametrize("removal", ["fail", "hang"])
@pytest.mark.parametrize(("flow", "status"), [("exit 0", 1), ("exit 2", 2)])
def test_run_fails_when_docker_does_not_remove_its_container(
    fake_docker: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    removal: str,
    flow: str,
    status: int,
) -> None:
    """A container left behind fails a run that passed and is named in the log.

    A run that failed keeps the flow's status.
    """
    monkeypatch.setattr(orfs, "STOP_SECONDS", 1)
    monkeypatch.setenv("FAKE_DOCKER_FLOW", flow)
    monkeypatch.setenv("FAKE_DOCKER_RM", removal)
    assert orfs.main(["run", "--from", "grt"]) == status
    [name] = _containers(fake_docker)
    error = capsys.readouterr().err
    log = (orfs.BUILD_DIRECTORY / "orfs.log").read_text()
    for text in (error, log):
        assert f"Error: Docker did not remove container {name}: " in text
        assert f"remove it with: docker rm --force {name}" in text


def test_run_removes_a_container_whose_id_docker_has_not_written(
    fake_docker: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Interrupted after Docker made the container, run removes it by name."""
    monkeypatch.setenv("FAKE_DOCKER_FLOW", "no-id sleep")

    class Interrupt(orfs.PlacementWatchdog):
        def check(self, line: str) -> str | None:
            if line == "created\n":
                raise KeyboardInterrupt
            return None

    monkeypatch.setattr(orfs, "PlacementWatchdog", Interrupt)
    assert orfs.main(["run", "--from", "grt"]) == 130
    assert _containers(fake_docker) == []
    run, *rest = _docker_calls(fake_docker)
    assert rest == [["rm", "--force", run[run.index("--name") + 1]]]


def test_run_keeps_makes_status_when_the_memory_question_fails(
    fake_docker: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A failed question about memory leaves it unknown and the removal done."""
    monkeypatch.setenv("FAKE_DOCKER_FLOW", "exit 2")

    def broken(container: str) -> bool:
        raise RuntimeError("inspection failed")

    monkeypatch.setattr(orfs, "stopped_for_memory", broken)
    assert orfs.main(["run", "--from", "grt"]) == 2
    error = capsys.readouterr().err
    assert "Warning: could not ask Docker about memory: inspection failed" in error
    assert "Traceback" not in error
    assert _containers(fake_docker) == []


def test_run_keeps_makes_status_when_docker_answers_garbage(
    fake_docker: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """An answer that is neither true nor false, nor UTF-8, means unknown."""
    monkeypatch.setenv("FAKE_DOCKER_FLOW", "exit 2")
    monkeypatch.setenv("FAKE_DOCKER_OOM", "garbled")
    assert orfs.main(["run", "--from", "grt"]) == 2
    error = capsys.readouterr().err
    assert "Docker could not say whether the kernel stopped the flow" in error
    assert "Traceback" not in error
    assert _containers(fake_docker) == []


def test_run_keeps_makes_status_when_the_summary_cannot_start(
    fake_docker: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A Docker client missing when the summary starts does not hide make's 2."""
    monkeypatch.setenv("FAKE_DOCKER_FLOW", "exit 2")
    real_run = subprocess.run

    def missing_for_the_summary(
        command: list[str], *args: object, **kwargs: object
    ) -> object:
        if "elapsed" in command:
            raise FileNotFoundError(2, "No such file or directory", "docker")
        return real_run(command, *args, **kwargs)  # type: ignore[call-overload]

    monkeypatch.setattr(orfs.subprocess, "run", missing_for_the_summary)
    assert orfs.main(["run", "--from", "grt"]) == 2
    error = capsys.readouterr().err
    assert "Error: make elapsed could not start" in error
    assert "Traceback" not in error
    assert _containers(fake_docker) == []


def test_summary_removes_the_container_that_its_failed_client_left(
    fake_docker: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A docker client that fails after Docker made the container (125)."""
    monkeypatch.setenv("FAKE_DOCKER_SUMMARY", "keep exit 125")
    assert orfs.main(["summary"]) == 125
    assert _containers(fake_docker) == []
    calls = _docker_calls(fake_docker)
    summary = next(call for call in calls if "elapsed" in call)
    assert ["rm", "--force", summary[summary.index("--name") + 1]] in calls


def test_run_removes_its_container_when_sigterm_comes_as_the_flow_ends(
    fake_docker: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A signal at the end of the flow unwinds run through the removal."""
    monkeypatch.setenv("FAKE_DOCKER_FLOW", "signal exit 0")
    with pytest.raises(SystemExit) as stop:
        orfs.main(["run", "--from", "grt"])
    assert stop.value.code == 143
    assert _containers(fake_docker) == []


def test_run_honors_a_sigterm_during_the_removal_once_it_is_done(
    fake_docker: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A signal while Docker removes the container stops run after the removal."""
    monkeypatch.setenv("FAKE_DOCKER_RM", "signal")
    with pytest.raises(SystemExit) as stop:
        orfs.main(["run", "--from", "grt"])
    assert stop.value.code == 143
    assert _containers(fake_docker) == []
    assert not any("elapsed" in call for call in _docker_calls(fake_docker))


def _sweep_step(state: Path) -> Path:
    """Write the workflow's step that removes the flow's containers to a file."""
    step = state.parent / "sweep.sh"
    step.write_text(
        str(_asic_steps("asic-flow-synth")["Remove the flow's containers"]["run"])
    )
    return step


def test_asic_workflow_sweep_removes_every_container_with_the_label(
    fake_docker: Path,
) -> None:
    """The step after the run removes what a killed orfs.py left, or nothing."""
    for name in ("frost-asic-flow-1-aa", "frost-asic-summary-1-bb"):
        (fake_docker / f"container-{name}").write_text("")
    step = _sweep_step(fake_docker)
    subprocess.run(["bash", "-e", str(step)], check=True)
    assert _containers(fake_docker) == []
    subprocess.run(["bash", "-e", str(step)], check=True)


@pytest.mark.parametrize("failure", ["FAKE_DOCKER_PS", "FAKE_DOCKER_RM"])
def test_asic_workflow_sweep_fails_when_docker_fails(
    fake_docker: Path, monkeypatch: pytest.MonkeyPatch, failure: str
) -> None:
    """A listing or a removal that fails fails the step."""
    (fake_docker / "container-frost-asic-flow-1-aa").write_text("")
    monkeypatch.setenv(failure, "fail")
    step = _sweep_step(fake_docker)
    assert subprocess.run(["bash", "-e", str(step)], check=False).returncode != 0


def test_run_keeps_the_flows_status_when_the_log_takes_no_more(
    fake_docker: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A log that refuses writes loses the out-of-memory line, not make's status."""
    monkeypatch.setenv("FAKE_DOCKER_FLOW", "exit 2")
    monkeypatch.setenv("FAKE_DOCKER_OOM", "true")
    monkeypatch.setenv("FAKE_DOCKER_BREAK_LOG", str(orfs.BUILD_DIRECTORY / "orfs.log"))
    assert orfs.main(["run", "--from", "grt"]) == 2
    error = capsys.readouterr().err
    assert "for lack of memory" in error
    assert "could not add that line" in error
    assert _containers(fake_docker) == []


def test_summary_gives_up_on_a_docker_call_that_hangs(
    fake_docker: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Make elapsed has a deadline, after which its container is removed."""
    monkeypatch.setattr(orfs, "SUMMARY_SECONDS", 1)
    monkeypatch.setenv("FAKE_DOCKER_SUMMARY", "sleep")
    start = time.monotonic()
    assert orfs.main(["summary"]) == 1
    assert time.monotonic() - start < 30
    assert "make elapsed did not finish within 1 seconds" in capsys.readouterr().err
    assert _containers(fake_docker) == []


def test_run_turns_sigterm_into_an_exception_before_preparing(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Preparation runs with the handler that unwinds run, which run restores."""
    monkeypatch.setattr(orfs, "BUILD_DIRECTORY", tmp_path / "build")
    handlers: list[tuple[object, object]] = []

    def prepare(frost_image: str, log_path: Path) -> int:
        handlers.append(
            (signal.getsignal(signal.SIGINT), signal.getsignal(signal.SIGTERM))
        )
        return 3

    monkeypatch.setattr(orfs, "prepare_in_frost_image", prepare)
    before = (signal.getsignal(signal.SIGINT), signal.getsignal(signal.SIGTERM))
    assert orfs.main(["run"]) == 3
    [(on_interrupt, on_termination)] = handlers
    assert isinstance(on_termination, orfs._Signals) and on_interrupt is on_termination
    assert (signal.getsignal(signal.SIGINT), signal.getsignal(signal.SIGTERM)) == before


def test_make_goals_resume_with_unconditional_stage_targets() -> None:
    """A resumed run reruns each stage from --from through --target."""
    assert orfs.make_goals(None, "grt") == ["grt"]
    assert orfs.make_goals("place", "grt") == ["do-place", "do-cts", "do-grt"]
    # Detailed routing resumes from the global routing database.
    assert orfs.make_goals("route", "finish") == [
        "do-5_2_route",
        "do-5_3_fillcell",
        "do-5_route",
        "do-5_route.sdc",
        "do-finish",
        "do-gds",
    ]
    with pytest.raises(ValueError, match="comes after"):
        orfs.make_goals("route", "cts")


def test_clock_period_reaches_make_only_when_given() -> None:
    """The flow's make sees FROST_CORE_CLOCK_PERIOD only for --clock-period."""
    assert orfs.make_variables(4, None) == ["NUM_CORES=4"]
    assert orfs.make_variables(16, 1.6) == [
        "NUM_CORES=16",
        "FROST_CORE_CLOCK_PERIOD=1.6",
    ]
    # Every digit the SDC files keep reaches the flow.
    assert orfs.make_variables(1, 100.0001)[1] == "FROST_CORE_CLOCK_PERIOD=100.0001"
    assert orfs.format_period(3.0) == "3"


def _write_synthesized_build(build: Path, core_period: str) -> None:
    """Leave a build whose synthesis wrote its constraints with core_period."""
    results = build / orfs.FLOW_SUBDIRECTORY.format(kind="results")
    results.mkdir(parents=True)
    (results / "1_synth.sdc").write_text(
        "current_design platform_top\n"
        f"create_clock -name core_clk -period {core_period} [get_ports {{i_clk}}]\n"
    )
    (build / "sources.mk").write_text("export VERILOG_FILES =\n")


def test_run_refuses_a_build_with_another_clock_period(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Make does not track the period, so a changed period needs a new build.

    Resuming takes the period from the build, so --from rejects the option.
    """
    _write_synthesized_build(tmp_path, "3.1030")
    monkeypatch.setattr(orfs, "BUILD_DIRECTORY", tmp_path)

    assert orfs.built_clock_period(tmp_path) == pytest.approx(3.103)
    assert orfs.main(["run", "--clock-period", "1.6"]) == 2
    assert "with a 3.103 ns core clock" in capsys.readouterr().err
    assert orfs.main(["run", "--from", "cts", "--clock-period", "1.6"]) == 2
    assert "cannot be combined with --from" in capsys.readouterr().err

    monkeypatch.setattr(orfs, "BUILD_DIRECTORY", tmp_path / "other")
    _write_synthesized_build(tmp_path / "other", "1.6000")
    assert orfs.main(["run"]) == 2
    assert "delete it to run the flow at 3.103 ns" in capsys.readouterr().err


def test_cpu_clock_build_configuration_and_resume(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    """CPU clock configuration changes require a fresh build; resumes use its clock."""
    _write_synthesized_build(tmp_path, "3.1030")
    monkeypatch.setattr(orfs, "BUILD_DIRECTORY", tmp_path)
    assert orfs.main(["run", "--cpu-clock-period", "1.3"]) == 2
    assert "CPU clock configuration differs" in capsys.readouterr().err
    constraints = (
        tmp_path / orfs.FLOW_SUBDIRECTORY.format(kind="results") / "1_synth.sdc"
    )
    constraints.write_text(
        constraints.read_text()
        + "create_clock -name cpu_clk -period 1.3000 [get_ports {i_cpu_clk}]\n"
    )
    assert orfs.main(["run"]) == 2
    assert "CPU clock configuration differs" in capsys.readouterr().err
    assert orfs.main(["run", "--cpu-clock-period", "7"]) == 2
    assert "CPU clock configuration differs" in capsys.readouterr().err
    commands: list[list[str]] = []

    def capture(command: list[str], *args: object, **kwargs: object) -> int:
        commands.append(command)
        return 1

    monkeypatch.setattr(orfs, "run_logged", capture)
    monkeypatch.setattr(orfs, "summarize", lambda **kwargs: 0)
    assert orfs.main(["run", "--from", "cts"]) == 1
    assert len(commands) == 1
    assert "FROST_CPU_CLOCK_PERIOD=1.3" in commands[0]


def _nesterov_row(iteration: int, hpwl: float) -> str:
    return f"{iteration:9d} |   0.9000 | {hpwl:.6e} |   +0.00% |  1.95e-17 |      \n"


def test_placement_watchdog_accepts_a_converging_placement() -> None:
    """A wirelength that settles near three times its start never stops the flow."""
    watchdog = orfs.PlacementWatchdog()
    assert (
        watchdog.check("[INFO GPL-0084] ---- Execute Nesterov Global Placement.\n")
        is None
    )
    for iteration in range(0, 2000, 10):
        assert (
            watchdog.check(_nesterov_row(iteration, 3.0e7 + 1.0e4 * iteration)) is None
        )


def test_placement_watchdog_stops_a_diverging_placement() -> None:
    """A hundredfold wirelength stops the flow at once, not at the iteration cap."""
    watchdog = orfs.PlacementWatchdog()
    assert watchdog.check(_nesterov_row(0, 3.078199e7)) is None
    reason = watchdog.check(_nesterov_row(550, 1.178e9))
    assert reason is not None and "diverged" in reason


def test_placement_watchdog_restarts_with_each_placement() -> None:
    """Each placement's first row is its own baseline."""
    watchdog = orfs.PlacementWatchdog()
    assert watchdog.check(_nesterov_row(0, 3.0e7)) is None
    watchdog.check("[INFO GPL-0084] ---- Execute Nesterov Global Placement.\n")
    assert watchdog.check(_nesterov_row(0, 5.0e8)) is None
    assert watchdog.check(_nesterov_row(900, 6.0e8)) is None


def test_placement_watchdog_stops_at_openroads_iteration_limit() -> None:
    """OpenROAD's warning that it hit the iteration limit stops the flow."""
    watchdog = orfs.PlacementWatchdog()
    line = "[WARNING GPL-1010] GPL reached the maximum number of iterations for nesterov 5000.\n"
    assert watchdog.check(line) is not None


def test_run_logged_stops_a_command_the_watchdog_rejects(tmp_path: Path) -> None:
    """The command is terminated, and its output up to the end is still logged."""
    # SIGTERM is blocked until the child waits for it: a handler that ran
    # inside print()'s own flush would find stdout busy and fail to write.
    child = (
        "import signal, sys\n"
        "signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGTERM})\n"
        "print('        0 |   0.9993 |  3.078199e+07 |   +0.00% |  1.95e-17 |', flush=True)\n"
        "print('      550 |   0.2604 |  1.177593e+09 |  +29.49% |  3.61e-07 |', flush=True)\n"
        "signal.sigwait({signal.SIGTERM})\n"
        "sys.stdout.write('child shutdown line\\n' * 20000)\n"
        "sys.stdout.flush()\n"
    )
    log = tmp_path / "orfs.log"
    status = orfs.run_logged(
        [sys.executable, "-c", child], log, watchdog=orfs.PlacementWatchdog()
    )
    assert status == 1
    text = log.read_text()
    assert "diverged" in text
    assert text.splitlines().count("child shutdown line") == 20000


def test_clock_period_option_rejects_periods_the_sdc_refuses(
    capsys: pytest.CaptureFixture[str],
) -> None:
    """The option rejects what the SDC would: four decimals keep div4 exact."""
    for period in (
        "0",
        "0.0",
        "-2",
        "nan",
        "inf",
        "fast",
        "1e-3",
        "08",
        "1.60004",
        "100",
        "1" * 400,
    ):
        with pytest.raises(SystemExit):
            orfs.main(["run", "--clock-period", period])
        assert "expected a positive period in ns" in capsys.readouterr().err


def test_sources_makefile_is_independent_of_the_mount_point(tmp_path: Path) -> None:
    """Sources are relative to the checkout; the converted NIC is in the build."""
    rtl = orfs.REPOSITORY_ROOT / "hw" / "rtl"
    converted = str(tmp_path / "nic.v")
    makefile = orfs.sources_makefile(
        [converted, str(rtl / "frost.sv"), str(rtl / "lib" / "cdc" / "cdc_sync.sv")],
        converted,
        [str(rtl / "lib/cache")],
    )

    assert makefile.splitlines()[1:] == [
        "export VERILOG_FILES = \\",
        "  $(WORK_HOME)/src/nic.v \\",
        "  $(FROST_ROOT)/hw/rtl/frost.sv \\",
        "  $(FROST_ROOT)/hw/rtl/lib/cdc/cdc_sync.sv",
        "export VERILOG_INCLUDE_DIRS = $(FROST_ROOT)/hw/rtl/lib/cache",
    ]
    with pytest.raises(ValueError, match="outside the repository"):
        orfs.sources_makefile([converted, "/elsewhere/top.sv"], converted)
    with pytest.raises(ValueError, match="include directory outside"):
        orfs.sources_makefile([converted], converted, ["/elsewhere/headers"])


# Stand-ins for the OpenSTA commands that asic/constraint.sdc calls. Each
# command prints what it constrains: "clock <name> <period>", "generated
# <name> <master> <divisor> <pin>", "<input|output> <port> <clock> <delay>",
# or "false_path <hold|all> <ports>". With FROST_HARNESS_NO_PINS set,
# get_pins finds nothing.
SDC_HARNESS = r"""
set clocks [dict create]
set clock_ports [dict create]
proc option {arguments name} {
    return [lindex $arguments [expr {[lsearch -exact $arguments $name] + 1}]]
}
proc create_clock {args} {
    dict set ::clocks [option $args -name] [option $args -period]
    dict set ::clock_ports [lindex $args end] [option $args -name]
    puts "clock [option $args -name] [option $args -period] [lindex $args end]"
}
proc create_generated_clock {args} {
    set master [dict get $::clock_ports [option $args -source]]
    dict set ::clocks [option $args -name] [dict get $::clocks $master]
    puts "generated [option $args -name] $master [option $args -divide_by]\
        [join [lindex $args end] { }]"
}
proc get_pins {args} {
    if {[info exists ::env(FROST_HARNESS_NO_PINS)]} {return {}}
    return [list [lindex $args end]]
}
proc get_ports {patterns} {return $patterns}
proc get_clocks {names} {return $names}
proc set_clock_groups {args} {
    foreach {flag members} [lrange $args 1 end] {
        if {$flag eq "-group"} {puts "group [join $members { }]"}
    }
}
proc set_max_delay {delay args} {puts "max_delay $delay [join $args { }]"}
proc set_min_delay {delay args} {puts "min_delay $delay [join $args { }]"}
proc all_inputs {args} {return $::inputs}
proc all_outputs {} {return $::outputs}
proc get_full_name {object} {return $object}
proc get_property {clock property} {return [dict get $::clocks $clock]}
proc set_input_delay {delay args} {
    puts "input [lindex $args end] [option $args -clock] $delay"
}
proc set_output_delay {delay args} {
    puts "output [lindex $args end] [option $args -clock] $delay"
}
proc set_false_path {args} {
    set checks [expr {"-hold" in $args ? "hold" : "all"}]
    puts "false_path $checks [join [option $args -from] { }]"
}
set inputs {
    i_rst i_instr_mem_en i_instr_mem_wrdata[3] i_ddr_axi_rdata[7]
    i_power_on_rst i_nic_rx_raw_data[5] i_nic_rx_signal_ok i_jtag_tms i_jtag_tdi i_jtag_trst_n
    i_nic_tx_clk_ok i_nic_rx_clk_ok i_nic_phy_status[2]
}
set outputs {o_uart_wr_en o_ddr_axi_araddr[4] o_nic_tx_raw_data[9] o_jtag_tdo}
source [lindex $argv 0]
"""
# The clock that times each of the harness's ports.
PORT_CLOCKS = {
    "i_rst": "core_clk",
    "i_instr_mem_en": "core_clk_div4",
    "i_instr_mem_wrdata[3]": "core_clk_div4",
    "i_ddr_axi_rdata[7]": "core_clk",
    "i_nic_rx_raw_data[5]": "nic_rx_clk",
    "i_nic_rx_signal_ok": "nic_rx_clk",
    "i_jtag_tms": "jtag_tck",
    "i_jtag_tdi": "jtag_tck",
    "i_jtag_trst_n": "core_clk",
    "i_power_on_rst": "core_clk",
    "i_nic_tx_clk_ok": "core_clk",
    "i_nic_rx_clk_ok": "core_clk",
    "i_nic_phy_status[2]": "core_clk",
    "o_uart_wr_en": "core_clk",
    "o_ddr_axi_araddr[4]": "core_clk",
    "o_nic_tx_raw_data[9]": "nic_tx_clk",
    "o_jtag_tdo": "jtag_tck",
}


def _evaluate_sdc(
    tmp_path: Path,
    core_period: str | None = None,
    *,
    find_pins: bool = True,
    cpu_period: str | None = None,
) -> subprocess.CompletedProcess[str]:
    """Run asic/constraint.sdc in tclsh with FROST_CORE_CLOCK_PERIOD set or not."""
    harness = tmp_path / "harness.tcl"
    harness.write_text(SDC_HARNESS)
    environment = {
        name: value
        for name, value in os.environ.items()
        if name
        not in (
            orfs.CLOCK_PERIOD_VARIABLE,
            "FROST_HARNESS_NO_PINS",
            "FROST_CPU_CLOCK_PERIOD",
        )
    }
    if core_period is not None:
        environment[orfs.CLOCK_PERIOD_VARIABLE] = core_period
    if cpu_period is not None:
        environment["FROST_CPU_CLOCK_PERIOD"] = cpu_period
    if not find_pins:
        environment["FROST_HARNESS_NO_PINS"] = "1"
    return subprocess.run(
        ["tclsh", str(harness), str(ASIC_DIRECTORY / "constraint.sdc")],
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
        env=environment,
    )


def _sdc_constraints(
    tmp_path: Path, core_period: str | None = None
) -> tuple[dict[str, float], dict[str, tuple[str, float]]]:
    """Return the clock periods and the ports' (clock, delay) that the SDC sets."""
    result = _evaluate_sdc(tmp_path, core_period)
    assert result.returncode == 0, result.stderr
    periods: dict[str, float] = {}
    delays: dict[str, tuple[str, float]] = {}
    for line in result.stdout.splitlines():
        kind, *fields = line.split()
        if kind == "clock":
            periods[fields[0]] = float(fields[1])
        elif kind == "generated":
            periods[fields[0]] = periods[fields[1]] / int(fields[2])
        elif kind in ("input", "output"):
            delays[fields[0]] = (fields[1], float(fields[2]))
    return periods, delays


def test_clock_periods_match_the_rtl_and_board(tmp_path: Path) -> None:
    """The core clock is CLK_FREQ_HZ; the NIC clocks are the Ethernet reference."""
    rtl = (orfs.REPOSITORY_ROOT / "hw/rtl/platform_top.sv").read_text()
    match = re.search(r"parameter int unsigned CLK_FREQ_HZ = (\d+)", rtl)
    assert match is not None
    core_ns = 1e9 / int(match[1])
    periods, _ = _sdc_constraints(tmp_path)

    assert periods["core_clk"] == pytest.approx(core_ns, abs=5e-4)
    assert periods["core_clk"] == orfs.default_clock_period()
    assert periods["core_clk_div4"] == pytest.approx(4 * periods["core_clk"])
    for nic_clock in ("nic_tx_clk", "nic_rx_clk"):
        assert periods[nic_clock] == pytest.approx(1e3 / 161.1328125, abs=5e-4)


@pytest.mark.parametrize("core_period", [None, "1.6", "2.25", "1.6001"])
def test_core_clock_period_sets_the_core_clocks_and_their_ports(
    tmp_path: Path, core_period: str | None
) -> None:
    """The quarter-rate clock and every port's delay follow the core period.

    Ports take a fifth of their clock's period, counted from the clock's I/O
    copy; the NIC and JTAG clocks stay.
    """
    periods, delays = _sdc_constraints(tmp_path, core_period)
    core = orfs.default_clock_period() if core_period is None else float(core_period)

    assert periods["core_clk"] == pytest.approx(core)
    assert periods["core_clk_div4"] == pytest.approx(4 * core)
    assert periods["nic_tx_clk"] == periods["nic_rx_clk"] == pytest.approx(6.206)
    assert periods["jtag_tck"] == pytest.approx(100.0)
    assert {port: clock for port, (clock, _) in delays.items()} == {
        port: f"{clock}_io" for port, clock in PORT_CLOCKS.items()
    }
    for port, (clock, delay) in delays.items():
        assert delay == pytest.approx(periods[clock] / 5), port


def test_each_clock_has_an_io_copy_at_one_pin(tmp_path: Path) -> None:
    """Every clock's ports count from a copy generated inside the chip.

    The copy divides by one, so it keeps its master's period, and a reference
    pattern that matches no pin stops the constraints.
    """
    result = _evaluate_sdc(tmp_path)
    assert result.returncode == 0, result.stderr
    generated = {
        fields[0]: (fields[1], fields[2], fields[3:])
        for kind, *fields in (line.split() for line in result.stdout.splitlines())
        if kind == "generated"
    }
    masters = ("core_clk", "core_clk_div4", "nic_tx_clk", "nic_rx_clk", "jtag_tck")
    assert {name: master for name, (master, _, _) in generated.items()} == {
        f"{master}_io": master for master in masters
    }
    for name, (_, divisor, pins) in generated.items():
        assert divisor == "1", name
        assert len(pins) == 1 and pins[0].endswith(("/CK", "/clk0")), name

    soc_source = (orfs.REPOSITORY_ROOT / "hw/rtl/soc_top/soc_top.sv").read_text()
    assert re.search(r"\bnic_mac_10g\s*#\s*\([^;]*\)\s*nic_mac\b", soc_source, re.S), (
        "the 10G MAC instance name in soc_top must stay stable"
    )
    mac_source = (
        orfs.REPOSITORY_ROOT / "hw/rtl/peripherals/nic/nic_mac_10g.sv"
    ).read_text()
    assert re.search(r"\beth10g_mac_pcs\s*#\s*\([^;]*\)\s*u_mac\b", mac_source, re.S), (
        "the 10G PCS instance name in nic_mac_10g must stay stable"
    )
    for direction in ("tx", "rx"):
        expected = f".nic_mac.u_mac.{direction}_gearbox.reservoir[0]"
        assert expected in generated[f"nic_{direction}_clk_io"][2][0]

    missing = _evaluate_sdc(tmp_path, find_pins=False)
    assert missing.returncode != 0
    assert "the I/O reference for core_clk" in missing.stderr


def test_clock_tree_synthesis_takes_each_clock_port_as_a_root(tmp_path: Path) -> None:
    """CTS_ARGS in config.mk lists the net of every clock's port.

    From the SDC's clocks, clock tree synthesis would take each I/O copy for a
    second clock on its master's net and stop, so it takes its roots from the
    list, with ORFS's other default arguments.
    """
    result = _evaluate_sdc(tmp_path)
    assert result.returncode == 0, result.stderr
    ports = {
        fields[2]
        for kind, *fields in (line.split() for line in result.stdout.splitlines())
        if kind == "clock"
    }
    config = (ASIC_DIRECTORY / "config.mk").read_text().replace("\\\n", " ")
    match = re.search(r"^export CTS_ARGS = (.*)$", config, re.MULTILINE)
    assert match is not None
    arguments = match[1].split(maxsplit=3)
    assert arguments[:3] == [
        "-sink_clustering_enable",
        "-repair_clock_nets",
        "-clk_nets",
    ]
    assert arguments[3].startswith("{") and arguments[3].endswith("}")
    assert sorted(arguments[3][1:-1].split()) == sorted(ports)


def test_only_the_asynchronous_levels_are_false_paths(tmp_path: Path) -> None:
    """Every other input keeps its setup and hold checks."""
    result = _evaluate_sdc(tmp_path)
    assert result.returncode == 0, result.stderr
    false_paths: dict[str, set[str]] = {"hold": set(), "all": set()}
    for line in result.stdout.splitlines():
        kind, *fields = line.split()
        if kind == "false_path":
            false_paths[fields[0]].update(fields[1:])

    assert false_paths == {
        "hold": set(),
        "all": {
            "i_jtag_trst_n",
            "i_power_on_rst",
            "i_nic_tx_clk_ok",
            "i_nic_rx_clk_ok",
            "i_nic_phy_status*",
        },
    }


def test_core_clock_period_must_be_a_positive_number(tmp_path: Path) -> None:
    """A malformed period stops the flow instead of creating a broken clock."""
    for period in ("fast", "0", "0.0000", "-1.6", "1e-3", "08", "1.60004", "100"):
        result = _evaluate_sdc(tmp_path, period)
        assert result.returncode != 0
        assert "FROST_CORE_CLOCK_PERIOD must be a positive number" in result.stderr
    # An empty variable means the default.
    assert _sdc_constraints(tmp_path, "")[0]["core_clk"] == orfs.default_clock_period()


def test_abc_reads_the_default_core_period() -> None:
    """ORFS takes ABC's delay target from the SDC's first period, as sed reads it.

    Its rule is the first line that starts with "set clk_period" or holds
    "-period" and a word; comments count too.
    """
    for line in (ASIC_DIRECTORY / "constraint.sdc").read_text().splitlines():
        match = re.match(r"set\s+clk_period\s+(\S+)", line) or re.search(
            r"-period\s+(\S+)", line
        )
        if match:
            assert float(match[1]) == orfs.default_clock_period()
            break
    else:
        pytest.fail("ORFS finds no clock period in asic/constraint.sdc")


def test_quarter_rate_clock_is_related_to_the_core_clock(tmp_path: Path) -> None:
    """Crossings between the core clocks are timed; the other clocks are apart.

    The debug slice writer's dc_fifo needs the core clock and its quarter-rate
    programming clock timed together, as the X3 constraints do.
    """
    result = _evaluate_sdc(tmp_path)
    assert result.returncode == 0, result.stderr
    groups = [
        set(line.split()[1:])
        for line in result.stdout.splitlines()
        if line.startswith("group ")
    ]

    assert sorted(map(sorted, groups)) == [
        ["core_clk", "core_clk_div4", "core_clk_div4_io", "core_clk_io"],
        ["jtag_tck", "jtag_tck_io"],
        ["nic_rx_clk", "nic_rx_clk_io"],
        ["nic_tx_clk", "nic_tx_clk_io"],
    ]
    assert set().union(*groups) == set(_sdc_constraints(tmp_path)[0])


@pytest.mark.parametrize("cpu_period", ["1.3", "3.103", "7"])
def test_cpu_boundary_constraints_bound_both_directions(
    tmp_path: Path, cpu_period: str
) -> None:
    """CPU, SoC and debug clocks share a group with bounded crossing delays."""
    result = _evaluate_sdc(tmp_path, cpu_period=cpu_period)
    assert result.returncode == 0, result.stderr
    groups = [
        set(line.split()[1:])
        for line in result.stdout.splitlines()
        if line.startswith("group ")
    ]
    assert any(
        {"cpu_clk", "core_clk", "core_clk_io", "jtag_tck", "jtag_tck_io"} <= group
        for group in groups
    )
    limits = [
        line.split()
        for line in result.stdout.splitlines()
        if line.startswith("max_delay ")
    ]
    assert len(limits) == 4
    for row in limits[:2]:
        assert float(row[1]) < min(float(cpu_period), orfs.default_clock_period())
        assert "-ignore_clock_latency" in row
    for row in limits[2:]:
        assert float(row[1]) < min(float(cpu_period), 100.0)
        assert "-ignore_clock_latency" in row
    assert limits[0][3:] == ["-from", "cpu_clk", "-to", "core_clk", "core_clk_io"]
    assert limits[1][3:] == ["-from", "core_clk", "core_clk_io", "-to", "cpu_clk"]
    assert limits[2][3:] == ["-from", "jtag_tck", "jtag_tck_io", "-to", "cpu_clk"]
    assert limits[3][3:] == ["-from", "cpu_clk", "-to", "jtag_tck", "jtag_tck_io"]


def test_mocked_memories_come_from_the_synthesis_log(tmp_path: Path) -> None:
    """The summary lists shrunk memories, largest first, with their dimensions."""
    log = tmp_path / "1_2_yosys.log"
    log.write_text(
        "Memory top/small has dimensions 32 x 64 = 2048\n"
        "Memory top/tags has dimensions 4096 x 17 = 69632\n"
        "Shrunk memory top/tags from 4096 rows to 1\n"
        "Memory top/data has dimensions 65536 x 256 = 16777216\n"
        "Shrunk memory top/data from 65536 rows to 1\n"
    )

    assert orfs.mocked_memories(log) == [
        ("top/data", 65536, 256),
        ("top/tags", 4096, 17),
    ]
    assert orfs.mocked_memories(tmp_path / "missing.log") == []


def test_sram_macros_come_from_the_synthesis_statistics(tmp_path: Path) -> None:
    """The summary counts each macro over the whole design."""
    statistics = tmp_path / "synth_stat.txt"
    statistics.write_text(
        "=== platform_top ===\n"
        "        2   1.27E+06        2   1.27E+06   sram_1w1r_4096x64_m8\n"
        "=== design hierarchy ===\n"
        "       10   6.35E+06        8   5.08E+06   sram_1w1r_4096x64_m8\n"
        "        4 2.64E+05        4 2.64E+05   sram_1w1r_1024x18\n"
        "   271588 5.06E+05   187232 3.49E+05   MUX2_X1\n"
    )

    assert orfs.sram_macros(statistics) == [
        ("sram_1w1r_4096x64_m8", 10),
        ("sram_1w1r_1024x18", 4),
    ]
    assert orfs.sram_macros(tmp_path / "missing.txt") == []


def test_macro_size_reads_the_lef() -> None:
    """The summary takes each macro's size from its committed LEF."""
    assert orfs.macro_size("sram_1w1r_4096x64_m8") == (751.9, 845.13)
    assert orfs.macro_size("sram_missing") is None


@pytest.mark.synthesis
def test_mac_buffers_map_to_sram_and_only_descriptors_need_mocking(
    tmp_path: Path,
) -> None:
    """The full-size MAC uses nine SRAMs; its large array is the descriptor queue."""
    root = orfs.REPOSITORY_ROOT
    net10g = root / "hw/rtl/net10g"
    sources = sorted(net10g.glob("*_pkg.sv")) + sorted(
        path for path in net10g.glob("*.sv") if not path.name.endswith("_pkg.sv")
    )
    converted = tmp_path / "net10g.v"
    subprocess.run(
        [
            "sv2v",
            "-DSYNTHESIS",
            "--exclude=Always",
            f"--write={converted}",
            *map(str, sources),
            "+RTS",
            "-N2",
            "-M2G",
            "-RTS",
        ],
        check=True,
        capture_output=True,
        text=True,
        timeout=300,
    )
    converted.write_text(re.sub(r"\balways_comb\b", "always @*", converted.read_text()))
    commands = [
        f"read_liberty -lib {path}"
        for path in sorted((ASIC_DIRECTORY / "sram/macros").glob("*/*.lib"))
    ]
    for source in (
        converted,
        root / "hw/rtl/lib/cdc/cdc_sync.sv",
        root / "hw/rtl/lib/ram/sdp_block_ram_dc_init.sv",
        ASIC_DIRECTORY / "sram/frost_sram_1w1r.sv",
    ):
        commands.append(f"read_verilog -sv -DSYNTHESIS -DFROST_SRAM_MACROS {source}")
    netlist = tmp_path / "net10g.json"
    commands += [
        "hierarchy -check -top eth10g_mac_pcs",
        "synth -top eth10g_mac_pcs -flatten -nofsm -run coarse",
        "check -assert",
        f"write_json {netlist}",
    ]
    subprocess.run(
        ["yosys", "-Q", "-T", "-p", "; ".join(commands)],
        check=True,
        capture_output=True,
        text=True,
        timeout=300,
    )
    cells = json.loads(netlist.read_text())["modules"]["eth10g_mac_pcs"]["cells"]
    macros = Counter(
        cell["type"] for cell in cells.values() if cell["type"].startswith("sram_")
    )
    assert macros == {"sram_1w1r_4096x64_m8": 1, "sram_1w1r_4096x8": 8}
    large_arrays = []
    for name, cell in cells.items():
        if cell["type"] not in ("$mem", "$mem_v2"):
            continue
        rows = int(cell["parameters"]["SIZE"], 2)
        width = int(cell["parameters"]["WIDTH"], 2)
        if rows * width > 4096:
            large_arrays.append((name, rows, width))
    assert large_arrays == [("mac_rx.packet_length", 512, 14)]


def test_summary_reports_a_partial_build(tmp_path: Path) -> None:
    """A run that stopped after synthesis still summarizes what it has."""
    logs = tmp_path / orfs.FLOW_SUBDIRECTORY.format(kind="logs")
    logs.mkdir(parents=True)
    (logs / "1_synth.json").write_text(
        json.dumps(
            {
                "synth__design__instance__count__stdcell": 1234567,
                "synth__design__instance__area__stdcell": 2345678.9,
            }
        )
    )

    summary = orfs.summary_markdown(tmp_path, "Total 42 1024")

    assert "| Standard cells | 1,234,567 | - |" in summary
    assert "| Standard-cell area (um^2) | 2,345,679 | - |" in summary
    assert "The final report has not run." in summary
    assert "Total 42 1024" in summary
    assert "Core clock period" not in summary

    _write_synthesized_build(tmp_path, "1.6000")
    assert "Core clock period: 1.6 ns." in orfs.summary_markdown(tmp_path, "")

    # A resumed build has only the stage databases it was given.
    results = tmp_path / orfs.FLOW_SUBDIRECTORY.format(kind="results")
    (results / "1_synth.sdc").rename(results / "5_1_grt.sdc")
    (results / "1_2_yosys.sdc").write_text(
        "create_clock -name core_clk -period $clk_period [get_ports i_clk]\n"
    )
    assert orfs.built_clock_period(tmp_path) == pytest.approx(1.6)


def test_blocks_follow_both_hierarchy_separators() -> None:
    """Blocks are the first four scopes, whether Yosys or OpenROAD named them."""
    assert (
        orfs.block(
            "cpu.hart.cpu_inst.u_tomasulo.u_rob/u_bank.g_banks[0].ram[0][7]$_DFFE_PP_"
        )
        == "cpu.hart.cpu_inst.u_tomasulo"
    )
    assert orfs.block("cpu.hart.cpu_inst.if_stage_inst.ras_q[63]$_DFF_P_") == (
        "cpu.hart.cpu_inst.if_stage_inst"
    )
    assert orfs.block("data_memory.memory[0][23]$_DFFE_PP_") == "data_memory"
    assert orfs.block("data_memory_address_registered[25]$_DFF_P_") == "top"
    assert orfs.block("o_nic_tx_raw_data[42]", {"o_nic_tx_raw_data[42]"}) == "ports"
    assert orfs.port_names(
        "set_input_delay 0.32 -clock [get_clocks {core_clk}] -add_delay "
        "[get_ports {i_ddr_axi_bid[0]}]\nset_false_path -from [list "
        "[get_ports {i_jtag_trst_n}]]\n"
    ) == {"i_ddr_axi_bid[0]", "i_jtag_trst_n"}


def test_mocked_rows_are_single_row_memories_from_the_log() -> None:
    """Row 0 of a mocked memory counts; a same-named array with more rows does not."""
    points = {
        "data_memory.memory[0][23]$_DFFE_PP_",
        "cpu_inst.u_rob/u_alloc.g_banks[1].u_bank.ram[0][5]$_DFFE_PP_",
        "cpu_inst.u_fetch.u_side.u_ram.ram[0]$_DFFE_PP_",
        "cpu_inst.u_fifo.memory[0][3]$_DFFE_PP_",
        "cpu_inst.u_fifo.memory[1][3]$_DFFE_PP_",
        "cpu_inst.u_rob/u_alloc.g_banks[1].u_bank.ram_q[2]$_DFF_P_",
        "i_rst",
    }
    memories = [
        "cpu_and_mem/data_memory.memory",
        "$paramod\\reorder_buffer/u_alloc.g_banks[1].u_bank.ram",
        "$paramod$0123\\imem_sideband_scalar_bank/u_ram.ram",
    ]

    assert orfs.mocked_rows(points, memories) == {
        "data_memory.memory[0][23]$_DFFE_PP_",
        "cpu_inst.u_rob/u_alloc.g_banks[1].u_bank.ram[0][5]$_DFFE_PP_",
        "cpu_inst.u_fetch.u_side.u_ram.ram[0]$_DFFE_PP_",
    }


def _path(slack: float, start: str, end: str, **fields: object) -> orfs.TimingPath:
    """Return a core clock path with the given slack and points."""
    values: dict[str, object] = {
        "capture": "core_clk",
        "launch": "core_clk",
        "slack": slack,
        "launched": 0.4,
        "arrival": 2.0,
        "required": 2.0 + slack,
        "skew": 0.0,
        "cells": 20,
        "buffers": 4,
        "startpoint": start,
        "endpoint": end,
        "launch_edge": 0.0,
        "capture_edge": 1.6,
    }
    values.update(fields)
    return orfs.TimingPath(**values)  # type: ignore[arg-type]


def test_path_report_ranks_blocks_and_families(tmp_path: Path) -> None:
    """The report gives each clock's slack, the core fmax, and the worst families."""
    table = tmp_path / "5_1_grt_paths.tsv"
    table.write_text(
        "capture\tlaunch\tslack\tlaunched\tarrival\trequired\tskew\tcells\t"
        "buffers\tstartpoint\tendpoint\tlaunch_edge\tcapture_edge\n"
        "core_clk\tcore_clk\t-0.8\t0.5\t2.9\t2.1\t0.01\t31\t9\t"
        "cpu_inst.u_rob.head_q$_DFF_P_\tcpu_inst.u_int_rs.src_q[3]$_DFF_P_\t0\t1.6\n"
        "core_clk\tcore_clk\t-3.2e-05\t0.5\t2.1\t2.1\t0.01\t12\t2\t"
        "cpu_inst.u_lq.c_q$_DFF_P_\tcpu_inst.u_lq.d_q$_DFF_P_\t0\t1.6\n"
    )
    paths = orfs.read_paths(table) + [
        _path(
            -0.75, "cpu_inst.u_rob.tail_q$_DFF_P_", "cpu_inst.u_int_rs.src_q[4]$_DFF_P_"
        ),
        # An input with its I/O delay is worse than any register path.
        _path(
            -1.2,
            "i_instr_mem_en",
            "data_memory.memory[0][1]$_DFFE_PP_",
            launch="core_clk_div4",
        ),
        _path(0.2, "cpu_inst.u_lq.a_q$_DFF_P_", "cpu_inst.u_lq.b_q$_DFF_P_"),
        _path(
            -0.9,
            "gen.l2.q$_DFF_P_",
            "gen.l1.q$_DFF_P_",
            capture="core_clk_div4",
            launch="core_clk_div4",
            capture_edge=6.4,
        ),
        _path(
            1.0,
            "u_dtm.a$_DFF_P_",
            "u_dtm.b$_DFF_P_",
            capture="jtag_tck",
            launch="jtag_tck",
        ),
    ]
    register_paths = [
        paths[0],
        _path(
            -0.4,
            "imem.row[0][3]$_DFFE_PP_",
            "imem.side_q[3]$_DFF_P_",
            launch="core_clk_div4",
        ),
        paths[5],
    ]
    periods = {"core_clk": 1.6, "core_clk_div4": 6.4, "jtag_tck": 100.0}

    report = orfs.paths_markdown(
        "grt",
        paths,
        register_paths,
        periods,
        {"data_memory.memory[0][1]$_DFFE_PP_", "imem.row[0][3]$_DFFE_PP_"},
        {"i_instr_mem_en"},
    )

    # The worst register path needs 1.6 + 0.8 ns. The -0.9 ns path between
    # quarter-rate registers has four core periods, 6.4 + 0.9 ns.
    assert orfs.path_fmax(register_paths[0], 1.6) == pytest.approx(1e3 / 2.4)
    assert orfs.path_fmax(register_paths[2], 1.6) == pytest.approx(4e3 / 7.3)
    # Skew can leave a path no delay to fit, and so no limit.
    assert orfs.path_fmax(_path(1.7, "a$_DFF_P_", "b$_DFF_P_"), 1.6) == math.inf
    assert "Core clock fmax estimate: 416.7 MHz, from the paths between" in report
    assert "| core_clk | 1.6 | 5 | 4 | -1.200 | -2.8 |" in report
    assert "| core_clk_div4 | 6.4 | 1 | 1 | -0.900 | -0.9 |" in report
    assert (
        "| core_clk_div4 | core_clk | 1 | -0.400 | 500.0 | `imem.row[0][3]$_DFFE_PP_` "
        "| `imem.side_q[3]$_DFF_P_` | reads a mocked memory |" in report
    )
    assert "| `cpu_inst.u_int_rs` | 2 | 2 | 0 | -0.800 |" in report
    assert (
        "| `cpu_inst.u_rob` | `cpu_inst.u_int_rs` | 2 | -0.800 | 31 (9) |  |" in report
    )
    assert (
        "| `ports` | `data_memory` | 1 | -1.200 | 20 (4) | from core_clk_div4; "
        "writes a mocked memory; from an input |" in report
    )
    # Blocks and families come worst first.
    assert report.index("| `data_memory` | 1 |") < report.index(
        "`cpu_inst.u_int_rs` | 2"
    )


def test_path_report_accounts_for_half_cycle_sram_reads(tmp_path: Path) -> None:
    """Falling-edge SRAM reads can limit fmax despite a full-cycle path's worse slack."""
    table = tmp_path / "6_final_register_paths.tsv"
    table.write_text(
        "capture\tlaunch\tslack\tlaunched\tarrival\trequired\tskew\tcells\t"
        "buffers\tstartpoint\tendpoint\tlaunch_edge\tcapture_edge\n"
        "core_clk\tcore_clk\t-0.4111648799\t4.222745709\t5.428816952\t"
        "5.017652072\t0.1988385012\t19\t7\tdata_memory.u_macro\t"
        "cpu_inst.u_lq.data$_DFF_P_\t1.5515\t3.103\n"
    )
    macro = orfs.read_paths(table)[0]
    register = _path(-0.6, "a$_DFF_P_", "b$_DFF_P_", capture_edge=3.103)
    assert orfs.core_cycles(macro, 3.103) == pytest.approx(0.5)
    assert orfs.path_fmax(macro, 3.103) == pytest.approx(
        1e3 / (3.103 + 2 * 0.4111648799)
    )
    report = orfs.paths_markdown(
        "final", [macro, register], [register, macro], {"core_clk": 3.103}, set(), set()
    )
    assert "Core clock fmax estimate: 254.8 MHz" in report
    assert "| core_clk | core_clk | 0.5 | -0.411 | 254.8 |" in report


@pytest.mark.parametrize(
    ("report", "edges"),
    [
        (
            "  1.5515000000  1.5515000000  clock core_clk (fall edge)\n"
            "  2.0000000000  3.5515000000  clock network delay (propagated)\n"
            "  3.1030000000  3.1030000000  clock core_clk (rise edge)\n",
            (1.5515, 3.103),
        ),
        (
            "  0.0000000000  0.0000000000  0.0000000000  clock core_clk (rise edge)\n"
            "  0.0000000000  1.6000000000  1.6000000000  clock core_clk (rise edge)\n",
            (0.0, 1.6),
        ),
        (
            "  9.3090000000  9.3090000000  clock core_clk (rise edge)\n"
            "  12.4120000000  12.4120000000  clock core_clk_div4 (rise edge)\n",
            (9.309, 12.412),
        ),
    ],
)
def test_clock_edge_export_reads_times_without_clock_latency(
    tmp_path: Path, report: str, edges: tuple[float, float]
) -> None:
    """The Tcl export reads edge times from ideal and propagated clock reports."""
    source = (ASIC_DIRECTORY / "critical_paths.tcl").read_text()
    procedure = source[
        source.index("proc frost_clock_edges") : source.index("proc frost_row")
    ]
    script = tmp_path / "edges.tcl"
    script.write_text(
        "namespace eval sta {\n"
        "  proc parse_report_path_options {cmd options format strict} {}\n"
        "  proc report_path_end {path_end} { return $path_end }\n"
        "}\n"
        "proc tee {quiet option name body} {\n"
        "  upvar 1 $name output\n"
        "  set output [uplevel 1 $body]\n"
        "}\n"
        + procedure
        + f"set report {{{report}}}\nputs [frost_clock_edges $report]\n"
    )
    result = subprocess.run(
        ["tclsh", str(script)], capture_output=True, text=True, check=True
    )
    assert tuple(map(float, result.stdout.split())) == pytest.approx(edges)


@pytest.mark.parametrize(
    ("launch_edge", "capture_edge", "cycles"),
    [(0.0, 12.412, 4), (6.206, 12.412, 2), (9.309, 12.412, 1)],
)
def test_path_fmax_accounts_for_quarter_rate_clock_edges(
    launch_edge: float, capture_edge: float, cycles: float
) -> None:
    """Clock edges retain the quarter-rate budget and the offset between clocks."""
    path = _path(
        -0.8,
        "a$_DFF_P_",
        "b$_DFF_P_",
        launch_edge=launch_edge,
        capture_edge=capture_edge,
    )
    assert orfs.core_cycles(path, 3.103) == pytest.approx(cycles)
    assert orfs.path_fmax(path, 3.103) == pytest.approx(1e3 / (3.103 + 0.8 / cycles))


def test_path_fmax_requires_clock_edges() -> None:
    """A missing or invalid edge span must not silently assume a full cycle."""
    with pytest.raises(ValueError, match="no clock edges"):
        orfs.path_fmax(_path(-0.4, "a", "b", launch_edge=None), 1.6)
    with pytest.raises(ValueError, match="positive clock edge span"):
        orfs.path_fmax(_path(-0.4, "a", "b", capture_edge=0.0), 1.6)


def test_io_clock_copies_count_as_their_masters() -> None:
    """Paths on a clock's I/O copy (asic/constraint.sdc) count as on the clock."""
    sdc = (
        "create_clock -name core_clk -period 3.1030 [get_ports {i_clk}]\n"
        "create_clock -name core_clk_div4 -period 12.4120 [get_ports {i_clk_div4}]\n"
        "create_generated_clock -name core_clk_io -source [get_ports {i_clk}] "
        "-divide_by 1 [get_pins {ddr.ar_valid_q$_DFF_P_/CK}]\n"
        "create_generated_clock -name core_clk_div4_io -source "
        "[get_ports {i_clk_div4}] -divide_by 1 "
        "[get_pins {data_memory.u_sram.gen_row[0].u_macro/clk0}]\n"
    )
    assert orfs.clock_periods(sdc) == pytest.approx(
        {
            "core_clk": 3.103,
            "core_clk_div4": 12.412,
            "core_clk_io": 3.103,
            "core_clk_div4_io": 12.412,
        }
    )
    # An input on the core clock's copy needs no note about its clock.
    path = _path(0.3, "i_ddr_axi_rvalid", "ddr.r_q$_DFF_P_", launch="core_clk_io")
    assert orfs._path_note(path, set(), {"i_ddr_axi_rvalid"}) == "from an input"
    # A path to the macro on the quarter-rate copy has four core periods.
    macro = "data_memory.u_sram.gen_row[0].u_macro"
    into_macro = _path(
        1.0,
        "imem.q$_DFF_P_",
        macro,
        launch="core_clk_div4",
        capture="core_clk_div4_io",
        capture_edge=12.412,
    )
    assert orfs.core_cycles(into_macro, 3.103) == pytest.approx(4)
    # Outputs on the copy join the core clock's endpoint tables.
    output = _path(-0.2, "ddr.w_q$_DFF_P_", "o_ddr_axi_wvalid", capture="core_clk_io")
    register = _path(0.1, "a$_DFF_P_", "b$_DFF_P_", capture_edge=3.103)
    report = orfs.paths_markdown(
        "grt",
        [output, register],
        [register],
        {"core_clk": 3.103, "core_clk_io": 3.103},
        set(),
        {"o_ddr_axi_wvalid"},
    )
    assert "| core_clk_io | 3.103 | 1 | 1 | -0.200 | -0.2 |" in report
    assert "| `ports` | 1 | 1 | 1 | -0.200 |" in report


def test_path_notes_name_the_sram_macros() -> None:
    """A path from or to an SRAM macro (asic/sram's u_macro) says so."""
    macro = "l2.data_array.u_sram.gen_macros.gen_row[3].gen_column[5].gen_macro.u_macro"
    note = orfs._path_note(_path(0.1, macro, "l2.rd_pipe[0][7]$_DFF_P_"), set(), set())
    assert note == "from an SRAM macro"
    note = orfs._path_note(
        _path(0.1, "l2.raddr$_DFF_P_", macro.replace(".", "/")), set(), set()
    )
    assert note == "to an SRAM macro"
    assert (
        orfs._path_note(_path(0.1, "u_macro_q$_DFF_P_", "a$_DFF_P_"), set(), set())
        == ""
    )
