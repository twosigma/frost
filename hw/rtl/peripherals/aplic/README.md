# APLIC

`aplic.sv` is an Advanced Platform-Level Interrupt Controller as specified by
the RISC-V Advanced Interrupt Architecture (AIA) 1.0, chapter 4. It has two
interrupt domains, a machine-level root domain and one supervisor-level child
domain, and delivers interrupts directly to harts: the root domain drives each
hart's machine external interrupt (MEIP) and the supervisor domain each hart's
supervisor external interrupt (SEIP). Software sees two separate controllers,
one per domain, as OpenSBI and Linux expect from a device tree with one
`riscv,aplic` node per domain. The SoC does not instantiate it yet; FROST's
interrupt controller is still the PLIC in `cpu_and_mem/plic.sv`.

## Parameters

| Parameter | Default | Range | Meaning |
|-----------|---------|-------|---------|
| `NUM_SOURCES` | 5 | 1 to 1023 | Interrupt sources, with identity numbers 1 to `NUM_SOURCES` |
| `NUM_HARTS` | 1 | 1 to 512 | Hart indices 0 to `NUM_HARTS - 1`, one IDC per hart in each domain |
| `IPRIOLEN` | 3 | 1 to 8 | Implemented priority bits; priority numbers run from 1 to `2^IPRIOLEN - 1` |

The default covers the PLIC's five sources. Simulation stops at time zero if a
parameter is out of range.

## Interface

The register interface has the shape of the PLIC's, so that the two can be
exchanged in the SoC.

| Port | Meaning |
|------|---------|
| `i_src[NUM_SOURCES-1:0]` | Source wires, bit 0 for source 1, synchronous to `i_clk` |
| `i_wr_en`, `i_wr_offset[21:0]`, `i_wr_data[31:0]` | One register write: its byte offset in the 4 MiB window and its 32-bit value |
| `i_rd_offset[21:0]`, `o_rd_pair[63:0]` | Combinational read of the aligned dword at the offset: the register at offset+4 in bits 63:32, the one at offset in bits 31:0 |
| `i_rd_capture` | Pulses once for each performed read, on the clock edge that captures `o_rd_pair` into the bus response |
| `o_meip[NUM_HARTS-1:0]`, `o_seip[NUM_HARTS-1:0]` | Registered interrupt lines of the root and supervisor domains, by hart index |

The AIA supports only naturally aligned 32-bit reads and writes in a domain's
control region and requires other accesses to be ignored. The SoC therefore
asserts `i_wr_en` only for a 32-bit store, and `i_rd_capture` only for a
32-bit load. A read's side effect, the claim of a `claimi` read, applies to
the word at `i_rd_offset`, so the SoC passes the load's full offset, with bit
2 selecting the word of the pair. The byte offset within a word, bits 1:0, is
ignored.

## Window

| Window offset | Size | Contents |
|---------------|------|----------|
| `0x0000` | 32 KiB | Control region of the root (machine-level) domain |
| `0x8000` | 32 KiB | Control region of the supervisor-level domain |

The rest of the 4 MiB window reads zero and ignores writes.

## Registers

Both domains have the same register map, at these offsets inside their
control regions. Every register is 32 bits wide.

| Offset | Register | Behavior |
|--------|----------|----------|
| `0x0000` | `domaincfg` | Bits 31:24 read `0x80`; bit 8 is IE, the domain's interrupt enable. DM (bit 2) and BE (bit 0) read zero: direct delivery, little-endian |
| `0x0004` + 4(i-1) | `sourcecfg[i]` | Source mode or delegation of source i (below) |
| `0x1BC0`–`0x1BCC` | `mmsiaddrcfg`, `mmsiaddrcfgh`, `smsiaddrcfg`, `smsiaddrcfgh` | Read zero: no domain has MSI delivery mode |
| `0x1C00` + 4k | `setip[k]` | Reads the pending bits of sources 32k to 32k+31; writing ones sets them where the source mode allows |
| `0x1CDC` | `setipnum` | Writing i sets source i's pending bit where allowed; reads zero |
| `0x1D00` + 4k | `in_clrip[k]` | Reads the rectified inputs; writing ones clears pending bits where allowed |
| `0x1DDC` | `clripnum` | Writing i clears source i's pending bit where allowed; reads zero |
| `0x1E00` + 4k | `setie[k]` | Reads the enable bits; writing ones sets them |
| `0x1EDC` | `setienum` | Writing i sets source i's enable bit; reads zero |
| `0x1F00` + 4k | `clrie[k]` | Writing ones clears enable bits; reads zero |
| `0x1FDC` | `clrienum` | Writing i clears source i's enable bit; reads zero |
| `0x2000` | `setipnum_le` | As `setipnum` |
| `0x2004` | `setipnum_be` | As `setipnum`, with the source number in big-endian byte order |
| `0x3000` | `genmsi` | Reads zero, as the spec requires in direct delivery mode |
| `0x3004` + 4(i-1) | `target[i]` | Hart index in bits 31:18, priority number (IPRIO) in bits 7:0 |
| `0x4000` + 32h | IDC of hart index h | The five registers below |

A write naming a source that is not active in the domain, by a bit or by
number, has no effect on that source. Bits and registers of sources that do not
exist, such as bit 0 of `setip[0]`, read zero. Every other offset in a region
reads zero and ignores writes.

Each interrupt delivery control (IDC) structure has these registers:

| Offset in the IDC | Register | Behavior |
|-------------------|----------|----------|
| `0x00` | `idelivery` | Bit 0 enables delivery to the hart |
| `0x04` | `iforce` | Bit 0 forces the hart's interrupt line on while IE and `idelivery` are set; a `claimi` read that returns zero clears it |
| `0x08` | `ithreshold` | `IPRIOLEN` bits; when nonzero, only priority numbers below it are delivered |
| `0x18` | `topi` | Identity of the top interrupt in bits 25:16 and its priority number in bits 7:0, or zero; read-only |
| `0x1C` | `claimi` | Reads as `topi`; a performed read claims the reported interrupt (below) |

The IDCs of hart indices at or above `NUM_HARTS` read zero and ignore writes.

## Domains and delegation

Each source is active in at most one domain, so its state is held once: the
root's delegation bit, the source mode in the domain that holds the source,
the pending and enable bits, and the target. Writing `sourcecfg[i]` in the
root domain with D (bit 10) set delegates source i to the supervisor domain,
the root's only child, whose child index (bits 9:0) is read-only zero. The
root then reads `0x400` for the source, and its pending and enable bits and
target read zero there. A newly delegated source reads zero in the supervisor
domain's `sourcecfg[i]`, inactive, until that domain writes it; writing D = 1
again in the root leaves the supervisor's configuration alone. Writing the
root's `sourcecfg[i]` with D clear takes the source back with the written
source mode.

The supervisor domain sees only the sources delegated to it. The others read
zero in all of its registers, and its writes to them are ignored, so software
holding only the supervisor domain cannot reach the root's sources. The
supervisor domain has no children, so writing its `sourcecfg[i]` with D set
writes the register as zero. A write that makes a source inactive, or moves it
between the domains, clears its enable bit and its pending bit, and a move
resets the source's target to hart 0 and priority 1. In the new mode the
pending bit then follows the wire (level-sensitive modes), or is set by the
write if it raises the rectified input (edge-sensitive modes, below).

## Source modes and pending bits

| SM | Mode | Rectified input | Pending bit |
|----|------|-----------------|-------------|
| 0 | Inactive | 0 | Zero, read-only |
| 1 | Detached | 0 | Set by `setip` and the `setipnum` registers; cleared by a claim or by `in_clrip` and `clripnum` |
| 4 | Edge1 | The wire | As Detached, and also set by a rising edge of the wire, rectified, and by a `sourcecfg` write that raises the rectified input |
| 5 | Edge0 | The inverted wire | As Edge1 |
| 6 | Level1 | The wire | The rectified input of the previous cycle, under the current mode, including the first cycle after a mode change; writes and claims neither set nor clear it |
| 7 | Level0 | The inverted wire | As Level1 |

The reserved encodings 2 and 3 write as Inactive. A set and a clear of one
pending bit in the same cycle leave it set, so an edge that arrives with the
claim of its source is not lost. The spec lets a `sourcecfg` write set the
pending bit when the new mode's rectified input is high; this design sets it
when the write leaves the source edge-sensitive and raises its rectified input,
comparing the new mode with the mode it had before the write, in whichever
domain held it. The bit is set at the write, so a claim or a clear in the next
cycle takes effect. The cycle of a mode change follows the old mode's rules
before the new mode applies: a level-sensitive source whose wire asserts in
that cycle stays pending in its new mode. The edge detector compares the wire
with its previous value under the current mode, so a change of mode is never
seen as an edge later.

## Delivery

For each IDC, `topi` reports the pending and enabled source of the domain whose
target names the IDC's hart and whose priority number is below a nonzero
`ithreshold`. The smallest priority number wins, and the lowest identity number
breaks a tie. A domain asserts its line to a hart while its IE and the hart's
`idelivery` are set and either `iforce` is set or `topi` is nonzero. `topi`
does not depend on IE or `idelivery`.

A performed read of `claimi` returns `topi`. If that is nonzero, it clears the
reported source's pending bit when the source is Detached or edge-sensitive; a
level-sensitive source stays pending until its wire drops. If it is zero, it
clears `iforce`. A `claimi` read without `i_rd_capture` has no side effect. The
claim's value and its side effect come from the same state, because `topi` is
combinational; when a claim and a register write arrive in the same cycle, the
claim takes effect first. The interrupt lines are registered.

`target` holds `clog2(NUM_HARTS)` bits of hart index; a hart index with no IDC
receives nothing. `IPRIO` keeps `IPRIOLEN` bits, and a write of zero sets 1.
While a source is inactive in a domain its target reads zero there, as the spec
requires. The spec leaves the target's value unspecified when the source
becomes active; this design then uses the last value written by the domain
holding the source, including writes made while it was inactive, which read as
zero until then. OpenSBI and Linux write targets before they activate sources,
and Linux's boot hart retargeting relies on such writes. Portable software
writes `target` after activating a source.

Reset clears IE, `idelivery`, `iforce` and `ithreshold` in both domains, makes
every source inactive and undelegated, and sets every target to hart 0 with
priority 1.

## Not implemented

MSI delivery mode is not implemented: `domaincfg.DM` reads zero, the MSI
address configuration registers and `genmsi` read zero, and there is no MSI
write port. Big-endian control regions are not implemented (`domaincfg.BE`
reads zero), and there are no other domains. Hart indices stop at 511, the
IDCs that fit in a 32 KiB region.

MSI delivery mode would add the root domain's MSI address configuration, the
MSI format of `target` (hart index, guest index, EIID), `genmsi`, the pending
rules that MSI mode gives level-sensitive sources, and a forwarder that writes
each pending and enabled source's MSI and then clears its pending bit. The
source state, the delegation logic and the register decode are shared with
direct delivery mode; the IDCs and `topi` selection serve direct delivery
mode only.

## Verification

The cocotb bench `verif/cocotb_tests/aplic/test_aplic.py` compares register
reads and both interrupt lines with a register-level model of the settled
state after each operation, and checks the values the spec gives in directed
tests. It covers every register and source mode, delegation and each domain's
view of the sources, priorities and thresholds, claims, `iforce` and
`idelivery`, several harts and a hart index with no IDC, claims in the cycle
after a write and in the same cycle as one, a reset during traffic, writes to
every unused word of both control regions with state in place, and the
programming sequences of OpenSBI's and Linux's APLIC drivers, and runs random
register traffic against the model. `tests/test_run_cocotb.py` runs it in four
shapes: `aplic` (40 sources, two harts), `aplic_default` (the defaults),
`aplic_limits` (1023 sources, three harts, 8-bit priorities) and
`aplic_512_harts`.
