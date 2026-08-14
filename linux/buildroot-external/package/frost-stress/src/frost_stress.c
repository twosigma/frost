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
 * FROST userspace boot stress payload (rv64 / no-MMU / bFLT).
 *
 * Run once at boot from inittab (::sysinit:/usr/bin/frost_stress --boot),
 * after rcS and before the getty. Exercises the kernel/core surfaces the
 * banner-level boot checks cannot see, then prints one machine-readable
 * verdict line plus a stable grep token that the QEMU CI job and the
 * hardware soak assert on:
 *
 *   FROST_USERSPACE_STRESS: ticks=.. vforks=.. futex=.. atomics=..
 *       cycles=.. instret=.. time=.. ipc_x1000=.. verdict=..
 *   FROST_USERSPACE_STRESS_PASS   (or _FAIL)
 *
 * (When the Zicntr counters are not U-readable the four counter fields
 * are replaced by ``counters=unavailable``; see phase 5.)
 *
 * Phases:
 *   1. Timer storm + signals: setitimer(ITIMER_REAL) at 5 ms, a SIGALRM
 *      handler counts >= 60 ticks (trap entry/exit + signal delivery under
 *      the periodic CLINT tick -- the surface the retired restore-window
 *      kernel patch used to mutate).
 *   2. Context switching: vfork+execve self as "--child" repeatedly and
 *      reap exit statuses (no-MMU has no fork; vfork+exec is the real
 *      process-creation path, exercising bFLT load + exec + scheduler).
 *   3. Futex ping-pong: parent and an exec'd child share a MAP_SHARED
 *      file mapping (the no-MMU shared-memory path) and alternate
 *      FUTEX_WAIT/FUTEX_WAKE for N rounds (sleep/wake + wait queues).
 *   4. LR/SC contention: both processes atomically increment a shared
 *      counter with no lock; the total must be exact. Preemption by the
 *      timer tick lands interrupts inside LR/SC windows and AMO traffic
 *      (the AMO-shield path) in real userspace.
 *   5. Zicntr counters: rdcycle/rdinstret/rdtime 64-bit deltas around a
 *      fixed integer workload, reported as cycles/instret/time plus
 *      ipc_x1000 -- per-boot quantitative regression evidence. On FROST
 *      the counters are U-readable out of reset (mcounteren resets to
 *      0x7), so the deltas are asserted; under QEMU mcounteren resets to
 *      0 and the M-mode kernel never sets it, so the first read raises an
 *      illegal-instruction signal -- a guard catches it and the phase
 *      degrades to ``counters=unavailable`` without failing the verdict.
 *
 * Exit code 0 on PASS. Any phase failure prints verdict=FAIL(reason) and
 * exits nonzero (inittab sysinit ignores it; the token is the signal).
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

/* Numeric CSR addresses under an explicit zicsr arch push so the reads
 * assemble regardless of the toolchain's -march spelling (.option arch
 * needs binutils >= 2.38; the pinned Buildroot ships 2.4x). The read is
 * XLEN-natural (unsigned long). */
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

/* The counters are single full-width CSRs (the rv32 *h addresses do not
 * exist and trap on FROST) — one csrr each (D12). */
static uint64_t read_cycle64(void)
{
    return RD_CSR(0xc00);
}

static uint64_t read_time64(void)
{
    return RD_CSR(0xc01);
}

static uint64_t read_instret64(void)
{
    return RD_CSR(0xc02);
}

/* Illegal-instruction guard: under QEMU the counter CSRs are not U-readable
 * (mcounteren resets to 0 there and the M-mode kernel never sets it), so the
 * first read dies with an illegal-instruction signal; longjmp out and report
 * the counters as unavailable instead. */
static sigjmp_buf g_counter_jmp;

static void illegal_insn_handler(int sig)
{
    (void) sig;
    siglongjmp(g_counter_jmp, 1);
}

/* Fixed integer workload the counter deltas are measured around; the
 * volatile sink keeps it un-elidable. Every iteration is at least one
 * retired instruction, giving a safe instret lower bound. */
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
    pid_t pid = vfork();
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

    /* ---- Phase 2: vfork/exec context switching ---- */
    int vforks = 0;
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

    /* ---- Phase 5: Zicntr counter deltas around a fixed workload ---- */
    /* Runs after the other phases so the system is quiet (timer disarmed,
     * children reaped); interrupts still land in the deltas, which is fine
     * for boot-level regression evidence. */
    uint64_t dc = 0, dt = 0, di = 0;
    int counters_ok = 0;
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
    if (counters_ok) {
        /* Counters readable: the deltas must be sane, else the counter
         * plumbing regressed and the boot must FAIL. */
        if (dc == 0)
            return fail("counter-cycle-delta");
        if (dt == 0)
            return fail("counter-time-delta");
        if (di < COUNTER_WORK_ITERS)
            return fail("counter-instret-delta");
    }

    if (counters_ok) {
        printf("FROST_USERSPACE_STRESS: ticks=%d vforks=%d futex=%d atomics=%u "
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
        printf("FROST_USERSPACE_STRESS: ticks=%d vforks=%d futex=%d atomics=%u "
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
