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

"""Write the --regions file frost-native uses to count part of a program's run.

The demonstration's closing table counts the benchmark work only: CoreMark's
timed loop and the ray tracer's rendering. This script finds the addresses
that bound those regions in a program's ELF file, so nothing in the program
is touched and its timing is unchanged.

  coremark   from the instruction that reads CoreMark's start time (the last
             cycle-counter read in start_time) to the instruction that reads its
             stop time (the first one in stop_time): the cycles CoreMark itself
             reports as "Total ticks".
  raytrace   from the empty function rt_mark_render_start to rt_mark_render_end,
             leaving out the cycles that end in an instruction of uart_send or
             uart_tx_ready (sending the picture's characters), clones included.

The file also carries the reorder buffer's size from the RTL sources, so the
presenter never types it.
"""

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path


def run(prefix: str, tool: str, *args: str) -> str:
    """Return the standard output of a binutils tool."""
    return subprocess.run(
        [prefix + tool, *args], check=True, capture_output=True, text=True
    ).stdout


def symbols(prefix: str, elf: str) -> dict[str, tuple[int, int]]:
    """Return {name: (address, size)} for the ELF's function symbols."""
    out: dict[str, tuple[int, int]] = {}
    for line in run(prefix, "nm", "-S", elf).splitlines():
        fields = line.split()
        if len(fields) == 4 and fields[2] in "tT":
            out[fields[3]] = (int(fields[0], 16), int(fields[1], 16))
    return out


def cycle_reads(prefix: str, elf: str, name: str) -> list[int]:
    """Return the addresses of the cycle-counter reads inside function name."""
    reads: list[int] = []
    inside = False
    for line in run(prefix, "objdump", "-d", elf).splitlines():
        if re.match(r"^[0-9a-f]+ <.+>:$", line):
            inside = line.endswith(f"<{name}>:")
            continue
        match = re.match(r"^\s*([0-9a-f]+):\s+[0-9a-f]+\s+rdcycle\s", line)
        if inside and match:
            reads.append(int(match.group(1), 16))
    return reads


def rob_depth(rtl_package: Path) -> int:
    """Return the reorder buffer size from the RTL package."""
    text = rtl_package.read_text(encoding="utf-8")
    match = re.search(r"ReorderBufferDepth\s*=\s*(\d+)", text)
    if not match:
        sys.exit(f"make_regions: no ReorderBufferDepth in {rtl_package}")
    return int(match.group(1))


def main() -> int:
    """Print the regions file for one program."""
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("app", choices=("coremark", "raytrace"))
    parser.add_argument("elf")
    parser.add_argument("riscv_pkg", type=Path, help="hw/rtl/.../riscv_pkg.sv")
    parser.add_argument(
        "--prefix", default=os.environ.get("RISCV_PREFIX", "riscv64-linux-")
    )
    args = parser.parse_args()

    lines: list[str] = []
    syms = symbols(args.prefix, args.elf)
    if args.app == "coremark":
        starts = cycle_reads(args.prefix, args.elf, "start_time")
        stops = cycle_reads(args.prefix, args.elf, "stop_time")
        if not starts or not stops:
            sys.exit("make_regions: no cycle-counter read in start_time or stop_time")
        lines += [f"start {starts[-1]:#x}", f"end {stops[0]:#x}"]
    else:
        for name in ("rt_mark_render_start", "rt_mark_render_end"):
            if name not in syms:
                sys.exit(f"make_regions: no symbol {name} in {args.elf}")
        lines += [
            f"start {syms['rt_mark_render_start'][0]:#x}",
            f"end {syms['rt_mark_render_end'][0]:#x}",
        ]
        for name in ("uart_send", "uart_tx_ready"):
            # The compiler may have cloned the function (uart_send.constprop.0).
            clones = [
                v for k, v in syms.items() if k == name or k.startswith(name + ".")
            ]
            if not clones:
                sys.exit(f"make_regions: no symbol {name} in {args.elf}")
            lines += [
                f"skip {address:#x} {address + size:#x}" for address, size in clones
            ]
    lines.append(f"rob_depth {rob_depth(args.riscv_pkg)}")
    print("\n".join(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main())
