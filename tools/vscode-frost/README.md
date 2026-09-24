# FROST FPGA Debugger

Program the X3, load software, debug bare-metal apps, and use the UART console
from VS Code. Install on the Linux FPGA host, directly or through Remote-SSH.
Use official VS Code 1.106+, a trusted FROST workspace, Microsoft C/C++, and
native Vivado, OpenOCD, Python, and RISC-V GDB.

## Build and install locally

From the repository root, build with the pinned image:

```bash
./scripts/frost.py run bash -c 'cd tools/vscode-frost && npm ci && npm run check && npm test && npm run package'
code --install-extension tools/vscode-frost/frost-0.3.0.vsix
```

For Remote-SSH, run **Extensions: Install from VSIX** in the connected window
and install on the FPGA host. Reload the window after installing or upgrading.
For native development, run the npm commands in `tools/vscode-frost` with
Node.js 22+. Packaging creates a local VSIX; it does not publish it.

Run **FROST: Configure Target**, then **FROST: Load Software** or **FROST:
Load Software and Debug**. The serial terminal opens automatically. Resume
a halted CPU to see new output; **FROST: Show Output** displays diagnostics.

## Target settings

Configure the FT4232H serial, exact Vivado target, application, placement,
actual CPU clock in Hz, and CoreMark-PRO mode when applicable. The target path
must be `127.0.0.1:3121/xilinx_tcf/Xilinx/<serial+channel>` as reported by Vivado;
the FTDI serial alone is insufficient. Attach-only use can omit this path.
Ports 3121 and 3333 must be free.

Cable identities and executable paths are machine-scoped User settings, outside
Settings Sync. App/layout/clock selections update existing workspace overrides
or otherwise User settings. Cancelling configuration saves nothing.

Set tool paths in **Settings → FROST** if they are absent from VS Code's host
PATH. Supply executable paths without shell arguments; GDB defaults to
`riscv64-linux-gdb`. Other useful settings:

| Setting | Behavior |
|---------|----------|
| `frost.repoRoot` | Selected workspace folder by default |
| `frost.elf` | Attach ELF; default resolves the app's registered build directory |
| `frost.bitstream` | `.bit` file; empty opens a picker |
| `frost.cpuClockHz` | Required actual bitstream clock; no assumed default |
| `frost.loadTimeoutMs` | Plain-load timeout, default two hours for first Linux builds |
| `frost.toolTimeoutMs` | Debug/program timeout |

Artifact paths are repository-relative. Attach requires the ELF matching the
loaded image; load-and-debug uses its own build. CoreMark-PRO aliases share
`sw/apps/coremark_pro`.

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

**FROST: Load Software** offers the repository loader's apps, including Linux
and benchmarks, and leaves the CPU running. Debug commands keep a separate
app selection. Placement choices are:

- **BRAM / default application layout:** use the app's layout, which may include DDR.
- **DDR relocation:** request `--ddr`; fixed-layout apps retain their placement.
- **CoreMark-PRO:** choose validation (`-v1`) or performance (`-v0`).

Repository app/board/layout restrictions still apply. Cancellation waits for
the loader to stop and image reset to settle before accepting another operation.

## Serial console

**FROST Serial** is bidirectional raw 8N1, without flow control or local echo.
Typed characters appear only if the target echoes them. Output pauses while
the CPU is halted. Close with **FROST: Close Serial Console**, the terminal's
close button, or **Ctrl+]**. Detach leaves it open.

`frost.serial.autoOpen` defaults to true. `frost.serial.port=auto` prefers a
stable `/dev/serial/by-id` FT4232H `if02` device matching `frost.jtagSerial`,
then falls back to the repository's X3 default (`/dev/ttyUSB3`). Ambiguous or
mismatched stable identities are refused; set an explicit path when needed.
`frost.serial.baudRate` defaults to 115200. Close and reopen after settings changes.

Close other serial readers first. The console stays open during managed JTAG
work; an automatic connection failure does not block the FPGA operation.
Large pastes are limited to 64 KiB pending input. No pyserial install is needed.

## Optional focused workspace

**Apply Focus Layout** hides bars, minimap, and the chat toolbar button and
configures Zen preferences. **Restore Layout** restores saved User values
while preserving later changes. Workspace overrides remain effective.
**Toggle Zen Mode** enters/exits Zen; Escape twice also exits.

For an independent extension set, import
[FROST.code-profile](resources/FROST.code-profile) into a new **FROST Debug**
profile, with independent Settings and UI State, then install the VSIX there.
See [focus instructions](resources/FOCUS.md) for profile-sharing limits.

## Debugging

Attach halts the loaded app at its current PC. Load-and-debug builds with
`--debug` and keeps a private ELF for the session. Avoid concurrent builds of
apps sharing a directory. `linux_boot` and `opensbi_smoke` are load-only
composite images. FreeRTOS supports CPU/source inspection without task views.
Debug benchmark timings are not reportable scores; use normal loading.

Managed loads wait for image reset: 1916 ms at 322.265625 MHz or 3582 ms at half rate.
After an external load, wait `ceil(4 * 2^27 * 1000 / CPU_clock_Hz) + 250` ms
before Attach. Startup depends on the built ELF:

| Built image | Initial debug stop |
| --- | --- |
| BRAM entry at zero, `main` present, no initialized writable DDR data | Reset/halt, verify PC zero, then continue to a temporary breakpoint at `main`. |
| The same BRAM conditions, without `main` | Reset/halt at PC zero for assembly source or instruction stepping. |
| DDR execution, initialized writable DDR data, or another entry address | Halt at the current PC after cable handoff. |

A default BRAM app can still contain initialized DDR data. Execution during
cable handoff can change it, and reset does not restore it; reload when needed.
`isa_test` uses `s0` in instruction tests, so frame-pointer unwinding is unavailable.

## Cable ownership and cleanup

Stop external OpenOCD/hardware-server sessions through their owners before
using FROST. The extension refuses occupied ports and never adopts or stops
another session's server. It allows one operation at a time and manages its
own Vivado/OpenOCD handoff. Progress notifications offer cancellation.

Use **FROST: Disconnect and Resume** for a nonterminating detach. Generic VS
Code Stop can request target termination. Reload after a debugger crash because
software breakpoint restoration is not guaranteed.

If native-process cleanup cannot be confirmed, new operations are blocked.
Inspect **FROST: Show Output**, confirm the cable is free, then reopen the
workspace. Process cleanup does not provide a lock against unrelated tools.

## Debugger scope

Supported: software breakpoints, source/instruction stepping, registers,
locals, and call stack. Hardware breakpoints, watchpoints, Linux debugging,
RTOS task views, profiling/ILA views, and persistent flash programming are
unavailable. GDB memory access is limited to BRAM and DDR to avoid MMIO side effects.

For optional-CSR failures in Registers, set `frost.registerDescription=core`
([details](resources/README.md)). For display problems, use
`-exec x/16i $pc` or `-exec info registers pc sp ra a0` in Debug Console.
MIEngine can report an `x86_64` assumption despite GDB reporting RV64;
disassembly can prefetch below BRAM or display stale breakpoint bytes.
Expanded application/startup support in version 0.3 awaits hardware validation.
