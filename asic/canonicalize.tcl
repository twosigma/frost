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
