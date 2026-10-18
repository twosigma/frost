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

# Places the SRAM macros (MACRO_PLACEMENT_TCL) in three columns of the core.
# The outer columns hold the L2 data, slices 0-3 on the left and 4-7 on the
# right, 8 macros deep each. The center column holds the L1D data at the top,
# a row of four macros for each way; the data memory at the bottom; the L1D
# tags, the L1I data, and the smaller macros above the data memory; and at
# its sides, around the logic, two stacks of L2 tags with the replacement
# state.
#
# Each L2 slice holds 64 bits of every line in a column of eight macros, one
# for each eighth of the {way, set} lines, so a bit's eight-way read
# multiplexer spans one column. A ring of free core around the columns
# carries the wires from the pins on the die's edges to the logic. The core
# is sized for this arrangement (DIE_AREA and CORE_AREA in config.mk), and
# the script fails if a macro is left out or does not fit. Positions are in
# microns from the core's lower-left corner, on the placement site grid.

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
# Space between a column of macros and the next column.
set frost_channel 80.0
# Space between the macros and the core's edges. Without it the pins that
# the I/O placer puts in front of a macro, over a thousand along the bottom
# or the top edge for the DDR port, have to squeeze past its corners, which
# congests global routing there.
set frost_edge 120.0
# Space between the center column's macros and the core's bottom and top
# edges. The I/O placer puts most of the pins, over a thousand, on one of
# those edges in front of the center column, where the logic is, and their
# wires and the logic they reach need the room.
set frost_center_edge 360.0
# Space between the data memory and the smaller macros above it, where the
# wires from the logic below the data memory turn up between those macros;
# with 80 um, global routing overflowed there.
set frost_memory_channel 160.0

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

# Place macros left to right in rows from (x, y) upward, starting a new row
# when the next macro would pass x + width; return the top of the last row.
proc frost_place_rows { macros x y width } {
  set row_x $x
  set row_height 0.0
  foreach inst $macros {
    if { $row_x > $x && $row_x + [frost_width $inst] > $x + $width } {
      set row_x $x
      set y [expr { $y + $row_height + $::frost_gap }]
      set row_height 0.0
    }
    frost_place $inst $row_x $y
    set row_x [expr { $row_x + [frost_width $inst] + $::frost_side_gap }]
    set row_height [expr { max($row_height, [frost_height $inst]) }]
  }
  return [expr { $y + $row_height }]
}

set frost_l2_data [frost_macros {l2_cache\.gen_data_array\.}]
set frost_l2_tags [frost_macros {l2_cache\.gen_tag_ultra\.}]
set frost_l2_plru [frost_macros {l2_cache\.gen_plru\.}]
set frost_l1d_data [frost_macros {l1_cache\.gen_data_banks\.}]
set frost_data_memory [frost_macros {data_memory\.}]
set frost_small_macros [concat \
  [frost_macros {l1_cache\.gen_tag_block\.}] \
  [frost_macros {l1i_cache\.gen_data_banks\.}] \
  [frost_macros {u_[rt]x_fifo\.storage\.}] \
  [frost_macros {btb_payload_ram}]]

set frost_tile_width [frost_width [lindex $frost_l2_data 0]]
set frost_tile_height [frost_height [lindex $frost_l2_data 0]]
set frost_slice_pitch [expr { $frost_tile_width + $frost_side_gap }]
set frost_depth_pitch [expr { $frost_tile_height + $frost_gap }]

# The center column: the two stacks of L2 tags at its sides, and between
# them room for the L1D data's rows of four macros and for two data memory
# macros side by side.
set frost_tag_width [frost_width [lindex $frost_l2_tags 0]]
set frost_tag_height [frost_height [lindex $frost_l2_tags 0]]
set frost_l1d_width [frost_width [lindex $frost_l1d_data 0]]
set frost_l1d_height [frost_height [lindex $frost_l1d_data 0]]
set frost_inner_width [expr { max(4 * $frost_l1d_width + 3 * $frost_side_gap, \
  2 * [frost_width [lindex $frost_data_memory 0]] + $frost_side_gap) }]
set frost_center_x [expr { $frost_edge + 4 * $frost_slice_pitch - $frost_side_gap + \
  $frost_channel }]
set frost_center_width [expr { $frost_inner_width + 2 * $frost_tag_width + \
  2 * $frost_channel }]
set frost_inner_x [expr { $frost_center_x + $frost_tag_width + $frost_channel }]

# L2 data: slice (gen_column) s, eighth of the lines (gen_row) r. Slices 4-7
# end at the ring, and the space that the core has beyond the arrangement's
# width widens the channel to their left.
set frost_right_x [expr { [frost_um [$frost_core dx]] - $frost_edge - \
  4 * $frost_slice_pitch + $frost_side_gap }]
if { $frost_right_x < $frost_center_x + $frost_center_width + $frost_channel } {
  error "the core is too narrow for the SRAM macros; widen CORE_AREA in config.mk"
}
foreach inst $frost_l2_data {
  set slice [frost_index $inst gen_column]
  set row [frost_index $inst gen_row]
  if { $slice < 4 } {
    set x [expr { $frost_edge + $slice * $frost_slice_pitch }]
  } else {
    set x [expr { $frost_right_x + ($slice - 4) * $frost_slice_pitch }]
  }
  frost_place $inst $x [expr { $frost_edge + $row * $frost_depth_pitch }]
}

set frost_l2_top [expr { $frost_edge + 8 * $frost_depth_pitch - $frost_gap }]
if { $frost_l2_top + $frost_edge > [frost_um [$frost_core dy]] } {
  error "the core is too short for the SRAM macros; heighten CORE_AREA in config.mk"
}

# The data memory at the bottom of the center column, two macros wide.
set frost_memory_top [frost_place_rows $frost_data_memory $frost_inner_x $frost_center_edge \
  $frost_inner_width]

# The L1D data at the top of the center column: way (gen_bank) w's bank in
# row w, its 64-bit slices (gen_column) side by side.
set frost_core_height [expr { [frost_um [$frost_core dy]] }]
set frost_l1d_y [expr { $frost_core_height - $frost_center_edge - \
  4 * ($frost_l1d_height + $frost_gap) + $frost_gap }]
foreach inst $frost_l1d_data {
  set way [frost_index $inst gen_bank]
  set slice [frost_index $inst gen_column]
  frost_place $inst [expr { $frost_inner_x + $slice * ($frost_l1d_width + $frost_side_gap) }] \
    [expr { $frost_l1d_y + $way * ($frost_l1d_height + $frost_gap) }]
}

# The L1D tags, the L1I data, the NIC's FIFOs, and the BTB's payload tables in
# rows above the data memory.
set frost_small_y [expr { $frost_memory_top + $frost_memory_channel }]
set frost_small_top [frost_place_rows $frost_small_macros $frost_inner_x $frost_small_y \
  $frost_inner_width]
if { $frost_small_top + $frost_channel > $frost_l1d_y } {
  error "the small macros reach the L1D data; heighten CORE_AREA in config.mk"
}

# The L2 tags in two stacks at the sides of the center column, each a row of
# the tag array (gen_row), its ways (gen_column) one above another, with the
# row's replacement state macro on top.
set frost_tag_y [expr { $frost_core_height / 2 - 2 * ($frost_tag_height + $frost_gap) }]
foreach inst [concat $frost_l2_tags $frost_l2_plru] {
  set side [frost_index $inst gen_row]
  set x [expr { $side == 0 ? $frost_center_x : \
    $frost_center_x + $frost_center_width - $frost_tag_width }]
  if { [lsearch -exact $frost_l2_plru $inst] >= 0 } {
    set level 4
  } else {
    set level [frost_index $inst gen_column]
  }
  frost_place $inst $x [expr { $frost_tag_y + $level * ($frost_tag_height + $frost_gap) }]
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
