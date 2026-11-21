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

lassign $argv export_script output_dir
set prefix [file join $output_dir export]
set argc 2
set argv [list design.dcp $prefix]

proc open_checkpoint {checkpoint} {
    if {$checkpoint ne "design.dcp"} {error "unexpected checkpoint $checkpoint"}
}

set path_rows {
    {-0.250 cpu cpu source1/C endpoint1/D}
    {0.045 cpu cpu source1/C endpoint2/D}
    {0.399 cpu {nic[1]} source2/C endpoint3/D}
    {0.400 cpu {nic[1]} source2/C endpoint4/D}
    {0.700 cpu {nic[1]} source2/C endpoint5/D}
    {1.000 cpu {nic[1]} source2/C endpoint6/D}
    {0.675 {nic[1]} cpu source3/C endpoint7/D}
    {0.700 {nic[1]} cpu source3/C endpoint8/D}
    {-0.015 {} cpu input endpoint9/D}
    {0.000 cpu {} source4/C output}
    {0.512 {io "ref", gated} cpu source5/C endpoint10/D}
}

proc get_timing_paths {args} {
    if {$args ne {-setup -sort_by slack -nworst 1 -max_paths 600000 -slack_lesser_than 1.0 -no_report_unconstrained}} {
        error "unexpected timing query $args"
    }
    return {0 1 2 3 4 5 6 7 8 9 10}
}

proc get_property {name path} {
    set fields {SLACK STARTPOINT_CLOCK ENDPOINT_CLOCK STARTPOINT_PIN ENDPOINT_PIN}
    set index [lsearch -exact $fields $name]
    if {$index < 0} {error "unexpected path property $name"}
    return [lindex $::path_rows $path $index]
}

proc report_clock_interaction {args} {
    if {$args ne [list -setup -significant_digits 3 -file ${::prefix}_clock_interaction.rpt]} {
        error "unexpected clock query $args"
    }
    set output [open [lindex $args end] w]
    try {
        set widths {23 23 11 7 7 11 11 15 20 24}
        set format_string [join [lmap width $widths {format {%%-%ds} $width}] "  "]
        puts $output "Clock Interaction Table"
        puts $output [format $format_string {From Clock} {To Clock} {Clock Edges} \
            WNS(ns) TNS(ns) Endpoints Endpoints Requirement(ns) Classification Constraints]
        puts $output [join [lmap width $widths {string repeat - $width}] "  "]
        foreach {launch capture wns total constraint} {
            cpu cpu -0.250 32 {Partial False Path}
            cpu {nic[1]} 0.399 11 Timed
            {nic[1]} cpu 0.675 8 {Max Delay Datapath Only}
            cpu ddr {} 9 {Asynchronous Groups}
            ddr cpu {} 2 {Asynchronous Groups}
            cpu freerun {} 6 {False Path}
            freerun freerun 2.100 7 Timed
        } {
            set edges [expr {$wns eq "" ? "" : "rise - rise"}]
            set classification [expr {$wns eq "" ? "Ignored" : "Clean"}]
            puts $output [format $format_string $launch $capture $edges $wns \
                "" 0 $total "" $classification $constraint]
        }
    } finally {
        close $output
    }
}

source $export_script

set output [open [file join $output_dir summary.rpt] w]
puts $output {Startpoint                     Endpoint                       Slack(ns)
------------------------------------------------------------------------
block/source/A                 top/dest/A                     -0.005
block/source/B
                               top/dest/B                      0.400
block/source/C
                               top/dest/C
                                                               0.700
block/source/D                 top/dest/D
                                                               1.000}
close $output
