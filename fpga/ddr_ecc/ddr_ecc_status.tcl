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

# Read the DDR4 controller's ECC registers over the JTAG DDR-load master.
#
# The controller's ECC management interface is reachable only from that master,
# at region offset 0x4000_0000 (fpga/build/x3_ddr_bd.tcl assigns it there). The
# register offsets are the controller's own; ddr_ecc_status.py names them.
#
# Reading is free of side effects. Clearing is not, and only happens when the
# caller asks: ECC_STATUS and CE_CNT are write-to-clear, and the failing-address
# and failing-data captures reload on the next error after the status clears.

if {$argc < 3} {
    puts stderr "Usage: vivado -source ddr_ecc_status.tcl -tclargs <target> <clear> <register-list> \[remote_host\] \[hw_server_url\]"
    exit 1
}
set hw_target [lindex $argv 0]
set do_clear [lindex $argv 1]
set register_list [lindex $argv 2]
set remote_host [lindex $argv 3]
set server_url [lindex $argv 4]

if {$hw_target eq ""} {
    puts stderr "Error: a nonempty exact hardware target is required"
    exit 1
}

# The controller's ECC window, relative to the DDR master's address space.
set ECC_WINDOW_BASE 0x40000000

source [file join [file dirname [info script]] .. common hw_session.tcl]

# The DDR master by name, as load_software.tcl identifies it; failing that, by
# protocol, since the DDR master is the AXI4 one and the BRAM loader is Lite.
# No write probe here: this script must not disturb memory to find its master.
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

proc ecc_read {axi offset} {
    global ECC_WINDOW_BASE
    set address [format 0x%08x [expr {$ECC_WINDOW_BASE + $offset}]]
    catch {delete_hw_axi_txn [get_hw_axi_txns eccrd]}
    create_hw_axi_txn eccrd [get_hw_axis $axi] -type read -address $address -len 1
    run_hw_axi [get_hw_axi_txns eccrd]
    set data [get_property DATA [get_hw_axi_txns eccrd]]
    delete_hw_axi_txn [get_hw_axi_txns eccrd]
    return $data
}

proc ecc_write {axi offset value} {
    global ECC_WINDOW_BASE
    set address [format 0x%08x [expr {$ECC_WINDOW_BASE + $offset}]]
    catch {delete_hw_axi_txn [get_hw_axi_txns eccwr]}
    create_hw_axi_txn eccwr [get_hw_axis $axi] \
        -type write -address $address -len 1 -data $value
    run_hw_axi [get_hw_axi_txns eccwr]
    delete_hw_axi_txn [get_hw_axi_txns eccwr]
}

frost_hw_session $remote_host $server_url $hw_target {
    refresh_hw_device -update_hw_probes false [lindex [get_hw_devices] 0]
    set ddr_axi [find_ddr_hw_axi]
    if {$ddr_axi eq ""} {
        puts stderr "Error: could not identify the DDR JTAG-AXI master"
        error "Could not identify the DDR JTAG-AXI master"
    }
    puts "FROST_ECC_MASTER $ddr_axi"

    # register_list is "name:offset name:offset ...", built by the Python side
    # so both ends name the registers identically.
    foreach entry $register_list {
        set parts [split $entry ":"]
        set name [lindex $parts 0]
        set offset [lindex $parts 1]
        puts "FROST_ECC $name=[ecc_read $ddr_axi $offset]"
    }

    if {$do_clear eq "1"} {
        # Writing a one to a latched status bit clears it; CE_CNT clears on any
        # write. The failing captures are read-only and reload with the next
        # error, so clearing the status is what re-arms them.
        ecc_write $ddr_axi 0x00C 00000000
        ecc_write $ddr_axi 0x000 00000003
        puts "FROST_ECC_CLEARED"
        foreach entry $register_list {
            set parts [split $entry ":"]
            set name [lindex $parts 0]
            set offset [lindex $parts 1]
            puts "FROST_ECC_AFTER $name=[ecc_read $ddr_axi $offset]"
        }
    }
    puts "FROST_ECC_DONE"
    flush stdout
}
