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

# Debug transport check for fpga/hw_regression.py's debug_port stage. Source
# this after a board configuration and before init:
#
#   openocd -f fpga/debug/openocd_x3.cfg -f fpga/debug/hw_debug_check.tcl \
#       -c init -c frost_debug_check -c shutdown
#
# frost_debug_check reads dtmcs over JTAG and dmstatus and hartinfo over DMI,
# halts the hart if it is running, reads dpc, resumes it, and reads dtmcs and
# hartinfo again. It prints raw values as "FROST_DEBUG <key>=<value>" lines in
# a fixed order, then FROST_DEBUG_DONE, and leaves the verdict to the caller
# (judge_debug_output in hw_regression.py), which accepts exactly that
# sequence. A failure prints "FROST_DEBUG_ERR: <reason>" and ends the
# sequence early; a hart this procedure halted is resumed even then, and its
# last state is printed as state_left. frost_debug_recover runs in a separate
# OpenOCD process to resume a halted hart if needed and report state_left so
# the caller confirms the hart's state independently of the first transcript.
#
# OpenOCD's background polling scans the TAP on a timer. It is switched off
# for the whole check: a poll between a raw irscan and its drscan would change
# the instruction and the scan would read another register. It is switched on
# again on every path.

if {[catch {
    riscv set_ebreakm off
    riscv set_ebreaks off
    riscv set_ebreaku off
}]} {
    catch {[target current] configure -ebreak exception}
}
catch {riscv autofence off}

# Every line is flushed at once so that a killed OpenOCD still leaves what it
# had printed.
proc frost_debug_print {key value} {
    puts "FROST_DEBUG $key=$value"
    flush stdout
}

# Read dtmcs through the TAP's DTMCS instruction (USER3 on the FPGA's own TAP).
proc frost_debug_read_dtmcs {tap} {
    set dtmcs_ir [expr {$tap eq "frost.fpga" ? 0x22 : 0x10}]
    irscan $tap $dtmcs_ir
    return [expr {"0x[drscan $tap 32 0]"}]
}

# dtmcs, after clearing a sticky busy status left by batched DMI scans in an
# earlier session; dmireset (dtmcs bit 16) clears it.
proc frost_debug_clean_dtmcs {tap} {
    set dtmcs [frost_debug_read_dtmcs $tap]
    if {($dtmcs & 0xf) == 1 && (($dtmcs >> 4) & 0x3f) == 7 && (($dtmcs >> 10) & 0x3) == 3} {
        irscan $tap [expr {$tap eq "frost.fpga" ? 0x22 : 0x10}]
        drscan $tap 32 0x10000
        set dtmcs [frost_debug_read_dtmcs $tap]
    }
    return $dtmcs
}

proc frost_debug_state {tgt} {
    poll
    return [$tgt curstate]
}

proc frost_debug_check_steps {tgt} {
    upvar 1 resume_needed resume_needed
    set tap [$tgt cget -chain-position]

    set dtmcs [frost_debug_clean_dtmcs $tap]
    frost_debug_print dtmcs [format 0x%08x $dtmcs]

    frost_debug_print dmstatus [format 0x%08x [riscv dmi_read 0x11]]
    frost_debug_print hartinfo [format 0x%08x [riscv dmi_read 0x12]]

    set before [frost_debug_state $tgt]
    frost_debug_print state_before $before
    if {$before ne "running" && $before ne "halted"} {
        error "the hart is $before before the check"
    }

    if {$before eq "running"} {
        set resume_needed 1
        halt
        wait_halt 2000
    }
    set halted [frost_debug_state $tgt]
    frost_debug_print state_halted $halted
    frost_debug_print dmstatus_halted [format 0x%08x [riscv dmi_read 0x11]]
    if {$halted ne "halted"} {
        error "the hart did not halt (state $halted)"
    }

    set resume_needed 1
    frost_debug_print dpc [format 0x%x [dict get [get_reg -force dpc] dpc]]

    resume
    set resume_needed 0
    frost_debug_print state_after_resume [frost_debug_state $tgt]
    frost_debug_print dmstatus_running [format 0x%08x [riscv dmi_read 0x11]]
    # The transport and the debug module must read the same after the run.
    # Read dtmcs without clearing sticky status so any error left by the check
    # itself is reported.
    frost_debug_print dtmcs_after [format 0x%08x [frost_debug_read_dtmcs $tap]]
    frost_debug_print hartinfo_after [format 0x%08x [riscv dmi_read 0x12]]
}

proc frost_debug_check {} {
    set tgt [target current]
    set resume_needed 0
    catch {poll off}
    if {[catch {frost_debug_check_steps $tgt} message]} {
        puts "FROST_DEBUG_ERR: $message"
        flush stdout
    }
    # Leave the hart running whatever happened above.
    if {$resume_needed} {
        catch {
            poll
            if {[$tgt curstate] eq "halted"} {
                resume
            }
        }
    }
    catch {poll on}
    catch {frost_debug_print state_left [frost_debug_state $tgt]}
    puts "FROST_DEBUG_DONE"
    flush stdout
}

proc frost_debug_recover {} {
    set tgt [target current]
    if {[catch {
        poll
        if {[$tgt curstate] eq "halted"} {
            resume
        }
    } message]} {
        puts "FROST_DEBUG_ERR: $message"
        flush stdout
    }
    catch {frost_debug_print state_left [frost_debug_state $tgt]}
    puts "FROST_DEBUG_DONE"
    flush stdout
}
