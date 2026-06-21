# Fresh handoff - FROST no-MMU Linux boot on Genesys2

Last updated by Codex: 2026-06-21. Latest hardware run described here was on
2026-06-20. This file is meant to be self-contained for a fresh agent.

## Mission

Boot no-MMU M-mode Linux on real Genesys2 hardware with the FROST RV32 out-of-order
core. Do not treat this as only a single bug fix. The larger goal is real hardware
Linux bring-up.

Current state (updated 2026-06-21 by Claude): the `0x80388bba` panic root cause is
now PROVEN in directed simulation and FIXED in RTL. The fix is verified in sim but
NOT yet on hardware. The next step is a Genesys2 bitstream rebuild with the
`cpu_ooo.sv` change and a hardware Linux boot re-test. See
"## RESOLVED 2026-06-21: stale interrupt_resume_pc across MRET-to-U (proven + fixed)"
below for the full proof, the one-line-class RTL fix, and the new directed test.

## RESOLVED 2026-06-21: stale interrupt_resume_pc across MRET-to-U (proven + fixed)

### Proven root cause

An MRET that returns below M-mode retires through the trap/MRET **full flush**, NOT
through the normal commit path:

- `o_mret_taken` asserts combinationally on the `o_mret_start` cycle (call it T).
- One cycle later (T+1) `mret_taken_reg` is high, and `misprediction_flush_controller`
  drives `flush_all` combinationally from it. `flush_all` wipes the ROB head and gates
  `commit_en` (reorder_buffer.sv), so the MRET is squashed and **never appears on
  `rob_commit_valid_raw`**.
- `interrupt_resume_pc` (cpu_ooo.sv) only updates on a valid ROB commit, so the MRET
  never refreshes it. It keeps the architectural next-PC of the instruction *before*
  the MRET — which equals the MRET instruction's own PC (in Linux, the `c.lwsp
  sp,8(sp)` at `0x80388bb8` makes that exactly `0x80388bba`).
- `trap_unit` only inhibits interrupts at T and T+1 (`i_mret_start || mret_taken_prev`).
  From T+3 onward (priv = U, inhibit dropped, registered timer re-eligible) until the
  first post-MRET instruction commits, a machine timer is taken and saves
  `mepc = interrupt_resume_pc = <MRET PC>`.
- Linux later restores that trap frame and `mret`s to the kernel MRET PC while in
  U-mode → illegal instruction (signal 4) → "Attempted to kill init".

This was confirmed two ways: independent static trace across
rob_serializer / reorder_buffer / misprediction_flush_controller / trap_unit / csr_file,
and a directed cocotb sim (below). The kernel disassembly was verified: runtime
`0x80388bba` is `mret` (0x30200073) at `ret_from_exception+0x76`, preceded by a 2-byte
non-branch `c.lwsp sp,8(sp)` — so `interrupt_resume_pc == 0x80388bba` pre-MRET is
legitimate, and `ret_from_exception` is the unified (U and M) return path.

### Directed test (new)

`sw/apps/mret_timer_resume_test/` (registered in `tests/test_run_cocotb.py`). It is a
focused variant of `umode_test`'s timer-preempts-U case: it makes the machine timer
*already pending* (`mtimecmp = 0`) before an MRET-to-U, and the naked M-mode handler
additionally records `mepc`. It asserts the saved resume PC is the U-mode target
(`&u_spin`), never the MRET's own PC.

Run it the standard way (`frost/tests`, `make clean`, `./test_run_cocotb.py
mret_timer_resume_test`). At low addresses the analog of `0x80388bba` is the inlined
`run_in_umode_pending_timer` MRET at `0x1c6`; the correct resume PC is `u_spin` at
`0xea`.

- BEFORE fix: `cause=0x80000007 from_priv=0x0 resume_mepc=0x000001C6` → `<<FAIL>>`
  (the bug: mepc = MRET PC).
- AFTER fix:  `cause=0x80000007 from_priv=0x0 resume_mepc=0x000000EA` → `<<PASS>>`.

The `FROST_DBG ... TRAP` probe shows the same timer trap (cycle 1095000) flipping
`resume_pc` from the stale `1c6` to `ea`, while the live `rob_pc` stays `1c6` — i.e.
the resume PC is now correctly decoupled from the squashed MRET head.

### The fix (RTL)

`hw/rtl/cpu_and_mem/cpu/cpu_ooo/cpu_ooo.sv`, the `interrupt_resume_pc` always_ff: add a
highest-priority branch that seeds it from the MRET target the cycle `mret_taken`
fires, so the U-target is in place before the inhibit window closes:

```systemverilog
end else if (mret_taken) begin
  interrupt_resume_pc <= csr_mepc;   // MRET retires via flush, never via commit;
                                     // seed the resume PC from the MRET target now
end else if (rob_commit_2_valid_raw) begin
  ...
```

`csr_mepc` is stable at that cycle (MRET does not write mepc; a trap entry that would
cannot coincide with `mret_taken`), and it equals the MRET redirect target. No
regression to the normal precise-interrupt-resume path: for non-MRET interrupts and
the WFI/empty-ROB case the commit branches are unchanged; nothing commits on the
`mret_taken` cycle (serializer has `commit_stall=1`), so the new branch never steals a
real commit's update. It is a narrow 1-bit select on a non-critical register (feeds
only `trap_unit.i_interrupt_pc`), so it should be timing-benign.

### Next step (hardware)

Rebuild the Genesys2 bitstream with this `cpu_ooo.sv` change and re-run the hardware
Linux boot (`python3 /tmp/linux_boot_watch.py`). The `0x80388bba` user-mode-MRET
illegal-instruction panic should no longer occur. If a new/different failure appears,
treat it as a fresh symptom — this specific stale-resume-PC mechanism is now closed.

## Environment

FROST repo:

```text
/home/adam-bagley/bigger_l0/frost
```

Relevant external Linux tree:

```text
/home/adam-bagley/bigger_l0/linux-mvp/buildroot/output/build/linux-6.18.7
```

Hardware:

- Genesys2 / Kintex-7.
- UART is `/dev/ttyUSB0`, 115200 8N1.
- The user programs FPGA bitstreams manually and tells the agent when the FPGA is ready.
- Use the boot-watch script rather than minicom for capture.

Hardware boot command:

```sh
python3 /tmp/linux_boot_watch.py
```

Latest synchronized UART log:

```text
/tmp/genesys2_linux_boot_synchronized.log
```

The worktree is dirty and contains intentional changes plus unrelated older bring-up
changes. Do not revert wholesale. Start with `git status --short` and inspect before
editing.

## Latest hardware result

The user programmed a Genesys2 bitstream containing the newest `trap_unit.sv` changes
and the current `cpu_ooo.sv` interrupt-resume plumbing. Running:

```sh
python3 /tmp/linux_boot_watch.py
```

rebuilt and loaded `sw/apps/linux_boot`, patched the local DDR image, loaded the FPGA,
and captured UART. The boot got past the original `_find_next_bit` / `ra=0xcc0`
panic and reached later initcall/pty territory, but still died:

```text
[    0.847064] swapper/0[1]: unhandled signal 4 code 0x1 at 0x80388bba
...
[    1.095342] Kernel panic - not syncing: Attempted to kill init! exitcode=0x00000004
...
[<80388bba>] ret_from_exception+0x76/0x7a
```

`0x80388bba` is Linux `ret_from_exception`'s final `mret` instruction:

```text
00388b74: csrw mepc,a2
...
00388bb8: lw   sp,8(sp)
00388bba: mret
```

The current bad symptom is therefore: user context eventually tries to execute the
kernel's `mret` instruction at `0x80388bba`, which is illegal outside M-mode.

## Important image-patch detail

`sw/apps/linux_boot/patch_ret_from_exception.py` patches the local FPGA-loadable DDR
image after copying from external Linux artifacts:

```text
word 0xe22dc: 18c1202f -> ff757513
```

The patch applies to:

```text
sw/apps/linux_boot/sw_ddr.mem
sw/apps/linux_boot/sw_ddr.txt
```

Do not use `vmlinux` objdump alone to decide whether the image was patched. The
external `vmlinux` and `linux-mvp/frost-artifacts/sw_ddr.txt` remain unpatched. The
loaded local dense image was patched in the latest run. Current verification command:

```sh
rg -n "18c1202f|ff757513" sw/apps/linux_boot/sw_ddr.txt \
  /home/adam-bagley/bigger_l0/linux-mvp/frost-artifacts/sw_ddr.txt
```

Expected current output:

```text
sw/apps/linux_boot/sw_ddr.txt:926429:ff757513
/home/adam-bagley/bigger_l0/linux-mvp/frost-artifacts/sw_ddr.txt:926429:18c1202f
```

## What is already fixed or ruled out

### 1. Original `_find_next_bit` / `ra=0xcc0` panic

Original hardware failure:

```text
FROST_IRQ_ENTER epc=801657ae ra=80094556 sp=804c3e40 cause=80000007 slot12=00000cc0
FROST_IRQ_RETURN epc=801657ae ra=80094556

Oops - illegal instruction
epc : 00000cc0
ra  : 00000cc0
sp  : 804c3e50
```

The UART probe proved the trap frame itself still had sane `epc`/`ra`; the interrupted
callee's own saved return-address slot at `12(sp)` was already stale `0x00000cc0` at
IRQ entry. That pointed to a lost stack store, not trap-frame corruption.

Root cause found: a same-cycle slot-2 store-like ROB commit could be missed by the
store queue's committed-empty guard during a full trap flush. `store_queue.sv` had
raw guard ports for a second commit slot, but `tomasulo_wrapper.sv` had tied them off.
This could let a timer IRQ full-flush while slot 2's store commit was still one cycle
away from the SQ; the registered commit then got masked, losing stores like
`sw ra,12(sp)`.

Fixes/checks now present in the worktree:

- `hw/rtl/cpu_and_mem/cpu/tomasulo/tomasulo_wrapper/tomasulo_wrapper.sv`
  connects raw slot-2 store-like commit information into the SQ guard.
- `hw/rtl/cpu_and_mem/cpu/cpu_ooo/cpu_ooo.sv` computes
  `sq_committed_empty_for_trap = sq_committed_empty && !rob_commit_store_like_raw &&
  !rob_commit_2_store_like_raw`.
- Directed tests were added for the Linux IRQ stack slot and the wrapper slot-2 guard.

After these changes, the old `_find_next_bit` / `slot12=0xcc0` signature did not
reproduce in the next hardware runs. Treat it as fixed unless it reappears.

### 2. MRET/interrupt race at `ret_from_exception::mret`

After the slot-2 store fix, a hardware run failed with a cleaner signature:

```text
FROST_IRQ_ENTER epc=80388bba ra=80094556 sp=804c3dc0 cause=80000007
FROST_IRQ_RETURN epc=80388bba ra=80094556
swapper/0[0]: unhandled signal 4 code 0x1 at 0x80388bba
```

This showed a timer IRQ could be taken with `mepc` equal to the M-mode `mret`
instruction itself.

Fixes/checks now present in `hw/rtl/cpu_and_mem/cpu/control/trap_unit.sv`:

- one-cycle `mret_taken_prev` recovery marker,
- interrupt latch inhibited/cleared during `i_mret_start || mret_taken_prev`,
- registered pending interrupts re-qualified against current CSR interrupt
  eligibility,
- registered pending interrupt loses to MRET during the MRET recovery window,
- interrupt trap PC comes from `i_interrupt_pc`, not raw live ROB trap PC.

These changes improved or changed the failure mode, but they did not finish the boot.
Latest hardware still reaches a user illegal instruction at `0x80388bba`.

### 3. CSR privilege write theory

Checked `hw/rtl/cpu_and_mem/cpu/csr/csr_file.sv`: plain `csrw mstatus` updates
`mstatus_mpp` and related fields but does not change current privilege `priv_q`.
`priv_q` changes on trap entry and actual `i_mret_taken`.

So the tempting explanation "Linux writes `mstatus.MPP=U` before `mret`, therefore
trap_unit already thinks it is in U-mode" does not match the CSR implementation.

### 4. UART drops

The apparent UART output drops were caused by a stale capture process. The user
confirmed the drops disappeared after killing that process. Do not chase UART output
drops as an RTL issue unless a new independent symptom appears.

## Current RTL areas to read first

`hw/rtl/cpu_and_mem/cpu/cpu_ooo/cpu_ooo.sv`

```systemverilog
logic [XLEN-1:0] interrupt_resume_pc;

function automatic logic [XLEN-1:0] retired_next_pc(
    input riscv_pkg::reorder_buffer_commit_t commit
);
  logic [XLEN-1:0] step;
  begin
    step = commit.is_compressed ? {{(XLEN - 2){1'b0}}, 2'b10} :
                                  {{(XLEN - 3){1'b0}}, 3'b100};
    if (commit.is_branch || commit.is_mret) begin
      retired_next_pc = commit.redirect_pc;
    end else begin
      retired_next_pc = commit.pc + step;
    end
  end
endfunction

always_ff @(posedge i_clk) begin
  if (i_rst) begin
    interrupt_resume_pc <= '0;
  end else if (rob_commit_2_valid_raw) begin
    interrupt_resume_pc <= retired_next_pc(rob_commit_comb_2);
  end else if (rob_commit_valid_raw) begin
    interrupt_resume_pc <= retired_next_pc(rob_commit_comb);
  end
end
```

`trap_unit` saves this as `mepc` for interrupts:

```systemverilog
o_trap_pc = i_interrupt_pc;
```

`hw/rtl/cpu_and_mem/cpu/tomasulo/reorder_buffer/reorder_buffer.sv` should also be
read around MRET commit handling. It currently sets MRET commit `redirect_pc` from
`i_mepc`.

## Current best hypothesis, not proven

The next thing to prove or disprove is whether `interrupt_resume_pc` can be stale or
wrong around an MRET return to U-mode.

Possible bad sequence:

1. Linux returns to user through `ret_from_exception`.
2. MRET redirect targets the user PC, but `interrupt_resume_pc` is still or becomes
   `0x80388bba`, the M-mode `mret` instruction address.
3. A machine timer interrupt becomes eligible just after return below M. This is legal:
   machine interrupts can preempt U-mode even when `mstatus.MIE` is 0.
4. Trap entry saves `mepc = i_interrupt_pc = 0x80388bba`.
5. Linux later restores that trap frame and executes `mret` to `0x80388bba` as user
   context.
6. U-mode executing MRET raises illegal instruction at `0x80388bba`.

This fits the latest user-visible failure, but it is still only a hypothesis. The
critical question is: what exact value is on `i_interrupt_pc` when the timer trap that
eventually leads to the `0x80388bba` signal is taken?

## Recommended next step

Do a directed simulation before any more hardware rebuilds.

Add or extend a small app, likely `sw/apps/umode_test/main.c` or a new
`sw/apps/mret_timer_resume_test/main.c`, to exercise:

1. M-mode sets `mtvec` to a handler that records `mcause`, `mepc`, `mstatus`, and a
   small progress marker.
2. M-mode sets up a U-mode return target label in `mepc`.
3. M-mode sets `mstatus.MPP=U` and enables the machine timer interrupt in `mie`.
4. Arrange a timer pending condition before MRET and/or immediately after MRET.
5. Execute MRET.
6. In the trap handler, assert:
   - `mcause == 0x80000007`,
   - previous privilege was U,
   - saved `mepc` is the U-mode target or U-mode fallthrough,
   - saved `mepc` is never the M-mode MRET instruction PC.

Add temporary cocotb visibility/assertions around:

- `mret_start`,
- `mret_taken`,
- `mret_taken_reg`,
- `csr_mepc`,
- `csr_priv`,
- `rob_commit_comb.valid`,
- `rob_commit_comb.is_mret`,
- `rob_commit_comb.pc`,
- `rob_commit_comb.redirect_pc`,
- `rob_commit_2_*` equivalents,
- `interrupt_resume_pc`,
- `trap_taken`,
- `trap_pc_internal`.

If the directed sim reproduces the bad `mepc`, the likely RTL fix is in
`cpu_ooo.sv`: seed or hold `interrupt_resume_pc` from the MRET target (`csr_mepc` /
MRET `redirect_pc`) across the MRET recovery window, and prevent MRET/invalid/old ROB
state from leaving it at the M-mode MRET PC. Do not apply that blindly; prove the
failure first.

If the directed sim does not reproduce, add better Linux restore-path instrumentation
before another bitstream:

- print a compact `FROST_RET_RESTORE` line immediately before `csrw mstatus`,
  `csrw mepc`, and `mret`,
- include `PT_EPC`, `PT_STATUS`, live `mstatus`, live `mepc`, and maybe `PT_RA`.

The Linux tree already has temporary raw UART probes in
`arch/riscv/kernel/entry.S` for `FROST_IRQ_ENTER`, `FROST_IRQ_RETURN`, and
`FROST_BAD_RET`, but it does not currently print every normal restore state.

## Tests that passed recently

```sh
./tests/test_run_cocotb.py trap_unit
COCOTB_NUM_RUNS=1 ./tests/test_run_cocotb.py umode_test
env FROST_IRQ_PRECISION_CHECK=1 FROST_IRQ_LOW_RA_ASSERT=1 \
  FROST_EXTERNAL_IRQ_SYMBOL=irq_find_next_bit_exact_callee \
  FROST_EXTERNAL_IRQ_OFFSET=0x52 FROST_EXTERNAL_IRQ_MAX_PULSES=1 \
  FROST_IRQ_CALLEE_SYMBOL=irq_find_next_bit_exact_callee \
  FROST_IRQ_PRECISION_EVENT_LIMIT=16 COCOTB_NUM_RUNS=1 \
  ./tests/test_run_cocotb.py linux_irq_find_next_slot_test
COCOTB_NUM_RUNS=1 ./tests/test_run_cocotb.py wfi_mepc_test
python3 -m py_compile sw/apps/linux_boot/patch_ret_from_exception.py
make -C sw/apps/linux_boot
```

Earlier slot-store regressions that passed:

```sh
env COCOTB_NUM_RUNS=1 ./tests/test_run_cocotb.py linux_irq_stack_slot_test
env COCOTB_NUM_RUNS=1 ./tests/test_run_cocotb.py linux_irq_active_ddr_test
env COCOTB_NUM_RUNS=1 ./tests/test_run_cocotb.py linux_irq_ddr_test
./tests/test_run_cocotb.py tomasulo_wrapper --testcase test_slot2_store_raw_commit_blocks_sq_committed_empty
./tests/test_run_cocotb.py tomasulo_wrapper --random-seed 1781982550
```

## Current dirty files that matter

At the time of this handoff, relevant intentional edits include:

- `hw/rtl/cpu_and_mem/cpu/control/trap_unit.sv`
- `hw/rtl/cpu_and_mem/cpu/cpu_ooo/cpu_ooo.sv`
- `hw/rtl/cpu_and_mem/cpu/tomasulo/tomasulo_wrapper/tomasulo_wrapper.sv`
- `sw/apps/linux_boot/Makefile`
- `sw/apps/linux_boot/patch_ret_from_exception.py`
- `tests/Makefile`
- `tests/test_run_cocotb.py`
- `verif/cocotb_tests/control/test_trap_unit.py`
- `verif/cocotb_tests/test_real_program.py`
- `verif/cocotb_tests/tomasulo/tomasulo_wrapper/test_tomasulo_wrapper.py`
- `verif/cocotb_tests/tomasulo/tomasulo_wrapper/tomasulo_interface.py`
- `sw/apps/linux_irq_stack_slot_test/`
- `sw/apps/linux_irq_active_ddr_test/`
- `sw/apps/linux_irq_ddr_test/`
- `sw/apps/linux_irq_find_next_slot_test/`
- `sw/apps/wfi_mepc_test/`

There are also unrelated dirty/untracked files in the worktree. Inspect before
touching and do not clean the tree unless the user explicitly asks.

## Timing caution

The user reported that recent RTL instrumentation made post-opt timing worse, although
one later implementation recovered during placement and closed. If more synthesizable
instrumentation is needed, keep it narrow: a few registered values or counters, no wide
debug muxes on already bad paths. Prefer directed simulation and Linux UART probes
before adding more FPGA-visible RTL debug.

## How to inspect the latest hardware log

Useful command:

```sh
rg -a -n "80388bba|80388bb|ret_from_exception|unhandled signal|Kernel panic|FROST_IRQ_(ENTER|RETURN)|FROST_BAD_RET|FROST_RET" \
  /tmp/genesys2_linux_boot_synchronized.log
```

Expected important lines include:

```text
[    0.847064] swapper/0[1]: unhandled signal 4 code 0x1 at 0x80388bba
[    1.095342] Kernel panic - not syncing: Attempted to kill init! exitcode=0x00000004
[<80388bba>] ret_from_exception+0x76/0x7a
```

Some UART around the recursive failure is garbled. Treat garbled `FROST_IRQ_ENTER`-like
lines as hints only; rely on clean kernel lines and directed sim for proof.

## Claude starting checklist

1. Read this file fully.
2. Run `git status --short`.
3. Read `cpu_ooo.sv` around `interrupt_resume_pc` and `trap_unit` instantiation.
4. Read `trap_unit.sv` around interrupt registration, MRET inhibit, and `o_trap_pc`.
5. Read ROB MRET commit/redirect handling.
6. Build the directed MRET-to-U plus timer-pending sim.
7. Only after the sim proves or disproves the current hypothesis, decide whether to
   patch RTL, add Linux restore instrumentation, or ask the user for another bitstream.

## UPDATE 2026-06-21 (Claude): boots to userspace; one flaky RTL race remains

The `0x80388bba` panic is fixed (RTL, committed: `718f8cc` + productionization
`3d7766c` + rebuild-robust patch `21d5af7`). Since then the bring-up went much
further on real Genesys2 hardware. Current state below.

### Kernel boots fully to the userspace handoff

No-MMU Linux 6.18.7 boots cleanly reset -> console (`ttyS0` 16550A) -> initramfs
-> `Run /sbin/init` at ~2.8s, clean log. The unpatched-kernel test proved the
hardware `interrupt_resume_pc` fix is the real cure for the U-mode MRET panic
(the `patch_ret_from_exception.py` MIE-clear is a *separate* partial mitigation
for the M-mode variant; see below).

### Userspace execution is PROVEN working

Built minimal bFLT test inits with the Buildroot toolchain
(`riscv32-buildroot-linux-uclibc-gcc -O2 -Wl,-elf2flt=-r`; no-MMU userspace is
bFLT `ram gotpic`, NOT plain ELF/FDPIC) and ran them as `/sbin/init`:
- single process `write()` + spin -> prints `USERSPACE_OK`.
- `vfork`+`exec` of a child, child + parent both run -> all markers.
- `vfork`+`exec`+child `_exit`+parent `waitpid` -> all markers, child reaped.

So U-mode execution, the `ecall` syscall round-trip, process creation, child
MRET-to-U, exit and reap all work. FROST hardware is solid for Linux userspace.

### Blocker 1 (software, root-caused): BusyBox bFLT stack + RAM

- `init: out of mem` -> BusyBox's bFLT stack/heap was only `0x3e80` (16 KiB),
  too small for no-MMU. `flthdr -s 0x100000 bin/busybox` clears it. PROPER FIX:
  set the FLAT stack size in Buildroot (covers all applets, which are symlinks
  to the one busybox binary).
- 16 MiB RAM was a temp sim-speed shrink; reverted `MEM_SIZE` to 64 MiB in
  `linux-mvp/frost-artifacts/build_fpga_boot.py`. (Memory size does NOT affect
  the flaky hang below.)

### Blocker 2 (RTL, isolated, NOT yet fixed): residual M-mode timer race

After Blocker 1, the late-kernel boot is intermittently hung (~33-67% of boots),
non-deterministic, at varying points in the timer-active region — frequently at
the exact `[0.14] clocksource: Switched to clocksource clint_clocksource` where
the UNPATCHED kernel hung 100% deterministically. Cheap isolation proved it is:
- NOT memory size: 2/6 flaky at both 32 and 64 MiB.
- NOT DDR / board state: 4/6 flaky on a freshly reprogrammed bitstream.
- => a residual machine-timer-interrupt trap-return race. The U-mode RTL fix +
  the MIE-clear patch reduced it from deterministic to flaky but did not close
  it. This is the "proper M-mode-window fix" that was deferred — the real
  reliability blocker, back in FROST-RTL territory.

NEXT STEP: directed sim of an M-mode machine-timer interrupt taken through the
`ret_from_exception` restore / MRET path (sweep the timer-injection cycle to hit
the bad window, like the original IRQ-precision tests), find the residual race,
fix in RTL, re-verify on hardware (re-run the 6-boot flaky-rate measurement,
expect 0 hangs).

### Operational notes for the next agent

- Program the FPGA yourself: `./fpga/program_bitstream/program_bitstream.py
  genesys2` (no need to ask the user). Reprogram to reset board state.
- Hardware boot/reload: `python3 /tmp/linux_boot_watch.py` (loads the patched
  image over JTAG via `load_software.py`; no bitstream reprogram needed for
  software/kernel changes). It now also breaks on `Run /sbin/init` / `out of
  mem` with a 30s post-load window — handy for fast flaky-rate loops (see
  `/tmp/flaky_iso.sh`).
- Kernel rebuild: edit `linux-mvp/.../linux-6.18.7/arch/riscv/kernel/entry.S`
  then `make -C linux-mvp/buildroot linux-rebuild`; the FROST IRQ debug probes
  and the false-triggering `FROST_BAD_RET` canary (it tripped on the legitimate
  `RA=0` at first return-to-userspace) are already removed.
- `patch_ret_from_exception.py` now locates its target by unique machine-code
  word (survives kernel rebuilds). It is STILL REQUIRED until the M-mode race is
  fixed; drop it after.

### M-mode race hunt status (in progress)

Reproduction approach scoped; race not yet reproduced in sim:
- Full `linux_boot` in Verilator is NOT viable: it is DDR-latency-bound, so 25M
  cycles only reached the early pre-timer `[0.000000] SLUB` line. Reaching the
  clocksource switch (~18.6M *instructions*) would take hundreds of millions of
  cycles / many hours. Don't retry full-kernel sim for this.
- New synthetic reproducer `sw/apps/mtimer_stress/` (registered; run from
  `frost/tests` with `COCOTB_MAX_CYCLES=3000000`): M-mode loop preempted by a
  frequent machine timer with the period swept (mtime + 24..87) each tick to hit
  every cycle offset around the MRET. It PASSES (survived 9851 IRQs) -> does NOT
  reproduce the race. The existing `linux_irq_*_test` DDR tests also pass. So the
  trigger is more specific than "M-mode timer + MRET + phase sweep".
- The `SQ: allocation attempted during flush` $warning (store_queue.sv:1178)
  fires during the stress but is a generic, handled condition (test passes) --
  likely benign, not the race.

Next ideas to try (untried): (a) a handler that saves/restores ALL 31 GPRs to a
DDR stack like the kernel (heavy in-flight DDR mem-ops during the trap-return
flush); (b) a WFI-idle + timer-wake deadlock stress (the clocksource hang may be
the first idle WFI not waking); (c) deep RTL analysis of deadlock paths in the
SERIAL FSM (rob_serializer.sv: SERIAL_MRET_EXEC / SERIAL_TRAP_WAIT waiting
forever) and the SQ/LQ full-flush drain (load_queue.sv ~1140-1152) when a timer
flush races in-flight memory ops; (d) if reliability is needed sooner, a stronger
kernel-side interrupt mask around the critical windows as an interim mitigation.
