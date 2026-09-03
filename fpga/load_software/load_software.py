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
import os
import shutil
import subprocess
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = SCRIPT_DIR.parent.parent

# Import shared target selection and the software registry.
sys.path.insert(0, str(SCRIPT_DIR.parent / "common"))
sys.path.insert(0, str(PROJECT_ROOT / "sw" / "apps"))
from hw_target import add_target_args, select_target  # noqa: E402
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
    "linux_irq_active_ddr_test",
    "linux_boot",
    "linux_irq_ddr_test",
    "linux_irq_stack_slot_test",
    "memory_test",
    "packet_parser",
    "pde_return_hazard",
    "print_clock_speed",
    "ras_stress_test",
    "ras_test",
    "spanning_test",
    "sprintf_test",
    "strings_test",
    "tick_torture",
    "tomasulo_perf",
    "tomasulo_test",
    "uart_echo",
]

# Clock frequency in Hz; CoreMark iterations target about 10 seconds.
BOARD_CONFIG = {
    # ``has_ddr``: the bitstream provides the JTAG DDR-load master (hw_axi_2)
    # and the cached DDR region. The flag exists so a future BRAM-only board can
    # be added without loading a DDR image.
    "x3": {"clock_freq": 300000000, "coremark_iterations": 11000, "has_ddr": True},
}

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

    kimage = PROJECT_ROOT / "linux" / "build-rv64" / "images" / "Image"
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
        )

        # Build with any workload-specific Make overrides.
        print(f"Compiling {app_name}...")
        make_command = ["make"]
        if make_vars:
            make_command.extend(f"{key}={value}" for key, value in make_vars.items())

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
    add_target_args(parser)
    args = parser.parse_args()

    # Listing targets does not require an application.
    if args.list_targets:
        select_target(
            args.vivado_path, args.remote_host, list_only=True, board=args.board
        )
        return

    # All loading modes require an application.
    if not args.software_app:
        parser.error("software_app is required unless using --list-targets")

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
    if args.software_app in DDR_APPS and not BOARD_CONFIG[args.board]["has_ddr"]:
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

    # Select by board vendor and optional target pattern.
    selected_target = select_target(
        args.vivado_path,
        args.remote_host,
        target_pattern=args.target,
        board=args.board,
    )

    # Resolve board settings and the application build directory.
    board_config = BOARD_CONFIG[args.board]
    clock_freq = board_config["clock_freq"]
    coremark_iterations = board_config["coremark_iterations"]

    tcl_script = SCRIPT_DIR / "load_software.tcl"
    app_dir_name = app_build_directory_name(args.software_app)
    app_dir = PROJECT_ROOT / "sw" / "apps" / app_dir_name

    if not app_dir.exists():
        print(f"Error: Application directory not found: {app_dir}", file=sys.stderr)
        sys.exit(1)

    # Compile before loading so both images match the selected board.
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
    if not compile_app_for_board(
        args.software_app,
        app_dir,
        clock_freq,
        coremark_iterations,
        make_vars,
        mem_config="ddr" if args.ddr else None,
    ):
        print(f"Error: Failed to compile {args.software_app}", file=sys.stderr)
        sys.exit(1)

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

    # Run Vivado and propagate loader failures.
    subprocess.run(vivado_command, check=True)


if __name__ == "__main__":
    main()
