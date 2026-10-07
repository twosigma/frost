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

# Post-route fallback for a CPU clock group whose worst paths remain tied.
# Giving each near-critical endpoint its own objective lets phys-opt retain
# improvements away from the one path that defines the clock group's WNS.
namespace eval frost_x3_endpoint_physopt {
    proc run {kind sweep_uncertainty} {
        if {$kind ni {EndpointAggressive EndpointTargeted}} {
            error "Unknown endpoint optimization pass: $kind"
        }
        set clk [get_clocks -quiet clock_from_mmcm]
        if {[llength $clk] != 1} {
            error "Endpoint optimization requires exactly one CPU clock"
        }
        if {![string is double -strict $sweep_uncertainty] || $sweep_uncertainty < 0} {
            error "Endpoint optimization requires a nonnegative setup uncertainty"
        }
        set paths [get_timing_paths -quiet -group clock_from_mmcm \
            -delay_type max -slack_lesser_than 0.005 -max_paths 600 -nworst 1]
        if {![llength $paths]} {
            puts "FROST_ENDPOINT_PHYSOPT $kind: no near-critical CPU endpoints"
            return 0
        }
        set ports [frost_x3_local_placement::port_constraints]
        set endpoints [dict create]
        set index 0
        try {
            foreach path $paths {
                set endpoint [get_property ENDPOINT_PIN $path]
                set name frost_endpoint_physopt_[incr index]
                if {[llength [get_timing_paths -quiet -group $name -max_paths 1]]} {
                    error "Endpoint optimization would overwrite active group $name"
                }
                group_path -name $name -from $clk -to $endpoint
                dict set endpoints $name [get_property NAME $endpoint]
            }
            puts "FROST_ENDPOINT_PHYSOPT $kind: [dict size $endpoints] endpoint groups"
            set_x3_setup_uncertainty x3 [expr {$sweep_uncertainty + 0.030}] \
                "$kind temporary margin"
            if {$kind eq "EndpointAggressive"} {
                phys_opt_design -directive AggressiveExplore -path_groups [dict keys $endpoints]
            } else {
                phys_opt_design -critical_cell_opt -critical_pin_opt \
                    -routing_opt -placement_opt -path_groups [dict keys $endpoints]
            }
        } finally {
            # Vivado removes a group only with the same from/to expression
            # that created it. A clock-to-clock default does not remove these
            # endpoint-specific groups. Restore the scoring uncertainty even
            # if removing a group fails; no checkpoint is accepted on error.
            try {
                dict for {name endpoint_name} $endpoints {
                    set endpoint [frost_x3_local_placement::exact_objects \
                        get_pins [list $endpoint_name]]
                    if {[llength $endpoint] != 1} {
                        error "Endpoint disappeared during optimization: $endpoint_name"
                    }
                    group_path -default -from $clk -to $endpoint
                }
                foreach name [dict keys $endpoints] {
                    if {[llength [get_timing_paths -quiet -group $name -max_paths 1]]} {
                        error "Temporary endpoint group still owns paths: $name"
                    }
                }
            } finally {
                set_x3_setup_uncertainty x3 $sweep_uncertainty "$kind scoring"
            }
        }
        if {[frost_x3_local_placement::port_constraints] ne $ports} {
            error "Endpoint optimization changed board port constraints"
        }
        return 1
    }

    proc candidate_is_legal {timing_file route_file} {
        set fh [open $timing_file]
        set timing [string map {| " "} [read $fh]]
        close $fh
        # Read the whole-design row, after temporary groups and the added
        # margin have been removed. Setup improvement is scored by the caller.
        if {![regexp {WNS\(ns\)[^\n]*\n[^\n]*\n\s*([-0-9.]+)\s+([-0-9.]+)\s+(\d+)\s+(\d+)\s+([-0-9.]+)\s+([-0-9.]+)\s+(\d+)\s+(\d+)\s+([-0-9.]+)\s+([-0-9.]+)\s+(\d+)\s+(\d+)} $timing -> wns tns sf se whs ths hf he wpws tpws pf pe]} {
            error "Missing whole-design setup/hold/pulse-width summary: $timing_file"
        }
        set fh [open $route_file]
        set route [read $fh]
        close $fh
        foreach {key pattern} {
            errors {# of nets with routing errors\.+\s*:\s*(\d+)}
            routable {# of routable nets\.+\s*:\s*(\d+)}
            routed {# of fully routed nets\.+\s*:\s*(\d+)}
        } {
            if {![regexp $pattern $route -> $key]} {
                error "Missing route status $key: $route_file"
            }
        }
        set valid [expr {$whs >= 0 && $ths >= 0 && $hf == 0 &&
            $wpws >= 0 && $tpws >= 0 && $pf == 0 &&
            $errors == 0 && $routable > 0 && $routed == $routable}]
        puts "FROST_ENDPOINT_PHYSOPT legal=$valid WHS=$whs THS=$ths WPWS=$wpws routing_errors=$errors fully_routed=$routed/$routable"
        return $valid
    }
}
