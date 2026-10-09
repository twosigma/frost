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

# Diagnostic-only helper: never sourced by the production place step.

# Post-place input-pin swaps for the two X3 PD target LUTs. Only the physical
# pin assignment changes; logic, location, and fixed flags stay the same. The
# recipe matches one recorded placement, and auto mode skips any other.
namespace eval frost_x3_pd_target_pin_swaps {
    proc pin_map {cell} {
        set result {}
        foreach pin [lsort [get_pins -of_objects $cell -filter {DIRECTION == IN}]] {
            set physical [get_bel_pins -of_objects $pin]
            if {[llength $physical] != 1} {
                mismatch "Nonunique physical input pin: $pin"
            }
            lappend result "[get_property REF_PIN_NAME $pin]:[file tail $physical]"
        }
        return $result
    }

    proc logical_signature {cell} {
        set result [list [get_property NAME $cell] [get_property REF_NAME $cell] [get_property INIT $cell]]
        foreach pin [lsort [get_pins -of_objects $cell]] {
            lappend result [list [get_property REF_PIN_NAME $pin] [lsort [get_nets -segments -of_objects $pin]]]
        }
        return $result
    }

    proc snapshot {cell} {
        set result [dict create cell $cell logic [logical_signature $cell] map [pin_map $cell]]
        foreach property {LOC BEL IS_LOC_FIXED IS_BEL_FIXED LOCK_PINS} {
            dict set result $property [get_property $property $cell]
        }
        return $result
    }

    proc remap {state mapping} {
        set cell [dict get $state cell]
        set site_bel "[dict get $state LOC]/[lindex [split [dict get $state BEL] .] end]"
        unplace_cell $cell
        reset_property LOCK_PINS $cell
        set_property LOCK_PINS $mapping $cell
        place_cell [list $cell $site_bel]
        set_property IS_LOC_FIXED [dict get $state IS_LOC_FIXED] $cell
        set_property IS_BEL_FIXED [dict get $state IS_BEL_FIXED] $cell
    }

    proc check_unchanged {before after} {
        foreach key {cell logic LOC BEL IS_LOC_FIXED IS_BEL_FIXED} {
            if {[dict get $before $key] ne [dict get $after $key]} {
                error "PD target pin refinement changed $key for [dict get $before cell]"
            }
        }
    }

    proc mismatch {message} {
        return -code error -errorcode {FROST PIN_SWAPS MISMATCH} $message
    }

    proc timing_summary {} {
        set result {}
        foreach {key delay} {wns max whs min} {
            set path [get_timing_paths -delay_type $delay -max_paths 1]
            if {[llength $path] != 1} {error "Expected a global $key timing path"}
            set slack [get_property SLACK $path]
            if {![string is double -strict $slack] || !($slack > -Inf && $slack < Inf)} {
                error "Invalid global $key slack: $slack"
            }
            dict set result $key $slack
        }
        return $result
    }

    proc check_sibling {site} {
        set sibling_bel [get_bels -quiet $site/D5LUT]
        if {[llength $sibling_bel] != 1 ||
            [llength [get_cells -quiet -of_objects $sibling_bel]] != 0} {
            mismatch "Expected unused paired D5LUT at $site"
        }
    }

    # mode is strict unless the caller passes auto. Returns 1 only when both
    # swaps are applied, global WNS and WHS are no worse, and the PASS audit is
    # written. In auto mode, a design that does not match the recipe returns 0
    # before any change, and a failed swap returns 0 once the rollback has
    # restored the original cells and timing. A failed rollback or audit write
    # is always an error, and a skip never leaves an audit file.
    proc apply {audit_file {mode strict}} {
        if {$mode ni {auto strict}} {error "Pin refinement mode must be auto or strict"}
        file delete $audit_file
        set prefix subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/if_stage_inst/c_ext_state_inst
        set recipes [list \
            [list ${prefix}/u_pd_target_compressed_candidate_i_12 LUT3 8'hB8 SLICE_X63Y358 \
                {I0:A5 I1:A6 I2:A4} {I0:A5 I1:A4 I2:A6}] \
            [list ${prefix}/u_pd_target_compressed_candidate_i_2 LUT4 16'hBF80 SLICE_X67Y361 \
                {I0:A5 I1:A6 I2:A4 I3:A3} {I0:A5 I1:A3 I2:A4 I3:A6}]]
        set states {}
        # Check both cells against the recipe before any change or timing
        # query, so an auto-mode skip does no timing work.
        set code [catch {
            foreach recipe $recipes {
                lassign $recipe name ref init site old_map new_map
                set cell [get_cells -quiet $name]
                if {[llength $cell] != 1} {mismatch "Expected one PD target LUT: $name"}
                set state [snapshot $cell]
                if {[get_property REF_NAME $cell] ne $ref ||
                    ![string equal -nocase [get_property INIT $cell] $init] ||
                    [dict get $state LOC] ne $site ||
                    [lindex [split [dict get $state BEL] .] end] ne "D6LUT" ||
                    [dict get $state map] ne $old_map ||
                    [dict get $state IS_LOC_FIXED] != 0 || [dict get $state IS_BEL_FIXED] != 0 ||
                    [dict get $state LOCK_PINS] ne ""} {
                    mismatch "PD target LUT does not match the recorded raw placement: $name"
                }
                check_sibling $site
                lappend states $state
            }
        } message options]
        if {$code != 0} {
            if {$mode eq "auto" && [dict get $options -errorcode] eq {FROST PIN_SWAPS MISMATCH}} {
                puts "FROST_X3_PD_TARGET_PIN_SWAPS=SKIPPED ($message)"
                return 0
            }
            return -options $options $message
        }

        set before_timing [timing_summary]
        set phase mutation
        set code [catch {
            foreach state $states recipe $recipes {
                remap $state [lindex $recipe 5]
            }
            set final_states {}
            foreach state $states recipe $recipes {
                set after [snapshot [dict get $state cell]]
                check_unchanged $state $after
                set new_map [lindex $recipe 5]
                if {[dict get $after map] ne $new_map ||
                    [lsort [dict get $after LOCK_PINS]] ne [lsort $new_map]} {
                    error "Actual PD target physical pin map differs from the requested map"
                }
                check_sibling [dict get $state LOC]
                lappend final_states $after
            }
            set after_timing [timing_summary]
            foreach key {wns whs} {
                if {[dict get $after_timing $key] < [dict get $before_timing $key]} {
                    error "Global $key regressed from [dict get $before_timing $key] to [dict get $after_timing $key] ns"
                }
            }
            set phase audit
            set audit [open $audit_file w]
            puts $audit "FROST_X3_PD_TARGET_PIN_SWAPS=PASS"
            puts $audit "MODE=$mode"
            puts $audit [list global_timing_before $before_timing global_timing_after $after_timing]
            foreach before $states after $final_states {
                puts $audit [list cell [dict get $before cell] before $before after $after]
            }
            close $audit
            unset audit
        } message options]
        if {$code != 0} {
            if {[info exists audit]} {catch {close $audit}}
            # Roll back both cells. Auto mode may continue only if every cell
            # snapshot and the global WNS and WHS match their original values
            # exactly; a failed rollback or audit write is always fatal.
            set rollback_errors {}
            foreach state $states {
                if {[catch {
                    remap $state [dict get $state map]
                    reset_property LOCK_PINS [dict get $state cell]
                    if {[snapshot [dict get $state cell]] ne $state} {error "Rollback state differs"}
                    check_sibling [dict get $state LOC]
                } rollback_error]} {
                    lappend rollback_errors $rollback_error
                }
            }
            if {[catch {
                set restored_timing [timing_summary]
                foreach key {wns whs} {
                    if {[dict get $restored_timing $key] != [dict get $before_timing $key]} {
                        error "Rollback global $key differs from original"
                    }
                }
                file delete $audit_file
            } rollback_error]} {
                lappend rollback_errors $rollback_error
            }
            if {[llength $rollback_errors] != 0} {
                append message "; rollback failed: [join $rollback_errors {; }]"
            } elseif {$mode eq "auto" && $phase ne "audit"} {
                puts "FROST_X3_PD_TARGET_PIN_SWAPS=SKIPPED (verified rollback: $message)"
                return 0
            }
            return -options $options $message
        }

        puts "Applied two X3 PD target physical pin maps; logical function, location and fixed flags unchanged"
        puts "Global pin refinement timing: before=$before_timing after=$after_timing"
        return 1
    }
}
