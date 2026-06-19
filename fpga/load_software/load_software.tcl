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

# Vivado TCL script to load software images via JTAG.
# Writes the low-BRAM image through AXI and, when present, bursts the
# cached-region image into DDR through the board's second JTAG-AXI master.

if { $argc < 3 } {
    puts "Error: Project root, software application name, and hardware target required"
    puts "Usage: vivado -source load_software.tcl -tclargs <project_root> <app_name> <hw_target> \[remote_host\] \[has_ddr\]"
    exit 1
}
set project_root [lindex $argv 0]
set software_application_name [lindex $argv 1]
set hw_target [lindex $argv 2]
# has_ddr: the bitstream provides the JTAG DDR-load master (hw_axi_2) and the
# DDR-backed cached region. Passed by load_software.py from BOARD_CONFIG.
set has_ddr 0
if { $argc >= 5 } {
    set has_ddr [lindex $argv 4]
}

set coremark_pro_apps [list coremark_pro_core coremark_pro_cjpeg \
                            coremark_pro_linear_alg coremark_pro_loops \
                            coremark_pro_nnet coremark_pro_parser \
                            coremark_pro_radix2 coremark_pro_sha \
                            coremark_pro_zip]

# Valid software applications (mirrors load_software.py VALID_APPS)
set valid_apps [list branch_pred_test c_ext_test call_stress cf_ext_test coremark \
                     {*}$coremark_pro_apps csr_test ddr_exec_test ddr_heap_test \
                     ddr_smc_test ddr_test freertos_demo fpu_assembly_test fpu_test \
                     hello_world isa_test memory_test \
                     packet_parser print_clock_speed ras_stress_test ras_test \
                     spanning_test sprintf_test strings_test tomasulo_perf \
                     tomasulo_test uart_echo]

if { [lsearch -exact $valid_apps $software_application_name] == -1 } {
    puts "Error: Invalid software app '$software_application_name'"
    puts "Valid apps: [join $valid_apps {, }]"
    exit 1
}

# Path to software binary in Vivado BRAM format (8 hex digits per line)
set firmware_application_name $software_application_name
if { [lsearch -exact $coremark_pro_apps $software_application_name] != -1 } {
    set firmware_application_name coremark_pro
}
set firmware_text_file ${project_root}/sw/apps/${firmware_application_name}/sw.txt

# Source helper functions for writing binary data to BRAM / DDR via AXI
set script_dir [file dirname [file normalize [info script]]]
source ${script_dir}/file_to_bram.tcl
source ${script_dir}/file_to_ddr.tcl

# Connect to FPGA hardware via JTAG
open_hw_manager
if { $argc >= 4 && [lindex $argv 3] ne "" } {
    # Remote host was provided - connect to remote hardware server
    set remote_hardware_server [lindex $argv 3]
    connect_hw_server -url ${remote_hardware_server}:3121
} else {
    # No remote host - connect to local hardware server
    connect_hw_server
}

# Select the specified hardware target and open it
current_hw_target $hw_target
open_hw_target

# Refresh device and reset AXI interface
refresh_hw_device [lindex [get_hw_devices] 0]
reset_hw_axi [get_hw_axis -of_objects [lindex [get_hw_devices] 0]]

# ---------------------------------------------------------------------------
# Identify the JTAG-AXI masters. DDR-enabled bitstreams contain TWO: the BRAM
# loader (jtag_to_axi_bridge in xilinx_frost_subsystem) and the DDR-image
# loader (jtag_axi_ddr inside the ddr_subsys block design). The hardware
# server enumerates them as hw_axi_1/hw_axi_2 in an order we do not control,
# so resolve them by the debug core's cell name; if that property is
# unavailable, fall back to a functional probe: the BRAM controller's read
# data is tied to zero, so write-then-readback distinguishes the two (the DDR
# echoes the written word, the BRAM path reads back zero). Probe writes land
# at addresses the subsequent image load overwrites anyway.
# ---------------------------------------------------------------------------
proc find_hw_axi_by_cell {pattern} {
    foreach axi [get_hw_axis] {
        set cell ""
        catch {set cell [get_property CELL_NAME $axi]}
        if {$cell ne "" && [string match $pattern $cell]} {
            return [get_property NAME $axi]
        }
    }
    return ""
}

proc probe_hw_axi_echoes {axi_name} {
    # Returns 1 if a write to address 0 reads back (DDR), 0 if it reads zero
    # (the BRAM controller, whose read data is tied off).
    catch {delete_hw_axi_txn probe_wr}
    catch {delete_hw_axi_txn probe_rd}
    create_hw_axi_txn probe_wr [get_hw_axis $axi_name] \
        -type write -address 0x00000000 -len 1 -data {A5A5A5A5}
    run_hw_axi [get_hw_axi_txns probe_wr]
    create_hw_axi_txn probe_rd [get_hw_axis $axi_name] \
        -type read -address 0x00000000 -len 1
    run_hw_axi [get_hw_axi_txns probe_rd]
    set data [get_property DATA [get_hw_axi_txns probe_rd]]
    delete_hw_axi_txn probe_wr
    delete_hw_axi_txn probe_rd
    return [expr {[string match -nocase "*a5a5a5a5*" $data] ? 1 : 0}]
}

set all_hw_axis [get_hw_axis]
set bram_axi ""
set ddr_axi ""
if {[llength $all_hw_axis] == 1} {
    set bram_axi [get_property NAME [lindex $all_hw_axis 0]]
    if {$has_ddr && [probe_hw_axi_echoes $bram_axi]} {
        puts "Error: only one JTAG-AXI master enumerated and it echoes like the"
        puts "DDR loader -- the BRAM loader is missing from the debug chain."
        exit 1
    }
} else {
    set bram_axi [find_hw_axi_by_cell "*jtag_to_axi_bridge*"]
    set ddr_axi [find_hw_axi_by_cell "*jtag_axi_ddr*"]
    if {$bram_axi eq "" || $ddr_axi eq ""} {
        puts "CELL_NAME unavailable; probing JTAG-AXI masters to identify them..."
        # One probe suffices with two masters: if the first echoes it is the
        # DDR loader and the other is the BRAM loader by elimination (and the
        # BRAM side never sees the probe write at all).
        set first_name [get_property NAME [lindex $all_hw_axis 0]]
        set second_name [get_property NAME [lindex $all_hw_axis 1]]
        if {[probe_hw_axi_echoes $first_name]} {
            set ddr_axi $first_name
            set bram_axi $second_name
        } else {
            set bram_axi $first_name
            set ddr_axi $second_name
        }
    }
    if {$bram_axi eq ""} {
        puts "Error: could not identify the BRAM-loader JTAG-AXI master"
        exit 1
    }
}
set axi_report "JTAG-AXI masters: BRAM loader = ${bram_axi}"
if {$ddr_axi ne ""} {
    append axi_report ", DDR loader = ${ddr_axi}"
}
puts $axi_report

set bram_base_address 0x00000000
set ddr_text_file ${project_root}/sw/apps/${firmware_application_name}/sw_ddr.txt

# DDR image first (when present): assert the image-load CPU reset with a
# single low-BRAM write, then burst the DDR image through hw_axi_2. The CPU
# stays in reset until well after the subsequent full BRAM load, and the
# caches re-invalidate on release, so the fresh DDR contents are never
# shadowed by stale lines or racing writebacks.
if { $has_ddr && $ddr_axi ne "" && [file exists $ddr_text_file] && [file size $ddr_text_file] > 12 } {
    set first_word_fd [open $firmware_text_file r]
    gets $first_word_fd first_word
    close $first_word_fd
    create_hw_axi_txn rst_assert [get_hw_axis $bram_axi] \
        -type write -address 0x00000000 -len 1 -data $first_word
    run_hw_axi [get_hw_axi_txns rst_assert]
    set ddr_word_count [expr {[file size $ddr_text_file] / 9}]
    puts "Loading ~${ddr_word_count} words into DDR via ${ddr_axi} (bursts)..."
    file2ddr $ddr_text_file $ddr_axi
}

# Write software to low BRAM starting at address 0.
file2bram $bram_base_address $firmware_text_file $bram_axi

# Load complete. The CPU was held in reset for the entire transfer above and
# only begins executing this image now, so any UART output received before this
# point is stale data from the previously loaded program. Emit a flushed
# sentinel on stdout so non-interactive harnesses (e.g.
# fpga/sweep_coremark_pro.py) can mark that boundary and ignore the stale tail.
puts "FROST_LOAD_COMPLETE"
flush stdout
