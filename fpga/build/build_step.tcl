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

# Run one Vivado stage in the current directory. build.py launches place and
# route candidates in separate processes, bounded by --jobs.

# Utilities

# Incremental placement carries its reference's negative WNS target into saved
# checkpoints. Remove that history before later optimization, without changing
# the placed/routed design or the original checkpoint bound to the timing gate.
proc primitive_placement_snapshot {} {
    set cells [get_cells -hier -filter {IS_PRIMITIVE}]
    set rows {}
    foreach name [get_property NAME $cells] loc [get_property LOC $cells] bel [get_property BEL $cells] ref [get_property REF_NAME $cells] level [get_property PRIMITIVE_LEVEL $cells] {
        # A macro's BEL can be a constraint alias: unlocking DDR OBUFDS changes
        # OUTINV to OUTBUF without moving a leaf. Unplaced aliases can also have
        # BEL constraints. Compare actual BELs for both and LOC/BEL for placed leaves.
        if {$level eq "MACRO" || $loc eq ""} {
            set bel [lsort [get_bels -quiet -of_objects [get_cells -quiet $name]]]
        }
        lappend rows [list $name $loc $bel $ref]
    }
    return [lsort -index 0 $rows]
}

proc current_setup_hold_slacks {} {
    set result {}
    foreach delay_type {max min} {
        lappend result [get_property SLACK [get_timing_paths -delay_type $delay_type -max_paths 1]]
    }
    return $result
}

proc open_timing_checkpoint {checkpoint_path work_directory} {
    global script_directory
    open_checkpoint $checkpoint_path
    source [file join $script_directory x3_local_placement.tcl]
    frost_x3_local_placement::recover_unfixed_ports $checkpoint_path
    if {[frost_x3_local_placement::saved_constraints] ne ""} {
        set placement [primitive_placement_snapshot]
        set slacks [current_setup_hold_slacks]
        frost_x3_local_placement::release
        if {$placement ne [primitive_placement_snapshot] || $slacks ne [current_setup_hold_slacks]} {
            error "Removing temporary placement constraints changed placement or timing"
        }
        puts "FROST_TIMING_FLOW placement_preservation=off setup_hold_slacks=$slacks"
    }
    # The report is empty for a checkpoint without incremental history.
    if {[string trim [report_incremental_reuse -return_string]] eq ""} {return}

    set placement [primitive_placement_snapshot]
    set slacks [current_setup_hold_slacks]
    set clean_checkpoint [file join $work_directory timing_input.dcp]
    set write_incremental [get_param checkpoint.writeIncrFile]
    try {
        set_param checkpoint.writeIncrFile 0
        write_checkpoint -force $clean_checkpoint
    } finally {
        set_param checkpoint.writeIncrFile $write_incremental
    }
    close_design
    open_checkpoint $clean_checkpoint

    if {[string trim [report_incremental_reuse -return_string]] ne ""} {
        error "Incremental timing target survived checkpoint conversion"
    }
    if {$placement ne [primitive_placement_snapshot] || $slacks ne [current_setup_hold_slacks]} {
        error "Removing incremental history changed placement or timing"
    }
    puts "FROST_TIMING_FLOW incremental=off preserved_cells=[llength $placement] setup_hold_slacks=$slacks"
}

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

# Parse slack and the failing endpoint count from the setup summary row.
proc get_setup_timing_summary {timing_report_file} {
    set result [dict create wns "" tns "" failing ""]

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
        if {[llength $fields] >= 3} {
            dict set result failing [lindex $fields 2]
        }
        break
    }

    return $result
}

proc setup_timing_met {summary {wns ""}} {
    if {$wns eq ""} {set wns [dict get $summary wns]}
    set tns [dict get $summary tns]
    set failing [dict get $summary failing]
    return [expr {$wns ne "" && $wns >= 0.0 && $tns ne "" && $tns >= 0.0 &&
        [string is integer -strict $failing] && $failing == 0}]
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

proc vcu118_vector_enabled {} {
    set vector [getenv_default FROST_VECTOR 0]
    if {$vector ni {0 1}} {
        error "FROST_VECTOR must be 0 or 1 (got '$vector')"
    }
    return $vector
}

# build.py --debug-ila: gather every MARK_DEBUG net (the FROST_DEBUG_FETCH_ILA
# mirrors) into one ILA on the CPU clock, one probe per bus, bit 0 first. Runs
# on the synthesized design before the checkpoint is written; the bitstream
# step then also writes the probes file.
proc frost_insert_fetch_ila {clock_net_name depth} {
    set marked [get_nets -hierarchical -filter {MARK_DEBUG == 1}]
    if {[llength $marked] == 0} {
        error "FROST_DEBUG_ILA: no MARK_DEBUG nets (FROST_DEBUG_FETCH_ILA not defined?)"
    }
    array set groups {}
    foreach net $marked {
        set name [get_property NAME $net]
        if {[regexp {^(.*)\[(\d+)\]$} $name -> base index]} {
            lappend groups($base) [list $index $name]
        } else {
            lappend groups($name) [list 0 $name]
        }
    }
    create_debug_core u_ila_fetch ila
    set core [get_debug_cores u_ila_fetch]
    set_property C_DATA_DEPTH $depth $core
    set_property C_TRIGIN_EN false $core
    set_property C_TRIGOUT_EN false $core
    set_property C_ADV_TRIGGER false $core
    set_property C_INPUT_PIPE_STAGES 2 $core
    set_property C_EN_STRG_QUAL true $core
    set_property ALL_PROBE_SAME_MU true $core
    set_property ALL_PROBE_SAME_MU_CNT 2 $core
    set_property port_width 1 [get_debug_ports u_ila_fetch/clk]
    connect_debug_port u_ila_fetch/clk [get_nets $clock_net_name]
    set probe_index 0
    foreach base [lsort -dictionary [array names groups]] {
        set nets [list]
        foreach bit [lsort -integer -index 0 $groups($base)] {
            lappend nets [lindex $bit 1]
        }
        if {$probe_index > 0} {
            create_debug_port u_ila_fetch probe
        }
        set port [get_debug_ports u_ila_fetch/probe$probe_index]
        set_property port_width [llength $nets] $port
        set_property PROBE_TYPE DATA_AND_TRIGGER $port
        connect_debug_port $port [get_nets $nets]
        puts "ILA probe$probe_index <= $base ([llength $nets] bits)"
        incr probe_index
    }
    # The core is implemented when the opt step reopens the checkpoint in
    # non-project mode; here (project mode) implement_debug_core insists on
    # a saved design. The definitions travel in the checkpoint's constraints.
    puts "Fetch ILA: $probe_index probes, depth $depth, clock $clock_net_name"
}

proc split_env_list {value} {
    set normalized [string map [list "," " " ":" " "] $value]
    set result [list]
    foreach item [split $normalized] {
        set trimmed [string trim $item]
        if {$trimmed ne ""} {
            lappend result $trimmed
        }
    }
    return $result
}

proc set_x3_setup_uncertainty {board_name uncertainty reason} {
    if {$board_name ne "x3"} {
        return
    }

    # x3.xdc names the CPU clock clock_from_mmcm for every X3 clock source.
    set cpu_clock [get_clocks -quiet clock_from_mmcm]
    if {[llength $cpu_clock] != 1} {
        error "X3 CPU clock clock_from_mmcm not found ($reason)"
    }

    set_clock_uncertainty -from $cpu_clock -to $cpu_clock $uncertainty -setup
    puts "Set x3 CPU setup clock uncertainty to $uncertainty ns ($reason)"
}

proc write_physopt_iteration_outputs {work_directory step board_name physopt_uncertainty best_wns continue_sweeps {sweep_num 0}} {
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
    set timing_met [expr {$best_wns ne "" && $best_wns >= 0.0 &&
        [setup_timing_met [get_setup_timing_summary $timing_file]]}]
    if {$step eq "post_second_route_physopt" || ($step eq "post_route_physopt" && $timing_met)} {
        set main_checkpoint_name final.dcp
        set main_report_prefix final
    }

    set published_checkpoint [file join $main_work_directory $main_checkpoint_name]
    file copy -force $checkpoint_file ${published_checkpoint}.tmp
    file rename -force ${published_checkpoint}.tmp $published_checkpoint
    foreach suffix [list _timing.rpt _util.rpt _high_fanout.rpt _failing_paths.csv] {
        file copy -force [file join $work_directory "phys_opt$suffix"] [file join $main_work_directory "$main_report_prefix$suffix"]
    }

    # --snapshot-physopt-from needs the hash after all sweep reports are written.
    # The launch token rejects stale iteration records in reused directories.
    # build.py writes the stage's sidecar only after the whole stage succeeds.
    set launch_file [file join $work_directory phys_opt_launch.json]
    if {$board_name eq "x3" && $step eq "post_place_physopt" && [file exists $launch_file]} {
        set launch_handle [open $launch_file r]
        set launch_json [read $launch_handle]
        close $launch_handle
        if {![regexp {"run_id"\s*:\s*"([a-f0-9]+)"} $launch_json unused run_id]} {
            error "Invalid phys-opt launch token in $launch_file"
        }
        set checkpoint_sha256 [lindex [exec sha256sum $checkpoint_file] 0]
        set iteration_file [file join $work_directory phys_opt_iteration.json]
        set iteration_handle [open ${iteration_file}.tmp w]
        puts $iteration_handle [format {{"schema":"x3_physopt_iteration_v1","run_id":"%s","sweep":%d,"checkpoint_sha256":"%s"}} $run_id $sweep_num $checkpoint_sha256]
        close $iteration_handle
        file rename -force ${iteration_file}.tmp $iteration_file
    }

    puts ""
    puts "  Wrote completed $step iteration output:"
    puts "    $checkpoint_file"
    puts "    [file join $main_work_directory $main_checkpoint_name]"

    if {$continue_sweeps && $physopt_uncertainty ne ""} {
        set_x3_setup_uncertainty $board_name $physopt_uncertainty "$step sweep"
    }
}

# Arguments

# Arguments: board_name step directive checkpoint_path retiming ?software_mem_dir? ?x3_place_mode?
if {$argc < 5} {
    puts "Error: Required arguments: board_name step directive checkpoint_path retiming"
    puts "Usage: vivado -mode batch -source build_step.tcl -tclargs <board_name> <step> <directive> <checkpoint_path> <retiming> ?software_mem_dir? ?x3_place_mode?"
    puts ""
    puts "Steps: synth, opt, place, verify_place, quick_route, post_place_physopt, route, post_route_physopt, second_route, post_second_route_physopt, bitstream"
    exit 1
}

set board_name [lindex $argv 0]
set step [lindex $argv 1]
set directive [lindex $argv 2]
set checkpoint_path [lindex $argv 3]
set retiming [lindex $argv 4]
set software_mem_directory ""
set x3_place_mode [lindex $argv 6]
if {$x3_place_mode ne "" && ($board_name ne "x3" || $step ne "place" ||
    $x3_place_mode ni {reference guided})} {
    error "Invalid X3 placement mode: $x3_place_mode"
}

# Add future targets here. Board wrappers, file lists, and constraints follow
# the <board>/<board>_frost conventions below. DDR-capable targets also provide
# a <board>_ddr_bd.tcl script and create_<board>_ddr_bd procedure; targets with
# a NIC transceiver provide a <board>_gty_ip.tcl script and
# create_<board>_gty_ip procedure.
set board_build_configs [dict create \
    x3 [dict create part_number xcux35-vsva1365-3-e has_ddr 1 has_gty 1] \
    vcu118 [dict create part_number xcvu9p-flga2104-2L-e has_ddr 1 has_gty 1] \
]
if {![dict exists $board_build_configs $board_name]} {
    puts "Error: Invalid board name '$board_name'"
    puts "Valid boards: [join [lsort [dict keys $board_build_configs]] {, }]"
    exit 1
}

# Board configuration
set board_build_config [dict get $board_build_configs $board_name]
set fpga_part_number [dict get $board_build_config part_number]
set board_has_ddr [dict get $board_build_config has_ddr]
set board_has_gty [dict get $board_build_config has_gty]
set top_level_module_name ${board_name}_frost

set number_of_parallel_jobs 32

# frost_launch_ip_runs_isolated RUNS JOBS: launch each IP out-of-context run with its own launch_runs call and its own
# Tcl Store user area. One launch_runs call over all the runs starts the child Vivado sessions in the same second, and
# sessions that share a user area (XILINX_TCLSTORE_USERAREA, or the default per-user one) race on its manifest:
# [Common 17-354] Could not open ... for writing, [Common 17-1257] Failed to create directory. A child inherits
# XILINX_TCLSTORE_USERAREA from this process at launch, so each run gets a fresh private copy of the parent's area (or
# an empty one) under the build directory. The parent's value is restored afterwards, also on failure.
proc frost_launch_ip_runs_isolated {runs jobs} {
    set had_area [info exists ::env(XILINX_TCLSTORE_USERAREA)]
    set parent_area ""
    if {$had_area} {
        set parent_area $::env(XILINX_TCLSTORE_USERAREA)
    }
    set run_areas [dict create]
    foreach run $runs {
        set area [file normalize [file join [pwd] tclstore_ip $run]]
        file delete -force $area
        file mkdir $area
        if {$parent_area ne "" && [file isdirectory $parent_area]} {
            foreach entry [glob -nocomplain -directory $parent_area *] {
                file copy -force $entry $area
            }
        }
        dict set run_areas $run $area
    }
    try {
        foreach run $runs {
            set ::env(XILINX_TCLSTORE_USERAREA) [dict get $run_areas $run]
            launch_runs $run -jobs $jobs
        }
    } finally {
        if {$had_area} {
            set ::env(XILINX_TCLSTORE_USERAREA) $parent_area
        } else {
            unset -nocomplain ::env(XILINX_TCLSTORE_USERAREA)
        }
    }
}

# Directories

# build.py sets the working directory.
set work_directory [pwd]
set script_directory [file dirname [file normalize [info script]]]
set project_root_directory [file dirname $script_directory/../../../]
set board_specific_directory [file join $project_root_directory boards/$board_name]
set rtl_file_list [file join $board_specific_directory ${board_name}_frost.f]
set constraints_file [file join $board_specific_directory constr/${board_name}.xdc]
set vector_constraints_file [file join $board_specific_directory constr/${board_name}_vector.xdc]
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
    # Remove any project directory and temporary IP Tcl Store areas left by an
    # interrupted or preserved synthesis step so create_ip_run starts clean.
    file delete -force $work_directory/vivado_proj
    file delete -force $work_directory/tclstore_ip
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

    if {$board_has_gty} {
        # The board's transceiver wizard cores (on X3 the NIC's and the CPU
        # clock's); the board top's transceiver wrappers instantiate them.
        # FROST_GTY_RX_EQ selects the NIC's receive equalizer (LPM by
        # default, or DFE).
        source [file join [file dirname [info script]] ${board_name}_gty_ip.tcl]
        set create_gty_ip_proc create_${board_name}_gty_ip
        $create_gty_ip_proc [getenv_default FROST_GTY_RX_EQ LPM]
    }

    generate_target all [get_ips]
    # Project mode has no synth_ip (CRITICAL WARNING Vivado 12-5447). Each IP gets its out-of-context
    # run instead (create_ip_run, launch_runs, wait_on_run); the run leaves the IP's synthesized
    # checkpoint beside the IP, which synth_design links below.
    set ip_synth_runs [list]
    foreach ip_core [get_ips] {
        set ip_core_name [get_property NAME $ip_core]
        set ip_core_xci [get_files -all ${ip_core_name}.xci]
        set ip_synth_run ${ip_core_name}_synth_1
        if {[llength [get_runs -quiet $ip_synth_run]] == 0} {
            create_ip_run $ip_core_xci
        }
        if {[llength [get_runs -quiet $ip_synth_run]] != 1} {
            error "IP synthesis run $ip_synth_run was not created"
        }
        lappend ip_synth_runs $ip_synth_run
    }
    if {[llength $ip_synth_runs]} {
        set ip_synth_error ""
        try {
            frost_launch_ip_runs_isolated $ip_synth_runs $number_of_parallel_jobs
            foreach ip_synth_run $ip_synth_runs {
                wait_on_run $ip_synth_run
                if {$ip_synth_error eq "" &&
                    ([get_property PROGRESS [get_runs $ip_synth_run]] ne "100%" ||
                     [get_property STATUS [get_runs $ip_synth_run]] ne "synth_design Complete!")} {
                    set ip_synth_error "IP synthesis run $ip_synth_run did not complete: [get_property STATUS [get_runs $ip_synth_run]]"
                }
            }
        } finally {
            file delete -force [file join [pwd] tclstore_ip]
        }
        if {$ip_synth_error ne ""} {
            error $ip_synth_error
        }
    }

    if {$board_has_ddr} {
        # The board BD script builds its memory controller, SmartConnect, and
        # JTAG loader. The board top instantiates the generated ddr_subsys wrapper.
        source [file join [file dirname [info script]] ${board_name}_ddr_bd.tcl]
        set create_ddr_bd_proc create_${board_name}_ddr_bd
        $create_ddr_bd_proc
        # Synthesize BD children globally without out-of-context runs for the block design.
        set_property synth_checkpoint_mode None [get_files ddr_subsys.bd]
        generate_target all [get_files ddr_subsys.bd]
        set ddr_subsys_wrapper [make_wrapper -files [get_files ddr_subsys.bd] -top]
        add_files -norecurse $ddr_subsys_wrapper
    }

    set rtl_source_files [list]
    set rtl_include_dirs [get_property include_dirs [current_fileset]]
    foreach item [flatten_rtl_file_list $rtl_file_list $project_root_directory] {
        if {[string match {+incdir+*} $item]} {
            lappend rtl_include_dirs [string range $item 8 end]
        } elseif {[lsearch -exact $rtl_source_files $item] < 0} {
            lappend rtl_source_files $item
        }
    }
    set_property include_dirs [lsort -unique $rtl_include_dirs] [current_fileset]

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
    if {$board_has_ddr} {
        set ddr_capacity_log2 [getenv_default FROST_DDR_CAPACITY_LOG2_BYTES ""]
        if {![string is integer -strict $ddr_capacity_log2] ||
            $ddr_capacity_log2 < 30 || $ddr_capacity_log2 > 37} {
            error "FROST_DDR_CAPACITY_LOG2_BYTES must match the board's 1-128 GiB DDR map"
        }
        set capacity_define FROST_DDR_CAPACITY_LOG2_BYTES=$ddr_capacity_log2
        foreach existing_define $current_verilog_defines {
            if {[string match FROST_DDR_CAPACITY_LOG2_BYTES=* $existing_define] &&
                $existing_define ne $capacity_define} {
                error "Vivado already has a conflicting FROST DDR capacity define"
            }
        }
        if {[lsearch -exact $current_verilog_defines $capacity_define] < 0} {
            lappend current_verilog_defines $capacity_define
        }
    }
    # build.py --debug-ila compiles the fetch ILA mirrors in.
    if {[getenv_default FROST_DEBUG_ILA 0] eq "1" &&
        [lsearch -exact $current_verilog_defines FROST_DEBUG_FETCH_ILA] < 0} {
        lappend current_verilog_defines FROST_DEBUG_FETCH_ILA
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
    if {$board_name eq "vcu118" && [vcu118_vector_enabled] eq "1"} {
        read_xdc $vector_constraints_file
    }
    set_property top $top_level_module_name [current_fileset]

    set synth_args [list -top $top_level_module_name -part $fpga_part_number -directive $directive]
    if {$retiming eq "1"} {
        lappend synth_args -global_retiming on
    }
    # build.py --cpu-clock-div exports FROST_CPU_CLK_DIV as the board's CPU_CLK_DIV.
    # It selects the GTY or MMCM clock division and the software clock frequency.
    set cpu_clk_div [getenv_default FROST_CPU_CLK_DIV 1]
    if {$cpu_clk_div ne "1"} {
        lappend synth_args -generic CPU_CLK_DIV=$cpu_clk_div
        puts "CPU clock divider $cpu_clk_div (generic CPU_CLK_DIV)"
    }
    # Profiling counters are a build option: build.py --perf-counters exports
    # FROST_PERF_COUNTERS and the board top takes it as PERF_COUNTERS.
    set perf_counters [getenv_default FROST_PERF_COUNTERS 0]
    if {$perf_counters ne "0" && $perf_counters ne "1"} {
        puts "Error: FROST_PERF_COUNTERS must be 0 or 1 (got '$perf_counters')"
        exit 1
    }
    if {$perf_counters eq "1"} {
        lappend synth_args -generic PERF_COUNTERS=1
        puts "Profiling counters included (generic PERF_COUNTERS)"
    }
    if {$board_name eq "vcu118"} {
        set misaligned_hw [getenv_default FROST_MISALIGNED_HW 1]
        if {$misaligned_hw ni {0 1}} {
            error "FROST_MISALIGNED_HW must be 0 or 1 (got '$misaligned_hw')"
        }
        if {$misaligned_hw eq "0"} {
            lappend synth_args -generic MISALIGNED_HW=0
        }
        if {[vcu118_vector_enabled] eq "1"} {
            lappend synth_args -generic CPU_CLK_HZ=162500000 -generic VECTOR=1 -generic VECTOR_ADVERTISE=1
            puts "VCU118 vector unit included (CPU_CLK_HZ=162500000, VECTOR=1, VLEN=256, VECTOR_ADVERTISE=1)"
        }
    }
    # A name used before its declaration becomes an implicit net. Verilator
    # binds the later declaration, but inside a generate block Vivado gives the
    # use its own net, so either the use or the declaration is left undriven.
    # Top-level synthesis rejects implicit nets (Synth 8-11241), names used
    # before their declarations (Synth 8-6901), and generated primitive inputs
    # on an undriven net (Synth 8-605). Vendor IP runs finish before these guards.
    set_msg_config -id {Synth 8-11241} -new_severity ERROR
    set_msg_config -id {Synth 8-6901} -new_severity ERROR
    set_msg_config -id {Synth 8-605} -new_severity ERROR
    # Out-of-range indices can become don't-cares in synthesis even when
    # simulation truncates the index to the intended vector width.
    set_msg_config -id {Synth 8-324} -new_severity ERROR
    synth_design {*}$synth_args
    if {$board_name eq "x3"} {
        source [file join $board_specific_directory constr/cpu_clock_boundary.tcl]
    }

    if {[getenv_default FROST_DEBUG_ILA 0] eq "1"} {
        frost_insert_fetch_ila main_clock [getenv_default FROST_DEBUG_ILA_DEPTH 4096]
    }

    # Save after the timing report, as the opt step explains.
    report_timing_summary -file $work_directory/post_synth_timing.rpt
    write_checkpoint -force $work_directory/post_synth.dcp
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
    if {$board_name eq "vcu118" && [file exists $constraints_file]} {
        read_xdc $constraints_file
        if {[vcu118_vector_enabled] eq "1"} {
            read_xdc $vector_constraints_file
        }
    }

    # build.py --debug-ila: the synthesis step defined the fetch ILA;
    # instantiate it (and the debug hub) before optimization.
    if {[getenv_default FROST_DEBUG_ILA 0] eq "1" && [llength [get_debug_cores -quiet]] > 0} {
        implement_debug_core
        puts "Fetch ILA implemented: [llength [get_debug_cores]] debug core(s)"
    }

    opt_design -directive $directive

    # Save after the timing report, which brings the derived clocks up to
    # date. Reopening a checkpoint saved without them, Vivado applies
    # x3.xdc's rename of the CPU clock before it derives the transceiver
    # clocks, so clock_from_mmcm and the constraints that name it are lost.
    report_timing_summary -file $work_directory/post_opt_timing.rpt
    write_checkpoint -force $work_directory/post_opt.dcp
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
    # Delete audits written by the diagnostic pin-swap and flush-guidance
    # helpers; the production place step never runs those helpers.
    file delete $work_directory/post_place_pin_swap_audit.txt
    file delete $work_directory/post_place_flush_guidance_audit.tcldict
    open_checkpoint $checkpoint_path
    if {$board_name eq "vcu118" && [file exists $constraints_file]} {
        read_xdc $constraints_file
        if {[vcu118_vector_enabled] eq "1"} {
            read_xdc $vector_constraints_file
        }
    }

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

    # Vary setup uncertainty to generate placements and ease packing. build.py
    # uses 0.050 ns steps from 0.500 ns; published checkpoints and scores use zero.
    set x3_place_seed_baseline_uncertainty 0.5
    set x3_place_baseline_uncertainty 0.0
    set x3_place_uncertainty [getenv_default FROST_PLACE_SETUP_UNCERTAINTY $x3_place_seed_baseline_uncertainty]
    set_x3_setup_uncertainty $board_name $x3_place_uncertainty "place overconstraint"

    # Use the same thread count and scoring checkpoint sequence for these
    # three seeds, including the additional seed in build.py.
    set reopen_x3_place_seed [expr {
        $board_name eq "x3" &&
        (($directive eq "ExtraNetDelay_high" &&
          abs(double($x3_place_uncertainty) - double($x3_place_seed_baseline_uncertainty)) < 1.0e-9) ||
         ($directive eq "ExtraPostPlacementOpt" &&
          (abs(double($x3_place_uncertainty) - 0.450) < 1.0e-9 ||
           abs(double($x3_place_uncertainty) - 0.425) < 1.0e-9)))
    }]
    if {$reopen_x3_place_seed} {
        set_param general.maxThreads 8
    }

    if {$x3_place_mode ne ""} {
        source [file join $script_directory x3_place.tcl]
        if {$x3_place_mode eq "guided"} {
            set_x3_setup_uncertainty $board_name $x3_place_baseline_uncertainty "measure local floorplan choices"
        }
        frost_x3_place::prepare $x3_place_mode $work_directory
        if {$x3_place_mode eq "guided"} {
            set_x3_setup_uncertainty $board_name $x3_place_uncertainty "final placement guidance"
        }
    }

    # Physical controls must be applied before this single placement pass.
    place_design -directive $directive

    if {$x3_place_mode eq "guided"} {
        frost_x3_place::verify $work_directory
        report_drc -ruledecks placer_checks -file $work_directory/post_place_drc.rpt
    }

    # Restore the scoring uncertainty before writing reports.
    # Derived jitter and existing CDC/IP constraints remain active.
    set_x3_setup_uncertainty $board_name $x3_place_baseline_uncertainty "real post-place scoring"

    if {$reopen_x3_place_seed} {
        write_checkpoint -force $work_directory/post_place.dcp
        close_design
        open_checkpoint $work_directory/post_place.dcp
        set_x3_setup_uncertainty $board_name $x3_place_baseline_uncertainty "clean-reopen place scoring"
    }
    write_checkpoint -force $work_directory/post_place.dcp
    report_timing_summary -file $work_directory/post_place_timing.rpt
    report_utilization -file $work_directory/post_place_util.rpt
    report_high_fanout_nets -timing -load_types -max_nets 50 -file $work_directory/post_place_high_fanout.rpt
    write_failing_paths_csv $work_directory/post_place_failing_paths.csv $work_directory/post_place_timing.rpt
    # build.py rejects congestion at the configured level (default 5).
    # This report omits windows below 5; an empty list does not mean zero congestion.
    report_design_analysis -congestion -file $work_directory/post_place_congestion.rpt
    if {$board_name eq "x3"} {
        source [file join $script_directory x3_post_place_gate.tcl]
        frost_x3_post_place_gate::write $work_directory
    }

    puts "** DONE — place_design complete with directive: $directive"

} elseif {$step eq "verify_place"} {
    # A separate Vivado process checks the final placement's stored constraints.
    # Do not reset uncertainty or modify the checkpoint in this verification.
    if {$board_name ne "x3" || $checkpoint_path eq ""} {
        error "verify_place requires an X3 placement checkpoint"
    }
    open_checkpoint $checkpoint_path
    source [file join $script_directory x3_place.tcl]
    frost_x3_place::verify $work_directory
    source [file join $script_directory x3_post_place_gate.tcl]
    frost_x3_post_place_gate::write $work_directory
    report_timing_summary -file $work_directory/post_place_verification_timing.rpt
    report_route_status -file $work_directory/post_place_route_status.rpt
    puts "** DONE — verified unchanged post-place checkpoint"

} elseif {$step eq "quick_route"} {
    # X3 seed-ranking probe, not a pipeline step. Clear the overconstraint and
    # run the cheapest route for its reports only; build.py still promotes the
    # unrouted post_place.dcp.
    if {$checkpoint_path eq ""} {
        puts "Error: quick_route step requires checkpoint_path"
        exit 1
    }
    open_timing_checkpoint $checkpoint_path $work_directory

    if {$board_name eq "x3"} {
        set_clock_uncertainty -from clock_from_mmcm -to clock_from_mmcm 0.0 -setup
    }
    route_design -directive RuntimeOptimized

    report_route_status -file $work_directory/quick_route_status.rpt
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
    open_timing_checkpoint $checkpoint_path $work_directory

    # Post-place phys-opt defaults to 0.5 ns added setup uncertainty; post-route
    # defaults to zero so closure decisions use real constraints.
    # FROST_PHYSOPT_SETUP_UNCERTAINTY overrides these defaults. Promoted reports
    # and checkpoints always use zero added uncertainty.
    if {$step eq "post_place_physopt"} {
        set physopt_uncertainty_default 0.5
    } else {
        set physopt_uncertainty_default 0.0
    }
    set physopt_uncertainty [getenv_default FROST_PHYSOPT_SETUP_UNCERTAINTY $physopt_uncertainty_default]
    if {$physopt_uncertainty ne ""} {
        set_x3_setup_uncertainty $board_name $physopt_uncertainty "$step sweep"
    }

    set vcu118_vector_post_route [expr {
        $board_name eq "vcu118" &&
        $step eq "post_route_physopt" &&
        [vcu118_vector_enabled] eq "1"
    }]
    set sweep_order_env [getenv_default FROST_PHYSOPT_SWEEP_ORDER ""]
    if {$sweep_order_env ne ""} {
        set sweep_order [split_env_list $sweep_order_env]
    } elseif {$vcu118_vector_post_route} {
        set sweep_order [list AggressiveExplore]
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

    # Retiming is the final ordinary pass. On X3's last routed stage, try
    # endpoint groups only after the ordinary passes stop making progress.
    # The opt-in VCU118 vector post-route stage runs AggressiveExplore only,
    # repeated while WNS improves up to 3 passes.
    set directive_sweep_order [list]
    foreach sweep_pass $sweep_order {
        if {$sweep_pass ne "-retime"} {
            lappend directive_sweep_order $sweep_pass
        }
    }
    set sweep_order $directive_sweep_order
    if {!($vcu118_vector_post_route && $sweep_order_env eq "")} {
        lappend sweep_order "-retime"
    }
    set endpoint_fallback 0
    if {$board_name eq "x3" && $step eq "post_second_route_physopt" &&
        $sweep_order_env eq "" && $physopt_uncertainty ne ""} {
        source [file join $script_directory x3_endpoint_physopt.tcl]
        lappend sweep_order EndpointAggressive EndpointTargeted EndpointClockEnable \
            EndpointClockIndividual EndpointPinRefine EndpointRouteRefine
        set endpoint_fallback 1
    }

    set total_physopt_passes [llength $sweep_order]
    set total_passes_run 0
    set sweep_num 1
    set early_exit 0
    set best_wns -999999.0
    set best_tns -999999999.0
    set best_setup_closed 0
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

    set max_sweeps_default [expr {$vcu118_vector_post_route ? 3 : 0}]
    set max_sweeps [getenv_default FROST_PHYSOPT_MAX_SWEEPS $max_sweeps_default]
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
        set best_setup_closed [setup_timing_met $initial_timing_summary $initial_wns]
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
        set try_endpoint_passes 0
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
            set endpoint_pass [expr {$endpoint_fallback &&
                $sweep_pass in {EndpointAggressive EndpointTargeted EndpointClockEnable \
                    EndpointClockIndividual EndpointPinRefine EndpointRouteRefine}}]
            if {$endpoint_pass} {
                if {$sweep_pass eq "EndpointAggressive"} {
                    set try_endpoint_passes [expr {!$sweep_kept_improvement}]
                }
                if {!$try_endpoint_passes} {
                    incr pass_num
                    continue
                }
                set pass_label $sweep_pass
                set pass_display $sweep_pass
            } elseif {$sweep_pass eq "-retime"} {
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
            if {$endpoint_pass} {
                if {[catch {
                    frost_x3_endpoint_physopt::run $sweep_pass $physopt_uncertainty $work_directory
                } endpoint_ran endpoint_error]} {
                    # A changed/removed endpoint may make exact cleanup fail.
                    # Discard the entire trial, including its temporary groups
                    # and margin, by reopening the saved best implementation.
                    puts "  Rejecting failed $pass_display: $endpoint_ran"
                    puts [dict get $endpoint_error -errorinfo]
                    if {![file exists $best_checkpoint]} {
                        error "Cannot restore a best checkpoint after failed $pass_display"
                    }
                    catch {close_design}
                    open_checkpoint $best_checkpoint
                    incr total_passes_run
                    incr pass_num
                    continue
                }
                if {!$endpoint_ran} {
                    incr pass_num
                    continue
                }
            } else {
                phys_opt_design {*}$phys_opt_args
            }
            incr total_passes_run
            set pass_improved 0

            set pass_report [file join $work_directory [format "phys_opt_probe_s%02d_p%02d_%s_timing.rpt" $sweep_num $pass_num $pass_label]]
            report_timing_summary -file $pass_report
            set timing_summary [get_setup_timing_summary $pass_report]
            set report_wns [dict get $timing_summary wns]
            set tns [dict get $timing_summary tns]
            set candidate_valid 1
            if {$endpoint_pass} {
                set route_report [file rootname $pass_report]_route.rpt
                set skew_report [file rootname $pass_report]_bus_skew.rpt
                report_route_status -file $route_report
                report_bus_skew -max_paths 1 -nworst 1 -file $skew_report
                set candidate_valid [frost_x3_endpoint_physopt::candidate_is_legal \
                    $pass_report $route_report $skew_report]
            }

            set worst_path [lindex [get_timing_paths -delay_type max -nworst 1 -max_paths 1] 0]
            set wns ""
            if {$worst_path ne ""} {
                set wns [get_property SLACK $worst_path]
            } elseif {$report_wns ne ""} {
                set wns $report_wns
            }

            if {$wns ne "" && $candidate_valid} {
                set setup_closed [setup_timing_met $timing_summary $wns]
                set newly_closed [expr {$setup_closed && !$best_setup_closed}]
                set better_wns [expr {$wns > ($best_wns + $wns_tie_epsilon)}]
                set same_wns [expr {abs($wns - $best_wns) <= $wns_tie_epsilon}]
                set better_tns [expr {$tns ne "" && $tns > ($best_tns + $tns_keep_epsilon)}]
                puts ""
                if {$tns ne ""} {
                    puts "  WNS/TNS after $pass_display: $wns ns / $tns ns"
                } else {
                    puts "  WNS after $pass_display: $wns ns"
                }

                if {$newly_closed || $better_wns || ($same_wns && $better_tns)} {
                    if {$newly_closed} {
                        set improvement_reason "setup closure"
                    } elseif {$better_wns} {
                        set improvement_reason "WNS"
                    } else {
                        set improvement_reason "TNS tie-break"
                    }
                    set best_wns $wns
                    set best_setup_closed $setup_closed
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

                # Closure is retained even when rounded slack ties the old
                # failing checkpoint; only then can the sweep stop early.
                if {$setup_closed} {
                    puts "  ** Timing met; stopping $step sweep early after $total_passes_run total phys_opt passes"
                    set early_exit 1
                    break
                }
            }

            if {($repeat_sweeps || $endpoint_pass) && !$pass_improved && [file exists $best_checkpoint]} {
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
            if {!$vcu118_vector_post_route && $sweep_tns_delta ne "" && abs($best_wns - $sweep_start_wns) <= $wns_tie_epsilon} {
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

        write_physopt_iteration_outputs $work_directory $step $board_name $physopt_uncertainty $best_wns $continue_sweeps $sweep_num

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
    open_timing_checkpoint $checkpoint_path $work_directory

    # Route X3 at zero added setup uncertainty, whatever the input carries.
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
    open_timing_checkpoint $checkpoint_path $work_directory

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
    source [file join $script_directory x3_local_placement.tcl]
    frost_x3_local_placement::recover_unfixed_ports $checkpoint_path

    # Final reports
    report_timing_summary -file $work_directory/final_timing.rpt
    report_utilization -file $work_directory/final_util.rpt
    report_high_fanout_nets -timing -load_types -max_nets 50 -file $work_directory/final_high_fanout.rpt
    report_drc -file $work_directory/final_drc.rpt
    report_bus_skew -max_paths 1 -nworst 1 -file $work_directory/final_bus_skew.rpt
    write_failing_paths_csv $work_directory/final_failing_paths.csv $work_directory/final_timing.rpt
    source [file join $script_directory x3_endpoint_physopt.tcl]
    if {![frost_x3_endpoint_physopt::bus_skew_is_legal $work_directory/final_bus_skew.rpt]} {
        error "Bus-skew constraints are not met; refusing bitstream generation. See $work_directory/final_bus_skew.rpt"
    }

    set bitstream_name ${board_name}_frost.bit
    write_bitstream -force $work_directory/$bitstream_name
    if {[llength [get_debug_cores -quiet]] > 0} {
        # The Hardware Manager needs the probes file to see the ILA.
        write_debug_probes -force $work_directory/${board_name}_frost.ltx
        puts "** Debug probes: $work_directory/${board_name}_frost.ltx"
    }

    puts "** DONE — bitstream generated: $work_directory/$bitstream_name"

} else {
    puts "Error: Unknown step '$step'"
    puts "Valid steps: synth, opt, place, quick_route, post_place_physopt, route, post_route_physopt, second_route, post_second_route_physopt, bitstream"
    exit 1
}

exit
