# Branch-predictor geometry sweeps

FROST exposes the direct-mapped BTB geometry as a top-level parameter:

`BP_BTB_INDEX_BITS`

The number of BTB entries is `2**BP_BTB_INDEX_BITS`. The default is 8 (256 entries).
The decoupled bimodal direction predictor remains 1024 entries because its index width is part of the existing pipeline metadata contract (`riscv_pkg::BpDirIdxBits`).

## Recommended sweep

Use the supplied helper to enumerate reproducible configurations:

```bash
python tools/bp_sweep.py --sizes 128 256 512 1024
```

For each size, the helper reports the corresponding `BP_BTB_INDEX_BITS` and an Icarus-style parameter override:

```text
128  -> BP_BTB_INDEX_BITS=7
256  -> BP_BTB_INDEX_BITS=8
512  -> BP_BTB_INDEX_BITS=9
1024 -> BP_BTB_INDEX_BITS=10
```

The helper can also wrap a simulator/build command. Use `{bp_bits}` in the command where the integer parameter value should be substituted:

```bash
python tools/bp_sweep.py --sizes 128 256 512 \
  --command "iverilog -Pcpu_and_mem.BP_BTB_INDEX_BITS={bp_bits} ..."
```

### What to measure

For each configuration collect at least:

- committed instructions / cycle (IPC)
- `IF_SLOT2_PRED_TAKEN`
- branch-prediction fence/disable counters
- total flush/recovery events
- FPGA LUTRAM/BRAM utilization and timing slack

Do not assume the largest BTB wins: larger direct-mapped tables reduce capacity misses but consume more memory and can increase conflict behavior elsewhere in the implementation.
