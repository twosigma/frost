# Contributing to FROST Software

See the [project guide](../CONTRIBUTING.md) for style, license headers, and
review requirements, and the [software guide](README.md) for libraries,
build options, memory layout, and test commands.

## Adding a New Application

Create `apps/<app>/` with source files and a Makefile:

```makefile
SRC_C := ../../lib/src/uart.c main.c
include ../../common/common.mk
```

Set app-specific options before the include; add `EXTRA_LDFLAGS := -lgcc`
when the app needs compiler runtime helpers. An assembly app supplying its
own `_start` must use the standalone backend instead of linking C startup:

```makefile
include ../../common/arch.mk
ARCH := $(FROST_XLEN_PREFIX)imac_zicsr_zicntr_zifencei_zba_zbb_zbs_zicond_zbkb_zihintpause
ABI := $(FROST_INT_ABI)
ASM_SRC := main.S
include ../../common/standalone_asm.mk
```

Both backends produce low-BRAM and DDR images; see
[build outputs](README.md#build-outputs). Standalone assembly has no `make size`
target. Set `GENERATE_IMEM_INIT=1` in a common C build when Vivado needs split-bank
instruction-memory initialization files.

`build_all_apps.py` discovers directories with Makefiles. To run the app:

- **Simulation:** add a `CocotbRunConfig` entry to `TEST_REGISTRY` in
  `tests/test_run_cocotb.py`.
- **FPGA:** add the app to `VALID_APPS` in
  `fpga/load_software/load_software.py` and `valid_apps` in its Tcl companion.
- **Parameterized workloads:** add workload/build metadata to
  `sw/apps/software_registry.py` where needed.

Document the app's purpose and expected output in its source. Automated tests
normally print `<<PASS>>` or `<<FAIL>>`.

## Adding a New Library

Add a documented public header under `lib/include/` and an implementation
under `lib/src/`. Preserve include guards and license headers, document API
limits in the header, add an application test for meaningful behavior, and
link it from the [library table](README.md#libraries).

## Bare-Metal Constraints

- Common builds use `-nostdlib` and `-ffreestanding`, with FROST's runtime.
  C++ exceptions and RTTI are unsupported.
- Use `volatile` pointers for MMIO and naturally aligned loads/stores;
  misaligned accesses trap.
- Default placement provides 95 KiB for code/read-only data and 160 KiB for
  data/stack, with a reserved 1 KiB debug slice. The linker protects a 112 KiB
  stack reserve; use `make size` to inspect a common C build.
- Place large objects in `.ddr_*` sections or allocate from the DDR heap.
  `MEM_CONFIG=ddr` relocates the program to cached DDR.
- Keep the software clock consistent with the bitstream. Debug builds change
  code generation and must not supply benchmark scores.

## FreeRTOS Applications

Start from `apps/freertos_demo/`, which contains the port, linker scripts,
and example configuration. Initialize submodules first. Set
`configCPU_CLOCK_HZ` to the actual CPU clock and use the CLINT-compatible
`mtime`/`mtimecmp` addresses `0x40000010`/`0x40000018` for timer interrupts.

## Testing

Run from the repository root:

```bash
./scripts/frost.py run python3 sw/apps/build_all_apps.py
./scripts/frost.py cocotb hello_world
FROST_COCOTB_MEM_CONFIG=ddr ./scripts/frost.py cocotb hello_world
./scripts/frost.py check
```

Substitute the affected app. The build sweep skips parameterized suites and
Linux unless requested; use their [dedicated runners](../tests/README.md)
when affected. Run board tools natively:

```bash
./fpga/program_bitstream/program_bitstream.py x3
./fpga/load_software/load_software.py x3 hello_world
```
