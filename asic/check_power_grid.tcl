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

# Runs after the power grid (POST_PDN_TCL) and fails the floorplan if a
# placed instance or a grid shape is not connected to its supply's pins: an
# SRAM macro, or a tap or end cap in a row that the macros cut off from the
# grid's straps. The cells placed later in a row connect through its rails.
# The final report's IR drop analysis would otherwise fail on the same fault
# after the whole flow.
foreach frost_supply {VDD VSS} {
  check_power_grid -net $frost_supply
}
