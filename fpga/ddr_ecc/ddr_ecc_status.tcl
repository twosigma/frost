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

# Read the DDR4 controller's ECC registers over the DDR JTAG master.
# The status helper supplies the window. Check it against the design and the
# FPGA part before issuing any transaction.
# Writes occur only when the caller asks to clear the registers.

if {$argc < 4} {
    puts stderr "Usage: vivado -source ddr_ecc_status.tcl -tclargs <target> <clear> <window-base> <board> \[remote_host\] \[hw_server_url\] \[python\]"
    exit 1
}
set hw_target [lindex $argv 0]
set do_clear [lindex $argv 1]
set ecc_window_base [lindex $argv 2]
set board [lindex $argv 3]
set remote_host [lindex $argv 4]
set server_url [lindex $argv 5]
set python [lindex $argv 6]
if {$python eq ""} {set python python3}

if {$hw_target eq ""} {
    puts stderr "Error: a nonempty exact hardware target is required"
    exit 1
}
if {![regexp {^0x[0-9a-fA-F]{8}$} $ecc_window_base]} {
    puts stderr "Error: a 32-bit hexadecimal ECC window base is required"
    exit 1
}
if {$ecc_window_base % 4 != 0} {
    puts stderr "Error: ECC window base must align to a 32-bit word"
    exit 1
}
if {$do_clear ni {0 1} || ![regexp {^[a-z][a-z0-9_]*$} $board]} {
    puts stderr "Error: expected a clear flag (0 or 1) and a board name"
    exit 1
}

set script_dir [file dirname [info script]]
# Keep Vivado's bundled Python settings in its own process.
if {[catch {
    exec env -u PYTHONHOME -u PYTHONPATH -u PYTHON -- \
        $python [file join $script_dir ddr_ecc_status.py] $board --window-spec
} spec]} {
    puts stderr "Error: could not read the ECC window for $board: $spec"
    exit 1
}
lassign $spec part design_base
set registers {}
foreach entry [lrange $spec 2 end] {
    lassign [split $entry ":"] name offset
    set address [expr {$ecc_window_base + $offset}]
    if {$address + 4 > 0x100000000} {
        puts stderr "Error: $name exceeds the 32-bit JTAG address space"
        exit 1
    }
    dict set registers $name [format 0x%08x $address]
}
if {$ecc_window_base != $design_base} {
    puts stderr "Error: ECC window for $board is $design_base, got $ecc_window_base"
    exit 1
}

source [file join $script_dir .. common hw_session.tcl]
# Find the DDR master by cell name, as load_software.tcl does, or else as the
# only full AXI4 master (the BRAM loader is AXI4-Lite). Never probe with a
# write: this script must not disturb memory to find its master.
proc find_ddr_hw_axi {} {
    foreach axi [get_hw_axis] {
        set cell ""
        catch {set cell [get_property CELL_NAME $axi]}
        if {$cell ne "" && [string match "*jtag_axi_ddr*" $cell]} {
            return [get_property NAME $axi]
        }
    }
    set candidates {}
    foreach axi [get_hw_axis] {
        set protocol ""
        catch {set protocol [get_property PROTOCOL $axi]}
        if {[string match -nocase "*full*" $protocol]} {
            lappend candidates [get_property NAME $axi]
        }
    }
    if {[llength $candidates] == 1} {
        return [lindex $candidates 0]
    }
    return ""
}

proc report_ecc {axi registers marker} {
    dict for {name address} $registers {
        catch {delete_hw_axi_txn [get_hw_axi_txns eccrd]}
        create_hw_axi_txn eccrd [get_hw_axis $axi] -type read -address $address -len 1
        run_hw_axi [get_hw_axi_txns eccrd]
        set data [string trim [get_property DATA [get_hw_axi_txns eccrd]]]
        delete_hw_axi_txn [get_hw_axi_txns eccrd]
        if {![regexp {^[0-9a-fA-F]{8}$} $data]} {
            error "$name at $address did not return a 32-bit hexadecimal word"
        }
        puts "$marker $name@$address=$data"
    }
}

proc ecc_write {axi address value} {
    catch {delete_hw_axi_txn [get_hw_axi_txns eccwr]}
    create_hw_axi_txn eccwr [get_hw_axis $axi] \
        -type write -address $address -len 1 -data $value
    run_hw_axi [get_hw_axi_txns eccwr]
    delete_hw_axi_txn [get_hw_axi_txns eccwr]
}

frost_hw_session $remote_host $server_url $hw_target {
    set device [lindex [get_hw_devices] 0]
    set dev_part [get_property PART $device]
    if {![string match -nocase $part $dev_part] && ![string match -nocase "$part-*" $dev_part]} {
        error "Expected FPGA part $part for $board, found $dev_part"
    }
    refresh_hw_device -update_hw_probes false $device
    set ddr_axi [find_ddr_hw_axi]
    if {$ddr_axi eq ""} {
        puts stderr "Error: could not identify the DDR JTAG-AXI master"
        error "Could not identify the DDR JTAG-AXI master"
    }
    puts "FROST_ECC_MASTER $ddr_axi"

    report_ecc $ddr_axi $registers FROST_ECC

    if {$do_clear eq "1"} {
        # A one written to a latched ECC_STATUS bit clears it, and CE_CNT takes
        # the written value. The failing-address and data captures are
        # read-only; clearing the status re-arms them for the next error.
        ecc_write $ddr_axi [dict get $registers CE_CNT] 00000000
        ecc_write $ddr_axi [dict get $registers ECC_STATUS] 00000003
        puts "FROST_ECC_CLEARED"
        report_ecc $ddr_axi $registers FROST_ECC_AFTER
    }
    puts "FROST_ECC_DONE"
    flush stdout
}
