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

    # Stream the image in burst-sized chunks. Reading the whole file into one
    # giant Tcl list and indexing it per word (lindex on a multi-MB list) is
    # pathologically slow in the Vivado tcl interpreter -- THAT, not the JTAG,
    # is what turned a ~6 MB Linux image into a ~17 min load (the actual
    # create/run/delete of all ~8.8k bursts is only ~15 s). Reading burst_words
    # lines at a time keeps every list tiny, so the data-prep is ~linear and
    # negligible. run+delete in batches so the live hw_axi_txn set stays bounded.
    set axi [get_hw_axis $axi_interface_name]
    set current_address 0
    set transaction_number 0
    set total_words 0
    set batch 0
    set batch_limit 512

    while {1} {
        # Collect up to burst_words words for this burst (skipping blank lines,
        # so non-blank word N still lands at DDR offset N -- matches the old
        # read-all-then-index behaviour).
        set chunk [list]
        for {set i 0} {$i < $burst_words} {incr i} {
            if {[gets $file_descriptor word_hex_value] < 0} { break }
            set trimmed [string trim $word_hex_value]
            if {$trimmed ne ""} { lappend chunk $trimmed }
        }
        set beats [llength $chunk]
        if {$beats == 0} { break }

        # hw_axi burst data is one bit-vector with beat 0 in the least
        # significant word: concatenate this burst's words last-to-first.
        set data ""
        for {set b [expr {$beats - 1}]} {$b >= 0} {incr b -1} {
            append data [lindex $chunk $b]
        }
        create_hw_axi_txn ddrwr$batch $axi \
            -type write -address [format 0x%08x $current_address] -len $beats -data $data
        incr batch
        incr transaction_number
        incr total_words $beats
        incr current_address [expr {4 * $beats}]
        if {$batch >= $batch_limit} {
            run_hw_axi [get_hw_axi_txns ddrwr*]
            delete_hw_axi_txn [get_hw_axi_txns ddrwr*]
            set batch 0
            puts "  DDR load progress: $total_words words"
            flush stdout
        }
    }
    close $file_descriptor

    if {$batch > 0} {
        run_hw_axi [get_hw_axi_txns ddrwr*]
        delete_hw_axi_txn [get_hw_axi_txns ddrwr*]
    }

    puts "Loaded $total_words DDR words in $transaction_number burst transaction(s)"
}
