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
 * FROST simulation-only FP32 LINPACK reference data.
 *
 * CoreMark-PRO's smallest upstream FP32 PGO preset is n=50, ntimes=10. This
 * local preset keeps the benchmark verified but uses n=10, ntimes=1 so the
 * cycle-accurate cocotb run stays short. Hardware builds use the official
 * upstream reference file instead.
 */

/* th_lib.h must precede linpack.h: the upstream header uses the MITH types
 * (e_u32, e_fp) without including them itself. */
#include "th_lib.h"

#include "linpack.h"

static linpack_params in_data[NUM_DATAS] = {
    [5] = {11,
           10,
           1,
           73686179,
           0,
           NULL,
           NULL,
           NULL,
           NULL,
           NULL,
           {0, 0, 0x00000000, 0x00800000},
           {0, 0, 0x00000000, 0x00800000},
           {0, -23, 0x00000000, 0x00f80000},
           {0, -23, 0x00000000, 0x00800000},
           {0, 0, 0x00000000, 0x00800000},
           {0, 0, 0x00000000, 0x00800000},
           {0, -3, 0x00000000, 0x00dfc1a4},
           0,
           0,
           0x00000fff,
           NULL,
           MIN_ACC_BITS_FP,
           0.0,
           0.0,
           0.0,
           0.0,
           0.0,
           0.0,
           0.0},
};

void init_presets_linpack(void)
{
    int idx;

    for (idx = 0; idx < NUM_DATAS; idx++) {
        th_memcpy(&presets_linpack[idx], &in_data[idx], sizeof(linpack_params));
        presets_linpack[idx].ref_data = &in_data[idx];
    }
}
