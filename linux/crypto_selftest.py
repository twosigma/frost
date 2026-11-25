#!/usr/bin/env python3
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

"""Verify RISC-V Linux crypto self-tests for the running kernel version.

Linux 6.12 ships the RISC-V Zvk algorithms as loadable ``arch/riscv/crypto``
``*-riscv64`` modules alongside ``crc32_generic`` and ``crc32c_generic``.
Linux 7.3 consolidates RISC-V Zvk AES, SHA-2, GHASH, ChaCha, and Zbc CRC32
into ``lib/crypto`` and ``lib/crc``: AES modes and SHA-2 are built in as
``*-lib`` drivers, while ``chacha``, ``gcm``, ``crc32-cryptoapi``, and
``crc32c-cryptoapi`` are loadable modules (with ``gcm(aes)`` instantiated as
``gcm_base(ctr-aes-lib,ghash-lib)`` via ``tcrypt mode=35``).
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import json
import os
from pathlib import Path
import re
import subprocess
import sys

KERNEL_RELEASE_RE = re.compile(r"^([0-9]+)\.([0-9]+)(?:[.\-+~].*)?$")

DMESG_FAILURE_RE = re.compile(
    r"alg:.*failed|self-test.*fail|illegal instruction|\bOops\b|\bBUG:|Kernel panic",
    re.IGNORECASE,
)

# Linux < 6.18 (Debian 13 6.12): arch/riscv/crypto modules + generic CRC32.
CRYPTO_MODULES_ARCH_RISCV: tuple[str, ...] = (
    "aes-riscv64",
    "chacha-riscv64",
    "ghash-riscv64",
    "sha256-riscv64",
    "sha512-riscv64",
    "gcm",
    "crc32_generic",
    "crc32c_generic",
)

CRYPTO_DRIVERS_ARCH_RISCV: tuple[str, ...] = (
    "aes-riscv64-zvkned",
    "ecb-aes-riscv64-zvkned",
    "cbc-aes-riscv64-zvkned",
    "cts-cbc-aes-riscv64-zvkned",
    "ctr-aes-riscv64-zvkned-zvkb",
    "xts-aes-riscv64-zvkned-zvbb-zvkg",
    "chacha20-riscv64-zvkb",
    "ghash-riscv64-zvkg",
    "sha224-riscv64-zvknha_or_zvknhb-zvkb",
    "sha256-riscv64-zvknha_or_zvknhb-zvkb",
    "sha384-riscv64-zvknhb-zvkb",
    "sha512-riscv64-zvknhb-zvkb",
    "crc32-generic",
    "crc32c-generic",
)

# Linux >= 7.3 (Debian 13 trixie-backports 7.3): built-in lib/crypto AES/SHA-2
# + loadable chacha, gcm (instantiated via tcrypt mode=35), crc32*-cryptoapi.
CRYPTO_MODULES_LIB_CRYPTO: tuple[str, ...] = (
    "chacha",
    "gcm",
    "crc32-cryptoapi",
    "crc32c-cryptoapi",
)

CRYPTO_DRIVERS_LIB_CRYPTO: tuple[str, ...] = (
    "aes-lib",
    "ecb-aes-lib",
    "cbc-aes-lib",
    "cts-cbc-aes-lib",
    "ctr-aes-lib",
    "xts-aes-lib",
    "sha224-lib",
    "sha256-lib",
    "sha384-lib",
    "sha512-lib",
    "chacha20-lib",
    "xchacha20-lib",
    "xchacha12-lib",
    "gcm_base(ctr-aes-lib,ghash-lib)",
    "crc32-lib",
    "crc32c-lib",
)


@dataclass(frozen=True)
class CryptoSpec:
    """Expected modules and ``/proc/crypto`` drivers for one kernel release."""

    layout: str
    modules: tuple[str, ...]
    tcrypt_modes: tuple[int, ...]
    required_drivers: tuple[str, ...]


def parse_kernel_release(release: str) -> tuple[int, int]:
    """Parse ``<major>.<minor>`` from a Linux ``uname -r`` release string."""
    match = KERNEL_RELEASE_RE.match(release.strip())
    if not match:
        raise ValueError(f"invalid kernel release string: {release!r}")
    return int(match.group(1)), int(match.group(2))


def crypto_spec_for_release(release: str) -> CryptoSpec:
    """Return the kernel-version-specific crypto module and driver set."""
    version = parse_kernel_release(release)
    if version >= (7, 3):
        return CryptoSpec(
            layout="lib/crypto",
            modules=CRYPTO_MODULES_LIB_CRYPTO,
            tcrypt_modes=(35,),
            required_drivers=CRYPTO_DRIVERS_LIB_CRYPTO,
        )
    if version < (6, 18):
        return CryptoSpec(
            layout="arch/riscv/crypto",
            modules=CRYPTO_MODULES_ARCH_RISCV,
            tcrypt_modes=(),
            required_drivers=CRYPTO_DRIVERS_ARCH_RISCV,
        )
    raise ValueError(
        f"unsupported intermediate crypto layout for kernel {release!r}; "
        "expected < 6.18 (arch/riscv/crypto) or >= 7.3 (lib/crypto)"
    )


def parse_proc_crypto(text: str) -> dict[str, list[dict[str, str]]]:
    """Parse ``/proc/crypto`` into stanzas grouped by ``driver`` name."""
    drivers: dict[str, list[dict[str, str]]] = {}
    cleaned = text.replace("\r\n", "\n").replace("\r", "\n")
    for block in re.split(r"\n{2,}", cleaned.strip()):
        kv: dict[str, str] = {}
        for line in block.splitlines():
            if ":" in line:
                key, val = line.split(":", 1)
                kv[key.strip()] = val.strip()
        if "driver" in kv:
            drivers.setdefault(kv["driver"], []).append(kv)
    return drivers


def verify_crypto_selftests(
    release: str,
    proc_crypto: str,
    dmesg: str = "",
) -> dict[str, object]:
    """Validate ``/proc/crypto`` and ``dmesg`` for ``release``.

    Every required driver for the running kernel's layout must be present and
    report ``selftest: passed``, no stanza in ``/proc/crypto`` may report
    ``failed`` or ``testing``, and ``dmesg`` must contain no crypto self-test
    or fatal kernel failure.
    """
    spec = crypto_spec_for_release(release)
    drivers = parse_proc_crypto(proc_crypto)

    missing = [drv for drv in spec.required_drivers if drv not in drivers]
    if missing:
        raise ValueError(
            f"missing {spec.layout} crypto drivers for {release}: {missing}"
        )

    bad_required: dict[str, list[str]] = {}
    for drv in spec.required_drivers:
        statuses = [entry.get("selftest", "") for entry in drivers[drv]]
        if not statuses or any(status != "passed" for status in statuses):
            bad_required[drv] = statuses
    if bad_required:
        raise ValueError(
            f"{spec.layout} crypto drivers failed selftest for {release}: "
            f"{bad_required}"
        )

    bad_global: dict[str, list[str]] = {}
    for drv, entries in sorted(drivers.items()):
        bad_states = [
            entry.get("selftest", "")
            for entry in entries
            if entry.get("selftest", "") not in ("passed", "unknown")
        ]
        if bad_states:
            bad_global[drv] = bad_states
    if bad_global:
        raise ValueError(
            f"/proc/crypto contains non-passed self-tests for {release}: {bad_global}"
        )

    bad_dmesg = [line for line in dmesg.splitlines() if DMESG_FAILURE_RE.search(line)]
    if bad_dmesg:
        raise ValueError(
            f"kernel dmesg reported crypto or fatal failure for {release}: "
            f"{bad_dmesg[:5]}"
        )

    return {
        "release": release,
        "layout": spec.layout,
        "passed": len(spec.required_drivers),
        "expected": len(spec.required_drivers),
        "drivers": list(spec.required_drivers),
        "dmesg_failures": 0,
    }


def guest_load_script() -> str:
    """Return a POSIX shell snippet that loads the running kernel's crypto set."""
    mods_old = " ".join(CRYPTO_MODULES_ARCH_RISCV)
    mods_lib = " ".join(CRYPTO_MODULES_LIB_CRYPTO)
    return (
        "KREL=$(uname -r)\n"
        'echo "CRYPTO_KERNEL_RELEASE=$KREL"\n'
        'KMAJ=$(printf "%s" "$KREL" | cut -d. -f1)\n'
        'KMIN=$(printf "%s" "$KREL" | cut -d. -f2 | sed "s/[^0-9].*$//")\n'
        'if [ "$KMAJ" -gt 7 ] || { [ "$KMAJ" -eq 7 ] && [ "$KMIN" -ge 3 ]; }; then\n'
        f'  for m in {mods_lib}; do modprobe -v "$m" || st=1; done\n'
        "  # tcrypt returns -EAGAIN after running the requested mode.\n"
        "  modprobe -v tcrypt mode=35 || true\n"
        'elif [ "$KMAJ" -lt 6 ] || { [ "$KMAJ" -eq 6 ] && [ "$KMIN" -lt 18 ]; }; then\n'
        f'  for m in {mods_old}; do modprobe -v "$m" || st=1; done\n'
        "else\n"
        '  echo "CRYPTO_UNSUPPORTED_KERNEL=$KREL"\n'
        "  st=1\n"
        "fi\n"
        "for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do\n"
        '  grep -q "selftest[[:space:]]*:[[:space:]]*testing" /proc/crypto || break\n'
        "  sleep 2\n"
        "done\n"
    )


def _cmd_check(args: argparse.Namespace) -> int:
    if args.live:
        release = os.uname().release
        proc_crypto = Path("/proc/crypto").read_text(encoding="utf-8", errors="replace")
        dmesg_proc = subprocess.run(
            ["dmesg"], capture_output=True, text=True, check=False, timeout=30
        )
        dmesg = dmesg_proc.stdout
    else:
        if not args.release or not args.proc_crypto:
            raise SystemExit("--release and --proc-crypto are required without --live")
        release = args.release
        proc_crypto = Path(args.proc_crypto).read_text(
            encoding="utf-8", errors="replace"
        )
        dmesg = (
            Path(args.dmesg).read_text(encoding="utf-8", errors="replace")
            if args.dmesg
            else ""
        )
    result = verify_crypto_selftests(release, proc_crypto, dmesg)
    print(json.dumps(result, indent=2))
    return 0


def main(argv: list[str] | None = None) -> int:
    """CLI entry point for crypto self-test checks and guest script generation."""
    parser = argparse.ArgumentParser(
        description="Verify RISC-V Linux crypto self-tests for the running kernel."
    )
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_check = sub.add_parser("check", help="Validate /proc/crypto and dmesg")
    p_check.add_argument("--live", action="store_true", help="Read live system state")
    p_check.add_argument("--release", help="Kernel release (uname -r)")
    p_check.add_argument("--proc-crypto", help="Path to captured /proc/crypto")
    p_check.add_argument("--dmesg", help="Optional path to captured dmesg")
    p_check.set_defaults(func=_cmd_check)

    p_script = sub.add_parser(
        "guest-script", help="Print POSIX shell snippet for loading crypto modules"
    )
    p_script.set_defaults(func=lambda _a: (sys.stdout.write(guest_load_script()), 0)[1])

    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except ValueError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
