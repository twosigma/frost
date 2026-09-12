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

# Fresh-netlist flush replication request and post-placement verification.
# The caller owns design opening, placement, constraints and checkpoints.
namespace eval ::frost_x3_flush_guidance {
    variable driver_name {subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/misprediction_flush_controller_inst/full_flush_side_effect_kill_q_reg}
    variable net_name {subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/misprediction_flush_controller_inst/full_flush_side_effect_kill_q}
    variable cells {}
    variable state {}
}
proc ::frost_x3_flush_guidance::one {objects description} {
    if {[llength $objects] != 1} {error "Expected one $description; found [llength $objects]"}
    return [lindex $objects 0]
}
proc ::frost_x3_flush_guidance::names {objects} {
    if {![llength $objects]} {return {}}
    return [lsort -unique [get_property NAME $objects]]
}
proc ::frost_x3_flush_guidance::find {command name} {
    set escaped [string map [list \\ \\\\ \" \\\"] $name]
    return [$command -quiet -hierarchical -filter [format {NAME == "%s"} $escaped]]
}
proc ::frost_x3_flush_guidance::cell {name} {
    variable cells
    if {![dict exists $cells $name]} {dict set cells $name [one [find get_cells $name] "cell $name"]}
    return [dict get $cells $name]
}
proc ::frost_x3_flush_guidance::pin {name} {
    set c [cell [file dirname $name]]
    foreach p [get_pins -quiet -of_objects $c] {
        if {[get_property NAME $p] eq $name} {return $p}
    }
    error "Missing exact pin $name"
}
proc ::frost_x3_flush_guidance::prop {object key} {
    if {$key ni [list_property $object]} {return {}}
    return [get_property $key $object]
}
proc ::frost_x3_flush_guidance::inactive {value} {
    return [expr {[string tolower $value] in {{} 0 false no}}]
}
proc ::frost_x3_flush_guidance::driver {p} {
    set direct [get_nets -quiet -of_objects $p]
    set ds [get_pins -quiet -of_objects $direct -filter {DIRECTION == OUT}]
    if {[llength $ds] == 1} {
        set owner [one [get_cells -quiet -of_objects $ds] "source owner"]
        if {[get_property IS_PRIMITIVE $owner]} {return [lindex $ds 0]}
    }
    # Driver-only expansion; no clock/reset consumer enumeration.
    set ns [get_nets -quiet -segments -of_objects $p]
    return [one [get_pins -quiet -leaf -of_objects $ns -filter {DIRECTION == OUT}] "electrical source"]
}
proc ::frost_x3_flush_guidance::source {p} {
    set d [driver $p]
    set ref [get_property REF_NAME [one [get_cells -quiet -of_objects $d] "primitive source owner"]]
    if {$ref in {GND VCC}} {return @$ref}
    return [get_property NAME $d]
}
proc ::frost_x3_flush_guidance::sink_set {q {allow_disconnected 0}} {
    set ns [get_nets -quiet -segments -of_objects $q]
    if {![llength $ns] && $allow_disconnected} {return {}}
    if {![llength $ns] || [llength [get_ports -quiet -of_objects $ns]]} {error "Flush Q output disconnected or reaches a top-level port"}
    if {[names [get_pins -quiet -leaf -of_objects $ns -filter {DIRECTION == OUT}]] ne [list [get_property NAME $q]]} {error "Ambiguous flush output driver"}
    set sinks [get_pins -quiet -leaf -of_objects $ns -filter {DIRECTION == IN}]
    if {[llength $sinks] > 1024 || [llength [names $sinks]] != [llength $sinks]} {error "Flush sink set exceeds finite scope or contains duplicates"}
    return [names $sinks]
}
proc ::frost_x3_flush_guidance::signature {name} {
    set c [cell $name]
    if {[get_property REF_NAME $c] ne "FDRE"} {error "Flush driver is not FDRE: $name"}
    set ports {}; foreach port {C CE D R Q} {lappend ports "$name/$port"}
    if {[names [get_pins -quiet -of_objects $c]] ne [lsort $ports]} {error "Changed FDRE interface: $name"}
    set result [dict create REF_NAME FDRE INIT [get_property INIT $c] inversions {} inputs {}]
    foreach key [lsort [list_property $c]] {
        if {[regexp {^IS_.*_INVERTED$} $key]} {dict set result inversions $key [get_property $key $c]}
    }
    foreach port {C CE D R} {
        set p [pin "$name/$port"]
        if {[get_property DIRECTION $p] ne "IN"} {error "Changed FDRE input direction"}
        dict set result inputs $port [source $p]
    }
    if {[get_property DIRECTION [pin "$name/Q"]] ne "OUT"} {error "Changed FDRE output direction"}
    set clk [one [get_clocks -quiet -of_objects [pin "$name/C"]] "flush CPU clock"]
    if {[get_property NAME $clk] ne "clock_from_mmcm" || [get_property PERIOD $clk] != 3.333} {error "Expected 300 MHz CPU clock on flush FDRE"}
    dict set result clock [list [get_property NAME $clk] [get_property PERIOD $clk]]
    return $result
}
proc ::frost_x3_flush_guidance::protection {c} {
    set result {}; set seen {}
    while {1} {
        set name [get_property NAME $c]
        if {$name in $seen || [llength $seen] >= 32} {error "Invalid flush hierarchy"}
        lappend seen $name
        set dt [prop $c DONT_TOUCH]
        if {![inactive $dt]} {error "Protected flush driver/ancestor: $name"}
        # KEEP=yes on the source FDRE is intentional RTL and compatible with
        # the placement replication request. Preserve it; never clear it.
        dict set result $name [dict create DONT_TOUCH $dt KEEP [prop $c KEEP]]
        set parent [prop $c PARENT]
        if {$parent eq {}} {break}
        set c [cell $parent]
    }
    return $result
}
proc ::frost_x3_flush_guidance::preflight {} {
    variable driver_name; variable net_name
    set c [cell $driver_name]
    foreach key {LOC BEL LOCK_PINS RLOC LUTNM HLUTNM SOFT_HLUTNM HU_SET U_SET H_SET} {
        if {[prop $c $key] ne {}} {error "Flush guidance requires an unplaced/unpacked FDRE: $key"}
    }
    foreach key {IS_LOC_FIXED IS_BEL_FIXED} {if {![inactive [prop $c $key]]} {error "Fixed flush driver"}}
    set sig [signature $driver_name]
    set protections [protection $c]
    set q [pin "$driver_name/Q"]
    set net [one [get_nets -quiet -of_objects $q] "direct flush Q net"]
    if {[get_property NAME $net] ne $net_name} {error "Changed direct flush Q net identity"}
    foreach key {MAX_FANOUT_MODE FORCE_MAX_FANOUT DONT_TOUCH} {
        if {$key ni [list_property $net]} {error "Missing physical replication property $key"}
    }
    set aliases {}
    foreach n [get_nets -quiet -segments -of_objects $q] {
        set dt [prop $n DONT_TOUCH]
        if {![inactive $dt]} {error "Protected flush net segment"}
        dict set aliases [get_property NAME $n] [dict create DONT_TOUCH $dt KEEP [prop $n KEEP]]
    }
    set mode [get_property MAX_FANOUT_MODE $net]; set limit [get_property FORCE_MAX_FANOUT $net]
    if {[string tolower $mode] ni {{} none clock_region} || $limit ni {{} 0 64}} {error "Conflicting existing flush fanout request"}
    set sinks [sink_set $q]
    if {![llength $sinks]} {error "Flush driver has no sinks"}
    return [dict create driver $driver_name net $net_name signature $sig sinks $sinks \
        protection $protections net_protection $aliases previous_mode $mode previous_limit $limit]
}
proc ::frost_x3_flush_guidance::audit {path value} {
    set f [open $path w]; try {puts $f $value} finally {close $f}
}
# Prepare and verify run in the same Vivado session around the caller's place.
# Return the captured current-design state; no external model is loaded.
proc ::frost_x3_flush_guidance::prepare {audit_file} {
    variable state; variable cells
    if {$state ne {}} {error "Flush guidance prepare already called in this session"}
    set cells {}
    audit $audit_file [dict create status PREFLIGHT]
    if {[catch {preflight} before options]} {
        audit $audit_file [dict create status FAILED_BEFORE_CHANGE reason $before]
        return -options $options $before
    }
    set state $before
    audit $audit_file [dict create status PROPERTY_UPDATE_STARTED before $state]
    if {[catch {
        set n [one [find get_nets [dict get $state net]] "flush Q net"]
        set_property MAX_FANOUT_MODE CLOCK_REGION $n
        if {![string equal -nocase [get_property MAX_FANOUT_MODE $n] CLOCK_REGION]} {error "Flush mode readback mismatch"}
        set_property FORCE_MAX_FANOUT 64 $n
        if {[get_property FORCE_MAX_FANOUT $n] ne "64"} {error "Flush limit readback mismatch"}
    } message options]} {
        audit $audit_file [dict create status FAILED_PROPERTY_UPDATE reason $message before $state]
        return -options $options $message
    }
    dict set state prepared 1
    audit $audit_file [dict create status PREPARED before $state mode CLOCK_REGION limit 64]
    puts "FROST_X3_FLUSH_GUIDANCE=PREPARED SINKS=[llength [dict get $state sinks]]"
    return $state
}
proc ::frost_x3_flush_guidance::verify_state {} {
    variable state; variable cells
    if {$state eq {} || ![dict exists $state prepared]} {error "Flush guidance was not prepared successfully"}
    set cells {}; set candidates {}; set owners {}
    # Connectivity discovers candidates; a name prefix alone proves nothing.
    foreach name [dict get $state sinks] {
        set p [pin $name]
        if {[get_property DIRECTION $p] ne "IN"} {error "Original flush sink direction changed"}
        set d [driver $p]
        if {[get_property REF_PIN_NAME $d] ne "Q"} {error "Original flush sink has a non-Q driver"}
        set c [one [get_cells -quiet -of_objects $d] "placed flush driver"]
        dict set candidates [get_property NAME $c] 1
        dict set owners $name [get_property NAME $d]
    }
    set original [dict get $state driver]
    set original_cells [find get_cells $original]
    if {[llength $original_cells] > 1} {error "Ambiguous original flush cell"}
    if {[llength $original_cells]} {dict set candidates $original 1}
    if {[dict size $candidates] > 1024} {error "Too many flush candidates"}
    set all {}; set partitions {}; set expected [dict get $state signature]
    foreach name [lsort [dict keys $candidates]] {
        if {[signature $name] ne $expected} {error "Changed flush replica register function/inputs: $name"}
        set sinks [sink_set [pin "$name/Q"] [expr {$name eq $original}]]
        foreach sink $sinks {
            if {$sink in $all} {error "Flush sink has multiple candidate owners"}
            lappend all $sink
        }
        dict set partitions $name $sinks
    }
    if {[lsort $all] ne [dict get $state sinks]} {error "Placed flush drivers do not preserve the complete original sink set"}
    # The placer may remove the original FDRE while retaining equivalent
    # replicas. Existing protected objects retain their original properties.
    dict for {name flags} [dict get $state protection] {
        set objects [find get_cells $name]
        if {![llength $objects] && $name eq [dict get $state driver]} {continue}
        set c [one $objects "preserved flush ancestor"]
        dict for {key value} $flags {if {[prop $c $key] ne $value} {error "Flush placement changed $name/$key"}}
    }
    return [dict create drivers [dict size $partitions] sinks [llength $all] \
        signature $expected partitions $partitions owners $owners]
}
proc ::frost_x3_flush_guidance::verify {audit_file} {
    variable state
    if {[catch {verify_state} result options]} {
        audit $audit_file [dict create status FAILED_AFTER_PLACE reason $result before $state]
        return -options $options $result
    }
    audit $audit_file [dict merge [dict create status VERIFIED before $state] $result]
    puts "FROST_X3_FLUSH_GUIDANCE=VERIFIED DRIVERS=[dict get $result drivers] SINKS=[dict get $result sinks]"
    return $result
}
