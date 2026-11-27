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
from vcu118_metadata import (
    VCU118_DEFAULT_VECTOR_VLEN,
    _summarize_zvl_and_v,
    extract_dtb_from_flash_image,
    fdt_cpu_isa_info,
    read_bitstream_sidecar,
    verify_dtb_vector_config,
)


def _check_flash_boot_vlen(
    boot: Path,
    *,
    expected_vector: bool | None = None,
    expected_vlen: int | None = None,
) -> None:
    """Verify the flash boot image's packed DTB does not use a non-256 VLEN."""
    dtb_blob = extract_dtb_from_flash_image(boot)
    try:
        info = fdt_cpu_isa_info(dtb_blob)
    except ValueError:
        info = None
    if info is not None and info["has_cpu_isa"]:
        for label, tokens in (
            ("riscv,isa", info["isa_tokens"]),
            ("riscv,isa-extensions", info["ext_tokens"]),
        ):
            if tokens is None:
                continue
            has_v, max_zvl = _summarize_zvl_and_v(tokens)
            if (has_v and max_zvl != VCU118_DEFAULT_VECTOR_VLEN) or (
                not has_v and max_zvl is not None
            ):
                raise ValueError(
                    f"flash boot image {boot} {label} advertises VLEN {max_zvl}; "
                    f"flash supports only default VLEN {VCU118_DEFAULT_VECTOR_VLEN} "
                    "(non-default VLENs are supported over JTAG loading only)"
                )
    if expected_vector is not None and expected_vlen is not None:
        try:
            verify_dtb_vector_config(
                dtb_blob,
                expected_vector=expected_vector,
                expected_vlen=expected_vlen,
                source=f"flash boot image {boot}",
                require_cpu_isa=False,
            )
        except ValueError as error:
            raise ValueError(
                f"{error} (non-default VLENs are supported over JTAG loading only)"
            ) from error


def main() -> None:
    """Validate inputs, prepare configuration data, then select the exact cable."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.set_defaults(remote_host="")
    parser.add_argument("--boot-image", type=Path)
    parser.add_argument("--fpga-image", type=Path)
    parser.add_argument("--boot-only", action="store_true")
    parser.add_argument(
        "--vlen",
        type=int,
        default=None,
        help="Vector register length in bits (flash supports only default VLEN 256; non-default VLENs are supported over JTAG loading only)",
    )
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--prepare-only", action="store_true")
    parser.add_argument("--vivado-path", default="vivado")
    add_target_args(parser, managed=True)
    args = parser.parse_args()
    validate_target_args(parser, args)
    if args.vlen is not None and args.vlen != VCU118_DEFAULT_VECTOR_VLEN:
        parser.error(
            f"--vlen {args.vlen} is not supported for flash; flash supports only "
            f"default VLEN {VCU118_DEFAULT_VECTOR_VLEN} "
            "(non-default VLENs are supported over JTAG loading only)"
        )
    if args.list_targets:
        select_target(
            args.vivado_path,
            "",
            board="vcu118",
            list_only=True,
            hw_server_url=args.hw_server_url,
            non_interactive=args.non_interactive,
        )
        return
    if args.boot_image is None or args.output_dir is None:
        parser.error("--boot-image and --output-dir are required")
    if args.boot_only == bool(args.fpga_image):
        parser.error("select either --fpga-image or --boot-only")
    boot = args.boot_image.resolve()
    if not boot.is_file() or boot.stat().st_size != 0x400000:
        parser.error("--boot-image must be a four-MiB image from make_flash_image.py")
    bit = args.fpga_image.resolve() if args.fpga_image else None
    if bit is not None and (
        not bit.is_file() or bit.suffix.lower() != ".bit" or not bit.stat().st_size
    ):
        parser.error("--fpga-image must be a nonempty .bit file")
    try:
        bit_meta = read_bitstream_sidecar(bit) if bit is not None else None
    except ValueError as error:
        parser.error(str(error))
    if (
        bit_meta is not None
        and bool(bit_meta["vector"])
        and int(bit_meta["vlen"]) != VCU118_DEFAULT_VECTOR_VLEN
    ):
        parser.error(
            f"bitstream {bit} has VLEN {bit_meta['vlen']}; flash supports only "
            f"default VLEN {VCU118_DEFAULT_VECTOR_VLEN} "
            "(non-default VLENs are supported over JTAG loading only)"
        )
    if args.vlen is not None and bit_meta is not None and not bit_meta["vector"]:
        parser.error("--vlen 256 cannot be used with a scalar VCU118 bitstream")
    try:
        _check_flash_boot_vlen(
            boot,
            expected_vector=(
                bool(bit_meta["vector"])
                if bit_meta is not None
                else (True if args.vlen is not None else None)
            ),
            expected_vlen=(
                int(bit_meta["vlen"])
                if bit_meta is not None
                else (VCU118_DEFAULT_VECTOR_VLEN if args.vlen is not None else None)
            ),
        )
    except (OSError, ValueError) as error:
        parser.error(str(error))
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
    )
    subprocess.run(
        [*command, "program", str(cfg), target, args.hw_server_url or ""], check=True
    )


if __name__ == "__main__":
    main()
