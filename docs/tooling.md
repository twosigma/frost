# Development tooling

Everything except Vivado runs in the `frost` Docker image, which pins the
exact tools CI uses. Build it and check your setup from the repository root:

```bash
docker build -t frost .
./scripts/frost.py doctor      # read-only check of Docker, the image, submodules, file ownership, and the cache
./scripts/frost.py check       # CI's lint and fast Python test jobs
```

Rebuild the image whenever its inputs change. Vivado and the board tools run
natively on the host.

## Tool versions

The [Dockerfile](../Dockerfile) pins the image's tools and their download
checksums, [`.pre-commit-config.yaml`](../.pre-commit-config.yaml) pins the
lint hooks, and [`pyproject.toml`](../pyproject.toml) and the
[extension lockfile](../tools/vscode-frost/package-lock.json) pin language
dependencies. The [README](../README.md#toolchain) summarizes the versions.

Vivado runs on the host and is validated with 2025.2. Native Python scripts
need Python 3.12 or later. The VS Code extension needs VS Code 1.106 or
later; the image supplies its build tools.

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

The wrapper runs the container as your user, so the files it creates stay
yours. It initializes submodules and caches tool downloads under
`$XDG_CACHE_HOME/frost/container` (by default `~/.cache/frost/container`).
`cocotb` and `pytest` run `make clean` in `tests/` first; `pytest` runs the
targets registered in `tests/test_run_cocotb.py`.

Variables starting with `COCOTB_` or `FROST_`, plus `WAVES`,
`DDR_MODEL_LATENCY`, and a few other build and proxy variables, pass through
to the container. `check` keeps going after a failed phase unless you add
`--fail-fast`, and its lint hooks may modify files. Run
`./scripts/frost.py --help` for every option.

## Shared RISC-V toolchain

One compiler, Bootlin's `riscv64-linux-` musl toolchain, builds bare-metal
applications, OpenSBI, and Linux userspace. Its debugger is
`riscv64-linux-gdb`. The image includes it. For native FPGA work, put the
checksummed Bootlin archive pinned in the Dockerfile on your PATH, or use the
copy a Buildroot build leaves behind:

```bash
export PATH="$PWD/linux/build-mmu/host/bin:$PATH"
riscv64-linux-gcc --version
riscv64-linux-gdb --version
```

The Python build and load helpers look on PATH first, then in
`linux/build-mmu/host/bin`. `RISCV_PREFIX` selects the compiler for
bare-metal Make builds and `FROST_LINUX_CROSS_COMPILE` for OpenSBI and Linux
builds. The VS Code extension's `frost.gdbPath` setting names the debugger
explicitly.

Bare-metal programs link statically, without PIE, against FROST's own startup
code, linker scripts, and runtime. CoreMark-PRO takes its math routines from
musl's `libc.a` but brings its own minimal runtime; it does not use Linux
startup code or system calls.

## Maintaining the image

Keep the pins in the Dockerfile, the CI workflow, the lint configuration, and
the language lockfiles consistent. Some constraints that are easy to break:

- cocotb needs a Python built as a shared library. The image builds one in
  `/usr/local/bin/python3` for repository commands and keeps the
  distribution's Python for system tools.
- Buildroot needs GNU `install`, and native Clang builds use the GCC installed
  in `/opt/gcc`.
- Yosys and SymbiYosys versions must stay compatible. The reorder-buffer proof
  uses Boolector's `btormc`; the CMake-compatibility and C17 settings in the
  Dockerfile apply only to Boolector and its dependencies.
- Docker and Buildroot must use the same checksummed Bootlin archive. After a
  compiler change, rebuild Buildroot in a fresh output directory.
- After updating OpenSBI or the compiler, run
  `./scripts/frost.py run make -C sw/apps/opensbi_smoke distclean`. A plain
  `clean` keeps that application's cached firmware.
- The Debian kernel and its headers must match the NIC module's ABI.

To validate an update, run `doctor` and `check`, unit and program simulations
in both memory tiers, formal and synthesis checks, regenerate the Spike
reference results, run the extension's tests, and rebuild the Linux images
from scratch. CI boots the Linux image under QEMU twice, with QEMU's own
OpenSBI and with FROST's, and both boots must print `FROST_NET10G_MODULE_PASS`
and `FROST_USERSPACE_STRESS_PASS` and reach a login prompt. To check how a
compiler update affects benchmarks, use the
[Spike instruction-count harness](../sw/apps/coremark/iss/README.md) and
matched benchmark runs. QEMU and simulation do not replace the
[hardware regression](../fpga/README.md#hardware-regression).
