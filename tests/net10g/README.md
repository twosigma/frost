# Standalone Ethernet verification

These benches compile only the new `hw/rtl/net10g` modules and local harnesses.
They do not depend on the CPU, software apps, the main test registry, or a
GTY simulation model. See [the RTL README](../../hw/rtl/net10g/README.md) for
interfaces, rates, packet behavior, and implementation limits.

[The Ethernet MAC/PCS job](../../.github/workflows/ci.yml) runs every standalone
target and the portable synthesis check on pull requests targeting `main`
and pushes to `main`. It reuses the existing workflow's `build-docker` image
artifact, loaded as `frost-dev:latest`, then invokes the commands shown below
through `scripts/frost.py --image frost-dev:latest`. Submodule
initialization is disabled because these checks do not need CPU/software
dependencies. The CPU jobs and test registry remain unchanged.

The `net10g-results` artifact retains simulation output, per-target XML
results, and synthesis logs/source hashes/summary for seven days, including
diagnostics from failed runs. A failed runner remains a failed CI step even
though its output is also captured with `tee`.

Run **through frost**, from the repository root:

```bash
./scripts/frost.py run python3 tests/net10g/run.py all
# Or select independent targets:
./scripts/frost.py run python3 tests/net10g/run.py codec scrambler
./scripts/frost.py run python3 tests/net10g/run.py mac_tx mac_rx integration
```

`run.py` refuses host-native execution, runs `make clean` for each target
before building, propagates subprocess failures, and checks that the XML
contains tests without failures/errors. The wrapper runs as the invoking
UID/GID. Build products and `results.xml` live in `sim_build/<target>/`, so
different targets can run concurrently. Do not run the same target twice
concurrently. The tests use fixed random seeds.

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
| `mac_rx` | Independent XGMII source and zlib FCS; both start lanes; malformed frames; stalls/overflow; data/descriptor wraparound and rollback; mixed sizes |
| `integration` | Independent raw-bitstream peers in both directions; AXIS stalls from startup; every receive bit phase; invalid termination lookahead; CRC rejection; PMA loss midframe and relock |

Integration tests use distinct clock phases but equal nominal periods; they
do not claim a metastability or board clocking proof. Each packet interface
belongs to its corresponding TX or RX domain. The only internal crossing is
the fault-status synchronizer. A future CPU integration needs packet CDC.

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

The image's Yosys 0.64 frontend does not accept the required SystemVerilog
package constructs directly, so the image installs **sv2v v0.0.13** as the
conversion frontend. This standalone script uses that binary when its
version matches the pin, so the CI step needs no network access. An image
predating the sv2v layer falls back to the script's own pinned download: it
fetches the upstream Linux archive, verifies the SHA256 pinned in the
script, and extracts only into `sim_build/synthesis`; neither the host nor
the image is modified. Later runs can reuse the verified archive.

The script snapshots and hashes the RTL, converts it, runs coarse synthesis
with memories retained and FSM recoding disabled, and rejects latches,
blackboxes, structural errors and out-of-range reads. It bounds subprocess
time/memory and retains complete logs, converted Verilog, a JSON netlist and
`summary.json` under `sim_build/synthesis/`.

At the default 9216-byte frame limit, the checked hierarchy retains five
memories containing **423,488 bits**. This is a portable structural check;
it does not establish RAM primitive mapping, 161.1328125 MHz timing, GTY
operation, or hardware interoperability. Any future Vivado checks must run
natively and use a separate output directory from the active CPU build.
