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

/* CoreMark platform configuration. */
#ifndef CORE_PORTME_H
#define CORE_PORTME_H
/************************/
/* Data types and settings */
/************************/
/* Set to 1 for floating-point support. */
#ifndef HAS_FLOAT
#define HAS_FLOAT 1
#endif
/* Set to 1 when time.h and its functions are available. */
#ifndef HAS_TIME_H
#define HAS_TIME_H 0
#endif
/* Ignored by this port, which uses the cycle counter instead of clock(). */
#ifndef USE_CLOCK
#define USE_CLOCK 0
#endif
/* Set to 1 when stdio.h is available. */
#ifndef HAS_STDIO
#define HAS_STDIO 0
#endif
/* Set to 1 for printf support; this port maps printf to uart_printf. */
#ifndef HAS_PRINTF
#define HAS_PRINTF 1
#endif
#include "uart.h"
#define printf uart_printf

/* Timing functions return a 64-bit cycle count. */
#include <stddef.h>
#include <stdint.h>
typedef uint64_t CORE_TICKS;

/* Build-identification strings reported by the benchmark. */
#ifndef COMPILER_VERSION
#ifdef __GNUC__
#define COMPILER_VERSION "GCC"__VERSION__
#else
#define COMPILER_VERSION "Please put compiler version here (e.g. gcc 4.1)"
#endif
#endif
#ifndef COMPILER_FLAGS
#define COMPILER_FLAGS FLAGS_STR /* "Please put compiler flags here (e.g. -o3)" */
#endif
#ifndef MEM_LOCATION
#define MEM_LOCATION "STACK"
#endif

/* ee_ptr_int must hold a pointer without truncation. */
typedef signed short ee_s16;
typedef unsigned short ee_u16;
typedef signed int ee_s32;
typedef float ee_f32;
typedef float ee_f16;
typedef unsigned char ee_u8;
typedef unsigned int ee_u32;
typedef uintptr_t ee_ptr_int;
typedef size_t ee_size_t;
/* Round up to a 4-byte boundary for the matrix input blocks. */
#define align_mem(x) (void *) (4 + (((ee_ptr_int) (x) - 1) & ~3))

/* Runtime seed source: SEED_ARG uses argv, SEED_FUNC calls a system
 * function, and SEED_VOLATILE reads volatile variables. */
#ifndef SEED_METHOD
#define SEED_METHOD SEED_VOLATILE
#endif

/* Workspace allocation: MEM_MALLOC uses malloc, MEM_STATIC uses a static
 * array, and MEM_STACK uses the stack. */
#ifndef MEM_METHOD
#define MEM_METHOD MEM_STACK
#endif

/* This port supports one context. More require core_start_parallel and
 * core_stop_parallel implementations in core_portme.c. */
#ifndef MULTITHREAD
#define MULTITHREAD 1
#define USE_PTHREAD 0
#define USE_FORK 0
#define USE_SOCKET 0
#endif

/* Set to 1 when main takes no argc/argv. */
#ifndef MAIN_HAS_NOARGC
#define MAIN_HAS_NOARGC 1
#endif

/* Set to 1 when main returns no value; 0 selects an int return of zero. */
#ifndef MAIN_HAS_NORETURN
#define MAIN_HAS_NORETURN 1
#endif

/* Must be 1 for this port. */
extern ee_u32 default_num_contexts;

typedef struct CORE_PORTABLE_S {
    ee_u8 portable_id;
} core_portable;

/* target specific init/fini */
void portable_init(core_portable *p, int *argc, char *argv[]);
void portable_fini(core_portable *p);

#if !defined(PROFILE_RUN) && !defined(PERFORMANCE_RUN) && !defined(VALIDATION_RUN)
#if (TOTAL_DATA_SIZE == 1200)
#define PROFILE_RUN 1
#elif (TOTAL_DATA_SIZE == 2000)
#define PERFORMANCE_RUN 1
#else
#define VALIDATION_RUN 1
#endif
#endif

#endif /* CORE_PORTME_H */
