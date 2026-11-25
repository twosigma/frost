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
 * RISC-V Supm user-space pointer-masking probe.
 *
 * Checks that the kernel advertises Supm/Ssnpm, enables tagged user addresses
 * through prctl(PR_SET_TAGGED_ADDR_CTRL) for PMLEN 7 and PMLEN 16, verifies
 * tagged loads, tagged stores, and syscall untagging, then disables tagging
 * and verifies that tagged loads and stores raise SIGSEGV without modifying
 * memory.
 */

#define _GNU_SOURCE

#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <setjmp.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <unistd.h>

#if defined(__riscv) && defined(__has_include) && __has_include(<asm/hwprobe.h>)
#include <asm/hwprobe.h>
#else
struct riscv_hwprobe {
    int64_t key;
    uint64_t value;
};
#endif

#ifndef __NR_riscv_hwprobe
#define __NR_riscv_hwprobe 258
#endif
#ifndef RISCV_HWPROBE_KEY_IMA_EXT_0
#define RISCV_HWPROBE_KEY_IMA_EXT_0 4
#endif
#ifndef RISCV_HWPROBE_EXT_SUPM
#define RISCV_HWPROBE_EXT_SUPM (1ULL << 49)
#endif
#ifndef PR_SET_TAGGED_ADDR_CTRL
#define PR_SET_TAGGED_ADDR_CTRL 55
#endif
#ifndef PR_GET_TAGGED_ADDR_CTRL
#define PR_GET_TAGGED_ADDR_CTRL 56
#endif
#ifndef PR_TAGGED_ADDR_ENABLE
#define PR_TAGGED_ADDR_ENABLE (1UL << 0)
#endif
#ifndef PR_PMLEN_SHIFT
#define PR_PMLEN_SHIFT 24
#endif
#ifndef PR_PMLEN_MASK
#define PR_PMLEN_MASK (0x7fUL << PR_PMLEN_SHIFT)
#endif

#define TOKEN_PREFIX "FROST_SUPM_PROBE"
#define TOKEN_SUMMARY "FROST_SUPM_PROBE_SUMMARY"
#define TOKEN_PASS "FROST_SUPM_PROBE_PASS"
#define TOKEN_FAIL "FROST_SUPM_PROBE_FAIL"

static sigjmp_buf g_fault_env;
static volatile sig_atomic_t g_fault_armed;
static volatile sig_atomic_t g_fault_sig;
static volatile sig_atomic_t g_fault_code;

static void segv_handler(int sig, siginfo_t *info, void *ucontext)
{
    (void) ucontext;
    if (g_fault_armed) {
        g_fault_armed = 0;
        g_fault_sig = sig;
        g_fault_code = (info != NULL) ? info->si_code : 0;
        siglongjmp(g_fault_env, 1);
    }
    _exit(128 + sig);
}

static inline uintptr_t tag_addr(const volatile void *base, uint64_t tag_bits)
{
    uintptr_t addr = (uintptr_t) base | (uintptr_t) tag_bits;
    __asm__ volatile("" : "+r"(addr) : : "memory");
    return addr;
}

static inline uint64_t tagged_load64(uintptr_t addr)
{
    uint64_t val = 0;
#if defined(__riscv) && (__riscv_xlen == 64)
    __asm__ volatile("ld %0, 0(%1)" : "=r"(val) : "r"(addr) : "memory");
#else
    val = *(const volatile uint64_t *) addr;
#endif
    return val;
}

static inline void tagged_store64(uintptr_t addr, uint64_t val)
{
#if defined(__riscv) && (__riscv_xlen == 64)
    __asm__ volatile("sd %0, 0(%1)" : : "r"(val), "r"(addr) : "memory");
#else
    *(volatile uint64_t *) addr = val;
#endif
}

static bool cpuinfo_has_ssnpm(void)
{
    FILE *fp = fopen("/proc/cpuinfo", "r");
    if (fp == NULL)
        return false;
    char line[4096];
    bool found = false;
    while (fgets(line, sizeof(line), fp) != NULL) {
        if (strncmp(line, "isa", 3) != 0)
            continue;
        char *colon = strchr(line, ':');
        if (colon == NULL)
            continue;
        const char *p = colon + 1;
        while (*p != '\0' && isspace((unsigned char) *p))
            p++;
        while (*p != '\0' && *p != '_' && !isspace((unsigned char) *p))
            p++;
        while (*p == '_') {
            p++;
            const char *start = p;
            while (*p != '\0' && *p != '_' && !isspace((unsigned char) *p))
                p++;
            size_t len = (size_t) (p - start);
            if (len == 5 && strncasecmp(start, "ssnpm", 5) == 0) {
                found = true;
                break;
            }
        }
        if (found)
            break;
    }
    fclose(fp);
    return found;
}

static bool check_discover(const char *run_id)
{
    struct riscv_hwprobe pair = {
        .key = RISCV_HWPROBE_KEY_IMA_EXT_0,
        .value = 0,
    };
    long rc = syscall(__NR_riscv_hwprobe, &pair, (size_t) 1, (size_t) 0, NULL, 0U);
    if (rc != 0) {
        printf("%s id=%s case=discover verdict=FAIL reason=hwprobe_rc_%ld_errno_%d\n",
               TOKEN_PREFIX,
               run_id,
               rc,
               errno);
        return false;
    }
    if ((pair.value & RISCV_HWPROBE_EXT_SUPM) == 0) {
        printf("%s id=%s case=discover verdict=FAIL reason=hwprobe_no_supm ext0=0x%llx\n",
               TOKEN_PREFIX,
               run_id,
               (unsigned long long) pair.value);
        return false;
    }
    if (!cpuinfo_has_ssnpm()) {
        printf(
            "%s id=%s case=discover verdict=FAIL reason=cpuinfo_no_ssnpm\n", TOKEN_PREFIX, run_id);
        return false;
    }
    long ctrl = prctl(PR_GET_TAGGED_ADDR_CTRL, 0, 0, 0, 0);
    if (ctrl != 0) {
        printf("%s id=%s case=discover verdict=FAIL reason=init_ctrl_%ld_errno_%d\n",
               TOKEN_PREFIX,
               run_id,
               ctrl,
               errno);
        return false;
    }
    printf("%s id=%s case=discover verdict=PASS hwprobe=1 cpuinfo=1 init_ctrl=0\n",
           TOKEN_PREFIX,
           run_id);
    return true;
}

static bool exercise_tags(
    volatile uint64_t *slots, const uint64_t *tags, size_t ntags, unsigned *loads, unsigned *stores)
{
    for (size_t i = 0; i < ntags; i++) {
        uint64_t expected = 0x1122334455667700ULL ^ ((uint64_t) (i + 1) * 0x0102030405060708ULL);
        slots[i] = expected;
        uint64_t got = tagged_load64(tag_addr(&slots[i], tags[i]));
        (*loads)++;
        if (got != expected)
            return false;

        uint64_t written = ~expected ^ (tags[i] >> 40);
        tagged_store64(tag_addr(&slots[i], tags[i]), written);
        (*stores)++;
        if (slots[i] != written)
            return false;

        uint64_t other_tag = tags[(i + 1) % ntags];
        uint64_t cross = written ^ 0xa5a55a5a0f0ff0f0ULL;
        tagged_store64(tag_addr(&slots[i], tags[i]), cross);
        (*stores)++;
        uint64_t cross_got = tagged_load64(tag_addr(&slots[i], other_tag));
        (*loads)++;
        if (cross_got != cross || slots[i] != cross)
            return false;
    }
    return true;
}

static bool check_pmlen7(const char *run_id, volatile uint64_t *slots)
{
    unsigned long req = PR_TAGGED_ADDR_ENABLE | (7UL << PR_PMLEN_SHIFT);
    if (prctl(PR_SET_TAGGED_ADDR_CTRL, req, 0, 0, 0) != 0) {
        printf("%s id=%s case=pmlen7 verdict=FAIL reason=prctl_set_errno_%d\n",
               TOKEN_PREFIX,
               run_id,
               errno);
        return false;
    }
    long ctrl = prctl(PR_GET_TAGGED_ADDR_CTRL, 0, 0, 0, 0);
    if (ctrl < 0 || ((unsigned long) ctrl & PR_TAGGED_ADDR_ENABLE) == 0) {
        printf(
            "%s id=%s case=pmlen7 verdict=FAIL reason=prctl_get_%ld\n", TOKEN_PREFIX, run_id, ctrl);
        return false;
    }
    unsigned long pmlen = ((unsigned long) ctrl & PR_PMLEN_MASK) >> PR_PMLEN_SHIFT;
    if (pmlen < 7UL) {
        printf("%s id=%s case=pmlen7 verdict=FAIL reason=pmlen_%lu\n", TOKEN_PREFIX, run_id, pmlen);
        return false;
    }
    static const uint64_t tags[] = {
        0x01ULL << 57,
        0x2aULL << 57,
        0x40ULL << 57,
        0x7fULL << 57,
    };
    unsigned loads = 0;
    unsigned stores = 0;
    if (!exercise_tags(slots, tags, sizeof(tags) / sizeof(tags[0]), &loads, &stores)) {
        printf("%s id=%s case=pmlen7 verdict=FAIL reason=data_mismatch\n", TOKEN_PREFIX, run_id);
        return false;
    }
    printf("%s id=%s case=pmlen7 verdict=PASS pmlen=%lu loads=%u stores=%u\n",
           TOKEN_PREFIX,
           run_id,
           pmlen,
           loads,
           stores);
    return true;
}

static bool check_tagged_pipe_syscall(uint8_t *page)
{
    int fds[2] = {-1, -1};
    if (pipe(fds) != 0)
        return false;

    static const char msg[] = "FROST_SUPM_SYSCALL_UNTAG";
    size_t len = sizeof(msg);
    uint8_t *tx = page + 128;
    uint8_t *rx = page + 256;
    memcpy(tx, msg, len);
    memset(rx, 0, len);

    const void *tagged_tx = (const void *) tag_addr(tx, 0xbeefULL << 48);
    void *tagged_rx = (void *) tag_addr(rx, 0x5a01ULL << 48);

    ssize_t wr = write(fds[1], tagged_tx, len);
    ssize_t rd = (wr == (ssize_t) len) ? read(fds[0], tagged_rx, len) : -1;
    close(fds[0]);
    close(fds[1]);
    return wr == (ssize_t) len && rd == (ssize_t) len && memcmp(rx, msg, len) == 0;
}

static bool check_pmlen16(const char *run_id, volatile uint64_t *slots, uint8_t *page)
{
    /* Requesting PMLEN 8 must round up to 16 on hardware with PMLEN 7 and 16. */
    unsigned long req8 = PR_TAGGED_ADDR_ENABLE | (8UL << PR_PMLEN_SHIFT);
    if (prctl(PR_SET_TAGGED_ADDR_CTRL, req8, 0, 0, 0) != 0) {
        printf("%s id=%s case=pmlen16 verdict=FAIL reason=prctl_set8_errno_%d\n",
               TOKEN_PREFIX,
               run_id,
               errno);
        return false;
    }
    long ctrl8 = prctl(PR_GET_TAGGED_ADDR_CTRL, 0, 0, 0, 0);
    unsigned long req8_pmlen =
        (ctrl8 >= 0) ? (((unsigned long) ctrl8 & PR_PMLEN_MASK) >> PR_PMLEN_SHIFT) : 0UL;
    if (ctrl8 < 0 || ((unsigned long) ctrl8 & PR_TAGGED_ADDR_ENABLE) == 0 || req8_pmlen != 16UL) {
        printf("%s id=%s case=pmlen16 verdict=FAIL reason=req8_pmlen_%lu\n",
               TOKEN_PREFIX,
               run_id,
               req8_pmlen);
        return false;
    }

    unsigned long req16 = PR_TAGGED_ADDR_ENABLE | (16UL << PR_PMLEN_SHIFT);
    if (prctl(PR_SET_TAGGED_ADDR_CTRL, req16, 0, 0, 0) != 0) {
        printf("%s id=%s case=pmlen16 verdict=FAIL reason=prctl_set16_errno_%d\n",
               TOKEN_PREFIX,
               run_id,
               errno);
        return false;
    }
    long ctrl = prctl(PR_GET_TAGGED_ADDR_CTRL, 0, 0, 0, 0);
    unsigned long pmlen =
        (ctrl >= 0) ? (((unsigned long) ctrl & PR_PMLEN_MASK) >> PR_PMLEN_SHIFT) : 0UL;
    if (ctrl < 0 || ((unsigned long) ctrl & PR_TAGGED_ADDR_ENABLE) == 0 || pmlen != 16UL) {
        printf(
            "%s id=%s case=pmlen16 verdict=FAIL reason=pmlen_%lu\n", TOKEN_PREFIX, run_id, pmlen);
        return false;
    }

    static const uint64_t tags[] = {
        0x0001ULL << 48,
        0x5a5aULL << 48,
        0x8001ULL << 48,
        0xffffULL << 48,
    };
    unsigned loads = 0;
    unsigned stores = 0;
    if (!exercise_tags(slots, tags, sizeof(tags) / sizeof(tags[0]), &loads, &stores)) {
        printf("%s id=%s case=pmlen16 verdict=FAIL reason=data_mismatch\n", TOKEN_PREFIX, run_id);
        return false;
    }

    if (!check_tagged_pipe_syscall(page)) {
        printf("%s id=%s case=pmlen16 verdict=FAIL reason=syscall_untag\n", TOKEN_PREFIX, run_id);
        return false;
    }

    unsigned long req32 = PR_TAGGED_ADDR_ENABLE | (32UL << PR_PMLEN_SHIFT);
    errno = 0;
    long rc32 = prctl(PR_SET_TAGGED_ADDR_CTRL, req32, 0, 0, 0);
    if (rc32 != -1 || errno != EINVAL) {
        printf("%s id=%s case=pmlen16 verdict=FAIL reason=pmlen32_rc_%ld_errno_%d\n",
               TOKEN_PREFIX,
               run_id,
               rc32,
               errno);
        return false;
    }

    printf("%s id=%s case=pmlen16 verdict=PASS pmlen=%lu req8_pmlen=%lu "
           "loads=%u stores=%u syscall=1 reject_pmlen32=1\n",
           TOKEN_PREFIX,
           run_id,
           pmlen,
           req8_pmlen,
           loads,
           stores);
    return true;
}

static bool probe_load_faults(uintptr_t addr)
{
    g_fault_sig = 0;
    g_fault_code = 0;
    g_fault_armed = 1;
    if (sigsetjmp(g_fault_env, 1) == 0) {
        volatile uint64_t sink = tagged_load64(addr);
        (void) sink;
        g_fault_armed = 0;
        return false;
    }
    return g_fault_sig == SIGSEGV;
}

static bool probe_store_faults(uintptr_t addr, uint64_t value)
{
    g_fault_sig = 0;
    g_fault_code = 0;
    g_fault_armed = 1;
    if (sigsetjmp(g_fault_env, 1) == 0) {
        tagged_store64(addr, value);
        g_fault_armed = 0;
        return false;
    }
    return g_fault_sig == SIGSEGV;
}

static bool check_disable_fault(const char *run_id, volatile uint64_t *slots)
{
    if (prctl(PR_SET_TAGGED_ADDR_CTRL, 0, 0, 0, 0) != 0) {
        printf("%s id=%s case=disable-fault verdict=FAIL reason=prctl_disable_errno_%d\n",
               TOKEN_PREFIX,
               run_id,
               errno);
        return false;
    }
    long ctrl = prctl(PR_GET_TAGGED_ADDR_CTRL, 0, 0, 0, 0);
    if (ctrl != 0) {
        printf("%s id=%s case=disable-fault verdict=FAIL reason=ctrl_still_%ld\n",
               TOKEN_PREFIX,
               run_id,
               ctrl);
        return false;
    }

    const uint64_t sentinel = 0xfeedfacecafebeefULL;
    const uint64_t poison = 0xbad0bad0bad0bad0ULL;
    slots[0] = sentinel;
    if (tagged_load64((uintptr_t) &slots[0]) != sentinel) {
        printf("%s id=%s case=disable-fault verdict=FAIL reason=untagged_load\n",
               TOKEN_PREFIX,
               run_id);
        return false;
    }

    struct sigaction sa;
    struct sigaction old_sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = segv_handler;
    sa.sa_flags = SA_SIGINFO;
    sigemptyset(&sa.sa_mask);
    if (sigaction(SIGSEGV, &sa, &old_sa) != 0) {
        printf("%s id=%s case=disable-fault verdict=FAIL reason=sigaction_errno_%d\n",
               TOKEN_PREFIX,
               run_id,
               errno);
        return false;
    }

    bool load7_faulted = probe_load_faults(tag_addr(&slots[0], 0x5aULL << 57));
    bool load16_faulted = probe_load_faults(tag_addr(&slots[0], 0x0001ULL << 48));
    bool store7_faulted = probe_store_faults(tag_addr(&slots[0], 0x5aULL << 57), poison);
    bool store16_faulted = probe_store_faults(tag_addr(&slots[0], 0x0001ULL << 48), poison);

    sigaction(SIGSEGV, &old_sa, NULL);

    if (!load7_faulted || !load16_faulted) {
        printf("%s id=%s case=disable-fault verdict=FAIL reason=tagged_load_did_not_fault "
               "load7=%d load16=%d\n",
               TOKEN_PREFIX,
               run_id,
               load7_faulted ? 1 : 0,
               load16_faulted ? 1 : 0);
        return false;
    }
    if (!store7_faulted || !store16_faulted) {
        printf("%s id=%s case=disable-fault verdict=FAIL reason=tagged_store_did_not_fault "
               "store7=%d store16=%d\n",
               TOKEN_PREFIX,
               run_id,
               store7_faulted ? 1 : 0,
               store16_faulted ? 1 : 0);
        return false;
    }
    if (slots[0] != sentinel) {
        printf("%s id=%s case=disable-fault verdict=FAIL reason=faulting_store_modified_memory\n",
               TOKEN_PREFIX,
               run_id);
        return false;
    }

    printf("%s id=%s case=disable-fault verdict=PASS ctrl_off=1 untagged_ok=1 "
           "load_sigsegv=1 store_sigsegv=1 store_unmodified=1\n",
           TOKEN_PREFIX,
           run_id);
    return true;
}

int main(int argc, char **argv)
{
    const char *run_id = "boot";
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--run-id") == 0 && i + 1 < argc) {
            run_id = argv[++i];
        } else {
            fprintf(stderr, "usage: %s [--run-id <id>]\n", argv[0]);
            return 2;
        }
    }

    setvbuf(stdout, NULL, _IONBF, 0);

    void *mem = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (mem == MAP_FAILED) {
        printf("%s id=%s case=discover verdict=FAIL reason=mmap_errno_%d\n",
               TOKEN_PREFIX,
               run_id,
               errno);
        printf("%s id=%s passed=0 failed=1 verdict=FAIL\n", TOKEN_SUMMARY, run_id);
        printf("%s\n", TOKEN_FAIL);
        return 1;
    }
    if (((uint64_t) (uintptr_t) mem & (0xffffULL << 48)) != 0) {
        printf(
            "%s id=%s case=discover verdict=FAIL reason=nonzero_top_bits\n", TOKEN_PREFIX, run_id);
        printf("%s id=%s passed=0 failed=1 verdict=FAIL\n", TOKEN_SUMMARY, run_id);
        printf("%s\n", TOKEN_FAIL);
        munmap(mem, 4096);
        return 1;
    }

    volatile uint64_t *slots = (volatile uint64_t *) mem;
    uint8_t *page = (uint8_t *) mem;

    int passed = 0;
    int failed = 0;
    if (check_discover(run_id))
        passed++;
    else
        failed++;
    if (check_pmlen7(run_id, slots))
        passed++;
    else
        failed++;
    if (check_pmlen16(run_id, slots, page))
        passed++;
    else
        failed++;
    if (check_disable_fault(run_id, slots))
        passed++;
    else
        failed++;

    munmap(mem, 4096);

    printf("%s id=%s passed=%d failed=%d verdict=%s\n",
           TOKEN_SUMMARY,
           run_id,
           passed,
           failed,
           failed == 0 ? "PASS" : "FAIL");
    printf("%s\n", failed == 0 ? TOKEN_PASS : TOKEN_FAIL);
    return failed == 0 ? 0 : 1;
}
