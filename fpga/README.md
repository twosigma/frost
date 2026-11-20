# FPGA Build and Deployment

These tools run natively on the Linux host, not in Docker. They need Vivado
(validated with 2025.2), Python 3.12+, a JTAG cable, and the
[RISC-V toolchain](../docs/tooling.md#shared-risc-v-toolchain) on PATH or in
`linux/build-mmu/host/bin`. The supported target is the Alveo X3522PV at
322.265625 MHz.

## Quick Start

```bash
./fpga/build/build.py x3                            # build the bitstream (takes hours)
./fpga/program_bitstream/program_bitstream.py x3    # program the FPGA
./fpga/load_software/load_software.py x3 coremark   # build and load an application
```

The bitstream boots Hello World. Loading an application rebuilds it and
replaces the BRAM and DDR contents without touching the bitstream. The UART
console runs at **115200 baud, 8N1**.

The X3 block design maps 1 GiB of DDR to the CPU. The build derives
`FROST_DDR_CAPACITY_LOG2_BYTES=30` from that map and passes it to the RTL
and application C flags. Application loads use the same map, so tests such
as `dma_torture` check overruns at the board's DDR boundary. Conflicting
inherited capacity values or C flags are rejected. The board wrapper checks that
FROST's DDR AXI address width matches its 30-bit port, with no address
slice that could alias a high request into low DDR. Resume from an older
netlist checkpoint is rejected unless its capacity is recorded and matches
the board; restart at synthesis after changing the DDR map.

The cache hierarchy uses one coherent hart and an S/M home.
`netlist_config.json` uses schema `x3_netlist_config_v5`. Checkpoint reuse
requires this schema and matching memory, reset and clock-domain settings.

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
(validation) or `-v0` (performance, with registry-configured iterations).
VCU118 iteration budgets are estimates derived from the X3 settings. The
sweep checks each run's reported duration against the score-rule minimum.
The loader holds the CPU in reset while it loads DDR, then loads low BRAM;
the CPU starts when the board's image-reset timer expires (see the
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

`--perf-counters` includes the `mperf*` profiling counters. They are left out
by default, at any clock, and the counter CSRs then read zero. The setting is
fixed at synthesis. See the
[counter reference](../hw/rtl/cpu_and_mem/cpu/cpu_ooo/perf/README.md).

The counters are machine-mode CSRs, so Linux cannot read them.
`debug/cache_counters.py` reads the cache counters over JTAG while anything
runs, halting the hart through OpenOCD only to take each snapshot and read
it. `window` takes a snapshot, runs a command or waits, then takes another
and reads both from the cache block's two snapshot banks, and prints the
deltas with the L2's write costs. It counts the window's cycles with the
`time` CSR, since Linux's perf support can stop and preload `mcycle`.
The Tcl helper requests `riscv autofence off` when supported. If OpenOCD
executes FENCE.I before resume, it drains committed stores, invalidates L1I
and synchronizes instruction-copy writes. Dirty L1D data remains available
to coherent home probes. Stop the Vivado `hw_server` first;
`FROST_JTAG_SERIAL` selects the cable as for `debug/openocd_x3.cfg`:

```bash
./fpga/debug/cache_counters.py window -- ssh root@192.0.2.2 'dd if=/root/big of=/dev/null bs=1M'
./fpga/debug/cache_counters.py window --seconds 30
```

An OpenOCD run stopped between its halt and its resume, by a timeout or
Ctrl-C, can leave the hart halted; `cache_counters.py resume` resumes it.

Bare-metal programs read the counters themselves. CoreMark-PRO built with
`COREMARK_PRO_CACHE_COUNTERS=1` prints the deltas over its timed region as a
`FROST_CACHE_COUNTERS` line, which the loader passes through from the
environment, and `cache_counters.py summarize` reports a sweep's log:

```bash
COREMARK_PRO_CACHE_COUNTERS=1 ./fpga/sweep_coremark_pro.py --board x3 -v0 | tee sweep.log
./fpga/debug/cache_counters.py summarize sweep.log
```

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

`hw_regression.py` runs the bare-metal applications, a debug-port check, all
nine CoreMark-PRO workloads, and Debian from an NFS root, then checks for DDR
ECC errors.
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
are reported as `ENV_FAIL` before the board is touched. The runner also builds
the memory error driver (`linux/frost-memerr`) for the pinned kernel and
installs it in that `usr/local/bin`; after login the stage loads it and
requires the X3's ECC reader to be active and polling, with no memory error
reported. It runs the debugfs scrub self-test and requires its pass line and
counters. With `patrol_seconds=10`, it requires patrol progress and a full
pass within 150 one-second waits, then reloads the module at the daily default.
`FROST_MEMERR_MODULE` names a prebuilt module instead.

The `debug_port` stage, which follows `hello_world`, checks the debug
transport through OpenOCD (`debug/hw_debug_check.tcl`): it reads `dtmcs` over
JTAG and `dmstatus` and `hartinfo` over the debug module interface, halts the
running hart, reads `dpc`, resumes it, and reads `dtmcs` (without clearing
sticky status) and `hartinfo` again. OpenOCD's background polling is switched
off for the whole script (a poll between a raw scan's instruction and data
steps would read another register) and switched on again on every path.

The script prints one fixed sequence of `FROST_DEBUG key=value` lines on
stdout and then `FROST_DEBUG_DONE`; OpenOCD's own log is on stderr. The check
transcript passes only if OpenOCD exits 0 with no `Error:` or
`FROST_DEBUG_ERR:` line on stderr, stdout is exactly that sequence (any text
before, between or after, a missing, repeated, reordered or malformed line
fails, and the message quotes the first offending line), both readings of
`dtmcs` and of `hartinfo` agree, `dtmcs` has version 1, 7 address bits, no
sticky error and zero reserved bits, `hartinfo` is the debug module's constant,
`dmstatus` reports the halted and then the running state of a single available
hart with nothing else set, and `state_left` is `running`.

Whenever the OpenOCD check process was started, the stage always ends by
running a separate OpenOCD process (`frost_debug_recover`, 30-second limit)
while the host cable lock is still held, including when the stage is
interrupted by `SIGINT` (Ctrl-C) or `SIGTERM`. During the stage, `SIGTERM` is
converted to an interrupt exception and the previous handler is restored on
exit; after confirmation finishes, the interrupt is re-raised. That second
process resumes the hart if it is halted and prints its state. Confirmation
succeeds only if the second process finishes in time, exits 0, prints no error
marker on stdout or stderr, and prints exactly `FROST_DEBUG state_left=running`
followed by `FROST_DEBUG_DONE`. The first transcript never decides the hart's
state on any path. Any other confirmation outcome, or an interrupt during
confirmation itself, reports the hart state as `UNKNOWN` (`FAIL` on normal
return) and prints the manual recovery command:

```bash
FROST_JTAG_SERIAL=<cable serial> ./fpga/debug/cache_counters.py resume
```

Stop Vivado's `hw_server` before running that manual recovery command.

The `debug_port` stage outcomes are `PASS` (primary check passed and the
separate process confirmed the hart running), `SKIPPED` (`FROST_JTAG_SERIAL`
is unset; neither pass nor failure, though a selection of only skipped stages
fails), `ENV_FAIL` (`OPENOCD` is missing or cannot start, or the host lock file
cannot be opened), `TIMEOUT` (the primary check exceeded 60 seconds and the
confirmation process confirmed the hart running), and `FAIL` (`hw_server` held
the cable past three minutes, the primary check failed, an unexpected exception
occurred, or confirmation did not prove the hart running). Any non-signal
exception inside the stage becomes `FAIL` with a masked message, never a
traceback. The stage does not use the UART, so a selection of only `debug_port`
and `ddr_ecc` does not check that the UART is free. `OPENOCD` names the OpenOCD
executable if it is not `openocd` on `PATH`. OpenOCD and Vivado's `hw_server`
cannot share the cable, so the stage waits up to three minutes for `hw_server`
to exit, which it does on its own shortly after its last client, and fails if
it does not. Everything the runner prints, and the text of every setup failure
it raises, masks the cable serial case-insensitively as `<cable serial>`,
because logs get pasted into issues.

The Linux preflight also checks the version of `frost_net10g` inside the
initramfs against `MODULE_VERSION` in `linux/frost-net10g/frost_net10g.c`. The
regression host requires `unmkinitramfs` (from `initramfs-tools-core`) and
`modinfo` (from `kmod`) on `PATH`. The preflight unpacks the initramfs into a
private temporary directory with `unmkinitramfs`, finds every regular file
named `frost_net10g.ko`, `frost_net10g.ko.xz`, `frost_net10g.ko.zst`, or
`frost_net10g.ko.gz`, reads each copy's version with `modinfo -F version`, and
always removes the temporary directory. `unmkinitramfs` unpacks only the early
section and the first compressed archive (the layout produced by
`update-initramfs`); the preflight success line notes this scope. The preflight
passes only when at least one copy exists in what `unmkinitramfs` unpacks and
every copy reports the tree's exact version. A missing tool, a tool that exits
nonzero, times out, or prints no version, no trailing newline, or multiple
versions, a non-regular entry under a module name, an initramfs without the
module, a version mismatch, or any unexpected preflight error reports an
environment failure naming the tool or file, both versions, and the rebuild
steps in `docs/debian_nfsroot.md` step 3. Without `--keep-going`, the run
prints that message as `ERROR: linux_boot: ...` and exits 1 before any stage;
with `--keep-going`, the other stages run and `linux_boot` appears in the
summary as `ENV_FAIL`.

As the authoritative check of the module actually loaded by the kernel, the
Linux stage reads `/sys/module/frost_net10g/version` after reaching its shell
prompt and before running the network test, and requires an exact match against
the tree's `MODULE_VERSION`. A mismatch, missing file, or unreadable output
fails the stage immediately with the same step 3 rebuild instructions.

The Linux stage accepts systemd `running`, or `degraded` when every failed
unit is a `session-N.scope` with `Result=resources`. It logs the tolerated
scopes. Any other failed unit or result fails the stage.
Before NIC loopback, the stage drops dentry and inode caches and copies the
static test to `/dev/shm`. The test opens its sysfs descriptors while the
link is up, then holds it down for 65 seconds to expire NFS's default
directory attribute cache. The shell opens its restoration files before the
test, restores MTU, flags and IPv6 through those descriptors, then writes,
syncs and removes a root file to check NFS recovery.

Stage selection follows `--board`; `bootrom` is available only on VCU118.
The `bootrom` stage requires FSBL, OpenSBI, a device tree and U-Boot in flash.
It requires the ROM's FSBL CRC verification, the FSBL's verified boot chain
and handoff, then the U-Boot banner and `frost=> ` prompt, in that order.
The prompt must remain at the end of the capture for one second of UART
silence. Progress belongs to the most recent ROM startup.
HALT messages, validation failures and trap diagnostics fail the stage.
Its timeout is at least 600 seconds, including compilation, loading, DDR
preparation and flash reads. A larger `--timeout` extends that budget.

The interactive `debug_target` and external-link `nic_echo` and `nic_bench`
applications are excluded from the default sequence.
`perf_off_test` checks that the profiling counters are absent, so it fails
against a bitstream built with `--perf-counters`. `--timeout` covers build,
load, and untimed input preparation as well as benchmark execution. A
bitstream at half the standard clock needs
`--timeout 4200 --linux-timeout 3600` to run every application, benchmark
workload, and Linux check.

Set `FROST_CPU_CLK_HZ` to the bitstream's actual CPU frequency. A clock
override skips the standard-clock CoreMark and CoreMark-PRO score thresholds;
the runner still reports the measured values and checks functional results.

`ddr_ecc/ddr_ecc_status.py` reads the DDR controller's accumulated error
counts; `--clear` starts a new interval. FROST's own view of the same errors
is the memory error unit, which `memerr_readback` checks on the board. `linux_boot_soak.py` boots the
Buildroot test image repeatedly.

## Building

`build/build.py` compiles `hello_world` into the initial BRAM contents, then
runs Vivado: `synth`, `opt`, `place`, `post_place_physopt`, `route`,
`post_route_physopt`, `second_route`, and `post_second_route_physopt`, then
the bitstream. Each step saves a checkpoint, so `--start-at` and
`--stop-after` can resume or stop at any step; `--start-at bitstream` writes
a bitstream from an existing `final.dcp`. Resuming keeps the synthesized
design, so RTL changes need a new synthesis, and a new synthesis or `opt`
result invalidates the placement. Resumed steps check the metadata files
saved beside each checkpoint, so copy a build directory as a whole.
`build.py --help` describes every step, option, and default.

```bash
./fpga/build/build.py x3 --stop-after place    # build through placement
./fpga/build/build.py x3 --start-at route      # resume from post_place_physopt.dcp
```

Setup timing counts as met only with nonnegative WNS and TNS and no failing
setup endpoints. When `route`, `post_route_physopt`, or `second_route` meets
it, the build skips to the bitstream. The X3 CPU datapath has no false-path or
multicycle exceptions.

### X3 placement

A full-rate X3 build places several candidates from the same post-opt
checkpoint and keeps one:

- A guided candidate. A reference placement (`ExtraNetDelay_high`, 0.325 ns
  setup uncertainty, CPU clock root `X1Y9`, and `MEDIUM` cell bloat on the
  integer reservation station and the memory station's source-2 operand
  cells) is measured, critical registers are moved and LUT inputs swapped in
  up to eight rounds, keeping a change only if setup and hold slack do not
  get worse, and a final `Quick` placement locks those choices in. It needs
  post-opt WNS >= 0.
- A grid of four placer directives at six setup uncertainties, plus a few
  fixed variants (`--directives` and `--num-uncertainties` change the grid
  and drop the guided candidate).

Local guidance expands endpoint queries until the complete count is available.
Register and pair trials reject an increase in that count.

A candidate qualifies when every path's slack immediately after placement,
at zero added uncertainty, prints as -0.201 ns or better (Vivado finds no
path below -0.2015 ns), and its congestion level is below 5. Up to three
qualifiers are quick-routed with `RuntimeOptimized`; a probe must finish
fully routed with no errors.
Probes without a router congestion warning rank first, then routed WNS and
TNS. If no candidate qualifies, the build stops.
`work/post_place_selection.json` records every candidate's result, and later
steps refuse to start unless the selection evidence beside `post_place.dcp`
is complete and unchanged.

The board constraints leave the NIC core and MAC unfenced. Even soft pblocks
can change the CPU's placement and congestion, so evaluate any new floorplan
against an unfenced placement of the current netlist.

### Phys-opt and routing

Every phys-opt step runs a directive sweep that ends with a retime-only pass
and repeats while WNS (or TNS at equal WNS) improves. Both route steps try
four router directives and keep the best result (`--route-directives`
narrows the list); `--jobs N` (default 12) limits simultaneous Vivado
processes. Phys-opt and routing first drop the incremental history inherited
from `RuntimeOptimized` placement, which would otherwise make Vivado stop at
that placement's WNS.

When the final X3 phys-opt sweep stalls, the build also optimizes the failing
CPU endpoints in groups, with a temporary 30 ps setup margin. Once at most 24
CPU endpoints fail, it also tries clock optimization of single endpoints,
faster LUT input pins along the critical paths, and rerouting shared nets
with the critical sink first. It keeps only changes that improve
whole-design timing and keep routing, hold, pulse-width, and bus-skew timing
legal. Bitstream generation saves `final_bus_skew.rpt` and refuses a bus-skew
violation.
`FROST_PHYSOPT_SWEEP_ORDER` replaces the default sweep schedule.

| Variable | Default | Effect |
|----------|---------|--------|
| `FROST_PLACE_CONGESTION_VETO_LEVEL` | `5` | Reject full-rate candidates whose congestion estimate reaches this level; no fallback if all fail |
| `FROST_PLACE_QUICK_ROUTE_COUNT` | `3` | Quick-route up to this many qualifying candidates. `0` disables probes (divided-clock default: `0`) and must be given again on resume |
| `FROST_PLACE_CELL_BLOAT` | unset | Use `LOW`, `MEDIUM`, or `HIGH` cell bloat for every grid candidate, or empty for none. Setting this or the next variable selects the grid only and drops the automatic `LOW` variants |
| `FROST_PLACE_CELL_BLOAT_CELLS` | `*u_tomasulo/u_int_rs` | Cell name patterns to bloat |
| `FROST_PHYSOPT_SETUP_UNCERTAINTY` | 0.5 ns after placement, 0 after routing | Added setup uncertainty for every phys_opt step |
| `FROST_GTY_RX_EQ` | `LPM` | NIC transceiver receive equalizer (`LPM` or `DFE`) |

Promoted reports and checkpoints always use zero added uncertainty. Only
full-rate builds in the default directory update the utilization table in
the root README; `./fpga/build/extract_timing_and_util_summary.py` refreshes
it from the most advanced stage with a utilization report.

To route a finished phys_opt sweep while the original build keeps going, fork
it into a new build directory:

```bash
./fpga/build/build.py x3 --start-at route --stop-after route \
  --snapshot-physopt-from fpga/build/x3/work \
  --build-dir fpga/build/x3/work_early_route --jobs 2
```

The destination must not exist yet. The fork keeps its reports and bitstream
in its own directory and leaves the README alone. Continue it with its
`--build-dir` and a `--start-at` step, without `--snapshot-physopt-from`. If
routing closes timing, the fork writes `final.dcp` and a bitstream even with
`--stop-after route`.

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
| Timing failure | `build/<board>/work/final_timing.rpt`; try other directives. Changing the CPU clock means changing the board's clock generation (`x3_cpu_clock_gty.sv`, or the MMCM that `--cpu-clock-div` 3 and 4 use) and the build and loader clock settings |
| `Synth 8-11241` or `Synth 8-6901` error | A name is undeclared or used before its declaration. Declare it before its first use. Vivado can bind the use to the later declaration or create an implicit net; inside a generate block the separate net can leave the use or the declaration undriven |
| `Synth 8-605` error | The build treats this Vivado warning as an error. Declare each signal before any generated primitive instance that uses it; a later declaration can leave the primitive on an undriven implicit net |
| `Synth 8-324` error | An array or vector index is out of range. The build rejects this because synthesis can replace the read with a don't-care while simulation silently truncates the index. Check index widths; for a two-entry vector indexed by an `int p` loop variable, use `p ^ 1` for the other entry, since `~p` is negative |
| Step "ended abnormally" | The Vivado step exited non-zero with no `ERROR:` line and no `Exiting Vivado` line in its log, so the process was killed from outside (another session, the out-of-memory killer) or crashed. The message names the last log line; check `dmesg` and free memory, then rerun from that step |
| Application does not run | The CPU clock setting (`FROST_CPU_CLK_HZ`), that the program fits in low BRAM, and that any DDR image was loaded |

The declaration-message guards apply to top-level synthesis for every board.
The shared build script sets them after vendor IP out-of-context synthesis
runs finish, before synthesizing FROST's top. The [strict elaboration
check](../tests/README.md#strict-systemverilog-elaboration) also checks the
X3 vector configuration and simulation vector lengths 128, 256, and 512.

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
