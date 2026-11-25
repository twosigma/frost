# TestRIG

[TestRIG](https://github.com/CTSRD-CHERI/TestRIG) compares FROST with the
[Sail RISC-V model](https://github.com/riscv/sail-riscv), the executable
formal specification, one instruction at a time. Its verification engine,
QuickCheckVEngine, generates random instruction sequences from templates,
sends each sequence to two implementations over the RVFI-DII protocol, and
compares the trace of every retired instruction: the destination register
and its value, the next PC, whether it trapped, the privilege mode, and for a
store its address, byte mask, and data. By default it shrinks mismatches
to short counterexamples.

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
| [`hw/sim/frost_rvfi_platform.sv`](../../hw/sim/frost_rvfi_platform.sv) | Simulation platform with a fixed-latency instruction injection interface and coherent caches |
| [`rvfi_dii.py`](rvfi_dii.py) | RVFI-DII packet formats |
| [`preamble.py`](preamble.py) | Instructions FROST runs after each reset, before a test |
| [`atomics.py`](atomics.py) | Random A-extension tests (see [The A extension](#the-a-extension)) |
| [`fp_ext.py`](fp_ext.py) | Random scalar FP (F, D, Zfhmin, and Zfa) tests (see [Scalar floating point and Zcb](#scalar-floating-point-and-zcb)) |
| [`compressed_mops.py`](compressed_mops.py) | Random Zcb, Zcmop, Zimop, and Zihintntl tests (see [Scalar floating point and Zcb](#scalar-floating-point-and-zcb)) |
| [`mmu.py`](mmu.py) | Random Sv39 MMU, ASID, SFENCE.VMA, and Sstvala tests (see [Sv39 MMU, cache-block operations, and Sstvala](#sv39-mmu-cache-block-operations-and-sstvala)) |
| [`cmo.py`](cmo.py) | Random Zicbom, Zicboz, Zicbop, Zawrs, device-window, and Sstvala tests (see [Sv39 MMU, cache-block operations, and Sstvala](#sv39-mmu-cache-block-operations-and-sstvala)) |
| [`misaligned.py`](misaligned.py) | Directed misaligned load and store traces across widths, offsets, boundaries, and second-page faults (see [Misaligned loads and stores](#misaligned-loads-and-stores)) |
| [`vector.py`](vector.py) | Random vector-instruction tests (see [The vector extension](#the-vector-extension)) |
| [`vector_segments.py`](vector_segments.py) | Seeded deterministic generator for five segment memory matrix traces covering all 252 base-V segment encodings (`--vector-segments`) |
| [`sail_frost.json`](sail_frost.json) | Sail settings that describe FROST |
| `sail_frost_vlen128.json`, `sail_frost_vlen256.json`, `sail_frost_vlen512.json` | Overlays on `sail_frost.json` that turn on the vector unit (`V`, `Zvfh`, `Zvfhmin`) at one vector length; they differ only in `V.vlen_exp` |
| [`traces/`](traces/) | Saved counterexamples, replayed in CI |
| [`sscofpmf/controls.S`](sscofpmf/controls.S) | Deterministic Sscofpmf delegation, controls and implemented HPM aliases, replayed with `--sscofpmf` in CI |

Random Zcb, Zcmop, Zimop and Zihintntl traces use `--zcb 50` ([`compressed_mops.py`](compressed_mops.py)): full-width operands, Zcb loads and stores on two
cached-DDR bases, every C.MOP.n, MOP.R.n and MOP.RR.n, the NTL hints, integer traffic, and reserved
neighbours that trap. A saved trace, `traces/zcb_zimop_zcmop_ntl.S`, runs every new encoding once.

Scalar cryptography traces use `--crypto 50`. The generator supplies full-width
operands, source and destination aliases, dependencies, integer multiply and
divide traffic, taken branches, and environment calls. `--seed` makes these
traces reproducible. The Sail configuration enables Zbc and Zbkc.

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
./scripts/frost.py run python3 tests/test_testrig.py --mmu 40              # Sv39 MMU, ASID, and SFENCE.VMA tests
./scripts/frost.py run python3 tests/test_testrig.py --cmo 80              # CMO, prefetch, Zawrs, and Sstvala tests
./scripts/frost.py run python3 tests/test_testrig.py --fp-ext 60 --test-length 250  # Scalar FP (F, D, Zfhmin, and Zfa) tests
./scripts/frost.py run python3 tests/test_testrig.py --zcb 50              # Zcb, Zcmop, Zimop, and Zihintntl tests
./scripts/frost.py run python3 tests/test_testrig.py --wfi                 # Directed WFI waits, wakes, and traps
./scripts/frost.py run python3 tests/test_testrig.py --misaligned          # Directed misaligned loads, stores, and second-page faults
./scripts/frost.py run python3 tests/test_testrig.py --sscofpmf           # deterministic counter controls
./scripts/frost.py run python3 tests/test_testrig.py --vector 12 \
  --vector-source-widths --vector-directed --seed 42 --vlen 128
./scripts/frost.py run python3 tests/test_testrig.py --ddr-capacity-log2-bytes 37 --trace-dir verif/testrig/traces
```

The first run builds the `rvfi_dii` simulation, and later runs reuse it
until `tests/` is cleaned. Counterexamples go to
`tests/testrig_failures/`, and the simulation log, Sail's log, and the
engine's output (`engine.log`) and instruction coverage table go to
`tests/testrig_logs/`. A
generated Sail configuration in that log directory records the selected DDR
capacity. The runner gives the same setting to FROST's RTL and enables the
full-width sparse DDR simulation model; the default is 1 GiB. This is a
simulation model, not a physical DDR-controller test. A
counterexample file lists the sequence as `.4byte` words with both traces in
comments; `--trace` replays it, and editing the words is the quickest way to
narrow a bug down. `FROST_RVFI_DII_DEBUG=1` logs every record the harness
collects, preamble included.

A successful run ends with `TestRIG PASS: compared <traces> traces and
<instructions> instructions; expected at least <traces> traces and
<instructions> instructions; logs in <directory>`. The counts come from
the instruction requests and both implementations' RVFI replies. Version
negotiation, halt tokens, and FROST's reset preamble are excluded from the
instruction count. QuickCheck's completed size-zero cases count as traces;
the session must compare at least one instruction.
Every non-halt execution packet counts, including replies with the RVFI
`valid` byte clear. The transport carries the execution record for comparison;
that byte is not a filter for packet counts.

Empty runs fail with a nonzero exit status and a `TestRIG FAIL` line stating
what was expected and what was found. Replay requires an existing trace file,
or a directory containing `.S` files, including subdirectories. Every replay
file must contain at least one `.4byte` or `.2byte` instruction. All requested
traces and instructions must be compared, and each implementation must
return every injected instruction. Generated runs require the requested
number of tests for each selected template; a filter or architecture that
selects no runnable templates fails. Explicit test counts and instruction
limits must be positive, including counts for every generator option.

Replay paths are relative to the command's working directory. The examples
above run from the repository root. For a direct invocation from `tests/`,
use `python3 test_testrig.py --trace-dir ../verif/testrig/traces`.

The runner selects the two loopback TCP ports while holding both probe
sockets open, then releases them for Sail and FROST to bind. This prevents
the OS from assigning the same ephemeral port to both implementations.

The NIC is instantiated with both MAC clocks and their clock-OK inputs
held low (`nic_mac_clocks=False` in the `rvfi_dii` registry entry).
Device loads and stores use the harness RAM. The NIC and DMA engine
AXI4-Lite request channels are tied low. Accesses to the harness RAM in the
NIC's window are allowed.
`FROST_NIC_MAC_CLOCKS=1` starts the MAC clocks for a comparison run.
The fixture uses `i_clk` for the CPU and SoC and requires
`ASYNC_CPU_CLOCK=0`. The independent CPU boundary belongs to the production
`platform_top` integration.

CI runs four scalar TestRIG jobs in parallel. Each draws its own 100 sequences per
template, 200 A-extension tests, 40 Sv39 MMU tests, 80 CMO and Sstvala
tests, 60 scalar FP tests (`--fp-ext 60 --test-length 250`), and 50 Zcb, Zcmop,
Zimop, and Zihintntl tests (`--zcb 50 --test-length 200`). Shard 1 also replays
`verif/testrig/traces` and runs `--crypto 50`, `--svinval 50`, `--sscofpmf`, and
`--wfi`; shard 3 runs the startup assertion controls
(`tests/random_start_sweep.py --require-controls`). Each job simulates
the SoC with its own DDR model timing (`FROST_DDR_MODEL_SEED`, see
[tests/README.md](../../tests/README.md#environment-and-output)).

| Option | Default | Meaning |
|--------|---------|---------|
| `--arch` | `rv64imfdcs_zicsr_zifencei` | Architecture the templates target (`rv64imafdcs_zicsr_zifencei` with `--atomics`, `--mmu` or `--cmo`) |
| `--tests` | 50 | Tests per template |
| `--ddr-capacity-log2-bytes` | 30 (1 GiB) | Set the DDR aperture for both FROST and Sail; accepted values 30–37 (1–128 GiB) |
| `--atomics` | off | Replay this many random A-extension tests instead of the templates |
| `--mmu` | off | Replay this many random Sv39 MMU, ASID, SFENCE.VMA, and Sstvala tests instead of the templates |
| `--cmo` | off | Replay this many random Zicbom, Zicboz, Zicbop, Zawrs, device-window, and Sstvala tests instead of the templates |
| `--wfi` | off | Replay directed WFI traces with a bounded DUT wait and Sail reply normalisation |
| `--crypto` | off | Replay this many scalar cryptography tests |
| `--zcb` | off | Replay this many Zcb, Zcmop, Zimop, and Zihintntl tests |
| `--fp-ext` | off | Replay this many scalar FP (F, D, Zfhmin, and Zfa) tests |
| `--svinval` | off | Replay this many random Svinval tests (`verif/testrig/svinval.py`) instead of the templates |
| `--sscofpmf` | off | Replay the deterministic counter-control trace (`verif/testrig/sscofpmf/controls.S`); `--trace` overrides the trace path |
| `--vector` | off | Replay this many random vector-instruction tests on a core built with the vector unit (see [The vector extension](#the-vector-extension)) |
| `--vector-length` | 20 | Operation groups per generated vector trace |
| `--vector-source-widths` | off | Add the directed integer, FP and memory source-width traces to `--vector` |
| `--vector-directed` | off | Add the directed vector CSR, scalar-result, fractional LMUL, FP and cached DDR memory traces to `--vector` |
| `--vector-segments` | off | Replay the five seeded generated segment traces from `verif/testrig/vector_segments.py` plus `verif/testrig/vector_segment.S` (sets `--vlen` to 128 when omitted) |
| `--vector-ext` | off | Replay the directed RVA23 vector extension traces (sets `--vlen` to 128 when omitted) |
| `--vlen` | 128 with `--vector` / `--vector-segments` | Build FROST with the vector unit at this vector length (128, 256 or 512) and configure Sail to match; needed to replay vector traces with `--trace` or `--trace-dir` |
| `--seed` | random (fixed for `--vector-segments`) | Seed for `--atomics`, `--zcb`, `--fp-ext`, `--mmu`, `--cmo`, `--svinval`, `--crypto`, `--vector` and `--vector-segments`; the runner prints the one it used |
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
unchanged except where noted below. It selects `frost_rvfi_platform` in place
of the production `platform_top`. This fixture uses the fixed-latency
Normal memory interface; the production AXI `CACHE_NORMAL_MEMORY` policy is
not passed to it. The CPU's read-size output qualifies 32-bit APLIC reads on
the fixture's MMIO path; unused request outputs are left open.
The [CPU boundary tests](../../hw/rtl/cpu_top/README.md#verification) cover
the production AXI interface separately.

Cacheable data requests and page-table walks use the coherent hart cache and
shared home. FENCE.I drains committed stores, waits for instruction-copy
writes, and invalidates L1I. Refills obtain dirty L1D data through home probes.
Cached LR/SC and AMO operations use
the CPU's protected atomic interface. The home serves the DMA ingress and
the vector unit's hart line client through its probe and completion channels.
The line client shares the home with the coherent hart cache and uses
source 0, class 3. The home routes grants and releases by message identity.
The fixture has four-way 4 KiB L1D and L1I caches and a four-way 16 KiB L2.
Whole-SoC program jobs also exercise the production cache capacities.
The retirement timeout bounds cache service, synchronization and recovery.
`FROST_RVFI_DII_HANG_CYCLES` sets the bound, which defaults to
100,000 cycles.

`frost_rvfi_dii.sv` replaces the low-BRAM
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

Each requested retirement, xRET, or exception produces one record: PC, next
PC, trap, privilege, the integer destination and its value (FP destinations are not
reported, as in Sail), and the physical address, mask and data of writes
through the store queue and the misaligned-access engine. CSR read values arrive through delayed write-back.
The vector unit writes through the hart line client. The runner clears
Sail's memory payload for a retiring vector store. Committed vector-store
traces must assert a trap or read back and assert each stored element with
scalar loads. The instruction word records the consumed
stream word. The other fields expose injection errors. The
harness also checks its own assumptions and reports a violation as a
simulation failure.

The recorder stores the requested trace and one following event for its final
next PC. Filler retirement advances the instruction layout without consuming
record capacity. Completion waits for the requested stores and CSR read
values. The hang bound counts cycles without a requested retirement or a
store or CSR completion, including cycles that retire filler. The
`rvfi_recorder` unit bench checks delayed data, two-store retirement at the
capacity boundary, missing store completion, excessive capacity requests, and
misaligned-access engine retirements, cross-page store reporting, and
second-part faults.

The build differs from the production core in these ways, all for
simulation only:

- instruction access faults are dropped and page faults kept, because
  injected instructions need no memory and Sail checks only translation for
  them; this also drops the access fault of an instruction page-table walk
  that reads outside DDR, which the default templates never produce;
- misaligned loads and stores always enter the misaligned-access path
  regardless of `mtvec`; plain misaligned loads and stores to cached DDR
  execute in the misaligned-access engine (`MISALIGNED_HW=1`), while accesses
  to low BRAM, device RAM, and atomics raise the address-misaligned exception;
- Legal WFI completes at once with the default build. `--wfi` enables the
  ROB wait and a simulation-only wake timeout. All TestRIG modes suppress
  interrupt delivery to the trap unit.
- loads and stores to the MMIO, APLIC and IMSIC windows read and write a RAM
  instead of the devices; the PMA admits loads throughout all three windows,
  including the full 2 MiB IMSIC window, and rejects atomics and reservations;
- the secondary Ethernet and SPI outputs stay idle, with flash chip select
  inactive; `ENABLE_1G_ETH` does not instantiate board peripherals in this
  fixture;
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
| Extensions | RV64IMAFDC, B, Zfa, Zfhmin, Zcb, Zcmop, Zihintntl, Zimop, Zicond, Zbc, Zbkb, Zbkc, Zkt, Zihintpause, Zicntr, Zihpm, Zic64b, Ziccif, Zicclsm, Zicboz, Zicbom, Zicbop, Zawrs, S, U, Sv39, Svade, Svinval, Svnapot, Svpbmt, Ssnpm, Svvptc, Sstc, Sscofpmf, Sscounterenw, Sstvala, Sstvecd; `misa` read-only |
| Memory regions | The PMA map: low BRAM, MMIO, APLIC, IMSIC, and configurable DDR (1 GiB default), the only region page-table walks read |
| Physical addresses | 64 bits wide, so an untranslated access beyond the memory map faults with its full address in `mtval` |
| Misaligned accesses | Plain loads and stores to cached DDR complete in hardware (`Zicclsm` enabled in `sail_frost.json`); low BRAM, device windows, and atomics raise address-misaligned traps after translation and the PMA check |
| `mtval` | The faulting instruction's bits for illegal instructions (Sstvala) |
| `mstatus.FS` | Dirty when an FP instruction raises a flag, even one already set |
| `mstatus.VS` | Read-only zero in the scalar fixture. The vector overlays allow all four VS states |
| HPM counters | Machine counters 3..10 have storage; random and saved traces keep their selectors disabled. User aliases 3..10 mirror machine storage; aliases 11..31 read zero in M-mode and trap below M-mode |
| Counter enables | `mcounteren`, `scounteren`: CY, TM, IR and HPM3..10; `mcountinhibit`: CY, IR and HPM3..10 |
| Delegation | `medeleg` mask 0xB3FF; `mideleg` mask 0x2222 |
| PMP | None |
| LR/SC | 32-byte reservation set, cancelled by a store or AMO from the hart to it (FROST also cancels it on a trap; see [The A extension](#the-a-extension)) |
| WFI | The default configuration completes legal WFI at once. Sail treats WFI as a nop in this configuration and skips the S-mode `mstatus.TW` check. The directed `--wfi` comparison checks legal M-mode and S-mode WFI, the S-mode TW trap, and the U-mode illegal-instruction trap |
| Zawrs | `wrs.nto` and `wrs.sto` complete at once; `wrs.nto` below M with `mstatus.TW` set raises illegal-instruction. Sail 0.16's non-nop wait loop enters `Step_Waiting` in RVFI-DII mode with `pc_wdata = 0` and consumes an extra packet, so `sail_frost.json` sets `nto.is_nop` true; `zawrs_test` and `sstvala_test` cover the `mstatus.TW` traps on `wrs.nto` and `wfi` |
| Sail's CLINT | At 0x2B6D_93F1_0000, outside FROST's map at an address random sequences do not form; Sail requires one for Zicntr |

The `--sscofpmf` replay checks `mideleg`'s full WARL mask and register and
immediate read-modify-write operations, `mhpmevent3..10` OF and inhibit fields
(keeping event selectors disabled), `scountovf`, machine counter storage and
user aliases 9/10. With `Zihpm` and `Sscofpmf` enabled in `sail_frost.json`,
default random and saved-trace runs also include `mideleg`, `scountovf` and
`hpmcounter3..31` while leaving `mhpmevent3..10` out so event selectors stay
disabled. The [Sscofpmf specification](https://docs.riscv.org/reference/isa/v20260120/priv/sscofpmf.html)
assigns local counter overflow interrupt number 13 and specifies that
`mideleg` controls its delegation to S-mode versus M-mode.

Replay a saved counterexample directly with `--trace <file>` (or
`--sscofpmf --trace <file>`); `--sscofpmf` cannot be combined with
`--trace-dir`, `--misaligned`, `--atomics`, `--crypto`, `--zcb`, `--fp-ext`,
`--mmu`, `--cmo`, `--svinval`, `--vector` or `--wfi`.

## What the comparison leaves out

The engine's default comparison skips source register values and load data;
a load is still checked through its destination register. The runner keeps
the templates and CSRs where FROST and Sail differ by design, or where the
result depends on timing, out of the default run:

| Left out | Why |
|----------|-----|
| `cycle`, `time`, `mcycle` | FROST counts clock cycles; Sail counts instructions |
| `mie`, `mip`, `sie`, `sip` | Sail takes an interrupt in place of an instruction, which the trace cannot express |
| `mtvec`, `stvec` | Reserved MODE values: FROST keeps the low bit, Sail keeps the old MODE |
| `mcause`, `scause` | The cause code is WLRL: FROST keeps any value written, Sail keeps the old value when the code is one it does not support |
| `mhpmevent3..10` | Implementation-defined fixed-event WARL selectors; leaving them untouched keeps counters disabled so `mhpmcounter3..31`, `hpmcounter3..31` and `scountovf` compare directly |
| Unnamed CSR addresses | Include FROST's custom profiling CSRs |
| The `atomic` and `memAmo` templates | They put traps between LR and SC (see [The A extension](#the-a-extension)); `--atomics` covers the A extension instead |
| `unstructured` template | Random 32-bit words reach custom CSRs and other implementation-defined encodings |
| CHERI and HPM event templates | Not applicable |
| Vector stores that trap part-way | Sail emits the last performed element's store fields on a trapping partial vector store while FROST's RVFI emits none (see [The vector extension](#the-vector-extension)) |

## Directed behavior

`menvcfg.FIOM` and `senvcfg.FIOM` are writable. FENCE orders I/O and memory
regardless of the predecessor and successor bits. `menvcfg.CBZE` and
`senvcfg.CBZE` are writable, and `cbo.zero` zeroes 64-byte blocks of low BRAM
and cached DDR, the regions `sail_frost.json` marks `supports_cbo_zero`.

An AMO write cancels the reservation on its 32-byte line. A branch recovered
at commit preserves the reservation. The directed traces
[`lrsc_amo.S`](traces/lrsc_amo.S) and [`lrsc_jump.S`](traces/lrsc_jump.S)
exercise both rules.

An LR launches at the ROB head after committed stores drain. The trace
[`lrsc_older_store.S`](traces/lrsc_older_store.S) places an older store in
the other word of the reserved doubleword and checks the following SC.

## WFI

`--wfi` runs one reset-isolated trace per case in [`wfi.py`](wfi.py). Legal
WFI waits with no interrupt pending in M-mode with TW clear or set and in
S-mode with TW clear. A build-time timeout wakes those waits. The default
value of `FROST_RVFI_DII_WFI_TIMEOUT` is zero, which lets legal WFI complete
without waiting. `--wfi` builds the TestRIG simulation with a 4096-cycle
limit. With SSIP already pending, S-mode WFI completes without entering the
wait whether the corresponding `mie` bit is set or clear. With Sstc armed
and STIP initially clear, S-mode WFI enters the wait and wakes when STIP
pends. MIE and SIE stay clear. The S-mode TW trap and U-mode traps with TW
clear and set check `mcause`, `mepc`, and `mtval` in the handler.

Run `--wfi` again to reproduce a directed WFI failure. The case files and
their expected wait and wake observations are deterministic.

The Sail overlay sets `wfi_is_nop=false` and `max_time_to_wait=0`. A legal
WFI emits a wait entry and one synthetic completion. The S-mode TW trap
also uses that two-reply sequence. The Sail-side monitor folds the
completion's next PC and trap bit into the WFI reply and resends the
consumed instruction packet. Unexpected replies and a trace ending on a
waiting WFI fail the comparison. Zawrs uses the model's nop settings.
An interrupt taken by Sail from S-mode has the same `insn=0`, `trap=1`,
`intr=0` completion shape as a TW trap, so only the comparison with the
DUT detects the difference.

The engine compares the normalised WFI and the following instructions.
The DUT also records wait entry, one wake due to a pending source or the
timeout, and WFI retirement at or after wake. The check requires that no
younger instruction retire before WFI wakes and retires. `mip` and `sip`
readbacks, the wait length, the timer's exact expiry, wake from M-level
interrupt lines, interrupt delivery on wake, and the debug and single-step
wake paths are outside this comparison. SEIP and local counter-overflow
sources have no directed WFI cases.

## The A extension

FROST and Sail cancel an LR reservation on an SC, on the hart's own store or
AMO to the reserved 32-byte line, and on reset. FROST also cancels it on a
trap, xRET, or FENCE-class flush (`fence.i`, `sfence.vma`, or a translation
CSR write), and Sail keeps it. The specification allows both, but an SC after
such an event succeeds on Sail and fails on FROST. QuickCheckVEngine's atomic
templates put traps and fences between LR and SC, so the default run leaves
them out, and `--atomics N` replays N tests from
[`atomics.py`](atomics.py) instead.

Each test mixes LR, SC, and AMOs of both widths and every ordering bit with
loads, stores, integer operations, branches, jumps, fences, `ecall`, and
accesses that fault: misaligned ones and ones to device memory, and to unmapped
addresses, including device-quadrant gaps. Between
an LR and the SC that closes it go only operations that cannot trap or flush:
integer operations, branches, JAL and JALR, FENCE, another LR, and loads,
stores, and AMOs to valid aligned addresses, some to the reserved line.
The SC uses the last LR's exact address and width or a different 32-byte line.
The model matches SC by reservation set; the cached CPU interface requires
an exact address and width match. Differing SC widths and offsets within a
reserved line are covered by the cache and full-CPU atomic benches.
An LR outside such a window always faults, so no reservation is open where
a trap can happen. Base registers hold fixed addresses in DDR, low BRAM,
the device quadrant, and unmapped space, and only their setup writes them.
Each window and each setup is a `.noshrink` strand, which QuickCheckVEngine's shrinking leaves whole, so
a shrunk counterexample follows the same rules. The memory permissions come
from `sail_frost.json`.

The tests come from a seed: `--seed` repeats a run, and without it the runner
picks one and prints it. They are written to `tests/testrig_logs/atomics/`.

## Scalar floating point and Zcb

QuickCheckVEngine's `float`, `float64`, `double`, and `double64` templates
initialize FP registers to zero and do not emit Zfhmin or Zfa instructions.
Its `compressed` template does not emit Zcb, Zcmop, Zimop, or Zihintntl
encodings. `--fp-ext N` replays N tests from [`fp_ext.py`](fp_ext.py), and
`--zcb N` replays N tests from [`compressed_mops.py`](compressed_mops.py).

Each `--fp-ext` test enables `mstatus.FS` Dirty, initializes a cached-DDR base
in `x9`, and mixes F, D, Zfhmin, and Zfa operations across corner, subnormal,
signed-zero, infinity, NaN, and improperly NaN-boxed operands in all five
rounding modes and `DYN`. Because neither Sail 0.16 nor FROST carries FP
destination registers on RVFI-DII, every FP destination is moved to an integer
register with `fmv.x.d` to compare all 64 bits including NaN boxing, `fflags`
is read and cleared after each operation, and FP stores are checked through
RVFI store records and integer readbacks. Each test also exercises reserved
rounding modes, `fcvtmod.w.d` with rounding modes other than `rtz`, misaligned
FP loads and stores, and unimplemented half-precision encodings that trap as
illegal instructions.

Each `--zcb` test initializes `x1..x15` with corner and random 64-bit values
and places two 8-byte-aligned cached-DDR bases in `x8` and `x9`. It mixes all
RV64 Zcb loads, stores, unary transforms, and `c.mul` with every `c.mop.n`,
`mop.r.n`, `mop.rr.n`, `ntl.*`, `c.ntl.*`, integer ALU traffic, and reserved
neighbor encodings that trap.

Scalar FP and Zcb exclusions in the Sail 0.16 comparison:

| Exclusion | Reason |
|-----------|--------|
| FP destination register RVFI channel | Sail 0.16 and FROST do not carry FP register writebacks on RVFI-DII; `--fp-ext` observes every FP result through `fmv.x.d`, `fflags`, and store records |
| Scalar `Zfh` arithmetic, comparisons, FMA, and `fclass.h` | FROST implements `Zfhmin` rather than full scalar `Zfh`, so `sail_frost.json` keeps `Zfh` disabled even though Sail 0.16 supports it; unimplemented `Zfh` encodings are checked as illegal-instruction traps |
| `fli.h` in scalar TestRIG | Under the Zfa specification `fli.h` requires `Zfh` or `Zvfh`; the scalar TestRIG build disables both `Zfh` and `V`, so `fli.h` traps as an illegal instruction on both implementations |
| `fmvh.x.d` and `fmvp.d.x` | RV32-only Zfa double-precision register-pair moves do not apply on RV64 |

## Misaligned loads and stores

`--misaligned` replays five deterministic traces from
[`misaligned.py`](misaligned.py) covering plain misaligned loads and stores
executed by the misaligned-access engine (`MISALIGNED_HW=1`, `Zicclsm`) in
cached DDR and address-misaligned or access-fault traps outside cached DDR:

- Bare-mode integer loads and stores (`lh`, `lhu`, `lw`, `lwu`, `ld`, `sh`,
  `sw`, `sd`, plus `x0` destination and source) at every misaligned offset
  across 8-byte dword, 32-byte sector, 64-byte cache-line, and 4 KiB page
  boundaries, with aligned readbacks on both sides of each boundary.
- Bare-mode scalar FP (`flh`, `flw`, `fld`, `fsh`, `fsw`, `fsd`) and compressed
  (`c.lh`, `c.lhu`, `c.sh`, `c.lw`, `c.sw`, `c.ld`, `c.sd`, `c.fld`, `c.fsd`,
  `c.lwsp`, `c.ldsp`, `c.fldsp`, `c.swsp`, `c.sdsp`, `c.fsdsp`) misaligned
  loads and stores across those boundaries.
- Sv39 translated misaligned loads and stores across 8-byte, 32-byte, 64-byte,
  and 4 KiB page boundaries (including non-adjacent physical frames and a
  2 MiB superpage) in MPRV S, direct S, and direct U modes, plus `MXR=1` and
  Ssnpm 7-bit pointer masking.
- Sv39 cross-page misaligned loads faulting on the second page (invalid PTE,
  execute-only without `MXR`, user page without `SUM`, supervisor page in U
  mode, `A=0`, reserved `W=1/R=0`, non-canonical upper VA, and unmapped upper
  PA), in M mode and delegated to S mode, alongside first-page faults.
- Low BRAM, MMIO, APLIC, and IMSIC misaligned accesses and misaligned DDR
  atomics (causes 4 and 6), plus unmapped physical addresses (causes 5 and 7),
  in bare and Sv39 modes.

For a translated store crossing a 4 KiB page boundary, Sail 0.16 splits the
access at the page boundary and reports the upper page's physical base, upper
byte mask, and shifted upper bytes in its single RVFI-DII store record; every
other store reports its starting physical address, full width mask, and
right-aligned data. `hw/sim/frost_rvfi_dii.sv` reports the same payload on the
engine's completion pulse, and the trace set reads back aligned dwords on both
sides of the boundary to verify both halves in memory.

Cases kept out of TestRIG because Sail 0.16 cannot model FROST's rule:

| Omitted case | Reason |
|--------------|--------|
| Sv39 cross-page store faulting on the second page | FROST validates both pages before any write, leaving page 1 untouched and `mem_wmask = 0` on the trapping record; Sail 0.16 writes the lower page before translating the upper page and leaves a nonzero `mem_wmask` on the trapping record |
| Sv39 cross-page access in or into low BRAM or a device window | Sail 0.16 splits a translated cross-page access at the 4 KiB page boundary before checking per-region `misaligned_exceptions`, so naturally aligned halves (`+0xFFF` for 2 bytes, `+0xFFE` for 4 bytes, `+0xFFC` for 8 bytes) retire on Sail instead of trapping, and an upper-page alignment trap writes the upper page base to `xtval` instead of the original virtual address |
| Bare-mode misaligned access straddling the upper edge of DDR into unmapped space | FROST writes the upper sector base to `xtval` for the access fault; Sail 0.16 writes the starting address |
| Bare-mode misaligned access straddling the upper edge of low BRAM or a device window into unmapped space | FROST checks the lower part first and raises address-misaligned (4/6); Sail 0.16 checks whole-range region containment first and raises access fault (5/7) |

## The vector extension

QuickCheckVEngine has no vector templates, so `--vector N` replays N tests
from [`vector.py`](vector.py) as raw instruction words, as `--atomics` does.
It needs a core built with the vector unit, which the runner requests with
`-GVECTOR=1 -GVLEN=<--vlen> -GVECTOR_ADVERTISE=1`, and a Sail configuration
for the same length:
`sail_frost.json` with the matching `sail_frost_vlen*.json` overlay, which
turns V on, makes `misa.V` read-only, and lets `mstatus.VS` take all four
states.

Each test enables FS and VS, zeroes v0..v31, `vxrm` and `vxsat`, runs random
integer vector operations (arithmetic, logic, shifts, saturation,
multiplication, division and slides) under random SEW, LMUL and AVL values
with tail- and mask-undisturbed policies, and then reads the state out.
Agnostic elements may legally differ between implementations. The test
initializes the vector state after the preamble
because Sail does not reset the vector registers and the first `vsetvli` must
use a non-`x0` AVL while `vtype.vill` is set; both implementations execute it.
The read-out first reads `vl` and `vtype`, then moves every 64-bit element of
v0..v31 into a scalar register with `vmv.x.s` and an in-place `vslidedown.vi`
by one, then reads `vxsat` and `vlenb`. This is
how the comparison sees vector state: RVFI-DII carries integer destinations,
and for a vector load or store only one element of its data, so a register
image cannot be read back through memory. The setup and the read-out are
`.noshrink` strands. Operands are drawn so that nearly all encodings are legal;
a small share may still trap on some register or mask combinations, which both
implementations must report alike.

The `--vector-source-widths` option adds directed integer, floating-point and
memory traces to the same replay. They check reserved source overlaps and
legal controls. The memory trace checks traps before an access.
[Integer](vector_source_widths_integer.S) · [Floating point](vector_source_widths_fp.S)
· [Memory](vector_source_widths_memory.S)

The `--vector-directed` option replays 25 directed base-V and Zfa traces (the
directed segment trace `vector_segment.S` runs with `--vector-segments`):

| Trace | Instruction family and coverage |
|-------|---------------------------------|
| [`vector_state_results.S`](vector_state_results.S) | `misa.V`, vector CSRs, `mstatus.VS`, `vsetivli`, `vsetvl`, `vcpop.m`, `vfirst.m`, `vfmv.f.s`, and selected trap outcomes |
| [`vector_fractional_lmul.S`](vector_fractional_lmul.S) | `vl`/`vtype` and arithmetic at `e8/mf8`, `e16/mf4`, and `e32/mf2`, widening, `tu`/`ta`/`ma` readouts, and illegal `e64/mf2` and `e32/mf8` `vill` recovery |
| [`vector_fp_results_flags.S`](vector_fp_results_flags.S) | Single- and double-precision vector add, multiply, and divide results, canonical NaN, all five `fflags`, and masked sNaN flag suppression |
| [`vector_fli_h.S`](vector_fli_h.S) | All 32 Zfa `fli.h` encodings, NaN-boxing, `frm` independence, `mstatus.FS` dirtying, and nonzero `funct3` / `FS = Off` traps |
| [`vector_fma.S`](vector_fma.S) | Single-width FP32/FP64 vector-vector and vector-scalar FMA single rounding, `RNE`/`RUP` rounding, masked `0 * inf` flag suppression, and canonical NaN |
| [`vector_fp_compare.S`](vector_fp_compare.S) | FP32/FP64 vector-vector and vector-scalar comparisons via mask readback, qNaN/sNaN flags, and masked NaN suppression |
| [`vector_fp_convert.S`](vector_fp_convert.S) | FP/integer and widening/narrowing FP conversions, rounding modes including round-to-odd narrowing, overflow, and mask-undisturbed NaN handling |
| [`vector_cached_load.S`](vector_cached_load.S), [`vector_cached_store.S`](vector_cached_store.S) | Aligned cached-DDR vector loads and stores with scalar initialization and readback |
| [`vector_unit_stride.S`](vector_unit_stride.S) | Aligned cached-DDR unit-stride loads/stores (`e8..e64`, masked/unmasked) and mask transfers (`vlm.v`, `vsm.v`), fractional/multi-register EMUL, page crossings, and scalar store readbacks |
| [`vector_strided.S`](vector_strided.S) | Aligned cached-DDR strided loads/stores (`e8..e64`) with positive, negative, and zero strides, masked/unmasked transfers, page crossings, and scalar store readbacks |
| [`vector_indexed.S`](vector_indexed.S) | Aligned cached-DDR unordered and ordered indexed loads/stores (`8..64`-bit indices), cross-width EMUL, duplicate-index ordering, in-place gathers, page crossings, and scalar store readbacks |
| [`vector_segment.S`](vector_segment.S) | Runs in `--vector-segments`: aligned cached-DDR unit-stride (`vlseg`/`vsseg`) and strided (`vlsseg`/`vssseg`) segment transfers for `nf = 2..8` across `e8..e64`, masked/unmasked, page crossings, and scalar store readbacks |
| [`vector_fof.S`](vector_fof.S) | Aligned `vle{8,16,32,64}ff.v` loads at the `0xC0000000` cached-DDR upper boundary: later-element `vl` trimming, masked fault preservation, and element-0 traps |
| [`vector_vstart_resume.S`](vector_vstart_resume.S) | Nonzero-`vstart` resumption across strided, indexed (including in-place `vd == vs2`), segment, and fault-only-first loads and stores: prestart preservation, `vstart >= vl`, fault-only-first trimming at `i > vstart` and `i == vstart`, fault-triggered resumption, and scalar store readbacks |
| [`vector_int_compare.S`](vector_int_compare.S) | Vector, scalar, and immediate integer comparisons at `SEW = 32` and `64`, mask-undisturbed preservation, and signed/unsigned ordering |
| [`vector_int_widen_narrow.S`](vector_int_widen_narrow.S) | Widening add/sub/mul/macc, `vzext`/`vsext`, narrowing right shifts, shift-amount masking, legal overlaps, and illegal width/LMUL traps |
| [`vector_fixed_point.S`](vector_fixed_point.S) | Saturating add/sub, averaging add/sub, `vsmul`, scaling shifts, and narrowing clips across all four `vxrm` modes, sticky `vxsat`, and overlap traps |
| [`vector_fp_single.S`](vector_fp_single.S) | Single-width FP32/FP64 add/sub/rsub/mul/div/rdiv/sqrt/rec7/rsqrt7, min/max, sign injection, `vfclass.v`, merge, and scalar-vector moves across all five `frm` modes, `fflags`, NaN-boxing, and traps |
| [`vector_whole_reg.S`](vector_whole_reg.S) | All 16 whole-register loads (`vl{1,2,4,8}re{8,16,32,64}`) and 4 stores (`vs{1,2,4,8}r.v`), `vill`/`vl` independence, page crossings, `vstart` fault resumption, scalar store readbacks, and illegal traps |
| [`vector_fp_widen.S`](vector_fp_widen.S) | All 18 FP32-to-FP64 widening add/sub/mul/FMA encodings across all five `frm` modes, subnormals, overflow, NaN-boxing, overlaps, and traps |
| [`vector_permutes.S`](vector_permutes.S) | `vslideup`/`vslidedown`, `vslide1*`/`vfslide1*`, `vrgather`/`vrgatherei16`, `vcompress.vm`, and `vmv{1,2,4,8}r.v`, out-of-range zeroing, masks, overlaps, and traps |
| [`vector_reductions.S`](vector_reductions.S) | All 16 base-V single-width and widening integer and FP reductions across all five `frm` modes, ordered FP summation, masked identities, `vl == 0`, overlaps, and traps |
| [`vector_carry_borrow.S`](vector_carry_borrow.S) | All 15 base-V `vadc`/`vmadc`/`vsbc`/`vmsbc` encodings across `e8..e64`, carry/borrow propagation, multi-limb chains, `tu`/`ta`, overlaps, and traps |
| [`vector_mask_ops.S`](vector_mask_ops.S) | All 15 base-V mask-register operations (eight logical ops, `vcpop.m`, `vfirst.m`, `vmsbf.m`, `vmsof.m`, `vmsif.m`, `viota.m`, `vid.v`), multi-block masks, overlaps, and traps |
| [`vector_int_mul_add.S`](vector_int_mul_add.S) | All 8 base-V integer multiply-add encodings (`vmacc`, `vnmsac`, `vmadd`, `vnmsub` in `.vv`/`.vx`) across `e8..e64`, wraparound, masks, overlaps, and traps |
| [`vector_int_vx_merge.S`](vector_int_vx_merge.S) | The remaining 18 base-V single-width integer encodings (16 `.vx` ALU/mul/div/rem forms plus `vmerge.vvm` and `vmerge.vxm`) across `e8..e64`, division corners, masks, overlaps, and traps |

Two reserved vector overlap encodings trap as illegal instructions in FROST
and Spike under RVV 1.0, while Sail 0.16 allows them, so they are not
compared in TestRIG:

- carry-out and borrow-out mask operations (`vmadc`, `vmsbc` with
  `LMUL > 1`) whose destination mask register overlaps an upper register of
  a multi-register source group (`vs2` or `vs1` beyond its lowest register);
- `viota.m` with `LMUL > 1` whose source mask register is an upper register
  of the destination group (for example `viota.m v8, v9` at `m2`).

Additional vector-extension behaviors are not compared against Sail 0.16:

- `fli.h` with `mstatus.VS = Off`: the vector Sail overlays enable `Zvfh` and
  `Zvfhmin` to match the `VECTOR=1` core, and Sail 0.16 gates `Zvfh` on
  `mstatus.VS != Off`, so `vector_fli_h.S` keeps `VS` enabled alongside `FS`.
  The `vec_fp_test` program covers `fli.h` with `VS = Off` on RTL and Spike.
- `Zvkt` data-independent execution timing: Sail 0.16 is an instruction-level
  functional model and has no cycle counts, so TestRIG cannot observe timing.
  Fixed-latency, operand-independent timing is covered outside TestRIG by
  `vec_integer_exec_v{128,256,512}`
  (`verif/cocotb_tests/vector/test_vec_integer_exec.py:zvkt_arithmetic_latency`),
  `vec_crypto_exec_v{128,256,512}`
  (`verif/cocotb_tests/vector/test_vec_crypto_exec.py:crypto_families`), and
  the `vec_int_lane` and `vec_mul_lane` unit benches.
- `Zvknha`/`Zvknhb` (`vsha2ms.vv`, `vsha2cl.vv`, `vsha2ch.vv`) with `vl == 0`
  and `LMUL * VLEN < EGW` (at `VLEN = 128`: `e32, mf2` or `e64, m1`): Sail
  0.16 retires these without trapping, whereas RVV Crypto 1.0, FROST and
  Spike raise an illegal-instruction trap. This case is covered outside
  TestRIG by the whole-SoC test `vec_crypto_exec_test_v128`
  (`sw/apps/vec_crypto_exec_test/main.c`) and the Spike legality comparator
  `tests/test_vector_legality_reference.py --forms crypto`.
- `Zvbc` (`vclmul`/`vclmulh`) with nonzero `vstart > 0` and `OP-VE` crypto
  instructions with `vstart >= vl` (for example `vstart == vl == 4`): Sail
  0.16 traps these as permitted by RVV 1.0, while FROST supports element
  restart on `Zvbc` and empty group restarts on `OP-VE`. Legal `OP-VE`
  restarts with `vstart < vl` (`vstart == 4, vl == 8`) are compared in
  TestRIG; the excluded `vstart` cases are covered outside TestRIG by
  `vec_crypto_exec_test_v{128,256,512}` (`sw/apps/vec_crypto_exec_test/main.c`),
  `vec_crypto_exec_v{128,256,512}`
  (`verif/cocotb_tests/vector/test_vec_crypto_exec.py`), and
  `tests/test_vector_legality_reference.py --forms crypto`.
- Vector stores that trap part-way (after performing one or more elements):
  `verif/testrig/run_stats.py` clears Sail's memory payload only for retiring
  (`trap == 0`) vector stores. On a trapping partial vector store, Sail 0.16
  emits the last performed element's store fields while FROST's RVFI emits
  none, so TestRIG cannot check vector stores that trap part-way. These cases
  are covered outside TestRIG by `vec_vstart_irq_test_v{128,256,512}`
  (`sw/apps/vec_vstart_irq_test/main.c`) and `vec_debug_partial`
  (`verif/cocotb_tests/vector/test_vec_debug_partial.py`).

The `--vector-ext` option replays eight directed RVA23 vector extension traces:

| Trace | Extension and coverage |
|-------|------------------------|
| [`vector_zvfhmin.S`](vector_zvfhmin.S) | Both Zvfhmin FP16/FP32 conversions (`vfwcvt.f.f.v`, `vfncvt.f.f.w`) and all 6 base-V `SEW = 16` int16/FP32 conversions across all five `frm` modes, subnormals, overflow, NaNs, scalar `Zfhmin` NaN-boxing, and traps |
| [`vector_zvbb.S`](vector_zvbb.S) | All 16 Zvbb/Zvkb mnemonics (17 encoding slots: `vandn`, `vbrev8`, `vrev8`, `vbrev`, `vclz`, `vctz`, `vcpop.v`, `vrol`, `vror`, `vwsll`) across `e8..e64`, shift/rotate masking, `imm[5] = 1`, overlaps, and traps |
| [`vector_zvbc_zvkned_zvkg.S`](vector_zvbc_zvkned_zvkg.S) | All 4 Zvbc (`vclmul`/`vclmulh`), 11 Zvkned AES-128/256, and 2 Zvkg GHASH encodings, FIPS-197 and NIST GCM vectors, `vstart = 4 < vl = 8` group restarts, and `OP-VE`/EGW traps |
| [`vector_zvknhb.S`](vector_zvknhb.S) | All 3 Zvknhb SHA-2 encodings (`vsha2ms.vv`, `vsha2cl.vv`, `vsha2ch.vv`) for SHA-256 (`SEW = 32`) and SHA-512 (`SEW = 64`), FIPS-180-4 vectors, `vstart = 4` restarts, and EGW/overlap traps |
| [`vector_zvfh_arith_fma.S`](vector_zvfh_arith_fma.S) | 29 Zvfh `SEW = 16` modes: 13 arithmetic/div/sqrt/rec7/rsqrt7 encodings and all 16 single-width FMA encodings across all five `frm` modes, FP16 subnormals, canonical NaN, `fflags`, masks, and traps |
| [`vector_zvfh_cmp_misc_red.S`](vector_zvfh_cmp_misc_red.S) | 33 Zvfh `SEW = 16` modes: 17 min/max/sgnj/class/merge/move/slide1, 10 comparison, and 6 reduction encodings across all 10 `vfclass.v` classes, NaN-boxing, `frm` modes, and traps |
| [`vector_zvfh_widen.S`](vector_zvfh_widen.S) | All 18 Zvfh FP16-to-FP32 widening add/sub/mul/FMA modes across all five `frm` modes, subnormals, NaN-boxing, masks, overlaps, and traps |
| [`vector_zvfh_cvt.S`](vector_zvfh_cvt.S) | 19 Zvfh conversion modes: 13 at `SEW = 16` (including `vfncvt.rod.f.f.w`) and all 6 `SEW = 8` int8/FP16 modes across all five `frm` modes, round-to-odd, saturation, masks, and traps |

On main pushes and pull requests labelled `run-ci`, CI runs three vector
TestRIG shards (`core`, `segment` and `ext`) at each of VLEN 128, 256 and 512,
sharing one prebuilt simulator per vector length. The `core` shard replays
12 generated traces of 20 operation groups from seed 42, the source-width
traces and the directed
state, fractional LMUL, FP, cached DDR, integer comparison, widening and
narrowing integer, fixed-point, single-width FP, whole-register memory,
widening FP, permute, reduction, carry/borrow, mask-register, integer
multiply-add and integer scalar/merge traces. The `segment` shard runs
`--vector-segments`, which generates five traces at CI time from the seeded
deterministic generator [`vector_segments.py`](vector_segments.py) (default
seed `0x5e600013`, with per-file SHA-256 digests pinned in
`tests/test_testrig_vector.py`) alongside the directed
[`vector_segment.S`](vector_segment.S) trace. Together those six segment
traces cover all 252 base-V segment load and store encodings (`vlseg`,
`vsseg`, `vlsseg`, `vssseg`, `vluxseg`, `vloxseg`, `vsuxseg`, `vsoxseg` and
`vlseg*ff` across `nf = 2..8` and 8/16/32/64-bit widths), segment field
ordering independent of `SEW`, masked/unmasked execution (`tu`/`mu` and
`ta`/`ma`), `vl == 0` and `VLMAX`, immediate scalar readbacks for every
stored byte, fault-only-first `vl` trimming across element 0 versus later
elements and mid-segment boundaries, non-fault-only-first `vstart` fault
reporting and resumption, and `nf * EMUL <= 8`, register-wrap, indexed
`vd`-group overlap, masked `v0`, alignment and `vill` traps. Together, `core`
and `segment` retire all 627 base-V machine encodings. The `ext` shard runs
`--vector-ext`, replaying all eight RVA23 vector extension traces
(`vector_zvfhmin.S`, `vector_zvbb.S`, `vector_zvbc_zvkned_zvkg.S`,
`vector_zvknhb.S`, `vector_zvfh_arith_fma.S`, `vector_zvfh_cmp_misc_red.S`,
`vector_zvfh_widen.S` and `vector_zvfh_cvt.S`, with `Zvfhmin`, `Zvfh`,
`Zvbb`, `Zvbc`, `Zvkg`, `Zvkned`, `Zvknha`, `Zvknhb` and `Zvkt` enabled in
`sail_frost_vlen*.json`). In CI, each vector TestRIG job has an 80-minute
limit: the `core` shard allows 55 minutes for replay and 50 minutes for VLEN
128 result controls, the `segment` shard allows 30 minutes for replay and 15
minutes for result controls, and the `ext` shard allows 16 minutes for replay
and 11 minutes for result controls. Both
implementations must return every planned trace and instruction. The
VLEN 128 `core`, `segment` and `ext` shards each reuse their simulator to flip one
bit in a FROST integer destination in each control replay. The `core` shard
checks `vmv.x.s` for integer
source widths, fractional LMUL, base FP results, fused multiply-add, FP
conversions, unit-stride memory, strided memory, indexed memory,
fault-only-first loads, integer comparisons, widening and
narrowing integer operations, fixed-point operations, single-width FP
operations, whole-register memory, widening FP, permute, reduction,
carry/borrow, mask-register, integer multiply-add and integer scalar/merge
operations, and checks `vcpop.m` for state and scalar results and FP
comparisons. The `segment` shard checks `vmv.x.s` for both the directed
segment trace (`segment`) and field 1 of the generated unit-stride segment
control load (`segment-matrix`). The `ext` shard checks `vmv.x.s` for all
eight extension traces (`zvfhmin`, `zvbb`, `zvbc-zvkned-zvkg`, `zvknhb`,
`zvfh-arith`, `zvfh-misc-red`, `zvfh-widen` and `zvfh-cvt`). TestRIG must report
each destination value mismatch.

The unit tests in `tests/test_testrig_vector.py` check the replay inputs
and match generated words against the assembler. They validate the Sail
configurations and use two Sail instances to check trace agreement at each
vector length and sensitivity to a width difference.

## Sv39 MMU, cache-block operations, and Sstvala

QuickCheckVEngine's default `pte` and `csr` templates run in M-mode, write only
zero to `satp.ASID`, emit only the global `sfence.vma x0, x0` form, and do not
emit Zicbom, Zicboz, `prefetch.w`, or Zawrs encodings. `--mmu N` replays N
tests from [`mmu.py`](mmu.py), and `--cmo N` replays N tests from
[`cmo.py`](cmo.py).

Each MMU test builds two Sv39 page-table hierarchies in cached DDR with 4 KiB
pages, 2 MiB megapages, 1 GiB gigapages, global leaves, non-leaf global
pointers, negative canonical upper-half virtual addresses, mapped device pages,
faulting PTEs (`V=0`, `A=0`, `D=0`, `U=1` under `SUM=0`/`1`, `X`-only under
`MXR=0`/`1`, reserved `W=1,R=0` and bit-54 PTEs, misaligned superpages,
non-leaf `D/A/U`, non-leaf pointers outside cached DDR, and unmapped or
out-of-range leaf PPNs), non-canonical virtual addresses, and the `mstatus.TVM`
and `mstatus.TSR` trap-intercept bits. Strands run across M (`MPRV=1`), S, and
U modes, delegate traps selectively to S-mode, read `mtval`/`stval`,
`mepc`/`sepc`, and `mcause`/`scause` into integer registers, switch ASIDs
without `SFENCE.VMA` while spilling the 16-entry L1 DTLB into the 512-entry L2
TLB and wrapping the 32-entry superpage side array, and mutate cached PTEs
followed by all four `SFENCE.VMA` forms (`(x0, x0)`, `(va, x0)`, `(x0, asid)`,
`(va, asid)`).

Each CMO test configures `menvcfg` and `senvcfg` (`FIOM`, `CBIE` including
reserved `10` legalization to `00`, `CBCFE`, and `CBZE`), interleaves cached
DDR, low-BRAM, and device-window stores with `cbo.clean`, `cbo.flush`,
`cbo.inval`, `prefetch.i`, `prefetch.r`, `prefetch.w`, `wfi` (with `TW` clear
in M and S, and clear or set in U), `wrs.sto`, and `wrs.nto`, and checks
`mtval`/`stval` across Bare and Sv39 permission, alignment,
illegal-instruction, and breakpoint traps.

Every strand in `mmu.py` and `cmo.py` is marked `.noshrink`, so
QuickCheckVEngine does not shrink counterexamples below whole strands. At the
end of a `--mmu` or `--cmo` run, the runner checks each strand's RVFI record
slice for the expected privilege mode, predicted trap or retirement, exception
cause, and fault-value CSR readback, prints the per-strand-kind table, and
fails the run when a predicted trap misses or a strand kind never reaches its
target behavior across the sample.

Several architectural and harness rules keep the comparison deterministic:

- A leading `cbo.inval` in a cached store/load sequence is preceded by
  `cbo.clean`. This gives both implementations the same value to reload after
  invalidation. The directed cache tests exercise discarding a dirty block.
- Sail walks page tables in memory on every access, whereas FROST caches
  translations across its L1 ITLB, L1 DTLB, L2 TLB, superpage array, and walk
  cache. Each non-zero ASID binds to one root table, valid-PTE edits pair with
  a matching `SFENCE.VMA`, and `Svvptc` invalid-to-valid upgrades install the
  leaf in the fault handler and drain committed stores via `mret` or `sret`
  without a fence.
- When a 32-bit instruction straddles a page boundary onto an unmapped second
  page, FROST writes `PC + 2` to `xtval` while Sail 0.16's `rvfi_fetch` passes
  `PC` in `F_Error(e, PC)`. Those strands compare `xepc` and `xcause` and clear
  `xtval`; 16-bit parcels at `0xFFE` followed by a fault at `0x1000` compare
  `xtval` directly.
- Sail 0.16's RVFI-DII write recorder asserts a 16-byte maximum write width
  (`core/rvfi_dii.sail`), so retiring a 64-byte `cbo.zero` aborts Sail.
  `cmo.py` exercises `cbo.zero` across `CBZE` privilege gates and Bare and Sv39
  access and page faults; retiring 64-byte zeroing is checked by the Zicboz
  cocotb benches.
- Under Sv39, FROST checks alignment before the page-table walk. Sail walks
  the page tables before checking alignment. Translated strands place
  misaligned checks on valid pages.

## Saved counterexamples

`traces/` holds directed regression sequences, one per file. The first of
CI's TestRIG jobs replays all of them before its random run.

| Trace | Checks |
|-------|--------|
| [`access_fault_tval.S`](traces/access_fault_tval.S) | Access faults on loads, stores, AMOs and LR write the faulting address to `mtval`, including Bare and Sv39 stores into a device-quadrant gap |
| [`clint_window_load.S`](traces/clint_window_load.S) | A load just below 2^35 faults at the 1 GiB default and reaches DDR with a 64 GiB configuration; Sail disables its CLINT in both configurations |
| [`envcfg_fiom.S`](traces/envcfg_fiom.S) | `menvcfg.FIOM`, `senvcfg.FIOM` and both CBZE bits are writable |
| [`fence_r0.S`](traces/fence_r0.S) | `fence r,0` retires |
| [`fp_csr_fs.S`](traces/fp_csr_fs.S) | Pure reads of `fflags`, `frm` and `fcsr` preserve Initial and Clean FS, and writes set FS to Dirty even when the value is unchanged |
| [`hpm_counters.S`](traces/hpm_counters.S) | Writable machine counter 3, zero-only machine counter/selector 31, and absent user alias 9 |
| [`imsic_window_load.S`](traces/imsic_window_load.S) | An aligned doubleword load in the IMSIC window reaches the TestRIG device RAM without an access fault |
| [`instret_nops.S`](traces/instret_nops.S) | NOP and C.NOP count in `minstret` |
| [`lr_reserved_rs2.S`](traces/lr_reserved_rs2.S) | Reserved `LR.W`/`LR.D` encodings with nonzero `rs2` trap as illegal without creating a reservation; legal `rs2 = 0` forms still pair with `SC` |
| [`lrsc_amo.S`](traces/lrsc_amo.S) | AMOs to the first two doublewords of the reserved line cancel the reservation; an AMO to the next line preserves it |
| [`lrsc_jump.S`](traces/lrsc_jump.S) | A JAL, JALR, or taken branch between LR and SC keeps the reservation |
| [`lrsc_older_store.S`](traces/lrsc_older_store.S) | An older store to the other word of the reserved doubleword drains before LR and permits the following SC |
| [`pte_nonleaf_dau.S`](traces/pte_nonleaf_dau.S) | A non-leaf PTE with D, A, or U set raises a page fault |
| [`svinval_sstc.S`](traces/svinval_sstc.S) | Svinval encodings, `mstatus.TVM`/U-mode legality, reserved `SYSTEM` `funct3=000` fields, and Sstc `stimecmp` gating across `menvcfg.STCE` and `mcounteren.TM` |
| [`svpbmt_pbmte.S`](traces/svpbmt_pbmte.S) | PBMTE readback and PBMT page faults; Sail does not check the uncached alias transport or cache coherence |
| [`svnapot_leaf.S`](traces/svnapot_leaf.S) | A 64 KiB NAPOT leaf (N, PPN[3:0] = 1000) translates two of its pages with PPN[3:0] = VA[15:12]; N with another PPN[3:0], in a 2 MiB leaf or in a pointer is a page fault |
| [`ssu64xl_uxl.S`](traces/ssu64xl_uxl.S) | `mstatus.UXL`/`SXL` and `sstatus.UXL` read 2 and keep 2 when written with 3, 0 and 1 (UXLEN is 64) |
| [`ssnpm_pmm.S`](traces/ssnpm_pmm.S) | `senvcfg.PMM` WARL (01 keeps the old value); with MPRV and MPP = U, tagged loads, stores and AMOs under Bare (PMLEN 16 and 7) and Sv39, masked faults with the transformed `mtval`, and no masking with MXR set or PMM = 00 |
| [`sstvala_illegal.S`](traces/sstvala_illegal.S) | Illegal 32-bit and 16-bit instructions write their instruction bits to `mtval` and `stval` |
| [`zawrs_ops.S`](traces/zawrs_ops.S) | `wrs.sto` and `wrs.nto` retire in M, S, and U modes and preserve an active `LR.D` reservation |
| [`zcb_zimop_zcmop_ntl.S`](traces/zcb_zimop_zcmop_ntl.S) | Zcb, Zcmop, Zimop, and Zihintntl encodings in M-mode compared with Sail, plus reserved neighboring encodings that stay illegal |
| [`zicbom_ops.S`](traces/zicbom_ops.S) | `cbo.clean`, `cbo.flush`, and `cbo.inval` across cached DDR, low BRAM, device windows, and unmapped addresses, with `CBIE`/`CBCFE` WARL checks |
