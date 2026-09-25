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
 * sprintf.c: portable sprintf / snprintf family with no <stdio.h> dependency.
 *
 * Floating-point conversions are exact. They expand |d| into its decimal
 * digits with integer arithmetic and round once, to nearest with ties to even,
 * so every finite double prints as a correctly rounding C library prints it.
 *
 * Supported: %d %i %u %o %x %X %f %F %e %E %g %G %c %s %p %n %%
 * Flags:     - + space 0 #
 * Width / precision: literal or *
 * Length modifiers:  hh h l ll z t
 */

#include <limits.h>
#include <sprintf.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

/* z and t read size_t and ptrdiff_t as each other's unsigned and signed forms. */
_Static_assert(sizeof(size_t) == sizeof(ptrdiff_t), "size_t and ptrdiff_t differ in width");

/* ── Output context ────────────────────────────────────────────────────── */

typedef struct {
    char *buf;
    size_t size;
    size_t pos;
    bool overflow;
} OutCtx;

static inline void ctx_advance(OutCtx *c, size_t n)
{
    if (n > SIZE_MAX - c->pos) {
        c->pos = SIZE_MAX;
        c->overflow = true;
    } else {
        c->pos += n;
    }
}

static inline void ctx_putc(OutCtx *c, char ch)
{
    if (c->buf && c->size > 0 && c->pos < c->size - 1)
        c->buf[c->pos] = ch;
    ctx_advance(c, 1);
}
static void ctx_write(OutCtx *c, const char *s, size_t n)
{
    if (c->buf && c->size > 0 && c->pos < c->size - 1) {
        size_t room = c->size - 1 - c->pos;
        size_t copy = n < room ? n : room;
        memcpy(c->buf + c->pos, s, copy);
    }
    ctx_advance(c, n);
}
static void ctx_repeat(OutCtx *c, char ch, size_t n)
{
    if (c->buf && c->size > 0 && c->pos < c->size - 1) {
        size_t room = c->size - 1 - c->pos;
        size_t fill = n < room ? n : room;
        memset(c->buf + c->pos, (unsigned char) ch, fill);
    }
    ctx_advance(c, n);
}
static void ctx_term(OutCtx *c)
{
    if (c->buf && c->size > 0)
        c->buf[(c->pos < c->size) ? c->pos : c->size - 1] = '\0';
}

/* ── Integer conversion ────────────────────────────────────────────────── */

#define IBUF 66
static const char *u64str(uint64_t v, unsigned base, bool up, char buf[IBUF], size_t *ol)
{
    static const char lo[] = "0123456789abcdef", hi[] = "0123456789ABCDEF";
    const char *d = up ? hi : lo;
    size_t i = IBUF;
    buf[--i] = '\0';
    if (!v)
        buf[--i] = '0';
    else
        while (v) {
            buf[--i] = d[v % base];
            v /= base;
        }
    *ol = IBUF - 1 - i;
    return &buf[i];
}

/* ── Floating-point digits ─────────────────────────────────────────────── */

static inline uint64_t dbits(double d)
{
    uint64_t u;
    memcpy(&u, &d, 8);
    return u;
}

typedef struct {
    bool neg, nan, inf;
} FPC;
static FPC fpclass(double d)
{
    uint64_t b = dbits(d);
    int e = (int) ((b >> 52) & 0x7FF);
    uint64_t m = b & 0xFFFFFFFFFFFFFULL;
    return (FPC){(b >> 63) != 0, e == 0x7FF && m != 0, e == 0x7FF && m == 0};
}

#define CHUNK_BASE 1000000000U

/* The largest double has 309 integer digits, 35 chunks of nine. The limbs
 * hold a fraction numerator of up to 1074 bits plus the 4 bits a multiply by
 * 10 adds, or an integer below 2^1024 while its chunks are divided out. */
#define FP_CHUNKS 35
#define FP_LIMBS 35

/*
 * Exact decimal digits of a finite |d|, most significant first: the integer
 * part as base-1e9 chunks, then the fraction frac / 2^fbits one digit at a
 * time. After the last nonzero digit the stream yields zeros.
 */
typedef struct {
    uint32_t chunk[FP_CHUNKS]; /* integer part, least significant chunk first */
    uint32_t frac[FP_LIMBS];   /* fraction numerator, least significant limb first */
    uint8_t cdig[9];           /* digits of chunk[ci], most significant first */
    int ci;                    /* chunk being read, -1 after the integer part */
    int cpos;                  /* next digit of cdig to read */
    int clast;                 /* last nonzero digit of cdig, -1 if none */
    int chunk_nz;              /* lowest nonzero chunk */
    int fbits;                 /* the fraction is frac / 2^fbits */
    int flo, ftop;             /* lowest and highest nonzero limbs; flo > ftop for 0 */
    int pend;                  /* first digit, read ahead past leading zeros; -1 if none */
    int e10;                   /* decimal exponent of the first digit (0 for zero) */
} FpDigits;

static void load_chunk(FpDigits *s)
{
    uint32_t v = s->chunk[s->ci];
    s->clast = -1;
    for (int j = 8; j >= 0; j--) {
        s->cdig[j] = (uint8_t) (v % 10U);
        v /= 10U;
        if (s->clast < 0 && s->cdig[j] != 0)
            s->clast = j;
    }
    s->cpos = 0;
}

/* Multiply the fraction by 10 and return the digit that moves above the binary point. */
static int frac_next(FpDigits *s)
{
    int q = s->fbits / 32, r = s->fbits % 32;
    uint32_t carry = 0, dg;

    if (s->flo > s->ftop)
        return 0;
    for (int i = s->flo; i <= s->ftop; i++) {
        uint64_t t = (uint64_t) s->frac[i] * 10U + carry;
        s->frac[i] = (uint32_t) t;
        carry = (uint32_t) (t >> 32);
    }
    if (carry)
        s->frac[++s->ftop] = carry;
    while (s->frac[s->flo] == 0)
        s->flo++;
    if (s->ftop < q)
        return 0;
    /* The product is below 2^(fbits + 4), so only limb q, and limb q + 1
     * when r > 28, hold bits at or above fbits. */
    dg = s->frac[q] >> r;
    if (s->ftop > q) {
        dg |= s->frac[q + 1] << (32 - r);
        s->frac[q + 1] = 0;
    }
    s->frac[q] = r ? s->frac[q] & ((1U << r) - 1U) : 0U;
    s->ftop = q;
    while (s->ftop >= s->flo && s->frac[s->ftop] == 0)
        s->ftop--;
    while (s->flo <= s->ftop && s->frac[s->flo] == 0)
        s->flo++;
    return (int) dg;
}

static int fpd_next(FpDigits *s)
{
    if (s->pend >= 0) {
        int dg = s->pend;
        s->pend = -1;
        return dg;
    }
    if (s->ci >= 0) {
        int dg = s->cdig[s->cpos++];
        if (s->cpos == 9 && --s->ci >= 0)
            load_chunk(s);
        return dg;
    }
    return frac_next(s);
}

/* True while a nonzero digit remains in the stream. */
static bool fpd_more(const FpDigits *s)
{
    if (s->pend > 0 || s->flo <= s->ftop)
        return true;
    return s->ci >= 0 && (s->cpos <= s->clast || s->ci > s->chunk_nz);
}

/* Start the digit stream of |d|, given the bits of a finite |d|. */
static void fpd_init(FpDigits *s, uint64_t bits)
{
    int be = (int) (bits >> 52);
    int k = be ? be - 1075 : -1074;
    uint64_t m = (bits & 0xFFFFFFFFFFFFFULL) | (be ? 1ULL << 52 : 0);
    int nchunk = 0;

    /* |d| = m * 2^k */
    memset(s->frac, 0, sizeof(s->frac));
    s->ci = -1;
    s->chunk_nz = 0;
    s->fbits = 0;
    s->flo = 0;
    s->ftop = -1;
    s->pend = -1;
    s->e10 = 0;
    if (m == 0)
        return;

    if (k >= 0) {
        /* Build the integer m * 2^k in the limbs, then divide out the chunks. */
        uint32_t *n = s->frac;
        int q = k / 32, r = k % 32, top = q + 2;
        n[q] = (uint32_t) (m << r);
        n[q + 1] = (uint32_t) (r ? m >> (32 - r) : m >> 32);
        n[q + 2] = (uint32_t) (r ? m >> (64 - r) : 0);
        do {
            uint64_t rem = 0;
            while (top > 0 && n[top] == 0)
                top--;
            for (int i = top; i >= 0; i--) {
                uint64_t t = (rem << 32) | n[i];
                n[i] = (uint32_t) (t / CHUNK_BASE);
                rem = t % CHUNK_BASE;
            }
            s->chunk[nchunk++] = (uint32_t) rem;
        } while (top > 0 || n[0] != 0);
    } else {
        int sh = -k;
        uint64_t ip = sh < 64 ? m >> sh : 0;
        uint64_t fr = sh < 64 ? m & ((1ULL << sh) - 1U) : m;
        while (ip) {
            s->chunk[nchunk++] = (uint32_t) (ip % CHUNK_BASE);
            ip /= CHUNK_BASE;
        }
        s->fbits = sh;
        s->frac[0] = (uint32_t) fr;
        s->frac[1] = (uint32_t) (fr >> 32);
        s->ftop = 1;
        while (s->ftop >= 0 && s->frac[s->ftop] == 0)
            s->ftop--;
        while (s->flo <= s->ftop && s->frac[s->flo] == 0)
            s->flo++;
    }

    if (nchunk > 0) {
        s->ci = nchunk - 1;
        load_chunk(s);
        while (s->cdig[s->cpos] == 0)
            s->cpos++;
        s->e10 = 9 * (nchunk - 1) + 8 - s->cpos;
        while (s->chunk[s->chunk_nz] == 0)
            s->chunk_nz++;
    } else {
        int dg;
        s->e10 = -1;
        while ((dg = frac_next(s)) == 0)
            s->e10--;
        s->pend = dg;
    }
}

/*
 * Rounding of `keep` digits, the first `lead` of them zeros ahead of the
 * stream's first digit, to nearest with ties to even.
 */
typedef struct {
    int64_t last_lt9; /* last kept digit below 9, or -1 */
    int64_t last_nz;  /* last nonzero kept digit after rounding, or -1 */
    bool up;          /* add one to digit keep - 1 */
    bool carry;       /* the addition carries out of digit 0 */
} FpRound;

static void fp_round(FpDigits *s, const FpDigits *start, int64_t lead, int64_t keep, FpRound *r)
{
    int64_t i = lead < keep ? lead : keep;
    int last = 0;

    *s = *start;
    r->last_lt9 = i - 1;
    r->last_nz = -1;
    r->up = false;
    for (; i < keep; i++) {
        if (!fpd_more(s)) {
            /* The remaining kept digits and the rounding digit are zeros. */
            r->last_lt9 = keep - 1;
            break;
        }
        last = fpd_next(s);
        if (last != 9)
            r->last_lt9 = i;
        if (last != 0)
            r->last_nz = i;
    }
    if (i == keep && keep >= lead) {
        int rd = fpd_next(s);
        r->up = rd > 5 || (rd == 5 && (fpd_more(s) || (last & 1)));
    }
    r->carry = r->up && r->last_lt9 < 0;
    if (r->up)
        r->last_nz = r->last_lt9;
}

/* Write zeros for digits [from, total), with the point after digit nint - 1. */
static void fp_zeros(OutCtx *c, int64_t from, int64_t total, int64_t nint, bool point)
{
    if (from < nint) {
        ctx_repeat(c, '0', (size_t) (nint - from));
        if (point)
            ctx_putc(c, '.');
        from = nint;
    }
    ctx_repeat(c, '0', (size_t) (total - from));
}

/*
 * Write the rounded digits: nint of them before the point and nfrac after it.
 * A carry out of the kept digits prints as a leading 1, then zeros.
 */
static void fp_digits_out(OutCtx *c,
                          FpDigits *s,
                          const FpDigits *start,
                          int64_t lead,
                          const FpRound *r,
                          int64_t nint,
                          int64_t nfrac,
                          bool point)
{
    int64_t total = nint + nfrac, i = 0;

    if (r->carry) {
        ctx_putc(c, '1');
        if (point && nint == 1)
            ctx_putc(c, '.');
        fp_zeros(c, 1, total, nint, point);
        return;
    }
    *s = *start;
    for (; i < total; i++) {
        int dg = 0;
        if (i >= lead) {
            if (!fpd_more(s))
                break;
            dg = fpd_next(s);
        }
        if (r->up && i >= r->last_lt9)
            dg = (i == r->last_lt9) ? dg + 1 : 0;
        ctx_putc(c, (char) ('0' + dg));
        if (point && i + 1 == nint)
            ctx_putc(c, '.');
    }
    fp_zeros(c, i, total, nint, point);
}

/* Infinity and NaN: the sign and the + and space flags apply, 0 does not. */
static void sp_special(OutCtx *c, bool nan, char sgn, bool up, int w, bool lj)
{
    const char *s = nan ? (up ? "NAN" : "nan") : (up ? "INF" : "inf");
    size_t l = sgn ? 4U : 3U;
    size_t pad = (w > 0 && (size_t) w > l) ? (size_t) w - l : 0;
    if (!lj)
        ctx_repeat(c, ' ', pad);
    if (sgn)
        ctx_putc(c, sgn);
    ctx_write(c, s, 3);
    if (lj)
        ctx_repeat(c, ' ', pad);
}

/* ── %f %F %e %E %g %G ─────────────────────────────────────────────────── */
static void
do_fp(OutCtx *c, double d, int prec, char conv, bool fp, bool fsp, bool fh, int w, bool lj, bool zp)
{
    FPC fc = fpclass(d);
    char sgn = fc.neg ? '-' : (fp ? '+' : (fsp ? ' ' : 0));
    bool up = conv == 'F' || conv == 'E' || conv == 'G';
    char style = (char) (conv | 0x20);
    uint64_t bits = dbits(d) & ~(1ULL << 63);
    int64_t p = prec < 0 ? 6 : prec;
    int64_t lead = 0, nint = 1, nfrac;
    bool trim = false;
    FpDigits start, s;
    FpRound r;

    if (fc.nan || fc.inf) {
        sp_special(c, fc.nan, sgn, up, w, lj);
        return;
    }
    fpd_init(&start, bits);
    int e10 = start.e10;

    if (style == 'g') {
        /* Style f when the exponent after rounding to P significant digits
         * is in [-4, P), else style e; trailing zeros go unless '#'. */
        int64_t x;
        if (p == 0)
            p = 1;
        fp_round(&s, &start, 0, p, &r);
        x = e10 + (r.carry ? 1 : 0);
        trim = !fh;
        style = (x >= -4 && x < p) ? 'f' : 'e';
        p = style == 'f' ? p - 1 - x : p - 1;
    }
    if (style == 'f') {
        nint = (e10 > 0 ? e10 : 0) + 1;
        lead = nint - 1 - e10;
    }
    fp_round(&s, &start, lead, nint + p, &r);
    if (style == 'e') {
        e10 += r.carry ? 1 : 0;
    } else if (r.carry) {
        nint++;
    }
    nfrac = p;
    if (trim)
        nfrac = r.last_nz >= nint ? r.last_nz - nint + 1 : 0;
    bool point = nfrac > 0 || fh;

    char eb[8];
    size_t el = 0;
    if (style == 'e') {
        unsigned ae = (unsigned) (e10 < 0 ? -e10 : e10);
        eb[el++] = up ? 'E' : 'e';
        eb[el++] = e10 < 0 ? '-' : '+';
        if (ae >= 100U)
            eb[el++] = (char) ('0' + ae / 100U);
        eb[el++] = (char) ('0' + ae / 10U % 10U);
        eb[el++] = (char) ('0' + ae % 10U);
    }

    size_t content = (sgn ? 1U : 0U) + (size_t) nint + (point ? 1U : 0U) + (size_t) nfrac + el;
    size_t pad = (w > 0 && (size_t) w > content) ? (size_t) w - content : 0;

    if (!lj && !zp)
        ctx_repeat(c, ' ', pad);
    if (sgn)
        ctx_putc(c, sgn);
    if (!lj && zp)
        ctx_repeat(c, '0', pad);
    fp_digits_out(c, &s, &start, lead, &r, nint, nfrac, point);
    ctx_write(c, eb, el);
    if (lj)
        ctx_repeat(c, ' ', pad);
}

/* ── Integer emit ──────────────────────────────────────────────────────── */
static void emit_int(OutCtx *c,
                     uint64_t uv,
                     bool sgnd,
                     bool neg,
                     unsigned base,
                     bool up,
                     bool lj,
                     bool fp,
                     bool fsp,
                     bool zp,
                     bool fh,
                     int w,
                     int prec)
{
    /* C99: a zero value with precision 0 prints no digits, only the padding and,
     * for a signed conversion, a '+' or ' ' flag. %#.0o is the exception: it
     * prints "0". */
    if (prec == 0 && uv == 0 && !(fh && base == 8)) {
        char sc = 0;
        if (sgnd) {
            if (neg)
                sc = '-';
            else if (fp)
                sc = '+';
            else if (fsp)
                sc = ' ';
        }
        size_t content = sc ? 1U : 0U;
        size_t pad = (w > 0 && (size_t) w > content) ? (size_t) w - content : 0;
        if (!lj)
            ctx_repeat(c, ' ', pad);
        if (sc)
            ctx_putc(c, sc);
        if (lj)
            ctx_repeat(c, ' ', pad);
        return;
    }

    char ib[IBUF];
    size_t dl;
    const char *digs = u64str(uv, base, up, ib, &dl);
    size_t pp = (prec > 0 && dl < (size_t) prec) ? (size_t) prec - dl : 0;

    /* '#' with o adds a leading 0 only when the precision has not already. */
    char pfx[3];
    int pl = 0;
    if (sgnd) {
        if (neg)
            pfx[pl++] = '-';
        else if (fp)
            pfx[pl++] = '+';
        else if (fsp)
            pfx[pl++] = ' ';
    } else if (fh && uv != 0) {
        if (base == 8 && pp == 0)
            pfx[pl++] = '0';
        else if (base == 16) {
            pfx[pl++] = '0';
            pfx[pl++] = up ? 'X' : 'x';
        }
    }

    size_t nl = (size_t) pl + pp + dl;
    size_t pad = (w > 0 && (size_t) w > nl) ? (size_t) w - nl : 0;
    bool dozp = zp && prec < 0 && !lj;

    if (!lj && !dozp)
        ctx_repeat(c, ' ', pad);
    for (int i = 0; i < pl; i++)
        ctx_putc(c, pfx[i]);
    if (!lj && dozp)
        ctx_repeat(c, '0', pad);
    ctx_repeat(c, '0', pp);
    ctx_write(c, digs, dl);
    if (lj)
        ctx_repeat(c, ' ', pad);
}

/* ── Core engine ─────────────────────────────────────────────────────── */

typedef enum { LM_NONE, LM_HH, LM_H, LM_L, LM_LL, LM_Z, LM_T } LenMod;

static int parse_decimal_int(const char **cursor, bool *clamped)
{
    const char *p = *cursor;
    int value = 0;

    while (*p >= '0' && *p <= '9') {
        int digit = *p++ - '0';
        if (value > (INT_MAX - digit) / 10) {
            value = INT_MAX;
            *clamped = true;
        } else {
            value = value * 10 + digit;
        }
    }
    *cursor = p;
    return value;
}

int vsnprintf(char *buf, size_t size, const char *fmt, va_list ap)
{
    OutCtx ctx = {buf, size, 0, false};

    for (const char *p = fmt; *p; p++) {
        if (*p != '%') {
            ctx_putc(&ctx, *p);
            continue;
        }
        p++;
        if (*p == '\0') {
            /* A trailing '%' is malformed, but it must not walk past fmt. */
            ctx_putc(&ctx, '%');
            break;
        }

        bool fm = false, fp = false, fsp = false, fz = false, fh = false;
        for (;;) {
            switch (*p) {
                case '-':
                    fm = true;
                    p++;
                    continue;
                case '+':
                    fp = true;
                    p++;
                    continue;
                case ' ':
                    fsp = true;
                    p++;
                    continue;
                case '0':
                    fz = true;
                    p++;
                    continue;
                case '#':
                    fh = true;
                    p++;
                    continue;
            }
            break;
        }

        int w = 0;
        if (*p == '*') {
            w = va_arg(ap, int);
            if (w < 0) {
                fm = true;
                if (w == INT_MIN) {
                    /* The positive width cannot be represented by int. */
                    w = INT_MAX;
                    ctx.overflow = true;
                } else {
                    w = -w;
                }
            }
            p++;
        } else {
            w = parse_decimal_int(&p, &ctx.overflow);
        }

        int prec = -1;
        bool precision_clamped = false;
        if (*p == '.') {
            p++;
            prec = 0;
            if (*p == '*') {
                prec = va_arg(ap, int);
                if (prec < 0)
                    prec = -1;
                p++;
            } else {
                prec = parse_decimal_int(&p, &precision_clamped);
            }
        }

        LenMod lm = LM_NONE;
        switch (*p) {
            case 'h':
                p++;
                lm = (*p == 'h') ? (p++, LM_HH) : LM_H;
                break;
            case 'l':
                p++;
                lm = (*p == 'l') ? (p++, LM_LL) : LM_L;
                break;
            case 'z':
                lm = LM_Z;
                p++;
                break;
            case 't':
                lm = LM_T;
                p++;
                break;
        }

        if (*p == '\0') {
            /* Likewise, do not advance beyond an incomplete conversion. */
            break;
        }

        /* A precision larger than INT_MAX does not itself imply that the
         * formatted output is too long: for example, it may merely bound a
         * one-character string. Integer precision, however, is a minimum
         * digit count, so a clamped integer precision necessarily exceeds the
         * representable snprintf return range. Do this after consuming length
         * modifiers so *p names the actual conversion. */
        if (precision_clamped &&
            (*p == 'd' || *p == 'i' || *p == 'u' || *p == 'o' || *p == 'x' || *p == 'X')) {
            ctx.overflow = true;
        }

        switch (*p) {
            case '%':
                ctx_putc(&ctx, '%');
                break;

            case 'c': {
                char ch = (char) va_arg(ap, int);
                size_t pad = w > 1 ? (size_t) w - 1U : 0;
                if (!fm)
                    ctx_repeat(&ctx, ' ', pad);
                ctx_putc(&ctx, ch);
                if (fm)
                    ctx_repeat(&ctx, ' ', pad);
                break;
            }
            case 's': {
                const char *s = va_arg(ap, const char *);
                if (!s)
                    s = "(null)";
                size_t sl = prec >= 0 ? strnlen(s, (size_t) prec) : strlen(s);
                size_t pad = (w > 0 && (size_t) w > sl) ? (size_t) w - sl : 0;
                if (!fm)
                    ctx_repeat(&ctx, ' ', pad);
                ctx_write(&ctx, s, sl);
                if (fm)
                    ctx_repeat(&ctx, ' ', pad);
                break;
            }
            case 'p': {
                void *ptr = va_arg(ap, void *);
                uintptr_t uv = (uintptr_t) ptr;
                char ib[IBUF];
                size_t dl;
                const char *digs = u64str((uint64_t) uv, 16, false, ib, &dl);
                size_t cont = 2U + dl;
                size_t pad = (w > 0 && (size_t) w > cont) ? (size_t) w - cont : 0;
                if (!fm)
                    ctx_repeat(&ctx, ' ', pad);
                ctx_putc(&ctx, '0');
                ctx_putc(&ctx, 'x');
                ctx_write(&ctx, digs, dl);
                if (fm)
                    ctx_repeat(&ctx, ' ', pad);
                break;
            }
            case 'd':
            case 'i': {
                int64_t sv;
                switch (lm) {
                    case LM_HH:
                        sv = (signed char) va_arg(ap, int);
                        break;
                    case LM_H:
                        sv = (short) va_arg(ap, int);
                        break;
                    case LM_L:
                        sv = (long) va_arg(ap, long);
                        break;
                    case LM_LL:
                        sv = (long long) va_arg(ap, long long);
                        break;
                    case LM_Z:
                        sv = (ptrdiff_t) va_arg(ap, ptrdiff_t);
                        break;
                    case LM_T:
                        sv = (ptrdiff_t) va_arg(ap, ptrdiff_t);
                        break;
                    default:
                        sv = va_arg(ap, int);
                        break;
                }
                bool neg = sv < 0;
                uint64_t uv = neg ? (uint64_t) (-(sv + 1)) + 1 : (uint64_t) sv;
                emit_int(&ctx, uv, true, neg, 10, false, fm, fp, fsp, fz, fh, w, prec);
                break;
            }
            case 'u':
            case 'o':
            case 'x':
            case 'X': {
                uint64_t uv;
                switch (lm) {
                    case LM_HH:
                        uv = (unsigned char) va_arg(ap, unsigned);
                        break;
                    case LM_H:
                        uv = (unsigned short) va_arg(ap, unsigned);
                        break;
                    case LM_L:
                        uv = (unsigned long) va_arg(ap, unsigned long);
                        break;
                    case LM_LL:
                        uv = (unsigned long long) va_arg(ap, unsigned long long);
                        break;
                    case LM_Z:
                    case LM_T:
                        uv = (size_t) va_arg(ap, size_t);
                        break;
                    default:
                        uv = (unsigned) va_arg(ap, unsigned);
                        break;
                }
                unsigned base = (*p == 'u') ? 10U : (*p == 'o') ? 8U : 16U;
                emit_int(&ctx, uv, false, false, base, *p == 'X', fm, fp, fsp, fz, fh, w, prec);
                break;
            }
            case 'f':
            case 'F':
            case 'e':
            case 'E':
            case 'g':
            case 'G':
                do_fp(&ctx, va_arg(ap, double), prec, *p, fp, fsp, fh, w, fm, fz);
                break;
            case 'n': {
                /* The count goes into the object type the length modifier names. */
                size_t n = ctx.pos;
                switch (lm) {
                    case LM_HH: {
                        signed char *np = va_arg(ap, signed char *);
                        if (np)
                            *np = (signed char) n;
                        break;
                    }
                    case LM_H: {
                        short *np = va_arg(ap, short *);
                        if (np)
                            *np = (short) n;
                        break;
                    }
                    case LM_L: {
                        long *np = va_arg(ap, long *);
                        if (np)
                            *np = (long) n;
                        break;
                    }
                    case LM_LL: {
                        long long *np = va_arg(ap, long long *);
                        if (np)
                            *np = (long long) n;
                        break;
                    }
                    case LM_Z:
                    case LM_T: {
                        ptrdiff_t *np = va_arg(ap, ptrdiff_t *);
                        if (np)
                            *np = (ptrdiff_t) n;
                        break;
                    }
                    default: {
                        int *np = va_arg(ap, int *);
                        if (np)
                            *np = (int) n;
                        break;
                    }
                }
                break;
            }
            default:
                ctx_putc(&ctx, '%');
                ctx_putc(&ctx, *p);
                break;
        }
    }
    ctx_term(&ctx);
    if (ctx.overflow || ctx.pos > INT_MAX)
        return -1;
    return (int) ctx.pos;
}

int vsprintf(char *buf, const char *fmt, va_list ap)
{
    return vsnprintf(buf, (size_t) -1, fmt, ap);
}

int snprintf(char *buf, size_t size, const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    int r = vsnprintf(buf, size, fmt, ap);
    va_end(ap);
    return r;
}

int sprintf(char *buf, const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    int r = vsprintf(buf, fmt, ap);
    va_end(ap);
    return r;
}
