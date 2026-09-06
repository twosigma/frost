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
 * FROST userspace boot stress payload. Two editions from one source:
 *
 *   - no-MMU / bFLT (the M-mode kernel lane): the original vfork/rdcycle
 *     payload.
 *   - MMU (FROST_STRESS_MMU, set by frost-stress.mk when BR2_USE_MMU): the
 *     Phase 3 OpenSBI + Sv39 lane, with real fork, copy-on-write and mmap
 *     phases, and the counter phase through perf_event_open.
 *
 * Inittab runs this once after rcS and before the getty. It prints a
 * machine-readable summary and a token checked by QEMU CI and hardware soaks:
 *
 *   FROST_USERSPACE_STRESS: ticks=.. vforks=.. futex=.. atomics=..
 *       cycles=.. instret=.. time=.. ipc_x1000=.. verdict=..
 *   FROST_USERSPACE_STRESS_PASS   (or _FAIL)
 *
 * (the MMU edition reports forks=.. and pages=.. beside them). If the
 * counters cannot be read, the counter fields become
 * ``counters=unavailable`` (phase 5).
 *
 * Phases:
 *   1. A 5 ms SIGALRM storm covers timer traps and signal delivery.
 *   2. Repeated vfork+exec exercises no-MMU process creation, bFLT loading,
 *      and scheduling. MMU: fork+exec plus a fork whose child rewrites the
 *      parent's heap copy, which must stay intact (copy-on-write), and an
 *      anonymous mapping walked page by page (demand faults).
 *   3. FUTEX_WAIT/FUTEX_WAKE ping-pong over a MAP_SHARED file mapping covers
 *      the shared-memory and wait-queue paths.
 *   4. Two processes contend on an LR/SC counter while timer IRQs preempt them;
 *      the final count must be exact.
 *   5. Counter deltas and ipc_x1000 around a fixed workload. no-MMU:
 *      rdcycle/rdinstret/rdtime (FROST resets mcounteren to 0x7; QEMU leaves
 *      the counters U-inaccessible, and a SIGILL guard reports them
 *      unavailable). MMU: cycles and instructions through perf_event_open
 *      (the SBI PMU on the fixed counters; the 6.18 kernel keeps direct
 *      rdcycle from userspace disabled), plus rdtime.
 *
 * Exit code 0 means PASS. Failures print verdict=FAIL(reason) and exit nonzero;
 * inittab ignores the status, so consumers must check the token.
 */

#include <fcntl.h>
#include <setjmp.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <sys/time.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#ifdef FROST_STRESS_MMU
#include <linux/perf_event.h>
#include <sys/ioctl.h>
#endif

#define SHM_PATH "/frost_stress.shm"
#define TICK_TARGET 60
#define VFORK_CHILDREN 12
#define FUTEX_ROUNDS 64
#define ATOMIC_INCS 20000u
#define COUNTER_WORK_ITERS 200000u

/* Shared page layout (MAP_SHARED file mapping on the initramfs ramfs). */
struct shared {
    volatile uint32_t futex_word; /* ping-pong turn: 0 = parent, 1 = child */
    volatile uint32_t rounds_child;
    volatile uint32_t counter;    /* LR/SC contention target              */
    volatile uint32_t child_done; /* child's atomics phase complete       */
    volatile uint32_t go;         /* barrier: parent releases the child   */
};

static volatile sig_atomic_t g_ticks;

static void alarm_handler(int sig)
{
    (void) sig;
    g_ticks++;
}

/* ---- Zicntr counter access (phase 5) ---- */

/* Numeric addresses under a zicsr arch push make these independent of -march.
 * .option arch needs binutils >= 2.38; the pinned Buildroot ships 2.4x. */
#define RD_CSR(num)                                                                                \
    ({                                                                                             \
        unsigned long __v;                                                                         \
        __asm__ volatile(".option push\n"                                                          \
                         ".option arch, +zicsr\n"                                                  \
                         "csrr %0, " #num "\n"                                                     \
                         ".option pop"                                                             \
                         : "=r"(__v));                                                             \
        __v;                                                                                       \
    })

/* Full-width CSRs; the rv32 *h addresses trap on FROST. time is readable
 * from userspace in both editions (the 6.18 kernel leaves scounteren.TM set). */
static uint64_t read_time64(void)
{
    return RD_CSR(0xc01);
}

#ifndef FROST_STRESS_MMU
static uint64_t read_cycle64(void)
{
    return RD_CSR(0xc00);
}

static uint64_t read_instret64(void)
{
    return RD_CSR(0xc02);
}

/* QEMU leaves these inaccessible in U-mode; escape SIGILL and report them
 * unavailable. */
static sigjmp_buf g_counter_jmp;

static void illegal_insn_handler(int sig)
{
    (void) sig;
    siglongjmp(g_counter_jmp, 1);
}
#endif

/* Fixed measured workload. The volatile sink prevents elision; each iteration
 * retires at least one instruction, providing the instret lower bound. */
static volatile uint32_t g_work_sink;

static void counter_workload(void)
{
    uint32_t x = 0x1234567u;
    for (uint32_t i = 0; i < COUNTER_WORK_ITERS; i++)
        x = x * 1664525u + 1013904223u;
    g_work_sink = x;
}

/* riscv32 has only the 64-bit-time futex syscall; untimed ops (NULL
 * timeout) make the two interchangeable. */
static long futex(volatile uint32_t *addr, int op, uint32_t val)
{
#ifdef SYS_futex
    return syscall(SYS_futex, addr, op, val, NULL, NULL, 0);
#else
    return syscall(SYS_futex_time64, addr, op, val, NULL, NULL, 0);
#endif
}
#define FUTEX_WAIT_OP 0
#define FUTEX_WAKE_OP 1

static struct shared *map_shared(int create)
{
    int flags = create ? (O_RDWR | O_CREAT | O_TRUNC) : O_RDWR;
    int fd = open(SHM_PATH, flags, 0600);
    if (fd < 0)
        return NULL;
    if (create && ftruncate(fd, 4096) != 0) {
        close(fd);
        return NULL;
    }
    void *p = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    return (p == MAP_FAILED) ? NULL : (struct shared *) p;
}

/* ---- child mode: --child <n> does brief work and exits with a code ---- */
static int run_exec_child(const char *arg)
{
    unsigned n = (unsigned) atoi(arg);
    volatile unsigned acc = n;
    for (unsigned i = 0; i < 5000; i++)
        acc = acc * 1664525u + 1013904223u;
    struct timespec ts = {0, 1000000}; /* 1 ms: bounce through the scheduler */
    nanosleep(&ts, NULL);
    return (int) ((n + (acc & 0)) % 64); /* deterministic per-child status */
}

/* ---- child mode: --stress-child runs the futex + atomics peer ---- */
static int run_stress_child(void)
{
    struct shared *sh = map_shared(0);
    if (!sh)
        return 97;

    /* Futex ping-pong: child waits for turn 1, flips to 0, wakes parent. */
    for (int r = 0; r < FUTEX_ROUNDS; r++) {
        while (__atomic_load_n(&sh->futex_word, __ATOMIC_ACQUIRE) != 1)
            futex(&sh->futex_word, FUTEX_WAIT_OP, 0);
        sh->rounds_child++;
        __atomic_store_n(&sh->futex_word, 0, __ATOMIC_RELEASE);
        futex(&sh->futex_word, FUTEX_WAKE_OP, 1);
    }

    /* Barrier, then LR/SC contention. */
    while (__atomic_load_n(&sh->go, __ATOMIC_ACQUIRE) == 0)
        futex(&sh->go, FUTEX_WAIT_OP, 0);
    for (uint32_t i = 0; i < ATOMIC_INCS; i++)
        __atomic_fetch_add(&sh->counter, 1, __ATOMIC_RELAXED);
    __atomic_store_n(&sh->child_done, 1, __ATOMIC_RELEASE);
    futex(&sh->child_done, FUTEX_WAKE_OP, 1);
    return 0;
}

static const char *g_self; /* argv[0]: exec target for children */

static pid_t spawn(const char *mode, const char *arg)
{
#ifdef FROST_STRESS_MMU
    pid_t pid = fork();
#else
    pid_t pid = vfork();
#endif
    if (pid == 0) {
        char *argv[4];
        argv[0] = (char *) g_self;
        argv[1] = (char *) mode;
        argv[2] = (char *) arg;
        argv[3] = NULL;
        execv(g_self, argv);
        _exit(126);
    }
    return pid;
}

#ifdef FROST_STRESS_MMU
/* ---- MMU-only phases: copy-on-write, demand paging, perf counters ---- */

#define COW_BYTES (64 * 1024)
#define ANON_PAGES 256

/* fork() without exec: the child rewrites a heap buffer and exits with a
 * checksum of what it wrote; the parent's copy must be untouched. Returns
 * the number of successful forks (2 expected), 0 on any failure. */
static int cow_phase(void)
{
    uint8_t *buf = malloc(COW_BYTES);
    if (!buf)
        return 0;
    for (int i = 0; i < COW_BYTES; i++)
        buf[i] = (uint8_t) (i * 7);
    int forks = 0;
    for (int round = 0; round < 2; round++) {
        pid_t pid = fork();
        if (pid < 0)
            return 0;
        if (pid == 0) {
            unsigned sum = 0;
            for (int i = 0; i < COW_BYTES; i++) {
                buf[i] = (uint8_t) (i ^ round);
                sum += buf[i];
            }
            _exit((int) (sum & 0x3f));
        }
        int st = 0;
        if (waitpid(pid, &st, 0) != pid || !WIFEXITED(st))
            return 0;
        unsigned want = 0;
        for (int i = 0; i < COW_BYTES; i++)
            want += (uint8_t) (i ^ round);
        if (WEXITSTATUS(st) != (int) (want & 0x3f))
            return 0;
        for (int i = 0; i < COW_BYTES; i++)
            if (buf[i] != (uint8_t) (i * 7))
                return 0; /* the child's writes leaked into the parent */
        forks++;
    }
    free(buf);
    return forks;
}

/* Anonymous mapping walked page by page: each first touch is a demand fault
 * through the page-table walker, each write a store fault (Svade). Returns
 * the page count on success, 0 on failure. */
static int anon_phase(void)
{
    size_t len = (size_t) ANON_PAGES * 4096;
    uint8_t *p = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (p == MAP_FAILED)
        return 0;
    for (int i = 0; i < ANON_PAGES; i++) {
        if (p[(size_t) i * 4096] != 0) /* fresh anonymous pages read as zero */
            return 0;
        p[(size_t) i * 4096 + 17] = (uint8_t) i;
    }
    for (int i = 0; i < ANON_PAGES; i++)
        if (p[(size_t) i * 4096 + 17] != (uint8_t) i)
            return 0;
    if (munmap(p, len) != 0)
        return 0;
    return ANON_PAGES;
}

static int perf_open(uint32_t config)
{
    struct perf_event_attr attr;
    memset(&attr, 0, sizeof(attr));
    attr.type = PERF_TYPE_HARDWARE;
    attr.size = sizeof(attr);
    attr.config = config;
    attr.disabled = 1;
    /* No :u/:k filtering: the SBI PMU without Sscofpmf advertises none. */
    return (int) syscall(SYS_perf_event_open, &attr, 0, -1, -1, 0);
}

static int perf_read(int fd, uint64_t *value)
{
    return read(fd, value, sizeof(*value)) == (ssize_t) sizeof(*value) ? 0 : -1;
}
#endif

static int fail(const char *reason)
{
    printf("FROST_USERSPACE_STRESS: verdict=FAIL(%s)\n", reason);
    printf("FROST_USERSPACE_STRESS_FAIL\n");
    fflush(stdout);
    return 1;
}

int main(int argc, char **argv)
{
    g_self = argv[0];
    if (argc >= 3 && strcmp(argv[1], "--child") == 0)
        return run_exec_child(argv[2]);
    if (argc >= 2 && strcmp(argv[1], "--stress-child") == 0)
        return run_stress_child();

    printf("FROST_USERSPACE_STRESS: starting\n");
    fflush(stdout);

    /* ---- Phase 1: timer storm + signal delivery ---- */
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = alarm_handler;
    if (sigaction(SIGALRM, &sa, NULL) != 0)
        return fail("sigaction");
    struct itimerval itv = {{0, 5000}, {0, 5000}}; /* 5 ms period */
    if (setitimer(ITIMER_REAL, &itv, NULL) != 0)
        return fail("setitimer");
    struct timespec ts = {0, 2000000};
    /* Bounded wait: 5 ms x TICK_TARGET plus generous slack. */
    for (int spins = 0; g_ticks < TICK_TARGET && spins < 4000; spins++)
        nanosleep(&ts, NULL); /* EINTR on each tick is expected */
    memset(&itv, 0, sizeof(itv));
    setitimer(ITIMER_REAL, &itv, NULL);
    int ticks = g_ticks;
    if (ticks < TICK_TARGET)
        return fail("timer-ticks");

    /* ---- Phase 2: vfork/exec context switching (MMU: fork/exec) ---- */
    int vforks = 0;
#ifdef FROST_STRESS_MMU
    int forks = cow_phase();
    if (forks != 2)
        return fail("cow");
    int pages = anon_phase();
    if (pages != ANON_PAGES)
        return fail("mmap-anon");
#endif
    for (int i = 0; i < VFORK_CHILDREN; i++) {
        char nbuf[8];
        snprintf(nbuf, sizeof(nbuf), "%d", i);
        pid_t pid = spawn("--child", nbuf);
        if (pid < 0)
            return fail("vfork");
        int st = 0;
        if (waitpid(pid, &st, 0) != pid || !WIFEXITED(st))
            return fail("waitpid");
        if (WEXITSTATUS(st) != i % 64)
            return fail("child-status");
        vforks++;
    }

    /* ---- Phases 3+4: shared-memory peer (futex, then LR/SC) ---- */
    struct shared *sh = map_shared(1);
    if (!sh)
        return fail("mmap-shared");
    memset((void *) sh, 0, sizeof(*sh));
    pid_t peer = spawn("--stress-child", "0");
    if (peer < 0)
        return fail("vfork-peer");

    int futex_rounds = 0;
    for (int r = 0; r < FUTEX_ROUNDS; r++) {
        __atomic_store_n(&sh->futex_word, 1, __ATOMIC_RELEASE);
        futex(&sh->futex_word, FUTEX_WAKE_OP, 1);
        while (__atomic_load_n(&sh->futex_word, __ATOMIC_ACQUIRE) != 0)
            futex(&sh->futex_word, FUTEX_WAIT_OP, 1);
        futex_rounds++;
    }
    if (sh->rounds_child != FUTEX_ROUNDS)
        return fail("futex-rounds");

    __atomic_store_n(&sh->go, 1, __ATOMIC_RELEASE);
    futex(&sh->go, FUTEX_WAKE_OP, 1);
    for (uint32_t i = 0; i < ATOMIC_INCS; i++)
        __atomic_fetch_add(&sh->counter, 1, __ATOMIC_RELAXED);
    while (__atomic_load_n(&sh->child_done, __ATOMIC_ACQUIRE) == 0)
        futex(&sh->child_done, FUTEX_WAIT_OP, 0);

    int st = 0;
    if (waitpid(peer, &st, 0) != peer || !WIFEXITED(st) || WEXITSTATUS(st) != 0)
        return fail("peer-exit");
    uint32_t total = __atomic_load_n(&sh->counter, __ATOMIC_ACQUIRE);
    if (total != 2u * ATOMIC_INCS)
        return fail("atomic-count");
    munmap((void *) sh, 4096);
    unlink(SHM_PATH);

    /* ---- Phase 5: counter deltas around a fixed workload ---- */
    /* Measure after disarming the timer and reaping children. */
    uint64_t dc = 0, dt = 0, di = 0;
    int counters_ok = 0;
#ifdef FROST_STRESS_MMU
    int fd_cycles = perf_open(PERF_COUNT_HW_CPU_CYCLES);
    int fd_instr = perf_open(PERF_COUNT_HW_INSTRUCTIONS);
    if (fd_cycles >= 0 && fd_instr >= 0) {
        uint64_t c0 = 0, c1 = 0, i0 = 0, i1 = 0;
        ioctl(fd_cycles, PERF_EVENT_IOC_RESET, 0);
        ioctl(fd_instr, PERF_EVENT_IOC_RESET, 0);
        ioctl(fd_cycles, PERF_EVENT_IOC_ENABLE, 0);
        ioctl(fd_instr, PERF_EVENT_IOC_ENABLE, 0);
        uint64_t t0 = read_time64();
        counter_workload();
        uint64_t t1 = read_time64();
        ioctl(fd_cycles, PERF_EVENT_IOC_DISABLE, 0);
        ioctl(fd_instr, PERF_EVENT_IOC_DISABLE, 0);
        if (perf_read(fd_cycles, &c1) == 0 && perf_read(fd_instr, &i1) == 0) {
            dc = c1 - c0;
            di = i1 - i0;
            dt = t1 - t0;
            counters_ok = 1;
        }
    }
    if (fd_cycles >= 0)
        close(fd_cycles);
    if (fd_instr >= 0)
        close(fd_instr);
#else
    struct sigaction ill_sa;
    memset(&ill_sa, 0, sizeof(ill_sa));
    ill_sa.sa_handler = illegal_insn_handler;
    if (sigaction(SIGILL, &ill_sa, NULL) != 0)
        return fail("sigaction-counters");
    if (sigsetjmp(g_counter_jmp, 1) == 0) {
        uint64_t c0 = read_cycle64();
        uint64_t t0 = read_time64();
        uint64_t i0 = read_instret64();
        counter_workload();
        uint64_t c1 = read_cycle64();
        uint64_t t1 = read_time64();
        uint64_t i1 = read_instret64();
        dc = c1 - c0;
        dt = t1 - t0;
        di = i1 - i0;
        counters_ok = 1;
    }
    signal(SIGILL, SIG_DFL);
#endif
    if (counters_ok) {
        /* Readable counters require sane deltas. */
        if (dc == 0)
            return fail("counter-cycle-delta");
        if (dt == 0)
            return fail("counter-time-delta");
        if (di < COUNTER_WORK_ITERS)
            return fail("counter-instret-delta");
    }

#ifdef FROST_STRESS_MMU
    printf("FROST_USERSPACE_STRESS: forks=%d pages=%d ", forks, pages);
#else
    printf("FROST_USERSPACE_STRESS: ");
#endif
    if (counters_ok) {
        printf("ticks=%d vforks=%d futex=%d atomics=%u "
               "cycles=%llu instret=%llu time=%llu ipc_x1000=%u verdict=PASS\n",
               ticks,
               vforks,
               futex_rounds,
               total,
               (unsigned long long) dc,
               (unsigned long long) di,
               (unsigned long long) dt,
               (unsigned) (di * 1000u / dc));
    } else {
        printf("ticks=%d vforks=%d futex=%d atomics=%u "
               "counters=unavailable verdict=PASS\n",
               ticks,
               vforks,
               futex_rounds,
               total);
    }
    printf("FROST_USERSPACE_STRESS_PASS\n");
    fflush(stdout);
    return 0;
}
