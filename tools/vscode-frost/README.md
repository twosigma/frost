# FROST FPGA Debugger

A local VS Code extension to program, load, debug, and use the UART console
on the FROST X3 FPGA. Bare-metal debugging uses Microsoft's public `cppdbg`
debugger through the installed C/C++ extension and native RISC-V GDB/OpenOCD.
Plain software loading uses the repository's native Vivado loader, including
its Linux and benchmark applications.

Install the VSIX in official VS Code on the Linux FPGA host, or on that
host through Remote-SSH. The workspace extension and all native tools must
run on the host with the repository and FPGA cable. It requires a trusted
workspace and Microsoft C/C++ (`ms-vscode.cpptools`).

## Build and install locally

The Docker image includes Node.js 26.9.0 and npm 12.0.2. Build tools
are pinned to TypeScript 7.0.2 and vsce 4.0.0. The VS Code 1.106 API floor
is retained; `@types/vscode` describes that supported API, and the Node type
baseline is 22 to match the extension host rather than the build runtime.

From the repository root, validate and package with the pinned image:

```bash
./scripts/frost.py run bash -c 'cd tools/vscode-frost && npm ci && npm run check && npm test && npm run package'
```

From `tools/vscode-frost`, with Node.js 22 or newer:

```bash
npm ci
npm run check
npm test
npm run package
code --install-extension frost-0.3.0.vsix
```

For Remote-SSH, use **Extensions: Install from VSIX** in the connected VS
Code window and install it on the FPGA host. Native Vivado remains a host
prerequisite; the repository's Docker image is for cocotb/regression tools.
Packaging does not publish to the Marketplace.

After installing or upgrading the VSIX, run **Developer: Reload Window**.
Run **FROST: Configure Target** once, then choose **FROST: Load Software**
for a normal application run or **FROST: Load Software and Debug** to choose
an application and debug it. The **FROST Serial** terminal opens automatically
by default. Resume a halted CPU to see new UART output. **FROST: Show Output**
contains build, programming, and connection diagnostics.

## Target settings

Open the FROST repository, then run **FROST: Configure Target**. Enter the
exact FT4232H JTAG bridge serial and full Vivado target path, then choose
an application, layout, actual CPU clock in Hz, and CoreMark-PRO mode when
applicable. This is the same repository-backed picker used by the two
load-and-debug commands. Cable identities are saved to User settings on the
extension host. Application, layout, clock, and run-mode choices update their
existing workspace-folder or workspace overrides, otherwise User settings.
Cancelling a prompt saves nothing. A Vivado target may be left
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
are resolved relative to the repository. With `frost.elf` empty, Attach uses
`sw/apps/<registered build directory>/sw.elf`; aliases such as
`coremark_pro_core` resolve to the shared `sw/apps/coremark_pro` directory.
An explicit `frost.elf` overrides that path for Attach and must match the
already loaded image. Load-and-debug uses the ELF returned by its own build.
`frost.bitstream` selects a `.bit` file; if empty, program commands open a
file picker. `frost.cpuClockHz` has no assumed board-clock default: supply
the frequency used by the actual bitstream.

## Commands

| Command | Purpose |
| --- | --- |
| FROST: Configure Target | Save the cable, Vivado target, clock and application choices. |
| FROST: Load Software | Choose any application accepted by the repository loader and run it using its normal build profile. |
| FROST: Attach Debugger | Attach `cppdbg` to the already loaded application. |
| FROST: Load Software and Debug | Choose and save a debug application, build/load it, then debug it. |
| FROST: Program Bitstream | Program volatile FPGA configuration. |
| FROST: Program Bitstream, Load and Debug | Choose and save a debug application, program the FPGA, load and debug it. |
| FROST: Disconnect and Resume | Request a nonterminating debugger detach, then stop the owned OpenOCD process. |
| FROST: Show Output | Open the FROST operation log. |
| FROST: Open Serial Console | Open or reconnect the integrated bidirectional UART terminal. |
| FROST: Close Serial Console | Close the terminal and release its owned UART connection. |
| FROST: Apply Focus Layout | Apply the optional quieter layout and save previous User values. |
| FROST: Restore Layout | Restore saved layout values while preserving subsequent user changes. |
| FROST: Toggle Zen Mode | Enter or leave VS Code's Zen Mode. |

## Plain software loading

**FROST: Load Software** reads the application list from the current
repository's loader. Its picker includes benchmark, test, and `linux_boot`
applications. Debug commands use a separately saved application selection.
Choose an application, its placement, and the actual FPGA CPU clock:

- **BRAM / default application layout** leaves placement to the app's Makefile.
  An app can still use DDR with this choice.
- **DDR relocation** passes the loader's `--ddr` option. Apps with fixed layouts
  retain their own placement.
- CoreMark-PRO workloads also ask for **Validation (-v1)** or **Performance (-v0)**.

This command uses the normal build profile, supplies the selected clock,
loads through the existing Python/Tcl flow, and leaves the CPU running.
It does not request `--debug` or start cppdbg, GDB, or OpenOCD. C/C++ remains
an installed extension dependency for the debugger commands. Loader
restrictions still apply: appearing in the registry does not make every
app/board/layout combination supported.

`frost.loadTimeoutMs` defaults to 7,200,000 ms (two hours), allowing for a
first Linux build. Debug/program operations continue to use
`frost.toolTimeoutMs`. Cancelling a load stops its owned loader and finishes
the image-reset settling interval before another operation is accepted.

## Serial console

The integrated **FROST Serial** terminal displays UART RX and sends typed
text to UART TX. It is raw 8N1 with no flow control or local echo: typed
characters appear only if the target echoes them. Application UART output
normally pauses while the debugger halts the CPU and resumes when it runs.
The terminal preserves UTF-8 characters split across transport reads.

`frost.serial.autoOpen` defaults to `true` for program, load, and debug
commands. Set it to `false` for manual use through **FROST: Open Serial
Console**. **FROST: Close Serial Console**, closing its terminal, or
**Ctrl+]** while that terminal has focus releases the connection. Debugger
detach leaves the serial console open so resumed program output stays visible.
After changing serial settings, close and reopen the console.

`frost.serial.port` defaults to `auto`: prefer a stable
`/dev/serial/by-id` X3/FT4232H `if02` UART matching `frost.jtagSerial`, then
use the repository's X3 default, currently `/dev/ttyUSB3`, when no stable
candidate exists. Ambiguous identities, or stable candidates belonging to
a different configured board, are refused. Set an explicit path to select
that exact device. `frost.serial.baudRate` defaults to 115200; the backend
accepts Linux's standard baud rates. Large pastes are bounded to a 64 KiB
pending input queue; send smaller chunks if it reports that the queue is full.

The console stays open during managed JTAG work and restores its serial
settings afterward. Close external serial terminals before opening FROST
Serial; it refuses connections when it detects another reader. An automatic
console connection failure does not prevent the requested FPGA operation.
No `pyserial` installation is required.

## Optional focused workspace

**FROST: Apply Focus Layout** hides the activity/status bars, minimap, and
chat toolbar button, and configures Zen preferences. **FROST: Restore
Layout** restores saved User overrides, preserving values that differ from
those applied. Neither command changes extension enablement. Workspace overrides
can still affect the visible result. **FROST: Toggle Zen Mode** enters or
leaves Zen; Escape twice also exits. Zen suppresses ordinary notification
popups while keeping errors visible.

For a separate extension set and layout, manually import
[FROST.code-profile](resources/FROST.code-profile) through **File → Preferences
→ Profiles → New Profile → Import Profile** into a **new FROST Debug profile**.
Keep Settings and UI State independent, review the import, and install the
local VSIX in that profile. This template requests C/C++; built-ins and
extensions applied to all profiles can still appear. Switching back restores
your previous profile. See [the focus instructions](resources/FOCUS.md) for
shared-setting restrictions and restoration details.

The 0.2 workbench check exercised Apply, Zen, and Restore: Restore removed
all 11 added overrides and preserved the other settings. Import through the
public Profiles UI created a separate FROST Debug profile with those 11
settings and C/C++ 1.33.8; the original Default profile remained active.

## Debugging

Both load-and-debug commands offer the loader's application list and save
your application, layout, clock, and CoreMark-PRO mode for later Attach.
`linux_boot` and `opensbi_smoke` are load-only because their composite images
need multi-ELF debugging. Cancelling a selection leaves the current session
connected.

Attach halts the loaded application at its current PC using a matching ELF.
Load-and-debug builds with `--debug`, loads the images, and keeps a private
ELF copy for the session. Avoid concurrent builds of the same application
or aliases that share its build directory.

`freertos_demo` supports source and CPU debugging without task-aware thread
views or RTOS inspection. Debug CoreMark/CoreMark-PRO runs use different
compiler settings and debugger pauses; their timings are not reportable
benchmark scores, even when the picker selects Performance (-v0).
Use normal **FROST: Load Software** runs for benchmark measurements.

Managed loads wait for the image-load reset before starting OpenOCD:
2040 ms at 300 MHz or 3830 ms at 150 MHz. Set `frost.cpuClockHz` to the
actual bitstream clock; an early debug request can leave the transport busy.
After an external load, wait
`ceil(4 * 2^27 * 1000 / frost.cpuClockHz) + 250` milliseconds before Attach.

The loader selects startup behavior from the actual ELF:

| Built image | Initial debug stop |
| --- | --- |
| BRAM entry at zero, `main` present, no initialized writable DDR data | Reset/halt, verify PC zero, then continue to a temporary breakpoint at `main`. |
| The same BRAM conditions, without `main` | Reset/halt at PC zero for assembly source or instruction stepping. |
| DDR execution, initialized writable DDR data, or another entry address | Halt at the current PC after cable handoff. |

The five standalone assembly apps (`branch_pred_test`, `c_ext_test`,
`cf_ext_test`, `fpu_assembly_test`, and `ras_test`) have no `main` and use
the reset stop in their default BRAM layout. An app selected as **BRAM /
default application layout** can still contain writable DDR data and use
current-PC attach. Execution during handoff can change that data; reset
alone would not restore it. Reload when fresh initialized DDR contents are
needed. `isa_test` deliberately leaves the frame-pointer register available
to its instruction tests, so ordinary frame-pointer stack unwinding is
unavailable for that app.

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

FROST supports software code breakpoints, source and instruction stepping,
registers, locals, and the call stack. Hardware code breakpoints and data
watchpoints are unavailable, even if C/C++ displays those actions. GDB
memory access is limited to BRAM and DDR to avoid device-register side effects.

If the Registers pane fails on an optional CSR such as `vcsr`, set
`frost.registerDescription` to `core` to use the bundled FROST CPU/FPU
register layout. See the [resource notes](resources/README.md).
MIEngine may still warn that it assumes `x86_64` despite GDB reporting RV64.

For disassembly or register-view problems, use `-exec x/16i $pc` or
`-exec info registers pc sp ra a0` in the Debug Console. Native disassembly
can prefetch below BRAM or retain stale breakpoint bytes in its display.

Linux loading is supported; Linux debugging is not. FreeRTOS debugging has
no task awareness. Profiling/ILA views and persistent flash programming are
not implemented. The expanded application and startup support in 0.3 still
awaits hardware testing.
