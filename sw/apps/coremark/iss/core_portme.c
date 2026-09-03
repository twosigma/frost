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

/* CoreMark port layer for the Spike instruction-count harness.
 *
 * No MMIO and no timer: start_time()/stop_time() each execute one
 * `csrr x0, cycle`, and nothing else in the program touches a CSR, so the
 * commit log can be sliced to exactly the timed region (count_instructions.py).
 * The seed block matches ../core_portme.c so both builds run the same
 * workload; only the port functions differ. */

#include "coremark.h"

#if VALIDATION_RUN
volatile ee_s32 seed1_volatile = 0x3415;
volatile ee_s32 seed2_volatile = 0x3415;
volatile ee_s32 seed3_volatile = 0x66;
#endif
#if PERFORMANCE_RUN
volatile ee_s32 seed1_volatile = 0x0;
volatile ee_s32 seed2_volatile = 0x0;
volatile ee_s32 seed3_volatile = 0x66;
#endif
#if PROFILE_RUN
volatile ee_s32 seed1_volatile = 0x8;
volatile ee_s32 seed2_volatile = 0x8;
volatile ee_s32 seed3_volatile = 0x8;
#endif
volatile ee_s32 seed4_volatile = ITERATIONS;
volatile ee_s32 seed5_volatile = 0;

#define TIMED_REGION_MARKER() __asm__ __volatile__("csrr x0, 0xc00")

ee_u32 default_num_contexts = 1;

void start_time(void)
{
    TIMED_REGION_MARKER();
}

void stop_time(void)
{
    TIMED_REGION_MARKER();
}

CORE_TICKS get_time(void)
{
    return 1;
}

secs_ret time_in_secs(CORE_TICKS ticks)
{
    return (secs_ret) ticks;
}

void portable_init(core_portable *p, int *argc, char *argv[])
{
    (void) argc;
    (void) argv;
    p->portable_id = 1;
}

void portable_fini(core_portable *p)
{
    p->portable_id = 0;
}
