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

# Read FROST's cache profiling counters through the debug module, for
# fpga/debug/cache_counters.py. Source this after a board or simulation
# configuration and before init:
#
#   openocd -f fpga/debug/openocd_x3.cfg -f fpga/debug/cache_counters.tcl \
#       -c init -c frost_cache_snapshot -c shutdown
#
# The two snapshot procedures halt a running hart, take a profiling-counter
# snapshot, and resume it. The cache block keeps the snapshot before the current one
# (mperfctl bit 1 selects it), so a window needs only a short halt at its
# start:
#
#   frost_cache_mark      takes the snapshot, reads the time CSR, and resumes:
#                           FROST_CACHE_MARK time=<n>
#   frost_cache_snapshot  takes the snapshot, reads the time CSR and the cache
#                         block's counters (106 up to mperfcount) from it and
#                         from the preceding one, and resumes:
#                           FROST_CACHE_SNAPSHOT time=<n> 106=<n> ...
#                           FROST_CACHE_PREVIOUS 106=<n> ...
#
# Both print "absent" in place of the fields when the core has no profiling
# counters. The time CSR reads the CLINT's mtime, which counts core cycles;
# Linux's perf support can stop and preload mcycle, so it is no clock here. A
# program that takes snapshots itself moves the same banks, so measure such a
# program either itself or with these, not both.

# mperfsel and mperfctl (0x7C0-0x7C1) and mperfdata, mperfdatah, and
# mperfcount (0xFC0-0xFC2) are custom machine-mode CSRs.
riscv expose_csrs 1984-1985,4032-4034

# Leave ebreak to the hart's own trap handlers. With OpenOCD's default, an
# ebreak after a snapshot has resumed the hart, such as a kernel warning,
# would halt it in Debug Mode with no debugger attached.
if {[catch {
    riscv set_ebreakm off
    riscv set_ebreaks off
    riscv set_ebreaku off
}]} {
    [target current] configure -ebreak exception
}

# OpenOCD versions that have it can skip the fence.i they otherwise run before
# each resume, which on FROST writes the L1D back and invalidates the L1I.
catch {riscv autofence off}

proc frost_csr {number} {
    set name csr$number
    return [expr {[dict get [get_reg -force $name] $name]}]
}

proc frost_set_csr {number value} {
    set_reg [list csr$number $value]
}

proc frost_time {} {
    return [expr {[dict get [get_reg -force time] time]}]
}

# The selected bank's cache block, as " <index>=<value>" fields.
proc frost_cache_bank {} {
    set fields ""
    set count [frost_csr 4034]
    for {set index 106} {$index < $count} {incr index} {
        # A selector write that did not reach the hart would return another
        # counter's value.
        frost_set_csr 1984 $index
        if {[frost_csr 1984] != $index} {
            error "mperfsel did not take $index"
        }
        set low [expr {[frost_csr 4032] & 0xffffffff}]
        set high [expr {[frost_csr 4033] & 0xffffffff}]
        append fields " $index=[expr {($high << 32) | $low}]"
    }
    return $fields
}

# Halt a running hart, run body, resume the hart even when body fails, and
# print the lines body returns. A hart a debugger has halted stays halted.
proc frost_cache_halted {body} {
    poll
    set state [[target current] curstate]
    if {$state ne "running" && $state ne "halted"} {
        error "the hart is $state, neither running nor halted"
    }
    set resume [expr {$state eq "running"}]
    set status [catch {
        if {$resume} {
            halt
            wait_halt 2000
        }
        uplevel 1 $body
    } result]
    if {$resume} {
        poll
        if {[[target current] curstate] eq "halted"} {
            resume
        }
    }
    if {$status} {
        error $result
    }
    foreach line $result {
        puts $line
    }
}

proc frost_cache_mark {} {
    frost_cache_halted {
        if {[frost_csr 4034] == 0} {
            list "FROST_CACHE_MARK absent"
        } else {
            frost_set_csr 1985 1
            list "FROST_CACHE_MARK time=[frost_time]"
        }
    }
}

proc frost_cache_snapshot {} {
    frost_cache_halted {
        if {[frost_csr 4034] == 0} {
            list "FROST_CACHE_SNAPSHOT absent"
        } else {
            frost_set_csr 1985 1
            set time [frost_time]
            set current [frost_cache_bank]
            frost_set_csr 1985 2
            set previous [frost_cache_bank]
            frost_set_csr 1985 0
            list "FROST_CACHE_SNAPSHOT time=$time$current" \
                "FROST_CACHE_PREVIOUS$previous"
        }
    }
}

# Resume the hart if it is halted, as an OpenOCD run stopped between its halt
# and its resume leaves it:
#   FROST_CACHE_HART resumed      or      FROST_CACHE_HART <state>
proc frost_cache_resume {} {
    poll
    set state [[target current] curstate]
    if {$state eq "halted"} {
        resume
        puts "FROST_CACHE_HART resumed"
    } else {
        puts "FROST_CACHE_HART $state"
    }
}
