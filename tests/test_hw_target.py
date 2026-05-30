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

"""Tests for FPGA hardware target selection."""

import subprocess

import pytest

from fpga.common.hw_target import get_available_targets


def test_get_available_targets_reports_vivado_failure(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Report Vivado failures instead of treating them as an empty target list."""

    def fail_vivado(
        *args: object, **kwargs: object
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.CompletedProcess(args=[], returncode=1, stdout="", stderr="")

    monkeypatch.setattr(subprocess, "run", fail_vivado)

    with pytest.raises(subprocess.CalledProcessError):
        get_available_targets("vivado")
