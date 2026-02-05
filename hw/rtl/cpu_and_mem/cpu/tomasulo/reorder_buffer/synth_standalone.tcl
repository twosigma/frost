# Standalone Vivado Synthesis Script for Reorder Buffer
# Target: 300MHz clock, UltraScale+ part
# Usage: vivado -mode batch -source synth_standalone.tcl

# Configuration
set fpga_part "xcux35-vsva1365-3-e"
set top_module "reorder_buffer"
set target_freq_mhz 300
set target_period_ns [expr {1000.0 / $target_freq_mhz}]

# Paths relative to this script
set script_dir [file dirname [file normalize [info script]]]
set project_root [file normalize "$script_dir/../../../../../.."]
set work_dir "$script_dir/synth_work"

puts "=============================================="
puts "Standalone Synthesis: $top_module"
puts "Target: $target_freq_mhz MHz ($target_period_ns ns period)"
puts "Part: $fpga_part"
puts "=============================================="

# Clean and create work directory
file delete -force $work_dir
file mkdir $work_dir

# Create in-memory project
create_project -in_memory -part $fpga_part

# Read RTL sources (order matters for package dependencies)
set rtl_files [list \
    "$project_root/hw/rtl/cpu_and_mem/cpu/riscv_pkg.sv" \
    "$script_dir/reorder_buffer.sv" \
]

puts "\nReading RTL files:"
foreach f $rtl_files {
    puts "  $f"
    if {![file exists $f]} {
        puts "ERROR: File not found: $f"
        exit 1
    }
}
read_verilog -sv $rtl_files

# Create clock constraint in memory
set xdc_content "create_clock -period $target_period_ns -name clk \[get_ports i_clk\]"
set xdc_file "$work_dir/timing.xdc"
set fp [open $xdc_file w]
puts $fp $xdc_content
close $fp
read_xdc $xdc_file

# Run synthesis
puts "\n=============================================="
puts "Running synthesis..."
puts "=============================================="

synth_design -top $top_module -part $fpga_part -directive Default -mode out_of_context

# Write checkpoint
write_checkpoint -force "$work_dir/post_synth.dcp"

# Generate reports
puts "\nGenerating reports..."

report_timing_summary -file "$work_dir/timing_summary.rpt" -max_paths 10
report_utilization -file "$work_dir/utilization.rpt"
report_high_fanout_nets -timing -load_types -max_nets 25 -file "$work_dir/high_fanout.rpt"

# Extract key timing metrics
set timing_summary [report_timing_summary -return_string -max_paths 1]

# Parse WNS from timing summary
set wns "N/A"
set tns "N/A"
if {[regexp {WNS\(ns\)\s+TNS\(ns\).*\n\s*-+\s*-+.*\n\s*([0-9.-]+)\s+([0-9.-]+)} $timing_summary match wns_val tns_val]} {
    set wns $wns_val
    set tns $tns_val
}

# Print summary
puts "\n=============================================="
puts "SYNTHESIS COMPLETE"
puts "=============================================="
puts "Target clock: $target_freq_mhz MHz ($target_period_ns ns)"
puts "Worst Negative Slack (WNS): $wns ns"
puts "Total Negative Slack (TNS): $tns ns"

if {$wns ne "N/A" && $wns >= 0} {
    puts "\nTIMING MET - Design closes at $target_freq_mhz MHz"
} elseif {$wns ne "N/A"} {
    set achieved_period [expr {$target_period_ns - $wns}]
    set achieved_freq [expr {1000.0 / $achieved_period}]
    puts "\nTIMING NOT MET"
    puts "Achieved frequency: [format %.1f $achieved_freq] MHz"
}

puts "\nReports written to: $work_dir/"
puts "  - timing_summary.rpt"
puts "  - utilization.rpt"
puts "  - high_fanout.rpt"
puts "  - post_synth.dcp"

# Report utilization summary to console
puts "\n=============================================="
puts "UTILIZATION SUMMARY"
puts "=============================================="
report_utilization -hierarchical -hierarchical_depth 1

exit
