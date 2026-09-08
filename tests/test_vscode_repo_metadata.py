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

"""Trusted repository metadata discovery without builds or hardware access."""

import json
from pathlib import Path
import runpy
import subprocess
import sys
from typing import Any

import pytest

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "tools/vscode-frost/resources/repo_metadata.py"
MARKER = "FROST_REPOSITORY_METADATA="


def query_metadata(root: Path) -> dict[str, Any]:
    """Run the packaged helper in a fresh interpreter, as the extension does."""
    result = subprocess.run(
        [sys.executable, "-B", str(HELPER), str(root)],
        check=True,
        capture_output=True,
        text=True,
        timeout=10,
    )
    records = [line for line in result.stdout.splitlines() if line.startswith(MARKER)]
    assert len(records) == 1
    value = json.loads(records[0][len(MARKER) :])
    assert isinstance(value, dict)
    return value


def test_metadata_matches_current_loader_and_uart_default() -> None:
    """The UI sees the complete current loader registry, including Linux."""
    original_paths = sys.path.copy()
    try:
        loader = runpy.run_path(str(ROOT / "fpga/load_software/load_software.py"))
        defaults = runpy.run_path(str(ROOT / "fpga/common/hw_defaults.py"))
    finally:
        sys.path[:] = original_paths
    metadata = query_metadata(ROOT)
    assert metadata["apps"] == loader["VALID_APPS"]
    assert "linux_boot" in metadata["apps"]
    assert "uart_echo" in metadata["apps"]
    assert metadata["defaultSerial"] == defaults["DEFAULT_SERIALS"]["x3"]
    assert set(metadata["coremarkProApps"]) == set(loader["COREMARK_PRO_APP_NAMES"])
    assert set(metadata["ddrApps"]) == set(loader["DDR_APPS"])
    assert metadata["hasDdr"] == loader["BOARD_CONFIG"]["x3"]["has_ddr"]
    assert set(metadata["debugApps"]) == loader["DEBUG_APPS"]
    assert metadata["debugUnsupported"] == loader["DEBUG_UNSUPPORTED"]
    assert set(metadata["debugUnsupported"]) == {"linux_boot", "opensbi_smoke"}
    assert len(metadata["debugApps"]) == len(metadata["apps"]) - 2
    assert metadata["appBuildDirectories"] == {
        app: loader["app_build_directory_name"](app) for app in loader["VALID_APPS"]
    }
    assert metadata["appBuildDirectories"]["coremark_pro_core"] == "coremark_pro"


def test_registry_changes_are_discovered_without_running_cli(tmp_path: Path) -> None:
    """A new imported app/default reaches the UI with no fixed extension list."""
    scripts = tmp_path / "fpga/load_software"
    common = tmp_path / "fpga/common"
    apps = tmp_path / "sw/apps"
    for directory in (scripts, common, apps):
        directory.mkdir(parents=True)
    registry = apps / "software_registry.py"
    registry.write_text("APP_NAMES = ['new_fixture_app']\n")
    (common / "hw_defaults.py").write_text(
        "DEFAULT_SERIALS = {'x3': '/dev/tty-fixture'}\n"
    )
    (scripts / "load_software.py").write_text(
        "from pathlib import Path\n"
        "import sys\n"
        "sys.path.insert(0, str(Path(__file__).parents[2] / 'sw/apps'))\n"
        "from software_registry import APP_NAMES\n"
        "VALID_APPS = APP_NAMES\n"
        "COREMARK_PRO_APP_NAMES = ()\n"
        "DDR_APPS = set()\n"
        "DEBUG_APPS = frozenset(VALID_APPS)\n"
        "DEBUG_UNSUPPORTED = {}\n"
        "def app_build_directory_name(app):\n"
        "    return 'shared_fixture' if app.endswith('_alias') else app\n"
        "BOARD_CONFIG = {'x3': {'has_ddr': True}}\n"
        "print('harmless import diagnostic')\n"
        "if __name__ == '__main__':\n"
        "    raise RuntimeError('CLI/build/hardware execution is forbidden')\n"
    )
    assert query_metadata(tmp_path)["apps"] == ["new_fixture_app"]
    registry.write_text("APP_NAMES = ['another_fixture_alias', 'new_fixture_app']\n")
    metadata = query_metadata(tmp_path)
    assert metadata["apps"] == ["another_fixture_alias", "new_fixture_app"]
    assert metadata["debugApps"] == metadata["apps"]
    assert metadata["debugUnsupported"] == {}
    assert metadata["appBuildDirectories"] == {
        "another_fixture_alias": "shared_fixture",
        "new_fixture_app": "new_fixture_app",
    }
    assert metadata["defaultSerial"] == "/dev/tty-fixture"
    assert not list(tmp_path.rglob("__pycache__"))


@pytest.mark.parametrize(
    "override",
    [
        "DEBUG_APPS = {'missing_app'}",
        "DEBUG_UNSUPPORTED = {'fixture': 'composite image'}",
        "DEBUG_APPS = set()",
        "DEBUG_APPS = set(); DEBUG_UNSUPPORTED = {'fixture': ''}",
        "app_build_directory_name = None",
        "def app_build_directory_name(app): return '../outside'",
    ],
)
def test_invalid_debug_contract_is_rejected(tmp_path: Path, override: str) -> None:
    """An incomplete eligibility policy or unsafe build path cannot reach the UI."""
    loader_dir = tmp_path / "fpga/load_software"
    defaults_dir = tmp_path / "fpga/common"
    loader_dir.mkdir(parents=True)
    defaults_dir.mkdir(parents=True)
    (defaults_dir / "hw_defaults.py").write_text(
        "DEFAULT_SERIALS = {'x3': '/dev/tty-fixture'}\n"
    )
    (loader_dir / "load_software.py").write_text(
        "VALID_APPS = ['fixture']\n"
        "COREMARK_PRO_APP_NAMES = ()\n"
        "DDR_APPS = set()\n"
        "DEBUG_APPS = {'fixture'}\n"
        "DEBUG_UNSUPPORTED = {}\n"
        "BOARD_CONFIG = {'x3': {'has_ddr': True}}\n"
        "def app_build_directory_name(app): return app\n"
        f"{override}\n"
        "if __name__ == '__main__':\n"
        "    raise RuntimeError('CLI/build/hardware execution is forbidden')\n"
    )
    with pytest.raises(subprocess.CalledProcessError) as failure:
        query_metadata(tmp_path)
    assert "ValueError" in failure.value.stderr
    assert "execution is forbidden" not in failure.value.stderr
