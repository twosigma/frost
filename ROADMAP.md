# FROST Roadmap

FROST is evolving from its original RV32GCB M/U-mode design into an RV64GCB
core with S-mode and Sv39 that boots mainline MMU Linux, followed by a stock
riscv64 distribution and a multi-hart SMP system. Phases are sequential; each
one keeps every existing suite green (riscv-arch-test, riscv-tests, torture,
formal, the cocotb program suites in both memory tiers, the Linux boot jobs),
re-closes X3 timing at 300 MHz post-route before it is called done, keeps the
core RTL vendor-primitive-free, and updates the documentation it makes stale.

## Phase 0 — Harden the Linux substrate (done)

Retire the post-link kernel mutation the no-MMU boot relied on, prove the
unpatched kernel boots in simulation and on hardware, add a userspace stress
payload to the boot jobs, document the boot ABI, and expose Zicntr to
userspace through `mcounteren`.

## Phase 1 — RV64GCB (done)

Widen the core to XLEN=64 (still M/U, still no-MMU) before changing the
privilege architecture, so the MMU is built once for Sv39: a native 64-bit
data tier, RV64 I/M/A/F/D/C, 64-bit CSRs and traps, the rv64 test matrices
and an rv64 no-MMU Linux image in CI. Exit met 2026-08-12 with X3 timing
closed at 300 MHz; rv32 support was retired once both boards ran rv64.

## Phase 2 — Memory-level parallelism (current)

The cached tier serializes one line transaction end-to-end, which limits
DDR-resident workloads and cannot host the Phase 3 page-table walker. Scope:
tagged line transactions with several outstanding through the adapter,
arbiter and AXI bridge; a non-blocking cache (hit-under-miss,
miss-under-miss, store-miss overlap) at every level; several cached loads in
flight at the load queue and several line fills at the fetch provider;
transaction tags parameterized so a walker or a second hart is one more port.
Exit: at least two demand misses measurably overlapped, a measured
CoreMark-Pro improvement on both boards, timing held, and a written account
of how page-table-walk traffic enters the fabric.

## Phase 3 — S-mode, Sv39, and MMU Linux

S-mode CSRs and delegation, Sv39 with ITLB/DTLB and a hardware page-table
walker, PIPT translation ahead of the cached tier, PLIC, OpenSBI as the
M-mode firmware, and a RISC-V debug module early in the phase. Verification
adds the privilege/VM suites, torture with paging, and directed TLB tests.
Exit: mainline rv64 MMU Linux (Buildroot userspace) boots unpatched in CI and
on hardware, with working `perf` basics.

## Phase 4 — System I/O and distribution

SD storage, Ethernet, and a stock riscv64 Debian from persistent storage.
Exit: log into Debian over SSH on hardware, install a package with apt, and
survive a multi-day soak.

## Phase 5 — SMP

Two harts on the X3 sharing an L2 as the point of coherence, IPIs, per-hart
PLIC contexts, and litmus-test coverage of RVWMO across harts. Exit: 2-hart
SMP Debian with measurable scaling, timing held, and a multi-day soak.

## Deferred

3-wide issue, an ASIC tape-out, the V/H/crypto extensions, and Sv32 are
deliberately out of scope until the phases above are complete and there is
demand for them.
