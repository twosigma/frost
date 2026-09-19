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

"""Static contracts for the frost_net10g NIC driver's one source.

linux/frost-net10g is built into the Buildroot kernel, through the kernel
patch that hooks drivers/net/ethernet/frost/ into the kernel build and the
external.mk hook that installs the directory's files there, and it is the
DKMS package that builds the driver as a module for Debian's kernels.
"""

import os
import re
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
DRIVER_DIR = REPO_ROOT / "linux" / "frost-net10g"
DRIVER_SOURCE = DRIVER_DIR / "frost_net10g.c"
DKMS_CONF = DRIVER_DIR / "dkms.conf"
KBUILD_MAKEFILE = DRIVER_DIR / "Makefile"
KCONFIG = DRIVER_DIR / "Kconfig"
BR2_EXTERNAL = REPO_ROOT / "linux" / "buildroot-external"
EXTERNAL_MK = BR2_EXTERNAL / "external.mk"
BOARD_DIR = BR2_EXTERNAL / "board" / "frost"
KERNEL_PATCH_DIR = BOARD_DIR / "patches" / "linux"
KERNEL_CONFIG = BOARD_DIR / "linux-frost.config"
DT_BINDING = BOARD_DIR / "frost,net10g.yaml"
PACKER = BOARD_DIR / "frost_boot_image.py"

# The files the hook installs into the kernel tree, and where
KERNEL_FILES = ["Kconfig", "Makefile", "frost_net10g.c"]
KERNEL_DIR = "drivers/net/ethernet/frost"
# The lines the kernel patch adds, one per parent file
HOOK_LINES = {
    "drivers/net/ethernet/Kconfig": f'source "{KERNEL_DIR}/Kconfig"',
    "drivers/net/ethernet/Makefile": "obj-$(CONFIG_NET_VENDOR_FROST) += frost/",
}
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
    """dkms.conf builds frost_net10g.ko from this directory for every kernel."""
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


def test_kernel_config_symbols_are_the_driver_kconfig() -> None:
    """The FROST kernel config enables symbols the driver's Kconfig defines.

    olddefconfig silently drops a symbol no Kconfig defines, which would
    leave the driver out of the kernel.
    """
    defined = set(re.findall(r"^config (\w+)$", KCONFIG.read_text(), re.M))
    assert defined == {"NET_VENDOR_FROST", "FROST_NET10G"}
    enabled = re.findall(r"^CONFIG_(\w+)=y$", KERNEL_CONFIG.read_text(), re.M)
    assert defined <= set(enabled)
    assert re.search(r"^config FROST_NET10G\n\ttristate ", KCONFIG.read_text(), re.M)


def test_kernel_patch_only_hooks_the_driver_directory() -> None:
    """The one kernel patch adds the two hook lines and none of the driver's files."""
    patches = sorted(KERNEL_PATCH_DIR.glob("*.patch"))
    assert [patch.name for patch in patches] == [
        "0001-net-ethernet-hook-in-the-FROST-net10g-driver.patch"
    ]
    # Without git format-patch's signature ("-- " and the git version)
    text = patches[0].read_text().rsplit("\n-- \n", 1)[0]
    touched = re.findall(r"^\+\+\+ b/(\S+)$", text, re.M)
    assert sorted(touched) == sorted(HOOK_LINES)
    assert not re.search(r"^--- /dev/null$", text, re.M)
    for path, line in HOOK_LINES.items():
        diff = text.split(f"+++ b/{path}\n", 1)[1].split("\ndiff --git ", 1)[0]
        added = [row[1:] for row in diff.splitlines() if row.startswith("+")]
        removed = [row for row in diff.splitlines() if row.startswith("-")]
        assert (added, removed) == ([line], []), path


def _run_hook(hook: str, *args: str) -> None:
    """Run an external.mk hook as Buildroot does: its lines are the recipe."""
    subprocess.run(
        [
            "make",
            "--no-print-directory",
            "-s",
            "-f",
            "-",
            f"BR2_EXTERNAL_FROST_PATH={BR2_EXTERNAL}",
            "INSTALL=install",
            *args,
            "hook",
        ],
        input=f"include {EXTERNAL_MK}\nhook:\n\t$({hook})\n",
        text=True,
        check=True,
    )


def test_buildroot_hooks_install_this_directory() -> None:
    """external.mk installs the driver's files where the patch hooks them in."""
    values = _make_variables(
        EXTERNAL_MK,
        [
            "FROST_NET10G_SRC_DIR",
            "FROST_NET10G_KERNEL_DIR",
            "FROST_NET10G_KERNEL_FILES",
            "FROST_NET10G_BUILD_FILES",
            "LINUX_POST_PATCH_HOOKS",
            "LINUX_PRE_BUILD_HOOKS",
            "LINUX_POST_LEGAL_INFO_HOOKS",
        ],
        f"BR2_EXTERNAL_FROST_PATH={BR2_EXTERNAL}",
        "LINUX_DIR=/linux",
    )
    assert Path(values["FROST_NET10G_SRC_DIR"]).resolve() == DRIVER_DIR
    assert values["FROST_NET10G_KERNEL_DIR"] == f"/linux/{KERNEL_DIR}"
    assert values["FROST_NET10G_KERNEL_FILES"].split() == KERNEL_FILES
    # Kconfig only after patching: the kernel configuration reads it before
    # any build step, so a refresh at build time would bypass olddefconfig
    assert values["FROST_NET10G_BUILD_FILES"].split() == ["Makefile", "frost_net10g.c"]
    assert values["LINUX_POST_PATCH_HOOKS"].split() == [
        "FROST_NET10G_INSTALL_KERNEL_SOURCES"
    ]
    assert values["LINUX_PRE_BUILD_HOOKS"].split() == [
        "FROST_NET10G_REFRESH_BUILD_SOURCES"
    ]
    assert values["LINUX_POST_LEGAL_INFO_HOOKS"].split() == ["FROST_NET10G_LEGAL_INFO"]


def test_buildroot_hooks_rewrite_only_changed_files(tmp_path: Path) -> None:
    """The hooks install the files, leave identical ones alone, restore edits."""
    linux_dir = f"LINUX_DIR={tmp_path / 'linux'}"
    installed = tmp_path / "linux" / KERNEL_DIR

    _run_hook("FROST_NET10G_INSTALL_KERNEL_SOURCES", linux_dir)
    assert sorted(path.name for path in installed.iterdir()) == sorted(KERNEL_FILES)
    for name in KERNEL_FILES:
        assert (installed / name).read_bytes() == (DRIVER_DIR / name).read_bytes()

    # Copies from an earlier build, two of them stale. Before a build only
    # the source is rewritten, so kbuild recompiles only what changed, and
    # Kconfig is left for the next patch step.
    for name in ("Kconfig", "frost_net10g.c"):
        (installed / name).write_text("stale\n")
    earlier = 1_000_000_000 * 10**9
    for name in KERNEL_FILES:
        os.utime(installed / name, ns=(earlier, earlier))
    _run_hook("FROST_NET10G_REFRESH_BUILD_SOURCES", linux_dir)
    mtimes = {name: (installed / name).stat().st_mtime_ns for name in KERNEL_FILES}
    assert (installed / "frost_net10g.c").read_bytes() == DRIVER_SOURCE.read_bytes()
    assert (installed / "Kconfig").read_text() == "stale\n"
    assert mtimes["frost_net10g.c"] > earlier
    assert (mtimes["Kconfig"], mtimes["Makefile"]) == (earlier, earlier)

    _run_hook("FROST_NET10G_INSTALL_KERNEL_SOURCES", linux_dir)
    assert (installed / "Kconfig").read_bytes() == KCONFIG.read_bytes()
    assert (installed / "Makefile").stat().st_mtime_ns == earlier


def test_buildroot_legal_info_saves_the_driver(tmp_path: Path) -> None:
    """legal-info archives the driver, which the kernel tarball and patch lack."""
    sources = tmp_path / "linux-6.18.7"
    _run_hook("FROST_NET10G_LEGAL_INFO", f"LINUX_REDIST_SOURCES_DIR={sources}")
    saved = sources / "frost-net10g"
    assert sorted(path.name for path in saved.iterdir()) == sorted(
        [*KERNEL_FILES, "README.md"]
    )
    for path in saved.iterdir():
        assert path.read_bytes() == (DRIVER_DIR / path.name).read_bytes()


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
