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
| [`mmu.py`](mmu.py) | Random Sv39 MMU, ASID, SFENCE.VMA, and Sstvala tests (see [Sv39 MMU, cache-block operations, and Sstvala](#sv39-mmu-cache-block-operations-and-sstvala)) |
| [`cmo.py`](cmo.py) | Random Zicbom, Zicboz, Zicbop, Zawrs, device-window, and Sstvala tests (see [Sv39 MMU, cache-block operations, and Sstvala](#sv39-mmu-cache-block-operations-and-sstvala)) |
| [`vector.py`](vector.py) | Random vector-instruction tests (see [The vector extension](#the-vector-extension)) |
| [`sail_frost.json`](sail_frost.json) | Sail settings that describe FROST |
| `sail_frost_vlen128.json`, `sail_frost_vlen256.json`, `sail_frost_vlen512.json` | Overlays on `sail_frost.json` that turn on the vector unit at one vector length; they differ only in `V.vlen_exp` |
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
./scripts/frost.py run python3 tests/test_testrig.py --wfi                 # Directed WFI waits, wakes, and traps
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
template, 200 A-extension tests, 40 Sv39 MMU tests, and 80 CMO and Sstvala
tests. The first job also runs the directed `--wfi` traces. Each job simulates
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
| `--fp-ext` | off | Replay this many Zfhmin and Zfa tests |
| `--svinval` | off | Replay this many random Svinval tests (`verif/testrig/svinval.py`) instead of the templates |
| `--sscofpmf` | off | Replay the deterministic counter-control trace (`verif/testrig/sscofpmf/controls.S`); `--trace` overrides the trace path |
| `--vector` | off | Replay this many random vector-instruction tests on a core built with the vector unit (see [The vector extension](#the-vector-extension)) |
| `--vector-length` | 20 | Operation groups per generated vector trace |
| `--vector-source-widths` | off | Add the directed integer, FP and memory source-width traces to `--vector` |
| `--vector-directed` | off | Add the directed vector CSR, scalar-result, fractional LMUL, FP and cached DDR memory traces to `--vector` |
| `--vlen` | 128 with `--vector` | Build FROST with the vector unit at this vector length (128, 256 or 512) and configure Sail to match; needed to replay vector traces with `--trace` or `--trace-dir` |
| `--seed` | random | Seed for `--atomics`, `--zcb`, `--fp-ext`, `--mmu`, `--cmo`, `--svinval`, `--crypto` and `--vector`; the runner prints the one it used |
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
through the store queue. CSR read values arrive through delayed write-back.
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
capacity boundary, missing store completion, and excessive capacity requests.

The build differs from the production core in these ways, all for
simulation only:

- instruction access faults are dropped and page faults kept, because
  injected instructions need no memory and Sail checks only translation for
  them; this also drops the access fault of an instruction page-table walk
  that reads outside DDR, which the default templates never produce;
- misaligned loads and stores always trap; production FROST traps them only
  once `mtvec` has a nonzero base, and performs plain ones to cached DDR in
  its misaligned-access engine (`MISALIGNED_HW`), which this build leaves out
  because the recorder sees no retirement for them;
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
| Extensions | RV64IMAFDC, B, Zfa, Zfhmin, Zcb, Zcmop, Zihintntl, Zimop, Zicond, Zbc, Zbkb, Zbkc, Zkt, Zihintpause, Zicntr, Zihpm, Zic64b, Ziccif, Zicboz, Zicbom, Zicbop, Zawrs, S, U, Sv39, Svade, Svinval, Svnapot, Svpbmt, Ssnpm, Svvptc, Sstc, Sscofpmf, Sscounterenw, Sstvala, Sstvecd; `misa` read-only |
| Memory regions | The PMA map: low BRAM, MMIO, APLIC, IMSIC, and configurable DDR (1 GiB default), the only region page-table walks read |
| Physical addresses | 64 bits wide, so an untranslated access beyond the memory map faults with its full address in `mtval` |
| Misaligned accesses | Address-misaligned trap, after the PMA check; `Zicclsm` is left off because TestRIG builds omit the misaligned-access engine |
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
`--trace-dir`, `--atomics`, `--crypto`, `--zcb`, `--fp-ext`, `--mmu`, `--cmo`,
`--svinval`, `--vector` or `--wfi`.

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

The `--vector-directed` option includes a state and scalar-result trace
for `misa.V`, vector CSRs, VS state, `vsetivli`, `vsetvl`, `vcpop.m`, `vfirst.m`
and `vfmv.f.s`. The trace
asserts the scalar results and selected trap outcomes. The mask operations
read five active bits from initialized mask bytes. FP extraction reads
initialized element zero and exposes its bits in integer registers. The
vector setup uses tail- and mask-undisturbed policies. [State and scalar results](vector_state_results.S)

The fractional LMUL trace checks VL and vtype at e8/mf8, e16/mf4 and
e32/mf2, arithmetic and a widening result. Integer reads also check
initialized tail elements under the tail-undisturbed policy and a
neighboring register. With the tail- and mask-agnostic policies the trace
reads only the initialized, mask-enabled element zero. The trace also checks
that e64/mf2 and e32/mf8 set `vill` and clear `vl`, and that a legal
setting after each rejection clears `vill` and restores a nonzero `vl`. [Fractional LMUL](vector_fractional_lmul.S)

The base FP trace checks binary32 vector adds and binary64 vector-scalar
multiplication and division. It compares exact and rounded results, the canonical
NaN and all five accrued exception flags. The masked add checks that the
disabled signaling NaN leaves the flags clear and reads only the initialized,
enabled result. [Base FP results and flags](vector_fp_results_flags.S)

The fused multiply-add trace checks the single-width vector-vector and
vector-scalar forms in binary32 and binary64. A nonzero residual checks
single rounding for a product that rounds to one on its own. The masked case
reads only the enabled result and checks that the disabled zero-times-infinity
element leaves the flags clear. The unmasked case checks the canonical NaN and
the invalid flag. A halfway fused result checks rounding under RNE and RUP
and the accrued inexact flag. [Fused multiply-add](vector_fma.S)

The FP comparison trace checks vector-vector and vector-scalar predicates
in binary32 and binary64. Mask population and first-set index expose active
comparison bits. The trace checks the results and accrued flags for quiet
and signaling NaNs. A masked comparison checks that a disabled NaN lane
leaves the invalid flag clear. [FP comparisons](vector_fp_compare.S)

The FP conversion trace checks conversions between floating-point and signed or
unsigned integer values, and widening and narrowing between floating-point
formats. It checks exact results, nearest-even rounding, truncation and
round-to-odd narrowing through integer readouts. An overflowing narrowing
conversion checks positive infinity and the overflow and inexact flags.
The mask-undisturbed conversion checks the enabled result and the preserved
masked-off element. The masked NaN leaves the invalid flag clear.
[FP conversions](vector_fp_convert.S)

The cached DDR traces check aligned vector loads and stores. Scalar stores
initialize the load input, and integer moves expose each loaded lane. The
store trace asserts that the vector store retires and that scalar loads read
the expected value from every written element.
[Cached load](vector_cached_load.S) and [cached store](vector_cached_store.S).

The unit-stride memory trace checks aligned cached DDR loads and stores at
8, 16, 32 and 64-bit element widths, both unmasked and masked, and mask loads
and stores (`vlm.v` and `vsm.v`). It covers vector lengths below and equal to
VLMAX, tail-undisturbed and mask-undisturbed readouts where defined,
multi-register and fractional EMUL transfers, zero-active transfers, and a
cached page-boundary crossing. Every vector store reads back all written bytes
through immediate scalar loads without reading `misa`.
[Unit-stride memory](vector_unit_stride.S)

The strided memory trace checks aligned cached DDR strided loads and stores at
8, 16, 32 and 64-bit element widths, both unmasked and masked. It covers
positive strides above and equal to the element size, negative strides, zero
strides through `x0` and through a zero-valued register, vector lengths below
and equal to VLMAX, tail-undisturbed and mask-undisturbed readouts where
defined, multi-register and fractional EMUL transfers, zero-active transfers,
and a cached page-boundary crossing. Every strided store reads back all
written bytes through immediate scalar loads without reading `misa`.
[Strided memory](vector_strided.S)

The indexed memory trace checks aligned cached DDR unordered and ordered
indexed loads and stores at 8, 16, 32 and 64-bit index widths, both unmasked
and masked. It covers matching and cross-width element and index widths
(fractional and multi-register index EMUL), unsigned high-bit and wide index
values, duplicate-index gathers and ordered duplicate-index store ordering,
legal in-place gathers, vector lengths below and equal to VLMAX,
tail-undisturbed and mask-undisturbed readouts where defined, zero-active
transfers, and a cached page-boundary crossing. Every indexed store reads back
all written bytes through immediate scalar loads without reading `misa`.
[Indexed memory](vector_indexed.S)

The segment memory trace checks aligned cached DDR unit-stride segment loads
and stores (`vlseg` and `vsseg`) for two through eight fields across 8, 16, 32
and 64-bit element widths, and strided segment loads and stores (`vlsseg` and
`vssseg`) across all four widths, both unmasked and masked. It covers positive,
negative and zero strides, vector lengths below and equal to VLMAX,
tail-undisturbed and mask-undisturbed readouts where defined, multi-register
and fractional EMUL field groups, zero-active transfers, and a cached
page-boundary crossing inside a segment. Every segment store reads back all
written bytes through immediate scalar loads without reading `misa`.
[Segment memory](vector_segment.S)

The fault-only-first load trace checks aligned `vle8ff.v`, `vle16ff.v`,
`vle32ff.v` and `vle64ff.v` loads, both unmasked and masked, across the upper
boundary of the 1 GiB cached DDR window at `0xC0000000`. It starts with a
scalar load at `0xC0000000` to check load access-fault agreement, then checks
later-element faults that trim `vl` while leaving post-fault lanes undisturbed
across all four widths, multi-register and VLMAX configurations, masked-off
faulting elements that preserve `vl`, non-faulting and zero-active loads, and
element-zero faults that trap with `mcause`, `mtval`, `vstart` and unchanged
`vl`, without reading `misa`. [Fault-only-first loads](vector_fof.S)

The integer comparison trace checks vector, scalar and immediate predicates
at SEW 32. It reads each active mask bit through an integer destination.
The mask-undisturbed case checks enabled updates and preserved disabled bits.
The SEW 64 cases read back `vtype` and check equality and ordering on
operands with matching low halves and differing upper halves. The signed
and unsigned ordering cases compare the same pairs, including one with
opposite signs. [Integer comparisons](vector_int_compare.S)

The widening and narrowing integer trace checks widening addition and
subtraction, integer zero and sign extensions, narrowing logical and
arithmetic right shifts, widening multiplication and widening
multiply-accumulate across their supported element widths. It covers
masked and unmasked forms, vector lengths below, equal to and zero
relative to VLMAX, tail- and mask-undisturbed readouts, shift-amount
masking at twice SEW without rounding or saturation, fractional and
multi-register group multipliers, legal register overlaps and illegal
width and group-multiplier traps.
[Widening and narrowing integer operations](vector_int_widen_narrow.S)

The fixed-point trace checks saturating addition and subtraction,
averaging addition and subtraction, saturating fractional multiplication,
scaling right shifts and narrowing fixed-point clips across all supported
element widths. It covers all four fixed-point rounding modes with `vxrm`
CSR readbacks after each write, saturation and sticky `vxsat` updates,
rounding before saturation on narrowing clips, inactive masked and tail
lanes leaving `vxsat` clear, vector lengths below, equal to and zero
relative to VLMAX, tail- and mask-undisturbed readouts, fractional and
multi-register group multipliers, legal register overlaps and illegal
widening, narrowing and mask-register overlap traps.
[Fixed-point operations](vector_fixed_point.S)

The single-width floating-point trace checks binary32 and binary64
addition, subtraction, reverse subtraction, multiplication, division,
reverse division, square root, reciprocal and reciprocal-square-root
estimates, minimum and maximum, sign injection, classification,
floating-point merge, and scalar-vector floating-point moves. It covers
all five rounding modes with `frm` CSR readbacks after each write across
addition, multiplication, division, reverse division, square root and
reciprocal estimates, all five accrued exception flags, signed-zero and
NaN-propagation corners, improperly NaN-boxed scalars, all ten
classification classes, masked and unmasked forms, vector lengths below,
equal to and zero relative to VLMAX, tail- and mask-undisturbed
readouts, fractional and multi-register group multipliers, legal
in-place overlap and illegal single-width FP traps.
[Single-width FP operations](vector_fp_single.S)

The whole-register memory trace checks all sixteen whole-register loads
(`vl1re`, `vl2re`, `vl4re` and `vl8re` at 8, 16, 32 and 64-bit element
widths) and all four whole-register stores (`vs1r.v`, `vs2r.v`,
`vs4r.v` and `vs8r.v`) in cached DDR. It covers neighboring-register
preservation, whole-register transfers while `vtype.vill` is set,
independence from `vl`, `vtype` and `v0`, odd-address byte-aligned
transfers, a cached 4 KiB page-boundary crossing, Page-0 access faults
and Page-1 faults at `0xC0000000` checking `vstart` granularity and
resumption across all four load widths, and illegal-instruction traps
for misaligned register groups, reserved field counts, masked forms,
nonzero store widths and `mew = 1`. Every retiring whole-register store
reads back all written bytes through immediate scalar loads without
reading `misa`. [Whole-register memory](vector_whole_reg.S)

The widening floating-point trace checks all eighteen binary32-to-binary64
widening floating-point encodings: narrow-source and wide-source addition
and subtraction (`vfwadd` and `vfwsub` in `.vv`, `.vf`, `.wv` and `.wf`),
widening multiplication (`vfwmul.vv` and `vfwmul.vf`), and all four
widening fused multiply-add sign forms (`vfwmacc`, `vfwnmacc`, `vfwmsac`
and `vfwnmsac` in `.vv` and `.vf`). It covers all five rounding modes with
`frm` CSR readbacks after each write across all sixteen rounding-capable
encodings, subnormal binary32 widening and exact binary64 subnormal
accumulation, signed-zero cancellation, binary64 overflow, `0 * inf + qNaN`
and `sNaN` invalid flags, improperly NaN-boxed scalars, masked and unmasked
forms, vector lengths below, equal to and zero relative to VLMAX, tail- and
mask-undisturbed readouts, `mf2` through `m4` group multipliers, legal
register overlaps and illegal widening FP traps.
[Widening FP operations](vector_fp_widen.S)

The permute trace checks slides (`vslideup.{vx,vi}`, `vslidedown.{vx,vi}`),
slide-by-one integer and floating-point moves (`vslide1up.vx`,
`vslide1down.vx`, `vfslide1up.vf`, `vfslide1down.vf`), register gathers
(`vrgather.{vv,vx,vi}`, `vrgatherei16.vv`), vector compression
(`vcompress.vm`) and whole-register moves (`vmv1r.v`, `vmv2r.v`, `vmv4r.v`,
`vmv8r.v`) across all supported element widths. It covers `vslideup` prefix
preservation under `tu` and `ta`, `vslidedown` 64-bit index wraparound,
exact `VLMAX - 1` versus `VLMAX` out-of-range zeroing, zero-extended five-bit
immediates (`uimm5` 16 and 31), `vrgatherei16` indices across all four data
widths including indices above 255 at SEW 8 and legal `vs2 == vs1` at SEW 16,
floating-point `sNaN` pass-through and improperly NaN-boxed scalar unboxing
without raising flags, `vcompress.vm` with all-zero, all-ones, sparse and
`v0` masks, `vmv<nr>r.v` independence of `vl` and `vlmul` plus self-copy,
masked and unmasked forms, vector lengths below, equal to and zero relative
to VLMAX, fractional and multi-register group multipliers, legal in-place
overlaps and illegal permute overlap, alignment, range, reserved and `vill`
traps.
[Vector permute operations](vector_permutes.S)

The reduction trace checks all sixteen base-V vector reduction encodings:
single-width integer reductions (`vredsum`, `vredand`, `vredor`, `vredxor`,
`vredminu`, `vredmin`, `vredmaxu` and `vredmax`), widening integer sum
reductions (`vwredsumu` and `vwredsum`), single-width floating-point
reductions (`vfredusum`, `vfredosum`, `vfredmin` and `vfredmax`), and
widening floating-point sum reductions (`vfwredusum` and `vfwredosum`)
across all supported element widths. It covers all five rounding modes with
`frm` CSR readbacks after each write across all four floating-point sum
reductions, strict left-to-right ordered floating-point summation, exact
binary32 subnormal widening, signed-zero cancellation and min/max ties,
floating-point overflow and invalid flags, masked-off lanes acting as
identities and suppressing `fflags`, all-masked-off copy of the scalar seed
including verbatim `sNaN` without flags, `vl == 0` leaving `vd[0]` and
`fflags` untouched, tail-undisturbed preservation of `vd[1]`, fractional
through `m8` group multipliers including odd scalar destinations and seeds,
legal register overlaps including masked `vd == v0`, and illegal reduction
width, source-overlap, `v0`-source, alignment, reserved `frm` and `vill`
traps.
[Vector reduction operations](vector_reductions.S)

The carry and borrow trace checks all fifteen base-V integer add-with-carry
and subtract-with-borrow encodings (`vadc.{vvm,vxm,vim}`,
`vmadc.{vvm,vxm,vim,vv,vx,vi}`, `vsbc.{vvm,vxm}` and
`vmsbc.{vvm,vxm,vv,vx}`) across all four element widths (`e8`, `e16`, `e32`
and `e64`). It covers carry-in and borrow-in propagation from `v0` versus
carry-free `vm = 1` suppression with `v0` set, sign-extended five-bit
immediates (`-1`, `-16` and `+15`), scalar truncation of upper register bits,
unsigned overflow and double-underflow boundaries without setting `vxsat`,
chained 128-bit two-limb addition and subtraction, multi-byte mask reads and
writes with tail-bit preservation, `tu` and `ta` policies, `vl == 0`,
`vl == VLMAX`, fractional through `m8` group multipliers, legal register
overlaps including in-place `vd == v0` mask updates and `m2` lowest-register
overlaps, and illegal reserved `vm = 1`, reserved `.vi`, `v0`-overlap,
alignment and `vill` traps.
[Vector carry and borrow operations](vector_carry_borrow.S)

The mask-register operations trace checks all fifteen base-V mask-register
encodings: all eight mask-register logical operations (`vmandn.mm`,
`vmand.mm`, `vmor.mm`, `vmxor.mm`, `vmorn.mm`, `vmnand.mm`, `vmnor.mm` and
`vmxnor.mm`), `vcpop.m`, `vfirst.m`, `vmsbf.m`, `vmsof.m`, `vmsif.m`,
`viota.m` and `vid.v`. It covers asymmetric truth tables across 80-bit
(`vl = 80`) two-block spans with tail-bit preservation, `vcpop.m` and
`vfirst.m` across 64-bit block boundaries including masked-off skipping,
all-zero `-1` results and `vl == 0`, `vmsbf`/`vmsof`/`vmsif` with first bit
at zero, across block 1 without retriggering, all-zero and masked-off
no-active-bit cases with `mu` preservation, `viota.m` and `vid.v` across all
four element widths (`e8`, `e16`, `e32` and `e64`), masked and unmasked
forms, `tu`/`ta`, `vl == 0`, `vl == VLMAX`, fractional through `m8` group
multipliers, legal `v0` and odd-register overlaps, and illegal reserved
`vm = 0`, `vd == vs2`, masked `vd == v0`, nonzero `vid.v` `vs2`, alignment
and `vill` traps.
[Vector mask-register operations](vector_mask_ops.S)

The integer multiply-add trace checks all eight base-V single-width integer
multiply-add encodings (`vmacc`, `vnmsac`, `vmadd` and `vnmsub` in `.vv` and
`.vx` forms) across all four element widths (`e8`, `e16`, `e32` and `e64`).
It covers asymmetric operands that distinguish `vd` as accumulator (`vmacc`,
`vnmsac`) from `vd` as multiplicand (`vmadd`, `vnmsub`), low-SEW wraparound
at unsigned and signed boundaries at every width, scalar upper-bit truncation
for `.vx` forms, masked and unmasked execution for all eight encodings,
`tu`/`mu` preservation and `ta`/`ma` execution across multi-register
boundaries, `vl == 0`, portable `vl == VLMAX` from `mf8` through `m8`, legal
register overlaps (`vd == vs1`, `vd == vs2`, `vs1 == vs2`,
`vd == vs1 == vs2` and unmasked `v0`), and illegal masked `v0`-overlap,
register-group alignment and `vill` traps.
[Vector integer multiply-add operations](vector_int_mul_add.S)

Two reserved vector overlap encodings trap as illegal instructions in FROST
and Spike under RVV 1.0, while Sail 0.16 allows them, so they are not
compared in TestRIG:

- carry-out and borrow-out mask operations (`vmadc`, `vmsbc` with
  `LMUL > 1`) whose destination mask register overlaps an upper register of
  a multi-register source group (`vs2` or `vs1` beyond its lowest register);
- `viota.m` with `LMUL > 1` whose source mask register is an upper register
  of the destination group (for example `viota.m v8, v9` at `m2`).

On main pushes and pull requests labelled `run-ci`, CI runs one job at
each of VLEN 128, 256 and 512. Each replays 12 generated traces of 20
operation groups from seed 42, the source-width traces and the directed
state, fractional LMUL, FP, cached DDR, integer comparison, widening and
narrowing integer, fixed-point, single-width FP, whole-register memory,
widening FP, permute, reduction, carry/borrow, mask-register and integer
multiply-add traces. Both
implementations must return every planned trace and instruction. The
VLEN 128 job reuses its simulator to flip one bit in a FROST integer
destination in each control replay. It checks `vmv.x.s` for integer
source widths, fractional LMUL, base FP results, fused multiply-add, FP
conversions, unit-stride memory, strided memory, indexed memory, segment
memory, fault-only-first loads, integer comparisons, widening and
narrowing integer operations, fixed-point operations, single-width FP
operations, whole-register memory, widening FP, permute, reduction,
carry/borrow, mask-register and integer multiply-add operations. It checks
`vcpop.m` for state and scalar results and FP comparisons. TestRIG must
report each destination value mismatch.

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
| [`lrsc_amo.S`](traces/lrsc_amo.S) | AMOs to the first two doublewords of the reserved line cancel the reservation; an AMO to the next line preserves it |
| [`lrsc_jump.S`](traces/lrsc_jump.S) | A JAL, JALR, or taken branch between LR and SC keeps the reservation |
| [`lrsc_older_store.S`](traces/lrsc_older_store.S) | An older store to the other word of the reserved doubleword drains before LR and permits the following SC |
| [`pte_nonleaf_dau.S`](traces/pte_nonleaf_dau.S) | A non-leaf PTE with D, A, or U set raises a page fault |
| [`svpbmt_pbmte.S`](traces/svpbmt_pbmte.S) | PBMTE readback and PBMT page faults; Sail does not check the uncached alias transport or cache coherence |
| [`svnapot_leaf.S`](traces/svnapot_leaf.S) | A 64 KiB NAPOT leaf (N, PPN[3:0] = 1000) translates two of its pages with PPN[3:0] = VA[15:12]; N with another PPN[3:0], in a 2 MiB leaf or in a pointer is a page fault |
| [`ssu64xl_uxl.S`](traces/ssu64xl_uxl.S) | `mstatus.UXL`/`SXL` and `sstatus.UXL` read 2 and keep 2 when written with 3, 0 and 1 (UXLEN is 64) |
| [`ssnpm_pmm.S`](traces/ssnpm_pmm.S) | `senvcfg.PMM` WARL (01 keeps the old value); with MPRV and MPP = U, tagged loads, stores and AMOs under Bare (PMLEN 16 and 7) and Sv39, masked faults with the transformed `mtval`, and no masking with MXR set or PMM = 00 |
| [`sstvala_illegal.S`](traces/sstvala_illegal.S) | Illegal 32-bit and 16-bit instructions write their instruction bits to `mtval` and `stval` |
| [`zawrs_ops.S`](traces/zawrs_ops.S) | `wrs.sto` and `wrs.nto` retire in M, S, and U modes and preserve an active `LR.D` reservation |
| [`zicbom_ops.S`](traces/zicbom_ops.S) | `cbo.clean`, `cbo.flush`, and `cbo.inval` across cached DDR, low BRAM, device windows, and unmapped addresses, with `CBIE`/`CBCFE` WARL checks |
