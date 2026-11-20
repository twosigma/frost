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

"""Unit tests for the demonstration: the ray tracer's references and frost-show.

The ray tracer's reference CRCs must equal what host_reference.c computes, and
frost-show must present stubbed simulator runs (UART bytes and --stats lines)
correctly, in plain text, and fail with one sentence when a self-check fails.
"""

import fcntl
import os
import pty
import re
import select
import shutil
import struct
import subprocess
import termios
import time
from pathlib import Path
from typing import Any

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
RAYTRACE_DIR = REPO_ROOT / "sw" / "apps" / "raytrace"
SHOW_CPP = REPO_ROOT / "demo" / "frost_show.cpp"
DEMO_SCRIPT = REPO_ROOT / "demo" / "run_demo.sh"

B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"


def _compiler(names: tuple[str, ...]) -> str:
    for name in names:
        path = shutil.which(name)
        if path:
            return path
    pytest.skip(f"no host compiler among {names}")


def _references() -> list[tuple[int, int, int, int]]:
    text = (RAYTRACE_DIR / "raytrace.c").read_text(encoding="utf-8")
    entries = re.findall(r"\{(\d+), (\d+), (\d+), 0x([0-9a-f]{8})u\}", text)
    return [(int(w), int(h), int(s), int(c, 16)) for w, h, s, c in entries]


def test_raytrace_makefile_sizes_have_references() -> None:
    """Every size the Makefile offers has a reference CRC in raytrace.c."""
    makefile = (RAYTRACE_DIR / "Makefile").read_text(encoding="utf-8")
    sizes = {
        (int(w), int(h), int(s))
        for w, h, s in re.findall(
            r"-DRT_WIDTH=(\d+) -DRT_HEIGHT=(\d+) -DRT_SAMPLES=(\d+)", makefile
        )
    }
    assert len(sizes) == 2
    assert sizes == {(w, h, s) for w, h, s, _ in _references()}


def test_raytrace_references_match_host_build(tmp_path: Path) -> None:
    """The CRCs raytrace.c checks are the frames the host reference renders."""
    cc = _compiler(("cc", "gcc", "clang"))
    binary = tmp_path / "host_reference"
    subprocess.run(
        [cc, "-O2", "-o", str(binary), str(RAYTRACE_DIR / "host_reference.c")],
        check=True,
        capture_output=True,
        text=True,
    )
    for width, height, samples, crc in _references():
        out = subprocess.run(
            [str(binary), str(width), str(height), str(samples)],
            check=True,
            capture_output=True,
            text=True,
        ).stdout
        assert out.strip().endswith(f"0x{crc:08x}"), (width, height, samples, out)


@pytest.fixture(scope="module")
def frost_show(tmp_path_factory: pytest.TempPathFactory) -> Path:
    """Compile frost-show for the host."""
    cxx = _compiler(("c++", "g++", "clang++"))
    out = tmp_path_factory.mktemp("frost_show") / "frost-show"
    subprocess.run(
        [
            cxx,
            "-std=c++17",
            "-O1",
            "-Wall",
            "-Wextra",
            "-Werror",
            "-o",
            str(out),
            str(SHOW_CPP),
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    return out


STUB_RUNNER = """#!/usr/bin/env bash
mem=""; stats=""; regions=""
while [ $# -gt 0 ]; do
    case "$1" in
        --mem-dir) mem="$2"; shift 2 ;;
        --stats) stats="$2"; shift 2 ;;
        --regions) regions="$2"; shift 2 ;;
        *) shift ;;
    esac
done
cat "$mem/uart.txt"
# Like frost-native: region counters only when asked for them with --regions.
if [ -n "$stats" ]; then
    if [ -n "$regions" ]; then cat "$mem/stats.txt" > "$stats"; else cat "$mem/stats_plain.txt" > "$stats"; fi
fi
exit "$(cat "$mem/exit_code")"
"""


def _stats_line(
    cycle: int, final: bool = False, region: tuple[int, ...] | None = None
) -> str:
    """Return one --stats line.

    region is (cycles, instructions, branches, mispredicts, reorder-buffer
    occupancy sum, retired0, retired1, retired2) of the counted region.
    """
    prefix = "rob_depth=32 "
    if region is not None:
        names = (
            "cycles instructions branches mispredicts rob_occupancy_sum "
            "retired0 retired1 retired2"
        ).split()
        prefix = (
            " ".join(f"region_{n}={v}" for n, v in zip(names, region, strict=True))
            + " rob_depth=32 "
        )
    return (
        prefix + f"cycle={cycle} instructions={cycle * 9 // 10} branches={cycle // 10} "
        f"mispredicts={cycle // 200} "
        f"rob_occupancy_sum={cycle * 20} retired0={cycle * 4 // 10} retired1={cycle * 3 // 10} "
        f"retired2={cycle * 3 // 10} uart_bytes=0"
        + (" final=1" if final else "")
        + "\n"
    )


COREMARK_OK = (
    "2K performance run parameters for coremark.\r\n"
    "CoreMark Size    : 666\r\n"
    "Total ticks      : 660000\r\n"
    "Iterations       : 3\r\n"
    "seedcrc          : 0xe9f5\r\n"
    "[0]crclist       : 0xe714\r\n"
    "[0]crcmatrix     : 0x1fd7\r\n"
    "[0]crcstate      : 0x8e3a\r\n"
    "[0]crcfinal      : 0xe714\r\n"
    "Correct operation validated. See README.md for run and reporting rules.\r\n"
    "<<PASS>>\r\n"
)


def _digits(rgb: int) -> str:
    """Four base64 digits of a 24-bit pixel, as the ray tracer sends it."""
    return "".join(B64[(rgb >> shift) & 63] for shift in (18, 12, 6, 0))


def _picture_lines(width: int, height: int, flat: int | None = None) -> list[str]:
    """UART lines of a stub picture: header, coarse pass, every pixel row."""
    lines = [f"FROST ray tracer {width}x{height}\r\n"]
    blocks = (width + 3) // 4

    def pixel(x: int, y: int) -> int:
        if flat is not None:
            return flat
        return ((x * 3) % 256) << 16 | ((y * 5 + x) % 256) << 8 | (255 - (x * 2) % 256)

    for y in range(0, height, 4):
        row = "".join(_digits(pixel(4 * b, y)) for b in range(blocks))
        lines.append(f"C{y:02d} {row}\r\n")
    for y in range(height):
        row = "".join(_digits(pixel(x, y)) for x in range(width))
        lines.append(f"P{y:02d} {row}\r\n")
    return lines


def _stage(
    root: Path,
    raytrace_ok: bool = True,
    size: tuple[int, int] = (8, 4),
    full: bool = False,
    coremark: str = COREMARK_OK,
    coremark_exit: int = 0,
    flat: int | None = None,
    cycles_region_mismatch: bool = False,
    regions_file: bool = True,
) -> tuple[Path, Path]:
    bin_dir = root / "bin"
    apps = root / "apps"
    bin_dir.mkdir(parents=True)
    runner = bin_dir / "frost-native-t4"
    runner.write_text(STUB_RUNNER, encoding="utf-8")
    runner.chmod(0o755)

    width, height = size
    lines = _picture_lines(width, height, flat)
    if raytrace_ok:
        lines.append("Frame CRC-32 0x12345678 matches the reference.\r\n<<PASS>>\r\n")
    else:
        lines.append(
            "Frame CRC-32 0x12345678 does not match the reference 0x87654321.\r\n<<FAIL>>\r\n"
        )
    ticks = re.search(r"Total ticks\s*:\s*(\d+)", coremark)
    # Counted regions: the rendering (without start-up and sending) and CoreMark's
    # timed loop, whose cycles are the ticks the program reports.
    render_region = (300000, 240000, 20000, 400, 24 * 300000, 90000, 120000, 90000)
    timed_loop = int(ticks.group(1)) if ticks else 660000
    coremark_region = (
        timed_loop,
        timed_loop * 91 // 100,
        50000,
        1000,
        18 * timed_loop,
        timed_loop * 30 // 100,
        timed_loop * 37 // 100,
        timed_loop * 33 // 100,
    )
    if cycles_region_mismatch:
        coremark_region = (timed_loop + 7, *coremark_region[1:])
    for name, uart, code, cycles, region in (
        (
            "raytrace_bram" if full else "raytrace_small_bram",
            "".join(lines),
            0 if raytrace_ok else 1,
            400000,
            render_region,
        ),
        ("coremark_bram", coremark, coremark_exit, 770000, coremark_region),
    ):
        d = apps / name
        d.mkdir(parents=True)
        (d / "uart.txt").write_text(uart, encoding="utf-8")
        if regions_file:
            (d / "regions.txt").write_text(
                "start 0x4\nend 0x8\nrob_depth 32\n", encoding="utf-8"
            )
        (d / "stats_plain.txt").write_text(
            _stats_line(cycles // 2) + _stats_line(cycles, final=True), encoding="utf-8"
        )
        (d / "stats.txt").write_text(
            _stats_line(cycles // 2) + _stats_line(cycles, final=True, region=region),
            encoding="utf-8",
        )
        (d / "exit_code").write_text(f"{code}\n", encoding="utf-8")
    return bin_dir, apps


def _run_show(
    frost_show: Path, bin_dir: Path, apps: Path
) -> subprocess.CompletedProcess[str]:
    env = dict(os.environ)
    env["NO_COLOR"] = "1"
    return subprocess.run(
        [
            str(frost_show),
            "--quick",
            "--threads",
            "4",
            "--bin-dir",
            str(bin_dir),
            "--apps-dir",
            str(apps),
        ],
        env=env,
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
    )


def test_frost_show_presents_both_programs(frost_show: Path, tmp_path: Path) -> None:
    """Plain output: picture, CoreMark figures from the ticks, the table, no markers."""
    bin_dir, apps = _stage(tmp_path)
    proc = _run_show(frost_show, bin_dir, apps)
    assert proc.returncode == 0, proc.stdout + proc.stderr
    out = proc.stdout
    assert "\x1b" not in out
    assert "Above: 8 x 4 pixels, 360,000 instructions (about 90,000 a row)" in out
    assert "in 400,000 clock cycles, checksum verified." in out
    assert "clock cycles, checksum verified." in out
    assert "3 iterations, every CRC correct (validated by CoreMark)" in out
    assert "660,000 clock cycles, 220,000 per iteration" in out
    # The table counts the regions, not the whole runs; the caption keeps the totals.
    assert re.search(r"Instructions\s+240,000\s+600,600", out)
    assert re.search(r"Clock cycles\s+300,000\s+660,000", out)
    assert re.search(r"Instructions per cycle\s+0\.80\s+0\.91", out)
    assert re.search(r"Cycles retiring 2 instructions\s+30%\s+33%", out)
    assert re.search(r"Average reorder-buffer entries \(of 32\)\s+24\.0\s+18\.0", out)
    assert re.search(r"Branches predicted correctly\s+98\.0%\s+98\.0%", out)
    flat = " ".join(out.split())
    assert "Counted while rendering and inside CoreMark's timed loop;" in flat
    assert "start-up and character output are left out" in flat
    assert "published CoreMark score is in its README" in out
    assert "CoreMark/MHz" not in out
    assert "Both programs verified their own results." in out
    for marker in ("<<PASS>>", "Total ticks", "20000 Hz", "seedcrc"):
        assert marker not in out
    assert max(len(line) for line in out.splitlines()) <= 80
    # Two picture rows of eight characters each, from four pixel rows.
    picture = [
        line for line in out.splitlines() if re.fullmatch(r" +[ .,:;=+*%#@]{8}", line)
    ]
    assert len(picture) == 2


def test_coremark_column_cycles_are_the_reported_iteration_cycles(
    frost_show: Path, tmp_path: Path
) -> None:
    """The table's CoreMark cycles are the number the program itself reports."""
    one = COREMARK_OK.replace("Iterations       : 3", "Iterations       : 1").replace(
        "Total ticks      : 660000", "Total ticks      : 213390"
    )
    bin_dir, apps = _stage(tmp_path, coremark=one)
    proc = _run_show(frost_show, bin_dir, apps)
    assert proc.returncode == 0, proc.stdout
    out = proc.stdout
    assert "213,390 clock cycles for this first iteration, from a cold start" in out
    assert re.search(r"Clock cycles\s+300,000\s+213,390\b", out)
    # A table that disagrees with the program's own count is a failed run.
    bin_dir, apps = _stage(tmp_path / "bad", coremark=one, cycles_region_mismatch=True)
    proc = _run_show(frost_show, bin_dir, apps)
    assert proc.returncode == 1
    assert "every CRC correct" not in proc.stdout


def test_no_regions_file_means_no_table_rather_than_whole_run_counters(
    frost_show: Path, tmp_path: Path
) -> None:
    """A program staged without regions never gets whole-run counters under the caption."""
    bin_dir, apps = _stage(tmp_path, regions_file=False)
    proc = _run_show(frost_show, bin_dir, apps)
    assert proc.returncode == 1, proc.stdout
    flat = " ".join(proc.stdout.split())
    assert "did not report the cycles of its counted region" in flat
    assert "What the core did" not in proc.stdout


def test_presenter_asks_the_simulator_for_the_regions(
    frost_show: Path, tmp_path: Path
) -> None:
    """With a regions file present the presenter passes it, or the stub gives no counters."""
    bin_dir, apps = _stage(tmp_path)
    proc = _run_show(frost_show, bin_dir, apps)
    assert proc.returncode == 0, proc.stdout
    assert "What the core did" in proc.stdout


def test_frost_show_fails_with_one_sentence(frost_show: Path, tmp_path: Path) -> None:
    """A failed self-check ends the run with status 1 and one plain sentence."""
    bin_dir, apps = _stage(tmp_path, raytrace_ok=False)
    proc = _run_show(frost_show, bin_dir, apps)
    assert proc.returncode == 1
    last = proc.stdout.strip().splitlines()[-1]
    assert last == "The ray tracer's picture did not match its reference checksum."
    assert "CRC correct" not in proc.stdout


def test_run_demo_default_runs_frost_show(tmp_path: Path) -> None:
    """run_demo.sh starts frost-show by default and keeps --raw and --app unfiltered."""
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    show = bin_dir / "frost-show"
    show.write_text('#!/usr/bin/env bash\necho "show:$*"\n', encoding="utf-8")
    show.chmod(0o755)
    env = dict(os.environ)
    env["FROST_DEMO_ROOT"] = str(tmp_path)
    env.pop("FROST_THREADS", None)

    def run(*args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(DEMO_SCRIPT), *args],
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )

    proc = run("--threads", "1", "--quick", "--color", "256")
    assert proc.returncode == 0, proc.stderr
    assert proc.stdout.startswith("show:")
    assert "--threads 1" in proc.stdout
    assert "--color 256" in proc.stdout
    assert proc.stdout.rstrip().endswith("--quick")
    assert f"--apps-dir {tmp_path}/apps" in proc.stdout

    proc = run("--full")
    assert proc.returncode == 0, proc.stderr
    assert proc.stdout.rstrip().endswith("--full")
    assert run("--quick", "--full").returncode == 2
    assert run("--full", "--raw").returncode == 2
    assert run("--quick", "--app", "coremark").returncode == 2
    assert run("--mem-config", "ddr").returncode == 2
    assert run("--color", "sepia").returncode == 2
    for flag, mode in (("--truecolor", "truecolor"), ("--256", "256")):
        proc = run(flag)
        assert proc.returncode == 0, proc.stderr
        assert f"--color {mode}" in proc.stdout


def _run_pty(
    cmd: list[str],
    env: dict[str, str],
    cols: int,
    rows: int,
    timeout: float = 60.0,
    stdin_null: bool = False,
    termios_log: list[tuple[list[Any], list[Any]]] | None = None,
) -> tuple[int, bytes]:
    """Run a command with a pseudo-terminal of a given size as stdin and stdout.

    stdin_null gives the command /dev/null as stdin instead. termios_log receives the terminal's modes
    before and after the run.
    """
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
    before = termios.tcgetattr(slave)
    proc = subprocess.Popen(
        cmd,
        stdin=subprocess.DEVNULL if stdin_null else slave,
        stdout=slave,
        stderr=slave,
        env=env,
        close_fds=True,
    )
    data = b""
    deadline = time.monotonic() + timeout
    try:
        while time.monotonic() < deadline:
            if not select.select([master], [], [], 0.05)[0]:
                if proc.poll() is not None:
                    break
                continue
            try:
                chunk = os.read(master, 65536)
            except OSError:
                break
            if not chunk:
                break
            data += chunk
        proc.wait(timeout=max(1.0, deadline - time.monotonic()))
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait()
        if termios_log is not None:
            termios_log.append((before, termios.tcgetattr(slave)))
        os.close(slave)
        os.close(master)
    return proc.returncode, data


def _widest_row(data: bytes) -> int:
    r"""Return the highest column a terminal's cursor reaches replaying the output.

    Escape sequences move or style but do not print; \r and \n return to column 0.
    A result above the terminal's width means a line wrapped.
    """
    text = data.decode("utf-8", errors="replace")
    text = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", text)
    text = re.sub(r"\x1bP.*?\x1b\\", "", text, flags=re.S)
    widest = col = 0
    for ch in text:
        if ch in "\r\n":
            col = 0
        elif ch >= " ":
            col += 1
            widest = max(widest, col)
    return widest


def _show_env(**extra: str | None) -> dict[str, str]:
    env = {k: v for k, v in os.environ.items() if k not in ("NO_COLOR", "COLORTERM")}
    env["TERM"] = "xterm-256color"
    for key, value in extra.items():
        if value is None:
            env.pop(key, None)
        else:
            env[key] = value
    return env


def _show_cmd(frost_show: Path, bin_dir: Path, apps: Path, *flags: str) -> list[str]:
    return [
        str(frost_show),
        "--threads",
        "4",
        "--bin-dir",
        str(bin_dir),
        "--apps-dir",
        str(apps),
        *flags,
    ]


@pytest.mark.parametrize("cols", [80, 60, 45, 39])
def test_output_never_wraps_on_narrow_terminals(
    frost_show: Path, tmp_path: Path, cols: int
) -> None:
    """The picture is scaled down to fit and no line of output wraps."""
    bin_dir, apps = _stage(tmp_path, size=(76, 44), full=True)
    rc, data = _run_pty(
        _show_cmd(frost_show, bin_dir, apps, "--color", "256"),
        _show_env(),
        cols=cols,
        rows=50,
    )
    out = data.decode("utf-8", errors="replace")
    assert rc == 0, out
    assert "Both programs verified their own" in " ".join(out.split())
    assert _widest_row(data) <= cols, (cols, _widest_row(data))
    assert "▀" in out


def test_too_narrow_terminal_gets_one_sentence_not_a_picture(
    frost_show: Path, tmp_path: Path
) -> None:
    """Below the least width the picture can be drawn at, say so instead."""
    bin_dir, apps = _stage(tmp_path, size=(76, 44), full=True)
    rc, data = _run_pty(
        _show_cmd(frost_show, bin_dir, apps, "--color", "256"),
        _show_env(),
        cols=30,
        rows=50,
    )
    out = data.decode("utf-8", errors="replace")
    assert rc == 0, out
    assert "▀" not in out
    flat = " ".join(re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", out).split())
    assert "needs a terminal at least 39 columns wide" in flat
    assert _widest_row(data) <= 30


COREMARK_VARIANTS = {
    "exit_status": (COREMARK_OK, 1),
    "fail_marker": (COREMARK_OK.replace("<<PASS>>", "<<FAIL>>"), 0),
    "wrong_crc": (COREMARK_OK.replace("0x1fd7", "0x1fd8"), 0),
    "missing_crc": (COREMARK_OK.replace("[0]crcstate      : 0x8e3a\r\n", ""), 0),
    "not_validated": (COREMARK_OK.replace("Correct operation validated.", "Done."), 0),
    "error_text": (COREMARK_OK.replace("<<PASS>>", "ERROR! crclist\r\n<<PASS>>"), 0),
}


@pytest.mark.parametrize("variant", sorted(COREMARK_VARIANTS))
def test_coremark_success_needs_clean_exit_marker_and_crcs(
    frost_show: Path, tmp_path: Path, variant: str
) -> None:
    """Parsed counts and the validation sentence are not enough to report success."""
    text, code = COREMARK_VARIANTS[variant]
    bin_dir, apps = _stage(tmp_path, coremark=text, coremark_exit=code)
    proc = _run_show(frost_show, bin_dir, apps)
    assert proc.returncode == 1, proc.stdout
    assert "every CRC correct" not in proc.stdout
    assert "Both programs verified" not in proc.stdout
    last = proc.stdout.strip().splitlines()[-1]
    assert "CoreMark" in last and "failed" in last or "stopped" in last, last


@pytest.mark.parametrize(
    "case",
    [
        {"TERM": "unknown"},
        {"TERM": "dumb"},
        {"TERM": ""},
        {"TERM": None},
        {"TERM": "tty33"},
        {"NO_COLOR": "1"},
    ],
    ids=[
        "term_unknown",
        "term_dumb",
        "term_empty",
        "term_unset",
        "term_tty33",
        "no_color",
    ],
)
def test_line_only_and_no_color_terminals_get_no_escape_sequences(
    frost_show: Path, tmp_path: Path, case: dict[str, str | None]
) -> None:
    """No cursor movement, erase or color reaches a line-only terminal or NO_COLOR."""
    bin_dir, apps = _stage(tmp_path, size=(76, 44), full=True)
    rc, data = _run_pty(
        _show_cmd(frost_show, bin_dir, apps),
        _show_env(**case),
        cols=80,
        rows=50,
    )
    out = data.decode("utf-8", errors="replace")
    assert rc == 0, out
    assert "\x1b" not in out, repr(out[:300])
    assert "Both programs verified their own results." in out
    assert _widest_row(data) <= 80


def _color_run(
    frost_show: Path,
    tmp_path: Path,
    *flags: str,
    env: dict[str, str] | None = None,
    stdin_null: bool = False,
    flat: int | None = None,
    termios_log: list[tuple[list[Any], list[Any]]] | None = None,
) -> tuple[int, str]:
    bin_dir, apps = _stage(tmp_path, size=(76, 44), full=True, flat=flat)
    rc, data = _run_pty(
        _show_cmd(frost_show, bin_dir, apps, *flags),
        env if env is not None else _show_env(),
        cols=80,
        rows=50,
        stdin_null=stdin_null,
        termios_log=termios_log,
    )
    out = data.decode("utf-8", errors="replace")
    assert rc == 0, out
    return rc, out


def test_color_comes_from_the_colorterm_variable(
    frost_show: Path, tmp_path: Path
) -> None:
    """COLORTERM=truecolor gives 24-bit color without asking the terminal."""
    _, out = _color_run(
        frost_show, tmp_path, env=_show_env(COLORTERM="truecolor"), flat=0xC91107
    )
    assert "38;2;201;17;7m" in out
    assert "38;5;" not in out
    assert "\x1bP$q" not in out


def test_color_comes_from_a_direct_color_term(frost_show: Path, tmp_path: Path) -> None:
    """A TERM that names direct color gives 24-bit color."""
    _, out = _color_run(
        frost_show, tmp_path, env=_show_env(TERM="xterm-direct"), flat=0xC91107
    )
    assert "38;2;201;17;7m" in out
    assert "\x1bP$q" not in out


def test_explicit_flags_beat_the_environment(frost_show: Path, tmp_path: Path) -> None:
    """--256 and --truecolor decide before COLORTERM and before any query."""
    _, out = _color_run(
        frost_show, tmp_path, "--256", env=_show_env(COLORTERM="truecolor")
    )
    assert "38;5;" in out and "38;2;" not in out
    _, out = _color_run(frost_show, tmp_path / "b", "--truecolor", flat=0xC91107)
    assert "38;2;201;17;7m" in out and "\x1bP$q" not in out


def test_256_colors_are_the_nearest_palette_color(
    frost_show: Path, tmp_path: Path
) -> None:
    """A flat area is one palette color: no dither pattern."""
    _, out = _color_run(frost_show, tmp_path, "--256", flat=0x739BC3)
    colors = set(re.findall(r"38;5;(\d+)m(?:\x1b\[48;5;\d+m)?\u2580", out))
    assert len(colors) == 1, colors


HINT = "256 colors here; for full color use -e COLORTERM=truecolor or --truecolor"


def _flat(out: str) -> str:
    return " ".join(re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", out).split())


def test_fallback_to_256_colors_says_so(frost_show: Path, tmp_path: Path) -> None:
    """The 256-color fallback on a terminal prints one line on how to get full color."""
    _, out = _color_run(frost_show, tmp_path)
    assert "38;5;" in out
    assert _flat(out).count(HINT) == 1
    # One physical line at 80 columns, never wrapped.
    assert any(
        HINT in re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", ln) for ln in out.split("\r\n")
    )


def test_no_fallback_line_otherwise(frost_show: Path, tmp_path: Path) -> None:
    """No such line in full color, when a mode is forced, in plain mode or in a pipe."""
    cases = [
        ("truecolor", ("--color", "auto"), _show_env(COLORTERM="truecolor")),
        ("forced", ("--256",), _show_env()),
        ("no_color", (), _show_env(NO_COLOR="1")),
        ("unknown", (), _show_env(TERM="unknown")),
    ]
    for name, flags, env in cases:
        _, out = _color_run(frost_show, tmp_path / name, *flags, env=env)
        assert HINT not in _flat(out), name
    bin_dir, apps = _stage(tmp_path / "pipe", size=(76, 44), full=True)
    proc = subprocess.run(
        _show_cmd(frost_show, bin_dir, apps),
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
        env=_show_env(),
        timeout=60,
        check=False,
    )
    assert proc.returncode == 0 and HINT not in proc.stdout


@pytest.mark.parametrize(
    ("term", "controls"),
    [
        ("tty33", False),
        ("dumb", False),
        ("unknown", False),
        (None, False),
        ("vt52", False),
        ("xterm-256color", True),
        ("screen-256color", True),
        ("tmux-256color", True),
        ("linux", True),
        ("vt220", True),
        ("alacritty", True),
        ("xterm-kitty", True),
    ],
)
def test_cursor_controls_only_for_known_terminal_types(
    frost_show: Path, tmp_path: Path, term: str | None, controls: bool
) -> None:
    """Live redraw needs a terminal type known to support it; anything else gets lines."""
    _, out = _color_run(frost_show, tmp_path, "--256", env=_show_env(TERM=term))
    assert ("\x1b[?25l" in out) == controls
    assert ("\x1b[K" in out) == controls


@pytest.mark.parametrize("cols", [80, 60, 39, 30])
@pytest.mark.parametrize("quick", [False, True], ids=["full", "quick"])
@pytest.mark.parametrize(
    ("name", "flags", "env"),
    [
        ("truecolor", ("--truecolor",), {}),
        ("fallback256", (), {}),
        ("forced256", ("--256",), {}),
        ("plain", (), {"NO_COLOR": "1"}),
        ("tty33", (), {"TERM": "tty33"}),
    ],
)
def test_no_printed_line_is_wider_than_the_terminal(
    frost_show: Path,
    tmp_path: Path,
    cols: int,
    quick: bool,
    name: str,
    flags: tuple[str, ...],
    env: dict[str, str],
) -> None:
    """Every line the demo prints, in every mode, fits the terminal's width."""
    bin_dir, apps = _stage(
        tmp_path, size=(24, 12) if quick else (76, 44), full=not quick
    )
    rc, data = _run_pty(
        _show_cmd(frost_show, bin_dir, apps, *(("--quick",) if quick else ()), *flags),
        _show_env(**env),
        cols=cols,
        rows=60,
    )
    out = data.decode("utf-8", errors="replace")
    assert rc == 0, out
    assert _widest_row(data) <= cols - 1, (name, cols, _widest_row(data))


@pytest.mark.parametrize("cols", [80, 60, 39])
def test_failure_sentences_fit_the_terminal_too(
    frost_show: Path, tmp_path: Path, cols: int
) -> None:
    """The one sentence of a failed run wraps in the terminal's width as well."""
    bin_dir, apps = _stage(tmp_path, size=(24, 12), coremark_exit=1)
    rc, data = _run_pty(
        _show_cmd(frost_show, bin_dir, apps, "--quick", "--256"),
        _show_env(),
        cols=cols,
        rows=60,
    )
    assert rc == 1
    assert _widest_row(data) <= cols - 1


# Inputs (flags, environment) and the color mode they give, in the documented order:
# flags, NO_COLOR, COLORTERM, a TERM that names direct color, else 256 colors.
MODE_TABLE = [
    (("--truecolor",), {"COLORTERM": None}, "truecolor"),
    (("--256",), {"COLORTERM": "truecolor"}, "256"),
    (("--truecolor",), {"NO_COLOR": "1"}, "truecolor"),
    ((), {"NO_COLOR": "1", "COLORTERM": "truecolor"}, "plain"),
    ((), {"COLORTERM": "truecolor"}, "truecolor"),
    ((), {"COLORTERM": "24bit"}, "truecolor"),
    ((), {"COLORTERM": "yes"}, "256"),
    ((), {"TERM": "xterm-direct"}, "truecolor"),
    ((), {"TERM": "xterm-256color", "COLORTERM": "truecolor"}, "truecolor"),
    ((), {}, "256"),
    ((), {"TERM": "tty33", "COLORTERM": "truecolor"}, "plain"),
]


@pytest.mark.parametrize(("flags", "env", "mode"), MODE_TABLE)
def test_color_mode_selection_table(
    frost_show: Path,
    tmp_path: Path,
    flags: tuple[str, ...],
    env: dict[str, str | None],
    mode: str,
) -> None:
    """Each input combination gives its documented mode."""
    _, out = _color_run(
        frost_show, tmp_path, *flags, env=_show_env(**env), flat=0xC91107
    )
    assert ("38;2;201;17;7m" in out) == (mode == "truecolor")
    assert ("38;5;" in out and "38;2;" not in out) == (mode == "256")
    assert ("\x1b" not in out) == (mode == "plain")
    assert (HINT in _flat(out)) == (mode == "256" and not flags)


def test_the_terminal_is_never_queried_or_reconfigured(
    frost_show: Path, tmp_path: Path
) -> None:
    """No request sequence is written in any mode, and the terminal modes are untouched."""
    cases = [(), ("--truecolor",), ("--256",)]
    envs = [{}, {"COLORTERM": "truecolor"}, {"NO_COLOR": "1"}, {"TERM": "tty33"}]
    for i, flags in enumerate(cases):
        for j, env in enumerate(envs):
            log: list[tuple[list[Any], list[Any]]] = []
            _, out = _color_run(
                frost_show,
                tmp_path / f"{i}{j}",
                *flags,
                env=_show_env(**env),
                termios_log=log,
            )
            # Device attributes (ESC [ c), device status (ESC [ n), DECRQSS (ESC P $ q),
            # and a 24-bit background set only to be queried are all absent.
            assert not re.search(r"\x1b\[[0-9;?]*[cn]", out), (flags, env)
            assert "\x1bP$q" not in out and "48;2;1;2;3" not in out, (flags, env)
            assert log[0][0] == log[0][1]


def _make_regions(monkeypatch: pytest.MonkeyPatch, tool_output: dict[str, str]) -> Any:
    """Load demo/make_regions.py with nm and objdump replaced by canned output."""
    import importlib.util

    spec = importlib.util.spec_from_file_location(
        "make_regions", REPO_ROOT / "demo" / "make_regions.py"
    )
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    monkeypatch.setattr(module, "run", lambda prefix, tool, *args: tool_output[tool])
    return module


def test_make_regions_bounds_coremark_and_the_ray_tracer(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """The region files name the instructions that bound the counted work."""
    pkg = tmp_path / "riscv_pkg.sv"
    pkg.write_text(
        "localparam int unsigned ReorderBufferDepth = 32;\n", encoding="utf-8"
    )
    objdump = (
        "0000000000005be4 <start_time>:\n"
        "    5bec:\t c00022f3          \trdcycle\tt0\n"
        "    5c7c:\t c00022f3          \trdcycle\tt0\n"
        "    5c84:\t 00008067          \tret\n"
        "\n"
        "0000000000005c88 <stop_time>:\n"
        "    5c88:\t c00027f3          \trdcycle\ta5\n"
        "    5c98:\t c0002373          \trdcycle\tt1\n"
    )
    nm = (
        "00000000000015c6 0000000000000002 T rt_mark_render_start\n"
        "00000000000015c8 0000000000000002 T rt_mark_render_end\n"
        "0000000000000c9c 0000000000000142 t uart_send.constprop.0\n"
        "0000000000000272 000000000000000c T uart_tx_ready\n"
        "0000000000000300 0000000000000010 T uart_sender_other\n"
    )
    module = _make_regions(monkeypatch, {"objdump": objdump, "nm": nm})
    monkeypatch.setattr("sys.argv", ["make_regions", "coremark", "x.elf", str(pkg)])
    assert module.main() == 0
    assert capsys.readouterr().out.split() == [
        "start",
        "0x5c7c",
        "end",
        "0x5c88",
        "rob_depth",
        "32",
    ]
    monkeypatch.setattr("sys.argv", ["make_regions", "raytrace", "x.elf", str(pkg)])
    assert module.main() == 0
    lines = capsys.readouterr().out.splitlines()
    assert lines == [
        "start 0x15c6",
        "end 0x15c8",
        "skip 0xc9c 0xdde",
        "skip 0x272 0x27e",
        "rob_depth 32",
    ]


def test_ray_tracer_keeps_its_markers_as_real_functions() -> None:
    """The marker calls and uart_send stay out of line so their addresses exist."""
    text = (RAYTRACE_DIR / "raytrace.c").read_text(encoding="utf-8")
    for name in ("rt_mark_render_start", "rt_mark_render_end"):
        assert f"__attribute__((noinline)) void {name}(void)" in text
        assert f"{name}();" in text
    assert "__attribute__((noinline)) static void uart_send" in text


CI_WORKFLOW = REPO_ROOT / ".github" / "workflows" / "ci.yml"

_CI_RAW_OUTPUT = (
    "Frost: Hello, world!\nseedcrc          : 0xe9f5\n[0]crclist       : 0xe714\n"
    "[0]crcmatrix     : 0x1fd7\n[0]crcstate      : 0x8e3a\n[0]crcfinal      : 0xe714\n"
    "Correct operation validated.\n<<PASS>>\nRTL assertions   : enabled after reset\n"
    "Demonstration finished: hello_world and CoreMark completed on the FROST RTL.\n"
)
_CI_SINGLE_OUTPUT = (
    "Simulator threads: 1\nFrost: Hello, world!\nto stop marker + 10,000 drain\n"
    "RTL assertions   : enabled after reset\n"
)


def _ci_demo_step_script() -> str:
    """Return the shell text of the quick-demonstration step of test-demo-image."""
    import yaml  # type: ignore[import-untyped]

    workflow = yaml.safe_load(CI_WORKFLOW.read_text(encoding="utf-8"))
    for step in workflow["jobs"]["test-demo-image"]["steps"]:
        if step.get("name", "").startswith("Run the quick demonstration"):
            return str(step["run"])
    raise AssertionError("quick demonstration step not found")


def _run_ci_demo_step(work: Path, quick_output: str) -> tuple[int, list[str]]:
    """Run the step's own shell text with a docker that prints canned output."""
    work.mkdir(parents=True)
    fake = work / "bin"
    fake.mkdir()
    docker = fake / "docker"
    docker.write_text(
        "#!/usr/bin/env bash\n"
        'echo "$*" >> "$FAKE_DOCKER_LOG"\n'
        'case "$*" in\n'
        '  *--quick*) cat "$FAKE_DIR/quick.txt" ;;\n'
        '  *--raw*) cat "$FAKE_DIR/raw.txt" ;;\n'
        '  *"--app hello_world"*) cat "$FAKE_DIR/single.txt" ;;\n'
        "esac\n",
        encoding="utf-8",
    )
    docker.chmod(0o755)
    (work / "quick.txt").write_text(quick_output, encoding="utf-8")
    (work / "raw.txt").write_text(_CI_RAW_OUTPUT, encoding="utf-8")
    (work / "single.txt").write_text(_CI_SINGLE_OUTPUT, encoding="utf-8")
    script = work / "step.sh"
    script.write_text(
        _ci_demo_step_script().replace("/tmp/", f"{work}/"), encoding="utf-8"
    )
    env = dict(os.environ)
    env["PATH"] = f"{fake}:{env['PATH']}"
    env["FAKE_DIR"] = str(work)
    env["FAKE_DOCKER_LOG"] = str(work / "docker.log")
    # GitHub runs a step's text with `bash -e`.
    proc = subprocess.run(
        ["bash", "-e", str(script)],
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )
    log = work / "docker.log"
    return proc.returncode, log.read_text(
        encoding="utf-8"
    ).splitlines() if log.exists() else []


def _stock_quick_output(frost_show: Path, tmp_path: Path) -> str:
    one = COREMARK_OK.replace("Iterations       : 3", "Iterations       : 1").replace(
        "Total ticks      : 660000", "Total ticks      : 213390"
    )
    bin_dir, apps = _stage(tmp_path / "stage", coremark=one)
    proc = _run_show(frost_show, bin_dir, apps)
    assert proc.returncode == 0, proc.stdout
    return proc.stdout


def test_ci_demo_step_passes_the_stock_quick_output(
    frost_show: Path, tmp_path: Path
) -> None:
    """The step's own shell text accepts the presenter's real output and runs all three."""
    quick = _stock_quick_output(frost_show, tmp_path)
    rc, calls = _run_ci_demo_step(tmp_path / "ok", quick)
    assert rc == 0
    assert len(calls) == 3


@pytest.mark.parametrize(
    "case", ["no_iteration_line", "count_changed", "no_loop_row", "no_label", "empty"]
)
def test_ci_demo_step_stops_on_every_bad_quick_output(
    frost_show: Path, tmp_path: Path, case: str
) -> None:
    """Each broken output ends the step at once, before the later containers run."""
    quick = _stock_quick_output(frost_show, tmp_path)
    lines = quick.splitlines(keepends=True)
    if case == "no_iteration_line":
        quick = "".join(
            ln for ln in lines if "clock cycles for this first iteration" not in ln
        )
    elif case == "count_changed":
        quick = "".join(
            ln.replace("213,390", "213,391") if "for this first iteration" in ln else ln
            for ln in lines
        )
    elif case == "no_loop_row":
        quick = "".join(
            ln for ln in lines if not ln.lstrip().startswith("Clock cycles")
        )
    elif case == "no_label":
        quick = quick.replace("Counted while rendering", "Counted")
    else:
        quick = ""
    rc, calls = _run_ci_demo_step(tmp_path / case, quick)
    assert rc != 0, case
    assert len(calls) == 1, calls


def test_ci_demo_step_has_no_swallowing_shell_patterns() -> None:
    """No `&&` or `||` list and no bare negation in the step: each check is an if."""
    import re as regex

    body = [
        ln.strip()
        for ln in _ci_demo_step_script().splitlines()
        if ln.strip() and not ln.strip().startswith("#")
    ]
    for line in body:
        assert not regex.search(r"(&&|\|\|)", line), line
        assert not line.startswith("!"), line
    assert body[0] == "set -euo pipefail"
