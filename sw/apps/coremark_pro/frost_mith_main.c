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
 * frost_mith_main.c
 *
 * PASS/FAIL bridge for running CoreMark-PRO workloads on FROST.
 *
 * The CoreMark-PRO workload entry (e.g. workloads/core/core.c) calls
 * mith_main(), which runs and CRC-verifies the workload, prints the score, and
 * returns. The workload's main() then returns 0 *unconditionally* (it discards
 * the harness result) and never calls exit(). Some workloads also print error
 * lines without incrementing MITH's per-item ->failed counter. On FROST, crt0
 * simply spins after main() returns, so nothing would ever signal pass/fail to
 * the simulation UART harness (which watches for "<<PASS>>" / "<<FAIL>>").
 *
 * Rather than fork the upstream (EEMBC-licensed) workload source, we interpose
 * the harness entry point: mith_lib.c is compiled with
 * -Dmith_main=mith_main_real (see the Makefile), so the real harness routine is
 * exported as mith_main_real(). This FROST-authored mith_main() wraps it: it
 * runs the real harness, then inspects each work item's verification result and
 * the FROST AL's benchmark-error latch. It exits with 0 (all checks clean) or
 * 1 (some item failed or an error line was emitted). al_frost.c's exit() turns
 * that into the "<<PASS>>" / "<<FAIL>>" UART marker.
 *
 * This is compiled against the MITH headers/types (NOT the FROST sw/lib
 * headers); exit() is declared by the toolchain's <stdlib.h> and defined in
 * al_frost.c, resolved at link.
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

    /* A workload passes only if every work item's CRC verification succeeded
     * and no benchmark error was printed. */
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
 * Each workload's default preset is large (e.g. core runs the CoreMark body
 * 10000x over a ~13k-element dataset; sha hashes 1 MiB; radix2 is a 64k-point
 * FFT) -- impractical for a cycle-accurate Verilator run. CoreMark-PRO's PGO
 * "training" path selects each benchmark's SMALLEST preset, each of which has
 * its own known-good expected CRC / reference data. pgo_training_run != 0 makes
 * every benchmark's define_params_*() pick that small preset (and skip the
 * command-line dataset overrides we don't use). The verification stays a true
 * end-to-end correctness check; it just runs on the small dataset.
 *
 * CMP_PGO_TRAINING is set per workload by the Makefile (WL_PGO):
 *   1 -> enable pgo_training_run (8 of 9 workloads pick their smallest preset).
 *   0 -> leave it 0; the workload then uses its default preset index. This is
 *        used only for cjpeg-rose7-preset, whose smallest *compiled* preset
 *        (Rose256, index 0) is the default -- enabling pgo there would select
 *        index 1 (goose), whose data is not compiled into the Rose256 build.
 *
 * Hardware performance builds compile with CMP_PGO_TRAINING=0 and pass an argv
 * string such as COREMARK_PRO_RUN_ARGS="-v0 -i100" at build time. Without -v0,
 * verify_output remains enabled and mith_main_loop() forces num_iterations to 1.
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

    /* Select the small verified preset unless argv overrides it. */
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
