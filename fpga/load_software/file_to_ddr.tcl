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
# asserts on low-BRAM writes; the caches re-invalidate on that reset, so the
# freshly written DDR contents are never shadowed by stale lines).
#
# CRITICAL: the image_load_reset is a ~4 s one-shot counter re-armed by each
# low-BRAM write. A multi-MB DDR image takes much longer than 4 s to burst in,
# so a single pre-load BRAM write is NOT enough -- the counter expires
# mid-load, the CPU comes out of reset, and free-runs against the half-written
# DDR image (nondeterministic -> flaky boot hangs). When bram_axi_name is
# given we re-arm the reset with a dummy low-BRAM write every poke_interval
# bursts (sub-second << 4 s), holding the CPU in reset for the ENTIRE load.
# The DDR loader (S01) is a separate AXI master and keeps running while the CPU
# is held, so the load still completes.

# Re-arm the image-load CPU reset with a single low-BRAM write (restarts the
# subsystem's ~4 s reset counter). Called right before every blocking DDR batch
# run so the counter can never expire mid-load and let the CPU free-run.
proc _rearm_image_load_reset {bram_axi_name rearm_word} {
    if {$bram_axi_name eq ""} return
    create_hw_axi_txn rstkeep [get_hw_axis $bram_axi_name] \
        -type write -address 0x00000000 -len 1 -data $rearm_word
    run_hw_axi [get_hw_axi_txns rstkeep]
    delete_hw_axi_txn [get_hw_axi_txns rstkeep]
}

proc file2ddr {firmware_filename {axi_interface_name hw_axi_2} {burst_words 256} {bram_axi_name ""} {rearm_word "00000000"}} {

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
    set batch_limit 128  ;# small batches so each blocking run_hw_axi stays well under the ~4 s reset counter

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
            # Re-arm the reset IMMEDIATELY before the blocking batch run (the only
            # loop step long enough to risk the ~4 s counter expiring mid-load).
            _rearm_image_load_reset $bram_axi_name $rearm_word
            run_hw_axi [get_hw_axi_txns ddrwr*]
            delete_hw_axi_txn [get_hw_axi_txns ddrwr*]
            set batch 0
            puts "  DDR load progress: $total_words words"
            flush stdout
        }
    }
    close $file_descriptor

    if {$batch > 0} {
        _rearm_image_load_reset $bram_axi_name $rearm_word
        run_hw_axi [get_hw_axi_txns ddrwr*]
        delete_hw_axi_txn [get_hw_axi_txns ddrwr*]
    }

    puts "Loaded $total_words DDR words in $transaction_number burst transaction(s)"
}
