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
 * PASS/FAIL bridge for CoreMark-PRO.
 *
 * Workload main() discards MITH's result. Some errors only print a message
 * without setting a work item's failed counter. Wrap mith_main_real() to
 * check both item failures and al_frost.c's error latch, then call exit()
 * to emit the UART result marker.
 *
 * The Makefile renames mith_lib.c's entry with -Dmith_main=mith_main_real.
 * Compile this wrapper with MITH headers, not sw/lib headers; the toolchain
 * declares exit(), and al_frost.c defines it.
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
 * FROST main builds argv from COREMARK_PRO_RUN_ARGS and calls the workload
 * main, renamed cmp_workload_main by the Makefile.
 *
 * CMP_PGO_TRAINING=1 selects each workload's small verified PGO preset and
 * bypasses dataset arguments. Official builds use 0. The cjpeg and zip
 * simulation wrappers also use 0 because they generate their own input.
 * Upstream cjpeg must keep it off: PGO selects goose data absent from the
 * Rose256 build.
 *
 * Hardware score runs pass -v0 and a board-specific -i count. Without -v0,
 * verify_output makes mith_main_loop() force one iteration.
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
