/*
 *    Copyright 2026 Two Sigma Open Source, LLC
 *
 *    Licensed under the Apache License, Version 2.0 (the "License");
 *    you may not use this file except in compliance with the License.
 *    You may obtain a copy of the License at
 *
 *        http://www.apache.org/licenses/LICENSE-2.0
 *
 *    Unless required by applicable law or agreed to in writing, software
 *    distributed under the License is distributed on an "AS IS" BASIS,
 *    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *    See the License for the specific language governing permissions and
 *    limitations under the License.
 */

/*
 * Prints the FPGA_CPU_CLK_FREQ build parameter over UART: a smoke check that
 * the parameter is set and UART output works.
 */

#include "uart.h"

int main(void)
{
    uart_printf("FPGA Clock Frequency: %u Hz\n", FPGA_CPU_CLK_FREQ);
    uart_printf("<<PASS>>\n");

    for (;;) {
    }
}
