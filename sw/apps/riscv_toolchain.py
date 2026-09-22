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

"""Locate the shared Bootlin compiler for container and native board builds."""

import os
from pathlib import Path
import shutil

DEFAULT_PREFIX = "riscv64-linux-"


def default_riscv_prefix(repository_root: Path) -> str:
    """Prefer PATH, then the checkout's existing Buildroot toolchain cache.

    Callers preserve an explicit RISCV_PREFIX before consulting this default.
    Returning the command prefix when neither installation exists lets Make
    report the missing compiler normally, without downloading a toolchain.
    """
    if shutil.which(f"{DEFAULT_PREFIX}gcc"):
        return DEFAULT_PREFIX
    cached_prefix = repository_root / "linux/build-mmu/host/bin" / DEFAULT_PREFIX
    compiler = Path(f"{cached_prefix}gcc")
    if compiler.is_file() and os.access(compiler, os.X_OK):
        return str(cached_prefix)
    return DEFAULT_PREFIX
