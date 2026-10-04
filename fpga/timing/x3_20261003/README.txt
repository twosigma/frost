X3 immediate post-place timing result, 2026-10-03

Qualified WNS: -0.189 ns, 34 ps better than the previous -0.223 ns record.
The native global timing gate passes with zero paths below -0.200 ns.
A fresh Vivado process reopened the saved checkpoint and confirmed -0.189 ns
without changing its constraints. The original limiting sideband-to-PD path
improved from -0.222 ns to -0.165 ns; the worst path is now in the IMMU.

Configuration
  RTL commit: d74dba7a822e79ea5ae43810f10ed542272ba3fc (unchanged RTL)
  Vivado: 2025.2, SW build 6299465
  Part: xcux35-vsva1365-3-e
  CPU frequency: 322265625 Hz; implemented clock period: 3.103 ns
  Post-opt WNS: +0.009 ns
  Added setup uncertainty during placement: 0.300 ns
  Added setup uncertainty for saved checkpoints and reports: 0.000 ns

Recipe
  1. From the archived post-opt checkpoint, set USER_CLOCK_ROOT to X1Y9 on
     both CPU clock nets. Run one place_design with ExtraNetDelay_high and
     0.300 ns setup overconstraint. The reference placement scores -0.222 ns.
  2. Reopen the same post-opt checkpoint and read the reference incrementally
     with RuntimeOptimized. Before place_design, unplace the sideband LUT5,
     constrain it to its original SLICE_X22Y497/A6LUT, and apply LOCK_PINS:
         I0:A2 I1:A6 I2:A4 I3:A5 I4:A3
     This assigns the late BRAM input I1 to A6 and the earlier registered
     select I4 to A3. The logical LUT INIT remains 32'hAAAACFC0.
  3. Run one place_design, then restore zero scoring uncertainty and write
     the checkpoint, reports, and native gate. There are no cell, net, or pin
     edits after place_design. The recipe invokes neither phys_opt_design
     nor route_design.

Target cell
  subsystem/frost_processor/cpu_and_memory_subsystem/instruction_memory/
  bits24_20_predecoded_2_saved[2]_i_5
  (The two lines above form one hierarchical cell name.)

Versioned files in this directory
  recipe/                            Frozen Tcl scripts used by reproduce.py
  reproduce.py                       Native placement and verification runner
  netlist_config.json                Configuration for downstream build stages
  manifest.json                      Configuration, source revision, input hashes
  evidence/                          Gate records and selected timing reports

Checkpoint bundle (kept outside Git)
  Default location: fpga/build/x3/post_place_20261003, relative to the repo root.
  Preserve or copy this directory when moving the recipe to another machine.
  A fresh Git clone alone does not contain the required checkpoints. Pass
  --artifacts /absolute/path/to/post_place_20261003 to use a copied bundle.

  The following paths are relative to that bundle:
  work/post_place.dcp                 Qualified checkpoint for downstream work
  work/post_place_gate.txt            Native threshold result
  work/post_place_gate_binding.json   SHA-256 binding between checkpoint and gate
  work/post_place_timing.rpt          Global timing summary
  work/post_place_failing_paths.csv   Negative setup timing paths
  work/placement.log                 Placement and constraint audit
  work/constraints_diff.txt          Differences from the reference's XDC
  verification/                      Reports from an unchanged, clean reopen
  reference/                         Preserved post-opt input and first placement
  recipe/                            Original Tcl snapshot used for qualification
  manifest.json                      Original bundle manifest

Reproduce natively on the host (Vivado is not in the Docker image):
  python3 fpga/timing/x3_20261003/reproduce.py \
    --output /absolute/path/to/a/new/reproduction_directory

The default repeats the final placement from the preserved reference. Add
--regenerate-reference to also repeat the initial full placement. The script
checks input hashes, runs placement, verifies the strict WNS target, reopens
the new checkpoint without altering constraints, and writes its gate binding.
It requires a new output directory and does not overwrite an existing run.
The versioned runner uses this directory's scripts and the bundle's hashed
reference inputs. Its only changes from the tested bundle runner are the
explicit artifact directory, the netlist-config location, and documentation
and formatting.
The Tcl scripts differ only by added license headers where needed.

Completed reproduction
  evidence/reproduction_result.json records a second -0.189 ns placement
  using the archived reference, followed by another unchanged clean reopen
  at -0.189 ns. Its negative-path CSV is byte-for-byte identical to the
  selected result. Both checkpoints have valid production gate bindings.
  Regenerating the initial full placement is supported by the script but was
  not part of this repeat; the reference checkpoint is preserved and hashed.

For a later post-place phys-opt run, the qualified checkpoint is ready for
this command from the repo root:
  python3 fpga/build/build.py x3 \
    --build-dir fpga/build/x3/post_place_20261003 \
    --start-at post_place_physopt --stop-after post_place_physopt

This result is specific to the archived netlist and placement reference.
Subsequent RTL changes need their own timing qualification. Routed timing
has not been measured as part of this work.
