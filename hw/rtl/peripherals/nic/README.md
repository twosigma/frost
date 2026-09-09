# NIC (net10g on the coherent DMA port)

Phase 4 slice 2 integrates the standalone 10GBASE-R MAC/PCS
(`hw/rtl/net10g`) as FROST's NIC: a CSR window, RX and TX descriptor rings
on the cache hierarchy's coherent DMA port, packet clock crossings to the
MAC's ~161 MHz domains, and one PLIC interrupt. This directory holds the
NIC's own blocks; the MAC/PCS is untouched and keeps its standalone CI job.
The blocks land in slices: this README grows with them.

| Module | Domain | Responsibility |
| --- | --- | --- |
| `nic_pkg.sv` | - | register offsets and interrupt bits shared with the benches and `sw/lib/include/nic.h` |
| `nic_irq.sv` | core | interrupt status, mask, per-direction completion moderation |
| `nic_reset_ctrl.sv` | core | the RESET sequence and the per-domain reset generation handshake |
| `nic_domain_reset.sv` | MAC (one per domain) | applies the domain reset and acknowledges the generation |
| `nic_reset_test_harness.sv` | bench | controller, two domains, two `async_fifo`s and a `cdc_gray_count` across three clocks |

The crossing primitives live in `hw/rtl/lib/cdc` (`cdc_sync`,
`cdc_reset_sync`, `cdc_gray_count`) and `hw/rtl/lib/fifo/async_fifo.sv`.

## Reset and clock domains

The NIC has three clock domains: the core clock and the MAC's TX and RX
clocks (one shared MMCM output on the loopback build, the transceiver's
clocks with a GTY). Each MAC domain gets its reset from `nic_domain_reset`:
`cdc_reset_sync` asserts it without a clock edge when the controller
raises the request, so a domain whose clock is absent still sits in reset,
and releases it aligned to the domain clock. The controller
(`nic_reset_ctrl`) drives the request with a generation bit per domain; the
far side answers with the generation it applied, and only after its own
clock has held the reset for `HOLD_CYCLES` (an `applied_valid` bit rules
out the reset value of the generation ever counting as an answer). The
release hold is preloaded while the request is up, so the domain reset has
no gap between the request's release and the hold.

`o_ready` per domain means: the current generation applied, the domain out
of reset, its clock reported present. Until then the domain's core-side
FIFO half and the engines' MAC-facing state are held in reset
(`o_core_rst_dom`), the CSR block refuses an enable, and the event
observers are rebased. A clock loss in operation starts a new generation on
its own, so nothing resumes on stale state when the clock returns.

RESET (the CSR bit, and the core's reset) is: stop the engines and wait for
the DMA front-end to owe no response, pulse the core-domain reset, start a
new generation in both domains. `o_busy` covers exactly that and never
waits for a MAC clock, so a build without a transceiver completes RESET.

`async_fifo` carries packets across: Gray-coded pointers through
`cdc_sync`, storage in the dual-clock block RAM, and a two-entry output
skid over the RAM's registered read so no word is presented twice or
skipped. Each side's reset clears its pointer, synchronizer copies and (on
the read side) the skid and any read in flight; the controller sequences
the two sides so a reset window overlaps. `cdc_gray_count` crosses MAC
event counts (registered Gray in the source, decoded and accumulated in the
core domain); its rebase input, driven from the domain's not-ready state,
keeps a source reset from reading as a wrap.

## Interrupts

`nic_irq` implements the contract the driver relies on. `IRQ_STATUS`
(0x040) is sticky and write-1-to-clear, with a set winning over a
same-cycle clear; `IRQ_MASK` (0x044) gates the level line and has atomic
`IRQ_MASK_SET` (0x054) and `IRQ_MASK_CLR` (0x058) views; masking loses
nothing. Bits: 0 RX and 1 TX (moderated completions), 2 RX_DROP, 3 LINK,
4 DESC_ERR (event latches).

RX and TX are moderated notifications. Per direction, an acknowledgement
(W1C of the bit) starts a new interval: it clears the notification, the
completion count and the timer. Within an interval every completion (one
per DD write response) counts, saturating; the first snapshots `RX_ITR` /
`TX_ITR` (0x048 / 0x04C: `[15:0]` delay in ticks, `[23:16]` max count) and
`TICK` (0x050, core cycles per tick, 0 counts as 1) and starts the
deadline, which never restarts. The bit raises when the count reaches max
(max 0 disables the comparator) or the deadline passes; delay 0 raises on
the first completion whatever max says. A raise stops the timer;
completions while the bit is set belong to the same interval; a completion
in the acknowledgement's cycle belongs to the new one. The driver's rule:
acknowledge before scanning the rings, never after the final scan.

## Verification

`verif/cocotb_tests/lib/test_async_fifo.py` (`async_fifo`): order and
completeness across clock ratios and phases, full then drain, a reader that
outruns the writer, both-side reset. `test_cdc_gray_count.py`
(`cdc_gray_count`): bursts, wrap, a source reset with and without the
rebase. `verif/cocotb_tests/nic/test_nic_irq.py` (`nic_irq`): the
moderation and acknowledgement cases above. `test_nic_reset.py`
(`nic_reset`): the startup handshake, RESET's drain and busy, an absent
clock, a lost clock, a stale acknowledgement, FIFO words and counter state
across resets. `formal/async_fifo.sby` bounds the FIFO under free-running
unrelated clocks: occupancy, no underflow, Gray consistency, and a watched
word delivered in order and intact.
