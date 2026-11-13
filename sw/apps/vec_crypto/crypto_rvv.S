//    Copyright 2026 Two Sigma Open Source, LLC
//
//    Licensed under the Apache License, Version 2.0 (the "License");
//    you may not use this file except in compliance with the License.
//    You may obtain a copy of the License at
//
//        http://www.apache.org/licenses/LICENSE-2.0
//
//    Unless required by applicable law or agreed to in writing, software
//    distributed under the License is distributed on an "AS IS" BASIS,
//    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//    See the License for the specific language governing permissions and
//    limitations under the License.

// Vector cryptography kernels: AES-128 and AES-256 (Zvkned), GHASH (Zvkg), and
// SHA-256 (Zvknha). Element groups are four 32-bit elements, so each kernel
// sets vl = 4 at e32 and runs for any VLEN >= 128.

    .text

// void aes128_expand_rvv(const uint8_t key[16], uint8_t rk[11][16])
    .globl  aes128_expand_rvv
    .type   aes128_expand_rvv, @function
aes128_expand_rvv:
    vsetivli zero, 4, e32, m1, ta, ma
    vle32.v v1, (a0)
    vse32.v v1, (a1)
    .irp    n, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10
    vaeskf1.vi v2, v1, \n
    addi    a1, a1, 16
    vse32.v v2, (a1)
    vmv.v.v v1, v2
    .endr
    ret
    .size   aes128_expand_rvv, . - aes128_expand_rvv

// void aes256_expand_rvv(const uint8_t key[32], uint8_t rk[15][16])
    .globl  aes256_expand_rvv
    .type   aes256_expand_rvv, @function
aes256_expand_rvv:
    vsetivli zero, 4, e32, m1, ta, ma
    vle32.v v1, (a0)            // rk[0]
    addi    a0, a0, 16
    vle32.v v2, (a0)            // rk[1]
    vse32.v v1, (a1)
    addi    a1, a1, 16
    vse32.v v2, (a1)
    // v1 = rk[i-2], v2 = rk[i-1] -> v3 = rk[i]
    .irp    n, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14
    vmv.v.v v3, v1
    vaeskf2.vi v3, v2, \n
    addi    a1, a1, 16
    vse32.v v3, (a1)
    vmv.v.v v1, v2
    vmv.v.v v2, v3
    .endr
    ret
    .size   aes256_expand_rvv, . - aes256_expand_rvv

// void aes_encrypt_rvv(const uint8_t *rk, int rounds, const uint8_t in[16], uint8_t out[16])
    .globl  aes_encrypt_rvv
    .type   aes_encrypt_rvv, @function
aes_encrypt_rvv:
    vsetivli zero, 4, e32, m1, ta, ma
    vle32.v v0, (a2)
    vle32.v v1, (a0)
    vaesz.vs v0, v1             // AddRoundKey with rk[0]
    addi    a1, a1, -1          // middle rounds: rounds - 1
1:  addi    a0, a0, 16
    vle32.v v1, (a0)
    vaesem.vs v0, v1
    addi    a1, a1, -1
    bnez    a1, 1b
    addi    a0, a0, 16
    vle32.v v1, (a0)
    vaesef.vs v0, v1            // final round
    vse32.v v0, (a3)
    ret
    .size   aes_encrypt_rvv, . - aes_encrypt_rvv

// void aes_decrypt_rvv(const uint8_t *rk, int rounds, const uint8_t in[16], uint8_t out[16])
    .globl  aes_decrypt_rvv
    .type   aes_decrypt_rvv, @function
aes_decrypt_rvv:
    vsetivli zero, 4, e32, m1, ta, ma
    vle32.v v0, (a2)
    slli    t0, a1, 4
    add     a0, a0, t0          // a0 = &rk[rounds]
    vle32.v v1, (a0)
    vaesz.vs v0, v1
    addi    a1, a1, -1
1:  addi    a0, a0, -16
    vle32.v v1, (a0)
    vaesdm.vs v0, v1
    addi    a1, a1, -1
    bnez    a1, 1b
    addi    a0, a0, -16
    vle32.v v1, (a0)
    vaesdf.vs v0, v1
    vse32.v v0, (a3)
    ret
    .size   aes_decrypt_rvv, . - aes_decrypt_rvv

// void ghash_rvv(uint8_t y[16], const uint8_t h[16], const uint8_t *data, size_t blocks)
// y = (y ^ block) * h for every block (vghsh.vv).
    .globl  ghash_rvv
    .type   ghash_rvv, @function
ghash_rvv:
    vsetivli zero, 4, e32, m1, ta, ma
    vle32.v v1, (a0)            // Y
    vle32.v v2, (a1)            // H
1:  beqz    a3, 2f
    vle32.v v3, (a2)
    vghsh.vv v1, v2, v3
    addi    a2, a2, 16
    addi    a3, a3, -1
    j       1b
2:  vse32.v v1, (a0)
    ret
    .size   ghash_rvv, . - ghash_rvv

// void gmul_rvv(uint8_t y[16], const uint8_t h[16]): y = y * h (vgmul.vv)
    .globl  gmul_rvv
    .type   gmul_rvv, @function
gmul_rvv:
    vsetivli zero, 4, e32, m1, ta, ma
    vle32.v v1, (a0)
    vle32.v v2, (a1)
    vgmul.vv v1, v2
    vse32.v v1, (a0)
    ret
    .size   gmul_rvv, . - gmul_rvv

// void sha256_block_rvv(uint32_t state[8], const uint8_t block[64], const uint32_t k[64])
// state is a b c d e f g h as in FIPS 180-4; k is the round constant table.
    .globl  sha256_block_rvv
    .type   sha256_block_rvv, @function
sha256_block_rvv:
    // Load a,b,c,d,e,f,g,h and build the {f,e,b,a} and {h,g,d,c} registers.
    lw      t0, 0(a0)           // a
    lw      t1, 4(a0)           // b
    lw      t2, 8(a0)           // c
    lw      t3, 12(a0)          // d
    lw      t4, 16(a0)          // e
    lw      t5, 20(a0)          // f
    lw      t6, 24(a0)          // g
    lw      a4, 28(a0)          // h
    addi    sp, sp, -32
    sw      t5, 0(sp)           // ABEF element 0 = f
    sw      t4, 4(sp)           // 1 = e
    sw      t1, 8(sp)           // 2 = b
    sw      t0, 12(sp)          // 3 = a
    sw      a4, 16(sp)          // CDGH element 0 = h
    sw      t6, 20(sp)          // 1 = g
    sw      t3, 24(sp)          // 2 = d
    sw      t2, 28(sp)          // 3 = c
    vsetivli zero, 4, e32, m1, ta, ma
    vle32.v v16, (sp)           // ABEF
    addi    t0, sp, 16
    vle32.v v17, (t0)           // CDGH
    vmv.v.v v18, v16            // saved ABEF
    vmv.v.v v19, v17            // saved CDGH
    // Message words, big-endian bytes to host words.
    vle32.v v8, (a1)
    addi    t0, a1, 16
    vle32.v v9, (t0)
    addi    t0, a1, 32
    vle32.v v10, (t0)
    addi    t0, a1, 48
    vle32.v v11, (t0)
    vrev8.v v8, v8
    vrev8.v v9, v9
    vrev8.v v10, v10
    vrev8.v v11, v11
    li      t0, 1
    vmv.s.x v0, t0              // mask 0b0001: element 0
    li      t1, 16              // 16 groups of 4 rounds
    mv      t2, a2              // K pointer
1:  vle32.v v12, (t2)
    addi    t2, t2, 16
    vadd.vv v12, v8, v12        // W + K for rounds 4g..4g+3
    vsha2cl.vv v17, v16, v12
    vsha2ch.vv v16, v17, v12
    // Next message group: v8 = sha2ms(v8 = W[3:0], v13 = {W[11:9], W[4]}, v11 = W[15:12]),
    // where v13 is v10 (W[11:8]) with element 0 replaced by W[4] from v9.
    vmerge.vvm v13, v10, v9, v0
    vsha2ms.vv v8, v13, v11
    vmv.v.v v13, v8             // rotate: v8 <- v9 <- v10 <- v11 <- new
    vmv.v.v v8, v9
    vmv.v.v v9, v10
    vmv.v.v v10, v11
    vmv.v.v v11, v13
    addi    t1, t1, -1
    bnez    t1, 1b
    // Add the saved state.
    vadd.vv v16, v16, v18
    vadd.vv v17, v17, v19
    vse32.v v16, (sp)
    addi    t0, sp, 16
    vse32.v v17, (t0)
    lw      t5, 0(sp)           // f
    lw      t4, 4(sp)           // e
    lw      t1, 8(sp)           // b
    lw      t0, 12(sp)          // a
    lw      a4, 16(sp)          // h
    lw      t6, 20(sp)          // g
    lw      t3, 24(sp)          // d
    lw      t2, 28(sp)          // c
    sw      t0, 0(a0)
    sw      t1, 4(a0)
    sw      t2, 8(a0)
    sw      t3, 12(a0)
    sw      t4, 16(a0)
    sw      t5, 20(a0)
    sw      t6, 24(a0)
    sw      a4, 28(a0)
    addi    sp, sp, 32
    ret
    .size   sha256_block_rvv, . - sha256_block_rvv
