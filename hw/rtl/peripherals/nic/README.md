# NIC (net10g on the coherent DMA port)

Phase 4 slice 2 integrates the standalone 10GBASE-R MAC/PCS
(`hw/rtl/net10g`) as FROST's NIC: a CSR window, RX and TX descriptor rings
on the cache hierarchy's coherent DMA port, packet clock crossings to the
MAC's ~161 MHz domains, and one PLIC interrupt. This directory holds the
NIC's own blocks; the MAC/PCS is untouched and keeps its standalone CI job.
The blocks land in slices: this README grows with them.

| Module | Domain | Responsibility |
| --- | --- | --- |
| `nic_pkg.sv` | - | the register map, interrupt bits, beat codes, request kinds and descriptor bits shared with the benches and `sw/lib/include/nic.h` |
| `nic_top.sv` | all | the NIC: the core-domain blocks below around `nic_mac_wrap`; register window, DMA line port and interrupt toward the SoC, MAC clocks and the raw PMA interface toward the board |
| `nic_csr.sv` | core | the register file: control, status, station address, rings, link and PHY registers, the 64-bit counters |
| `nic_irq.sv` | core | interrupt status, mask, per-direction completion moderation |
| `nic_mac_wrap.sv` | MAC + core | the MAC/PCS in its two domains, the packet FIFOs, the domain resets, status synchronizers, event counters, the raw loopback |
| `nic_dma_front.sv` | core | the two engines' requests onto the one DMA line port: four entries with a three-per-side cap, RX priority with a grant-counted bound, response steering, aperture refusal, the drain |
| `nic_desc_fetch.sv` | core | one ring's descriptor supply: prefetch cursor, two-line cache, eligibility captured at the read's acceptance |
| `nic_rx_engine.sv` | core | frames from the RX FIFO into ring buffers: filter, `nic_byte_pack`, truncation, status writes |
| `nic_tx_engine.sv` | core | ring buffers into the TX FIFO: validation, reads with a reorder buffer, `nic_byte_unpack`, status writes |
| `nic_byte_pack.sv` | core | 8-byte beats to strobed 32-byte line writes at any byte address |
| `nic_byte_unpack.sv` | core | 32-byte lines to 8-byte beats from any byte offset |
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

## Descriptor rings and the DMA path

Descriptors are 16 bytes, two per line: word 0 the buffer address (any
byte alignment), word 1 the length (TX: with SOP and EOP in bits 16 and
17), word 2 the status word hardware writes (`[15:0]` received length for
RX, 16 DD, 17 TRUNC, 18 ERR, 19 ABORT), word 3 reserved. Software posts
descriptors below TAIL; hardware consumes them in order from HEAD, one
frame each.

`nic_desc_fetch` runs a prefetch cursor ahead of HEAD and reads the line
of the cursor's descriptor into a two-line cache when the cursor is below
TAIL. Which descriptors of that line may be used is decided when the read
is accepted by the port, never when it returns: the cursor's, and the next
one when it is in the same line and below TAIL at that moment. A
descriptor posted later is therefore always read again after its
doorbell, which is what makes the slice 1 doorbell argument (cached
descriptor stores ordered before the MMIO TAIL store, the read's probe
writing the dirty line back) deliver the posted image. A disable or the
drain invalidates the cache; a BASE/SIZE write also zeroes HEAD.

`nic_rx_engine` admits a frame only with an eligible descriptor cached (an
empty ring holds the frame in the FIFO) and applies the filter to the
first beat: promiscuous, a group address, or the station address. A
rejected frame is consumed without a descriptor. An accepted one goes
through `nic_byte_pack`, which rotates each beat by the buffer address
modulo 8 and places it in a two-line window, issuing a line write with the
strobes it accumulated whenever the window's lower line is complete; bytes
beyond the buffer length are dropped and the status carries TRUNC with the
full received length. A buffer of length 0 or outside the aperture
consumes the frame and completes with DD|ERR. The status write is issued
only after every data write of the frame has been answered, and one status
write is in flight per direction, so DD becomes visible in ring order and
a reader that sees DD and then reads the buffer sees the data.

`nic_tx_engine` validates a descriptor (length 1..9216, SOP and EOP,
buffer inside the aperture; DD|ERR and nothing sent otherwise), reads the
buffer's lines in address order with up to four in flight or waiting in a
reorder buffer, and `nic_byte_unpack` turns them into beats, the last
carrying the remaining bytes. When the last beat has entered the FIFO the
status write is issued; DD means the buffer has been read.

`nic_dma_front` owns the port: it registers one request per engine,
presents RX before TX (a TX request that has watched `STARVATION_LIMIT` RX
grants goes first), lets a refused presentation hand the next cycle to the
other engine, caps a side at three of the four entries so the other side
always finds one, steers each response to its owner by entry, refuses
addresses outside cached DDR with an error response instead of a port
request, and under the drain withdraws its registered requests with error
responses and waits for the fired ones. Every request an engine hands it
gets exactly one response.

A MAC-domain reset that is not a NIC RESET is a stream epoch change: the
engines see it as a level (`i_abort`), abandon the frame in progress
(RX: no more bytes written, DD|ERR|ABORT after the outstanding writes;
TX: nothing more pushed, DD|ERR|ABORT after the outstanding reads) and
resume at a frame boundary when it clears. The RESET drain (`i_stop`)
abandons the frame without a completion and reaches idle once every
response is in.

## Registers

`nic_csr` implements the driver-facing map in `nic_pkg` (byte offsets in
the 4 KiB window; 32-bit registers, 64-bit counters from 0x080 read whole):
ID, CTRL (RX_EN, TX_EN, PROMISC, RESET), STATUS (idle, RESET_BUSY, RX FIFO
empty, READY and CONFIG_ERR per direction), MAC_LO/HI, the RX and TX ring
registers (BASE, SIZE, TAIL, HEAD), the interrupt registers (in `nic_irq`),
LINK (the PCS and MAC levels plus CARRIER), PHY_CTRL and PHY_STATUS. An
enable is accepted only while the direction is READY and its ring is valid
(BASE 32-byte aligned, SIZE in 2..16, the ring inside cached DDR); a refused
enable sets CONFIG_ERR and raises DESC_ERR. BASE and SIZE are writable only
while the direction is disabled and idle, and a write starts a new ring
generation. RESET (CTRL bit 8) is the unconditional abort-and-drain of the
reset section: it reads back as RESET_BUSY, configuration writes are
ignored meanwhile, and it returns every ring register, enable, counter and
the interrupt block to defaults while the station address, PROMISC and
PHY_CTRL survive. A direction whose MAC domain loses READY is disabled.

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
across resets. `test_nic_dma_front.py` (`nic_dma_front`): response
steering under out-of-order responses, the per-side cap, the grant bound,
a refused line not blocking the other engine, aperture refusal, the drain.
`test_nic_byte_pack.py` and `test_nic_byte_unpack.py`: the byte invariant
(input byte j lands at, or comes from, address A + j) over every offset,
lengths 1..100 and jumbo, truncation, stalls at line crossings.
`test_nic_rx_engine.py` and `test_nic_tx_engine.py` run the engines
against a memory model with out-of-order responses (`dma_model.py`): data
byte-exact with nothing written outside the buffers and status words, the
filter, truncation and bad descriptors, the ring-empty hold, the doorbell
re-read, status after data and in ring order, abort and the drain. `formal/async_fifo.sby` bounds the FIFO under free-running
unrelated clocks: occupancy, no underflow, Gray consistency, and a watched
word delivered in order and intact.
