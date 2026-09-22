# Development tooling

Use the `frost` Docker image for the same tools as CI. Build and run it from
the repository root:

```bash
docker build -t frost .
./scripts/frost.py doctor
./scripts/frost.py check
```

`doctor` checks the image, tool pins, Docker access, submodules, ownership,
and cache without changing the setup. Rebuild the image when its inputs change.
Vivado builds and board tools run natively; Vivado is not in the image.

## Tool versions

[Dockerfile](../Dockerfile) defines image pins and download checksums.
[`.pre-commit-config.yaml`](../.pre-commit-config.yaml) pins lint hooks;
[`pyproject.toml`](../pyproject.toml) and the
[extension lockfile](../tools/vscode-frost/package-lock.json) define language dependencies.

Vivado runs on the host and is validated with **2025.2**.

Native Python scripts support Python 3.12+. The VS Code extension requires
VS Code 1.106 or later; its build runtime is supplied by the image.

## Workflows

```bash
./scripts/frost.py cocotb hello_world
./scripts/frost.py pytest -m cocotb_unit -v
./scripts/frost.py formal --target trap_unit
./scripts/frost.py synthesis --target generic
./scripts/frost.py lint
./scripts/frost.py run python3 sw/apps/build_all_apps.py
./scripts/frost.py shell
```

The wrapper initializes submodules, runs as your UID/GID, and caches tool
downloads under `$XDG_CACHE_HOME/frost/container` (default
`~/.cache/frost/container`). Both `cocotb` and `pytest` clean `tests/` first;
`pytest` selects targets in `tests/test_run_cocotb.py`.

`COCOTB_*`, `FROST_*`, `WAVES`, `DDR_MODEL_LATENCY`, and selected build/proxy
variables pass into the container. See `./scripts/frost.py --help` for options.
`check` runs CI's lint and fast Python jobs; it continues after a failed phase
unless `--fail-fast` is set. Lint hooks may modify files.

## Shared RISC-V toolchain

Bootlin's `riscv64-linux-` compiler builds bare-metal apps, OpenSBI, and Linux
userspace; GDB is `riscv64-linux-gdb`. For native FPGA workflows, put the
checksummed Bootlin archive pinned in the Dockerfile on PATH, or use an
existing Buildroot toolchain:

```bash
export PATH="$PWD/linux/build-mmu/host/bin:$PATH"
riscv64-linux-gcc --version
riscv64-linux-gdb --version
```

Python build/load helpers use PATH, then `linux/build-mmu/host/bin`.
`RISCV_PREFIX` overrides bare-metal Make builds;
`FROST_LINUX_CROSS_COMPILE` overrides OpenSBI/Linux builds. The extension's
`frost.gdbPath` can name GDB explicitly.

Bare-metal builds use FROST startup, linker scripts, and runtime with static,
non-PIE linking. CoreMark-PRO takes musl math objects from `libc.a` and supplies
its own minimal runtime; it does not use Linux startup or syscalls.

## Maintaining the image

Keep Docker, CI, lint, and language dependency pins consistent. In particular:

- cocotb embeds the shared Python library; retain the distribution Python for
  system utilities and use `/usr/local/bin/python3` for repository commands.
- Select GNU `install` for Buildroot and `/opt/gcc` for native Clang builds.
- Keep Yosys and SymbiYosys compatible. The ROB proof requires Boolector's
  `btormc`; its CMake compatibility settings and dependencies' C17 settings
  are scoped to those builds.
- Use the same checksummed Bootlin archive in Docker and Buildroot. Rebuild
  in a fresh Buildroot output directory after compiler changes.
- After OpenSBI or compiler updates, run
  `./scripts/frost.py run make -C sw/apps/opensbi_smoke distclean`;
  ordinary `clean` preserves that app's firmware cache.
- Keep the Debian kernel and headers matched to the NIC module ABI.

Validate updates with `doctor`, `check`, unit/program simulations in both memory
tiers, formal and synthesis checks, reference regeneration, extension tests,
and fresh Linux builds. CI's QEMU boots must reach `FROST_NET10G_MODULE_PASS`,
`FROST_USERSPACE_STRESS_PASS`, and a login prompt with both firmware paths.
Use the [Spike harness](../sw/apps/coremark/iss/README.md) and matched benchmark
runs to check compiler effects. QEMU and simulation do not replace
[native hardware regression](../fpga/README.md#hardware-regression).
