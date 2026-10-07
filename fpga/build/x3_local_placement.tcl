#    Copyright 2026 Two Sigma Open Source, LLC
#
#    Licensed under the Apache License, Version 2.0 (the "License");
#    you may not use this file except in compliance with the License.
#    You may obtain a copy of the License at
#
#        http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS,
#    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#    See the License for the specific language governing permissions and
#    limitations under the License.

# Derive physical guidance from this build's freshly placed reference. The
# caller must run place_design afterwards and score that result separately.
# No logic, connectivity, clock constraints, or timing exceptions are changed.
namespace eval ::frost_x3_local_placement {
    variable restore_property FROST_X3_PLACEMENT_CONSTRAINTS

    proc constraint_flags {} {
        set result {}
        foreach property {IS_LOC_FIXED IS_BEL_FIXED DONT_TOUCH} {
            set objects [get_cells -quiet -hier -filter "$property == 1"]
            set names {}
            if {[llength $objects]} {set names [lsort [get_property NAME $objects]]}
            dict set result $property $names
        }
        return $result
    }

    proc constrained_nets {property} {
        set nets [get_nets -quiet -hier -filter "$property == 1"]
        if {![llength $nets]} {return {}}
        return [lsort [get_property NAME $nets]]
    }

    proc protected_nets {} {return [constrained_nets DONT_TOUCH]}

    proc exact_objects {command names} {
        if {![llength $names]} {return {}}
        set result [$command -quiet $names]
        if {![llength $result] || [lsort [get_property NAME $result]] ne [lsort $names]} {
            error "Missing or ambiguous preserved objects: $command"
        }
        return $result
    }

    proc saved_constraints {} {
        variable restore_property
        if {$restore_property ni [list_property [current_design]]} {return {}}
        return [get_property $restore_property [current_design]]
    }

    proc remember_constraints {} {
        variable restore_property
        if {[saved_constraints] ne ""} {error "Placement preservation is already active"}
        if {$restore_property ni [list_property [current_design]]} {
            create_property -type string $restore_property design
        }
        set_property $restore_property \
            [dict create schema x3_placement_constraints_v1 flags [constraint_flags] \
                protected_nets [protected_nets] fixed_routes [constrained_nets IS_ROUTE_FIXED] \
                pblocks {}] [current_design]
    }

    proc constrain_guidance {guidance} {
        variable restore_property
        set saved [saved_constraints]
        if {[dict get $saved schema] ne "x3_placement_constraints_v1"} {
            error "Missing original placement constraints"
        }
        if {![dict size $guidance]} {return}
        set baseline [unplaced]
        lock_design -level placement
        set groups {}
        dict for {name state} $guidance {
            set c [cell $name]
            if {[signature $c] ne [dict get $state logic]} {
                error "Guidance no longer matches logical cell $name"
            }
            unplace_cell $c
            if {[dict exists $state pins]} {
                reset_property LOCK_PINS $c
                set_property LOCK_PINS [dict get $state LOCK_PINS] $c
            }
            set_property BEL [dict get $state BEL] $c
            dict lappend groups [dict get $state LOC] $c
        }
        set index 0
        set pblocks {}
        dict for {site cells} $groups {
            set name frost_x3_guided_[incr index]
            if {[llength [get_pblocks -quiet $name]]} {error "Placement pblock already exists: $name"}
            set pb [create_pblock $name]
            resize_pblock $pb -add $site:$site
            set_property IS_SOFT false $pb
            add_cells_to_pblock $pb $cells
            lappend pblocks $name
        }
        # LOC would immediately place a cell. Hard one-site pblocks constrain
        # the chosen sites while leaving the cells genuinely unplaced for the
        # final place_design, which must legalize and place them itself.
        if {[unplaced] ne [lsort [concat $baseline [dict keys $guidance]]]} {
            error "Guided placement did not leave exactly the intended cells unplaced"
        }
        dict set saved pblocks $pblocks
        set_property $restore_property $saved [current_design]
        puts "FROST_LOCAL_PLACE ready cells=[dict size $guidance] pblocks=[llength $pblocks]"
    }

    # Called when opening the final placement for downstream optimization, never
    # during post-place qualification. Metadata travels inside the checkpoint.
    proc release {} {
        variable restore_property
        set saved [saved_constraints]
        if {$saved eq ""} {return 0}
        if {[dict get $saved schema] ne "x3_placement_constraints_v1"} {
            error "Unknown saved placement constraints"
        }
        set original [dict get $saved flags]
        foreach name [dict get $saved pblocks] {
            set pb [get_pblocks -quiet $name]
            if {[llength $pb] != 1} {error "Missing temporary placement pblock: $name"}
            delete_pblocks $pb
        }
        # Native unlock handles transformed multi-BEL primitives atomically.
        # Setting IS_BEL_FIXED on all their leaf aliases separately can fail
        # with conflicting LUTRAM BEL locations even when clearing the flag.
        lock_design -unlock -level logical
        dict for {property names} $original {
            set objects [exact_objects get_cells $names]
            if {[llength $objects]} {set_property $property true $objects}
        }
        foreach {property key} {DONT_TOUCH protected_nets IS_ROUTE_FIXED fixed_routes} {
            set objects [exact_objects get_nets [dict get $saved $key]]
            if {[llength $objects]} {set_property $property true $objects}
            if {[constrained_nets $property] ne [dict get $saved $key]} {
                error "Original net $property constraints were not restored"
            }
        }
        if {[constraint_flags] ne $original} {
            error "Original constraints were not restored"
        }
        reset_property $restore_property [current_design]
        puts "FROST_LOCAL_PLACE restored original LOC/BEL/DONT_TOUCH constraints"
        return 1
    }

    proc cell {name} {
        set result [get_cells -quiet $name]
        if {[llength $result] != 1 || [get_property NAME $result] ne $name} {
            error "Nonunique guidance cell: $name"
        }
        return $result
    }

    proc slack {args} {
        set path [get_timing_paths -quiet -max_paths 1 {*}$args]
        if {[llength $path] != 1} {error "Missing guidance timing path: $args"}
        set value [get_property SLACK $path]
        if {![string is double -strict $value] || !($value > -Inf && $value < Inf)} {
            error "Invalid guidance slack: $value"
        }
        return $value
    }

    proc slacks {} {
        # Another clock domain can hide a regression in the CPU hold minimum.
        return [list [slack -delay_type max] [slack -delay_type min] \
            [slack -group clock_from_mmcm -delay_type max] \
            [slack -group clock_from_mmcm -delay_type min]]
    }

    proc output_slack {c} {
        return [slack -through [get_pins -of_objects $c -filter {DIRECTION == OUT}]]
    }

    proc register_slack {c} {
        set inputs [get_pins -of_objects $c -filter {DIRECTION == IN && IS_CLOCK == 0}]
        return [expr {min([slack -to $inputs], [output_slack $c])}]
    }

    proc hold_slacks {c} {
        set result {}
        if {[get_property REF_NAME $c] eq "FDRE"} {
            foreach pin [lsort [get_pins -of_objects $c -filter {DIRECTION == IN && IS_CLOCK == 0}]] {
                if {![llength [get_timing_paths -quiet -delay_type min -to $pin -max_paths 1]]} {continue}
                dict set result $pin [slack -delay_type min -to $pin]
            }
        }
        set output [get_pins -of_objects $c -filter {DIRECTION == OUT}]
        if {![llength [get_timing_paths -quiet -delay_type min -through $output -max_paths 1]]} {return {}}
        dict set result output [slack -delay_type min -through $output]
        return $result
    }

    proc hold_no_worse {before after} {
        if {![dict size $before] || [dict keys $before] ne [dict keys $after]} {return 0}
        dict for {pin value} $before {
            # Positive hold margin may be spent, but a negative local minimum
            # cannot worsen and a previously passing minimum cannot fail.
            if {[dict get $after $pin] < min($value, 0)} {return 0}
        }
        return 1
    }

    proc pin_map {c} {
        set result {}
        foreach pin [lsort [get_pins -of_objects $c -filter {DIRECTION == IN}]] {
            set physical [get_bel_pins -of_objects $pin]
            if {[llength $physical] != 1} {error "Unmapped guidance LUT input: $pin"}
            dict set result [get_property REF_PIN_NAME $pin] [file tail $physical]
        }
        return $result
    }

    proc signature {c} {
        set result [list [get_property REF_NAME $c] [get_property INIT $c]]
        foreach pin [lsort [get_pins -of_objects $c]] {
            lappend result [list [get_property REF_PIN_NAME $pin] \
                [lsort [get_nets -segments -of_objects $pin]]]
        }
        return $result
    }

    proc snapshot {c} {
        set result [dict create cell $c logic [signature $c]]
        foreach p {LOC BEL LOCK_PINS IS_LOC_FIXED IS_BEL_FIXED} {
            dict set result $p [get_property $p $c]
        }
        dict set result BEL [lindex [split [dict get $result BEL] .] end]
        if {[string match LUT* [get_property REF_NAME $c]]} {
            dict set result pins [pin_map $c]
        }
        return $result
    }

    proc unplaced {} {
        # LOC is supported for both primitive and transformed primitive cells.
        # IS_PLACED is not a Vivado cell property; using it silently selects none.
        set objects [get_cells -quiet -hier -filter {IS_PRIMITIVE && LOC == ""}]
        if {![llength $objects]} {return {}}
        return [lsort [get_property NAME $objects]]
    }

    proc remap {state site_bel mapping} {
        set c [cell [dict get $state cell]]
        unplace_cell $c
        if {[dict exists $state pins]} {
            reset_property LOCK_PINS $c
            set pins {}
            dict for {logical physical} $mapping {lappend pins "$logical:$physical"}
            set_property LOCK_PINS $pins $c
        }
        place_cell [list $c $site_bel]
        if {[signature $c] ne [dict get $state logic]} {
            error "Physical guidance changed logic or connectivity: $c"
        }
        if {[dict exists $state pins] && [pin_map $c] ne $mapping} {
            error "Physical guidance did not preserve requested pins: $c"
        }
    }

    proc restore {state} {
        set c [dict get $state cell]
        set mapping {}
        if {[dict exists $state pins]} {set mapping [dict get $state pins]}
        remap $state [dict get $state LOC]/[dict get $state BEL] $mapping
        if {[dict exists $state pins]} {
            # remap installs a complete pin lock before placing the LUT.
            # Vivado rejects replacing that property on a placed cell, even
            # with the same value. Clearing it preserves the physical pins
            # and lets us restore the original full, partial, or empty lock.
            reset_property LOCK_PINS $c
            if {[dict get $state LOCK_PINS] ne ""} {
                set_property LOCK_PINS [dict get $state LOCK_PINS] $c
            }
        }
        foreach p {IS_LOC_FIXED IS_BEL_FIXED} {set_property $p [dict get $state $p] $c}
        if {[snapshot $c] ne $state} {error "Guidance rollback did not restore $c"}
    }

    proc no_worse {before after} {
        if {![llength $before] || [llength $before] != [llength $after]} {
            error "Incompatible guidance timing measurements"
        }
        foreach old $before new $after {if {$new < $old} {return 0}}
        return 1
    }

    proc require_placed {baseline} {
        if {[unplaced] ne $baseline} {
            error "Local guidance unplaced a companion cell; timing cannot be scored"
        }
    }

    proc below_gate_count {} {
        set paths [get_timing_paths -quiet -group clock_from_mmcm -delay_type max \
            -slack_lesser_than -0.200 -max_paths 10000 -nworst 1]
        if {[llength $paths] >= 10000} {error "Guidance endpoint count reached its query limit"}
        if {![llength $paths]} {return 0}
        return [llength [lsort -unique [get_property ENDPOINT_PIN $paths]]]
    }

    # Pull a separated register toward a low-fanout LUT driver. All of the
    # register's timed inputs and outputs participate in the acceptance test.
    proc refine_registers {guidance_variable originally_unplaced {limit 24}} {
        upvar 1 $guidance_variable guidance
        require_placed $originally_unplaced
        set initial [slacks]
        set candidates {}
        foreach path [get_timing_paths -quiet -group clock_from_mmcm \
            -slack_lesser_than -0.195 -max_paths 1000 -nworst 1] {
            set ep [get_pins -quiet [get_property ENDPOINT_PIN $path]]
            set c [get_cells -quiet -of_objects $ep]
            if {[llength $c] != 1 || [get_property REF_NAME $c] ne "FDRE" || [dict exists $candidates $c]} {continue}
            set original [snapshot $c]
            if {![pair_movable $c $guidance]} {continue}
            set nets [get_nets -quiet -segments -of_objects $ep]
            set drivers [get_pins -quiet -leaf -of_objects $nets -filter {DIRECTION == OUT}]
            set sinks [get_pins -quiet -leaf -of_objects $nets -filter {DIRECTION == IN}]
            if {[llength $drivers] != 1 || [llength $sinks] > 16} {continue}
            set dc [get_cells -quiet -of_objects $drivers]
            if {![string match LUT* [get_property REF_NAME $dc]]} {continue}
            if {![regexp {^SLICE_X([0-9]+)Y([0-9]+)$} [dict get $original LOC] -> x y] ||
                ![regexp {^SLICE_X([0-9]+)Y([0-9]+)$} [get_property LOC $dc] -> tx ty]} {continue}
            if {abs($x-$tx) < 2 && abs($y-$ty) < 2} {continue}
            set letter [string index [lindex [split [get_property BEL $dc] .] end] 0]
            dict set candidates $c [list $x $y $tx $ty $letter]
            if {[dict size $candidates] >= $limit} {break}
        }
        set accepted 0
        set checked 0
        dict for {c coordinates} $candidates {
            if {[slack] > -0.195} {break}
            incr checked
            set original [snapshot $c]
            set before [slacks]
            set before_hold [hold_slacks $c]
            if {![dict size $before_hold]} {continue}
            if {[catch {register_slack $c} before_score]} {continue}
            if {$before_score > -0.195} {continue}
            set before_count [below_gate_count]
            set best_score $before_score
            set best_guard $before
            set best_site ""
            lassign $coordinates x y tx ty letter
            set sites [list [list $tx $ty]]
            foreach fraction {0.25 0.5 0.75} {
                lappend sites [list [expr {round($x+($tx-$x)*$fraction)}] [expr {round($y+($ty-$y)*$fraction)}]]
            }
            foreach {dx dy} {-1 0 1 0 0 -1 0 1} {lappend sites [list [expr {$tx+$dx}] [expr {$ty+$dy}]]}
            set legal 0
            foreach xy [lsort -unique $sites] {
                lassign $xy sx sy
                set site SLICE_X${sx}Y${sy}
                if {![llength [get_sites -quiet $site]] || $site eq [dict get $original LOC]} {continue}
                set bels [list ${letter}FF ${letter}FF2 [dict get $original BEL]]
                foreach b {AFF BFF CFF DFF EFF FFF GFF HFF AFF2 BFF2 CFF2 DFF2 EFF2 FFF2 GFF2 HFF2} {
                    if {$b ni $bels} {lappend bels $b}
                }
                foreach bel $bels {
                    set b [get_bels -quiet $site/$bel]
                    if {[llength $b] != 1 || [llength [get_cells -quiet -of_objects $b]]} {continue}
                    set placed [expr {![catch {remap $original $site/$bel {}}]}]
                    if {$placed} {
                        require_placed $originally_unplaced
                        incr legal
                        set score [register_slack $c]
                        set hold [hold_slacks $c]
                        set guard [slacks]
                        if {$score >= $before_score+0.010-1e-9 && $score > $best_score &&
                            [no_worse $best_guard $guard] && [hold_no_worse $before_hold $hold]} {
                            set count [below_gate_count]
                            if {$count <= $before_count} {
                                set best_score $score
                                set best_hold $hold
                                set best_guard $guard
                                set best_count $count
                                set best_site $site/$bel
                            }
                        }
                    }
                    restore $original
                    require_placed $originally_unplaced
                    if {$placed} {break}
                }
                # Illegal letters are never scored. Verify timing after the
                # site's attempts instead of recomputing it for each rejected
                # letter; exact cell state and placement are checked above.
                if {[slacks] ne $before || [register_slack $c] != $before_score || [hold_slacks $c] ne $before_hold} {
                    error "Register trial failed to restore timing: $c"
                }
                if {$best_score >= -0.175} {break}
            }
            if {[below_gate_count] != $before_count} {error "Register trial changed unrelated timing after rollback: $c"}
            if {$best_site ne ""} {
                remap $original $best_site {}
                require_placed $originally_unplaced
                if {[register_slack $c] != $best_score || [hold_slacks $c] ne $best_hold ||
                    [slacks] ne $best_guard || [below_gate_count] != $best_count} {
                    restore $original
                    require_placed $originally_unplaced
                    error "Accepted register placement did not reproduce: $c"
                }
                dict set guidance $c [snapshot $c]
                incr accepted
            }
            puts "FROST_LOCAL_PLACE register_trial=$checked accepted=$accepted cell=$c site=$best_site local=$before_score->$best_score legal_sites=$legal setup_hold=[slacks] below_gate=[below_gate_count]"
        }
        if {![no_worse $initial [slacks]]} {error "Register refinement worsened timing"}
        return $accepted
    }

    proc refine {work_directory} {
        remember_constraints
        set initial [slacks]
        set originally_unplaced [unplaced]
        set guidance {}
        set paths [get_timing_paths -quiet -group clock_from_mmcm \
            -slack_lesser_than -0.175 -max_paths 1000 -nworst 1]
        set registers [get_cells -quiet -of_objects $paths -filter \
            {NAME =~ *l2_cache/data_array/u_xpm_ram/*doutb_pipe_reg* && REF_NAME == FDRE}]
        # Balance URAM-to-register and register-to-cache delay in the middle
        # columns. Every site is evaluated on the current netlist; no archived
        # cell names, placements, or timing measurements are reused.
        foreach c [lsort $registers] {
            set original [snapshot $c]
            if {[dict get $original IS_LOC_FIXED] || [dict get $original IS_BEL_FIXED]} {continue}
            set before [slacks]
            set before_hold [hold_slacks $c]
            if {![dict size $before_hold]} {continue}
            set best [register_slack $c]
            set best_site [dict get $original LOC]/[dict get $original BEL]
            foreach x {120 128 112} {
                foreach y {410 404 416} {
                    set site [get_sites -quiet SLICE_X${x}Y${y}]
                    if {[llength $site] != 1} {continue}
                    foreach bel {AFF BFF CFF DFF EFF FFF GFF HFF AFF2 BFF2 CFF2 DFF2 EFF2 FFF2 GFF2 HFF2} {
                        set b [get_bels -quiet $site/$bel]
                        if {[llength $b] != 1 || [llength [get_cells -quiet -of_objects $b]]} {continue}
                        if {![catch {remap $original $site/$bel {}}]} {
                            require_placed $originally_unplaced
                            set score [register_slack $c]
                            if {$score > $best && [no_worse $before [slacks]] &&
                                [hold_no_worse $before_hold [hold_slacks $c]]} {
                                set best $score
                                set best_site $site/$bel
                            }
                        }
                        restore $original
                        break
                    }
                    if {$best >= 0.400} {break}
                }
                if {$best >= 0.400} {break}
            }
            if {$best_site ne "[dict get $original LOC]/[dict get $original BEL]"} {
                remap $original $best_site {}
                dict set guidance $c [snapshot $c]
                puts "FROST_LOCAL_PLACE register=$c site=$best_site balanced_slack=$best setup_hold=[slacks]"
            }
        }

        for {set round 0} {$round < 8 && [slack] <= -0.195} {incr round} {
            set changes 0
            set paths [get_timing_paths -quiet -group clock_from_mmcm \
                -slack_lesser_than -0.175 -max_paths 40 -nworst 1]
            set candidates {}
            # Visit the worst paths first and skip cells whose paths already
            # improved. This limits unnecessary locks and repeated timing work.
            foreach path $paths {
                foreach c [get_cells -quiet -of_objects $path -filter {REF_NAME =~ LUT*}] {
                    dict set candidates $c 1
                }
            }
            foreach c [dict keys $candidates] {
                if {[slack] > -0.195} {break}
                if {[output_slack $c] > -0.195} {continue}
                set original [snapshot $c]
                if {([dict get $original IS_LOC_FIXED] || [dict get $original IS_BEL_FIXED]) &&
                    ![dict exists $guidance $c]} {continue}
                set before_hold [hold_slacks $c]
                if {![dict size $before_hold]} {continue}
                set site [dict get $original LOC]
                set bel [dict get $original BEL]
                if {![string match *6LUT $bel]} {continue}
                set sibling [get_bels -quiet $site/[string index $bel 0]5LUT]
                if {[llength $sibling] != 1 || [llength [get_cells -quiet -of_objects $sibling]]} {continue}
                set worst_pin ""
                set worst_slack Inf
                foreach pin [get_pins -of_objects $c -filter {DIRECTION == IN}] {
                    set path [get_timing_paths -quiet -through $pin -max_paths 1]
                    if {![llength $path]} {continue}
                    set value [get_property SLACK $path]
                    if {$value < $worst_slack} {
                        set worst_slack $value
                        set worst_pin [get_property REF_PIN_NAME $pin]
                    }
                }
                set base [dict get $original pins]
                if {$worst_pin eq "" || [dict get $base $worst_pin] eq "A6"} {continue}
                set old_physical [dict get $base $worst_pin]
                set best $base
                set best_local [output_slack $c]
                set before [slacks]
                set best_global $before
                dict for {logical physical} $base {
                    if {$logical eq $worst_pin || [string compare $physical $old_physical] < 0} {continue}
                    set trial $base
                    dict set trial $worst_pin $physical
                    dict set trial $logical $old_physical
                    if {![catch {remap $original $site/$bel $trial}]} {
                        require_placed $originally_unplaced
                        set local [output_slack $c]
                        set global [slacks]
                        if {$local > $best_local && [no_worse $best_global $global] &&
                            [hold_no_worse $before_hold [hold_slacks $c]]} {
                            set best $trial
                            set best_local $local
                            set best_global $global
                        }
                    }
                    restore $original
                }
                if {$best ne $base} {
                    remap $original $site/$bel $best
                    dict set guidance $c [snapshot $c]
                    incr changes
                    puts "FROST_LOCAL_PLACE lut=$c pins=$best local_slack=$best_local setup_hold=[slacks]"
                }
            }
            set pairs 0
            set registers 0
            if {[slack] <= -0.195} {
                set pairs [refine_pairs guidance $originally_unplaced 12]
            }
            if {[slack] <= -0.195} {
                set registers [refine_registers guidance $originally_unplaced 16]
            }
            puts "FROST_LOCAL_PLACE round=$round pin_changes=$changes pairs=$pairs registers=$registers setup_hold=[slacks] below_gate=[below_gate_count]"
            if {!$changes && !$pairs && !$registers} {break}
        }
        require_placed $originally_unplaced
        set final [slacks]
        if {![no_worse $initial $final]} {error "Local guidance worsened global timing"}
        set audit [dict create schema x3_local_placement_v1 \
            slack_order {global_setup global_hold cpu_setup cpu_hold} initial_slacks $initial \
            final_slacks $final cells $guidance]
        set f [open [file join $work_directory post_place_guidance.tcldict] w]
        puts $f $audit
        close $f
        puts "FROST_LOCAL_PLACE complete cells=[dict size $guidance] setup_hold=$final"
        return $guidance
    }

    # Read-only after the final placer and again after reopening its checkpoint.
    proc verify {work_directory} {
        set saved [saved_constraints]
        if {$saved eq "" || [dict get $saved schema] ne "x3_placement_constraints_v1"} {
            error "Missing placement constraint restoration metadata"
        }
        foreach name [dict get $saved pblocks] {
            if {[llength [get_pblocks -quiet $name]] != 1} {
                error "Missing saved placement pblock: $name"
            }
        }
        set f [open [file join $work_directory post_place_guidance.tcldict]]
        set audit [read $f]
        close $f
        if {[dict get $audit schema] ne "x3_local_placement_v1"} {error "Unknown local placement audit"}
        dict for {name expected} [dict get $audit cells] {
            set actual [snapshot [cell $name]]
            foreach p {logic LOC BEL pins} {
                if {[dict exists $expected $p] && [dict get $actual $p] ne [dict get $expected $p]} {
                    error "Final placement changed $p for guided cell $name"
                }
            }
        }
        puts "FROST_LOCAL_PLACE verified cells=[dict size [dict get $audit cells]]"
    }
}

source [file join [file dirname [info script]] x3_pair_placement.tcl]
