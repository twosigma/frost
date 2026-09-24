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
Copyright 2018 Embedded Microprocessor Benchmark Consortium (EEMBC)

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

Original Author: Shay Gal-on
*/

#include "coremark.h"

#include "timer.h"
#define TOMASULO_PROFILE_USE_DEFAULT_REPORT_SNAPSHOTS 1
#include "tomasulo_profile.h"

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
/* Timing: ticks are CPU cycles from the cycle counter, and EE_TICKS_PER_SEC is
 * FPGA_CPU_CLK_FREQ. TIMER_RES_DIVIDER must stay 1: GETMYTIME returns undivided
 * cycles, and only EE_TICKS_PER_SEC is divided by it. */
#define NSECS_PER_SEC FPGA_CPU_CLK_FREQ * 1ULL
#define CORETIMETYPE uint64_t
#define GETMYTIME(_t) (*_t = read_timer64())
#define MYTIMEDIFF(fin, ini) ((fin) - (ini))
#define TIMER_RES_DIVIDER 1
#define SAMPLE_TIME_IMPLEMENTATION 1
#define EE_TICKS_PER_SEC (NSECS_PER_SEC / TIMER_RES_DIVIDER)

/* Cycle counts at the start and end of the timed region, and the profiling
 * snapshots taken around them. */
static CORETIMETYPE start_time_val, stop_time_val;
tomasulo_profile_snapshot_t tomasulo_profile_default_report_start;
tomasulo_profile_snapshot_t tomasulo_profile_default_report_end;

/* Called right before the timed region. The profiling snapshot is taken before
 * the cycle read here and after it in stop_time(), so neither snapshot counts
 * toward the timed cycles. */
void start_time(void)
{
    tomasulo_profile_take_snapshot(&tomasulo_profile_default_report_start);
    GETMYTIME(&start_time_val);
}
/* Called right after the timed region. */
void stop_time(void)
{
    GETMYTIME(&stop_time_val);
    tomasulo_profile_take_snapshot(&tomasulo_profile_default_report_end);
}
/* Return the timed region's length in CPU cycles. */
CORE_TICKS
get_time(void)
{
    CORE_TICKS elapsed = (CORE_TICKS) (MYTIMEDIFF(stop_time_val, start_time_val));
    return elapsed;
}
/* Convert cycles to seconds at FPGA_CPU_CLK_FREQ. */
secs_ret time_in_secs(CORE_TICKS ticks)
{
#if HAS_FLOAT
    uint64_t ticks_per_sec = EE_TICKS_PER_SEC;
    if (ticks_per_sec == 0)
        ticks_per_sec = 1; /* Guard against FPGA_CPU_CLK_FREQ=0 */

    uint64_t whole_secs = ticks / ticks_per_sec;
    uint32_t rem_ticks = (uint32_t) (ticks % ticks_per_sec);
    uint32_t denom_ticks = (uint32_t) ticks_per_sec;

    float frac = 0.0f;
    if (denom_ticks != 0) {
        float rem_f = (float) rem_ticks;
        float denom_f = (float) denom_ticks;
        frac = rem_f / denom_f;
    }

    return (secs_ret) whole_secs + (secs_ret) frac;
#else
    /* Divide in 32 bits: shifting both values right by 20 bits keeps enough
     * precision for whole seconds. */
    ee_u32 ticks_shifted = (ee_u32) (ticks >> 20);
    ee_u32 divisor_shifted = (ee_u32) (EE_TICKS_PER_SEC >> 20);
    if (divisor_shifted == 0)
        divisor_shifted = 1; /* Prevent div-by-zero for very low clocks */
    return (secs_ret) (ticks_shifted / divisor_shifted);
#endif
}

ee_u32 default_num_contexts = 1;

/* Print the run configuration and check the port's type sizes. */
void portable_init(core_portable *p, int *argc, char *argv[])
{
    ee_printf("\nBaremetal Coremark %d iterations, assuming %d Hz FPGA clock.\n",
              ITERATIONS,
              NSECS_PER_SEC);
    ee_printf("Adjust FPGA_CPU_CLK_FREQ in Makefile if clock frequency differs.\n");
    ee_printf("Expect a run time of at least 10 seconds before result printed.\n");
    ee_printf("Increase ITERATIONS in the Makefile if CPU is too fast.\n");

    (void) argc; // prevent unused warning
    (void) argv; // prevent unused warning

    if (sizeof(ee_ptr_int) != sizeof(ee_u8 *)) {
        ee_printf("ERROR! Please define ee_ptr_int to a type that holds a "
                  "pointer!\n");
    }
    if (sizeof(ee_u32) != 4) {
        ee_printf("ERROR! Please define ee_u32 to a 32b unsigned type!\n");
    }
    p->portable_id = 1;
}
/* Print the tick count and the profiling report, then <<PASS>> if no CRC check
 * failed or <<FAIL>> otherwise. */
void portable_fini(core_portable *p)
{
    /* Get back to the containing core_results struct to check err field */
    core_results *res = (core_results *) ((char *) p - offsetof(core_results, port));

    p->portable_id = 0;
    /* fpga/hw_regression.py computes the score from this line; keep its format. */
    ee_printf("Total 64-bit ticks : %llu\n", (unsigned long long) (stop_time_val - start_time_val));
    ee_printf("To calculate Coremark score: ITERATIONS*FPGA_CPU_CLK_FREQ/(Total 64-bit ticks)\n");
    tomasulo_profile_print_report("CoreMark timed region",
                                  &tomasulo_profile_default_report_start,
                                  &tomasulo_profile_default_report_end);
    if (res->err == 0) {
        ee_printf("<<PASS>>\n");
    } else {
        ee_printf("<<FAIL>>\n");
    }
}
