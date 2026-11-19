// Copyright (c) 2026 John Goodacre.
// fefuzz: front-end fuzzer program. fe_gen.py emits fe_gen.S (a random mix of branches, calls,
// indirect calls and jumps, returns and loops) and the signature it must return. Prints <<PASS>>
// when the signature matches.
#include "fe_expect.h"
#include "uart.h"
#include <stdint.h>

extern uint64_t fe_run(void);

int main(void)
{
    uint64_t sig = fe_run();
    uart_printf("fefuzz seed %lu rounds %lu sig %016lx want %016lx\n",
                (unsigned long) FE_SEED,
                (unsigned long) FE_ROUNDS,
                (unsigned long) sig,
                (unsigned long) FE_EXPECT);
    uart_printf(sig == FE_EXPECT ? "<<PASS>>\n" : "<<FAIL>>\n");
    for (;;) {
    }
}
