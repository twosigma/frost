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
 * sprintf.c  –  portable sprintf / snprintf, no <stdio.h> dependency.
 *
 * Floating-point uses integer-scaling (multiply |d|×10^prec, round in
 * uint64_t domain) which avoids cascading FP-rounding errors.
 *
 * Supported: %d %i %u %o %x %X %f %F %e %E %g %G %c %s %p %%
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
} OutCtx;

static inline void ctx_putc(OutCtx *c, char ch)
{
    if (c->buf && c->pos + 1 < c->size)
        c->buf[c->pos] = ch;
    c->pos++;
}
static void ctx_write(OutCtx *c, const char *s, size_t n)
{
    for (size_t i = 0; i < n; i++)
        ctx_putc(c, s[i]);
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
    int l = (int) strlen(s), pad = w - l;
    if (!lj)
        while (pad-- > 0)
            ctx_putc(c, ' ');
    ctx_write(c, s, (size_t) l);
    if (lj)
        while (pad-- > 0)
            ctx_putc(c, ' ');
}

/* emit sign + number string, padding to width */
static void padout(
    OutCtx *c, char sgn, const char *pfx, int pl, const char *num, int nl, int w, bool lj, bool zp)
{
    int content = (sgn ? 1 : 0) + pl + nl, pad = (w > content) ? w - content : 0;
    if (!lj && !zp)
        while (pad-- > 0)
            ctx_putc(c, ' ');
    if (sgn)
        ctx_putc(c, sgn);
    if (pl)
        ctx_write(c, pfx, (size_t) pl);
    if (!lj && zp)
        while (pad-- > 0)
            ctx_putc(c, '0');
    ctx_write(c, num, (size_t) nl);
    if (lj)
        while (pad-- > 0)
            ctx_putc(c, ' ');
}

/* ── %f ───────────────────────────────────────────────────────────────── */
static void do_f(OutCtx *c, double d, int prec, bool fp, bool fsp, bool fh, int w, bool lj, bool zp)
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
    int sp = prec;
    if (idigs + sp > (int) NP10)
        sp = (int) NP10 - idigs;
    if (sp < 0)
        sp = 0;

    /* scaled = round(ad * 10^sp) */
    double sh = ad * (double) P10U[sp] + 0.5;
    uint64_t scaled = (sh >= (double) UINT64_MAX) ? UINT64_MAX : (uint64_t) sh;

    uint64_t scale = P10U[sp];
    uint64_t ipart = scaled / scale, fpart = scaled % scale;

    char fb[80];
    int fi = 0;

    /* integer part */
    if (ipart == 0) {
        fb[fi++] = '0';
    } else {
        char ib[IBUF];
        size_t il;
        const char *ip = u64str(ipart, 10, false, ib, &il);
        for (size_t k = 0; k < il; k++)
            fb[fi++] = ip[k];
    }
    /* fractional part */
    if (prec > 0 || fh) {
        fb[fi++] = '.';
        if (sp > 0) {
            char ib[IBUF];
            size_t fl2;
            const char *fp2 = u64str(fpart, 10, false, ib, &fl2);
            int lz = sp - (int) fl2;
            for (int k = 0; k < lz; k++)
                fb[fi++] = '0';
            for (size_t k = 0; k < fl2; k++)
                fb[fi++] = fp2[k];
        }
        for (int k = sp; k < prec; k++)
            fb[fi++] = '0';
    }
    fb[fi] = '\0';
    padout(c, sgn, NULL, 0, fb, fi, w, lj, zp);
}

/* ── %e / %E ─────────────────────────────────────────────────────────── */
static void
do_e(OutCtx *c, double d, int prec, bool fp, bool fsp, bool fh, int w, bool lj, bool zp, bool up)
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

    char fb[80];
    int fi = 0;
    fb[fi++] = (char) ('0' + (int) first);
    if (prec > 0 || fh) {
        fb[fi++] = '.';
        if (sp > 0) {
            char ib[IBUF];
            size_t fl;
            const char *fp2 = u64str(frac, 10, false, ib, &fl);
            int lz = sp - (int) fl;
            for (int k = 0; k < lz; k++)
                fb[fi++] = '0';
            for (size_t k = 0; k < fl; k++)
                fb[fi++] = fp2[k];
        }
        for (int k = sp; k < prec; k++)
            fb[fi++] = '0';
    }
    /* exponent */
    fb[fi++] = up ? 'E' : 'e';
    int ae = e10;
    fb[fi++] = (ae < 0) ? '-' : '+';
    if (ae < 0)
        ae = -ae;
    if (ae >= 100)
        fb[fi++] = (char) ('0' + ae / 100);
    fb[fi++] = (char) ('0' + (ae / 10) % 10);
    fb[fi++] = (char) ('0' + ae % 10);
    fb[fi] = '\0';
    padout(c, sgn, NULL, 0, fb, fi, w, lj, zp);
}

/* strip trailing zeros (and lone '.') after fractional dot, in-place */
static int strip_tz(char *s, int len, bool fh)
{
    if (fh)
        return len;
    int dot = -1;
    for (int i = 0; i < len; i++)
        if (s[i] == '.') {
            dot = i;
            break;
        }
    if (dot < 0)
        return len;
    int nl = len;
    while (nl > dot + 1 && s[nl - 1] == '0')
        nl--;
    if (nl > 0 && s[nl - 1] == '.')
        nl--;
    s[nl] = '\0';
    return nl;
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

    /* build into scratch (no width/padding yet) */
    char tmp[128];
    OutCtx sc = {tmp, sizeof(tmp), 0};

    if (e10 < -4 || e10 >= prec) {
        do_e(&sc, d, prec - 1, fp, fsp, fh, 0, false, false, up);
    } else {
        int p = prec - 1 - e10;
        if (p < 0)
            p = 0;
        do_f(&sc, d, p, fp, fsp, fh, 0, false, false);
    }
    ctx_term(&sc);
    int tlen = (int) sc.pos;

    /* strip trailing zeros from the mantissa portion */
    if (!fh) {
        /* find where the sign/space prefix ends */
        int start = (tmp[0] == '-' || tmp[0] == '+' || tmp[0] == ' ') ? 1 : 0;
        /* find 'e'/'E' if present */
        int epos = -1;
        for (int i = start; i < tlen; i++)
            if (tmp[i] == 'e' || tmp[i] == 'E') {
                epos = i;
                break;
            }

        if (epos >= 0) {
            /* strip in mantissa [start..epos) */
            char mant[64];
            int ml = epos - start;
            memcpy(mant, &tmp[start], (size_t) ml);
            mant[ml] = '\0';
            int nml = strip_tz(mant, ml, false);
            /* rebuild */
            char nb[128];
            int ni = 0;
            if (start)
                nb[ni++] = tmp[0];
            memcpy(&nb[ni], mant, (size_t) nml);
            ni += nml;
            int el = tlen - epos;
            memcpy(&nb[ni], &tmp[epos], (size_t) el);
            ni += el;
            nb[ni] = '\0';
            memcpy(tmp, nb, (size_t) (ni + 1));
            tlen = ni;
        } else {
            int start2 = (tmp[0] == '-' || tmp[0] == '+' || tmp[0] == ' ') ? 1 : 0;
            int nsl = strip_tz(tmp + start2, tlen - start2, false);
            tlen = nsl + start2;
            tmp[tlen] = '\0';
        }
    }

    /* now apply width/padding */
    int start = (tmp[0] == '-' || tmp[0] == '+' || tmp[0] == ' ') ? 1 : 0;
    char sgn2 = (start ? tmp[0] : 0);
    int plen = tlen - start;
    int pad = (w > tlen) ? w - tlen : 0;
    if (!lj && !zp)
        while (pad-- > 0)
            ctx_putc(c, ' ');
    if (sgn2)
        ctx_putc(c, sgn2);
    if (!lj && zp)
        while (pad-- > 0)
            ctx_putc(c, '0');
    ctx_write(c, tmp + start, (size_t) plen);
    if (lj)
        while (pad-- > 0)
            ctx_putc(c, ' ');
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
    /* C99: %.0d with value 0 → empty (just padding) */
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
        int pad = w - (sc ? 1 : 0);
        if (!lj)
            while (pad-- > 0)
                ctx_putc(c, ' ');
        if (sc)
            ctx_putc(c, sc);
        if (lj)
            while (pad-- > 0)
                ctx_putc(c, ' ');
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

    int pp = (prec > 0 && (int) dl < prec) ? prec - (int) dl : 0;
    int nl = pl + pp + (int) dl;
    int pad = (w > nl) ? w - nl : 0;
    bool dozp = zp && prec < 0 && !lj;

    if (!lj && !dozp)
        while (pad-- > 0)
            ctx_putc(c, ' ');
    for (int i = 0; i < pl; i++)
        ctx_putc(c, pfx[i]);
    if (!lj && dozp)
        while (pad-- > 0)
            ctx_putc(c, '0');
    for (int i = 0; i < pp; i++)
        ctx_putc(c, '0');
    ctx_write(c, digs, dl);
    if (lj)
        while (pad-- > 0)
            ctx_putc(c, ' ');
}

/* ── Core engine ─────────────────────────────────────────────────────── */

typedef enum { LM_NONE, LM_HH, LM_H, LM_L, LM_LL, LM_Z, LM_T } LenMod;

int vsnprintf(char *buf, size_t size, const char *fmt, va_list ap)
{
    OutCtx ctx = {buf, size, 0};

    for (const char *p = fmt; *p; p++) {
        if (*p != '%') {
            ctx_putc(&ctx, *p);
            continue;
        }
        p++;

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
                w = -w;
            }
            p++;
        } else
            while (*p >= '0' && *p <= '9')
                w = w * 10 + (*p++ - '0');

        int prec = -1;
        if (*p == '.') {
            p++;
            prec = 0;
            if (*p == '*') {
                prec = va_arg(ap, int);
                if (prec < 0)
                    prec = -1;
                p++;
            } else
                while (*p >= '0' && *p <= '9')
                    prec = prec * 10 + (*p++ - '0');
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

        switch (*p) {
            case '%':
                ctx_putc(&ctx, '%');
                break;

            case 'c': {
                char ch = (char) va_arg(ap, int);
                int pad = w - 1;
                if (!fm)
                    while (pad-- > 0)
                        ctx_putc(&ctx, ' ');
                ctx_putc(&ctx, ch);
                if (fm)
                    while (pad-- > 0)
                        ctx_putc(&ctx, ' ');
                break;
            }
            case 's': {
                const char *s = va_arg(ap, const char *);
                if (!s)
                    s = "(null)";
                size_t sl = strlen(s);
                if (prec >= 0 && (size_t) prec < sl)
                    sl = (size_t) prec;
                int pad = (w > (int) sl) ? w - (int) sl : 0;
                if (!fm)
                    while (pad-- > 0)
                        ctx_putc(&ctx, ' ');
                ctx_write(&ctx, s, sl);
                if (fm)
                    while (pad-- > 0)
                        ctx_putc(&ctx, ' ');
                break;
            }
            case 'p': {
                void *ptr = va_arg(ap, void *);
                uintptr_t uv = (uintptr_t) ptr;
                char ib[IBUF];
                size_t dl;
                const char *digs = u64str((uint64_t) uv, 16, false, ib, &dl);
                int cont = 2 + (int) dl, pad = (w > cont) ? w - cont : 0;
                if (!fm)
                    while (pad-- > 0)
                        ctx_putc(&ctx, ' ');
                ctx_putc(&ctx, '0');
                ctx_putc(&ctx, 'x');
                ctx_write(&ctx, digs, dl);
                if (fm)
                    while (pad-- > 0)
                        ctx_putc(&ctx, ' ');
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
                do_f(&ctx, va_arg(ap, double), prec, fp, fsp, fh, w, fm, fz);
                break;
            case 'e':
            case 'E':
                do_e(&ctx, va_arg(ap, double), prec, fp, fsp, fh, w, fm, fz, *p == 'E');
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
