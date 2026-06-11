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

# Write a DDR image (sw_ddr.txt: one 32-bit hex word per line, dense from
# region offset 0) through the dedicated JTAG-AXI DDR master. Unlike the
# single-word BRAM path, this uses AXI4 INCR bursts (up to 256 beats per
# transaction) -- the radix2 image is ~800 KiB and would take ~200k
# transactions otherwise.
#
# Addresses are REGION-RELATIVE: offset 0 = the base of the 1 GiB cached
# region (0x8000_0000 in the CPU's address map). The CPU must be held in
# reset while this runs (the image-load reset in xilinx_frost_subsystem
# asserts on low-BRAM writes, which the loader always performs afterwards;
# the caches re-invalidate on that reset, so the freshly written DDR contents
# are never shadowed by stale lines).

proc file2ddr {firmware_filename {axi_interface_name hw_axi_2} {burst_words 256}} {

    set file_descriptor [open $firmware_filename r]
    set words [list]
    while {[gets $file_descriptor word_hex_value] >= 0} {
        set trimmed [string trim $word_hex_value]
        if {$trimmed ne ""} {
            lappend words $trimmed
        }
    }
    close $file_descriptor

    set total_words [llength $words]
    set current_address 0
    set transaction_number 0
    set index 0

    while {$index < $total_words} {
        set beats [expr {min($burst_words, $total_words - $index)}]
        # hw_axi burst data is one bit-vector with beat 0 in the least
        # significant word: concatenate this burst's words last-to-first.
        set data ""
        for {set b [expr {$beats - 1}]} {$b >= 0} {incr b -1} {
            append data [lindex $words [expr {$index + $b}]]
        }
        set formatted_address [format 0x%08x $current_address]
        create_hw_axi_txn ddrwr$transaction_number [get_hw_axis $axi_interface_name] \
            -type write -address $formatted_address -len $beats -data $data
        incr transaction_number
        incr index $beats
        incr current_address [expr {4 * $beats}]
    }

    if {$transaction_number > 0} {
        run_hw_axi [get_hw_axi_txns ddrwr*]
    }

    puts "Loaded $total_words DDR words in $transaction_number burst transaction(s)"
}
