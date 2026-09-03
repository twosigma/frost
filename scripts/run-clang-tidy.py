#!/usr/bin/env python3
#
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

"""Run clang-tidy with each RISC-V source file's build flags.

Make supplies the ABI, defines, and include paths. Compiler diagnostics are
errors; the existing bugprone, misc, performance, and readability findings in
``.clang-tidy`` remain advisory until the repository has a clean baseline.
Advisory counts are always reported; ``FROST_CLANG_TIDY_SHOW_ADVISORIES=1``
prints the findings themselves.
"""

import os
import re
import shlex
import subprocess
import sys
from pathlib import Path


_MAKE_VALUE_PREFIX = "__FROST_CLANG_TIDY_MAKE_VALUE__"
_CLANG_UNSUPPORTED_FLAGS = {"-fno-tree-loop-distribute-patterns"}
_ADVISORY_DIAGNOSTIC = re.compile(r"^.+:\d+:\d+: warning:", re.MULTILINE)
_SHOW_ADVISORIES_ENV = "FROST_CLANG_TIDY_SHOW_ADVISORIES"
_COREMARK_PRO_CONTEXTS = {
    "al_frost.c": ("FROST_CFLAGS", "core"),
    "frost_cjpeg_tiny.c": ("MITH_CFLAGS", "cjpeg-rose7-preset"),
    "frost_linpack_tiny_f32.c": ("MITH_CFLAGS", "linear_alg-mid-100x100-sp"),
    "frost_mith_main.c": ("INTERPOSE_CFLAGS", "core"),
    "frost_zip_darkmark_sim.c": ("MITH_CFLAGS", "zip-test"),
}


def get_root_dir() -> Path:
    """Return the repository root."""
    return Path(__file__).parent.parent.resolve()


def _evaluate_make_variables(
    working_directory: Path,
    makefile: str,
    variable_names: tuple[str, ...],
    make_arguments: tuple[str, ...] = (),
) -> dict[str, str]:
    """Evaluate Make variables without running the Makefile's build targets."""
    info_lines = "\n".join(
        f"$(info {_MAKE_VALUE_PREFIX}{name}=$(strip $({name})))"
        for name in variable_names
    )
    make_probe = f"""\
include {makefile}
.DEFAULT_GOAL := __frost_clang_tidy_config
{info_lines}
.PHONY: __frost_clang_tidy_config
__frost_clang_tidy_config:
\t@:
"""

    command = [
        "make",
        "--no-print-directory",
        "--silent",
        "-f",
        "-",
        *make_arguments,
        "__frost_clang_tidy_config",
    ]
    makefile_path = working_directory / makefile
    try:
        result = subprocess.run(
            command,
            cwd=working_directory,
            input=make_probe,
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError as error:
        raise RuntimeError(
            f"Failed to run Make for {makefile_path}: {error}"
        ) from error

    if result.returncode != 0:
        details = (result.stderr or result.stdout).strip()
        suffix = f":\n{details}" if details else ""
        raise RuntimeError(
            f"Make could not evaluate clang-tidy flags from {makefile_path}{suffix}"
        )

    values: dict[str, str] = {}
    for line in result.stdout.splitlines():
        for name in variable_names:
            prefix = f"{_MAKE_VALUE_PREFIX}{name}="
            if line.startswith(prefix):
                values[name] = line.removeprefix(prefix).strip()

    missing = [name for name in variable_names if not values.get(name)]
    if missing:
        raise RuntimeError(
            f"Make did not provide {', '.join(missing)} from {makefile_path}"
        )

    return values


def extract_flags_from_common_mk(root_dir: Path) -> tuple[str, str]:
    """Evaluate RISCV_FLAGS and FPGA_CPU_CLK_FREQ from common.mk.

    Make expansion preserves ``?=``, recursive variables such as ``$(MABI)``,
    and environment overrides; text parsing previously produced ``-mabi=``.

    Returns:
        Tuple of (riscv_flags, fpga_clk_freq)

    Raises:
        FileNotFoundError: If common.mk does not exist.
        RuntimeError: If Make cannot evaluate the configuration.
    """
    common_mk = root_dir / "sw" / "common" / "common.mk"

    if not common_mk.exists():
        raise FileNotFoundError(f"Cannot find {common_mk}")

    values = _evaluate_make_variables(
        root_dir,
        "sw/common/common.mk",
        ("RISCV_FLAGS", "FPGA_CPU_CLK_FREQ"),
    )
    return values["RISCV_FLAGS"], values["FPGA_CPU_CLK_FREQ"]


def _resolve_include_paths(flags: str, working_directory: Path) -> str:
    """Make relative compiler include paths absolute for a repository-root run."""
    tokens = shlex.split(flags)
    resolved: list[str] = []
    index = 0
    while index < len(tokens):
        token = tokens[index]
        if token in _CLANG_UNSUPPORTED_FLAGS:
            index += 1
            continue
        if token == "-I" and index + 1 < len(tokens):
            include_path = Path(tokens[index + 1])
            if not include_path.is_absolute():
                include_path = (working_directory / include_path).resolve()
            resolved.extend(("-I", str(include_path)))
            index += 2
            continue
        if token.startswith("-I") and len(token) > 2:
            include_path = Path(token[2:])
            if not include_path.is_absolute():
                include_path = (working_directory / include_path).resolve()
            resolved.append(f"-I{include_path}")
        else:
            resolved.append(token)
        index += 1
    return shlex.join(resolved)


def extract_flags_for_file(
    file_path: str,
    root_dir: Path,
    default_flags: str,
    default_clock: str,
) -> tuple[str, str]:
    """Evaluate the compile flags of the app that owns the file."""
    path = Path(file_path)
    if path.is_absolute():
        try:
            relative_path = path.resolve().relative_to(root_dir.resolve())
        except ValueError:
            relative_path = path
    else:
        relative_path = path

    if len(relative_path.parts) < 3 or relative_path.parts[:2] != ("sw", "apps"):
        lib_include = root_dir / "sw" / "lib" / "include"
        return f"{default_flags} -I{lib_include}", default_clock

    app_name = relative_path.parts[2]
    app_dir = root_dir / "sw" / "apps" / app_name
    filename = relative_path.name

    if app_name == "coremark_pro":
        try:
            flag_variable, workload = _COREMARK_PRO_CONTEXTS[filename]
        except KeyError as error:
            raise RuntimeError(
                f"No CoreMark-PRO clang-tidy build context for {file_path}"
            ) from error
        values = _evaluate_make_variables(
            app_dir,
            "Makefile",
            (flag_variable, "FPGA_CPU_CLK_FREQ"),
            (f"WORKLOAD={workload}",),
        )
        flags = values[flag_variable]
        clock = values["FPGA_CPU_CLK_FREQ"]
    elif app_name == "riscv_tests":
        values = _evaluate_make_variables(
            app_dir,
            "Makefile.bench",
            ("CFLAGS", "INCLUDES"),
        )
        flags = f"{values['CFLAGS']} {values['INCLUDES']}"
        clock = default_clock
    elif app_name == "arch_test":
        values = _evaluate_make_variables(
            app_dir,
            "Makefile",
            ("ARCH", "ABI", "INCLUDES"),
        )
        flags = (
            f"-march={values['ARCH']} -mabi={values['ABI']} -DXLEN=64 -DFLEN=64 "
            f"{values['INCLUDES']}"
        )
        clock = default_clock
    else:
        values = _evaluate_make_variables(
            app_dir,
            "Makefile",
            ("CFLAGS", "FPGA_CPU_CLK_FREQ"),
        )
        flags = values["CFLAGS"]
        clock = values["FPGA_CPU_CLK_FREQ"]

    return _resolve_include_paths(flags, app_dir), clock


def get_riscv_sysroot(root_dir: Path) -> str:
    """Return the C library sysroot used by the RISC-V GCC toolchain."""
    try:
        result = subprocess.run(
            ["riscv-none-elf-gcc", "-print-sysroot"],
            cwd=root_dir,
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError as error:
        raise RuntimeError(
            f"Failed to query the RISC-V GCC sysroot: {error}"
        ) from error

    sysroot = result.stdout.strip()
    if result.returncode != 0 or not sysroot:
        details = (result.stderr or result.stdout).strip()
        suffix = f": {details}" if details else ""
        raise RuntimeError(f"Could not determine the RISC-V GCC sysroot{suffix}")
    return str(Path(sysroot).resolve())


def run_clang_tidy(
    file_path: str,
    _root_dir: Path,
    riscv_flags: str,
    fpga_clk_freq: str,
) -> bool:
    """Run clang-tidy on a single file.

    Returns:
        True if clang-tidy passed, False otherwise
    """
    # App Makefiles usually put -DFPGA_CPU_CLK_FREQ in their own flags. A second
    # definition risks clang's macro-redefinition diagnostic, which the
    # --warnings-as-errors setting below makes fatal. Add the clock only when
    # the flags lack it (the common.mk fallback context).
    resolved_flags = shlex.split(riscv_flags) if riscv_flags else []
    clang_tidy_flags = ["--target=riscv64-unknown-elf"]
    if not any(flag.startswith("-DFPGA_CPU_CLK_FREQ=") for flag in resolved_flags):
        clang_tidy_flags.append(f"-DFPGA_CPU_CLK_FREQ={fpga_clk_freq}")
    clang_tidy_flags.extend(resolved_flags)

    cmd = [
        "clang-tidy",
        "--quiet",
        "--warnings-as-errors=clang-diagnostic-*",
        file_path,
        "--",
    ] + clang_tidy_flags

    try:
        result = subprocess.run(
            cmd,
            check=False,
            capture_output=True,
            text=True,
        )
    except OSError as error:
        print(f"clang-tidy could not run for {file_path}: {error}", file=sys.stderr)
        return False

    if result.returncode == 0:
        combined_output = "\n".join(
            output.rstrip() for output in (result.stdout, result.stderr) if output
        )
        advisory_count = len(_ADVISORY_DIAGNOSTIC.findall(combined_output))
        if advisory_count:
            print(
                f"clang-tidy advisory: {file_path} has {advisory_count} "
                f"non-blocking finding(s); set {_SHOW_ADVISORIES_ENV}=1 for details",
                file=sys.stderr,
            )
            if os.environ.get(_SHOW_ADVISORIES_ENV) == "1":
                print(combined_output, file=sys.stderr)
        return True

    print(
        f"clang-tidy failed for {file_path} (exit {result.returncode}):",
        file=sys.stderr,
    )
    for output in (result.stdout, result.stderr):
        if output:
            print(output.rstrip(), file=sys.stderr)
    return False


def main() -> int:
    """Run clang-tidy on provided files."""
    if len(sys.argv) < 2:
        return 0

    root_dir = get_root_dir()
    try:
        default_flags, default_clock = extract_flags_from_common_mk(root_dir)
        sysroot = get_riscv_sysroot(root_dir)
    except (OSError, RuntimeError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1

    # A configuration failure for one file does not stop the others.
    passed = True
    for file_path in sys.argv[1:]:
        try:
            riscv_flags, fpga_clk_freq = extract_flags_for_file(
                file_path,
                root_dir,
                default_flags,
                default_clock,
            )
        except (OSError, RuntimeError) as error:
            print(f"ERROR configuring {file_path}: {error}", file=sys.stderr)
            passed = False
            continue
        riscv_flags = f"{riscv_flags} --sysroot={shlex.quote(sysroot)}"
        if not run_clang_tidy(file_path, root_dir, riscv_flags, fpga_clk_freq):
            passed = False

    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
