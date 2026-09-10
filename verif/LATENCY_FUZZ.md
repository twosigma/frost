# Deterministic latency fuzzing

FROST already has simulation-only latency perturbation in the behavioral DDR and fetch path. The timing-stress runner makes those knobs reproducible as a single test configuration.

## Profiles

| Profile | DDR latency | DDR jitter | Reorder | Fetch fuzz |
|---|---:|---:|---:|---:|
| `baseline` | 30 | 0 | 0 | 0 |
| `ddr-jitter` | 30 | 19 | 0 | 0 |
| `ddr-reorder` | 30 | 19 | 1 | 0 |
| `fetch-jitter` | 30 | 19 | 1 | 7 |
| `max-stress` | 7 | 31 | 1 | 15 |

Run a reproducible stress case from the repository root:

```bash
python tools/latency_fuzz.py amo_irq_torture --profile max-stress --seed 0x1234 --count 4
```

The runner records `build/latency-fuzz.json`. If a run fails, the seed and profile are printed as a replay command. The DDR model now has an explicit `DDR_MODEL_JITTER_SEED` parameter, so two runs with the same simulator parameters and seed use the same memory-latency sequence.

`--random-seed` still controls cocotb's software/test randomness separately. This separation is intentional: the test workload RNG and the hardware timing RNG should be independently reproducible.
