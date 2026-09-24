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

# X3 post-place timing gate, run after placement with the added setup
# uncertainty back at zero (the gate checks this). Writes post_place_gate.txt
# with STATUS=PASS when no path has setup slack below -0.200 ns. Printed slack
# has three decimals and cannot resolve that boundary, so the comparison uses
# Vivado's calculated slack.
namespace eval ::frost_x3_post_place_gate {
    proc one {objects label} {
        if {[llength $objects] != 1} {error "Expected one $label"}
        return $objects
    }

    proc read_text {path} {
        set f [open $path r]
        set result [read $f]
        close $f
        return $result
    }

    proc finite {value} {
        return [regexp {^-?[0-9]+([.][0-9]+)?$} $value]
    }

    # report_timing prints the requirement to three decimals, but the clock
    # object holds the full period. Accept a printed value within half a unit
    # of the last printed digit (0.0005 ns) of the period.
    proc displays_as {value expected} {
        return [expr {abs($value - $expected) <= 0.0005}]
    }

    proc validate_cpu_report {text period} {
        if {![regexp -line {^\| Design State\s*:\s*Fully Placed\s*$} $text] ||
            ![regexp -line {^\s*Path Type:\s*Setup \(Max} $text]} {
            error "Post-place gate requires a Fully Placed CPU setup report"
        }
        if {[regexp -all {clocked by clock_from_mmcm  } $text] != 2 ||
            ![regexp -line {^\s*Requirement:\s*([0-9.]+)ns} $text -> requirement] ||
            ![finite $requirement] || ![displays_as $requirement $period]} {
            error "Post-place gate CPU requirement differs from its real clock"
        }
        set explicit 0
        foreach line [split $text \n] {
            if {[string first "User Uncertainty" $line] >= 0} {
                if {![regexp {User Uncertainty\s*\(UU\):\s*([-+0-9.]+)ns\s*$} $line -> value] ||
                    ![finite $value] || $value != 0} {
                    error "Post-place gate requires zero added CPU setup uncertainty"
                }
                incr explicit
            }
        }
        if {!$explicit && (![regexp -line {^\s*Clock Uncertainty:.*\+ PE[ \t]*$} $text] ||
            [string first "+ UU" $text] >= 0)} {
            error "Post-place gate cannot establish zero added setup uncertainty"
        }
    }

    proc write {work_directory} {
        set audit [file join $work_directory post_place_gate.txt]
        file delete $audit
        if {[get_property PART [current_design]] ne "xcux35-vsva1365-3-e"} {
            error "Post-place gate expected the X3 part"
        }
        set clock [one [get_clocks clock_from_mmcm] "X3 CPU clock"]
        set period [get_property PERIOD $clock]
        if {![finite $period] || $period <= 0} {error "Invalid CPU clock period"}

        # Require a global worst path, so a design with no timed paths cannot pass.
        set command [list get_timing_paths -delay_type max -sort_by slack -max_paths 1 -nworst 1]
        set worst [one [{*}$command] "global max-delay path"]
        set slack [get_property SLACK $worst]
        if {![finite $slack]} {error "Missing finite global setup slack"}
        report_timing -of_objects $worst -file [file join $work_directory post_place_gate_worst.rpt]

        # Check the worst CPU-to-CPU path's report for the CPU clock period and
        # zero user uncertainty (UU). The global worst path may be in a MAC
        # clock domain, whose report says nothing about the CPU clock.
        set cpu_path [one [{*}$command -from $clock -to $clock] "CPU max-delay path"]
        foreach key {STARTPOINT_CLOCK ENDPOINT_CLOCK GROUP} {
            if {[get_property $key $cpu_path] ne "clock_from_mmcm"} {
                error "Post-place gate CPU path has unexpected clock ownership"
            }
        }
        set cpu_report [file join $work_directory post_place_gate_cpu.rpt]
        report_timing -of_objects $cpu_path -file $cpu_report
        validate_cpu_report [read_text $cpu_report] $period

        # Vivado compares calculated slack with the threshold (-slack_lesser_than
        # is strict); the rounded SLACK value never decides it.
        set below [{*}$command -slack_lesser_than -0.200]
        set count [llength $below]
        if {$count > 1} {error "Unexpected strict-threshold path count"}
        if {$count} {
            report_timing -of_objects $below -file [file join $work_directory post_place_gate_below.rpt]
        }
        set status [expr {$count == 0 ? "PASS" : "FAIL"}]
        set f [open $audit w]
        puts $f "STATUS=$status"
        puts $f "THRESHOLD_NS=-0.200"
        puts $f "CPU_PERIOD_NS=$period"
        puts $f "USER_SETUP_UNCERTAINTY_NS=0.000"
        puts $f "STRICT_BELOW_GATE_PATHS=$count"
        puts $f "WORST_SLACK_NS=$slack"
        close $f
        puts "X3 post-place gate: $status (WNS@0=$slack ns, paths strictly below -0.200 ns: $count)"
        return [expr {$count == 0}]
    }
}
