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

# Validate command line arguments - require board name, synth_only flag, and retiming flag
if {$argc != 3} {
    puts "Error: Board name, synth_only flag, and retiming flag are required"
    puts "Usage: vivado -mode batch -source build.tcl -tclargs <board_name> <synth_only> <retiming>"
    exit 1
}
set board_name [lindex $argv 0]
set synth_only [lindex $argv 1]
set retiming [lindex $argv 2]
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
set work_directory   [file join $script_directory $board_name work]
set project_root_directory [file dirname $script_directory/../../../]
set board_specific_directory [file join $project_root_directory boards/$board_name]
set rtl_file_list [file join $board_specific_directory ${board_name}_frost.f]
set constraints_file [file join $board_specific_directory constr/${board_name}.xdc]

puts "Board: $board_name"
puts "FPGA Part: $fpga_part_number"
puts "Top Module: $top_level_module_name"
puts "Script directory: $script_directory"
puts "Project root: $project_root_directory"
puts "Board files: $board_specific_directory"

# Create work directory if it doesn't exist
if {![file isdirectory $work_directory]} {
    file mkdir $work_directory
}

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
                     -flatten_hierarchy rebuilt \
                     -directive AlternateRoutability \
                     -resource_sharing off]
if {$retiming eq "1"} {
    lappend synth_args -global_retiming on
}
synth_design {*}$synth_args

write_checkpoint -force $work_directory/post_synth.dcp
report_timing_summary -file $work_directory/post_synth_timing.rpt
report_utilization    -file $work_directory/post_synth_util.rpt

if {$synth_only eq "1"} {
    puts "** DONE — synthesis only, checkpoint at $work_directory/post_synth.dcp"
    exit
}

opt_design -directive ExploreWithRemap
write_checkpoint -force $work_directory/post_opt.dcp
report_timing_summary -file $work_directory/post_opt_timing.rpt
report_utilization    -file $work_directory/post_opt_util.rpt

# apply overconstraining during placer for better placement
set_clock_uncertainty -from clock_from_mmcm -to clock_from_mmcm 1.0 -setup
place_design -directive ExtraNetDelay_high
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
