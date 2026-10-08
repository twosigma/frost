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

# Rebuild a shared data route with its failing sink routed first. Unrouting
# only that sink retains the shared trunk and can reproduce the same delay.
namespace eval frost_x3_endpoint_physopt {
    proc route_net_eligible {net} {
        if {[llength $net] != 1 || [get_property TYPE $net] ne "SIGNAL" ||
            [string is true -strict [get_property DONT_TOUCH $net]] ||
            [string is true -strict [get_property IS_ROUTE_FIXED $net]]} {return 0}
        # LOGICAL_DRIVER alone is a root placeholder, with no physical route
        # nodes prescribed. Preserve it exactly after the temporary branch fix.
        set fixed [string trim [get_property FIXED_ROUTE $net] " \n\t\r{}"]
        return [expr {$fixed in {"" LOGICAL_DRIVER}}]
    }

    proc route_candidates {report} {
        set candidates [dict create]
        set failing 0
        set pending {}
        foreach line [split $report "\n"] {
            if {[regexp {^Slack \((MET|VIOLATED)\)\s*:\s*([-0-9.]+)ns} $line -> status slack]} {
                set failing [expr {$status eq "VIOLATED" || $slack < 0}]
                set pending {}
            }
            if {!$failing} {continue}
            if {[regexp {net \(fo=([0-9]+), routed\)\s+([-0-9.]+)\s+[-0-9.]+\s+\S+} $line -> fanout delay]} {
                set pending {}
                if {$delay >= 0.100 && $fanout >= 2 && $fanout <= 128} {
                    set pending $delay
                }
            }
            if {$pending eq "" || ![regexp {^\s+SLICE_X[0-9]+Y[0-9]+\s+[rf]\s+(\S+)$} $line -> pin_name]} {continue}
            set delay $pending
            set pending {}
            set pin [frost_x3_local_placement::exact_objects get_pins [list $pin_name]]
            set net [get_nets -quiet -top_net_of_hierarchical_group -of_objects $pin]
            if {![route_net_eligible $net]} {continue}
            set name [get_property NAME $net]
            # Reports are ordered by slack, so keep the worst sink of each
            # shared net. Names survive the checkpoint reload between trials.
            if {![dict exists $candidates $name]} {
                dict set candidates $name [list $delay $pin_name]
            }
        }
        set result {}
        foreach row [lsort -real -decreasing -index 0 [dict values $candidates]] {
            lappend result [lindex $row 1]
        }
        return $result
    }

    proc placement_signature {} {
        set cells [get_cells -hier -filter {IS_PRIMITIVE}]
        set result {}
        foreach name [get_property NAME $cells] ref [get_property REF_NAME $cells] \
            loc [get_property LOC $cells] bel [get_property BEL $cells] {
            lappend result [list $name $ref $loc $bel]
        }
        return [lsort -index 0 $result]
    }

    proc net_leaf_pins {net} {
        set pins [get_pins -quiet -leaf -of_objects [get_nets -segments $net]]
        if {![llength $pins]} {return {}}
        return [lsort -unique [get_property NAME $pins]]
    }

    proc timing_constraints {path} {
        write_xdc -type timing -constraints all -exclude_physical -no_tool_comments -force $path
        set fh [open $path]
        set text [read $fh]
        close $fh
        set result {}
        foreach line [split $text "\n"] {
            # Even -no_tool_comments retains a header naming the output file.
            if {[string match "#*" [string trimleft $line]] || [string trim $line] eq ""} {continue}
            lappend result $line
        }
        return $result
    }

    proc reroute_critical_sink {pin_name prefix} {
        set pin [frost_x3_local_placement::exact_objects get_pins [list $pin_name]]
        set net [get_nets -top_net_of_hierarchical_group -of_objects $pin]
        if {![route_net_eligible $net]} {error "Data route is constrained or ineligible"}
        set name [get_property NAME $net]
        set original_fixed [get_property FIXED_ROUTE $net]
        set original_flag [get_property IS_ROUTE_FIXED $net]
        set bindings [net_leaf_pins $net]
        set placements [placement_signature]
        set flags [frost_x3_local_placement::constraint_flags]
        set protected [frost_x3_local_placement::protected_nets]
        set fixed [frost_x3_local_placement::constrained_nets IS_ROUTE_FIXED]
        set ports [frost_x3_local_placement::port_constraints]
        set clocks [clock_signature]
        set constraints [timing_constraints ${prefix}_before.xdc]
        set routes [clock_routes]
        if {![dict size $routes]} {error "No clock routes to preserve"}
        dict for {clock saved} $routes {
            set_property IS_ROUTE_FIXED true \
                [frost_x3_local_placement::exact_objects get_nets [list $clock]]
        }
        # On any error the caller restores the entire saved checkpoint.
        route_design -unroute -nets $net
        route_design -pins $pin -delay
        set partial [get_property ROUTE $net]
        set nodes [get_nodes -quiet -of_objects $net]
        if {![llength $nodes]} {error "Critical sink has no routed nodes"}
        set nodes [get_property NAME $nodes]
        set_property FIXED_ROUTE $partial $net
        set_property IS_ROUTE_FIXED true $net
        route_design -preserve
        set net [frost_x3_local_placement::exact_objects get_nets [list $name]]
        set actual_nodes [get_nodes -quiet -of_objects $net]
        if {![llength $actual_nodes]} {error "Critical route disappeared"}
        set actual_nodes [get_property NAME $actual_nodes]
        foreach node $nodes {
            if {$node ni $actual_nodes} {error "Router replaced the fixed critical branch"}
        }
        set_property IS_ROUTE_FIXED false $net
        restore_property FIXED_ROUTE $original_fixed $net
        set_property IS_ROUTE_FIXED $original_flag $net
        restore_clock_routes $routes
        if {[get_property FIXED_ROUTE $net] ne $original_fixed ||
            [net_leaf_pins $net] ne $bindings ||
            [placement_signature] ne $placements ||
            [frost_x3_local_placement::constraint_flags] ne $flags ||
            [frost_x3_local_placement::protected_nets] ne $protected ||
            [frost_x3_local_placement::constrained_nets IS_ROUTE_FIXED] ne $fixed ||
            [frost_x3_local_placement::port_constraints] ne $ports ||
            [clock_signature] ne $clocks ||
            [timing_constraints ${prefix}_after.xdc] ne $constraints} {
            error "Critical routing changed placement, connections, or constraints"
        }
    }

    proc refine_routes {work_directory} {
        if {$work_directory eq "" || ![file isdirectory $work_directory]} {
            error "Routed net refinement requires the build work directory"
        }
        set paths [get_timing_paths -quiet -group clock_from_mmcm -delay_type max \
            -slack_lesser_than 0.0 -max_paths 25 -nworst 1]
        if {![llength $paths] || [llength $paths] > 24} {return 0}
        set report [report_timing -max_paths 24 -nworst 1 -group clock_from_mmcm \
            -input_pins -return_string]
        set candidates [route_candidates $report]
        if {![llength $candidates]} {return 0}
        set prefix [file join $work_directory routed_net_refine]
        set best_score [routed_score ${prefix}_initial]
        if {![llength $best_score]} {return 0}
        set checkpoint ${prefix}_best.dcp
        write_checkpoint -force $checkpoint
        set accepted 0
        set trial 0
        foreach pin_name $candidates {
            set pin [get_pins -quiet [list $pin_name]]
            if {![llength $pin] || ![llength [get_timing_paths -quiet -through $pin \
                -delay_type max -slack_lesser_than 0.0 -max_paths 1]]} {continue}
            incr trial
            set trial_prefix ${prefix}_[format %03d $trial]
            puts "FROST_ENDPOINT_PHYSOPT route_trial=$trial pin=$pin_name"
            set improved 0
            if {[catch {
                reroute_critical_sink $pin_name $trial_prefix
                set score [routed_score $trial_prefix]
                if {[score_improves $score $best_score]} {
                    write_checkpoint -force $checkpoint
                    set best_score $score
                    set improved 1
                    incr accepted
                    puts "FROST_ENDPOINT_PHYSOPT accepted_route=$pin_name WNS/TNS=[lrange $score 0 1]"
                }
            } reason options]} {
                puts "FROST_ENDPOINT_PHYSOPT rejected_route=$pin_name reason=$reason"
                puts [dict get $options -errorinfo]
            }
            if {!$improved} {
                catch {close_design}
                open_checkpoint $checkpoint
            }
            if {[score_setup_closed $best_score]} {break}
        }
        puts "FROST_ENDPOINT_PHYSOPT route_refinement trials=$trial accepted=$accepted WNS/TNS=[lrange $best_score 0 1]"
        return [expr {$accepted > 0}]
    }
}
