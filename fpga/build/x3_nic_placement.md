# X3 copies on a fresh optimized netlist

`x3_nic_placement.tcl` provides a finite netlist transformation for the X3
configuration. Source it after the build's normal `opt_design`, before its first
`place_design`, then call:

```tcl
::frost_x3_nic_placement::post_opt $audit_file auto
```

The return value is `1` after all four copies and their readback checks succeed,
or `0` when an expected structure is absent and the complete batch is skipped
before any mutation. `strict` makes those preflight mismatches fatal too. Native
command errors are fatal in either mode. Any error after mutation is fatal and
records `FAILED_AFTER_MUTATION`; the caller must stop that implementation and
preserve its diagnostic output. The helper does not attempt a partial rollback.
It restores every attempted sideband bank protection change even when a native
release or reconnect fails. Failure to restore any bank is fatal.

The four roles are:

| Role | Actual selected consumers | New LUT | Moved logical leaves |
| --- | --- | --- | --- |
| DMA | `wdata_q_reg_0_3_154_167/WE`, the entire RAM32M16 write-enable port | LUT2 | 16 |
| L1I | `mshr_data_q_reg[1][139,149,170,211,228,244,248]/CE` | LUT6 | 7 |
| Fetch prefix | `instruction_memory/o_instr_buffer[30]_i_2/I0` | LUT5 | 1 |
| Sideband address | Four RAM256X1D `DPRA[3]` macro ports: low 3840–4095, high 5632–5887 and 5888–6143, pair-valid 6400–6655 | LUT6 | 16 |

These roles are separate from the L1D completion and T-enable transformation in
`l1_control_repair.tcl`. The PC i189/i180 changes from earlier placement
experiments were moves, not copies, and are not part of this helper.

The selectors describe the supported synthesized consumer structure. Some
synthesized names may change with tool versions or source changes, so they are
compatibility guards, not a guarantee that every synthesis will match. The
original driver is discovered from each selected consumer. Its LUT width and
INIT must match the supported role, and its current ordered input identities
are copied and checked. Source driver names, reset replication names, net
aliases and complete original output ownership are captured from the current
netlist. Original consumers outside the selected partition retain their driver.
No file from a previous experiment is read.

For memories, only the native external macro port is reconnected. Preflight
checks its actual macro type, lower net, complete direct lower-pin group and
leaf owner/type. Readback preserves every selected macro's internal primitive
configuration and direct pin connections, every other external macro input and
output, and direct write-clock net identity. The three named sideband bank
`DONT_TOUCH` values are released only around the four DPRA reconnects and restored
exactly in a `finally` block. Other edited ancestor and net protections must be
absent. No bank-wide primitive census or clock/constant fanout census is used.
The source LUT input identities/configuration, selected consumer configuration,
other inputs, output connections and pin timing controls are also checked.
Literal case values (including zero) are active controls, while false/zero
`IS_CASE_ANALYSIS` and `HAS_CASE_ANALYSIS` flags are inactive. Placement and
packing properties are names: a group or pin-lock value named `0` is not empty.

This is an unplaced-netlist operation. It imports no checkpoint, sets no site,
BEL, pin lock, reuse property, clock or timing exception, and performs no
implementation command. Historical physical groups and positions are not
expected on a fresh netlist; the first placer packs the new logical enables.
The build must still measure its own setup/hold timing and implementation
results. Equivalent logic and matching copy counts do not establish timing
closure.

`::frost_x3_nic_placement::post_place $audit_file auto` currently records a
no-op. No portable placement refinement is enabled. Moving the earlier 19 cells
or remapping inputs would require current-run placement/maps and timing
headroom, plus verified functional and setup/hold recovery if a refinement is
rejected. It must not assume that a previous placement's improvements add up in
a fresh build.

The focused command-model tests execute this Tcl, including complete macro
boundaries, changing collection order, constant sources, late preflight failures,
partial edits and protection restoration:

```sh
FROST_SKIP_SUBMODULE_INIT=1 ./scripts/frost.py run python3 -m pytest tests/test_x3_nic_placement.py -q
```

These tests check the transaction and connectivity guards. A native fresh build
is still required to establish compatibility with Vivado's actual netlist and
whether the timing target is met.
