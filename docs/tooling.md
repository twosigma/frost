# Development tooling

The pins in `Dockerfile`, `.pre-commit-config.yaml`, the Linux submodules,
and `tools/vscode-frost/package-lock.json` were checked on **2026-09-21**.
Use `docker build -t frost .` and `./scripts/frost.py doctor` after updating.
`doctor` checks the embedded image inputs and the installed tool versions;
its Python, GCC, LLVM, CMake, QEMU and Node checks also catch stale images.

## Upstream releases

| Component | Pinned release | Upstream source |
|---|---|---|
| Ubuntu | 26.04 | [Release notes](https://documentation.ubuntu.com/release-notes/26.04/) |
| Python | 3.14.7 | [Python downloads](https://www.python.org/downloads/) |
| GCC | 16.2.0 | [GCC releases](https://gcc.gnu.org/releases.html) |
| LLVM (Clang, clang-tidy, clang-format) | 23.1.1 | [Release](https://github.com/llvm/llvm-project/releases/tag/llvmorg-23.1.1) |
| CMake | 4.4.3 | [Release](https://github.com/Kitware/CMake/releases/tag/v4.4.3) |
| Meson / Ninja | 1.12.0 / 1.13.2 | [Meson](https://pypi.org/project/meson/1.12.0/), [Ninja](https://pypi.org/project/ninja/1.13.2/) |
| Verilator | 5.052 | [Tag](https://github.com/verilator/verilator/tree/v5.052) |
| Yosys / SymbiYosys | 0.69 | [Yosys](https://github.com/YosysHQ/yosys/releases/tag/v0.69), [SBY](https://github.com/YosysHQ/sby/tree/v0.69) |
| Z3 | 5.1.0 | [Release](https://github.com/Z3Prover/z3/releases/tag/z3-5.1.0) |
| Boolector / btormc | 3.2.4 | [Final release](https://github.com/Boolector/boolector/releases/tag/3.2.4) |
| Verible | 0.0-4294-gc1d8f5e8 | [Release](https://github.com/chipsalliance/verible/releases/tag/v0.0-4294-gc1d8f5e8) |
| sv2v | 0.0.13 | [Release](https://github.com/zachjs/sv2v/releases/tag/v0.0.13) |
| xPack bare-metal RISC-V GCC | 15.2.0-1 | [Release](https://github.com/xpack-dev-tools/riscv-none-elf-gcc-xpack/releases/tag/v15.2.0-1) |
| Bootlin stable musl RISC-V GCC | 2026.08-1 (GCC 15.3.0) | [Downloads and checksums](https://toolchains.bootlin.com/downloads/releases/toolchains/riscv64-lp64d/tarballs/) |
| Buildroot / OpenSBI | 2026.08 / 1.9 | [Buildroot](https://buildroot.org/news.html), [OpenSBI](https://github.com/riscv-software-src/opensbi/releases/tag/v1.9) |
| QEMU | 11.1.1 | [Downloads](https://www.qemu.org/download/) |
| Spike | `02b1dc182164bb73b19b050676dd89f0834f8b2e` | [Pinned commit](https://github.com/riscv-software-src/riscv-isa-sim/commit/02b1dc182164bb73b19b050676dd89f0834f8b2e) |
| OpenOCD | 0.12.0 | [Release](https://openocd.org/pages/getting-openocd.html) |
| Cocotb / pytest / pytest-cov | 2.1.0 / 9.1.1 / 7.1.0 | [Cocotb](https://pypi.org/project/cocotb/), [pytest](https://pypi.org/project/pytest/), [pytest-cov](https://pypi.org/project/pytest-cov/) |
| Ruff / mypy | 0.16.8 / 2.3.1 | [Ruff](https://pypi.org/project/ruff/0.16.8/), [mypy](https://pypi.org/project/mypy/2.3.1/) |
| pre-commit / Click | 4.6.2 / 8.5.0 | [pre-commit](https://pypi.org/project/pre-commit/4.6.2/), [Click](https://pypi.org/project/click/8.5.0/) |
| Standard hooks / license hooks | 6.0.0 / 1.5.6 | [Standard hooks](https://github.com/pre-commit/pre-commit-hooks/releases/tag/v6.0.0), [License hooks](https://github.com/Lucas-C/pre-commit-hooks/releases/tag/v1.5.6) |
| Node.js / npm | 26.9.0 / 12.0.2 | [Node release archive](https://nodejs.org/dist/v26.9.0/), [npm](https://www.npmjs.com/package/npm) |
| pip / setuptools / wheel | 26.2.1 / 84.0.0 / 0.48.0 | [pip](https://pypi.org/project/pip/26.2.1/), [setuptools](https://pypi.org/project/setuptools/84.0.0/), [wheel](https://pypi.org/project/wheel/0.48.0/) |
| TypeScript / vsce | 7.0.2 / 4.0.0 | [TypeScript](https://github.com/microsoft/TypeScript/releases/tag/v7.0.2), [vsce](https://www.npmjs.com/package/@vscode/vsce) |

CI pins checkout 7.0.1, upload-artifact 7.0.1, download-artifact 8.0.1,
cache 6.1.0, setup-buildx-action 4.4.1 and build-push-action 7.4.0. The
[Ubuntu 26.04 hosted runner](https://github.com/actions/runner-images/blob/main/images/ubuntu/Ubuntu2604-Readme.md)
launches the Ubuntu 26.04 container; its host compiler and Python do not run
the regression tests.

## Compatibility decisions

- Buildroot rejects the uutils `install` shipped by Ubuntu 26.04 because of
  upstream issue [#12166](https://github.com/uutils/coreutils/issues/12166).
  The image selects GNU `install` through the distribution's alternatives.
  Ninja's wheel includes Kitware's jobserver patch; `doctor` recognizes its
  version-banner suffix while still checking the exact release number.
- Python in the image is built with its shared library for cocotb embedding.
  Distribution utilities retain `/usr/bin/python3`; repo commands use
  `/usr/local/bin/python3`. Ruff and mypy target Python 3.12 so native Vivado
  hosts retain their supported Python floor.
- LLVM tools use one upstream release; pre-commit uses the same clang-format
  version. Native Clang explicitly selects `/opt/gcc` so it cannot select
  Ubuntu's incomplete prerelease GCC tree. Ruff and mypy run in pre-commit's
  pinned environments. Python development extras match those pins too.
  The image extracts only Clang, clang-tidy, clang-format and Clang's builtin
  headers/runtime from the upstream archive, and strips Spike's debug symbols.
  CI deletes the exported image archive after loading it to leave space for
  builds and test artifacts.
- GCC is built from a stable release because Ubuntu 26.04's `gcc-16` package
  is a prerelease. The compiler's shared libraries are registered with ld.so.
  Boolector's old CMake projects use a scoped compatibility policy; its
  Lingeling dependency and Spike's bundled libfdt use C17 because their C
  sources predate GCC's C23 default. The ROB proof still requires `btormc`, so
  replacing Boolector with Bitwuzla is not a version update.
- Buildroot and Docker use the same checksummed Bootlin archive. Buildroot
  downloads it through the custom external-toolchain configuration because
  its built-in Bootlin selection still points at 2025.08. Native loaders
  can therefore build without an image-specific `/opt` installation. Start
  with a fresh Buildroot output directory after this upgrade. CI keys its
  ccache by the Dockerfile and toolchain config to separate compiler updates.
  Also run `./scripts/frost.py run make -C sw/apps/opensbi_smoke distclean`
  once after upgrading OpenSBI or Bootlin: ordinary `clean` deliberately keeps
  that application's firmware cache for native board reloads.
- OpenSBI 1.9 enables only U-mode `time` reads at entry (`scounteren=0x2`),
  following its [upstream counter-access change](https://github.com/riscv-software-src/opensbi/commit/5b305e30a55d93d507006dd11685bdeb7e7207e8).
  The smoke test checks that exact value, successful U-mode `rdtime`, and
  illegal-instruction traps for U-mode `rdcycle`/`rdinstret`. S-mode counter
  and SBI PMU checks remain in place. The supervisor controls U-mode
  cycle/instruction access.
- The Debian kernel, its matching headers, and the Debian NFS root are target
  software. Their existing snapshot pins and module ABI remain independent
  of the development-tool update. Both QEMU firmware paths must boot that
  kernel and load its newly compiled NIC module.
- The VS Code API floor remains 1.106, with matching API types. Node 22 type
  declarations match the extension host; Node 26 is the build/test runtime.
  The wrapper places npm downloads in its writable cache mount.
- Vivado remains a separately installed native tool. Its documented validated
  version and hardware regression results are not changed by this image.
  Architecture-test, benchmark and FreeRTOS source pins are also retained.

## Validation

Run all simulation and formal checks through the image; the cocotb wrapper
cleans `tests/` before each run. Vivado flows run natively.

```bash
docker build -t frost .
./scripts/frost.py doctor
./scripts/frost.py check
./scripts/frost.py pytest -m cocotb_unit -q
./scripts/frost.py cocotb hello_world
FROST_COCOTB_MEM_CONFIG=ddr ./scripts/frost.py cocotb hello_world
./scripts/frost.py cocotb opensbi_smoke
./scripts/frost.py formal
./scripts/frost.py synthesis
./scripts/frost.py run python3 tests/net10g/synthesize.py
./scripts/frost.py run python3 sw/apps/arch_test/generate_references.py --all --parallel 16
./scripts/frost.py run python3 sw/apps/riscv_torture/generate_tests.py --references-only --parallel 16
./scripts/frost.py run bash -c 'cd tools/vscode-frost && npm ci && npm run check && npm test && npm run package'
```

For Linux, use the [Buildroot build instructions](../linux/buildroot-external/README.md#build)
in a fresh output directory, then run the CI QEMU lane with both bundled
and FROST-built OpenSBI. Require `FROST_NET10G_MODULE_PASS`,
`FROST_USERSPACE_STRESS_PASS` and the userspace login prompt from each boot.
These validate the compiler, firmware, kernel headers, module and emulator
as one stack; they do not replace the board's native hardware regression.

Checks completed for the 2026-09-21 update:

- Lint and all 658 fast Python tests passed. Python 3.12 compatibility
  checks also passed.
- All 91 cocotb unit targets and the BRAM/DDR Hello World runs passed.
- The OpenSBI 1.9 RTL smoke passed in 5,310,949 cycles, including the new
  U-mode counter-permission checks and all existing timer, trap and PMU tests.
- All 92 formal tasks passed, including the Z3 CSR/trap targets and btormc ROB
  checks.
- All 124 extension tests, TypeScript checking, VSIX packaging and Python
  wheel packaging passed.
- Spike regenerated all 262 architecture-test and 20 torture references
  without changing their signatures.
- A fresh Buildroot build completed, including OpenSBI and the NIC module.
  Both QEMU firmware paths reached all three required boot markers.
- Generic CPU, Xilinx UltraScale+ CPU and portable Ethernet synthesis passed.

Vivado implementation, board programming and the Debian NFS-root hardware
regression were not run for this tooling update.
