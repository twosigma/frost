# NIC (net10g on the coherent DMA port)

FROST's NIC puts the [10GBASE-R MAC/PCS](../../net10g/README.md) on the SoC.
Software sees a 4 KiB register window at `0x4003_0000` and one interrupt
(PLIC source 4). Frames move through RX and TX descriptor rings in cached
DDR, which the NIC reads and writes over the cache hierarchy's coherent DMA
port, so the driver needs no cache maintenance. Packet FIFOs cross between
the CPU clock and the MAC's two clocks; on the X3 those are the transceiver's
161.13 MHz TX and RX clocks. This file is the hardware reference the Linux
driver ([`frost_net10g`](../../../../linux/frost-net10g/README.md)) follows.

| Module | Domain | Responsibility |
| --- | --- | --- |
| `nic_pkg.sv` | - | Register map, interrupt bits, beat codes, request kinds, and descriptor bits, shared with the benches and `sw/lib/include/nic.h` |
| `nic_top.sv` | all | The NIC: the core-domain blocks below around `nic_mac_wrap`. Faces the SoC with the register window, DMA line port, and interrupt, and the board with the MAC clocks, the raw PMA interface, and the PCS block lock |
| `nic_csr.sv` | core | Register file: control, status, station address, rings, link and PHY registers, 64-bit counters |
| `nic_irq.sv` | core | Interrupt status, mask, and per-direction completion moderation |
| `nic_mac_wrap.sv` | MAC + core | The MAC/PCS in its two domains, the packet FIFOs, the domain resets, status synchronizers, event counters, and the raw loopback (`RAW_LOOPBACK`) |
| `nic_dma_front.sv` | core | Both engines' requests onto the one DMA line port: four entries with at most three per side, RX priority with a grant-counted bound, response steering, aperture refusal, and the RESET drain |
| `nic_desc_fetch.sv` | core | One ring's descriptor supply: prefetch cursor, two-line cache, eligibility fixed when the read is requested |
| `nic_rx_engine.sv` | core | Frames from the RX FIFO into ring buffers: filter, `nic_byte_pack`, truncation, status writes |
| `nic_tx_engine.sv` | core | Ring buffers into the TX FIFO: validation, reads through a reorder buffer, `nic_byte_unpack`, status writes |
| `nic_byte_pack.sv` | core | 8-byte beats to strobed 32-byte line writes at any byte address |
| `nic_byte_unpack.sv` | core | 32-byte lines to 8-byte beats from any byte offset |
| `nic_reset_ctrl.sv` | core | The RESET sequence and the per-domain reset generation handshake |
| `nic_domain_reset.sv` | MAC (one per domain) | Applies the domain reset and acknowledges the generation |
| `nic_reset_test_harness.sv` | bench | Controller, two domains, two `async_fifo`s, and a `cdc_gray_count` across three clocks |

The crossing primitives live in `hw/rtl/lib/cdc` (`cdc_sync`,
`cdc_reset_sync`, `cdc_gray_count`) and `hw/rtl/lib/fifo/async_fifo.sv`.

## Integration

`cpu_and_mem.sv` instantiates `nic_top`:

| Interface | Connection |
| --- | --- |
| Registers | A 4 KiB window at `0x4003_0000`, inside the strongly ordered MMIO range |
| Interrupt | PLIC source 4 |
| DMA | The cache hierarchy's coherent DMA port, through a two-port `line_port_arbiter` shared with the DMA test engine. The NIC is port 0 and has priority, within the arbiter's starvation bound. Each agent uses 2-bit ids, and the arbiter adds the port bit |
| MAC clocks | `frost.sv` brings in the TX and RX clocks separately, each with a presence level (`i_nic_tx_clk`, `i_nic_rx_clk`, `i_nic_tx_clk_ok`, `i_nic_rx_clk_ok`), and gives the PHY inputs defaults |
| Block lock | `o_nic_rx_block_lock` exports the PCS block lock (LINK's RX_LOCKED, already synchronized to the core clock) for a board's transceiver supervisor |

`RAW_LOOPBACK` (a `frost.sv` parameter, default 1, passed down to
`nic_mac_wrap`) builds the raw loopback behind PHY_CTRL's MAC_LOOPBACK. That
path feeds the raw TX word into the RX PCS with no crossing logic, so it
needs one clock on both MAC clock ports, as simulation provides. With
`RAW_LOOPBACK=0`, for a transceiver's independent TX and RX clocks, the
loopback is not built: raw RX comes only from the PHY inputs, and PHY_CTRL
stores MAC_LOOPBACK but it selects nothing. Software chooses MAC_LOOPBACK
from PHY_STATUS's CLK_SHARED, so that build reads CLK_SHARED as 0 whatever
the board drives; the other PHY_STATUS bits follow the board.

Constrain the clock crossings one by one, as the
[X3 constraints](../../../../boards/x3/constr/x3.xdc) do: Gray-bus delay and
skew, single-bit synchronizers, and reset assertion. Cutting the whole clock
pair would hide an unconstrained crossing. The constraints find each
synchronizer by its first-stage register, `stage_q` in `cdc_sync`.

On the X3 the link carries Debian's NFS root over fiber. The bare-metal
examples `sw/apps/nic_loopback` (internal loopback) and `sw/apps/nic_echo`
(echoes frames from a link partner) both have full-system simulation tests.
The Linux driver is a DKMS module for Debian's kernel; see the
[driver guide](../../../../linux/frost-net10g/README.md). The hardware
regression's Linux stage tests it with `frost_nettest` (from the
`frost-stress` package) through the driver's loopback feature: the raw
loopback when both MAC directions share a clock, the transceiver's PMA
loopback otherwise.

### The X3 transceiver

The X3 (`boards/x3/x3_frost.sv`, `RAW_LOOPBACK = 0`) runs the MAC over a GTY
transceiver, wrapped by `boards/x3/x3_nic_gty.sv`:

| Part | X3 setting |
| --- | --- |
| Channel | Channel 0 of quad 231 (GTYE4_CHANNEL_X0Y28), lane 1 of the DSFP28 cage labelled 2 |
| Line | Raw 64-bit PMA at 10.3125 Gb/s; the soft PCS does the 64b/66b coding |
| Clocks | QPLL0 from the card's 161.1328125 MHz Ethernet reference clock. The TX USRCLK2 and the recovered RX USRCLK2 are the MAC clocks |
| Supervisor | Runs on a free-running 150 MHz clock and owns the transceiver's resets |

A direction's clock-OK means its user clock is running and no reset that
stops that clock is pending (an RX PCS reset leaves it up); every low
interval lasts at least 1 ms, so the NIC's synchronizers see it.
RX_SIGNAL_OK means the transceiver's RX reset is done and no loopback change
or reset is in progress; it drops before any reset that can stop the RX
clock.

If block lock stays absent for 100 ms, the supervisor resets the RX PCS,
which keeps both clocks and READY, and retries after each further 100 ms
without lock. Every tenth retry in a row is a full RX reset (GTRXRESET) instead.
UG578 asks for that after the receive inputs are connected or the far end
powers up, so a fiber plugged in later can still lock. Block lock, or any
reset other than the PCS reset, restarts the count.

These events take clock-OK down:

| Event | Directions |
| --- | --- |
| A PLL lock loss, a TX or RX reset done that drops unasked, or a reset that does not complete in time (each restarts the whole transceiver) | TX and RX |
| PHY_RESET | TX and RX |
| A PMA_LOOPBACK change or a full RX reset | RX |

The NIC then starts a new reset generation in those domains and disables
those directions, as for any lost MAC clock. So while no link partner is
present, RX READY drops about once a second and the NIC disables receive;
the Linux driver enables it again when the carrier returns.

PHY registers on the X3:

| Bit | Behavior |
| --- | --- |
| PHY_CTRL.PHY_RESET | While set, the NIC sees both MAC clocks absent and no receive signal (the transceiver keeps running, with its reset controller's reset-all held). Clearing it runs the full reset sequence |
| PHY_CTRL.PMA_LOOPBACK | Near-end PMA loopback, the NIC's self-test path on this build, applied through an RX reset. The line TX still transmits |
| PHY_CTRL.TX_DISABLE | No effect: the module's transmit disable is not an FPGA pin on this card |
| PHY_STATUS.CLK_SHARED | 0 |
| PHY_STATUS.GT_RESET_DONE | The transceiver's TX and RX reset done |
| PHY_STATUS.CDR_LOCK | The transceiver's RX reset done (its own CDR lock output is reserved) |
| PHY_STATUS.MODULE_PRESENT, LOS | 1 and 0, because no module status reaches the FPGA |

## Reset and clock domains

The NIC has three clock domains: the core clock and the MAC's TX and RX
clocks (one shared clock in simulation, the transceiver's two clocks on the
X3). Each MAC domain's reset comes from a handshake:

- `nic_reset_ctrl` raises a request with a generation bit per domain.
- `nic_domain_reset` asserts the domain's reset through `cdc_reset_sync`
  without waiting for a clock edge, so a domain whose clock is absent still
  sits in reset. Once its own clock has held the reset for at least
  `HOLD_CYCLES` (8) cycles, it answers with the generation it applied; an
  `applied_valid` bit keeps the generation's reset value from ever counting
  as an answer.
- After the controller drops the request, the reset stays asserted for at
  least another `HOLD_CYCLES` domain clocks, with no gap in between. A gap would
  let the core side see the domain out of reset and report it READY while
  the reset came back.

A domain is READY when its current generation has been applied, it is out of
reset, and its clock is reported present. Until then the domain's core-side
FIFO half and the engines' MAC-facing state are held in reset, the register
block refuses an enable, and the domain's event counters rebase. A clock loss
in operation starts a new generation by itself, so nothing resumes on stale
state when the clock returns.

RESET (the CTRL bit) stops the engines, waits until the DMA front end owes no
response, pulses the core-domain reset, and starts a new generation in both
MAC domains. RESET_BUSY covers exactly that and never waits for a MAC clock,
so RESET completes even while the transceiver is in reset. The core's own
reset clears all NIC state, including the station address, PROMISC, and
PHY_CTRL, and then runs the same sequence.

Packets cross in `async_fifo`: Gray-coded pointers through `cdc_sync`,
dual-clock block RAM, and a two-entry output skid over the RAM's registered
read, so no word is presented twice or skipped. Each side resets in its own
domain and clears everything on that side, so no old word can reappear; the
two sides must be in reset together for one window with no traffic, which the
reset controller arranges. MAC event counts cross in `cdc_gray_count`, which
keeps a Gray-coded count in the source domain and accumulates 64-bit totals
in the core domain. Its rebase input, driven while the domain is not READY,
keeps a source reset from reading as a counter wrap.

## Descriptor rings and the DMA path

Descriptors are 16 bytes, two per 32-byte line:

| Word | Contents |
| --- | --- |
| 0 | Buffer address, any byte alignment |
| 1 | Length in `[15:0]`: the buffer length for RX, the frame length for TX. TX also sets SOP (bit 16) and EOP (bit 17) |
| 2 | Status, written by hardware: `[15:0]` received length (RX), 16 DD, 17 TRUNC, 18 ERR, 19 ABORT |
| 3 | Reserved |

A ring has 2^SIZE entries at a 32-byte-aligned BASE in cached DDR. Software
posts descriptors below TAIL, zeroing word 2; hardware consumes them in order
from HEAD, one frame per descriptor, and writes word 2 when it is done.

`nic_desc_fetch` runs a prefetch cursor ahead of HEAD. When the cursor is
below TAIL, it reads the line holding the cursor's descriptor into a two-line
cache. Which descriptors of that line may be used is fixed when the read is
handed to the DMA front end, never when it returns: the cursor's, and the
next one if it is in the same line and below TAIL at that moment. A
descriptor posted later is therefore always read again after its doorbell,
so descriptor stores ordered before the MMIO TAIL write are visible to that
read through the coherent DMA port. Disabling the direction or RESET drops
the cache; a BASE or SIZE write also zeroes HEAD and TAIL.

`nic_rx_engine` admits a frame only when an eligible descriptor is cached; an
empty ring holds the frame in the FIFO. It applies the filter to the first
beat: PROMISC, a group address, or the station address. A rejected frame is
consumed without a descriptor. An accepted frame goes through
`nic_byte_pack`. Every byte of a frame moves by the same amount (the buffer
address modulo 8), so the packer rotates each 8-byte beat once and places it
in a two-line window, and each time the window's lower line is complete it
issues one line write with the strobes it collected. Bytes beyond the buffer
length are dropped, and the status carries TRUNC with the full received
length. A buffer of length 0 or not wholly inside cached DDR consumes the
frame and completes with DD|ERR.

The status write is issued only after every data write of the frame has been
acknowledged, and each direction has one status write in flight at a time.
DD therefore becomes visible in ring order, and a reader that sees DD and
then reads the buffer sees the data.

`nic_tx_engine` validates a descriptor: length 1 to 9216, SOP and EOP both
set (a frame occupies exactly one descriptor), and the buffer inside cached
DDR. An invalid one completes with DD|ERR and sends nothing. A valid one's
buffer is read line by line in address order, with up to four reads in flight
or waiting in a reorder buffer, and `nic_byte_unpack` turns the lines into
beats, the last carrying the remaining bytes. The status write is issued when
the last beat has entered the FIFO: DD means the buffer has been read, not
that the frame reached the wire.

`nic_dma_front` puts both engines on the one DMA port. Every request an
engine hands it gets exactly one response.

- It owns four entries, and the port id is the entry index, so every
  accepted request has a place for its response. Each engine may hold at most
  three, so the other always finds one.
- It presents RX before TX, but a TX request that has watched
  `STARVATION_LIMIT` (8) RX grants goes first.
- When the port refuses a request (for example, because the DMA sequencer
  holds its line), the other engine's request is presented the next cycle,
  so a locked line never blocks the other engine's traffic to a different
  line.
- It refuses an address outside cached DDR with an error response instead of
  a port request.
- During the RESET drain it answers its registered requests with error
  responses instead of issuing them, and waits for the fired ones.
- It relies on the port answering only ids it was given; simulation asserts
  this rather than the hardware filtering responses.

A MAC-domain reset outside a NIC RESET (a lost clock or a transceiver reset)
abandons the frame in progress; the engines see it as the `i_abort` level.
RX writes no more bytes and completes the descriptor with DD|ERR|ABORT once
its outstanding writes are acknowledged; a frame whose last beat has already
arrived completes normally, since it needs nothing more from the MAC. TX
pushes no more beats and completes with DD|ERR|ABORT after its outstanding
reads. Both resume at a frame boundary when the reset ends. The RESET drain
(`i_stop`) abandons the frame without a completion and reaches idle once
every response is in.

## Registers

`nic_csr` implements the map in `nic_pkg.sv`, which `sw/lib/include/nic.h`
mirrors. Offsets are bytes within the 4 KiB window, and registers are 32
bits:

| Offset | Register | Contents |
| --- | --- | --- |
| `0x000` | ID | `0x4E49_4301`: "NIC", ABI version 1 |
| `0x004` | CTRL | 0 RX_EN, 1 TX_EN, 2 PROMISC, 8 RESET (reads back as RESET_BUSY) |
| `0x008` | STATUS | 0 RX_IDLE, 1 TX_IDLE, 2 RESET_BUSY, 3 RX_FIFO_EMPTY, 4 RX_READY, 5 TX_READY, 6 RX_CONFIG_ERR, 7 TX_CONFIG_ERR |
| `0x00C`, `0x010` | MAC_LO, MAC_HI | Station address: bytes 0 to 3 in MAC_LO (byte 0 in `[7:0]`), bytes 4 and 5 in MAC_HI `[15:0]` |
| `0x020`–`0x02C` | RX_BASE, RX_SIZE, RX_TAIL, RX_HEAD | RX ring: base address, log2 of the entry count, producer index, consumer index (read-only) |
| `0x030`–`0x03C` | TX_BASE, TX_SIZE, TX_TAIL, TX_HEAD | TX ring, same layout |
| `0x040`–`0x058` | IRQ_STATUS, IRQ_MASK, RX_ITR, TX_ITR, TICK, IRQ_MASK_SET, IRQ_MASK_CLR | See [Interrupts](#interrupts) |
| `0x060` | LINK | 0 RX_LOCKED, 1 RX_HIGH_BER, 2 RX_LOCAL_FAULT, 3 RX_REMOTE_FAULT, 4 TX_LINK_READY, 5 RX_SIGNAL_OK, 6 TX_CLK_OK, 7 RX_CLK_OK, 8 CARRIER (RX locked with no high BER or fault, and TX link ready) |
| `0x064` | PHY_CTRL | 0 MAC_LOOPBACK, 1 PHY_RESET, 2 PMA_LOOPBACK, 3 TX_DISABLE |
| `0x068` | PHY_STATUS | 0 CLK_SHARED, 1 GT_RESET_DONE, 2 CDR_LOCK, 3 MODULE_PRESENT, 4 LOS |
| `0x080`–`0x0FF` | Counters | 64-bit counters in `nic_pkg` order: RX frames, bytes, filtered, truncated, descriptor errors, and aborts; TX frames, bytes, descriptor errors, and aborts; then the MAC's RX overflow, bad frame, bad FCS, and PCS bad block, and TX drop and PCS bad block |

Use 32-bit loads and stores. The register bus has no byte enables, so a byte
or halfword store is replicated over the whole register (a byte store of 1 to
CTRL sets RESET), and a 64-bit store writes only the upper register of its
dword. A 64-bit load returns an aligned register pair; read each counter
whole with one 64-bit load.

- An enable is accepted only while the direction is READY and its ring is
  valid: BASE 32-byte aligned, SIZE in 2..16, and the whole ring inside
  cached DDR. A refused enable sets the direction's CONFIG_ERR and raises
  DESC_ERR.
- Clearing an enable stops new frames and descriptor fetches; a frame in
  progress finishes. The direction's IDLE bit shows when nothing is in
  flight.
- BASE and SIZE are writable only while the direction is disabled and idle.
  Writing either starts a new ring generation: TAIL and HEAD return to 0 and
  the descriptor cache is dropped.
- A CTRL write with RESET set requests the reset, and nothing else in that
  write takes effect.
- RESET is the unconditional abort-and-drain described under
  [Reset and clock domains](#reset-and-clock-domains). It reads back as
  RESET_BUSY, and configuration writes are ignored until it completes. It
  returns every ring register, enable, and counter, and the interrupt block,
  to their defaults; the station address, PROMISC, and PHY_CTRL survive.
- A direction whose MAC domain loses READY is disabled. Its ring registers
  and HEAD are kept.

## Interrupts

`nic_irq` implements the interrupt rules the driver relies on.

- IRQ_STATUS (`0x040`) is sticky and write-1-to-clear; a set wins over a
  clear in the same cycle.
- IRQ_MASK (`0x044`) gates the level interrupt line. IRQ_MASK_SET (`0x054`)
  and IRQ_MASK_CLR (`0x058`) change it atomically, so two contexts never
  read-modify-write it. Masking loses nothing: counting, timing, and latching
  continue while masked.

| Bit | Name | Raised by |
| --- | --- | --- |
| 0 | RX | Moderated RX completions |
| 1 | TX | Moderated TX completions |
| 2 | RX_DROP | A received frame filtered out, completed with ERR or ABORT, or lost to MAC overflow |
| 3 | LINK | A change of LINK's CARRIER |
| 4 | DESC_ERR | A descriptor completed with ERR or ABORT, or a refused enable |

RX_DROP, LINK, and DESC_ERR are plain event latches. RX and TX are moderated
notifications, not "descriptors are waiting". For each direction:

- Acknowledging the bit (writing 1 to it in IRQ_STATUS, even when it reads 0)
  starts a new interval: it clears the notification, the completion count,
  and the timer.
- Every completion (one per DD write response) in an interval counts,
  saturating. The first one snapshots RX_ITR or TX_ITR (`0x048` / `0x04C`:
  `[15:0]` delay in ticks, `[23:16]` max count) and TICK (`0x050`: core cycles
  per tick, 0 counting as 1; it resets to `CLK_FREQ_HZ / 1_000_000`, about
  one microsecond), and starts the deadline, which later completions do not
  restart.
- The bit is raised when the count reaches max (max 0 disables this) or the
  deadline passes. Delay 0 raises on the first completion whatever max says.
- A raise stops the timer. Completions while the bit is set belong to the
  same interval; a completion in the cycle of the acknowledgement belongs to
  the new one. Configuration changes apply from the next interval.

The driver's rule, which makes this lossless: acknowledge before scanning the
rings (flushing the acknowledgement with a register read), never after the
final scan.

## Verification

| Cocotb target | Coverage |
| --- | --- |
| `async_fifo`, `cdc_gray_count` | Clock crossings, ordering, reset, and event counts |
| `nic_irq`, `nic_reset` | Interrupt moderation, reset and drain, and absent or lost clocks |
| `nic_dma_front` | Tagged responses, fairness, aperture errors, and drain |
| `nic_byte_pack`, `nic_byte_unpack` | Byte placement, alignment, truncation, and backpressure |
| `nic_rx_engine`, `nic_tx_engine` | Rings, filtering, buffer and status ordering, malformed descriptors, and aborts |
| `nic_top` | Whole NIC with three clocks and raw loopback |
| `nic_top_unrelated_clocks` | Independent TX and RX clocks with `RAW_LOOPBACK=0` |
| `nic_loopback`, `nic_echo` | Full-system software tests in both memory tiers |

Run with `./scripts/frost.py cocotb <target>`. The
[NIC benches](../../../../verif/cocotb_tests/nic/) contain the detailed cases.
The `async_fifo` formal target checks bounded ordering and occupancy under
unrelated clocks. Linux driver testing uses `frost_nettest`; see the
[driver guide](../../../../linux/frost-net10g/README.md).
