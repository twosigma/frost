# FROST core register description

`frost-core.xml` is an opt-in GDB target description for FROST's RV64 core.
It exposes 68 core and floating-point registers, avoiding unsupported optional
CSRs such as `vcsr` that can make GDB's bulk register reads fail.

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

Keep all CPU and FPU registers required by the target-description features;
pruning individual members can make GDB reject the description.

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
including spaces. Do not add quotation marks around the filename: GDB
includes those marks in the filename and only emits a warning when opening it
fails. When using `-interpreter-exec console`, escape the whole command as an MI
string; do not separately quote the filename inside it.

## Validation and limits

The description supports register reads and refreshes while stepping code in
BRAM or DDR. FROST's debug module implements abstract GPR access; OpenOCD uses its program
buffer fallback for floating-point and CSR access. Individual register Watches
and explicit `info registers pc sp ra a0` also remain available.

This file intentionally provides no general CSR, profiling-counter, or vector
register view. Changing the server's remote register numbering or using a core
with a different XLEN/FLEN requires a matching target description. The underlying
server behavior can be inspected in the exact
[OpenOCD CSR exposure logic](https://github.com/openocd-org/openocd/blob/b6ee13720/src/target/riscv/riscv.c#L4231).
