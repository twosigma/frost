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

#ifndef TIMER_H
#define TIMER_H

#include "csr.h"
#include <stdint.h>

#ifndef FPGA_CPU_CLK_FREQ
#define FPGA_CPU_CLK_FREQ 100000000 /* Default 100MHz, override in makefile */
#endif

/**
 * Read the low 32 bits of the cycle counter CSR (Zicntr extension)
 *
 * Reads the CSR rather than an MMIO timer register, so it costs one
 * instruction. read_timer64() returns the full 64-bit counter.
 */
static inline __attribute__((always_inline)) uint32_t read_timer(void)
{
    return rdcycle();
}

/**
 * Read full 64-bit cycle count from CSR (Zicntr extension)
 *
 * Use this for long-running benchmarks to avoid 32-bit overflow.
 * At 300 MHz, 32-bit overflows in ~14 seconds; 64-bit lasts ~1900 years.
 */
static inline __attribute__((always_inline)) uint64_t read_timer64(void)
{
    return rdcycle64();
}

/**
 * Busy-wait for the given number of clock ticks
 */
static inline void delay_ticks(uint32_t number_of_ticks)
{
    uint32_t timer_start_value = read_timer();
    while ((uint32_t) (read_timer() - timer_start_value) < number_of_ticks)
        ;
}

/**
 * Delay for approximately 1 second (exact timing depends on FPGA_CPU_CLK_FREQ)
 */
static inline void delay_1_second(void)
{
    delay_ticks(FPGA_CPU_CLK_FREQ);
}

#endif /* TIMER_H */
