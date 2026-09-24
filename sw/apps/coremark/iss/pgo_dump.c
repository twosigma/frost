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

/* Freestanding gcov dumper for the Spike PGO-training harness (README.md).
 *
 * -fprofile-info-section puts one gcov_info pointer per translation unit in
 * .gcov_info; __gcov_info_to_gcda() turns each into a gcda byte stream, and
 * __gcov_filename_to_gcfn() prefixes it with the name gcov-tool merge-stream
 * needs.  The stream leaves over Spike's HTIF syscall proxy as raw bytes on
 * stdout.  Measurement tooling only: generate_profile.py links this, and no
 * FROST image ever does.  The FROST port cannot host it, because printing a
 * few kilobytes over the modelled UART costs tens of millions of simulated
 * cycles. */

#include <gcov.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/mman.h>

extern volatile uint64_t tohost;
extern volatile uint64_t fromhost;

static uint64_t htif_syscall_block[8] __attribute__((aligned(64)));

static void htif_write(const void *buffer, unsigned long length)
{
    htif_syscall_block[0] = 64; /* SYS_write */
    htif_syscall_block[1] = 1;  /* stdout */
    htif_syscall_block[2] = (uint64_t) (uintptr_t) buffer;
    htif_syscall_block[3] = length;
    __asm__ volatile("fence" ::: "memory");
    tohost = (uint64_t) (uintptr_t) htif_syscall_block;
    while (fromhost == 0)
        ;
    fromhost = 0;
}

/* One buffered write per chunk keeps the HTIF round trips down. */
static void dump_callback(const void *data, unsigned length, void *arg)
{
    (void) arg;
    if (length)
        htif_write(data, length);
}

static void filename_callback(const char *filename, void *arg)
{
    __gcov_filename_to_gcfn(filename, dump_callback, arg);
}

/* __gcov_info_to_gcda asks for one scratch block; a static arena avoids malloc. */
static unsigned char gcov_arena[262144];
static unsigned long gcov_arena_used;

static void *allocate_callback(unsigned length, void *arg)
{
    (void) arg;
    unsigned long aligned = (gcov_arena_used + 7u) & ~7ul;
    if (aligned + length > sizeof(gcov_arena))
        return NULL;
    gcov_arena_used = aligned + length;
    return &gcov_arena[aligned];
}

/* libgcov's value profilers and error paths reference a handful of libc
 * entry points that a -nostdlib link does not supply. The training binary
 * reads no existing gcda, so fread is never called, and the bump allocators
 * are sized well above what one CoreMark training run asks for. */
void abort(void) __attribute__((noreturn));
void *calloc(size_t count, size_t size);
void *malloc(size_t size);
void free(void *pointer);
size_t fread(void *pointer, size_t size, size_t count, void *stream);

/* Streaming a fresh edge-count profile neither merges existing files nor
 * allocates Linux mappings. Resolve these unused libgcov references locally
 * rather than linking its filesystem/TLS driver. Fail visibly if a future
 * libgcov starts using either facility on this path.
 */
void __gcov_merge_add(long long *counters, unsigned count)
{
    (void) counters;
    (void) count;
    abort();
}

void *mmap(void *address, size_t length, int protection, int flags, int descriptor, off_t offset)
{
    (void) address;
    (void) length;
    (void) protection;
    (void) flags;
    (void) descriptor;
    (void) offset;
    abort();
}

static unsigned char libc_arena[65536];
static size_t libc_arena_used;

void *malloc(size_t size)
{
    size_t aligned = (libc_arena_used + 15u) & ~(size_t) 15u;
    if (aligned + size > sizeof(libc_arena))
        return NULL;
    libc_arena_used = aligned + size;
    return &libc_arena[aligned];
}

void *calloc(size_t count, size_t size)
{
    size_t total = count * size;
    unsigned char *block = malloc(total);
    if (block)
        for (size_t i = 0; i < total; i++)
            block[i] = 0;
    return block;
}

void free(void *pointer)
{
    (void) pointer;
}

size_t fread(void *pointer, size_t size, size_t count, void *stream)
{
    (void) pointer;
    (void) size;
    (void) count;
    (void) stream;
    return 0;
}

/* Report and stop the simulator rather than spinning, so a failure in the
 * dump, such as an undersized arena, is visible instead of looking like a hung
 * training run. */
void abort(void)
{
    static const char message[] = "\n<<GCOV-ABORT>>\n";
    htif_write(message, sizeof(message) - 1);
    tohost = 1;
    for (;;)
        ;
}

extern const struct gcov_info *const __gcov_info_start[];
extern const struct gcov_info *const __gcov_info_end[];

void pgo_dump(void);
void pgo_dump(void)
{
    const struct gcov_info *const *info = __gcov_info_start;
    while (info != __gcov_info_end) {
        gcov_arena_used = 0;
        __gcov_info_to_gcda(*info, filename_callback, dump_callback, allocate_callback, NULL);
        info++;
    }
}
