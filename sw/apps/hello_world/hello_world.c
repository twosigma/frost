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

/**
 * Hello world: UART and cycle-counter smoke test.
 *
 * Prints a greeting once a second with uart_printf, waits with
 * delay_1_second(), and reports the cycle-counter delta between iterations,
 * which should track FPGA_CPU_CLK_FREQ. A good first program to run when
 * bringing up new hardware.
 */

#include <stdint.h>

#include "timer.h"
#include "uart.h"

int main(void)
{
    uint32_t timer_value_last_iteration = read_timer();
    uint32_t seconds_elapsed = 0;

    for (;;) {
        uart_printf("[%6lu s] Frost: Hello, world!\n", (unsigned long) seconds_elapsed);

        delay_1_second();

        uint32_t timer_value_now = read_timer();
        uint32_t timer_ticks_delta = timer_value_now - timer_value_last_iteration;
        timer_value_last_iteration = timer_value_now;
        ++seconds_elapsed;

        uart_printf(
            "Δticks = %lu (expect ≈ %u)\n", (unsigned long) timer_ticks_delta, FPGA_CPU_CLK_FREQ);
    }
}
