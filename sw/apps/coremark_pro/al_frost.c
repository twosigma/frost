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
 * al_frost.c
 *
 * FROST bare-metal shims for the EEMBC CoreMark-PRO MITH harness.
 *
 * The MITH adaptation layer (mith/al/src/th_al.c, th_lib.c) is compiled with
 * -DHOST_EXAMPLE_CODE=1, which routes its "host" functionality through a small
 * set of POSIX / C-library functions: clock_gettime(), vprintf(), exit(),
 * abort(), getenv(), plus the SMP/affinity hooks that normally live in
 * al_smp.c, which this single-context build does not compile. This file
 * provides those functions against FROST hardware (cycle counter and UART) and
 * the FROST libc.
 *
 * This file is compiled in isolation against the FROST sw/lib headers
 * (-I../../lib/include). It must not be compiled with the MITH include path,
 * and the MITH sources must not be compiled with the FROST lib include path.
 * The Makefile explains the header shadowing that this split avoids.
 */

#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
#include <time.h>

#include "csr.h"     /* rdcycle64() */
#include "sprintf.h" /* vsnprintf / vsprintf */
#include "uart.h"    /* uart_puts */

/* FPGA_CPU_CLK_FREQ is provided on the command line (see Makefile). Fall back
 * to a default so this file also compiles standalone. */
#ifndef FPGA_CPU_CLK_FREQ
#define FPGA_CPU_CLK_FREQ 30000000u
#endif

static volatile int coremark_pro_error_seen;
/* Keep trap diagnostics XLEN-wide: benchmark state includes 64-bit values and
 * cached-DDR pointers even when the default image executes from low BRAM. */
static volatile uintptr_t trap_ra;
static volatile uintptr_t trap_sp;
static volatile uintptr_t trap_gp;
static volatile uintptr_t trap_a0;
static volatile uintptr_t trap_a1;
static volatile uintptr_t trap_a2;
static volatile uintptr_t trap_a3;
static volatile uintptr_t trap_a4;
static volatile uintptr_t trap_a5;
static volatile uintptr_t trap_a6;
static volatile uintptr_t trap_a7;
static volatile uintptr_t trap_s0;
static volatile uintptr_t trap_s1;
static volatile uintptr_t trap_s2;
static volatile uintptr_t trap_s3;

void exit(int code);

void frost_coremark_pro_trap_handler(void) __attribute__((noreturn));
void frost_coremark_pro_trap_entry(void) __attribute__((naked, aligned(4)));

void frost_coremark_pro_trap_entry(void)
{
    __asm__ volatile("la t0, trap_ra\n"
                     "sd ra, 0(t0)\n"
                     "la t0, trap_sp\n"
                     "sd sp, 0(t0)\n"
                     "la t0, trap_gp\n"
                     "sd gp, 0(t0)\n"
                     "la t0, trap_a0\n"
                     "sd a0, 0(t0)\n"
                     "la t0, trap_a1\n"
                     "sd a1, 0(t0)\n"
                     "la t0, trap_a2\n"
                     "sd a2, 0(t0)\n"
                     "la t0, trap_a3\n"
                     "sd a3, 0(t0)\n"
                     "la t0, trap_a4\n"
                     "sd a4, 0(t0)\n"
                     "la t0, trap_a5\n"
                     "sd a5, 0(t0)\n"
                     "la t0, trap_a6\n"
                     "sd a6, 0(t0)\n"
                     "la t0, trap_a7\n"
                     "sd a7, 0(t0)\n"
                     "la t0, trap_s0\n"
                     "sd s0, 0(t0)\n"
                     "la t0, trap_s1\n"
                     "sd s1, 0(t0)\n"
                     "la t0, trap_s2\n"
                     "sd s2, 0(t0)\n"
                     "la t0, trap_s3\n"
                     "sd s3, 0(t0)\n"
                     "j frost_coremark_pro_trap_handler");
}

void frost_coremark_pro_install_trap_handler(void)
{
    csr_write(mtvec, (uintptr_t) frost_coremark_pro_trap_entry);
}

void frost_coremark_pro_trace(const char *s)
{
    uart_puts(s);
}

void frost_coremark_pro_trap_handler(void)
{
    uintptr_t mcause = csr_read(mcause);
    uintptr_t mepc = csr_read(mepc);
    uintptr_t mtval = csr_read(mtval);

    uart_puts("\n<<TRAP>>\n");
    uart_printf("mcause=0x%016lx mepc=0x%016lx mtval=0x%016lx\n",
                (unsigned long) mcause,
                (unsigned long) mepc,
                (unsigned long) mtval);
    uart_printf("ra=0x%016lx sp=0x%016lx gp=0x%016lx\n",
                (unsigned long) trap_ra,
                (unsigned long) trap_sp,
                (unsigned long) trap_gp);
    uart_printf("a0=0x%016lx a1=0x%016lx a2=0x%016lx a3=0x%016lx\n",
                (unsigned long) trap_a0,
                (unsigned long) trap_a1,
                (unsigned long) trap_a2,
                (unsigned long) trap_a3);
    uart_printf("a4=0x%016lx a5=0x%016lx a6=0x%016lx a7=0x%016lx\n",
                (unsigned long) trap_a4,
                (unsigned long) trap_a5,
                (unsigned long) trap_a6,
                (unsigned long) trap_a7);
    uart_printf("s0=0x%016lx s1=0x%016lx s2=0x%016lx s3=0x%016lx\n",
                (unsigned long) trap_s0,
                (unsigned long) trap_s1,
                (unsigned long) trap_s2,
                (unsigned long) trap_s3);
    exit(1);
    for (;;) {
    }
}

void frost_coremark_pro_clear_error(void)
{
    coremark_pro_error_seen = 0;
}

int frost_coremark_pro_error_seen(void)
{
    return coremark_pro_error_seen;
}

static int contains_token(const char *s, const char *token)
{
    if (s == NULL || token == NULL || *token == '\0') {
        return 0;
    }

    for (; *s != '\0'; s++) {
        const char *a = s;
        const char *b = token;
        while (*a != '\0' && *b != '\0' && *a == *b) {
            a++;
            b++;
        }
        if (*b == '\0') {
            return 1;
        }
    }

    return 0;
}

static void latch_benchmark_errors(const char *s)
{
    if (contains_token(s, "ERROR") || contains_token(s, "Error") || contains_token(s, "Failure:") ||
        contains_token(s, "Failed ") || contains_token(s, "failed malloc") ||
        contains_token(s, "Malloc Failed")) {
        coremark_pro_error_seen = 1;
    }
}

/* ========================================================================== */
/* Timing: clock_gettime()                                                    */
/*                                                                            */
/* th_al.c's GETMYTIME() macro (HOST_EXAMPLE_CODE, gcc path) is               */
/*   clock_gettime(CLOCK_REALTIME, &ts)                                       */
/* with NSECS_PER_SEC == 1000000000. Wall-clock time is derived from the      */
/* cycle counter assuming a fixed FPGA_CPU_CLK_FREQ. The prototype must       */
/* match newlib's <time.h> declaration exactly.                               */
/* ========================================================================== */
int clock_gettime(clockid_t clk_id, struct timespec *ts)
{
    (void) clk_id;
    if (ts == NULL) {
        return -1;
    }

    uint64_t cycles = rdcycle64();
    uint64_t freq = (uint64_t) FPGA_CPU_CLK_FREQ;

    ts->tv_sec = (time_t) (cycles / freq);
    /* (cycles % freq) is < freq < 2^32, so the multiply by 1e9 fits in 64 bits
     * as long as freq <= ~1.8e10, which holds for any realistic clock. */
    ts->tv_nsec = (long) (((cycles % freq) * 1000000000ull) / freq);
    return 0;
}

/* ========================================================================== */
/* Console output: vprintf()                                                  */
/*                                                                            */
/* With USE_TH_PRINTF=0, the harness routes th_printf -> al_printf -> vprintf.*/
/* The text is formatted into a static buffer (single-context build, so no    */
/* reentrancy concern), scanned for benchmark error tokens, and written to    */
/* the UART.                                                                  */
/* ========================================================================== */
int vprintf(const char *fmt, va_list ap)
{
    static char buf[512];
    int n = vsnprintf(buf, sizeof(buf), fmt, ap);
    latch_benchmark_errors(buf);
    uart_puts(buf);
    return n;
}

/* ========================================================================== */
/* Process control: exit() / abort()                                          */
/*                                                                            */
/* th_al.c's al_exit() calls exit(code). exit() writes a PASS/FAIL marker so  */
/* a simulation harness watching the UART can detect the self-verifying       */
/* result, then spins forever (there is no OS to return to). Prototypes match */
/* newlib's noreturn exit()/abort().                                          */
/* ========================================================================== */
void exit(int code)
{
    uart_puts(code == 0 ? "<<PASS>>\n" : "<<FAIL>>\n");
    for (;;) {
        /* spin */
    }
}

void abort(void)
{
    exit(1);
}

/* ========================================================================== */
/* newlib reentrancy anchor: _impure_ptr                                      */
/*                                                                            */
/* th_lib.c's redirect_std_files() reads stdin/stdout/stderr, which newlib    */
/* expands to _impure_ptr->_stdin/_stdout/_stderr. With -nostdlib there is no */
/* newlib _impure_ptr, so provide one pointing at a zeroed struct _reent. The */
/* stored stdin/stdout/stderr values land in th_stdin/th_stdout/th_stderr     */
/* (declared 'void *' in th_lib.c) and are never dereferenced as files,       */
/* because FAKE_FILEIO=1 turns every al_* file op into a no-op stub. So the   */
/* members only need to be readable, not valid FILE handles.                  */
/* ========================================================================== */
#include <sys/reent.h>
static struct _reent frost_impure_reent;
struct _reent *_impure_ptr = &frost_impure_reent;

/* ========================================================================== */
/* newlib errno accessor: __errno()                                           */
/*                                                                            */
/* The toolchain's libm, used by the floating-point workloads (linpack,       */
/* loops, nnet, radix2) for sqrtf/powf/sinf/..., reports domain/range errors  */
/* by writing errno, which newlib expands to *__errno() ==                    */
/* _impure_ptr->_errno. With -nostdlib there is no newlib __errno(), so       */
/* provide one backed by the _impure_ptr reent above. The benchmarks never    */
/* read errno; the function only satisfies the libm references.               */
/* ========================================================================== */
int *__errno(void)
{
    return &_impure_ptr->_errno;
}

/* ========================================================================== */
/* Environment: getenv()                                                      */
/*                                                                            */
/* al_getenv() forwards to getenv() under HOST_EXAMPLE_CODE. No environment   */
/* exists on bare metal; CoreMark-PRO 'core' does not depend on one.          */
/* ========================================================================== */
char *getenv(const char *key)
{
    (void) key;
    return NULL;
}

/* ========================================================================== */
/* SMP / affinity hooks normally in mith/al/src/al_smp.c                      */
/*                                                                            */
/* The build is single-context (USE_SINGLE_CONTEXT=1) and does not compile    */
/* al_smp.c. mith_lib.c still calls al_item_setaffinity() in its run loop,    */
/* and core.c references al_set_hardware_info()/hardware_info via the -P=     */
/* command-line option (unused on bare metal). The trivial versions here      */
/* match al_smp.h's declarations. The types are defined locally so this       */
/* FROST-headers compilation unit does not need the MITH include path.        */
/* ========================================================================== */
typedef struct hardware_info_s {
    int num_processors;
    char *description_string;
} hardware_info_t;

/* Global expected by the harness (declared 'extern' in al_smp.h). */
hardware_info_t hardware_info = {1, NULL};

void al_set_hardware_info(char *pdescription)
{
    /* Record the description but do not parse it; a single processor is the
     * only valid configuration for this single-context bare-metal build. */
    hardware_info.num_processors = 1;
    hardware_info.description_string = pdescription;
}

int al_item_setaffinity(int kernel_id, int instance_id, int item_id, uint32_t context_id)
{
    /* No scheduler / no affinity on bare metal: single context always. */
    (void) kernel_id;
    (void) instance_id;
    (void) item_id;
    (void) context_id;
    return 0;
}

/* ========================================================================== */
/* newlib character-class table: _ctype_                                      */
/*                                                                            */
/* Several benchmark kernels (e.g. darkmark/parser's ezxml.c, zlib) include   */
/* the toolchain's <ctype.h>, whose isspace()/isalpha()/... are macros that   */
/* index newlib's global _ctype_[] classification table:                      */
/*     #define isspace(c) ((_ctype_+1)[(int)(c)] & _S)                        */
/* The FROST sw/lib ctype.c provides is*() as functions, but the system-      */
/* header macros shadow them at the call sites in MITH code, so the link      */
/* needs the _ctype_ symbol itself. Provide the standard newlib ASCII table.  */
/*                                                                            */
/* Layout: 257 bytes. Index 0 is the EOF (-1) slot (0); indices 1..256 map    */
/* characters 0..255. Bit flags: _U=0x01 _L=0x02 _N(digit)=0x04 _S(space)=    */
/* 0x08 _P(punct)=0x10 _C(control)=0x20 _X(xdigit)=0x40 _B(blank/space)=0x80. */
/* These bytes were verified to match the rv32 newlib libc.a _ctype_ exactly. */
/* ========================================================================== */
const char _ctype_[257] = {
    0x00, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x28, 0x28, 0x28, 0x28, 0x28, 0x20,
    0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20,
    0x20, 0x88, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10,
    0x10, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x10, 0x10, 0x10, 0x10, 0x10,
    0x10, 0x10, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01,
    0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x10, 0x10, 0x10, 0x10,
    0x10, 0x10, 0x42, 0x42, 0x42, 0x42, 0x42, 0x42, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02,
    0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x10, 0x10, 0x10, 0x10,
    0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00,
};

/* ========================================================================== */
/* File metadata: stat()                                                      */
/*                                                                            */
/* th_al.c's al_fsize() calls stat() to size a file (HAVE_STAT_H path). The   */
/* file-based workloads (parser, zip) read their input from generated in-     */
/* memory buffers in the minimal pgo configs, so al_fsize() is never called   */
/* at runtime, but it is still referenced and must link. With FAKE_FILEIO=1   */
/* there is no filesystem, so report "no such file": stat() returns -1 and    */
/* al_fsize() yields 0. Prototype matches newlib's <sys/stat.h>.              */
/* ========================================================================== */
#include <sys/stat.h>
int stat(const char *path, struct stat *buf)
{
    (void) path;
    (void) buf;
    return -1; /* no filesystem on bare metal (FAKE_FILEIO) */
}

/* ========================================================================== */
/* Unused libc surface pulled in by dead code: vsscanf / sscanf / fclose      */
/*                                                                            */
/* A few workloads reference C-library functions only from code paths that    */
/* the minimal pgo configurations never execute:                              */
/*   - cjpeg's parse_dataset_cjpeg() calls th_sscanf() (->al_vsscanf->vsscanf)*/
/*     only for a "-dataname=" option the build does not pass.                */
/*   - zip's define_params_zip() calls fclose() only in the "-f=<file>" branch*/
/*     (it generates its input in memory instead).                            */
/* These are dead at runtime but must resolve at link time. The toolchain's   */
/* newlib provides full scanf/stdio, but pulling it in would drag in the      */
/* _impure_ptr FILE machinery that the -nostdlib build avoids. Provide inert  */
/* stubs: vsscanf/sscanf convert nothing (return 0) and fclose succeeds       */
/* (return 0).                                                                */
/* Prototypes match newlib's <stdio.h>.                                       */
/* ========================================================================== */
#include <stdio.h>
int vsscanf(const char *str, const char *fmt, va_list ap)
{
    (void) str;
    (void) fmt;
    (void) ap;
    return 0; /* no fields converted */
}

int sscanf(const char *str, const char *fmt, ...)
{
    (void) str;
    (void) fmt;
    return 0; /* no fields converted */
}

int fclose(FILE *stream)
{
    (void) stream;
    return 0; /* no filesystem on bare metal (FAKE_FILEIO) */
}
