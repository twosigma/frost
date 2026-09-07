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
 * frost_sigprobe: signal-return probe for the MMU lane.
 *
 * On the MMU lane's first board boot, busybox's rcS and the login shell died
 * with SIGILL at the vDSO sigreturn trampoline right after a child exit,
 * while frost_stress's SIGALRM returns were fine. This probe runs the
 * suspect variants, each in a forked runner so a crash is reported instead
 * of ending the probe, and prints one line per variant:
 *
 *   FROST_SIGPROBE v<n> <name>: ok | signal <k> | exit <k>
 *
 * Variants (busybox's shell installs handlers with sa_flags = 0 and a full
 * sa_mask, no SA_RESTART):
 *   v0  SIGALRM from setitimer, flags 0, empty mask (the stress's shape)
 *   v1  SIGCHLD, flags 0, full mask; child _exit(0); parent in waitpid
 *   v2  v1, but the child execs /bin/true (exec + exit, the shell's shape)
 *   v3  v1 with an empty mask
 *   v4  v1 with SA_RESTART
 *   v5  v1 after touching the vDSO (clock_gettime) first
 *   v6  v2 repeated five times (five child exits, five signal returns)
 * The board's first probe run died in v1/v3/v4/v5 and survived v2/v6: the
 * dying variants have the child exit while the parent is still inside
 * musl's post-fork signal unblock, before any user-mode store to the
 * parent's copy-on-write-protected stack, so the kernel's write of the
 * signal frame is the first write and faults in S-mode. These isolate that:
 *   v7  v1 with SIGCHLD blocked across the fork; the parent touches its
 *       stack (user-mode copy-on-write fault) before unblocking
 *   v8  v7, but the parent touches its heap instead of its stack
 *   v9  no fork: SIGALRM delivered onto a fresh, never-written alternate
 *       signal stack (the frame write is a kernel-mode first touch)
 *   v10 v9 with the alternate stack touched first
 */

#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/time.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static volatile sig_atomic_t g_got;

static void handler(int signo)
{
    (void) signo;
    g_got = 1;
}

static int install(int signo, int flags, int full_mask)
{
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = handler;
    sa.sa_flags = flags;
    if (full_mask)
        sigfillset(&sa.sa_mask);
    else
        sigemptyset(&sa.sa_mask);
    return sigaction(signo, &sa, NULL);
}

static int child_exit_now(void)
{
    _exit(0);
}

static int child_exec_true(void)
{
    execl("/bin/true", "true", (char *) NULL);
    _exit(127);
}

/* Fork a child, wait for it in waitpid while SIGCHLD's handler runs. */
static int one_round(int (*child_fn)(void))
{
    int status = 0;
    pid_t pid = fork();
    if (pid < 0)
        return 10;
    if (pid == 0)
        child_fn();
    g_got = 0;
    while (waitpid(pid, &status, 0) < 0) {
        /* EINTR after the handler: retry (sa_flags has no SA_RESTART) */
    }
    return (WIFEXITED(status) && WEXITSTATUS(status) == 0) ? 0 : 11;
}

/* v7/v8: fork with SIGCHLD blocked, touch a page in user mode, unblock. */
static int blocked_fork_round(int touch_stack)
{
    volatile unsigned long stack_word = 0;
    static volatile unsigned long *heap;
    sigset_t chld, old;
    int status = 0;
    pid_t pid;
    sigemptyset(&chld);
    sigaddset(&chld, SIGCHLD);
    if (install(SIGCHLD, 0, 1) != 0)
        return 20;
    if (sigprocmask(SIG_BLOCK, &chld, &old) != 0)
        return 23;
    pid = fork();
    if (pid < 0)
        return 10;
    if (pid == 0)
        _exit(0);
    if (touch_stack) {
        stack_word = 1; /* the parent's first post-fork stack write, from U */
    } else {
        if (heap == NULL)
            heap = malloc(64);
        *heap = 1;
    }
    g_got = 0;
    sigprocmask(SIG_SETMASK, &old, NULL); /* SIGCHLD delivered here */
    while (waitpid(pid, &status, 0) < 0) {
    }
    if (touch_stack && stack_word != 1)
        return 12;
    return (WIFEXITED(status) && WEXITSTATUS(status) == 0) ? 0 : 11;
}

/* v9/v10: SIGALRM onto an alternate signal stack, fresh or pre-touched. */
static int altstack_round(int touch_first)
{
    struct sigaction sa;
    struct itimerval itv;
    struct timespec nap = {0, 20 * 1000 * 1000};
    stack_t ss;
    size_t len = 64 * 1024;
    void *mem = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (mem == MAP_FAILED)
        return 24;
    if (touch_first)
        memset(mem, 0, len);
    ss.ss_sp = mem;
    ss.ss_size = len;
    ss.ss_flags = 0;
    if (sigaltstack(&ss, NULL) != 0)
        return 25;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = handler;
    sa.sa_flags = SA_ONSTACK;
    sigemptyset(&sa.sa_mask);
    if (sigaction(SIGALRM, &sa, NULL) != 0)
        return 20;
    memset(&itv, 0, sizeof(itv));
    itv.it_value.tv_usec = 5000;
    if (setitimer(ITIMER_REAL, &itv, NULL) != 0)
        return 21;
    g_got = 0;
    nanosleep(&nap, NULL);
    return g_got ? 0 : 22;
}

static int variant(int v)
{
    struct timespec ts;
    switch (v) {
        case 0: {
            struct itimerval itv;
            struct timespec nap = {0, 20 * 1000 * 1000};
            if (install(SIGALRM, 0, 0) != 0)
                return 20;
            memset(&itv, 0, sizeof(itv));
            itv.it_value.tv_usec = 5000;
            if (setitimer(ITIMER_REAL, &itv, NULL) != 0)
                return 21;
            g_got = 0;
            nanosleep(&nap, NULL);
            return g_got ? 0 : 22;
        }
        case 1:
            if (install(SIGCHLD, 0, 1) != 0)
                return 20;
            return one_round(child_exit_now);
        case 2:
            if (install(SIGCHLD, 0, 1) != 0)
                return 20;
            return one_round(child_exec_true);
        case 3:
            if (install(SIGCHLD, 0, 0) != 0)
                return 20;
            return one_round(child_exit_now);
        case 4:
            if (install(SIGCHLD, SA_RESTART, 1) != 0)
                return 20;
            return one_round(child_exit_now);
        case 5:
            clock_gettime(CLOCK_MONOTONIC, &ts); /* vDSO touch */
            if (install(SIGCHLD, 0, 1) != 0)
                return 20;
            return one_round(child_exit_now);
        case 6: {
            int r = 0;
            if (install(SIGCHLD, 0, 1) != 0)
                return 20;
            for (int i = 0; i < 5 && r == 0; i++)
                r = one_round(child_exec_true);
            return r;
        }
        case 7:
            return blocked_fork_round(1);
        case 8:
            return blocked_fork_round(0);
        case 9:
            return altstack_round(0);
        case 10:
            return altstack_round(1);
        default:
            return 30;
    }
}

static const char *const g_names[] = {
    "sigalrm-flags0",
    "sigchld-fullmask-exit",
    "sigchld-fullmask-exec",
    "sigchld-emptymask",
    "sigchld-sa_restart",
    "sigchld-after-vdso-touch",
    "sigchld-exec-x5",
    "sigchld-blocked-fork-stack-touched",
    "sigchld-blocked-fork-heap-touched",
    "sigalrm-altstack-fresh",
    "sigalrm-altstack-touched",
};
#define N_VARIANTS 11

int main(int argc, char **argv)
{
    int only = (argc > 1) ? atoi(argv[1]) : -1;
    setvbuf(stdout, NULL, _IONBF, 0);
    printf("FROST_SIGPROBE: starting\n");
    for (int v = 0; v < N_VARIANTS; v++) {
        pid_t runner;
        int status = 0;
        if (only >= 0 && v != only)
            continue;
        runner = fork();
        if (runner < 0) {
            printf("FROST_SIGPROBE v%d %s: fork failed\n", v, g_names[v]);
            continue;
        }
        if (runner == 0)
            _exit(variant(v));
        while (waitpid(runner, &status, 0) < 0) {
        }
        if (WIFSIGNALED(status))
            printf("FROST_SIGPROBE v%d %s: signal %d\n", v, g_names[v], WTERMSIG(status));
        else if (WIFEXITED(status) && WEXITSTATUS(status) == 0)
            printf("FROST_SIGPROBE v%d %s: ok\n", v, g_names[v]);
        else
            printf("FROST_SIGPROBE v%d %s: exit %d\n", v, g_names[v], WEXITSTATUS(status));
    }
    printf("FROST_SIGPROBE: done\n");
    return 0;
}
