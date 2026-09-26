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
 * PASS/FAIL bridge for running CoreMark-PRO workloads on FROST.
 *
 * The CoreMark-PRO workload entry (e.g. workloads/core/core.c) calls
 * mith_main(), which runs and verifies the workload, prints the score, and
 * returns. The workload's main() then returns 0 unconditionally (it discards
 * the harness result) and never calls exit(). Some workloads also print error
 * lines without incrementing MITH's per-item ->failed counter. On FROST, crt0
 * spins after main() returns, so nothing would ever print the "<<PASS>>" or
 * "<<FAIL>>" marker that the simulation and board harnesses watch for.
 *
 * Interposing the harness entry point avoids forking the upstream
 * (EEMBC-licensed) workload source. mith_lib.c is compiled with
 * -Dmith_main=mith_main_real (see the Makefile), so the real harness routine is
 * exported as mith_main_real(). The FROST-specific mith_main() below wraps it.
 * It runs the real harness, then inspects each work item's verification result
 * and the FROST AL's benchmark-error latch, and exits with 0 (all checks clean)
 * or 1 (an item failed or an error line was printed). al_frost.c's exit() turns
 * that into the "<<PASS>>" / "<<FAIL>>" UART marker.
 *
 * This file is compiled against the MITH headers and types, not the FROST
 * sw/lib headers. exit() is declared by the toolchain's <stdlib.h> and defined
 * in al_frost.c; the link resolves it.
 */

#include <stdlib.h> /* exit */

#include "mith_workload.h"
#include "th_lib.h"

/* The real harness entry, renamed in mith_lib.o via -Dmith_main=mith_main_real. */
extern int mith_main_real(ee_workload *workload,
                          unsigned int num_iterations,
                          unsigned int num_contexts,
                          Bool oversubscribe_allowed,
                          unsigned int num_workers);

extern void frost_coremark_pro_clear_error(void);
extern int frost_coremark_pro_error_seen(void);
extern void frost_coremark_pro_install_trap_handler(void);
extern void frost_coremark_pro_trace(const char *s);

#ifndef COREMARK_PRO_TRACE
#define COREMARK_PRO_TRACE 0
#endif

int mith_main(ee_workload *workload,
              unsigned int num_iterations,
              unsigned int num_contexts,
              Bool oversubscribe_allowed,
              unsigned int num_workers)
{
#if COREMARK_PRO_TRACE
    frost_coremark_pro_trace("<<CMP_MITH>>\n");
#endif

    int result =
        mith_main_real(workload, num_iterations, num_contexts, oversubscribe_allowed, num_workers);

    /* A workload passes only if no work item recorded a failure and no
     * benchmark error was printed. */
    int failed = 0;
    for (unsigned int i = 0; i < workload->max_idx; i++) {
        if (workload->load[i]->failed > 0) {
            failed = 1;
        }
    }
    if (frost_coremark_pro_error_seen()) {
        failed = 1;
    }

    exit(failed);  /* al_frost.c: prints "<<PASS>>"/"<<FAIL>>"; never returns */
    return result; /* unreachable */
}

/*
 * FROST entry point.
 *
 * Every CoreMark-PRO workload's own main() is renamed to a single fixed symbol,
 * cmp_workload_main(), via -Dmain=cmp_workload_main on the workload wrapper
 * object (see the Makefile). This FROST main() builds argv from a compile-time
 * string and then calls it, so the entry point is workload-agnostic.
 *
 * Minimal-but-verified configuration
 * ----------------------------------
 * Each workload's default preset is large (core runs the CoreMark body 10000x
 * over a ~13k-element dataset; sha hashes 1 MiB; radix2 is a 64k-point FFT),
 * which is impractical for a cycle-accurate Verilator run. CoreMark-PRO's PGO
 * "training" path selects each benchmark's smallest preset, each of which has
 * its own known-good expected CRC / reference data. pgo_training_run != 0 makes
 * every benchmark's define_params_*() pick that small preset and skip the
 * command-line dataset overrides, which simulation builds do not use.
 * Verification remains an end-to-end correctness check on the small dataset.
 *
 * CMP_PGO_TRAINING is set per workload by the Makefile (WL_PGO):
 *   1 -> enable pgo_training_run, so the workload picks its smallest preset.
 *        Simulation builds of every workload except cjpeg-rose7-preset and
 *        zip-test take this path.
 *   0 -> leave it 0. Official builds use 0 and run each workload's default
 *        preset. The cjpeg and zip simulation builds also use 0; their FROST
 *        wrappers (frost_cjpeg_tiny.c, frost_zip_darkmark_sim.c) supply their
 *        own generated input. Upstream cjpeg must not enable it:
 *        pgo_training_run selects index 1 (goose), whose data the Rose256
 *        build does not compile.
 *
 * Hardware builds compile with CMP_PGO_TRAINING=0 and pass an argv string at
 * build time, such as COREMARK_PRO_RUN_ARGS="-v0 -i100" for a score run.
 * Without -v0, verify_output remains enabled and mith_main_loop() forces
 * num_iterations to 1.
 */
#ifndef CMP_PGO_TRAINING
#define CMP_PGO_TRAINING 1
#endif

#ifndef COREMARK_PRO_RUN_ARGS
#define COREMARK_PRO_RUN_ARGS ""
#endif

extern int cmp_workload_main(int argc, char *argv[]);

int main(void)
{
    frost_coremark_pro_install_trap_handler();
    frost_coremark_pro_clear_error();
#if COREMARK_PRO_TRACE
    frost_coremark_pro_trace("<<CMP_MAIN>>\n");
#endif

    /* A -pgo= run argument, parsed by the workload's main(), overrides this. */
    pgo_training_run = CMP_PGO_TRAINING;

    static char arg_storage[] = COREMARK_PRO_RUN_ARGS;
    static char *workload_argv[16];
    int argc = 1;
    workload_argv[0] = "cmp";

    char *p = arg_storage;
    while (*p != '\0' && argc < (int) (sizeof(workload_argv) / sizeof(workload_argv[0])) - 1) {
        while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') {
            p++;
        }
        if (*p == '\0') {
            break;
        }
        workload_argv[argc++] = p;
        while (*p != '\0' && *p != ' ' && *p != '\t' && *p != '\n' && *p != '\r') {
            p++;
        }
        if (*p != '\0') {
            *p++ = '\0';
        }
    }
    workload_argv[argc] = NULL;

    return cmp_workload_main(argc, workload_argv);
}
