# TestRIG

[TestRIG](https://github.com/CTSRD-CHERI/TestRIG) compares FROST with the
[Sail RISC-V model](https://github.com/riscv/sail-riscv), the executable
formal specification, one instruction at a time. Its verification engine,
QuickCheckVEngine, generates random instruction sequences from templates,
sends each sequence to two implementations over the RVFI-DII protocol, and
compares the trace of every retired instruction: the destination register
and its value, the next PC, whether it trapped, the privilege mode, and for a
store its address, byte mask, and data. On a mismatch it shrinks the sequence
to a short counterexample.

Directed tests check the behavior their authors chose, and the torture suite
compares end states over a fixed corpus. TestRIG instead generates new
sequences on every run, reaches encodings and orderings that compilers and
directed tests do not produce, and judges each instruction against a
reference that FROST's authors did not write. It found the four
conformance bugs fixed for
[issue #58](https://github.com/twosigma/frost/issues/58).

| Path | Contents |
|------|----------|
| [`tests/test_testrig.py`](../../tests/test_testrig.py) | Runner: starts Sail, the simulation, and the engine |
| [`verif/cocotb_tests/test_rvfi_dii.py`](../cocotb_tests/test_rvfi_dii.py) | RVFI-DII server for the simulated SoC |
| [`hw/sim/frost_rvfi_dii.sv`](../../hw/sim/frost_rvfi_dii.sv) | Simulation-only harness: instruction injection, retirement records, device RAM |
| [`rvfi_dii.py`](rvfi_dii.py) | RVFI-DII packet formats |
| [`preamble.py`](preamble.py) | Instructions FROST runs after each reset, before a test |
| [`atomics.py`](atomics.py) | Random A-extension tests (see [The A extension](#the-a-extension)) |
| [`sail_frost.json`](sail_frost.json) | Sail settings that describe FROST |
| [`traces/`](traces/) | Saved counterexamples, replayed in CI |

## Running

The frost image provides `sail_riscv_sim` and `QCVEngine`. From the
repository root:

```bash
./scripts/frost.py run make -C tests clean
./scripts/frost.py run python3 tests/test_testrig.py                       # every default template, 50 tests each
./scripts/frost.py run python3 tests/test_testrig.py --include '^(mem|pte)$' --tests 500
./scripts/frost.py run python3 tests/test_testrig.py --trace tests/testrig_failures/failure-<time>.S
./scripts/frost.py run python3 tests/test_testrig.py --trace-dir verif/testrig/traces
./scripts/frost.py run python3 tests/test_testrig.py --atomics 200         # A-extension tests
```

The first run builds the `rvfi_dii` simulation, and later runs reuse it
until `tests/` is cleaned. Counterexamples go to
`tests/testrig_failures/`, and the simulation log, Sail's log, and the
engine's instruction coverage table go to `tests/testrig_logs/`. A
counterexample file lists the sequence as `.4byte` words with both traces in
comments; `--trace` replays it, and editing the words is the quickest way to
narrow a bug down. `FROST_RVFI_DII_DEBUG=1` logs every record the harness
collects, preamble included.

| Option | Default | Meaning |
|--------|---------|---------|
| `--arch` | `rv64imfdcs_zicsr_zifencei` | Architecture the templates target |
| `--tests` | 50 | Tests per template |
| `--atomics` | 0 | Replay this many random A-extension tests instead of the templates |
| `--seed` | random | Seed for `--atomics`; the runner prints the one it used |
| `--test-length` | 200 | Maximum instructions per test |
| `--include`, `--exclude` | see the runner | Template name regexes |
| `--csr-include` | see the runner | CSRs the templates may access |
| `--continue-on-fail` | off | Keep testing after a failure |
| `--no-shrink` | off | Report failures unshrunk |

## Instruction injection

TestRIG supplies instructions by position, not by address: the k-th
instruction to retire or trap must execute the k-th word of the sequence, at
whatever PC the architecture reaches. A branch to itself followed by an add
puts the branch and the add at the same address, one after the other.

The `rvfi_dii` build (`FROST_RVFI_DII`, defined only by its entry in
[`tests/test_run_cocotb.py`](../../tests/test_run_cocotb.py)) leaves the CPU
unchanged except where noted below. `frost_rvfi_dii.sv` replaces the low-BRAM
instruction memory, and every fetch goes through the low-BRAM presenter. It
answers each fetch window from a layout of the sequence: word r at address R,
the next word right after it, and so on, with C.NOP outside the layout. The
layout changes on the clock edge where the fetch PC loads a redirect from
`pc_controller`:

| Redirect | New layout starts at | With word |
|----------|----------------------|-----------|
| Reset | 0 | 0 |
| Trap, xRET, FENCE-class flush, commit-time misprediction recovery | the redirect target | the number of words already retired or trapped |
| Early misprediction recovery | the redirect target | one past the branch: retired count plus the branch's distance from the ROB head |
| PD redirect | the redirect target | one past the PD branch, found by its PC in the current layout |

Branch prediction is off in this build, so fetch stays on the sequential
path between redirects and every instruction in the front end belongs to the
current layout. A window is computed from the layout current when it is
presented, so a window presented after a redirect belongs to the new path.

Each retirement, xRET, or exception produces one record: PC, next PC, trap,
privilege, the integer destination and its value (FP destinations are not
reported, as in Sail), and for a store or AMO its physical address, size
mask, and data. Store data comes from the store queue's in-order memory
writes; a CSR's read value from the delayed CSR write-back. The record's
instruction word is the stream word the event consumed, not one read back
from the core, so an injection error shows up in the other fields. The
harness also checks its own assumptions and reports a violation as a
simulation failure.

The build differs from the production core in these ways, all for
simulation only:

- instruction access faults are dropped and page faults kept, because
  injected instructions need no memory and Sail checks only translation for
  them; this also drops the access fault of an instruction page-table walk
  that reads outside DDR, which the default templates never produce;
- misaligned loads and stores always trap; production FROST traps them only
  once `mtvec` has a nonzero base;
- WFI completes at once, and no interrupt is ever taken;
- loads and stores to the device quadrant read and write a RAM instead of the
  devices;
- the DDR model, the low BRAM data copy, and the device RAM clear on every
  reset.

Every test starts with a reset and the [preamble](preamble.py), which zeroes
the registers, sets the CSRs whose reset values differ from Sail's, and lands
on 0x8000_0000 with `minstret` at zero. Its records are dropped.

## Matching Sail to FROST

`sail_frost.json` overrides Sail's default configuration where FROST makes a
different implementation choice:

| Setting | FROST |
|---------|-------|
| Extensions | RV64IMAFDC, B, Zicond, Zbkb, Zihintpause, Zicntr, S, U, Sv39, Svade, Sstc; `misa` read-only |
| Memory regions | The PMA map: low BRAM, the device pages, the rest of the device quadrant (stores only), and 1 GiB of DDR, the only region page-table walks read |
| Physical addresses | 64 bits wide, so an untranslated access beyond the memory map faults with its full address in `mtval` |
| Misaligned accesses | Address-misaligned trap, after the PMA check |
| `mtval` | 0 for illegal instructions |
| `mstatus.FS` | Dirty when an FP instruction raises a flag, even one already set |
| `mstatus.VS` | Read-only zero: FROST has no V extension |
| HPM counters | `mhpmcounter3..31` and `mhpmevent3..31` read zero; no `hpmcounter3..31` |
| Counter enables | `mcounteren`, `scounteren`: CY, TM, and IR; `mcountinhibit`: CY and IR |
| Delegation | `medeleg` mask 0xB3FF, `mideleg` mask 0x222 |
| PMP | None |
| LR/SC | Doubleword reservation set, cancelled by a store or AMO from the hart to it (FROST also cancels it on a trap; see [The A extension](#the-a-extension)) |
| WFI | Completes at once |
| Sail's CLINT | At 0x7_FFFF_0000, outside FROST's map; Sail requires one for Zicntr |

## What the comparison leaves out

The engine's default comparison skips source register values and load data;
a load is still checked through its destination register. The runner keeps
the templates and CSRs where FROST and Sail differ by design, or where the
result depends on timing, out of the default run:

| Left out | Why |
|----------|-----|
| `cycle`, `time`, `mcycle` | FROST counts clock cycles; Sail counts instructions |
| `mie`, `mip`, `sie`, `sip` | Sail takes an interrupt in place of an instruction, which the trace cannot express |
| `stimecmp` | The Sstc timer compare depends on time |
| `mtvec`, `stvec` | Reserved MODE values: FROST keeps the low bit, Sail keeps the old MODE |
| `mcause`, `scause` | The cause code is WLRL: FROST keeps any value written, Sail keeps the old value when the code is one it does not support |
| Unnamed CSR addresses | Include FROST's custom profiling CSRs |
| The `atomic` and `memAmo` templates | They put traps between LR and SC (see [The A extension](#the-a-extension)); `--atomics` covers the A extension instead |
| `unstructured` template | Random 32-bit words reach custom CSRs and other implementation-defined encodings |
| CHERI and HPM event templates | Not applicable |

## Differences found

- `menvcfg.FIOM` and `senvcfg.FIOM` were read-only zero. The privileged
  specification allows that only without S-mode or with `satp.MODE` fixed at
  Bare, and Sail rejects a configuration that combines it with Sv39. Both are
  now writable. FIOM changes nothing else in FROST: its FENCE ignores the
  predecessor and successor bits, so it already treats I/O like memory.
- FROST kept an LR reservation across its own AMO writes to the reserved
  doubleword, which Sail's setting cancels, and cancelled it when a branch
  recovered at commit, such as a JAL or JALR between LR and SC. TestRIG's
  build disables branch prediction, so each such jump recovered at commit
  and its SC failed. There, an LR/SC retry loop with a forward JAL between LR
  and SC, a loop the specification's eventual-success rule covers, could
  never succeed. An AMO write to the reserved doubleword now cancels the
  reservation, and commit-time recovery keeps it
  ([`lrsc_amo.S`](traces/lrsc_amo.S), [`lrsc_jump.S`](traces/lrsc_jump.S)).

## The A extension

FROST and Sail cancel an LR reservation on an SC, on the hart's own store or
AMO to the reserved doubleword, and on reset. FROST also cancels it on a
trap, xRET, or FENCE-class flush (`fence.i`, `sfence.vma`, or a translation
CSR write), and Sail keeps it. The specification allows both, but an SC after
such an event succeeds on Sail and fails on FROST. QuickCheckVEngine's atomic
templates put traps and fences between LR and SC, so the default run leaves
them out, and `--atomics N` replays N tests from
[`atomics.py`](atomics.py) instead.

Each test mixes LR, SC, and AMOs of both widths and every ordering bit with
loads, stores, integer operations, branches, jumps, fences, `ecall`, and
accesses that fault: misaligned ones and ones to device memory, to the
store-only part of the device quadrant, and outside the memory map. Between
an LR and the SC that closes it go only operations that cannot trap or flush:
integer operations, branches, JAL and JALR, FENCE, another LR, and loads,
stores, and AMOs to valid aligned addresses, some to the reserved doubleword.
The SC goes to the same doubleword or another. An LR outside such a window
always faults, so no reservation is open where a trap can happen. Base
registers hold fixed addresses in DDR, low BRAM, the device quadrant, and
unmapped space, and only their setup writes them. Each window and each setup
is a `.noshrink` strand, which QuickCheckVEngine's shrinking leaves whole, so
a shrunk counterexample follows the same rules. The memory permissions come
from `sail_frost.json`.

The tests come from a seed: `--seed` repeats a run, and without it the runner
picks one and prints it. They are written to `tests/testrig_logs/atomics/`.

## Saved counterexamples

`traces/` holds sequences that once exposed a bug, one per file. CI replays
all of them before its random run.

| Trace | Checks |
|-------|--------|
| [`envcfg_fiom.S`](traces/envcfg_fiom.S) | `menvcfg.FIOM` and `senvcfg.FIOM` are writable |
| [`fence_r0.S`](traces/fence_r0.S) | `fence r,0` retires (it was decoded as PAUSE and hung the core) |
| [`hpm_counters.S`](traces/hpm_counters.S) | `mhpmcounter3..31` and `mhpmevent3..31` read zero |
| [`instret_nops.S`](traces/instret_nops.S) | NOP and C.NOP count in `minstret` |
| [`lrsc_amo.S`](traces/lrsc_amo.S) | An AMO to the reserved doubleword cancels the reservation; one to the next doubleword does not |
| [`lrsc_jump.S`](traces/lrsc_jump.S) | A JAL, JALR, or taken branch between LR and SC keeps the reservation |
| [`pte_nonleaf_dau.S`](traces/pte_nonleaf_dau.S) | A non-leaf PTE with D, A, or U set raises a page fault |
