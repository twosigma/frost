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

"""Check consistency of the frost_net10g driver and its module builds.

DKMS and linux/debian_kernel.py build the same module; the latter installs it
in the test initramfs. Kconfig and the kbuild Makefile also support an in-tree
build. dkms.conf repeats the Kconfig dependencies.
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


def test_driver_negotiates_full_width_nic_dma_without_breaking_legacy() -> None:
    """The kernel driver must not advertise 64-bit DMA then truncate descriptors."""
    source = DRIVER_SOURCE.read_text()
    assert "NET10G_ABI_EXTENDED_SUPPORTED" in source
    assert "dma_set_mask_and_coherent(dev, DMA_BIT_MASK(64))" in source
    assert "dma_set_mask_and_coherent(dev, DMA_BIT_MASK(32))" in source
    assert "writel(NET10G_ABI_EXTENDED, priv->base + NET10G_ABI_CTRL)" in source
    assert "writeq(priv->rx_ring_dma, priv->base + NET10G_RX_BASE64)" in source
    assert "writeq(priv->tx_ring_dma, priv->base + NET10G_TX_BASE64)" in source
    assert "readq(priv->base + NET10G_RX_BASE64)" in source
    assert "readq(priv->base + NET10G_TX_BASE64)" in source
    assert "desc->word1 = cpu_to_le32(upper_32_bits(dma));" in source
    assert "desc->word2 = cpu_to_le32(len);" in source
    assert "priv->wide_abi ? &desc->word3 : &desc->word2" in source
    assert "desc->addr = cpu_to_le32(lower_32_bits(dma));" not in source


def _debian_kernel() -> ModuleType:
    """Import linux/debian_kernel.py by path (it is a script, not a package)."""
    spec = importlib.util.spec_from_file_location("debian_kernel", DEBIAN_KERNEL)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_debian_module_build_matches_the_dkms_package() -> None:
    """The boot module uses DKMS's sources, command, and module name.

    Both run make -C <kernel build dir> M=<build dir> modules.
    """
    helper = _debian_kernel()
    conf = _dkms_conf()
    assert helper.DRIVER_DIR == DRIVER_DIR
    assert helper.MODULE_NAME == DRIVER_SOURCE.stem == conf["BUILT_MODULE_NAME[0]"]
    source = DEBIAN_KERNEL.read_text()
    assert 'f"M={build}"' in source and '"modules"' in source
    # Only the kbuild Makefile and the source are needed: the Kconfig is for an
    # in-tree build, which an external module build bypasses.
    assert 'for name in ("Makefile", f"{driver.name}.c")' in source
    assert helper.MODULE_INIT_SCRIPT.startswith("etc/init.d/S")


def _define(name: str) -> str:
    matches = re.findall(
        rf"^#define {name}\s+(\S+)\s*$", DRIVER_SOURCE.read_text(), re.M
    )
    assert len(matches) == 1, f"{name}: {matches}"
    return matches[0]


def _group(pattern: str, text: str) -> str:
    match = re.search(pattern, text)
    assert match is not None, pattern
    return match.group(1)


def _ethtool_ops(source: str) -> str:
    ops = re.search(r"ethtool_ops frost_ethtool_ops = \{(.*?)\n\};", source, re.S)
    assert ops is not None
    return ops.group(1)


def test_driver_sizes_the_rings_from_ethtool() -> None:
    """Both rings, the page pool and the buffer arrays follow per-device sizes."""
    source = DRIVER_SOURCE.read_text()
    assert _define("FROST_RING_DEFAULT") == "512"
    assert _define("FROST_RING_MIN") == "64"
    assert _define("FROST_RING_MAX") == "4096"
    # The fixed-size constants are gone
    for gone in ("FROST_RING_ENTRIES", "FROST_RING_LOG2", "FROST_RING_MASK"):
        assert gone not in source
    assert ".pool_size = priv->rx_entries," in source
    assert "FROST_RING_BYTES(priv->rx_entries)" in source
    assert "FROST_RING_BYTES(priv->tx_entries)" in source
    assert (
        "kvcalloc(priv->rx_entries" in source and "kvcalloc(priv->tx_entries" in source
    )
    # SIZE holds log2(entries); the write is read back and checked
    assert "writel(ilog2(priv->rx_entries), priv->base + NET10G_RX_SIZE)" in source
    assert "writel(ilog2(priv->tx_entries), priv->base + NET10G_TX_SIZE)" in source
    assert "readl(priv->base + NET10G_RX_SIZE) != ilog2(priv->rx_entries)" in source
    assert "readl(priv->base + NET10G_TX_SIZE) != ilog2(priv->tx_entries)" in source
    ops = _ethtool_ops(source)
    assert ".get_ringparam" in ops and ".set_ringparam" in ops
    assert "priv->rx_entries = FROST_RING_DEFAULT;" in source
    assert "priv->tx_entries = FROST_RING_DEFAULT;" in source


def test_driver_ring_range_fits_the_nic_and_the_tx_queue_thresholds() -> None:
    """The range stays inside nic_pkg's SIZE limits and above the TX wake threshold."""
    pkg = (REPO_ROOT / "hw/rtl/peripherals/nic/nic_pkg.sv").read_text()
    lo = int(_group(r"RingSizeLog2Min = (\d+);", pkg))
    hi = int(_group(r"RingSizeLog2Max = (\d+);", pkg))
    ring_min = int(_define("FROST_RING_MIN"))
    for name in ("FROST_RING_MIN", "FROST_RING_MAX", "FROST_RING_DEFAULT"):
        size = int(_define(name))
        assert size & (size - 1) == 0, name
        assert (1 << lo) <= size <= (1 << hi), name
    # A TX ring must be able to reach FROST_TX_WAKE_DESCS free entries:
    # MAX_SKB_FRAGS (17) + 3 + ceil(65536 / 9216) = 28 to stop, twice that to wake
    assert 2 * (17 + 3 + -(-65536 // 9216)) < ring_min


def test_driver_set_ringparam_rounds_up_and_restores_on_failure() -> None:
    """Resize frees at the old size, rebuilds at the new one, and falls back on failure."""
    source = DRIVER_SOURCE.read_text()
    body = re.search(r"static int frost_set_ringparam\(.*?\n\}\n", source, re.S)
    assert body is not None
    text = body.group(0)
    assert "roundup_pow_of_two(ring->rx_pending)" in text
    assert "roundup_pow_of_two(ring->tx_pending)" in text
    assert "ring->rx_pending < FROST_RING_MIN" in text and "return -EINVAL" in text
    assert "frost_reconfigure(" in text
    # A running interface goes through the stop and open paths, with the new sizes between them
    reconf = re.search(r"static int frost_reconfigure\(.*?\n\}\n", source, re.S)
    assert reconf is not None
    text = reconf.group(0)
    down = text.index("frost_down(ndev)")
    assign = text.index("priv->rx_entries = rx;", down)
    assert down < assign < text.index("err = frost_up(ndev)")
    assert "priv->rx_entries = old_rx;" in text and "priv->tx_entries = old_tx;" in text
    assert "priv->rx_fifo_limit = old_fifo;" in text
    # A stop after a failed resize must not tear down rings that are not there
    stop_match = re.search(r"static int frost_down\(.*?\n\}\n", source, re.S)
    assert stop_match is not None
    stop = stop_match.group(0)
    assert stop.index("if (!priv->hw_up)") < stop.index("frost_quiesce(priv)")
    assert "priv->hw_up = true;" in source and "priv->hw_up = false;" in stop


def _snake(name: str) -> str:
    return re.sub(r"(?<!^)([A-Z])", r"_\1", name).lower()


def test_driver_exposes_every_hardware_counter_in_order() -> None:
    """Ethtool -S lists each nic_pkg counter, read as 64 bits."""
    pkg = (REPO_ROOT / "hw/rtl/peripherals/nic/nic_pkg.sv").read_text()
    indexed = {
        name: int(index)
        for name, index in re.findall(r"localparam int unsigned (Cnt\w+) = (\d+);", pkg)
    }
    ordered = sorted(indexed, key=indexed.__getitem__)
    assert [indexed[name] for name in ordered] == list(range(len(ordered)))
    assert int(_group(r"NumCounters = (\d+);", pkg)) == len(ordered)
    assert int(_define("NET10G_COUNTERS"), 16) == int(
        _group(r"CounterBaseOffset = 12'h([0-9A-Fa-f]+);", pkg), 16
    )
    source = DRIVER_SOURCE.read_text()
    table = re.search(
        r"frost_stat_names\[\]\[ETH_GSTRING_LEN\] = \{(.*?)\n\};", source, re.S
    )
    assert table is not None
    names = re.findall(r'"(\w+)"', table.group(1))
    assert names == [_snake(name.removeprefix("Cnt")) for name in ordered]
    ops = _ethtool_ops(source)
    for hook in (".get_sset_count", ".get_strings", ".get_ethtool_stats"):
        assert hook in ops
    # The extended ABI reads the aligned doubleword at once, the legacy ABI re-reads the high half
    reader = re.search(r"static u64 frost_read_counter\(.*?\n\}\n", source, re.S)
    assert reader is not None
    assert "readq(reg)" in reader.group(0)
    assert "while (hi != readl(reg + 4))" in reader.group(0)


def test_driver_rx_fifo_limit_matches_the_nic_registers() -> None:
    """The driver's RX_FIFO_LIMIT constants are nic_pkg's."""
    pkg = (REPO_ROOT / "hw/rtl/peripherals/nic/nic_pkg.sv").read_text()
    for name, macro in (
        ("RxFifoLimitOffset", "NET10G_RX_FIFO_LIMIT"),
        ("RxFifoDepthOffset", "NET10G_RX_FIFO_DEPTH"),
    ):
        assert int(_define(macro), 16) == int(
            _group(rf"{name} = 12'h([0-9A-Fa-f]+);", pkg), 16
        )
    assert _define("FROST_FIFO_LIMIT_MIN") == _group(r"RxFifoLimitMin = (\d+);", pkg)
    assert _define("FROST_FIFO_LIMIT_DEFAULT") == _group(
        r"RxFifoLimitDefault = (\d+);", pkg
    )
    assert _define("FROST_FIFO_WORD_BYTES") == "8"


def test_driver_exposes_rx_fifo_bytes_as_a_devlink_runtime_parameter() -> None:
    """rx_fifo_bytes is a runtime devlink parameter validated against the built depth."""
    source = DRIVER_SOURCE.read_text()
    param = re.search(r"frost_devlink_params\[\] = \{(.*?)\n\};", source, re.S)
    assert param is not None
    assert '"rx_fifo_bytes"' in param.group(1)
    assert "DEVLINK_PARAM_TYPE_U32" in param.group(1)
    assert "BIT(DEVLINK_PARAM_CMODE_RUNTIME)" in param.group(1)
    validate = re.search(
        r"static int frost_dl_rx_fifo_validate\(.*?\n\}\n", source, re.S
    )
    assert validate is not None
    assert "priv->rx_fifo_depth * FROST_FIFO_WORD_BYTES" in validate.group(0)
    assert "FROST_FIFO_LIMIT_MIN * FROST_FIFO_WORD_BYTES" in validate.group(0)
    assert "% FROST_FIFO_WORD_BYTES" in validate.group(0)
    # The set callback uses the ring-size path, under RTNL
    setter = re.search(r"static int frost_dl_rx_fifo_set\(.*?\n\}\n", source, re.S)
    assert setter is not None
    text = setter.group(0)
    assert (
        text.index("rtnl_lock()")
        < text.index("frost_reconfigure(")
        < text.index("rtnl_unlock()")
    )
    assert "ctx->val.vu32 / FROST_FIFO_WORD_BYTES" in text
    # RESET returns the limit to its default, so every open writes it back and reads it back
    up = re.search(r"static int frost_up\(.*?\n\}\n", source, re.S)
    assert up is not None
    assert "frost_apply_fifo_limit(priv)" in up.group(0)
    apply_fn = re.search(r"static int frost_apply_fifo_limit\(.*?\n\}\n", source, re.S)
    assert apply_fn is not None
    assert (
        "writel(priv->rx_fifo_limit, priv->base + NET10G_RX_FIFO_LIMIT)"
        in apply_fn.group(0)
    )
    assert "readl_poll_timeout(priv->base + NET10G_RX_FIFO_LIMIT" in apply_fn.group(0)
    # Hardware without the register (depth reads 0) gets no parameter
    assert "if (priv->rx_fifo_depth) {\n\t\terr = frost_devlink_init(priv);" in source
    # Teardown unregisters before freeing, after the netdev is gone (devm runs in reverse order)
    init = re.search(r"static int frost_devlink_init\(.*?\n\}\n", source, re.S)
    assert init is not None
    text = init.group(0)
    assert text.index("frost_devlink_free") < text.index("frost_devlink_unregister")
    assert re.search(r"^\tselect NET_DEVLINK$", KCONFIG.read_text(), re.M)


def test_driver_pause_control_matches_the_nic_registers() -> None:
    """Ethtool -A drives PAUSE_CTRL, reopening a running interface, with autoneg refused."""
    pkg = (REPO_ROOT / "hw/rtl/peripherals/nic/nic_pkg.sv").read_text()
    assert int(_define("NET10G_PAUSE_CTRL"), 16) == int(
        _group(r"PauseCtrlOffset = 12'h([0-9A-Fa-f]+);", pkg), 16
    )
    assert (
        _define("NET10G_PAUSE_RX") == f"BIT({_group(r'PauseCtrlBitRx = (\d+);', pkg)})"
    )
    assert (
        _define("NET10G_PAUSE_TX") == f"BIT({_group(r'PauseCtrlBitTx = (\d+);', pkg)})"
    )
    # ABI_CTRL bit 5 advertises the registers (nic_csr builds the read value)
    assert _define("NET10G_ABI_PAUSE_SUPPORTED") == "BIT(5)"
    csr = (REPO_ROOT / "hw/rtl/peripherals/nic/nic_csr.sv").read_text()
    assert (
        "reg_word = {25'b0, 1'b1, 1'b1, 1'b1, 1'b1, rx_csum_q, 1'b1, wide_mode_q};"
        in csr
    )
    source = DRIVER_SOURCE.read_text()
    ops = _ethtool_ops(source)
    assert ".get_pauseparam" in ops and ".set_pauseparam" in ops
    setter = re.search(r"static int frost_set_pauseparam\(.*?\n\}\n", source, re.S)
    assert setter is not None
    text = setter.group(0)
    assert "if (!priv->pause_abi)" in text and "return -EOPNOTSUPP" in text
    assert "if (pause->autoneg)" in text and "return -EINVAL" in text
    assert "frost_reconfigure(" in text
    # Every open writes the bits back after RESET, and reads them back
    apply_fn = re.search(r"static int frost_apply_fifo_limit\(.*?\n\}\n", source, re.S)
    assert apply_fn is not None
    assert "writel(priv->pause, priv->base + NET10G_PAUSE_CTRL)" in apply_fn.group(0)
    assert "readl(priv->base + NET10G_PAUSE_CTRL) != priv->pause" in apply_fn.group(0)
    # The three pause counters are listed after the GMII ones
    assert '"rx_pause_frames"' in source and '"tx_paused_cycles"' in source


def test_driver_splits_tx_segments_only_for_old_hardware() -> None:
    """ABI_CTRL bit 6 lifts the 9216-byte segment split; hardware without it keeps it."""
    source = DRIVER_SOURCE.read_text()
    assert _define("NET10G_ABI_TX_LONG_SEGMENTS") == "BIT(6)"
    assert _define("FROST_TX_DESC_MAX") == "9216"
    probe = re.search(
        r"priv->tx_desc_max = \(readl\(base \+ NET10G_ABI_CTRL\) &\s+NET10G_ABI_TX_LONG_SEGMENTS\) \?\s+FIELD_MAX\(NET10G_DESC_LEN\) : FROST_TX_DESC_MAX;",
        source,
    )
    assert probe is not None
    # The transmit path splits by the per-device limit, never the constant
    xmit = re.search(r"static netdev_tx_t frost_start_xmit\(.*?\n\}\n", source, re.S)
    assert xmit is not None
    assert "FROST_TX_DESC_MAX" not in xmit.group(0)
    assert xmit.group(0).count("priv->tx_desc_max") == 4
    pkg = (REPO_ROOT / "hw/rtl/peripherals/nic/nic_pkg.sv").read_text()
    assert "bit 6 reads one" in pkg


def _run_driver_function(
    tmp_path: Path, declarations: str, function: str, main: str
) -> None:
    """Execute an actual driver helper with DMA and skb inputs supplied by a small C harness."""
    source = DRIVER_SOURCE.read_text()
    body = re.search(rf"static [^\n]* {function}\(.*?\n\}}\n", source, re.S)
    assert body is not None, function
    program = tmp_path / "driver_test.c"
    program.write_text(declarations + "\n" + body.group(0) + "\n" + main)
    executable = tmp_path / "driver_test"
    built = subprocess.run(
        ["cc", "-std=c11", "-Wall", "-Werror", str(program), "-o", str(executable)],
        capture_output=True,
        text=True,
    )
    assert built.returncode == 0, built.stderr
    subprocess.run([str(executable)], check=True, capture_output=True, text=True)


def test_tx_unmap_matches_mapping_kind_and_skips_unmapped_descriptors(
    tmp_path: Path,
) -> None:
    """Completion and reset share exactly-once teardown of head, fragment and parameter slots."""
    _run_driver_function(
        tmp_path,
        r"""
#include <assert.h>
#include <stdbool.h>
#define DMA_TO_DEVICE 1
struct frost_priv { void *dev; };
struct frost_buf { unsigned long dma; unsigned int len; bool page_mapping; };
static int singles, pages;
static void dma_unmap_single(void *dev, unsigned long dma, unsigned int len, int dir)
{
    assert(dev && dma == 123 && len == 17 && dir == DMA_TO_DEVICE);
    singles++;
}
static void dma_unmap_page(void *dev, unsigned long dma, unsigned int len, int dir)
{
    assert(dev && dma == 456 && len == 32768 && dir == DMA_TO_DEVICE);
    pages++;
}
""",
        "frost_tx_unmap",
        r"""
int main(void)
{
    struct frost_priv priv = { .dev = &singles };
    struct frost_buf buffers[] = {
        {0, 0, false}, {123, 17, false}, {0, 0, true}, {456, 32768, true}
    };
    for (int i = 0; i < 4; i++) {
        frost_tx_unmap(&priv, &buffers[i]);
        frost_tx_unmap(&priv, &buffers[i]);
    }
    assert(singles == 1 && pages == 1);
    return 0;
}
""",
    )
    source = DRIVER_SOURCE.read_text()
    for function in ("frost_tx_reap", "frost_reset_and_free"):
        body = re.search(rf"static void {function}\(.*?\n\}}\n", source, re.S)
        assert body is not None and "frost_tx_unmap(priv, buf);" in body.group(0)


def test_tso_uses_software_for_ipv6_extension_headers(tmp_path: Path) -> None:
    """A routing header's final destination must not be replaced by the current IPv6 DA."""
    _run_driver_function(
        tmp_path,
        r"""
#include <assert.h>
#include <stdint.h>
#define SKB_GSO_TCPV4 1
#define SKB_GSO_TCPV6 2
#define NETIF_F_GSO_MASK 3
#define ETH_HLEN 14
#define VLAN_HLEN 4
#define ETH_P_IPV6 0x86dd
#define NET10G_TSO_MAX_HDR 160
#define NET10G_CTX_MSS 16383
#define NET10G_CTX_PAYLOAD 65535
#define FIELD_MAX(x) (x)
#define htons(x) (x)
typedef uint64_t netdev_features_t;
struct net_device { int unused; };
struct ipv6hdr { char bytes[40]; };
struct sk_buff { unsigned int len, l3, l4, hdr, protocol, encapsulation;
                 unsigned int gso_type, gso_size; };
#define skb_shinfo(skb) (skb)
#define skb_is_gso(skb) ((skb)->gso_size != 0)
#define skb_network_offset(skb) ((skb)->l3)
#define skb_tcp_all_headers(skb) ((skb)->hdr)
#define skb_transport_offset(skb) ((skb)->l4)
#define vlan_get_protocol(skb) ((skb)->protocol)
""",
        "frost_features_check",
        r"""
int main(void)
{
    struct sk_buff skb = { .len = 3000, .l3 = 14, .l4 = 54, .hdr = 74,
                          .protocol = ETH_P_IPV6, .gso_type = SKB_GSO_TCPV6,
                          .gso_size = 1460 };
    assert(frost_features_check(&skb, 0, 7) == 7);
    /* Same TCP packet with a 24-byte IPv6 routing header. */
    skb.l4 += 24;
    skb.hdr += 24;
    assert(frost_features_check(&skb, 0, 7) == 4);
    /* Ordinary VLAN-tagged IPv6 remains eligible. */
    skb.l3 = 18; skb.l4 = 58; skb.hdr = 78;
    assert(frost_features_check(&skb, 0, 7) == 7);
    /* IPv4 options remain eligible. */
    skb.protocol = 0x0800; skb.l3 = 14; skb.l4 = 38; skb.hdr = 58;
    skb.gso_type = SKB_GSO_TCPV4;
    assert(frost_features_check(&skb, 0, 7) == 7);
    return 0;
}
""",
    )


def test_legacy_hardware_does_not_advertise_descriptor_chaining() -> None:
    """The long-segment capability identifies hardware that accepts FIRST..LAST chains."""
    source = DRIVER_SOURCE.read_text()
    assert (
        "priv->sg_abi = !!(readl(base + NET10G_ABI_CTRL) & NET10G_ABI_TX_LONG_SEGMENTS);"
        in source
    )
    assert "priv->segment_abi = priv->sg_abi && priv->csum_abi &&" in source
    assert re.search(
        r"if \(priv->sg_abi\) \{\s*ndev->hw_features \|= NETIF_F_SG;\s*ndev->features \|= NETIF_F_SG;\s*\}",
        source,
    )


def test_reconfigure_stops_tx_after_the_last_napi_completion(tmp_path: Path) -> None:
    """A completion racing with NAPI shutdown cannot leave the queue awake for ring teardown."""
    _run_driver_function(
        tmp_path,
        r"""
#include <assert.h>
#include <stdbool.h>
#define NET10G_IRQ_ALL 31
#define NET10G_IRQ_MASK_CLR 0
#define NET10G_IRQ_MASK 0
static bool napi_disabled, stopped, irq_synced;
struct frost_priv { int napi, refill_timer, irq; char *base; void *ndev; };
static void napi_disable(int *napi)
{
    /* A poll that was already running completes and wakes the stopped queue. */
    stopped = false;
    napi_disabled = true;
}
static void timer_delete_sync(int *timer) { assert(napi_disabled); }
static void writel(int value, char *reg) {}
static int readl(char *reg) { return 0; }
static void synchronize_irq(int irq) { irq_synced = true; }
static void netif_tx_disable(void *ndev)
{
    assert(napi_disabled && irq_synced);
    stopped = true;
}
""",
        "frost_quiesce",
        r"""
int main(void)
{
    char reg;
    struct frost_priv priv = { .base = &reg };
    stopped = true;
    frost_quiesce(&priv);
    assert(stopped);
    return 0;
}
""",
    )


def test_reset_timeout_detaches_the_page_pool_from_napi() -> None:
    """Pinned DMA allocations may outlive the netdev after an unrecoverable RESET timeout."""
    source = DRIVER_SOURCE.read_text()
    body = re.search(r"static void frost_reset_and_free\(.*?\n\}\n", source, re.S)
    assert body is not None
    text = body.group(0)
    timeout = text.index("priv->broken = true;")
    detach = text.index("page_pool_disable_direct_recycling(priv->rx_pool);", timeout)
    assert timeout < detach < text.index("netif_device_detach(ndev)", timeout)
    assert detach < text.index("return;", timeout)
