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

# Yosys commands that ORFS runs after elaborating the design
# (SYNTH_CANONICALIZE_TCL).

# Keep the 10G RX parser's state encoding, as tests/test_run_yosys.py does:
# FSM recoding would expand its symbolic transitions into a table.
setattr -set fsm_encoding {"none"} *eth10g_mac_rx*/w:state

# The data memory (tdp_bram_dc_byte_en) is written from two clocks: the
# program-loading port on i_clk_div4 and the core's port on i_clk. Flip-flops
# have one clock each, so Yosys cannot map that memory to standard cells, even
# mocked as one row; it needs a two-port SRAM macro. Until it has one, its
# programming port runs on i_clk in this flow. That port's paths to and from
# the i_clk_div4 logic then get one core clock cycle (3.103 ns at the default
# period) where the design gives them a quarter-rate cycle, four core cycles.
# connect edits only modules without processes; synthesis would run proc next.
yosys proc cpu_and_mem
yosys cd cpu_and_mem
yosys connect -port data_memory i_port_a_clk i_clk
yosys cd
