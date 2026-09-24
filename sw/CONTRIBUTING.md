# Contributing to FROST Software

This guide covers adding bare-metal applications and libraries under `sw/`.
The [project guide](../CONTRIBUTING.md) covers style, license headers, and
review; the [software guide](README.md) covers the libraries, build options,
memory map, and test commands.

## Adding a New Application

Create `apps/<app>/` with the sources and a Makefile that includes the shared
rules:

```makefile
SRC_C := ../../lib/src/uart.c main.c
include ../../common/common.mk
```

Set app-specific variables before the `include`, and add
`EXTRA_LDFLAGS := -lgcc` if the app needs compiler runtime helpers. An
assembly app that defines its own `_start` uses the standalone backend
instead of the C startup code:

```makefile
include ../../common/arch.mk
ARCH := $(FROST_XLEN_PREFIX)imac_zicsr_zicntr_zifencei_zba_zbb_zbs_zicond_zbkb_zihintpause
ABI := $(FROST_INT_ABI)
ASM_SRC := main.S
include ../../common/standalone_asm.mk
```

Both backends produce the low-BRAM and DDR images listed under
[build outputs](README.md#build-outputs). The standalone backend runs the
assembler directly, so its `.S` files cannot use `#if` (use `.if`), and it has
no `make size` target. Only the program the bitstream boots (`hello_world`)
needs `GENERATE_IMEM_INIT=1`, which writes the split instruction-BRAM init
files that Vivado reads.

`build_all_apps.py` builds any directory with a Makefile. To run the app
elsewhere, register it:

| To run it in | Register it in |
|--------------|----------------|
| Simulation | A `CocotbRunConfig` entry in `TEST_REGISTRY`, `tests/test_run_cocotb.py` |
| The FPGA loader | `VALID_APPS` in `fpga/load_software/load_software.py` and `valid_apps` in `fpga/load_software/load_software.tcl` |

Apps in `VALID_APPS` also run in the
[hardware regression](../fpga/README.md#hardware-regression), which by default
passes an app on `<<PASS>>`. Exclude an app that cannot pass unattended, such
as one that waits for a debugger, in `fpga/hw_regression.py`. Programs that share one
build directory, like the CoreMark-PRO workloads, are described in
`sw/apps/software_registry.py`.

Describe the app's purpose and expected output at the top of its main source,
make automated tests print `<<PASS>>` or `<<FAIL>>`, and add a row to the
[application table](README.md#applications).

## Adding a New Library

Put a documented header in `lib/include/` and its implementation in
`lib/src/`. Keep the include guard and license header, document the API's
limits in the header, add an application that tests it, and list it in the
[library table](README.md#libraries).

## Bare-Metal Constraints

- `common.mk` builds with `-nostdlib` and `-ffreestanding`, so programs get
  FROST's runtime and nothing else (plus `libgcc` with `-lgcc`). C++
  exceptions and RTTI are not supported.
- Access MMIO through `volatile` pointers and keep loads and stores naturally
  aligned. Misaligned accesses trap once a trap vector is installed (a nonzero
  `mtvec` base); before that, the hardware does not check alignment.
- Low BRAM gives a program 95 KiB for code and read-only data and 160 KiB for
  data and stack, of which the linker reserves 112 KiB for the stack (see the
  [memory map](README.md#memory-map)). `make size` reports a C build's usage.
- Put large objects in `.ddr_*` sections or allocate them from the DDR heap.
  `MEM_CONFIG=ddr` moves the whole program to cached DDR.
- Build for the clock of the bitstream you load (`FPGA_CPU_CLK_FREQ`, which
  the FPGA loader sets). Debug builds change code generation and must not
  produce benchmark scores.

## FreeRTOS Applications

Start from `apps/freertos_demo/`, which has the FROST port
(`port_frost.c`, `port_frost_asm.S`), linker scripts for both memory tiers,
and an example `FreeRTOSConfig.h`. The kernel is the `sw/FreeRTOS-Kernel`
submodule; `scripts/frost.py` initializes it, and native builds need
`git submodule update --init --recursive` first. The example config derives
`configCPU_CLOCK_HZ` from `FPGA_CPU_CLK_FREQ` and runs the tick from the
native `mtime` and `mtimecmp` registers at `0x40000010` and `0x40000018`.

## Testing

Run from the repository root, substituting the affected app:

```bash
./scripts/frost.py run python3 sw/apps/build_all_apps.py            # build every ordinary app
./scripts/frost.py cocotb hello_world                               # simulate from low BRAM
FROST_COCOTB_MEM_CONFIG=ddr ./scripts/frost.py cocotb hello_world   # simulate from cached DDR
./scripts/frost.py check                                            # lint and fast Python tests
```

The build sweep skips the compliance and torture suites and `linux_boot`; use
their [runners](../tests/README.md) when you change them. Board tools run
natively:

```bash
./fpga/program_bitstream/program_bitstream.py x3
./fpga/load_software/load_software.py x3 hello_world
```
