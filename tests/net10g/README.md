# Standalone Ethernet verification

The 10GBASE-R Ethernet MAC and PCS in
[`hw/rtl/net10g`](../../hw/rtl/net10g/README.md) have their own cocotb
benches and a portable synthesis check. The benches compile only the
`net10g` modules, the two-flop synchronizer they take from `hw/rtl/lib/cdc`
(`cdc_sync.sv`), and the harnesses in this directory. They do not depend on
the CPU, software applications, the main test registry, or a GTY simulation
model. The [RTL README](../../hw/rtl/net10g/README.md) describes the
interfaces, rates, packet behavior, and implementation limits.

CI runs the benches and the synthesis check in the pinned image. The
`net10g-results` artifact holds the simulation results and synthesis logs,
including those of failed runs.

## Simulation

Run through frost, from the repository root:

```bash
./scripts/frost.py run python3 tests/net10g/run.py all                # every target
./scripts/frost.py run python3 tests/net10g/run.py codec scrambler    # selected targets
./scripts/frost.py run python3 tests/net10g/run.py mac_tx mac_rx mac_rx_60 mac_rx_124 integration
```

`run.py` refuses to run outside the container. It cleans each target before
building and puts results and build products in `sim_build/<target>/`.
Different targets can run at the same time, but not two runs of the same
target. Random seeds are fixed.

`mac_rx_60` and `mac_rx_124` rerun the receive tests with `MAX_FRAME_BYTES`
set to 60 and 124, which brings the MAC's storage limits within a few frames.
Cases that cannot occur at those limits are skipped.

| Target | Coverage |
| --- | --- |
| `crc` | Independent zlib checks across arbitrary CRC seeds and byte masks |
| `codec` | The published golden encoding; every legal block format, C code, and O code; malformed words, headers, and fields; ignored reserved padding |
| `scrambler` | The published Clause 49 scrambler vectors; a serial reference; reset and enable pauses; three-error propagation and self-synchronization |
| `sequence` | Every sequence of four blocks from the five block classes; termination lookahead; pauses and reset; explicit error and control classification |
| `gearbox` | Independent bit queues, all packing phases, randomized slips, sparse input and reset, continuous TX output |
| `link` | Exact block-lock thresholds and windows; signal loss; BER thresholds and the physical-clock timer; local and remote fault qualification and timeout |
| `tx_reconcile` | Midframe faults, local fault priority, paused enable, recovery at an idle boundary, suppression of packet tails |
| `mac_tx` | Independent XGMII and FCS checking; lengths, padding, and termination lanes; AXIS back-pressure; malformed, oversized, and aborted packets; resets |
| `mac_rx` | Independent XGMII source and zlib FCS; both start lanes, including across enable gaps; malformed frames at every preamble position and termination lane; stalls and overflow; data and descriptor wraparound and rollback; mixed sizes; restart after early drops; clock-exact handshake release and final-beat credit; reset of the decode stage and output register |
| `mac_rx_60`, `mac_rx_124` | The `mac_rx` cases at small frame limits, plus a frame that runs past the limit and out of space at once (reported as overlength) and admission with an empty output register |
| `integration` | Independent raw-bitstream peers in both directions; AXIS stalls from startup; every receive bit phase; invalid termination lookahead; CRC rejection; PMA loss midframe and relock |

The integration bench runs the transmit and receive clocks at the same period
with different phases, so it does not test metastability or board clocking.
Packet clock-domain crossing belongs to the enclosing
[NIC](../../hw/rtl/peripherals/nic/README.md), not the MAC/PCS.

## Portable synthesis

```bash
./scripts/frost.py run python3 tests/net10g/synthesize.py
```

sv2v, pinned in the image, converts the sources, and Yosys runs coarse
synthesis. If the image lacks the pinned sv2v, the script downloads its
release archive, checks the SHA-256, and caches it in `sim_build/synthesis/`.

The check fails on latches, blackboxes, structural errors, and out-of-range
bit selects. Logs, source hashes, the converted Verilog, a JSON netlist, and
`summary.json` stay in `sim_build/synthesis/`.

This checks RTL structure, not FPGA RAM mapping, timing, transceiver
operation, or interoperability with real hardware. Run any Vivado check
natively, in an output directory separate from any active CPU build.
