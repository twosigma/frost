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

"""Load a software application image to FPGA low BRAM and optional DDR via JTAG."""

import argparse
from collections.abc import Mapping
import hashlib
import json
import os
import re
import shlex
import shutil
import struct
import subprocess
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = SCRIPT_DIR.parent.parent

# Import shared target selection and the software registry.
sys.path.insert(0, str(SCRIPT_DIR.parent / "common"))
sys.path.insert(0, str(PROJECT_ROOT / "sw" / "apps"))
from hw_target import add_target_args, select_target, validate_target_args  # noqa: E402
from software_registry import (  # noqa: E402
    COREMARK_PRO_APP_NAMES,
    app_build_directory_name,
    coremark_pro_hardware_error,
    coremark_pro_make_vars,
    is_coremark_pro_program,
)

# Applications accepted by the JTAG loader.
VALID_APPS = [
    "amo_irq_torture",
    "branch_pred_test",
    "c_ext_test",
    "call_stress",
    "cf_ext_test",
    "coremark",
    *COREMARK_PRO_APP_NAMES,
    "csr_test",
    "debug_target",
    "ddr_exec_test",
    "ddr_atomic_test",
    "ddr_heap_test",
    "ddr_smc_test",
    "ddr_test",
    "freertos_demo",
    "fpu_assembly_test",
    "fpu_test",
    "hello_world",
    "isa_test",
    "itlb_test",
    "linux_irq_active_ddr_test",
    "linux_boot",
    "linux_irq_ddr_test",
    "linux_irq_stack_slot_test",
    "memory_test",
    "opensbi_smoke",
    "packet_parser",
    "pde_return_hazard",
    "print_clock_speed",
    "ras_stress_test",
    "ras_test",
    "smode_test",
    "spanning_test",
    "sprintf_test",
    "strings_test",
    "tick_torture",
    "tomasulo_perf",
    "tomasulo_test",
    "uart_echo",
    "umode_test",
    "vm_test",
]

# Clock frequency in Hz; CoreMark iterations target about 10 seconds.
BOARD_CONFIG = {
    # ``has_ddr``: the bitstream provides the JTAG DDR-load master (hw_axi_2)
    # and the cached DDR region. The flag exists so a future BRAM-only board can
    # be added without loading a DDR image.
    "x3": {"clock_freq": 300000000, "coremark_iterations": 11000, "has_ddr": True},
}

# A functional-validation bitstream (build.py --cpu-clock-div) runs the CPU
# below the board's rated clock. FROST_CPU_CLK_HZ names that clock so the app
# builds (FPGA_CPU_CLK_FREQ: UART divisor, timer constants, the Linux device
# tree) match the programmed bitstream.
CPU_CLK_ENV = "FROST_CPU_CLK_HZ"
DEBUG_UNSUPPORTED = {
    "linux_boot": "Linux kernel debugging is not available in this extension.",
    "opensbi_smoke": "Debugging OpenSBI and its separate payload is not available in this extension.",
}
DEBUG_APPS = frozenset(VALID_APPS).difference(DEBUG_UNSUPPORTED)
# These application Makefiles deliberately override even a caller's BRAM
# request. The built stamp is checked against this effective layout.
FORCED_DDR_APPS = frozenset(
    {
        "amo_irq_torture",
        "linux_irq_active_ddr_test",
        "linux_irq_ddr_test",
        "linux_irq_stack_slot_test",
        "pde_return_hazard",
        "tick_torture",
    }
)


def board_clock_freq(
    board: str, environment: Mapping[str, str] = os.environ
) -> tuple[int, bool]:
    """Return the board's CPU clock in Hz and whether FROST_CPU_CLK_HZ set it."""
    rated = int(BOARD_CONFIG[board]["clock_freq"])
    raw = environment.get(CPU_CLK_ENV, "").strip()
    if not raw:
        return rated, False
    try:
        override = int(raw)
    except ValueError as exc:
        raise ValueError(
            f"{CPU_CLK_ENV} must be an integer Hz value, got {raw!r}"
        ) from exc
    if override <= 0:
        raise ValueError(f"{CPU_CLK_ENV} must be positive, got {override}")
    return override, True


# These apps use the cached DDR region, which reads as zero without a wired
# controller.
DDR_APPS = frozenset(COREMARK_PRO_APP_NAMES) | {
    "amo_irq_torture",
    "ddr_exec_test",
    "ddr_atomic_test",
    "ddr_heap_test",
    "ddr_smc_test",
    "ddr_test",
    "linux_irq_active_ddr_test",
    "linux_boot",
    "linux_irq_ddr_test",
    "linux_irq_stack_slot_test",
    "opensbi_smoke",
    "pde_return_hazard",
    "tick_torture",
}


def _linux_boot_preflight() -> None:
    """Check Linux build prerequisites and warn before a cold 30-60 min build."""
    buildroot_makefile = PROJECT_ROOT / "linux" / "buildroot" / "Makefile"
    if not buildroot_makefile.exists():
        print(
            "Error: the Buildroot submodule (linux/buildroot) is not initialized.\n"
            "  Run: git submodule update --init linux/buildroot",
            file=sys.stderr,
        )
        sys.exit(1)

    missing = [tool for tool in ("make", "dtc") if shutil.which(tool) is None]
    if missing:
        print(
            "Error: missing host tools required to build the Linux image: "
            f"{', '.join(missing)}.\n"
            "  Install Buildroot's host dependencies (see "
            "linux/buildroot-external/README.md) or run inside the\n"
            "  frost-dev Docker image, which ships them.",
            file=sys.stderr,
        )
        sys.exit(1)

    kimage = PROJECT_ROOT / "linux" / "build-mmu" / "images" / "Image"
    if not kimage.exists():
        print(
            "Note: no cached kernel image found -- linux_boot will build the "
            "kernel + rootfs from source now.\n"
            "  The FIRST build compiles a full rv64 cross toolchain and can take "
            "30-60 min; later loads reuse\n"
            "  the cached build and only re-pack the DDR image for this board "
            "(seconds).",
            file=sys.stderr,
        )


def compile_app_for_board(
    app_name: str,
    app_dir: Path,
    clock_freq: int,
    coremark_iterations: int,
    make_vars: dict[str, str] | None = None,
    mem_config: str | None = None,
    debug: bool = False,
) -> bool:
    """Compile an app with board settings and optional Make overrides."""
    # Start from the caller's toolchain environment.
    env = os.environ.copy()
    if "RISCV_PREFIX" not in env:
        env["RISCV_PREFIX"] = "riscv-none-elf-"

    # Apply board-dependent clock and CoreMark settings.
    env["FPGA_CPU_CLK_FREQ"] = str(clock_freq)
    if app_name == "coremark":
        env["ITERATIONS"] = str(coremark_iterations)
    # MEM_CONFIG relinks any app from the default BRAM into cached DDR; the
    # Makefile's ``?=`` honors this override.
    if mem_config:
        env["MEM_CONFIG"] = mem_config

    # A cold linux_boot build includes the cross toolchain and takes 30-60 min.
    # Its clean target preserves the cached kernel/rootfs and removes only
    # board-specific packed output.
    is_linux_boot = app_name == "linux_boot"
    clean_timeout = 300 if is_linux_boot else 30
    build_timeout = 5400 if is_linux_boot else 120

    try:
        # Clean first so board and diagnostic overrides take effect.
        subprocess.run(
            ["make", "clean"],
            cwd=app_dir,
            env=env,
            capture_output=True,
            text=True,
            timeout=clean_timeout,
            check=True,
        )

        # Build with any workload-specific Make overrides.
        print(f"Compiling {app_name}...")
        make_command = ["make"]
        if make_vars:
            make_command.extend(f"{key}={value}" for key, value in make_vars.items())
        if debug:
            make_command.append("FROST_DEBUG=1")

        result = subprocess.run(
            make_command,
            cwd=app_dir,
            env=env,
            capture_output=False,  # Show output
            text=True,
            timeout=build_timeout,
        )

        if result.returncode != 0:
            return False

        # The simulator reads sw.mem and load_software.tcl reads sw.txt.
        sw_mem = app_dir / "sw.mem"
        if not sw_mem.exists():
            print(f"Error: sw.mem not created for {app_name}", file=sys.stderr)
            return False
        sw_txt = app_dir / "sw.txt"
        if not sw_txt.exists():
            print(f"Error: sw.txt not created for {app_name}", file=sys.stderr)
            return False

        return True

    except subprocess.TimeoutExpired:
        print(f"Error: Compilation timed out for {app_name}", file=sys.stderr)
        return False
    except Exception as e:
        print(f"Error compiling {app_name}: {e}", file=sys.stderr)
        return False


def inspect_debug_elf(elf: bytes, require_dwarf: bool) -> tuple[int, bool, bool]:
    """Return entry, defined executable main, and initialized writable DDR.

    Bound every table, string and payload access. Extended ELF section counts
    are intentionally unsupported: these small bare-metal images do not use
    them. A malformed ELF must fail before the loader can discover hardware.
    """
    if (
        len(elf) < 64
        or elf[:7] != b"\x7fELF\x02\x01\x01"
        or struct.unpack_from("<HHI", elf, 16) != (2, 243, 1)
    ):
        raise ValueError("sw.elf must be a little-endian RV64 executable ELF")

    def payload(offset: int, size: int) -> bytes:
        if offset > len(elf) or size > len(elf) - offset:
            raise ValueError("invalid ELF payload bounds")
        return elf[offset : offset + size]

    def string(table: bytes, offset: int) -> bytes:
        if offset >= len(table):
            raise ValueError("invalid ELF string offset")
        end = table.find(b"\0", offset)
        if end < 0:
            raise ValueError("unterminated ELF string")
        return table[offset:end]

    entry, program_offset, section_offset = struct.unpack_from("<QQQ", elf, 24)
    header_size, program_size, program_count, section_size, count, names_index = (
        struct.unpack_from("<HHHHHH", elf, 52)
    )
    if header_size != 64 or section_size < 64 or not count or names_index >= count:
        raise ValueError("invalid ELF section table")
    payload(section_offset, section_size * count)
    sections = [
        struct.unpack_from("<IIQQQQIIQQ", elf, section_offset + section_size * index)
        for index in range(count)
    ]
    names_header = sections[names_index]
    if names_header[1] != 3:
        raise ValueError("invalid ELF section-name table")
    names = payload(names_header[4], names_header[5])
    nonempty_sections: set[bytes] = set()
    writable_ddr = False
    for section in sections:
        name = string(names, section[0])
        kind, flags, address, offset, size = section[1:6]
        if kind != 8:  # SHT_NOBITS has no file payload.
            payload(offset, size)
            if size:
                nonempty_sections.add(name)
            if (
                flags & 3 == 3
                and size
                and address < 0xC0000000
                and address + size > 0x80000000
            ):
                writable_ddr = True
    if require_dwarf and not {b".debug_info", b".debug_line"} <= nonempty_sections:
        raise ValueError("debug ELF lacks nonempty .debug_info or .debug_line")

    # Also consider load segments, including initialized data with an unusual
    # section name. The loader's DDR image is loaded at its runtime address;
    # restarting crt0 cannot restore bytes already changed during handoff.
    if program_count:
        if program_size < 56 or program_count == 0xFFFF:
            raise ValueError("invalid ELF program table")
        payload(program_offset, program_size * program_count)
        for index in range(program_count):
            kind, flags, offset, address, _physical, size, memory_size, _align = (
                struct.unpack_from(
                    "<IIQQQQQQ", elf, program_offset + program_size * index
                )
            )
            payload(offset, size)
            if kind == 1:
                if size > memory_size:
                    raise ValueError("invalid ELF load segment size")
                if (
                    flags & 2
                    and size
                    and address < 0xC0000000
                    and address + size > 0x80000000
                ):
                    writable_ddr = True

    has_main = False
    for section in sections:
        if section[1] not in (2, 11):  # SHT_SYMTAB / SHT_DYNSYM
            continue
        offset, size, linked, symbol_size = (
            section[4],
            section[5],
            section[6],
            section[9],
        )
        if (
            symbol_size < 24
            or size % symbol_size
            or linked >= count
            or sections[linked][1] != 3
        ):
            raise ValueError("invalid ELF symbol table")
        strings = payload(sections[linked][4], sections[linked][5])
        for cursor in range(offset, offset + size, symbol_size):
            name, info, _other, defined, value, _size = struct.unpack_from(
                "<IBBHQQ", elf, cursor
            )
            symbol_name = string(strings, name)
            if (
                symbol_name != b"main"
                or info & 15 not in (0, 2)
                or not 0 < defined < count
            ):
                continue
            target = sections[defined]
            if target[2] & 4 and target[3] <= value < target[3] + target[5]:
                has_main = True
    return entry, has_main, writable_ddr


def validate_prebuilt_app(
    app_dir: Path,
    clock_freq: int,
    mem_config: str,
    debug: bool,
    *,
    app_name: str | None = None,
    make_vars: Mapping[str, str] | None = None,
    coremark_iterations: int | None = None,
) -> dict[str, str]:
    """Validate a bare-metal build and describe its safe debugger startup.

    This checks current files/settings, not source freshness. Callers must keep
    the directory unchanged until loading finishes. The returned hash binds a
    subsequent --skip-build to this exact Make configuration, without a new
    persistent manifest. Application aliases use their registry build path.
    """
    app_name = app_name or app_dir.name
    if app_name not in DEBUG_APPS:
        raise ValueError(
            DEBUG_UNSUPPORTED.get(app_name, "Unsupported debug application")
        )
    for name in ("sw.elf", "sw.txt", "sw_ddr.txt", ".frost-build-config.bin"):
        if not (app_dir / name).is_file():
            raise ValueError(
                f"missing prebuilt file: {app_dir / name}; run --build-only first"
            )
    config_bytes = (app_dir / ".frost-build-config.bin").read_bytes()
    config: dict[str, str] = {}
    for field in config_bytes.decode().strip().split("|"):
        key, separator, value = field.partition("=")
        if not separator or key in config:
            raise ValueError("invalid or duplicate prebuilt Make configuration field")
        config[key] = value.strip()
    effective_memory = "ddr" if app_name in FORCED_DDR_APPS else mem_config
    required = {
        "MEM_CONFIG": effective_memory,
        "FROST_DEBUG": str(int(debug)),
        "FPGA_CPU_CLK_FREQ": str(clock_freq),
    }
    if effective_memory not in ("bram", "ddr"):
        raise ValueError("prebuilt memory mode must be bram or ddr")
    if is_coremark_pro_program(app_name):
        if make_vars is None:
            raise ValueError(
                "CoreMark-PRO prebuilt validation requires the selected workload/run mode"
            )
        for key in ("WORKLOAD", "COREMARK_PRO_RUN_ARGS", "COREMARK_PRO_OFFICIAL"):
            if key not in make_vars:
                raise ValueError(f"CoreMark-PRO build contract is missing {key}")
            required[key] = make_vars[key]
        for key in (
            "COREMARK_PRO_TRACE",
            "FROST_MALLOC_DISABLE_FREE",
            "FROST_MALLOC_GUARD_FREE",
            "FROST_MALLOC_EVICT_FREE",
            "FROST_MEMORY_FENCE_WRITES",
        ):
            required[key] = make_vars.get(key, os.environ.get(key, "0"))
    if any(config.get(key) != value for key, value in required.items()):
        raise ValueError(
            "prebuilt memory mode, debug profile, CPU clock, or workload options differ; run --build-only first"
        )
    if app_name == "coremark" and coremark_iterations is not None:
        if f"-DITERATIONS={coremark_iterations}" not in shlex.split(
            config.get("CFLAGS", "")
        ):
            raise ValueError(
                "prebuilt CoreMark iterations differ; run --build-only first"
            )
    entry, has_main, writable_ddr = inspect_debug_elf(
        (app_dir / "sw.elf").read_bytes(), debug
    )
    for name in ("sw.txt", "sw_ddr.txt"):
        words = (app_dir / name).read_text().splitlines()
        if (name == "sw.txt" or effective_memory == "ddr") and not words:
            raise ValueError(f"{name} is empty")
        if any(
            len(word) != 8 or any(c not in "0123456789abcdefABCDEF" for c in word)
            for word in words
        ):
            raise ValueError(f"{name} contains invalid 32-bit image words")
    strategy = "attach"
    if effective_memory == "bram" and entry == 0 and not writable_ddr:
        strategy = "main" if has_main else "reset"
    return {
        "app": app_name,
        "appDirectory": str(app_dir.resolve()),
        "elf": str((app_dir / "sw.elf").resolve()),
        "effectiveMemory": effective_memory,
        "startStrategy": strategy,
        "buildConfigSha256": hashlib.sha256(config_bytes).hexdigest(),
    }


def main() -> None:
    """Write BRAM and optional cached-DDR images over JTAG."""
    parser = argparse.ArgumentParser(
        description="Load software application images to FPGA low BRAM and optional DDR via JTAG"
    )
    parser.add_argument(
        "board",
        choices=list(BOARD_CONFIG.keys()),
        help="Target FPGA board",
    )
    parser.add_argument(
        "software_app",
        nargs="?",
        choices=VALID_APPS,
        help="Software application to load",
    )
    parser.add_argument(
        "remote_host",
        nargs="?",
        default="",
        help="Remote server hostname or IP (port 3121 will be used)",
    )
    parser.add_argument(
        "--vivado-path",
        default="vivado",
        help="Path to Vivado executable (default: vivado from PATH)",
    )
    parser.add_argument(
        "--ddr",
        action="store_true",
        help=(
            "Build the app to execute from the cached DDR region (passes "
            "MEM_CONFIG=ddr to the app Makefile), so an otherwise BRAM-resident "
            "app runs its code from DDR. Requires a board with has_ddr."
        ),
    )
    parser.add_argument(
        "--debug",
        action="store_true",
        help="Build supported bare-metal C or assembly applications with DWARF (C uses -Og and no unrolling)",
    )
    build_mode = parser.add_mutually_exclusive_group()
    build_mode.add_argument(
        "--build-only",
        action="store_true",
        help="Compile and validate images, without starting Vivado or accessing JTAG",
    )
    build_mode.add_argument(
        "--skip-build",
        action="store_true",
        help="Load validated bare-metal files without rebuilding; keep app files unchanged",
    )
    parser.add_argument(
        "--expected-build-config-sha256",
        help="With --skip-build, require the exact Make configuration hash reported by --build-only --debug",
    )
    coremark_pro_mode = parser.add_mutually_exclusive_group()
    coremark_pro_mode.add_argument(
        "-v0",
        dest="coremark_pro_mode",
        action="store_const",
        const="performance",
        help=(
            "CoreMark-PRO performance/score run: disable validation and use "
            "hardware-sized iteration presets"
        ),
    )
    coremark_pro_mode.add_argument(
        "-v1",
        dest="coremark_pro_mode",
        action="store_const",
        const="validation",
        help=(
            "CoreMark-PRO validation run: enable official result checking "
            "(iterations collapse to one validation pass)"
        ),
    )
    coremark_pro_diagnostic = parser.add_mutually_exclusive_group()
    coremark_pro_diagnostic.add_argument(
        "--coremark-pro-disable-free",
        action="store_true",
        help=(
            "Diagnostic only: build CoreMark-PRO with free() disabled to isolate "
            "heap reuse/cache coherency issues"
        ),
    )
    coremark_pro_diagnostic.add_argument(
        "--coremark-pro-guard-free",
        action="store_true",
        help=(
            "Diagnostic only: build CoreMark-PRO with invalid-free guards to "
            "skip bogus frees while preserving normal heap reuse"
        ),
    )
    parser.add_argument(
        "--coremark-pro-evict-free",
        action="store_true",
        help=(
            "Diagnostic only: evict load-queue L0 entries for freed CoreMark-PRO "
            "heap blocks before returning them to the freelist"
        ),
    )
    parser.add_argument(
        "--coremark-pro-fence-writes",
        action="store_true",
        help=(
            "Diagnostic only: insert RISC-V fences after FROST libc string and "
            "bulk-memory writes used by CoreMark-PRO"
        ),
    )
    parser.add_argument(
        "--coremark-pro-parser-gen-ref",
        action="store_true",
        help=(
            "Diagnostic only: for coremark_pro_parser, ask the workload to print "
            "the computed parser reference CRC using -D=-g1"
        ),
    )
    parser.add_argument(
        "--coremark-pro-trace",
        action="store_true",
        help=(
            "Enable the crt0 early-boot UART trace markers "
            "(COREMARK_PRO_TRACE=1): distinguishes a hang before main() "
            "from one inside the workload"
        ),
    )
    parser.add_argument(
        "--coremark-pro-parser-size",
        type=int,
        metavar="BYTES",
        help=(
            "Diagnostic only: for coremark_pro_parser, override the generated XML "
            "size and print the computed reference CRC"
        ),
    )
    add_target_args(parser, managed=True)
    args = parser.parse_args()
    validate_target_args(parser, args)
    if args.expected_build_config_sha256 is not None:
        if not args.skip_build:
            parser.error("--expected-build-config-sha256 requires --skip-build")
        if not re.fullmatch(r"[0-9a-fA-F]{64}", args.expected_build_config_sha256):
            parser.error(
                "--expected-build-config-sha256 must contain 64 hexadecimal digits"
            )
    target_options = dict(
        hw_server_url=args.hw_server_url,
        target_exact=args.target_exact,
        non_interactive=args.non_interactive,
    )
    if args.list_targets and (args.build_only or args.skip_build or args.debug):
        parser.error("--list-targets cannot be combined with build/debug options")

    # Listing targets does not require an application.
    if args.list_targets:
        select_target(
            args.vivado_path,
            args.remote_host,
            list_only=True,
            board=args.board,
            **target_options,
        )
        return

    # All loading modes require an application.
    if not args.software_app:
        parser.error("software_app is required unless using --list-targets")
    if (args.debug or args.skip_build) and args.software_app not in DEBUG_APPS:
        parser.error(f"'{args.software_app}': {DEBUG_UNSUPPORTED[args.software_app]}")

    is_coremark_pro = is_coremark_pro_program(args.software_app)
    if is_coremark_pro and args.coremark_pro_mode is None:
        parser.error(
            "CoreMark-PRO workloads require either -v0 or -v1. Use -v0 for "
            "performance/score runs with hardware-sized iterations; use -v1 "
            "for validation runs that check workload correctness."
        )
    if not is_coremark_pro and args.coremark_pro_mode is not None:
        parser.error("-v0 and -v1 are only valid for CoreMark-PRO workloads")
    if not is_coremark_pro and (
        args.coremark_pro_disable_free
        or args.coremark_pro_guard_free
        or args.coremark_pro_evict_free
        or args.coremark_pro_fence_writes
        or args.coremark_pro_trace
        or args.coremark_pro_parser_gen_ref
        or args.coremark_pro_parser_size is not None
    ):
        parser.error(
            "CoreMark-PRO diagnostic flags are only valid for CoreMark-PRO workloads"
        )
    if args.coremark_pro_disable_free and args.coremark_pro_evict_free:
        parser.error(
            "--coremark-pro-evict-free has no effect with --coremark-pro-disable-free"
        )
    if args.coremark_pro_parser_size is not None and args.coremark_pro_parser_size <= 0:
        parser.error("--coremark-pro-parser-size must be positive")
    if (
        args.coremark_pro_parser_gen_ref or args.coremark_pro_parser_size is not None
    ) and args.software_app != "coremark_pro_parser":
        parser.error("parser diagnostics are only valid for coremark_pro_parser")
    if (
        args.coremark_pro_parser_gen_ref or args.coremark_pro_parser_size is not None
    ) and args.coremark_pro_mode != "validation":
        parser.error("parser reference diagnostics require -v1 validation mode")

    # Reject DDR apps on future BRAM-only bitstreams instead of loading an
    # image whose cached address range reads as zero.
    if (args.ddr or args.software_app in DDR_APPS) and not BOARD_CONFIG[args.board][
        "has_ddr"
    ]:
        parser.error(
            f"'{args.software_app}' uses the DDR-backed cached region, which "
            f"board '{args.board}' does not provide in this bitstream."
        )

    coremark_pro_error = coremark_pro_hardware_error(args.software_app)
    if coremark_pro_error is not None:
        parser.error(
            f"'{args.software_app}' is not supported by the current official "
            f"CoreMark-PRO hardware flow: {coremark_pro_error}."
        )

    # Run Linux preflight before target prompting or the potentially long build.
    if args.software_app == "linux_boot":
        _linux_boot_preflight()

    # Resolve board settings and the application build directory.
    board_config = BOARD_CONFIG[args.board]
    try:
        clock_freq, clock_overridden = board_clock_freq(args.board)
    except ValueError as error:
        parser.error(str(error))
    if clock_overridden:
        print(f"CPU clock override: {CPU_CLK_ENV}={clock_freq} Hz")
    coremark_iterations = board_config["coremark_iterations"]

    tcl_script = SCRIPT_DIR / "load_software.tcl"
    app_dir_name = app_build_directory_name(args.software_app)
    app_dir = PROJECT_ROOT / "sw" / "apps" / app_dir_name

    if not app_dir.exists():
        print(f"Error: Application directory not found: {app_dir}", file=sys.stderr)
        sys.exit(1)

    # Compile before loading so both images match the selected board.
    if not args.skip_build:
        print(f"Compiling {args.software_app} for {args.board} ({clock_freq} Hz)...")
    if args.software_app == "coremark":
        print(f"  CoreMark iterations: {coremark_iterations}")
    make_vars = coremark_pro_make_vars(
        args.software_app,
        hardware=True,
        hardware_mode=args.coremark_pro_mode or "performance",
        board=args.board,
    )
    if args.coremark_pro_parser_gen_ref or args.coremark_pro_parser_size is not None:
        if args.coremark_pro_parser_size is None:
            parser_dataset_args = "-g1"
        else:
            parser_dataset_args = f"-n={args.coremark_pro_parser_size}-g1"
        make_vars["COREMARK_PRO_RUN_ARGS"] += f" -D={parser_dataset_args}"
    if args.coremark_pro_disable_free:
        make_vars["FROST_MALLOC_DISABLE_FREE"] = "1"
    if args.coremark_pro_guard_free:
        make_vars["FROST_MALLOC_GUARD_FREE"] = "1"
    if args.coremark_pro_evict_free:
        make_vars["FROST_MALLOC_EVICT_FREE"] = "1"
    if args.coremark_pro_fence_writes:
        make_vars["FROST_MEMORY_FENCE_WRITES"] = "1"
    if args.coremark_pro_trace:
        make_vars["COREMARK_PRO_TRACE"] = "1"
    if make_vars:
        print(f"  CoreMark-PRO workload: {make_vars['WORKLOAD']}")
        print(f"  CoreMark-PRO hardware args: {make_vars['COREMARK_PRO_RUN_ARGS']}")
        if args.coremark_pro_disable_free:
            print("  CoreMark-PRO diagnostic: free() disabled")
        if args.coremark_pro_guard_free:
            print("  CoreMark-PRO diagnostic: invalid frees guarded")
        if args.coremark_pro_evict_free:
            print("  CoreMark-PRO diagnostic: freed heap blocks evict L0")
        if args.coremark_pro_fence_writes:
            print("  CoreMark-PRO diagnostic: libc writes are fenced")
        if (
            args.coremark_pro_parser_gen_ref
            or args.coremark_pro_parser_size is not None
        ):
            if args.coremark_pro_parser_size is None:
                print("  CoreMark-PRO diagnostic: parser prints generated reference")
            else:
                print(
                    "  CoreMark-PRO diagnostic: parser prints generated "
                    f"reference for {args.coremark_pro_parser_size} byte XML"
                )
        if make_vars.get("COREMARK_PRO_OFFICIAL") == "1":
            print("  CoreMark-PRO mode: official hardware")
        if args.coremark_pro_mode == "performance":
            print("  CoreMark-PRO run type: performance/score (-v0)")
        elif args.coremark_pro_mode == "validation":
            print("  CoreMark-PRO run type: validation (-v1)")
    if not args.skip_build and not compile_app_for_board(
        args.software_app,
        app_dir,
        clock_freq,
        coremark_iterations,
        make_vars,
        mem_config="ddr" if args.ddr else None,
        debug=args.debug,
    ):
        print(f"Error: Failed to compile {args.software_app}", file=sys.stderr)
        sys.exit(1)

    descriptor = None
    # Keep ordinary existing loader behavior for other applications. The new
    # prebuilt contract applies to managed builds and loads; the original two
    # apps retain their previous unconditional validation.
    if args.software_app in DEBUG_APPS and (
        args.debug
        or args.skip_build
        or args.build_only
        or args.software_app in {"hello_world", "debug_target"}
    ):
        try:
            descriptor = validate_prebuilt_app(
                app_dir,
                clock_freq,
                "ddr" if args.ddr else os.environ.get("MEM_CONFIG", "bram"),
                args.debug or os.environ.get("FROST_DEBUG") == "1",
                app_name=args.software_app,
                make_vars=make_vars,
                coremark_iterations=coremark_iterations,
            )
            if (
                args.expected_build_config_sha256 is not None
                and descriptor["buildConfigSha256"]
                != args.expected_build_config_sha256.lower()
            ):
                raise ValueError(
                    "prebuilt Make configuration changed since build-only; rebuild and select its matching ELF"
                )
        except (ValueError, OSError) as error:
            parser.error(str(error))
    if args.build_only:
        if args.debug:
            print("FROST_DEBUG_BUILD=" + json.dumps(descriptor, sort_keys=True))
        print(f"FROST_ELF={app_dir / 'sw.elf'}")
        print("FROST_BUILD_COMPLETE")
        return

    # Build and validate before discovery can acquire the cable.
    selected_target = select_target(
        args.vivado_path,
        args.remote_host,
        target_pattern=args.target,
        board=args.board,
        **target_options,
    )

    # Vivado options must precede -tclargs or Tcl receives them as arguments.
    vivado_command = [
        args.vivado_path,
        "-mode",
        "batch",
        "-nojournal",
        "-nolog",
        "-source",
        str(tcl_script),
        "-tclargs",
        str(PROJECT_ROOT),
        args.software_app,
        selected_target,
    ]

    # Tcl receives the optional host, then whether hw_axi_2 and cached DDR exist.
    vivado_command.append(args.remote_host if args.remote_host else "")
    vivado_command.append("1" if BOARD_CONFIG[args.board]["has_ddr"] else "0")
    vivado_command.append(args.hw_server_url or "")

    # Run Vivado and propagate loader failures.
    subprocess.run(vivado_command, check=True)


if __name__ == "__main__":
    main()
