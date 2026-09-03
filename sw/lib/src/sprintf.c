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
 * Floating-point conversion scales |d| by 10^prec and rounds in the uint64_t
 * domain, which avoids cascading floating-point rounding errors.
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

/* ── Floating-point helpers ────────────────────────────────────────────── */

static const uint64_t P10U[] = {1ULL,
                                10ULL,
                                100ULL,
                                1000ULL,
                                10000ULL,
                                100000ULL,
                                1000000ULL,
                                10000000ULL,
                                100000000ULL,
                                1000000000ULL,
                                10000000000ULL,
                                100000000000ULL,
                                1000000000000ULL,
                                10000000000000ULL,
                                100000000000000ULL,
                                1000000000000000ULL,
                                10000000000000000ULL,
                                100000000000000000ULL,
                                1000000000000000000ULL};
#define NP10 18

static const double P10D[] = {1e0,  1e1,  1e2,  1e3,  1e4,  1e5,  1e6,  1e7,  1e8,  1e9,  1e10,
                              1e11, 1e12, 1e13, 1e14, 1e15, 1e16, 1e17, 1e18, 1e19, 1e20, 1e21,
                              1e22, 1e23, 1e24, 1e25, 1e26, 1e27, 1e28, 1e29, 1e30, 1e31};

static inline double dabs(double d)
{
    return d < 0 ? -d : d;
}
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
    return (FPC) {(b >> 63) != 0, e == 0x7FF && m != 0, e == 0x7FF && m == 0};
}

/* floor(log10(|d|)) for d>0 */
static int exp10of(double d)
{
    d = dabs(d);
    int e = 0;
    if (d >= 1.0) {
        while (e < 31 && d >= P10D[e + 1])
            e++;
    } else {
        while (d < 1.0 && e > -350) {
            d *= 10.0;
            e--;
        }
        if (d >= 10.0) {
            d /= 10.0;
            e++;
        } /* FP rounding edge-case */
    }
    return e;
}

static void sp_special(OutCtx *c, const char *s, int w, bool lj)
{
    size_t l = strlen(s);
    size_t pad = (w > 0 && (size_t) w > l) ? (size_t) w - l : 0;
    if (!lj)
        ctx_repeat(c, ' ', pad);
    ctx_write(c, s, l);
    if (lj)
        ctx_repeat(c, ' ', pad);
}

/* ── %f ───────────────────────────────────────────────────────────────── */
static void
do_f(OutCtx *c, double d, int prec, bool fp, bool fsp, bool fh, int w, bool lj, bool zp, bool trim)
{
    if (prec < 0)
        prec = 6;
    FPC fc = fpclass(d);
    if (fc.nan) {
        sp_special(c, "nan", w, lj);
        return;
    }
    if (fc.inf) {
        sp_special(c, fc.neg ? "-inf" : "inf", w, lj);
        return;
    }

    double ad = dabs(d);
    char sgn = fc.neg ? '-' : (fp ? '+' : (fsp ? ' ' : 0));

    /* integer digit count */
    int e10 = (ad == 0.0) ? 0 : exp10of(ad);
    int idigs = (e10 >= 0) ? (e10 + 1) : 0;

    /* cap precision so idigs+prec <= NP10 (fits in uint64_t) */
    int sp;
    if (idigs >= (int) NP10) {
        sp = 0;
    } else {
        int max_sp = (int) NP10 - idigs;
        sp = prec < max_sp ? prec : max_sp;
    }

    /* scaled = round(ad * 10^sp) */
    double sh = ad * (double) P10U[sp] + 0.5;
    uint64_t scaled = (sh >= (double) UINT64_MAX) ? UINT64_MAX : (uint64_t) sh;

    uint64_t scale = P10U[sp];
    uint64_t ipart = scaled / scale, fpart = scaled % scale;

    int frac_digits = sp;
    int out_prec = prec;
    if (trim && !fh) {
        while (frac_digits > 0 && fpart % 10U == 0) {
            fpart /= 10U;
            frac_digits--;
        }
        out_prec = frac_digits;
    }

    char ib[IBUF];
    size_t il;
    const char *ip = u64str(ipart, 10, false, ib, &il);

    char frac_buf[IBUF];
    size_t fl = 0;
    const char *frac = NULL;
    if (frac_digits > 0)
        frac = u64str(fpart, 10, false, frac_buf, &fl);

    size_t body = il;
    if (out_prec > 0 || fh)
        body += 1U + (size_t) out_prec;
    size_t content = body + (sgn ? 1U : 0U);
    size_t pad = (w > 0 && (size_t) w > content) ? (size_t) w - content : 0;

    if (!lj && !zp)
        ctx_repeat(c, ' ', pad);
    if (sgn)
        ctx_putc(c, sgn);
    if (!lj && zp)
        ctx_repeat(c, '0', pad);

    ctx_write(c, ip, il);
    if (out_prec > 0 || fh) {
        ctx_putc(c, '.');
        if (frac_digits > 0) {
            ctx_repeat(c, '0', (size_t) frac_digits - fl);
            ctx_write(c, frac, fl);
        }
        ctx_repeat(c, '0', (size_t) (out_prec - frac_digits));
    }
    if (lj)
        ctx_repeat(c, ' ', pad);
}

/* ── %e / %E ─────────────────────────────────────────────────────────── */
static void do_e(OutCtx *c,
                 double d,
                 int prec,
                 bool fp,
                 bool fsp,
                 bool fh,
                 int w,
                 bool lj,
                 bool zp,
                 bool up,
                 bool trim)
{
    if (prec < 0)
        prec = 6;
    FPC fc = fpclass(d);
    if (fc.nan) {
        sp_special(c, "nan", w, lj);
        return;
    }
    if (fc.inf) {
        sp_special(c, fc.neg ? "-inf" : "inf", w, lj);
        return;
    }

    double ad = dabs(d);
    char sgn = fc.neg ? '-' : (fp ? '+' : (fsp ? ' ' : 0));
    int e10 = (ad == 0.0) ? 0 : exp10of(ad);

    /* cap precision */
    int sp = prec;
    if (sp > (int) NP10 - 1)
        sp = (int) NP10 - 1;

    /* normalise: t = ad/10^e10, should be in [1,10) */
    double t;
    if (ad == 0.0)
        t = 0.0;
    else if (e10 >= 0 && e10 <= (int) NP10)
        t = ad / (double) P10U[e10];
    else if (e10 < 0 && -e10 <= (int) NP10)
        t = ad * (double) P10U[-e10];
    else if (e10 >= 0 && e10 <= 31)
        t = ad / P10D[e10];
    else
        t = ad;
    /* nudge into [1,10) */
    if (ad != 0.0) {
        while (t >= 10.0) {
            t /= 10.0;
            e10++;
        }
        while (t < 1.0) {
            t *= 10.0;
            e10--;
        }
    }

    uint64_t scale = P10U[sp];
    double sh = t * (double) scale + 0.5;
    uint64_t scaled = (sh >= (double) UINT64_MAX) ? UINT64_MAX : (uint64_t) sh;
    /* rounding overflow? */
    if (scaled >= scale * 10) {
        scaled /= 10;
        e10++;
    }

    uint64_t first = scaled / scale, frac = scaled % scale;

    int frac_digits = sp;
    int out_prec = prec;
    if (trim && !fh) {
        while (frac_digits > 0 && frac % 10U == 0) {
            frac /= 10U;
            frac_digits--;
        }
        out_prec = frac_digits;
    }

    char frac_buf[IBUF];
    size_t fl = 0;
    const char *frac_str = NULL;
    if (frac_digits > 0)
        frac_str = u64str(frac, 10, false, frac_buf, &fl);

    int ae = e10;
    char exp_sign = (ae < 0) ? '-' : '+';
    if (ae < 0)
        ae = -ae;
    char exp_buf[IBUF];
    size_t exp_digits;
    const char *exp_str = u64str((uint64_t) ae, 10, false, exp_buf, &exp_digits);
    size_t exponent_len = 2U + (exp_digits < 2U ? 2U : exp_digits);

    size_t body = 1U + exponent_len;
    if (out_prec > 0 || fh)
        body += 1U + (size_t) out_prec;
    size_t content = body + (sgn ? 1U : 0U);
    size_t pad = (w > 0 && (size_t) w > content) ? (size_t) w - content : 0;

    if (!lj && !zp)
        ctx_repeat(c, ' ', pad);
    if (sgn)
        ctx_putc(c, sgn);
    if (!lj && zp)
        ctx_repeat(c, '0', pad);

    ctx_putc(c, (char) ('0' + (int) first));
    if (out_prec > 0 || fh) {
        ctx_putc(c, '.');
        if (frac_digits > 0) {
            ctx_repeat(c, '0', (size_t) frac_digits - fl);
            ctx_write(c, frac_str, fl);
        }
        ctx_repeat(c, '0', (size_t) (out_prec - frac_digits));
    }
    ctx_putc(c, up ? 'E' : 'e');
    ctx_putc(c, exp_sign);
    if (exp_digits < 2U)
        ctx_putc(c, '0');
    ctx_write(c, exp_str, exp_digits);

    if (lj)
        ctx_repeat(c, ' ', pad);
}

/* ── %g / %G ─────────────────────────────────────────────────────────── */
static void
do_g(OutCtx *c, double d, int prec, bool fp, bool fsp, bool fh, int w, bool lj, bool zp, bool up)
{
    if (prec < 0)
        prec = 6;
    if (prec == 0)
        prec = 1;
    FPC fc = fpclass(d);
    if (fc.nan) {
        sp_special(c, "nan", w, lj);
        return;
    }
    if (fc.inf) {
        sp_special(c, fc.neg ? "-inf" : "inf", w, lj);
        return;
    }

    double ad = dabs(d);
    int e10 = (ad == 0.0) ? 0 : exp10of(ad);

    if (e10 < -4 || e10 >= prec) {
        do_e(c, d, prec - 1, fp, fsp, fh, w, lj, zp, up, true);
    } else {
        int64_t requested = (int64_t) prec - 1 - e10;
        int p = requested > INT_MAX ? INT_MAX : (int) requested;
        do_f(c, d, p, fp, fsp, fh, w, lj, zp, true);
    }
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
    /* C99: %.0d with value 0 prints nothing but the padding */
    if (prec == 0 && uv == 0 && !fh) {
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
        if (base == 8)
            pfx[pl++] = '0';
        else if (base == 16) {
            pfx[pl++] = '0';
            pfx[pl++] = up ? 'X' : 'x';
        }
    }

    size_t pp = (prec > 0 && dl < (size_t) prec) ? (size_t) prec - dl : 0;
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
            case 'u': {
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
                        uv = (size_t) va_arg(ap, size_t);
                        break;
                    default:
                        uv = (unsigned) va_arg(ap, unsigned);
                        break;
                }
                emit_int(&ctx, uv, false, false, 10, false, fm, fp, fsp, fz, fh, w, prec);
                break;
            }
            case 'o': {
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
                    default:
                        uv = (unsigned) va_arg(ap, unsigned);
                        break;
                }
                emit_int(&ctx, uv, false, false, 8, false, fm, fp, fsp, fz, fh, w, prec);
                break;
            }
            case 'x':
            case 'X': {
                bool up = (*p == 'X');
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
                    default:
                        uv = (unsigned) va_arg(ap, unsigned);
                        break;
                }
                emit_int(&ctx, uv, false, false, 16, up, fm, fp, fsp, fz, fh, w, prec);
                break;
            }
            case 'f':
            case 'F':
                do_f(&ctx, va_arg(ap, double), prec, fp, fsp, fh, w, fm, fz, false);
                break;
            case 'e':
            case 'E':
                do_e(&ctx, va_arg(ap, double), prec, fp, fsp, fh, w, fm, fz, *p == 'E', false);
                break;
            case 'g':
            case 'G':
                do_g(&ctx, va_arg(ap, double), prec, fp, fsp, fh, w, fm, fz, *p == 'G');
                break;
            case 'n': {
                int *np = va_arg(ap, int *);
                if (np)
                    *np = (int) ctx.pos;
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
