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

# Write the 32-bit words of sw_ddr.txt, one per line, to consecutive DDR
# addresses from region offset zero through the DDR JTAG-AXI master, in AXI4
# INCR bursts of up to burst_words words rather than one transaction per word.
#
# Addresses are region-relative: zero maps to CPU address 0x8000_0000, the
# 1 GiB cached-region base. Low-BRAM writes hold the CPU in image reset, and
# the reset clears the caches, so no stale line hides the new DDR data.
#
# The image reset releases the CPU a fixed time after the last low-BRAM write
# (about 1.7 s at full rate), and a multi-MB DDR load takes longer. So a write
# through bram_axi_name re-arms the reset before each batch of bursts, and the
# CPU never runs a partial image while the DDR master (SmartConnect S01) is
# still loading.

# Re-arm the image reset by writing rearm_word to BRAM address zero. Does
# nothing without a BRAM master.
proc _rearm_image_load_reset {bram_axi_name rearm_word} {
    if {$bram_axi_name eq ""} return
    create_hw_axi_txn rstkeep [get_hw_axis $bram_axi_name] \
        -type write -address 0x00000000 -len 1 -data $rearm_word
    run_hw_axi [get_hw_axi_txns rstkeep]
    delete_hw_axi_txn [get_hw_axi_txns rstkeep]
}

proc file2ddr {firmware_filename {axi_interface_name hw_axi_2} {burst_words 256} {bram_axi_name ""} {rearm_word "00000000"}} {

    set file_descriptor [open $firmware_filename r]

    # Read one burst of words at a time: indexing word by word into a list of
    # the whole multi-MB file is far slower. Running and deleting transactions
    # in batches also bounds how many exist at once.
    set axi [get_hw_axis $axi_interface_name]
    set current_address 0
    set transaction_number 0
    set total_words 0
    set batch 0
    set batch_limit 128  ;# keeps each blocking run_hw_axi well under the image-reset interval

    while {1} {
        # Skip blanks so nonblank word N remains at offset N.
        set chunk [list]
        for {set i 0} {$i < $burst_words} {incr i} {
            if {[gets $file_descriptor word_hex_value] < 0} { break }
            set trimmed [string trim $word_hex_value]
            if {$trimmed ne ""} { lappend chunk $trimmed }
        }
        set beats [llength $chunk]
        if {$beats == 0} { break }

        # hw_axi puts beat zero in the least-significant word.
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
            # Re-arm right before the blocking run_hw_axi, the only slow step.
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
