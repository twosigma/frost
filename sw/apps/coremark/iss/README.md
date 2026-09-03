# CoreMark instruction counting under Spike

A measurement tool, not part of any build, test, or board flow. It runs the
unmodified CoreMark sources from `../coremark/` through Spike at **either XLEN**
and reports how many instructions the timed region retires.

## Why it exists

The core is RV64-only — the rv32 lane was retired in `c0be5bc` — so a question
like "how much of CoreMark's lp64 cost is the ABI, and how much is codegen we
left on the table?" cannot be answered on the RTL any more. Instruction counts,
unlike cycles, depend only on the toolchain, so they *can* still be measured
across both ABIs. That is all this harness does.

It answers the "how many instructions" half. The "how fast does the machine
retire them" half still needs `./scripts/frost.py cocotb coremark`, which is
the only thing that produces a CoreMark score.

## Usage

Needs the pinned toolchain and Spike, so run it inside the image:

```bash
./scripts/frost.py run sw/apps/coremark/iss/count_instructions.py --matrix
./scripts/frost.py run sw/apps/coremark/iss/count_instructions.py --xlen 64
./scripts/frost.py run sw/apps/coremark/iss/count_instructions.py --xlen 32 \
    -- --param max-inline-insns-auto=200
```

`--matrix` reproduces the ablation quoted in `../Makefile`:

```
flags                                   rv32/ilp32d   rv64/lp64d    lp64
stock                                       254,726      284,492   11.7%
inline                                      227,779      257,229   12.9%
inline_sa                                   221,613      251,220   13.4%
full                                        221,578      251,089   13.3%
```

## How it works, and what it is not

`core_portme.c` here replaces the app's port layer: no MMIO, no timer.
`start_time()` and `stop_time()` each execute one `csrr x0, cycle`, and nothing
else in the program reads that CSR, so `count_instructions.py` slices Spike's
`--log-commits` trace to exactly the timed region. `uart.h` is a shim that lets
the app's own `../core_portme.h` compile unchanged (the real MMIO header is
never on the include path), and `stub.c` supplies the few libc entry points GCC
can synthesize calls to. `crt0_spike.S` enables `mstatus.FS` — Spike resets it
to Off, and CoreMark's prologue stores an FP register.

**Calibration.** With the flags FROST ships, this harness lands within 0.4% of
the cocotb timed-region `instret` at both XLENs, and the offset has the same
sign and magnitude in both lanes (the difference is port code outside the timed
region). Absolute numbers are therefore approximate; ratios between
configurations are not.

**It cannot tell you about IPC, cycles, or a score.** Spike is functional only.
Fetch-window behaviour, branch prediction, cache effects and the 2-wide bundler
— which is where most of FROST's CoreMark headroom turned out to be — are
invisible here.
