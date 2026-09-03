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

# Run one Vivado build step and directive; build.py uses this for parallel sweeps.

# Utilities

# Parse timing report to get number of failing setup endpoints
proc get_failing_endpoint_count {timing_report_file} {
    set setup_count 0

    set fh [open $timing_report_file r]
    set content [read $fh]
    close $fh

    set lines [split $content "\n"]
    set in_summary_table 0
    foreach line $lines {
        if {[string match "*TNS Failing Endpoints*" $line]} {
            set in_summary_table 1
            continue
        }
        if {$in_summary_table && [string match "*-------*" $line]} {
            continue
        }
        if {$in_summary_table && [string trim $line] ne ""} {
            set fields [regexp -all -inline -- {-?[0-9.]+} $line]
            if {[llength $fields] >= 3} {
                set setup_count [lindex $fields 2]
            }
            break
        }
    }

    return [expr {int($setup_count)}]
}

# Parse WNS/TNS from the Design Timing Summary setup row in a timing report.
proc get_setup_timing_summary {timing_report_file} {
    set result [dict create wns "" tns ""]

    if {![file exists $timing_report_file]} {
        return $result
    }

    set fh [open $timing_report_file r]
    set content [read $fh]
    close $fh

    set in_summary_table 0
    foreach line [split $content "\n"] {
        if {[string match "*WNS(ns)*TNS(ns)*" $line]} {
            set in_summary_table 1
            continue
        }

        if {!$in_summary_table} {
            continue
        }

        set trimmed [string trim $line]
        if {$trimmed eq "" || [string match "*---*" $trimmed]} {
            continue
        }

        set fields [regexp -all -inline -- {-?[0-9]+[.][0-9]+|-?[0-9]+} $trimmed]
        if {[llength $fields] >= 2} {
            dict set result wns [lindex $fields 0]
            dict set result tns [lindex $fields 1]
        }
        break
    }

    return $result
}

# Generate CSV report of failing setup timing paths
proc write_failing_paths_csv {output_file {timing_report_file ""}} {
    if {$timing_report_file ne "" && [file exists $timing_report_file]} {
        set max_paths [get_failing_endpoint_count $timing_report_file]
        puts "Detected $max_paths failing setup endpoints from timing report"
    } else {
        set max_paths 1000
    }

    if {$max_paths > 0} {
        set paths [get_timing_paths -max_paths $max_paths -slack_lesser_than 0 -delay_type max]
    } else {
        set paths {}
    }

    set fh [open $output_file w]

    puts $fh "slack_ns,requirement_ns,logic_delay_ns,net_delay_ns,logic_levels,routes,high_fanout,startpoint,endpoint,start_clock,end_clock,path_group"

    foreach path $paths {
        set slack [get_property SLACK $path]
        set requirement [get_property REQUIREMENT $path]
        set logic_delay [get_property DATAPATH_LOGIC_DELAY $path]
        set net_delay [get_property DATAPATH_NET_DELAY $path]
        set logic_levels [get_property LOGIC_LEVELS $path]
        set startpoint [get_property STARTPOINT_PIN $path]
        set endpoint [get_property ENDPOINT_PIN $path]
        set start_clk [get_property STARTPOINT_CLOCK $path]
        set end_clk [get_property ENDPOINT_CLOCK $path]
        set path_group [get_property GROUP $path]

        set nets [get_nets -of_objects $path -quiet]
        set routes [llength $nets]
        set high_fanout 0
        foreach net $nets {
            set fanout [get_property FLAT_PIN_COUNT $net]
            if {$fanout > $high_fanout} {
                set high_fanout $fanout
            }
        }

        puts $fh "$slack,$requirement,$logic_delay,$net_delay,$logic_levels,$routes,$high_fanout,\"$startpoint\",\"$endpoint\",$start_clk,$end_clk,$path_group"
    }

    close $fh
    puts "Wrote [llength $paths] failing setup paths to $output_file"
}

# Recursively read file list and expand nested file lists
proc flatten_rtl_file_list {file_list_path project_root} {
    set rtl_files_list {}
    set file_handle [open $file_list_path r]

    while {[gets $file_handle current_line] >= 0} {
        set current_line [string trim $current_line]
        if {$current_line eq "" || [string match "#*" $current_line]} {continue}

        set current_line [string map [list {$(ROOT)} $project_root] $current_line]

        if {[string match {-f *} $current_line]} {
            foreach {flag nested_file_list} $current_line {}
            lappend rtl_files_list {*}[flatten_rtl_file_list $nested_file_list $project_root]
        } elseif {[string match {+incdir+*} $current_line]} {
            lappend rtl_files_list $current_line
        } else {
            lappend rtl_files_list $current_line
        }
    }
    close $file_handle
    return $rtl_files_list
}

proc getenv_default {name default_value} {
    if {[info exists ::env($name)] && $::env($name) ne ""} {
        return $::env($name)
    }
    return $default_value
}

proc split_env_list {value} {
    set normalized [string map [list "," " "] $value]
    set result [list]
    foreach item [split $normalized] {
        set trimmed [string trim $item]
        if {$trimmed ne ""} {
            lappend result $trimmed
        }
    }
    return $result
}

proc get_cpu_timing_clock {} {
    set cpu_clock [get_clocks -quiet clock_from_mmcm]
    if {[llength $cpu_clock] > 0} {
        return $cpu_clock
    }

    set cpu_clock [get_clocks -quiet sysclk]
    if {[llength $cpu_clock] > 0} {
        return $cpu_clock
    }

    puts "WARNING: Could not find CPU timing clock clock_from_mmcm or sysclk"
    return {}
}

proc set_x3_setup_uncertainty {board_name uncertainty reason} {
    if {$board_name ne "x3"} {
        return
    }

    set cpu_clock [get_cpu_timing_clock]
    if {[llength $cpu_clock] == 0} {
        return
    }

    set_clock_uncertainty -from $cpu_clock -to $cpu_clock $uncertainty -setup
    puts "Set x3 CPU setup clock uncertainty to $uncertainty ns ($reason)"
}

# Validate the selected-PC endpoint family of the X3 metadata-to-PC cost group:
# one canonical FD* selected-PC endpoint per bit [63:0] (the PC carries the
# full architectural width since Phase 3 M2 retired the producer-side 32-bit
# masking), all on clock_from_mmcm, and no unexpected o_pc_reg* D-pin family
# beyond selected PC and the excluded o_pc_reg_reg state family.
proc validate_x3_pc_tail_scope {scope_label} {
    set selected_end_re {^.*/pc_controller_inst/o_pc_reg\[([0-9]+)\](_rep.*)?/D$}
    set state_end_re {^.*/pc_controller_inst/o_pc_reg_reg\[([0-9]+)\](_rep.*)?/D$}
    set broad_end_re {^.*/pc_controller_inst/o_pc_reg[^/]*/D$}

    set pc_tail_clock [get_clocks -quiet clock_from_mmcm]
    if {[llength $pc_tail_clock] != 1} {
        error "$scope_label X3 PC-tail scope expected one clock_from_mmcm, got [llength $pc_tail_clock]"
    }

    set selected_ends [get_pins -quiet -hierarchical -regexp $selected_end_re]
    set state_ends [get_pins -quiet -hierarchical -regexp $state_end_re]
    set broad_ends [get_pins -quiet -hierarchical -regexp $broad_end_re]
    set selected_end_names [lsort -unique [get_property NAME $selected_ends]]
    set state_end_names [lsort -unique [get_property NAME $state_ends]]
    set broad_end_names [lsort -unique [get_property NAME $broad_ends]]
    set allowed_end_names [lsort -unique [concat $selected_end_names $state_end_names]]

    if {[llength $allowed_end_names] != [llength $selected_end_names] + [llength $state_end_names]} {
        error "$scope_label X3 PC-tail selected and state endpoint families overlap"
    }
    if {$broad_end_names ne $allowed_end_names} {
        error "$scope_label X3 PC-tail broad endpoint family is not the selected/state disjoint union: broad=[llength $broad_end_names] selected=[llength $selected_end_names] state=[llength $state_end_names]"
    }

    set selected_bit_counts [dict create]
    set canonical_bit_counts [dict create]
    set canonical_end_names [list]
    foreach endpoint $selected_ends {
        set endpoint_name [get_property NAME $endpoint]
        if {![regexp $selected_end_re $endpoint_name -> bit_text replica_suffix]} {
            error "$scope_label X3 PC-tail endpoint escaped exact selected family: $endpoint_name"
        }
        if {[scan $bit_text %d bit_index] != 1 || $bit_index < 0 || $bit_index > 63} {
            error "$scope_label X3 PC-tail endpoint has out-of-range PC bit '$bit_text': $endpoint_name"
        }
        dict incr selected_bit_counts $bit_index
        if {$replica_suffix eq ""} {
            dict incr canonical_bit_counts $bit_index
            lappend canonical_end_names $endpoint_name
        }

        set endpoint_cells [get_cells -quiet -of_objects $endpoint]
        if {[llength $endpoint_cells] != 1} {
            error "$scope_label X3 PC-tail endpoint does not belong to exactly one cell: $endpoint_name"
        }
        set endpoint_ref_name [get_property REF_NAME $endpoint_cells]
        if {![string match "FD*" $endpoint_ref_name]} {
            error "$scope_label X3 PC-tail endpoint is not an FD* primitive ($endpoint_ref_name): $endpoint_name"
        }
        set endpoint_clock_pins [get_pins -quiet -of_objects $endpoint_cells -filter {IS_CLOCK == 1}]
        if {[llength $endpoint_clock_pins] != 1} {
            error "$scope_label X3 PC-tail endpoint does not have exactly one C pin: $endpoint_name"
        }
        set endpoint_clocks [get_clocks -quiet -of_objects $endpoint_clock_pins]
        set endpoint_clock_names [lsort -unique [get_property NAME $endpoint_clocks]]
        if {$endpoint_clock_names ne [list clock_from_mmcm]} {
            error "$scope_label X3 PC-tail endpoint is not clocked exactly by clock_from_mmcm ($endpoint_clock_names): $endpoint_name"
        }
    }

    if {[dict size $selected_bit_counts] != 64} {
        error "$scope_label X3 PC-tail selected endpoint family has [dict size $selected_bit_counts] PC bits, expected 64"
    }
    for {set bit_index 0} {$bit_index < 64} {incr bit_index} {
        if {![dict exists $selected_bit_counts $bit_index]} {
            error "$scope_label X3 PC-tail selected endpoint family is missing PC bit $bit_index"
        }
        if {![dict exists $canonical_bit_counts $bit_index] || [dict get $canonical_bit_counts $bit_index] != 1} {
            error "$scope_label X3 PC-tail PC bit $bit_index does not have exactly one canonical non-replica endpoint"
        }
    }

    return [dict create \
        ends $selected_ends \
        end_names $selected_end_names \
        canonical_end_names [lsort -unique $canonical_end_names] \
        pc_bits [dict size $selected_bit_counts]]
}

# Validate an indexed PC-state family, accepting placer replicas but no other
# namespace members. Each bit retains one canonical FD* CPU-clock endpoint.
proc validate_x3_pc_tail_indexed_family {
    scope_label family_label endpoint_re broad_end_re last_bit
} {
    set endpoints [get_pins -quiet -hierarchical -regexp $endpoint_re]
    set broad_ends [get_pins -quiet -hierarchical -regexp $broad_end_re]
    set endpoint_names [lsort -unique [get_property NAME $endpoints]]
    set broad_end_names [lsort -unique [get_property NAME $broad_ends]]
    if {$broad_end_names ne $endpoint_names} {
        error "$scope_label X3 $family_label broad endpoint namespace contains an unexpected family: broad=[llength $broad_end_names] exact=[llength $endpoint_names]"
    }

    set bit_counts [dict create]
    set canonical_bit_counts [dict create]
    set canonical_end_names [list]
    foreach endpoint $endpoints {
        set endpoint_name [get_property NAME $endpoint]
        if {![regexp $endpoint_re $endpoint_name -> bit_text replica_suffix]} {
            error "$scope_label X3 $family_label endpoint escaped its exact family: $endpoint_name"
        }
        if {[scan $bit_text %d bit_index] != 1 || $bit_index < 0 || $bit_index > $last_bit} {
            error "$scope_label X3 $family_label endpoint has out-of-range bit '$bit_text': $endpoint_name"
        }
        dict incr bit_counts $bit_index
        if {$replica_suffix eq ""} {
            dict incr canonical_bit_counts $bit_index
            lappend canonical_end_names $endpoint_name
        }

        set endpoint_cells [get_cells -quiet -of_objects $endpoint]
        if {[llength $endpoint_cells] != 1} {
            error "$scope_label X3 $family_label endpoint does not belong to exactly one cell: $endpoint_name"
        }
        set endpoint_ref_name [get_property REF_NAME $endpoint_cells]
        if {![string match "FD*" $endpoint_ref_name]} {
            error "$scope_label X3 $family_label endpoint is not an FD* primitive ($endpoint_ref_name): $endpoint_name"
        }
        set endpoint_clock_pins [get_pins -quiet -of_objects $endpoint_cells -filter {IS_CLOCK == 1}]
        if {[llength $endpoint_clock_pins] != 1} {
            error "$scope_label X3 $family_label endpoint does not have exactly one C pin: $endpoint_name"
        }
        set endpoint_clocks [get_clocks -quiet -of_objects $endpoint_clock_pins]
        set endpoint_clock_names [lsort -unique [get_property NAME $endpoint_clocks]]
        if {$endpoint_clock_names ne [list clock_from_mmcm]} {
            error "$scope_label X3 $family_label endpoint is not clocked exactly by clock_from_mmcm ($endpoint_clock_names): $endpoint_name"
        }
    }

    set expected_bit_count [expr {$last_bit + 1}]
    if {[dict size $bit_counts] != $expected_bit_count} {
        error "$scope_label X3 $family_label endpoint family has [dict size $bit_counts] bits, expected $expected_bit_count"
    }
    for {set bit_index 0} {$bit_index <= $last_bit} {incr bit_index} {
        if {![dict exists $bit_counts $bit_index]} {
            error "$scope_label X3 $family_label endpoint family is missing bit $bit_index"
        }
        if {![dict exists $canonical_bit_counts $bit_index] || [dict get $canonical_bit_counts $bit_index] != 1} {
            error "$scope_label X3 $family_label bit $bit_index does not have exactly one canonical non-replica endpoint"
        }
    }

    return [dict create \
        ends $endpoints \
        end_names $endpoint_names \
        canonical_end_names [lsort -unique $canonical_end_names] \
        bits [dict size $bit_counts]]
}

# Validate a scalar PC-control family: one canonical endpoint plus optional
# placer replicas, with no unmatched suffix family.
proc validate_x3_pc_tail_scalar_family {
    scope_label family_label endpoint_re broad_end_re
} {
    set endpoints [get_pins -quiet -hierarchical -regexp $endpoint_re]
    set broad_ends [get_pins -quiet -hierarchical -regexp $broad_end_re]
    set endpoint_names [lsort -unique [get_property NAME $endpoints]]
    set broad_end_names [lsort -unique [get_property NAME $broad_ends]]
    if {$broad_end_names ne $endpoint_names} {
        error "$scope_label X3 $family_label broad endpoint namespace contains an unexpected family: broad=[llength $broad_end_names] exact=[llength $endpoint_names]"
    }

    set canonical_count 0
    set canonical_end_names [list]
    foreach endpoint $endpoints {
        set endpoint_name [get_property NAME $endpoint]
        if {![regexp $endpoint_re $endpoint_name -> replica_suffix]} {
            error "$scope_label X3 $family_label endpoint escaped its exact family: $endpoint_name"
        }
        if {$replica_suffix eq ""} {
            incr canonical_count
            lappend canonical_end_names $endpoint_name
        }

        set endpoint_cells [get_cells -quiet -of_objects $endpoint]
        if {[llength $endpoint_cells] != 1} {
            error "$scope_label X3 $family_label endpoint does not belong to exactly one cell: $endpoint_name"
        }
        set endpoint_ref_name [get_property REF_NAME $endpoint_cells]
        if {![string match "FD*" $endpoint_ref_name]} {
            error "$scope_label X3 $family_label endpoint is not an FD* primitive ($endpoint_ref_name): $endpoint_name"
        }
        set endpoint_clock_pins [get_pins -quiet -of_objects $endpoint_cells -filter {IS_CLOCK == 1}]
        if {[llength $endpoint_clock_pins] != 1} {
            error "$scope_label X3 $family_label endpoint does not have exactly one C pin: $endpoint_name"
        }
        set endpoint_clocks [get_clocks -quiet -of_objects $endpoint_clock_pins]
        set endpoint_clock_names [lsort -unique [get_property NAME $endpoint_clocks]]
        if {$endpoint_clock_names ne [list clock_from_mmcm]} {
            error "$scope_label X3 $family_label endpoint is not clocked exactly by clock_from_mmcm ($endpoint_clock_names): $endpoint_name"
        }
    }
    if {[llength $endpoints] < 1 || $canonical_count != 1} {
        error "$scope_label X3 $family_label expected at least one endpoint and exactly one canonical endpoint: total=[llength $endpoints] canonical=$canonical_count"
    }

    return [dict create \
        ends $endpoints \
        end_names $endpoint_names \
        canonical_end_names [lsort -unique $canonical_end_names] \
        canonical $canonical_count]
}

# Existence and namespace checks alone cannot distinguish a preserved but
# disconnected launch from a live timing source. Require an independently
# discoverable max path from every launch to its intended endpoint family at
# every pre-place, post-place, and clean-reopen validation point.
proc validate_x3_pc_tail_start_connectivity {
    scope_label family_label starts ends
} {
    set connected 0
    foreach start $starts {
        set path [get_timing_paths -quiet -delay_type max \
            -from $start -to $ends -max_paths 1 -nworst 1]
        if {[llength $path] != 1} {
            error "$scope_label X3 $family_label launch has no timing path to its endpoint family: [get_property NAME $start]"
        }
        incr connected
    }
    return $connected
}

# Discover the X3 metadata-to-PC cost group: the fourteen pinned scalar LUTRAM
# overlay output-FF launches of the predecode metadata (seven sideband
# predicates on both IMEM parities, imem_predecode.sv) feeding four disjoint PC
# state/control families. Historical ``compressed`` procedure, key, group,
# audit, and report names remain part of the artifact schema.
proc validate_x3_pc_compressed_tail_scope {scope_label} {
    set compressed_start_re {^.*/instruction_memory/u_(even|odd)_(is_compressed_lo|is_compressed_hi|even_local_pair_valid|pairable_native_lo|pairable_compressed_hi|pairable_native_hi|slot2_start_valid_lo)_bank/read_q_reg/C$}
    set state_end_re {^.*/pc_controller_inst/o_pc_reg_reg\[([0-9]+)\](_rep.*)?/D$}
    set state_broad_end_re {^.*/pc_controller_inst/o_pc_reg_reg[^/]*/D$}
    set seq_end_re {^.*/pc_controller_inst/seq_next_pc_reg_hw_q_reg\[([0-9]+)\](_rep.*)?/D$}
    set seq_broad_end_re {^.*/pc_controller_inst/seq_next_pc_reg_hw_q_reg[^/]*/D$}
    set pending_end_re {^.*/pc_controller_inst/pending_prediction_valid_reg(_rep.*)?/D$}
    set pending_broad_end_re {^.*/pc_controller_inst/pending_prediction_valid_reg[^/]*/D$}

    set selected_scope [validate_x3_pc_tail_scope $scope_label]
    set expected_compressed_start_keys [list]
    foreach predicate [list is_compressed_lo is_compressed_hi even_local_pair_valid \
                           pairable_native_lo pairable_compressed_hi pairable_native_hi \
                           slot2_start_valid_lo] {
        foreach parity [list even odd] {
            lappend expected_compressed_start_keys "$predicate:$parity"
        }
    }
    set compressed_starts [get_pins -quiet -hierarchical -regexp $compressed_start_re]
    set compressed_start_counts [dict create]
    foreach start $compressed_starts {
        set start_name [get_property NAME $start]
        if {![regexp $compressed_start_re $start_name -> parity predicate]} {
            error "$scope_label X3 PC-metadata tail launch escaped its exact family: $start_name"
        }
        dict incr compressed_start_counts "$predicate:$parity"
    }
    foreach expected_key $expected_compressed_start_keys {
        if {![dict exists $compressed_start_counts $expected_key] || [dict get $compressed_start_counts $expected_key] != 1} {
            error "$scope_label X3 PC-metadata tail launch '$expected_key' did not match exactly once"
        }
    }
    set expected_start_count [llength $expected_compressed_start_keys]
    if {[llength $compressed_starts] != $expected_start_count || [dict size $compressed_start_counts] != $expected_start_count} {
        error "$scope_label X3 PC-metadata tail launch scope mismatch: starts=[llength $compressed_starts] keys=[dict size $compressed_start_counts] expected=$expected_start_count"
    }

    set state_scope [validate_x3_pc_tail_indexed_family \
        $scope_label o_pc_reg_reg $state_end_re $state_broad_end_re 63]
    set seq_scope [validate_x3_pc_tail_indexed_family \
        $scope_label seq_next_pc_reg_hw_q $seq_end_re $seq_broad_end_re 62]
    set pending_scope [validate_x3_pc_tail_scalar_family \
        $scope_label pending_prediction_valid $pending_end_re $pending_broad_end_re]

    set compressed_start_names [lsort -unique [get_property NAME $compressed_starts]]

    set selected_end_names [dict get $selected_scope end_names]
    set state_end_names [dict get $state_scope end_names]
    set seq_end_names [dict get $seq_scope end_names]
    set pending_end_names [dict get $pending_scope end_names]
    set union_end_names [lsort -unique [concat \
        $selected_end_names $state_end_names $seq_end_names $pending_end_names]]
    set component_end_count [expr {
        [llength $selected_end_names] + [llength $state_end_names] +
        [llength $seq_end_names] + [llength $pending_end_names]
    }]
    if {[llength $union_end_names] != $component_end_count} {
        error "$scope_label X3 PC-metadata tail endpoint families overlap"
    }

    set compressed_connected_starts [validate_x3_pc_tail_start_connectivity \
        $scope_label PC-metadata-tail $compressed_starts \
        [concat \
            [dict get $selected_scope ends] [dict get $state_scope ends] \
            [dict get $seq_scope ends] [dict get $pending_scope ends]]]

    return [dict create \
        compressed_starts $compressed_starts \
        compressed_start_names $compressed_start_names \
        selected_ends [dict get $selected_scope ends] \
        selected_end_names $selected_end_names \
        selected_canonical_end_names [dict get $selected_scope canonical_end_names] \
        selected_bits [dict get $selected_scope pc_bits] \
        state_ends [dict get $state_scope ends] \
        state_end_names $state_end_names \
        state_canonical_end_names [dict get $state_scope canonical_end_names] \
        state_bits [dict get $state_scope bits] \
        seq_ends [dict get $seq_scope ends] \
        seq_end_names $seq_end_names \
        seq_canonical_end_names [dict get $seq_scope canonical_end_names] \
        seq_bits [dict get $seq_scope bits] \
        pending_ends [dict get $pending_scope ends] \
        pending_end_names $pending_end_names \
        pending_canonical_end_names [dict get $pending_scope canonical_end_names] \
        pending_canonical [dict get $pending_scope canonical] \
        compressed_connected_starts $compressed_connected_starts \
        union_ends [concat \
            [dict get $selected_scope ends] [dict get $state_scope ends] \
            [dict get $seq_scope ends] [dict get $pending_scope ends]] \
        union_end_names $union_end_names]
}

proc write_physopt_iteration_outputs {work_directory step board_name physopt_uncertainty best_wns continue_sweeps} {
    if {$physopt_uncertainty ne ""} {
        set_x3_setup_uncertainty $board_name 0.0 "$step report"
    }

    set checkpoint_file [file join $work_directory phys_opt.dcp]
    set timing_file [file join $work_directory phys_opt_timing.rpt]
    set util_file [file join $work_directory phys_opt_util.rpt]
    set high_fanout_file [file join $work_directory phys_opt_high_fanout.rpt]
    set failing_paths_file [file join $work_directory phys_opt_failing_paths.csv]

    write_checkpoint -force $checkpoint_file
    report_timing_summary -file $timing_file
    report_utilization -file $util_file
    report_high_fanout_nets -timing -load_types -max_nets 50 -file $high_fanout_file
    write_failing_paths_csv $failing_paths_file $timing_file

    set main_work_directory [file join [file dirname $work_directory] work]
    file mkdir $main_work_directory

    set main_checkpoint_name ${step}.dcp
    set main_report_prefix $step
    set timing_met [expr {$best_wns ne "" && $best_wns >= 0.0}]
    if {$step eq "post_second_route_physopt" || ($step eq "post_route_physopt" && $timing_met)} {
        set main_checkpoint_name final.dcp
        set main_report_prefix final
    }

    file copy -force $checkpoint_file [file join $main_work_directory $main_checkpoint_name]
    foreach suffix [list _timing.rpt _util.rpt _high_fanout.rpt _failing_paths.csv] {
        file copy -force [file join $work_directory "phys_opt$suffix"] [file join $main_work_directory "$main_report_prefix$suffix"]
    }

    puts ""
    puts "  Wrote completed $step iteration output:"
    puts "    $checkpoint_file"
    puts "    [file join $main_work_directory $main_checkpoint_name]"

    if {$continue_sweeps && $physopt_uncertainty ne ""} {
        set_x3_setup_uncertainty $board_name $physopt_uncertainty "$step overconstraint"
    }
}

# Arguments

# Arguments: board_name step directive checkpoint_path retiming ?software_mem_dir?
if {$argc < 5} {
    puts "Error: Required arguments: board_name step directive checkpoint_path retiming"
    puts "Usage: vivado -mode batch -source build_step.tcl -tclargs <board_name> <step> <directive> <checkpoint_path> <retiming> ?software_mem_dir?"
    puts ""
    puts "Steps: synth, opt, place, quick_route, post_place_physopt, route, post_route_physopt, second_route, post_second_route_physopt, bitstream"
    exit 1
}

set board_name [lindex $argv 0]
set step [lindex $argv 1]
set directive [lindex $argv 2]
set checkpoint_path [lindex $argv 3]
set retiming [lindex $argv 4]
set software_mem_directory ""

if {$board_name ne "x3" && $board_name ne "genesys2"} {
    puts "Error: Invalid board name '$board_name'"
    puts "Valid boards: x3, genesys2"
    exit 1
}

# Board configuration

if {$board_name eq "genesys2"} {
    set fpga_part_number xc7k325tffg900-2
    set top_level_module_name genesys2_frost
} elseif {$board_name eq "x3"} {
    set fpga_part_number xcux35-vsva1365-3-e
    set top_level_module_name x3_frost
}

set number_of_parallel_jobs 32

# Directories

# build.py sets the working directory.
set work_directory [pwd]
set script_directory [file dirname [file normalize [info script]]]
set project_root_directory [file dirname $script_directory/../../../]
set board_specific_directory [file join $project_root_directory boards/$board_name]
set rtl_file_list [file join $board_specific_directory ${board_name}_frost.f]
set constraints_file [file join $board_specific_directory constr/${board_name}.xdc]
if {$argc >= 6} {
    set software_mem_directory [file normalize [lindex $argv 5]]
} else {
    set software_mem_directory [file join $project_root_directory sw/apps/hello_world]
}

puts "=========================================="
puts "Board: $board_name"
puts "Step: $step"
puts "Directive: $directive"
puts "FPGA Part: $fpga_part_number"
puts "Work directory: $work_directory"
puts "Software memory directory: $software_mem_directory"
if {$checkpoint_path ne ""} {
    puts "Input checkpoint: $checkpoint_path"
}
puts "=========================================="

# Step execution

if {$step eq "synth"} {
    # Synthesis
    set_param general.maxThreads $number_of_parallel_jobs
    create_project -part $fpga_part_number -force tmp_proj $work_directory/vivado_proj
    set_property IP_OUTPUT_REPO $work_directory/vivado_proj/ip_cache [current_project]

    # Create IP cores
    create_ip -name jtag_axi -vendor xilinx.com -library ip -version 1.2 -module_name jtag_axi_0
    set_property -dict [list \
        CONFIG.PROTOCOL {2} \
        CONFIG.M_AXI_DATA_WIDTH {32} \
        CONFIG.M_AXI_ADDR_WIDTH {32} \
    ] [get_ips jtag_axi_0]

    create_ip -name axi_bram_ctrl -vendor xilinx.com -library ip -version 4.1 -module_name axi_bram_ctrl_0
    set_property -dict [list \
        CONFIG.PROTOCOL {AXI4LITE} \
        CONFIG.SINGLE_PORT_BRAM {1} \
        CONFIG.MEM_DEPTH {65536} \
    ] [get_ips axi_bram_ctrl_0]

    generate_target all [get_ips]
    synth_ip [get_ips]

    if {$board_name eq "genesys2"} {
        # genesys2_ddr_bd.tcl builds MIG, SmartConnect, JTAG loader, and reset
        # sequencing; genesys2_frost.sv instantiates its generated wrapper.
        read_verilog ${project_root_directory}/boards/genesys2/mem_reset_control.v
        source [file join [file dirname [info script]] genesys2_ddr_bd.tcl]
        create_genesys2_ddr_bd
        # Synthesize BD children globally; this flow never creates OOC IP runs.
        set_property synth_checkpoint_mode None [get_files ddr_subsys.bd]
        generate_target all [get_files ddr_subsys.bd]
        set ddr_subsys_wrapper [make_wrapper -files [get_files ddr_subsys.bd] -top]
        add_files -norecurse $ddr_subsys_wrapper
    }

    if {$board_name eq "x3"} {
        # x3_ddr_bd.tcl builds the DDR4 controller, SmartConnect, and JTAG loader;
        # x3_frost.sv instantiates its wrapper and x3.xdc constrains the pins.
        source [file join [file dirname [info script]] x3_ddr_bd.tcl]
        create_x3_ddr_bd
        set_property synth_checkpoint_mode None [get_files ddr_subsys.bd]
        generate_target all [get_files ddr_subsys.bd]
        set ddr_subsys_wrapper [make_wrapper -files [get_files ddr_subsys.bd] -top]
        add_files -norecurse $ddr_subsys_wrapper
    }

    set rtl_source_files [flatten_rtl_file_list $rtl_file_list $project_root_directory]

    # Enable Xilinx primitives and Vivado initialization only in this flow.
    set current_verilog_defines [get_property verilog_define [current_fileset]]
    if {$current_verilog_defines eq ""} {
        set current_verilog_defines [list]
    }
    foreach define_name {FROST_XILINX_PRIMS FROST_VIVADO_SYNTH} {
        if {[lsearch -exact $current_verilog_defines $define_name] < 0} {
            lappend current_verilog_defines $define_name
        }
    }
    set_property verilog_define $current_verilog_defines [current_fileset]

    read_verilog {*}$rtl_source_files
    read_mem [file join $software_mem_directory sw.mem]
    read_mem [file join $software_mem_directory sw_imem_even_cold.mem]
    read_mem [file join $software_mem_directory sw_imem_odd_cold.mem]
    read_mem [file join $software_mem_directory sw_imem_even_frontend_hot.mem]
    read_mem [file join $software_mem_directory sw_imem_odd_frontend_hot.mem]
    read_mem [file join $software_mem_directory sw_imem_even_sideband.mem]
    read_mem [file join $software_mem_directory sw_imem_odd_sideband.mem]
    read_mem [file join $software_mem_directory sw_imem_even_compressed.mem]
    read_mem [file join $software_mem_directory sw_imem_odd_compressed.mem]
    # One scalar LUTRAM overlay image per sideband predicate and parity bank.
    foreach scalar_replica [list is_compressed_lo is_compressed_hi even_local_pair_valid \
                                 pairable_native_lo pairable_compressed_hi pairable_native_hi \
                                 slot2_start_valid_lo] {
        read_mem [file join $software_mem_directory sw_imem_even_${scalar_replica}.mem]
        read_mem [file join $software_mem_directory sw_imem_odd_${scalar_replica}.mem]
    }
    read_xdc $constraints_file
    set_property top $top_level_module_name [current_fileset]

    set synth_args [list -top $top_level_module_name -part $fpga_part_number -directive $directive]
    if {$retiming eq "1"} {
        lappend synth_args -global_retiming on
    }
    synth_design {*}$synth_args

    write_checkpoint -force $work_directory/post_synth.dcp
    report_timing_summary -file $work_directory/post_synth_timing.rpt
    report_utilization -file $work_directory/post_synth_util.rpt
    report_high_fanout_nets -timing -load_types -max_nets 50 -file $work_directory/post_synth_high_fanout.rpt
    write_failing_paths_csv $work_directory/post_synth_failing_paths.csv $work_directory/post_synth_timing.rpt

    puts "** DONE — synthesis complete with directive: $directive"

} elseif {$step eq "opt"} {
    # Logic optimization
    if {$checkpoint_path eq ""} {
        puts "Error: opt step requires checkpoint_path"
        exit 1
    }
    open_checkpoint $checkpoint_path

    # opt_design -merge_equivalent_drivers -hier_fanout_limit 512
    opt_design -directive $directive

    write_checkpoint -force $work_directory/post_opt.dcp
    report_timing_summary -file $work_directory/post_opt_timing.rpt
    report_utilization -file $work_directory/post_opt_util.rpt
    report_high_fanout_nets -timing -load_types -max_nets 50 -file $work_directory/post_opt_high_fanout.rpt
    write_failing_paths_csv $work_directory/post_opt_failing_paths.csv $work_directory/post_opt_timing.rpt

    puts "** DONE — opt_design complete with directive: $directive"

} elseif {$step eq "place"} {
    # Placement
    if {$checkpoint_path eq ""} {
        puts "Error: place step requires checkpoint_path"
        exit 1
    }
    open_checkpoint $checkpoint_path

    # Optional UG904 CELL_BLOAT_FACTOR for wire-dense hierarchies. Enable with
    # FROST_PLACE_CELL_BLOAT=LOW/MEDIUM/HIGH; FROST_PLACE_CELL_BLOAT_CELLS
    # overrides the default integer-RS hotspot glob.
    set cell_bloat [string toupper [getenv_default FROST_PLACE_CELL_BLOAT ""]]
    if {$cell_bloat ne ""} {
        if {[lsearch -exact {LOW MEDIUM HIGH} $cell_bloat] < 0} {
            puts "Error: FROST_PLACE_CELL_BLOAT must be LOW, MEDIUM, or HIGH (got '$cell_bloat')"
            exit 1
        }
        set bloat_patterns [split_env_list [getenv_default FROST_PLACE_CELL_BLOAT_CELLS "*u_tomasulo/u_int_rs"]]
        foreach bloat_pattern $bloat_patterns {
            set bloat_cells [get_cells -quiet -hierarchical -filter "NAME =~ $bloat_pattern"]
            if {[llength $bloat_cells] == 0} {
                puts "WARNING: FROST_PLACE_CELL_BLOAT pattern '$bloat_pattern' matched no cells"
                continue
            }
            set_property CELL_BLOAT_FACTOR $cell_bloat $bloat_cells
            puts "Set CELL_BLOAT_FACTOR $cell_bloat on [llength $bloat_cells] cell(s) matching '$bloat_pattern'"
        }
    }

    # X3 needs setup overconstraint for 300 MHz. build.py varies it downward
    # from 0.500 ns in 0.050 ns steps as surrogate seeds and to ease packing.
    # Keep this baseline synchronized with X3_PLACE_BASELINE_UNCERTAINTY_NS.
    set x3_place_baseline_uncertainty 0.5
    set x3_place_uncertainty [getenv_default FROST_PLACE_SETUP_UNCERTAINTY $x3_place_baseline_uncertainty]
    set_x3_setup_uncertainty $board_name $x3_place_uncertainty "place overconstraint"

    # Qualified X3 seeds use one PC-tail placer cost group, not timing
    # exceptions: the fourteen predecode-metadata scalar launches to selected,
    # state, sequential, and pending-valid consumers. Remove it after placement
    # and verify all paths return to clock_from_mmcm on a clean reopen.
    # Qualified solutions: ExtraNetDelay_high/0.500 (the accepted control),
    # ExtraPostPlacementOpt/0.450, and ExtraPostPlacementOpt/0.425. The 0.425
    # seed is the phase11 off-grid seed that first passed the post-demolition
    # gate under the then-active fetch pblock (score -0.699, raw -0.199;
    # 2026-08-20) and routed to closure. It remains competitive after that
    # pblock's retirement, so build.py appends 0.425 through
    # X3_PLACE_EXTRA_SEED_CANDIDATES.
    set use_x3_pc_tail_group [expr {
        $board_name eq "x3" &&
        (($directive eq "ExtraNetDelay_high" &&
          abs(double($x3_place_uncertainty) - double($x3_place_baseline_uncertainty)) < 1.0e-9) ||
         ($directive eq "ExtraPostPlacementOpt" &&
          (abs(double($x3_place_uncertainty) - 0.450) < 1.0e-9 ||
           abs(double($x3_place_uncertainty) - 0.425) < 1.0e-9)))
    }]
    if {$use_x3_pc_tail_group} {
        set_param general.maxThreads 8
        set x3_pc_tail_scope [validate_x3_pc_compressed_tail_scope "pre-place"]
        set x3_pc_compressed_tail_starts [dict get $x3_pc_tail_scope compressed_starts]
        set x3_pc_tail_ends [dict get $x3_pc_tail_scope selected_ends]
        set x3_pc_compressed_tail_ends [dict get $x3_pc_tail_scope union_ends]
        set x3_pc_compressed_tail_pre_start_count [llength $x3_pc_compressed_tail_starts]
        set x3_pc_compressed_tail_pre_start_names [dict get $x3_pc_tail_scope compressed_start_names]
        set x3_pc_tail_pre_end_count [llength $x3_pc_tail_ends]
        set x3_pc_tail_pre_canonical_end_names [dict get $x3_pc_tail_scope selected_canonical_end_names]
        set x3_pc_tail_pre_bit_count [dict get $x3_pc_tail_scope selected_bits]
        set x3_pc_tail_pre_state_end_count [llength [dict get $x3_pc_tail_scope state_ends]]
        set x3_pc_tail_pre_state_canonical_end_names [dict get $x3_pc_tail_scope state_canonical_end_names]
        set x3_pc_tail_pre_state_bit_count [dict get $x3_pc_tail_scope state_bits]
        set x3_pc_tail_pre_seq_end_count [llength [dict get $x3_pc_tail_scope seq_ends]]
        set x3_pc_tail_pre_seq_canonical_end_names [dict get $x3_pc_tail_scope seq_canonical_end_names]
        set x3_pc_tail_pre_seq_bit_count [dict get $x3_pc_tail_scope seq_bits]
        set x3_pc_tail_pre_pending_end_count [llength [dict get $x3_pc_tail_scope pending_ends]]
        set x3_pc_tail_pre_pending_canonical_end_names [dict get $x3_pc_tail_scope pending_canonical_end_names]
        set x3_pc_tail_pre_pending_canonical [dict get $x3_pc_tail_scope pending_canonical]
        set x3_pc_tail_pre_union_end_count [llength $x3_pc_compressed_tail_ends]
        puts "FROST_PC_TAIL_PRE_SCOPE compressed_starts=$x3_pc_compressed_tail_pre_start_count selected=$x3_pc_tail_pre_end_count state=$x3_pc_tail_pre_state_end_count seq=$x3_pc_tail_pre_seq_end_count pending=$x3_pc_tail_pre_pending_end_count union=$x3_pc_tail_pre_union_end_count"
        group_path -name frost_pc_compressed_tail -from $x3_pc_compressed_tail_starts -to $x3_pc_compressed_tail_ends
    }

    place_design -directive $directive

    if {$use_x3_pc_tail_group} {
        # Reacquire PSIP-created/removed/renamed replicas before restoring the
        # clock group. Canonical endpoints remain exact; replica names may vary.
        set x3_pc_tail_scope_after [validate_x3_pc_compressed_tail_scope "post-place"]
        set x3_pc_compressed_tail_starts_after [dict get $x3_pc_tail_scope_after compressed_starts]
        set x3_pc_tail_ends_after [dict get $x3_pc_tail_scope_after selected_ends]
        set x3_pc_compressed_tail_ends_after [dict get $x3_pc_tail_scope_after union_ends]
        set x3_pc_compressed_tail_post_start_count [llength $x3_pc_compressed_tail_starts_after]
        set x3_pc_compressed_tail_post_start_names [dict get $x3_pc_tail_scope_after compressed_start_names]
        set x3_pc_tail_post_end_count [llength $x3_pc_tail_ends_after]
        set x3_pc_tail_post_end_names [dict get $x3_pc_tail_scope_after selected_end_names]
        set x3_pc_tail_post_canonical_end_names [dict get $x3_pc_tail_scope_after selected_canonical_end_names]
        set x3_pc_tail_post_bit_count [dict get $x3_pc_tail_scope_after selected_bits]
        set x3_pc_tail_post_state_end_count [llength [dict get $x3_pc_tail_scope_after state_ends]]
        set x3_pc_tail_post_state_end_names [dict get $x3_pc_tail_scope_after state_end_names]
        set x3_pc_tail_post_state_canonical_end_names [dict get $x3_pc_tail_scope_after state_canonical_end_names]
        set x3_pc_tail_post_state_bit_count [dict get $x3_pc_tail_scope_after state_bits]
        set x3_pc_tail_post_seq_end_count [llength [dict get $x3_pc_tail_scope_after seq_ends]]
        set x3_pc_tail_post_seq_end_names [dict get $x3_pc_tail_scope_after seq_end_names]
        set x3_pc_tail_post_seq_canonical_end_names [dict get $x3_pc_tail_scope_after seq_canonical_end_names]
        set x3_pc_tail_post_seq_bit_count [dict get $x3_pc_tail_scope_after seq_bits]
        set x3_pc_tail_post_pending_end_count [llength [dict get $x3_pc_tail_scope_after pending_ends]]
        set x3_pc_tail_post_pending_end_names [dict get $x3_pc_tail_scope_after pending_end_names]
        set x3_pc_tail_post_pending_canonical_end_names [dict get $x3_pc_tail_scope_after pending_canonical_end_names]
        set x3_pc_tail_post_pending_canonical [dict get $x3_pc_tail_scope_after pending_canonical]
        set x3_pc_tail_post_union_end_count [llength $x3_pc_compressed_tail_ends_after]
        set x3_pc_tail_post_union_end_names [dict get $x3_pc_tail_scope_after union_end_names]
        if {$x3_pc_compressed_tail_post_start_names ne $x3_pc_compressed_tail_pre_start_names} {
            error "post-place X3 PC-metadata tail start names differ from the pre-place scope"
        }
        if {$x3_pc_tail_post_canonical_end_names ne $x3_pc_tail_pre_canonical_end_names} {
            error "post-place X3 selected PC-tail canonical endpoint names differ from the pre-place scope"
        }
        if {$x3_pc_tail_post_state_canonical_end_names ne $x3_pc_tail_pre_state_canonical_end_names} {
            error "post-place X3 state PC-tail canonical endpoint names differ from the pre-place scope"
        }
        if {$x3_pc_tail_post_seq_canonical_end_names ne $x3_pc_tail_pre_seq_canonical_end_names} {
            error "post-place X3 sequential PC-tail canonical endpoint names differ from the pre-place scope"
        }
        if {$x3_pc_tail_post_pending_canonical_end_names ne $x3_pc_tail_pre_pending_canonical_end_names} {
            error "post-place X3 pending PC-tail canonical endpoint names differ from the pre-place scope"
        }
        group_path -default -from $x3_pc_compressed_tail_starts_after -to $x3_pc_compressed_tail_ends_after
    }

    # Restore 0.5 ns for equal scoring and post-place phys-opt; route clears it.
    set_x3_setup_uncertainty $board_name $x3_place_baseline_uncertainty "full place overconstraint for seed-fair scoring"

    if {$use_x3_pc_tail_group} {
        # At the clean-reopen scoring boundary, test path ownership because
        # Vivado may retain empty group objects.
        write_checkpoint -force $work_directory/post_place.dcp
        close_design
        open_checkpoint $work_directory/post_place.dcp
        set_x3_setup_uncertainty $board_name $x3_place_baseline_uncertainty "clean-reopen place scoring"

        set x3_pc_tail_scope_score [validate_x3_pc_compressed_tail_scope "clean-reopen"]
        set x3_pc_compressed_tail_starts_score [dict get $x3_pc_tail_scope_score compressed_starts]
        set x3_pc_tail_ends_score [dict get $x3_pc_tail_scope_score selected_ends]
        set x3_pc_compressed_tail_ends_score [dict get $x3_pc_tail_scope_score union_ends]
        set x3_pc_compressed_tail_score_start_count [llength $x3_pc_compressed_tail_starts_score]
        set x3_pc_compressed_tail_score_start_names [dict get $x3_pc_tail_scope_score compressed_start_names]
        set x3_pc_tail_score_end_count [llength $x3_pc_tail_ends_score]
        set x3_pc_tail_score_end_names [dict get $x3_pc_tail_scope_score selected_end_names]
        set x3_pc_tail_score_bit_count [dict get $x3_pc_tail_scope_score selected_bits]
        set x3_pc_tail_score_state_end_count [llength [dict get $x3_pc_tail_scope_score state_ends]]
        set x3_pc_tail_score_state_end_names [dict get $x3_pc_tail_scope_score state_end_names]
        set x3_pc_tail_score_state_bit_count [dict get $x3_pc_tail_scope_score state_bits]
        set x3_pc_tail_score_seq_end_count [llength [dict get $x3_pc_tail_scope_score seq_ends]]
        set x3_pc_tail_score_seq_end_names [dict get $x3_pc_tail_scope_score seq_end_names]
        set x3_pc_tail_score_seq_bit_count [dict get $x3_pc_tail_scope_score seq_bits]
        set x3_pc_tail_score_pending_end_count [llength [dict get $x3_pc_tail_scope_score pending_ends]]
        set x3_pc_tail_score_pending_end_names [dict get $x3_pc_tail_scope_score pending_end_names]
        set x3_pc_tail_score_pending_canonical [dict get $x3_pc_tail_scope_score pending_canonical]
        set x3_pc_tail_score_union_end_count [llength $x3_pc_compressed_tail_ends_score]
        set x3_pc_tail_score_union_end_names [dict get $x3_pc_tail_scope_score union_end_names]
        if {$x3_pc_compressed_tail_score_start_names ne $x3_pc_compressed_tail_post_start_names} {
            error "clean-reopen X3 PC-metadata tail start names differ from the post-place scope"
        }
        if {$x3_pc_tail_score_end_names ne $x3_pc_tail_post_end_names} {
            error "clean-reopen X3 PC-tail endpoint names differ from the post-place scope"
        }
        if {$x3_pc_tail_score_state_end_names ne $x3_pc_tail_post_state_end_names} {
            error "clean-reopen X3 state PC-tail endpoint names differ from the post-place scope"
        }
        if {$x3_pc_tail_score_seq_end_names ne $x3_pc_tail_post_seq_end_names} {
            error "clean-reopen X3 sequential PC-tail endpoint names differ from the post-place scope"
        }
        if {$x3_pc_tail_score_pending_end_names ne $x3_pc_tail_post_pending_end_names} {
            error "clean-reopen X3 pending PC-tail endpoint names differ from the post-place scope"
        }
        if {$x3_pc_tail_score_union_end_names ne $x3_pc_tail_post_union_end_names} {
            error "clean-reopen X3 PC-metadata tail union endpoint names differ from the post-place scope"
        }

        set x3_pc_tail_group_name frost_pc_compressed_tail
        set x3_pc_tail_group [get_path_groups -quiet $x3_pc_tail_group_name]
        set x3_pc_tail_lingering_paths {}
        if {[llength $x3_pc_tail_group] != 0} {
            set x3_pc_tail_lingering_paths [get_timing_paths -quiet -group $x3_pc_tail_group -max_paths 1 -delay_type max]
        }
        if {[llength $x3_pc_tail_lingering_paths] != 0} {
            error "temporary $x3_pc_tail_group_name still owns timing paths after clean reopen"
        }

        set x3_pc_compressed_tail_scored_paths [get_timing_paths -from $x3_pc_compressed_tail_starts_score -to $x3_pc_compressed_tail_ends_score -max_paths 10000 -nworst 100 -delay_type max]
        if {[llength $x3_pc_compressed_tail_scored_paths] == 0} {
            error "no X3 PC-metadata tail timing paths after clean reopen"
        }
        set x3_pc_compressed_tail_scored_groups [lsort -unique [get_property GROUP $x3_pc_compressed_tail_scored_paths]]
        if {[llength $x3_pc_compressed_tail_scored_groups] != 1 || [lindex $x3_pc_compressed_tail_scored_groups 0] ne "clock_from_mmcm"} {
            error "noncanonical X3 PC-metadata tail scoring groups: $x3_pc_compressed_tail_scored_groups"
        }

        set x3_pc_tail_audit [open $work_directory/post_place_group_audit.txt w]
        # COMPRESSED_* is the stable audit prefix for the predecode-metadata
        # launch scope (fourteen scalar output FFs).
        puts $x3_pc_tail_audit "DIRECTIVE=$directive"
        puts $x3_pc_tail_audit "PLACE_UNCERTAINTY_NS=[format %.3f $x3_place_uncertainty]"
        puts $x3_pc_tail_audit "SCORE_UNCERTAINTY_NS=[format %.3f $x3_place_baseline_uncertainty]"
        puts $x3_pc_tail_audit "PRE_COMPRESSED_STARTS=$x3_pc_compressed_tail_pre_start_count"
        puts $x3_pc_tail_audit "PRE_ENDS=$x3_pc_tail_pre_end_count"
        puts $x3_pc_tail_audit "PRE_PC_BITS=$x3_pc_tail_pre_bit_count"
        puts $x3_pc_tail_audit "PRE_STATE_ENDS=$x3_pc_tail_pre_state_end_count"
        puts $x3_pc_tail_audit "PRE_STATE_PC_BITS=$x3_pc_tail_pre_state_bit_count"
        puts $x3_pc_tail_audit "PRE_SEQ_ENDS=$x3_pc_tail_pre_seq_end_count"
        puts $x3_pc_tail_audit "PRE_SEQ_PC_BITS=$x3_pc_tail_pre_seq_bit_count"
        puts $x3_pc_tail_audit "PRE_PENDING_ENDS=$x3_pc_tail_pre_pending_end_count"
        puts $x3_pc_tail_audit "PRE_PENDING_CANONICAL=$x3_pc_tail_pre_pending_canonical"
        puts $x3_pc_tail_audit "PRE_UNION_ENDS=$x3_pc_tail_pre_union_end_count"
        puts $x3_pc_tail_audit "POST_COMPRESSED_STARTS=$x3_pc_compressed_tail_post_start_count"
        puts $x3_pc_tail_audit "POST_ENDS=$x3_pc_tail_post_end_count"
        puts $x3_pc_tail_audit "POST_PC_BITS=$x3_pc_tail_post_bit_count"
        puts $x3_pc_tail_audit "POST_STATE_ENDS=$x3_pc_tail_post_state_end_count"
        puts $x3_pc_tail_audit "POST_STATE_PC_BITS=$x3_pc_tail_post_state_bit_count"
        puts $x3_pc_tail_audit "POST_SEQ_ENDS=$x3_pc_tail_post_seq_end_count"
        puts $x3_pc_tail_audit "POST_SEQ_PC_BITS=$x3_pc_tail_post_seq_bit_count"
        puts $x3_pc_tail_audit "POST_PENDING_ENDS=$x3_pc_tail_post_pending_end_count"
        puts $x3_pc_tail_audit "POST_PENDING_CANONICAL=$x3_pc_tail_post_pending_canonical"
        puts $x3_pc_tail_audit "POST_UNION_ENDS=$x3_pc_tail_post_union_end_count"
        puts $x3_pc_tail_audit "PRE_COMPRESSED_START_NAMES_MATCH_POST=1"
        puts $x3_pc_tail_audit "PRE_SELECTED_CANONICAL_NAMES_MATCH_POST=1"
        puts $x3_pc_tail_audit "PRE_STATE_CANONICAL_NAMES_MATCH_POST=1"
        puts $x3_pc_tail_audit "PRE_SEQ_CANONICAL_NAMES_MATCH_POST=1"
        puts $x3_pc_tail_audit "PRE_PENDING_CANONICAL_NAMES_MATCH_POST=1"
        puts $x3_pc_tail_audit "SCORE_COMPRESSED_STARTS=$x3_pc_compressed_tail_score_start_count"
        puts $x3_pc_tail_audit "SCORE_ENDS=$x3_pc_tail_score_end_count"
        puts $x3_pc_tail_audit "SCORE_PC_BITS=$x3_pc_tail_score_bit_count"
        puts $x3_pc_tail_audit "SCORE_STATE_ENDS=$x3_pc_tail_score_state_end_count"
        puts $x3_pc_tail_audit "SCORE_STATE_PC_BITS=$x3_pc_tail_score_state_bit_count"
        puts $x3_pc_tail_audit "SCORE_SEQ_ENDS=$x3_pc_tail_score_seq_end_count"
        puts $x3_pc_tail_audit "SCORE_SEQ_PC_BITS=$x3_pc_tail_score_seq_bit_count"
        puts $x3_pc_tail_audit "SCORE_PENDING_ENDS=$x3_pc_tail_score_pending_end_count"
        puts $x3_pc_tail_audit "SCORE_PENDING_CANONICAL=$x3_pc_tail_score_pending_canonical"
        puts $x3_pc_tail_audit "SCORE_UNION_ENDS=$x3_pc_tail_score_union_end_count"
        puts $x3_pc_tail_audit "SCORE_COMPRESSED_START_NAMES_MATCH_POST=1"
        puts $x3_pc_tail_audit "SCORE_ENDPOINT_NAMES_MATCH_POST=1"
        puts $x3_pc_tail_audit "SCORE_COMPRESSED_ENDPOINT_NAMES_MATCH_POST=1"
        puts $x3_pc_tail_audit "LINGERING_CUSTOM_PATHS=0"
        puts $x3_pc_tail_audit "COMPRESSED_SCORED_GROUPS=$x3_pc_compressed_tail_scored_groups"
        close $x3_pc_tail_audit
    }

    # Guided candidates overwrite the temporary DCP only after the audit passes.
    write_checkpoint -force $work_directory/post_place.dcp
    report_timing_summary -file $work_directory/post_place_timing.rpt
    report_utilization -file $work_directory/post_place_util.rpt
    report_high_fanout_nets -timing -load_types -max_nets 50 -file $work_directory/post_place_high_fanout.rpt
    write_failing_paths_csv $work_directory/post_place_failing_paths.csv $work_directory/post_place_timing.rpt
    # build.py vetoes seeds at the configured congestion level (default 5),
    # because overconstrained post-place WNS can favor unroutable density.
    report_design_analysis -congestion -file $work_directory/post_place_congestion.rpt
    if {$use_x3_pc_tail_group} {
        report_timing -from $x3_pc_compressed_tail_starts_score -to $x3_pc_compressed_tail_ends_score -delay_type max -max_paths 1000 -nworst 10 -file $work_directory/post_place_pc_compressed_tail_timing.rpt
    }

    puts "** DONE — place_design complete with directive: $directive"

} elseif {$step eq "quick_route"} {
    # X3 seed-ranking probe, not a pipeline step. Clear overconstraint and run
    # the cheapest route; emit reports but promote the original post_place.dcp.
    if {$checkpoint_path eq ""} {
        puts "Error: quick_route step requires checkpoint_path"
        exit 1
    }
    open_checkpoint $checkpoint_path

    if {$board_name eq "x3"} {
        set_clock_uncertainty -from clock_from_mmcm -to clock_from_mmcm 0.0 -setup
    }
    route_design -directive RuntimeOptimized

    report_timing_summary -file $work_directory/quick_route_timing.rpt
    report_design_analysis -congestion -file $work_directory/quick_route_congestion.rpt

    puts "** DONE — quick_route probe complete"

} elseif {[string match "post_place_physopt*" $step] || [string match "post_route_physopt*" $step] || [string match "post_second_route_physopt*" $step]} {
    # Phys-opt sweep: run every directive from AggressiveExplore, then retime.
    # Ignore the caller's directive. Repeat until a full sweep has no meaningful
    # WNS/TNS gain, retaining each improvement and publishing the current best
    # after every sweep.
    if {$checkpoint_path eq ""} {
        puts "Error: $step step requires checkpoint_path"
        exit 1
    }
    open_checkpoint $checkpoint_path

    set physopt_uncertainty [getenv_default FROST_PHYSOPT_SETUP_UNCERTAINTY ""]
    if {$physopt_uncertainty ne ""} {
        set_x3_setup_uncertainty $board_name $physopt_uncertainty "$step overconstraint"
    }

    set sweep_order_env [getenv_default FROST_PHYSOPT_SWEEP_ORDER ""]
    if {$sweep_order_env ne ""} {
        set sweep_order [split_env_list $sweep_order_env]
    } else {
        set sweep_order [list \
        AggressiveExplore \
        Default \
        Explore \
        ExploreWithHoldFix \
        AlternateReplication \
        AggressiveFanoutOpt \
        AlternateFlowWithRetiming \
        RuntimeOptimized \
        ExploreWithAggressiveHoldFix \
        ]
    }

    # Always make the non-directive retime pass the final pass in each sweep.
    set directive_sweep_order [list]
    foreach sweep_pass $sweep_order {
        if {$sweep_pass ne "-retime"} {
            lappend directive_sweep_order $sweep_pass
        }
    }
    set sweep_order $directive_sweep_order
    lappend sweep_order "-retime"

    set total_physopt_passes [llength $sweep_order]
    set total_passes_run 0
    set sweep_num 1
    set early_exit 0
    set best_wns -999999.0
    set best_tns -999999999.0
    set best_pass 0
    set best_sweep 0
    set best_directive ""
    set best_checkpoint [file join $work_directory phys_opt_best.dcp]
    set wns_tie_epsilon [getenv_default FROST_PHYSOPT_WNS_TIE_EPSILON 0.0005]
    set tns_keep_epsilon [getenv_default FROST_PHYSOPT_TNS_KEEP_EPSILON 0.0]
    set tns_repeat_epsilon [getenv_default FROST_PHYSOPT_TNS_REPEAT_EPSILON [getenv_default FROST_PHYSOPT_TNS_TIE_EPSILON 0.0]]
    set accepted_checkpoint_dir [getenv_default FROST_PHYSOPT_ACCEPTED_CHECKPOINT_DIR ""]
    if {$accepted_checkpoint_dir ne ""} {
        file mkdir $accepted_checkpoint_dir
    }

    set repeat_sweeps_value [getenv_default FROST_PHYSOPT_REPEAT_SWEEPS 1]
    if {$step eq "post_place_physopt"} {
        set repeat_sweeps_value [getenv_default FROST_POST_PLACE_PHYSOPT_REPEAT_SWEEPS $repeat_sweeps_value]
    } elseif {$step eq "post_route_physopt"} {
        set repeat_sweeps_value [getenv_default FROST_POST_ROUTE_PHYSOPT_REPEAT_SWEEPS $repeat_sweeps_value]
    } elseif {$step eq "post_second_route_physopt"} {
        set repeat_sweeps_value [getenv_default FROST_POST_SECOND_ROUTE_PHYSOPT_REPEAT_SWEEPS $repeat_sweeps_value]
    }
    set repeat_sweeps [expr {$repeat_sweeps_value ne "0"}]

    set max_sweeps [getenv_default FROST_PHYSOPT_MAX_SWEEPS 0]
    if {$step eq "post_place_physopt"} {
        set max_sweeps [getenv_default FROST_POST_PLACE_PHYSOPT_MAX_SWEEPS $max_sweeps]
    } elseif {$step eq "post_route_physopt"} {
        set max_sweeps [getenv_default FROST_POST_ROUTE_PHYSOPT_MAX_SWEEPS $max_sweeps]
    } elseif {$step eq "post_second_route_physopt"} {
        set max_sweeps [getenv_default FROST_POST_SECOND_ROUTE_PHYSOPT_MAX_SWEEPS $max_sweeps]
    }

    set initial_report [file join $work_directory phys_opt_initial_timing.rpt]
    report_timing_summary -file $initial_report
    set initial_timing_summary [get_setup_timing_summary $initial_report]
    set initial_report_wns [dict get $initial_timing_summary wns]
    set initial_tns [dict get $initial_timing_summary tns]

    set initial_worst_path [lindex [get_timing_paths -delay_type max -nworst 1 -max_paths 1] 0]
    set initial_wns ""
    if {$initial_worst_path ne ""} {
        set initial_wns [get_property SLACK $initial_worst_path]
    } elseif {$initial_report_wns ne ""} {
        set initial_wns $initial_report_wns
    }

    if {$initial_wns ne ""} {
        set best_wns $initial_wns
        if {$initial_tns ne ""} {
            set best_tns $initial_tns
        }
        set best_directive "input_checkpoint"
        write_checkpoint -force $best_checkpoint
        puts ""
        if {$initial_tns ne ""} {
            puts "  Initial $step WNS/TNS: $best_wns ns / $best_tns ns"
        } else {
            puts "  Initial $step WNS: $best_wns ns"
        }
    }

    while {1} {
        set sweep_kept_improvement 0
        set sweep_start_wns $best_wns
        set sweep_start_tns $best_tns
        set pass_num 1
        puts ""
        puts "=========================================="
        if {$repeat_sweeps} {
            puts "  $step sweep iteration $sweep_num"
        } else {
            puts "  $step sweep"
        }
        puts "=========================================="

        foreach sweep_pass $sweep_order {
            if {$sweep_pass eq "-retime"} {
                set pass_label "retime"
                set pass_display "-retime"
                set phys_opt_args [list -retime]
            } else {
                set pass_label $sweep_pass
                set pass_display $sweep_pass
                set phys_opt_args [list -directive $sweep_pass]
            }

            puts ""
            puts "------------------------------------------"
            if {$repeat_sweeps} {
                puts "  $step sweep $sweep_num, pass $pass_num/$total_physopt_passes: $pass_display"
            } else {
                puts "  $step pass $pass_num/$total_physopt_passes: $pass_display"
            }
            puts "------------------------------------------"
            phys_opt_design {*}$phys_opt_args
            incr total_passes_run
            set pass_improved 0

            set pass_report [file join $work_directory [format "phys_opt_probe_s%02d_p%02d_%s_timing.rpt" $sweep_num $pass_num $pass_label]]
            report_timing_summary -file $pass_report
            set timing_summary [get_setup_timing_summary $pass_report]
            set report_wns [dict get $timing_summary wns]
            set tns [dict get $timing_summary tns]

            set worst_path [lindex [get_timing_paths -delay_type max -nworst 1 -max_paths 1] 0]
            set wns ""
            if {$worst_path ne ""} {
                set wns [get_property SLACK $worst_path]
            } elseif {$report_wns ne ""} {
                set wns $report_wns
            }

            if {$wns ne ""} {
                set better_wns [expr {$wns > ($best_wns + $wns_tie_epsilon)}]
                set same_wns [expr {abs($wns - $best_wns) <= $wns_tie_epsilon}]
                set better_tns [expr {$tns ne "" && $tns > ($best_tns + $tns_keep_epsilon)}]
                puts ""
                if {$tns ne ""} {
                    puts "  WNS/TNS after $pass_display: $wns ns / $tns ns"
                } else {
                    puts "  WNS after $pass_display: $wns ns"
                }

                if {$better_wns || ($same_wns && $better_tns)} {
                    if {$better_wns} {
                        set improvement_reason "WNS"
                    } else {
                        set improvement_reason "TNS tie-break"
                    }
                    set best_wns $wns
                    if {$tns ne ""} {
                        set best_tns $tns
                    }
                    set best_pass $pass_num
                    set best_sweep $sweep_num
                    set best_directive $pass_display
                    write_checkpoint -force $best_checkpoint
                    if {$accepted_checkpoint_dir ne ""} {
                        set wns_name [string map [list - m . p] $wns]
                        set tns_name "na"
                        if {$tns ne ""} {
                            set tns_name [string map [list - m . p] $tns]
                        }
                        set accepted_base [format "%s_s%02d_p%02d_%s_wns_%s_tns_%s" $step $sweep_num $pass_num $pass_label $wns_name $tns_name]
                        set accepted_checkpoint [file join $accepted_checkpoint_dir "${accepted_base}.dcp"]
                        write_checkpoint -force $accepted_checkpoint
                        if {[file exists $pass_report]} {
                            file copy -force $pass_report [file join $accepted_checkpoint_dir "${accepted_base}_timing.rpt"]
                        }
                        puts "  Saved accepted $step checkpoint: $accepted_checkpoint"
                    }
                    set sweep_kept_improvement 1
                    set pass_improved 1
                    if {$tns ne ""} {
                        puts "  ** New best $step: WNS=$best_wns ns, TNS=$best_tns ns ($best_directive, sweep $best_sweep, pass $best_pass/$total_physopt_passes, $improvement_reason)"
                    } else {
                        puts "  ** New best $step: WNS=$best_wns ns ($best_directive, sweep $best_sweep, pass $best_pass/$total_physopt_passes, $improvement_reason)"
                    }
                }

                if {$wns >= 0.0} {
                    puts "  ** Timing met; stopping $step sweep early after $total_passes_run total phys_opt passes"
                    set early_exit 1
                    break
                }
            }

            if {$repeat_sweeps && !$pass_improved && [file exists $best_checkpoint]} {
                puts ""
                puts "  Reverting non-improving $step pass; restoring best WNS=$best_wns ns, TNS=$best_tns ns"
                close_design
                open_checkpoint $best_checkpoint
            }

            incr pass_num
        }

        set continue_sweeps 0
        if {$early_exit} {
            set continue_sweeps 0
        } elseif {!$repeat_sweeps} {
            set continue_sweeps 0
        } elseif {!$sweep_kept_improvement} {
            puts ""
            puts "  No WNS/TNS improvement during $step sweep iteration $sweep_num; stopping after convergence"
            set continue_sweeps 0
        } else {
            set sweep_wns_delta [expr {$best_wns - $sweep_start_wns}]
            set sweep_tns_delta ""
            if {$best_tns ne "" && $sweep_start_tns ne ""} {
                set sweep_tns_delta [expr {$best_tns - $sweep_start_tns}]
            }
            set repeat_for_wns [expr {$best_wns > ($sweep_start_wns + $wns_tie_epsilon)}]
            set repeat_for_tns 0
            if {$sweep_tns_delta ne "" && abs($best_wns - $sweep_start_wns) <= $wns_tie_epsilon} {
                set repeat_for_tns [expr {$sweep_tns_delta > $tns_repeat_epsilon}]
            }
            if {!$repeat_for_wns && !$repeat_for_tns} {
                puts ""
                if {$sweep_tns_delta ne ""} {
                    puts "  Kept best $step improvement from sweep $sweep_num, but sweep delta WNS=[format %.3f $sweep_wns_delta] ns, TNS=[format %.3f $sweep_tns_delta] ns is below repeat threshold; stopping repeated sweeps"
                } else {
                    puts "  Kept best $step improvement from sweep $sweep_num, but sweep WNS delta=[format %.3f $sweep_wns_delta] ns is below repeat threshold; stopping repeated sweeps"
                }
                set continue_sweeps 0
            } elseif {$max_sweeps ne "0" && $sweep_num >= $max_sweeps} {
                puts ""
                puts "  Reached max repeated $step sweeps ($max_sweeps); stopping"
                set continue_sweeps 0
            } else {
                puts ""
                if {$sweep_tns_delta ne ""} {
                    puts "  $step sweep iteration $sweep_num improved enough to repeat (WNS delta=[format %.3f $sweep_wns_delta] ns, TNS delta=[format %.3f $sweep_tns_delta] ns); starting another sweep from best checkpoint"
                } else {
                    puts "  $step sweep iteration $sweep_num improved enough to repeat (WNS delta=[format %.3f $sweep_wns_delta] ns); starting another sweep from best checkpoint"
                }
                set continue_sweeps 1
            }
        }

        if {[file exists $best_checkpoint]} {
            puts ""
            if {$best_pass == 0} {
                puts "  Restoring best $step checkpoint: input checkpoint (WNS=$best_wns ns, TNS=$best_tns ns)"
            } else {
                puts "  Restoring best $step pass: $best_directive (sweep $best_sweep, pass $best_pass/$total_physopt_passes, WNS=$best_wns ns, TNS=$best_tns ns)"
            }
            close_design
            open_checkpoint $best_checkpoint
        }

        write_physopt_iteration_outputs $work_directory $step $board_name $physopt_uncertainty $best_wns $continue_sweeps

        if {!$continue_sweeps} {
            break
        }

        incr sweep_num
    }

    if {$early_exit} {
        puts "** DONE — $step sweep complete ($total_passes_run total phys_opt passes, stopped early on closure)"
    } else {
        puts "** DONE — $step sweep complete ($total_passes_run total phys_opt passes)"
    }

} elseif {$step eq "route"} {
    # Routing
    if {$checkpoint_path eq ""} {
        puts "Error: route step requires checkpoint_path"
        exit 1
    }
    open_checkpoint $checkpoint_path

    # Remove X3's placement overconstraint.
    if {$board_name eq "x3"} {
        set_clock_uncertainty -from clock_from_mmcm -to clock_from_mmcm 0.0 -setup
    }
    route_design -directive $directive -tns_cleanup

    write_checkpoint -force $work_directory/post_route.dcp
    report_timing_summary -file $work_directory/post_route_timing.rpt
    report_utilization -file $work_directory/post_route_util.rpt
    report_high_fanout_nets -timing -load_types -max_nets 50 -file $work_directory/post_route_high_fanout.rpt
    write_failing_paths_csv $work_directory/post_route_failing_paths.csv $work_directory/post_route_timing.rpt

    puts "** DONE — route_design complete with directive: $directive"

} elseif {$step eq "second_route"} {
    # Second route without -tns_cleanup, starting from post-route phys-opt. X3's
    # overconstraint was already cleared in the first route checkpoint.
    if {$checkpoint_path eq ""} {
        puts "Error: second_route step requires checkpoint_path"
        exit 1
    }
    open_checkpoint $checkpoint_path

    route_design -directive $directive

    write_checkpoint -force $work_directory/post_second_route.dcp
    report_timing_summary -file $work_directory/post_second_route_timing.rpt
    report_utilization -file $work_directory/post_second_route_util.rpt
    report_high_fanout_nets -timing -load_types -max_nets 50 -file $work_directory/post_second_route_high_fanout.rpt
    write_failing_paths_csv $work_directory/post_second_route_failing_paths.csv $work_directory/post_second_route_timing.rpt

    puts "** DONE — second route_design complete with directive: $directive"

} elseif {$step eq "bitstream"} {
    # Bitstream generation
    if {$checkpoint_path eq ""} {
        puts "Error: bitstream step requires checkpoint_path"
        exit 1
    }
    open_checkpoint $checkpoint_path

    # Final reports
    report_timing_summary -file $work_directory/final_timing.rpt
    report_utilization -file $work_directory/final_util.rpt
    report_high_fanout_nets -timing -load_types -max_nets 50 -file $work_directory/final_high_fanout.rpt
    report_drc -file $work_directory/final_drc.rpt
    write_failing_paths_csv $work_directory/final_failing_paths.csv $work_directory/final_timing.rpt

    set bitstream_name ${board_name}_frost.bit
    write_bitstream -force $work_directory/$bitstream_name

    puts "** DONE — bitstream generated: $work_directory/$bitstream_name"

} else {
    puts "Error: Unknown step '$step'"
    puts "Valid steps: synth, opt, place, quick_route, post_place_physopt, route, post_route_physopt, second_route, post_second_route_physopt, bitstream"
    exit 1
}

exit
