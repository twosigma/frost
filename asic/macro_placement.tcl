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

# Places the SRAM macros (MACRO_PLACEMENT_TCL) in three bands across the
# core, with the logic in a band between the top two:
#
#   top:    L1I, NIC FIFOs, BTB, RX | L1D data | L1D, L2 tags, NIC TX
#   middle: the logic, with the pins on the core's left and right edges
#   lower:  instruction memory, even parity | odd parity
#   bottom: L2 data, slices 0-3 | data memory | L2 data, slices 4-7
#
# Each L2 slice holds 64 bits of every {way, set} line in one macro. The I/O
# placer keeps the pins off the top and bottom edges (PLACE_PINS_ARGS in
# config.mk). The core is sized for this arrangement (DIE_AREA and CORE_AREA
# in config.mk), and the script fails if a macro is left out or does not
# fit. Positions are in microns from the core's lower-left corner, on the
# placement site grid.

set frost_block [ord::get_db_block]
set frost_dbu [$frost_block getDefUnits]
set frost_core [$frost_block getCoreArea]
set frost_site_width 0.19
set frost_row_height 1.4
# Space above and below a macro: room for the router to reach its edge pins
# and for the buffers on long wires.
set frost_gap 40.0
# Space between macros side by side. The cell rows between two such macros
# get their power from the metal4 straps that cross them, one for each supply
# every 56 um in the platform's grid (grid_strategy-M1-M4-M7.tcl), and each
# macro's grid keeps the straps' vias 2 um away from it. Wider than 56 um
# plus both margins and a strap's width, the space holds a strap of each
# supply wherever the macros fall.
set frost_side_gap 62.0
# Space between a group of macros and the next one.
set frost_channel 80.0
# Space between the macros and the core's edges, which carries the wires
# from the pins past the macros' corners.
set frost_edge 120.0
# The least height that the logic band keeps between the two bands.
set frost_min_logic 600.0

proc frost_um { dbu_value } {
  return [expr { double($dbu_value) / $::frost_dbu }]
}

# The block's macros whose names match a regular expression, in name order.
proc frost_macros { pattern } {
  set matches {}
  foreach inst [$::frost_block getInsts] {
    if { [[$inst getMaster] isBlock] && [regexp -- $pattern [$inst getName]] } {
      lappend matches $inst
    }
  }
  return [lsort -command frost_compare_names $matches]
}

proc frost_compare_names { a b } {
  return [string compare [$a getName] [$b getName]]
}

# The index after a generate block name, such as 3 in "gen_row[3]".
proc frost_index { inst block } {
  if { ![regexp -- "${block}\\\\?\\\[(\[0-9\]+)\\\\?\\\]" [$inst getName] -> index] } {
    error "macro [$inst getName] has no $block index"
  }
  return $index
}

# Order L2 data macros by their slice (gen_column).
proc frost_compare_slices { a b } {
  return [expr { [frost_index $a gen_column] - [frost_index $b gen_column] }]
}

proc frost_width { inst } {
  return [frost_um [[$inst getMaster] getWidth]]
}

proc frost_height { inst } {
  return [frost_um [[$inst getMaster] getHeight]]
}

set frost_placed {}

# Place a macro with its lower-left corner at (x, y) microns from the core's
# corner, snapped down to the site grid, unflipped. The arithmetic is in
# database units, so a macro placed against the core's edge fits exactly.
proc frost_place { inst x y } {
  set site [expr { round($::frost_site_width * $::frost_dbu) }]
  set row [expr { round($::frost_row_height * $::frost_dbu) }]
  set x [expr { round($x * $::frost_dbu) / $site * $site }]
  set y [expr { round($y * $::frost_dbu) / $row * $row }]
  set master [$inst getMaster]
  if { $x < 0 || $y < 0 || $x + [$master getWidth] > [$::frost_core dx] || \
       $y + [$master getHeight] > [$::frost_core dy] } {
    error "macro [$inst getName] at ([frost_um $x], [frost_um $y]) does not fit in the core"
  }
  $inst setOrient R0
  $inst setLocation [expr { [$::frost_core xMin] + $x }] [expr { [$::frost_core yMin] + $y }]
  $inst setPlacementStatus FIRM
  lappend ::frost_placed $inst
}

# Place macros in a grid of columns from (x, y): the i-th macro in column
# i modulo columns and row i divided by columns, counted from the bottom.
proc frost_place_grid { macros x y columns } {
  set i 0
  foreach inst $macros {
    set column [expr { $i % $columns }]
    set row [expr { $i / $columns }]
    frost_place $inst [expr { $x + $column * ([frost_width $inst] + $::frost_side_gap) }] \
      [expr { $y + $row * ([frost_height $inst] + $::frost_gap) }]
    incr i
  }
}

# Place macros of any widths side by side from (x, y), left to right.
proc frost_place_row { macros x y } {
  foreach inst $macros {
    frost_place $inst $x $y
    set x [expr { $x + [frost_width $inst] + $::frost_side_gap }]
  }
}

# The width and height of such a row.
proc frost_row_width { macros } {
  set width [expr { -$::frost_side_gap }]
  foreach inst $macros {
    set width [expr { $width + [frost_width $inst] + $::frost_side_gap }]
  }
  return $width
}

proc frost_row_height { macros } {
  set height 0.0
  foreach inst $macros {
    set height [expr { max($height, [frost_height $inst]) }]
  }
  return $height
}

# The width and height of such a grid of equal macros.
proc frost_grid_width { macros columns } {
  return [expr { $columns * [frost_width [lindex $macros 0]] + \
    ($columns - 1) * $::frost_side_gap }]
}

proc frost_grid_height { macros columns } {
  set rows [expr { ([llength $macros] + $columns - 1) / $columns }]
  return [expr { $rows * [frost_height [lindex $macros 0]] + ($rows - 1) * $::frost_gap }]
}

set frost_l2_data [lsort -command frost_compare_slices \
  [frost_macros {home\.array\.data_array\.}]]
set frost_l2_tags [frost_macros {home\.array\.gen_tag_ultra\.}]
set frost_data_memory [frost_macros {data_memory\.}]
set frost_l1d_data [frost_macros {l1d\.array\.data_array\.}]
set frost_l1d_tags [frost_macros {l1d\.array\.gen_tag_block\.}]
set frost_l1i_data [frost_macros {l1i\.gen_data_banks\.}]
set frost_nic [frost_macros {u_[rt]x_fifo\.storage\.}]
set frost_nic_rx [frost_macros {mac_rx\.g_memory_lane}]
set frost_nic_tx [frost_macros {mac_tx\.u_frame_memory\.}]
set frost_btb [frost_macros {btb_payload_ram}]
# Each parity's instruction memory banks, two macros a bank: the cold bank's,
# then the frontend-hot bank's, then the compressed bank's.
proc frost_imem_parity { parity } {
  set macros {}
  foreach bank {cold frontend_hot compressed} {
    lappend macros {*}[frost_macros "instruction_memory\\.u_${parity}_${bank}\\."]
  }
  return $macros
}
set frost_imem_even [frost_imem_parity even]
set frost_imem_odd [frost_imem_parity odd]

set frost_core_width [frost_um [$frost_core dx]]
set frost_core_height [frost_um [$frost_core dy]]

# The bottom band: the L2 data's slices (gen_column) 0-3 and 4-7 in two
# blocks of two by two, and the data memory's rows between them.
set frost_l2_width [frost_grid_width [lrange $frost_l2_data 0 3] 2]
set frost_memory_x [expr { $frost_edge + $frost_l2_width + $frost_channel }]
set frost_right_x [expr { $frost_memory_x + [frost_grid_width $frost_data_memory 2] + \
  $frost_channel }]
if { $frost_right_x + $frost_l2_width + $frost_edge > $frost_core_width } {
  error "the core is too narrow for the SRAM macros; widen CORE_AREA in config.mk"
}
frost_place_grid [lrange $frost_l2_data 0 3] $frost_edge $frost_edge 2
frost_place_grid $frost_data_memory $frost_memory_x $frost_edge 2
frost_place_grid [lrange $frost_l2_data 4 7] $frost_right_x $frost_edge 2
set frost_bottom_top [expr { $frost_edge + max([frost_grid_height $frost_data_memory 2], \
  [frost_grid_height [lrange $frost_l2_data 0 3] 2]) }]

# The lower band, a channel above the bottom band: the instruction memory's
# even parity at the left and its odd parity, in mirror order, at the right,
# centered.
set frost_imem_even_width [frost_row_width $frost_imem_even]
set frost_imem_width [expr { $frost_imem_even_width + $frost_channel + \
  [frost_row_width $frost_imem_odd] }]
set frost_imem_x [expr { ($frost_core_width - $frost_imem_width) / 2 }]
if { $frost_imem_x < $frost_edge } {
  error "the core is too narrow for the instruction memory's macros; widen CORE_AREA in config.mk"
}
set frost_imem_y [expr { $frost_bottom_top + $frost_channel }]
frost_place_row $frost_imem_even $frost_imem_x $frost_imem_y
frost_place_row [lreverse $frost_imem_odd] \
  [expr { $frost_imem_x + $frost_imem_even_width + $frost_channel }] $frost_imem_y
set frost_bottom_top [expr { $frost_imem_y + max([frost_row_height $frost_imem_even], \
  [frost_row_height $frost_imem_odd]) }]

# The top band: the L1D data in the middle, four 64-bit slices in a two by
# two grid; at the left the L1I data, four banks of four slices, then the
# NIC's FIFOs, the BTB's payload tables and the MAC's
# receive lanes; at the right the L1D tags, the L2 tags and the MAC's transmit
# frame buffer.
set frost_l1d_width [frost_grid_width $frost_l1d_data 2]
set frost_l1d_x [expr { ($frost_core_width - $frost_l1d_width) / 2 }]
set frost_l1d_y [expr { $frost_core_height - $frost_edge - \
  [frost_grid_height $frost_l1d_data 2] }]
frost_place_grid $frost_l1d_data $frost_l1d_x $frost_l1d_y 2

set frost_left_y [expr { $frost_core_height - $frost_edge - \
  [frost_grid_height $frost_l1i_data 4] }]
frost_place_grid $frost_l1i_data $frost_edge $frost_left_y 4
set frost_left_y [expr { $frost_left_y - $frost_gap - [frost_grid_height $frost_nic 2] }]
frost_place_grid $frost_nic $frost_edge $frost_left_y 2
set frost_left_y [expr { $frost_left_y - $frost_gap - [frost_grid_height $frost_btb 3] }]
frost_place_grid $frost_btb $frost_edge $frost_left_y 3
set frost_left_y [expr { $frost_left_y - $frost_gap - [frost_grid_height $frost_nic_rx 4] }]
frost_place_grid $frost_nic_rx $frost_edge $frost_left_y 4
set frost_left_width [expr { max([frost_grid_width $frost_l1i_data 4], \
  [frost_grid_width $frost_nic 2], [frost_grid_width $frost_btb 3], \
  [frost_grid_width $frost_nic_rx 4]) }]

set frost_right_width [expr { max([frost_grid_width $frost_l1d_tags 2], \
  [frost_grid_width $frost_l2_tags 2], [frost_grid_width $frost_nic_tx 1]) }]
set frost_tags_x [expr { $frost_core_width - $frost_edge - $frost_right_width }]
set frost_right_y [expr { $frost_core_height - $frost_edge - \
  [frost_grid_height $frost_l1d_tags 2] }]
frost_place_grid $frost_l1d_tags $frost_tags_x $frost_right_y 2
set frost_right_y [expr { $frost_right_y - $frost_gap - [frost_grid_height $frost_l2_tags 2] }]
frost_place_grid $frost_l2_tags $frost_tags_x $frost_right_y 2
set frost_right_y [expr { $frost_right_y - $frost_gap - [frost_grid_height $frost_nic_tx 1] }]
frost_place_grid $frost_nic_tx $frost_tags_x $frost_right_y 1

if { $frost_edge + $frost_left_width + $frost_channel > $frost_l1d_x || \
     $frost_l1d_x + $frost_l1d_width + $frost_channel > $frost_tags_x } {
  error "the top band's macros overlap; widen CORE_AREA in config.mk"
}
if { min($frost_l1d_y, $frost_left_y, $frost_right_y) - $frost_bottom_top < \
     $frost_min_logic } {
  error "the logic band is too low; heighten CORE_AREA in config.mk"
}

# Every macro in the design has a place.
set frost_macro_count 0
foreach inst [$frost_block getInsts] {
  if { [[$inst getMaster] isBlock] } {
    incr frost_macro_count
    if { [lsearch -exact $frost_placed $inst] < 0 } {
      error "macro [$inst getName] has no place in asic/macro_placement.tcl"
    }
  }
}
puts "Placed $frost_macro_count SRAM macros"
