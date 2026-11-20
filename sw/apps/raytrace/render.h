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
 * Scene and renderer for the ray tracer, shared by the FROST program
 * (raytrace.c) and the host reference (host_reference.c).
 *
 * All arithmetic is 64-bit integer fixed point (16 fraction bits), so the
 * frame is bit for bit the same wherever it is computed: a host build gives
 * the reference CRC that the FROST program checks. Square roots come from a
 * reciprocal-square-root table refined by a Newton step (multiplies only).
 * The integer pipelines carry the whole computation; in FROST's FP unit,
 * square roots, comparisons and conversions run one at a time.
 *
 * The scene lives in its own header (scene_sunset.inc: two large spheres on a
 * tiled floor under a sunset, lit by one distant light with shadows, specular
 * highlights and up to three bounces); RT_SCENE_HEADER names another.
 * Colors are 8 bits a channel: the square root of the linear value (a gamma
 * curve), packed as 0xRRGGBB.
 */

#ifndef RAYTRACE_RENDER_H
#define RAYTRACE_RENDER_H

#include <stdint.h>

/* Fixed point: value = raw / 65536. */
typedef int64_t fx;
#define FX_SHIFT 16
#define FX_ONE ((fx) 1 << FX_SHIFT)
/* A constant written as a decimal fraction, rounded to the nearest raw value. */
#define FX(x) ((fx) ((x) * 65536.0 + ((x) < 0 ? -0.5 : 0.5)))

static inline fx fx_mul(fx a, fx b)
{
    return (a * b) >> FX_SHIFT;
}

typedef struct {
    fx x, y, z;
} vec3;

static inline vec3 v3(fx x, fx y, fx z)
{
    vec3 r = {x, y, z};
    return r;
}

static inline vec3 v_add(vec3 a, vec3 b)
{
    return v3(a.x + b.x, a.y + b.y, a.z + b.z);
}

static inline vec3 v_sub(vec3 a, vec3 b)
{
    return v3(a.x - b.x, a.y - b.y, a.z - b.z);
}

static inline vec3 v_scale(vec3 a, fx s)
{
    return v3(fx_mul(a.x, s), fx_mul(a.y, s), fx_mul(a.z, s));
}

static inline fx v_dot(vec3 a, vec3 b)
{
    return (a.x * b.x + a.y * b.y + a.z * b.z) >> FX_SHIFT;
}

static inline vec3 v_cross(vec3 a, vec3 b)
{
    return v3(fx_mul(a.y, b.z) - fx_mul(a.z, b.y),
              fx_mul(a.z, b.x) - fx_mul(a.x, b.z),
              fx_mul(a.x, b.y) - fx_mul(a.y, b.x));
}

/* 1/sqrt(m) at the middle of m = [1 + i / 64, 1 + (i + 1) / 64), in 30 fraction bits. */
static const int32_t rt_rsqrt_seed[192] = {
    1069571937, 1061375863, 1053365364, 1045533543, 1037873853, 1030380081, 1023046322, 1015866961,
    1008836655, 1001950318, 995203101,  988590382,  982107753,  975751001,  969516107,  963399225,
    957396679,  951504951,  945720673,  940040618,  934461692,  928980931,  923595489,  918302635,
    913099745,  907984300,  902953878,  898006148,  893138870,  888349887,  883637122,  878998575,
    874432318,  869936492,  865509306,  861149030,  856853995,  852622592,  848453263,  844344506,
    840294869,  836302947,  832367382,  828486860,  824660110,  820885902,  817163045,  813490383,
    809866800,  806291212,  802762568,  799279851,  795842072,  792448274,  789097526,  785788926,
    782521599,  779294692,  776107379,  772958857,  769848346,  766775087,  763738342,  760737394,
    757771545,  754840116,  751942447,  749077893,  746245831,  743445649,  740676754,  737938568,
    735230528,  732552083,  729902700,  727281856,  724689043,  722123764,  719585535,  717073885,
    714588353,  712128489,  709693855,  707284021,  704898571,  702537095,  700199195,  697884480,
    695592571,  693323095,  691075688,  688849996,  686645670,  684462372,  682299768,  680157534,
    678035353,  675932912,  673849909,  671786046,  669741030,  667714578,  665706409,  663716251,
    661743836,  659788901,  657851191,  655930453,  654026442,  652138916,  650267639,  648412378,
    646572906,  644749001,  642940445,  641147024,  639368526,  637604748,  635855486,  634120543,
    632399724,  630692839,  628999701,  627320126,  625653934,  624000948,  622360996,  620733905,
    619119510,  617517646,  615928151,  614350868,  612785640,  611232315,  609690743,  608160777,
    606642271,  605135082,  603639073,  602154103,  600680040,  599216749,  597764100,  596321965,
    594890217,  593468733,  592057391,  590656069,  589264652,  587883021,  586511063,  585148667,
    583795720,  582452115,  581117744,  579792502,  578476286,  577168993,  575870523,  574580778,
    573299660,  572027073,  570762923,  569507118,  568259565,  567020175,  565788860,  564565531,
    563350103,  562142492,  560942613,  559750385,  558565727,  557388559,  556218802,  555056379,
    553901213,  552753230,  551612356,  550478516,  549351640,  548231656,  547118494,  546012085,
    544912362,  543819257,  542732704,  541652637,  540578994,  539511710,  538450722,  537395969};

/* 1/sqrt(v) for v > 0 in fixed point. */
static inline fx fx_rsqrt(fx v)
{
    /* v = M * 4^j with M in [2^30, 2^32), so 1/sqrt(v / 2^16) = 2^-(7 + j) / sqrt(M / 2^30). */
    int msb = 63 - __builtin_clzll((uint64_t) v);
    int j = (msb - 30) >> 1;
    uint64_t m = j >= 0 ? (uint64_t) v >> (2 * j) : (uint64_t) v << (-2 * j);
    int64_t y = rt_rsqrt_seed[(m >> 24) - 64];
    /* One Newton step: the seed is within 0.4%, the result within 0.003%. */
    int64_t my2 = (int64_t) ((((int64_t) m * y) >> 30) * y >> 30);
    y = (y * ((3LL << 30) - my2)) >> 31;
    int s = 21 + j;
    return s >= 0 ? y >> s : y << -s;
}

static inline fx fx_sqrt(fx v)
{
    return v > 0 ? fx_mul(v, fx_rsqrt(v)) : 0;
}

static inline vec3 v_norm(vec3 a)
{
    return v_scale(a, fx_rsqrt(v_dot(a, a)));
}

typedef struct {
    vec3 center;
    fx radius;
    fx radius_sq;
    fx inv_radius;
    vec3 color;
    fx reflect; /* fraction of light from the mirror direction */
    fx shine;   /* specular highlight strength */
} sphere_t;

#define RT_EPSILON FX(0.002)
#define RT_OFFSET FX(0.002)
#define RT_FAR FX(500.0)

#define RT_SPHERE(cx, cy, cz, r, red, green, blue, refl, sh)                                       \
    {{FX(cx), FX(cy), FX(cz)},                                                                     \
     FX(r),                                                                                        \
     FX((r) * (r)),                                                                                \
     FX(1.0 / (r)),                                                                                \
     {FX(red), FX(green), FX(blue)},                                                               \
     FX(refl),                                                                                     \
     FX(sh)}

#ifndef RT_SCENE_HEADER
#define RT_SCENE_HEADER "scene_sunset.inc"
#endif
#include RT_SCENE_HEADER

typedef struct {
    vec3 eye, forward, right, up;
    vec3 light;
    int width, height;
    int samples;     /* rays per pixel: 1, 2 or 4 */
    fx quarter_step; /* a quarter pixel in screen units, with 16 extra fraction bits */
} rt_camera_t;

static inline void rt_setup(rt_camera_t *cam, int width, int height, int samples)
{
    vec3 look_at = RT_LOOK_AT;
    cam->eye = RT_EYE;
    cam->forward = v_norm(v_sub(look_at, cam->eye));
    cam->right = v_norm(v_cross(v3(0, FX_ONE, 0), cam->forward));
    cam->up = v_cross(cam->forward, cam->right);
    cam->light = v_norm(RT_LIGHT_DIR);
    cam->width = width;
    cam->height = height;
    cam->samples = samples;
    /* Half the screen height is 0.5, so a quarter pixel is 1 / (4 * height). */
    cam->quarter_step = (FX_ONE << 16) / (4 * height);
}

/* Nearest sphere hit along o + t d with t > RT_EPSILON; returns its index or -1. */
static inline int rt_hit_sphere(vec3 o, vec3 d, fx *t_out)
{
    int best = -1;
    fx best_t = *t_out;
    for (int i = 0; i < RT_NUM_SPHERES; i++) {
        vec3 oc = v_sub(o, rt_spheres[i].center);
        fx b = v_dot(oc, d);
        if (b > 0) {
            continue; /* moving away from the center, and o is outside */
        }
        fx c = v_dot(oc, oc) - rt_spheres[i].radius_sq;
        fx disc = fx_mul(b, b) - c;
        if (disc <= 0) {
            continue;
        }
        fx t = -b - fx_sqrt(disc);
        if (t > RT_EPSILON && t < best_t) {
            best_t = t;
            best = i;
        }
    }
    *t_out = best_t;
    return best;
}

/* True when a sphere blocks the light from point p. */
static inline int rt_shadowed(vec3 p, vec3 l)
{
    for (int i = 0; i < RT_NUM_SPHERES; i++) {
        vec3 oc = v_sub(p, rt_spheres[i].center);
        fx b = v_dot(oc, l);
        if (b > 0) {
            continue;
        }
        fx c = v_dot(oc, oc) - rt_spheres[i].radius_sq;
        if (fx_mul(b, b) - c > 0) {
            return 1;
        }
    }
    return 0;
}

static inline vec3 rt_sky(const rt_camera_t *cam, vec3 d)
{
    fx h = d.y < 0 ? 0 : d.y;
    /* Ease from the horizon colors towards the zenith. */
    vec3 c;
#if RT_SKY_THREE_STOPS
    fx q = fx_mul(h, 2 * FX_ONE - h);
    if (q < FX(0.5)) {
        fx w = 2 * q;
        c = v_add(v_scale(RT_SKY_HORIZON, FX_ONE - w), v_scale(RT_SKY_MIDDLE, w));
    } else {
        fx w = 2 * q - FX_ONE;
        c = v_add(v_scale(RT_SKY_MIDDLE, FX_ONE - w), v_scale(RT_SKY_ZENITH, w));
    }
#else
    fx k = fx_mul(h, 2 * FX_ONE - h);
    k = fx_mul(k, 2 * FX_ONE - k);
    c = v_add(v_scale(RT_SKY_HORIZON, FX_ONE - k), v_scale(RT_SKY_ZENITH, k));
#endif
    fx s = v_dot(d, cam->light);
    if (RT_SKY_GLOW && s > 0) {
        fx g = fx_mul(s, s);
        g = fx_mul(g, g);
        g = fx_mul(g, g);
        g = fx_mul(g, g); /* s^16: a soft glow around the light */
        fx g2 = fx_mul(g, g);
        g2 = fx_mul(g2, g2);
        g2 = fx_mul(g2, g2); /* s^128: the bright core */
        fx w = fx_mul(FX(0.35), g) + fx_mul(FX(0.6), g2);
        c = v_add(c, v3(w, w, fx_mul(FX(0.30), g) + fx_mul(FX(0.6), g2)));
    }
    return c;
}

static inline vec3 rt_trace(const rt_camera_t *cam, vec3 o, vec3 d)
{
    vec3 color = v3(0, 0, 0);
    fx weight = FX_ONE;
    for (int bounce = 0; bounce < RT_MAX_BOUNCES; bounce++) {
        fx t = RT_FAR;
        int id = rt_hit_sphere(o, d, &t);
        int on_floor = 0;
        if (d.y < -FX(0.002)) {
            fx tf = (-o.y * FX_ONE) / d.y;
            if (tf > RT_EPSILON && tf < t) {
                t = tf;
                id = -1;
                on_floor = 1;
            }
        }
        if (id < 0 && !on_floor) {
            color = v_add(color, v_scale(rt_sky(cam, d), weight));
            break;
        }

        vec3 p = v_add(o, v_scale(d, t));
        vec3 n, base;
        fx reflect, shine;
        if (on_floor) {
            n = v3(0, FX_ONE, 0);
            /* The arithmetic shift rounds towards minus infinity. */
            int64_t ix = p.x >> RT_TILE_SHIFT;
            int64_t iz = p.z >> RT_TILE_SHIFT;
            base = ((ix + iz) & 1) ? RT_TILE_DARK : RT_TILE_LIGHT;
            reflect = RT_FLOOR_REFLECT;
            shine = FX(0.3);
        } else {
            const sphere_t *s = &rt_spheres[id];
            n = v_scale(v_sub(p, s->center), s->inv_radius);
            base = s->color;
            reflect = s->reflect;
            shine = s->shine;
        }

        fx cos_in = v_dot(d, n);
        vec3 r = v_sub(d, v_scale(n, 2 * cos_in));
        vec3 p_off = v_add(p, v_scale(n, RT_OFFSET));

        fx diffuse = v_dot(n, cam->light);
        fx spec = 0;
        if (diffuse > 0 && !rt_shadowed(p_off, cam->light)) {
            fx rl = v_dot(r, cam->light);
            if (rl > 0) {
                fx h = fx_mul(rl, rl);
                h = fx_mul(h, h);
                h = fx_mul(h, h);
                h = fx_mul(h, h);
                h = fx_mul(h, h); /* rl^32 */
                spec = fx_mul(shine, h);
            }
        } else {
            diffuse = 0;
        }
        fx lit = RT_AMBIENT + fx_mul(FX_ONE - RT_AMBIENT, diffuse);
        vec3 local = v_add(v_scale(base, lit), v3(spec, spec, spec));

        if (on_floor) {
            /* Fade distant tiles into the horizon haze. */
            fx fog = (t * FX_ONE) / (t + RT_FOG_DISTANCE);
            local = v_add(v_scale(local, FX_ONE - fog), v_scale(RT_SKY_HORIZON, fog));
            reflect = fx_mul(reflect, FX_ONE - fog);
        }

        color = v_add(color, v_scale(local, fx_mul(weight, FX_ONE - reflect)));
        weight = fx_mul(weight, reflect);
        if (weight < FX(0.02)) {
            break;
        }
        o = p_off;
        d = r;
    }
    return color;
}

static uint32_t rt_crc_table[256];

static inline void rt_init_tables(void)
{
    for (uint32_t i = 0; i < 256; i++) {
        uint32_t c = i;
        for (int k = 0; k < 8; k++) {
            c = (c >> 1) ^ (0xEDB88320u & (0u - (c & 1u)));
        }
        rt_crc_table[i] = c;
    }
}

/* Gamma (square-root curve) and 8-bit quantization of a linear value. */
static inline uint32_t rt_quantize(fx c)
{
    if (c <= 0) {
        return 0;
    }
    if (c >= FX_ONE) {
        return 255;
    }
    fx v = (fx_sqrt(c) * 255 + (FX_ONE >> 1)) >> FX_SHIFT;
    return v > 255 ? 255 : (uint32_t) v;
}

/* Render pixel (x, y) and return it as 8-bit channels packed r:g:b. */
static inline uint32_t rt_pixel(const rt_camera_t *cam, int x, int y)
{
    /* Sample offsets within the pixel, in quarters: center, or a rotated grid. */
    static const int offsets[4][2] = {{1, 1}, {3, 3}, {3, 1}, {1, 3}};
    const int n = cam->samples;
    vec3 sum = v3(0, 0, 0);
    for (int s = 0; s < n; s++) {
        int ox = n == 1 ? 2 : offsets[s][0];
        int oy = n == 1 ? 2 : offsets[s][1];
        /* Sample position in quarter pixels from the screen center. */
        fx u = ((fx) (4 * x + ox - 2 * cam->width) * cam->quarter_step) >> 16;
        fx v = ((fx) (2 * cam->height - 4 * y - oy) * cam->quarter_step) >> 16;
        vec3 d = v_norm(v_add(cam->forward, v_add(v_scale(cam->right, u), v_scale(cam->up, v))));
        sum = v_add(sum, rt_trace(cam, cam->eye, d));
    }
    if (n == 2) {
        sum = v3(sum.x >> 1, sum.y >> 1, sum.z >> 1);
    } else if (n == 4) {
        sum = v3(sum.x >> 2, sum.y >> 2, sum.z >> 2);
    }
    return (rt_quantize(sum.x) << 16) | (rt_quantize(sum.y) << 8) | rt_quantize(sum.z);
}

/* CRC-32 (IEEE 802.3, reflected) over one pixel's three channel bytes. */
static inline uint32_t rt_crc_pixel(uint32_t crc, uint32_t rgb)
{
    crc = (crc >> 8) ^ rt_crc_table[(crc ^ ((rgb >> 16) & 255)) & 0xFF];
    crc = (crc >> 8) ^ rt_crc_table[(crc ^ ((rgb >> 8) & 255)) & 0xFF];
    crc = (crc >> 8) ^ rt_crc_table[(crc ^ (rgb & 255)) & 0xFF];
    return crc;
}

/* Base64 alphabet for the four-character pixel encoding (24 bits). */
static const char rt_digits[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

#endif /* RAYTRACE_RENDER_H */
