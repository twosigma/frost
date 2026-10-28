#!/usr/bin/env python3
#    Copyright 2026 John Goodacre
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

"""Prepare or program a VCU118 configuration and software flash image."""

import argparse
from pathlib import Path
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "common"))
from hw_target import add_target_args, select_target, validate_target_args


def main() -> None:
    """Validate inputs, prepare configuration data, then select the exact cable."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.set_defaults(remote_host="")
    parser.add_argument("--boot-image", required=True, type=Path)
    parser.add_argument("--bitstream", type=Path)
    parser.add_argument("--boot-only", action="store_true")
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--prepare-only", action="store_true")
    parser.add_argument("--vivado-path", default="vivado")
    add_target_args(parser, managed=True)
    args = parser.parse_args()
    validate_target_args(parser, args)
    if args.boot_only == bool(args.bitstream):
        parser.error("select either --bitstream or --boot-only")
    boot = args.boot_image.resolve()
    if not boot.is_file() or boot.stat().st_size != 0x400000:
        parser.error("--boot-image must be a four-MiB image from make_flash_image.py")
    bit = args.bitstream.resolve() if args.bitstream else None
    if bit is not None and (
        not bit.is_file() or bit.suffix.lower() != ".bit" or not bit.stat().st_size
    ):
        parser.error("--bitstream must be a nonempty .bit file")
    output = args.output_dir.resolve()
    cfg = output / "frost_flash_cfg.bin"
    if cfg in (boot, bit):
        parser.error("output must not overwrite an input")
    output.mkdir(parents=True, exist_ok=True)
    script = Path(__file__).with_suffix(".tcl").resolve()
    command = [
        args.vivado_path,
        "-mode",
        "batch",
        "-nojournal",
        "-nolog",
        "-source",
        str(script),
        "-tclargs",
    ]
    subprocess.run(
        [*command, "prepare", str(boot), str(bit or ""), str(cfg)], check=True
    )
    if args.prepare_only:
        return
    target = select_target(
        args.vivado_path,
        "",
        target_pattern=args.target,
        board="vcu118",
        hw_server_url=args.hw_server_url,
        target_exact=args.target_exact,
        non_interactive=args.non_interactive,
        list_only=args.list_targets,
    )
    if args.list_targets:
        return
    subprocess.run(
        [*command, "program", str(cfg), target, args.hw_server_url or ""], check=True
    )


if __name__ == "__main__":
    main()
