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

# Bounded native-command model. It exercises the production Tcl, including
# distinct upper/lower macro nets and protection failures during reconnects.
set scenario [lindex $argv 0]
set helper [lindex $argv 1]
set audit [lindex $argv 2]
set objects {}; set mutation_count 0; set cell_creates 0; set restored {}; set fault_done 0
proc add_cell {name ref {init {}} {macro 0}} {
    global objects
    set parent [file dirname $name]
    if {$parent eq "."} {set parent {}}
    if {$parent ne "" && ![dict exists $objects $parent]} {add_cell $parent HIER}
    set props [dict create NAME $name REF_NAME $ref PARENT $parent INIT $init \
        LOC {} BEL {} IS_LOC_FIXED 0 IS_BEL_FIXED 0 DONT_TOUCH {} KEEP {} \
        LOCK_PINS {} LUTNM {} HLUTNM {} SOFT_HLUTNM {} RLOC {} U_SET {} HU_SET {} H_SET {}]
    dict set props PRIMITIVE_LEVEL [expr {$macro ? "MACRO" : ($ref eq "HIER" ? "HIER" : "LEAF")}]
    dict set objects $name [dict create type cell props $props]
}
proc add_net {name} {
    global objects
    if {![dict exists $objects $name]} {
        dict set objects $name [dict create type net props [dict create NAME $name DONT_TOUCH {} KEEP {}]]
    }
}
proc add_pin {name direction net {lower {}}} {
    global objects
    add_net $net
    if {$lower ne ""} {add_net $lower}
    dict set objects $name [dict create type pin net $net lower $lower props [dict create \
        NAME $name REF_PIN_NAME [file tail $name] DIRECTION $direction PARENT [file dirname $name] \
        IS_CLOCK [expr {[file tail $name] in {C CLK WCLK}}] CASE_VALUE {} IS_CASE_ANALYSIS false HAS_CASE_ANALYSIS 0 IS_DISABLED 0]]
}
proc arg {args flag {default {}}} {
    set i [lsearch -exact $args $flag]
    return [expr {$i < 0 ? $default : [lindex $args [expr {$i+1}]]}]
}
proc get_property {property items} {
    global objects
    set values {}
    foreach object $items {lappend values [dict get $objects $object props $property]}
    if {[llength $values] == 1} {return [lindex $values 0]}
    return $values
}
proc list_property {object} {global objects; return [dict keys [dict get $objects $object props]]}
proc get_cells {args} {
    global objects scenario
    if {$scenario eq "native_error"} {error "Injected native collection error"}
    set from [arg $args -of_objects]
    if {$from ne ""} {
        set out {}
        foreach obj $from {lappend out [dict get $objects $obj props PARENT]}
        return [lsort -unique $out]
    }
    set filter [arg $args -filter]
    if {![regexp {^NAME == "(.*)"$} $filter -> name]} {error "Unexpected get_cells $args"}
    if {[dict exists $objects $name] && [dict get $objects $name type] eq "cell"} {return [list $name]}
    return {}
}
proc expand_nets {seeds} {
    global objects
    set out $seeds
    for {set k 0} {$k < [llength $out]} {incr k} {
        set n [lindex $out $k]
        dict for {name row} $objects {
            if {[dict get $row type] ne "pin" || [dict get $row lower] eq ""} {continue}
            set upper [dict get $row net]; set lower [dict get $row lower]
            if {$n in [list $upper $lower]} {
                foreach v [list $upper $lower] {if {$v ne "" && $v ni $out} {lappend out $v}}
            }
        }
    }
    return [lsort -unique $out]
}
proc get_nets {args} {
    global objects
    set filter [arg $args -filter]
    if {$filter ne ""} {
        regexp {^NAME == "(.*)"$} $filter -> name
        if {[dict exists $objects $name] && [dict get $objects $name type] eq "net"} {return [list $name]}
        return {}
    }
    set from [arg $args -of_objects]; set result {}
    if {$from eq ""} {set from [lindex $args end]}
    foreach obj $from {
        if {[dict get $objects $obj type] eq "net"} {lappend result $obj; continue}
        set boundary [arg $args -boundary_type]
        set key [expr {$boundary eq "lower" ? "lower" : "net"}]
        set n [dict get $objects $obj $key]
        if {$n ne ""} {lappend result $n}
    }
    if {"-segments" in $args} {return [expand_nets $result]}
    return [lsort -unique $result]
}
proc get_pins {args} {
    global objects mutation_count
    set from [arg $args -of_objects]
    if {"-leaf" in $args && "runtime/zero_net" in $from} {error "Unexpected constant fanout traversal"}
    set result {}; set filter [arg $args -filter]
    dict for {name row} $objects {
        if {[dict get $row type] ne "pin"} {continue}
        set parent [dict get $row props PARENT]
        set match [expr {$parent in $from || [dict get $row net] in $from ||
            ([dict get $row lower] ne "" && [dict get $row lower] in $from)}]
        if {!$match} {continue}
        if {"-leaf" in $args && [dict get $objects $parent props PRIMITIVE_LEVEL] ne "LEAF"} {continue}
        if {$filter ne ""} {
            if {![regexp {^DIRECTION == (IN|OUT)$} $filter -> dir]} {error "Unexpected filter $filter"}
            if {[dict get $row props DIRECTION] ne $dir} {continue}
        }
        lappend result $name
    }
    # Changing collection enumeration order must not affect logical guards.
    if {$mutation_count} {return [lreverse $result]}
    return $result
}
proc get_ports {args} {return {}}
proc set_property {property value object} {
    global objects mutation_count restored scenario fault_done
    incr mutation_count
    dict set objects $object props $property $value
    if {$property eq "DONT_TOUCH" && [string tolower $value] in {true 1 yes}} {lappend restored $object}
    if {$scenario eq "restore_failure" && !$fault_done && $property eq "DONT_TOUCH" && $value eq "true"} {
        set fault_done 1; error "Injected restore failure"
    }
    if {$scenario eq "release_failure" && !$fault_done && $property eq "DONT_TOUCH" && $value eq "false"} {
        set fault_done 1; error "Injected partial release failure"
    }
}
proc create_cell {args} {
    global cell_creates mutation_count scenario
    incr mutation_count; incr cell_creates
    if {$scenario eq "create_failure" && $cell_creates == 2} {error "Injected create failure"}
    set ref [arg $args -reference]; set name [lindex $args end]
    add_cell $name $ref
    regexp {LUT([1-6])} $ref -> width
    for {set i 0} {$i < $width} {incr i} {add_pin $name/I$i IN {}}
    add_pin $name/O OUT {}
}
proc create_net {name} {global mutation_count; incr mutation_count; add_net $name}
proc disconnect_net {args} {
    global objects mutation_count
    incr mutation_count
    set p [arg $args -pinlist]; set n [arg $args -net]
    if {[dict get $objects $p net] ne $n} {error "Wrong disconnect boundary"}
    dict set objects $p net {}
}
proc connect_net {args} {
    global objects mutation_count scenario fault_done recipes
    incr mutation_count
    set p [arg $args -objects]; set n [arg $args -net]
    set macro [file dirname $p]; set bank [file dirname $macro]
    if {[expr {[file tail $p] eq {DPRA[3]}}] && [dict get $objects $bank props DONT_TOUCH] ne "false"} {error "Protected macro reconnect"}
    if {$scenario eq "connect_failure" && !$fault_done && [expr {[file tail $p] eq {DPRA[3]}}]} {
        set fault_done 1; error "Injected sideband connect failure"
    }
    dict set objects $p net $n
    if {$scenario in {changed_source changed_macro} && !$fault_done && [expr {[file tail $p] eq {DPRA[3]}}]} {
        set fault_done 1
        if {$scenario eq "changed_source"} {
            dict set objects runtime/driver_DMA/I0 net runtime/alternate
        } else {
            set leaf [lindex [dict get $recipes DMA selected] 0]
            dict set objects [file dirname $leaf] props INIT 32'hBAD
        }
    }
}
source $helper
set recipes [::frost_x3_nic_placement::recipes]
# A different synthesized source name is intentional: lookup follows consumers.
add_cell runtime/reset FDRE 1'b0
add_pin runtime/reset/Q OUT runtime/reset_net
add_cell runtime/alternate_source FDRE 1'b0
add_pin runtime/alternate_source/Q OUT runtime/alternate
add_cell runtime/zero GND
add_pin runtime/zero/G OUT runtime/zero_net
set source_cells {}
set banks {}
dict for {role recipe} $recipes {
    set c runtime/driver_$role; set n runtime/net_$role
    add_cell $c [dict get $recipe ref] [dict get $recipe init]
    regexp {LUT([1-6])} [dict get $recipe ref] -> width
    for {set i 0} {$i < $width} {incr i} {
        set sc runtime/source_${role}_$i; add_cell $sc LUT1 2'h2
        add_pin $sc/I0 IN runtime/zero_net
        add_pin $sc/O OUT runtime/source_${role}_${i}_net
        add_pin $c/I$i IN runtime/source_${role}_${i}_net
        lappend source_cells $sc
    }
    add_pin $c/O OUT $n
    add_cell runtime/retained_$role FDRE 1'b0
    add_pin runtime/retained_$role/CE IN $n
    dict for {mn ms} [dict get $recipe macros] {
        add_cell $mn [dict get $ms ref] {} 1
        set port [dict get $ms port]; set lower $mn/lower_selected
        add_pin $mn/$port IN $n $lower
        add_pin $mn/WCLK IN runtime/reset_net $mn/lower_clock
        foreach leaf [dict get $ms leaves] {
            set lc [file dirname $leaf]; add_cell $lc [expr {$role eq "DMA" ? "RAMD32" : "RAMD64E"}] 64'h0123
            add_pin $leaf IN $lower
            add_pin $lc/WCLK IN $mn/lower_clock
            add_pin $lc/O OUT $lc/data_out
        }
    }
    if {![dict size [dict get $recipe macros]]} {
        foreach leaf [dict get $recipe selected] {
            set lc [file dirname $leaf]
            add_cell $lc [expr {$role eq "L1I" ? "FDRE" : "LUT3"}] [expr {$role eq "L1I" ? "1'b0" : "8'hFE"}]
            add_pin $leaf IN $n
            add_pin $lc/[expr {$role eq "L1I" ? "D" : "I1"}] IN runtime/zero_net
            add_pin $lc/[expr {$role eq "L1I" ? "C" : "I2"}] IN runtime/reset_net
            add_pin $lc/[expr {$role eq "L1I" ? "Q" : "O"}] OUT $lc/out
        }
    }
    foreach bank [dict get $recipe banks] {
        dict set objects $bank props DONT_TOUCH true
        lappend banks $bank
    }
}
set mode auto
switch -- $scenario {
    positive - create_failure - connect_failure - release_failure - restore_failure - changed_source - changed_macro - native_error {}
    constant {dict set objects runtime/driver_L1I/I0 net runtime/zero_net}
    missing_last {dict unset objects [lindex [dict get $recipes SIDEBAND selected] end]}
    wrong_driver {dict set objects [lindex [dict get $recipes E04 selected] 0] net runtime/alternate}
    bad_init {dict set objects runtime/driver_SIDEBAND props INIT 64'h0}
    placed {dict set objects runtime/driver_DMA props LOC FRESH_SITE}
    protected {dict set objects runtime props KEEP true}
    case_zero {dict set objects runtime/driver_DMA/I0 props CASE_VALUE 0}
    case_flag_true {dict set objects runtime/driver_DMA/I0 props IS_CASE_ANALYSIS true}
    packing_zero {dict set objects runtime/driver_DMA props LUTNM 0}
    packing_false {dict set objects runtime/driver_DMA props HLUTNM false}
    lock_zero {dict set objects runtime/driver_DMA props LOCK_PINS 0}
    location_zero {dict set objects runtime/driver_DMA props LOC 0}
    split_group {
        set mn [lindex [dict keys [dict get $recipes DMA macros]] 0]
        add_cell $mn/EXTRA RAMD32 32'h0; add_pin $mn/EXTRA/WE IN $mn/lower_selected
    }
    strict_missing {set mode strict; dict unset objects [lindex [dict get $recipes E04 selected] 0]}
    default {error "Unknown case $scenario"}
}
set original $objects
set rc [catch {::frost_x3_nic_placement::post_opt $audit $mode} value options]
set f [open $audit]; set record [read $f]; close $f
if {$scenario in {positive constant}} {
    if {$rc || $value != 1 || [dict get $record status] ne "APPLIED" || $cell_creates != 4} {error "Expected four-copy success: $value"}
    if {[dict get $record moved_leaves] != 40} {error "Wrong finite move count"}
    foreach bank [lsort -unique $banks] {if {[dict get $objects $bank props DONT_TOUCH] ne "true"} {error "Bank not restored"}}
    # Native connectivity independently checks exact 40 moved leaves and each
    # retained consumer, without trusting only the helper's audit fields.
    dict for {role recipe} $recipes {
        set out runtime/driver_${role}__frost_[string tolower $role]_copy/O
        foreach leaf [dict get $recipe selected] {
            set ds [get_pins -leaf -of_objects [get_nets -segments -of_objects $leaf] -filter {DIRECTION == OUT}]
            if {$ds ne [list $out]} {error "Wrong driver $leaf"}
        }
        set ds [get_pins -leaf -of_objects [get_nets -segments -of_objects runtime/retained_$role/CE] -filter {DIRECTION == OUT}]
        if {$ds ne [list runtime/driver_$role/O]} {error "Retained driver changed"}
    }
} elseif {$scenario in {missing_last wrong_driver bad_init placed protected case_zero case_flag_true packing_zero packing_false lock_zero location_zero split_group}} {
    if {$rc || $value != 0 || $mutation_count || $objects ne $original} {error "Unsafe preflight skip: $value"}
} elseif {$scenario in {native_error strict_missing}} {
    if {!$rc || $mutation_count || $objects ne $original} {error "Native/strict preflight error escaped: $value"}
} else {
    if {!$rc || [dict get $record status] ne "FAILED_AFTER_MUTATION" || !$mutation_count} {error "Partial failure was not fatal: $value"}
    foreach bank [lsort -unique $banks] {if {[dict get $objects $bank props DONT_TOUCH] ne "true"} {error "Failed edit left bank released"}}
}
if {$scenario eq "restore_failure" && [llength $restored] != 3} {error "Did not attempt every restore"}
puts "PASS $scenario"
