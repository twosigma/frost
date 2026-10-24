# AXI library

AXI4 blocks for the masters that reach cached memory without a CPU: the NIC
and the DMA test engine in `soc_top`, and later any block with an AXI4 master
port. `axi_mux` joins the masters and `axi_coherent_bridge` turns their bursts
into requests on `cpu_top`'s coherent ingress, so their reads see data still
dirty in the L1D and their writes update or invalidate the CPU's cached
copies.

| File | Role |
|------|------|
| `axi_coherent_bridge.sv` | AXI4 slave into the coherent ingress: classifies each burst, splits it into line requests, and returns B and R in AXI order |
| `axi_mux.sv` | N AXI4 slave ports onto one AXI4 master port, round-robin per burst, with the port index prefixed to ids |
| `axi_checker.sv` | Simulation-only protocol monitor for one AXI4 interface |
| `axi_mux_test_harness.sv` | cocotb top: `axi_mux` with three ports, each named separately |

In `soc_top` and the TestRIG platform:

```
nic_top (line_port_axi_bridge inside) --+
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

The NIC is port 0 and the engine port 1; their 3-bit ids reach the bridge as
4-bit ids. An `axi_checker` watches each port and the bridge's slave port
in simulation.

## axi_coherent_bridge

Each AW and AR waits one cycle in an input register and is classified there.
A burst with AxSIZE wider than the bus, the reserved burst type, a FIXED
burst over 16 beats, a WRAP burst that is not 2, 4, 8 or 16 beats from an
AxSIZE-aligned address, or an INCR burst that crosses a 4 KiB boundary is
answered SLVERR. One whose start address lies outside
`[REGION_BASE, REGION_BASE + REGION_BYTES)` is answered DECERR. Neither sends
a line request: the bridge takes the burst's W beats and answers its B, or
every R beat with zero data, with the code. The region's boundaries are 4 KiB
aligned, so a legal burst that starts inside it ends inside it. AxLOCK,
AxCACHE, AxPROT and AxQOS are ignored, and an exclusive access is performed
as a normal one and answered OKAY, as AXI4 specifies for a slave without
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
response has a place in the read buffer. Writes take the line port first,
and a read waits for at most `STARVATION_LIMIT` write grants. The choice is
held while the presented request waits, as the ingress requires.

Every AXI READY and every B and R output comes from registered state, and
the line request is presented from registers. A one-beat read takes five
cycles from its AR handshake to its R beat when the ingress answers in the
next cycle; each segment occupies the line port for one cycle.

`i_rst` is synchronous, and while it is asserted every VALID and READY is
low. The bridge resets with its AXI masters, and each reset of the ingress,
which drops the requests it holds, must overlap one of the bridge. In
`soc_top` the masters, the mux and the bridge reset with `rst_core`, and the
ingress's reset includes it.

## axi_mux

The downstream id is `{port index, upstream id}`, so B and R return to the
port named by their id's top bits. AW and AR are each granted round-robin, a
burst at a time, and a grant is held while the downstream VALID waits. AW is
granted only to a port that also presents WVALID, which AXI4 allows a slave
to require, so a master whose write data is late cannot hold the W channel.
Each downstream AW records `{port, AWLEN}` in a `W_DEPTH`-entry FIFO, and W
beats come from the port at its head.

The mux holds no beat: VALID and payload pass down and READY up through
combinational paths, which AXI4 does not allow between one component's inputs
and outputs. It is used only between interfaces that drive their outputs from
registers and take their inputs into registers, as in `soc_top`. A port that
leaves the SoC needs an AXI register slice.

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
| `axi_mux` | Three masters sharing id values against a reordering slave, late write data, and reset mid-traffic |

Unbounded formal safety proofs cover the bridge (`axi_coherent_bridge`: AXI4 slave
rules, B and R order and codes, each line write carrying exactly the bytes
of its segment, R data for an arbitrary byte, and the ingress's request
rules, with 8-byte lines on a 16-bit and a 64-bit bus and in `soc_top`'s
configuration) and the mux (`axi_mux`: AXI4 rules on every port, W in
AW-grant order, and B and R reaching the port their id names); see the
[formal guide](../../../../formal/README.md). These proofs establish response
ordering, no duplicate responses and conservation of outstanding requests;
they do not establish eventual completion or starvation freedom. The three
bridge cocotb benches and the mux bench check completion with timeouts,
including reads under sustained writes in the bridge. The whole-system programs
`dma_torture`, `nic_loopback`, `nic_echo` and the `pa_dma_test` and
`pa_nic_packet_test` families run the NIC and the engine through the bridge
in both memory configurations.
