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
 * FROST simulation-only zip benchmark shim.
 *
 * The upstream PGO-small zip input is only 1000 bytes, but zlib's default
 * compression settings still take the slow deflate path. For cocotb, compile
 * zlib with FASTEST and force a 100-byte generated input with fixed expected
 * compressed length and CRC. Hardware builds compile the official source.
 */

#define define_params_zip frost_zip_define_params_upstream
#include "coremark-pro/benchmarks/darkmark/zip/zip_darkmark.c"
#undef define_params_zip

void *define_params_zip(unsigned int idx, char *name, char *dataset)
{
    e_u32 saved_pgo_training_run = pgo_training_run;
    zip_params *params;

    (void) idx;
    (void) dataset;

    pgo_training_run = 0;
    params = (zip_params *) frost_zip_define_params_upstream(0, name, "-n=100-t=2-s40-g1");
    pgo_training_run = saved_pgo_training_run;

    params->expected_result = 83;
    params->expected_crc = 0x5def;
    params->gen_ref = 0;
    return params;
}
