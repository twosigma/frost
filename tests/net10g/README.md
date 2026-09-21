# Standalone Ethernet verification

These benches compile only the `hw/rtl/net10g` modules, the two-flop
synchronizer they take from `hw/rtl/lib/cdc` (`cdc_sync.sv`), and local
harnesses. They do not depend on the CPU, software apps, the main test
registry, or a GTY simulation model. See
[the RTL README](../../hw/rtl/net10g/README.md) for interfaces, rates, packet
behavior, and implementation limits.

CI runs these benches and the portable synthesis check in the pinned image.
The `net10g-results` artifact contains simulation results and synthesis logs,
including failed runs.

Run **through frost**, from the repository root:

```bash
./scripts/frost.py run python3 tests/net10g/run.py all
# Or select independent targets:
./scripts/frost.py run python3 tests/net10g/run.py codec scrambler
./scripts/frost.py run python3 tests/net10g/run.py mac_tx mac_rx mac_rx_60 mac_rx_124 integration
```

`run.py` requires Docker and cleans each target before building. Results and
build products are under `sim_build/<target>/`. Different targets can run
concurrently; do not run the same target twice at once. Random seeds are fixed.

`mac_rx_60` and `mac_rx_124` rerun RX tests with smaller `MAX_FRAME_BYTES`
limits to exercise storage boundaries; unreachable cases are skipped.

| Target | Coverage |
| --- | --- |
| `crc` | Independent zlib checks across arbitrary CRC seeds and byte masks |
| `codec` | Published golden encoding; every legal block format/C/O code; malformed words, headers and fields; ignored reserved padding |
| `scrambler` | Ten published golden words; serial reference; reset/enable pauses; three-error propagation and self synchronization |
| `sequence` | All 625 four-block class sequences; termination lookahead; pauses/reset; explicit error-control classification |
| `gearbox` | Independent bit queues, all packing phases, randomized slips, sparse input/reset, continuous TX output |
| `link` | Exact block-lock thresholds/windows; signal loss; BER thresholds and physical timer; LF/RF qualification and timeout |
| `tx_reconcile` | Midframe faults, local priority, paused enable, idle-boundary recovery, suppression of packet tails |
| `mac_tx` | Independent XGMII/FCS checking; lengths/padding/termination lanes; AXIS backpressure; malformed/oversized/aborted packets; resets |
| `mac_rx` | Independent XGMII source and zlib FCS; both start lanes, including across enable gaps; malformed frames at every preamble position and termination lane; stalls/overflow; data/descriptor wraparound and rollback; mixed sizes; restart after early drops; clock-exact handshake release and final-beat credit; reset of the decode stage and output register |
| `mac_rx_60`, `mac_rx_124` | The `mac_rx` cases at small frame limits, adding the overlength/no-space tie and admission with an empty output register |
| `integration` | Independent raw-bitstream peers in both directions; AXIS stalls from startup; every receive bit phase; invalid termination lookahead; CRC rejection; PMA loss midframe and relock |

Integration tests use equal nominal clock periods with distinct phases;
they do not validate metastability or board clocking. Packet CDC belongs to
the enclosing NIC, not the MAC/PCS.

To check new files with the repository's pinned hooks without running
auto-fixers over unrelated files:

```bash
./scripts/frost.py run pre-commit run --files \
  hw/rtl/net10g/*.sv hw/rtl/net10g/*.md hw/rtl/net10g/net10g.f \
  tests/net10g/*.sv tests/net10g/*.py tests/net10g/Makefile tests/net10g/README.md
```

The configured mypy hook still checks the repository's complete `verif` and
`tests` trees. Formatter/license hooks may update the new files; review and
rerun when they do.

## Portable synthesis

```bash
./scripts/frost.py run python3 tests/net10g/synthesize.py
```

The check uses the image's pinned sv2v frontend and Yosys for coarse
synthesis. An older image without sv2v downloads and verifies the pinned
archive under `sim_build/synthesis/`.

It rejects latches, blackboxes, structural errors, and out-of-range reads.
Logs, RTL hashes, converted Verilog, a JSON netlist, and `summary.json` are
retained under `sim_build/synthesis/`.

This checks RTL structure, not FPGA RAM mapping, timing, transceiver
operation, or hardware interoperability. Run Vivado checks natively in a
separate output directory from any active CPU build.
