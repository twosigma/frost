# AXI library

AXI4 interconnect, coherent ingress and clock crossings for the CPU, NIC
and DMA test engine in `soc_top`. `axi_mux` joins the masters and
`axi_coherent_bridge` turns their bursts
into requests on `cpu_top`'s coherent ingress, so their reads see data still
dirty in the L1D and their writes update or invalidate the CPU's cached
copies.

| File | Role |
|------|------|
| `axi_cdc.sv` | Five independent asynchronous FIFOs carrying all AXI4 channel fields between unrelated clocks |
| `axi_coherent_bridge.sv` | AXI4 slave into the coherent ingress: classifies each burst, splits it into line requests, and returns B and R in AXI order |
| `axi_mux.sv` | N AXI4 slave ports onto one AXI4 master port, round-robin per burst, with the port index prefixed to ids |
| `axi_register_slice.sv` | Five-channel AXI4 two-entry skid register slice isolating VALID, payload and READY outputs |
| `axil_register_slice.sv` | Five-channel AXI4-Lite two-entry skid register slice isolating VALID, payload and READY outputs |
| `axil_reg_bridge.sv` | 64-bit AXI4-Lite slave to register-file adapter with 32-bit writes, aligned 64-bit reads and optional full-dword wide writes |
| `axi_checker.sv` | Simulation-only protocol monitor for one AXI4 interface |
| `axil_checker.sv` | Simulation-only protocol monitor for one AXI4-Lite interface |
| `axi_mux_test_harness.sv` | cocotb top: `axi_mux` with three ports, each named separately |

In `soc_top` and the TestRIG platform:

```
nic_engine (line_port_axi_bridge inside) --+
                                        +-- axi_mux -- axi_coherent_bridge -- coherent ingress
dma_test_engine_axi ---------------------+
```

The bus is 256 bits. The NIC moves one 32-byte beat per line. The engine
does the same or, with `MODE.BURST` set, moves each line as four 8-byte
beats: a WRAP read starting at dword (line index mod 4) and an INCR write.
The bridge makes each narrow beat a line request of its own, skipping write
beats with no strobes, so a CPU store can land between two beats of one
line. A line copied in burst mode can then mix older and newer source data,
and its destination changes a beat at a time. Without concurrent stores to
either region both modes produce the same data, and in both the data writes
complete before the optional status write and interrupt.

The primary NIC is port 0 and the engine port 1. In the two-port TestRIG
platform (`frost_rvfi_platform.sv`), their 3-bit ids reach the bridge as
4-bit ids. In `soc_top`, `axi_mux` also carries the hart's non-cacheable
alias port (plus the secondary 1G NIC when `ENABLE_1G_ETH != 0`), so default
builds (`BaseDmaPorts` = 3 or 4, `EXT_DMA_PORTS = 0`) present 5-bit ids to
the bridge, widening to `max(3, EXT_DMA_ID_BITS) + clog2(BaseDmaPorts +
EXT_DMA_PORTS)` when external DMA ports are enabled. An `axi_checker`
watches each port and the bridge's slave port in simulation.

## axi_cdc

The AW, W and AR channels cross from the source clock to the destination
clock; B and R cross in the reverse direction. Each FIFO uses registered
Gray pointers, two-flop synchronizers and dual-clock RAM with a registered
output skid buffer. A channel preserves its full payload and holds VALID
and payload through backpressure. Address and data channels are independent.
`DEPTH` defaults to four RAM entries per channel, plus the output skid.

The caller supplies synchronous resets with an overlapping assertion
window and no traffic until both sides have observed reset.
`cdc_reset_pair` holds both sides until each clock has advanced its release
chain, including when a clock stops. Reset discards every queued channel
beat, so the connected owners reset together. CPU-only reset leaves the
memory crossing active to drain the CPU master's outstanding requests.

In the optional FROST CPU clock configuration, the memory master crosses
before `soc_axi_slave`. DMA crosses after `axi_mux`, and
`axi_coherent_bridge` runs on the CPU clock. The common-clock configuration
uses direct wires. The constraints bound Gray-pointer and payload paths
below a period of the faster clock, without an asynchronous clock-group
exception between these two clocks.

## axi_coherent_bridge

Each AW and AR waits one cycle in an input register and is classified there.
A burst with AxSIZE wider than the bus, the reserved burst type, a FIXED
burst over 16 beats, a WRAP burst that is not 2, 4, 8 or 16 beats from an
AxSIZE-aligned address, or an INCR burst that crosses a 4 KiB boundary is
answered SLVERR. One whose start address lies outside
`[REGION_BASE, REGION_BASE + REGION_BYTES)` is answered DECERR. Neither sends
a line request: the bridge takes the burst's W beats and answers its B, or
every R beat with zero data, with the code. The region's boundaries are 4 KiB
aligned, so a legal burst that starts inside it ends inside it. The bridge
captures AWCACHE[3] for writes and ARCACHE[2] for reads with each burst. A
clear allocation bit marks its line requests as streaming. The coherent
home restricts streaming miss allocations to way 0 and services hits in
any way. AxLOCK, AxPROT and AxQOS are ignored, and an exclusive access is
performed as a normal one and answered OKAY, as AXI4 specifies for a slave without
exclusive support.

Beat addresses and byte lanes follow AXI4 for FIXED, INCR and WRAP bursts,
and W strobes are masked to each beat's lanes. A segment is the set of beats
one line request serves. When the bus is as wide as a line each beat is a
segment of its own. On a narrower bus a segment is a run of consecutive beats
in one line, merged in an assembly register, later beats overwriting earlier
ones byte by byte. A segment with no strobe set sends no request.

Line writes leave in AW and beat order, line reads in AR and beat order, and
the two directions are independent, as in AXI. A burst's B waits until all of
its W beats are in and every line it wrote has been answered, so a B means
the burst's bytes are ordered at the L2. R returns in AR order, one burst at
a time. An error from the ingress makes the burst's B SLVERR, or the R beats
of that line SLVERR. The tables hold `WRITE_BURSTS` and `READ_BURSTS` bursts,
four each by default, counting the input registers.

Writes use line ids `{0, n}` and reads `{1, n}`, n below
`2^(LINE_ID_BITS - 1)`. A write id is held from the segment's seal to its
line response; a read id until its segment's last R beat, so every line
response has a place in the read buffer. A write takes the lowest free id. A
read takes the first free id after the last read's, so a retired read id is
reused last: the coherent ingress answers a read at its grant and holds its
id until the home's release. Writes take the line port first,
and a read waits for at most `STARVATION_LIMIT` write grants. The choice is
held while the presented request waits, as the ingress requires.

The cluster ingress admits eight line requests and preserves every bit of
the bridge's line ID. In soc_top the bridge's line IDs are four bits wide,
the full coherent request ID, so it has eight read and eight write IDs, and
its tables hold eight bursts per direction. A write's line response follows the
matching home Release, after its data operation and completion acknowledgement;
a read's follows its grant, which carries its final data. The ingress holds an
ID until both the response and the Release.

Every AXI READY and every B and R output comes from registered state, and
the line request is presented from registers. A one-beat read takes five
cycles from its AR handshake to its R beat when the ingress answers in the
next cycle; each segment occupies the line port for one cycle.

`i_rst` is synchronous and applies at the flops, so an output can stay live in
a first reset cycle, when the masters and the ingress on that reset ignore it.
The bridge resets with its AXI masters, and each reset of the ingress, which
drops the requests it holds, must overlap one of the bridge. In the
common-clock `soc_top` configuration, the masters, mux and bridge
reset with `rst_core`. A one-cycle core or DDR transport reset reaches the bridge and ingress
on the same edge. The bridge discards any reply already presented on that
edge, and the ingress clears its response valid before the bridge can accept
another reply. The optional
asynchronous configuration pairs the resets of the DMA owners across both
clocks.

## axi_mux

The downstream id is `{port index, upstream id}`, so B and R return to the
port named by their id's top bits. AW and AR are each granted round-robin, a
burst at a time, and a grant is held while the downstream VALID waits. AW is
granted only to a port that also presents WVALID, which AXI4 allows a slave
to require, so a master whose write data is late cannot hold the W channel.
Each downstream AW records `{port, AWLEN}` in a `W_DEPTH`-entry FIFO, and W
beats come from the port at its head.

The mux and its neighbors discard transfers on their shared reset edge.
AW, W and AR can be presented on that edge. Reset clears both held grants
and the W queue. The first AW after release selects the next W owner.

The mux holds no beat: VALID and payload pass down and READY up through
combinational paths, which AXI4 does not allow between one component's inputs
and outputs. It is used only between interfaces that drive their outputs from
registers and take their inputs into registers, as in `soc_top`. A port that
leaves the SoC needs an AXI register slice.

## Register slices

`axi_register_slice` (AXI4) and `axil_register_slice` (AXI4-Lite) put a
two-entry skid buffer on each of the five channels (AW, W and AR forward; B
and R reverse). Every VALID, payload and READY output comes directly from a
register, with zero combinational paths between slave and master ports. Each
channel accepts and presents one beat per cycle when the consumer is ready,
and holds VALID and payload steady across stalls.

`i_rst` is synchronous active-high at the flip-flops only. During reset every
VALID and READY output clears on the clock edge and buffered beats are
discarded, so the upstream and downstream endpoints must share the same reset
epoch (`o_soc_rst` in `soc_top`). Each slice adds one cycle of latency per
direction on the external port it guards: `axi_register_slice` sits off every
CPU path, and `axil_register_slice` sits off every CPU instruction, cache,
BRAM, DDR and internal-MMIO path (traversed only by CPU loads and stores
targeting the optional external AXI4-Lite window).

## axi_checker

The checker reports `$error` when a VALID that has not been accepted drops or
changes its payload, when WLAST is not on beat AWLEN + 1 of its AW (checked
while each W beat follows its AW or comes with it), or when an AW or AR
carries an illegal AxSIZE or burst. An exclusive access reports a `$warning`.
Its body is empty in synthesis and formal builds.

## Verification

| Target | Coverage |
| --- | --- |
| `axi_coherent_bridge`, `axi_coherent_bridge_64`, `axi_coherent_bridge_32` | Random bursts of every type and size against a byte reference at 256, 64 and 32 bits, error bursts, ingress errors, out-of-order line responses with stalls, exhausted ids and tables, read starvation under writes, and reset with bursts in flight |
| `coherent_axi_ingress`, `coherent_axi_ingress_64`, `coherent_axi_ingress_8` | The bridge connected to the ingress (four entries; eight, with soc_top's eight line IDs and bursts per direction, in `_8`), delayed coherent channels, full credits, B after every line release, and shared reset at each coherent stage |
| `axi_cdc` | All channel fields, independent backpressure, full FIFOs, wraparound, reset cancellation, equal periods with phase offset and unequal periods in both directions |
| `axi_mux` | Three masters sharing id values against a reordering slave, late write data, and reset with simultaneous AW, W and AR offers followed by a fresh W owner |
| `axi_register_slice`, `axil_register_slice` | Full-rate streaming, random upstream/downstream stalls, full-skid backpressure and synchronous reset cancellation across all five channels |
| `soc_ext_plugins` | `soc_top` cached build with `EXT_DMA_PORTS=2` (`EXT_DMA_ID_BITS=4`), `EXTERNAL_MAC=1`, `EXT_AXIL_WINDOW=1` and `ENABLE_1G_ETH=1`: packed two-port external DMA bursts (matching IDs across ports) contending with the internal DMA engine, write and read DECERR out-of-aperture responses, external MAC AXI4-Stream TX/RX loopback, independent one-hot TX-ready and RX-ready isolation, APLIC source 2 wired-OR sharing with the 1G NIC, and external AXI4-Lite reads/writes/SLVERR/reset cancellation |
| `soc_ext_axil_bram` | `soc_top` BRAM-only build (`ENABLE_CACHED_TIER=0`, `EXT_AXIL_WINDOW=1`), filtered to `ext_axil_window`: external 16 KiB AXI4-Lite reads and writes across all four pages, SLVERR propagation, and mid-read core reset cancellation |

Unbounded formal safety tasks check the bridge (`axi_coherent_bridge`: AXI4 slave
rules, B and R order and codes, each line write carrying exactly the bytes
of its segment, R data for an arbitrary byte, and the ingress's request
rules, with 8-byte lines on a 16-bit and a 64-bit bus, and with `soc_top`'s
256-bit bus and 32-byte lines at four and eight bursts and line IDs per
direction; addresses are reduced to 16 bits), the mux (`axi_mux`: AXI4
rules on every port, W in AW-grant order, and B and R reaching the port their
id names), the register slices (`axi_register_slice`: per-channel AXI4 and
AXI4-Lite hold rules, two-entry occupancy bounds, ordered payload transfer
and reset clearing), and the clock-domain crossing (`axi_cdc`: per-channel AXI4 hold
rules, in-flight bounds, FIFO ordering across RAM-entry reuse, and reset
gating under `cdc_reset_pair` and `soc_top`'s 1-source-clock `dma_cdc` skew at
reduced widths); see the [formal guide](../../../../formal/README.md). The assertions cover response
ordering, no duplicate responses and conservation of outstanding requests;
they do not establish eventual completion or starvation freedom. The three
bridge cocotb benches and the mux bench check completion with timeouts,
including reads under sustained writes in the bridge. The whole-system programs
`dma_torture`, `nic_loopback`, `nic_dma_stress`, `nic_echo` and the `pa_dma_test` and
`pa_nic_packet_test` families run the NIC and the engine through the bridge
in both memory configurations.

## AXI4-Lite registers

`axil_reg_bridge` connects a 64-bit AXI4-Lite slave to a register file with
32-bit writes, separate complete 64-bit writes, and an aligned 64-bit read
pair. `ADDR_BITS` selects the window offset width. `WIDE_OFFSETS` packs
`WIDE_COUNT` aligned offsets, least-significant entry first.

The bridge accepts AW and W in either order, buffers their payloads, and
executes one transaction at a time through response acceptance. B and R are
registered and return OKAY. AxPROT is accepted and ignored. Reset abandons
transactions and clears control state at the flops; in a first reset cycle
the handshakes and register writes can stay live, and the register file and
the requester take the same reset. A write with every strobe set at a
listed wide offset asserts `o_wr64_en`. Other writes to those dwords have no
effect. For other offsets, any upper-half strobe selects the upper word;
otherwise the lower word is selected. Any set strobe asserts `o_wr_en`, and
byte enables within the selected word do not mask its data. Reads align the
offset down to eight bytes and capture `i_rd_pair` once.

`axil_checker`, instantiated by the bridge, checks held-channel stability,
responses against accepted requests, and the AXI4-Lite response encoding in
simulation. It accepts independent AW and W ordering. Its body is empty in
synthesis and formal builds. `axil_reg_bridge` has formal properties for
transaction conservation and the complete address, strobe and data mapping.

## Integrating board-level blocks

`frost`, `platform_top` and `soc_top` expose three compile-time integration
hooks (all zero by default, so standard builds instantiate zero extra logic)
along with `o_soc_rst`, the core-domain synchronous active-high reset on
`i_clk`. Board-level blocks that attach to any of these ports run on `i_clk`
and reset with `o_soc_rst` (or cross from their own clock through `axi_cdc`
or a dual-clock FIFO before reaching these ports).
An external master or slave samples `o_soc_rst` directly at its flops on
`i_clk`. An extra reset pipeline register would reset it one edge after the
port slices.

### 1. External coherent AXI4 DMA masters (`EXT_DMA_PORTS`)

Set `EXT_DMA_PORTS = N` (requires `ENABLE_CACHED_TIER = 1`) and
`EXT_DMA_ID_BITS = W` (default 3, must be nonzero) on `frost` or `soc_top`
to attach `N` external AXI4 DMA masters, such as a PCIe root complex or an
accelerator, to `dma_interconnect`.

- Port layout: each signal on `i_ext_dma_*` and `o_ext_dma_*` is a flat
  vector packed across ports `0 .. N-1`, where port `p` occupies
  `[p*WIDTH +: WIDTH]`. Data is 256 bits (`wstrb` 32 bits), addresses are
  64-bit full physical addresses, and IDs are `EXT_DMA_ID_BITS` bits wide.
  Internally `axi_mux` extends every upstream ID to
  `max(3, EXT_DMA_ID_BITS)` and prefixes `clog2(BaseDmaPorts + N)` port bits.
- Register-slice isolation: `soc_top` places an `axi_register_slice` on every
  external port between the top-level pins and `axi_mux`, so external logic
  never creates a combinational loop through `axi_mux`. Simulation also
  attaches an `axi_checker` to each external port.
- Burst and coherence rules: FIXED, INCR and WRAP bursts follow AXI4 rules
  (see `axi_coherent_bridge` above). Legal bursts starting inside
  `[CACHED_BASE, CACHED_BASE + CACHED_SIZE_BYTES)` execute coherently through
  the L2 home, probing L1D without software cache maintenance. Out-of-range
  bursts return DECERR; illegal bursts (over-wide AxSIZE, invalid WRAP length
  or alignment, INCR crossing a 4 KiB boundary) return SLVERR.
- Cache allocation hints: `AWCACHE[3] = 0` or `ARCACHE[2] = 0` marks a burst
  as streaming (miss allocations restricted to L2 way 0, hits served from any
  way); setting the allocation bit allows normal L2 allocation.
- Reset contract: `o_soc_rst` asserts whenever `soc_top` resets the DMA mux,
  slices and coherent bridge (including core reset, SYSRESET and `ndmreset`,
  plus DDR interconnect reset with either common or independent CPU clocks).
  External masters must drop pending transactions on `o_soc_rst` and wait for
  `o_soc_rst == 0` before issuing requests.

### 2. External Ethernet MAC (`EXTERNAL_MAC`)

Set `EXTERNAL_MAC = 1` (requires `ENABLE_CACHED_TIER = 1`) to omit the
internal `nic_mac_10g` block and export the primary `nic_engine`'s core-clock
MAC boundary on `o_ext_mac_*` and `i_ext_mac_*`. The engine keeps its MMIO
register window at `0x4003_0000`, descriptor rings, coherent DMA master and
APLIC source 4 interrupt unchanged.

- Data streams (on `i_clk` / `o_ext_mac_rst`): 64-bit AXI4-Stream TX
  (`o_ext_mac_tx_tvalid`, `i_ext_mac_tx_tready`, `tdata`, `tkeep`, `tlast`,
  `tuser`) and RX (`i_ext_mac_rx_tvalid`, `o_ext_mac_rx_tready`, `tdata`,
  `tkeep`, `tlast`). `tkeep` uses contiguous low-byte masks (`8'hFF` on
  non-final beats, `(8'h01 << n) - 1` for `n` in `1..8` on final beats).
  `o_ext_mac_tx_tuser = 1` on a final TX beat marks an aborted frame that the
  MAC must discard without sending on the wire. `o_ext_mac_tx_csum[14:0]`
  carries the per-frame checksum request (`{offset_div2[6:0], start_div2[6:0],
  enable}`) valid on the first beat of each TX frame.
- Reset and status sideband: `o_ext_mac_rst` is the core reset,
  `o_ext_mac_soft_rst` mirrors `CTRL.RESET` drain/reset, and
  `o_ext_mac_restart` is a one-cycle pulse requesting a MAC-domain reset
  generation. The external MAC returns `i_ext_mac_ready[1:0]` (`{rx_ready,
  tx_ready}`: bit 0 is TX ready, bit 1 is RX ready), `i_ext_mac_link[7:0]`
  (mapped to `LINK[7:0]`; bit 0 also drives `o_nic_rx_block_lock`), and
  `i_ext_mac_raw_loopback_en`.
- Flow control, RX FIFO limit and counters: `o_ext_mac_loopback`,
  `o_ext_mac_station_addr[47:0]`, `o_ext_mac_pause_ctrl[1:0]`,
  `o_ext_mac_pause_high_water[13:0]`, `o_ext_mac_pause_low_water[13:0]`,
  `o_ext_mac_pause_interval[15:0]`, `o_ext_mac_rx_fifo_limit[13:0]`,
  `o_ext_mac_rx_fifo_limit_wr`, `i_ext_mac_rx_fifo_limit_busy`,
  `o_ext_mac_rx_desc_starved` and `i_ext_mac_totals[21*64-1:0]` (21 packed
  64-bit counters in `nic_pkg` order; unused counters may be tied to zero).
- Reference implementations: `hw/rtl/peripherals/nic/nic_mac_10g.sv`,
  `nic_mac_1g.sv` and `nic_mac_cdc.sv` implement this boundary.

### 3. External AXI4-Lite peripheral window (`EXT_AXIL_WINDOW`)

Set `EXT_AXIL_WINDOW = 1` (works with both `ENABLE_CACHED_TIER = 1` and
`ENABLE_CACHED_TIER = 0`) to expose a 16 KiB AXI4-Lite master port
(`o_ext_axil_*` / `i_ext_axil_*`) mapped at physical addresses
`0x4002_4000` through `0x4002_7FFF`.

- Addressing and isolation: `o_ext_axil_awaddr` and `o_ext_axil_araddr` are
  14-bit byte offsets within the 16 KiB window. `soc_top` places an
  `axil_register_slice` on the boundary (plus `axil_checker` in simulation),
  breaking combinational paths between the local device decoder and the
  external slave.
- Data lanes and helper bridge: the port is 64 bits wide (`wdata`/`rdata`
  64 bits, `wstrb` 8 bits) matching the NIC and DMA register ports. For a
  32-bit or mixed 32/64-bit register bank, instantiate `axil_reg_bridge` with
  `ADDR_BITS = 14`. Responses (`bresp`/`rresp`) propagate back to the CPU AXI
  response, so returning `SLVERR` (`2'b10`) raises a load or store access
  fault.
- Interrupts and reset: wire a peripheral's level-high interrupt to
  `i_external_interrupt` (APLIC source 2, wired-OR with the secondary 1G NIC
  interrupt when `ENABLE_1G_ETH != 0` in a cached build, and dedicated to the
  pin when `ENABLE_1G_ETH = 0` or `ENABLE_CACHED_TIER = 0`).
  Reset the slave with `o_soc_rst`; if `o_soc_rst` asserts mid-transaction,
  `soc_top` cancels the pending local access and clears the slice.
