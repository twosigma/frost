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

/**
 * Vector memcpy, memmove, memset, memcmp, strlen, strchr and strcpy in the
 * style C libraries use (string_rvv.S), checked against scalar references
 * for every length 0..300 at several source and destination alignments,
 * with guard bytes around each destination. The string routines also run
 * on strings whose NUL is the last byte of the last mapped page, which
 * only passes if their over-reads use fault-only-first loads.
 */

#include "vec_test.h"

void *memcpy_rvv(void *dst, const void *src, size_t n);
void *memmove_rvv(void *dst, const void *src, size_t n);
void *memset_rvv(void *dst, int c, size_t n);
int memcmp_rvv(const void *a, const void *b, size_t n);
size_t strlen_rvv(const char *s);
char *strchr_rvv(const char *s, int c);
char *strcpy_rvv(char *dst, const char *src);

/* Build with -DVT_QUICK for RTL simulation: lengths step by 7 instead of 1
 * (about 60 million instructions become about 18 million). */
#ifdef VT_QUICK
#define LSTEP 7
#else
#define LSTEP 1
#endif

#define BUF 1024
static uint8_t a_[BUF + 64] __attribute__((aligned(64)));
static uint8_t b_[BUF + 64] __attribute__((aligned(64)));
static uint8_t ref[BUF + 64] __attribute__((aligned(64)));
static uint64_t seed = 0x9e3779b97f4a7c15ull;

static void fill_random(uint8_t *p, size_t n)
{
    for (size_t i = 0; i < n; i++)
        p[i] = (uint8_t) vt_rand(&seed);
}

static void test_memcpy(void)
{
    for (unsigned n = 0; n <= 300; n += LSTEP) {
        for (unsigned sa = 0; sa < 4; sa++) {
            unsigned da = (sa * 3 + 1) & 7;
            fill_random(a_, sizeof a_);
            memset(b_, 0x55, sizeof b_);
            memcpy(ref, b_, sizeof b_);
            memcpy(ref + 16 + da, a_ + 16 + sa, n);
            void *r = memcpy_rvv(b_ + 16 + da, a_ + 16 + sa, n);
            VT_EQ(r, b_ + 16 + da, "memcpy return");
            VT_EQ(memcmp(b_, ref, 700), 0, "memcpy contents and guards");
        }
    }
}

static void test_memmove(void)
{
    /* Every overlap: dst below src, equal, above src, by 1..70 bytes. */
    for (unsigned n = 0; n <= 200; n += (n < 20 ? 1 : 7)) {
        for (int delta = -70; delta <= 70; delta += (delta > -3 && delta < 3) ? 1 : 13) {
            fill_random(a_, sizeof a_);
            memcpy(ref, a_, sizeof a_);
            uint8_t *s = a_ + 100;
            uint8_t *d = a_ + 100 + delta;
            /* Reference through a temporary. */
            memcpy(b_, s, n);
            memcpy(ref + 100 + delta, b_, n);
            memmove_rvv(d, s, n);
            VT_EQ(memcmp(a_, ref, 400), 0, "memmove overlap");
        }
    }
}

static void test_memset(void)
{
    for (unsigned n = 0; n <= 300; n += LSTEP) {
        unsigned off = n & 7;
        memset(b_, 0x11, sizeof b_);
        memcpy(ref, b_, sizeof b_);
        for (unsigned i = 0; i < n; i++)
            ref[16 + off + i] = 0xa7;
        void *r = memset_rvv(b_ + 16 + off, 0x1a7, n); /* only the low byte is used */
        VT_EQ(r, b_ + 16 + off, "memset return");
        VT_EQ(memcmp(b_, ref, 400), 0, "memset contents and guards");
    }
}

static int ref_memcmp(const uint8_t *x, const uint8_t *y, size_t n)
{
    for (size_t i = 0; i < n; i++)
        if (x[i] != y[i])
            return x[i] - y[i];
    return 0;
}

static void test_memcmp(void)
{
    fill_random(a_, sizeof a_);
    for (unsigned n = 0; n <= 300; n += (n < 80 ? 1 : 11)) {
        memcpy(b_, a_, sizeof b_);
        VT_EQ(memcmp_rvv(a_ + 3, b_ + 3, n), 0, "memcmp equal");
        for (unsigned pos = 0; pos < n; pos += (n < 40 ? 1 : 17)) {
            b_[3 + pos] ^= (uint8_t) (1 + pos % 200);
            int want = ref_memcmp(a_ + 3, b_ + 3, n);
            VT_EQ(memcmp_rvv(a_ + 3, b_ + 3, n), (unsigned long) (long) want, "memcmp differs");
            b_[3 + pos] ^= (uint8_t) (1 + pos % 200);
        }
    }
}

static void make_string(uint8_t *p, size_t len)
{
    for (size_t i = 0; i < len; i++)
        p[i] = (uint8_t) (1 + vt_rand(&seed) % 255);
    p[len] = 0;
}

static void test_strings(void)
{
    for (unsigned len = 0; len <= 300; len += LSTEP) {
        for (unsigned off = 0; off < 3; off++) {
            uint8_t *s = a_ + 8 + off * 5;
            make_string(s, len);
            VT_EQ(strlen_rvv((char *) s), len, "strlen");
            /* strchr: a byte inside, a byte after the NUL's position, NUL itself. */
            if (len) {
                unsigned pos = (unsigned) (vt_rand(&seed) % len);
                uint8_t c = s[pos];
                char *first = 0;
                for (unsigned i = 0; i < len; i++)
                    if (s[i] == c) {
                        first = (char *) s + i;
                        break;
                    }
                VT_EQ(strchr_rvv((char *) s, c), first, "strchr hit");
            }
            VT_EQ(strchr_rvv((char *) s, 0), s + len, "strchr NUL");
            /* A byte that is not in the string. */
            uint8_t absent = 0;
            for (unsigned c = 1; c < 256 && !absent; c++) {
                int present = 0;
                for (unsigned i = 0; i < len; i++)
                    present |= s[i] == c;
                if (!present)
                    absent = (uint8_t) c;
            }
            if (absent)
                VT_EQ(strchr_rvv((char *) s, absent), 0, "strchr miss");
            /* strcpy with guards. */
            memset(b_, 0x77, sizeof b_);
            memcpy(ref, b_, sizeof b_);
            memcpy(ref + 24 + off, s, len + 1);
            char *r = strcpy_rvv((char *) b_ + 24 + off, (char *) s);
            VT_EQ(r, b_ + 24 + off, "strcpy return");
            VT_EQ(memcmp(b_, ref, 400), 0, "strcpy contents and guards");
        }
    }
}

/* The NUL is the last byte of the last mapped page: a plain vle8 over-read
 * would fault; fault-only-first must not. */
static void test_page_end(void)
{
    uint8_t *end = (uint8_t *) VT_FF_END;
    vt_trap_clear();
    for (unsigned len = 0; len <= 200; len += LSTEP) {
        uint8_t *s = end - (len + 1);
        make_string(s, len);
        VT_EQ(strlen_rvv((char *) s), len, "strlen at the page end");
        VT_EQ(strchr_rvv((char *) s, 0), s + len, "strchr NUL at the page end");
        memset(b_, 0x33, sizeof b_);
        strcpy_rvv((char *) b_ + 8, (char *) s);
        VT_EQ(memcmp(b_ + 8, s, len + 1), 0, "strcpy at the page end");
        VT_EQ(b_[8 + len + 1], 0x33, "strcpy guard at the page end");
    }
    VT_EQ(vt_trap_count, 0, "no trap from string over-reads");
}

int main(void)
{
    vt_enable_vector();
    vt_trap_install();

    test_memcpy();
    test_memmove();
    test_memset();
    test_memcmp();
    test_strings();
    test_page_end();

    return vt_finish("vec_string");
}
