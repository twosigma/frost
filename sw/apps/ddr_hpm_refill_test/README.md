# Cache refill HPM program

Run `./scripts/frost.py cocotb ddr_hpm_refill_test` from the repository root.
The registered configuration keeps the driver and stack in BRAM and executes
the measured bodies and accesses their data in cached DDR. Whole-program DDR
relocation is excluded from the program registry's DDR selection: instruction
fetches from the driver would enter the data measurement windows.

The program checks selectors 19, 20 and 21 on counters 3, 6 and 5:

- Cold 8-line and 24-line instruction bodies have bounded allocation counts.
  The entry line and its next-line partner can be requested before the opening
  CSR sample. Return stubs are primed, and the closing sample follows execution
  and event draining. The allowed windows are therefore 6–8 and 22–24.
- Four alternating pairs check that the long body contributes 14–18 more
  refills than the short body: their line-count difference is 16, and their
  independent zero-to-two leading requests can differ by at most two. Each
  body has a separately measured warm second pass, whose count must be zero.
- Both code pages are resident in L2 before measurement. L1D permission misses,
  L2 demand refills and L2 prefetch refills must remain zero in the instruction
  windows. A data-side event cannot substitute for the instruction event.
- Scattered loads into 32 untouched pages require exactly 32 demand reads and
  no prefetch reads; a warm pass requires no demand reads. A stream over two
  untouched pages requires exactly 128 demand-plus-prefetch reads and uses
  prefetching. MINH, counter wrap, OF, LCOFIP and scountovf are also checked.

These are workload checks. Exact request-to-pulse accounting is checked on
every clock by the cache/home benches and by the home refill formal properties.
Instruction-body size alone does not define an exact CSR measurement window:
the event includes speculative and next-line allocation requests.

For a random-start run, set `FROST_RANDOM_START_SEED=1` before the command.
`FROST_DDR_MODEL_SEED` independently selects memory-response timing. Each
registered run executes the program twice across reset. Reset invalidates the
cache tags, so both executions start with cold data windows even if the cached
run counter has not reached backing memory before reset.
