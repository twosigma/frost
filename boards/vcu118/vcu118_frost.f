#    Copyright 2026 John Goodacre
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

# VCU118 board sources

# FROST RISC-V processor core and all submodules
-f $(ROOT)/hw/rtl/frost.f

# Common Xilinx FROST subsystem (JTAG, BRAM controller, CPU)
$(ROOT)/boards/xilinx_frost_subsystem.sv

# VCU118 clock generator (MMCM from SYSCLK1_300)
$(ROOT)/boards/vcu118/vcu118_clock.sv

# VCU118 DDR4 memory region initializer (valid ECC setup)
$(ROOT)/boards/vcu118/vcu118_ddr_init.sv

# VCU118 board top-level wrapper
$(ROOT)/boards/vcu118/vcu118_frost.sv
