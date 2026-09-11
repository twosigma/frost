# X3 NIC hardware validation — 2026-09-10

The 150 MHz CPU / 40 MHz internal-loopback MAC build passed all **42
self-contained hardware regression stages**, as reported by the board operator.
The final implementation reports setup WNS **+0.184 ns**, hold WHS
**+0.010 ns**, and no setup, hold or pulse-width violations. This validates
the divided-clock implementation; 300 MHz routed timing closure is ongoing.

The run includes NIC loopback, coherent DMA torture, CPU instruction and
privilege tests, DDR execution and atomics, interrupts, address translation,
floating point, FreeRTOS, all nine CoreMark-PRO workloads, and Linux boot,
stress and login. Linux reported nonzero cycle and instruction counters.
CoreMark scored 493.17 and CoreMark-PRO 72.57 with the 150 MHz override;
the rated-clock benchmark gates were intentionally skipped by the runner.

NIC loopback exercises bring-up, eight frame cases (including a 9,000-byte
frame), interrupts, filtering and reset. The bitstream uses internal digital
loopback and instantiates no GTY channel/common primitives. It therefore
does not validate optics, cables or an external Ethernet link. `nic_echo`,
which requires external receive traffic, was excluded from this run.

## Retained baseline

The complete build directory and available software artifacts are archived at:

```text
/home/adam-bagley/fable_frost_backups/slice1_150mhz_hardware_pass_20260910_234243-0400
```

The archive contains the bitstream, checkpoints, reports, logs, BRAM images,
available application load images and ELF files, a tracked-source snapshot,
submodule revisions, the user-supplied regression summary and SHA-256
manifests. All 1,035 archived files were checksum-verified. Shared
CoreMark-PRO build outputs retain the last workload, rather than nine
separate binaries. Archiving did not perform another board run or readback.

The bitstream was built at `21d3fa99`; the source snapshot is at `396a4fc3`.
The intervening commit fixes host loader registration and its tests/docs,
with identical hardware RTL. Bitstream SHA-256:

```text
6f2d5aa1668fc578609148a1e6fe5a7f93bff9b483464fba7c3f9aefdcf34de6
```

To restore this specific build from a source checkout:

```bash
./fpga/program_bitstream/program_bitstream.py x3 --bitstream /home/adam-bagley/fable_frost_backups/slice1_150mhz_hardware_pass_20260910_234243-0400/work/x3_frost.bit
FROST_CPU_CLK_HZ=150000000 ./fpga/hw_regression.py --board x3 nic_loopback
```

Keep the 150 MHz override for all software loaded into this bitstream.
Do not resume a 300 MHz implementation from its divided-clock checkpoints.

The earlier 300 MHz synthesis/optimization/placement checkpoints and reports
are independently preserved at:

```text
/home/adam-bagley/fable_frost_backups/slice1_300mhz_post_place_20260910_213710-0400
```

That build's selected `ExtraPostPlacementOpt_u0.500` placement had real-constraint
WNS −0.387 ns (−0.887 ns with the added optimization uncertainty), and its
quick-route probe had WNS −0.719 ns with a congestion warning. These are
intermediate implementation results, not the timing of the passing bitstream.
