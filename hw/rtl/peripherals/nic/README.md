# NIC (net10g on the coherent DMA port)

FROST's NIC connects the [10GBASE-R MAC/PCS](../../net10g/README.md) to a
CSR window, RX/TX descriptor rings on coherent DMA, and one PLIC interrupt.
Packet FIFOs cross between the CPU and MAC clocks; X3 uses the transceiver's
161.13 MHz TX and RX clocks.

| Module | Domain | Responsibility |
| --- | --- | --- |
| `nic_pkg.sv` | - | the register map, interrupt bits, beat codes, request kinds and descriptor bits shared with the benches and `sw/lib/include/nic.h` |
| `nic_top.sv` | all | the NIC: the core-domain blocks below around `nic_mac_wrap`; register window, DMA line port and interrupt toward the SoC, MAC clocks, the raw PMA interface and the PCS block lock toward the board |
| `nic_csr.sv` | core | the register file: control, status, station address, rings, link and PHY registers, the 64-bit counters |
| `nic_irq.sv` | core | interrupt status, mask, per-direction completion moderation |
| `nic_mac_wrap.sv` | MAC + core | the MAC/PCS in its two domains, the packet FIFOs, the domain resets, status synchronizers, event counters, the raw loopback (`RAW_LOOPBACK`) |
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

## Integration

`cpu_and_mem.sv` instantiates `nic_top` at 0x4003_0000 (a 4 KiB window
inside the strongly ordered MMIO range) with PLIC source 4, and puts it on
the cache hierarchy's coherent DMA port through a `line_port_arbiter`
ahead of the DMA test engine: the NIC is port 0 with priority under the
arbiter's grant bound, each agent presents 2-bit ids and the arbiter adds
the port bit. `frost.sv` carries the TX and RX MAC clocks separately, each
with its presence level (`i_nic_tx_clk`, `i_nic_rx_clk`, `i_nic_tx_clk_ok`,
`i_nic_rx_clk_ok`), and defaults the PHY lines. The `RAW_LOOPBACK` parameter
(default 1, passed from `frost.sv` through `cpu_and_mem` and `nic_top` to
`nic_mac_wrap`) builds the raw loopback behind PHY_CTRL's MAC_LOOPBACK. That
path feeds the raw TX word into the RX PCS with no crossing logic, so it
needs one clock on both MAC clock ports, as simulation provides. With 0, for
a transceiver's independent TX and RX clocks, neither the mux nor its select
synchronizer is built, raw RX comes only from the PHY inputs, and PHY_CTRL
still stores MAC_LOOPBACK, which then selects nothing. Software chooses
MAC_LOOPBACK from PHY_STATUS's CLK_SHARED, so that build reads CLK_SHARED as
0 whatever the board drives; the other PHY_STATUS bits follow the board.
`o_nic_rx_block_lock` exports the PCS block lock (LINK's RX_LOCKED, already
synchronized to the core clock) for a board's transceiver supervisor.

The X3 (`boards/x3/x3_frost.sv`, `RAW_LOOPBACK = 0`) puts the MAC on a GTY
transceiver, `boards/x3/x3_nic_gty.sv`: channel 0 of quad 231
(GTYE4_CHANNEL_X0Y28, lane 1 of the DSFP28 cage labelled 2) as a raw 64-bit
10.3125 Gb/s PMA, QPLL0 from the card's 161.1328125 MHz Ethernet clock, its
TX USRCLK2 and recovered RX USRCLK2 as the MAC clocks. The wrapper's
supervisor runs on a free-running 150 MHz clock and owns the transceiver's
resets. Clock-OK is a direction's user clock running with no reset of that
direction pending, each low interval held for at least a millisecond;
RX_SIGNAL_OK is the transceiver's RX reset done outside any loopback change
or reset, and it drops before any reset that can stop the RX clock. When
block lock stays absent for 100 ms the supervisor resets the transceiver's
RX PCS, which keeps both clocks and READY, and retries every 100 ms while it
stays absent. Every tenth retry in a row is a full RX reset (GTRXRESET)
instead, which UG578 recommends after the receive inputs are connected or
the far end powers up, so that a fiber plugged in later can lock; block
lock, or any reset other than the PCS reset, restarts that count. A PLL
lock loss, a reset done that drops or a reset that does not complete (all
restart the whole transceiver), PHY_RESET (both directions), and a
PMA_LOOPBACK change or a full RX reset (RX) take clock-OK down:
the NIC then starts a new generation in those domains and disables those
directions, as for any lost MAC clock. So while no link partner is present,
RX READY drops about once a second and the NIC disables receive; the Linux
driver enables it again when the carrier returns.

On the X3, while PHY_CTRL's PHY_RESET is set the NIC sees both MAC clocks
absent and no receive signal (the transceiver keeps running with its reset
controller's reset-all held), and clearing it runs the transceiver's full
reset sequence; PMA_LOOPBACK selects near-end PMA loopback, the
NIC's self-test path on this build (the line TX still transmits), applied
through an RX reset; TX_DISABLE has no effect, since the module's transmit
disable is not an FPGA pin on this card. PHY_STATUS reads CLK_SHARED 0,
GT_RESET_DONE as the transceiver's TX and RX reset done, CDR_LOCK as its RX
reset done (the transceiver's own CDR lock output is reserved), and
MODULE_PRESENT 1 with LOS 0, because no module status reaches the FPGA.

Constrain clock crossings individually, as in the
[X3 constraints](../../../../boards/x3/constr/x3.xdc): Gray-bus delay and
skew, single-bit synchronizers, and reset assertion. Cutting the entire
clock pair would hide unconstrained crossings.

The X3 link carries Debian's NFS root over fiber. Bare-metal examples are
`sw/apps/nic_loopback` (internal loopback) and `sw/apps/nic_echo` (echoes
frames from a link partner). Both have full-system simulation tests.

The Linux driver, `frost_net10g`, is in `linux/frost-net10g`: FROST boots
Debian's kernel, which has no driver of its own, so the directory is a DKMS
package that builds it as a module, and `linux/debian_kernel.py` builds it the
same way for the pinned kernel and puts it in the test initramfs.
`frost_nettest` (in the `frost-stress` package) runs it in the hardware
regression's Linux stage through the driver's loopback feature: the raw
loopback where both MAC directions share a clock, the transceiver's PMA
loopback otherwise.

## Reset and clock domains

The NIC has three clock domains: the core clock and the MAC's TX and RX
clocks (one shared clock in simulation, the transceiver's clocks on the
X3). Each MAC domain gets its reset from `nic_domain_reset`:
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
waits for a MAC clock, so RESET completes while the transceiver is in
reset.

`async_fifo` carries packets across: Gray-coded pointers through
`cdc_sync`, storage in the dual-clock block RAM, and a two-entry output
skid over the RAM's registered read so no word is presented twice or
skipped. The write side registers the decoded synchronized read pointer,
adding one write-clock cycle to free-space credit return and separating
Gray conversion from the occupancy/write-enable path. This can prolong
backpressure near full; it does not add latency to a word's read path.
Each side's reset clears its pointer, synchronizer copies, the write-side
decode and (on the read side) the skid and any read in flight; the controller
sequences the two sides so a reset window overlaps. `cdc_gray_count` crosses MAC
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
doorbell, so cached descriptor stores ordered before the MMIO TAIL write are visible
to the read through the coherent DMA port. A disable or the
drain invalidates the cache; a BASE/SIZE write also zeroes HEAD.

`nic_rx_engine` admits a frame only with an eligible descriptor cached (an
empty ring holds the frame in the FIFO) and applies the filter to the
first beat: promiscuous, a group address, or the station address. A
rejected frame is consumed without a descriptor. An accepted one goes
through `nic_byte_pack`, whose two-beat input queue accepts one beat per
cycle while writes flow and keeps RX FIFO ready independent of same-cycle
byte placement and write backpressure. Sustained backpressure fills the queue
and deasserts ready. The queue adds one initial cycle before
byte placement; start, flush, and reset discard queued beats. It rotates each
queued beat by the buffer address modulo 8 and places it in a two-line window,
issuing a line write with the
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
gets exactly one response. Response steering trusts the port to answer only
the ids it was given, and asserts it in simulation: a response whose id is
out of range, or names an entry the front end does not own, is an error
rather than something the module filters. Port eligibility is registered with the next
request and entry occupancy, cutting the drain and free-entry logic out
of the downstream valid/selection path without adding request latency.
Both possible next eligibility values are computed before the sequencer's
ready arrives; whether a request fires selects between them at the register.

A MAC-domain reset that is not a NIC RESET is a stream epoch change: the
engines see it as a level (`i_abort`), abandon the frame in progress
(RX: no more bytes written, DD|ERR|ABORT after the outstanding writes; a
frame whose last beat is already in completes normally, it needs nothing
from the MAC; TX: nothing more pushed, DD|ERR|ABORT after the outstanding
reads) and resume at a frame boundary when it clears. The RESET drain (`i_stop`)
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

| Cocotb target | Coverage |
| --- | --- |
| `async_fifo`, `cdc_gray_count` | Clock crossings, ordering, reset, and event counts |
| `nic_irq`, `nic_reset` | Interrupt moderation, reset/drain, and absent or lost clocks |
| `nic_dma_front` | Tagged responses, fairness, aperture errors, and drain |
| `nic_byte_pack`, `nic_byte_unpack` | Byte placement, alignment, truncation, and backpressure |
| `nic_rx_engine`, `nic_tx_engine` | Rings, filtering, buffer/status ordering, malformed descriptors, and aborts |
| `nic_top` | Whole NIC with three clocks and raw loopback |
| `nic_top_unrelated_clocks` | Independent TX/RX clocks with `RAW_LOOPBACK=0` |
| `nic_loopback`, `nic_echo` | Full-system software tests in both memory tiers |

Run with `./scripts/frost.py cocotb <target>`. The
[NIC benches](../../../../verif/cocotb_tests/nic/) contain the detailed cases.
The `async_fifo` formal target checks bounded ordering and occupancy under
unrelated clocks. Linux driver testing uses `frost_nettest`; see the
[driver guide](../../../../linux/frost-net10g/README.md).
