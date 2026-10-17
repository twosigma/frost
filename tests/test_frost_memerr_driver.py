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

"""Check consistency of the frost_memerr driver, its packaging and the hardware.

DKMS and linux/debian_kernel.py build the same module. The driver's register
offsets and bits are the unit's (hw/rtl/cpu_and_mem/memory_error_unit.sv) and
the bare-metal header's (sw/lib/include/memory_error.h).
"""

import importlib.util
import re
import subprocess
from pathlib import Path
from types import ModuleType

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
DRIVER_DIR = REPO_ROOT / "linux" / "frost-memerr"
DRIVER_SOURCE = DRIVER_DIR / "frost_memerr.c"
DKMS_CONF = DRIVER_DIR / "dkms.conf"
KBUILD_MAKEFILE = DRIVER_DIR / "Makefile"
KCONFIG = DRIVER_DIR / "Kconfig"
DEBIAN_KERNEL = REPO_ROOT / "linux" / "debian_kernel.py"
BOARD_DIR = REPO_ROOT / "linux" / "buildroot-external" / "board" / "frost"
DT_BINDING = BOARD_DIR / "frost,memory-error.yaml"
PACKER = BOARD_DIR / "frost_boot_image.py"
UNIT_RTL = REPO_ROOT / "hw" / "rtl" / "cpu_and_mem" / "memory_error_unit.sv"
BARE_METAL_HEADER = REPO_ROOT / "sw" / "lib" / "include" / "memory_error.h"
SPDX = "SPDX-License-Identifier: GPL-2.0-only OR BSD-2-Clause"

# The driver's register names, the bare-metal header's, and the RTL's.
REGISTERS = {
    "CAPS": "CAPS",
    "STATUS": "STATUS",
    "IRQ_EN": "IRQ_EN",
    "CE_COUNT": "CE_COUNT",
    "UE_COUNT": "UE_COUNT",
    "AXI_RD_ERRS": "AXI_RD_ERRS",
    "AXI_WR_ERRS": "AXI_WR_ERRS",
    "CE_ADDR": "CE_ADDR",
    "UE_ADDR": "UE_ADDR",
    "AXI_ERR": "AXI_ERR",
    "ECC_POLLS": "ECC_POLLS",
}


def _dkms_conf() -> dict[str, str]:
    """Return dkms.conf's assignments (it is sourced by bash: KEY="value")."""
    values = {}
    for line in DKMS_CONF.read_text().splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        match = re.fullmatch(r'([A-Z_]+(?:\[\d+\])?)="([^"$`\\]*)"', line)
        assert match is not None, f"dkms.conf: not a plain assignment: {line!r}"
        values[match.group(1)] = match.group(2)
    return values


def _driver_macro(name: str) -> str:
    matches = re.findall(rf'^{name}\("([^"]*)"\);$', DRIVER_SOURCE.read_text(), re.M)
    assert len(matches) == 1, f"{name}: {matches}"
    return matches[0]


def _defines(text: str, prefix: str) -> dict[str, int]:
    """Return the numeric #defines that start with prefix, by their suffix."""
    return {
        match.group(1): int(match.group(2), 0)
        for match in re.finditer(
            rf"^#define {prefix}([A-Z_0-9]+) (0x[0-9A-Fa-f]+|\d+)u?$", text, re.M
        )
    }


def _debian_kernel() -> ModuleType:
    """Import linux/debian_kernel.py by path (it is a script, not a package)."""
    spec = importlib.util.spec_from_file_location("debian_kernel", DEBIAN_KERNEL)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_dkms_package_matches_the_driver() -> None:
    """dkms.conf builds frost_memerr.ko from this directory at MODULE_VERSION.

    DKMS skips a kernel that lacks one of the Kconfig dependencies, which
    BUILD_EXCLUSIVE_CONFIG repeats.
    """
    conf = _dkms_conf()
    assert conf["PACKAGE_VERSION"] == _driver_macro("MODULE_VERSION")
    assert conf["PACKAGE_NAME"] == DRIVER_DIR.name
    assert conf["BUILT_MODULE_NAME[0]"] == DRIVER_SOURCE.stem
    assert conf["DEST_MODULE_LOCATION[0]"].startswith(("/kernel", "/updates", "/extra"))
    depends = re.search(
        r"^config FROST_MEMERR\n(?:\t.*\n)*?\tdepends on (.+)$",
        KCONFIG.read_text(),
        re.M,
    )
    assert depends is not None
    assert conf["BUILD_EXCLUSIVE_CONFIG"].split() == [
        f"CONFIG_{symbol.strip()}" for symbol in depends.group(1).split("&&")
    ]


@pytest.mark.parametrize(
    ("args", "obj_m"),
    [
        (["CONFIG_FROST_MEMERR=m"], "frost_memerr.o"),
        ([], ""),
        (["KBUILD_EXTMOD=/usr/src/frost-memerr"], "frost_memerr.o"),
    ],
    ids=["in-tree-module", "not-selected", "external-module"],
)
def test_kbuild_makefile_serves_both_builds(args: list[str], obj_m: str) -> None:
    """In the kernel tree Kconfig selects the driver; out of tree it is a module."""
    printer = "\t@echo 'obj-m=$(obj-m)'\n"
    result = subprocess.run(
        ["make", "--no-print-directory", "-s", "-f", "-", *args],
        input=f"include {KBUILD_MAKEFILE}\n.PHONY: print-vars\nprint-vars:\n{printer}",
        capture_output=True,
        text=True,
        check=True,
    )
    assert result.stdout.strip() == f"obj-m={obj_m}"


def test_driver_binds_the_device_tree_node() -> None:
    """The driver matches the compatible the binding documents and the packer emits."""
    source = DRIVER_SOURCE.read_text()
    table = re.search(
        r"of_device_id frost_memerr_of_match\[\] = \{(.*?)\n\};", source, re.S
    )
    assert table is not None
    assert re.findall(r'\.compatible = "([^"]+)"', table.group(1)) == [
        "frost,memory-error"
    ]
    assert "MODULE_DEVICE_TABLE(of, frost_memerr_of_match);" in source
    assert re.search(r"^    const: frost,memory-error$", DT_BINDING.read_text(), re.M)
    assert 'compatible = "frost,memory-error";' in PACKER.read_text()


def test_driver_license_and_build() -> None:
    """The license headers, and debian_kernel.py's entry for the module."""
    assert _driver_macro("MODULE_LICENSE") == "Dual BSD/GPL"
    assert DRIVER_SOURCE.read_text().splitlines()[0] == f"// {SPDX}"
    for path in (KCONFIG, KBUILD_MAKEFILE, DKMS_CONF):
        assert path.read_text().splitlines()[0] == f"# {SPDX}", path.name
    helper = _debian_kernel()
    assert helper.MEMERR.directory == DRIVER_DIR
    assert helper.MEMERR.name == DRIVER_SOURCE.stem
    assert helper.MEMERR in helper.DRIVERS


def test_register_map_matches_the_hardware() -> None:
    """The driver, the bare-metal header and the RTL's map agree.

    The RTL documents each offset in its header comment, as "0xNN NAME".
    """
    driver = _defines(DRIVER_SOURCE.read_text(), "MEMERR_")
    header = _defines(BARE_METAL_HEADER.read_text(), "MEMORY_ERROR_")
    rtl = {
        match.group(2): int(match.group(1), 16)
        for match in re.finditer(
            r"^ \*   (0x[0-9A-F]{2}) ([A-Z_]+) ", UNIT_RTL.read_text(), re.M
        )
    }
    for name, rtl_name in REGISTERS.items():
        assert driver[name] == header[name] == rtl[rtl_name], name
    # STATUS and IRQ_EN bits.
    status = re.search(
        r"0x04 STATUS +W1C +bit 0 CE, bit 1 UE, bit 2 AXI read error,\s+\*\s+"
        r"bit 3 AXI write error, bit 4 new CE_ADDR, bit 5\s+\*\s+new UE_ADDR",
        UNIT_RTL.read_text(),
    )
    assert status is not None
    assert "#define MEMERR_CE BIT(0)" in DRIVER_SOURCE.read_text()
    assert "#define MEMERR_UE BIT(1)" in DRIVER_SOURCE.read_text()
    assert "#define MEMERR_AXI_RD BIT(2)" in DRIVER_SOURCE.read_text()
    assert "#define MEMERR_AXI_WR BIT(3)" in DRIVER_SOURCE.read_text()
    assert "#define MEMERR_CE_ADDR_NEW BIT(4)" in DRIVER_SOURCE.read_text()
    assert "#define MEMERR_UE_ADDR_NEW BIT(5)" in DRIVER_SOURCE.read_text()
    assert "#define MEMORY_ERROR_CE_ADDR_NEW (1u << 4)" in BARE_METAL_HEADER.read_text()
    assert "#define MEMORY_ERROR_UE_ADDR_NEW (1u << 5)" in BARE_METAL_HEADER.read_text()
    assert "#define MEMORY_ERROR_PLIC_SOURCE 5u" in BARE_METAL_HEADER.read_text()
