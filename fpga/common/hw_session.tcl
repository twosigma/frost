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

# Close this client's connections on both success and Tcl errors. A caller-owned
# hw_server remains alive; stopping that process is the caller's responsibility.
proc frost_hw_session {remote_host server_url target body} {
    set connected 0
    set opened 0
    set status [catch {
        open_hw_manager
        if {$server_url ne ""} {
            if {$remote_host ne ""} {error "remote host and explicit server URL conflict"}
            connect_hw_server -url $server_url
        } elseif {$remote_host ne ""} {
            connect_hw_server -url ${remote_host}:3121
        } else {
            # Preserve the existing interactive CLI's local-server behavior.
            connect_hw_server
        }
        set connected 1
        if {$target ne ""} {
            if {[lsearch -exact [get_hw_targets] $target] < 0} {
                error "Exact hardware target not found: $target"
            }
            current_hw_target $target
            open_hw_target
            set opened 1
            if {[llength [get_hw_devices]] != 1} {
                error "Expected exactly one FPGA device on target $target"
            }
        }
        uplevel 1 $body
    } result options]
    set cleanup_commands {}
    if {$opened} {lappend cleanup_commands close_hw_target}
    if {$connected} {lappend cleanup_commands disconnect_hw_server}
    lappend cleanup_commands close_hw_manager
    foreach command $cleanup_commands {
        if {[catch {$command} cleanup_error]} {
            puts stderr "Error: $command failed: $cleanup_error"
            if {!$status} {set result "Hardware session cleanup failed"}
            set status 1
        }
    }
    if {$status} {
        puts stderr "Error: $result"
        exit 1
    }
}
