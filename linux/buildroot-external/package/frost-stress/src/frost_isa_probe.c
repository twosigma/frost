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
 * RISC-V ISA discovery and extended register-state probe.
 *
 * Queries the ISA extensions the kernel exposes through the live device tree,
 * /proc/cpuinfo, riscv_hwprobe, AT_HWCAP, and prctl, then selects the matching
 * verification matrix:
 *
 *   - When the kernel reports the optional RISC-V V extension: checks
 *     discovery and instruction smoke, two-process same-hart context switches,
 *     normal and alternate-stack signal frames and returns, ptrace regsets,
 *     ELF core notes, fork policy and state isolation, exec reset and policy
 *     inheritance, and lazy first-use handling via tracefs.
 *   - When the kernel reports the extension absent: checks that all discovery
 *     surfaces agree on absence, that the probed instruction raises SIGILL at
 *     its exact PC, that signal frames carry no extended state record, and
 *     that the extended ptrace regset returns EINVAL.
 *
 * Built for RV64GC/LP64D with extended instructions confined to leaf routines
 * in frost_isa_probe_asm.S so startup, C code, and libc stay scalar.
 */

#define _GNU_SOURCE

#include <ctype.h>
#include <dirent.h>
#include <elf.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <linux/futex.h>
#include <sched.h>
#include <setjmp.h>
#include <signal.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/prctl.h>
#include <sys/ptrace.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/uio.h>
#include <sys/utsname.h>
#include <sys/wait.h>
#include <time.h>
#include <ucontext.h>
#include <unistd.h>

#if defined(__riscv) && !defined(FROST_ISA_PROBE_HOST_SELFTEST)
#include <asm/hwcap.h>
#if defined(__has_include) && __has_include(<asm/hwprobe.h>)
#include <asm/hwprobe.h>
#else
struct riscv_hwprobe {
    int64_t key;
    uint64_t value;
};
#endif
#include <asm/ptrace.h>
#ifndef RISCV_MAX_VLENB
struct __riscv_ctx_hdr {
    uint32_t magic;
    uint32_t size;
};

struct __riscv_extra_ext_header {
    uint32_t __padding[129] __attribute__((aligned(16)));
    uint32_t reserved;
    struct __riscv_ctx_hdr hdr;
};

struct __riscv_v_ext_state {
    unsigned long vstart;
    unsigned long vl;
    unsigned long vtype;
    unsigned long vcsr;
    unsigned long vlenb;
    void *datap;
};
#define RISCV_MAX_VLENB (8192)
#endif
#include <sys/auxv.h>
#endif

#ifndef RISCV_V_MAGIC
#define RISCV_V_MAGIC 0x53465457U
#endif
#ifndef END_MAGIC
#define END_MAGIC 0x0U
#endif
#ifndef END_HDR_SIZE
#define END_HDR_SIZE 0x0U
#endif
#ifndef NT_PRSTATUS
#define NT_PRSTATUS 1
#endif
#ifndef NT_RISCV_VECTOR
#define NT_RISCV_VECTOR 0x901
#endif
#ifndef ENODATA
#define ENODATA 61
#endif
#ifndef AT_MINSIGSTKSZ
#define AT_MINSIGSTKSZ 51
#endif
#ifndef __NR_riscv_hwprobe
#define __NR_riscv_hwprobe 258
#endif
#ifndef PR_RISCV_V_SET_CONTROL
#define PR_RISCV_V_SET_CONTROL 69
#endif
#ifndef PR_RISCV_V_GET_CONTROL
#define PR_RISCV_V_GET_CONTROL 70
#endif
#ifndef PR_RISCV_V_VSTATE_CTRL_DEFAULT
#define PR_RISCV_V_VSTATE_CTRL_DEFAULT 0
#endif
#ifndef PR_RISCV_V_VSTATE_CTRL_OFF
#define PR_RISCV_V_VSTATE_CTRL_OFF 1
#endif
#ifndef PR_RISCV_V_VSTATE_CTRL_ON
#define PR_RISCV_V_VSTATE_CTRL_ON 2
#endif
#ifndef PR_RISCV_V_VSTATE_CTRL_INHERIT
#define PR_RISCV_V_VSTATE_CTRL_INHERIT (1 << 4)
#endif
#ifndef PR_RISCV_V_VSTATE_CTRL_CUR_MASK
#define PR_RISCV_V_VSTATE_CTRL_CUR_MASK 0x3
#endif
#ifndef PR_RISCV_V_VSTATE_CTRL_NEXT_MASK
#define PR_RISCV_V_VSTATE_CTRL_NEXT_MASK 0xc
#endif
#ifndef PR_RISCV_V_VSTATE_CTRL_MASK
#define PR_RISCV_V_VSTATE_CTRL_MASK 0x1f
#endif
#ifndef COMPAT_HWCAP_ISA_I
#define COMPAT_HWCAP_ISA_I (1UL << ('I' - 'A'))
#define COMPAT_HWCAP_ISA_M (1UL << ('M' - 'A'))
#define COMPAT_HWCAP_ISA_A (1UL << ('A' - 'A'))
#define COMPAT_HWCAP_ISA_F (1UL << ('F' - 'A'))
#define COMPAT_HWCAP_ISA_D (1UL << ('D' - 'A'))
#define COMPAT_HWCAP_ISA_C (1UL << ('C' - 'A'))
#endif
#ifndef COMPAT_HWCAP_ISA_V
#define COMPAT_HWCAP_ISA_V (1UL << ('V' - 'A'))
#endif
#ifndef RISCV_HWPROBE_KEY_BASE_BEHAVIOR
#define RISCV_HWPROBE_KEY_BASE_BEHAVIOR 3
#define RISCV_HWPROBE_BASE_BEHAVIOR_IMA (1ULL << 0)
#define RISCV_HWPROBE_KEY_IMA_EXT_0 4
#define RISCV_HWPROBE_IMA_V (1ULL << 2)
#endif

#define MIN_PROBE_VLENB 16U
#define MAX_PROBE_VLENB 256U
#define MAX_PROBE_VSIZE (32U * MAX_PROBE_VLENB)
#define REGSET_HDR_BYTES 40U
#define DEFAULT_VLENB 0U
#define DEFAULT_SWITCH_ROUNDS 64
#define DEFAULT_SIGNAL_ROUNDS 8
#define STOCK_SIGNAL_ROUNDS 4
#define FIRST_USE_SETUP_BUDGET_MS 180000ULL
#define FIRST_USE_PHASE_BUDGET_MS 25000ULL
#define TOKEN_PREFIX "FROST_ISA_PROBE"
#define TOKEN_INFO "FROST_ISA_PROBE_INFO"
#define TOKEN_SUMMARY "FROST_ISA_PROBE_SUMMARY"

struct first_use_budgets {
    uint64_t setup_deadline_ms;
    uint64_t phase_deadline_ms;
    bool phase_started;
};

static void
first_use_budgets_init(struct first_use_budgets *b, uint64_t now_ms, uint64_t setup_budget_ms)
{
    b->setup_deadline_ms = now_ms + setup_budget_ms;
    b->phase_deadline_ms = 0ULL;
    b->phase_started = false;
}

static bool first_use_setup_expired(const struct first_use_budgets *b, uint64_t now_ms)
{
    return now_ms >= b->setup_deadline_ms;
}

static void
first_use_start_phases(struct first_use_budgets *b, uint64_t now_ms, uint64_t phase_budget_ms)
{
    b->phase_deadline_ms = now_ms + phase_budget_ms;
    b->phase_started = true;
}

static bool
first_use_phase_expired(const struct first_use_budgets *b, uint64_t now_ms, bool polled_once)
{
    return polled_once && b->phase_started && now_ms >= b->phase_deadline_ms;
}

static void format_elapsed_s(uint64_t start_ms, uint64_t now_ms, char *buf, size_t sz)
{
    uint64_t elapsed_ms = (now_ms >= start_ms) ? (now_ms - start_ms) : 0ULL;
    snprintf(buf,
             sz,
             "%llu.%03llus",
             (unsigned long long) (elapsed_ms / 1000ULL),
             (unsigned long long) (elapsed_ms % 1000ULL));
}

static bool is_supported_vlenb(uint64_t vlenb)
{
    return vlenb >= MIN_PROBE_VLENB && vlenb <= MAX_PROBE_VLENB && (vlenb & (vlenb - 1U)) == 0U;
}

struct ext_reg_state {
    uint64_t vstart;
    uint64_t vl;
    uint64_t vtype;
    uint64_t vcsr;
    uint64_t vlenb;
    uint64_t reserved[3];
    uint8_t vreg[MAX_PROBE_VSIZE];
} __attribute__((aligned(64)));

_Static_assert(offsetof(struct ext_reg_state, vstart) == 0, "vstart offset");
_Static_assert(offsetof(struct ext_reg_state, vl) == 8, "vl offset");
_Static_assert(offsetof(struct ext_reg_state, vtype) == 16, "vtype offset");
_Static_assert(offsetof(struct ext_reg_state, vcsr) == 24, "vcsr offset");
_Static_assert(offsetof(struct ext_reg_state, vlenb) == 32, "vlenb offset");
_Static_assert(offsetof(struct ext_reg_state, vreg) == 64, "vreg offset");

#if defined(__riscv) && !defined(FROST_ISA_PROBE_HOST_SELFTEST)
_Static_assert(offsetof(ucontext_t, uc_mcontext) == 176, "uc_mcontext offset");
_Static_assert(sizeof(struct user_regs_struct) == 256, "user_regs_struct size");
_Static_assert(offsetof(struct __riscv_extra_ext_header, hdr) == 520, "sc_extdesc.hdr offset");
_Static_assert(sizeof(struct __riscv_extra_ext_header) == 528, "sc_extdesc size");
_Static_assert(sizeof(struct __riscv_v_ext_state) == 48, "v_ext_state size");

extern uint64_t isa_probe_first_use_vsetvli(void);
extern uint64_t isa_probe_phase2_vsetvli(uint64_t avl);
extern uint64_t isa_probe_read_vlenb(void);
extern void isa_probe_load_state(const struct ext_reg_state *in);
extern void isa_probe_dump_state(struct ext_reg_state *out);
extern void isa_probe_rearm_vstart(uint64_t vstart);
extern void isa_probe_spin_until_flag(volatile uint32_t *ready_out,
                                      volatile const uint32_t *stop_in);
extern const uint8_t isa_probe_first_use_insn[];
extern const uint8_t isa_probe_phase2_insn[];
extern const uint8_t isa_probe_spin_loop[];
extern const uint8_t isa_probe_spin_end[];
#endif

enum expect_mode {
    EXPECT_AUTO = 0,
    EXPECT_PRESENT = 1,
    EXPECT_ABSENT = 2,
};

enum obs_mode {
    OBS_UNKNOWN = 0,
    OBS_PRESENT = 1,
    OBS_ABSENT = 2,
};

/* --- Minimal SHA-256 for core-note digests --- */

struct sha256_ctx {
    uint32_t h[8];
    uint64_t total_len;
    uint8_t buf[64];
    size_t buf_len;
};

static const uint32_t k_sha256[64] = {
    0x428a2f98U, 0x71374491U, 0xb5c0fbcfU, 0xe9b5dba5U, 0x3956c25bU, 0x59f111f1U, 0x923f82a4U,
    0xab1c5ed5U, 0xd807aa98U, 0x12835b01U, 0x243185beU, 0x550c7dc3U, 0x72be5d74U, 0x80deb1feU,
    0x9bdc06a7U, 0xc19bf174U, 0xe49b69c1U, 0xefbe4786U, 0x0fc19dc6U, 0x240ca1ccU, 0x2de92c6fU,
    0x4a7484aaU, 0x5cb0a9dcU, 0x76f988daU, 0x983e5152U, 0xa831c66dU, 0xb00327c8U, 0xbf597fc7U,
    0xc6e00bf3U, 0xd5a79147U, 0x06ca6351U, 0x14292967U, 0x27b70a85U, 0x2e1b2138U, 0x4d2c6dfcU,
    0x53380d13U, 0x650a7354U, 0x766a0abbU, 0x81c2c92eU, 0x92722c85U, 0xa2bfe8a1U, 0xa81a664bU,
    0xc24b8b70U, 0xc76c51a3U, 0xd192e819U, 0xd6990624U, 0xf40e3585U, 0x106aa070U, 0x19a4c116U,
    0x1e376c08U, 0x2748774cU, 0x34b0bcb5U, 0x391c0cb3U, 0x4ed8aa4aU, 0x5b9cca4fU, 0x682e6ff3U,
    0x748f82eeU, 0x78a5636fU, 0x84c87814U, 0x8cc70208U, 0x90befffaU, 0xa4506cebU, 0xbef9a3f7U,
    0xc67178f2U,
};

static inline uint32_t rotr32(uint32_t x, unsigned n)
{
    return (x >> n) | (x << (32U - n));
}

static void sha256_block(struct sha256_ctx *ctx, const uint8_t block[64])
{
    uint32_t w[64];
    for (int i = 0; i < 16; i++) {
        w[i] = ((uint32_t) block[i * 4] << 24) | ((uint32_t) block[i * 4 + 1] << 16) |
               ((uint32_t) block[i * 4 + 2] << 8) | (uint32_t) block[i * 4 + 3];
    }
    for (int i = 16; i < 64; i++) {
        uint32_t s0 = rotr32(w[i - 15], 7) ^ rotr32(w[i - 15], 18) ^ (w[i - 15] >> 3);
        uint32_t s1 = rotr32(w[i - 2], 17) ^ rotr32(w[i - 2], 19) ^ (w[i - 2] >> 10);
        w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }
    uint32_t a = ctx->h[0], b = ctx->h[1], c = ctx->h[2], d = ctx->h[3];
    uint32_t e = ctx->h[4], f = ctx->h[5], g = ctx->h[6], h = ctx->h[7];
    for (int i = 0; i < 64; i++) {
        uint32_t S1 = rotr32(e, 6) ^ rotr32(e, 11) ^ rotr32(e, 25);
        uint32_t ch = (e & f) ^ ((~e) & g);
        uint32_t temp1 = h + S1 + ch + k_sha256[i] + w[i];
        uint32_t S0 = rotr32(a, 2) ^ rotr32(a, 13) ^ rotr32(a, 22);
        uint32_t maj = (a & b) ^ (a & c) ^ (b & c);
        uint32_t temp2 = S0 + maj;
        h = g;
        g = f;
        f = e;
        e = d + temp1;
        d = c;
        c = b;
        b = a;
        a = temp1 + temp2;
    }
    ctx->h[0] += a;
    ctx->h[1] += b;
    ctx->h[2] += c;
    ctx->h[3] += d;
    ctx->h[4] += e;
    ctx->h[5] += f;
    ctx->h[6] += g;
    ctx->h[7] += h;
}

static void sha256_init(struct sha256_ctx *ctx)
{
    ctx->h[0] = 0x6a09e667U;
    ctx->h[1] = 0xbb67ae85U;
    ctx->h[2] = 0x3c6ef372U;
    ctx->h[3] = 0xa54ff53aU;
    ctx->h[4] = 0x510e527fU;
    ctx->h[5] = 0x9b05688cU;
    ctx->h[6] = 0x1f83d9abU;
    ctx->h[7] = 0x5be0cd19U;
    ctx->total_len = 0;
    ctx->buf_len = 0;
}

static void sha256_update(struct sha256_ctx *ctx, const uint8_t *data, size_t len)
{
    ctx->total_len += (uint64_t) len;
    while (len > 0) {
        size_t take = 64 - ctx->buf_len;
        if (take > len)
            take = len;
        memcpy(ctx->buf + ctx->buf_len, data, take);
        ctx->buf_len += take;
        data += take;
        len -= take;
        if (ctx->buf_len == 64) {
            sha256_block(ctx, ctx->buf);
            ctx->buf_len = 0;
        }
    }
}

static void sha256_final_hex(struct sha256_ctx *ctx, char out[65])
{
    uint64_t bits = ctx->total_len * 8ULL;
    uint8_t pad = 0x80;
    sha256_update(ctx, &pad, 1);
    uint8_t zero = 0;
    while (ctx->buf_len != 56)
        sha256_update(ctx, &zero, 1);
    uint8_t len_be[8];
    for (int i = 0; i < 8; i++)
        len_be[i] = (uint8_t) ((bits >> (56 - i * 8)) & 0xffU);
    sha256_update(ctx, len_be, 8);
    static const char hex[] = "0123456789abcdef";
    for (int i = 0; i < 8; i++) {
        for (int j = 0; j < 8; j++)
            out[i * 8 + j] = hex[(ctx->h[i] >> (28 - j * 4)) & 0xfU];
    }
    out[64] = '\0';
}

static void sha256_hex(const uint8_t *data, size_t len, char out[65])
{
    struct sha256_ctx ctx;
    sha256_init(&ctx);
    sha256_update(&ctx, data, len);
    sha256_final_hex(&ctx, out);
}

/* --- Common timing, file I/O, and pattern helpers --- */

#if defined(__riscv) && !defined(FROST_ISA_PROBE_HOST_SELFTEST)
static uint64_t g_probe_start_ms;

static uint64_t mono_ms(void)
{
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0)
        return 0;
    return (uint64_t) ts.tv_sec * 1000ULL + (uint64_t) ts.tv_nsec / 1000000ULL;
}

static void probe_progress(const char *run_id, const char *case_name, const char *step)
{
    char tbuf[32];
    uint64_t now = mono_ms();
    uint64_t base = (g_probe_start_ms > 0) ? g_probe_start_ms : now;
    format_elapsed_s(base, now, tbuf, sizeof(tbuf));
    printf("%s id=%s case=%s step=%s t=%s\n", TOKEN_INFO, run_id, case_name, step, tbuf);
}

static void sleep_ms(unsigned ms)
{
    struct timespec ts;
    ts.tv_sec = (time_t) (ms / 1000U);
    ts.tv_nsec = (long) ((ms % 1000U) * 1000000UL);
    while (nanosleep(&ts, &ts) < 0 && errno == EINTR) {
    }
}

static ssize_t read_file_bounded(const char *path, void *buf, size_t max_len)
{
    int fd = open(path, O_RDONLY);
    if (fd < 0)
        return -1;
    size_t total = 0;
    while (total < max_len) {
        ssize_t n = read(fd, (uint8_t *) buf + total, max_len - total);
        if (n < 0) {
            if (errno == EINTR)
                continue;
            int saved = errno;
            close(fd);
            errno = saved;
            return -1;
        }
        if (n == 0)
            break;
        total += (size_t) n;
    }
    close(fd);
    return (ssize_t) total;
}

static int write_file_all(const char *path, int flags, const void *buf, size_t len)
{
    int fd = open(path, flags, 0644);
    if (fd < 0)
        return -1;
    size_t off = 0;
    while (off < len) {
        ssize_t n = write(fd, (const uint8_t *) buf + off, len - off);
        if (n < 0) {
            if (errno == EINTR)
                continue;
            int saved = errno;
            close(fd);
            errno = saved;
            return -1;
        }
        off += (size_t) n;
    }
    if (close(fd) != 0)
        return -1;
    return 0;
}

static void *alloc_shared_mem(size_t size, int *fd_out)
{
    long ps = sysconf(_SC_PAGESIZE);
    size_t page = (ps > 0) ? (size_t) ps : 4096U;
    size_t map_size = (size + page - 1U) & ~(page - 1U);
    char tmpl[64];
    int fd = -1;

    snprintf(tmpl, sizeof(tmpl), "/dev/shm/frost_isa_shm_XXXXXX");
    fd = mkstemp(tmpl);
    if (fd < 0) {
        snprintf(tmpl, sizeof(tmpl), "/tmp/frost_isa_shm_XXXXXX");
        fd = mkstemp(tmpl);
    }
    if (fd < 0)
        return MAP_FAILED;
    unlink(tmpl);
    if (ftruncate(fd, (off_t) map_size) != 0) {
        close(fd);
        return MAP_FAILED;
    }
    void *ptr = mmap(NULL, map_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (ptr == MAP_FAILED) {
        close(fd);
        return MAP_FAILED;
    }
    /* Prefault every backing page before any timed or live-register region. */
    memset(ptr, 0, map_size);
    if (fd_out != NULL) {
        int fl = fcntl(fd, F_GETFD);
        if (fl >= 0)
            fcntl(fd, F_SETFD, fl & ~FD_CLOEXEC);
        *fd_out = fd;
    } else {
        close(fd);
    }
    return ptr;
}

static size_t align_page_size(size_t size)
{
    long ps = sysconf(_SC_PAGESIZE);
    size_t page = (ps > 0) ? (size_t) ps : 4096U;
    return (size + page - 1U) & ~(page - 1U);
}
#endif

static void fill_pattern(struct ext_reg_state *st, uint8_t seed, uint64_t vlenb, int tuple_id)
{
    memset(st, 0, sizeof(*st));
    if (tuple_id == 0) {
        /* e16, m1, tu, mu: VLMAX = vlenb / 2 */
        uint64_t vlmax = vlenb / 2U;
        st->vl = (vlmax > 3U) ? (vlmax - 3U) : vlmax;
        st->vtype = 0x08;
        st->vstart = (st->vl > 2U) ? 2U : 1U;
        st->vcsr = 3;
    } else if (tuple_id == 1) {
        /* e32, m1, ta, ma: VLMAX = vlenb / 4 */
        uint64_t vlmax = vlenb / 4U;
        st->vl = (vlmax > 1U) ? (vlmax - 1U) : vlmax;
        st->vtype = 0xd0;
        st->vstart = 1;
        st->vcsr = 4;
    } else {
        /* e8, m1, ta, mu (handler clobber pattern): VLMAX = vlenb */
        uint64_t vlmax = vlenb;
        st->vl = (vlmax > 5U) ? (vlmax - 5U) : vlmax;
        st->vtype = 0x40;
        st->vstart = 2;
        st->vcsr = 5;
    }
    st->vlenb = vlenb;
    for (uint64_t reg = 0; reg < 32; reg++) {
        for (uint64_t byte = 0; byte < vlenb; byte++) {
            st->vreg[reg * vlenb + byte] = (uint8_t) (seed ^ ((73U * reg + 19U * byte) & 0xffU));
        }
    }
}

static bool compare_state(const struct ext_reg_state *got,
                          const struct ext_reg_state *want,
                          uint64_t vlenb,
                          char *diff,
                          size_t diff_sz)
{
    if (got->vlenb != want->vlenb) {
        snprintf(diff,
                 diff_sz,
                 "csr=vlenb got=0x%llx want=0x%llx",
                 (unsigned long long) got->vlenb,
                 (unsigned long long) want->vlenb);
        return false;
    }
    if (got->vstart != want->vstart) {
        snprintf(diff,
                 diff_sz,
                 "csr=vstart got=0x%llx want=0x%llx",
                 (unsigned long long) got->vstart,
                 (unsigned long long) want->vstart);
        return false;
    }
    if (got->vl != want->vl) {
        snprintf(diff,
                 diff_sz,
                 "csr=vl got=0x%llx want=0x%llx",
                 (unsigned long long) got->vl,
                 (unsigned long long) want->vl);
        return false;
    }
    if (got->vtype != want->vtype) {
        snprintf(diff,
                 diff_sz,
                 "csr=vtype got=0x%llx want=0x%llx",
                 (unsigned long long) got->vtype,
                 (unsigned long long) want->vtype);
        return false;
    }
    if (got->vcsr != want->vcsr) {
        snprintf(diff,
                 diff_sz,
                 "csr=vcsr got=0x%llx want=0x%llx",
                 (unsigned long long) got->vcsr,
                 (unsigned long long) want->vcsr);
        return false;
    }
    for (uint64_t reg = 0; reg < 32; reg++) {
        for (uint64_t byte = 0; byte < vlenb; byte++) {
            uint8_t g = got->vreg[reg * vlenb + byte];
            uint8_t w = want->vreg[reg * vlenb + byte];
            if (g != w) {
                snprintf(diff,
                         diff_sz,
                         "reg=v%llu byte=%llu got=0x%02x want=0x%02x",
                         (unsigned long long) reg,
                         (unsigned long long) byte,
                         g,
                         w);
                return false;
            }
        }
    }
    return true;
}

static bool
check_zero_vregs(const struct ext_reg_state *got, uint64_t vlenb, char *diff, size_t diff_sz)
{
    for (uint64_t reg = 0; reg < 32; reg++) {
        for (uint64_t byte = 0; byte < vlenb; byte++) {
            uint8_t g = got->vreg[reg * vlenb + byte];
            if (g != 0) {
                snprintf(diff,
                         diff_sz,
                         "init_nonzero reg=v%llu byte=%llu got=0x%02x",
                         (unsigned long long) reg,
                         (unsigned long long) byte,
                         g);
                return false;
            }
        }
    }
    return true;
}

static void encode_regset_bytes(uint8_t *buf, const struct ext_reg_state *st, uint64_t vlenb)
{
    memcpy(buf + 0, &st->vstart, 8);
    memcpy(buf + 8, &st->vl, 8);
    memcpy(buf + 16, &st->vtype, 8);
    memcpy(buf + 24, &st->vcsr, 8);
    memcpy(buf + 32, &st->vlenb, 8);
    memcpy(buf + REGSET_HDR_BYTES, st->vreg, (size_t) (32U * vlenb));
}

static bool compare_regset_bytes(const uint8_t *buf,
                                 size_t len,
                                 const struct ext_reg_state *want,
                                 uint64_t vlenb,
                                 char *diff,
                                 size_t diff_sz)
{
    size_t expected_len = REGSET_HDR_BYTES + (size_t) (32U * vlenb);
    if (len != expected_len) {
        snprintf(diff, diff_sz, "len=%zu want=%zu", len, expected_len);
        return false;
    }
    struct ext_reg_state parsed;
    memset(&parsed, 0, sizeof(parsed));
    memcpy(&parsed.vstart, buf + 0, 8);
    memcpy(&parsed.vl, buf + 8, 8);
    memcpy(&parsed.vtype, buf + 16, 8);
    memcpy(&parsed.vcsr, buf + 24, 8);
    memcpy(&parsed.vlenb, buf + 32, 8);
    memcpy(parsed.vreg, buf + REGSET_HDR_BYTES, (size_t) (32U * vlenb));
    return compare_state(&parsed, want, vlenb, diff, diff_sz);
}

/* --- ISA string, DT extension list, cpuinfo, and ELF64 core parsers --- */

static bool is_zve_token(const char *tok)
{
    return strcmp(tok, "zve32x") == 0 || strcmp(tok, "zve32f") == 0 || strcmp(tok, "zve64x") == 0 ||
           strcmp(tok, "zve64f") == 0 || strcmp(tok, "zve64d") == 0;
}

static uint64_t parse_zvl_bits(const char *tok)
{
    if (strncmp(tok, "zvl", 3) != 0)
        return 0;
    const char *p = tok + 3;
    if (!isdigit((unsigned char) *p))
        return 0;
    char *end = NULL;
    unsigned long long bits = strtoull(p, &end, 10);
    if (end == NULL || strcmp(end, "b") != 0 || bits < 32ULL || bits > 65536ULL)
        return 0;
    if ((bits & (bits - 1ULL)) != 0ULL)
        return 0;
    return (uint64_t) bits;
}

static bool
parse_isa_string(const char *raw, bool *has_v, bool *has_zve, uint64_t *max_zvl_bits_out)
{
    *has_v = false;
    *has_zve = false;
    uint64_t max_zvl = 0;
    if (max_zvl_bits_out != NULL)
        *max_zvl_bits_out = 0;
    if (raw == NULL)
        return false;
    while (*raw != '\0' && isspace((unsigned char) *raw))
        raw++;
    if (strncasecmp(raw, "rv64", 4) != 0 && strncasecmp(raw, "rv32", 4) != 0)
        return false;

    const char *p = raw + 4;
    while (*p != '\0' && *p != '_' && !isspace((unsigned char) *p)) {
        char c = (char) tolower((unsigned char) *p);
        if (c == 'v')
            *has_v = true;
        p++;
    }
    while (*p == '_') {
        p++;
        char tok[64];
        size_t n = 0;
        while (*p != '\0' && *p != '_' && !isspace((unsigned char) *p)) {
            if (n + 1 < sizeof(tok))
                tok[n++] = (char) tolower((unsigned char) *p);
            p++;
        }
        tok[n] = '\0';
        if (strcmp(tok, "v") == 0)
            *has_v = true;
        if (is_zve_token(tok))
            *has_zve = true;
        uint64_t zvl = parse_zvl_bits(tok);
        if (zvl > max_zvl)
            max_zvl = zvl;
    }
    if (max_zvl_bits_out != NULL)
        *max_zvl_bits_out = max_zvl;
    return true;
}

static bool parse_dt_ext_list(const char *buf,
                              size_t len,
                              bool *has_v,
                              bool *has_zve,
                              size_t *count_out,
                              uint64_t *max_zvl_bits_out)
{
    *has_v = false;
    *has_zve = false;
    uint64_t max_zvl = 0;
    if (max_zvl_bits_out != NULL)
        *max_zvl_bits_out = 0;
    size_t count = 0;
    size_t off = 0;
    while (off < len) {
        size_t start = off;
        while (off < len && buf[off] != '\0')
            off++;
        size_t tlen = off - start;
        if (tlen > 0) {
            char tok[64];
            size_t copy = (tlen < sizeof(tok) - 1) ? tlen : (sizeof(tok) - 1);
            for (size_t i = 0; i < copy; i++)
                tok[i] = (char) tolower((unsigned char) buf[start + i]);
            tok[copy] = '\0';
            if (strcmp(tok, "v") == 0)
                *has_v = true;
            if (is_zve_token(tok))
                *has_zve = true;
            uint64_t zvl = parse_zvl_bits(tok);
            if (zvl > max_zvl)
                max_zvl = zvl;
            count++;
        }
        if (off < len && buf[off] == '\0')
            off++;
    }
    if (count_out != NULL)
        *count_out = count;
    if (max_zvl_bits_out != NULL)
        *max_zvl_bits_out = max_zvl;
    return count > 0;
}

static bool parse_cpuinfo_buf(const char *buf,
                              int target_cpu,
                              char *isa_out,
                              size_t isa_sz,
                              char *hart_isa_out,
                              size_t hart_isa_sz)
{
    isa_out[0] = '\0';
    hart_isa_out[0] = '\0';
    bool in_target = false;
    bool found_cpu = false;
    const char *p = buf;

    while (*p != '\0') {
        const char *eol = strchr(p, '\n');
        size_t llen = (eol != NULL) ? (size_t) (eol - p) : strlen(p);
        char line[1024];
        size_t copy = (llen < sizeof(line) - 1) ? llen : (sizeof(line) - 1);
        memcpy(line, p, copy);
        line[copy] = '\0';

        char *colon = strchr(line, ':');
        if (colon != NULL) {
            *colon = '\0';
            char *key = line;
            char *val = colon + 1;
            while (*key && isspace((unsigned char) *key))
                key++;
            size_t klen = strlen(key);
            while (klen > 0 && isspace((unsigned char) key[klen - 1]))
                key[--klen] = '\0';
            while (*val && isspace((unsigned char) *val))
                val++;
            size_t vlen = strlen(val);
            while (vlen > 0 && isspace((unsigned char) val[vlen - 1]))
                val[--vlen] = '\0';

            if (strcmp(key, "processor") == 0) {
                char *end = NULL;
                long idx = strtol(val, &end, 10);
                in_target = (end != val && *end == '\0' && idx == target_cpu);
                if (in_target)
                    found_cpu = true;
            } else if (in_target) {
                if (strcmp(key, "isa") == 0)
                    snprintf(isa_out, isa_sz, "%s", val);
                else if (strcmp(key, "hart isa") == 0)
                    snprintf(hart_isa_out, hart_isa_sz, "%s", val);
            }
        }
        if (eol == NULL)
            break;
        p = eol + 1;
    }
    return found_cpu && isa_out[0] != '\0' && hart_isa_out[0] != '\0';
}

struct core_parse_result {
    bool valid_elf;
    int prstatus_count;
    int vec_note_count;
    int bad_owner_vec_notes;
    size_t vec_desc_size;
    const uint8_t *vec_desc;
    char vec_sha256[65];
    char error[128];
};

static bool parse_elf_core_buf(const uint8_t *buf, size_t len, struct core_parse_result *res)
{
    memset(res, 0, sizeof(*res));
    if (len < sizeof(Elf64_Ehdr)) {
        snprintf(res->error, sizeof(res->error), "core_too_small");
        return false;
    }
    Elf64_Ehdr ehdr;
    memcpy(&ehdr, buf, sizeof(ehdr));
    if (memcmp(ehdr.e_ident, ELFMAG, SELFMAG) != 0 || ehdr.e_ident[EI_CLASS] != ELFCLASS64 ||
        ehdr.e_ident[EI_DATA] != ELFDATA2LSB || ehdr.e_type != ET_CORE ||
        ehdr.e_machine != EM_RISCV) {
        snprintf(res->error, sizeof(res->error), "bad_elf_header");
        return false;
    }
    if (ehdr.e_phentsize < sizeof(Elf64_Phdr) || ehdr.e_phnum == 0 || ehdr.e_phoff > len) {
        snprintf(res->error, sizeof(res->error), "bad_phdr_table");
        return false;
    }
    uint64_t ph_table_bytes = (uint64_t) ehdr.e_phnum * (uint64_t) ehdr.e_phentsize;
    if (ph_table_bytes > len - ehdr.e_phoff) {
        snprintf(res->error, sizeof(res->error), "truncated_phdr_table");
        return false;
    }

    for (uint16_t i = 0; i < ehdr.e_phnum; i++) {
        Elf64_Phdr phdr;
        size_t ph_off = (size_t) ehdr.e_phoff + (size_t) i * (size_t) ehdr.e_phentsize;
        memcpy(&phdr, buf + ph_off, sizeof(phdr));
        if (phdr.p_type != PT_NOTE)
            continue;
        if (phdr.p_offset > len || phdr.p_filesz > len - phdr.p_offset) {
            snprintf(res->error, sizeof(res->error), "truncated_pt_note");
            return false;
        }
        size_t pos = (size_t) phdr.p_offset;
        size_t end = pos + (size_t) phdr.p_filesz;
        while (pos < end) {
            if (end - pos < sizeof(Elf64_Nhdr)) {
                snprintf(res->error, sizeof(res->error), "truncated_note_hdr");
                return false;
            }
            Elf64_Nhdr nhdr;
            memcpy(&nhdr, buf + pos, sizeof(nhdr));
            pos += sizeof(Elf64_Nhdr);
            if (nhdr.n_namesz > end - pos) {
                snprintf(res->error, sizeof(res->error), "truncated_note_name");
                return false;
            }
            size_t name_pad = ((size_t) nhdr.n_namesz + 3U) & ~3U;
            if (name_pad < nhdr.n_namesz || name_pad > end - pos) {
                snprintf(res->error, sizeof(res->error), "truncated_note_name_pad");
                return false;
            }
            const uint8_t *name = buf + pos;
            pos += name_pad;
            if (nhdr.n_descsz > end - pos) {
                snprintf(res->error, sizeof(res->error), "truncated_note_desc");
                return false;
            }
            size_t desc_pad = ((size_t) nhdr.n_descsz + 3U) & ~3U;
            if (desc_pad < nhdr.n_descsz || desc_pad > end - pos) {
                snprintf(res->error, sizeof(res->error), "truncated_note_desc_pad");
                return false;
            }
            const uint8_t *desc = buf + pos;
            pos += desc_pad;

            if (nhdr.n_type == NT_PRSTATUS && nhdr.n_namesz == 5 &&
                memcmp(name, "CORE\0", 5) == 0) {
                res->prstatus_count++;
            } else if (nhdr.n_type == NT_RISCV_VECTOR) {
                if (nhdr.n_namesz == 6 && memcmp(name, "LINUX\0", 6) == 0) {
                    res->vec_note_count++;
                    res->vec_desc = desc;
                    res->vec_desc_size = nhdr.n_descsz;
                    sha256_hex(desc, nhdr.n_descsz, res->vec_sha256);
                } else {
                    res->bad_owner_vec_notes++;
                }
            }
        }
    }

    res->valid_elf = true;
    return true;
}

/*
 * Linux 7.0 (upstream commit 8cdb04bd06c1, "riscv: ptrace: return ENODATA for
 * inactive vector extension") changed PTRACE_GETREGSET(NT_RISCV_VECTOR) for a
 * thread that has never used V from -EINVAL to -ENODATA. When V is absent from
 * the CPU/kernel, arch/riscv/kernel/ptrace.c returns -EINVAL on all kernels.
 */
static bool parse_kernel_release(const char *release, unsigned *major_out, unsigned *minor_out)
{
    if (release == NULL || !isdigit((unsigned char) release[0]))
        return false;
    const char *p = release;
    unsigned long major = 0;
    while (isdigit((unsigned char) *p)) {
        if (major > (UINT_MAX - 9U) / 10U)
            return false;
        major = major * 10UL + (unsigned long) (*p - '0');
        p++;
    }
    if (*p != '.')
        return false;
    p++;
    if (!isdigit((unsigned char) *p))
        return false;
    unsigned long minor = 0;
    while (isdigit((unsigned char) *p)) {
        if (minor > (UINT_MAX - 9U) / 10U)
            return false;
        minor = minor * 10UL + (unsigned long) (*p - '0');
        p++;
    }
    if (*p != '\0' && *p != '.' && *p != '-' && *p != '+' && *p != '~')
        return false;
    *major_out = (unsigned) major;
    *minor_out = (unsigned) minor;
    return true;
}

static int expected_inactive_vreg_errno_for_release(const char *release)
{
    unsigned major = 0, minor = 0;
    if (!parse_kernel_release(release, &major, &minor))
        return -1;
    /* Upstream commit 8cdb04bd06c1 (first released in Linux 7.0). */
    return (major >= 7U) ? ENODATA : EINVAL;
}

/* --- Built-in host/target parser self-test --- */

static size_t build_synthetic_core(uint8_t *out,
                                   size_t cap,
                                   bool include_vec,
                                   const char *vec_owner,
                                   const struct ext_reg_state *st,
                                   uint64_t vlenb)
{
    uint8_t notes[4096];
    size_t npos = 0;

    /* CORE / NT_PRSTATUS dummy payload (64 bytes). */
    Elf64_Nhdr nh1 = {5, 64, NT_PRSTATUS};
    memcpy(notes + npos, &nh1, sizeof(nh1));
    npos += sizeof(nh1);
    memcpy(notes + npos, "CORE\0\0\0\0", 8);
    npos += 8;
    memset(notes + npos, 0x11, 64);
    npos += 64;

    if (include_vec) {
        size_t owner_len = strlen(vec_owner) + 1;
        size_t owner_pad = (owner_len + 3U) & ~3U;
        size_t desc_len = REGSET_HDR_BYTES + (size_t) (32U * vlenb);
        size_t desc_pad = (desc_len + 3U) & ~3U;
        Elf64_Nhdr nh2 = {(Elf64_Word) owner_len, (Elf64_Word) desc_len, NT_RISCV_VECTOR};
        memcpy(notes + npos, &nh2, sizeof(nh2));
        npos += sizeof(nh2);
        memset(notes + npos, 0, owner_pad);
        memcpy(notes + npos, vec_owner, owner_len);
        npos += owner_pad;
        memset(notes + npos, 0, desc_pad);
        memcpy(notes + npos + 0, &st->vstart, 8);
        memcpy(notes + npos + 8, &st->vl, 8);
        memcpy(notes + npos + 16, &st->vtype, 8);
        memcpy(notes + npos + 24, &st->vcsr, 8);
        memcpy(notes + npos + 32, &st->vlenb, 8);
        memcpy(notes + npos + REGSET_HDR_BYTES, st->vreg, (size_t) (32U * vlenb));
        npos += desc_pad;
    }

    size_t hdr_total = sizeof(Elf64_Ehdr) + sizeof(Elf64_Phdr);
    if (hdr_total + npos > cap)
        return 0;

    Elf64_Ehdr ehdr;
    memset(&ehdr, 0, sizeof(ehdr));
    memcpy(ehdr.e_ident, ELFMAG, SELFMAG);
    ehdr.e_ident[EI_CLASS] = ELFCLASS64;
    ehdr.e_ident[EI_DATA] = ELFDATA2LSB;
    ehdr.e_ident[EI_VERSION] = EV_CURRENT;
    ehdr.e_type = ET_CORE;
    ehdr.e_machine = EM_RISCV;
    ehdr.e_version = EV_CURRENT;
    ehdr.e_ehsize = sizeof(Elf64_Ehdr);
    ehdr.e_phoff = sizeof(Elf64_Ehdr);
    ehdr.e_phentsize = sizeof(Elf64_Phdr);
    ehdr.e_phnum = 1;

    Elf64_Phdr phdr;
    memset(&phdr, 0, sizeof(phdr));
    phdr.p_type = PT_NOTE;
    phdr.p_offset = hdr_total;
    phdr.p_filesz = npos;
    phdr.p_align = 4;

    memcpy(out, &ehdr, sizeof(ehdr));
    memcpy(out + sizeof(ehdr), &phdr, sizeof(phdr));
    memcpy(out + hdr_total, notes, npos);
    return hdr_total + npos;
}

static int run_selftest(void)
{
    /* 1. SHA-256 reference vector ("abc"). */
    char digest[65];
    sha256_hex((const uint8_t *) "abc", 3, digest);
    if (strcmp(digest, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad") != 0) {
        printf("FROST_ISA_SELFTEST sha256: FAIL got=%s\n", digest);
        return 1;
    }
    printf("FROST_ISA_SELFTEST sha256: pass\n");

    /* 2. ISA string parser must not confuse rv64 or sv* extensions with V. */
    bool has_v = true, has_zve = true;
    uint64_t max_zvl = 0;
    const char *stock_isa = "rv64imafdc_zfa_zfhmin_zicboz_svade_svinval_svnapot_svpbmt_svvptc";
    if (!parse_isa_string(stock_isa, &has_v, &has_zve, &max_zvl) || has_v || has_zve ||
        max_zvl != 0) {
        printf("FROST_ISA_SELFTEST isa-stock: FAIL has_v=%d has_zve=%d\n", has_v, has_zve);
        return 1;
    }
    const char *present_isa = "rv64imafdcv_zfa_zvl128b_zvl512b_svade_svvptc";
    if (!parse_isa_string(present_isa, &has_v, &has_zve, &max_zvl) || !has_v || has_zve ||
        max_zvl != 512) {
        printf("FROST_ISA_SELFTEST isa-present: FAIL has_v=%d has_zve=%d zvl=%llu\n",
               has_v,
               has_zve,
               (unsigned long long) max_zvl);
        return 1;
    }
    const char *zve_isa = "rv64imafdc_zve32x_svade";
    if (!parse_isa_string(zve_isa, &has_v, &has_zve, &max_zvl) || has_v || !has_zve) {
        printf("FROST_ISA_SELFTEST isa-zve: FAIL has_v=%d has_zve=%d\n", has_v, has_zve);
        return 1;
    }
    printf("FROST_ISA_SELFTEST isa-parser: pass\n");

    /* 3. DT NUL-delimited extension parser. */
    const char dt_stock[] = "i\0m\0a\0f\0d\0c\0svade\0svvptc\0";
    size_t dt_cnt = 0;
    if (!parse_dt_ext_list(dt_stock, sizeof(dt_stock), &has_v, &has_zve, &dt_cnt, &max_zvl) ||
        has_v || has_zve || dt_cnt != 8 || max_zvl != 0) {
        printf("FROST_ISA_SELFTEST dt-stock: FAIL\n");
        return 1;
    }
    const char dt_present[] = "i\0m\0a\0f\0d\0c\0v\0zvl256b\0svvptc\0";
    if (!parse_dt_ext_list(dt_present, sizeof(dt_present), &has_v, &has_zve, &dt_cnt, &max_zvl) ||
        !has_v || has_zve || dt_cnt != 9 || max_zvl != 256) {
        printf("FROST_ISA_SELFTEST dt-present: FAIL\n");
        return 1;
    }
    printf("FROST_ISA_SELFTEST dt-parser: pass\n");

    /* 4. ELF64 core and regset encode/compare across VLEN 128, 256, and 512. */
    const uint64_t test_vlenbs[3] = {16U, 32U, 64U};
    uint8_t core_buf[8192];
    uint8_t reg_buf[REGSET_HDR_BYTES + MAX_PROBE_VSIZE];
    struct core_parse_result res;
    char diff[128] = "";
    for (size_t i = 0; i < 3; i++) {
        uint64_t vb = test_vlenbs[i];
        if (!is_supported_vlenb(vb)) {
            printf("FROST_ISA_SELFTEST vlenb-support: FAIL vb=%llu\n", (unsigned long long) vb);
            return 1;
        }
        struct ext_reg_state pat;
        fill_pattern(&pat, (uint8_t) (0x5aU + (unsigned) i), vb, (int) (i & 1U));
        encode_regset_bytes(reg_buf, &pat, vb);
        if (!compare_regset_bytes(
                reg_buf, REGSET_HDR_BYTES + (size_t) (32U * vb), &pat, vb, diff, sizeof(diff))) {
            printf("FROST_ISA_SELFTEST regset-roundtrip: FAIL vb=%llu diff=%s\n",
                   (unsigned long long) vb,
                   diff);
            return 1;
        }
        size_t core_len = build_synthetic_core(core_buf, sizeof(core_buf), true, "LINUX", &pat, vb);
        if (!parse_elf_core_buf(core_buf, core_len, &res) || res.prstatus_count != 1 ||
            res.vec_note_count != 1 ||
            res.vec_desc_size != REGSET_HDR_BYTES + (size_t) (32U * vb) ||
            !compare_regset_bytes(res.vec_desc, res.vec_desc_size, &pat, vb, diff, sizeof(diff))) {
            printf("FROST_ISA_SELFTEST core-valid: FAIL vb=%llu err=%s diff=%s\n",
                   (unsigned long long) vb,
                   res.error,
                   diff);
            return 1;
        }
    }
    struct ext_reg_state pat;
    fill_pattern(&pat, 0x5a, 32, 1);
    size_t core_len = build_synthetic_core(core_buf, sizeof(core_buf), true, "LINUX", &pat, 32);
    printf("FROST_ISA_SELFTEST core-valid: pass\n");

    size_t scalar_len = build_synthetic_core(core_buf, sizeof(core_buf), false, "LINUX", &pat, 32);
    if (!parse_elf_core_buf(core_buf, scalar_len, &res) || res.prstatus_count != 1 ||
        res.vec_note_count != 0) {
        printf("FROST_ISA_SELFTEST core-scalar: FAIL\n");
        return 1;
    }
    printf("FROST_ISA_SELFTEST core-scalar: pass\n");

    size_t bad_owner_len = build_synthetic_core(core_buf, sizeof(core_buf), true, "CORE", &pat, 32);
    if (!parse_elf_core_buf(core_buf, bad_owner_len, &res) || res.vec_note_count != 0 ||
        res.bad_owner_vec_notes != 1) {
        printf("FROST_ISA_SELFTEST core-owner: FAIL\n");
        return 1;
    }
    printf("FROST_ISA_SELFTEST core-owner: pass\n");

    if (parse_elf_core_buf(core_buf, core_len - 17, &res)) {
        printf("FROST_ISA_SELFTEST core-truncated: FAIL accepted truncated buffer\n");
        return 1;
    }
    printf("FROST_ISA_SELFTEST core-truncated: pass\n");

    /* 5. /proc/cpuinfo parser and zero-state checker. */
    const char *ci_sample = "processor\t: 0\n"
                            "hart\t\t: 0\n"
                            "isa\t\t: rv64imafdc_zicboz_svvptc\n"
                            "hart isa\t: rv64imafdc_zicboz_svvptc\n";
    char ci_isa[128] = "", ci_hart[128] = "";
    if (!parse_cpuinfo_buf(ci_sample, 0, ci_isa, sizeof(ci_isa), ci_hart, sizeof(ci_hart)) ||
        strcmp(ci_isa, "rv64imafdc_zicboz_svvptc") != 0 || strcmp(ci_hart, ci_isa) != 0) {
        printf("FROST_ISA_SELFTEST cpuinfo-parser: FAIL\n");
        return 1;
    }
    struct ext_reg_state zst;
    memset(&zst, 0, sizeof(zst));
    if (!check_zero_vregs(&zst, 32, diff, sizeof(diff))) {
        printf("FROST_ISA_SELFTEST zero-check-clean: FAIL\n");
        return 1;
    }
    zst.vreg[32 * 5 + 7] = 0x1;
    if (check_zero_vregs(&zst, 32, diff, sizeof(diff))) {
        printf("FROST_ISA_SELFTEST zero-check-dirty: FAIL\n");
        return 1;
    }
    printf("FROST_ISA_SELFTEST cpuinfo-zero: pass\n");

    /* 6. Separate first-use setup budget vs phase deadline and progress timestamp formatting. */
    if (FIRST_USE_SETUP_BUDGET_MS < 120000ULL || FIRST_USE_PHASE_BUDGET_MS != 25000ULL) {
        printf("FROST_ISA_SELFTEST first-use-budget: FAIL constants\n");
        return 1;
    }
    struct first_use_budgets b;
    uint64_t t0 = 10000ULL;
    first_use_budgets_init(&b, t0, FIRST_USE_SETUP_BUDGET_MS);
    /* A slow 56.188 s setup stays within the setup budget and does not consume phase 1. */
    uint64_t t_setup_done = t0 + 56188ULL;
    if (first_use_setup_expired(&b, t_setup_done) ||
        !first_use_setup_expired(&b, t0 + FIRST_USE_SETUP_BUDGET_MS)) {
        printf("FROST_ISA_SELFTEST first-use-budget: FAIL setup-expiry\n");
        return 1;
    }
    first_use_start_phases(&b, t_setup_done, FIRST_USE_PHASE_BUDGET_MS);
    if (first_use_phase_expired(&b, t_setup_done + 3ULL, true) ||
        first_use_phase_expired(&b, t_setup_done + FIRST_USE_PHASE_BUDGET_MS, false) ||
        !first_use_phase_expired(&b, t_setup_done + FIRST_USE_PHASE_BUDGET_MS, true)) {
        printf("FROST_ISA_SELFTEST first-use-budget: FAIL phase-expiry\n");
        return 1;
    }
    printf("FROST_ISA_SELFTEST first-use-budget: pass\n");

    char tbuf[32];
    format_elapsed_s(1000ULL, 1000ULL, tbuf, sizeof(tbuf));
    if (strcmp(tbuf, "0.000s") != 0) {
        printf("FROST_ISA_SELFTEST progress-format: FAIL got=%s\n", tbuf);
        return 1;
    }
    format_elapsed_s(1000ULL, 57188ULL, tbuf, sizeof(tbuf));
    if (strcmp(tbuf, "56.188s") != 0) {
        printf("FROST_ISA_SELFTEST progress-format: FAIL got=%s\n", tbuf);
        return 1;
    }
    printf("FROST_ISA_SELFTEST progress-format: pass\n");

    /* 7. Kernel-version-keyed inactive NT_RISCV_VECTOR ptrace errno (Linux 7.0: 8cdb04bd06c1). */
    static const struct {
        const char *release;
        int want_errno;
    } krel_cases[] = {
        {"6.12.113+deb13-riscv64", EINVAL},
        {"6.19.9", EINVAL},
        {"7.0", ENODATA},
        {"7.0.0", ENODATA},
        {"7.0-rc1", ENODATA},
        {"7.3.4+deb13-riscv64", ENODATA},
        {"8.1.0", ENODATA},
        {"", -1},
        {"abc", -1},
        {"7", -1},
        {"7.", -1},
        {".3", -1},
        {"7.a", -1},
        {"7.3x", -1},
    };
    for (size_t i = 0; i < sizeof(krel_cases) / sizeof(krel_cases[0]); i++) {
        int got = expected_inactive_vreg_errno_for_release(krel_cases[i].release);
        if (got != krel_cases[i].want_errno) {
            printf("FROST_ISA_SELFTEST inactive-vreg-errno: FAIL rel=%s want=%d got=%d\n",
                   krel_cases[i].release,
                   krel_cases[i].want_errno,
                   got);
            return 1;
        }
    }
    printf("FROST_ISA_SELFTEST inactive-vreg-errno: pass\n");

    printf("FROST_ISA_SELFTEST_PASS\n");
    return 0;
}

#if defined(__riscv) && !defined(FROST_ISA_PROBE_HOST_SELFTEST)

/* --- Runtime RISC-V Linux helpers --- */

static int expected_inactive_vreg_errno(char *rel_buf, size_t rel_sz)
{
    struct utsname uts;
    memset(&uts, 0, sizeof(uts));
    if (uname(&uts) != 0) {
        if (rel_buf != NULL && rel_sz > 0)
            rel_buf[0] = '\0';
        return -1;
    }
    if (rel_buf != NULL && rel_sz > 0)
        snprintf(rel_buf, rel_sz, "%s", uts.release);
    return expected_inactive_vreg_errno_for_release(uts.release);
}

static bool pin_to_cpu(int cpu)
{
    cpu_set_t set;
    CPU_ZERO(&set);
    CPU_SET(cpu, &set);
    if (sched_setaffinity(0, sizeof(set), &set) != 0)
        return false;
    cpu_set_t check;
    CPU_ZERO(&check);
    if (sched_getaffinity(0, sizeof(check), &check) != 0)
        return false;
    return CPU_COUNT(&check) == 1 && CPU_ISSET(cpu, &check);
}

static bool find_of_cpu_node(int cpu, char *out_path, size_t out_sz)
{
    char direct[128];
    snprintf(direct, sizeof(direct), "/sys/firmware/devicetree/base/cpus/cpu@%d", cpu);
    struct stat st;
    if (stat(direct, &st) == 0 && S_ISDIR(st.st_mode)) {
        snprintf(out_path, out_sz, "%s", direct);
        return true;
    }
    DIR *dir = opendir("/sys/firmware/devicetree/base/cpus");
    if (dir == NULL)
        return false;
    struct dirent *de;
    bool found = false;
    while ((de = readdir(dir)) != NULL) {
        if (strncmp(de->d_name, "cpu", 3) != 0)
            continue;
        char cand[512];
        char dtype_path[640];
        char dtype[32];
        snprintf(cand, sizeof(cand), "/sys/firmware/devicetree/base/cpus/%.255s", de->d_name);
        if (stat(cand, &st) != 0 || !S_ISDIR(st.st_mode))
            continue;
        snprintf(dtype_path, sizeof(dtype_path), "%s/device_type", cand);
        ssize_t n = read_file_bounded(dtype_path, dtype, sizeof(dtype) - 1);
        if (n <= 0)
            continue;
        dtype[n] = '\0';
        if (strcmp(dtype, "cpu") != 0)
            continue;
        snprintf(out_path, out_sz, "%s", cand);
        found = true;
        break;
    }
    closedir(dir);
    return found;
}

static int wait_child_deadline(pid_t pid, int *status_out, uint64_t deadline_ms)
{
    bool polled_once = false;
    for (;;) {
        pid_t r = waitpid(pid, status_out, WNOHANG);
        if (r == pid)
            return 0;
        if (r < 0) {
            if (errno == EINTR)
                continue;
            return -1;
        }
        if (polled_once && mono_ms() >= deadline_ms) {
            kill(pid, SIGKILL);
            while (waitpid(pid, status_out, 0) < 0 && errno == EINTR) {
            }
            errno = ETIMEDOUT;
            return -1;
        }
        sleep_ms(2);
        polled_once = true;
    }
}

static int wait_ptrace_stop_deadline(pid_t pid, int *status_out, uint64_t deadline_ms)
{
    for (;;) {
        pid_t r = waitpid(pid, status_out, WNOHANG);
        if (r == pid)
            return 0;
        if (r < 0) {
            if (errno == EINTR)
                continue;
            return -1;
        }
        if (mono_ms() >= deadline_ms) {
            kill(pid, SIGKILL);
            while (waitpid(pid, status_out, 0) < 0 && errno == EINTR) {
            }
            errno = ETIMEDOUT;
            return -1;
        }
        sleep_ms(2);
    }
}

/* --- Case 1: discover (present and absent) --- */

struct discover_info {
    enum obs_mode mode;
    bool ok;
    uint64_t vlenb;
    int smoke_ok;
    char reason[128];
};

static bool run_smoke_child(
    uint64_t expected_vlenb, uint64_t *got_vlenb, uint64_t *got_vl, char *reason, size_t reason_sz)
{
    struct smoke_shm {
        uint64_t vlenb;
        uint64_t vl;
        int ctrl_after_set;
        int ok_a;
        int ok_b;
        char diff[128];
    };
    struct smoke_shm *shm = alloc_shared_mem(sizeof(*shm), NULL);
    if (shm == MAP_FAILED) {
        snprintf(reason, reason_sz, "shm_alloc_failed");
        return false;
    }

    pid_t pid = fork();
    if (pid < 0) {
        munmap(shm, align_page_size(sizeof(*shm)));
        snprintf(reason, reason_sz, "fork_failed");
        return false;
    }
    if (pid == 0) {
        if (prctl(PR_RISCV_V_SET_CONTROL, PR_RISCV_V_VSTATE_CTRL_ON) < 0)
            _exit(10);
        int ctrl = prctl(PR_RISCV_V_GET_CONTROL);
        shm->ctrl_after_set = ctrl;
        if (ctrl < 0 || (ctrl & PR_RISCV_V_VSTATE_CTRL_CUR_MASK) != PR_RISCV_V_VSTATE_CTRL_ON)
            _exit(11);

        uint64_t vl = isa_probe_first_use_vsetvli();
        uint64_t vlenb = isa_probe_read_vlenb();
        shm->vl = vl;
        shm->vlenb = vlenb;
        if (!is_supported_vlenb(vlenb))
            _exit(16);
        if (expected_vlenb != 0 && vlenb != expected_vlenb)
            _exit(12);
        if (vl != vlenb / 2U)
            _exit(17);

        struct ext_reg_state *pat = mmap(NULL,
                                         align_page_size(sizeof(*pat) * 2),
                                         PROT_READ | PROT_WRITE,
                                         MAP_PRIVATE | MAP_ANONYMOUS,
                                         -1,
                                         0);
        if (pat == MAP_FAILED)
            _exit(13);
        memset(pat, 0, sizeof(*pat) * 2);
        struct ext_reg_state *got = pat + 1;

        /* Tuple A: seed and immediate dump with zero syscalls in between. */
        fill_pattern(pat, 0x5a, vlenb, 0);
        isa_probe_load_state(pat);
        isa_probe_dump_state(got);
        if (!compare_state(got, pat, vlenb, shm->diff, sizeof(shm->diff)))
            _exit(14);
        shm->ok_a = 1;

        /* Tuple B: seed and immediate dump with zero syscalls in between. */
        fill_pattern(pat, 0xa5, vlenb, 1);
        isa_probe_load_state(pat);
        isa_probe_dump_state(got);
        if (!compare_state(got, pat, vlenb, shm->diff, sizeof(shm->diff)))
            _exit(15);
        shm->ok_b = 1;
        _exit(0);
    }

    int status = 0;
    int wr = wait_child_deadline(pid, &status, mono_ms() + 10000ULL);
    *got_vlenb = shm->vlenb;
    *got_vl = shm->vl;
    bool passed = false;
    if (wr != 0) {
        snprintf(reason, reason_sz, "smoke_timeout");
    } else if (WIFSIGNALED(status)) {
        snprintf(reason, reason_sz, "smoke_signal_%d", WTERMSIG(status));
    } else if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        if (shm->diff[0] != '\0')
            snprintf(reason, reason_sz, "smoke_mismatch_%.96s", shm->diff);
        else if (WIFEXITED(status) && WEXITSTATUS(status) == 16)
            snprintf(reason, reason_sz, "unsupported_vlenb_%llu", (unsigned long long) shm->vlenb);
        else if (WIFEXITED(status) && WEXITSTATUS(status) == 12)
            snprintf(reason,
                     reason_sz,
                     "vlenb_mismatch_got_%llu_want_%llu",
                     (unsigned long long) shm->vlenb,
                     (unsigned long long) expected_vlenb);
        else if (WIFEXITED(status) && WEXITSTATUS(status) == 17)
            snprintf(reason,
                     reason_sz,
                     "smoke_vl_%llu_want_%llu",
                     (unsigned long long) shm->vl,
                     (unsigned long long) (shm->vlenb / 2U));
        else
            snprintf(reason, reason_sz, "smoke_exit_%d", WEXITSTATUS(status));
    } else if (shm->ok_a != 1 || shm->ok_b != 1) {
        snprintf(reason, reason_sz, "smoke_incomplete");
    } else {
        passed = true;
    }
    munmap(shm, align_page_size(sizeof(*shm)));
    return passed;
}

static struct discover_info
run_discover(const char *run_id, enum expect_mode expect, uint64_t expected_vlenb, int cpu)
{
    struct discover_info out;
    memset(&out, 0, sizeof(out));
    out.mode = OBS_UNKNOWN;
    probe_progress(run_id, "discover", "start");

    if (!pin_to_cpu(cpu)) {
        snprintf(out.reason, sizeof(out.reason), "pin_cpu_%d_failed", cpu);
        printf("%s id=%s case=discover verdict=FAIL reason=%s\n", TOKEN_PREFIX, run_id, out.reason);
        return out;
    }

    char cpu_node[512];
    if (!find_of_cpu_node(cpu, cpu_node, sizeof(cpu_node))) {
        snprintf(out.reason, sizeof(out.reason), "of_cpu_node_missing");
        printf("%s id=%s case=discover verdict=FAIL reason=%s\n", TOKEN_PREFIX, run_id, out.reason);
        return out;
    }

    char dt_ext_path[640];
    char dt_isa_path[640];
    snprintf(dt_ext_path, sizeof(dt_ext_path), "%s/riscv,isa-extensions", cpu_node);
    snprintf(dt_isa_path, sizeof(dt_isa_path), "%s/riscv,isa", cpu_node);

    char dt_ext_buf[4096];
    char dt_isa_buf[2048];
    ssize_t dt_ext_len = read_file_bounded(dt_ext_path, dt_ext_buf, sizeof(dt_ext_buf));
    ssize_t dt_isa_len = read_file_bounded(dt_isa_path, dt_isa_buf, sizeof(dt_isa_buf) - 1);

    bool dt_ext_ok = false, dt_ext_v = false, dt_ext_zve = false;
    size_t dt_ext_cnt = 0;
    uint64_t dt_ext_zvl_bits = 0;
    if (dt_ext_len > 0)
        dt_ext_ok = parse_dt_ext_list(
            dt_ext_buf, (size_t) dt_ext_len, &dt_ext_v, &dt_ext_zve, &dt_ext_cnt, &dt_ext_zvl_bits);

    bool dt_isa_ok = false, dt_isa_v = false, dt_isa_zve = false;
    uint64_t dt_isa_zvl_bits = 0;
    if (dt_isa_len > 0) {
        dt_isa_buf[dt_isa_len] = '\0';
        dt_isa_ok = parse_isa_string(dt_isa_buf, &dt_isa_v, &dt_isa_zve, &dt_isa_zvl_bits);
    } else {
        dt_isa_buf[0] = '\0';
    }
    uint64_t dt_max_zvl_bits =
        (dt_ext_zvl_bits > dt_isa_zvl_bits) ? dt_ext_zvl_bits : dt_isa_zvl_bits;

    char cpuinfo_buf[16384];
    ssize_t cpuinfo_len = read_file_bounded("/proc/cpuinfo", cpuinfo_buf, sizeof(cpuinfo_buf) - 1);
    char ci_isa[1024] = "", ci_hart_isa[1024] = "";
    bool ci_ok = false, ci_isa_v = false, ci_isa_zve = false, ci_hart_v = false,
         ci_hart_zve = false;
    if (cpuinfo_len > 0) {
        cpuinfo_buf[cpuinfo_len] = '\0';
        ci_ok = parse_cpuinfo_buf(
            cpuinfo_buf, cpu, ci_isa, sizeof(ci_isa), ci_hart_isa, sizeof(ci_hart_isa));
        if (ci_ok) {
            ci_ok = parse_isa_string(ci_isa, &ci_isa_v, &ci_isa_zve, NULL) &&
                    parse_isa_string(ci_hart_isa, &ci_hart_v, &ci_hart_zve, NULL);
        }
    }

    struct riscv_hwprobe pairs_all[2] = {
        {.key = RISCV_HWPROBE_KEY_BASE_BEHAVIOR, .value = 0},
        {.key = RISCV_HWPROBE_KEY_IMA_EXT_0, .value = 0},
    };
    errno = 0;
    long hwp_all_rc = syscall(__NR_riscv_hwprobe, pairs_all, 2, 0, NULL, 0);
    int hwp_all_errno = (hwp_all_rc < 0) ? errno : 0;

    cpu_set_t mask;
    CPU_ZERO(&mask);
    CPU_SET(cpu, &mask);
    struct riscv_hwprobe pairs_hart[2] = {
        {.key = RISCV_HWPROBE_KEY_BASE_BEHAVIOR, .value = 0},
        {.key = RISCV_HWPROBE_KEY_IMA_EXT_0, .value = 0},
    };
    errno = 0;
    long hwp_hart_rc = syscall(__NR_riscv_hwprobe, pairs_hart, 2, sizeof(mask), &mask, 0);
    int hwp_hart_errno = (hwp_hart_rc < 0) ? errno : 0;

    unsigned long hwcap = getauxval(AT_HWCAP);
    bool hwcap_base = (hwcap & (COMPAT_HWCAP_ISA_I | COMPAT_HWCAP_ISA_M | COMPAT_HWCAP_ISA_A |
                                COMPAT_HWCAP_ISA_F | COMPAT_HWCAP_ISA_D | COMPAT_HWCAP_ISA_C)) ==
                      (COMPAT_HWCAP_ISA_I | COMPAT_HWCAP_ISA_M | COMPAT_HWCAP_ISA_A |
                       COMPAT_HWCAP_ISA_F | COMPAT_HWCAP_ISA_D | COMPAT_HWCAP_ISA_C);
    bool hwcap_v = (hwcap & COMPAT_HWCAP_ISA_V) != 0;

    char allow_buf[32] = "missing";
    ssize_t allow_len =
        read_file_bounded("/proc/sys/abi/riscv_v_default_allow", allow_buf, sizeof(allow_buf) - 1);
    if (allow_len > 0) {
        allow_buf[allow_len] = '\0';
        while (allow_len > 0 && isspace((unsigned char) allow_buf[allow_len - 1]))
            allow_buf[--allow_len] = '\0';
    }

    errno = 0;
    int ctrl = prctl(PR_RISCV_V_GET_CONTROL);
    int ctrl_errno = (ctrl < 0) ? errno : 0;
    probe_progress(run_id, "discover", "surfaces_read");

    printf("%s id=%s case=discover of=%s dt_ext_ok=%d dt_ext_v=%d dt_ext_zve=%d dt_ext_cnt=%zu "
           "dt_isa_ok=%d dt_isa_v=%d dt_isa_zve=%d ci_ok=%d ci_isa_v=%d ci_hart_v=%d\n",
           TOKEN_INFO,
           run_id,
           cpu_node,
           dt_ext_ok,
           dt_ext_v,
           dt_ext_zve,
           dt_ext_cnt,
           dt_isa_ok,
           dt_isa_v,
           dt_isa_zve,
           ci_ok,
           ci_isa_v,
           ci_hart_v);
    printf("%s id=%s case=discover hwprobe_all_rc=%ld(e=%d) base=0x%llx ext0=0x%llx "
           "hwprobe_hart_rc=%ld(e=%d) hbase=0x%llx hext0=0x%llx hwcap=0x%lx prctl=%d(e=%d) "
           "default_allow=%s\n",
           TOKEN_INFO,
           run_id,
           hwp_all_rc,
           hwp_all_errno,
           (unsigned long long) pairs_all[0].value,
           (unsigned long long) pairs_all[1].value,
           hwp_hart_rc,
           hwp_hart_errno,
           (unsigned long long) pairs_hart[0].value,
           (unsigned long long) pairs_hart[1].value,
           hwcap,
           ctrl,
           ctrl_errno,
           allow_buf);

    if (!dt_ext_ok || !dt_isa_ok || !ci_ok) {
        snprintf(out.reason,
                 sizeof(out.reason),
                 "discovery_source_missing(dt_ext=%d,dt_isa=%d,ci=%d)",
                 dt_ext_ok,
                 dt_isa_ok,
                 ci_ok);
        printf("%s id=%s case=discover verdict=FAIL reason=%s\n", TOKEN_PREFIX, run_id, out.reason);
        return out;
    }

    if (hwp_all_rc != 0 || hwp_hart_rc != 0 ||
        pairs_all[0].key != RISCV_HWPROBE_KEY_BASE_BEHAVIOR ||
        pairs_all[1].key != RISCV_HWPROBE_KEY_IMA_EXT_0 ||
        pairs_hart[0].key != RISCV_HWPROBE_KEY_BASE_BEHAVIOR ||
        pairs_hart[1].key != RISCV_HWPROBE_KEY_IMA_EXT_0 ||
        (pairs_all[0].value & RISCV_HWPROBE_BASE_BEHAVIOR_IMA) == 0 ||
        (pairs_hart[0].value & RISCV_HWPROBE_BASE_BEHAVIOR_IMA) == 0 || !hwcap_base) {
        snprintf(out.reason, sizeof(out.reason), "hwprobe_or_hwcap_base_failed");
        printf("%s id=%s case=discover verdict=FAIL reason=%s\n", TOKEN_PREFIX, run_id, out.reason);
        return out;
    }

    bool hwp_all_v = (pairs_all[1].value & RISCV_HWPROBE_IMA_V) != 0;
    bool hwp_hart_v = (pairs_hart[1].value & RISCV_HWPROBE_IMA_V) != 0;
    bool prctl_present = (ctrl >= 0);
    bool prctl_absent = (ctrl < 0 && ctrl_errno == EINVAL);

    bool all_present = dt_ext_v && dt_isa_v && ci_isa_v && ci_hart_v && hwp_all_v && hwp_hart_v &&
                       hwcap_v && prctl_present;
    bool all_absent = !dt_ext_v && !dt_ext_zve && !dt_isa_v && !dt_isa_zve && !ci_isa_v &&
                      !ci_isa_zve && !ci_hart_v && !ci_hart_zve && !hwp_all_v && !hwp_hart_v &&
                      !hwcap_v && prctl_absent;

    if (all_present) {
        out.mode = OBS_PRESENT;
    } else if (all_absent) {
        out.mode = OBS_ABSENT;
    } else {
        snprintf(out.reason, sizeof(out.reason), "discovery_surfaces_disagree");
        printf("%s id=%s case=discover verdict=FAIL reason=%s\n", TOKEN_PREFIX, run_id, out.reason);
        return out;
    }

    if (expect == EXPECT_PRESENT && out.mode != OBS_PRESENT) {
        snprintf(out.reason, sizeof(out.reason), "expected_present_got_absent");
        printf("%s id=%s case=discover verdict=FAIL reason=%s\n", TOKEN_PREFIX, run_id, out.reason);
        return out;
    }
    if (expect == EXPECT_ABSENT && out.mode != OBS_ABSENT) {
        snprintf(out.reason, sizeof(out.reason), "expected_absent_got_present");
        printf("%s id=%s case=discover verdict=FAIL reason=%s\n", TOKEN_PREFIX, run_id, out.reason);
        return out;
    }

    if (out.mode == OBS_ABSENT) {
        out.ok = true;
        probe_progress(run_id, "discover", "done");
        printf("%s id=%s case=discover verdict=PASS mode=absent\n", TOKEN_PREFIX, run_id);
        return out;
    }

    /* Present mode: verify default policy and run smoke child. */
    if ((ctrl & PR_RISCV_V_VSTATE_CTRL_CUR_MASK) != PR_RISCV_V_VSTATE_CTRL_ON) {
        snprintf(out.reason, sizeof(out.reason), "default_policy_not_on_%d", ctrl);
        printf("%s id=%s case=discover verdict=FAIL reason=%s\n", TOKEN_PREFIX, run_id, out.reason);
        return out;
    }

    uint64_t got_vlenb = 0, got_vl = 0;
    probe_progress(run_id, "discover", "smoke_start");
    if (!run_smoke_child(expected_vlenb, &got_vlenb, &got_vl, out.reason, sizeof(out.reason))) {
        printf("%s id=%s case=discover verdict=FAIL reason=%s\n", TOKEN_PREFIX, run_id, out.reason);
        return out;
    }
    probe_progress(run_id, "discover", "smoke_done");
    if (dt_max_zvl_bits > 0 && got_vlenb * 8ULL < dt_max_zvl_bits) {
        snprintf(out.reason,
                 sizeof(out.reason),
                 "vlenb_%llu_below_dt_zvl_%llu",
                 (unsigned long long) got_vlenb,
                 (unsigned long long) dt_max_zvl_bits);
        printf("%s id=%s case=discover verdict=FAIL reason=%s\n", TOKEN_PREFIX, run_id, out.reason);
        return out;
    }
    out.vlenb = got_vlenb;
    out.smoke_ok = 1;
    out.ok = true;
    probe_progress(run_id, "discover", "done");
    printf("%s id=%s case=discover verdict=PASS mode=present vlenb=%llu smoke=1\n",
           TOKEN_PREFIX,
           run_id,
           (unsigned long long) got_vlenb);
    return out;
}

/* --- Case 2 (Positive): lazy first use via tracefs function_graph --- */

struct first_use_shm {
    volatile uint32_t state; /* 0=init, 1=ready, 2=phase1_done, 3=phase2_done */
    volatile uint32_t cmd;   /* 0=hold, 1=run_phase1, 2=run_phase2, 3=abort */
    pid_t child_pid;
    uint64_t vl1;
    uint64_t vl2;
    int ctrl_val;
    int p2_match;
    char diff[128];
    struct ext_reg_state init_snap;
    struct ext_reg_state p2_snap;
};

/*
 * The child sleeps in futex wait while the parent configures tracefs (a long
 * walk of the kernel symbol table on a one-hart system); spinning there would
 * take the single CPU from that work and be counted in the setup budget.
 * The futex word lives in a shared mapping, so the operations are the
 * non-private ones.
 */
static void first_use_cmd_wait_nonzero(volatile uint32_t *cmd)
{
    while (__atomic_load_n(cmd, __ATOMIC_ACQUIRE) == 0U) {
        (void) syscall(SYS_futex, (uint32_t *) cmd, FUTEX_WAIT, 0U, NULL, NULL, 0);
    }
}

static void first_use_cmd_wake(volatile uint32_t *cmd)
{
    (void) syscall(SYS_futex, (uint32_t *) cmd, FUTEX_WAKE, 1, NULL, NULL, 0);
}

static int worker_first_use(int shm_fd, uint64_t expected_vlenb)
{
    size_t map_sz = align_page_size(sizeof(struct first_use_shm));
    struct first_use_shm *shm = mmap(NULL, map_sz, PROT_READ | PROT_WRITE, MAP_SHARED, shm_fd, 0);
    if (shm == MAP_FAILED)
        return 20;

    int ctrl = prctl(PR_RISCV_V_GET_CONTROL);
    shm->ctrl_val = ctrl;
    if (ctrl < 0 || (ctrl & PR_RISCV_V_VSTATE_CTRL_CUR_MASK) != PR_RISCV_V_VSTATE_CTRL_ON) {
        if (prctl(PR_RISCV_V_SET_CONTROL, PR_RISCV_V_VSTATE_CTRL_ON) < 0)
            return 21;
        shm->ctrl_val = prctl(PR_RISCV_V_GET_CONTROL);
    }

    struct ext_reg_state *pat = mmap(NULL,
                                     align_page_size(sizeof(*pat)),
                                     PROT_READ | PROT_WRITE,
                                     MAP_PRIVATE | MAP_ANONYMOUS,
                                     -1,
                                     0);
    if (pat == MAP_FAILED)
        return 22;
    fill_pattern(pat, 0x3c, expected_vlenb, 0);
    uint64_t p2_avl = (expected_vlenb / 4U) - 1U;
    shm->child_pid = getpid();

    /*
     * The wait for the Phase 1 release is a futex sleep: it runs before any
     * vector instruction, so it cannot reach the first-use handler. From the
     * release through phase 2 completion, execute zero syscalls.
     */
    __atomic_store_n(&shm->state, 1U, __ATOMIC_RELEASE);
    first_use_cmd_wait_nonzero(&shm->cmd);
    if (__atomic_load_n(&shm->cmd, __ATOMIC_ACQUIRE) != 1U)
        return 23;

    /* Phase 1: first extended instruction triggers lazy allocation/enable. */
    shm->vl1 = isa_probe_first_use_vsetvli();
    isa_probe_dump_state(&shm->init_snap);
    __atomic_store_n(&shm->state, 2U, __ATOMIC_RELEASE);

    while (__atomic_load_n(&shm->cmd, __ATOMIC_ACQUIRE) == 1U) {
    }
    if (__atomic_load_n(&shm->cmd, __ATOMIC_ACQUIRE) != 2U)
        return 24;

    /* Phase 2: second instruction must not re-enter the first-use handler. */
    shm->vl2 = isa_probe_phase2_vsetvli(p2_avl);
    isa_probe_load_state(pat);
    isa_probe_dump_state(&shm->p2_snap);
    if (compare_state(&shm->p2_snap, pat, expected_vlenb, shm->diff, sizeof(shm->diff)))
        shm->p2_match = 1;
    __atomic_store_n(&shm->state, 3U, __ATOMIC_RELEASE);
    return shm->p2_match ? 0 : 25;
}

static bool symbol_in_filter_functions(const char *sym)
{
    FILE *fp = fopen("/sys/kernel/tracing/available_filter_functions", "r");
    if (fp == NULL)
        return false;
    char line[512];
    bool found = false;
    while (fgets(line, sizeof(line), fp) != NULL) {
        char name[256];
        if (sscanf(line, "%255s", name) == 1 && strcmp(name, sym) == 0) {
            found = true;
            break;
        }
    }
    fclose(fp);
    return found;
}

static bool tracer_available(const char *tracer)
{
    FILE *fp = fopen("/sys/kernel/tracing/available_tracers", "r");
    if (fp == NULL)
        return false;
    char tok[128];
    bool found = false;
    while (fscanf(fp, "%127s", tok) == 1) {
        if (strcmp(tok, tracer) == 0) {
            found = true;
            break;
        }
    }
    fclose(fp);
    return found;
}

static int count_fgraph_hits(const char *trace_path,
                             const char *func_name,
                             pid_t target_pid,
                             char *sample_line,
                             size_t sample_sz)
{
    FILE *fp = fopen(trace_path, "r");
    if (fp == NULL)
        return -1;
    int total = 0;
    char line[1024];
    char needle[160];
    snprintf(needle, sizeof(needle), "%s()", func_name);
    if (sample_line != NULL && sample_sz > 0)
        sample_line[0] = '\0';

    while (fgets(line, sizeof(line), fp) != NULL) {
        if (line[0] == '#')
            continue;
        if (strstr(line, needle) == NULL)
            continue;
        /* With funcgraph-proc=1, the first '|' is preceded by '<comm>-<pid>'. */
        char *bar = strchr(line, '|');
        if (bar == NULL)
            continue;
        char *p = bar;
        while (p > line && (p[-1] == ' ' || p[-1] == '\t'))
            p--;
        char *digits_end = p;
        while (p > line && isdigit((unsigned char) p[-1]))
            p--;
        if (p == digits_end || p == line || p[-1] != '-')
            continue;
        char *end = NULL;
        long parsed_pid = strtol(p, &end, 10);
        if (end != digits_end || parsed_pid != (long) target_pid)
            continue;

        total++;
        if (sample_line != NULL && sample_sz > 0 && sample_line[0] == '\0') {
            size_t len = strlen(line);
            while (len > 0 && (line[len - 1] == '\n' || line[len - 1] == '\r'))
                line[--len] = '\0';
            size_t copy = (len < sample_sz - 1) ? len : (sample_sz - 1);
            memcpy(sample_line, line, copy);
            sample_line[copy] = '\0';
        }
    }
    fclose(fp);
    return total;
}

static bool read_trace_missed(const char *per_cpu_dir, unsigned long *missed_out)
{
    DIR *dir = opendir(per_cpu_dir);
    if (dir == NULL)
        return false;
    unsigned long missed = 0;
    int cpus_read = 0;
    struct dirent *de = NULL;
    while ((de = readdir(dir)) != NULL) {
        if (strncmp(de->d_name, "cpu", 3) != 0 || !isdigit((unsigned char) de->d_name[3]))
            continue;
        char stats_path[640];
        int n = snprintf(stats_path, sizeof(stats_path), "%s/%.64s/stats", per_cpu_dir, de->d_name);
        if (n <= 0 || (size_t) n >= sizeof(stats_path))
            continue;
        FILE *fp = fopen(stats_path, "r");
        if (fp == NULL)
            continue;
        cpus_read++;
        char line[256];
        while (fgets(line, sizeof(line), fp) != NULL) {
            unsigned long val = 0;
            if (sscanf(line, "overrun: %lu", &val) == 1 ||
                sscanf(line, "commit overrun: %lu", &val) == 1 ||
                sscanf(line, "dropped events: %lu", &val) == 1) {
                missed += val;
            }
        }
        fclose(fp);
    }
    closedir(dir);
    if (cpus_read == 0)
        return false;
    *missed_out = missed;
    return true;
}

static void sanitize_id(const char *in, char *out, size_t out_sz)
{
    size_t j = 0;
    for (size_t i = 0; in[i] != '\0' && j + 1 < out_sz; i++) {
        if (isalnum((unsigned char) in[i]) || in[i] == '_')
            out[j++] = in[i];
    }
    if (j == 0 && out_sz > 1)
        out[j++] = '0';
    out[j] = '\0';
}

static int run_first_use(const char *run_id, uint64_t expected_vlenb)
{
    const char *tr = "/sys/kernel/tracing";
    const char *target_fn = "riscv_v_first_use_handler";
    char instances_dir[256];
    snprintf(instances_dir, sizeof(instances_dir), "%s/instances", tr);

    probe_progress(run_id, "first-use", "start");

    if (access(instances_dir, W_OK) != 0) {
        printf("%s id=%s case=first-use verdict=FAIL reason=tracefs_unavailable\n",
               TOKEN_PREFIX,
               run_id);
        return 1;
    }
    if (!tracer_available("function_graph")) {
        printf("%s id=%s case=first-use verdict=FAIL reason=function_graph_unavailable\n",
               TOKEN_PREFIX,
               run_id);
        return 1;
    }
    if (!symbol_in_filter_functions(target_fn)) {
        printf(
            "%s id=%s case=first-use verdict=FAIL reason=symbol_missing\n", TOKEN_PREFIX, run_id);
        return 1;
    }

    int shm_fd = -1;
    struct first_use_shm *shm = alloc_shared_mem(sizeof(*shm), &shm_fd);
    if (shm == MAP_FAILED) {
        printf(
            "%s id=%s case=first-use verdict=FAIL reason=shm_alloc_failed\n", TOKEN_PREFIX, run_id);
        return 1;
    }
    probe_progress(run_id, "first-use", "preflight_done");

    char clean_id[24];
    sanitize_id(run_id, clean_id, sizeof(clean_id));
    char inst_dir[256];
    snprintf(
        inst_dir, sizeof(inst_dir), "%s/instances/isa_probe_%s_%ld", tr, clean_id, (long) getpid());

    char tracing_on_path[384], tracer_path[384], filter_path[384], pid_path[384];
    char opt_proc_path[384], trace_path[384], per_cpu_dir[384];
    snprintf(tracing_on_path, sizeof(tracing_on_path), "%s/tracing_on", inst_dir);
    snprintf(tracer_path, sizeof(tracer_path), "%s/current_tracer", inst_dir);
    snprintf(filter_path, sizeof(filter_path), "%s/set_ftrace_filter", inst_dir);
    snprintf(pid_path, sizeof(pid_path), "%s/set_ftrace_pid", inst_dir);
    snprintf(opt_proc_path, sizeof(opt_proc_path), "%s/options/funcgraph-proc", inst_dir);
    snprintf(trace_path, sizeof(trace_path), "%s/trace", inst_dir);
    snprintf(per_cpu_dir, sizeof(per_cpu_dir), "%s/per_cpu", inst_dir);

    bool inst_created = false;
    pid_t child = -1;
    int rc = 1;
    char reason[160] = "unknown";
    int traps_before = -1, traps_p1 = -1, traps_p2 = -1;
    unsigned long trace_missed = 0;
    int init_zero = 0;
    char sample[256] = "";
    struct first_use_budgets budgets;
    first_use_budgets_init(&budgets, mono_ms(), FIRST_USE_SETUP_BUDGET_MS);

    /* Fork and exec a fresh scalar-only child that waits at the gate. */
    probe_progress(run_id, "first-use", "spawn_child");
    child = fork();
    if (child < 0) {
        snprintf(reason, sizeof(reason), "fork_failed");
        goto cleanup;
    }
    if (child == 0) {
        char fd_arg[32], vlenb_arg[32];
        snprintf(fd_arg, sizeof(fd_arg), "%d", shm_fd);
        snprintf(vlenb_arg, sizeof(vlenb_arg), "%llu", (unsigned long long) expected_vlenb);
        char *argv_exec[] = {"frost_isa_probe", "--worker", "first-use", fd_arg, vlenb_arg, NULL};
        execv("/proc/self/exe", argv_exec);
        _exit(127);
    }

    bool gate_polled = false;
    while (__atomic_load_n(&shm->state, __ATOMIC_ACQUIRE) < 1U) {
        int st = 0;
        if (waitpid(child, &st, WNOHANG) == child) {
            child = -1;
            snprintf(reason, sizeof(reason), "child_died_before_gate_%d", st);
            goto cleanup;
        }
        if (gate_polled && first_use_setup_expired(&budgets, mono_ms())) {
            snprintf(reason, sizeof(reason), "gate_timeout");
            goto cleanup;
        }
        sleep_ms(2);
        gate_polled = true;
    }
    probe_progress(run_id, "first-use", "gate_ready");

    probe_progress(run_id, "first-use", "mkdir");
    if (mkdir(inst_dir, 0755) != 0) {
        snprintf(reason, sizeof(reason), "mkdir_instance_errno_%d", errno);
        goto cleanup;
    }
    inst_created = true;
    if (first_use_setup_expired(&budgets, mono_ms())) {
        snprintf(reason, sizeof(reason), "setup_timeout");
        goto cleanup;
    }

    char fn_cmd[128];
    char pid_cmd[64];
    snprintf(fn_cmd, sizeof(fn_cmd), "%s\n", target_fn);
    snprintf(pid_cmd, sizeof(pid_cmd), "%ld\n", (long) child);

    if (write_file_all(tracing_on_path, O_WRONLY | O_TRUNC, "0\n", 2) != 0) {
        snprintf(reason, sizeof(reason), "tracing_off_errno_%d", errno);
        goto cleanup;
    }
    probe_progress(run_id, "first-use", "filter");
    if (write_file_all(filter_path, O_WRONLY | O_TRUNC, fn_cmd, strlen(fn_cmd)) != 0) {
        snprintf(reason, sizeof(reason), "ftrace_filter_errno_%d", errno);
        goto cleanup;
    }
    if (first_use_setup_expired(&budgets, mono_ms())) {
        snprintf(reason, sizeof(reason), "setup_timeout");
        goto cleanup;
    }
    probe_progress(run_id, "first-use", "pid");
    if (write_file_all(pid_path, O_WRONLY | O_TRUNC, pid_cmd, strlen(pid_cmd)) != 0) {
        snprintf(reason, sizeof(reason), "ftrace_pid_errno_%d", errno);
        goto cleanup;
    }
    probe_progress(run_id, "first-use", "tracer");
    if (write_file_all(tracer_path, O_WRONLY | O_TRUNC, "function_graph\n", 15) != 0) {
        snprintf(reason, sizeof(reason), "tracer_set_errno_%d", errno);
        goto cleanup;
    }
    if (first_use_setup_expired(&budgets, mono_ms())) {
        snprintf(reason, sizeof(reason), "setup_timeout");
        goto cleanup;
    }
    probe_progress(run_id, "first-use", "options");
    if (write_file_all(opt_proc_path, O_WRONLY | O_TRUNC, "1\n", 2) != 0) {
        snprintf(reason, sizeof(reason), "opt_proc_errno_%d", errno);
        goto cleanup;
    }
    probe_progress(run_id, "first-use", "enable");
    if (write_file_all(trace_path, O_WRONLY | O_TRUNC, "", 0) != 0 ||
        write_file_all(tracing_on_path, O_WRONLY | O_TRUNC, "1\n", 2) != 0) {
        snprintf(reason, sizeof(reason), "trace_enable_errno_%d", errno);
        goto cleanup;
    }

    traps_before = count_fgraph_hits(trace_path, target_fn, child, NULL, 0);
    if (traps_before != 0) {
        snprintf(reason, sizeof(reason), "traps_before_%d", traps_before);
        goto cleanup;
    }
    if (first_use_setup_expired(&budgets, mono_ms())) {
        snprintf(reason, sizeof(reason), "setup_timeout");
        goto cleanup;
    }
    probe_progress(run_id, "first-use", "setup_done");

    /* Start phase limits only after child spawn and tracefs setup finish. */
    first_use_start_phases(&budgets, mono_ms(), FIRST_USE_PHASE_BUDGET_MS);

    /* Release Phase 1. */
    probe_progress(run_id, "first-use", "phase1_release");
    __atomic_store_n(&shm->cmd, 1U, __ATOMIC_RELEASE);
    first_use_cmd_wake(&shm->cmd);
    bool p1_polled = false;
    while (__atomic_load_n(&shm->state, __ATOMIC_ACQUIRE) < 2U) {
        int st = 0;
        if (waitpid(child, &st, WNOHANG) == child) {
            child = -1;
            snprintf(reason, sizeof(reason), "child_died_phase1_status_0x%x", st);
            goto cleanup;
        }
        if (first_use_phase_expired(&budgets, mono_ms(), p1_polled)) {
            snprintf(reason, sizeof(reason), "phase1_timeout");
            goto cleanup;
        }
        sleep_ms(2);
        p1_polled = true;
    }

    traps_p1 = count_fgraph_hits(trace_path, target_fn, child, sample, sizeof(sample));
    if (traps_p1 != 1) {
        snprintf(reason, sizeof(reason), "phase1_traps_%d", traps_p1);
        goto cleanup;
    }
    uint64_t want_vl1 = expected_vlenb / 2U;
    uint64_t want_vl2 = (expected_vlenb / 4U) - 1U;
    if (shm->vl1 != want_vl1 || shm->init_snap.vlenb != expected_vlenb) {
        snprintf(reason,
                 sizeof(reason),
                 "phase1_vl_%llu_want_%llu_vlenb_%llu",
                 (unsigned long long) shm->vl1,
                 (unsigned long long) want_vl1,
                 (unsigned long long) shm->init_snap.vlenb);
        goto cleanup;
    }
    char zdiff[128] = "";
    if (!check_zero_vregs(&shm->init_snap, expected_vlenb, zdiff, sizeof(zdiff))) {
        snprintf(reason, sizeof(reason), "%s", zdiff);
        goto cleanup;
    }
    init_zero = 1;
    probe_progress(run_id, "first-use", "phase1_done");

    /* Release Phase 2. */
    probe_progress(run_id, "first-use", "phase2_release");
    __atomic_store_n(&shm->cmd, 2U, __ATOMIC_RELEASE);
    int status = 0;
    if (wait_child_deadline(child, &status, budgets.phase_deadline_ms) != 0) {
        child = -1;
        snprintf(reason, sizeof(reason), "phase2_timeout");
        goto cleanup;
    }
    pid_t done_pid = child;
    child = -1;

    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        snprintf(reason, sizeof(reason), "phase2_child_status_0x%x_diff_%.112s", status, shm->diff);
        goto cleanup;
    }
    if (shm->vl2 != want_vl2 || shm->vl2 == shm->vl1 || shm->p2_match != 1) {
        snprintf(reason,
                 sizeof(reason),
                 "phase2_vl_%llu_want_%llu_match_%d",
                 (unsigned long long) shm->vl2,
                 (unsigned long long) want_vl2,
                 shm->p2_match);
        goto cleanup;
    }

    (void) write_file_all(tracing_on_path, O_WRONLY | O_TRUNC, "0\n", 2);
    traps_p2 = count_fgraph_hits(trace_path, target_fn, done_pid, NULL, 0);
    if (traps_p2 != 1) {
        snprintf(reason, sizeof(reason), "phase2_traps_%d", traps_p2);
        goto cleanup;
    }
    if (!read_trace_missed(per_cpu_dir, &trace_missed)) {
        snprintf(reason, sizeof(reason), "trace_stats_missing");
        goto cleanup;
    }
    if (trace_missed != 0) {
        snprintf(reason, sizeof(reason), "trace_missed_%lu", trace_missed);
        goto cleanup;
    }
    probe_progress(run_id, "first-use", "phase2_done");

    printf("%s id=%s case=first-use vl1=%llu vl2=%llu missed=%lu trace=%s\n",
           TOKEN_INFO,
           run_id,
           (unsigned long long) shm->vl1,
           (unsigned long long) shm->vl2,
           trace_missed,
           sample);
    rc = 0;

cleanup:
    probe_progress(run_id, "first-use", "cleanup");
    if (child > 0) {
        __atomic_store_n(&shm->cmd, 3U, __ATOMIC_RELEASE);
        kill(child, SIGKILL);
        int st = 0;
        while (waitpid(child, &st, 0) < 0 && errno == EINTR) {
        }
    }
    if (inst_created) {
        (void) write_file_all(tracing_on_path, O_WRONLY | O_TRUNC, "0\n", 2);
        (void) write_file_all(tracer_path, O_WRONLY | O_TRUNC, "nop\n", 4);
        (void) write_file_all(pid_path, O_WRONLY | O_TRUNC, "", 0);
        (void) write_file_all(filter_path, O_WRONLY | O_TRUNC, "", 0);
        (void) rmdir(inst_dir);
    }
    close(shm_fd);
    munmap(shm, align_page_size(sizeof(*shm)));
    probe_progress(run_id, "first-use", "done");

    if (rc == 0) {
        printf("%s id=%s case=first-use verdict=PASS traps_before=%d traps_phase1=%d "
               "traps_phase2=%d missed=%lu init_zero=%d\n",
               TOKEN_PREFIX,
               run_id,
               traps_before,
               traps_p1,
               traps_p2,
               trace_missed,
               init_zero);
    } else {
        printf("%s id=%s case=first-use verdict=FAIL reason=%s\n", TOKEN_PREFIX, run_id, reason);
    }
    return rc;
}

/* --- Case 3 (Positive): two runnable processes on the same hart --- */

struct switch_shm {
    volatile uint32_t phase;
    volatile uint32_t abort_flag;
    pid_t pid_a;
    pid_t pid_b;
    int rounds_a;
    int rounds_b;
    int err_a;
    int err_b;
    char diff_a[128];
    char diff_b[128];
};

static int run_switch_worker(struct switch_shm *shm, int who, int rounds, int cpu, uint64_t vlenb)
{
    if (!pin_to_cpu(cpu))
        return 30;
    if (prctl(PR_RISCV_V_SET_CONTROL, PR_RISCV_V_VSTATE_CTRL_ON) < 0)
        return 31;

    struct ext_reg_state *bufs = mmap(NULL,
                                      align_page_size(sizeof(*bufs) * 2),
                                      PROT_READ | PROT_WRITE,
                                      MAP_PRIVATE | MAP_ANONYMOUS,
                                      -1,
                                      0);
    if (bufs == MAP_FAILED)
        return 32;
    memset(bufs, 0, sizeof(*bufs) * 2);
    struct ext_reg_state *pat = bufs;
    struct ext_reg_state *snap = bufs + 1;

    if (who == 0) {
        shm->pid_a = getpid();
        fill_pattern(pat, 0x5a, vlenb, 0);
    } else {
        shm->pid_b = getpid();
        fill_pattern(pat, 0xa5, vlenb, 1);
    }

    /* No syscalls from seeding until all rounds finish. */
    if (who == 0) {
        isa_probe_load_state(pat);
        __atomic_store_n(&shm->phase, 1U, __ATOMIC_RELEASE);
    } else {
        while (__atomic_load_n(&shm->phase, __ATOMIC_ACQUIRE) < 1U) {
            if (__atomic_load_n(&shm->abort_flag, __ATOMIC_ACQUIRE))
                return 33;
        }
        isa_probe_load_state(pat);
        __atomic_store_n(&shm->phase, 2U, __ATOMIC_RELEASE);
    }

    for (int r = 1; r <= rounds; r++) {
        uint32_t wait_for = (who == 0) ? (uint32_t) (2 * r) : (uint32_t) (2 * r + 1);
        uint32_t next_val = wait_for + 1U;
        while (__atomic_load_n(&shm->phase, __ATOMIC_ACQUIRE) != wait_for) {
            if (__atomic_load_n(&shm->abort_flag, __ATOMIC_ACQUIRE))
                return 34;
        }
        isa_probe_dump_state(snap);
        char *diff_dst = (who == 0) ? shm->diff_a : shm->diff_b;
        if (!compare_state(snap, pat, vlenb, diff_dst, 128)) {
            if (who == 0)
                shm->err_a = r;
            else
                shm->err_b = r;
            __atomic_store_n(&shm->abort_flag, 1U, __ATOMIC_RELEASE);
            return 35;
        }
        isa_probe_rearm_vstart(pat->vstart);
        if (who == 0)
            shm->rounds_a = r;
        else
            shm->rounds_b = r;
        __atomic_store_n(&shm->phase, next_val, __ATOMIC_RELEASE);
    }
    return 0;
}

static int run_switch(const char *run_id, int rounds, int cpu, uint64_t vlenb)
{
    probe_progress(run_id, "switch", "start");
    struct switch_shm *shm = alloc_shared_mem(sizeof(*shm), NULL);
    if (shm == MAP_FAILED) {
        printf("%s id=%s case=switch verdict=FAIL reason=shm_alloc_failed\n", TOKEN_PREFIX, run_id);
        return 1;
    }

    pid_t pid_a = fork();
    if (pid_a < 0) {
        munmap(shm, align_page_size(sizeof(*shm)));
        printf("%s id=%s case=switch verdict=FAIL reason=fork_a_failed\n", TOKEN_PREFIX, run_id);
        return 1;
    }
    if (pid_a == 0)
        _exit(run_switch_worker(shm, 0, rounds, cpu, vlenb));

    pid_t pid_b = fork();
    if (pid_b < 0) {
        kill(pid_a, SIGKILL);
        int st = 0;
        waitpid(pid_a, &st, 0);
        munmap(shm, align_page_size(sizeof(*shm)));
        printf("%s id=%s case=switch verdict=FAIL reason=fork_b_failed\n", TOKEN_PREFIX, run_id);
        return 1;
    }
    if (pid_b == 0)
        _exit(run_switch_worker(shm, 1, rounds, cpu, vlenb));
    probe_progress(run_id, "switch", "workers_spawned");

    uint64_t deadline = mono_ms() + 55000ULL;
    int st_a = 0, st_b = 0;
    bool done_a = false, done_b = false;
    bool timed_out = false;
    while (!done_a || !done_b) {
        if (!done_a && waitpid(pid_a, &st_a, WNOHANG) == pid_a)
            done_a = true;
        if (!done_b && waitpid(pid_b, &st_b, WNOHANG) == pid_b)
            done_b = true;
        if (done_a && done_b)
            break;
        if (mono_ms() >= deadline) {
            timed_out = true;
            __atomic_store_n(&shm->abort_flag, 1U, __ATOMIC_RELEASE);
            if (!done_a) {
                kill(pid_a, SIGKILL);
                waitpid(pid_a, &st_a, 0);
            }
            if (!done_b) {
                kill(pid_b, SIGKILL);
                waitpid(pid_b, &st_b, 0);
            }
            break;
        }
        sleep_ms(5);
    }

    uint32_t final_phase = __atomic_load_n(&shm->phase, __ATOMIC_ACQUIRE);
    uint32_t expected_phase = (uint32_t) (2 * rounds + 2);
    probe_progress(run_id, "switch", "done");
    printf("%s id=%s case=switch pid_a=%ld pid_b=%ld phase=%u/%u rounds_a=%d rounds_b=%d\n",
           TOKEN_INFO,
           run_id,
           (long) shm->pid_a,
           (long) shm->pid_b,
           final_phase,
           expected_phase,
           shm->rounds_a,
           shm->rounds_b);

    bool ok = !timed_out && WIFEXITED(st_a) && WEXITSTATUS(st_a) == 0 && WIFEXITED(st_b) &&
              WEXITSTATUS(st_b) == 0 && shm->pid_a != 0 && shm->pid_b != 0 &&
              shm->pid_a != shm->pid_b && shm->rounds_a == rounds && shm->rounds_b == rounds &&
              final_phase == expected_phase;

    if (ok) {
        printf("%s id=%s case=switch verdict=PASS rounds_a=%d rounds_b=%d cpu=%d\n",
               TOKEN_PREFIX,
               run_id,
               shm->rounds_a,
               shm->rounds_b,
               cpu);
    } else if (timed_out) {
        printf("%s id=%s case=switch verdict=FAIL reason=timeout_phase_%u\n",
               TOKEN_PREFIX,
               run_id,
               final_phase);
    } else if (shm->err_a != 0) {
        printf("%s id=%s case=switch verdict=FAIL reason=a_round_%d_%s\n",
               TOKEN_PREFIX,
               run_id,
               shm->err_a,
               shm->diff_a);
    } else if (shm->err_b != 0) {
        printf("%s id=%s case=switch verdict=FAIL reason=b_round_%d_%s\n",
               TOKEN_PREFIX,
               run_id,
               shm->err_b,
               shm->diff_b);
    } else {
        printf("%s id=%s case=switch verdict=FAIL reason=status_a_0x%x_b_0x%x\n",
               TOKEN_PREFIX,
               run_id,
               st_a,
               st_b);
    }

    munmap(shm, align_page_size(sizeof(*shm)));
    return ok ? 0 : 1;
}

/* --- Case 4 (Positive & Stock): signal frame and return --- */

struct sig_shared {
    volatile uint32_t ready;
    volatile uint32_t stop;
    int deliveries;
    int clobbers_ok;
    int fail_code;
    uint32_t observed_magic;
    uint32_t observed_size;
    char diff[128];
};

static struct sig_shared *g_sig_shm;
static pid_t g_sig_sender_pid;
static bool g_sig_present_mode;
static bool g_sig_expect_alt;
static uint64_t g_sig_vlenb;
static uintptr_t g_sig_alt_base;
static uintptr_t g_sig_alt_end;
static uintptr_t g_sig_main_sp;
static struct ext_reg_state *g_sig_expected;
static struct ext_reg_state *g_sig_clobber;
static struct ext_reg_state *g_sig_clobber_chk;

static void sigusr1_handler(int sig, siginfo_t *si, void *uctx)
{
    volatile uintptr_t local_marker = 0;
    uintptr_t sp = (uintptr_t) &local_marker;
    int err = 0;

    if (sig != SIGUSR1 || si == NULL || uctx == NULL) {
        err = 1;
        goto done;
    }
    if (si->si_pid != g_sig_sender_pid || si->si_code != SI_USER) {
        err = 2;
        goto done;
    }

    ucontext_t *uc = (ucontext_t *) uctx;
    const struct user_regs_struct *regs = (const struct user_regs_struct *) &uc->uc_mcontext;
    uintptr_t pc = (uintptr_t) regs->pc;
    if (pc < (uintptr_t) isa_probe_spin_loop || pc >= (uintptr_t) isa_probe_spin_end) {
        err = 3;
        goto done;
    }

    if (g_sig_expect_alt) {
        if (sp < g_sig_alt_base || sp >= g_sig_alt_end) {
            err = 4;
            goto done;
        }
        if ((uintptr_t) uc < g_sig_alt_base || (uintptr_t) uc >= g_sig_alt_end) {
            err = 5;
            goto done;
        }
    } else {
        if (g_sig_alt_base != 0 && sp >= g_sig_alt_base && sp < g_sig_alt_end) {
            err = 6;
            goto done;
        }
        if ((uintptr_t) uc < sp || (uintptr_t) uc >= g_sig_main_sp) {
            err = 7;
            goto done;
        }
    }

    const uint8_t *mc = (const uint8_t *) &uc->uc_mcontext;
    const struct __riscv_extra_ext_header *ext =
        (const struct __riscv_extra_ext_header *) (mc + sizeof(struct user_regs_struct));
    if (ext->reserved != 0) {
        err = 8;
        goto done;
    }

    const uint8_t *cursor = (const uint8_t *) &ext->hdr;
    struct __riscv_ctx_hdr hdr;
    memcpy(&hdr, cursor, sizeof(hdr));
    g_sig_shm->observed_magic = hdr.magic;
    g_sig_shm->observed_size = hdr.size;

    uintptr_t frame_hi = g_sig_expect_alt ? g_sig_alt_end : g_sig_main_sp;
    if (!g_sig_present_mode) {
        if (hdr.magic != END_MAGIC || hdr.size != END_HDR_SIZE) {
            err = 9;
            goto done;
        }
    } else {
        size_t expected_rec_size = sizeof(struct __riscv_ctx_hdr) +
                                   sizeof(struct __riscv_v_ext_state) +
                                   (size_t) (32U * g_sig_vlenb);
        if (hdr.magic != RISCV_V_MAGIC || hdr.size != expected_rec_size) {
            err = 10;
            goto done;
        }
        if ((uintptr_t) cursor + hdr.size + sizeof(struct __riscv_ctx_hdr) > frame_hi) {
            err = 11;
            goto done;
        }
        const struct __riscv_v_ext_state *vs =
            (const struct __riscv_v_ext_state *) (cursor + sizeof(struct __riscv_ctx_hdr));
        if (((uintptr_t) vs & 0xfU) != 0) {
            err = 12;
            goto done;
        }
        uintptr_t datap_addr = (uintptr_t) vs->datap;
        uintptr_t expected_datap = (uintptr_t) vs + sizeof(struct __riscv_v_ext_state);
        if ((datap_addr & 0xfU) != 0 || datap_addr != expected_datap ||
            datap_addr + (size_t) (32U * g_sig_vlenb) > (uintptr_t) cursor + hdr.size) {
            err = 13;
            goto done;
        }
        struct __riscv_ctx_hdr end_hdr;
        memcpy(&end_hdr, cursor + hdr.size, sizeof(end_hdr));
        if (end_hdr.magic != END_MAGIC || end_hdr.size != END_HDR_SIZE) {
            err = 14;
            goto done;
        }

        struct ext_reg_state frame_snap;
        memset(&frame_snap, 0, sizeof(frame_snap));
        frame_snap.vstart = vs->vstart;
        frame_snap.vl = vs->vl;
        frame_snap.vtype = vs->vtype;
        frame_snap.vcsr = vs->vcsr;
        frame_snap.vlenb = vs->vlenb;
        memcpy(frame_snap.vreg, vs->datap, (size_t) (32U * g_sig_vlenb));
        if (!compare_state(&frame_snap,
                           g_sig_expected,
                           g_sig_vlenb,
                           g_sig_shm->diff,
                           sizeof(g_sig_shm->diff))) {
            err = 15;
            goto done;
        }

        /* Overwrite live registers in the handler and verify the clobber took effect. */
        isa_probe_load_state(g_sig_clobber);
        isa_probe_dump_state(g_sig_clobber_chk);
        if (!compare_state(g_sig_clobber_chk,
                           g_sig_clobber,
                           g_sig_vlenb,
                           g_sig_shm->diff,
                           sizeof(g_sig_shm->diff))) {
            err = 16;
            goto done;
        }
        isa_probe_rearm_vstart(g_sig_clobber->vstart);
        g_sig_shm->clobbers_ok++;
    }

    g_sig_shm->deliveries++;

done:
    if (err != 0 && g_sig_shm->fail_code == 0)
        g_sig_shm->fail_code = err;
    __atomic_store_n(&g_sig_shm->stop, 1U, __ATOMIC_RELEASE);
}

static bool run_signal_stack_phase(bool present_mode,
                                   bool use_altstack,
                                   int rounds,
                                   uint64_t vlenb,
                                   int *deliveries_out,
                                   int *clobbers_out,
                                   uint32_t *magic_out,
                                   uint32_t *size_out,
                                   char *reason,
                                   size_t reason_sz)
{
    struct sig_shared *shm = alloc_shared_mem(sizeof(*shm), NULL);
    if (shm == MAP_FAILED) {
        snprintf(reason, reason_sz, "shm_alloc_failed");
        return false;
    }

    pid_t parent_pid = getpid();
    pid_t child = fork();
    if (child < 0) {
        munmap(shm, align_page_size(sizeof(*shm)));
        snprintf(reason, reason_sz, "fork_failed");
        return false;
    }
    if (child == 0) {
        volatile uintptr_t stack_anchor = 0;
        g_sig_main_sp = (uintptr_t) &stack_anchor;
        g_sig_shm = shm;
        g_sig_sender_pid = parent_pid;
        g_sig_present_mode = present_mode;
        g_sig_expect_alt = use_altstack;
        g_sig_vlenb = vlenb;
        g_sig_alt_base = 0;
        g_sig_alt_end = 0;

        if (present_mode && prctl(PR_RISCV_V_SET_CONTROL, PR_RISCV_V_VSTATE_CTRL_ON) < 0)
            _exit(40);

        struct ext_reg_state *states = mmap(NULL,
                                            align_page_size(sizeof(*states) * 4),
                                            PROT_READ | PROT_WRITE,
                                            MAP_PRIVATE | MAP_ANONYMOUS,
                                            -1,
                                            0);
        if (states == MAP_FAILED)
            _exit(41);
        memset(states, 0, sizeof(*states) * 4);
        g_sig_expected = states + 0;
        g_sig_clobber = states + 1;
        g_sig_clobber_chk = states + 2;
        struct ext_reg_state *resumed = states + 3;

        /* Always allocate a guarded alternate stack so normal-stack checks can also exclude it. */
        long ps = sysconf(_SC_PAGESIZE);
        size_t page = (ps > 0) ? (size_t) ps : 4096U;
        unsigned long minsig = getauxval(AT_MINSIGSTKSZ);
        size_t usable = 65536U;
        if (minsig > 0 && (size_t) minsig * 2U > usable)
            usable = (size_t) minsig * 2U;
        usable = (usable + page - 1U) & ~(page - 1U);
        uint8_t *guarded =
            mmap(NULL, usable + 2U * page, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (guarded == MAP_FAILED)
            _exit(42);
        if (mprotect(guarded + page, usable, PROT_READ | PROT_WRITE) != 0)
            _exit(43);
        memset(guarded + page, 0, usable);
        g_sig_alt_base = (uintptr_t) (guarded + page);
        g_sig_alt_end = g_sig_alt_base + usable;

        if (use_altstack) {
            stack_t ss;
            ss.ss_sp = (void *) g_sig_alt_base;
            ss.ss_size = usable;
            ss.ss_flags = 0;
            if (sigaltstack(&ss, NULL) != 0)
                _exit(44);
        }

        struct sigaction sa;
        memset(&sa, 0, sizeof(sa));
        sa.sa_sigaction = sigusr1_handler;
        sa.sa_flags = SA_SIGINFO | (use_altstack ? SA_ONSTACK : 0);
        sigemptyset(&sa.sa_mask);
        if (sigaction(SIGUSR1, &sa, NULL) != 0)
            _exit(45);

        for (int r = 0; r < rounds; r++) {
            __atomic_store_n(&shm->stop, 0U, __ATOMIC_RELEASE);
            if (present_mode) {
                fill_pattern(g_sig_expected, (uint8_t) (0x30U + (unsigned) r), vlenb, r & 1);
                fill_pattern(g_sig_clobber, (uint8_t) (0xc0U + (unsigned) r), vlenb, 2);
                /* Live window: zero syscalls from load_state through dump_state after sigreturn. */
                isa_probe_load_state(g_sig_expected);
                isa_probe_spin_until_flag(&shm->ready, &shm->stop);
                isa_probe_dump_state(resumed);
                if (shm->fail_code != 0)
                    _exit(46);
                if (!compare_state(resumed, g_sig_expected, vlenb, shm->diff, sizeof(shm->diff))) {
                    shm->fail_code = 17;
                    _exit(47);
                }
            } else {
                isa_probe_spin_until_flag(&shm->ready, &shm->stop);
                if (shm->fail_code != 0)
                    _exit(46);
            }
        }
        _exit(0);
    }

    uint64_t deadline = mono_ms() + 20000ULL;
    bool ok = true;
    for (int r = 0; r < rounds; r++) {
        while (__atomic_load_n(&shm->ready, __ATOMIC_ACQUIRE) == 0U) {
            int st = 0;
            if (waitpid(child, &st, WNOHANG) == child) {
                child = -1;
                snprintf(reason,
                         reason_sz,
                         "target_died_round_%d_status_0x%x_fc_%d_%s",
                         r,
                         st,
                         shm->fail_code,
                         shm->diff);
                ok = false;
                break;
            }
            if (mono_ms() >= deadline) {
                snprintf(reason, reason_sz, "ready_timeout_round_%d", r);
                ok = false;
                break;
            }
            sleep_ms(1);
        }
        if (!ok)
            break;
        __atomic_store_n(&shm->ready, 0U, __ATOMIC_RELEASE);
        if (kill(child, SIGUSR1) != 0) {
            snprintf(reason, reason_sz, "kill_errno_%d", errno);
            ok = false;
            break;
        }
    }

    int status = 0;
    if (child > 0) {
        if (!ok) {
            kill(child, SIGKILL);
            waitpid(child, &status, 0);
        } else if (wait_child_deadline(child, &status, deadline) != 0) {
            snprintf(reason, reason_sz, "exit_timeout");
            ok = false;
        } else if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
            snprintf(reason,
                     reason_sz,
                     "target_status_0x%x_fc_%d_%s",
                     status,
                     shm->fail_code,
                     shm->diff);
            ok = false;
        }
    }

    *deliveries_out = shm->deliveries;
    *clobbers_out = shm->clobbers_ok;
    *magic_out = shm->observed_magic;
    *size_out = shm->observed_size;
    if (ok && shm->deliveries != rounds) {
        snprintf(reason, reason_sz, "deliveries_%d_want_%d", shm->deliveries, rounds);
        ok = false;
    }
    if (ok && present_mode && shm->clobbers_ok != rounds) {
        snprintf(reason, reason_sz, "clobbers_%d_want_%d", shm->clobbers_ok, rounds);
        ok = false;
    }

    munmap(shm, align_page_size(sizeof(*shm)));
    return ok;
}

static int run_signal(
    const char *run_id, bool present_mode, int rounds, const char *stack_mode, uint64_t vlenb)
{
    char reason[192] = "";
    probe_progress(run_id, "signal", "start");
    if (!present_mode) {
        int deliv = 0, clob = 0;
        uint32_t magic = 0, sz = 0;
        probe_progress(run_id, "signal", "normal_start");
        if (!run_signal_stack_phase(
                false, false, rounds, vlenb, &deliv, &clob, &magic, &sz, reason, sizeof(reason))) {
            probe_progress(run_id, "signal", "done");
            printf("%s id=%s case=signal verdict=FAIL reason=%s\n", TOKEN_PREFIX, run_id, reason);
            return 1;
        }
        probe_progress(run_id, "signal", "done");
        printf("%s id=%s case=signal verdict=PASS rounds=%d end_magic=%u end_size=%u\n",
               TOKEN_PREFIX,
               run_id,
               deliv,
               magic,
               sz);
        return 0;
    }

    int norm_deliv = 0, norm_clob = 0, alt_deliv = 0, alt_clob = 0;
    uint32_t norm_magic = 0, norm_sz = 0, alt_magic = 0, alt_sz = 0;
    bool do_norm = (strcmp(stack_mode, "both") == 0 || strcmp(stack_mode, "normal") == 0);
    bool do_alt = (strcmp(stack_mode, "both") == 0 || strcmp(stack_mode, "alt") == 0);

    if (do_norm) {
        probe_progress(run_id, "signal", "normal_start");
        if (!run_signal_stack_phase(true,
                                    false,
                                    rounds,
                                    vlenb,
                                    &norm_deliv,
                                    &norm_clob,
                                    &norm_magic,
                                    &norm_sz,
                                    reason,
                                    sizeof(reason))) {
            probe_progress(run_id, "signal", "done");
            printf("%s id=%s case=signal verdict=FAIL reason=normal_%s\n",
                   TOKEN_PREFIX,
                   run_id,
                   reason);
            return 1;
        }
        probe_progress(run_id, "signal", "normal_done");
    }
    if (do_alt) {
        probe_progress(run_id, "signal", "alt_start");
        if (!run_signal_stack_phase(true,
                                    true,
                                    rounds,
                                    vlenb,
                                    &alt_deliv,
                                    &alt_clob,
                                    &alt_magic,
                                    &alt_sz,
                                    reason,
                                    sizeof(reason))) {
            probe_progress(run_id, "signal", "done");
            printf(
                "%s id=%s case=signal verdict=FAIL reason=alt_%s\n", TOKEN_PREFIX, run_id, reason);
            return 1;
        }
        probe_progress(run_id, "signal", "alt_done");
    }

    probe_progress(run_id, "signal", "done");
    printf("%s id=%s case=signal norm_magic=0x%x norm_size=%u alt_magic=0x%x alt_size=%u\n",
           TOKEN_INFO,
           run_id,
           norm_magic,
           norm_sz,
           alt_magic,
           alt_sz);
    printf("%s id=%s case=signal verdict=PASS normal_rounds=%d alt_rounds=%d clobbers=%d\n",
           TOKEN_PREFIX,
           run_id,
           norm_deliv,
           alt_deliv,
           norm_clob + alt_clob);
    return 0;
}

/* --- Case 5 (Positive & Stock): ptrace regset visibility and write --- */

struct ptrace_shm {
    volatile uint32_t ready;
    volatile uint32_t stop;
    volatile uint32_t ready2;
    volatile uint32_t stop2;
    int setregset_seen;
    int resumed_ok;
    char diff[128];
};

static int run_ptrace(const char *run_id, bool present_mode, uint64_t vlenb)
{
    probe_progress(run_id, "ptrace", "start");
    struct ptrace_shm *shm = alloc_shared_mem(sizeof(*shm), NULL);
    if (shm == MAP_FAILED) {
        printf("%s id=%s case=ptrace verdict=FAIL reason=shm_alloc_failed\n", TOKEN_PREFIX, run_id);
        return 1;
    }

    struct ext_reg_state expected;
    struct ext_reg_state written;
    fill_pattern(&expected, 0x69, vlenb, 0);
    fill_pattern(&written, 0x96, vlenb, 1);

    pid_t parent_pid = getpid();
    pid_t child = fork();
    if (child < 0) {
        munmap(shm, align_page_size(sizeof(*shm)));
        printf("%s id=%s case=ptrace verdict=FAIL reason=fork_failed\n", TOKEN_PREFIX, run_id);
        return 1;
    }
    if (child == 0) {
        (void) prctl(PR_SET_DUMPABLE, 1);
#ifdef PR_SET_PTRACER
        (void) prctl(PR_SET_PTRACER, (unsigned long) parent_pid);
#else
        (void) parent_pid;
#endif
        if (present_mode && prctl(PR_RISCV_V_SET_CONTROL, PR_RISCV_V_VSTATE_CTRL_ON) < 0)
            _exit(50);
        if (ptrace(PTRACE_TRACEME, 0, NULL, NULL) != 0)
            _exit(51);

        if (!present_mode) {
            /* Enter known-PC spin loop; parent sends SIGSTOP to inspect regsets. */
            isa_probe_spin_until_flag(&shm->ready, &shm->stop);
            _exit(0);
        }

        /* Stop 1: never-used scalar stop before touching any extended instruction. */
        raise(SIGSTOP);

        struct ext_reg_state *bufs = mmap(NULL,
                                          align_page_size(sizeof(*bufs) * 3),
                                          PROT_READ | PROT_WRITE,
                                          MAP_PRIVATE | MAP_ANONYMOUS,
                                          -1,
                                          0);
        if (bufs == MAP_FAILED)
            _exit(52);
        memset(bufs, 0, sizeof(*bufs) * 3);
        fill_pattern(bufs, 0x69, vlenb, 0);
        fill_pattern(bufs + 1, 0x96, vlenb, 1);
        struct ext_reg_state *after = bufs + 2;

        /*
         * Live window 1: seed initial state (0x69), spin for Stop 2 while tracer
         * checks GETREGSET and writes new state (0x96) via SETREGSET, then resume
         * with signal 0 and verify hardware registers equal the written state.
         */
        isa_probe_load_state(bufs);
        isa_probe_spin_until_flag(&shm->ready, &shm->stop);
        isa_probe_dump_state(after);
        if (!compare_state(after, bufs + 1, vlenb, shm->diff, sizeof(shm->diff)))
            _exit(53);
        shm->setregset_seen = 1;

        /*
         * Live window 2: restore the checked state (dump_state clears vstart) and
         * spin for Stop 3 so the tracer can read back the live post-resume regset.
         */
        isa_probe_load_state(after);
        isa_probe_spin_until_flag(&shm->ready2, &shm->stop2);
        isa_probe_dump_state(after);
        if (!compare_state(after, bufs + 1, vlenb, shm->diff, sizeof(shm->diff)))
            _exit(54);
        shm->resumed_ok = 1;
        _exit(0);
    }

    uint64_t deadline = mono_ms() + 15000ULL;
    size_t want_bytes = REGSET_HDR_BYTES + (size_t) (32U * vlenb);
    uint8_t vec_buf[REGSET_HDR_BYTES + MAX_PROBE_VSIZE];
    uint8_t set_buf[REGSET_HDR_BYTES + MAX_PROBE_VSIZE];
    char reason[192] = "";
    int status = 0;

    if (!present_mode) {
        while (__atomic_load_n(&shm->ready, __ATOMIC_ACQUIRE) == 0U) {
            if (waitpid(child, &status, WNOHANG) == child) {
                snprintf(reason, sizeof(reason), "child_exited_early_0x%x", status);
                goto fail_stock;
            }
            if (mono_ms() >= deadline) {
                snprintf(reason, sizeof(reason), "ready_timeout");
                goto fail_stock;
            }
            sleep_ms(2);
        }
        if (kill(child, SIGSTOP) != 0 || wait_ptrace_stop_deadline(child, &status, deadline) != 0 ||
            !WIFSTOPPED(status) || WSTOPSIG(status) != SIGSTOP) {
            snprintf(reason, sizeof(reason), "stop_failed_0x%x", status);
            goto fail_stock;
        }
        probe_progress(run_id, "ptrace", "stopped");
        struct user_regs_struct gpr;
        struct iovec gi = {.iov_base = &gpr, .iov_len = sizeof(gpr)};
        if (ptrace(PTRACE_GETREGSET, child, (void *) (uintptr_t) NT_PRSTATUS, &gi) != 0 ||
            gi.iov_len != sizeof(gpr) || (uintptr_t) gpr.pc < (uintptr_t) isa_probe_spin_loop ||
            (uintptr_t) gpr.pc >= (uintptr_t) isa_probe_spin_end) {
            snprintf(reason, sizeof(reason), "gpr_check_failed_pc_0x%lx", gpr.pc);
            goto fail_stock;
        }
        struct iovec vi = {.iov_base = vec_buf, .iov_len = want_bytes};
        errno = 0;
        long vr = ptrace(PTRACE_GETREGSET, child, (void *) (uintptr_t) NT_RISCV_VECTOR, &vi);
        /*
         * Absent-mode check: arch/riscv/kernel/ptrace.c rejects NT_RISCV_VECTOR
         * with EINVAL when the CPU/kernel has no V extension, on all kernels
         * (upstream commit 8cdb04bd06c1 only changed the inactive present-mode path).
         */
        if (vr == 0 || errno != EINVAL) {
            snprintf(reason, sizeof(reason), "expected_einval_got_rc_%ld_errno_%d", vr, errno);
            goto fail_stock;
        }
        __atomic_store_n(&shm->stop, 1U, __ATOMIC_RELEASE);
        if (ptrace(PTRACE_CONT, child, NULL, NULL) != 0 ||
            wait_child_deadline(child, &status, deadline) != 0 || !WIFEXITED(status) ||
            WEXITSTATUS(status) != 0) {
            snprintf(reason, sizeof(reason), "resume_failed_0x%x", status);
            goto fail_stock;
        }
        munmap(shm, align_page_size(sizeof(*shm)));
        probe_progress(run_id, "ptrace", "done");
        printf("%s id=%s case=ptrace verdict=PASS gpr_ok=1 einval=1\n", TOKEN_PREFIX, run_id);
        return 0;

    fail_stock:
        kill(child, SIGKILL);
        waitpid(child, &status, 0);
        munmap(shm, align_page_size(sizeof(*shm)));
        probe_progress(run_id, "ptrace", "done");
        printf("%s id=%s case=ptrace verdict=FAIL reason=%s\n", TOKEN_PREFIX, run_id, reason);
        return 1;
    }

    /* Positive mode: Stop 1 (never-used) -> EINVAL (< 7.0) or ENODATA (>= 7.0; 8cdb04bd06c1). */
    char krel[65] = "";
    int want_inactive_errno = expected_inactive_vreg_errno(krel, sizeof(krel));
    if (want_inactive_errno < 0) {
        snprintf(reason, sizeof(reason), "stop1_uname_parse_failed_%s", krel);
        goto fail_pos;
    }
    if (wait_ptrace_stop_deadline(child, &status, deadline) != 0 || !WIFSTOPPED(status) ||
        WSTOPSIG(status) != SIGSTOP) {
        snprintf(reason, sizeof(reason), "stop1_failed_0x%x", status);
        goto fail_pos;
    }
    struct user_regs_struct gpr;
    struct iovec gi = {.iov_base = &gpr, .iov_len = sizeof(gpr)};
    if (ptrace(PTRACE_GETREGSET, child, (void *) (uintptr_t) NT_PRSTATUS, &gi) != 0 ||
        gi.iov_len != sizeof(gpr) || gpr.pc == 0) {
        snprintf(reason, sizeof(reason), "stop1_gpr_failed");
        goto fail_pos;
    }
    struct iovec vi1 = {.iov_base = vec_buf, .iov_len = want_bytes};
    errno = 0;
    long vr1 = ptrace(PTRACE_GETREGSET, child, (void *) (uintptr_t) NT_RISCV_VECTOR, &vi1);
    if (vr1 == 0 || errno != want_inactive_errno) {
        snprintf(reason,
                 sizeof(reason),
                 "stop1_expected_errno_%d_rc_%ld_e_%d",
                 want_inactive_errno,
                 vr1,
                 errno);
        goto fail_pos;
    }
    if (ptrace(PTRACE_CONT, child, NULL, NULL) != 0) {
        snprintf(reason, sizeof(reason), "cont1_failed");
        goto fail_pos;
    }
    probe_progress(run_id, "ptrace", "stop1_done");

    /* Wait for live-state handshake, then Stop 2 (active). */
    while (__atomic_load_n(&shm->ready, __ATOMIC_ACQUIRE) == 0U) {
        if (waitpid(child, &status, WNOHANG) == child) {
            snprintf(reason, sizeof(reason), "child_died_before_stop2_0x%x", status);
            goto fail_pos;
        }
        if (mono_ms() >= deadline) {
            snprintf(reason, sizeof(reason), "stop2_ready_timeout");
            goto fail_pos;
        }
        sleep_ms(2);
    }
    if (kill(child, SIGSTOP) != 0 || wait_ptrace_stop_deadline(child, &status, deadline) != 0 ||
        !WIFSTOPPED(status) || WSTOPSIG(status) != SIGSTOP) {
        snprintf(reason, sizeof(reason), "stop2_failed_0x%x", status);
        goto fail_pos;
    }

    gi.iov_len = sizeof(gpr);
    if (ptrace(PTRACE_GETREGSET, child, (void *) (uintptr_t) NT_PRSTATUS, &gi) != 0 ||
        gi.iov_len != sizeof(gpr) || (uintptr_t) gpr.pc < (uintptr_t) isa_probe_spin_loop ||
        (uintptr_t) gpr.pc >= (uintptr_t) isa_probe_spin_end) {
        snprintf(reason, sizeof(reason), "stop2_gpr_pc_0x%lx", gpr.pc);
        goto fail_pos;
    }
    struct iovec vi2 = {.iov_base = vec_buf, .iov_len = want_bytes};
    memset(vec_buf, 0, want_bytes);
    if (ptrace(PTRACE_GETREGSET, child, (void *) (uintptr_t) NT_RISCV_VECTOR, &vi2) != 0) {
        snprintf(reason, sizeof(reason), "stop2_vregset_errno_%d", errno);
        goto fail_pos;
    }
    char diff[128] = "";
    if (!compare_regset_bytes(vec_buf, vi2.iov_len, &expected, vlenb, diff, sizeof(diff))) {
        snprintf(reason, sizeof(reason), "stop2_mismatch_%s", diff);
        goto fail_pos;
    }

    /* Write a distinct register state via PTRACE_SETREGSET and verify readback. */
    encode_regset_bytes(set_buf, &written, vlenb);
    struct iovec vi_set = {.iov_base = set_buf, .iov_len = want_bytes};
    if (ptrace(PTRACE_SETREGSET, child, (void *) (uintptr_t) NT_RISCV_VECTOR, &vi_set) != 0 ||
        vi_set.iov_len != want_bytes) {
        snprintf(reason, sizeof(reason), "stop2_setregset_errno_%d_len_%zu", errno, vi_set.iov_len);
        goto fail_pos;
    }
    struct iovec vi_rb = {.iov_base = vec_buf, .iov_len = want_bytes};
    memset(vec_buf, 0, want_bytes);
    if (ptrace(PTRACE_GETREGSET, child, (void *) (uintptr_t) NT_RISCV_VECTOR, &vi_rb) != 0) {
        snprintf(reason, sizeof(reason), "stop2_readback_errno_%d", errno);
        goto fail_pos;
    }
    if (!compare_regset_bytes(vec_buf, vi_rb.iov_len, &written, vlenb, diff, sizeof(diff))) {
        snprintf(reason, sizeof(reason), "stop2_set_readback_mismatch_%s", diff);
        goto fail_pos;
    }

    /* Resume with signal 0; tracee verifies it reads written state, then stops for Stop 3. */
    __atomic_store_n(&shm->stop, 1U, __ATOMIC_RELEASE);
    if (ptrace(PTRACE_CONT, child, NULL, NULL) != 0) {
        snprintf(reason, sizeof(reason), "cont2_failed");
        goto fail_pos;
    }
    probe_progress(run_id, "ptrace", "stop2_done");

    while (__atomic_load_n(&shm->ready2, __ATOMIC_ACQUIRE) == 0U) {
        if (waitpid(child, &status, WNOHANG) == child) {
            snprintf(
                reason, sizeof(reason), "tracee_setregset_check_failed_0x%x_%s", status, shm->diff);
            goto fail_pos;
        }
        if (mono_ms() >= deadline) {
            snprintf(reason, sizeof(reason), "stop3_ready_timeout");
            goto fail_pos;
        }
        sleep_ms(2);
    }
    if (kill(child, SIGSTOP) != 0 || wait_ptrace_stop_deadline(child, &status, deadline) != 0 ||
        !WIFSTOPPED(status) || WSTOPSIG(status) != SIGSTOP) {
        snprintf(reason, sizeof(reason), "stop3_failed_0x%x", status);
        goto fail_pos;
    }
    struct iovec vi3 = {.iov_base = vec_buf, .iov_len = want_bytes};
    memset(vec_buf, 0, want_bytes);
    if (ptrace(PTRACE_GETREGSET, child, (void *) (uintptr_t) NT_RISCV_VECTOR, &vi3) != 0) {
        snprintf(reason, sizeof(reason), "stop3_vregset_errno_%d", errno);
        goto fail_pos;
    }
    if (!compare_regset_bytes(vec_buf, vi3.iov_len, &written, vlenb, diff, sizeof(diff))) {
        snprintf(reason, sizeof(reason), "stop3_readback_mismatch_%s", diff);
        goto fail_pos;
    }
    probe_progress(run_id, "ptrace", "stop3_done");

    __atomic_store_n(&shm->stop2, 1U, __ATOMIC_RELEASE);
    if (ptrace(PTRACE_CONT, child, NULL, NULL) != 0 ||
        wait_child_deadline(child, &status, deadline) != 0 || !WIFEXITED(status) ||
        WEXITSTATUS(status) != 0 || shm->setregset_seen != 1 || shm->resumed_ok != 1) {
        snprintf(reason, sizeof(reason), "resume_failed_0x%x_%s", status, shm->diff);
        goto fail_pos;
    }

    munmap(shm, align_page_size(sizeof(*shm)));
    probe_progress(run_id, "ptrace", "done");
    printf("%s id=%s case=ptrace kernel=%s inactive_errno=%d\n",
           TOKEN_INFO,
           run_id,
           krel,
           want_inactive_errno);
    printf("%s id=%s case=ptrace verdict=PASS inactive_einval=1 active_bytes=%zu setregset_ok=1 "
           "resumed_ok=1\n",
           TOKEN_PREFIX,
           run_id,
           vi2.iov_len);
    return 0;

fail_pos:
    kill(child, SIGKILL);
    waitpid(child, &status, 0);
    munmap(shm, align_page_size(sizeof(*shm)));
    probe_progress(run_id, "ptrace", "done");
    printf("%s id=%s case=ptrace verdict=FAIL reason=%s\n", TOKEN_PREFIX, run_id, reason);
    return 1;
}

/* --- Case 6 (Positive): ELF core note visibility --- */

struct core_shm {
    volatile uint32_t ready;
    volatile uint32_t stop;
};

static bool configure_core_child_limits(void)
{
    if (prctl(PR_SET_DUMPABLE, 1) != 0)
        return false;
    (void) write_file_all("/proc/self/coredump_filter", O_WRONLY | O_TRUNC, "0\n", 2);

    struct rlimit rl;
    if (getrlimit(RLIMIT_CORE, &rl) == 0) {
        rl.rlim_cur = (rl.rlim_max == RLIM_INFINITY || rl.rlim_max > 16U * 1024U * 1024U)
                          ? (16U * 1024U * 1024U)
                          : rl.rlim_max;
        if (rl.rlim_cur == 0)
            rl.rlim_cur = RLIM_INFINITY;
        (void) setrlimit(RLIMIT_CORE, &rl);
    }
    if (getrlimit(RLIMIT_FSIZE, &rl) == 0 && rl.rlim_cur < 4U * 1024U * 1024U) {
        rl.rlim_cur = rl.rlim_max;
        (void) setrlimit(RLIMIT_FSIZE, &rl);
    }
    sigset_t set;
    sigemptyset(&set);
    sigaddset(&set, SIGQUIT);
    sigprocmask(SIG_UNBLOCK, &set, NULL);
    signal(SIGQUIT, SIG_DFL);
    return true;
}

static bool run_core_trial(const char *dir_path,
                           bool live_ext,
                           const struct ext_reg_state *expected,
                           uint64_t vlenb,
                           struct core_parse_result *parsed_out,
                           char *file_sha256,
                           char *reason,
                           size_t reason_sz)
{
    struct core_shm *shm = alloc_shared_mem(sizeof(*shm), NULL);
    if (shm == MAP_FAILED) {
        snprintf(reason, reason_sz, "shm_alloc_failed");
        return false;
    }

    pid_t child = fork();
    if (child < 0) {
        munmap(shm, align_page_size(sizeof(*shm)));
        snprintf(reason, reason_sz, "fork_failed");
        return false;
    }
    if (child == 0) {
        if (!configure_core_child_limits())
            _exit(60);
        if (live_ext) {
            if (prctl(PR_RISCV_V_SET_CONTROL, PR_RISCV_V_VSTATE_CTRL_ON) < 0)
                _exit(61);
            struct ext_reg_state *st = mmap(NULL,
                                            align_page_size(sizeof(*st)),
                                            PROT_READ | PROT_WRITE,
                                            MAP_PRIVATE | MAP_ANONYMOUS,
                                            -1,
                                            0);
            if (st == MAP_FAILED)
                _exit(62);
            memcpy(st, expected, sizeof(*st));
            /* Live window: zero syscalls before fatal SIGQUIT. */
            isa_probe_load_state(st);
            isa_probe_spin_until_flag(&shm->ready, &shm->stop);
        } else {
            isa_probe_spin_until_flag(&shm->ready, &shm->stop);
        }
        _exit(63);
    }

    uint64_t deadline = mono_ms() + 15000ULL;
    int status = 0;
    while (__atomic_load_n(&shm->ready, __ATOMIC_ACQUIRE) == 0U) {
        if (waitpid(child, &status, WNOHANG) == child) {
            munmap(shm, align_page_size(sizeof(*shm)));
            snprintf(reason, reason_sz, "child_exited_before_ready_0x%x", status);
            return false;
        }
        if (mono_ms() >= deadline) {
            kill(child, SIGKILL);
            waitpid(child, &status, 0);
            munmap(shm, align_page_size(sizeof(*shm)));
            snprintf(reason, reason_sz, "ready_timeout");
            return false;
        }
        sleep_ms(2);
    }

    kill(child, SIGQUIT);
    if (wait_child_deadline(child, &status, deadline) != 0) {
        munmap(shm, align_page_size(sizeof(*shm)));
        snprintf(reason, reason_sz, "wait_timeout");
        return false;
    }
    munmap(shm, align_page_size(sizeof(*shm)));

    if (!WIFSIGNALED(status) || WTERMSIG(status) != SIGQUIT || !WCOREDUMP(status)) {
        snprintf(reason, reason_sz, "no_coredump_status_0x%x", status);
        return false;
    }

    char core_path[PATH_MAX];
    snprintf(core_path, sizeof(core_path), "%s/core.%ld", dir_path, (long) child);
    struct stat st;
    if (stat(core_path, &st) != 0 || st.st_size <= 0 || st.st_size > 8 * 1024 * 1024) {
        snprintf(
            reason, reason_sz, "core_file_stat_failed_e_%d_sz_%lld", errno, (long long) st.st_size);
        unlink(core_path);
        return false;
    }

    uint8_t *buf = malloc((size_t) st.st_size);
    if (buf == NULL) {
        unlink(core_path);
        snprintf(reason, reason_sz, "malloc_failed");
        return false;
    }
    ssize_t nread = read_file_bounded(core_path, buf, (size_t) st.st_size);
    unlink(core_path);
    if (nread != st.st_size) {
        free(buf);
        snprintf(reason, reason_sz, "core_read_short");
        return false;
    }

    if (file_sha256 != NULL)
        sha256_hex(buf, (size_t) nread, file_sha256);

    bool ok = parse_elf_core_buf(buf, (size_t) nread, parsed_out);
    if (!ok) {
        snprintf(reason, reason_sz, "elf_parse_%s", parsed_out->error);
    } else if (parsed_out->prstatus_count < 1) {
        snprintf(reason, reason_sz, "missing_prstatus");
        ok = false;
    } else if (parsed_out->bad_owner_vec_notes != 0) {
        snprintf(reason, reason_sz, "bad_note_owner");
        ok = false;
    } else if (!live_ext) {
        if (parsed_out->vec_note_count != 0) {
            snprintf(reason, reason_sz, "unexpected_ext_note_in_scalar_core");
            ok = false;
        }
    } else {
        if (parsed_out->vec_note_count != 1) {
            snprintf(reason, reason_sz, "ext_note_count_%d", parsed_out->vec_note_count);
            ok = false;
        } else {
            char diff[128] = "";
            if (!compare_regset_bytes(parsed_out->vec_desc,
                                      parsed_out->vec_desc_size,
                                      expected,
                                      vlenb,
                                      diff,
                                      sizeof(diff))) {
                snprintf(reason, reason_sz, "note_mismatch_%s", diff);
                ok = false;
            }
        }
    }

    /* Detach pointer into freed buffer; scalar metadata remains valid. */
    parsed_out->vec_desc = NULL;
    free(buf);
    return ok;
}

static int run_core(const char *run_id, const char *opt_dir, uint64_t vlenb)
{
    probe_progress(run_id, "core", "start");
    const char *cp_path = "/proc/sys/kernel/core_pattern";
    char orig_pattern[1024];
    ssize_t orig_len = read_file_bounded(cp_path, orig_pattern, sizeof(orig_pattern) - 1);
    if (orig_len <= 0) {
        printf("%s id=%s case=core verdict=FAIL reason=read_core_pattern_failed\n",
               TOKEN_PREFIX,
               run_id);
        return 1;
    }
    orig_pattern[orig_len] = '\0';

    char work_dir[PATH_MAX];
    bool created_dir = false;
    if (opt_dir != NULL && opt_dir[0] != '\0') {
        snprintf(work_dir, sizeof(work_dir), "%s", opt_dir);
        if (mkdir(work_dir, 0700) == 0)
            created_dir = true;
    } else {
        snprintf(work_dir, sizeof(work_dir), "/dev/shm/frost_isa_core_XXXXXX");
        if (mkdtemp(work_dir) == NULL) {
            printf("%s id=%s case=core verdict=FAIL reason=mkdtemp_failed\n", TOKEN_PREFIX, run_id);
            return 1;
        }
        created_dir = true;
    }

    char new_pattern[PATH_MAX + 16];
    snprintf(new_pattern, sizeof(new_pattern), "%s/core.%%p\n", work_dir);
    if (write_file_all(cp_path, O_WRONLY | O_TRUNC, new_pattern, strlen(new_pattern)) != 0) {
        if (created_dir)
            rmdir(work_dir);
        printf("%s id=%s case=core verdict=FAIL reason=write_core_pattern_errno_%d\n",
               TOKEN_PREFIX,
               run_id,
               errno);
        return 1;
    }

    struct ext_reg_state expected;
    fill_pattern(&expected, 0xc3, vlenb, 1);

    struct core_parse_result scalar_res, live_res;
    char scalar_sha[65] = "", live_sha[65] = "";
    char reason[192] = "";
    bool ok = false;

    probe_progress(run_id, "core", "scalar_trial");
    if (!run_core_trial(
            work_dir, false, &expected, vlenb, &scalar_res, scalar_sha, reason, sizeof(reason))) {
        char tmp[192];
        snprintf(tmp, sizeof(tmp), "scalar_%.176s", reason);
        snprintf(reason, sizeof(reason), "%s", tmp);
    } else {
        probe_progress(run_id, "core", "live_trial");
        if (!run_core_trial(
                work_dir, true, &expected, vlenb, &live_res, live_sha, reason, sizeof(reason))) {
            char tmp[192];
            snprintf(tmp, sizeof(tmp), "live_%.176s", reason);
            snprintf(reason, sizeof(reason), "%s", tmp);
        } else {
            ok = true;
        }
    }

    probe_progress(run_id, "core", "restore");
    int restore_ok = 0;
    if (write_file_all(cp_path, O_WRONLY | O_TRUNC, orig_pattern, (size_t) orig_len) == 0) {
        char check_buf[1024];
        ssize_t clen = read_file_bounded(cp_path, check_buf, sizeof(check_buf) - 1);
        if (clen == orig_len && memcmp(check_buf, orig_pattern, (size_t) orig_len) == 0)
            restore_ok = 1;
    }
    if (created_dir)
        (void) rmdir(work_dir);
    probe_progress(run_id, "core", "done");

    if (ok && restore_ok) {
        printf("%s id=%s case=core scalar_prstatus=%d live_prstatus=%d note_bytes=%zu "
               "note_sha256=%s file_sha256=%s\n",
               TOKEN_INFO,
               run_id,
               scalar_res.prstatus_count,
               live_res.prstatus_count,
               live_res.vec_desc_size,
               live_res.vec_sha256,
               live_sha);
        printf("%s id=%s case=core verdict=PASS scalar_ok=1 note_bytes=%zu restored=1\n",
               TOKEN_PREFIX,
               run_id,
               live_res.vec_desc_size);
        return 0;
    }

    if (ok && !restore_ok)
        snprintf(reason, sizeof(reason), "core_pattern_restore_failed");
    printf("%s id=%s case=core verdict=FAIL reason=%s restored=%d\n",
           TOKEN_PREFIX,
           run_id,
           reason,
           restore_ok);
    return 1;
}

/* --- Case 7 (Positive): fork policy inheritance and parent/child state isolation --- */

struct fork_shm {
    volatile uint32_t child_ready;
    volatile uint32_t parent_live;
    volatile uint32_t child_exited;
    volatile pid_t child_pid_pub;
    pid_t parent_pid;
    pid_t child_pid;
    int child_ctrl;
    int child_init_zero;
    int child_pat_ok;
    int parent_intact;
    char diff[128];
};

static bool pid_is_zombie(pid_t pid)
{
    char path[64];
    snprintf(path, sizeof(path), "/proc/%ld/stat", (long) pid);
    char buf[512];
    ssize_t n = read_file_bounded(path, buf, sizeof(buf) - 1);
    if (n <= 0)
        return false;
    buf[n] = '\0';
    char *rparen = strrchr(buf, ')');
    return rparen != NULL && rparen[1] == ' ' && rparen[2] == 'Z';
}

static int run_fork_case(const char *run_id, int cpu, uint64_t vlenb)
{
    probe_progress(run_id, "fork", "start");
    char krel[65] = "";
    int want_inactive_errno = expected_inactive_vreg_errno(krel, sizeof(krel));
    if (want_inactive_errno < 0) {
        printf("%s id=%s case=fork verdict=FAIL reason=uname_parse_failed_%s\n",
               TOKEN_PREFIX,
               run_id,
               krel);
        return 1;
    }
    struct fork_shm *shm = alloc_shared_mem(sizeof(*shm), NULL);
    if (shm == MAP_FAILED) {
        printf("%s id=%s case=fork verdict=FAIL reason=shm_alloc_failed\n", TOKEN_PREFIX, run_id);
        return 1;
    }

    /* Run inside a dedicated launcher child so main process policy stays untouched. */
    pid_t launcher = fork();
    if (launcher < 0) {
        munmap(shm, align_page_size(sizeof(*shm)));
        printf(
            "%s id=%s case=fork verdict=FAIL reason=launcher_fork_failed\n", TOKEN_PREFIX, run_id);
        return 1;
    }
    if (launcher == 0) {
        if (!pin_to_cpu(cpu))
            _exit(69);
        int wanted_ctrl = PR_RISCV_V_VSTATE_CTRL_ON | (PR_RISCV_V_VSTATE_CTRL_OFF << 2) |
                          PR_RISCV_V_VSTATE_CTRL_INHERIT;
        if (prctl(PR_RISCV_V_SET_CONTROL, wanted_ctrl) < 0)
            _exit(70);
        if (prctl(PR_RISCV_V_GET_CONTROL) != wanted_ctrl)
            _exit(71);

        struct ext_reg_state *bufs = mmap(NULL,
                                          align_page_size(sizeof(*bufs) * 3),
                                          PROT_READ | PROT_WRITE,
                                          MAP_PRIVATE | MAP_ANONYMOUS,
                                          -1,
                                          0);
        if (bufs == MAP_FAILED)
            _exit(72);
        memset(bufs, 0, sizeof(*bufs) * 3);
        struct ext_reg_state *pat_parent = bufs + 0;
        struct ext_reg_state *got = bufs + 1;
        struct ext_reg_state *pat_child = bufs + 2;

        fill_pattern(pat_parent, 0x55, vlenb, 0);
        isa_probe_load_state(pat_parent);
        isa_probe_dump_state(got);
        if (!compare_state(got, pat_parent, vlenb, shm->diff, sizeof(shm->diff)))
            _exit(73);

        /* Re-arm dirty parent state right before calling fork(). */
        isa_probe_load_state(pat_parent);
        shm->parent_pid = getpid();
        pid_t child = fork();
        if (child < 0)
            _exit(74);
        if (child == 0) {
            shm->child_pid = getpid();
            shm->child_ctrl = prctl(PR_RISCV_V_GET_CONTROL);
            (void) prctl(PR_SET_DUMPABLE, 1);
            if (ptrace(PTRACE_TRACEME, 0, NULL, NULL) != 0)
                _exit(75);
            raise(SIGSTOP);

            /* First extended use in child: snapshot initial state immediately. */
            uint64_t vl = isa_probe_first_use_vsetvli();
            if (vl != vlenb / 2U)
                _exit(76);
            isa_probe_dump_state(got);
            if (!check_zero_vregs(got, vlenb, shm->diff, sizeof(shm->diff)))
                _exit(77);
            shm->child_init_zero = 1;

            /* Prepare child's own distinct pattern and wait until parent holds 0x55 live. */
            fill_pattern(pat_child, 0xaa, vlenb, 1);
            __atomic_store_n(&shm->child_ready, 1U, __ATOMIC_RELEASE);
            uint64_t c_deadline = mono_ms() + 15000ULL;
            while (__atomic_load_n(&shm->parent_live, __ATOMIC_ACQUIRE) == 0U) {
                if (mono_ms() >= c_deadline)
                    _exit(78);
            }

            /* Load and verify child's 0xaa pattern on the same hart, then exit with it live. */
            isa_probe_load_state(pat_child);
            isa_probe_dump_state(got);
            if (!compare_state(got, pat_child, vlenb, shm->diff, sizeof(shm->diff)))
                _exit(78);
            isa_probe_load_state(pat_child);
            shm->child_pat_ok = 1;
            _exit(0);
        }

        /* Parent inspects child's never-used regset before child touches extended state. */
        uint64_t deadline = mono_ms() + 15000ULL;
        int st = 0;
        if (wait_ptrace_stop_deadline(child, &st, deadline) != 0 || !WIFSTOPPED(st) ||
            WSTOPSIG(st) != SIGSTOP) {
            kill(child, SIGKILL);
            waitpid(child, &st, 0);
            _exit(79);
        }
        struct user_regs_struct gpr;
        struct iovec gi = {.iov_base = &gpr, .iov_len = sizeof(gpr)};
        if (ptrace(PTRACE_GETREGSET, child, (void *) (uintptr_t) NT_PRSTATUS, &gi) != 0) {
            kill(child, SIGKILL);
            waitpid(child, &st, 0);
            _exit(80);
        }
        uint8_t vec_buf[REGSET_HDR_BYTES + MAX_PROBE_VSIZE];
        struct iovec vi = {.iov_base = vec_buf,
                           .iov_len = REGSET_HDR_BYTES + (size_t) (32U * vlenb)};
        errno = 0;
        /* Inactive V regset returns EINVAL (< 7.0) or ENODATA (>= 7.0; commit 8cdb04bd06c1). */
        if (ptrace(PTRACE_GETREGSET, child, (void *) (uintptr_t) NT_RISCV_VECTOR, &vi) == 0 ||
            errno != want_inactive_errno) {
            snprintf(
                shm->diff, sizeof(shm->diff), "vreg_want_%d_got_%d", want_inactive_errno, errno);
            kill(child, SIGKILL);
            waitpid(child, &st, 0);
            _exit(81);
        }
        if (ptrace(PTRACE_DETACH, child, NULL, NULL) != 0) {
            kill(child, SIGKILL);
            waitpid(child, &st, 0);
            _exit(82);
        }

        /* Wait until child finishes its zero-init check before entering the syscall-free window. */
        while (__atomic_load_n(&shm->child_ready, __ATOMIC_ACQUIRE) == 0U) {
            if (waitpid(child, &st, WNOHANG) == child)
                _exit(82);
            if (mono_ms() >= deadline) {
                kill(child, SIGKILL);
                waitpid(child, &st, 0);
                _exit(82);
            }
            sleep_ms(2);
        }

        /*
         * Reload parent's pre-fork 0x55 pattern (RISC-V Linux syscall entry discards
         * caller-saved extended registers during fork/ptrace), then hold it live with
         * zero syscalls while child runs its 0xaa pattern and exits completely.
         * Grandparent marks child_exited once child reaches zombie state 'Z'.
         */
        __atomic_store_n(&shm->child_pid_pub, child, __ATOMIC_RELEASE);
        isa_probe_load_state(pat_parent);
        isa_probe_spin_until_flag(&shm->parent_live, &shm->child_exited);

        /* Immediately after child exits, verify parent's own 0x55 state before writing anything. */
        isa_probe_dump_state(got);
        bool intact = compare_state(got, pat_parent, vlenb, shm->diff, sizeof(shm->diff));

        if (wait_child_deadline(child, &st, deadline) != 0 || !WIFEXITED(st) ||
            WEXITSTATUS(st) != 0) {
            kill(child, SIGKILL);
            waitpid(child, &st, 0);
            _exit(82);
        }
        if (shm->child_pid == 0 || shm->child_pid == shm->parent_pid ||
            shm->child_ctrl != wanted_ctrl)
            _exit(83);
        if (!intact)
            _exit(84);
        shm->parent_intact = 1;
        _exit(0);
    }

    probe_progress(run_id, "fork", "launcher_spawned");
    uint64_t deadline = mono_ms() + 18000ULL;
    int status = 0;
    int wr = -1;
    for (;;) {
        pid_t r = waitpid(launcher, &status, WNOHANG);
        if (r == launcher) {
            wr = 0;
            break;
        }
        pid_t cpid = __atomic_load_n(&shm->child_pid_pub, __ATOMIC_ACQUIRE);
        if (cpid > 0 && __atomic_load_n(&shm->child_exited, __ATOMIC_ACQUIRE) == 0U &&
            pid_is_zombie(cpid)) {
            probe_progress(run_id, "fork", "child_exited");
            __atomic_store_n(&shm->child_exited, 1U, __ATOMIC_RELEASE);
        }
        if (mono_ms() >= deadline) {
            __atomic_store_n(&shm->child_exited, 1U, __ATOMIC_RELEASE);
            if (cpid > 0)
                kill(cpid, SIGKILL);
            kill(launcher, SIGKILL);
            while (waitpid(launcher, &status, 0) < 0 && errno == EINTR) {
            }
            wr = -1;
            break;
        }
        sleep_ms(2);
    }

    probe_progress(run_id, "fork", "done");
    bool ok = (wr == 0 && WIFEXITED(status) && WEXITSTATUS(status) == 0 &&
               shm->child_init_zero == 1 && shm->child_pat_ok == 1 && shm->parent_intact == 1);
    if (ok) {
        printf("%s id=%s case=fork parent_pid=%ld child_pid=%ld child_ctrl=0x%x kernel=%s "
               "inactive_errno=%d\n",
               TOKEN_INFO,
               run_id,
               (long) shm->parent_pid,
               (long) shm->child_pid,
               shm->child_ctrl,
               krel,
               want_inactive_errno);
        printf("%s id=%s case=fork verdict=PASS ctrl_ok=1 inactive_einval=1 init_zero=1 "
               "isolated=1\n",
               TOKEN_PREFIX,
               run_id);
    } else {
        printf("%s id=%s case=fork verdict=FAIL reason=status_0x%x_wr_%d_diff_%s\n",
               TOKEN_PREFIX,
               run_id,
               status,
               wr,
               shm->diff);
    }
    munmap(shm, align_page_size(sizeof(*shm)));
    return ok ? 0 : 1;
}

/* --- Case 8 (Positive) and Stock Case 2: SIGILL helper + exec --- */

static sigjmp_buf g_sigill_jmp;
static volatile sig_atomic_t g_sigill_got;
static volatile int g_sigill_code;
static volatile uintptr_t g_sigill_addr;
static volatile uintptr_t g_sigill_pc;

static void sigill_handler(int sig, siginfo_t *si, void *uctx)
{
    (void) sig;
    g_sigill_got = 1;
    g_sigill_code = (si != NULL) ? si->si_code : -1;
    g_sigill_addr = (si != NULL) ? (uintptr_t) si->si_addr : 0;
    if (uctx != NULL) {
        const ucontext_t *uc = (const ucontext_t *) uctx;
        const struct user_regs_struct *regs = (const struct user_regs_struct *) &uc->uc_mcontext;
        g_sigill_pc = (uintptr_t) regs->pc;
    }
    siglongjmp(g_sigill_jmp, 1);
}

static bool probe_expected_sigill(
    int *scalar_pre_out, int *sigill_out, int *pc_match_out, char *reason, size_t reason_sz)
{
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = sigill_handler;
    sa.sa_flags = SA_SIGINFO;
    sigemptyset(&sa.sa_mask);
    if (sigaction(SIGILL, &sa, NULL) != 0) {
        snprintf(reason, reason_sz, "sigaction_errno_%d", errno);
        return false;
    }

    volatile int scalar_pre = 0;
    g_sigill_got = 0;
    g_sigill_code = 0;
    g_sigill_addr = 0;
    g_sigill_pc = 0;

    if (sigsetjmp(g_sigill_jmp, 1) == 0) {
        scalar_pre = 1;
        (void) isa_probe_first_use_vsetvli();
        snprintf(reason, reason_sz, "instruction_did_not_trap");
        return false;
    }

    uintptr_t want_pc = (uintptr_t) isa_probe_first_use_insn;
    *scalar_pre_out = scalar_pre;
    *sigill_out = (g_sigill_got == 1 && g_sigill_code == ILL_ILLOPC) ? 1 : 0;
    *pc_match_out = (g_sigill_pc == want_pc && g_sigill_addr == want_pc) ? 1 : 0;

    if (!*scalar_pre_out || !*sigill_out || !*pc_match_out) {
        snprintf(reason,
                 reason_sz,
                 "sigill_mismatch(got=%d,code=%d,pc=0x%lx,addr=0x%lx,want=0x%lx)",
                 (int) g_sigill_got,
                 g_sigill_code,
                 (unsigned long) g_sigill_pc,
                 (unsigned long) g_sigill_addr,
                 (unsigned long) want_pc);
        return false;
    }
    return true;
}

static int run_illegal(const char *run_id)
{
    probe_progress(run_id, "illegal", "start");
    struct ill_shm {
        int scalar_pre;
        int sigill;
        int pc_match;
        char reason[160];
    };
    struct ill_shm *shm = alloc_shared_mem(sizeof(*shm), NULL);
    if (shm == MAP_FAILED) {
        printf(
            "%s id=%s case=illegal verdict=FAIL reason=shm_alloc_failed\n", TOKEN_PREFIX, run_id);
        return 1;
    }

    pid_t child = fork();
    if (child < 0) {
        munmap(shm, align_page_size(sizeof(*shm)));
        printf("%s id=%s case=illegal verdict=FAIL reason=fork_failed\n", TOKEN_PREFIX, run_id);
        return 1;
    }
    if (child == 0) {
        bool ok = probe_expected_sigill(
            &shm->scalar_pre, &shm->sigill, &shm->pc_match, shm->reason, sizeof(shm->reason));
        _exit(ok ? 0 : 1);
    }

    int status = 0;
    int wr = wait_child_deadline(child, &status, mono_ms() + 5000ULL);
    probe_progress(run_id, "illegal", "done");
    bool ok = (wr == 0 && WIFEXITED(status) && WEXITSTATUS(status) == 0 && shm->sigill == 1 &&
               shm->pc_match == 1 && shm->scalar_pre == 1);
    if (ok) {
        printf("%s id=%s case=illegal verdict=PASS sigill=1 pc_match=1 scalar_pre=1\n",
               TOKEN_PREFIX,
               run_id);
    } else {
        printf("%s id=%s case=illegal verdict=FAIL reason=%s_status_0x%x\n",
               TOKEN_PREFIX,
               run_id,
               shm->reason[0] ? shm->reason : "child_failed",
               status);
    }
    munmap(shm, align_page_size(sizeof(*shm)));
    return ok ? 0 : 1;
}

struct exec_shm {
    pid_t pre_pid;
    pid_t post_pid;
    uint64_t cookie_seen;
    int ctrl_seen;
    int init_zero;
    int work_ok;
    int sigill_ok;
    char reason[160];
};

static int
worker_exec_mode(const char *mode, const char *cookie_str, int shm_fd, uint64_t expected_vlenb)
{
    size_t map_sz = align_page_size(sizeof(struct exec_shm));
    struct exec_shm *shm = mmap(NULL, map_sz, PROT_READ | PROT_WRITE, MAP_SHARED, shm_fd, 0);
    if (shm == MAP_FAILED)
        return 90;

    shm->post_pid = getpid();
    shm->cookie_seen = strtoull(cookie_str, NULL, 16);
    shm->ctrl_seen = prctl(PR_RISCV_V_GET_CONTROL);

    if (strcmp(mode, "exec-on") == 0) {
        int cur = shm->ctrl_seen & PR_RISCV_V_VSTATE_CTRL_CUR_MASK;
        int next = (shm->ctrl_seen & PR_RISCV_V_VSTATE_CTRL_NEXT_MASK) >> 2;
        if (shm->ctrl_seen < 0 || cur != PR_RISCV_V_VSTATE_CTRL_ON ||
            next != PR_RISCV_V_VSTATE_CTRL_DEFAULT) {
            snprintf(shm->reason, sizeof(shm->reason), "bad_ctrl_on_0x%x", shm->ctrl_seen);
            return 91;
        }
        /* Scalar stop before first extended use so parent checks inactive regset. */
        raise(SIGSTOP);

        struct ext_reg_state *bufs = mmap(NULL,
                                          align_page_size(sizeof(*bufs) * 2),
                                          PROT_READ | PROT_WRITE,
                                          MAP_PRIVATE | MAP_ANONYMOUS,
                                          -1,
                                          0);
        if (bufs == MAP_FAILED)
            return 92;
        memset(bufs, 0, sizeof(*bufs) * 2);

        if (isa_probe_first_use_vsetvli() != expected_vlenb / 2U) {
            snprintf(shm->reason, sizeof(shm->reason), "first_use_vl_wrong");
            return 93;
        }
        isa_probe_dump_state(bufs + 1);
        if (!check_zero_vregs(bufs + 1, expected_vlenb, shm->reason, sizeof(shm->reason)))
            return 94;
        shm->init_zero = 1;

        fill_pattern(bufs, 0x99, expected_vlenb, 1);
        isa_probe_load_state(bufs);
        isa_probe_dump_state(bufs + 1);
        if (!compare_state(bufs + 1, bufs, expected_vlenb, shm->reason, sizeof(shm->reason)))
            return 95;
        shm->work_ok = 1;
        return 0;
    }

    if (strcmp(mode, "exec-off") == 0) {
        int cur = shm->ctrl_seen & PR_RISCV_V_VSTATE_CTRL_CUR_MASK;
        int next = (shm->ctrl_seen & PR_RISCV_V_VSTATE_CTRL_NEXT_MASK) >> 2;
        if (shm->ctrl_seen < 0 || cur != PR_RISCV_V_VSTATE_CTRL_OFF ||
            next != PR_RISCV_V_VSTATE_CTRL_DEFAULT) {
            snprintf(shm->reason, sizeof(shm->reason), "bad_ctrl_off_0x%x", shm->ctrl_seen);
            return 96;
        }
        int sp = 0, si = 0, pm = 0;
        if (!probe_expected_sigill(&sp, &si, &pm, shm->reason, sizeof(shm->reason)))
            return 97;
        shm->sigill_ok = 1;
        return 0;
    }

    return 98;
}

static bool run_exec_trial(bool next_on, uint64_t cookie, uint64_t vlenb, char *reason, size_t rsz)
{
    int shm_fd = -1;
    struct exec_shm *shm = alloc_shared_mem(sizeof(*shm), &shm_fd);
    if (shm == MAP_FAILED) {
        snprintf(reason, rsz, "shm_alloc_failed");
        return false;
    }

    pid_t child = fork();
    if (child < 0) {
        close(shm_fd);
        munmap(shm, align_page_size(sizeof(*shm)));
        snprintf(reason, rsz, "fork_failed");
        return false;
    }
    if (child == 0) {
        int ctrl_req = PR_RISCV_V_VSTATE_CTRL_ON |
                       ((next_on ? PR_RISCV_V_VSTATE_CTRL_ON : PR_RISCV_V_VSTATE_CTRL_OFF) << 2);
        if (prctl(PR_RISCV_V_SET_CONTROL, ctrl_req) < 0)
            _exit(85);
        struct ext_reg_state *bufs = mmap(NULL,
                                          align_page_size(sizeof(*bufs) * 2),
                                          PROT_READ | PROT_WRITE,
                                          MAP_PRIVATE | MAP_ANONYMOUS,
                                          -1,
                                          0);
        if (bufs == MAP_FAILED)
            _exit(86);
        memset(bufs, 0, sizeof(*bufs) * 2);
        fill_pattern(bufs, 0x42, vlenb, 0);
        isa_probe_load_state(bufs);
        isa_probe_dump_state(bufs + 1);
        if (!compare_state(bufs + 1, bufs, vlenb, shm->reason, sizeof(shm->reason)))
            _exit(87);
        isa_probe_load_state(bufs);

        shm->pre_pid = getpid();
        if (next_on) {
            (void) prctl(PR_SET_DUMPABLE, 1);
            if (ptrace(PTRACE_TRACEME, 0, NULL, NULL) != 0)
                _exit(88);
        }
        char cookie_arg[32], fd_arg[32], vlenb_arg[32];
        snprintf(cookie_arg, sizeof(cookie_arg), "%llx", (unsigned long long) cookie);
        snprintf(fd_arg, sizeof(fd_arg), "%d", shm_fd);
        snprintf(vlenb_arg, sizeof(vlenb_arg), "%llu", (unsigned long long) vlenb);
        char *argv_exec[] = {"frost_isa_probe",
                             "--worker",
                             next_on ? "exec-on" : "exec-off",
                             cookie_arg,
                             fd_arg,
                             vlenb_arg,
                             NULL};
        execv("/proc/self/exe", argv_exec);
        _exit(127);
    }

    uint64_t deadline = mono_ms() + 15000ULL;
    int status = 0;
    bool ok = false;

    if (next_on) {
        char krel[65] = "";
        int want_inactive_errno = expected_inactive_vreg_errno(krel, sizeof(krel));
        if (want_inactive_errno < 0) {
            snprintf(reason, rsz, "exec_on_uname_parse_failed_%s", krel);
            goto fail;
        }
        /* Stop 1: SIGTRAP on execve completion -> inactive V regset (8cdb04bd06c1: ENODATA on
         * >= 7.0). */
        if (wait_ptrace_stop_deadline(child, &status, deadline) != 0 || !WIFSTOPPED(status) ||
            WSTOPSIG(status) != SIGTRAP) {
            snprintf(reason, rsz, "exec_on_trap_failed_0x%x", status);
            goto fail;
        }
        uint8_t vec_buf[REGSET_HDR_BYTES + MAX_PROBE_VSIZE];
        struct iovec vi = {.iov_base = vec_buf,
                           .iov_len = REGSET_HDR_BYTES + (size_t) (32U * vlenb)};
        errno = 0;
        if (ptrace(PTRACE_GETREGSET, child, (void *) (uintptr_t) NT_RISCV_VECTOR, &vi) == 0 ||
            errno != want_inactive_errno) {
            snprintf(reason, rsz, "exec_on_trap_vreg_want_%d_got_%d", want_inactive_errno, errno);
            goto fail;
        }
        if (ptrace(PTRACE_CONT, child, NULL, NULL) != 0) {
            snprintf(reason, rsz, "exec_on_cont1_failed");
            goto fail;
        }
        /* Stop 2: SIGSTOP right before first extended use -> inactive V regset errno. */
        if (wait_ptrace_stop_deadline(child, &status, deadline) != 0 || !WIFSTOPPED(status) ||
            WSTOPSIG(status) != SIGSTOP) {
            snprintf(reason, rsz, "exec_on_stop2_failed_0x%x_%s", status, shm->reason);
            goto fail;
        }
        vi.iov_len = REGSET_HDR_BYTES + (size_t) (32U * vlenb);
        errno = 0;
        if (ptrace(PTRACE_GETREGSET, child, (void *) (uintptr_t) NT_RISCV_VECTOR, &vi) == 0 ||
            errno != want_inactive_errno) {
            snprintf(reason, rsz, "exec_on_stop2_vreg_want_%d_got_%d", want_inactive_errno, errno);
            goto fail;
        }
        if (ptrace(PTRACE_CONT, child, NULL, NULL) != 0) {
            snprintf(reason, rsz, "exec_on_cont2_failed");
            goto fail;
        }
    }

    if (wait_child_deadline(child, &status, deadline) != 0) {
        snprintf(reason, rsz, "exec_timeout");
        goto done;
    }
    child = -1;
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        snprintf(reason, rsz, "exec_status_0x%x_%s", status, shm->reason);
        goto done;
    }
    if (shm->pre_pid != shm->post_pid || shm->cookie_seen != cookie) {
        snprintf(reason, rsz, "exec_pid_or_cookie_mismatch");
        goto done;
    }
    if (next_on && (shm->init_zero != 1 || shm->work_ok != 1)) {
        snprintf(reason, rsz, "exec_on_incomplete");
        goto done;
    }
    if (!next_on && shm->sigill_ok != 1) {
        snprintf(reason, rsz, "exec_off_no_sigill");
        goto done;
    }
    ok = true;
    goto done;

fail:
    if (child > 0) {
        kill(child, SIGKILL);
        waitpid(child, &status, 0);
    }
done:
    close(shm_fd);
    munmap(shm, align_page_size(sizeof(*shm)));
    return ok;
}

static int run_exec_case(const char *run_id, uint64_t vlenb)
{
    char reason[192] = "";
    probe_progress(run_id, "exec", "start");
    probe_progress(run_id, "exec", "exec_on_start");
    if (!run_exec_trial(true, 0x51a7c001ULL, vlenb, reason, sizeof(reason))) {
        probe_progress(run_id, "exec", "done");
        printf("%s id=%s case=exec verdict=FAIL reason=on_%s\n", TOKEN_PREFIX, run_id, reason);
        return 1;
    }
    probe_progress(run_id, "exec", "exec_off_start");
    if (!run_exec_trial(false, 0x51a7c002ULL, vlenb, reason, sizeof(reason))) {
        probe_progress(run_id, "exec", "done");
        printf("%s id=%s case=exec verdict=FAIL reason=off_%s\n", TOKEN_PREFIX, run_id, reason);
        return 1;
    }
    probe_progress(run_id, "exec", "done");
    printf("%s id=%s case=exec verdict=PASS on_ok=1 off_sigill=1\n", TOKEN_PREFIX, run_id);
    return 0;
}

/* --- Full suite driver --- */

static int run_suite(const char *run_id,
                     enum expect_mode expect,
                     uint64_t vlenb,
                     int cpu,
                     int switch_rounds,
                     int sig_rounds,
                     const char *core_dir)
{
    struct discover_info disc = run_discover(run_id, expect, vlenb, cpu);
    if (!disc.ok) {
        const char *mstr = (disc.mode == OBS_PRESENT)  ? "present"
                           : (disc.mode == OBS_ABSENT) ? "absent"
                                                       : "unknown";
        printf("%s id=%s mode=%s passed=0 failed=1 verdict=FAIL\n", TOKEN_SUMMARY, run_id, mstr);
        return 1;
    }

    int passed = 1;
    int failed = 0;

    if (disc.mode == OBS_PRESENT) {
        /* Run every untraced case before tracefs-based first-use. */
        uint64_t active_vlenb = disc.vlenb;
        if (run_switch(run_id, switch_rounds, cpu, active_vlenb) == 0)
            passed++;
        else
            failed++;

        if (run_signal(run_id, true, sig_rounds, "both", active_vlenb) == 0)
            passed++;
        else
            failed++;

        if (run_ptrace(run_id, true, active_vlenb) == 0)
            passed++;
        else
            failed++;

        if (run_core(run_id, core_dir, active_vlenb) == 0)
            passed++;
        else
            failed++;

        if (run_fork_case(run_id, cpu, active_vlenb) == 0)
            passed++;
        else
            failed++;

        if (run_exec_case(run_id, active_vlenb) == 0)
            passed++;
        else
            failed++;

        if (run_first_use(run_id, active_vlenb) == 0)
            passed++;
        else
            failed++;

        printf("%s id=%s mode=present passed=%d failed=%d verdict=%s\n",
               TOKEN_SUMMARY,
               run_id,
               passed,
               failed,
               (failed == 0 && passed == 8) ? "PASS" : "FAIL");
        return (failed == 0 && passed == 8) ? 0 : 1;
    }

    /* Stock / absent matrix: 4 cases. */
    uint64_t absent_vlenb = (vlenb != 0) ? vlenb : 32U;
    if (run_illegal(run_id) == 0)
        passed++;
    else
        failed++;

    if (run_signal(run_id, false, STOCK_SIGNAL_ROUNDS, "normal", absent_vlenb) == 0)
        passed++;
    else
        failed++;

    if (run_ptrace(run_id, false, absent_vlenb) == 0)
        passed++;
    else
        failed++;

    printf("%s id=%s mode=absent passed=%d failed=%d verdict=%s\n",
           TOKEN_SUMMARY,
           run_id,
           passed,
           failed,
           (failed == 0 && passed == 4) ? "PASS" : "FAIL");
    return (failed == 0 && passed == 4) ? 0 : 1;
}

static enum expect_mode parse_expect_arg(const char *s)
{
    if (strcmp(s, "present") == 0)
        return EXPECT_PRESENT;
    if (strcmp(s, "absent") == 0)
        return EXPECT_ABSENT;
    return EXPECT_AUTO;
}

static bool quick_kernel_present(void)
{
    int ctrl = prctl(PR_RISCV_V_GET_CONTROL);
    return ctrl >= 0;
}

static uint64_t probe_hw_vlenb_child(void)
{
    uint64_t *shm = alloc_shared_mem(sizeof(uint64_t), NULL);
    if (shm == MAP_FAILED)
        return 0;
    pid_t pid = fork();
    if (pid < 0) {
        munmap(shm, align_page_size(sizeof(uint64_t)));
        return 0;
    }
    if (pid == 0) {
        if (prctl(PR_RISCV_V_SET_CONTROL, PR_RISCV_V_VSTATE_CTRL_ON) < 0)
            _exit(1);
        (void) isa_probe_first_use_vsetvli();
        *shm = isa_probe_read_vlenb();
        _exit(0);
    }
    int status = 0;
    uint64_t got = 0;
    if (wait_child_deadline(pid, &status, mono_ms() + 5000ULL) == 0 && WIFEXITED(status) &&
        WEXITSTATUS(status) == 0) {
        got = *shm;
    }
    munmap(shm, align_page_size(sizeof(uint64_t)));
    return got;
}

#endif /* __riscv && !FROST_ISA_PROBE_HOST_SELFTEST */

int main(int argc, char **argv)
{
    setvbuf(stdout, NULL, _IONBF, 0);

    if (argc >= 2 && strcmp(argv[1], "--selftest") == 0)
        return run_selftest();

#if defined(__riscv) && !defined(FROST_ISA_PROBE_HOST_SELFTEST)
    g_probe_start_ms = mono_ms();
    if (argc >= 3 && strcmp(argv[1], "--worker") == 0) {
        if (strcmp(argv[2], "first-use") == 0 && argc >= 5)
            return worker_first_use(atoi(argv[3]), strtoull(argv[4], NULL, 0));
        if ((strcmp(argv[2], "exec-on") == 0 || strcmp(argv[2], "exec-off") == 0) && argc >= 6)
            return worker_exec_mode(argv[2], argv[3], atoi(argv[4]), strtoull(argv[5], NULL, 0));
        return 126;
    }

    const char *cmd = (argc >= 2) ? argv[1] : "suite";
    const char *run_id = "0";
    const char *stack_mode = "both";
    const char *core_dir = NULL;
    enum expect_mode expect = EXPECT_AUTO;
    uint64_t vlenb = DEFAULT_VLENB;
    int cpu = 0;
    int rounds = -1;
    int mode_override = -1; /* -1=auto, 0=absent, 1=present */

    for (int i = 2; i < argc; i++) {
        if (strcmp(argv[i], "--run-id") == 0 && i + 1 < argc) {
            run_id = argv[++i];
        } else if (strcmp(argv[i], "--vlenb") == 0 && i + 1 < argc) {
            vlenb = strtoull(argv[++i], NULL, 0);
        } else if (strcmp(argv[i], "--cpu") == 0 && i + 1 < argc) {
            cpu = atoi(argv[++i]);
        } else if (strcmp(argv[i], "--rounds") == 0 && i + 1 < argc) {
            rounds = atoi(argv[++i]);
        } else if (strcmp(argv[i], "--stack") == 0 && i + 1 < argc) {
            stack_mode = argv[++i];
        } else if (strcmp(argv[i], "--dir") == 0 && i + 1 < argc) {
            core_dir = argv[++i];
        } else if (strcmp(argv[i], "--expect") == 0 && i + 1 < argc) {
            expect = parse_expect_arg(argv[++i]);
        } else if (strcmp(argv[i], "--mode") == 0 && i + 1 < argc) {
            const char *m = argv[++i];
            if (strcmp(m, "present") == 0)
                mode_override = 1;
            else if (strcmp(m, "absent") == 0)
                mode_override = 0;
        } else {
            fprintf(stderr, "frost_isa_probe: unknown argument: %s\n", argv[i]);
            return 2;
        }
    }

    if (vlenb != 0 && !is_supported_vlenb(vlenb)) {
        fprintf(stderr,
                "frost_isa_probe: unsupported --vlenb %llu (supported: power of two in [%u, %u])\n",
                (unsigned long long) vlenb,
                MIN_PROBE_VLENB,
                MAX_PROBE_VLENB);
        return 2;
    }

    if (strcmp(cmd, "suite") == 0) {
        return run_suite(run_id,
                         expect,
                         vlenb,
                         cpu,
                         (rounds > 0) ? rounds : DEFAULT_SWITCH_ROUNDS,
                         DEFAULT_SIGNAL_ROUNDS,
                         core_dir);
    }
    if (strcmp(cmd, "discover") == 0)
        return run_discover(run_id, expect, vlenb, cpu).ok ? 0 : 1;
    if (strcmp(cmd, "illegal") == 0)
        return run_illegal(run_id);

    bool present = (mode_override >= 0) ? (mode_override == 1) : quick_kernel_present();
    if (vlenb == 0) {
        if (present) {
            vlenb = probe_hw_vlenb_child();
            if (!is_supported_vlenb(vlenb)) {
                printf("%s id=%s case=%s verdict=FAIL reason=unsupported_vlenb_%llu\n",
                       TOKEN_PREFIX,
                       run_id,
                       cmd,
                       (unsigned long long) vlenb);
                return 1;
            }
        } else {
            vlenb = 32U;
        }
    }

    if (strcmp(cmd, "first-use") == 0)
        return run_first_use(run_id, vlenb);
    if (strcmp(cmd, "switch") == 0)
        return run_switch(run_id, (rounds > 0) ? rounds : DEFAULT_SWITCH_ROUNDS, cpu, vlenb);
    if (strcmp(cmd, "signal") == 0) {
        int r = (rounds > 0) ? rounds : (present ? DEFAULT_SIGNAL_ROUNDS : STOCK_SIGNAL_ROUNDS);
        return run_signal(run_id, present, r, stack_mode, vlenb);
    }
    if (strcmp(cmd, "ptrace") == 0)
        return run_ptrace(run_id, present, vlenb);
    if (strcmp(cmd, "core") == 0)
        return run_core(run_id, core_dir, vlenb);
    if (strcmp(cmd, "fork") == 0)
        return run_fork_case(run_id, cpu, vlenb);
    if (strcmp(cmd, "exec") == 0)
        return run_exec_case(run_id, vlenb);

    fprintf(stderr, "frost_isa_probe: unknown subcommand: %s\n", cmd);
    return 2;
#else
    fprintf(stderr, "frost_isa_probe: built for host selftest only; pass --selftest\n");
    return 2;
#endif
}
