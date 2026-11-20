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

/* The first WFI holds retirement while the direct JAL and its fall-through
 * WFI enter the ROB. The bench wakes the first WFI through APLIC source 2.
 * A timer also lets the program finish when run without the bench. */
#include "aplic.h"
#include "trap.h"
#include "uart.h"

int main(void)
{
    unsigned int fell_through = 0;

    disable_interrupts();
    aplic_enable_machine_source(2);
    enable_external_interrupt();
    enable_timer_interrupt();
    set_timer_cmp(rdmtime() + 1000000);

    __asm__ volatile(".option push\n.option norvc\n"
                     "wfi_recovery_gate: wfi\n"
                     "jal zero, wfi_recovery_target\n"
                     "wfi\n"
                     "li %0, 1\n"
                     "wfi_recovery_target:\n"
                     ".option pop\n"
                     : "+r"(fell_through)
                     :
                     : "memory");

    uart_puts(fell_through ? "<<FAIL>> JAL fell through\n" : "<<PASS>>\n");
    for (;;) {
    }
}
