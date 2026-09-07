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
 */

#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
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
};

int main(int argc, char **argv)
{
    int only = (argc > 1) ? atoi(argv[1]) : -1;
    setvbuf(stdout, NULL, _IONBF, 0);
    printf("FROST_SIGPROBE: starting\n");
    for (int v = 0; v < 7; v++) {
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
