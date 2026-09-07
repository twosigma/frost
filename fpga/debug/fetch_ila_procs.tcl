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

# Fetch-seam ILA procedures (build.py --debug-ila), shared by the standalone
# capture script and the loader's hooks. They act on an open hardware
# target: the caller has connected and selected the device. Arming, waiting
# and collecting must share one session: refresh_hw_device (which every new
# session performs to see the core) resets an armed ILA.

proc frost_ila_attach {ltx_file} {
    # Attach the probes file and return the ILA (error if none).
    set device [current_hw_device]
    set_property PROBES.FILE $ltx_file $device
    set_property FULL_PROBES.FILE $ltx_file $device
    refresh_hw_device -update_hw_probes true $device
    set ilas [get_hw_ilas -of_objects $device]
    if {[llength $ilas] == 0} {
        error "no ILA on the device (is the --debug-ila bitstream programmed and the ltx right?)"
    }
    return [lindex $ilas 0]
}

proc frost_ila_find_probe {ila glob} {
    set probes [get_hw_probes -of_objects $ila -filter "NAME =~ \"$glob\""]
    if {[llength $probes] != 1} {
        set names [list]
        foreach probe [get_hw_probes -of_objects $ila] { lappend names [get_property NAME $probe] }
        error "probe pattern '$glob' matched [llength $probes] probes; available: [join $names { }]"
    }
    return [lindex $probes 0]
}

proc frost_ila_status {ila} {
    return [report_property -return_string $ila *STATUS*]
}

proc frost_ila_arm {ila fault_probe_glob pc_probe_glob pc_value trigger_position} {
    # A fresh refresh leaves every probe comparing against don't-care; the
    # fault probe and the PC probe carry the trigger.
    set fault_probe [frost_ila_find_probe $ila $fault_probe_glob]
    set pc_probe [frost_ila_find_probe $ila $pc_probe_glob]
    set_property TRIGGER_COMPARE_VALUE eq1'b1 $fault_probe
    set_property TRIGGER_COMPARE_VALUE $pc_value $pc_probe
    set_property CONTROL.TRIGGER_CONDITION AND $ila
    # A basic-trigger core reports some controls as read-only; keep defaults then.
    foreach {name value} [list CONTROL.CAPTURE_MODE ALWAYS CONTROL.WINDOW_COUNT 1] {
        if {[catch {set_property $name $value $ila} note]} {
            puts "note: $name left at default ($note)"
        }
    }
    set_property CONTROL.TRIGGER_POSITION $trigger_position $ila
    run_hw_ila $ila
    puts "ILA armed: [get_property NAME $fault_probe] == 1 AND [get_property NAME $pc_probe] == $pc_value"
    puts [frost_ila_status $ila]
}

proc frost_ila_wait_and_collect {ila csv_file timeout_minutes} {
    # Block in this session until the trigger fires (or the timeout), then
    # write the samples. A fresh Hardware Manager session cannot do this:
    # its device refresh resets the core, so arming, waiting and collecting
    # share one session.
    if {[catch {wait_on_hw_ila -timeout $timeout_minutes $ila} note]} {
        puts "wait_on_hw_ila: $note"
    }
    puts [frost_ila_status $ila]
    set data [upload_hw_ila_data $ila]
    write_hw_ila_data -force -csv_file $csv_file $data
    puts "ILA capture written: $csv_file"
}
