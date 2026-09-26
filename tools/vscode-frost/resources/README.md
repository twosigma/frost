# FROST core register description

`frost-core.xml` is an optional GDB target description for FROST's RV64 core.
It describes the integer registers, `pc`, the floating-point registers, and
the floating-point CSRs, and leaves out optional CSRs such as `vcsr` that can
make GDB's bulk register reads fail. The extension uses it when
`frost.registerDescription` is `core`.

| Registers | OpenOCD remote register numbers | Wire width |
| --- | --- | --- |
| `x0`–`x31`, using ABI names, and `pc` | 0–32 | 64 bits |
| `f0`–`f31`, using ABI names | 33–64 | 64 bits |
| `fflags`, `frm`, `fcsr` | 66, 67, 68 | 64 bits |

Each register carries an explicit `regnum` that matches OpenOCD's numbering,
including the gap at 65. Do not renumber registers when editing this file.
Keep every register that the CPU and FPU features require: GDB can reject a
description with a member missing. The floating-point registers keep
OpenOCD's `FPU_FD` union of single and double views, and the floating-point
CSRs keep `save-restore="no"` and their 64-bit transfer width. FROST
implements `fflags` in bits 4:0, `frm` in bits 2:0, and `fcsr` as
`{frm, fflags}` in bits 7:0; the other bits read zero (see the
[CSR file](../../../hw/rtl/cpu_and_mem/cpu/csr/csr_file.sv)).

## Loading the description

Set the file in a fresh GDB session, **before** connecting to OpenOCD:

```text
set tdesc filename /absolute/path/to/resources/frost-core.xml
target extended-remote 127.0.0.1:3333
```

The extension passes its installed copy's path in the `cppdbg` setup
commands. The setting replaces the target's own description for that GDB
session only; OpenOCD and the processor are unchanged. `unset tdesc filename`
returns to the target's description. Start a new debug session after
changing it, because the adapter caches register metadata.

GDB takes everything after `set tdesc filename` as the file name, spaces
included. Do not quote it: GDB treats the quotes as part of the name and only
warns when the open fails. With `-interpreter-exec console`, quote the whole
command as one MI string and nothing inside it.

## Limits

The description supports reading and refreshing registers while stepping in
BRAM or DDR. FROST's debug module reads GPRs through abstract commands;
OpenOCD reads floating-point registers and CSRs through its program buffer
fallback. Individual register watches and `info registers pc sp ra a0` also
work.

The file has no general CSR, profiling-counter, or vector registers. A server
with different remote register numbers, or a core with a different XLEN or
FLEN, needs its own description. OpenOCD's
[CSR exposure logic](https://github.com/openocd-org/openocd/blob/b6ee13720/src/target/riscv/riscv.c#L4231)
shows what the server itself reports.
