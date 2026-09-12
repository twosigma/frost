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

# Fresh-netlist X3 distribution copies. No checkpoint, timing or placement input.
namespace eval ::frost_x3_nic_placement {
    variable cells {}
    variable pins {}
    variable protections {}
    variable released {}
}
proc ::frost_x3_nic_placement::mismatch {message} {
    return -code error -errorcode {FROST X3_COPY MISMATCH} $message
}
proc ::frost_x3_nic_placement::one {objects label} {
    if {[llength $objects] != 1} {mismatch "Expected one $label, found [llength $objects]"}
    return [lindex $objects 0]
}
proc ::frost_x3_nic_placement::names {objects} {
    if {![llength $objects]} {return {}}
    return [lsort -unique [get_property NAME $objects]]
}
proc ::frost_x3_nic_placement::find {command name} {
    set escaped [string map [list \\ \\\\ \" \\\"] $name]
    return [$command -quiet -hierarchical -filter [format {NAME == "%s"} $escaped]]
}
proc ::frost_x3_nic_placement::cell {name} {
    variable cells
    if {![dict exists $cells $name]} {
        set c [one [find get_cells $name] "cell $name"]
        if {[get_property NAME $c] ne $name} {mismatch "Cell selector changed identity"}
        dict set cells $name $c
    }
    return [dict get $cells $name]
}
proc ::frost_x3_nic_placement::pin {name} {
    variable pins
    if {![dict exists $pins $name]} {
        set c [cell [file dirname $name]]
        set matches {}
        foreach p [lsort [get_pins -of_objects $c]] {
            if {[get_property NAME $p] eq $name} {lappend matches $p}
        }
        dict set pins $name [one $matches "pin $name"]
    }
    return [dict get $pins $name]
}
proc ::frost_x3_nic_placement::prop {object key} {
    if {$key ni [list_property $object]} {return @absent}
    return [get_property $key $object]
}
proc ::frost_x3_nic_placement::inactive {value} {
    return [expr {[string tolower $value] in {{} 0 false no @absent}}]
}
# Placement and packing values are names, not booleans. A name "0" is active.
proc ::frost_x3_nic_placement::string_unset {object key} {
    return [expr {$key ni [list_property $object] || [get_property $key $object] eq ""}]
}
proc ::frost_x3_nic_placement::config {c} {
    set result [dict create REF_NAME [get_property REF_NAME $c]]
    foreach key [lsort [list_property $c]] {
        if {[regexp {^(INIT($|_)|IS_.*_INVERTED$|READ_WIDTH|WRITE_WIDTH|WRITE_MODE|DO[AB]_REG$|RAM_MODE$|EN_ECC_)} $key]} {
            dict set result $key [get_property $key $c]
        }
    }
    return $result
}
proc ::frost_x3_nic_placement::nets {p} {
    set ns [get_nets -segments -of_objects $p]
    if {![llength $ns] || [llength $ns] > 128} {mismatch "Disconnected or excessive net aliases: $p"}
    return $ns
}
proc ::frost_x3_nic_placement::driver {p} {
    return [one [get_pins -leaf -of_objects [nets $p] -filter {DIRECTION == OUT}] "driver of $p"]
}
proc ::frost_x3_nic_placement::source {p} {
    # Check immediate constant drivers first; never walk a global constant net.
    set direct [get_nets -of_objects $p]
    if {[llength $direct]} {
        set ds [get_pins -of_objects $direct -filter {DIRECTION == OUT}]
        if {[llength $ds] == 1} {
            set owner [one [get_cells -of_objects $ds] "direct source owner"]
            set ref [get_property REF_NAME $owner]
            if {$ref in {GND VCC}} {return @$ref}
        }
    }
    return [get_property NAME [driver $p]]
}
proc ::frost_x3_nic_placement::leaves {p} {
    set ns [nets $p]
    if {[get_property NAME [driver $p]] ne [get_property NAME $p] ||
        [llength [get_ports -quiet -of_objects $ns]]} {mismatch "Nonlocal or multiply driven output $p"}
    set ps [get_pins -leaf -of_objects $ns -filter {DIRECTION == IN}]
    set result [names $ps]
    if {[llength $result] != [llength $ps] || [llength $ps] > 4096} {mismatch "Output fanout exceeds finite copy scope"}
    return $result
}
proc ::frost_x3_nic_placement::signature {c} {
    set ref [get_property REF_NAME $c]
    if {![regexp {^LUT([1-6])$} $ref -> width]} {mismatch "Expected LUT1..6 source"}
    set result [dict create ref $ref init [get_property INIT $c] inputs {}]
    set expected [list [get_property NAME $c]/O]
    for {set i 0} {$i < $width} {incr i} {
        set p [pin [get_property NAME $c]/I$i]
        if {[get_property DIRECTION $p] ne "IN"} {mismatch "Changed LUT input direction"}
        dict set result inputs I$i [source $p]
        lappend expected [get_property NAME $p]
    }
    if {[names [get_pins -of_objects $c]] ne [lsort $expected] ||
        [get_property DIRECTION [pin [get_property NAME $c]/O]] ne "OUT"} {mismatch "Changed LUT interface"}
    return $result
}
proc ::frost_x3_nic_placement::protection {c allowed_banks} {
    variable protections
    set depth 0
    while {1} {
        if {[incr depth] > 24} {mismatch "Excessive hierarchy depth"}
        set name [get_property NAME $c]
        foreach key {DONT_TOUCH KEEP} {
            set value [prop $c $key]
            if {![inactive $value] && !($key eq "DONT_TOUCH" && $name in $allowed_banks &&
                [string tolower $value] in {1 true yes})} {mismatch "Protected edited hierarchy $name/$key"}
            dict set protections $name $key $value
        }
        set parent [prop $c PARENT]
        if {$parent in {{} @absent}} {break}
        set c [cell $parent]
    }
}
proc ::frost_x3_nic_placement::net_protection {ns} {
    foreach n $ns {
        foreach key {DONT_TOUCH KEEP} {
            if {![inactive [prop $n $key]]} {mismatch "Protected edited net $n/$key"}
        }
    }
}
proc ::frost_x3_nic_placement::controls {p} {
    set result {}
    foreach key [lsort [list_property $p]] {
        if {[regexp -nocase {CASE|DISABLE.*TIMING|TIMING.*DISABLE} $key]} {
            set v [get_property $key $p]
            # Literal CASE_VALUE=0 constrains the pin. Boolean flags such as
            # IS_CASE_ANALYSIS=false or HAS_CASE_ANALYSIS=0 do not.
            if {[regexp -nocase {CASE} $key] && ![regexp -nocase {^(IS_|HAS_)} $key]} {
                set active [expr {$v ne ""}]
            } else {
                set active [expr {[string tolower $v] ni {{} 0 false no}}]
            }
            if {$active} {mismatch "Active pin control $p/$key"}
            dict set result $key $v
        }
    }
    return $result
}
proc ::frost_x3_nic_placement::consumer {c macro {moved_port {}}} {
    if {$macro && $moved_port eq ""} {mismatch "Macro snapshot requires its declared moved port"}
    set result [dict create config [config $c] pins {}]
    foreach p [lsort [get_pins -of_objects $c]] {
        set key [get_property REF_PIN_NAME $p]
        set direction [get_property DIRECTION $p]
        set direct [get_nets -of_objects $p]
        if {$macro} {set direct [get_nets -boundary_type upper -of_objects $p]}
        set row [dict create direction $direction nets [names $direct] controls [controls $p]]
        # Unchanged macro inputs retain their exact local upper net, including
        # an unused disconnected port. Do not walk a potentially global alias
        # set to infer their source. Internal direct nets are checked separately.
        # The moved port still requires its exact singleton electrical driver.
        # No electrical clock fanout traversal or source-wide load census.
        if {$direction eq "IN" && $key ni {C CLK WCLK} && [prop $p IS_CLOCK] ni {1 true} &&
            (!$macro || $key eq $moved_port)} {
            dict set row source [source $p]
        }
        dict set result pins $key $row
    }
    return $result
}
proc ::frost_x3_nic_placement::macro_snapshot {name port expected_ref expected_leaves} {
    set c [cell $name]
    if {[get_property REF_NAME $c] ne $expected_ref || [prop $c PRIMITIVE_LEVEL] ne "MACRO"} {
        mismatch "Unsupported native memory macro $name"
    }
    set p [pin $name/$port]
    set lower [one [get_nets -boundary_type lower -of_objects $p] "macro lower net"]
    set direct [names [get_pins -of_objects $lower]]
    if {$direct ne [lsort [concat [list $name/$port] $expected_leaves]]} {mismatch "Split or changed whole macro-port group $name/$port"}
    set internals {}
    foreach leaf $expected_leaves {
        set lc [cell [file dirname $leaf]]
        if {[prop $lc PARENT] ne $name || [get_property REF_NAME $lc] ni {RAMD32 RAMS32 RAMD64E}} {
            mismatch "Changed macro leaf owner/type $leaf"
        }
        set record [dict create config [config $lc] pins {}]
        foreach lp [lsort [get_pins -of_objects $lc]] {
            dict set record pins [get_property REF_PIN_NAME $lp] [dict create \
                direction [get_property DIRECTION $lp] nets [names [get_nets -of_objects $lp]] \
                controls [controls $lp]]
        }
        dict set internals [get_property NAME $lc] $record
    }
    return [dict create lower [get_property NAME $lower] direct $direct internals $internals]
}
proc ::frost_x3_nic_placement::recipes {} {
    set root subsystem/frost_processor/cpu_and_memory_subsystem
    set cache $root/gen_cached_tier.cache_hierarchy
    set imem $root/instruction_memory
    set dma $cache/dma_sequencer/wdata_q_reg_0_3_154_167
    set dma_leaves {}
    foreach letter {A B C D E F G H} {
        foreach suffix {{} _D1} {lappend dma_leaves $dma/RAM${letter}${suffix}/WE}
    }
    set l1i {}
    foreach bit {139 149 170 211 228 244 248} {
        lappend l1i [format {%s/l1i_cache/mshr_data_q_reg[1][%d]/CE} $cache $bit]
    }
    set e04 [list $imem/o_instr_buffer\[30\]_i_2/I0]
    set side {}; set macros {}; set banks {}
    foreach {bank chunk} {
        u_even_is_compressed_lo_bank memory_reg_3840_4095_0_0
        u_even_is_compressed_hi_bank memory_reg_5888_6143_0_0
        u_even_is_compressed_hi_bank memory_reg_5632_5887_0_0
        u_even_even_local_pair_valid_bank memory_reg_6400_6655_0_0
    } {
        set name $imem/$bank/$chunk; set group {}
        foreach letter {A B C D} {lappend group $name/DP.$letter/RADR3}
        set side [concat $side $group]
        dict set macros $name [dict create port {DPRA[3]} ref RAM256X1D leaves $group]
        lappend banks $imem/$bank
    }
    return [dict create \
        DMA [dict create ref LUT2 init 4'h1 selected $dma_leaves \
            macros [dict create $dma [dict create port WE ref RAM32M16 leaves $dma_leaves]] banks {}] \
        L1I [dict create ref LUT6 init 64'h4444445444444444 selected $l1i macros {} banks {}] \
        E04 [dict create ref LUT5 init 32'hAAAACFC0 selected $e04 macros {} banks {}] \
        SIDEBAND [dict create ref LUT6 init 64'hAFCCAFFFA0CCA000 selected $side macros $macros banks [lsort -unique $banks]]]
}
proc ::frost_x3_nic_placement::prepare {} {
    variable cells {}; variable pins {}; variable protections {}; variable released {}
    set result {}; set seen {}
    dict for {role recipe} [recipes] {
        set selected [lsort [dict get $recipe selected]]
        set first [pin [lindex $selected 0]]
        set out [driver $first]
        set c [one [get_cells -of_objects $out] "selected driver owner"]
        set name [get_property NAME $c]; set sig [signature $c]
        if {[get_property REF_PIN_NAME $out] ne "O" || [dict get $sig ref] ne [dict get $recipe ref] ||
            ![string equal -nocase [dict get $sig init] [dict get $recipe init]] || $name in $seen} {
            mismatch "Unsupported or shared $role LUT function"
        }
        lappend seen $name
        protection $c {}
        foreach key {IS_LOC_FIXED IS_BEL_FIXED} {
            if {![inactive [prop $c $key]]} {mismatch "Post-opt copy source has fixed placement $name/$key"}
        }
        foreach key {LOC BEL LOCK_PINS LUTNM HLUTNM SOFT_HLUTNM RLOC U_SET HU_SET H_SET} {
            if {![string_unset $c $key]} {mismatch "Post-opt copy source has placement/packing $name/$key"}
        }
        set source_configs {}; set input_nets {}
        dict for {port identity} [dict get $sig inputs] {
            set ip [pin $name/$port]; controls $ip
            dict set input_nets $port [one [get_nets -of_objects $ip] "LUT input immediate net"]
            net_protection [nets $ip]
            if {![string match @* $identity]} {
                set sc [cell [file dirname $identity]]
                dict set source_configs [get_property NAME $sc] [config $sc]
            }
        }
        set all [leaves $out]
        if {[llength $all] <= [llength $selected]} {mismatch "$role must retain original consumers"}
        net_protection [nets $out]
        set consumers {}; set moving {}; set macro_records {}
        foreach leaf $selected {
            set p [pin $leaf]
            if {$leaf ni $all || [get_property NAME [driver $p]] ne "$name/O"} {mismatch "Selected consumer has another driver: $leaf"}
        }
        if {[dict size [dict get $recipe macros]]} {
            dict for {mn ms} [dict get $recipe macros] {
                set mc [cell $mn]; set port [dict get $ms port]; set p [pin $mn/$port]
                protection $mc [dict get $recipe banks]
                dict set macro_records $mn [macro_snapshot $mn $port [dict get $ms ref] [dict get $ms leaves]]
                dict set consumers $mn [consumer $mc 1 $port]
                set upper [one [get_nets -boundary_type upper -of_objects $p] "macro upper net"]
                net_protection [list $upper]
                lappend moving [dict create pin $mn/$port old_net [get_property NAME $upper] macro 1]
            }
        } else {
            foreach leaf $selected {
                set lc [cell [file dirname $leaf]]; set p [pin $leaf]
                set expected [expr {$role eq "L1I" ? "FDRE" : "LUT3"}]
                if {[get_property REF_NAME $lc] ne $expected} {mismatch "Unsupported $role consumer type"}
                protection $lc {}
                dict set consumers [get_property NAME $lc] [consumer $lc 0]
                lappend moving [dict create pin $leaf old_net [get_property NAME [one [get_nets -of_objects $p] "selected immediate net"]] macro 0]
            }
        }
        foreach bank [dict get $recipe banks] {
            if {[string tolower [prop [cell $bank] DONT_TOUCH]] ni {1 true yes}} {mismatch "Expected protected sideband bank $bank"}
        }
        set copy ${name}__frost_[string tolower $role]_copy
        if {[llength [find get_cells $copy]] || [llength [find get_nets ${copy}_out]]} {mismatch "Copy object already exists"}
        set retained {}
        foreach leaf $all {if {$leaf ni $selected} {lappend retained $leaf}}
        dict set result $role [dict create recipe $recipe cell $name signature $sig \
            selected $selected retained $retained source_configs $source_configs input_nets $input_nets \
            consumers $consumers moving $moving macros $macro_records copy $copy]
    }
    # Shared upstream data sources are allowed. One target may not drive another
    # target's inputs: that would require a different declared fanout delta.
    dict for {role state} $result {
        dict for {port identity} [dict get $state signature inputs] {
            if {[file dirname $identity] in $seen} {mismatch "Interdependent copy targets"}
        }
    }
    return $result
}
proc ::frost_x3_nic_placement::restore_banks {} {
    variable released; variable protections
    set failures {}
    foreach bank $released {
        if {[catch {
            set_property DONT_TOUCH [dict get $protections $bank DONT_TOUCH] [cell $bank]
            if {[prop [cell $bank] DONT_TOUCH] ne [dict get $protections $bank DONT_TOUCH]} {error "readback differs"}
        } message]} {lappend failures "$bank: $message"}
    }
    if {[llength $failures]} {error "Bank protection restore failed: $failures"}
    set released {}
}
proc ::frost_x3_nic_placement::edit {states} {
    variable released
    dict for {role state} $states {
        set copy [dict get $state copy]
        create_cell -reference [dict get $state signature ref] $copy
        set c [cell $copy]
        set_property INIT [dict get $state signature init] $c
        if {[prop $c PARENT] ne [prop [cell [dict get $state cell]] PARENT]} {error "Copy parent differs"}
        dict for {port net} [dict get $state input_nets] {
            connect_net -hierarchical -net $net -objects [pin $copy/$port]
        }
        create_net ${copy}_out
        set net [one [find get_nets ${copy}_out] "new copy net"]
        connect_net -hierarchical -net $net -objects [pin $copy/O]
        try {
            foreach bank [dict get $state recipe banks] {
                # Record before attempting release, so every attempted change
                # is restored even if the native command partially succeeds.
                lappend released $bank
                set_property DONT_TOUCH false [cell $bank]
                if {![inactive [prop [cell $bank] DONT_TOUCH]]} {error "Bank release did not read back"}
            }
            foreach move [dict get $state moving] {
                set p [pin [dict get $move pin]]
                disconnect_net -net [dict get $move old_net] -pinlist $p
                connect_net -hierarchical -basename frost_x3_copy_pass -net $net -objects $p
            }
        } finally {restore_banks}
    }
}
proc ::frost_x3_nic_placement::verify {states} {
    variable protections
    set report {}
    dict for {role state} $states {
        set expected [dict get $state signature]; set copy [dict get $state copy]
        foreach {kind name sinks} [list original [dict get $state cell] [dict get $state retained] copy $copy [dict get $state selected]] {
            set c [cell $name]
            if {[signature $c] ne $expected || [leaves [pin $name/O]] ne $sinks} {error "Changed $role/$kind function or complete ownership"}
            foreach key {IS_LOC_FIXED IS_BEL_FIXED DONT_TOUCH KEEP} {
                if {![inactive [prop $c $key]]} {error "Unexpected new placement/protection $name/$key"}
            }
            foreach key {LOC BEL LOCK_PINS} {
                if {![string_unset $c $key]} {error "Unexpected new placement/packing $name/$key"}
            }
        }
        dict for {name expected_config} [dict get $state source_configs] {
            if {[config [cell $name]] ne $expected_config} {error "Changed upstream source configuration $name"}
        }
        set consumer_expected [dict get $state consumers]
        foreach move [dict get $state moving] {
            set pn [dict get $move pin]; set name [file dirname $pn]; set port [file tail $pn]
            dict set consumer_expected $name pins $port source $copy/O
            # The replacement upper alias may be generated by connect_net.
            # Prove its electrical driver; preserve all other exact pin nets.
            set direct [get_nets -of_objects [pin $pn]]
            if {[dict get $move macro]} {set direct [get_nets -boundary_type upper -of_objects [pin $pn]]}
            if {[llength $direct] != 1 || [get_property NAME [driver [pin $pn]]] ne "$copy/O"} {error "Changed copied consumer boundary"}
            dict set consumer_expected $name pins $port nets [names $direct]
        }
        dict for {name expected_consumer} $consumer_expected {
            set macro [dict exists [dict get $state recipe macros] $name]
            set moved_port {}
            if {$macro} {set moved_port [dict get $state recipe macros $name port]}
            if {[consumer [cell $name] $macro $moved_port] ne $expected_consumer} {error "Changed consumer configuration/other pins $name"}
        }
        dict for {name spec} [dict get $state recipe macros] {
            if {[macro_snapshot $name [dict get $spec port] [dict get $spec ref] [dict get $spec leaves]] ne [dict get $state macros $name]} {
                error "Changed whole memory macro internal boundary $name"
            }
        }
        dict set report $role [dict create original [dict get $state cell] copy $copy \
            signature $expected original_sinks [dict get $state retained] copy_sinks [dict get $state selected]]
    }
    dict for {name flags} $protections {
        dict for {key value} $flags {
            if {[prop [cell $name] $key] ne $value} {error "Changed hierarchy protection $name/$key"}
        }
    }
    return $report
}
proc ::frost_x3_nic_placement::write_audit {path data} {
    set f [open $path w]
    try {puts $f $data} finally {close $f}
}
# Return 1 only for four applied and verified copies; auto mismatch returns 0.
# Native query errors and every error after the first edit remain fatal.
proc ::frost_x3_nic_placement::post_opt {audit_file {mode auto}} {
    if {$mode ni {auto strict}} {error "Copy mode must be auto or strict"}
    write_audit $audit_file [dict create status PREFLIGHT mode $mode]
    set code [catch {prepare} states options]
    if {$code} {
        write_audit $audit_file [dict create status SKIPPED_OR_PREFLIGHT_ERROR mode $mode reason $states]
        if {$mode eq "auto" && [dict get $options -errorcode] eq {FROST X3_COPY MISMATCH}} {
            puts "FROST_X3_NIC_POST_OPT=SKIPPED ($states)"
            return 0
        }
        return -options $options $states
    }
    write_audit $audit_file [dict create status PREPARED mode $mode states $states]
    set code [catch {edit $states; verify $states} result options]
    if {$code} {
        write_audit $audit_file [dict create status FAILED_AFTER_MUTATION mode $mode reason $result states $states]
        return -options $options $result
    }
    write_audit $audit_file [dict create status APPLIED mode $mode copies 4 moved_leaves 40 states $states result $result]
    puts "FROST_X3_NIC_POST_OPT=APPLIED COPIES=4 MOVED_LEAVES=40"
    return 1
}
# No physical recipe is assumed for a fresh first placement. A future refinement
# must measure current maps/headroom and preserve global setup/hold on rollback.
proc ::frost_x3_nic_placement::post_place {audit_file {mode auto}} {
    if {$mode ni {auto strict}} {error "Copy mode must be auto or strict"}
    write_audit $audit_file [dict create status SKIPPED reason {No portable post-place refinement enabled}]
    puts "FROST_X3_NIC_POST_PLACE=SKIPPED (no current-placement recipe)"
    return 0
}
