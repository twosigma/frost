<!--
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
-->

# IMSIC

`imsic.sv` implements Incoming MSI Controllers as specified by the RISC-V
Advanced Interrupt Architecture (AIA) 1.0, chapter 3, for a group of harts.
Each hart has a machine-level and a supervisor-level interrupt file
(`imsic_file.sv`). A file records message-signaled interrupts (MSIs), 32-bit
stores of an interrupt identity to the file's page, and signals the hart's
machine or supervisor external interrupt while one of them is pending and
enabled. Software reaches a file through the Smaia and Ssaia CSRs: `miselect`
and `mireg` with `mtopei` at machine level, `siselect` and `sireg` with
`stopei` at supervisor level. The module gives each file a port for those
CSRs, which the hart's CSR file connects to. An inter-processor interrupt is a
store to the target hart's page. The SoC does not instantiate the IMSIC yet,
and the CSR file does not implement the AIA CSRs yet.

## Parameters

| Parameter | Default | Range | Meaning |
|-----------|---------|-------|---------|
| `NUM_HARTS` | 1 | 1 to 4096 | Hart indices 0 to `NUM_HARTS - 1`, a machine-level and a supervisor-level file each |
| `NUM_IDS` | 63 | 63, 127, 191, ... 2047 | Interrupt identities 1 to `NUM_IDS` in every file: one less than a multiple of 64, as the spec requires |
| `M_BASE_ADDR` | `0x4800_0000` | Aligned to the region size | Base address of the machine-level region |
| `S_BASE_ADDR` | `0x4810_0000` | Aligned to the region size | Base address of the supervisor-level region |
| `APLIC_DELIVERY` | 1 | 0 or 1 | `eidelivery` supports `0x40000000`, delivery by an APLIC in direct mode |

Each region holds 2^k pages of 4 KiB, k = clog2(`NUM_HARTS`), so its size is
4 KiB for one hart, 8 KiB for two, and 16 KiB for three or four. Simulation
stops at time zero if a parameter is out of range, a base is not aligned to
the region size, or the two regions overlap. The 63-identity default is the
spec's minimum; Linux and OpenSBI accept any of the allowed sizes, read from
the device tree's `riscv,num-ids`.

## Memory map

The machine-level files form one region and the supervisor-level files
another, the arrangement the AIA recommends and Linux and OpenSBI expect:
hart h's file at a level is the page at that level's base + `0x1000` * h.

| Offset in a file's page | Register | Behavior |
|-------------------------|----------|----------|
| `0x000` | `seteipnum_le` | Writing identity i, 1 to `NUM_IDS`, sets its pending bit |
| `0x004` | `seteipnum_be` | The same, with i in big-endian byte order |

A write of identity 0, of a value above `NUM_IDS`, or to any other offset is
ignored, and so is a write to the page of a hart index at or above
`NUM_HARTS` inside a region. Every address in both regions reads zero,
`seteipnum_le` and `seteipnum_be` included.

| Device-tree node | `reg` | `interrupts-extended` |
|------------------|-------|-----------------------|
| Machine level, `compatible = "riscv,imsics"` | `M_BASE_ADDR`, region size | Each hart's `cpu-intc` with 11, in hart-index order |
| Supervisor level, `compatible = "riscv,imsics"` | `S_BASE_ADDR`, region size | Each hart's `cpu-intc` with 9, in hart-index order |

Both nodes also carry `interrupt-controller`, `msi-controller`,
`#interrupt-cells = <0>`, `#msi-cells = <0>`, and `riscv,num-ids` equal to
`NUM_IDS`. Linux and OpenSBI compute k, the hart-index bits, from the number
of `interrupts-extended` entries, so a node that lists every hart needs no
`riscv,hart-index-bits`.

## Interface

The write port has the shape of the APLIC's register writes,
with a physical address in place of a window offset because the regions
have their own bases. There is no read port: the SoC returns zero for loads
in the regions.

| Port | Meaning |
|------|---------|
| `i_wr_en`, `i_wr_addr[31:0]`, `i_wr_data[31:0]` | One 32-bit store: its physical address and the 32-bit value in little-endian lane order. Addresses outside both regions are ignored, and bits 1:0 of the address are not decoded |
| `i_aplic_meip`, `i_aplic_seip` | An APLIC's direct-mode interrupt lines, by hart index |
| `o_meip`, `o_seip` | Registered external interrupt lines for each hart's `mip.MEIP` and `mip.SEIP` |

The AIA supports only naturally aligned 32-bit accesses to a file's page and
requires others to be ignored, so the SoC asserts `i_wr_en` only for a
32-bit store. A store reaches its file one cycle after the cycle that
presents it; writes to one file stay in order, as the spec requires.

Each file has the hart-side ports below, prefixed `i_m_` and `o_m_` for the
machine-level files and `i_s_` and `o_s_` for the supervisor-level files. The
vectors hold every hart: hart h uses bits 8h+7:8h of `iselect`, bits
64h+63:64h of `ireg`, `ireg_keep` and `ireg_set`, bits 32h+31:32h of
`topei`, and bit h of the rest.

| Port | Meaning |
|------|---------|
| `i_*_iselect[7:0]` | The `*iselect` value of a `*ireg` access |
| `o_*_ireg[63:0]` | The selected register, combinational from the file's registers |
| `o_*_ireg_illegal` | The select names a register that does not exist at XLEN 64; a `*ireg` access must raise an illegal-instruction exception. It depends on the select alone |
| `i_*_ireg_we`, `i_*_ireg_keep[63:0]`, `i_*_ireg_set[63:0]` | Write the selected register with the Zicsr update: its next value is (value & keep) \| set |
| `o_*_topei[31:0]` | `*topei`, registered |
| `i_*_topei_claim` | A write to `*topei` in this cycle |

The CSR file forms keep and set from funct3 as `csr_file.sv` already does for
its own registers: csrrw gives keep 0 and set the operand, csrrs keep all
ones and set the operand, and csrrc keep the operand's complement and set 0.
The file applies the update to the register it holds, so a csrrs or csrrc
never writes back a stale copy of a pending bit.

A claim is a write, so the CSR file raises `i_*_topei_claim` only for a
committed `*topei` access with write intent: every csrrw, and a csrrs or
csrrc whose rs1 or immediate field is nonzero, whatever the operand's value.
A pure read, csrrs or csrrc with x0, must not claim; `csr_file.sv`'s generic
write enable is also set for those, so the claim takes its decoded write
intent. The CSR file raises neither strobe for an access that traps, and it
decides privilege: when `mvien` bit 9 is set, an S-mode access to `stopei`,
or to `sireg` with any select from `0x70` to `0xFF`, reserved selects
included, raises an illegal-instruction exception.

## Registers of an interrupt file

| `*iselect` | Register | Behavior |
|------------|----------|----------|
| `0x70` | `eidelivery` | 0: delivery off. 1: the file delivers. `0x40000000`: an APLIC delivers (below). WARL: a write keeps `0x40000000` when bit 30 of the new value is set and `APLIC_DELIVERY` is 1, and otherwise bit 0 |
| `0x72` | `eithreshold` | When nonzero, identities at or above it do not interrupt and are not reported. WLRL, clog2(`NUM_IDS` + 1) bits |
| `0x80` + 2w | `eip` word w (the spec's `eip2w`) | Pending bits of identities 64w to 64w + 63, bit i % 64 for identity i |
| `0xC0` + 2w | `eie` word w (`eie2w`) | Enable bits of the same identities |

Bit 0 of the first words, for the nonexistent identity 0, and the bits of
identities above `NUM_IDS` are read-only zeros, and so are the words above the
last implemented one. Software may set and clear pending bits through `eip` as
well as through MSIs. The odd selects `0x81` to `0xBF` and `0xC1` to `0xFF`
name `eip1`, `eip3`, ... and `eie1`, `eie3`, ..., which exist only at XLEN 32;
`o_*_ireg_illegal` reports them, and they read zero and ignore writes. The
reserved selects `0x71` and `0x73` to `0x7F` read zero and ignore writes; the
spec gives them no exception of their own, though the `mvien` rule above can
still forbid the access. Selects below `0x70` are not the IMSIC's: the CSR
file decodes them, with the major interrupt priorities at `0x30` to `0x3F`.
The CSR file also decides the values above `0xFF` before an access reaches
this port, which takes only the low 8 bits.

`*topei` reports the lowest pending and enabled identity, below
`eithreshold` when that is nonzero, in bits 26:16 and again as its priority
in bits 10:0, or zero when there is none. It does not depend on
`eidelivery`. A write to `*topei`, `i_*_topei_claim`, clears the pending bit
of the identity `o_*_topei` reports in the same cycle and ignores the value
written; with `*topei` zero it changes nothing. A csrrw of `*topei`
therefore reads an identity and claims it in one access. `o_*_topei` is
registered, and the file recomputes it from its next state on every edge, so
it always reports the current registers: a claim on the next cycle reports
the next identity.

## Delivery

A file's line is set while `eidelivery` is 1 and some identity is pending,
enabled, and below a nonzero `eithreshold`, that is, while `*topei` is
nonzero. With `eidelivery` 0 the line is clear. The line is registered on the
same clock edge as the file's state, so it always matches the state: a store
presented to the write port in one cycle sets its pending bit, and can raise
the line, at the end of the next cycle, and a claim of the last such identity
drops the line at the end of the claim's cycle.

With `APLIC_DELIVERY`, `eidelivery` may hold `0x40000000`. The hart's
external interrupt at the file's level then comes from the APLIC in direct
delivery mode, on `i_aplic_meip` or `i_aplic_seip`, registered once more, and
the file acts as if `eidelivery` were 0; it still records MSIs and reports
`*topei`. Reset sets `0x40000000`, as the spec requires when the value is
supported. Software that does not know about IMSICs, which includes FROST's
bare-metal tests, Linux with a device tree that names only the APLIC, and
OpenSBI without an IMSIC node, therefore keeps its external interrupts from
the APLIC. OpenSBI and Linux write `eidelivery` 1 when their device tree
names the IMSIC, each at its own level, so firmware can take
inter-processor interrupts through the machine-level files while Linux
keeps the APLIC's direct delivery at supervisor level, until the APLIC
forwards wired interrupts as MSIs. Without `APLIC_DELIVERY`, `eidelivery`
holds only 0 or 1 and resets to 0, and the APLIC inputs are unused.

## Simultaneous events

The updates of one cycle take effect in this order: a claim, then a `*ireg`
write, then an MSI. Hart-side reads report the state before all three. An
MSI therefore acts as if it arrived a cycle after a hart-side access in the
same cycle, which the AIA allows because a store's effect on a file may be
delayed:

| In one cycle, at one file | Result |
|---------------------------|--------|
| An MSI for identity i and a claim of i | The claim reads and clears i; i is pending again after the edge |
| An MSI for identity j and a claim of i | The claim reads and clears i; j is pending after the edge, and the next `*topei` reports it if it wins |
| An MSI for i and a `*ireg` write to i's `eip` word | The write's read returns the word without i, the write lands, and i is pending after the edge, even if the write cleared it |
| An MSI and a write to `eie`, `eithreshold` or `eidelivery` | Both take effect |
| A claim and a `*ireg` write | The write applies to the state after the claim; the CSR file issues one CSR access at a time, so this does not arise |

Because a store reaches its file one cycle after the cycle that presents it,
an MSI that arrives at a file in the same cycle as a hart-side access was
presented to the write port a cycle earlier. A store presented in the same
cycle as a hart-side access takes effect a cycle after it. Writes to
different files never interact.

## Reset

Reset clears every pending and enable bit and `eithreshold` in every file and
sets `eidelivery` to `0x40000000` with `APLIC_DELIVERY` and to 0 without. The
spec leaves the other values unspecified.

## Not implemented

There are no guest interrupt files, because FROST has no H extension, and so
no `vsiselect`, `vsireg` or `vstopei` state and no guest-index bits in the
addresses. The hart-side port serves XLEN 64 only: the odd `eip` and `eie`
registers of XLEN 32 are illegal selects. Accesses other than aligned 32-bit
stores are ignored rather than reported as access faults, which the spec
permits; the SoC filters them before the write port. A file's size is fixed
by `NUM_IDS` and cannot be changed by software. The major interrupt
priorities (`*iselect` `0x30` to `0x3F`) belong to the CSR file.

## Verification

The cocotb bench `verif/cocotb_tests/imsic/test_imsic.py` drives the write
port and every file's hart-side port and compares, every cycle, each file's
`*ireg` read, illegal flag and `*topei`, and after every edge both lines of
every hart, with a cycle-level model (`imsic_model.py`). It checks all 256
selects of every file, `eidelivery`'s and `eithreshold`'s write rules, the
`eip` and `eie` words in all three Zicsr forms, MSIs of every identity (of a
spread of them with 2047) in randomly chosen byte orders, identity 0 and
values above `NUM_IDS`, the other offsets, unused pages and addresses outside
the regions, `*topei` and claims, the lines with each `eidelivery` value, the
simultaneous events above, separate harts and levels, the register sequences
of OpenSBI's and Linux's IMSIC drivers, and random traffic on back-to-back
cycles. `tests/test_run_cocotb.py` runs it in three shapes: `imsic` (two
harts, 191 identities), `imsic_default` (the defaults) and `imsic_limits`
(three harts, 2047 identities, no APLIC delivery, other bases).
