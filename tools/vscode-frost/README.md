# FROST FPGA Debugger

A local VS Code extension for FROST bare-metal development on the X3 FPGA.
It uses Microsoft's public `cppdbg` debugger through the installed C/C++
extension, native RISC-V GDB/OpenOCD, and native Vivado program/load tools.

Install the VSIX in official VS Code on the Linux FPGA host, or on that
host through Remote-SSH. The workspace extension and all native tools must
run on the host with the repository and FPGA cable. It requires a trusted
workspace and Microsoft C/C++ (`ms-vscode.cpptools`).

## Build and install locally

From `tools/vscode-frost`, with Node.js 22 or newer:

```bash
npm ci
npm run check
npm test
npm run package
code --install-extension frost-0.1.0.vsix
```

For Remote-SSH, use **Extensions: Install from VSIX** in the connected VS
Code window and install it on the FPGA host. Native Vivado remains a host
prerequisite; the repository's Docker image is for cocotb/regression tools.
Packaging does not publish to the Marketplace.

## Target settings

Open the FROST repository, then run **FROST: Configure Target**. Enter the
exact FT4232H JTAG bridge serial, the full Vivado target path, the actual
CPU clock in Hz, application, and BRAM/DDR selection. The command saves
these to User settings on the extension host. A Vivado target may be left
empty for attach-only use; load/program operations require it. The full
path must use the owned endpoint
`127.0.0.1:3121/xilinx_tcf/Xilinx/<serial+channel>`. Obtain the exact target
identity from Vivado; the FTDI serial alone does not establish that path.
The extension uses loopback ports 3121 for its hardware server and 3333
for OpenOCD, and fails if a port is already owned by another process.

Set tool paths under **Settings → FROST** if `python3`, `openocd`,
`riscv-none-elf-gdb`, `vivado`, and `hw_server` are absent from VS Code's
host environment `PATH`. These settings contain executable paths, without
extra shell arguments. Tool paths and cable identities use machine-scoped
settings so they remain outside the repository and Settings Sync.

`frost.repoRoot` defaults to the selected workspace folder. Artifact paths
are resolved relative to the repository; `frost.elf` defaults to
`sw/apps/<app>/sw.elf`. An attach ELF must match the already loaded image.
`frost.bitstream` selects a `.bit` file; if empty, program commands open a
file picker. `frost.cpuClockHz` has no assumed board-clock default: supply
the frequency used by the actual bitstream.

## Commands

| Command | Purpose |
| --- | --- |
| FROST: Configure Target | Save the cable, Vivado target, clock and application choices. |
| FROST: Attach Debugger | Attach `cppdbg` to the already loaded application. |
| FROST: Load Software and Debug | Build/load the selected application, then debug it. |
| FROST: Program Bitstream | Program volatile FPGA configuration. |
| FROST: Program Bitstream, Load and Debug | Program the FPGA, load the application and start debugging. |
| FROST: Disconnect and Resume | Request a nonterminating debugger detach, then stop the owned OpenOCD process. |
| FROST: Show Output | Open the FROST operation log. |

Attach halts the already loaded application at its current PC using the
selected ELF; it does not reset or reload it. Load commands build the
selected application with the repository's `--debug` profile and load the
resulting BRAM/DDR images. The extension retains the ELF used for that
operation and checks that its build artifacts did not change during the
load. Avoid concurrent builds of the same application.

After the loader exits, load commands wait
`ceil(4 * 2^27 * 1000 / frost.cpuClockHz) + 250` milliseconds before starting
OpenOCD: 3830 ms at 150 MHz or 2040 ms at 300 MHz. The 27-bit image-reset
counter runs at CPU clock/4, holding both the CPU and debug module in reset
for about 3.579 seconds at 150 MHz. Hardware testing found that issuing DMI
while this reset was active could leave the transport persistently busy.
The clock setting must match the bitstream for this guard to be effective.
This wait allows the existing load reset to expire; it introduces no RTL
change or software startup gate. For an externally loaded image, complete
the same interval before using **FROST: Attach Debugger**.

For a BRAM load-and-debug operation, GDB requests reset/halt, verifies PC
zero, and continues to a temporary breakpoint at `main`. DDR load-and-debug
halts at the current PC after cable handoff. The DDR application can
already have executed and changed initialized data; a reset would not
restore that data. DDR therefore has no fresh-stop-at-`main` promise.
Reload the image when fresh initialized DDR contents are needed.

## Cable ownership and cleanup

Before an operation, stop any external OpenOCD/hardware-server session
through its owner. FROST refuses existing servers and occupied ports; it
never adopts or terminates another session's server. A program/load
operation stops its owned Vivado hardware server before starting OpenOCD.
Only one extension operation is active at a time. Progress notifications
offer cancellation, and failures are reported in **FROST: Show Output**.
If cancellation arrives after image loading begins, cleanup waits for the
loader to stop and then for the full image-reset interval before another
command can run. This prevents the next operation from issuing DMI while
the partially loaded image still holds the debug module in reset.

Use **FROST: Disconnect and Resume** to request debugger detach without
target termination. OpenOCD's detach event resumes execution when the
debugger connection closes, including after a crash. The generic VS Code
Stop button has a different shutdown policy and may request target
termination; its behavior is not established by this extension's detach
contract. Restoration of software breakpoints after a crash is unproven;
reload before relying on the image contents.

A small worker owns each native process group and stops that group if the
extension host dies or its IPC connection closes. This includes child
processes created by tool launchers. If cleanup cannot be confirmed, the
extension reports the uncertainty and blocks new operations in that
window. Inspect the operation log and confirm the cable is free before
reopening the workspace and retrying. These mechanisms do not provide a
cross-process cable lock against unrelated applications.

## Debugger scope

The extension launches public `cppdbg` sessions; it provides no custom DAP
adapter or replacement stepping engine. FROST uses software code
breakpoints. It has no hardware code breakpoints or data watchpoints;
`cppdbg` can still show a data-breakpoint action, which should remain
unused. GDB access is limited to low BRAM and DDR to keep automatic memory
prefetch away from device registers with read side effects.

The direct C/C++ 1.29.3 hardware spike verified source breakpoints,
step into/over/out, locals, call stack, selected-register Watches, and DDR
instruction disassembly/stepping. MIEngine still warns that it assumes
`x86_64` despite GDB identifying `riscv:rv64`; the extension supplies no
false `targetArchitecture` override. Initial BRAM disassembly underflow
and stale displayed breakpoint bytes are documented in `fpga/README.md`
in the repository. Console `-exec x/16i $pc` and
`-exec info registers pc sp ra a0` remain available.

The default target description can make the native Registers pane fail on
unsupported optional CSRs such as `vcsr`. `frost.registerDescription: core`
opts into the bundled CPU/FPU description, preserving the captured
OpenOCD register numbers and excluding optional CSR/vector enumeration.
It is specific to the tested FROST RV64 register layout. Its parser and
numbering passed offline checks. On hardware, the native Registers → CPU
pane expanded successfully and an MI bulk read returned all 68 selected
registers, including the FPRs, `fflags`, `frm`, and `fcsr`, without the
`vcsr` error. Reads refreshed after stepping, with changing PC and stack
pointer values. See [the resource notes](resources/README.md).

Hardware checks passed for **Program Bitstream**, the guarded
program/load/OpenOCD/`cppdbg` startup sequence, and **Attach Debugger** at
the current PC with its private ELF copy. **Disconnect and Resume**
resumed UART output through seconds 0–7 at 150 MHz and stopped the owned
OpenOCD process. The initial unguarded examination failure also confirmed
owned-process cleanup without starting GDB; reprogramming restored access.

BRAM load-and-debug automatically stopped at `main` (`0x6a8`) without an
extra Continue. Source step-over, a source breakpoint, step into
`uart_printf`, and step back out to `main` all passed. Native register
refresh returned all 68 values after stepping; SP changed from `0x40000`
to `0x3ffd0`, and PC followed the stepped instructions.

Managed DDR load-and-debug also passed: after the 3830 ms guard, the
debugger halted at the current PC (`0x800006d4`) with `.text` in
`0x80000000`–`0x80000710`. A source breakpoint at `hello_world.c:37`
stopped at `0x800006be`; native disassembly and instruction stepping
covered both 16-bit and 32-bit instructions. A RAM round trip at
`0x80010000` wrote/read `0x0123456789abcdef` and restored the original
`0x00ff00ff00ff00ff`. Core-register bulk reads also passed in DDR.
Managed detach resumed UART seconds 2–7 at approximately 150 million
ticks per second and stopped the owned OpenOCD process. This proves the
current-PC DDR attach flow, with the startup/data limitation above.

This first version does not add Linux/RTOS support, profiling/ILA views,
flash-memory programming, or a UART console.
