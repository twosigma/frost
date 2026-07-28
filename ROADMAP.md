# FROST Roadmap

The long-term goal: evolve FROST from an RV32GCB M/U-mode core into an
RV64GCB core with S-mode and Sv39 virtual memory that boots mainline MMU
Linux — ultimately a stock riscv64 distribution, and then a multi-hart
SMP system running it — while holding the 300 MHz UltraScale+ timing
baseline and the existing verification bar.

Phases are sequential; each has explicit exit criteria. Performance
side-projects are welcome at any point as long as they do not slip a phase
exit (see "Standing invariants" and "Side quests").

## Standing invariants (every phase)

- All existing suites stay green: riscv-arch-test, riscv-tests, torture,
  formal, the cocotb program suites in both memory tiers, and the Linux
  boot jobs.
- X3 timing closes at 300 MHz (post-route WNS ≥ 0) at every phase exit.
  Interim regressions on feature branches are fine; a phase is not done
  until timing is recovered.
- Core RTL stays vendor-primitive-free and passes the Yosys targets.
- Documentation moves with the change that makes it stale — READMEs,
  module docs, registry descriptions — never as a follow-up.

## Phase 0 — Harden the Linux substrate (current)

Until 2026-07-26 the no-MMU boot depended on a post-link binary mutation
of the kernel (in what is now `patch_linux_image.py`) that rewrote the
`ret_from_exception` restore window — a crutch for a suspected M-mode
restore-window race. S-mode multiplies xRET restore windows, so before
any privilege-architecture expansion this class of bug had to be closed
in reviewable form. The investigation resolved it as retirement rather
than an RTL fix:

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
   also counts held ticks crossing the whole window so the mechanism is
   provably exercised, not merely survived.
3. **Done — mutation retired.** The image flow no longer rewrites the
   kernel (the initramfs fixups and env-gated bring-up hooks in
   `patch_linux_image.py` stay).
4. **Done — unpatched boot proven.** RTL simulation boots the unpatched
   image to the CI checkpoint, and a 10-boot hardware soak on Genesys2
   reached the login prompt 10/10 times through the CLINT clocksource
   switch — the point where the unpatched kernel formerly hung 33-67%
   of the time.

5. **Done — userspace-depth boot validation.** The `frost-stress`
   payload (timer storm + signal delivery, vfork/exec context switching,
   futex ping-pong over a `MAP_SHARED` mapping, lock-free LR/SC
   contention) runs from inittab before the getty and prints the
   `FROST_USERSPACE_STRESS_PASS` token. The `linux-boot-qemu` CI job
   asserts the token plus the login prompt, and `fpga/linux_boot_soak.py`
   scores it across repeated hardware boots. The RTL-sim leg deliberately
   keeps its bounded 22M-cycle boot-health regression: full userspace is
   ~10^8+ cycles, beyond CI-runner sim throughput; userspace depth on the
   real core comes from the hardware soak.

6. **Done — boot ABI documented.** `linux/README.md`: boot chain and
   entry state, memory map (including the ns16550a face and SiFive CLINT
   alias), DT contract, interrupt/time model, advertised ISA, and the
   load-bearing kernel-config options.

7. **Done — Linux-facing counters.** The Zicntr counters became a real,
   spec-shaped userspace surface: `mcounteren` (0x306) now exists (WARL
   CY/TM/IR, reset `0x7` so counters are U-readable out of reset; U-mode
   reads trap illegal when a bit is clear — gate checked at the ROB head,
   per-bit coverage in `umode_test`, register proven in the `csr_file`
   formal target), and the `frost-stress` payload measures
   `cycles`/`instret`/`time` deltas plus IPC around a fixed workload on
   every boot, folded into its summary line. The hardware soak fails any
   boot whose counter phase degraded (QEMU legitimately degrades:
   it resets `mcounteren` to 0). The 121 custom perf counters stay
   M-mode-only (`mperf*`) — the boot-level evidence later phases need is
   the per-boot cycles/instret/IPC line, not an hpmcounter programming
   model, which remains future work if a real consumer (`perf`) appears
   in Phase 3.

Exit: N consecutive unpatched-kernel boots pass the deepened CI on
Verilator and QEMU, and a hardware boot is demonstrated on at least one
board.

## Phase 1 — RV64 (RV64GCB, still M/U, still no-MMU)

Widen the core to XLEN=64 before touching the privilege architecture, so
the datapath disruption is validated while the environment is still
one-dimensional, and so the MMU is built once, directly for Sv39. The
struct plumbing is already XLEN-parameterized (`riscv_pkg`); the FP
regfile, LQ/SQ data paths, and CDB already carry 64-bit values for D.

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

## Phase 2 — Memory-level parallelism

The cached tier currently serializes one line transaction end-to-end
(`cached_tier_adapter` → line ports → single-beat AXI). That is both a
structural limiter for DDR-resident workloads (the 2nd CDB lane bought
+2.4% CoreMark; a single miss costs far more) and a structural problem for
Phase 3, where hardware page-table walks inject additional loads into the
same fabric and must not queue behind a single-outstanding assumption.

Scope: multiple outstanding line transactions through the adapter,
arbiter, and AXI bridge (proper AXI IDs or in-order completion tracking);
miss-status handling on the LQ/fetch-provider side; write-combining or at
least store-miss overlap in the L1D path. Sized and validated with the
cache counters below plus CoreMark-Pro deltas; the frost_cache unit bench
and formal targets extend to the new concurrency. SMP-readiness (see
Phase 5): keep transaction tagging hart-parameterized and the MSHR /
arbiter design free of single-master assumptions — this fabric gains a
second master later, and that property is near-free now but expensive to
retrofit.

What the 15 cache counters now measure directly (they postdate the first
draft of this phase, so the framing above was written blind). On the
cached-tier CoreMark run: L1I hits 99.7%, L1D hits 98.1%, L2 cold at 0.0%
because the working set never outlives L1; instruction-fetch misses stall
the front end on 1.4% of cycles; average miss latency is 43.5 cycles for
L1D and 36.0 for L2. The same binary is 1.79× slower through the cached
tier than from BRAM (307,889 → 551,976 ticks, IPC 0.82 → 0.46, on the
single-iteration profiling build rather than a scoring run) at an almost
unchanged L0 hit rate.

That measurement narrows this phase rather than confirming it. Overlapping
misses is still a Phase 3 prerequisite — a page-table walk must not queue
behind a single-outstanding assumption, and that argument stands on its own
— but misses are too rare on this workload for MLP alone to move CoreMark
much. The cached-tier penalty is dominated by the ~6-cycle L1D read-hit
path (`DATA_READ_LATENCY + 3` at the line port, plus the adapter and load
queue), not by miss rate; MicroBlaze V's single-cycle cache read hit is why
it pays nothing for the same move. Shortening the hit path, or widening the
L0's coverage of the cached region, is therefore the higher-value work for
DDR-resident code with small working sets — which is what an OS hot path
looks like. Whether that becomes part of this phase or a separate one is an
open decision; the exit criteria below still only cover MLP.

Exit: ≥2 demand misses in flight demonstrably overlapped, measured
CoreMark-Pro improvement on both boards, timing held, and a written
account of how PTW traffic will slot into the fabric.

## Phase 3 — S-mode, Sv39, and MMU Linux

The big one. Scope:

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
  extension is the secondary-hart bring-up protocol SMP Linux expects, so
  choosing OpenSBI here prepays that too.

Verification: riscv-tests v-variants, arch-test privilege/VM suites,
torture with paging enabled, directed sfence/TLB-shootdown tests, and
the Phase 0 restore-window test extended to sret.

Exit: mainline rv64 Linux with MMU (Buildroot userspace) boots unpatched
in CI and on hardware, with working `perf` basics.

## Phase 4 — A real computer

I/O to make the Linux system genuinely usable, then the distro:

1. Persistent storage: SPI-mode SD controller (Genesys2 has the slot) +
   upstream-driver-compatible programming model, persistent rootfs.
2. Ethernet: RGMII MAC on Genesys2 + Linux driver; NFS/SSH.
3. Stock riscv64 distribution (Debian) from persistent storage — first
   via debootstrap into a ramdisk as a milestone, then for real from SD,
   with apt and sshd as the acceptance demo, plus a sustained-uptime
   soak.

Exit: log into Debian over SSH on hardware, install a package with apt,
and survive a multi-day soak.

## Phase 5 — SMP (multi-hart)

Replicate the tuned core rather than widen it: the same profiling logic
that parks 3-wide issue (rename/wakeup/CDB are the timing-critical
structures, for marginal IPC) argues for thread-level parallelism as the
next throughput lever once the system is I/O-complete — apt, compile
jobs, and sshd sessions are throughput workloads, and the X3 sits at
~15% LUT utilization with one core. Target: 2 harts on the X3, SMP
Debian. (The Genesys2 at ~69% cannot fit a second core; it stays
uniprocessor.)

Scope:

- Coherence **is** the phase: the write-back L1Ds join a shared L2 as
  the point of coherence (the cheaper credible topology for two harts;
  a private-L1 snoop or directory protocol is the fallback if the shared
  L2 becomes the bottleneck), with LR/SC reservations killed by remote
  invalidations and one global atomicity point for AMOs. This touches
  the machinery with the richest bug history in the repo (AMO shield,
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

Entered only after the Phase 4 exit, deliberately: a rock-solid
uniprocessor Debian is the bisection baseline that keeps "SMP bug" and
"system bug" distinguishable, and SMP is the upgrade the finished system
actually feels. The groundwork is prepaid in the SMP-readiness notes in
Phases 2 and 3 because those interfaces are near-free to parameterize at
design time and expensive to retrofit.

Exit: 2-hart SMP Debian on the X3 (both harts online), litmus suites
green, a parallel workload demonstrating meaningful scaling over one
hart, timing held at 300 MHz, and a multi-day SMP soak.

## Deliberate non-goals (for now)

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

## Side quests (allowed anytime, must not slip phase exits)

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
