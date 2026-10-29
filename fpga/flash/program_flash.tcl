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

# Prepare configuration data or program the selected VCU118 flash.
set mode [lindex $argv 0]
if {$mode eq "prepare" && $argc == 4} {
    lassign [lrange $argv 1 end] boot bit cfg
    if {![file isfile $boot] || [file size $boot] != 0x400000} {
        error "Expected a four-MiB boot image"
    }
    set options [list -format bin -size 128 -interface SPIx4 \
        -loaddata [list up 0x03000000 $boot] -force]
    if {$bit ne ""} {
        if {![file isfile $bit] || [file extension $bit] ne ".bit"} {
            error "Expected a .bit configuration file"
        }
        lappend options -loadbit [list up 0 $bit]
    }
    write_cfgmem {*}$options $cfg
} elseif {$mode eq "program" && $argc == 4} {
    lassign [lrange $argv 1 end] cfg target url
    set prm [file rootname $cfg].prm
    if {$target eq "" || ![file isfile $cfg] || ![file isfile $prm]} {
        error "Configuration data, its PRM file and an exact target are required"
    }
    source [file join [file dirname [info script]] .. common hw_session.tcl]
    frost_hw_session "" $url $target {
        set device [lindex [get_hw_devices] 0]
        if {![string match "xcvu9p*" [get_property PART $device]]} {
            error "Expected xcvu9p on the selected target"
        }
        set part [lsort -unique [get_cfgmem_parts mt25qu01g-spi-x1_x2_x4]]
        if {[llength $part] != 1} {error "Expected the VCU118 configuration flash part"}
        create_hw_cfgmem -hw_device $device $part
        set memory [get_property PROGRAM.HW_CFGMEM $device]
        foreach {name value} {BLANK_CHECK 0 ERASE 1 CFG_PROGRAM 1 VERIFY 1 CHECKSUM 0
                             ADDRESS_RANGE use_file UNUSED_PIN_TERMINATION pull-none} {
            set_property PROGRAM.$name $value $memory
        }
        set_property PROGRAM.FILES [list $cfg] $memory
        set_property PROGRAM.PRM_FILE [list $prm] $memory
        create_hw_bitstream -hw_device $device [get_property PROGRAM.HW_CFGMEM_BITFILE $device]
        program_hw_devices $device
        refresh_hw_device $device
        program_hw_cfgmem -hw_cfgmem $memory
        puts "FROST_FLASH_COMPLETE"
    }
} else {
    error "Usage: prepare boot-image bitstream-or-empty output | program cfg exact-target server-url"
}
