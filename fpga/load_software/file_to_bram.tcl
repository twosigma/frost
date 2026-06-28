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

# ---------------------------------------------------------------
# file2bram.tcl - Load firmware file into FPGA BRAM via AXI4-Lite
# ---------------------------------------------------------------
# Reads hex file (one 32-bit word per line) and writes to BRAM through
# JTAG-to-AXI bridge. Used for loading software without reprogramming FPGA.

proc _file2bram_rearm_image_load_reset {axi_interface_name base_memory_address rearm_word} {
    set old_txn [get_hw_axi_txns -quiet bramrstkeep]
    if {[llength $old_txn] > 0} {
        delete_hw_axi_txn $old_txn
    }
    create_hw_axi_txn bramrstkeep [get_hw_axis $axi_interface_name] \
        -type write -address [format 0x%08x $base_memory_address] -len 1 -data $rearm_word
    run_hw_axi [get_hw_axi_txns bramrstkeep]
    delete_hw_axi_txn [get_hw_axi_txns bramrstkeep]
}

proc file2bram {base_memory_address firmware_filename {axi_interface_name hw_axi_1} {batch_limit 64}} {

    # Open firmware file (text format: 8 hex digits per line)
    set file_descriptor [open $firmware_filename r]
    set current_address $base_memory_address
    set transaction_number 0
    set batch_word_count 0
    set total_words 0
    set first_word ""

    # Read file line by line - each line is one 32-bit word in hexadecimal.
    # Run bounded batches so the hardware image-load reset one-shot cannot
    # expire while Vivado is blocked inside one very large run_hw_axi call.
    while {[gets $file_descriptor word_hex_value] >= 0} {
        set word_hex_value [string trim $word_hex_value]
        if {$word_hex_value eq ""} {
            continue
        }
        if {$first_word eq ""} {
            set first_word $word_hex_value
        }

        set formatted_address [format 0x%08x $current_address]
        create_hw_axi_txn bramwr$batch_word_count [get_hw_axis $axi_interface_name] \
            -type write -address $formatted_address -len 1 -data $word_hex_value
        incr batch_word_count
        incr transaction_number
        incr total_words
        incr current_address 4

        if {$batch_word_count >= $batch_limit} {
            run_hw_axi [get_hw_axi_txns bramwr*]
            delete_hw_axi_txn [get_hw_axi_txns bramwr*]
            set batch_word_count 0
            if {$first_word ne ""} {
                _file2bram_rearm_image_load_reset $axi_interface_name $base_memory_address $first_word
            }
        }
    }
    close $file_descriptor

    if {$batch_word_count > 0} {
        run_hw_axi [get_hw_axi_txns bramwr*]
        delete_hw_axi_txn [get_hw_axi_txns bramwr*]
    }

    puts "Loaded $total_words words starting at [format 0x%08x $base_memory_address] in bounded batches"
}
