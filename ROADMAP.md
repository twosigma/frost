# FROST Roadmap

FROST is evolving from its original RV32GCB M/U-mode design into an RV64GCB
core with S-mode and Sv39 that boots mainline MMU Linux, followed by a stock
riscv64 distribution and a multi-hart SMP system. Each phase must preserve the
300 MHz UltraScale+ timing baseline and existing verification coverage.

Phases are sequential and have explicit exit criteria. Optional performance
work must not delay them (see "Standing invariants" and "Optional work").

## Standing invariants (every phase)

- All existing suites stay green: riscv-arch-test, riscv-tests, torture,
  formal, the cocotb program suites in both memory tiers, and the Linux
  boot jobs.
- X3 timing closes at 300 MHz (post-route WNS ≥ 0) at every phase exit.
  Feature branches may regress temporarily; a phase is not done
  until timing is recovered.
- Core RTL stays vendor-primitive-free and passes the Yosys targets.
- Update READMEs, module docs, and registry descriptions with any change that
  makes them stale.

## Phase 0 — Harden the Linux substrate (done)

Until 2026-07-26, no-MMU boot used a post-link kernel mutation (now in
`patch_linux_image.py`) to rewrite the `ret_from_exception` restore window for
a suspected M-mode race. Because S-mode adds xRET restore windows, this needed
resolution before privilege expansion. The investigation showed the mutation
could be retired without an RTL fix:

1. **Done — root cause.** The suspected race does not exist on the
   current core. The restored status image never has MIE set (audited
   every `regs->status` writer in the pinned 6.18.7 tree), delivery
   re-checks the live MIE at fire time, and the commit hold pins the
   interrupt resume PC while a take is armed. The boot hangs the
   mutation fought trace to two since-fixed RTL bugs: the held-interrupt
   latch erasure (`39977c7`) and the AMO orphaned-write (`1ef269e`).
2. **Done — directed regression.** `restore_window_stress` replays the
   kernel's restore-window shape (DDR-draining SC, register-restore
   misses, U/M return variants, WFI idle interludes, AMO-shield
   deferrals) with timer arrival phase-swept across the window, and
   asserts delivery legality (mepc never inside the MIE=0 window, MIE
   always clear at handler entry, every return lands exactly once). It
   also counts held ticks across the window to confirm the mechanism is
   exercised.
3. **Done — mutation retired.** The image flow no longer rewrites the
   kernel (the initramfs fixups and env-gated bring-up hooks in
   `patch_linux_image.py` stay).
4. **Done — unpatched boot proven.** RTL simulation boots the unpatched
   image to the CI checkpoint, and a 10-boot hardware soak on Genesys2
   reached the login prompt 10/10 times through the CLINT clocksource switch,
   where the unpatched kernel formerly hung 33-67% of the time.

5. **Done — userspace boot validation.** The `frost-stress`
   payload (timer storm + signal delivery, vfork/exec context switching,
   futex ping-pong over a `MAP_SHARED` mapping, lock-free LR/SC
   contention) runs from inittab before the getty and prints the
   `FROST_USERSPACE_STRESS_PASS` token. The `linux-boot-qemu` CI job
   asserts the token plus the login prompt, and `fpga/linux_boot_soak.py`
   scores it across repeated hardware boots. The RTL-sim leg
   keeps its bounded 22M-cycle boot-health regression: full userspace is
   ~10^8+ cycles, beyond CI-runner sim throughput; userspace depth on the
   real core comes from the hardware soak.

6. **Done — boot ABI documented.** `linux/README.md`: boot chain and
   entry state, memory map (including the ns16550a face and SiFive CLINT
   alias), DT contract, interrupt/time model, advertised ISA, and the
   load-bearing kernel-config options.

7. **Done — Linux-facing counters.** Zicntr is exposed to userspace through
   `mcounteren` (0x306): WARL CY/TM/IR, reset `0x7` so counters are U-readable
   out of reset. U-mode
   reads trap illegal when a bit is clear — gate checked at the ROB head,
   per-bit coverage in `umode_test`, register proven in the `csr_file`
   formal target. The `frost-stress` payload measures
   `cycles`/`instret`/`time` deltas plus IPC around a fixed workload on
   every boot in its summary line. The hardware soak fails any
   boot whose counter phase degraded (QEMU legitimately degrades:
   it resets `mcounteren` to 0). The 121 custom perf counters stay
   M-mode-only (`mperf*`) — the boot-level evidence later phases need is
   the per-boot cycles/instret/IPC line, not an hpmcounter programming
   model, which remains future work if a real consumer (`perf`) appears
   in Phase 3.

Exit: N consecutive unpatched-kernel boots pass the deepened CI on
Verilator and QEMU, and a hardware boot is demonstrated on at least one
board.

## Phase 1 — RV64 (RV64GCB, still M/U, still no-MMU) (done)

Widen the core to XLEN=64 before changing the privilege architecture, keeping
datapath validation separate and allowing one MMU implementation for Sv39. The
struct plumbing is already XLEN-parameterized (`riscv_pkg`); the FP
regfile and CDB already carry 64-bit values for D. (The phase-entry audit
qualified the rest of that assumption: below the queues the memory tier is
32-bit per transaction — FLD/FSD are two-phase word pairs — so a native
64-bit data tier is in scope, sequenced first and proven under rv32.)

The [Phase 1 plan](docs/rv64/phase1_plan.md) records decisions D1–D15 and
milestones M0–M8. The [XLEN=64 readiness audit](docs/rv64/xlen_audit.md)
contains 365 file:line findings against `9b76e39`, including 106
silent-misbehavior hazards, three independently checked readiness claims, and
tool-behavior experiments.

Scope: RV64I W-instructions and 64-bit shifts/compares/AGU, RV64 M
(64×64 MUL/MULH, 64-bit DIV), RV64 A (LR.D/SC.D/AMO*.D), RV64 F/D
(FCVT.{L,LU} forms, FMV.X.D), RV64C recoding (C.ADDIW/C.LD/C.SD replace
C.JAL/C.FLW/C.FSW), 64-bit CSR file and trap values, decode/imm-gen, and
the fetch/predecode path's C-table changes.

Verification: mirror the rv32 matrices to rv64 (arch-test, riscv-tests,
torture against 64-bit Spike) and add an rv64 no-MMU Buildroot image to
the Linux boot jobs. Whether the rv32 configuration remains a maintained
build or is frozen is decided at phase exit based on what the dual-XLEN
support actually costs in RTL and CI complexity.

Exit: rv64 suites green, rv64 no-MMU Linux boots in CI, X3 timing
re-closed at 300 MHz with the 64-bit datapath.

**Exit met (2026-08-12).** The rv64 matrix (arch-test, riscv-tests,
torture, isa_test, the program suites in both memory tiers) and both
rv64 Linux boot jobs are green in CI; X3 timing closed at 300 MHz with
the 64-bit datapath (final routed WNS +0.003 ns, zero failing endpoints)
after placement-driven changes to the fetch, dispatch-payload, load-queue,
and CDB critical paths. Genesys2 rv32 timing also improved from an accepted
−0.104 ns violation to +0.087 ns. Hardware baselines on both boards are
recorded in `fpga/hw_regression.py` (X3 rv64: 827.32 CoreMark,
131.04 CoreMark-PRO; the classic-CoreMark delta vs the rv32 build is the
documented lp64 ABI effect, `docs/rv64/coremark_lp64_gap.md`). The D9
dual-XLEN decision initially resolved to keep-dual with measured costs,
then was reversed once Genesys2 rv64 timing closed and that configuration
was validated on silicon: both boards now ship RV64GCB and rv32 support
is retired (decision record: `docs/rv64/phase1_plan.md`, D9).

## Phase 2 — Memory-level parallelism (current)

The cached tier serializes one line transaction end-to-end
(`cached_tier_adapter` → line ports → single-beat AXI). That is both a
structural limiter for DDR-resident workloads (the 2nd CDB lane bought
+2.4% CoreMark; a single miss costs far more) and a structural problem for
Phase 3, where hardware page-table walks inject additional loads into the
same fabric and must not queue behind a single-outstanding assumption.

Scope: support multiple outstanding line transactions through the adapter,
arbiter, and AXI bridge (proper AXI IDs or in-order completion tracking);
miss-status handling on the LQ/fetch-provider side; write-combining or at
least store-miss overlap in the L1D path. Sized and validated with the
cache counters below plus CoreMark-Pro deltas; the frost_cache unit bench
and formal targets extend to the new concurrency. For Phase 5, keep
transaction tags hart-parameterized and avoid single-master assumptions in
the MSHR and arbiter; this is inexpensive now and costly to retrofit when the
fabric gains a second master.

The 15 cache counters refine the original scope. On cached-tier CoreMark, L1I
hits 99.7%, L1D hits 98.1%, and cold L2 hits 0.0%
because the working set never outlives L1; instruction-fetch misses stall
the front end on 1.4% of cycles; average miss latency is 43.5 cycles for
L1D and 36.0 for L2. The same binary is 1.79× slower through the cached
tier than from BRAM (307,889 → 551,976 ticks, IPC 0.82 → 0.46, on the
single-iteration profiling build rather than a scoring run) at an almost
unchanged L0 hit rate.

These results narrow the phase: overlapping misses remain a Phase 3
prerequisite because a page-table walk cannot queue behind a single outstanding
request, but misses are too rare for MLP alone to move CoreMark much. The
cached-tier penalty is dominated by the ~6-cycle L1D read-hit
path (`DATA_READ_LATENCY + 3` at the line port, plus the adapter and load
queue), not by miss rate; MicroBlaze V's single-cycle cache read hit is why
it pays nothing for the same move. Shortening the hit path, or widening the
L0's coverage of the cached region, is therefore the higher-value work for
DDR-resident code with small working sets, including OS hot paths. Whether
that belongs in this phase or a separate one is an
open decision; the exit criteria below still only cover MLP.

Exit: ≥2 demand misses in flight demonstrably overlapped, measured
CoreMark-Pro improvement on both boards, timing held, and a written
account of how PTW traffic will slot into the fabric.

## Phase 3 — S-mode, Sv39, and MMU Linux

Scope:

- S-mode CSRs, delegation (medeleg/mideleg), sret, and the mstatus
  fields that become meaningful (SUM, MXR, MPRV, TVM, TSR, TW).
- Sv39: ITLB/DTLB, a hardware page-table walker riding the Phase 2
  fabric, sfence.vma integrated with the existing flush hierarchy, and
  page-fault plumbing through the ROB's precise-exception path.
- Translation placement is PIPT: translate in the LSU/fetch before the
  cached tier (the 128 KiB direct-mapped L1D cannot be virtually indexed
  with 4 KiB pages). The 1-cycle BRAM tier's behavior under translation
  is a phase-entry design decision, as is A/D-bit handling (hardware
  update vs. trap-and-update).
- PLIC for external interrupts; OpenSBI (or a minimal in-tree SBI first)
  as the M-mode firmware layer.
- RISC-V debug module (JTAG DTM + OpenOCD/GDB) early in this phase — it
  is the bring-up tool for everything after it.
- SMP-readiness (see Phase 5): build the PLIC with per-hart×mode contexts
  and the debug module hart-array-aware from the start; OpenSBI's HSM
  extension is the secondary-hart bring-up protocol SMP Linux expects, which
  favors choosing OpenSBI here.

Verification: riscv-tests v-variants, arch-test privilege/VM suites,
torture with paging enabled, directed sfence/TLB-shootdown tests, and
the Phase 0 restore-window test extended to sret.

Exit: mainline rv64 Linux with MMU (Buildroot userspace) boots unpatched
in CI and on hardware, with working `perf` basics.

## Phase 4 — System I/O and distribution

Add Linux I/O, then a stock distribution:

1. Persistent storage: SPI-mode SD controller (Genesys2 has the slot) +
   upstream-driver-compatible programming model, persistent rootfs.
2. Ethernet: RGMII MAC on Genesys2 + Linux driver; NFS/SSH.
3. Stock riscv64 distribution (Debian) from persistent storage — first
   via debootstrap into a ramdisk as a milestone, then from SD,
   with apt and sshd as the acceptance demo, plus a sustained-uptime
   soak.

Exit: log into Debian over SSH on hardware, install a package with apt,
and survive a multi-day soak.

## Phase 5 — SMP (multi-hart)

Replicate the tuned core rather than widening it. Three-wide issue would expand
timing-critical rename, wakeup, and CDB logic for marginal IPC, while apt,
compile jobs, and sshd benefit from thread-level parallelism. With one core,
the X3 uses ~15% of its LUTs; the target is two harts running SMP Debian. The
Genesys2 uses ~69% and remains uniprocessor.

Scope:

- Coherence dominates the phase: the write-back L1Ds join a shared L2 as
  the point of coherence (the lower-cost topology for two harts;
  a private-L1 snoop or directory protocol is the fallback if the shared
  L2 becomes the bottleneck), with LR/SC reservations killed by remote
  invalidations and one global atomicity point for AMOs. This touches
  logic with the richest bug history in the repo (AMO shield,
  orphaned writes, reservation tracking), so it carries a
  Phase-3-sized verification budget by design.
- IPIs via per-hart `msip` and per-hart `mtimecmp` (the CLINT layout is
  already per-hart indexed by address); PLIC contexts per hart×mode and
  a hart-aware debug module arrive prebuilt from Phase 3;
  secondary-hart bring-up over OpenSBI's HSM extension.
- RVWMO becomes a cross-hart obligation: litmus-test suites (herd-style)
  join the verification matrix as a new axis, alongside directed
  cross-hart LR/SC/AMO tests and an SMP extension of the boot-stress
  payload (its futex and LR/SC phases pinned to different harts).

Phase 4 must finish first so uniprocessor Debian provides a bisection baseline
that separates SMP bugs from system bugs. The Phase 2 and 3 SMP-readiness work
avoids later interface retrofits.

Exit: 2-hart SMP Debian on the X3 (both harts online), litmus suites
green, a parallel workload demonstrating meaningful scaling over one
hart, timing held at 300 MHz, and a multi-day SMP soak.

## Deferred work

- **3-wide issue** — widens rename/wakeup/CDB, exactly the structures
  that dominate current timing, for marginal IPC at this window size.
  Revisit only if post-MMU profiling shows issue width limiting real
  workloads.
- **ASIC tape-out** — parked until there is a sponsor, an SRAM story,
  and a physical-design owner; open-PDK shuttles today would clock below
  the FPGA and freeze the rapid-iteration loop.
- **V / H / crypto extensions** — V is a core-sized project and needs
  S-mode context switching for Linux userspace anyway; H needs S-mode
  first; both wait until after Phase 3 and until there is demand.
- **Sv32** — building the MMU once, for Sv39, avoids maintaining a
  second translation format indefinitely.

## Optional work (must not delay phase exits)

- Genesys2 Fmax probe: the 133.33 MHz CPU clock is a chosen MMCM ratio
  (800/6), not a demonstrated ceiling; measure what Kintex-7 actually
  closes.
- Branch-prediction upgrades (bimodal → gshare/TAGE-class) once the
  counters show mispredicts, not misses, dominating a workload that
  matters.
- Slim-configuration feasibility: one bounded experiment (F/D removal,
  smaller queues/caches, single CDB lane) to establish what the core
  costs at minimum spec and whether one parameterized tree can span
  both ends — never a fork.
