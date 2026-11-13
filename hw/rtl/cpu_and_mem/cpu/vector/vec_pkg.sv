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
  Types shared by the vector unit's datapath blocks.
*/
package vec_pkg;

  // Element width: SEW = 8 << sew.
  typedef enum logic [1:0] {
    SEW8  = 2'd0,
    SEW16 = 2'd1,
    SEW32 = 2'd2,
    SEW64 = 2'd3
  } sew_e;

  // Integer lane operations. Operand a is the vs2 element, b the vs1 element
  // or the scalar operand; compares produce one mask bit per element.
  typedef enum logic [4:0] {
    VI_ADD   = 5'd0,   // a + b
    VI_SUB   = 5'd1,   // a - b
    VI_RSUB  = 5'd2,   // b - a
    VI_AND   = 5'd3,
    VI_OR    = 5'd4,
    VI_XOR   = 5'd5,
    VI_ANDN  = 5'd6,   // a & ~b (Zvbb vandn)
    VI_MINU  = 5'd7,
    VI_MIN   = 5'd8,
    VI_MAXU  = 5'd9,
    VI_MAX   = 5'd10,
    VI_SLL   = 5'd11,  // a << b[log2(SEW)-1:0]
    VI_SRL   = 5'd12,
    VI_SRA   = 5'd13,
    VI_ROL   = 5'd14,  // Zvbb rotates
    VI_ROR   = 5'd15,
    VI_MERGE = 5'd16,  // mask ? b : a
    VI_MV    = 5'd17,  // b
    VI_BREV  = 5'd18,  // Zvbb: bit reverse within the element
    VI_BREV8 = 5'd19,  // Zvbb: bit reverse within each byte
    VI_REV8  = 5'd20,  // Zvbb: byte reverse within the element
    VI_CLZ   = 5'd21,
    VI_CTZ   = 5'd22,
    VI_CPOP  = 5'd23,
    VI_MSEQ  = 5'd24,  // mask = a == b
    VI_MSNE  = 5'd25,
    VI_MSLTU = 5'd26,  // mask = a < b
    VI_MSLT  = 5'd27,
    VI_MSLEU = 5'd28,  // mask = a <= b
    VI_MSLE  = 5'd29,
    VI_MSGTU = 5'd30,  // mask = a > b
    VI_MSGT  = 5'd31
  } int_op_e;

  // Multiply lane operations. x and y are the multiplicand elements and z
  // the addend; the sequencer picks them from vs1, vs2 and vd (vmacc and
  // vmadd differ only in that choice).
  typedef enum logic [2:0] {
    VM_MUL    = 3'd0,  // low SEW bits of x * y
    VM_MULH   = 3'd1,  // high SEW bits, signed x signed
    VM_MULHU  = 3'd2,  // high SEW bits, unsigned x unsigned
    VM_MULHSU = 3'd3,  // high SEW bits, signed x x unsigned y
    VM_MACC   = 3'd4,  // low SEW bits of z + x * y
    VM_NMSAC  = 3'd5   // low SEW bits of z - x * y
  } mul_op_e;

  // Mask unit operations. The logical ones combine two mask registers bit by
  // bit (a is vs2, b is vs1); the rest read mask bits a, qualified by the
  // active bits (body within vl and the v0 mask).
  typedef enum logic [3:0] {
    VK_AND   = 4'd0,   // vmand
    VK_NAND  = 4'd1,   // vmnand
    VK_ANDN  = 4'd2,   // vmandn: a & ~b
    VK_XOR   = 4'd3,   // vmxor
    VK_OR    = 4'd4,   // vmor
    VK_NOR   = 4'd5,   // vmnor
    VK_ORN   = 4'd6,   // vmorn: a | ~b
    VK_XNOR  = 4'd7,   // vmxnor
    VK_CPOP  = 4'd8,   // vcpop.m: active set bits
    VK_FIRST = 4'd9,   // vfirst.m: index of the first active set bit, or -1
    VK_SBF   = 4'd10,  // vmsbf.m: set before first
    VK_SIF   = 4'd11,  // vmsif.m: set including first
    VK_SOF   = 4'd12,  // vmsof.m: set only first
    VK_IOTA  = 4'd13,  // viota.m: count of earlier active set bits per element
    VK_ID    = 4'd14   // vid.v: element index
  } mask_op_e;

  // Reduction unit operations: vred* over SEW elements, and the widening sums
  // vwredsumu/vwredsum into a 2*SEW accumulator.
  typedef enum logic [3:0] {
    VR_SUM   = 4'd0,
    VR_AND   = 4'd1,
    VR_OR    = 4'd2,
    VR_XOR   = 4'd3,
    VR_MINU  = 4'd4,
    VR_MIN   = 4'd5,
    VR_MAXU  = 4'd6,
    VR_MAX   = 4'd7,
    VR_WSUMU = 4'd8,
    VR_WSUM  = 4'd9
  } red_op_e;

  // AES element-group operations (Zvkned). State is vd, the round key vs2.
  typedef enum logic [2:0] {
    VA_EF  = 3'd0,  // vaesef: final encryption round
    VA_EM  = 3'd1,  // vaesem: middle encryption round
    VA_DF  = 3'd2,  // vaesdf: final decryption round
    VA_DM  = 3'd3,  // vaesdm: middle decryption round
    VA_Z   = 3'd4,  // vaesz: round-zero key addition
    VA_KF1 = 3'd5,  // vaeskf1: next AES-128 round key
    VA_KF2 = 3'd6   // vaeskf2: next AES-256 round key
  } aes_op_e;

  // SHA-2 element-group operations (Zvknha, Zvknhb).
  typedef enum logic [1:0] {
    VS_MS = 2'd0,  // vsha2ms: four message-schedule words
    VS_CL = 2'd1,  // vsha2cl: two rounds with the low message words
    VS_CH = 2'd2   // vsha2ch: two rounds with the high message words
  } sha_op_e;

endpackage
