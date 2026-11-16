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

#include <stdint.h>

#include "mmio.h"

extern unsigned long wp_odd_train(unsigned long value);
extern unsigned long wp_odd_overlap(unsigned long value);
extern unsigned long wp_even_train(unsigned long value);
extern unsigned long wp_even_overlap(unsigned long value);
extern unsigned long wp_slot2_below_train(unsigned long value);
extern unsigned long wp_slot2_below_b2_train(unsigned long value);
extern unsigned long wp_slot2_below_overlap(unsigned long value);
extern unsigned long wp_slot2_at_train(unsigned long value);
extern unsigned long wp_slot2_at_b2_train(unsigned long value);
extern unsigned long wp_slot2_at_overlap(unsigned long value);

static void puts_uart(const char *text)
{
    while (*text)
        UART_TX = (uint8_t) *text++;
}

static void hex_uart(unsigned long value)
{
    static const char digits[] = "0123456789abcdef";
    for (int shift = 60; shift >= 0; shift -= 4)
        UART_TX = digits[(value >> shift) & 15];
}

int main(void)
{
    static const char *const labels[4] = {
        "odd RESULT ",
        "even RESULT ",
        "slot2_below RESULT ",
        "slot2_at RESULT ",
    };
    unsigned long results[4][8];
    for (int pass = 0; pass < 8; ++pass) {
        for (int train = 0; train < 4; ++train)
            wp_odd_train(0);
        results[0][pass] = wp_odd_overlap(0);
        for (int train = 0; train < 4; ++train)
            wp_even_train(0);
        results[1][pass] = wp_even_overlap(0);
        for (int train = 0; train < 4; ++train) {
            wp_slot2_below_train(0);
            wp_slot2_below_b2_train(0);
        }
        results[2][pass] = wp_slot2_below_overlap(0);
        for (int train = 0; train < 4; ++train) {
            wp_slot2_at_train(0);
            wp_slot2_at_b2_train(0);
        }
        results[3][pass] = wp_slot2_at_overlap(0);
    }
    int ok = 1;
    for (int kind = 0; kind < 4; ++kind) {
        for (int pass = 0; pass < 8; ++pass) {
            puts_uart(labels[kind]);
            hex_uart(results[kind][pass]);
            puts_uart(" expected 0000000000000011\r\n");
            ok &= results[kind][pass] == 17;
        }
    }
    puts_uart(ok ? "<<PASS>>\r\n" : "<<FAIL>>\r\n");
    for (;;) {
    }
}
