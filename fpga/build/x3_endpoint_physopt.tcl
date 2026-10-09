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

# Post-route fallback when a CPU clock group's worst paths remain tied.
# Separate endpoint objectives let phys-opt retain improvements beyond the
# path that defines the clock group's WNS.
namespace eval frost_x3_endpoint_physopt {
    proc clock_signature {} {
        set result [dict create]
        foreach name [lsort [get_property NAME [get_clocks]]] {
            set clock [get_clocks [list $name]]
            dict set result $name [list [get_property PERIOD $clock] \
                [get_property WAVEFORM $clock]]
        }
        return $result
    }

    proc run {kind sweep_uncertainty {work_directory ""}} {
        if {![string is double -strict $sweep_uncertainty] || $sweep_uncertainty < 0} {
            error "Endpoint optimization requires a nonnegative setup uncertainty"
        }
        if {$kind eq "EndpointPinRefine"} {
            return [refine_pins $work_directory]
        }
        if {$kind eq "EndpointClockIndividual"} {
            return [refine_clocks $work_directory $sweep_uncertainty]
        }
        if {$kind eq "EndpointRouteRefine"} {
            return [refine_routes $work_directory]
        }
        if {$kind ni {EndpointAggressive EndpointTargeted EndpointClockEnable}} {
            error "Unknown endpoint optimization pass: $kind"
        }
        set clk [get_clocks -quiet clock_from_mmcm]
        if {[llength $clk] != 1} {
            error "Endpoint optimization requires exactly one CPU clock"
        }
        set paths [get_timing_paths -quiet -group clock_from_mmcm \
            -delay_type max -slack_lesser_than 0.005 -max_paths 600 -nworst 1]
        if {![llength $paths]} {
            puts "FROST_ENDPOINT_PHYSOPT $kind: no near-critical CPU endpoints"
            return 0
        }
        set ports [frost_x3_local_placement::port_constraints]
        set clocks [clock_signature]
        set endpoints [dict create]
        set index 0
        try {
            foreach path $paths {
                set endpoint [get_property ENDPOINT_PIN $path]
                if {$kind eq "EndpointClockEnable" &&
                    ([get_property REF_PIN_NAME $endpoint] ne "CE" ||
                     [get_property SLACK $path] >= 0)} {
                    continue
                }
                set name frost_endpoint_physopt_[incr index]
                if {[llength [get_timing_paths -quiet -group $name -max_paths 1]]} {
                    error "Endpoint optimization would overwrite active group $name"
                }
                group_path -name $name -from $clk -to $endpoint
                dict set endpoints $name [get_property NAME $endpoint]
            }
            if {![dict size $endpoints]} {return 0}
            puts "FROST_ENDPOINT_PHYSOPT $kind: [dict size $endpoints] endpoint groups"
            set_x3_setup_uncertainty x3 [expr {$sweep_uncertainty + 0.030}] \
                "$kind temporary margin"
            if {$kind eq "EndpointAggressive"} {
                phys_opt_design -directive AggressiveExplore -path_groups [dict keys $endpoints]
            } elseif {$kind eq "EndpointTargeted"} {
                phys_opt_design -critical_cell_opt -critical_pin_opt \
                    -routing_opt -placement_opt -path_groups [dict keys $endpoints]
            } else {
                phys_opt_design -clock_opt -path_groups [dict keys $endpoints]
            }
        } finally {
            # Vivado removes a group only with the same from/to expression
            # that created it. A clock-to-clock default does not remove these
            # endpoint-specific groups. Restore the scoring uncertainty even
            # if removing a group fails; no checkpoint is accepted on error.
            try {
                dict for {name endpoint_name} $endpoints {
                    set endpoint [frost_x3_local_placement::exact_objects \
                        get_pins [list $endpoint_name]]
                    if {[llength $endpoint] != 1} {
                        error "Endpoint disappeared during optimization: $endpoint_name"
                    }
                    group_path -default -from $clk -to $endpoint
                }
                foreach name [dict keys $endpoints] {
                    if {[llength [get_timing_paths -quiet -group $name -max_paths 1]]} {
                        error "Temporary endpoint group still owns paths: $name"
                    }
                }
            } finally {
                set_x3_setup_uncertainty x3 $sweep_uncertainty "$kind scoring"
            }
        }
        if {[frost_x3_local_placement::port_constraints] ne $ports} {
            error "Endpoint optimization changed board port constraints"
        }
        if {[clock_signature] ne $clocks} {
            error "Endpoint optimization changed clock periods or waveforms"
        }
        return 1
    }

    proc append_pin_candidates {pins failing seen_name} {
        upvar 1 $seen_name seen
        if {!$failing} {return}
        # Work back from each endpoint. Shared upstream pins are tried once.
        foreach name [lreverse $pins] {
            if {[dict exists $seen $name]} {continue}
            set pin [get_pins -quiet [list $name]]
            set cell [get_cells -quiet -of_objects $pin]
            if {[llength $cell] != 1 ||
                ![regexp {^LUT[1-6]$} [get_property REF_NAME $cell]] ||
                [get_property LOCK_PINS $cell] ne ""} {continue}
            set bel [lindex [split [get_property BEL $cell] .] end]
            if {![regexp {^[A-H]6LUT$} $bel]} {continue}
            set paired_bel [get_bels -quiet \
                [get_property LOC $cell]/[string replace $bel 1 1 5]]
            if {[llength $paired_bel] != 1 ||
                [llength [get_cells -quiet -of_objects $paired_bel]]} {continue}
            set mapping [frost_x3_local_placement::pin_map $cell]
            set logical [get_property REF_PIN_NAME $pin]
            if {![dict exists $mapping $logical]} {continue}
            # A5 can still benefit from A6 when only a few picoseconds remain.
            if {[dict get $mapping $logical] ni {A1 A2 A3 A4 A5}} {continue}
            dict set seen $name 1
        }
    }

    proc pin_candidates {report} {
        set seen [dict create]
        set pins {}
        set failing 0
        foreach line [split $report "\n"] {
            if {[regexp {^Slack \((MET|VIOLATED)\)\s*:\s*([-0-9.]+)ns} $line -> status slack]} {
                append_pin_candidates $pins $failing seen
                set pins {}
                # A real violation can display as -0.000 ns. The report's
                # status preserves that distinction from an exactly met path.
                set failing [expr {$status eq "VIOLATED" || $slack < 0}]
            }
            if {[regexp {^\s+SLICE_X[0-9]+Y[0-9]+\s+[rf]\s+(\S+/I[0-9]+)$} $line -> pin]} {
                lappend pins $pin
            }
        }
        append_pin_candidates $pins $failing seen
        return [dict keys $seen]
    }

    proc restore_property {property value object} {
        if {$value eq ""} {
            reset_property $property $object
        } else {
            set_property $property $value $object
        }
    }

    proc clock_routes {} {
        # Clock definitions alone omit distribution nets after a clock buffer.
        # Include the nets feeding clock pins, but exclude constant-tied pins.
        # This also preserves clocks internal to device primitives, even when
        # they have no separate timing-clock object. Snapshot every alias before
        # changing any fixed-route flag, then deduplicate and sort the names.
        set pins [get_pins -hier -filter {IS_CLOCK && DIRECTION == IN}]
        set nets [concat [get_nets -of_objects [get_clocks]] \
            [get_nets -of_objects $pins]]
        set nets [get_nets -top_net_of_hierarchical_group $nets]
        set routes [dict create]
        foreach net $nets {
            set name [get_property NAME $net]
            if {[dict exists $routes $name] ||
                [get_property TYPE $net] in {GROUND POWER}} {continue}
            set route [get_property ROUTE $net]
            if {$route eq ""} {continue}
            set nodes [get_nodes -quiet -of_objects $net]
            set pips [get_pips -quiet -of_objects $net]
            if {[llength $nodes]} {set nodes [lsort -unique [get_property NAME $nodes]]}
            if {[llength $pips]} {set pips [lsort -unique [get_property NAME $pips]]}
            dict set routes $name [list $route [get_property FIXED_ROUTE $net] \
                [string is true -strict [get_property IS_ROUTE_FIXED $net]] $nodes $pips]
        }
        set result [dict create]
        foreach name [lsort [dict keys $routes]] {
            dict set result $name [dict get $routes $name]
        }
        return $result
    }

    proc restore_clock_routes {routes} {
        set after [clock_routes]
        if {[dict keys $after] ne [dict keys $routes]} {
            error "Routed refinement changed the clock network"
        }
        dict for {name saved} $routes {
            # ROUTE is a tree whose branch order can change during checkpoint
            # serialization. The physical nodes and PIPs define the routing.
            if {[lrange [dict get $after $name] 3 end] ne [lrange $saved 3 end]} {
                error "Routed refinement changed clock routing: $name"
            }
        }
        dict for {name saved} $routes {
            lassign $saved route fixed_route fixed
            set net [frost_x3_local_placement::exact_objects get_nets [list $name]]
            set_property IS_ROUTE_FIXED false $net
            restore_property FIXED_ROUTE $fixed_route $net
            set_property IS_ROUTE_FIXED $fixed $net
        }
        set restored [clock_routes]
        if {[dict keys $restored] ne [dict keys $routes]} {
            error "Routed refinement did not restore the clock network"
        }
        dict for {name saved} $routes {
            if {[lrange [dict get $restored $name] 1 end] ne [lrange $saved 1 end]} {
                error "Routed refinement did not restore clock routing constraints: $name"
            }
        }
    }

    proc remap_routed_pin {pin_name target} {
        set pin [frost_x3_local_placement::exact_objects get_pins [list $pin_name]]
        set cell [get_cells -of_objects $pin]
        set cell_name [get_property NAME $cell]
        set state [frost_x3_local_placement::snapshot $cell]
        set logical [get_property REF_PIN_NAME $pin]
        set mapping [dict get $state pins]
        set old [dict get $mapping $logical]
        if {$target eq $old || $old eq "A6" ||
            ($old eq "A5" && $target ne "A6") ||
            ($old in {A3 A4} && $target eq "A4")} {return 0}
        if {[dict get $state LOCK_PINS] ne ""} {
            error "Refusing to replace an existing LUT pin constraint: $cell_name"
        }
        set owner ""
        dict for {input physical} $mapping {
            if {$physical eq $target} {set owner $input}
        }
        dict set mapping $logical $target
        if {$owner ne ""} {dict set mapping $owner $old}
        set original_dt [get_property DONT_TOUCH $cell]
        set ports [frost_x3_local_placement::port_constraints]
        set clocks [clock_signature]
        set unplaced [frost_x3_local_placement::unplaced]
        set routes [clock_routes]
        if {![dict size $routes]} {error "No clock routes to preserve"}
        dict for {name saved} $routes {
            set_property IS_ROUTE_FIXED true \
                [frost_x3_local_placement::exact_objects get_nets [list $name]]
        }
        # The caller reopens its best checkpoint on any error, including a
        # routing failure. No partially restored candidate can be retained.
        route_design -unroute -pins [get_pins -of_objects $cell -filter {DIRECTION == IN}]
        set_property DONT_TOUCH false $cell
        frost_x3_local_placement::remap $state \
            [dict get $state LOC]/[dict get $state BEL] $mapping
        frost_x3_local_placement::require_placed $unplaced
        route_design -preserve
        restore_clock_routes $routes
        set cell [frost_x3_local_placement::cell $cell_name]
        if {[frost_x3_local_placement::signature $cell] ne [dict get $state logic] ||
            [frost_x3_local_placement::pin_map $cell] ne $mapping ||
            [get_property LOC $cell] ne [dict get $state LOC] ||
            [lindex [split [get_property BEL $cell] .] end] ne [dict get $state BEL]} {
            error "LUT pin refinement changed logic, connectivity, or its requested pin map"
        }
        reset_property LOCK_PINS $cell
        foreach flag {IS_LOC_FIXED IS_BEL_FIXED} {
            set_property $flag [dict get $state $flag] $cell
        }
        restore_property DONT_TOUCH $original_dt $cell
        frost_x3_local_placement::require_placed $unplaced
        if {[frost_x3_local_placement::port_constraints] ne $ports ||
            [clock_signature] ne $clocks} {
            error "LUT pin refinement changed board pins or clock definitions"
        }
        return 1
    }

    proc routed_score {prefix} {
        set timing_file ${prefix}_timing.rpt
        set route_file ${prefix}_route.rpt
        set skew_file ${prefix}_bus_skew.rpt
        report_timing_summary -file $timing_file
        report_route_status -file $route_file
        report_bus_skew -max_paths 1 -nworst 1 -file $skew_file
        if {![candidate_is_legal $timing_file $route_file $skew_file]} {return {}}
        set fh [open $timing_file]
        set report [read $fh]
        close $fh
        if {![regexp {WNS\(ns\)[^\n]*\n[^\n]*\n\s*([-0-9.]+)\s+([-0-9.]+)\s+(\d+)} $report -> wns tns failing]} {
            error "Missing setup summary for routed refinement"
        }
        # Use the same worst-path SLACK property as the enclosing sweep, and
        # keep the endpoint count to resolve a displayed zero at the boundary.
        return [list [frost_x3_local_placement::slack -delay_type max] $tns $failing]
    }

    proc score_setup_closed {score} {
        return [expr {[llength $score] == 3 && [lindex $score 0] >= 0 &&
            [lindex $score 1] >= 0 && [lindex $score 2] == 0}]
    }

    proc score_improves {candidate baseline} {
        if {[llength $candidate] != 3 || [llength $baseline] != 3} {return 0}
        if {[score_setup_closed $candidate] && ![score_setup_closed $baseline]} {return 1}
        lassign $candidate wns tns
        lassign $baseline best_wns best_tns
        return [expr {$wns > $best_wns + 0.0005 ||
            (abs($wns - $best_wns) <= 0.0005 && $tns > $best_tns)}]
    }

    proc refine_clocks {work_directory sweep_uncertainty} {
        if {$work_directory eq "" || ![file isdirectory $work_directory]} {
            error "Routed clock refinement requires the build work directory"
        }
        set paths [get_timing_paths -quiet -group clock_from_mmcm -delay_type max \
            -slack_lesser_than 0.0 -max_paths 25 -nworst 1]
        if {![llength $paths] || [llength $paths] > 24} {return 0}
        # Convert Vivado object handles into names before any checkpoint reload.
        set endpoints [string trim [format "%s\n" [get_property ENDPOINT_PIN $paths]]]
        set prefix [file join $work_directory routed_clock_refine]
        set best_score [routed_score ${prefix}_initial]
        if {![llength $best_score]} {return 0}
        set checkpoint ${prefix}_best.dcp
        write_checkpoint -force $checkpoint
        set accepted 0
        set trial 0
        foreach endpoint_name $endpoints {
            set endpoint [frost_x3_local_placement::exact_objects get_pins [list $endpoint_name]]
            if {![llength [get_timing_paths -quiet -to $endpoint \
                -delay_type max -slack_lesser_than 0.0 -max_paths 1]]} {continue}
            set clk [get_clocks clock_from_mmcm]
            set ports [frost_x3_local_placement::port_constraints]
            set clocks [clock_signature]
            set group frost_endpoint_clock_individual
            set improved 0
            incr trial
            puts "FROST_ENDPOINT_PHYSOPT clock_trial=$trial endpoint=$endpoint_name"
            if {[catch {
                if {[llength [get_timing_paths -quiet -group $group -max_paths 1]]} {
                    error "Clock refinement would overwrite an active path group"
                }
                group_path -name $group -from $clk -to $endpoint
                try {
                    set_x3_setup_uncertainty x3 [expr {$sweep_uncertainty + 0.030}] \
                        "Individual clock optimization margin"
                    phys_opt_design -clock_opt -path_groups $group
                } finally {
                    try {
                        set endpoint [frost_x3_local_placement::exact_objects \
                            get_pins [list $endpoint_name]]
                        group_path -default -from $clk -to $endpoint
                        if {[llength [get_timing_paths -quiet -group $group -max_paths 1]]} {
                            error "Temporary clock group still owns paths"
                        }
                    } finally {
                        set_x3_setup_uncertainty x3 $sweep_uncertainty \
                            "Individual clock optimization scoring"
                    }
                }
                if {[clock_signature] ne $clocks ||
                    [frost_x3_local_placement::port_constraints] ne $ports} {
                    error "Clock refinement changed board pins or clock definitions"
                }
                set score [routed_score ${prefix}_[format %03d $trial]]
                if {[score_improves $score $best_score]} {
                    write_checkpoint -force $checkpoint
                    set best_score $score
                    set improved 1
                    incr accepted
                    puts "FROST_ENDPOINT_PHYSOPT accepted_clock=$endpoint_name WNS/TNS=[lrange $score 0 1]"
                }
            } reason options]} {
                puts "FROST_ENDPOINT_PHYSOPT rejected_clock=$endpoint_name reason=$reason"
                puts [dict get $options -errorinfo]
            }
            if {!$improved} {
                catch {close_design}
                open_checkpoint $checkpoint
            }
            if {[score_setup_closed $best_score]} {break}
        }
        return [expr {$accepted > 0}]
    }

    proc refine_pins {work_directory} {
        if {$work_directory eq "" || ![file isdirectory $work_directory]} {
            error "Routed LUT pin refinement requires the build work directory"
        }
        # This local search is for the last few failures, after the broader
        # optimizations. All candidates come from this design's timing report.
        set paths [get_timing_paths -quiet -group clock_from_mmcm -delay_type max \
            -slack_lesser_than 0.0 -max_paths 25 -nworst 1]
        if {![llength $paths] || [llength $paths] > 24} {return 0}
        set report [report_timing -max_paths 24 -nworst 1 -group clock_from_mmcm \
            -input_pins -return_string]
        set candidates [pin_candidates $report]
        if {![llength $candidates]} {return 0}
        set prefix [file join $work_directory routed_pin_refine]
        set best_score [routed_score ${prefix}_initial]
        if {![llength $best_score]} {return 0}
        set checkpoint ${prefix}_best.dcp
        write_checkpoint -force $checkpoint
        set accepted 0
        set trials 0
        # Try each physical input across all candidates, fastest input first.
        foreach target {A6 A5 A4} {
            foreach pin_name $candidates {
                set pin [get_pins -quiet [list $pin_name]]
                if {![llength $pin] || ![llength [get_timing_paths -quiet -through $pin \
                    -delay_type max -slack_lesser_than 0.0 -max_paths 1]]} {continue}
                incr trials
                set trial_prefix ${prefix}_[format %03d $trials]
                puts "FROST_ENDPOINT_PHYSOPT pin_trial=$trials pin=$pin_name target=$target"
                set improved 0
                if {[catch {
                    if {[remap_routed_pin $pin_name $target]} {
                        set score [routed_score $trial_prefix]
                        if {[score_improves $score $best_score]} {
                            write_checkpoint -force $checkpoint
                            set best_score $score
                            set improved 1
                            incr accepted
                            puts "FROST_ENDPOINT_PHYSOPT accepted_pin=$pin_name target=$target WNS/TNS=[lrange $score 0 1]"
                        }
                    }
                } reason options]} {
                    puts "FROST_ENDPOINT_PHYSOPT rejected_pin=$pin_name reason=$reason"
                    puts [dict get $options -errorinfo]
                }
                if {!$improved} {
                    catch {close_design}
                    open_checkpoint $checkpoint
                }
                if {[score_setup_closed $best_score]} {
                    break
                }
            }
            if {[score_setup_closed $best_score]} {break}
        }
        puts "FROST_ENDPOINT_PHYSOPT pin_refinement trials=$trials accepted=$accepted WNS/TNS=[lrange $best_score 0 1]"
        return [expr {$accepted > 0}]
    }

    proc bus_skew_is_legal {skew_file} {
        set fh [open $skew_file]
        set report [read $fh]
        close $fh
        set summary [dict create]
        set measured [dict create]
        set current ""
        set valid 1
        foreach line [split $report "\n"] {
            # The summary has one row per constraint, beginning with its ID
            # and XDC position. Require a detailed worst-path result for each.
            if {[regexp {^([0-9]+)\s+[0-9]+\s+\S} $line -> id]} {
                dict set summary $id 1
            }
            if {[regexp {^Id:\s+([0-9]+)\s*$} $line -> id]} {
                if {$current ne ""} {error "Missing bus-skew result for constraint $current"}
                set current $id
            }
            if {[regexp {^Slack \((MET|VIOLATED)\)\s*:\s*([-0-9.]+)ns} $line -> status slack]} {
                if {$current eq "" || [dict exists $measured $current]} {
                    error "Unexpected duplicate or unassociated bus-skew result"
                }
                dict set measured $current 1
                set current ""
                # The status catches a negative slack rounded to 0.000 ns.
                if {$status ne "MET" || $slack < 0} {set valid 0}
            }
        }
        # X3 has board and IP bus-skew constraints. Empty or truncated reports
        # cannot establish that those constraints are satisfied.
        if {$current ne "" || ![dict size $summary] ||
            [lsort -integer [dict keys $summary]] ne [lsort -integer [dict keys $measured]]} {
            error "Incomplete bus-skew report: $skew_file"
        }
        puts "FROST_ENDPOINT_PHYSOPT bus_skew_legal=$valid constraints=[dict size $summary]"
        return $valid
    }

    proc candidate_is_legal {timing_file route_file skew_file} {
        set fh [open $timing_file]
        set timing [string map {| " "} [read $fh]]
        close $fh
        # Read the whole-design row, after temporary groups and the added
        # margin have been removed. Setup improvement is scored by the caller.
        if {![regexp {WNS\(ns\)[^\n]*\n[^\n]*\n\s*([-0-9.]+)\s+([-0-9.]+)\s+(\d+)\s+(\d+)\s+([-0-9.]+)\s+([-0-9.]+)\s+(\d+)\s+(\d+)\s+([-0-9.]+)\s+([-0-9.]+)\s+(\d+)\s+(\d+)} $timing -> wns tns sf se whs ths hf he wpws tpws pf pe]} {
            error "Missing whole-design setup/hold/pulse-width summary: $timing_file"
        }
        set fh [open $route_file]
        set route [read $fh]
        close $fh
        foreach {key pattern} {
            errors {# of nets with routing errors\.+\s*:\s*(\d+)}
            routable {# of routable nets\.+\s*:\s*(\d+)}
            routed {# of fully routed nets\.+\s*:\s*(\d+)}
        } {
            if {![regexp $pattern $route -> $key]} {
                error "Missing route status $key: $route_file"
            }
        }
        set skew_valid [bus_skew_is_legal $skew_file]
        set valid [expr {$skew_valid && $whs >= 0 && $ths >= 0 && $hf == 0 &&
            $wpws >= 0 && $tpws >= 0 && $pf == 0 &&
            $errors == 0 && $routable > 0 && $routed == $routable}]
        puts "FROST_ENDPOINT_PHYSOPT legal=$valid WHS=$whs THS=$ths WPWS=$wpws routing_errors=$errors fully_routed=$routed/$routable"
        return $valid
    }
}

source [file join [file dirname [info script]] x3_route_refinement.tcl]
