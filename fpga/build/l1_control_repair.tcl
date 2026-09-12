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

# Guarded X3 L1D completion factoring and final T clock-enable distribution.
# See l1_control_repair.md for the source boundary, proof and flow contract.
namespace eval ::frost_l1_control_repair {variable cells {}}

proc ::frost_l1_control_repair::recipe {} {
    set base {subsystem/frost_processor/cpu_and_memory_subsystem/gen_cached_tier.cache_hierarchy/l1_cache}
    set r {}
    dict set r boundary W "$base/t_write_q_reg/Q"
    dict set r boundary X [format {%s/gen_tag_block.tag_array/perf_events_q[hit_under_miss]_i_2__0/O} $base]
    dict set r boundary R1 "$base/rq_id_q_reg_0_3_0_0_i_4/O"
    dict set r boundary R2 "$base/gen_tag_block.tag_array/re_in_reg_i_4__0/O"
    dict set r boundary R3 "$base/gen_tag_block.tag_array/reread_q_i_11/O"
    dict set r boundary R4 "$base/gen_tag_block.tag_array/reread_q_i_12/O"
    dict set r boundary V0 [format {%s/data_array/probe_id_q[1][3]_i_2/O} $base]
    dict set r boundary V2 [format {%s/data_array/perf_events_q[conflict_stall]_i_2__0/O} $base]
    dict set r boundary V4 "$base/data_array/reread_q_i_2__0/O"
    dict set r boundary B0 [format {%s/gen_tag_block.tag_array/gen_plain_write.ram_reg_bram_1/DOUTBDOUT[6]} $base]
    dict set r boundary B1 [format {%s/gen_tag_block.tag_array/gen_plain_write.ram_reg_bram_1/DOUTBDOUT[7]} $base]
    dict set r boundary B2 [format {%s/gen_tag_block.tag_array/perf_events_q[writeback]_i_2/O} $base]
    dict set r boundary B5 "$base/data_array/reread_q_i_3/O"
    dict set r old BLOCK [dict create cell [format {%s/gen_tag_block.tag_array/re_in_reg_i_3__0} $base] \
        width 2 init {4'h1} inputs {W X}]
    dict set r old READY [dict create cell [format {%s/gen_tag_block.tag_array/reread_q_i_5} $base] \
        width 5 init {32'hF222FFFF} inputs {BLOCK R1 R2 R3 R4}]
    dict set r old NODE9 [dict create cell [format {%s/gen_tag_block.tag_array/w_valid_q_i_2__0} $base] \
        width 6 init {64'hFFFFFFFF0000007F} inputs {B0 B1 B2 R3 BLOCK B5}]
    dict set r old VALID [dict create cell [format {%s/gen_tag_block.tag_array/w_valid_q_i_1__0} $base] \
        width 5 init {32'h01000101} inputs {V0 READY V2 NODE9 V4}]
    dict set r new C [dict create cell [format {%s/gen_tag_block.tag_array/w_valid_q_i_1__0__cofactor_C} $base] \
        width 2 init {4'h1} inputs {V0 V2}]
    dict set r new G [dict create cell [format {%s/gen_tag_block.tag_array/w_valid_q_i_1__0__cofactor_G} $base] \
        width 5 init {32'hF0FFE0EE} inputs {W R1 B5 V4 X}]
    dict set r new Y [dict create cell [format {%s/gen_tag_block.tag_array/w_valid_q_i_1__0__cofactor_Y} $base] \
        width 5 init {32'h77FF70F0} inputs {B0 B1 W B2 X}]
    dict set r new FINAL [dict create cell [format {%s/gen_tag_block.tag_array/w_valid_q_i_1__0} $base] \
        width 6 init {64'h2020AAA000000000} inputs {C R2 G Y R3 R4}]
    dict set r outputs BLOCK {}
    set leaves [dict get $r outputs BLOCK]; lappend leaves [format {%s/gen_tag_block.tag_array/re_in_reg_i_1__0/I1} $base]; dict set r outputs BLOCK $leaves
    set leaves [dict get $r outputs BLOCK]; lappend leaves [format {%s/gen_tag_block.tag_array/reread_q_i_1__0/I2} $base]; dict set r outputs BLOCK $leaves
    set leaves [dict get $r outputs BLOCK]; lappend leaves [format {%s/gen_tag_block.tag_array/reread_q_i_5/I0} $base]; dict set r outputs BLOCK $leaves
    set leaves [dict get $r outputs BLOCK]; lappend leaves [format {%s/gen_tag_block.tag_array/w_valid_q_i_2__0/I4} $base]; dict set r outputs BLOCK $leaves
    dict set r outputs READY {}
    set leaves [dict get $r outputs READY]; lappend leaves [format {%s/gen_tag_block.tag_array/probe_valid_q[2]_i_2/I2} $base]; dict set r outputs READY $leaves
    set leaves [dict get $r outputs READY]; lappend leaves [format {%s/gen_tag_block.tag_array/reread_q_i_1__0/I5} $base]; dict set r outputs READY $leaves
    set leaves [dict get $r outputs READY]; lappend leaves [format {%s/gen_tag_block.tag_array/w_valid_q_i_1__0/I1} $base]; dict set r outputs READY $leaves
    dict set r outputs NODE9 {}
    set leaves [dict get $r outputs NODE9]; lappend leaves [format {%s/gen_tag_block.tag_array/probe_valid_q[2]_i_2/I4} $base]; dict set r outputs NODE9 $leaves
    set leaves [dict get $r outputs NODE9]; lappend leaves [format {%s/gen_tag_block.tag_array/w_valid_q_i_1__0/I3} $base]; dict set r outputs NODE9 $leaves
    dict set r outputs VALID {}
    set leaves [dict get $r outputs VALID]; lappend leaves [format {%s/gen_tag_block.tag_array/ack_id_q_reg_0_15_0_3_i_1/I3} $base]; dict set r outputs VALID $leaves
    set leaves [dict get $r outputs VALID]; lappend leaves [format {%s/gen_tag_block.tag_array/ack_wr_q[4]_i_1__0/I0} $base]; dict set r outputs VALID $leaves
    set leaves [dict get $r outputs VALID]; lappend leaves [format {%s/gen_tag_block.tag_array/perf_events_q[hit]_i_1__0/I0} $base]; dict set r outputs VALID $leaves
    set leaves [dict get $r outputs VALID]; lappend leaves [format {%s/gen_tag_block.tag_array/perf_events_q[hit_under_miss]_i_1__1/I0} $base]; dict set r outputs VALID $leaves
    set leaves [dict get $r outputs VALID]; lappend leaves [format {%s/gen_tag_block.tag_array/perf_events_q[miss]_i_1__0/I2} $base]; dict set r outputs VALID $leaves
    set leaves [dict get $r outputs VALID]; lappend leaves [format {%s/gen_tag_block.tag_array/perf_events_q[writeback]_i_1__0/I3} $base]; dict set r outputs VALID $leaves
    set leaves [dict get $r outputs VALID]; lappend leaves [format {%s/gen_tag_block.tag_array/re_in_reg_i_1__0/I3} $base]; dict set r outputs VALID $leaves
    set leaves [dict get $r outputs VALID]; lappend leaves [format {%s/gen_tag_block.tag_array/rp_victim_q[0]_i_1__0/I1} $base]; dict set r outputs VALID $leaves
    set leaves [dict get $r outputs VALID]; lappend leaves [format {%s/gen_tag_block.tag_array/sk_valid_q_i_1__0/I2} $base]; dict set r outputs VALID $leaves
    set leaves [dict get $r outputs VALID]; lappend leaves [format {%s/gen_tag_block.tag_array/t_idx_match_q[0]_i_1__0/I2} $base]; dict set r outputs VALID $leaves
    set leaves [dict get $r outputs VALID]; lappend leaves [format {%s/gen_tag_block.tag_array/t_idx_match_q[1]_i_1__0/I2} $base]; dict set r outputs VALID $leaves
    set leaves [dict get $r outputs VALID]; lappend leaves [format {%s/gen_tag_block.tag_array/t_idx_match_q[2]_i_1__0/I2} $base]; dict set r outputs VALID $leaves
    set leaves [dict get $r outputs VALID]; lappend leaves [format {%s/gen_tag_block.tag_array/t_idx_match_q[3]_i_1__0/I2} $base]; dict set r outputs VALID $leaves
    set leaves [dict get $r outputs VALID]; lappend leaves [format {%s/gen_tag_block.tag_array/t_line_match_q[0]_i_1__0/I3} $base]; dict set r outputs VALID $leaves
    set leaves [dict get $r outputs VALID]; lappend leaves [format {%s/gen_tag_block.tag_array/t_line_match_q[1]_i_1__0/I3} $base]; dict set r outputs VALID $leaves
    set leaves [dict get $r outputs VALID]; lappend leaves [format {%s/gen_tag_block.tag_array/t_line_match_q[2]_i_1__0/I3} $base]; dict set r outputs VALID $leaves
    set leaves [dict get $r outputs VALID]; lappend leaves [format {%s/gen_tag_block.tag_array/t_line_match_q[3]_i_1__0/I3} $base]; dict set r outputs VALID $leaves
    set leaves [dict get $r outputs VALID]; lappend leaves [format {%s/gen_tag_block.tag_array/t_valid_q_i_1__0/I1} $base]; dict set r outputs VALID $leaves
    set leaves [dict get $r outputs VALID]; lappend leaves [format {%s/gen_tag_block.tag_array/t_wb_match_q[0]_i_1__0/I2} $base]; dict set r outputs VALID $leaves
    set leaves [dict get $r outputs VALID]; lappend leaves [format {%s/gen_tag_block.tag_array/t_wb_match_q[1]_i_1__0/I2} $base]; dict set r outputs VALID $leaves
    set leaves [dict get $r outputs VALID]; lappend leaves [format {%s/gen_tag_block.tag_array/t_wb_match_q[1]_i_2/I2} $base]; dict set r outputs VALID $leaves
    set leaves [dict get $r outputs VALID]; lappend leaves [format {%s/gen_tag_block.tag_array/t_wdata_q[255]_i_1__0/I1} $base]; dict set r outputs VALID $leaves
    set leaves [dict get $r outputs VALID]; lappend leaves [format {%s/gen_tag_block.tag_array/tag_response_valid_q[0]_i_1/I2} $base]; dict set r outputs VALID $leaves
    set leaves [dict get $r outputs VALID]; lappend leaves [format {%s/gen_tag_block.tag_array/w_op_q[0]_i_1__0/I1} $base]; dict set r outputs VALID $leaves
    set leaves [dict get $r outputs VALID]; lappend leaves [format {%s/gen_tag_block.tag_array/w_op_q[1]_i_1__0/I1} $base]; dict set r outputs VALID $leaves
    set leaves [dict get $r outputs VALID]; lappend leaves [format {%s/gen_tag_block.tag_array/w_op_q[2]_i_1__0/I1} $base]; dict set r outputs VALID $leaves
    set leaves [dict get $r outputs VALID]; lappend leaves [format {%s/gen_tag_block.tag_array/w_wdata_q[255]_i_1__0/I0} $base]; dict set r outputs VALID $leaves
    set leaves [dict get $r outputs VALID]; lappend leaves [format {%s/w_valid_q_reg/D} $base]; dict set r outputs VALID $leaves
    set partitions {}
    set leaves {}
    foreach bit {6 7 18 23 24 26 27 30 31} {lappend leaves [format {%s/t_addr_q_reg[%d]/CE} $base $bit]}
    foreach bit {194 195 196 197 198 199 200 201 202 203 204 205 206 207 208 209 212 213 215 216 217 219 220 221 227 228 229 230 231 243 244 245 246 247 252 253 254 255} {lappend leaves [format {%s/t_wdata_q_reg[%d]/CE} $base $bit]}
    foreach bit {27} {lappend leaves [format {%s/t_wstrb_q_reg[%d]/CE} $base $bit]}
    lappend partitions [lsort $leaves]
    set leaves {}
    foreach bit {210 211 214 218 226 232 233 234 235 238 239 240 241 242 248 249} {lappend leaves [format {%s/t_wdata_q_reg[%d]/CE} $base $bit]}
    foreach bit {1 3 4 5 6 7 8 9 10 11 12 13 14 15 16 18 19 20 21 22 23 28 29 30} {lappend leaves [format {%s/t_wstrb_q_reg[%d]/CE} $base $bit]}
    lappend leaves [format {%s/t_probe_q_reg/CE} $base]
    lappend leaves [format {%s/t_write_q_reg/CE} $base]
    lappend partitions [lsort $leaves]
    set leaves {}
    foreach bit {5 8 9 10 11 12 13 14 15 16 19 21 22 25 28 29} {lappend leaves [format {%s/t_addr_q_reg[%d]/CE} $base $bit]}
    foreach bit {0 1} {lappend leaves [format {%s/t_id_q_reg[%d]/CE} $base $bit]}
    foreach bit {192 193 222 223 224 225 236 237 250 251} {lappend leaves [format {%s/t_wdata_q_reg[%d]/CE} $base $bit]}
    foreach bit {0 2 17 24 25 26} {lappend leaves [format {%s/t_wstrb_q_reg[%d]/CE} $base $bit]}
    lappend leaves [format {%s/t_probe_inval_q_reg/CE} $base]
    lappend partitions [lsort $leaves]
    set leaves {}
    foreach bit {17 20} {lappend leaves [format {%s/t_addr_q_reg[%d]/CE} $base $bit]}
    foreach bit {31} {lappend leaves [format {%s/t_wstrb_q_reg[%d]/CE} $base $bit]}
    lappend partitions [lsort $leaves]
    dict set r partitions $partitions
    dict set r t_cell [format {%s/gen_tag_block.tag_array/t_wdata_q[255]_i_1__0} $base]
    dict set r t_inputs {}
    dict lappend r t_inputs [format {%s/t_wdata_q[255]_i_3__0/O} $base]
    dict lappend r t_inputs [format {%s/gen_tag_block.tag_array/w_valid_q_i_1__0/O} $base]
    dict lappend r t_inputs [format {%s/t_valid_q_reg/Q} $base]
    dict lappend r t_inputs @current_reset_driver
    return $r
}
# A mismatch is skippable only before the first edit. Unexpected API failures
# and every failure after mutation remain fatal in both modes.
proc ::frost_l1_control_repair::mismatch {message} {
    return -code error -errorcode {FROST L1_CONTROL MISMATCH} $message
}
proc ::frost_l1_control_repair::one {objects label} {
    if {[llength $objects] != 1} {mismatch "Expected one $label, found [llength $objects]"}
    return [lindex $objects 0]
}
proc ::frost_l1_control_repair::names {objects} {
    if {![llength $objects]} {return {}}
    return [lsort -unique [get_property NAME $objects]]
}
proc ::frost_l1_control_repair::named {command name} {
    set escaped [string map [list \\ \\\\ \" \\\"] $name]
    return [$command -quiet -hierarchical -filter [format {NAME == "%s"} $escaped]]
}
proc ::frost_l1_control_repair::cell {name} {
    variable cells
    if {![dict exists $cells $name]} {dict set cells $name [one [named get_cells $name] "cell $name"]}
    return [dict get $cells $name]
}
proc ::frost_l1_control_repair::pin {name} {
    set c [cell [file dirname $name]]
    # REF_PIN_NAME can contain brackets; literal equality avoids glob lookup.
    set escaped [string map [list \\ \\\\ \" \\\"] [file tail $name]]
    return [one [get_pins -quiet -of_objects $c -filter [format {REF_PIN_NAME == "%s"} $escaped]] "pin $name"]
}
proc ::frost_l1_control_repair::property {object key} {
    if {$key ni [list_property $object]} {return {}}
    return [get_property $key $object]
}
proc ::frost_l1_control_repair::integer_init {value} {
    if {![regexp -nocase {^[0-9]+'([hb])([0-9a-f]+)$} $value -> radix digits]} {
        mismatch "Unsupported INIT representation: $value"
    }
    if {$radix eq "b"} {return [expr "0b$digits"]}
    return [expr "0x$digits"]
}
proc ::frost_l1_control_repair::driver {p} {
    set net [one [get_nets -quiet -of_objects $p] "immediate input net"]
    set direct [get_pins -quiet -of_objects $net -filter {DIRECTION == OUT}]
    if {[llength $direct] == 1} {
        set owner [one [get_cells -quiet -of_objects $direct] "direct driver owner"]
        if {[get_property IS_PRIMITIVE $owner]} {return [get_property NAME $direct]}
    }
    # Only find the driver. Never enumerate clock or reset consumers.
    set nets [get_nets -quiet -segments -of_objects $p]
    return [get_property NAME [one [get_pins -quiet -leaf -of_objects $nets -filter {DIRECTION == OUT}] "electrical driver"]]
}
proc ::frost_l1_control_repair::loads {output} {
    set p [pin $output]
    set nets [get_nets -quiet -segments -of_objects $p]
    if {![llength $nets] || [llength [get_ports -quiet -of_objects $nets]]} {mismatch "Disconnected or external output: $output"}
    if {[names [get_pins -quiet -leaf -of_objects $nets -filter {DIRECTION == OUT}]] ne [list $output]} {mismatch "Ambiguous output driver: $output"}
    set leaves [get_pins -quiet -leaf -of_objects $nets -filter {DIRECTION == IN}]
    if {[llength $leaves] > 512} {mismatch "Unexpected local output fanout: $output"}
    return [names $leaves]
}
proc ::frost_l1_control_repair::inputs {name} {
    set c [cell $name]
    set result {}
    foreach p [get_pins -quiet -of_objects $c -filter {DIRECTION == IN}] {
        dict set result [get_property REF_PIN_NAME $p] [driver $p]
    }
    return $result
}
proc ::frost_l1_control_repair::configuration {name} {
    set c [cell $name]; set result {}
    foreach key {REF_NAME INIT IS_C_INVERTED IS_CE_INVERTED IS_D_INVERTED IS_R_INVERTED IS_S_INVERTED DONT_TOUCH KEEP} {
        dict set result $key [property $c $key]
    }
    return $result
}
proc ::frost_l1_control_repair::check_editable {name} {
    set c [cell $name]
    foreach key {DONT_TOUCH KEEP IS_LOC_FIXED IS_BEL_FIXED LOCK_PINS RLOC HU_SET U_SET} {
        if {[property $c $key] ni {{} 0 false FALSE}} {mismatch "Protected or packed cell: $name ($key)"}
    }
    if {[property $c LOC] ne {} || [property $c BEL] ne {}} {mismatch "L1 repair requires an unplaced optimized netlist: $name"}
    # Resolve real PARENT properties; no string-derived ownership assumption.
    set seen {}
    while {[set parent [property $c PARENT]] ne {}} {
        if {$parent in $seen || [llength $seen] >= 32} {mismatch "Invalid ancestor chain: $name"}
        lappend seen $parent; set c [cell $parent]
        if {[property $c DONT_TOUCH] ni {{} 0 false FALSE}} {mismatch "Protected ancestor: $parent"}
    }
}
proc ::frost_l1_control_repair::check_net {p} {
    foreach net [get_nets -quiet -segments -of_objects $p] {
        foreach key {DONT_TOUCH KEEP} {
            if {[property $net $key] ni {{} 0 false FALSE}} {mismatch "Protected edited net: [get_property NAME $net]"}
        }
    }
}
proc ::frost_l1_control_repair::read_node {spec symbol_pins} {
    set name [dict get $spec cell]; set c [cell $name]
    set width [dict get $spec width]
    if {[get_property REF_NAME $c] ne "LUT$width"} {mismatch "Changed LUT width: $name"}
    set actual [inputs $name]; set expected {}; set ordered {}
    set i 0
    foreach symbol [dict get $spec inputs] {
        set source [dict get $symbol_pins $symbol]
        dict set expected I$i $source
        if {![dict exists $actual I$i] || [dict get $actual I$i] ne $source} {mismatch "Changed ordered source: $name/I$i"}
        lappend ordered $symbol; incr i
    }
    if {[lsort [dict keys $actual]] ne [lsort [dict keys $expected]] ||
        [names [get_pins -quiet -of_objects $c -filter {DIRECTION == OUT}]] ne [list "$name/O"]} {mismatch "Changed LUT ports: $name"}
    set init [get_property INIT $c]
    if {[integer_init $init] != [integer_init [dict get $spec init]]} {mismatch "Changed LUT INIT: $name"}
    return [dict replace $spec init $init inputs $ordered]
}
# Evaluate the actual read-back node INITs and ordered source identities. This
# proof is over 13 independent binary boundary values, not a CPU state proof.
proc ::frost_l1_control_repair::evaluate {nodes order values} {
    foreach role $order {
        set node [dict get $nodes $role]; set index 0; set bit 0
        foreach source [dict get $node inputs] {
            set index [expr {$index | ([dict get $values $source] << $bit)}]; incr bit
        }
        dict set values $role [expr {([integer_init [dict get $node init]] >> $index) & 1}]
    }
    return [dict get $values [lindex $order end]]
}
proc ::frost_l1_control_repair::prove {actual proposed boundary} {
    if {[dict size $boundary] != 13 || [llength [lsort -unique [dict values $boundary]]] != 13} {mismatch "Changed independent boundary"}
    set ones 0
    for {set assignment 0} {$assignment < 8192} {incr assignment} {
        set values {}; set bit 0
        foreach symbol [dict keys $boundary] {dict set values $symbol [expr {($assignment >> $bit) & 1}]; incr bit}
        set old [evaluate $actual {BLOCK READY NODE9 VALID} $values]
        set new [evaluate $proposed {C G Y FINAL} $values]
        if {$old != $new} {mismatch "Completion factor counterexample: assignment=$assignment"}
        incr ones $old
    }
    return [dict create assignments 8192 ones $ones mismatches 0]
}
proc ::frost_l1_control_repair::preflight {r} {
    set symbols [dict get $r boundary]
    dict for {role spec} [dict get $r old] {dict set symbols $role "[dict get $spec cell]/O"}
    set actual {}; set snapshots {}; set consumer_inputs {}; set consumers {}
    dict for {role spec} [dict get $r old] {
        dict set actual $role [read_node $spec $symbols]
        set name [dict get $spec cell]; check_editable $name
        if {[loads "$name/O"] ne [lsort [dict get $r outputs $role]]} {mismatch "Changed $role output ownership"}
        foreach leaf [dict get $r outputs $role] {lappend consumers [file dirname $leaf]}
    }
    set proof [prove $actual [dict get $r new] [dict get $r boundary]]
    set t [dict get $r t_cell]; check_editable $t
    set t_inputs [inputs $t]
    if {[get_property REF_NAME [cell $t]] ne "LUT4" || [integer_init [get_property INIT [cell $t]]] != 0x0045 ||
        [lsort [dict keys $t_inputs]] ne {I0 I1 I2 I3}} {mismatch "Changed final T function"}
    set i 0
    foreach expected [dict get $r t_inputs] {
        if {$i < 3 && [dict get $t_inputs I$i] ne $expected} {mismatch "Changed final T source I$i"}; incr i
    }
    set all {}; set counts {}
    foreach group [dict get $r partitions] {set all [concat $all $group]; lappend counts [llength $group]}
    if {$counts ne {48 42 35 3} || [llength [lsort -unique $all]] != 128 || [loads "$t/O"] ne [lsort $all]} {mismatch "Changed full T128 partition"}
    foreach leaf $all {
        set owner [file dirname $leaf]; set c [cell $owner]
        if {[get_property REF_NAME $c] ni {FDRE FDSE} || [file tail $leaf] ne "CE"} {mismatch "Unexpected T consumer: $leaf"}
        check_editable $owner; lappend consumers $owner
    }
    set valid [dict get $r old VALID cell]
    foreach source [concat [dict values [dict get $r boundary]] [dict values $t_inputs]] {
        dict set snapshots [file dirname $source] [configuration [file dirname $source]]
    }
    foreach name [lsort -unique $consumers] {
        if {$name eq $valid} {continue}
        dict set snapshots $name [configuration $name]
        dict set consumer_inputs $name [inputs $name]
    }
    foreach spec [dict values [dict get $r new]] {
        set name [dict get $spec cell]
        if {$name ne $valid && ([llength [named get_cells $name]] || [llength [named get_nets "${name}_out"]])} {mismatch "Existing cofactor object: $name"}
    }
    for {set i 1} {$i <= 3} {incr i} {
        set name "${t}__frost_ce_copy_$i"
        if {[llength [named get_cells $name]] || [llength [named get_nets "${name}_out"]]} {mismatch "Existing T copy: $name"}
    }
    foreach name [list $valid $t] {
        foreach p [get_pins -quiet -of_objects [cell $name]] {check_net $p}
    }
    foreach leaf $all {check_net [pin $leaf]}
    set ordered_t {}; foreach port {I0 I1 I2 I3} {lappend ordered_t [dict get $t_inputs $port]}
    return [dict create proof $proof symbols $symbols snapshots $snapshots consumer_inputs $consumer_inputs t_inputs $ordered_t]
}
proc ::frost_l1_control_repair::attach {source destination} {
    set net [one [get_nets -quiet -of_objects [pin $source]] "source immediate net"]
    connect_net -hierarchical -net $net -objects [pin $destination]
}
proc ::frost_l1_control_repair::make_lut {spec symbols {output_net {}}} {
    set name [dict get $spec cell]
    create_cell -reference LUT[dict get $spec width] $name
    set c [cell $name]; set_property INIT [dict get $spec init] $c
    set i 0
    foreach symbol [dict get $spec inputs] {attach [dict get $symbols $symbol] "$name/I$i"; incr i}
    if {$output_net eq {}} {
        create_net "${name}_out"
        set output_net [one [named get_nets "${name}_out"] "new output net"]
    }
    connect_net -hierarchical -net $output_net -objects [pin "$name/O"]
    return "$name/O"
}
proc ::frost_l1_control_repair::edit_and_check {r state} {
    set symbols [dict get $state symbols]; set valid [dict get $r old VALID cell]
    foreach role {C G Y} {
        dict set symbols $role [make_lut [dict get $r new $role] $symbols]
    }
    set old [cell $valid]
    set output [get_property NAME [one [get_nets -quiet -of_objects [pin "$valid/O"]] "retained VALID net"]]
    foreach p [get_pins -quiet -of_objects $old] {
        disconnect_net -net [one [get_nets -quiet -of_objects $p] "old VALID net"] -pinlist $p
    }
    remove_cell $old
    variable cells; dict unset cells $valid
    make_lut [dict get $r new FINAL] $symbols [one [named get_nets $output] "retained VALID net"]
    set expected_inputs [dict get $state consumer_inputs]
    set t [dict get $r t_cell]; set i 0; set t_drivers [list $t]
    foreach group [lrange [dict get $r partitions] 1 end] {
        incr i; set name "${t}__frost_ce_copy_$i"
        set source_symbols {}; set input_symbols {}
        set j 0
        foreach source [dict get $state t_inputs] {dict set source_symbols P$j $source; lappend input_symbols P$j; incr j}
        make_lut [dict create cell $name width 4 init {16'h0045} inputs $input_symbols] $source_symbols
        lappend t_drivers $name
        foreach leaf $group {
            set p [pin $leaf]
            disconnect_net -net [one [get_nets -quiet -of_objects $p] "old CE net"] -pinlist $p
            attach "$name/O" $leaf
            dict set expected_inputs [file dirname $leaf] CE "$name/O"
        }
    }
    dict for {name expected} [dict get $state snapshots] {
        if {$name eq $valid} {continue}
        if {[configuration $name] ne $expected} {error "L1 repair changed source/consumer configuration: $name"}
    }
    dict for {name expected} $expected_inputs {
        set actual [inputs $name]
        if {[lsort [dict keys $actual]] ne [lsort [dict keys $expected]]} {error "Changed preserved consumer ports: $name"}
        dict for {port source} $expected {
            if {[dict get $actual $port] ne $source} {error "Changed preserved consumer input: $name/$port"}
        }
    }
    dict for {role spec} [dict get $r new] {read_node $spec $symbols}
    foreach role {BLOCK READY NODE9} {read_node [dict get $r old $role] $symbols}
    foreach role {C G Y} port {I0 I2 I3} {
        set name [dict get $r new $role cell]; check_editable $name
        if {[loads "$name/O"] ne [list "$valid/$port"]} {error "Unexpected new cofactor output owner: $role"}
    }
    check_editable $valid
    set outputs {}
    foreach role {BLOCK READY NODE9 VALID} {
        set expected [dict get $r outputs $role]
        if {$role in {READY NODE9}} {
            set old_port [expr {$role eq "READY" ? "I1" : "I3"}]
            set expected [lsearch -all -inline -not -exact $expected "$valid/$old_port"]
        }
        if {$role eq "VALID"} {
            foreach name [lrange $t_drivers 1 end] {lappend expected "$name/I1"}
        }
        set actual [loads "[dict get $r old $role cell]/O"]
        if {$actual ne [lsort $expected]} {error "Changed retained $role output owners"}
        dict set outputs $role $actual
    }
    foreach name $t_drivers group [dict get $r partitions] {
        check_editable $name
        set actual [inputs $name]; set j 0
        foreach source [dict get $state t_inputs] {
            if {[dict get $actual I$j] ne $source} {error "Changed T copy input"}; incr j
        }
        if {[get_property REF_NAME [cell $name]] ne "LUT4" || [integer_init [get_property INIT [cell $name]]] != 0x0045 || [loads "$name/O"] ne $group} {error "Changed final T partition/function"}
    }
    return [dict create proof [dict get $state proof] t_counts {48 42 35 3} t_leaves 128 valid_leaves 31 outputs $outputs]
}
proc ::frost_l1_control_repair::write_audit {path value} {
    set f [open $path w]; puts $f $value; close $f
}
proc ::frost_l1_control_repair::apply {audit_file {mode auto}} {
    variable cells; set cells {}
    if {$mode ni {auto strict}} {error "L1 control repair mode must be auto or strict"}
    write_audit $audit_file [dict create status PREFLIGHT]
    set r [recipe]
    set code [catch {preflight $r} state options]
    if {$code} {
        write_audit $audit_file [dict create status FAILED_BEFORE_EDIT reason $state]
        if {$mode eq "auto" && [dict exists $options -errorcode] && [dict get $options -errorcode] eq {FROST L1_CONTROL MISMATCH}} {
            write_audit $audit_file [dict create status SKIPPED_BEFORE_EDIT reason $state]
            puts "FROST_L1_CONTROL_REPAIR=SKIPPED ($state)"; return 0
        }
        return -options $options $state
    }
    write_audit $audit_file [dict create status EDIT_STARTED before $state]
    if {[catch {edit_and_check $r $state} result options]} {
        write_audit $audit_file [dict create status FAILED_AFTER_EDIT reason $result before $state]
        return -options $options $result
    }
    write_audit $audit_file [dict merge [dict create status APPLIED before $state] $result]
    puts "FROST_L1_CONTROL_REPAIR=APPLIED PROOF=8192 T_COUNTS=48,42,35,3 T_LEAVES=128 VALID_LEAVES=31"
    return 1
}
