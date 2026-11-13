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
  The AES block of the vector unit (Zvkned) for one 128-bit element group:
  vaesef, vaesem, vaesdf, vaesdm and vaesz on state i_state (vd) with round key
  i_key (vs2), and the key-schedule steps vaeskf1 (AES-128: next round key from
  i_key and round i_rnd) and vaeskf2 (AES-256: next round key from i_state, the
  key two rounds back, and i_key, the previous one). Byte j of the group is
  AES state byte j (column j/4, row j%4); key words are 32-bit little-endian.
  Round numbers outside 1..10 (vaeskf1) or 2..14 (vaeskf2) are replaced by the
  number with bit 3 inverted, as the specification requires.

  S-box lookups take the first cycle; ShiftRows, the key-schedule words and
  the round-key addition the second; MixColumns (followed by the round key,
  as vaesem orders them) or InvMixColumns (after the round key, as vaesdm
  orders them) the third. The
  result appears a fixed three cycles after the cycle that takes the input, for
  every operation and value, so the timing is independent of the data
  (Zvkt).
*/
module vec_aes_group (
    input  logic                     i_clk,
    input  logic                     i_rst,
    input  logic                     i_valid,
    input  vec_pkg::aes_op_e         i_op,
    input  logic             [  3:0] i_rnd,
    input  logic             [127:0] i_state,
    input  logic             [127:0] i_key,
    output logic                     o_valid,
    output logic             [127:0] o_result
);


  // The AES S-box.
  function automatic logic [7:0] sbox_fwd(input logic [7:0] x);
    unique case (x)
      8'h00:   sbox_fwd = 8'h63;
      8'h01:   sbox_fwd = 8'h7c;
      8'h02:   sbox_fwd = 8'h77;
      8'h03:   sbox_fwd = 8'h7b;
      8'h04:   sbox_fwd = 8'hf2;
      8'h05:   sbox_fwd = 8'h6b;
      8'h06:   sbox_fwd = 8'h6f;
      8'h07:   sbox_fwd = 8'hc5;
      8'h08:   sbox_fwd = 8'h30;
      8'h09:   sbox_fwd = 8'h01;
      8'h0a:   sbox_fwd = 8'h67;
      8'h0b:   sbox_fwd = 8'h2b;
      8'h0c:   sbox_fwd = 8'hfe;
      8'h0d:   sbox_fwd = 8'hd7;
      8'h0e:   sbox_fwd = 8'hab;
      8'h0f:   sbox_fwd = 8'h76;
      8'h10:   sbox_fwd = 8'hca;
      8'h11:   sbox_fwd = 8'h82;
      8'h12:   sbox_fwd = 8'hc9;
      8'h13:   sbox_fwd = 8'h7d;
      8'h14:   sbox_fwd = 8'hfa;
      8'h15:   sbox_fwd = 8'h59;
      8'h16:   sbox_fwd = 8'h47;
      8'h17:   sbox_fwd = 8'hf0;
      8'h18:   sbox_fwd = 8'had;
      8'h19:   sbox_fwd = 8'hd4;
      8'h1a:   sbox_fwd = 8'ha2;
      8'h1b:   sbox_fwd = 8'haf;
      8'h1c:   sbox_fwd = 8'h9c;
      8'h1d:   sbox_fwd = 8'ha4;
      8'h1e:   sbox_fwd = 8'h72;
      8'h1f:   sbox_fwd = 8'hc0;
      8'h20:   sbox_fwd = 8'hb7;
      8'h21:   sbox_fwd = 8'hfd;
      8'h22:   sbox_fwd = 8'h93;
      8'h23:   sbox_fwd = 8'h26;
      8'h24:   sbox_fwd = 8'h36;
      8'h25:   sbox_fwd = 8'h3f;
      8'h26:   sbox_fwd = 8'hf7;
      8'h27:   sbox_fwd = 8'hcc;
      8'h28:   sbox_fwd = 8'h34;
      8'h29:   sbox_fwd = 8'ha5;
      8'h2a:   sbox_fwd = 8'he5;
      8'h2b:   sbox_fwd = 8'hf1;
      8'h2c:   sbox_fwd = 8'h71;
      8'h2d:   sbox_fwd = 8'hd8;
      8'h2e:   sbox_fwd = 8'h31;
      8'h2f:   sbox_fwd = 8'h15;
      8'h30:   sbox_fwd = 8'h04;
      8'h31:   sbox_fwd = 8'hc7;
      8'h32:   sbox_fwd = 8'h23;
      8'h33:   sbox_fwd = 8'hc3;
      8'h34:   sbox_fwd = 8'h18;
      8'h35:   sbox_fwd = 8'h96;
      8'h36:   sbox_fwd = 8'h05;
      8'h37:   sbox_fwd = 8'h9a;
      8'h38:   sbox_fwd = 8'h07;
      8'h39:   sbox_fwd = 8'h12;
      8'h3a:   sbox_fwd = 8'h80;
      8'h3b:   sbox_fwd = 8'he2;
      8'h3c:   sbox_fwd = 8'heb;
      8'h3d:   sbox_fwd = 8'h27;
      8'h3e:   sbox_fwd = 8'hb2;
      8'h3f:   sbox_fwd = 8'h75;
      8'h40:   sbox_fwd = 8'h09;
      8'h41:   sbox_fwd = 8'h83;
      8'h42:   sbox_fwd = 8'h2c;
      8'h43:   sbox_fwd = 8'h1a;
      8'h44:   sbox_fwd = 8'h1b;
      8'h45:   sbox_fwd = 8'h6e;
      8'h46:   sbox_fwd = 8'h5a;
      8'h47:   sbox_fwd = 8'ha0;
      8'h48:   sbox_fwd = 8'h52;
      8'h49:   sbox_fwd = 8'h3b;
      8'h4a:   sbox_fwd = 8'hd6;
      8'h4b:   sbox_fwd = 8'hb3;
      8'h4c:   sbox_fwd = 8'h29;
      8'h4d:   sbox_fwd = 8'he3;
      8'h4e:   sbox_fwd = 8'h2f;
      8'h4f:   sbox_fwd = 8'h84;
      8'h50:   sbox_fwd = 8'h53;
      8'h51:   sbox_fwd = 8'hd1;
      8'h52:   sbox_fwd = 8'h00;
      8'h53:   sbox_fwd = 8'hed;
      8'h54:   sbox_fwd = 8'h20;
      8'h55:   sbox_fwd = 8'hfc;
      8'h56:   sbox_fwd = 8'hb1;
      8'h57:   sbox_fwd = 8'h5b;
      8'h58:   sbox_fwd = 8'h6a;
      8'h59:   sbox_fwd = 8'hcb;
      8'h5a:   sbox_fwd = 8'hbe;
      8'h5b:   sbox_fwd = 8'h39;
      8'h5c:   sbox_fwd = 8'h4a;
      8'h5d:   sbox_fwd = 8'h4c;
      8'h5e:   sbox_fwd = 8'h58;
      8'h5f:   sbox_fwd = 8'hcf;
      8'h60:   sbox_fwd = 8'hd0;
      8'h61:   sbox_fwd = 8'hef;
      8'h62:   sbox_fwd = 8'haa;
      8'h63:   sbox_fwd = 8'hfb;
      8'h64:   sbox_fwd = 8'h43;
      8'h65:   sbox_fwd = 8'h4d;
      8'h66:   sbox_fwd = 8'h33;
      8'h67:   sbox_fwd = 8'h85;
      8'h68:   sbox_fwd = 8'h45;
      8'h69:   sbox_fwd = 8'hf9;
      8'h6a:   sbox_fwd = 8'h02;
      8'h6b:   sbox_fwd = 8'h7f;
      8'h6c:   sbox_fwd = 8'h50;
      8'h6d:   sbox_fwd = 8'h3c;
      8'h6e:   sbox_fwd = 8'h9f;
      8'h6f:   sbox_fwd = 8'ha8;
      8'h70:   sbox_fwd = 8'h51;
      8'h71:   sbox_fwd = 8'ha3;
      8'h72:   sbox_fwd = 8'h40;
      8'h73:   sbox_fwd = 8'h8f;
      8'h74:   sbox_fwd = 8'h92;
      8'h75:   sbox_fwd = 8'h9d;
      8'h76:   sbox_fwd = 8'h38;
      8'h77:   sbox_fwd = 8'hf5;
      8'h78:   sbox_fwd = 8'hbc;
      8'h79:   sbox_fwd = 8'hb6;
      8'h7a:   sbox_fwd = 8'hda;
      8'h7b:   sbox_fwd = 8'h21;
      8'h7c:   sbox_fwd = 8'h10;
      8'h7d:   sbox_fwd = 8'hff;
      8'h7e:   sbox_fwd = 8'hf3;
      8'h7f:   sbox_fwd = 8'hd2;
      8'h80:   sbox_fwd = 8'hcd;
      8'h81:   sbox_fwd = 8'h0c;
      8'h82:   sbox_fwd = 8'h13;
      8'h83:   sbox_fwd = 8'hec;
      8'h84:   sbox_fwd = 8'h5f;
      8'h85:   sbox_fwd = 8'h97;
      8'h86:   sbox_fwd = 8'h44;
      8'h87:   sbox_fwd = 8'h17;
      8'h88:   sbox_fwd = 8'hc4;
      8'h89:   sbox_fwd = 8'ha7;
      8'h8a:   sbox_fwd = 8'h7e;
      8'h8b:   sbox_fwd = 8'h3d;
      8'h8c:   sbox_fwd = 8'h64;
      8'h8d:   sbox_fwd = 8'h5d;
      8'h8e:   sbox_fwd = 8'h19;
      8'h8f:   sbox_fwd = 8'h73;
      8'h90:   sbox_fwd = 8'h60;
      8'h91:   sbox_fwd = 8'h81;
      8'h92:   sbox_fwd = 8'h4f;
      8'h93:   sbox_fwd = 8'hdc;
      8'h94:   sbox_fwd = 8'h22;
      8'h95:   sbox_fwd = 8'h2a;
      8'h96:   sbox_fwd = 8'h90;
      8'h97:   sbox_fwd = 8'h88;
      8'h98:   sbox_fwd = 8'h46;
      8'h99:   sbox_fwd = 8'hee;
      8'h9a:   sbox_fwd = 8'hb8;
      8'h9b:   sbox_fwd = 8'h14;
      8'h9c:   sbox_fwd = 8'hde;
      8'h9d:   sbox_fwd = 8'h5e;
      8'h9e:   sbox_fwd = 8'h0b;
      8'h9f:   sbox_fwd = 8'hdb;
      8'ha0:   sbox_fwd = 8'he0;
      8'ha1:   sbox_fwd = 8'h32;
      8'ha2:   sbox_fwd = 8'h3a;
      8'ha3:   sbox_fwd = 8'h0a;
      8'ha4:   sbox_fwd = 8'h49;
      8'ha5:   sbox_fwd = 8'h06;
      8'ha6:   sbox_fwd = 8'h24;
      8'ha7:   sbox_fwd = 8'h5c;
      8'ha8:   sbox_fwd = 8'hc2;
      8'ha9:   sbox_fwd = 8'hd3;
      8'haa:   sbox_fwd = 8'hac;
      8'hab:   sbox_fwd = 8'h62;
      8'hac:   sbox_fwd = 8'h91;
      8'had:   sbox_fwd = 8'h95;
      8'hae:   sbox_fwd = 8'he4;
      8'haf:   sbox_fwd = 8'h79;
      8'hb0:   sbox_fwd = 8'he7;
      8'hb1:   sbox_fwd = 8'hc8;
      8'hb2:   sbox_fwd = 8'h37;
      8'hb3:   sbox_fwd = 8'h6d;
      8'hb4:   sbox_fwd = 8'h8d;
      8'hb5:   sbox_fwd = 8'hd5;
      8'hb6:   sbox_fwd = 8'h4e;
      8'hb7:   sbox_fwd = 8'ha9;
      8'hb8:   sbox_fwd = 8'h6c;
      8'hb9:   sbox_fwd = 8'h56;
      8'hba:   sbox_fwd = 8'hf4;
      8'hbb:   sbox_fwd = 8'hea;
      8'hbc:   sbox_fwd = 8'h65;
      8'hbd:   sbox_fwd = 8'h7a;
      8'hbe:   sbox_fwd = 8'hae;
      8'hbf:   sbox_fwd = 8'h08;
      8'hc0:   sbox_fwd = 8'hba;
      8'hc1:   sbox_fwd = 8'h78;
      8'hc2:   sbox_fwd = 8'h25;
      8'hc3:   sbox_fwd = 8'h2e;
      8'hc4:   sbox_fwd = 8'h1c;
      8'hc5:   sbox_fwd = 8'ha6;
      8'hc6:   sbox_fwd = 8'hb4;
      8'hc7:   sbox_fwd = 8'hc6;
      8'hc8:   sbox_fwd = 8'he8;
      8'hc9:   sbox_fwd = 8'hdd;
      8'hca:   sbox_fwd = 8'h74;
      8'hcb:   sbox_fwd = 8'h1f;
      8'hcc:   sbox_fwd = 8'h4b;
      8'hcd:   sbox_fwd = 8'hbd;
      8'hce:   sbox_fwd = 8'h8b;
      8'hcf:   sbox_fwd = 8'h8a;
      8'hd0:   sbox_fwd = 8'h70;
      8'hd1:   sbox_fwd = 8'h3e;
      8'hd2:   sbox_fwd = 8'hb5;
      8'hd3:   sbox_fwd = 8'h66;
      8'hd4:   sbox_fwd = 8'h48;
      8'hd5:   sbox_fwd = 8'h03;
      8'hd6:   sbox_fwd = 8'hf6;
      8'hd7:   sbox_fwd = 8'h0e;
      8'hd8:   sbox_fwd = 8'h61;
      8'hd9:   sbox_fwd = 8'h35;
      8'hda:   sbox_fwd = 8'h57;
      8'hdb:   sbox_fwd = 8'hb9;
      8'hdc:   sbox_fwd = 8'h86;
      8'hdd:   sbox_fwd = 8'hc1;
      8'hde:   sbox_fwd = 8'h1d;
      8'hdf:   sbox_fwd = 8'h9e;
      8'he0:   sbox_fwd = 8'he1;
      8'he1:   sbox_fwd = 8'hf8;
      8'he2:   sbox_fwd = 8'h98;
      8'he3:   sbox_fwd = 8'h11;
      8'he4:   sbox_fwd = 8'h69;
      8'he5:   sbox_fwd = 8'hd9;
      8'he6:   sbox_fwd = 8'h8e;
      8'he7:   sbox_fwd = 8'h94;
      8'he8:   sbox_fwd = 8'h9b;
      8'he9:   sbox_fwd = 8'h1e;
      8'hea:   sbox_fwd = 8'h87;
      8'heb:   sbox_fwd = 8'he9;
      8'hec:   sbox_fwd = 8'hce;
      8'hed:   sbox_fwd = 8'h55;
      8'hee:   sbox_fwd = 8'h28;
      8'hef:   sbox_fwd = 8'hdf;
      8'hf0:   sbox_fwd = 8'h8c;
      8'hf1:   sbox_fwd = 8'ha1;
      8'hf2:   sbox_fwd = 8'h89;
      8'hf3:   sbox_fwd = 8'h0d;
      8'hf4:   sbox_fwd = 8'hbf;
      8'hf5:   sbox_fwd = 8'he6;
      8'hf6:   sbox_fwd = 8'h42;
      8'hf7:   sbox_fwd = 8'h68;
      8'hf8:   sbox_fwd = 8'h41;
      8'hf9:   sbox_fwd = 8'h99;
      8'hfa:   sbox_fwd = 8'h2d;
      8'hfb:   sbox_fwd = 8'h0f;
      8'hfc:   sbox_fwd = 8'hb0;
      8'hfd:   sbox_fwd = 8'h54;
      8'hfe:   sbox_fwd = 8'hbb;
      8'hff:   sbox_fwd = 8'h16;
      default: sbox_fwd = 8'h00;
    endcase
  endfunction

  // The inverse AES S-box.
  function automatic logic [7:0] sbox_inv(input logic [7:0] x);
    unique case (x)
      8'h00:   sbox_inv = 8'h52;
      8'h01:   sbox_inv = 8'h09;
      8'h02:   sbox_inv = 8'h6a;
      8'h03:   sbox_inv = 8'hd5;
      8'h04:   sbox_inv = 8'h30;
      8'h05:   sbox_inv = 8'h36;
      8'h06:   sbox_inv = 8'ha5;
      8'h07:   sbox_inv = 8'h38;
      8'h08:   sbox_inv = 8'hbf;
      8'h09:   sbox_inv = 8'h40;
      8'h0a:   sbox_inv = 8'ha3;
      8'h0b:   sbox_inv = 8'h9e;
      8'h0c:   sbox_inv = 8'h81;
      8'h0d:   sbox_inv = 8'hf3;
      8'h0e:   sbox_inv = 8'hd7;
      8'h0f:   sbox_inv = 8'hfb;
      8'h10:   sbox_inv = 8'h7c;
      8'h11:   sbox_inv = 8'he3;
      8'h12:   sbox_inv = 8'h39;
      8'h13:   sbox_inv = 8'h82;
      8'h14:   sbox_inv = 8'h9b;
      8'h15:   sbox_inv = 8'h2f;
      8'h16:   sbox_inv = 8'hff;
      8'h17:   sbox_inv = 8'h87;
      8'h18:   sbox_inv = 8'h34;
      8'h19:   sbox_inv = 8'h8e;
      8'h1a:   sbox_inv = 8'h43;
      8'h1b:   sbox_inv = 8'h44;
      8'h1c:   sbox_inv = 8'hc4;
      8'h1d:   sbox_inv = 8'hde;
      8'h1e:   sbox_inv = 8'he9;
      8'h1f:   sbox_inv = 8'hcb;
      8'h20:   sbox_inv = 8'h54;
      8'h21:   sbox_inv = 8'h7b;
      8'h22:   sbox_inv = 8'h94;
      8'h23:   sbox_inv = 8'h32;
      8'h24:   sbox_inv = 8'ha6;
      8'h25:   sbox_inv = 8'hc2;
      8'h26:   sbox_inv = 8'h23;
      8'h27:   sbox_inv = 8'h3d;
      8'h28:   sbox_inv = 8'hee;
      8'h29:   sbox_inv = 8'h4c;
      8'h2a:   sbox_inv = 8'h95;
      8'h2b:   sbox_inv = 8'h0b;
      8'h2c:   sbox_inv = 8'h42;
      8'h2d:   sbox_inv = 8'hfa;
      8'h2e:   sbox_inv = 8'hc3;
      8'h2f:   sbox_inv = 8'h4e;
      8'h30:   sbox_inv = 8'h08;
      8'h31:   sbox_inv = 8'h2e;
      8'h32:   sbox_inv = 8'ha1;
      8'h33:   sbox_inv = 8'h66;
      8'h34:   sbox_inv = 8'h28;
      8'h35:   sbox_inv = 8'hd9;
      8'h36:   sbox_inv = 8'h24;
      8'h37:   sbox_inv = 8'hb2;
      8'h38:   sbox_inv = 8'h76;
      8'h39:   sbox_inv = 8'h5b;
      8'h3a:   sbox_inv = 8'ha2;
      8'h3b:   sbox_inv = 8'h49;
      8'h3c:   sbox_inv = 8'h6d;
      8'h3d:   sbox_inv = 8'h8b;
      8'h3e:   sbox_inv = 8'hd1;
      8'h3f:   sbox_inv = 8'h25;
      8'h40:   sbox_inv = 8'h72;
      8'h41:   sbox_inv = 8'hf8;
      8'h42:   sbox_inv = 8'hf6;
      8'h43:   sbox_inv = 8'h64;
      8'h44:   sbox_inv = 8'h86;
      8'h45:   sbox_inv = 8'h68;
      8'h46:   sbox_inv = 8'h98;
      8'h47:   sbox_inv = 8'h16;
      8'h48:   sbox_inv = 8'hd4;
      8'h49:   sbox_inv = 8'ha4;
      8'h4a:   sbox_inv = 8'h5c;
      8'h4b:   sbox_inv = 8'hcc;
      8'h4c:   sbox_inv = 8'h5d;
      8'h4d:   sbox_inv = 8'h65;
      8'h4e:   sbox_inv = 8'hb6;
      8'h4f:   sbox_inv = 8'h92;
      8'h50:   sbox_inv = 8'h6c;
      8'h51:   sbox_inv = 8'h70;
      8'h52:   sbox_inv = 8'h48;
      8'h53:   sbox_inv = 8'h50;
      8'h54:   sbox_inv = 8'hfd;
      8'h55:   sbox_inv = 8'hed;
      8'h56:   sbox_inv = 8'hb9;
      8'h57:   sbox_inv = 8'hda;
      8'h58:   sbox_inv = 8'h5e;
      8'h59:   sbox_inv = 8'h15;
      8'h5a:   sbox_inv = 8'h46;
      8'h5b:   sbox_inv = 8'h57;
      8'h5c:   sbox_inv = 8'ha7;
      8'h5d:   sbox_inv = 8'h8d;
      8'h5e:   sbox_inv = 8'h9d;
      8'h5f:   sbox_inv = 8'h84;
      8'h60:   sbox_inv = 8'h90;
      8'h61:   sbox_inv = 8'hd8;
      8'h62:   sbox_inv = 8'hab;
      8'h63:   sbox_inv = 8'h00;
      8'h64:   sbox_inv = 8'h8c;
      8'h65:   sbox_inv = 8'hbc;
      8'h66:   sbox_inv = 8'hd3;
      8'h67:   sbox_inv = 8'h0a;
      8'h68:   sbox_inv = 8'hf7;
      8'h69:   sbox_inv = 8'he4;
      8'h6a:   sbox_inv = 8'h58;
      8'h6b:   sbox_inv = 8'h05;
      8'h6c:   sbox_inv = 8'hb8;
      8'h6d:   sbox_inv = 8'hb3;
      8'h6e:   sbox_inv = 8'h45;
      8'h6f:   sbox_inv = 8'h06;
      8'h70:   sbox_inv = 8'hd0;
      8'h71:   sbox_inv = 8'h2c;
      8'h72:   sbox_inv = 8'h1e;
      8'h73:   sbox_inv = 8'h8f;
      8'h74:   sbox_inv = 8'hca;
      8'h75:   sbox_inv = 8'h3f;
      8'h76:   sbox_inv = 8'h0f;
      8'h77:   sbox_inv = 8'h02;
      8'h78:   sbox_inv = 8'hc1;
      8'h79:   sbox_inv = 8'haf;
      8'h7a:   sbox_inv = 8'hbd;
      8'h7b:   sbox_inv = 8'h03;
      8'h7c:   sbox_inv = 8'h01;
      8'h7d:   sbox_inv = 8'h13;
      8'h7e:   sbox_inv = 8'h8a;
      8'h7f:   sbox_inv = 8'h6b;
      8'h80:   sbox_inv = 8'h3a;
      8'h81:   sbox_inv = 8'h91;
      8'h82:   sbox_inv = 8'h11;
      8'h83:   sbox_inv = 8'h41;
      8'h84:   sbox_inv = 8'h4f;
      8'h85:   sbox_inv = 8'h67;
      8'h86:   sbox_inv = 8'hdc;
      8'h87:   sbox_inv = 8'hea;
      8'h88:   sbox_inv = 8'h97;
      8'h89:   sbox_inv = 8'hf2;
      8'h8a:   sbox_inv = 8'hcf;
      8'h8b:   sbox_inv = 8'hce;
      8'h8c:   sbox_inv = 8'hf0;
      8'h8d:   sbox_inv = 8'hb4;
      8'h8e:   sbox_inv = 8'he6;
      8'h8f:   sbox_inv = 8'h73;
      8'h90:   sbox_inv = 8'h96;
      8'h91:   sbox_inv = 8'hac;
      8'h92:   sbox_inv = 8'h74;
      8'h93:   sbox_inv = 8'h22;
      8'h94:   sbox_inv = 8'he7;
      8'h95:   sbox_inv = 8'had;
      8'h96:   sbox_inv = 8'h35;
      8'h97:   sbox_inv = 8'h85;
      8'h98:   sbox_inv = 8'he2;
      8'h99:   sbox_inv = 8'hf9;
      8'h9a:   sbox_inv = 8'h37;
      8'h9b:   sbox_inv = 8'he8;
      8'h9c:   sbox_inv = 8'h1c;
      8'h9d:   sbox_inv = 8'h75;
      8'h9e:   sbox_inv = 8'hdf;
      8'h9f:   sbox_inv = 8'h6e;
      8'ha0:   sbox_inv = 8'h47;
      8'ha1:   sbox_inv = 8'hf1;
      8'ha2:   sbox_inv = 8'h1a;
      8'ha3:   sbox_inv = 8'h71;
      8'ha4:   sbox_inv = 8'h1d;
      8'ha5:   sbox_inv = 8'h29;
      8'ha6:   sbox_inv = 8'hc5;
      8'ha7:   sbox_inv = 8'h89;
      8'ha8:   sbox_inv = 8'h6f;
      8'ha9:   sbox_inv = 8'hb7;
      8'haa:   sbox_inv = 8'h62;
      8'hab:   sbox_inv = 8'h0e;
      8'hac:   sbox_inv = 8'haa;
      8'had:   sbox_inv = 8'h18;
      8'hae:   sbox_inv = 8'hbe;
      8'haf:   sbox_inv = 8'h1b;
      8'hb0:   sbox_inv = 8'hfc;
      8'hb1:   sbox_inv = 8'h56;
      8'hb2:   sbox_inv = 8'h3e;
      8'hb3:   sbox_inv = 8'h4b;
      8'hb4:   sbox_inv = 8'hc6;
      8'hb5:   sbox_inv = 8'hd2;
      8'hb6:   sbox_inv = 8'h79;
      8'hb7:   sbox_inv = 8'h20;
      8'hb8:   sbox_inv = 8'h9a;
      8'hb9:   sbox_inv = 8'hdb;
      8'hba:   sbox_inv = 8'hc0;
      8'hbb:   sbox_inv = 8'hfe;
      8'hbc:   sbox_inv = 8'h78;
      8'hbd:   sbox_inv = 8'hcd;
      8'hbe:   sbox_inv = 8'h5a;
      8'hbf:   sbox_inv = 8'hf4;
      8'hc0:   sbox_inv = 8'h1f;
      8'hc1:   sbox_inv = 8'hdd;
      8'hc2:   sbox_inv = 8'ha8;
      8'hc3:   sbox_inv = 8'h33;
      8'hc4:   sbox_inv = 8'h88;
      8'hc5:   sbox_inv = 8'h07;
      8'hc6:   sbox_inv = 8'hc7;
      8'hc7:   sbox_inv = 8'h31;
      8'hc8:   sbox_inv = 8'hb1;
      8'hc9:   sbox_inv = 8'h12;
      8'hca:   sbox_inv = 8'h10;
      8'hcb:   sbox_inv = 8'h59;
      8'hcc:   sbox_inv = 8'h27;
      8'hcd:   sbox_inv = 8'h80;
      8'hce:   sbox_inv = 8'hec;
      8'hcf:   sbox_inv = 8'h5f;
      8'hd0:   sbox_inv = 8'h60;
      8'hd1:   sbox_inv = 8'h51;
      8'hd2:   sbox_inv = 8'h7f;
      8'hd3:   sbox_inv = 8'ha9;
      8'hd4:   sbox_inv = 8'h19;
      8'hd5:   sbox_inv = 8'hb5;
      8'hd6:   sbox_inv = 8'h4a;
      8'hd7:   sbox_inv = 8'h0d;
      8'hd8:   sbox_inv = 8'h2d;
      8'hd9:   sbox_inv = 8'he5;
      8'hda:   sbox_inv = 8'h7a;
      8'hdb:   sbox_inv = 8'h9f;
      8'hdc:   sbox_inv = 8'h93;
      8'hdd:   sbox_inv = 8'hc9;
      8'hde:   sbox_inv = 8'h9c;
      8'hdf:   sbox_inv = 8'hef;
      8'he0:   sbox_inv = 8'ha0;
      8'he1:   sbox_inv = 8'he0;
      8'he2:   sbox_inv = 8'h3b;
      8'he3:   sbox_inv = 8'h4d;
      8'he4:   sbox_inv = 8'hae;
      8'he5:   sbox_inv = 8'h2a;
      8'he6:   sbox_inv = 8'hf5;
      8'he7:   sbox_inv = 8'hb0;
      8'he8:   sbox_inv = 8'hc8;
      8'he9:   sbox_inv = 8'heb;
      8'hea:   sbox_inv = 8'hbb;
      8'heb:   sbox_inv = 8'h3c;
      8'hec:   sbox_inv = 8'h83;
      8'hed:   sbox_inv = 8'h53;
      8'hee:   sbox_inv = 8'h99;
      8'hef:   sbox_inv = 8'h61;
      8'hf0:   sbox_inv = 8'h17;
      8'hf1:   sbox_inv = 8'h2b;
      8'hf2:   sbox_inv = 8'h04;
      8'hf3:   sbox_inv = 8'h7e;
      8'hf4:   sbox_inv = 8'hba;
      8'hf5:   sbox_inv = 8'h77;
      8'hf6:   sbox_inv = 8'hd6;
      8'hf7:   sbox_inv = 8'h26;
      8'hf8:   sbox_inv = 8'he1;
      8'hf9:   sbox_inv = 8'h69;
      8'hfa:   sbox_inv = 8'h14;
      8'hfb:   sbox_inv = 8'h63;
      8'hfc:   sbox_inv = 8'h55;
      8'hfd:   sbox_inv = 8'h21;
      8'hfe:   sbox_inv = 8'h0c;
      8'hff:   sbox_inv = 8'h7d;
      default: sbox_inv = 8'h00;
    endcase
  endfunction

  function automatic logic [7:0] xtime(input logic [7:0] x);
    xtime = {x[6:0], 1'b0} ^ (x[7] ? 8'h1b : 8'h00);
  endfunction

  function automatic logic [7:0] rcon(input logic [3:0] i);
    unique case (i)
      4'd0: rcon = 8'h01;
      4'd1: rcon = 8'h02;
      4'd2: rcon = 8'h04;
      4'd3: rcon = 8'h08;
      4'd4: rcon = 8'h10;
      4'd5: rcon = 8'h20;
      4'd6: rcon = 8'h40;
      4'd7: rcon = 8'h80;
      4'd8: rcon = 8'h1b;
      4'd9: rcon = 8'h36;
      default: rcon = 8'h00;
    endcase
  endfunction

  // Stage 0: input registers.
  logic s0_valid;
  vec_pkg::aes_op_e s0_op;
  logic [3:0] s0_rnd;
  logic [127:0] s0_state, s0_key;
  always_ff @(posedge i_clk) begin
    if (i_rst) s0_valid <= 1'b0;
    else s0_valid <= i_valid;
    s0_op <= i_op;
    s0_state <= i_state;
    s0_key <= i_key;
    // Out-of-range round numbers have bit 3 inverted.
    if (i_op == vec_pkg::VA_KF1)
      s0_rnd <= (i_rnd == 4'd0 || i_rnd > 4'd10) ? (i_rnd ^ 4'd8) : i_rnd;
    else s0_rnd <= (i_rnd < 4'd2 || i_rnd > 4'd14) ? (i_rnd ^ 4'd8) : i_rnd;
  end

  // Stage 1: forward and inverse S-boxes of the state, and of key word 3.
  logic [127:0] sub_fwd, sub_inv;
  logic [31:0] key_sub;
  always_comb begin
    for (int j = 0; j < 16; j++) begin
      sub_fwd[8*j+:8] = sbox_fwd(s0_state[8*j+:8]);
      sub_inv[8*j+:8] = sbox_inv(s0_state[8*j+:8]);
    end
    for (int j = 0; j < 4; j++) key_sub[8*j+:8] = sbox_fwd(s0_key[96+8*j+:8]);
  end

  logic s1_valid;
  vec_pkg::aes_op_e s1_op;
  logic [3:0] s1_rnd;
  logic [127:0] s1_state, s1_key, s1_fwd, s1_inv;
  logic [31:0] s1_key_sub;
  always_ff @(posedge i_clk) begin
    if (i_rst) s1_valid <= 1'b0;
    else s1_valid <= s0_valid;
    s1_op <= s0_op;
    s1_rnd <= s0_rnd;
    s1_state <= s0_state;
    s1_key <= s0_key;
    s1_fwd <= sub_fwd;
    s1_inv <= sub_inv;
    s1_key_sub <= key_sub;
  end

  // Stage 2: ShiftRows (row r moves left by r for encryption, right for
  // decryption), the key schedule, and the round-key addition.
  logic [127:0] shifted, added, sched;
  always_comb begin
    for (int c = 0; c < 4; c++)
    for (int r = 0; r < 4; r++) begin
      if (s1_op == vec_pkg::VA_DF || s1_op == vec_pkg::VA_DM)
        shifted[8*(4*c+r)+:8] = s1_inv[8*(4*((c+4-r)%4)+r)+:8];
      else shifted[8*(4*c+r)+:8] = s1_fwd[8*(4*((c+r)%4)+r)+:8];
    end
    added = ((s1_op == vec_pkg::VA_Z) ? s1_state : shifted) ^ s1_key;
  end
  always_comb begin
    logic [31:0] t, w0, w1, w2, w3;
    logic [127:0] prev;
    logic [ 31:0] rot;
    // RotWord on a little-endian word moves byte 1 to byte 0.
    rot = {s1_key_sub[7:0], s1_key_sub[31:8]};
    // vaeskf1 builds on the current key; vaeskf2 on the key two rounds back
    // (vd). Even vaeskf2 rounds rotate and add Rcon, odd ones only
    // substitute.
    if (s1_op == vec_pkg::VA_KF1) begin
      t = rot ^ {24'b0, rcon(s1_rnd - 4'd1)};
      prev = s1_key;
    end else begin
      t = s1_rnd[0] ? s1_key_sub : (rot ^ {24'b0, rcon((s1_rnd >> 1) - 4'd1)});
      prev = s1_state;
    end
    w0 = prev[31:0] ^ t;
    w1 = prev[63:32] ^ w0;
    w2 = prev[95:64] ^ w1;
    w3 = prev[127:96] ^ w2;
    sched = {w3, w2, w1, w0};
  end

  logic s2_valid;
  vec_pkg::aes_op_e s2_op;
  logic [127:0] s2_shifted, s2_key, s2_added, s2_sched;
  always_ff @(posedge i_clk) begin
    if (i_rst) s2_valid <= 1'b0;
    else s2_valid <= s1_valid;
    s2_op <= s1_op;
    s2_shifted <= shifted;
    s2_key <= s1_key;
    s2_added <= added;
    s2_sched <= sched;
  end

  // Stage 3: MixColumns of the shifted state, then the round key, for
  // vaesem; InvMixColumns of the key-added state for vaesdm.
  logic [127:0] mixed, inv_mixed;
  always_comb begin
    for (int c = 0; c < 4; c++) begin
      logic [7:0] e0, e1, e2, e3, f0, f1, f2, f3;
      e0 = s2_shifted[32*c+:8];
      e1 = s2_shifted[32*c+8+:8];
      e2 = s2_shifted[32*c+16+:8];
      e3 = s2_shifted[32*c+24+:8];
      f0 = xtime(e0);
      f1 = xtime(e1);
      f2 = xtime(e2);
      f3 = xtime(e3);
      mixed[32*c+:8] = f0 ^ f1 ^ e1 ^ e2 ^ e3 ^ s2_key[32*c+:8];
      mixed[32*c+8+:8] = e0 ^ f1 ^ f2 ^ e2 ^ e3 ^ s2_key[32*c+8+:8];
      mixed[32*c+16+:8] = e0 ^ e1 ^ f2 ^ f3 ^ e3 ^ s2_key[32*c+16+:8];
      mixed[32*c+24+:8] = f0 ^ e0 ^ e1 ^ e2 ^ f3 ^ s2_key[32*c+24+:8];
    end
    for (int c = 0; c < 4; c++) begin
      logic [7:0] a0, a1, a2, a3;
      logic [7:0] x0, x1, x2, x3, y0, y1, y2, y3, z0, z1, z2, z3;
      a0 = s2_added[32*c+:8];
      a1 = s2_added[32*c+8+:8];
      a2 = s2_added[32*c+16+:8];
      a3 = s2_added[32*c+24+:8];
      x0 = xtime(a0);
      x1 = xtime(a1);
      x2 = xtime(a2);
      x3 = xtime(a3);
      // Multiples 4a and 8a for the inverse coefficients 9, 11, 13, 14.
      y0 = xtime(x0);
      y1 = xtime(x1);
      y2 = xtime(x2);
      y3 = xtime(x3);
      z0 = xtime(y0);
      z1 = xtime(y1);
      z2 = xtime(y2);
      z3 = xtime(y3);
      // 14 = 8+4+2, 11 = 8+2+1, 13 = 8+4+1, 9 = 8+1
      inv_mixed[32*c+:8] = (z0 ^ y0 ^ x0) ^ (z1 ^ x1 ^ a1) ^ (z2 ^ y2 ^ a2) ^ (z3 ^ a3);
      inv_mixed[32*c+8+:8] = (z0 ^ a0) ^ (z1 ^ y1 ^ x1) ^ (z2 ^ x2 ^ a2) ^ (z3 ^ y3 ^ a3);
      inv_mixed[32*c+16+:8] = (z0 ^ y0 ^ a0) ^ (z1 ^ a1) ^ (z2 ^ y2 ^ x2) ^ (z3 ^ x3 ^ a3);
      inv_mixed[32*c+24+:8] = (z0 ^ x0 ^ a0) ^ (z1 ^ y1 ^ a1) ^ (z2 ^ a2) ^ (z3 ^ y3 ^ x3);
    end
  end

  always_ff @(posedge i_clk) begin
    if (i_rst) o_valid <= 1'b0;
    else o_valid <= s2_valid;
    unique case (s2_op)
      vec_pkg::VA_EM: o_result <= mixed;
      vec_pkg::VA_DM: o_result <= inv_mixed;
      vec_pkg::VA_KF1, vec_pkg::VA_KF2: o_result <= s2_sched;
      default: o_result <= s2_added;  // vec_pkg::VA_EF, vec_pkg::VA_DF, vec_pkg::VA_Z
    endcase
  end

endmodule
