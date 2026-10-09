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

# Move a critical LUT together with the register it alone drives toward the
# LUT's critical predecessor, extending the guidance refine derives from the
# fresh reference placement. Requires x3_local_placement.tcl. The caller still
# runs place_design and scores that result separately. No logic,
# connectivity, clock constraints, or timing exceptions are changed.
namespace eval ::frost_x3_local_placement {
    proc pair_names {objects} {
        # Converting a large collection to a string truncates it; ask for names.
        if {![llength $objects]} {return {}}
        return [lsort -unique [get_property NAME $objects]]
    }

    proc pair_movable {c guidance} {
        if {[llength [get_pblocks -quiet -of_objects $c]]} {return 0}
        # Cells refine already moved may carry fixed flags from place_cell.
        if {[dict exists $guidance [get_property NAME $c]]} {return 1}
        return [expr {![get_property IS_LOC_FIXED $c] && ![get_property IS_BEL_FIXED $c]}]
    }

    proc pair_below_gate {} {
        return [below_gate_count]
    }

    # Registers whose D is driven only by a 6LUT in the same letter of the
    # same site, with the paired 5LUT empty, worst endpoint first.
    proc pair_candidates {guidance limit} {
        set paths [get_timing_paths -quiet -group clock_from_mmcm -delay_type max \
            -slack_lesser_than -0.195 -max_paths 1000 -nworst 1]
        set endpoints {}
        if {[llength $paths]} {set endpoints [get_property ENDPOINT_PIN $paths]}
        set result {}
        set rejected {}
        foreach name $endpoints {
            if {[dict size $result] >= $limit} {break}
            set d [get_pins -quiet $name]
            if {[llength $d] != 1 || [get_property REF_PIN_NAME $d] ne "D"} {
                dict incr rejected endpoint
                continue
            }
            set r [get_cells -quiet -of_objects $d]
            if {[llength $r] != 1 || [get_property REF_NAME $r] ne "FDRE"} {
                dict incr rejected endpoint
                continue
            }
            set nets [get_nets -quiet -segments -of_objects $d]
            set drivers [get_pins -quiet -leaf -of_objects $nets -filter {DIRECTION == OUT}]
            set sinks [get_pins -quiet -leaf -of_objects $nets -filter {DIRECTION == IN}]
            if {[llength [pair_names $drivers]] != 1 || [llength [pair_names $sinks]] != 1} {
                dict incr rejected fanout
                continue
            }
            set l [get_cells -quiet -of_objects $drivers]
            if {[llength $l] != 1 || ![string match LUT* [get_property REF_NAME $l]]} {
                dict incr rejected driver
                continue
            }
            if {![pair_movable $r $guidance] || ![pair_movable $l $guidance]} {
                dict incr rejected fixed
                continue
            }
            set site [get_property LOC $r]
            set lut_bel [lindex [split [get_property BEL $l] .] end]
            set reg_bel [lindex [split [get_property BEL $r] .] end]
            if {$site eq "" || [get_property LOC $l] ne $site ||
                ![regexp {^([A-H])6LUT$} $lut_bel -> letter] ||
                ![regexp "^${letter}FF2?\$" $reg_bel]} {
                dict incr rejected geometry
                continue
            }
            set five [get_bels -quiet $site/${letter}5LUT]
            if {[llength $five] != 1 || [llength [get_cells -quiet -of_objects $five]]} {
                dict incr rejected shared_lut
                continue
            }
            dict set result [get_property NAME $r] [get_property NAME $l]
        }
        puts "FROST_LOCAL_PLACE pair_candidates endpoints=[llength $endpoints] selected=[dict size $result] rejected=$rejected"
        return $result
    }

    # Bounded targets: fractions of the way to the predecessor, the
    # predecessor's site and neighbours, then small moves around home.
    proc pair_sites {x y tx ty} {
        set points {}
        foreach f {0.25 0.5 0.75} {
            lappend points [expr {$x + round(($tx - $x) * $f)}] [expr {$y + round(($ty - $y) * $f)}]
        }
        foreach {dx dy} {0 0 -1 0 1 0 0 -1 0 1} {lappend points [expr {$tx + $dx}] [expr {$ty + $dy}]}
        foreach {dx dy} {-1 0 1 0 0 -2 0 2} {lappend points [expr {$x + $dx}] [expr {$y + $dy}]}
        set result {}
        foreach {sx sy} $points {
            set site SLICE_X${sx}Y${sy}
            if {$sx < 0 || $sy < 0 || ($sx == $x && $sy == $y) || $site in $result} {continue}
            lappend result $site
            if {[llength $result] == 11} {break}
        }
        return $result
    }

    # Letters whose 6LUT, 5LUT, FF and FF2 are all empty, preferred first.
    proc pair_letters {site preferred} {
        set s [get_sites -quiet $site]
        if {[llength $s] != 1} {return {}}
        # Empty BELs in carry, wide-mux, LUTRAM or SRL sites may still serve
        # as route-throughs or shared write-address inputs.
        if {[llength [get_cells -quiet -of_objects $s -filter \
            {REF_NAME =~ CARRY* || REF_NAME =~ MUXF* || REF_NAME =~ RAM* || REF_NAME =~ SRL*}]]} {
            return {}
        }
        set result {}
        foreach letter [concat $preferred [lsearch -all -inline -not -exact {A B C D E F G H} $preferred]] {
            set free 1
            foreach suffix {6LUT 5LUT FF FF2} {
                set b [get_bels -quiet $site/$letter$suffix]
                if {[llength $b] != 1 || [llength [get_cells -quiet -of_objects $b]]} {
                    set free 0
                    break
                }
            }
            if {$free} {lappend result $letter}
        }
        return $result
    }

    # Returns 0 when Vivado rejects the placement. Either cell may then be
    # placed or unplaced; pair_restore handles both.
    proc pair_place {states targets} {
        foreach state $states {
            set c [cell [dict get $state cell]]
            if {[get_property LOC $c] ne ""} {unplace_cell $c}
        }
        set command {}
        foreach state $states target $targets {
            set c [cell [dict get $state cell]]
            if {[dict exists $state pins]} {
                reset_property LOCK_PINS $c
                set locks {}
                dict for {logical physical} [dict get $state pins] {lappend locks $logical:$physical}
                set_property LOCK_PINS $locks $c
            }
            lappend command $c $target
        }
        # One call places both, so the LUT can drive the register inside the site.
        if {[catch {place_cell $command}]} {return 0}
        foreach state $states target $targets {
            set c [cell [dict get $state cell]]
            if {[signature $c] ne [dict get $state logic]} {
                error "Pair placement changed logic or connectivity: $c"
            }
            if {[dict exists $state pins] && [pin_map $c] ne [dict get $state pins]} {
                error "Pair placement did not preserve LUT pins: $c"
            }
            if {"[get_property LOC $c]/[lindex [split [get_property BEL $c] .] end]" ne $target} {
                error "Pair placement did not land on $target: $c"
            }
        }
        return 1
    }

    proc pair_restore {states} {
        set targets {}
        foreach state $states {lappend targets [dict get $state LOC]/[dict get $state BEL]}
        if {![pair_place $states $targets]} {
            error "Pair rollback could not re-place [dict get [lindex $states 1] cell]"
        }
        foreach state $states {
            set c [cell [dict get $state cell]]
            if {[dict exists $state pins]} {
                # Vivado rejects replacing a placed LUT's lock, even with the
                # same value; clearing it keeps the physical pins.
                reset_property LOCK_PINS $c
                if {[dict get $state LOCK_PINS] ne ""} {
                    set_property LOCK_PINS [dict get $state LOCK_PINS] $c
                }
            }
            foreach p {IS_LOC_FIXED IS_BEL_FIXED} {set_property $p [dict get $state $p] $c}
            if {[snapshot $c] ne $state} {error "Pair rollback did not restore $c"}
        }
    }

    # Local setup first; global, hold and the costly endpoint count only for
    # moves that could still be accepted.
    proc pair_measure {r floor best guard_floor hold_floor below} {
        set result [dict create setup [register_slack $r] guard {} holds {} below {} accept 0]
        set setup [dict get $result setup]
        if {$setup < $floor || $setup <= $best} {return $result}
        dict set result guard [slacks]
        if {![no_worse $guard_floor [dict get $result guard]]} {return $result}
        dict set result holds [hold_slacks $r]
        if {![hold_no_worse $hold_floor [dict get $result holds]]} {return $result}
        dict set result below [pair_below_gate]
        dict set result accept [expr {[dict get $result below] <= $below}]
        return $result
    }

    # Leaves the pair at its best qualifying sites, or exactly where it was.
    # Returns the outcome refine_pairs records.
    proc refine_pair {number reg lut originally_unplaced below_variable} {
        upvar 1 $below_variable below
        set r [cell $reg]
        set l [cell $lut]
        set d [get_pins -of_objects $r -filter {REF_PIN_NAME == D}]
        set path [get_timing_paths -quiet -delay_type max -to $d -max_paths 1 -nworst 1]
        if {[llength $path] != 1} {return no_d_path}
        set d_slack [get_property SLACK $path]
        if {![string is double -strict $d_slack]} {return no_d_path}
        # An earlier accepted pair may already have repaired this endpoint.
        if {$d_slack > -0.195} {return improved}
        set on_path [pair_names [get_pins -quiet -of_objects $path]]
        set critical {}
        foreach pin [get_pins -of_objects $l -filter {DIRECTION == IN}] {
            if {[get_property NAME $pin] in $on_path} {lappend critical $pin}
        }
        if {[llength $critical] != 1} {return no_critical_input}
        set drivers [get_pins -quiet -leaf -filter {DIRECTION == OUT} \
            -of_objects [get_nets -quiet -segments -of_objects [lindex $critical 0]]]
        if {[llength [pair_names $drivers]] != 1} {return multiple_drivers}
        set driver_cell [get_cells -of_objects $drivers]
        set predecessor [get_property NAME $driver_cell]
        set source [get_property LOC $driver_cell]
        set states [list [snapshot $l] [snapshot $r]]
        if {![regexp {^SLICE_X([0-9]+)Y([0-9]+)$} [dict get [lindex $states 1] LOC] -> x y]} {
            return home_site
        }
        if {![regexp {^SLICE_X([0-9]+)Y([0-9]+)$} $source -> tx ty]} {
            puts "FROST_LOCAL_PLACE pair=$number skip=predecessor_site predecessor=$predecessor loc=$source"
            return predecessor_site
        }
        if {$tx == $x && $ty == $y} {return predecessor_colocated}
        if {[catch {register_slack $r} before_setup]} {return no_setup_baseline}
        set before_holds [hold_slacks $r]
        if {![dict size $before_holds]} {return no_hold_baseline}
        set before_guard [slacks]
        set floor [expr {$before_setup + 0.010 - 1e-9}]
        set letter [string index [dict get [lindex $states 0] BEL] 0]
        set ff [string range [dict get [lindex $states 1] BEL] 1 end]
        set sites [pair_sites $x $y $tx $ty]
        puts "FROST_LOCAL_PLACE pair=$number register=$reg predecessor=$predecessor at=$source setup=$before_setup sites=$sites"

        set best {}
        set best_setup $before_setup
        set best_guard $before_guard
        set attempts 0
        set legal 0
        foreach site $sites {
            # Adequate margin ends the search; remaining endpoints matter more.
            if {$best_setup >= -0.175} {break}
            # The first legal letter is the only trial for each site.
            foreach free [pair_letters $site $letter] {
                set targets [list $site/${free}6LUT $site/$free$ff]
                incr attempts
                set placed 0
                set status [catch {
                    set placed [pair_place $states $targets]
                    if {$placed} {
                        require_placed $originally_unplaced
                        set measured [pair_measure $r $floor $best_setup $best_guard $before_holds $below]
                    }
                } message options]
                pair_restore $states
                require_placed $originally_unplaced
                if {$status} {return -options $options $message}
                if {[register_slack $r] ne $before_setup || [hold_slacks $r] ne $before_holds ||
                    [slacks] ne $before_guard} {
                    error "Pair rollback did not restore timing for $reg"
                }
                if {!$placed} {continue}
                incr legal
                puts "FROST_LOCAL_PLACE pair=$number site=$targets setup=[dict get $measured setup] guard=[dict get $measured guard] below=[dict get $measured below] better=[dict get $measured accept]"
                if {[dict get $measured accept]} {
                    set best $targets
                    set best_measured $measured
                    set best_setup [dict get $measured setup]
                    set best_guard [dict get $measured guard]
                }
                break
            }
        }
        if {$attempts && [pair_below_gate] != $below} {
            error "Pair rollback changed the below-gate endpoint count for $reg"
        }
        if {$best eq ""} {
            puts "FROST_LOCAL_PLACE pair=$number attempts=$attempts legal=$legal no qualifying move"
            return [expr {$legal ? "no_gain" : "no_legal"}]
        }

        set status [catch {
            if {![pair_place $states $best]} {error "Accepted pair placement is no longer legal: $reg"}
            require_placed $originally_unplaced
            set again [list [register_slack $r] [slacks] [hold_slacks $r] [pair_below_gate]]
        } message options]
        if {$status || $again ne [list [dict get $best_measured setup] [dict get $best_measured guard] \
                [dict get $best_measured holds] [dict get $best_measured below]]} {
            pair_restore $states
            require_placed $originally_unplaced
            if {$status} {return -options $options $message}
            error "Pair placement did not reproduce its measured timing: $reg"
        }
        set below [dict get $best_measured below]
        puts "FROST_LOCAL_PLACE pair=$number sites=$best setup=$before_setup->$best_setup guard=$before_guard->[dict get $best_measured guard] below=$below"
        return accepted
    }

    # Extends the caller's guidance dict with both cells of every accepted
    # pair and returns the accepted pair count.
    proc refine_pairs {guidance_variable originally_unplaced {limit 16}} {
        upvar 1 $guidance_variable guidance
        if {![info exists guidance]} {set guidance {}}
        require_placed $originally_unplaced
        set initial [slacks]
        set candidates [pair_candidates $guidance $limit]
        set number 0
        set accepted 0
        set outcomes {}
        set below {}
        if {[dict size $candidates]} {set below [pair_below_gate]}
        dict for {reg lut} $candidates {
            set outcome [refine_pair [incr number] $reg $lut $originally_unplaced below]
            dict incr outcomes $outcome
            if {$outcome eq "accepted"} {
                incr accepted
                foreach name [list $lut $reg] {dict set guidance $name [snapshot [cell $name]]}
            }
            puts "FROST_LOCAL_PLACE pair=$number result=$outcome accepted=$accepted setup_hold=[slacks] below=$below"
        }
        require_placed $originally_unplaced
        set final [slacks]
        if {![no_worse $initial $final]} {error "Pair guidance worsened global timing"}
        puts "FROST_LOCAL_PLACE pairs complete candidates=$number accepted=$accepted outcomes=$outcomes setup_hold=$initial->$final below=$below"
        return $accepted
    }
}
