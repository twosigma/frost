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

# Vivado step script for FROST RISC-V processor
# Runs a single build step with a specific directive
# Called by build.py for parallel sweeps

# =============================================================================
# Utility Procedures
# =============================================================================

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

# =============================================================================
# Argument Parsing
# =============================================================================

# Arguments: board_name step directive checkpoint_path retiming ?software_mem_dir?
if {$argc < 5} {
    puts "Error: Required arguments: board_name step directive checkpoint_path retiming"
    puts "Usage: vivado -mode batch -source build_step.tcl -tclargs <board_name> <step> <directive> <checkpoint_path> <retiming> ?software_mem_dir?"
    puts ""
    puts "Steps: synth, opt, place, post_place_physopt, route, post_route_physopt, second_route, post_second_route_physopt, bitstream"
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

# =============================================================================
# Board Configuration
# =============================================================================

if {$board_name eq "genesys2"} {
    set fpga_part_number xc7k325tffg900-2
    set top_level_module_name genesys2_frost
} elseif {$board_name eq "x3"} {
    set fpga_part_number xcux35-vsva1365-3-e
    set top_level_module_name x3_frost
}

set number_of_parallel_jobs 32

# =============================================================================
# Directory Setup
# =============================================================================

# Work directory is the current directory (set by Python script)
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

# =============================================================================
# Step Execution
# =============================================================================

if {$step eq "synth"} {
    # ===================
    # SYNTHESIS STEP
    # ===================
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
        # DDR3 subsystem: MIG (configured by the transplanted mig_a.prj) +
        # SmartConnect + JTAG DDR-image loader + calibration/reset sequencing,
        # assembled as a small block design (see genesys2_ddr_bd.tcl). The
        # generated wrapper (ddr_subsys_wrapper) is instantiated by
        # genesys2_frost.sv.
        read_verilog ${project_root_directory}/boards/genesys2/mem_reset_control.v
        source [file join [file dirname [info script]] genesys2_ddr_bd.tcl]
        create_genesys2_ddr_bd
        # Global synthesis for the BD: child IPs (MIG, SmartConnect, JTAG-AXI)
        # compile into the main synth_design run instead of expecting
        # pre-synthesized OOC checkpoints (this flow never launches IP runs).
        set_property synth_checkpoint_mode None [get_files ddr_subsys.bd]
        generate_target all [get_files ddr_subsys.bd]
        set ddr_subsys_wrapper [make_wrapper -files [get_files ddr_subsys.bd] -top]
        add_files -norecurse $ddr_subsys_wrapper
    }

    set rtl_source_files [flatten_rtl_file_list $rtl_file_list $project_root_directory]

    # Enable Xilinx primitive instantiations and Vivado-specific init handling
    # in RTL. Generic synthesis flows stay technology-agnostic.
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
    read_mem [file join $software_mem_directory sw_imem_even.mem]
    read_mem [file join $software_mem_directory sw_imem_odd.mem]
    read_mem [file join $software_mem_directory sw_imem_even_sideband.mem]
    read_mem [file join $software_mem_directory sw_imem_odd_sideband.mem]
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
    # ===================
    # OPT DESIGN STEP
    # ===================
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
    # ===================
    # PLACE DESIGN STEP
    # ===================
    if {$checkpoint_path eq ""} {
        puts "Error: place step requires checkpoint_path"
        exit 1
    }
    open_checkpoint $checkpoint_path

    # Apply overconstraining before placement (x3 only - needed for 300 MHz timing closure)
    if {$board_name eq "x3"} {
        set_clock_uncertainty -from clock_from_mmcm -to clock_from_mmcm 0.5 -setup
    }
    place_design -directive $directive

    write_checkpoint -force $work_directory/post_place.dcp
    report_timing_summary -file $work_directory/post_place_timing.rpt
    report_utilization -file $work_directory/post_place_util.rpt
    report_high_fanout_nets -timing -load_types -max_nets 50 -file $work_directory/post_place_high_fanout.rpt
    write_failing_paths_csv $work_directory/post_place_failing_paths.csv $work_directory/post_place_timing.rpt

    puts "** DONE — place_design complete with directive: $directive"

} elseif {[string match "post_place_physopt*" $step] || [string match "post_route_physopt*" $step] || [string match "post_second_route_physopt*" $step]} {
    # ===================
    # PHYS_OPT SWEEP (post-place, post-route, or post-second-route)
    # ===================
    # Run phys_opt_design serially with every directive, starting with
    # AggressiveExplore, then finish each sweep with a retime-only pass. The
    # directive arg from the caller is ignored; the sweep order is fixed here.
    # Physopt repeats full sweeps until an entire sweep fails to improve WNS or,
    # for same-WNS sweeps, TNS by a meaningful amount. Inside a sweep, every
    # WNS/TNS improvement is kept so small gains can stack across later passes.
    # After each completed sweep iteration, the current best checkpoint and
    # reports are written to both the step work directory and the board's main
    # work directory.
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
    # ===================
    # ROUTE DESIGN STEP
    # ===================
    if {$checkpoint_path eq ""} {
        puts "Error: route step requires checkpoint_path"
        exit 1
    }
    open_checkpoint $checkpoint_path

    # Remove overconstraining before router (x3 only - matches placement overconstrain)
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
    # ===================
    # SECOND ROUTE DESIGN STEP (no -tns_cleanup)
    # ===================
    # Re-routes from the post_route_physopt checkpoint without -tns_cleanup,
    # giving the router a different exploration path. The x3 clock-uncertainty
    # overconstraint was already cleared during the first route pass and is
    # baked into the upstream checkpoint, so we don't touch it here.
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
    # ===================
    # BITSTREAM GENERATION
    # ===================
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
    puts "Valid steps: synth, opt, place, post_place_physopt, route, post_route_physopt, second_route, post_second_route_physopt, bitstream"
    exit 1
}

exit
