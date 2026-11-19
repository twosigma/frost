// Copyright (c) 2026 John Goodacre.
// pd_itt_slot2_test: every not-taken iteration of the probe's branch must make
// its indirect call (probe.S). Prints <<PASS>> when the callee ran exactly once
// per not-taken iteration, each time through the call.
#include "uart.h"
#include <stdint.h>

#define ITERATIONS 4000

extern void pd_itt_probe(long iteration, void (*callee)(void));
extern void pd_itt_callee(void);
extern volatile uint64_t pd_itt_calls, pd_itt_skipped, pd_itt_bad_ra;

int main(void)
{
    for (long i = 0; i < ITERATIONS; i++)
        pd_itt_probe(i, pd_itt_callee);
    uint64_t want = ITERATIONS / 4;
    uart_printf("pd_itt_slot2: calls %lu (want %lu) skipped %lu bad_ra %lu\n",
                (unsigned long) pd_itt_calls,
                (unsigned long) want,
                (unsigned long) pd_itt_skipped,
                (unsigned long) pd_itt_bad_ra);
    int ok = pd_itt_calls == want && pd_itt_skipped == 0 && pd_itt_bad_ra == 0;
    uart_printf(ok ? "<<PASS>>\n" : "<<FAIL>>\n");
    for (;;) {
    }
}
