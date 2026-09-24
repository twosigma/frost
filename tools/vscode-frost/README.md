# FROST FPGA Debugger

This VS Code extension programs a FROST X3 board, builds and loads software
over JTAG, debugs bare-metal programs through GDB and OpenOCD, and provides a
two-way UART console. It runs on the Linux host with the FPGA cable, locally
or through Remote-SSH, and calls the repository's own build and load scripts.

It needs official VS Code 1.106 or newer, a trusted FROST workspace, the
Microsoft C/C++ extension, and native Vivado, OpenOCD, Python, and RISC-V GDB
on the FPGA host.

## Build and install locally

From the repository root, build with the pinned Docker image and install:

```bash
./scripts/frost.py run bash -c 'cd tools/vscode-frost && npm ci && npm run check && npm test && npm run package'
code --install-extension tools/vscode-frost/frost-0.3.0.vsix
```

For Remote-SSH, run **Extensions: Install from VSIX** in the connected window
so the extension installs on the FPGA host. Reload the window after
installing or upgrading. To build without Docker, run the same npm commands in
`tools/vscode-frost` with Node.js 22 or newer. Packaging creates a local VSIX
and publishes nothing.

Then run **FROST: Configure Target**, followed by **FROST: Load Software** or
**FROST: Load Software and Debug**. The **FROST Serial** terminal opens
automatically, and **FROST: Show Output** shows the build and tool logs.

## Target settings

**FROST: Configure Target** asks for the FT4232H JTAG serial and the exact
Vivado target, then an application, its placement, and a CoreMark-PRO mode
when one applies. The Vivado target is the full path Vivado reports,
`127.0.0.1:3121/xilinx_tcf/Xilinx/<serial+channel>`; the FTDI serial alone is
not enough. Leave it empty for attach-only use. The extension runs its own
hardware server on port 3121 and OpenOCD on port 3333, and both ports must be
free.

Cable identities and tool paths are machine-scoped User settings, so Settings
Sync does not copy them. Application, placement, and clock choices update an
existing workspace override, or User settings otherwise. Cancelling Configure
Target saves nothing.

If a tool is not on VS Code's `PATH` on the host, set its path under
**Settings → FROST** (`frost.pythonPath`, `frost.openocdPath`,
`frost.gdbPath`, `frost.vivadoPath`, `frost.hwServerPath`). Give the
executable only, without arguments. GDB defaults to `riscv64-linux-gdb`.

| Setting | Default | Behavior |
|---------|---------|----------|
| `frost.repoRoot` | Workspace folder | Repository root, relative to the workspace folder or absolute |
| `frost.cpuClockHz` | `322265625` | CPU clock of the programmed bitstream; `161132812` for a `--cpu-clock-div 2` build |
| `frost.bitstream` | Empty | `.bit` file for the program commands; empty opens a file picker |
| `frost.elf` | Empty | ELF for Attach; empty uses `sw.elf` in the app's build directory |
| `frost.loadTimeoutMs` | 2 hours | Timeout for Load Software, long enough for a first Linux build |
| `frost.toolTimeoutMs` | 5 minutes | Timeout for debug loads and programming |
| `frost.startupTimeoutMs` | 20 seconds | Timeout for starting the debugger or a hardware server |

Relative paths resolve against the repository. Attach needs the ELF of the
image that is loaded; the debug load commands use the ELF they just built.
CoreMark-PRO workloads share the `sw/apps/coremark_pro` build directory.

## Commands

| Command | Purpose |
| --- | --- |
| FROST: Configure Target | Save the cable, Vivado target, and application choices. |
| FROST: Load Software | Build any application the repository loader accepts, with its normal build profile, and run it. |
| FROST: Attach Debugger | Attach `cppdbg` to the application that is already loaded. |
| FROST: Load Software and Debug | Choose and save a debug application, build and load it, then debug it. |
| FROST: Program Bitstream | Program the FPGA's volatile configuration. |
| FROST: Program Bitstream, Load and Debug | Choose and save a debug application, program the FPGA, then load and debug it. |
| FROST: Disconnect and Resume | Request a detach that leaves the program running, then stop OpenOCD. |
| FROST: Show Output | Open the FROST operation log. |
| FROST: Open Serial Console | Open or reconnect the UART terminal. |
| FROST: Close Serial Console | Close the terminal and release the UART. |
| FROST: Apply Focus Layout | Apply an optional quieter layout, saving the previous User settings. |
| FROST: Restore Layout | Restore the saved settings, keeping any you changed since. |
| FROST: Toggle Zen Mode | Enter or leave VS Code's Zen Mode. |

## Loading software

**FROST: Load Software** offers every application the repository loader
accepts, including Linux and the benchmarks, and leaves the CPU running. It
does not change the application the debug commands remember. It asks for a
placement:

| Placement | Effect |
|---|---|
| BRAM / default application layout | The app's own layout, which may include DDR |
| DDR relocation | Passes `--ddr`; apps with a fixed layout keep it |

CoreMark-PRO workloads also ask for validation (`-v1`) or performance (`-v0`)
mode. The loader's own restrictions on apps, boards, and layouts still apply.
Cancelling waits for the loader to exit and the image reset to settle before
another operation can start.

## Serial console

**FROST Serial** is a raw two-way UART terminal at 8N1, with no flow control
or local echo, so typed characters appear only if the program echoes them.
Output pauses while the CPU is halted. Close it with
**FROST: Close Serial Console**, the terminal's close button, or **Ctrl+]**.
Detaching the debugger leaves it open.

| Setting | Default | Behavior |
|---------|---------|----------|
| `frost.serial.autoOpen` | `true` | Open the console for program, load, and debug commands |
| `frost.serial.port` | `auto` | Prefer the stable `/dev/serial/by-id` FT4232H `if02` device matching `frost.jtagSerial`, else the repository's X3 default (`/dev/ttyUSB3`). Ambiguous or mismatched devices are refused; set an explicit path instead. |
| `frost.serial.baudRate` | `115200` | Baud rate |

Close and reopen the console after changing these settings. Close other
programs that read the port first: the console refuses the port when it
detects another reader.
It stays open during JTAG operations, and a failed automatic connection does
not stop the FPGA operation. Pasted input is limited to 64 KiB waiting to be
sent. No pyserial install is needed.

## Focus layout

**FROST: Apply Focus Layout** hides the activity bar, status bar, minimap,
and chat button, and sets Zen Mode preferences. **FROST: Restore Layout** puts
back the saved User settings but keeps any you changed since.
[FOCUS.md](resources/FOCUS.md) lists the settings and explains how to import
[FROST.code-profile](resources/FROST.code-profile) as a separate
**FROST Debug** profile.

## Debugging

Attach halts the loaded program at its current PC. The debug load commands
build with `--debug`, load the image, and give the debugger a private copy of
the ELF for the session. Avoid concurrent builds of apps that share a build
directory: a load stops if the image changes under it.

`linux_boot` and `opensbi_smoke` are composite images that can be loaded but
not debugged. FreeRTOS programs support CPU and source debugging, without
task views. Timings from debug builds of benchmarks are not valid scores; use
**FROST: Load Software** for measurements.

After a load, the debug module stays in reset until the image-load reset
releases, and a debugger access during that time can be lost. Managed loads
wait for it before starting OpenOCD: 1916 ms at 322.265625 MHz, 3582 ms at
half rate. After loading an image some other way, wait
`ceil(4 * 2^27 * 1000 / CPU_clock_Hz) + 250` ms before Attach.

The first stop depends on the built image:

| Built image | Initial debug stop |
| --- | --- |
| BRAM entry at zero, `main` present, no initialized writable DDR data | Reset and halt, check that the PC is zero, then run to a temporary breakpoint at `main`. |
| The same BRAM conditions, without `main` | Reset and halt at PC zero, for assembly source or instruction stepping. |
| DDR execution, initialized writable DDR data, or another entry address | Halt at the current PC after the cable handoff. |

An app in the default BRAM layout can still have initialized DDR data. The
program can run during the cable handoff and change it, and a reset does not
restore it, so reload the image when you need that data fresh. `isa_test`
clobbers `s0` in its compressed-instruction tests, so frame-pointer unwinding
does not work there.

## Cable handoff and cleanup

The program, load, and debug commands refuse to run while any other OpenOCD
or `hw_server` process is running on the host, or while port 3121 or 3333 is
in use. The extension never adopts or stops another session's server, so stop
those sessions through whatever started them. It runs one operation at a
time, moves the cable between Vivado and OpenOCD itself, and offers
cancellation in its progress notification.

End a session with **FROST: Disconnect and Resume**, which requests a detach
that leaves the program running. If the detach is not confirmed, the
extension falls back to VS Code's generic Stop, which can ask to terminate the
target, and stops OpenOCD anyway. After a debugger crash or an unconfirmed
detach, reload the image, because the extension cannot guarantee that
software breakpoints were removed from memory.

If the extension cannot confirm that its native processes stopped, it blocks
new operations. Check **FROST: Show Output**, confirm that the cable is free,
then close and reopen the window. This cleanup does not lock the cable
against unrelated tools.

## Debugger scope

Supported: software breakpoints, source and instruction stepping, registers,
locals, and the call stack. Not available: hardware breakpoints, watchpoints,
Linux debugging, RTOS task views, profiling or ILA views, and persistent flash
programming. GDB can access only BRAM and DDR, so it never reads a device
register that has read side effects.

## Known issues

- The extension is a preview release. On the board, debugging has been
  tested with `hello_world` and `debug_target`, not yet with the other
  applications the picker offers.
- If the Registers view fails on an optional CSR such as `vcsr`, set
  `frost.registerDescription` to `core` to use the bundled CPU and FPU
  register description ([details](resources/README.md)).
- MIEngine can report that it assumes `x86_64` even though GDB reports RV64.
- The disassembly view can try to read below the start of BRAM or show stale
  breakpoint bytes. In the Debug Console, `-exec x/16i $pc` and
  `-exec info registers pc sp ra a0` show the real state.
