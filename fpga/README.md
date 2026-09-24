# FPGA Build and Deployment

These tools run natively on the Linux host, not in Docker. They need Vivado
(validated with 2025.2), Python 3.12+, a JTAG cable, and the
[RISC-V toolchain](../docs/tooling.md#shared-risc-v-toolchain) on PATH or in
`linux/build-mmu/host/bin`. The supported target is the Alveo X3522PV at
322.265625 MHz.

## Quick Start

```bash
./fpga/build/build.py x3                            # build the bitstream (30-90 min)
./fpga/program_bitstream/program_bitstream.py x3    # program the FPGA
./fpga/load_software/load_software.py x3 coremark   # build and load an application
```

The bitstream boots Hello World. Loading an application rebuilds it and
replaces the BRAM and DDR contents without touching the bitstream. The UART
console runs at **115200 baud, 8N1**.

## Programming the FPGA

```bash
./fpga/program_bitstream/program_bitstream.py x3 --list-targets
./fpga/program_bitstream/program_bitstream.py x3 --target '<serial>'
./fpga/program_bitstream/program_bitstream.py x3 --bitstream path/to/image.bit
```

The programmer and the loader share these options:

| Option | Behavior |
|--------|----------|
| `--list-targets` | List targets matching the board vendor |
| `--target PATTERN` | Select by list index or case-insensitive name/serial substring |
| `--target-exact NAME` | Require the full, case-sensitive target name |
| `--non-interactive` | Fail instead of prompting when the target is ambiguous |
| Positional hostname | Connect to `hw_server` on that host, port 3121 |
| `--hw-server-url HOST:PORT` | Use an already running server instead of starting one |

With a single target, it is selected automatically; it must contain exactly
one FPGA. For a remote host, start `hw_server -d` there first. Closing a
Vivado connection does not stop the server or release the cable.

## Loading Software

```bash
./fpga/load_software/load_software.py x3 hello_world
./fpga/load_software/load_software.py x3 hello_world --ddr
./fpga/load_software/load_software.py x3 coremark_pro_core -v1
./fpga/load_software/load_software.py x3 coremark_pro_radix2 -v0
```

Run with `--help` for the list of applications. CoreMark-PRO needs `-v1`
(validation) or `-v0` (performance, with board-calibrated iterations). The
loader holds the CPU in reset while it loads DDR, then loads low BRAM; the
CPU starts about 1.7 seconds after the last write (see the
[board guide](../boards/README.md#jtag-based-software-loading)).

| Option | Behavior |
|--------|----------|
| `--ddr` | Build the application to run from cached DDR |
| `--debug` | Debug build (`-Og -g3` for C) |
| `--build-only` | Build and validate the images without touching the cable |
| `--skip-build` | Load the existing build after checking its images and build settings |
| `--expected-build-config-sha256 HASH` | With `--skip-build`, require the configuration hash reported by `--build-only --debug` |

`--debug` and `--skip-build` apply to single-ELF applications, not the
composite `linux_boot` and `opensbi_smoke` images. `--skip-build` does not
check that the build matches the sources. Leave the build files alone until
the load finishes and debug with that same ELF; the CoreMark-PRO workloads
share one build directory, so building another one meanwhile replaces them.

## Divided-clock builds

`--cpu-clock-div N` divides the CPU clock by N for functional testing. UART,
timers, the loader, and Hello World follow the divided clock; DDR and
Ethernet keep their own clocks. Unless you pass sweep options, these builds
place and route once, with `RuntimeOptimized`, so they finish much sooner.
They don't update the utilization table in the root README.

Loading and hardware regression assume the full-rate clock. For a divided
build, set `FROST_CPU_CLK_HZ` to the actual clock; this also sets the clock in
the Linux device tree and turns off the full-rate benchmark score gates.

```bash
./fpga/build/build.py x3 --cpu-clock-div 2
./fpga/program_bitstream/program_bitstream.py x3
FROST_CPU_CLK_HZ=161132812 ./fpga/load_software/load_software.py x3 hello_world
FROST_CPU_CLK_HZ=161132812 ./fpga/hw_regression.py --board x3 hello_world itlb_test
```

## Profiling counters

`--perf-counters` and `--no-perf-counters` include or leave out the `mperf*`
profiling counters. They are off by default at full rate and on in
divided-clock builds. Without them, the counter CSRs read zero. The setting is
fixed at synthesis. See the
[counter reference](../hw/rtl/cpu_and_mem/cpu/cpu_ooo/perf/README.md).

## VS Code debugging

The [FROST extension](../tools/vscode-frost/README.md) handles programming,
loading, debugging, the serial console, and handing the cable between Vivado
and OpenOCD. Run **FROST: Configure Target** after installing it.

To debug from the command line, load a `--debug` build and wait for the image
reset to release the CPU (1.9 s at full rate, 3.6 s at half rate). Stop the
Vivado `hw_server` that owns the cable, then run:

```bash
openocd -f fpga/debug/openocd_x3.cfg
riscv64-linux-gdb sw/apps/hello_world/sw.elf \
  -ex 'mem 0 0x40000 rw' -ex 'mem 0x80000000 0xc0000000 rw' \
  -ex 'set mem inaccessible-by-default on' \
  -ex 'target extended-remote :3333'
```

The `mem` commands limit GDB to BRAM and DDR, so it never reads a device
register that has read side effects, such as the UART receive register.
Software breakpoints work in BRAM and DDR; hardware breakpoints and
watchpoints are not available. Debugger memory access is slow, so load whole
images with the JTAG loader rather than through GDB. See the
[debugger limits](../tools/vscode-frost/README.md#debugger-scope).

[`.vscode/launch.json`](../.vscode/launch.json) also has a manual
configuration, **FROST: X3 loaded hello_world**, that attaches to an already
loaded image at its current PC, with a matching OpenOCD task that logs to
`.vscode/openocd.log`. To give the cable back to Vivado, pause,
enter `-exec detach`, stop the session, and end the OpenOCD task. Reload the
image after a debugger crash, or when initialized DDR data must be restored.

## Hardware regression

`hw_regression.py` runs the bare-metal applications, all nine CoreMark-PRO
workloads, and Debian from an NFS root, then checks for DDR ECC errors.
Prepare the [Debian export](../docs/debian_nfsroot.md#hardware-regression) and
describe it in the Git-ignored `fpga/site.env`:

```text
FROST_LINUX_NFSROOT=192.0.2.1:/srv/nfs/debian
FROST_LINUX_IP=192.0.2.2::192.0.2.1:255.255.255.0:frost:eth0:off
```

```bash
./fpga/hw_regression.py --board x3                # every stage
./fpga/hw_regression.py --board x3 linux_boot     # selected stages
```

The runner needs local access to the export, write access to its
`usr/local/bin`, and a Linux cross compiler (`FROST_LINUX_CROSS_COMPILE`
overrides discovery). It boots the pinned Debian kernel with the matching
initramfs from the export; `FROST_LINUX_KERNEL` and `FROST_LINUX_INITRD`
override them, and environment variables override `site.env`. Setup problems
are reported as `ENV_FAIL` before the board is touched.

The interactive `debug_target` and `nic_echo` applications are not run, and
`perf_off_test` runs only against a full-rate bitstream. `--timeout` covers
build and load time; some workloads need more (X3 ZIP needs 600 seconds).

`ddr_ecc/ddr_ecc_status.py` reads the DDR controller's accumulated error
counts; `--clear` starts a new interval. `linux_boot_soak.py` boots the
Buildroot test image repeatedly.

## Building

`build/build.py` compiles `hello_world` into the initial BRAM contents, then
runs Vivado: `synth`, `opt`, `place`, `post_place_physopt`, `route`,
`post_route_physopt`, `second_route`, and `post_second_route_physopt`, then
the bitstream. Each step saves a checkpoint, so `--start-at` and
`--stop-after` can resume or stop at any step. Resuming keeps the synthesized
design; RTL changes need a new synthesis.

On X3, placement and routing are sweeps. Placement runs several directives,
each at several setup-uncertainty values, and keeps the best result; both
route steps try several directives. `--jobs N` (default 12) limits how many
Vivado processes run at once, so watch memory when running several builds.
`--directives`, `--num-uncertainties`, and `--route-directives` narrow the
sweeps. `build.py --help` describes every step and default.

If no placement reaches −0.200 ns setup slack, the build warns and continues
with the best one. The X3 CPU datapath has no false-path or multicycle
exceptions.

| Variable | Default | Effect |
|----------|---------|--------|
| `FROST_PLACE_CONGESTION_VETO_LEVEL` | `5` | Among placements that meet timing, drop those whose congestion estimate reaches this level; if that drops them all, keep the least congested |
| `FROST_PLACE_QUICK_ROUTE_COUNT` | `0` | Quick-route this many passing placements and choose by routed slack |
| `FROST_PLACE_CELL_BLOAT` | unset | `LOW`, `MEDIUM`, or `HIGH` cell bloat for every placement, or empty for none. Setting this or the next variable turns off the automatic `LOW` variants |
| `FROST_PLACE_CELL_BLOAT_CELLS` | `*u_tomasulo/u_int_rs` | Hierarchy patterns to bloat |
| `FROST_PHYSOPT_SETUP_UNCERTAINTY` | 0.5 ns after placement, 0 after routing | Added setup uncertainty for every phys_opt step |
| `FROST_GTY_RX_EQ` | `LPM` | NIC transceiver receive equalizer (`LPM` or `DFE`) |

Promoted reports and checkpoints always use zero added uncertainty.

Resumed steps check the metadata files saved beside each checkpoint, so copy
a build directory as a whole. A new synthesis or `opt` result invalidates the
placement: rerun placement before resuming later steps. Only full-rate builds
update the utilization table in the root README;
`./fpga/build/extract_timing_and_util_summary.py` refreshes it from the
latest-stage reports in the build directory.

To route a finished phys_opt sweep while the original build keeps going, fork
it into a new build directory:

```bash
./fpga/build/build.py x3 --start-at route --stop-after route \
  --snapshot-physopt-from fpga/build/x3/work \
  --build-dir fpga/build/x3/work_early_route --jobs 2
```

The destination must not exist yet. The fork keeps its reports and bitstream
in its own directory and leaves the README alone; resume it with `--build-dir`
alone. If routing closes timing, the fork writes `final.dcp` and a bitstream
even with `--stop-after route`.

## ILA captures

`--debug-ila` adds a Vivado ILA on fetch, translation, commit, and trap
signals, and writes a probes file beside the bitstream. Combine it with
`--cpu-clock-div 2` for a faster build.

```bash
./fpga/build/build.py x3 --cpu-clock-div 2 --debug-ila
./fpga/program_bitstream/program_bitstream.py x3
./fpga/debug/capture_fetch_ila.py x3 hook --offset 5e4   # trigger: fetch fault at this page offset
FROST_ILA_ARM_HOOK=fpga/build/x3/work/ila_arm_hook.tcl \
  FROST_ILA_COLLECT_HOOK=fpga/build/x3/work/ila_collect_hook.tcl \
  FROST_CPU_CLK_HZ=161132812 ./fpga/hw_regression.py --board x3 linux_boot
./fpga/debug/fetch_ila_report.py fpga/build/x3/work/fetch_ila.csv --before 200 --only if_ fp_
```

`hook` arms the capture inside the loader's own Hardware Manager session;
opening a separate session would reset the core and lose the armed trigger.
`capture` is the standalone form. The default trigger keeps 3072 of 4096
samples before the fetch fault.

## Troubleshooting

| Symptom | What to check |
|---------|---------------|
| No target found | Power, the cable, `hw_server`, and `--list-targets` |
| Wrong or ambiguous target | Select one with `--target` or `--target-exact` |
| Timing failure | `build/<board>/work/final_timing.rpt`; try other directives. Changing the CPU clock also means updating the board's MMCM settings and the build and loader clock settings |
| `Synth 8-605` error | The build treats this Vivado warning as an error. Declare each signal before any generated primitive instance that uses it; a later declaration can leave the primitive on an undriven implicit net |
| Application does not run | The CPU clock setting (`FROST_CPU_CLK_HZ`), that the program fits in low BRAM, and that any DDR image was loaded |

To add a board, follow the
[board checklist](../boards/README.md#adding-support-for-new-boards). To add an
application, see [sw/CONTRIBUTING.md](../sw/CONTRIBUTING.md#adding-a-new-application).

## License

Copyright 2026 Two Sigma Open Source, LLC

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
