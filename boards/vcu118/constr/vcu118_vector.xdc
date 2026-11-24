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
#
# Optional vector-unit floorplan for AMD/Xilinx VCU118 (applied after vcu118.xdc
# when FROST_VECTOR=1). Place the whole vector-unit hierarchy (including its
# register file) in SLR1; the rest of the core stays in pblock_slr2 (SLR2).
create_pblock pblock_vec_slr1
resize_pblock pblock_vec_slr1 -add {SLR1}
remove_cells_from_pblock [get_pblocks pblock_slr2] [get_cells -quiet -hierarchical -filter {
    NAME =~ "u_frost_subsystem/*gen_vector_unit.u_vec_unit" && !IS_PRIMITIVE
}]
add_cells_to_pblock [get_pblocks pblock_vec_slr1] [get_cells -quiet -hierarchical -filter {
    NAME =~ "u_frost_subsystem/*gen_vector_unit.u_vec_unit" && !IS_PRIMITIVE
}]
