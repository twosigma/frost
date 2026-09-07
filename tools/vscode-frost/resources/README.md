# FROST core register description

`frost-core.xml` is an opt-in GDB target description for FROST's RV64 core.
It limits the native Registers pane to 68 named registers. The OpenOCD build
used in the September 7, 2026 X3 spike advertised unsupported optional CSRs,
including `vcsr`; GDB's bulk register read then failed on that register.
This resource keeps the CPU and FPU features from that session's actual target
description and omits the remaining CSR and virtual-register features.

| Registers | OpenOCD remote register numbers | Wire width |
| --- | --- | --- |
| `x0`–`x31`, using ABI names, and `pc` | 0–32 | 64 bits |
| `f0`–`f31`, using ABI names | 33–64 | 64 bits |
| `fflags`, `frm`, `fcsr` | 66, 67, 68 | 64 bits |

The explicit register numbers preserve the server's numbering, including the
gap at 65. Do not renumber registers when pruning this file. Floating-point
registers retain OpenOCD's `FPU_FD` union with single- and double-precision
interpretations. The floating-point CSRs retain `save-restore="no"` and their
64-bit transfer width. FROST implements `fflags` in bits 4:0, `frm` in bits 2:0,
and `fcsr` as `{frm, fflags}` in bits 7:0; the remaining bits read zero. See
[the CSR implementation](../../../hw/rtl/cpu_and_mem/cpu/csr/csr_file.sv).

GDB requires the complete `org.gnu.gdb.riscv.cpu` feature. If the optional FPU
feature is present, it requires all 32 floating-point registers plus `fflags`,
`frm`, and `fcsr`. A CPU-only description can be used for a separate diagnostic
experiment, but it would remove floating-point register inspection from that
session. These requirements come from
[GDB's RISC-V target feature documentation](https://sourceware.org/gdb/current/onlinedocs/gdb.html/RISC_002dV-Features.html).

## Loading the description

Set the filename in a fresh GDB session **before** connecting to OpenOCD:

```text
set tdesc filename /absolute/path/to/resources/frost-core.xml
target extended-remote 127.0.0.1:3333
```

The extension supplies its installed resource path in `cppdbg` setup commands.
This setting replaces the target-supplied description for that GDB session;
it does not change OpenOCD or the processor. `unset tdesc filename` restores
target-supplied descriptions. Start a fresh debug session when changing this
option because the adapter caches register metadata.

GDB's `set tdesc filename` takes the entire remaining text as the filename,
including spaces. Do not add quotation marks around the filename: GDB 16.3
includes those marks in the filename and only emits a warning when opening it
fails. When using `-interpreter-exec console`, escape the whole command as an MI
string; do not separately quote the filename inside it.

## Validation and limits

Offline validation with xPack GDB 16.3 checked that both XML features exactly
preserve the captured OpenOCD register metadata, that GDB accepts and prints the
description without warnings, and that MI register discovery returns exactly
the 68 intended names. The same check passed with a resource filename containing
spaces. GDB still reserves 4,194 internal register-number slots, most with empty
names; those empty slots are expected and do not represent extra exposed CSRs.

The extension's X3 hardware session subsequently expanded Registers → CPU
successfully. An actual MI bulk register-value request returned all 68 selected
registers, including the 32 FPRs and `fflags`, `frm`, and `fcsr`, without the
previous `vcsr` failure. These checks establish live register-read availability
as well as parser and numbering compatibility. Subsequent source stepping also
refreshed all 68 register values: SP changed from `0x40000` to `0x3ffd0`, and
PC advanced through `0x6a8`, `0x6b6`, `0x6bc`, and `0x6be`. This verifies
register-pane refresh during the BRAM debug session.

The managed DDR session also successfully read the complete core-register
set while debugging code at `0x80000000`. Its source breakpoint stopped
at `0x800006be`, and native instruction stepping advanced through both
32-bit and 16-bit instructions to `0x800006d4`.

FROST's debug module implements abstract GPR access; OpenOCD uses its program
buffer fallback for floating-point and CSR access. Individual register Watches
and explicit `info registers pc sp ra a0` also remain available.

This file intentionally provides no general CSR, profiling-counter, or vector
register view. Changing the server's remote register numbering or using a core
with a different XLEN/FLEN requires a matching target description. The underlying
server behavior can be inspected in the exact
[OpenOCD CSR exposure logic](https://github.com/openocd-org/openocd/blob/b6ee13720/src/target/riscv/riscv.c#L4231).
