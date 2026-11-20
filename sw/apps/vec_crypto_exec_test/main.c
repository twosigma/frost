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

/* Crypto element groups through the committed engine. */
#include "../vec_common/vec_test.h"
#ifndef VEC_VLEN
#define VEC_VLEN 256
#endif
struct test_case {
    const char *name;
    unsigned vt, regs;
    const uint64_t *expected;
};
static unsigned long setvl(unsigned long avl, unsigned long vt)
{
    unsigned long vl;
    __asm__ volatile(".insn r 0x57, 7, 0x40, %0, %1, %2" : "=r"(vl) : "r"(avl), "r"(vt) : "memory");
    return vl;
}
/* Whole-register transfers keep the operand images independent of vl and SEW. */
struct register_images {
    uint64_t source[32][VEC_VLEN / 64];
    uint64_t result[2][VEC_VLEN / 64];
    uint64_t reference[2][VEC_VLEN / 64];
    uint64_t follower[2][VEC_VLEN / 64];
};
#ifdef VT_SPIKE
static volatile struct register_images backing __attribute__((aligned(64)));
static volatile struct register_images *const images = &backing;
#else
/* Vector loads and stores use the cached DDR scratch region. */
static volatile struct register_images *const images =
    (volatile struct register_images *) 0x83008400ul;
#endif

static void load_sources(void)
{
    /* vl8re8.v into v0, v8, v16 and v24. */
    __asm__ volatile(".insn r 0x07, 0, 0x71, x0,  %0, x8" ::"r"(images->source[0]) : "memory");
    __asm__ volatile(".insn r 0x07, 0, 0x71, x8,  %0, x8" ::"r"(images->source[8]) : "memory");
    __asm__ volatile(".insn r 0x07, 0, 0x71, x16, %0, x8" ::"r"(images->source[16]) : "memory");
    __asm__ volatile(".insn r 0x07, 0, 0x71, x24, %0, x8" ::"r"(images->source[24]) : "memory");
}

static void store_result(void)
{
    /* vs2r.v v16 writes v16 and v17, including the tail. */
    __asm__ volatile(".insn r 0x27, 0, 0x11, x16, %0, x8" ::"r"(images->result[0]) : "memory");
}

static void operation(unsigned k)
{
    register uint64_t a0 __asm__("a0") = 0x123456789abcdef0ull;
    switch (k) {
        case 0:
            __asm__ volatile(".word 0xa2802877" ::"r"(a0) : "memory");
            break;
        case 1:
            __asm__ volatile(".word 0xa6702877" ::"r"(a0) : "memory");
            break;
        case 2:
            __asm__ volatile(".word 0xa280a877" ::"r"(a0) : "memory");
            break;
        case 3:
            __asm__ volatile(".word 0xa670a877" ::"r"(a0) : "memory");
            break;
        case 4:
            __asm__ volatile(".word 0xa2812877" ::"r"(a0) : "memory");
            break;
        case 5:
            __asm__ volatile(".word 0xa6712877" ::"r"(a0) : "memory");
            break;
        case 6:
            __asm__ volatile(".word 0xa281a877" ::"r"(a0) : "memory");
            break;
        case 7:
            __asm__ volatile(".word 0xa671a877" ::"r"(a0) : "memory");
            break;
        case 8:
            __asm__ volatile(".word 0xa673a877" ::"r"(a0) : "memory");
            break;
        case 9:
            __asm__ volatile(".word 0x8a8fa877" ::"r"(a0) : "memory");
            break;
        case 10:
            __asm__ volatile(".word 0xaa802877" ::"r"(a0) : "memory");
            break;
        case 11:
            __asm__ volatile(".word 0xb68c2877" ::"r"(a0) : "memory");
            break;
        case 12:
            __asm__ volatile(".word 0xb68c2877" ::"r"(a0) : "memory");
            break;
        case 13:
            __asm__ volatile(".word 0xbe8c2877" ::"r"(a0) : "memory");
            break;
        case 14:
            __asm__ volatile(".word 0xbe8c2877" ::"r"(a0) : "memory");
            break;
        case 15:
            __asm__ volatile(".word 0xba8c2877" ::"r"(a0) : "memory");
            break;
        case 16:
            __asm__ volatile(".word 0xba8c2877" ::"r"(a0) : "memory");
            break;
        case 17:
            __asm__ volatile(".word 0xb28c2877" ::"r"(a0) : "memory");
            break;
        case 18:
            __asm__ volatile(".word 0xa288a877" ::"r"(a0) : "memory");
            break;
        case 19:
            __asm__ volatile(".word 0x328c2857" ::"r"(a0) : "memory");
            break;
        case 20:
            __asm__ volatile(".word 0x30856857" ::"r"(a0) : "memory");
            break;
        case 21:
            __asm__ volatile(".word 0x368c2857" ::"r"(a0) : "memory");
            break;
        case 22:
            __asm__ volatile(".word 0x34856857" ::"r"(a0) : "memory");
            break;
    }
}
#if VEC_VLEN == 128
static const uint64_t expected_0[] = {
    0x780b52a7dc46bd37ull, 0x780b52a7dc46bd37ull, 0x25fe45f71e52565eull, 0x25fe45f71e52565eull};
static const uint64_t expected_1[] = {0x5138739866767f43ull, 0x5138739866767f43ull};
static const uint64_t expected_2[] = {0x5b6b66d001794028ull, 0x5b6b66d001794028ull};
static const uint64_t expected_3[] = {
    0x5a6867d7007a4117ull, 0x5a6867d7007a4117ull, 0xf13847e7d88c0434ull, 0xf13847e7d88c0434ull};
static const uint64_t expected_4[] = {0xe075d40e39411772ull, 0xe075d40e39411772ull};
static const uint64_t expected_5[] = {0xe176d5093842164dull, 0xe176d5093842164dull};
static const uint64_t expected_6[] = {
    0x5c69651f2c0a407bull, 0x5c69651f2c0a407bull, 0xc4970d10e17942ffull, 0xc4970d10e17942ffull};
static const uint64_t expected_7[] = {0x5d6a64182d094144ull, 0x5d6a64182d094144ull};
static const uint64_t expected_8[] = {0x19fb193f197b1937ull, 0x19fb193f197b1937ull};
static const uint64_t expected_9[] = {
    0x6e637e83e71915dfull, 0x4aa7da3fc3ddb163ull, 0x68ba9dace2c1f1f1ull, 0x4c7e2110c6054d4dull};
static const uint64_t expected_10[] = {0x6ee37efbff610d9full, 0x4aa7da77db25a913ull};
static const uint64_t expected_11[] = {0x24687ad13b34ed17ull, 0xe8a18f07723369f5ull};
static const uint64_t expected_12[] = {
    0xe6a09bb689cc582aull, 0x68241d3e0948dcbcull, 0xfc90238062736ef5ull, 0x2c4c9f6659846531ull};
static const uint64_t expected_13[] = {0xeb09a20e679853c4ull, 0x9550fac0cca38a61ull};
static const uint64_t expected_14[] = {
    0x79b7b784b03d914aull, 0x2a2e350f6eeb97c3ull, 0xacbf34fdae727157ull, 0x9a0d9ad4f6698c47ull};
static const uint64_t expected_15[] = {
    0xeb09a20e679853c4ull, 0x9550fac0cca38a61ull, 0x1facb46687496f3dull, 0xf1f8fc294901099eull};
static const uint64_t expected_16[] = {
    0x7ab8b885b13e924bull, 0xf7737a9ac2a8568bull, 0xadc035feaf737258ull, 0x9120928b00c92181ull};
static const uint64_t expected_17[] = {0x84817e21cf72ef35ull, 0x1d4c370e04fce665ull};
static const uint64_t expected_18[] = {
    0x5435c85720b30cd5ull, 0xc76ab4ef47709e8bull, 0x91d3aff666af60f6ull, 0xbc12e2e15538cf72ull};
static const uint64_t expected_19[] = {0x3c26d73d9d47aa00ull, 0x3c26d73d9d47aa00ull};
static const uint64_t expected_20[] = {0x91827364b5c6d7e8ull, 0x91827364b5c6d7e8ull};
static const uint64_t expected_21[] = {
    0x48a9e03b6f4e7d90ull, 0x48a9e03b6f4e7d90ull, 0x489de088efea6de5ull, 0x489de088efea6de5ull};
static const uint64_t expected_22[] = {0x91827364b5c6d7e8ull, 0x91827364b5c6d7e8ull};
static const struct test_case cases[] = {
    {"DM", 17, 2, expected_0},      {"DM", 16, 1, expected_1},      {"DF", 16, 1, expected_2},
    {"DF", 17, 2, expected_3},      {"EM", 16, 1, expected_4},      {"EM", 16, 1, expected_5},
    {"EF", 17, 2, expected_6},      {"EF", 16, 1, expected_7},      {"Z", 16, 1, expected_8},
    {"KF1", 17, 2, expected_9},     {"KF2", 16, 1, expected_10},    {"MS", 16, 1, expected_11},
    {"MS", 25, 2, expected_12},     {"CL", 16, 1, expected_13},     {"CL", 25, 2, expected_14},
    {"CH", 17, 2, expected_15},     {"CH", 25, 2, expected_16},     {"GHSH", 16, 1, expected_17},
    {"GMUL", 17, 2, expected_18},   {"clmul", 24, 1, expected_19},  {"clmul", 24, 1, expected_20},
    {"clmulh", 25, 2, expected_21}, {"clmulh", 24, 1, expected_22},
};
#endif
#if VEC_VLEN == 256
static const uint64_t expected_0[] = {0x780b52a7dc46bd37ull,
                                      0x780b52a7dc46bd37ull,
                                      0x780b52a7dc46bd37ull,
                                      0x780b52a7dc46bd37ull,
                                      0x25fe45f71e52565eull,
                                      0x25fe45f71e52565eull,
                                      0x25fe45f71e52565eull,
                                      0x25fe45f71e52565eull};
static const uint64_t expected_1[] = {
    0x5138739866767f43ull, 0x5138739866767f43ull, 0x5138739866767f43ull, 0x5138739866767f43ull};
static const uint64_t expected_2[] = {
    0x5b6b66d001794028ull, 0x5b6b66d001794028ull, 0x5b6b66d001794028ull, 0x5b6b66d001794028ull};
static const uint64_t expected_3[] = {0x5a6867d7007a4117ull,
                                      0x5a6867d7007a4117ull,
                                      0x5a6867d7007a4117ull,
                                      0x5a6867d7007a4117ull,
                                      0xf13847e7d88c0434ull,
                                      0xf13847e7d88c0434ull,
                                      0xf13847e7d88c0434ull,
                                      0xf13847e7d88c0434ull};
static const uint64_t expected_4[] = {
    0xe075d40e39411772ull, 0xe075d40e39411772ull, 0xe075d40e39411772ull, 0xe075d40e39411772ull};
static const uint64_t expected_5[] = {
    0xe176d5093842164dull, 0xe176d5093842164dull, 0xe176d5093842164dull, 0xe176d5093842164dull};
static const uint64_t expected_6[] = {0x5c69651f2c0a407bull,
                                      0x5c69651f2c0a407bull,
                                      0x5c69651f2c0a407bull,
                                      0x5c69651f2c0a407bull,
                                      0xc4970d10e17942ffull,
                                      0xc4970d10e17942ffull,
                                      0xc4970d10e17942ffull,
                                      0xc4970d10e17942ffull};
static const uint64_t expected_7[] = {
    0x5d6a64182d094144ull, 0x5d6a64182d094144ull, 0x5d6a64182d094144ull, 0x5d6a64182d094144ull};
static const uint64_t expected_8[] = {
    0x19fb193f197b1937ull, 0x19fb193f197b1937ull, 0x19fb193f197b1937ull, 0x19fb193f197b1937ull};
static const uint64_t expected_9[] = {0x6e637e83e71915dfull,
                                      0x4aa7da3fc3ddb163ull,
                                      0x6e637e83e71915dfull,
                                      0x4aa7da3fc3ddb163ull,
                                      0x68ba9dace2c1f1f1ull,
                                      0x4c7e2110c6054d4dull,
                                      0x68ba9dace2c1f1f1ull,
                                      0x4c7e2110c6054d4dull};
static const uint64_t expected_10[] = {
    0x6ee37efbff610d9full, 0x4aa7da77db25a913ull, 0x6ee37efbff610d9full, 0x4aa7da77db25a913ull};
static const uint64_t expected_11[] = {
    0x24687ad13b34ed17ull, 0xe8a18f07723369f5ull, 0x24687ad13b34ed17ull, 0xe8a18f07723369f5ull};
static const uint64_t expected_12[] = {0xd23c7fa26eaf1b96ull,
                                       0xd23c7fa26eaf1b96ull,
                                       0x2e4a7493cdf8f561ull,
                                       0x420d808f99f58985ull,
                                       0x69251e3f0a49ddbdull,
                                       0x69251e3f0a49ddbdull,
                                       0xb230e915e8e079bbull,
                                       0xc5edf511b4e40dafull};
static const uint64_t expected_13[] = {
    0xeb09a20e679853c4ull, 0x9550fac0cca38a61ull, 0xeb09a20e679853c4ull, 0x9550fac0cca38a61ull};
static const uint64_t expected_14[] = {0x78b6b683af3c9049ull,
                                       0x6ae9f0522a2d6c06ull,
                                       0xba86deeb1c1f640cull,
                                       0x33ab8f4ac1deb8b4ull,
                                       0xf3f6f65206045892ull,
                                       0xa77a42a108c4c68full,
                                       0x26fe73cb0439389full,
                                       0xb407f03d98d21b2cull};
static const uint64_t expected_15[] = {0xeb09a20e679853c4ull,
                                       0x9550fac0cca38a61ull,
                                       0xeb09a20e679853c4ull,
                                       0x9550fac0cca38a61ull,
                                       0x1facb46687496f3dull,
                                       0xf1f8fc294901099eull,
                                       0x1facb46687496f3dull,
                                       0xf1f8fc294901099eull};
static const uint64_t expected_16[] = {0x78b6b683af3c9049ull,
                                       0x6ae9f0522a2d6c06ull,
                                       0xba86deeb1c1f640cull,
                                       0x33ab8f4ac1deb8b4ull,
                                       0xf3f6f65206045892ull,
                                       0xa77a42a108c4c68full,
                                       0x26fe73cb0439389full,
                                       0xb407f03d98d21b2cull};
static const uint64_t expected_17[] = {
    0x84817e21cf72ef35ull, 0x1d4c370e04fce665ull, 0x84817e21cf72ef35ull, 0x1d4c370e04fce665ull};
static const uint64_t expected_18[] = {0x5435c85720b30cd5ull,
                                       0xc76ab4ef47709e8bull,
                                       0x5435c85720b30cd5ull,
                                       0xc76ab4ef47709e8bull,
                                       0x91d3aff666af60f6ull,
                                       0xbc12e2e15538cf72ull,
                                       0x91d3aff666af60f6ull,
                                       0xbc12e2e15538cf72ull};
static const uint64_t expected_19[] = {
    0x3c26d73d9d47aa00ull, 0x3c26d73d9d47aa00ull, 0x3c26d73d9d47aa00ull, 0x3c26d73d9d47aa00ull};
static const uint64_t expected_20[] = {
    0x91827364b5c6d7e8ull, 0x91827364b5c6d7e8ull, 0x91827364b5c6d7e8ull, 0x91539378e6484a00ull};
static const uint64_t expected_21[] = {0x48a9e03b6f4e7d90ull,
                                       0x48a9e03b6f4e7d90ull,
                                       0x48a9e03b6f4e7d90ull,
                                       0x48a9e03b6f4e7d90ull,
                                       0x489de088efea6de5ull,
                                       0x489de088efea6de5ull,
                                       0x489de088efea6de5ull,
                                       0x489de088efea6de5ull};
static const uint64_t expected_22[] = {
    0x91827364b5c6d7e8ull, 0x91827364b5c6d7e8ull, 0x91827364b5c6d7e8ull, 0x099ee6a0c53e8463ull};
static const struct test_case cases[] = {
    {"DM", 17, 2, expected_0},      {"DM", 16, 1, expected_1},      {"DF", 16, 1, expected_2},
    {"DF", 17, 2, expected_3},      {"EM", 16, 1, expected_4},      {"EM", 16, 1, expected_5},
    {"EF", 17, 2, expected_6},      {"EF", 16, 1, expected_7},      {"Z", 16, 1, expected_8},
    {"KF1", 17, 2, expected_9},     {"KF2", 16, 1, expected_10},    {"MS", 16, 1, expected_11},
    {"MS", 25, 2, expected_12},     {"CL", 16, 1, expected_13},     {"CL", 25, 2, expected_14},
    {"CH", 17, 2, expected_15},     {"CH", 25, 2, expected_16},     {"GHSH", 16, 1, expected_17},
    {"GMUL", 17, 2, expected_18},   {"clmul", 24, 1, expected_19},  {"clmul", 24, 1, expected_20},
    {"clmulh", 25, 2, expected_21}, {"clmulh", 24, 1, expected_22},
};
#endif
#if VEC_VLEN == 512
static const uint64_t expected_0[] = {0x780b52a7dc46bd37ull,
                                      0x780b52a7dc46bd37ull,
                                      0x780b52a7dc46bd37ull,
                                      0x780b52a7dc46bd37ull,
                                      0x780b52a7dc46bd37ull,
                                      0x780b52a7dc46bd37ull,
                                      0x780b52a7dc46bd37ull,
                                      0x780b52a7dc46bd37ull,
                                      0x25fe45f71e52565eull,
                                      0x25fe45f71e52565eull,
                                      0x25fe45f71e52565eull,
                                      0x25fe45f71e52565eull,
                                      0x25fe45f71e52565eull,
                                      0x25fe45f71e52565eull,
                                      0x25fe45f71e52565eull,
                                      0x25fe45f71e52565eull};
static const uint64_t expected_1[] = {0x5138739866767f43ull,
                                      0x5138739866767f43ull,
                                      0x5138739866767f43ull,
                                      0x5138739866767f43ull,
                                      0x5138739866767f43ull,
                                      0x5138739866767f43ull,
                                      0x5138739866767f43ull,
                                      0x5138739866767f43ull};
static const uint64_t expected_2[] = {0x5b6b66d001794028ull,
                                      0x5b6b66d001794028ull,
                                      0x5b6b66d001794028ull,
                                      0x5b6b66d001794028ull,
                                      0x5b6b66d001794028ull,
                                      0x5b6b66d001794028ull,
                                      0x5b6b66d001794028ull,
                                      0x5b6b66d001794028ull};
static const uint64_t expected_3[] = {0x5a6867d7007a4117ull,
                                      0x5a6867d7007a4117ull,
                                      0x5a6867d7007a4117ull,
                                      0x5a6867d7007a4117ull,
                                      0x5a6867d7007a4117ull,
                                      0x5a6867d7007a4117ull,
                                      0x5a6867d7007a4117ull,
                                      0x5a6867d7007a4117ull,
                                      0xf13847e7d88c0434ull,
                                      0xf13847e7d88c0434ull,
                                      0xf13847e7d88c0434ull,
                                      0xf13847e7d88c0434ull,
                                      0xf13847e7d88c0434ull,
                                      0xf13847e7d88c0434ull,
                                      0xf13847e7d88c0434ull,
                                      0xf13847e7d88c0434ull};
static const uint64_t expected_4[] = {0xe075d40e39411772ull,
                                      0xe075d40e39411772ull,
                                      0xe075d40e39411772ull,
                                      0xe075d40e39411772ull,
                                      0xe075d40e39411772ull,
                                      0xe075d40e39411772ull,
                                      0xe075d40e39411772ull,
                                      0xe075d40e39411772ull};
static const uint64_t expected_5[] = {0xe176d5093842164dull,
                                      0xe176d5093842164dull,
                                      0xe176d5093842164dull,
                                      0xe176d5093842164dull,
                                      0xe176d5093842164dull,
                                      0xe176d5093842164dull,
                                      0xe176d5093842164dull,
                                      0xe176d5093842164dull};
static const uint64_t expected_6[] = {0x5c69651f2c0a407bull,
                                      0x5c69651f2c0a407bull,
                                      0x5c69651f2c0a407bull,
                                      0x5c69651f2c0a407bull,
                                      0x5c69651f2c0a407bull,
                                      0x5c69651f2c0a407bull,
                                      0x5c69651f2c0a407bull,
                                      0x5c69651f2c0a407bull,
                                      0xc4970d10e17942ffull,
                                      0xc4970d10e17942ffull,
                                      0xc4970d10e17942ffull,
                                      0xc4970d10e17942ffull,
                                      0xc4970d10e17942ffull,
                                      0xc4970d10e17942ffull,
                                      0xc4970d10e17942ffull,
                                      0xc4970d10e17942ffull};
static const uint64_t expected_7[] = {0x5d6a64182d094144ull,
                                      0x5d6a64182d094144ull,
                                      0x5d6a64182d094144ull,
                                      0x5d6a64182d094144ull,
                                      0x5d6a64182d094144ull,
                                      0x5d6a64182d094144ull,
                                      0x5d6a64182d094144ull,
                                      0x5d6a64182d094144ull};
static const uint64_t expected_8[] = {0x19fb193f197b1937ull,
                                      0x19fb193f197b1937ull,
                                      0x19fb193f197b1937ull,
                                      0x19fb193f197b1937ull,
                                      0x19fb193f197b1937ull,
                                      0x19fb193f197b1937ull,
                                      0x19fb193f197b1937ull,
                                      0x19fb193f197b1937ull};
static const uint64_t expected_9[] = {0x6e637e83e71915dfull,
                                      0x4aa7da3fc3ddb163ull,
                                      0x6e637e83e71915dfull,
                                      0x4aa7da3fc3ddb163ull,
                                      0x6e637e83e71915dfull,
                                      0x4aa7da3fc3ddb163ull,
                                      0x6e637e83e71915dfull,
                                      0x4aa7da3fc3ddb163ull,
                                      0x68ba9dace2c1f1f1ull,
                                      0x4c7e2110c6054d4dull,
                                      0x68ba9dace2c1f1f1ull,
                                      0x4c7e2110c6054d4dull,
                                      0x68ba9dace2c1f1f1ull,
                                      0x4c7e2110c6054d4dull,
                                      0x68ba9dace2c1f1f1ull,
                                      0x4c7e2110c6054d4dull};
static const uint64_t expected_10[] = {0x6ee37efbff610d9full,
                                       0x4aa7da77db25a913ull,
                                       0x6ee37efbff610d9full,
                                       0x4aa7da77db25a913ull,
                                       0x6ee37efbff610d9full,
                                       0x4aa7da77db25a913ull,
                                       0x6ee37efbff610d9full,
                                       0x4aa7da77db25a913ull};
static const uint64_t expected_11[] = {0x24687ad13b34ed17ull,
                                       0xe8a18f07723369f5ull,
                                       0x24687ad13b34ed17ull,
                                       0xe8a18f07723369f5ull,
                                       0x24687ad13b34ed17ull,
                                       0xe8a18f07723369f5ull,
                                       0x24687ad13b34ed17ull,
                                       0xe8a18f07723369f5ull};
static const uint64_t expected_12[] = {0xd23c7fa26eaf1b96ull,
                                       0xd23c7fa26eaf1b96ull,
                                       0x2e4a7493cdf8f561ull,
                                       0x420d808f99f58985ull,
                                       0xd23c7fa26eaf1b96ull,
                                       0xd23c7fa26eaf1b96ull,
                                       0x2e4a7493cdf8f561ull,
                                       0x420d808f99f58985ull,
                                       0x69251e3f0a49ddbdull,
                                       0x69251e3f0a49ddbdull,
                                       0xb230e915e8e079bbull,
                                       0xc5edf511b4e40dafull,
                                       0x69251e3f0a49ddbdull,
                                       0x69251e3f0a49ddbdull,
                                       0xb230e915e8e079bbull,
                                       0xc5edf511b4e40dafull};
static const uint64_t expected_13[] = {0xeb09a20e679853c4ull,
                                       0x9550fac0cca38a61ull,
                                       0xeb09a20e679853c4ull,
                                       0x9550fac0cca38a61ull,
                                       0xeb09a20e679853c4ull,
                                       0x9550fac0cca38a61ull,
                                       0xeb09a20e679853c4ull,
                                       0x9550fac0cca38a61ull};
static const uint64_t expected_14[] = {0x78b6b683af3c9049ull,
                                       0x6ae9f0522a2d6c06ull,
                                       0xba86deeb1c1f640cull,
                                       0x33ab8f4ac1deb8b4ull,
                                       0x78b6b683af3c9049ull,
                                       0x6ae9f0522a2d6c06ull,
                                       0xba86deeb1c1f640cull,
                                       0x33ab8f4ac1deb8b4ull,
                                       0xf3f6f65206045892ull,
                                       0xa77a42a108c4c68full,
                                       0x26fe73cb0439389full,
                                       0xb407f03d98d21b2cull,
                                       0xf3f6f65206045892ull,
                                       0xa77a42a108c4c68full,
                                       0x26fe73cb0439389full,
                                       0xb407f03d98d21b2cull};
static const uint64_t expected_15[] = {0xeb09a20e679853c4ull,
                                       0x9550fac0cca38a61ull,
                                       0xeb09a20e679853c4ull,
                                       0x9550fac0cca38a61ull,
                                       0xeb09a20e679853c4ull,
                                       0x9550fac0cca38a61ull,
                                       0xeb09a20e679853c4ull,
                                       0x9550fac0cca38a61ull,
                                       0x1facb46687496f3dull,
                                       0xf1f8fc294901099eull,
                                       0x1facb46687496f3dull,
                                       0xf1f8fc294901099eull,
                                       0x1facb46687496f3dull,
                                       0xf1f8fc294901099eull,
                                       0x1facb46687496f3dull,
                                       0xf1f8fc294901099eull};
static const uint64_t expected_16[] = {0x78b6b683af3c9049ull,
                                       0x6ae9f0522a2d6c06ull,
                                       0xba86deeb1c1f640cull,
                                       0x33ab8f4ac1deb8b4ull,
                                       0x78b6b683af3c9049ull,
                                       0x6ae9f0522a2d6c06ull,
                                       0xba86deeb1c1f640cull,
                                       0x33ab8f4ac1deb8b4ull,
                                       0xf3f6f65206045892ull,
                                       0xa77a42a108c4c68full,
                                       0x26fe73cb0439389full,
                                       0xb407f03d98d21b2cull,
                                       0xf3f6f65206045892ull,
                                       0xa77a42a108c4c68full,
                                       0x26fe73cb0439389full,
                                       0xb407f03d98d21b2cull};
static const uint64_t expected_17[] = {0x84817e21cf72ef35ull,
                                       0x1d4c370e04fce665ull,
                                       0x84817e21cf72ef35ull,
                                       0x1d4c370e04fce665ull,
                                       0x84817e21cf72ef35ull,
                                       0x1d4c370e04fce665ull,
                                       0x84817e21cf72ef35ull,
                                       0x1d4c370e04fce665ull};
static const uint64_t expected_18[] = {0x5435c85720b30cd5ull,
                                       0xc76ab4ef47709e8bull,
                                       0x5435c85720b30cd5ull,
                                       0xc76ab4ef47709e8bull,
                                       0x5435c85720b30cd5ull,
                                       0xc76ab4ef47709e8bull,
                                       0x5435c85720b30cd5ull,
                                       0xc76ab4ef47709e8bull,
                                       0x91d3aff666af60f6ull,
                                       0xbc12e2e15538cf72ull,
                                       0x91d3aff666af60f6ull,
                                       0xbc12e2e15538cf72ull,
                                       0x91d3aff666af60f6ull,
                                       0xbc12e2e15538cf72ull,
                                       0x91d3aff666af60f6ull,
                                       0xbc12e2e15538cf72ull};
static const uint64_t expected_19[] = {0x3c26d73d9d47aa00ull,
                                       0x3c26d73d9d47aa00ull,
                                       0x3c26d73d9d47aa00ull,
                                       0x3c26d73d9d47aa00ull,
                                       0x3c26d73d9d47aa00ull,
                                       0x3c26d73d9d47aa00ull,
                                       0x3c26d73d9d47aa00ull,
                                       0x3c26d73d9d47aa00ull};
static const uint64_t expected_20[] = {0x91827364b5c6d7e8ull,
                                       0x91827364b5c6d7e8ull,
                                       0x91827364b5c6d7e8ull,
                                       0x91539378e6484a00ull,
                                       0x91539378e6484a00ull,
                                       0x91827364b5c6d7e8ull,
                                       0x91539378e6484a00ull,
                                       0x91539378e6484a00ull};
static const uint64_t expected_21[] = {0x48a9e03b6f4e7d90ull,
                                       0x48a9e03b6f4e7d90ull,
                                       0x48a9e03b6f4e7d90ull,
                                       0x48a9e03b6f4e7d90ull,
                                       0x48a9e03b6f4e7d90ull,
                                       0x48a9e03b6f4e7d90ull,
                                       0x48a9e03b6f4e7d90ull,
                                       0x48a9e03b6f4e7d90ull,
                                       0x489de088efea6de5ull,
                                       0x489de088efea6de5ull,
                                       0x489de088efea6de5ull,
                                       0x489de088efea6de5ull,
                                       0x489de088efea6de5ull,
                                       0x489de088efea6de5ull,
                                       0x489de088efea6de5ull,
                                       0x489de088efea6de5ull};
static const uint64_t expected_22[] = {0x91827364b5c6d7e8ull,
                                       0x91827364b5c6d7e8ull,
                                       0x91827364b5c6d7e8ull,
                                       0x099ee6a0c53e8463ull,
                                       0x099ee6a0c53e8463ull,
                                       0x91827364b5c6d7e8ull,
                                       0x099ee6a0c53e8463ull,
                                       0x099ee6a0c53e8463ull};
static const struct test_case cases[] = {
    {"DM", 17, 2, expected_0},      {"DM", 16, 1, expected_1},      {"DF", 16, 1, expected_2},
    {"DF", 17, 2, expected_3},      {"EM", 16, 1, expected_4},      {"EM", 16, 1, expected_5},
    {"EF", 17, 2, expected_6},      {"EF", 16, 1, expected_7},      {"Z", 16, 1, expected_8},
    {"KF1", 17, 2, expected_9},     {"KF2", 16, 1, expected_10},    {"MS", 16, 1, expected_11},
    {"MS", 25, 2, expected_12},     {"CL", 16, 1, expected_13},     {"CL", 25, 2, expected_14},
    {"CH", 17, 2, expected_15},     {"CH", 25, 2, expected_16},     {"GHSH", 16, 1, expected_17},
    {"GMUL", 17, 2, expected_18},   {"clmul", 24, 1, expected_19},  {"clmul", 24, 1, expected_20},
    {"clmulh", 25, 2, expected_21}, {"clmulh", 24, 1, expected_22},
};
#endif

#define OPV(f, m, a, b, t, d)                                                                      \
    (((uint32_t) (f) << 26) | ((m) << 25) | ((a) << 20) | ((b) << 15) | ((t) << 12) | ((d) << 7) | \
     0x57)
#define EMIT(word) __asm__ volatile(".word %0" ::"i"(word) : "memory")
#define ILLEGAL(word)                                                                              \
    do {                                                                                           \
        unsigned long fault_pc;                                                                    \
        vt_trap_clear();                                                                           \
        __asm__ volatile("lla %0, 1f\n1: .word %1" : "=r"(fault_pc) : "i"(word) : "memory");       \
        VT_EQ(vt_trap_count, 1, "reserved form traps");                                            \
        VT_EQ(vt_trap_cause, 2, "illegal-instruction cause");                                      \
        VT_EQ(vt_trap_tval, word, "illegal instruction word");                                     \
        VT_EQ(vt_trap_epc, fault_pc, "faulting instruction address");                              \
    } while (0)

#define OPG(f, a, b, d) (OPV(f, 1, a, b, 2, d) | 0x20u)
static void special_cases(void)
{
#ifndef VT_SPIKE
    /* The pinned reference reserves nonzero arithmetic vstart values. */
    const uint64_t initial = 0xaaaabbbbccccddddull;
    const uint64_t key = 0x1111222233334444ull;
    setvl(~0ul, 24);
    for (unsigned w = 0; w < VEC_VLEN / 64; w++) {
        images->source[8][w] = key;
        images->source[16][w] = initial;
        images->source[17][w] = initial;
    }
    load_sources();
    setvl(8, 16 | (VEC_VLEN == 128 ? 1 : 0));
    VT_CSR_WRITE(vstart, 4);
    EMIT(OPG(0x29, 8, 7, 16));
    VT_EQ(vt_trap_count, 0, "valid group restart does not trap");
    VT_EQ(VT_CSR_READ(vstart), 0, "group restart clears vstart");
    setvl(~0ul, 24);
    store_result();
    for (unsigned w = 0; w < (VEC_VLEN == 128 ? 4u : VEC_VLEN / 64u); w++) {
        uint64_t value = images->result[w / (VEC_VLEN / 64)][w % (VEC_VLEN / 64)];
        VT_EQ(value,
              w >= 2 && w < 4 ? initial ^ key : initial,
              "group restart preserves prefix and tail");
    }
    /* vclmul.vx at vstart=1. Multiplication by x is a one-bit shift. */
    load_sources();
    setvl(2, 24);
    VT_CSR_WRITE(vstart, 1);
    register uint64_t factor __asm__("a0") = 2;
    __asm__ volatile(".word %0" ::"i"(OPV(12, 1, 8, 10, 6, 16)), "r"(factor) : "memory");
    VT_EQ(VT_CSR_READ(vstart), 0, "carry-less multiply clears vstart");
    store_result();
    VT_EQ(images->result[0][0], initial, "carry-less multiply preserves prefix");
    VT_EQ(images->result[0][1], key << 1, "scalar carry-less multiply restarts");
    load_sources();
    setvl(4, 16);
    VT_CSR_WRITE(vstart, 4);
    EMIT(OPG(0x29, 8, 7, 16));
    VT_EQ(VT_CSR_READ(vstart), 0, "empty group restart clears vstart");
    store_result();
    for (unsigned w = 0; w < VEC_VLEN / 64; w++)
        VT_EQ(images->result[0][w], initial, "empty group restart preserves destination");
    VT_EQ(vt_trap_count, 0, "legal restarts complete");
#endif
    setvl(1, 16);
    load_sources();
    ILLEGAL(OPG(0x28, 8, 2, 16));
    store_result();
    for (unsigned w = 0; w < VEC_VLEN / 64; w++)
        VT_EQ(images->result[0][w], images->source[16][w], "partial group preserves destination");
    setvl(4, 16);
    VT_CSR_WRITE(vstart, 1);
    ILLEGAL(OPG(0x28, 8, 2, 16));
    VT_EQ(vt_trap_vstart, 1, "group restart must be a multiple of four");
    ILLEGAL(OPG(0x28, 8, 2, 16) & ~(1u << 25));
    ILLEGAL(OPG(0x29, 16, 2, 16));     /* Scalar key overlaps destination. */
    ILLEGAL(OPG(0x2d, 8, 16, 16));     /* SHA destination overlaps source. */
    ILLEGAL(OPV(12, 1, 8, 24, 2, 16)); /* Zvbc requires SEW64. */
    setvl(~0ul, 24);
#ifndef VT_SPIKE
    ILLEGAL(OPV(12, 0, 0, 24, 2, 16)); /* Mask/data source EEWs differ. */
#endif
    ILLEGAL(OPV(12, 0, 8, 24, 2, 0)); /* A masked destination cannot be v0. */
    setvl(~0ul, 8);
    ILLEGAL(OPG(0x28, 8, 2, 16)); /* AES requires SEW32. */
#if VEC_VLEN == 128
    setvl(0, 0x17); /* e32,mf2: group capacity is only 64 bits, even at vl=0. */
    ILLEGAL(OPG(0x28, 8, 2, 16));
    setvl(0, 24); /* SHA512 requires LMUL2 at VLEN128. */
    ILLEGAL(OPG(0x2d, 8, 24, 16));
#endif
    vt_trap_clear();
    setvl(4, 16);
    load_sources();
    const uint64_t xor_word = images->source[16][0] ^ images->source[8][0];
    unsigned long status = VT_CSR_READ(mstatus);
    VT_CSR_WRITE(mstatus, status & ~VT_MSTATUS_FS);
    EMIT(OPG(0x29, 8, 7, 16));
    VT_EQ(VT_CSR_READ(mstatus) & VT_MSTATUS_FS, 0, "crypto does not dirty FS");
    VT_CSR_WRITE(mstatus, status);
    VT_EQ(vt_trap_count, 0, "crypto executes with FS off");
    store_result();
    VT_EQ(images->result[0][0], xor_word, "FS-off AES writes its round result");
    VT_CSR_WRITE(mstatus, status & ~VT_MSTATUS_VS);
    ILLEGAL(OPG(0x29, 8, 7, 16));
    VT_CSR_WRITE(mstatus, status);
    setvl(2, 24);
    VT_CSR_WRITE(mstatus, status & ~VT_MSTATUS_VS);
    ILLEGAL(OPV(12, 1, 8, 24, 2, 16));
    VT_EQ(VT_CSR_READ(mstatus) & VT_MSTATUS_VS, 0, "VS stays off after an illegal instruction");
    VT_CSR_WRITE(mstatus, status);
    store_result();
    VT_EQ(images->result[0][0], xor_word, "VS-off traps preserve the prior AES result");
}

#define VT_E32M2 0x11u
#define VSETIVLI(d, avl, vt)                                                                       \
    ((3u << 30) | ((uint32_t) (vt) << 20) | ((avl) << 15) | (7u << 12) | ((d) << 7) | 0x57)
#define LOAD2(vd, src)                                                                             \
    __asm__ volatile(".insn r 0x07, 0, 0x11, x" #vd ", %0, x8" ::"r"(src) : "memory")
#define STORE2(vs, dst)                                                                            \
    __asm__ volatile(".insn r 0x27, 0, 0x11, x" #vs ", %0, x8" ::"r"(dst) : "memory")

/* Element e (SEW 32) of the two-register group whose first image is regs[0]. */
static uint32_t element32(volatile uint64_t (*regs)[VEC_VLEN / 64], unsigned e)
{
    const unsigned per_reg = VEC_VLEN / 32;
    uint64_t word = regs[e / per_reg][(e % per_reg) / 2];
    return (uint32_t) (word >> (32 * (e & 1)));
}

static void expect_group_trap(unsigned long pc, uint32_t word, unsigned long vstart)
{
    VT_EQ(vt_trap_count, 1, "partial group traps");
    VT_EQ(vt_trap_cause, 2, "partial group cause");
    VT_EQ(vt_trap_tval, word, "partial group instruction word");
    VT_EQ(vt_trap_epc, pc, "partial group instruction address");
    VT_EQ(vt_trap_vstart, vstart, "partial group keeps vstart");
}

static void expect_destination_unchanged(void)
{
    setvl(~0ul, 24);
    store_result();
    for (unsigned r = 0; r < 2; r++)
        for (unsigned w = 0; w < VEC_VLEN / 64; w++)
            VT_EQ(images->result[r][w], images->source[16 + r][w], "trap preserves destination");
}

/* vaesz.vs v16, v8 at e32/m2: elements [start, vl) take the round key. */
static void expect_round_zero(unsigned start, unsigned vl)
{
    setvl(~0ul, 24);
    store_result();
    for (unsigned e = 0; e < 2 * VEC_VLEN / 32; e++) {
        uint32_t initial = element32(&images->source[16], e);
        uint32_t want =
            e >= start && e < vl ? initial ^ element32(&images->source[8], e % 4) : initial;
        VT_EQ(element32(&images->result[0], e), want, "round-zero group");
    }
}

/* Scalar work long enough for the whole-register loads before it to finish,
 * so the next element-group instruction meets an idle vector unit at the ROB
 * head and is judged as early as possible after the instruction before it. */
static void settle(void)
{
    for (volatile unsigned i = 0; i < 64; i++) {
    }
}

/* Each writer of vl or vstart directly before an element-group instruction:
 * the ROB head must judge the value that instruction executes under. */
static void back_to_back_cases(void)
{
    const uint32_t em = OPG(0x28, 8, 2, 16), z = OPG(0x29, 8, 7, 16);
    unsigned long pc;
    /* vsetivli to vl = 8: legal at once. */
    setvl(~0ul, 24);
    load_sources();
    settle();
    vt_trap_clear();
    __asm__ volatile(".word %0\n"
                     ".word %1\n" ::"i"(VSETIVLI(0, 8, VT_E32M2)),
                     "i"(z)
                     : "memory");
    VT_EQ(vt_trap_count, 0, "whole groups after vsetivli");
    expect_round_zero(0, 8);
    /* vsetivli to vl = 6. */
    load_sources();
    settle();
    vt_trap_clear();
    __asm__ volatile("lla %0, 1f\n"
                     ".word %1\n"
                     "1: .word %2\n"
                     : "=&r"(pc)
                     : "i"(VSETIVLI(0, 6, VT_E32M2)), "i"(em)
                     : "memory");
    VT_EQ(VT_CSR_READ(vl), 6, "vsetivli sets vl");
    expect_group_trap(pc, em, 0);
    expect_destination_unchanged();
    /* csrw vstart, 2. */
    load_sources();
    setvl(8, VT_E32M2);
    settle();
    vt_trap_clear();
    __asm__ volatile("lla %0, 1f\n"
                     "csrw vstart, %1\n"
                     "1: .word %2\n"
                     : "=&r"(pc)
                     : "r"(2ul), "i"(em)
                     : "memory");
    expect_group_trap(pc, em, 2);
    expect_destination_unchanged();
#ifndef VT_SPIKE
    /* csrw vstart, 4: the second group only. */
    load_sources();
    setvl(8, VT_E32M2);
    settle();
    vt_trap_clear();
    __asm__ volatile("csrw vstart, %0\n"
                     ".word %1\n" ::"r"(4ul),
                     "i"(z)
                     : "memory");
    VT_EQ(vt_trap_count, 0, "group restart after csrw");
    VT_EQ(VT_CSR_READ(vstart), 0, "group restart after csrw clears vstart");
    expect_round_zero(4, 8);
#endif
    /* A fault-only-first load trims vl to 6. */
    load_sources();
    setvl(8, VT_E32M2);
    settle();
    vt_trap_clear();
    __asm__ volatile("lla %0, 1f\n"
                     ".insn r 0x07, 6, 0x01, x4, %1, x16\n"
                     "1: .word %2\n"
                     : "=&r"(pc)
                     : "r"(VT_FF_END - 24), "i"(em)
                     : "memory");
    VT_EQ(VT_CSR_READ(vl), 6, "fault-only-first trims vl");
    expect_group_trap(pc, em, 0);
    expect_destination_unchanged();
}

/* Destination groups that alias a source, at e32/m2 with two or more element
 * groups. The first word executes with aliased registers, the second with
 * v20, v24 and v28 holding copies of the same images; a vector add follows
 * the aliased instruction directly. */
#define OVERLAP_CASES(X)                                                                           \
    X(OPG(0x28, 16, 0, 16), OPG(0x28, 24, 0, 20), 16, 16, 8)                                       \
    X(OPG(0x28, 16, 1, 16), OPG(0x28, 24, 1, 20), 16, 16, 8)                                       \
    X(OPG(0x28, 16, 2, 16), OPG(0x28, 24, 2, 20), 16, 16, 8)                                       \
    X(OPG(0x28, 16, 3, 16), OPG(0x28, 24, 3, 20), 16, 16, 8)                                       \
    X(OPG(0x28, 16, 17, 16), OPG(0x28, 24, 17, 20), 16, 16, 8)                                     \
    X(OPG(0x22, 16, 1, 16), OPG(0x22, 24, 1, 20), 16, 16, 8)                                       \
    X(OPG(0x2a, 16, 2, 16), OPG(0x2a, 24, 2, 20), 16, 16, 8)                                       \
    X(OPG(0x2c, 16, 8, 16), OPG(0x2c, 24, 28, 20), 16, 16, 8)                                      \
    X(OPG(0x2c, 8, 16, 16), OPG(0x2c, 24, 28, 20), 16, 8, 16)                                      \
    X(OPG(0x2c, 16, 16, 16), OPG(0x2c, 24, 28, 20), 16, 16, 16)                                    \
    X(OPG(0x2c, 8, 8, 16), OPG(0x2c, 24, 28, 20), 16, 8, 8)
#define VADD_VI_V4 OPV(0x00, 1, 4, 1, 3, 4)

static void overlap_cases(void)
{
    static const unsigned images_of[][3] = {
#define IMAGES(o, r, d, a, b) {d, a, b},
        OVERLAP_CASES(IMAGES)
#undef IMAGES
    };
    for (unsigned k = 0; k < sizeof(images_of) / sizeof(images_of[0]); k++) {
        setvl(~0ul, 24);
        load_sources();
        LOAD2(20, images->source[images_of[k][0]]);
        LOAD2(24, images->source[images_of[k][1]]);
        LOAD2(28, images->source[images_of[k][2]]);
        setvl(~0ul, VT_E32M2);
        vt_trap_clear();
        unsigned n = 0;
#define RUN(o, r, d, a, b)                                                                         \
    if (n++ == k) {                                                                                \
        __asm__ volatile(".word %0\n.word %1\n.word %2\n" ::"i"(r), "i"(o), "i"(VADD_VI_V4)        \
                         : "memory");                                                              \
    }
        OVERLAP_CASES(RUN)
#undef RUN
        VT_EQ(vt_trap_count, 0, "aliased groups are legal");
        VT_EQ(VT_CSR_READ(vstart), 0, "aliased groups clear vstart");
        setvl(~0ul, 24);
        store_result();
        STORE2(20, images->reference[0]);
        STORE2(4, images->follower[0]);
        unsigned changed = 0;
        for (unsigned r = 0; r < 2; r++)
            for (unsigned w = 0; w < VEC_VLEN / 64; w++) {
                VT_EQ(images->result[r][w], images->reference[r][w], "aliased group result");
                changed += images->result[r][w] != images->source[16 + r][w];
            }
        VT_TRUE(changed != 0, "aliased group writes its destination");
        for (unsigned e = 0; e < 2 * VEC_VLEN / 32; e++)
            VT_EQ(element32(&images->follower[0], e),
                  element32(&images->source[4], e) + 1,
                  "vector add after an element group");
    }
}

int main(void)
{
    vt_enable_vector();
    vt_trap_install();
    VT_EQ(vt_vlenb() * 8, VEC_VLEN, "vector length");
    for (unsigned r = 0; r < 32; r++)
        for (unsigned w = 0; w < VEC_VLEN / 64; w++)
            images->source[r][w] = 0x81726354a5b6c7d8ull + r * 0x0101010101010101ull;
    for (unsigned k = 0; k < sizeof(cases) / sizeof(cases[0]); k++) {
        const struct test_case *t = &cases[k];
        setvl(~0ul, 24);
        load_sources();
        setvl(~0ul, t->vt);
        operation(k);
        VT_EQ(VT_CSR_READ(vstart), 0, "vstart clears");
        setvl(~0ul, 24);
        store_result();
        for (unsigned r = 0; r < t->regs; r++)
            for (unsigned word = 0; word < VEC_VLEN / 64; word++) {
                uint64_t expected = t->expected[r * (VEC_VLEN / 64) + word];
#ifdef VEC_NEGATIVE_CONTROL
                if (k == 0 && r == 0 && word == 0)
                    expected ^= 1;
#endif
                VT_EQ(images->result[r][word], expected, t->name);
            }
        VT_EQ(vt_trap_count, 0, "legal crypto does not trap");
    }
    special_cases();
    back_to_back_cases();
    overlap_cases();
    return vt_finish("vec_crypto_exec_test");
}
