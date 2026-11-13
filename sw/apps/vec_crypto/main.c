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
 * Vector cryptography: AES-128 and AES-256 block encryption and decryption
 * (Zvkned), AES-GCM (AES-CTR from the vector AES block kernel and GHASH from
 * Zvkg), and one SHA-256 block compression (Zvknha, Zvknhb with SEW = 32).
 * Known-answer vectors (FIPS 197, the GCM specification's test case 2, and
 * FIPS 180-2 "abc") prove the scalar reference in this file; the vector
 * kernels in crypto_rvv.S are then compared with it on random keys, nonces,
 * additional data and message lengths.
 */

#include "vec_test.h"

void aes128_expand_rvv(const uint8_t key[16], uint8_t rk[11][16]);
void aes256_expand_rvv(const uint8_t key[32], uint8_t rk[15][16]);
void aes_encrypt_rvv(const uint8_t *rk, int rounds, const uint8_t in[16], uint8_t out[16]);
void aes_decrypt_rvv(const uint8_t *rk, int rounds, const uint8_t in[16], uint8_t out[16]);
void ghash_rvv(uint8_t y[16], const uint8_t h[16], const uint8_t *data, size_t blocks);
void gmul_rvv(uint8_t y[16], const uint8_t h[16]);
void sha256_block_rvv(uint32_t state[8], const uint8_t block[64], const uint32_t k[64]);

static uint64_t seed = 0xa5a5a5a5deadbeefull;

/* ------------------------------------------------------------------ scalar AES */

static uint8_t sbox[256], inv_sbox[256];

static uint8_t xtime(uint8_t x)
{
    return (uint8_t) ((x << 1) ^ ((x >> 7) * 0x1b));
}

static uint8_t gmul8(uint8_t a, uint8_t b)
{
    uint8_t p = 0;
    while (b) {
        if (b & 1)
            p ^= a;
        a = xtime(a);
        b >>= 1;
    }
    return p;
}

static void init_sbox(void)
{
    for (unsigned i = 0; i < 256; i++) {
        uint8_t inv = 0;
        for (unsigned j = 1; j < 256 && i; j++)
            if (gmul8((uint8_t) i, (uint8_t) j) == 1) {
                inv = (uint8_t) j;
                break;
            }
        uint8_t s = inv, x = inv;
        for (int r = 0; r < 4; r++) {
            x = (uint8_t) ((x << 1) | (x >> 7));
            s ^= x;
        }
        s ^= 0x63;
        sbox[i] = s;
        inv_sbox[s] = (uint8_t) i;
    }
}

static void aes_expand_ref(const uint8_t *key, int nk, uint8_t *rk)
{
    int words = 4 * (nk + 7);
    memcpy(rk, key, 4 * nk);
    uint8_t rcon = 1;
    for (int i = nk; i < words; i++) {
        uint8_t t[4];
        memcpy(t, rk + 4 * (i - 1), 4);
        if (i % nk == 0) {
            uint8_t u = t[0];
            t[0] = (uint8_t) (sbox[t[1]] ^ rcon);
            t[1] = sbox[t[2]];
            t[2] = sbox[t[3]];
            t[3] = sbox[u];
            rcon = xtime(rcon);
        } else if (nk > 6 && i % nk == 4) {
            for (int j = 0; j < 4; j++)
                t[j] = sbox[t[j]];
        }
        for (int j = 0; j < 4; j++)
            rk[4 * i + j] = (uint8_t) (rk[4 * (i - nk) + j] ^ t[j]);
    }
}

static void aes_encrypt_ref(const uint8_t *rk, int rounds, const uint8_t in[16], uint8_t out[16])
{
    uint8_t s[16];
    for (int i = 0; i < 16; i++)
        s[i] = in[i] ^ rk[i];
    for (int r = 1; r <= rounds; r++) {
        uint8_t t[16];
        for (int i = 0; i < 16; i++)
            t[i] = sbox[s[i]];
        for (int c = 0; c < 4; c++)
            for (int row = 0; row < 4; row++)
                s[4 * c + row] = t[4 * ((c + row) & 3) + row];
        if (r != rounds) {
            for (int c = 0; c < 4; c++) {
                uint8_t *p = s + 4 * c;
                uint8_t a0 = p[0], a1 = p[1], a2 = p[2], a3 = p[3];
                p[0] = (uint8_t) (xtime(a0) ^ (xtime(a1) ^ a1) ^ a2 ^ a3);
                p[1] = (uint8_t) (a0 ^ xtime(a1) ^ (xtime(a2) ^ a2) ^ a3);
                p[2] = (uint8_t) (a0 ^ a1 ^ xtime(a2) ^ (xtime(a3) ^ a3));
                p[3] = (uint8_t) ((xtime(a0) ^ a0) ^ a1 ^ a2 ^ xtime(a3));
            }
        }
        for (int i = 0; i < 16; i++)
            s[i] ^= rk[16 * r + i];
    }
    memcpy(out, s, 16);
}

/* ------------------------------------------------------------------ scalar GHASH */

static void gf_mul_ref(uint8_t x[16], const uint8_t h[16])
{
    uint8_t z[16] = {0}, v[16];
    memcpy(v, h, 16);
    for (int i = 0; i < 128; i++) {
        if ((x[i / 8] >> (7 - i % 8)) & 1)
            for (int j = 0; j < 16; j++)
                z[j] ^= v[j];
        int lsb = v[15] & 1;
        for (int j = 15; j > 0; j--)
            v[j] = (uint8_t) ((v[j] >> 1) | (v[j - 1] << 7));
        v[0] >>= 1;
        if (lsb)
            v[0] ^= 0xe1;
    }
    memcpy(x, z, 16);
}

static void ghash_ref(uint8_t y[16], const uint8_t h[16], const uint8_t *data, size_t blocks)
{
    for (size_t b = 0; b < blocks; b++) {
        for (int j = 0; j < 16; j++)
            y[j] ^= data[16 * b + j];
        gf_mul_ref(y, h);
    }
}

/* ------------------------------------------------------------------ GCM (96-bit IV) */

typedef struct {
    int rounds;
    uint8_t rk[15 * 16];
} aes_key_t;

typedef void (*block_fn)(const aes_key_t *, const uint8_t[16], uint8_t[16]);
typedef void (*ghash_fn)(uint8_t[16], const uint8_t[16], const uint8_t *, size_t);

static void enc_ref(const aes_key_t *k, const uint8_t in[16], uint8_t out[16])
{
    aes_encrypt_ref(k->rk, k->rounds, in, out);
}

static void enc_vec(const aes_key_t *k, const uint8_t in[16], uint8_t out[16])
{
    aes_encrypt_rvv(k->rk, k->rounds, in, out);
}

static void ghash_vec(uint8_t y[16], const uint8_t h[16], const uint8_t *d, size_t n)
{
    ghash_rvv(y, h, d, n);
}

static void inc32(uint8_t ctr[16])
{
    for (int i = 15; i >= 12; i--)
        if (++ctr[i])
            break;
}

/* GCM encrypt with the given block cipher and GHASH. */
static void gcm_encrypt(block_fn enc,
                        ghash_fn gh,
                        const aes_key_t *k,
                        const uint8_t iv[12],
                        const uint8_t *aad,
                        size_t alen,
                        const uint8_t *pt,
                        size_t n,
                        uint8_t *ct,
                        uint8_t tag[16])
{
    uint8_t zero[16] = {0}, h[16], j0[16], ctr[16], ks[16], y[16] = {0}, pad[16];
    enc(k, zero, h);
    memcpy(j0, iv, 12);
    j0[12] = j0[13] = j0[14] = 0;
    j0[15] = 1;
    memcpy(ctr, j0, 16);
    for (size_t off = 0; off < n; off += 16) {
        inc32(ctr);
        enc(k, ctr, ks);
        size_t m = n - off < 16 ? n - off : 16;
        for (size_t i = 0; i < m; i++)
            ct[off + i] = pt[off + i] ^ ks[i];
    }
    /* GHASH(A || pad || C || pad || len(A) || len(C)). */
    gh(y, h, aad, alen / 16);
    if (alen % 16) {
        memset(pad, 0, 16);
        memcpy(pad, aad + alen / 16 * 16, alen % 16);
        gh(y, h, pad, 1);
    }
    gh(y, h, ct, n / 16);
    if (n % 16) {
        memset(pad, 0, 16);
        memcpy(pad, ct + n / 16 * 16, n % 16);
        gh(y, h, pad, 1);
    }
    uint8_t lens[16] = {0};
    uint64_t abits = alen * 8, cbits = n * 8;
    for (int i = 0; i < 8; i++) {
        lens[7 - i] = (uint8_t) (abits >> (8 * i));
        lens[15 - i] = (uint8_t) (cbits >> (8 * i));
    }
    gh(y, h, lens, 1);
    enc(k, j0, ks);
    for (int i = 0; i < 16; i++)
        tag[i] = y[i] ^ ks[i];
}

static void hex_to_bytes(const char *hex, uint8_t *out, size_t n)
{
    for (size_t i = 0; i < n; i++) {
        unsigned v = 0;
        for (int j = 0; j < 2; j++) {
            char c = hex[2 * i + j];
            v = v * 16 + (unsigned) (c <= '9' ? c - '0' : c - 'a' + 10);
        }
        out[i] = (uint8_t) v;
    }
}

static void
check_bytes(const uint8_t *got, const uint8_t *want, size_t n, const char *what, int line)
{
    vt_checks++;
    if (memcmp(got, want, n) != 0) {
        vt_fail_head(what, line);
        vt_puts("\r\n");
    }
}
#define CHECK_BYTES(g, w, n, what) check_bytes(g, w, n, what, __LINE__)

static void test_aes_kat(void)
{
    uint8_t key[32], pt[16], want[16], out[16], rk[15 * 16];
    hex_to_bytes("00112233445566778899aabbccddeeff", pt, 16);
    /* FIPS 197 appendix C.1 and C.3. */
    hex_to_bytes("000102030405060708090a0b0c0d0e0f", key, 16);
    hex_to_bytes("69c4e0d86a7b0430d8cdb78070b4c55a", want, 16);
    aes_expand_ref(key, 4, rk);
    aes_encrypt_ref(rk, 10, pt, out);
    CHECK_BYTES(out, want, 16, "scalar AES-128 known answer");
    memset(rk, 0, sizeof rk);
    aes128_expand_rvv(key, (uint8_t (*)[16]) rk);
    memset(out, 0xa5, 16); /* A kernel that writes nothing must not match. */
    aes_encrypt_rvv(rk, 10, pt, out);
    CHECK_BYTES(out, want, 16, "vector AES-128 known answer");
    hex_to_bytes("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f", key, 32);
    hex_to_bytes("8ea2b7ca516745bfeafc49904b496089", want, 16);
    aes_expand_ref(key, 8, rk);
    aes_encrypt_ref(rk, 14, pt, out);
    CHECK_BYTES(out, want, 16, "scalar AES-256 known answer");
    memset(rk, 0, sizeof rk);
    aes256_expand_rvv(key, (uint8_t (*)[16]) rk);
    memset(out, 0xa5, 16);
    aes_encrypt_rvv(rk, 14, pt, out);
    CHECK_BYTES(out, want, 16, "vector AES-256 known answer");
    uint8_t back[16];
    memset(back, 0x5a, 16);
    aes_decrypt_rvv(rk, 14, out, back);
    CHECK_BYTES(back, pt, 16, "vector AES-256 decrypt");
}

static void test_aes_random(void)
{
    for (int iter = 0; iter < 20; iter++) {
        uint8_t key[32], pt[16], a[16], b[16], rkv[15 * 16], rkr[15 * 16], back[16];
        for (int i = 0; i < 32; i++)
            key[i] = (uint8_t) vt_rand(&seed);
        for (int i = 0; i < 16; i++)
            pt[i] = (uint8_t) vt_rand(&seed);
        for (int bits = 0; bits < 2; bits++) {
            int nk = bits ? 8 : 4, rounds = bits ? 14 : 10;
            aes_expand_ref(key, nk, rkr);
            if (bits)
                aes256_expand_rvv(key, (uint8_t (*)[16]) rkv);
            else
                aes128_expand_rvv(key, (uint8_t (*)[16]) rkv);
            CHECK_BYTES(rkv, rkr, 16 * (rounds + 1), "key schedule");
            aes_encrypt_ref(rkr, rounds, pt, a);
            memset(b, 0xa5, 16);
            memset(back, 0x5a, 16);
            aes_encrypt_rvv(rkv, rounds, pt, b);
            CHECK_BYTES(b, a, 16, "AES encrypt");
            aes_decrypt_rvv(rkv, rounds, b, back);
            CHECK_BYTES(back, pt, 16, "AES decrypt");
        }
    }
}

static void test_gcm_kat(void)
{
    /* GCM specification test case 2: K = 0, IV = 0, P = 0, no AAD. */
    aes_key_t k;
    uint8_t key[16] = {0}, iv[12] = {0}, pt[16] = {0}, ct[16], tag[16], want_ct[16], want_tag[16];
    hex_to_bytes("0388dace60b6a392f328c2b971b2fe78", want_ct, 16);
    hex_to_bytes("ab6e47d42cec13bdf53a67b21257bddf", want_tag, 16);
    k.rounds = 10;
    aes_expand_ref(key, 4, k.rk);
    gcm_encrypt(enc_ref, ghash_ref, &k, iv, 0, 0, pt, 16, ct, tag);
    CHECK_BYTES(ct, want_ct, 16, "scalar GCM test case 2 ciphertext");
    CHECK_BYTES(tag, want_tag, 16, "scalar GCM test case 2 tag");
    memset(&k, 0, sizeof k);
    k.rounds = 10;
    aes128_expand_rvv(key, (uint8_t (*)[16]) k.rk);
    memset(ct, 0xa5, sizeof ct);
    memset(tag, 0x5a, sizeof tag);
    gcm_encrypt(enc_vec, ghash_vec, &k, iv, 0, 0, pt, 16, ct, tag);
    CHECK_BYTES(ct, want_ct, 16, "vector GCM test case 2 ciphertext");
    CHECK_BYTES(tag, want_tag, 16, "vector GCM test case 2 tag");
}

static void test_gcm_random(void)
{
    static uint8_t aad[64], pt[100], ct_r[100], ct_v[100];
    for (int iter = 0; iter < 24; iter++) {
        aes_key_t kr, kv;
        uint8_t key[32], iv[12], tag_r[16], tag_v[16];
        for (int i = 0; i < 32; i++)
            key[i] = (uint8_t) vt_rand(&seed);
        for (int i = 0; i < 12; i++)
            iv[i] = (uint8_t) vt_rand(&seed);
        for (unsigned i = 0; i < sizeof aad; i++)
            aad[i] = (uint8_t) vt_rand(&seed);
        for (unsigned i = 0; i < sizeof pt; i++)
            pt[i] = (uint8_t) vt_rand(&seed);
        size_t alen = (size_t) (vt_rand(&seed) % 41);
        size_t n = (size_t) (vt_rand(&seed) % 97);
        int aes256 = iter & 1;
        kr.rounds = kv.rounds = aes256 ? 14 : 10;
        aes_expand_ref(key, aes256 ? 8 : 4, kr.rk);
        if (aes256)
            aes256_expand_rvv(key, (uint8_t (*)[16]) kv.rk);
        else
            aes128_expand_rvv(key, (uint8_t (*)[16]) kv.rk);
        gcm_encrypt(enc_ref, ghash_ref, &kr, iv, aad, alen, pt, n, ct_r, tag_r);
        memset(ct_v, 0xa5, sizeof ct_v);
        memset(tag_v, 0x5a, sizeof tag_v);
        gcm_encrypt(enc_vec, ghash_vec, &kv, iv, aad, alen, pt, n, ct_v, tag_v);
        CHECK_BYTES(ct_v, ct_r, n, "GCM ciphertext");
        CHECK_BYTES(tag_v, tag_r, 16, "GCM tag");
    }
    /* vgmul agrees with the scalar field multiplication. */
    for (int iter = 0; iter < 20; iter++) {
        uint8_t x[16], h[16], r[16], v[16];
        for (int i = 0; i < 16; i++) {
            x[i] = (uint8_t) vt_rand(&seed);
            h[i] = (uint8_t) vt_rand(&seed);
        }
        memcpy(r, x, 16);
        gf_mul_ref(r, h);
        memcpy(v, x, 16);
        gmul_rvv(v, h);
        CHECK_BYTES(v, r, 16, "vgmul");
    }
}

/* ------------------------------------------------------------------ SHA-256 */

static const uint32_t K256[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2};

static const uint32_t H256[8] = {
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};

#define ROR(x, n) (((x) >> (n)) | ((x) << (32 - (n))))

static void sha256_block_ref(uint32_t st[8], const uint8_t blk[64])
{
    uint32_t w[64];
    for (int i = 0; i < 16; i++)
        w[i] = (uint32_t) blk[4 * i] << 24 | (uint32_t) blk[4 * i + 1] << 16 |
               (uint32_t) blk[4 * i + 2] << 8 | blk[4 * i + 3];
    for (int i = 16; i < 64; i++) {
        uint32_t s0 = ROR(w[i - 15], 7) ^ ROR(w[i - 15], 18) ^ (w[i - 15] >> 3);
        uint32_t s1 = ROR(w[i - 2], 17) ^ ROR(w[i - 2], 19) ^ (w[i - 2] >> 10);
        w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }
    uint32_t a = st[0], b = st[1], c = st[2], d = st[3], e = st[4], f = st[5], g = st[6], h = st[7];
    for (int i = 0; i < 64; i++) {
        uint32_t S1 = ROR(e, 6) ^ ROR(e, 11) ^ ROR(e, 25);
        uint32_t ch = (e & f) ^ (~e & g);
        uint32_t t1 = h + S1 + ch + K256[i] + w[i];
        uint32_t S0 = ROR(a, 2) ^ ROR(a, 13) ^ ROR(a, 22);
        uint32_t maj = (a & b) ^ (a & c) ^ (b & c);
        uint32_t t2 = S0 + maj;
        h = g;
        g = f;
        f = e;
        e = d + t1;
        d = c;
        c = b;
        b = a;
        a = t1 + t2;
    }
    st[0] += a;
    st[1] += b;
    st[2] += c;
    st[3] += d;
    st[4] += e;
    st[5] += f;
    st[6] += g;
    st[7] += h;
}

static void test_sha256(void)
{
    uint8_t blk[64] = {0};
    blk[0] = 'a';
    blk[1] = 'b';
    blk[2] = 'c';
    blk[3] = 0x80;
    blk[63] = 24; /* length in bits */
    uint32_t st[8], want[8] = {0xba7816bf,
                               0x8f01cfea,
                               0x414140de,
                               0x5dae2223,
                               0xb00361a3,
                               0x96177a9c,
                               0xb410ff61,
                               0xf20015ad};
    memcpy(st, H256, sizeof st);
    sha256_block_ref(st, blk);
    VT_EQ(memcmp(st, want, 32), 0, "scalar SHA-256 abc known answer");
    memcpy(st, H256, sizeof st);
    sha256_block_rvv(st, blk, K256);
    VT_EQ(memcmp(st, want, 32), 0, "vector SHA-256 abc known answer");
    for (int iter = 0; iter < 30; iter++) {
        uint32_t s0[8], s1[8];
        for (int i = 0; i < 64; i++)
            blk[i] = (uint8_t) vt_rand(&seed);
        for (int i = 0; i < 8; i++)
            s0[i] = s1[i] = (uint32_t) vt_rand(&seed);
        sha256_block_ref(s0, blk);
        sha256_block_rvv(s1, blk, K256);
        VT_EQ(memcmp(s0, s1, 32), 0, "SHA-256 block on random state");
    }
}

int main(void)
{
    vt_enable_vector();
    vt_trap_install();
    init_sbox();
    test_aes_kat();
    test_aes_random();
    test_gcm_kat();
    test_gcm_random();
    test_sha256();
    return vt_finish("vec_crypto");
}
