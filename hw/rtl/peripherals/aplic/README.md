# APLIC

`aplic.sv` is an Advanced Platform-Level Interrupt Controller as specified by
the RISC-V Advanced Interrupt Architecture (AIA) 1.0, chapter 4. It has two
interrupt domains, a machine-level root domain and one supervisor-level child
domain. In direct delivery mode the root domain drives each hart's machine
external interrupt (MEIP) and the supervisor domain each hart's supervisor
external interrupt (SEIP). With MSI support enabled, either domain can instead
forward interrupts as 32-bit writes to the harts' IMSIC interrupt files.
Software sees two separate controllers, one per domain, as OpenSBI and Linux
expect from a device tree with one `riscv,aplic` node per domain. The SoC
instantiates it with five sources, one hart and direct delivery only. The
machine domain is at `0x4400_0000` and the supervisor domain at
`0x4400_8000`.

## Parameters

| Parameter | Default | Range | Meaning |
|-----------|---------|-------|---------|
| `NUM_SOURCES` | 5 | 1 to 1023 | Interrupt sources, with identity numbers 1 to `NUM_SOURCES` |
| `NUM_HARTS` | 1 | 1 to 512 | Hart indices 0 to `NUM_HARTS - 1`, one IDC per hart in each domain |
| `IPRIOLEN` | 3 | 1 to 8 | Implemented priority bits; priority numbers run from 1 to `2^IPRIOLEN - 1` |
| `MSI_ENABLE` | 0 | 0 or 1 | Implement MSI delivery alongside direct delivery |
| `MSI_ADDR_WIDTH` | 56 | 32 to 64 | Physical byte address width of the MSI master |
| `MMSIADDRCFG_RESET` | 0 | 32 bits | Root machine MSI low configuration at system reset |
| `MMSIADDRCFGH_RESET` | 0 | 32 bits | Root machine MSI high configuration, including lock, at system reset |
| `SMSIADDRCFG_RESET` | 0 | 32 bits | Root supervisor MSI low configuration at system reset |
| `SMSIADDRCFGH_RESET` | 0 | 32 bits | Root supervisor MSI high configuration at system reset |

The default covers the SoC's five sources. Simulation stops at time zero if a
parameter is out of range. Reset parameters pass through the same WARL rules
as register writes. `MSI_ENABLE = 0` preserves the direct-only register behavior
and ties all MSI outputs to zero; `i_msi_ready` then has no effect.

## Interface

The register interface connects to the SoC's 64-bit MMIO read and write paths.

| Port | Meaning |
|------|---------|
| `i_src[NUM_SOURCES-1:0]` | Source wires, bit 0 for source 1, synchronous to `i_clk` |
| `i_wr_en`, `i_wr_offset[21:0]`, `i_wr_data[31:0]` | One register write: its byte offset in the 4 MiB window and its 32-bit value |
| `i_rd_offset[21:0]`, `o_rd_pair[63:0]` | Combinational read of the aligned dword: the register at `offset & ~7` in bits 31:0 and the next word in bits 63:32 |
| `i_rd_capture` | Pulses once for each performed read, on the clock edge that captures `o_rd_pair` into the bus response |
| `o_meip[NUM_HARTS-1:0]`, `o_seip[NUM_HARTS-1:0]` | Registered interrupt lines of the root and supervisor domains, by hart index |
| `o_msi_valid`, `i_msi_ready` | A write is accepted on a rising edge with both asserted; reset suppresses valid |
| `o_msi_addr[MSI_ADDR_WIDTH-1:0]`, `o_msi_data[31:0]` | Physical byte address and little-endian data of a naturally aligned 32-bit MSI store |

The AIA supports only naturally aligned 32-bit reads and writes in a domain's
control region and requires other accesses to be ignored. The SoC therefore
asserts `i_wr_en` only for a 32-bit store, and `i_rd_capture` only for a
32-bit load. Other read sizes return zero at the SoC boundary and cause no
side effect. A read's side effect, the claim of a `claimi` read, applies to
the word at `i_rd_offset`, so the SoC passes the load's full offset, with bit
2 selecting the word of the pair. The byte offset within a word, bits 1:0, is
ignored.

The source identities are 1 for the ns16550 UART, 2 for the external pin,
3 for the DMA test engine, 4 for the NIC, and 5 for the memory error unit.
OpenSBI delegates them to the supervisor domain, which Linux configures for
level-high delivery. Bare-metal programs use `sw/lib/include/aplic.h`.

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
| `0x0000` | `domaincfg` | Bits 31:24 read `0x80`; bit 8 is IE, the domain's interrupt enable. DM (bit 2) selects MSI delivery when `MSI_ENABLE = 1`, otherwise reads zero. BE (bit 0) reads zero |
| `0x0004` + 4(i-1) | `sourcecfg[i]` | Source mode or delegation of source i (below) |
| `0x1BC0`–`0x1BCC` | `mmsiaddrcfg`, `mmsiaddrcfgh`, `smsiaddrcfg`, `smsiaddrcfgh` | Root-only MSI address configuration when `MSI_ENABLE = 1`; otherwise read zero |
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
| `0x3000` | `genmsi` | Hart index, Busy and EIID in MSI mode; read-only zero in direct mode |
| `0x3004` + 4(i-1) | `target[i]` | Hart index in bits 31:18; IPRIO in bits 7:0 in direct mode, EIID in bits 10:0 in MSI mode |
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
In MSI mode all IDC reads return zero and accesses have no side effects.
IDC state is retained across delivery-mode changes. The registered direct
interrupt line is gated by DM as well as IE, so it goes low on the clock
after the mode change.

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
resets the source's target to hart 0, priority 1 and EIID 1. In the new mode the
pending bit then follows the wire for direct-mode level sources, or is set by
the write if it raises an edge or MSI-level rectified input.

## Source modes and pending bits

| SM | Mode | Rectified input | Pending bit in direct mode |
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
pending bit when the new mode's rectified input is high. In direct mode this
design sets it when the write leaves the source edge-sensitive and raises its rectified input,
comparing the new mode with the mode it had before the write, in whichever
domain held it. The bit is set at the write, so a claim or a clear in the next
cycle takes effect. The cycle of a mode change follows the old mode's rules
before the new mode applies: a level-sensitive source whose wire asserts in
that cycle stays pending in its new mode. The edge detector compares the wire
with its previous value under the current mode, so a change of mode is never
seen as an edge later.

For Detached and edge sources, MSI mode uses the same pending rules except
that selecting an MSI offer replaces a claim. For Level1 and Level0 in MSI mode,
a rising rectified input sets pending. A software set also sets pending
while that input is high. A low rectified input, a software clear, or a
selected MSI offer clears pending. A held high input does not retrigger after
forwarding. Software can rearm it with `setipnum`, as Linux does at EOI,
or wait for a new low-to-high transition. A low rectified input takes
precedence over a simultaneous software set.

In MSI mode a `sourcecfg` write sets pending when it raises a rectified
edge or level input. The cycle of a source-mode or delivery-mode change
first applies the old mode's input, claim and MSI retirement rules, then
the new mode's rectified-input constraints. Switching an asserted level
source from direct mode to MSI mode preserves its pending interrupt;
switching back to direct mode resumes following the wire.

## Direct delivery

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

Reset clears IE, DM, `idelivery`, `iforce` and `ithreshold` in both domains,
makes every source inactive and undelegated, and sets every target to hart 0
with priority 1 and EIID 1. Priority and EIID are stored separately; a target
write changes the field selected by DM and the shared hart index. A mode
change retains both fields. The specification leaves target fields
unspecified on a delivery-mode change, so software should rewrite them.

## MSI address configuration

The four address registers exist only at the root domain and are independent
of its current DM. `mmsiaddrcfgh.L`, bit 31, locks all four registers until
system reset. The write setting L also writes its other fields. Locked
values remain visible. Setting L in the reset parameter makes the configuration
fixed from reset. The SoC must connect `i_rst` to system reset, not to a
software-accessible local reset that could unlock the configuration.

Each pair supplies a 44-bit Base PPN: the low register contributes bits 31:0
and the high register bits 11:0. PPN bits beyond `MSI_ADDR_WIDTH - 12` are
read-only zero. The machine high register also holds LHXW in bits 15:12,
HHXW in bits 18:16, LHXS in bits 22:20 and HHXS in bits 28:24. The supervisor
high register has only LHXS in bits 22:20 in addition to its high PPN.
Reserved bits read zero. LHXW, HHXW and LHXS retain all their field bits.
HHXS is clamped to `min(31, MSI_ADDR_WIDTH - 31)` so even a seven-bit high
index cannot overflow the address port. This bound is conservative when
HHXW is smaller. Overlapping base and index bits are combined with OR;
the registers do not force those base bits to zero.

Machine and supervisor domains use the same hart index numbering. For
machine delivery, let `g = (hart >> LHXW) & ((1 << HHXW) - 1)` and
`h = hart & ((1 << LHXW) - 1)`. The byte address is
`(BasePPN | (g << (HHXS + 12)) | (h << LHXS)) << 12`.
Supervisor delivery uses its own Base PPN and LHXS, with LHXW, HHXW and HHXS
from the machine high register. There is no hypervisor extension: Guest Index,
bits 17:12 of both domains' MSI targets, is read-only zero. Bit 11 is reserved.
EIID keeps all 11 bits, including zero, and the write data is its zero extension
to 32 bits. Hart Index retains the same bits as in direct mode. An unused
hart-index encoding produces its calculated address in MSI mode; software
must use an implemented hart index and an EIID supported by the IMSIC.

## MSI delivery and ordering

A source is eligible when it is active, pending and enabled and its domain
has DM and IE set. The forwarder snapshots that eligibility, its target and
the address configuration when offering a write. Address, data and valid
remain stable until acceptance. A later disable, target write, address write,
mode change or delegation cannot retract an offered write. Such a write can
therefore arrive after software reconfigures its source. Reset discards the
offer and suppresses valid.

The pending bit is retired on the edge that selects and registers the offer.
This is the forwarding event in AIA 1.0 section 4.9: the source is pending,
enabled and active in an MSI-mode domain with IE set when it is forwarded.
A simultaneous set or edge keeps the bit set. Later sets and edges record
new interrupts, including while the offer is stalled. Acceptance does not
change a source's pending bit. Other input and software pending rules
continue to operate during a stall. A mode change does not restore the
interrupt already represented by an offer.

Sources 1 through `NUM_SOURCES`, root `genmsi` and supervisor `genmsi` share
one round-robin ring, in that order. The pointer advances past the accepted
slot. With eventual ready and stable eligibility, no slot waits through more
than `NUM_SOURCES + 1` other acceptances. There is one outstanding offer and
one idle selection cycle after each acceptance, giving at most one accepted
write every two cycles. There is no source-priority ordering in MSI mode.

Writing `genmsi` in MSI mode when Busy is zero stores Hart Index and EIID and
sets Busy, bit 12. All other bits read zero. Writes while Busy is one are
ignored, including on the acceptance edge. Acceptance clears Busy and retains
Hart Index and EIID. IE does not gate these writes. A queued generator shares
the bounded arbitration delay above. In direct mode `genmsi` reads zero and
ignores writes, as AIA 1.0 section 4.5.15 requires, even if a marker is queued.
A marker requested in MSI mode remains eligible across a change to direct
mode, so it completes with minimal delay instead of waiting for another
mode change. The specification does not prescribe cancellation on a DM
change. Both queued and offered markers retain Busy internally until
acceptance. System reset clears both generators.

The port issues one global sequence of stores. The SoC receiver must preserve
that order through visibility at the IMSICs, at least for writes to the same
hart, including across the M and S interrupt files. This supplies the AIA
`genmsi` guarantee that its marker becomes visible only after earlier MSIs to
that hart. Busy becoming zero means the store was accepted by the receiver;
software still waits for the marker in the IMSIC when synchronizing.

## SoC connection

Decode `o_msi_addr` to the IMSIC machine and supervisor page regions and send
each accepted store to offset zero, the little-endian `seteipnum` register.
For a directly connected, always-accepting IMSIC, tie `i_msi_ready` high and
pulse its write enable with `o_msi_valid && i_msi_ready`. Pass the address and
32-bit data through an arbiter shared with CPU and device MSI stores. The
arbiter asserts ready only when it has accepted responsibility for delivery.
If it buffers stores, it must preserve the ordering described above. An AXI
bridge must retain the whole request through its address and data handshakes
and guarantee delivery once it asserts ready here; this interface has no
separate completion or error channel.

For two harts with 4 KiB pages at machine base `0x48000000` and supervisor
base `0x48100000`, set `mmsiaddrcfg = 0x48000`, `mmsiaddrcfgh = 0x1000`,
`smsiaddrcfg = 0x48100` and `smsiaddrcfgh = 0`. These values give LHXW = 1,
HHXW = 0 and both LHXS = 0. Hart 1 uses base + `0x1000` in each region.
Set L after configuration, or use locked reset parameters for fixed pages.
An integration with a 32-bit IMSIC address input can select `MSI_ADDR_WIDTH = 32`.
The APLIC register windows remain separate MMIO slaves, with the root window
accessible only to machine-level software. SoC integration and device-tree
updates are outside this module.

## Not implemented

Big-endian control regions are not implemented (`domaincfg.BE` reads zero),
and there are no guest interrupt files or other domains. Hart indices stop
at 511, the IDCs that fit in a 32 KiB region. The master provides no error
response or retry protocol; acceptance must guarantee delivery.

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
register traffic against the model. `tests/test_run_cocotb.py` runs it in five
shapes: `aplic` (40 sources, two harts), `aplic_default` (the defaults),
`aplic_limits` (1023 sources, three harts, 8-bit priorities) and
`aplic_512_harts`, plus `aplic_direct_msi` (40 sources, two harts and
`MSI_ENABLE = 1`, with direct delivery).

The formal target `formal/aplic.sby` checks the properties in the module's
`ifdef FORMAL` block, written from the spec's register offsets and rules
rather than taken from the logic: `topi` selection; the pending-bit rules of
every mode, including the cycle of a mode change; the `sourcecfg`, `target`,
`domaincfg` and IDC write rules; delegation; isolation of the root domain from
supervisor writes; the reset state; the interrupt pins; and the value of every
word of both control regions and of the rest of the window. `bmc` (depth 12),
`prove` and `cover` use three sources, two harts and two priority bits;
`prove_one_hart` one of each; `prove_wide` 33 sources, which use a second
word in each bitmap; and `prove_three_harts` three harts and 8-bit
priorities. The `prove` tasks are unbounded (k-induction).

The MSI bench `verif/cocotb_tests/aplic/test_aplic_msi.py` checks every read pair,
every offered MSI and the registered interrupt lines against the clocked model.
It covers address WARL and lock behavior, all source modes, both address
formulas with two harts, EIID zero, Busy and IE, mixed delivery modes,
delegation, backpressure, sets after a stalled retarget, source masking and
domain disable during a stall, simultaneous selection and writes, fairness, reset
in flight and random traffic. The `aplic_msi` shape has 40 sources, two harts
and 56-bit addresses. `aplic_msi_32` checks 32-bit address WARL behavior and
`aplic_msi_locked` checks reset-locked configuration, each with five sources
and two harts.

The MSI formal tasks check selection eligibility, cyclic arbitration rank,
snapshot address and data, request stability, selection retirement,
every pending transition, EIID writes, address WARL, lock and generator state.
An independent conservation property checks that, absent a software clear,
reconfiguration or a low level input, a pending interrupt remains pending
or appears as a new offer. It observes registered offers rather than the
retirement decoder. Every new source offer also requires a previously
pending, enabled, active source in an MSI-mode domain with IE set.
Inputs, including ready and register writes during backpressure, are arbitrary.
`msi_bmc` has depth 12, `msi_prove` uses unbounded induction, and `msi_cover`
reaches both domains, every active source mode, generators with IE clear,
stalls, concurrent sets and edges at selection and acceptance, pending
interrupts after delegation, generator completion in direct mode and locked
writes. `msi_prove_32`, `msi_prove_locked` and `msi_prove_wide`
check 32-bit addresses with three harts, reset locking with one hart, and
33 sources spanning two bitmap words. `msi_prove_four_harts` checks multi-bit
hart indices with 56-bit addresses. Each MSI prove task uses depth 5 induction.

The software-sequence tests exercise the address and delegation writes in
[OpenSBI's APLIC driver](https://github.com/riscv-software-src/opensbi/blob/master/lib/utils/irqchip/aplic.c)
and the target and level EOI writes in
[Linux's MSI driver](https://github.com/torvalds/linux/blob/master/drivers/irqchip/irq-riscv-aplic-msi.c).

`tests/aplic_msi_mutations.py` checks a correct baseline and five
isolated faults. Every fault must fail a cocotb assertion and produce
a bounded formal counterexample; compilation errors do not count as detection.
The acceptance-retirement mutant includes pending-episode tracking and a
delayed clear. A further run removes the complete pending transition assertion to check that the conservation property rejects it alone.
The diagnostic runs serially, cleans before each cocotb run, and keeps its
private RTL copies, logs and XML reports under the worktree's `sim_build/`.

```bash
./scripts/frost.py run python3 tests/aplic_msi_mutations.py
```

| Fault | Directed cocotb check | Formal check |
|-------|-----------------------|--------------|
| Use machine LHXS for supervisor addresses | Target and address formulas | Offered address matches the snapshot |
| Retire on acceptance with pending-episode tracking | Stalled mask and retarget sequences | Pending transition and independent conservation |
| Allow writes after lock | Address configuration | WARL and locked-register next state |
| Gate `genmsi` by domain IE | Generator with IE clear | Eligibility and selection |
| Reset the arbiter pointer after every acceptance | Continuous-traffic fairness | Pointer advancement |

The `aplic_test` program checks the SoC register path in BRAM and DDR
configurations, including both domains, delegation, machine interrupt entry,
level-sensitive claims, thresholds, `iforce`, and byte, halfword and doubleword
accesses. Invalid read sizes return zero without consuming pending interrupts
or clearing `iforce`; invalid write sizes leave both register lanes unchanged.
