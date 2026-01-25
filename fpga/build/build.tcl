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

# Vivado build script for FROST RISC-V processor
# Synthesizes, implements, and generates bitstream for specified FPGA board

# Parse timing report to get number of failing setup endpoints
proc get_failing_endpoint_count {timing_report_file} {
    set setup_count 0

    set fh [open $timing_report_file r]
    set content [read $fh]
    close $fh

    # Look for the timing summary table line with format:
    # WNS  TNS  TNS_Failing  TNS_Total  WHS  THS  THS_Failing  THS_Total  ...
    # The data line follows the header with dashes
    set lines [split $content "\n"]
    set in_summary_table 0
    foreach line $lines {
        # Detect the header line
        if {[string match "*TNS Failing Endpoints*" $line]} {
            set in_summary_table 1
            continue
        }
        # Skip the separator line with dashes
        if {$in_summary_table && [string match "*-------*" $line]} {
            continue
        }
        # Parse the data line
        if {$in_summary_table && [string trim $line] ne ""} {
            # Extract numbers from the line
            set fields [regexp -all -inline -- {-?[0-9.]+} $line]
            # Fields order: WNS, TNS, TNS_Failing, ...
            if {[llength $fields] >= 3} {
                set setup_count [lindex $fields 2]
            }
            break
        }
    }

    return [expr {int($setup_count)}]
}

# Generate CSV report of failing setup timing paths
# If timing_report_file is provided, extracts failing path count from it
proc write_failing_paths_csv {output_file {timing_report_file ""}} {
    # Determine max_paths from timing report or use default
    if {$timing_report_file ne "" && [file exists $timing_report_file]} {
        set max_paths [get_failing_endpoint_count $timing_report_file]
        puts "Detected $max_paths failing setup endpoints from timing report"
    } else {
        set max_paths 1000
    }

    # Get setup violations (negative slack)
    if {$max_paths > 0} {
        set paths [get_timing_paths -max_paths $max_paths -slack_lesser_than 0 -delay_type max]
    } else {
        set paths {}
    }

    set fh [open $output_file w]

    # CSV header
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

        # Count routes and find max fanout
        set nets [get_nets -of_objects $path -quiet]
        set routes [llength $nets]
        set high_fanout 0
        foreach net $nets {
            set fanout [get_property FLAT_PIN_COUNT $net]
            if {$fanout > $high_fanout} {
                set high_fanout $fanout
            }
        }

        # Escape commas in pin names by quoting
        puts $fh "$slack,$requirement,$logic_delay,$net_delay,$logic_levels,$routes,$high_fanout,\"$startpoint\",\"$endpoint\",$start_clk,$end_clk,$path_group"
    }

    close $fh

    puts "Wrote [llength $paths] failing setup paths to $output_file"
}

# Validate command line arguments
# Required: board_name, synth_only, retiming
# Optional: opt_only (stop after opt_design, for generating shared checkpoint)
#           placer_directive (default: AltSpreadLogic_high)
#           checkpoint_path (if provided, skip synthesis and load this checkpoint)
#           work_suffix (suffix for work directory, used for parallel runs)
#           synth_directive (default: PerformanceOptimized)
if {$argc < 3} {
    puts "Error: Board name, synth_only flag, and retiming flag are required"
    puts "Usage: vivado -mode batch -source build.tcl -tclargs <board_name> <synth_only> <retiming> \[opt_only\] \[placer_directive\] \[checkpoint_path\] \[work_suffix\] \[synth_directive\]"
    exit 1
}
set board_name [lindex $argv 0]
set synth_only [lindex $argv 1]
set retiming [lindex $argv 2]
set opt_only [expr {$argc > 3 ? [lindex $argv 3] : "0"}]
set placer_directive [expr {$argc > 4 ? [lindex $argv 4] : "ExtraTimingOpt"}]
set checkpoint_path [expr {$argc > 5 ? [lindex $argv 5] : ""}]
set work_suffix [expr {$argc > 6 ? [lindex $argv 6] : ""}]
set synth_directive [expr {$argc > 7 ? [lindex $argv 7] : "PerformanceOptimized"}]
if {$board_name ne "x3" && $board_name ne "genesys2" && $board_name ne "nexys_a7"} {
    puts "Error: Invalid board name '$board_name'"
    puts "Valid boards: x3, genesys2, nexys_a7"
    exit 1
}

# Configure FPGA part number and top-level module based on board
if {$board_name eq "genesys2"} {
    # Kintex-7 FPGA on Genesys2 board
    set fpga_part_number xc7k325tffg900-2
    set top_level_module_name  genesys2_frost
} elseif {$board_name eq "x3"} {
    # UltraScale+ FPGA on X3 board
    set fpga_part_number xcux35-vsva1365-3-e
    set top_level_module_name  x3_frost
} elseif {$board_name eq "nexys_a7"} {
    # Artix-7 FPGA on Nexys A7-100T board
    set fpga_part_number xc7a100tcsg324-1
    set top_level_module_name  nexys_a7_frost
}

# Number of parallel jobs for synthesis and implementation
set number_of_parallel_jobs 32

# Directory structure setup
# Expected directory hierarchy from this script:
#   <project_root>/fpga/build/build.tcl
# Navigate up 5 levels to reach project root:
#   build.tcl -> build/ -> fpga/ -> frost/ -> src/ -> <project_root>
set script_directory [file dirname [file normalize [info script]]]
# Work directory can have a suffix for parallel sweep runs (e.g., work_Explore, work_Default)
if {$work_suffix ne ""} {
    set work_directory [file join $script_directory $board_name "work_${work_suffix}"]
} else {
    set work_directory [file join $script_directory $board_name work]
}
set project_root_directory [file dirname $script_directory/../../../]
set board_specific_directory [file join $project_root_directory boards/$board_name]
set rtl_file_list [file join $board_specific_directory ${board_name}_frost.f]
set constraints_file [file join $board_specific_directory constr/${board_name}.xdc]

puts "Board: $board_name"
puts "FPGA Part: $fpga_part_number"
puts "Top Module: $top_level_module_name"
puts "Placer Directive: $placer_directive"
puts "Synth Directive: $synth_directive"
puts "Script directory: $script_directory"
puts "Work directory: $work_directory"
puts "Project root: $project_root_directory"
puts "Board files: $board_specific_directory"
if {$checkpoint_path ne ""} {
    puts "Starting from checkpoint: $checkpoint_path"
}

# Create work directory if it doesn't exist
if {![file isdirectory $work_directory]} {
    file mkdir $work_directory
}

# If starting from a checkpoint, load it and skip synthesis
if {$checkpoint_path ne ""} {
    puts "Loading checkpoint: $checkpoint_path"
    open_checkpoint $checkpoint_path
} else {
    # Full synthesis flow follows
    # Recursively read file list and expand any nested file lists
# Transforms hierarchical .f file structure into flat list of RTL files for Vivado
proc flatten_rtl_file_list {file_list_path project_root} {
    set rtl_files_list {}
    set file_handle [open $file_list_path r]

    while {[gets $file_handle current_line] >= 0} {
        set current_line [string trim $current_line]
        # Skip empty lines and comments
        if {$current_line eq "" || [string match "#*" $current_line]} {continue}

        # Expand $(ROOT) variable to actual project root path
        set current_line [string map [list {$(ROOT)} $project_root] $current_line]

        if {[string match {-f *} $current_line]} {
            # Nested file list - recursively expand it
            foreach {flag nested_file_list} $current_line {}
            lappend rtl_files_list {*}[flatten_rtl_file_list $nested_file_list $project_root]
        } elseif {[string match {+incdir+*} $current_line]} {
            # Include directory directive - preserve as-is for Vivado
            lappend rtl_files_list $current_line
        } else {
            # Regular RTL file path
            lappend rtl_files_list $current_line
        }
    }
    close $file_handle
    return $rtl_files_list
}

# Read and expand all RTL source files from hierarchical file list
set rtl_source_files [flatten_rtl_file_list $rtl_file_list $project_root_directory]

# Configure Vivado to use multiple threads for faster build
set_param general.maxThreads $number_of_parallel_jobs
create_project -part $fpga_part_number -force tmp_proj $work_directory/vivado_proj

# Set board-specific IP output repository to prevent collisions between parallel builds
set_property IP_OUTPUT_REPO $work_directory/vivado_proj/ip_cache [current_project]

# Create IP cores programmatically (avoids version-specific XCI file issues)
# This ensures compatibility across different Vivado versions

# JTAG-to-AXI Master: Allows software loading via JTAG
# - AXI4-Lite protocol for simple register access
# - 32-bit address and data width
create_ip -name jtag_axi -vendor xilinx.com -library ip -version 1.2 -module_name jtag_axi_0
set_property -dict [list \
    CONFIG.PROTOCOL {2} \
    CONFIG.M_AXI_DATA_WIDTH {32} \
    CONFIG.M_AXI_ADDR_WIDTH {32} \
] [get_ips jtag_axi_0]

# AXI BRAM Controller: Bridges AXI to BRAM interface for instruction memory
# - AXI4-Lite protocol
# - Single-port BRAM mode (we use external dual-port BRAM)
# - 16K depth = 64KB addressable (16-bit address)
create_ip -name axi_bram_ctrl -vendor xilinx.com -library ip -version 4.1 -module_name axi_bram_ctrl_0
set_property -dict [list \
    CONFIG.PROTOCOL {AXI4LITE} \
    CONFIG.SINGLE_PORT_BRAM {1} \
    CONFIG.MEM_DEPTH {16384} \
] [get_ips axi_bram_ctrl_0]

# Generate output products and synthesize
generate_target all [get_ips]
synth_ip [get_ips]

read_verilog {*}$rtl_source_files
# initialize the memory with hello world program
read_mem $project_root_directory/sw/apps/hello_world/sw.mem
read_xdc      $constraints_file
set_property top $top_level_module_name [current_fileset]

set synth_args [list -top $top_level_module_name -part $fpga_part_number \
                     -directive $synth_directive]
if {$retiming eq "1"} {
    lappend synth_args -global_retiming on
}
synth_design {*}$synth_args

write_checkpoint -force $work_directory/post_synth.dcp
report_timing_summary -file $work_directory/post_synth_timing.rpt
report_utilization    -file $work_directory/post_synth_util.rpt
write_failing_paths_csv $work_directory/post_synth_failing_paths.csv $work_directory/post_synth_timing.rpt

if {$synth_only eq "1"} {
    puts "** DONE — synthesis only, checkpoint at $work_directory/post_synth.dcp"
    exit
}

opt_design -directive ExploreWithRemap
write_checkpoint -force $work_directory/post_opt.dcp
report_timing_summary -file $work_directory/post_opt_timing.rpt
report_utilization    -file $work_directory/post_opt_util.rpt

if {$opt_only eq "1"} {
    puts "** DONE — opt_design only, checkpoint at $work_directory/post_opt.dcp"
    exit
}

}
# End of synthesis/opt block - from here on, we either came from checkpoint or fresh synthesis

# apply overconstraining during placer for better placement
set_clock_uncertainty -from clock_from_mmcm -to clock_from_mmcm 1.0 -setup
place_design -directive $placer_directive
puts "** Placer completed with directive: $placer_directive"
phys_opt_design -directive AggressiveExplore
write_checkpoint -force $work_directory/post_place.dcp
report_timing_summary -file $work_directory/post_place_timing.rpt
report_utilization    -file $work_directory/post_place_util.rpt

# remove overconstraining after placer
set_clock_uncertainty -from clock_from_mmcm -to clock_from_mmcm 0.0 -setup
route_design    -directive AggressiveExplore
phys_opt_design -directive AggressiveExplore
phys_opt_design -directive AlternateFlowWithRetiming
write_checkpoint -force $work_directory/post_route.dcp
report_timing_summary -file $work_directory/post_route_timing.rpt
report_utilization    -file $work_directory/post_route_util.rpt
report_drc -file $work_directory/post_route_drc.rpt

set bitstream_name ${board_name}_frost.bit
write_bitstream -force $work_directory/$bitstream_name
puts "** DONE — bitstream is at $work_directory/$bitstream_name"
exit
