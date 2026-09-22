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

"""Fetch the pinned Debian RISC-V kernel and build its FROST NIC module.

Produces a flat Linux Image and a module matched to its Debian headers; the
initramfs command adds the module and startup script to the test image.
Host kbuild tools drive the riscv64 headers using the Linux cross compiler.

Cache entries are immutable and keyed by input digest. Builders hold an
exclusive lock, stage work privately, and publish by rename. Manifests validate
reuse; incomplete entries rebuild. Old entries remain for concurrent readers.
``FROST_DEBIAN_KERNEL_CACHE`` changes the default ``linux/debian-kernel`` path;
``FROST_NET10G_MODULE`` selects a prebuilt module.

Commands: fetch, release, image, module, initramfs. Results go to stdout and
progress to stderr. See ``linux/README.md`` and ``--help``.
"""

import argparse
import contextlib
import fcntl
import hashlib
import io
import os
import re
import shutil
import struct
import subprocess
import sys
import tarfile
import urllib.parse
import urllib.request
import uuid
from collections.abc import Iterator
from dataclasses import dataclass
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent


def log(message: str) -> None:
    """Report progress on stderr, leaving stdout for the answer."""
    print(f"debian_kernel: {message}", file=sys.stderr, flush=True)


def run_logged(command: list[str], env: dict[str, str] | None = None) -> None:
    """Run a child with its stdout redirected to ours, so stdout stays the answer.

    kbuild and strip talk on stdout, and a caller that captures ours wants only
    the path it asked for.
    """
    sys.stderr.flush()
    try:
        stream: int | None = sys.stderr.fileno()
    except (AttributeError, OSError, io.UnsupportedOperation):
        stream = None
    if stream is not None:
        subprocess.run(command, check=True, env=env, stdout=stream)
        return
    # A caller replaced stderr with something that has no file descriptor (a
    # test harness): collect the child's output and forward it afterwards.
    done = subprocess.run(command, check=True, env=env, capture_output=True, text=True)
    sys.stderr.write(done.stdout)
    sys.stderr.write(done.stderr)


# --- The pin ----------------------------------------------------------------
# One snapshot.debian.org timestamp and one source version pin every package
# below, so the kernel cannot move underneath a build. This is the kernel the
# X3 board runs from its Debian NFS root; ../docs/debian_nfsroot.md installs
# the same version there.
SNAPSHOT = "20260907T023910Z"
SNAPSHOT_BASE = (
    f"https://snapshot.debian.org/archive/debian/{SNAPSHOT}/pool/main/l/linux"
)
# Debian's source version, the .deb filename's middle field.
SOURCE_VERSION = "6.12.107-1"
# uname -r of the packaged kernel: the vermagic the module must match and the
# /lib/modules directory name. It is also the banner the boot must print.
KERNEL_RELEASE = "6.12.107+deb13-riscv64"
# The kernel prints "Linux version <release> (<builder>) ...", so the trailing
# space is part of the marker: without it the check also passes for a release
# this one is a prefix of, such as 6.12.107+deb13-riscv64-debug.
KERNEL_BANNER = f"Linux version {KERNEL_RELEASE} "
# The linux-headers/linux-kbuild trees are named after the ABI, the release
# without the architecture suffix.
KERNEL_ABI = "6.12.107+deb13"


@dataclass(frozen=True)
class DebianPackage:
    """One pinned .deb: its name, architecture, size and sha256."""

    name: str
    arch: str
    size: int
    sha256: str
    # Members to extract, by path prefix inside the package (Debian's own
    # layout, which the extracted tree keeps). Everything else is skipped:
    # linux-image alone carries ~100 MiB of modules FROST never loads.
    members: tuple[str, ...]

    @property
    def filename(self) -> str:
        """Return the .deb file name, as the pool directory spells it."""
        return f"{self.name}_{SOURCE_VERSION}_{self.arch}.deb"

    @property
    def url(self) -> str:
        """Return the snapshot.debian.org URL of this .deb."""
        return f"{SNAPSHOT_BASE}/{urllib.parse.quote(self.filename)}"


# The kernel itself. Only boot/ is kept: the flat Image FROST packs and the
# configuration it was built with, for reference.
KERNEL_PACKAGE = DebianPackage(
    name=f"linux-image-{KERNEL_RELEASE}",
    arch="riscv64",
    size=112_012_420,
    sha256="abe9f65d74b434692149482b031db7a2aaf832921e09f69f775293c0e0c5799c",
    members=(f"boot/vmlinux-{KERNEL_RELEASE}", f"boot/config-{KERNEL_RELEASE}"),
)

# The module build's inputs. linux-headers-<abi>-common holds the kernel's own
# Makefile and headers; linux-headers-<release> the architecture half plus
# .config, Module.symvers and the generated headers; linux-kbuild the host
# tools (fixdep, modpost, genksyms), which are host binaries, so the amd64
# build of that package drives the riscv64 headers tree.
#
# The headers tree's ``vmlinux`` is deliberately left out: it is only the BTF
# base for CONFIG_DEBUG_INFO_BTF_MODULES, and without it kbuild skips module
# BTF generation with a message instead of demanding pahole, which the FROST
# image does not ship (an out-of-tree module gains nothing from BTF).
HEADER_PACKAGES = (
    DebianPackage(
        name=f"linux-headers-{KERNEL_ABI}-common",
        arch="all",
        size=11_214_736,
        sha256="12dc292d7c238928fbcb7eebbe79208758fe263a4e2ea0e9b6734e6df12020a5",
        members=(f"usr/src/linux-headers-{KERNEL_ABI}-common/",),
    ),
    DebianPackage(
        name=f"linux-headers-{KERNEL_RELEASE}",
        arch="riscv64",
        size=2_880_864,
        sha256="aac824a77f6e91407f5fe0b592a491b026ec7fe4cbb4c053a2f9afeed3981445",
        members=(
            f"usr/src/linux-headers-{KERNEL_RELEASE}/.config",
            f"usr/src/linux-headers-{KERNEL_RELEASE}/.kernelvariables",
            f"usr/src/linux-headers-{KERNEL_RELEASE}/Makefile",
            f"usr/src/linux-headers-{KERNEL_RELEASE}/Module.symvers",
            f"usr/src/linux-headers-{KERNEL_RELEASE}/arch/",
            f"usr/src/linux-headers-{KERNEL_RELEASE}/include/",
            f"usr/src/linux-headers-{KERNEL_RELEASE}/scripts",
            f"usr/src/linux-headers-{KERNEL_RELEASE}/tools",
        ),
    ),
    DebianPackage(
        name=f"linux-kbuild-{KERNEL_ABI}",
        arch="amd64",
        size=1_797_128,
        sha256="0a88527eb05bca1ce75e7d39ec27539d385a24cf90b2b28917cc4903a4f710d3",
        members=(f"usr/lib/linux-kbuild-{KERNEL_ABI}/",),
    ),
)

PACKAGES = (KERNEL_PACKAGE, *HEADER_PACKAGES)

# --- Cache layout -----------------------------------------------------------
# Inside the checkout, like Buildroot's linux/dl and linux/ccache, so the
# container (which mounts only the checkout) and native tools share one cache.
DEFAULT_CACHE = REPO_ROOT / "linux" / "debian-kernel"
CACHE_ENV = "FROST_DEBIAN_KERNEL_CACHE"
# Bumped whenever the extraction, its fixups or the cache layout change, so an
# older cache is re-extracted under a new name rather than reused.
EXTRACT_VERSION = 2
# How much of each digest names a directory: enough that a collision is not a
# practical concern, short enough to read.
KEY_LENGTH = 16

# --- The module build -------------------------------------------------------
DRIVER_DIR = REPO_ROOT / "linux" / "frost-net10g"
MODULE_NAME = "frost_net10g"
# Debian's .kernelvariables overrides CROSS_COMPILE to this prefix, so the
# module build answers to it with wrapper scripts around whatever riscv64
# Linux-target toolchain is installed (FROST_LINUX_CROSS_COMPILE).
DEBIAN_CROSS_COMPILE = "riscv64-linux-gnu-"
CROSS_ENV = "FROST_LINUX_CROSS_COMPILE"
DEFAULT_CROSS = "riscv64-linux-"
# Bumped when the wrapper set or the build command changes.
BUILD_VERSION = 1
# A module built elsewhere, for a tree that cannot build one (no headers, no
# cross toolchain). It must be the module for KERNEL_RELEASE; unlike one built
# here it is taken on trust, since verifying it needs the headers tree.
MODULE_ENV = "FROST_NET10G_MODULE"

# The initramfs tokens the boot prints, asserted by fpga/hw_regression.py's
# Linux stage, fpga/linux_boot_soak.py and CI's QEMU boot job. The script
# compares ``uname -r`` with the pinned release itself: the pin sets
# CONFIG_MODVERSIONS, and with symbol CRCs present Linux skips the release
# field of vermagic, so a successful insmod alone does not identify the kernel.
MODULE_PASS_TOKEN = "FROST_NET10G_MODULE_PASS"
MODULE_FAIL_TOKEN = "FROST_NET10G_MODULE_FAIL"
# The exact line a healthy boot prints, which the gates require, and the pattern
# that requires it exactly: without the boundary a longer release would satisfy
# it, since this line is a prefix of that one.
MODULE_PASS_LINE = f"{MODULE_PASS_TOKEN} {KERNEL_RELEASE}"
MODULE_PASS_RE = re.compile(re.escape(MODULE_PASS_LINE) + r"(?![\w.+-])")
# Runs from Buildroot's /etc/init.d/rcS, which the overlay inittab invokes as a
# sysinit entry, so the module is loaded before the getty and before any
# network test. S03 puts it after the stock S01/S02 scripts.
MODULE_INIT_SCRIPT = "etc/init.d/S03frost-net10g"

# The counter line's token, and the program in the base archive that prints it.
# Its presence is how a current test userspace is recognized: an archive built
# before the counter mode existed boots happily and reports no counters at all,
# quietly costing the board soak the counter evidence it scores. Composing an
# initramfs from such a base is refused instead. The hardware regression types
# the same token's command, but on the Debian NFS root it boots, from a build of
# the same source installed there (fpga/hw_regression.py).
INITRAMFS_COUNTER_TOKEN = "FROST_COUNTERS"
INITRAMFS_COUNTER_PROGRAM = "usr/bin/frost_stress"
# Buildroot does not notice an edited package source on its own.
FROST_STRESS_REBUILD = (
    "make -C linux/buildroot O=<build dir> frost-stress-rebuild && "
    "make -C linux/buildroot O=<build dir>"
)


def cache_dir(cache: Path | str | None = None) -> Path:
    """Return the cache directory: the argument, the environment, or default."""
    if cache is not None:
        return Path(cache).resolve()
    from_env = os.environ.get(CACHE_ENV, "")
    return Path(from_env).resolve() if from_env else DEFAULT_CACHE


@contextlib.contextmanager
def cache_lock(cache: Path | str | None = None) -> Iterator[None]:
    """Hold the cache's exclusive lock for the duration of a mutation.

    Consumers do not take it: they read directories that are published whole,
    under a name that already accounts for their inputs. It serializes the
    builders, so two of them neither repeat the work nor remove each other's
    staging.
    """
    directory = cache_dir(cache)
    directory.mkdir(parents=True, exist_ok=True)
    with (directory / ".lock").open("w") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        yield


def staging_dir(cache: Path | str | None = None) -> Path:
    """Return a fresh private directory to build a cache entry in."""
    staging = cache_dir(cache) / "staging" / f"{os.getpid()}-{uuid.uuid4().hex[:8]}"
    staging.mkdir(parents=True)
    return staging


def publish(staged: Path, final: Path) -> Path:
    """Move a finished staging directory into place with one rename.

    A reader therefore sees either nothing or the whole entry. Losing the race
    to another builder is not an error: its entry has the same inputs, so it is
    the same entry, and ours is discarded.
    """
    try:
        staged.rename(final)
    except OSError:
        shutil.rmtree(staged, ignore_errors=True)
    return final


def pin_digest() -> str:
    """Return a digest of the pin, so a changed pin names a new cache entry."""
    parts = [str(EXTRACT_VERSION), SNAPSHOT, SOURCE_VERSION, KERNEL_RELEASE]
    parts += [f"{p.filename}:{p.sha256}:{'|'.join(p.members)}" for p in PACKAGES]
    return hashlib.sha256("\n".join(parts).encode()).hexdigest()[:KEY_LENGTH]


def sysroot(cache: Path | str | None = None) -> Path:
    """Return the directory the packages extract into, keeping Debian's paths."""
    return cache_dir(cache) / f"sysroot-{pin_digest()}"


def kernel_image(cache: Path | str | None = None) -> Path:
    """Return the path of the flat kernel ``Image`` inside the cache."""
    return sysroot(cache) / "boot" / f"vmlinux-{KERNEL_RELEASE}"


def kernel_build_dir(cache: Path | str | None = None) -> Path:
    """Return the headers tree a module build runs ``make -C`` against."""
    return sysroot(cache) / "usr" / "src" / f"linux-headers-{KERNEL_RELEASE}"


def symvers(cache: Path | str | None = None) -> Path:
    """Return the pinned kernel's exported-symbol versions."""
    return kernel_build_dir(cache) / "Module.symvers"


# The files a usable extraction must have, and what the manifest records their
# sizes under. A truncated or partly deleted entry fails this and is rebuilt.
MANIFEST_NAME = ".frost-manifest"


def required_files(root: Path) -> dict[str, Path]:
    """Return the paths a complete extraction must hold, keyed by a short name."""
    headers = root / "usr" / "src" / f"linux-headers-{KERNEL_RELEASE}"
    kbuild = root / "usr" / "lib" / f"linux-kbuild-{KERNEL_ABI}"
    return {
        "image": root / "boot" / f"vmlinux-{KERNEL_RELEASE}",
        "config": root / "boot" / f"config-{KERNEL_RELEASE}",
        "headers-makefile": headers / "Makefile",
        "headers-config": headers / ".config",
        "symvers": headers / "Module.symvers",
        "common-makefile": (
            root / "usr" / "src" / f"linux-headers-{KERNEL_ABI}-common" / "Makefile"
        ),
        "fixdep": kbuild / "scripts" / "basic" / "fixdep",
        "modpost": kbuild / "scripts" / "mod" / "modpost",
    }


def write_manifest(root: Path) -> None:
    """Record the size of every required file, for validation on reuse."""
    lines = [
        f"{name} {path.stat().st_size}"
        for name, path in sorted(required_files(root).items())
    ]
    (root / MANIFEST_NAME).write_text("\n".join(lines) + "\n")


def manifest_holds(root: Path) -> bool:
    """Return True when every required file is present at its recorded size."""
    manifest = root / MANIFEST_NAME
    if not manifest.exists():
        return False
    recorded = dict(
        line.split(" ", 1) for line in manifest.read_text().splitlines() if line
    )
    paths = required_files(root)
    if set(recorded) != set(paths):
        return False
    for name, path in paths.items():
        if not path.exists() or str(path.stat().st_size) != recorded[name]:
            return False
    return True


def download(package: DebianPackage, dl_dir: Path) -> Path:
    """Return the cached .deb, downloading and checking it when absent.

    A file of the pinned size and sha256 is reused. The download streams into a
    per-process temporary and is published with one rename, so a second builder
    (or an interrupted one) can neither see nor truncate a partial file.
    """
    dl_dir.mkdir(parents=True, exist_ok=True)
    path = dl_dir / package.filename
    if path.exists() and path.stat().st_size == package.size:
        if file_digest(path) == package.sha256:
            return path
    log(f"fetching {package.filename}")
    temporary = dl_dir / f".{package.filename}.{os.getpid()}.{uuid.uuid4().hex[:8]}"
    digest = hashlib.sha256()
    size = 0
    try:
        with urllib.request.urlopen(package.url, timeout=120) as response:
            with temporary.open("wb") as out:
                while chunk := response.read(1 << 20):
                    digest.update(chunk)
                    size += len(chunk)
                    out.write(chunk)
        if size != package.size or digest.hexdigest() != package.sha256:
            raise RuntimeError(
                f"{package.url}: expected {package.size} bytes sha256 "
                f"{package.sha256}, got {size} bytes sha256 {digest.hexdigest()}"
            )
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)
    return path


def file_digest(path: Path) -> str:
    """Return a file's sha256, read in chunks rather than all at once."""
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1 << 20):
            digest.update(chunk)
    return digest.hexdigest()


def deb_data_tar(deb: Path) -> bytes:
    """Return the data.tar member of a .deb (an ar archive) as bytes.

    Reads the ar format directly: the image ships no dpkg-deb-independent
    extractor, and tarfile handles the xz compression natively.
    """
    with deb.open("rb") as handle:
        if handle.read(8) != b"!<arch>\n":
            raise RuntimeError(f"{deb}: not an ar archive")
        while True:
            header = handle.read(60)
            if len(header) < 60:
                raise RuntimeError(f"{deb}: no data.tar member")
            name = header[0:16].decode("ascii").strip().rstrip("/")
            size = int(header[48:58].decode("ascii").strip())
            payload = handle.read(size)
            if size % 2:
                handle.read(1)
            if name.startswith("data.tar"):
                return payload


def extract(package: DebianPackage, deb: Path, destination: Path) -> int:
    """Extract the package's wanted members into destination; return the count.

    Members are selected by the prefixes in ``package.members``: a prefix
    ending in ``/`` takes the whole subtree, any other names one file or
    symlink.
    """
    wanted = 0
    with tarfile.open(fileobj=io.BytesIO(deb_data_tar(deb)), mode="r:*") as tar:
        for member in tar:
            name = member.name.removeprefix("./").lstrip("/")
            if not any(
                name.startswith(prefix) if prefix.endswith("/") else name == prefix
                for prefix in package.members
            ):
                continue
            member.name = name
            tar.extract(member, destination, filter="tar")
            wanted += 1
    if wanted == 0:
        raise RuntimeError(f"{deb}: none of {package.members} is in the package")
    return wanted


def fix_headers_tree(root: Path) -> None:
    """Make the extracted headers tree buildable outside /usr/src.

    Debian's architecture Makefile includes the common tree by absolute path,
    which only resolves when the packages are installed. Rewrite it relative to
    itself; the tree's ``scripts`` and ``tools`` symlinks into linux-kbuild are
    already relative and resolve inside the extracted sysroot.
    """
    arch_makefile = (
        root / "usr" / "src" / f"linux-headers-{KERNEL_RELEASE}" / "Makefile"
    )
    absolute = f"/usr/src/linux-headers-{KERNEL_ABI}-common/Makefile"
    text = arch_makefile.read_text()
    if absolute not in text:
        raise RuntimeError(
            f"{arch_makefile}: expected an include of {absolute}; the packaging "
            "changed, so re-check this fixup against the new layout"
        )
    relative = (
        "$(dir $(lastword $(MAKEFILE_LIST)))"
        f"../linux-headers-{KERNEL_ABI}-common/Makefile"
    )
    arch_makefile.write_text(
        "# Rewritten by linux/debian_kernel.py: Debian's own line includes the\n"
        "# common tree by absolute path, which only resolves once the packages\n"
        "# are installed under /usr/src.\n"
        f"include {relative}\n"
    )
    # A changed cross prefix would silently build the module with the host
    # compiler, so fail loudly instead.
    variables = (
        root / "usr" / "src" / f"linux-headers-{KERNEL_RELEASE}" / ".kernelvariables"
    )
    if f"CROSS_COMPILE = {DEBIAN_CROSS_COMPILE}" not in variables.read_text():
        raise RuntimeError(
            f"{variables}: no 'CROSS_COMPILE = {DEBIAN_CROSS_COMPILE}'; update "
            "DEBIAN_CROSS_COMPILE in linux/debian_kernel.py to the new prefix"
        )


def fetch(cache: Path | str | None = None, dl_dir: Path | None = None) -> Path:
    """Download, verify and extract every pinned package; return the sysroot.

    A published extraction that still matches its manifest is reused, so this is
    cheap to call before every pack. One that does not (truncated, partly
    deleted) is replaced under the lock.
    """
    root = sysroot(cache)
    if manifest_holds(root):
        return root
    with cache_lock(cache):
        if manifest_holds(root):  # another builder finished while we waited
            return root
        if root.exists():
            log(f"{root.name} is incomplete; extracting it again")
            shutil.rmtree(root)
        downloads = dl_dir if dl_dir is not None else cache_dir(cache) / "dl"
        debs = [(package, download(package, downloads)) for package in PACKAGES]
        staging = staging_dir(cache)
        try:
            staged = staging / root.name
            staged.mkdir()
            for package, deb in debs:
                extract(package, deb, staged)
            fix_headers_tree(staged)
            write_manifest(staged)
            publish(staged, root)
        finally:
            shutil.rmtree(staging, ignore_errors=True)
    if not manifest_holds(root):
        raise RuntimeError(f"{root}: extraction did not produce a complete tree")
    log(f"{KERNEL_RELEASE} extracted into {root}")
    return root


def cross_prefix(cross: str | None = None) -> str:
    """Return the riscv64 Linux-target cross prefix to build the module with."""
    return cross or os.environ.get(CROSS_ENV) or DEFAULT_CROSS


def toolchain_identity(cross: str | None = None) -> tuple[Path, str]:
    """Return the resolved compiler and a string that identifies it.

    The identity is what the cache keys the wrappers and the module objects on:
    kbuild records the compiler by Debian's ``riscv64-linux-gnu-gcc`` name, so
    nothing in a build directory changes when the toolchain behind that name
    does, and stale objects would survive.
    """
    prefix = cross_prefix(cross)
    resolved = shutil.which(f"{prefix}gcc")
    if resolved is None:
        raise RuntimeError(
            f"{prefix}gcc is not on PATH: the module needs a riscv64 "
            f"Linux-target cross toolchain (the frost image ships one; set "
            f"{CROSS_ENV} or --cross for another)"
        )
    # Not resolve(): a Bootlin or Buildroot toolchain's gcc is a link to one
    # generic wrapper that decides what to run from its own name, so following
    # the link and invoking the target turns every tool into the same tool.
    compiler = Path(resolved)
    version = subprocess.run(
        [str(compiler), "--version"], capture_output=True, text=True, check=True
    ).stdout.splitlines()[0]
    machine = subprocess.run(
        [str(compiler), "-dumpmachine"], capture_output=True, text=True, check=True
    ).stdout.strip()
    identity = "\n".join([str(BUILD_VERSION), str(compiler), version, machine])
    return compiler, identity


def toolchain_bin(cache: Path | str | None = None, cross: str | None = None) -> Path:
    """Publish wrappers that answer to Debian's cross prefix; return their dir.

    Debian's headers tree hard-overrides ``CROSS_COMPILE`` to
    ``riscv64-linux-gnu-``, so the tools it invokes must exist under that name.
    These are wrapper scripts rather than symlinks because the toolchain's gcc
    is itself a wrapper that finds its real binary from its own name. The
    directory is named after the toolchain, so two builders with different
    toolchains get one each instead of overwriting a shared directory.
    """
    compiler, identity = toolchain_identity(cross)
    key = hashlib.sha256(identity.encode()).hexdigest()[:KEY_LENGTH]
    out = cache_dir(cache) / f"toolchain-{key}"
    marker = out / ".complete"
    if marker.exists():
        return out
    prefix = cross_prefix(cross)
    # The prefix may be absolute (Buildroot's post-image hook passes
    # $HOST_DIR/bin/riscv64-linux-); only its last component names the tools.
    base = Path(prefix).name
    tool_dir = compiler.parent
    with cache_lock(cache):
        if marker.exists():
            return out
        staging = staging_dir(cache)
        try:
            staged = staging / out.name
            staged.mkdir()
            for tool in sorted(tool_dir.glob(f"{base}*")):
                if not tool.is_file() or not os.access(tool, os.X_OK):
                    continue
                wrapper = staged / f"{DEBIAN_CROSS_COMPILE}{tool.name[len(base) :]}"
                wrapper.write_text(f'#!/bin/sh\nexec "{tool}" "$@"\n')
                wrapper.chmod(0o755)
            if not (staged / f"{DEBIAN_CROSS_COMPILE}objcopy").exists():
                raise RuntimeError(
                    f"{tool_dir}: no {base}objcopy; the module's metadata cannot "
                    "be verified without it"
                )
            (staged / ".complete").write_text(identity + "\n")
            publish(staged, out)
        finally:
            shutil.rmtree(staging, ignore_errors=True)
    return out


def module_dir(cache: Path | str | None = None, cross: str | None = None) -> Path:
    """Return the build directory for this pin and this toolchain.

    Keying it on both is what keeps kbuild honest: it records the compiler by
    name and the headers by path, so neither a swapped toolchain behind that
    name nor a re-extracted tree at the same path would otherwise invalidate
    the objects.
    """
    _, identity = toolchain_identity(cross)
    key = hashlib.sha256(f"{pin_digest()}\n{identity}".encode()).hexdigest()
    return cache_dir(cache) / f"module-{key[:KEY_LENGTH]}"


def module_path(cache: Path | str | None = None, cross: str | None = None) -> Path:
    """Return the path of the built NIC module inside the cache."""
    return module_dir(cache, cross) / f"{MODULE_NAME}.ko"


def elf_section(module: Path, section: str, objcopy: str) -> bytes:
    """Return one section of an ELF object as raw bytes."""
    out = module.parent / f".{module.name}.{section.strip('.')}.bin"
    subprocess.run(
        [objcopy, "-O", "binary", f"--only-section={section}", str(module), str(out)],
        check=True,
        capture_output=True,
    )
    try:
        return out.read_bytes()
    finally:
        out.unlink(missing_ok=True)


def module_info(module: Path, objcopy: str) -> dict[str, list[str]]:
    """Return the module's .modinfo key/value pairs, values grouped by key."""
    fields: dict[str, list[str]] = {}
    for entry in elf_section(module, ".modinfo", objcopy).split(b"\0"):
        if not entry:
            continue
        key, _, value = entry.decode().partition("=")
        fields.setdefault(key, []).append(value)
    return fields


# struct modversion_info: an unsigned long CRC then a 56-byte name, one per
# symbol the module imports (kernel/module.h, MODULE_NAME_LEN).
MODVERSION_ENTRY = 64


def module_symbol_crcs(module: Path, objcopy: str) -> dict[str, int]:
    """Return the CRC the module recorded for every symbol it imports."""
    blob = elf_section(module, "__versions", objcopy)
    if not blob or len(blob) % MODVERSION_ENTRY:
        raise RuntimeError(
            f"{module}: __versions is {len(blob)} bytes, not a whole number of "
            f"{MODVERSION_ENTRY}-byte entries; the pin sets CONFIG_MODVERSIONS, "
            "so the module must carry symbol CRCs"
        )
    crcs = {}
    for offset in range(0, len(blob), MODVERSION_ENTRY):
        (crc,) = struct.unpack_from("<Q", blob, offset)
        name = blob[offset + 8 : offset + MODVERSION_ENTRY].split(b"\0")[0].decode()
        crcs[name] = crc
    return crcs


def kernel_symbol_crcs(path: Path) -> dict[str, int]:
    """Return the exported-symbol CRCs of Module.symvers."""
    crcs = {}
    for line in path.read_text().splitlines():
        fields = line.split("\t")
        if len(fields) >= 2:
            crcs[fields[1]] = int(fields[0], 16) & 0xFFFFFFFF
    return crcs


def verify_module(module: Path, cache: Path | str | None, objcopy: str) -> None:
    """Fail unless the module is the pinned kernel's, by metadata and CRCs.

    vermagic's first field is the release, which Linux itself ignores once
    symbol CRCs are present, so checking it here is the only place the built
    module is tied to the pin. The CRCs then tie it to the pinned tree's
    exported symbols: a module compiled against another kernel's headers
    records different ones.
    """
    fields = module_info(module, objcopy)
    if fields.get("name") != [MODULE_NAME]:
        raise RuntimeError(f"{module}: modinfo name is {fields.get('name')}")
    magic = (fields.get("vermagic") or [""])[0]
    tokens = magic.split()
    if not tokens or tokens[0] != KERNEL_RELEASE:
        raise RuntimeError(
            f"{module}: vermagic {magic!r} is not {KERNEL_RELEASE}'s; it was "
            "built against another kernel's headers"
        )
    if "modversions" not in tokens:
        raise RuntimeError(
            f"{module}: vermagic {magic!r} has no modversions; the pin sets "
            "CONFIG_MODVERSIONS"
        )
    exported = kernel_symbol_crcs(symvers(cache))
    wrong = {
        name: crc
        for name, crc in module_symbol_crcs(module, objcopy).items()
        if exported.get(name) != (crc & 0xFFFFFFFF)
    }
    if wrong:
        raise RuntimeError(
            f"{module}: {len(wrong)} symbol CRCs do not match "
            f"{symvers(cache)}: {sorted(wrong)[:5]}"
        )


def build_module(
    cache: Path | str | None = None,
    cross: str | None = None,
    driver_dir: Path = DRIVER_DIR,
) -> Path:
    """Build frost_net10g as a module for the pinned kernel; return the .ko.

    The build directory is named after the pin and the toolchain, so objects
    are never reused across either. Inside it the driver's sources are copied
    and only rewritten when they change, so kbuild recompiles an edited driver
    and nothing else. ``CC`` is passed explicitly so that the exact compiler
    name in Debian's ``.kernelvariables`` (``$(CROSS_COMPILE)gcc-14`` today)
    does not have to exist. Nothing is published until the module's metadata
    and symbol CRCs say it belongs to the pinned kernel.
    """
    fetch(cache)
    build = module_dir(cache, cross)
    module = build / f"{MODULE_NAME}.ko"
    bin_dir = toolchain_bin(cache, cross)
    environment = dict(os.environ)
    environment["PATH"] = f"{bin_dir}{os.pathsep}{environment.get('PATH', '')}"
    objcopy = str(bin_dir / f"{DEBIAN_CROSS_COMPILE}objcopy")
    with cache_lock(cache):
        build.mkdir(parents=True, exist_ok=True)
        for name in ("Makefile", f"{MODULE_NAME}.c"):
            source = (driver_dir / name).read_bytes()
            staged = build / name
            if not staged.exists() or staged.read_bytes() != source:
                staged.write_bytes(source)
        run_logged(
            [
                "make",
                "-C",
                str(kernel_build_dir(cache)),
                f"M={build}",
                f"CC={DEBIAN_CROSS_COMPILE}gcc",
                "modules",
            ],
            env=environment,
        )
        # Debug information triples the module's size, and the initramfs travels
        # to the board over JTAG. This is what kbuild's INSTALL_MOD_STRIP=1 runs.
        run_logged(
            [f"{DEBIAN_CROSS_COMPILE}strip", "--strip-debug", str(module)],
            env=environment,
        )
        try:
            verify_module(module, cache, objcopy)
        except Exception:
            # Leave nothing behind at the path a consumer reads: a rejected
            # module must not look like a built one to the next run.
            module.unlink(missing_ok=True)
            raise
    return module


# --- The initramfs ----------------------------------------------------------
# A cpio (newc) writer: the kernel concatenates initramfs archives, so the
# module and its init script are appended to Buildroot's own rootfs.cpio
# instead of regenerating it. Buildroot's archive is left byte-for-byte alone,
# and a checkout with an already-built initramfs needs no Buildroot rebuild.
CPIO_MAGIC = b"070701"
CPIO_TRAILER = "TRAILER!!!"
# Every newc member is padded to 4 bytes, and the kernel's unpacker rejects a
# gap between two archives that leaves a length not a multiple of 4
# (init/initramfs.c, do_reset). GNU cpio pads a whole archive to 512, which our
# own trailing padding matches so the result looks like one it wrote.
CPIO_ALIGN = 4
CPIO_BLOCK = 512


def cpio_entry(name: str, mode: int, data: bytes = b"", *, ino: int = 0) -> bytes:
    """Return one newc cpio member: 110-byte header, padded name, padded data."""
    nlink = 2 if mode & 0o040000 else 1
    fields = (
        ino,
        mode,
        0,  # uid: root
        0,  # gid: root
        nlink,
        0,  # mtime: fixed, so the composed archive is reproducible
        len(data),
        0,  # devmajor
        0,  # devminor
        0,  # rdevmajor
        0,  # rdevminor
        len(name) + 1,
        0,  # check: unused by the newc format
    )
    header = CPIO_MAGIC + b"".join(b"%08X" % field for field in fields)
    out = header + name.encode() + b"\0"
    out += b"\0" * (-len(out) % CPIO_ALIGN)
    out += data
    out += b"\0" * (-len(data) % CPIO_ALIGN)
    return out


def cpio_members(archive: bytes) -> Iterator[tuple[str, int, bytes]]:
    """Yield (name, mode, data) for every member of concatenated newc archives.

    The reader the initramfs check needs: it walks the inter-archive padding the
    kernel's unpacker walks, so it sees the members of every archive in the
    file rather than only the first.
    """
    at = 0
    while at < len(archive):
        if archive[at] == 0:  # padding between or after archives
            at += 1
            continue
        if archive[at : at + len(CPIO_MAGIC)] != CPIO_MAGIC:
            raise RuntimeError(f"offset {at}: not a newc cpio header")
        if at + 110 > len(archive):
            raise RuntimeError(f"offset {at}: the cpio header is truncated")
        try:
            fields = [
                int(archive[at + 6 + 8 * i : at + 14 + 8 * i], 16) for i in range(13)
            ]
        except ValueError as bad:
            raise RuntimeError(f"offset {at}: unreadable cpio header: {bad}") from bad
        mode, size, namesize = fields[1], fields[6], fields[11]
        at += 110
        name = archive[at : at + namesize - 1].decode()
        at += namesize
        at += -at % CPIO_ALIGN
        data = archive[at : at + size]
        at += size
        at += -at % CPIO_ALIGN
        if name != CPIO_TRAILER:
            yield name, mode, data


def module_cpio(module: bytes, release: str = KERNEL_RELEASE) -> bytes:
    """Return a cpio archive holding the module and the script that loads it.

    ``/etc/init.d/rcS`` runs the script, so nothing in Buildroot has to know
    about the module. ``insmod`` takes the module's path, which needs no
    ``depmod`` metadata; ``modules.dep`` is written anyway so that ``modprobe``
    works for a person debugging on the board.

    The script checks ``uname -r`` before it loads anything: the pin sets
    CONFIG_MODVERSIONS, and Linux skips vermagic's release field once a module
    carries symbol CRCs, so a successful insmod does not by itself say which
    kernel is running.
    """
    script = f"""#!/bin/sh
# Generated by linux/debian_kernel.py: load the FROST NIC driver, which is a
# module because Debian's kernel has none built in. The release test is not
# redundant with the insmod: with CONFIG_MODVERSIONS the kernel ignores
# vermagic's release field, so this module would load into any ABI-compatible
# kernel. The gates require the token below, so they require the release too.
MODULE=/lib/modules/{release}/{MODULE_NAME}.ko
EXPECT={release}
case "$1" in
start)
\tRUNNING=$(uname -r)
\tif [ "$RUNNING" != "$EXPECT" ]; then
\t\techo "{MODULE_FAIL_TOKEN} kernel $RUNNING is not $EXPECT"
\telif insmod "$MODULE"; then
\t\techo "{MODULE_PASS_TOKEN} $RUNNING"
\telse
\t\techo "{MODULE_FAIL_TOKEN} insmod $MODULE"
\tfi
\t;;
stop)
\trmmod {MODULE_NAME} 2>/dev/null
\t;;
esac
# Never stop rcS: the token above is what the boot gates judge.
exit 0
"""
    directories = (
        "etc",
        "etc/init.d",
        "lib",
        "lib/modules",
        f"lib/modules/{release}",
    )
    out = b""
    ino = 1
    for name in directories:
        out += cpio_entry(name, 0o040755, ino=ino)
        ino += 1
    for name, mode, data in (
        (f"lib/modules/{release}/{MODULE_NAME}.ko", 0o100644, module),
        (
            f"lib/modules/{release}/modules.dep",
            0o100644,
            f"{MODULE_NAME}.ko:\n".encode(),
        ),
        (MODULE_INIT_SCRIPT, 0o100755, script.encode()),
    ):
        out += cpio_entry(name, mode, data, ino=ino)
        ino += 1
    out += cpio_entry(CPIO_TRAILER, 0)
    return out + b"\0" * (-len(out) % CPIO_BLOCK)


def prebuilt_module(module: Path | str | None = None) -> Path | None:
    """Return a module built elsewhere, from the argument or the environment."""
    named = module if module is not None else os.environ.get(MODULE_ENV) or None
    return Path(named) if named is not None else None


def check_base_initramfs(base: Path, payload: bytes) -> None:
    """Fail unless the base archive can be appended to and drives the gates.

    Two ways a stale archive would otherwise reach a board: its length may not
    suit a second archive, and its ``frost_stress`` may predate the counter mode,
    which the boot would survive while reporting none of the counters the board
    soak scores.
    """
    if len(payload) % CPIO_ALIGN:
        raise RuntimeError(
            f"{base}: {len(payload)} bytes is not a multiple of {CPIO_ALIGN}; "
            "the kernel's unpacker rejects the padding between two archives "
            "unless the remainder is aligned (init/initramfs.c, do_reset)"
        )
    program = next(
        (
            data
            for name, _, data in cpio_members(payload)
            if name == INITRAMFS_COUNTER_PROGRAM
        ),
        None,
    )
    if program is None:
        raise RuntimeError(f"{base}: holds no /{INITRAMFS_COUNTER_PROGRAM}")
    if INITRAMFS_COUNTER_TOKEN.encode() not in program:
        raise RuntimeError(
            f"{base}: its /{INITRAMFS_COUNTER_PROGRAM} predates "
            f"{INITRAMFS_COUNTER_TOKEN}, so it is older than the counter "
            f"evidence the board soak scores. Rebuild the test userspace:\n"
            f"  {FROST_STRESS_REBUILD}"
        )


def compose_initramfs(
    base: Path,
    out: Path,
    cache: Path | str | None = None,
    cross: str | None = None,
    module: Path | str | None = None,
) -> Path:
    """Write base plus the NIC module and its loader as one initramfs.

    The kernel unpacks concatenated cpio archives in order, which is how the
    module reaches Buildroot's userspace without rebuilding it. The base is
    checked first, so no consumer can pack a stale one (see
    ``check_base_initramfs``).
    """
    payload = base.read_bytes()
    check_base_initramfs(base, payload)
    ko = prebuilt_module(module) or build_module(cache, cross)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(payload + module_cpio(ko.read_bytes()))
    return out


def main(argv: list[str] | None = None) -> int:
    """Run the command line; return a process status."""
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--cache",
        default=None,
        help=f"cache directory (default: ${CACHE_ENV} or {DEFAULT_CACHE})",
    )
    parser.add_argument(
        "--cross",
        default=None,
        help=f"riscv64 Linux-target cross prefix (default: ${CROSS_ENV} "
        f"or {DEFAULT_CROSS})",
    )
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("fetch", help="download, verify and extract the packages")
    commands.add_parser("release", help=f"print {KERNEL_RELEASE}")
    image = commands.add_parser("image", help="print the kernel Image path")
    image.add_argument(
        "--no-fetch",
        action="store_true",
        help="print the path without downloading anything (for Makefiles)",
    )
    commands.add_parser("module", help="build the NIC module and print its path")
    initramfs = commands.add_parser(
        "initramfs", help="write an initramfs holding the NIC module"
    )
    initramfs.add_argument("--base", required=True, help="Buildroot's rootfs.cpio")
    initramfs.add_argument("--out", required=True, help="the composed initramfs")
    initramfs.add_argument(
        "--module",
        default=None,
        help=f"a module built elsewhere, instead of building one (${MODULE_ENV})",
    )
    args = parser.parse_args(argv)

    if args.command == "release":
        print(KERNEL_RELEASE)
    elif args.command == "fetch":
        print(fetch(args.cache))
    elif args.command == "image":
        if not args.no_fetch:
            fetch(args.cache)
        print(kernel_image(args.cache))
    elif args.command == "module":
        print(build_module(args.cache, args.cross))
    elif args.command == "initramfs":
        print(
            compose_initramfs(
                Path(args.base), Path(args.out), args.cache, args.cross, args.module
            )
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
