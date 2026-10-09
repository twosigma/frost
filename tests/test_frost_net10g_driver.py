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

"""Static checks that the frost_net10g driver, DKMS package, and module build agree.

linux/frost-net10g is a DKMS package that builds the driver as a module for
Debian's kernels. linux/debian_kernel.py builds the same module for the pinned
kernel and puts it in the test initramfs. The Kconfig and the kbuild Makefile
also support an in-tree build, and dkms.conf repeats the Kconfig dependencies.
"""

import importlib.util
import re
import subprocess
from pathlib import Path
from types import ModuleType

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
DRIVER_DIR = REPO_ROOT / "linux" / "frost-net10g"
DEBIAN_KERNEL = REPO_ROOT / "linux" / "debian_kernel.py"
DRIVER_SOURCE = DRIVER_DIR / "frost_net10g.c"
DKMS_CONF = DRIVER_DIR / "dkms.conf"
KBUILD_MAKEFILE = DRIVER_DIR / "Makefile"
KCONFIG = DRIVER_DIR / "Kconfig"
BR2_EXTERNAL = REPO_ROOT / "linux" / "buildroot-external"
BOARD_DIR = BR2_EXTERNAL / "board" / "frost"
DT_BINDING = BOARD_DIR / "frost,net10g.yaml"
PACKER = BOARD_DIR / "frost_boot_image.py"

# MODULE_LICENSE strings the kernel treats as GPL-compatible (license_is_gpl_compatible())
GPL_COMPATIBLE_LICENSES = {
    "GPL",
    "GPL v2",
    "GPL and additional rights",
    "Dual BSD/GPL",
    "Dual MIT/GPL",
    "Dual MPL/GPL",
}
SPDX = "SPDX-License-Identifier: GPL-2.0-only OR BSD-2-Clause"


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


def _make_variables(makefile: Path, names: list[str], *args: str) -> dict[str, str]:
    """Return make's values of the named variables after reading makefile."""
    printer = "".join(f"\t@echo '{name}=$({name})'\n" for name in names)
    result = subprocess.run(
        ["make", "--no-print-directory", "-s", "-f", "-", *args],
        input=f"include {makefile}\n.PHONY: print-vars\nprint-vars:\n{printer}",
        capture_output=True,
        text=True,
        check=True,
    )
    return dict(line.split("=", 1) for line in result.stdout.splitlines())


def test_dkms_package_version_is_the_module_version() -> None:
    """dkms.conf's PACKAGE_VERSION is the driver's MODULE_VERSION."""
    assert _dkms_conf()["PACKAGE_VERSION"] == _driver_macro("MODULE_VERSION")


def test_dkms_conf_names_the_package_and_the_module() -> None:
    """dkms.conf builds frost_net10g.ko from this directory for every kernel.

    DKMS skips a kernel that lacks one of the Kconfig dependencies, which
    BUILD_EXCLUSIVE_CONFIG repeats.
    """
    conf = _dkms_conf()
    # DKMS sources the tree from /usr/src/<PACKAGE_NAME>-<PACKAGE_VERSION>/
    assert conf["PACKAGE_NAME"] == DRIVER_DIR.name
    assert conf["BUILT_MODULE_NAME[0]"] == DRIVER_SOURCE.stem
    # dkms rejects any other prefix
    assert conf["DEST_MODULE_LOCATION[0]"].startswith(("/kernel", "/updates", "/extra"))
    assert conf["AUTOINSTALL"] == "yes"
    # The Kconfig dependencies, which the forced module build bypasses
    depends = re.search(
        r"^config FROST_NET10G\n(?:\t.*\n)*?\tdepends on (.+)$",
        KCONFIG.read_text(),
        re.M,
    )
    assert depends is not None
    assert conf["BUILD_EXCLUSIVE_CONFIG"].split() == [
        f"CONFIG_{symbol.strip()}" for symbol in depends.group(1).split("&&")
    ]
    # One module, built by DKMS's default command in the tree's top directory
    assert not {key for key in conf if key.endswith("]") and not key.endswith("[0]")}
    assert not {"MAKE[0]", "BUILT_MODULE_LOCATION[0]"} & conf.keys()


@pytest.mark.parametrize(
    ("args", "obj_y", "obj_m"),
    [
        (["CONFIG_FROST_NET10G=y"], "frost_net10g.o", ""),
        (["CONFIG_FROST_NET10G=m"], "", "frost_net10g.o"),
        ([], "", ""),
        (["KBUILD_EXTMOD=/usr/src/frost-net10g"], "", "frost_net10g.o"),
    ],
    ids=["built-in", "in-tree-module", "not-selected", "external-module"],
)
def test_kbuild_makefile_serves_both_builds(
    args: list[str], obj_y: str, obj_m: str
) -> None:
    """In the kernel tree Kconfig selects the driver; out of tree it is a module."""
    values = _make_variables(KBUILD_MAKEFILE, ["obj-y", "obj-m"], *args)
    assert values == {"obj-y": obj_y, "obj-m": obj_m}


def test_driver_binds_the_device_tree_node() -> None:
    """The driver matches the compatible the binding documents and the packer emits."""
    source = DRIVER_SOURCE.read_text()
    table = re.search(r"of_device_id frost_of_match\[\] = \{(.*?)\n\};", source, re.S)
    assert table is not None
    assert re.findall(r'\.compatible = "([^"]+)"', table.group(1)) == ["frost,net10g"]
    # The module alias udev loads it by comes from this table
    assert "MODULE_DEVICE_TABLE(of, frost_of_match);" in source
    assert re.search(r"^    const: frost,net10g$", DT_BINDING.read_text(), re.M)
    assert 'compatible = "frost,net10g";' in PACKER.read_text()


def test_driver_license_is_gpl_compatible() -> None:
    """The module license keeps a distribution kernel free of the license taint."""
    assert _driver_macro("MODULE_LICENSE") in GPL_COMPATIBLE_LICENSES
    assert DRIVER_SOURCE.read_text().splitlines()[0] == f"// {SPDX}"
    for path in (KCONFIG, KBUILD_MAKEFILE, DKMS_CONF):
        assert path.read_text().splitlines()[0] == f"# {SPDX}", path.name


def _debian_kernel() -> ModuleType:
    """Import linux/debian_kernel.py by path (it is a script, not a package)."""
    spec = importlib.util.spec_from_file_location("debian_kernel", DEBIAN_KERNEL)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_debian_module_build_matches_the_dkms_package() -> None:
    """The module FROST boots is this directory, built the way DKMS builds it.

    linux/debian_kernel.py runs DKMS's default command, ``make -C <kernel build
    dir> M=<build dir> modules``, over copies of the files DKMS would build, and
    installs the module DKMS names.
    """
    helper = _debian_kernel()
    conf = _dkms_conf()
    assert helper.DRIVER_DIR == DRIVER_DIR
    assert helper.MODULE_NAME == DRIVER_SOURCE.stem == conf["BUILT_MODULE_NAME[0]"]
    source = DEBIAN_KERNEL.read_text()
    assert 'f"M={build}"' in source and '"modules"' in source
    # Only the kbuild Makefile and the source are needed: the Kconfig is for an
    # in-tree build, which an external module build bypasses.
    assert 'for name in ("Makefile", f"{MODULE_NAME}.c")' in source
    assert helper.MODULE_INIT_SCRIPT.startswith("etc/init.d/S")
