#!/usr/bin/env python3

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

"""Pack the manual SRST payload with a small, reset-focused device tree.

Use the production firmware, reset binding and image layout. The reduced
platform describes the boot hart, memory, console, CLINT and SYSRESET;
it does not exercise Linux's full tree or interrupt-controller setup.
"""

import importlib.util
from pathlib import Path
import sys
from typing import Any

ROOT = Path(__file__).resolve().parents[3]
PACKER = ROOT / "linux/buildroot-external/board/frost/frost_boot_image.py"
spec = importlib.util.spec_from_file_location("frost_reset_packer", PACKER)
assert spec is not None and spec.loader is not None
packer = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = packer
spec.loader.exec_module(packer)


def gen_reset_dts(*, clk_hz: int, mem_size: int, **unused: Any) -> str:
    """Describe only the devices needed for the S-mode reset call."""
    return f"""/dts-v1/;
/ {{
    #address-cells = <1>;
    #size-cells = <1>;
    compatible = "frost,rv64", "frost";
    model = "FROST SBI reset";
    chosen {{ stdout-path = "/soc/serial@{packer.UART_BASE:x}"; }};
    cpus {{
        #address-cells = <1>;
        #size-cells = <0>;
        timebase-frequency = <{clk_hz}>;
        cpu@0 {{
            device_type = "cpu";
            reg = <0>;
            status = "okay";
            compatible = "riscv";
            riscv,isa = "rv64imafdc_zicsr_zifencei";
            mmu-type = "riscv,sv39";
            cpu_intc: interrupt-controller {{
                #interrupt-cells = <1>;
                interrupt-controller;
                compatible = "riscv,cpu-intc";
            }};
        }};
    }};
    memory@{packer.DDR_BASE:x} {{
        device_type = "memory";
        reg = <0x{packer.DDR_BASE:x} 0x{mem_size:x}>;
    }};
    soc {{
        compatible = "simple-bus";
        #address-cells = <1>;
        #size-cells = <1>;
        ranges;
        serial@{packer.UART_BASE:x} {{
            compatible = "ns16550a";
            reg = <0x{packer.UART_BASE:x} 0x100>;
            reg-shift = <2>;
            reg-io-width = <4>;
            clock-frequency = <{clk_hz}>;
            current-speed = <115200>;
        }};
        clint@{packer.CLINT_BASE:x} {{
            compatible = "sifive,clint0", "riscv,clint0";
            reg = <0x{packer.CLINT_BASE:x} 0xc000>;
            interrupts-extended = <&cpu_intc 3 &cpu_intc 7>;
        }};
        sysreset: syscon@{packer.SYSRESET_BASE:x} {{
            compatible = "frost,sysreset", "syscon";
            reg = <0x{packer.SYSRESET_BASE:x} 0x1000>;
            reg-io-width = <4>;
            reboot {{
                compatible = "syscon-reboot";
                regmap = <&sysreset>;
                offset = <0>;
                value = <0x{packer.SYSRESET_VALUE:x}>;
            }};
        }};
    }};
}};
"""


if __name__ == "__main__":
    packer.gen_dts = gen_reset_dts
    sys.exit(packer.main())
