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

"""Program the multi-stage boot image into VCU118 SPI NOR Flash using Vivado."""

import argparse
from pathlib import Path
import subprocess
import sys

from make_flash_image import build_flash_image


def main():
    parser = argparse.ArgumentParser(description="Program VCU118 SPI NOR Flash")
    parser.add_argument(
        "--full",
        action="store_true",
        default=True,
        help="Program both FPGA bitstream (0x00000000) and boot image (0x03000000) for standalone boot",
    )
    parser.add_argument(
        "--boot-only",
        action="store_true",
        help="Program only the boot image at 0x03000000",
    )
    args = parser.parse_args()

    repo_root = Path(__file__).resolve().parent.parent.parent
    bitstream_file = repo_root / "fpga/build/vcu118/work/vcu118_frost.bit"
    raw_bin = Path("/tmp/frost_flash.bin")
    cfg_bin = Path("/tmp/frost_flash_cfg.bin")
    cfg_prm = Path("/tmp/frost_flash_cfg.prm")
    tcl_script = Path("/tmp/program_flash_vcu118.tcl")

    # Step 1: Pack the multi-stage boot image
    print(">>> Step 1: Packing boot components into /tmp/frost_flash.bin...")
    build_flash_image(repo_root, raw_bin)

    # Step 2: Generate Vivado TCL programming script
    wsl_prefix = "//wsl.localhost/Ubuntu-24.04"
    win_raw_bin = f"{wsl_prefix}{raw_bin}"
    win_bitstream = f"{wsl_prefix}{bitstream_file}"
    win_cfg_bin = f"{wsl_prefix}{cfg_bin}"
    win_cfg_prm = f"{wsl_prefix}{cfg_prm}"

    if args.boot_only or not bitstream_file.is_file():
        loaddata_spec = f'up 0x03000000 {win_raw_bin}'
    else:
        loaddata_spec = f'up 0x00000000 {win_bitstream} up 0x03000000 {win_raw_bin}'

    tcl_content = f"""# Vivado Flash Programming Script for VCU118
# Step 1: Create config memory file
write_cfgmem -format bin -size 128 -interface SPIx4 -loaddata "{loaddata_spec}" -force {win_cfg_bin}

# Step 2: Connect to hardware manager
open_hw_manager
connect_hw_server -url localhost:3121
set target [get_hw_targets -filter {{NAME =~ "*210308AEDDAB*"}}]
if {{[llength $target] == 0}} {{
    set target [lindex [get_hw_targets] 0]
}}
puts "Using target: $target"
open_hw_target $target

current_hw_device [get_hw_devices xcvu9p_0]
refresh_hw_device -update_hw_probes false [lindex [get_hw_devices xcvu9p_0] 0]

# Step 3: Configure and program MT25QU01G SPI NOR flash
create_hw_cfgmem -hw_device [lindex [get_hw_devices xcvu9p_0] 0] [lindex [get_cfgmem_parts {{mt25qu01g-spi-x1_x2_x4}}] 0]
set_property PROGRAM.BLANK_CHECK  0 [get_property PROGRAM.HW_CFGMEM [lindex [get_hw_devices xcvu9p_0] 0]]
set_property PROGRAM.ERASE        1 [get_property PROGRAM.HW_CFGMEM [lindex [get_hw_devices xcvu9p_0] 0]]
set_property PROGRAM.CFG_PROGRAM  1 [get_property PROGRAM.HW_CFGMEM [lindex [get_hw_devices xcvu9p_0] 0]]
set_property PROGRAM.VERIFY       1 [get_property PROGRAM.HW_CFGMEM [lindex [get_hw_devices xcvu9p_0] 0]]
set_property PROGRAM.CHECKSUM     0 [get_property PROGRAM.HW_CFGMEM [lindex [get_hw_devices xcvu9p_0] 0]]
set_property PROGRAM.ADDRESS_RANGE {{use_file}} [get_property PROGRAM.HW_CFGMEM [lindex [get_hw_devices xcvu9p_0] 0]]
set_property PROGRAM.FILES [list "{win_cfg_bin}"] [get_property PROGRAM.HW_CFGMEM [lindex [get_hw_devices xcvu9p_0] 0]]
set_property PROGRAM.PRM_FILE [list "{win_cfg_prm}"] [get_property PROGRAM.HW_CFGMEM [lindex [get_hw_devices xcvu9p_0] 0]]
set_property PROGRAM.UNUSED_PIN_TERMINATION {{pull-none}} [get_property PROGRAM.HW_CFGMEM [lindex [get_hw_devices xcvu9p_0] 0]]

puts "Loading indirect flash programming bitstream..."
create_hw_bitstream -hw_device [lindex [get_hw_devices xcvu9p_0] 0] [get_property PROGRAM.HW_CFGMEM_BITFILE [lindex [get_hw_devices xcvu9p_0] 0]]
program_hw_devices [lindex [get_hw_devices xcvu9p_0] 0]
refresh_hw_device [lindex [get_hw_devices xcvu9p_0] 0]

puts "Erasing and programming SPI NOR Flash (0x03000000 .. 0x033FFFFF)..."
program_hw_cfgmem -hw_cfgmem [get_property PROGRAM.HW_CFGMEM [lindex [get_hw_devices xcvu9p_0] 0]]

puts "Flash programming complete!"
close_hw_target
disconnect_hw_server
"""
    tcl_script.write_text(tcl_content)

    print(">>> Step 2: Running Vivado flash programming over JTAG...")
    cmd = ["vivado", "-mode", "batch", "-source", str(tcl_script), "-nolog", "-nojournal"]
    result = subprocess.run(cmd)
    if result.returncode != 0:
        print(f"ERROR: Vivado flash programming failed with code {result.returncode}", file=sys.stderr)
        sys.exit(result.returncode)

    print(">>> SPI NOR Flash successfully programmed!")


if __name__ == "__main__":
    main()

