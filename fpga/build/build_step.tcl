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

# =============================================================================
# Argument Parsing
# =============================================================================

# Arguments: board_name step directive checkpoint_path retiming
if {$argc < 5} {
    puts "Error: Required arguments: board_name step directive checkpoint_path retiming"
    puts "Usage: vivado -mode batch -source build_step.tcl -tclargs <board_name> <step> <directive> <checkpoint_path> <retiming>"
    puts ""
    puts "Steps: synth, opt, place, post_place_physopt_pass*, route, post_route_physopt_pass*, bitstream"
    exit 1
}

set board_name [lindex $argv 0]
set step [lindex $argv 1]
set directive [lindex $argv 2]
set checkpoint_path [lindex $argv 3]
set retiming [lindex $argv 4]

if {$board_name ne "x3" && $board_name ne "genesys2" && $board_name ne "nexys_a7"} {
    puts "Error: Invalid board name '$board_name'"
    puts "Valid boards: x3, genesys2, nexys_a7"
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
} elseif {$board_name eq "nexys_a7"} {
    set fpga_part_number xc7a100tcsg324-1
    set top_level_module_name nexys_a7_frost
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

puts "=========================================="
puts "Board: $board_name"
puts "Step: $step"
puts "Directive: $directive"
puts "FPGA Part: $fpga_part_number"
puts "Work directory: $work_directory"
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
        CONFIG.MEM_DEPTH {16384} \
    ] [get_ips axi_bram_ctrl_0]

    generate_target all [get_ips]
    synth_ip [get_ips]

    set rtl_source_files [flatten_rtl_file_list $rtl_file_list $project_root_directory]
    read_verilog {*}$rtl_source_files
    read_mem $project_root_directory/sw/apps/hello_world/sw.mem
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

    opt_design -merge_equivalent_drivers -hier_fanout_limit 512
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

} elseif {[string match "post_place_physopt*" $step] || [string match "post_route_physopt*" $step]} {
    # ===================
    # PHYS_OPT DESIGN STEP (single pass)
    # ===================
    if {$checkpoint_path eq ""} {
        puts "Error: phys_opt step requires checkpoint_path"
        exit 1
    }
    open_checkpoint $checkpoint_path

    phys_opt_design -directive $directive

    write_checkpoint -force $work_directory/phys_opt.dcp
    report_timing_summary -file $work_directory/phys_opt_timing.rpt
    report_utilization -file $work_directory/phys_opt_util.rpt
    report_high_fanout_nets -timing -load_types -max_nets 50 -file $work_directory/phys_opt_high_fanout.rpt
    write_failing_paths_csv $work_directory/phys_opt_failing_paths.csv $work_directory/phys_opt_timing.rpt

    puts "** DONE — phys_opt_design complete with directive: $directive"

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
    puts "Valid steps: synth, opt, place, post_place_physopt_pass*, route, post_route_physopt_pass*, bitstream"
    exit 1
}

exit
