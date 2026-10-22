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
 * Incoming MSI Controllers (RISC-V AIA 1.0, chapter 3) for NUM_HARTS harts:
 * a machine-level and a supervisor-level interrupt file per hart
 * (imsic_file.sv), with the hart side of each file on its own port for the
 * hart's CSR file. There are no guest interrupt files: FROST has no H
 * extension. README.md beside this file gives the memory map, the ports and
 * the implementation choices.
 *
 * Memory map, as the AIA arranges it and Linux and OpenSBI expect: the
 * machine-level files form one region at M_BASE_ADDR and the
 * supervisor-level files another at S_BASE_ADDR, one 4 KiB page per hart,
 * hart h's page at base + 0x1000 * h. Each region spans 2^k pages, k =
 * clog2(NUM_HARTS), and its base is aligned to that size. In a page:
 *   0x000  seteipnum_le  writing identity i sets its pending bit
 *   0x004  seteipnum_be  the same, with i in big-endian byte order
 * A write of identity 0 or above NUM_IDS, or of anything else in the
 * regions (other offsets, pages of hart indices at or above NUM_HARTS),
 * is ignored. Every address in the regions reads zero, so the module has no
 * read port: the SoC returns zero for loads there.
 *
 * The write port takes one naturally aligned 32-bit store, by physical
 * address; the AIA requires other access sizes to be ignored, so the SoC
 * asserts i_wr_en only for a 32-bit store, below 4 GiB. Writes outside both
 * regions are ignored. A write is decoded into a register and reaches its
 * file a cycle later, which keeps the writes to one file in order.
 *
 * Hart-side ports are flat vectors: hart h's file uses bits [8h+7:8h] of
 * i_*_iselect, [64h+63:64h] of o_*_ireg, i_*_ireg_keep and i_*_ireg_set,
 * [32h+31:32h] of o_*_topei, and bit h of the rest. i_aplic_meip and
 * i_aplic_seip carry an APLIC's direct-mode lines to the files whose
 * eidelivery is 0x40000000; o_meip and o_seip are the lines for each hart's
 * mip.MEIP and mip.SEIP.
 */
module imsic #(
    parameter int unsigned NUM_HARTS = 1,  // hart indices 0..NUM_HARTS-1 (at most 4096)
    // Identities per interrupt file: one less than a multiple of 64, 63 to 2047.
    parameter int unsigned NUM_IDS = 63,
    // Region bases, each aligned to 4 KiB times the next power of two of NUM_HARTS.
    parameter logic [31:0] M_BASE_ADDR = 32'h4800_0000,
    parameter logic [31:0] S_BASE_ADDR = 32'h4810_0000,
    // eidelivery supports 0x40000000, delivery by an APLIC in direct mode.
    parameter bit APLIC_DELIVERY = 1'b1
) (
    input logic i_clk,
    input logic i_rst,

    // MSI write: one naturally aligned 32-bit store.
    input logic        i_wr_en,
    input logic [31:0] i_wr_addr,  // physical address; bits [1:0] ignored
    input logic [31:0] i_wr_data,

    // Machine-level files: miselect/mireg and mtopei, by hart.
    input  logic [ 8*NUM_HARTS-1:0] i_m_iselect,
    output logic [64*NUM_HARTS-1:0] o_m_ireg,
    output logic [   NUM_HARTS-1:0] o_m_ireg_illegal,
    input  logic [   NUM_HARTS-1:0] i_m_ireg_we,
    input  logic [64*NUM_HARTS-1:0] i_m_ireg_keep,
    input  logic [64*NUM_HARTS-1:0] i_m_ireg_set,
    output logic [32*NUM_HARTS-1:0] o_m_topei,
    input  logic [   NUM_HARTS-1:0] i_m_topei_claim,

    // Supervisor-level files: siselect/sireg and stopei, by hart.
    input  logic [ 8*NUM_HARTS-1:0] i_s_iselect,
    output logic [64*NUM_HARTS-1:0] o_s_ireg,
    output logic [   NUM_HARTS-1:0] o_s_ireg_illegal,
    input  logic [   NUM_HARTS-1:0] i_s_ireg_we,
    input  logic [64*NUM_HARTS-1:0] i_s_ireg_keep,
    input  logic [64*NUM_HARTS-1:0] i_s_ireg_set,
    output logic [32*NUM_HARTS-1:0] o_s_topei,
    input  logic [   NUM_HARTS-1:0] i_s_topei_claim,

    // An APLIC's direct-mode lines, and the external interrupt lines, by hart.
    input  logic [NUM_HARTS-1:0] i_aplic_meip,
    input  logic [NUM_HARTS-1:0] i_aplic_seip,
    output logic [NUM_HARTS-1:0] o_meip,
    output logic [NUM_HARTS-1:0] o_seip
);

  localparam int unsigned HartBits = (NUM_HARTS > 1) ? $clog2(NUM_HARTS) : 0;
  // A region holds 2^HartBits pages; its address bits above RegionShift
  // match its base.
  localparam int unsigned RegionShift = 12 + HartBits;
  localparam logic [19:0] PageMask = 20'((1 << HartBits) - 1);

`ifndef SYNTHESIS
  initial begin
    if (NUM_HARTS < 1 || NUM_HARTS > 4096) $fatal(1, "imsic: NUM_HARTS must be 1 to 4096");
    if (((M_BASE_ADDR & 32'((1 << RegionShift) - 1)) != 0) ||
        ((S_BASE_ADDR & 32'((1 << RegionShift) - 1)) != 0))
      $fatal(1, "imsic: M_BASE_ADDR and S_BASE_ADDR must be aligned to their region size");
    if ((M_BASE_ADDR >> RegionShift) == (S_BASE_ADDR >> RegionShift))
      $fatal(1, "imsic: the machine-level and supervisor-level regions overlap");
  end
`endif

  // ---------------------------------------------------------------------------
  // MSI decode: the region, the hart's page, the register, and the identity.
  // ---------------------------------------------------------------------------
  logic wr_m, wr_s, wr_le, wr_be, wr_valid;
  logic [19:0] wr_page;
  logic [31:0] wr_value;
  assign wr_m = i_wr_en && ((i_wr_addr >> RegionShift) == (M_BASE_ADDR >> RegionShift));
  assign wr_s = i_wr_en && ((i_wr_addr >> RegionShift) == (S_BASE_ADDR >> RegionShift));
  assign wr_page = i_wr_addr[31:12] & PageMask;
  assign wr_le = (i_wr_addr[11:2] == 10'h000);
  assign wr_be = (i_wr_addr[11:2] == 10'h001);
  // seteipnum_be holds its identity in big-endian byte order.
  assign wr_value = wr_be ?
      {i_wr_data[7:0], i_wr_data[15:8], i_wr_data[23:16], i_wr_data[31:24]} : i_wr_data;
  assign wr_valid = (wr_le || wr_be) && (wr_value != '0) && (wr_value <= 32'(NUM_IDS));

  // Accesses are whole words, so the byte offset inside the word is unused.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [1:0] byte_offset_unused;
  /* verilator lint_on UNUSEDSIGNAL */
  assign byte_offset_unused = i_wr_addr[1:0];

  // One registered MSI per cycle: a valid bit per file and the identity.
  logic [NUM_HARTS-1:0] msi_m_q, msi_s_q;
  logic [10:0] msi_id_q;
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      msi_m_q <= '0;
      msi_s_q <= '0;
    end else begin
      for (int h = 0; h < int'(NUM_HARTS); h++) begin
        msi_m_q[h] <= wr_m && wr_valid && (wr_page == 20'(h));
        msi_s_q[h] <= wr_s && wr_valid && (wr_page == 20'(h));
      end
    end
    msi_id_q <= wr_value[10:0];
  end

  // ---------------------------------------------------------------------------
  // Interrupt files
  // ---------------------------------------------------------------------------
  for (genvar h = 0; h < int'(NUM_HARTS); h++) begin : gen_hart
    imsic_file #(
        .NUM_IDS(NUM_IDS),
        .APLIC_DELIVERY(APLIC_DELIVERY)
    ) m_file (
        .i_clk,
        .i_rst,
        .i_msi_valid(msi_m_q[h]),
        .i_msi_id(msi_id_q),
        .i_iselect(i_m_iselect[8*h+:8]),
        .o_ireg(o_m_ireg[64*h+:64]),
        .o_ireg_illegal(o_m_ireg_illegal[h]),
        .i_ireg_we(i_m_ireg_we[h]),
        .i_ireg_keep(i_m_ireg_keep[64*h+:64]),
        .i_ireg_set(i_m_ireg_set[64*h+:64]),
        .o_topei(o_m_topei[32*h+:32]),
        .i_topei_claim(i_m_topei_claim[h]),
        .i_aplic_eip(i_aplic_meip[h]),
        .o_eip(o_meip[h])
    );
    imsic_file #(
        .NUM_IDS(NUM_IDS),
        .APLIC_DELIVERY(APLIC_DELIVERY)
    ) s_file (
        .i_clk,
        .i_rst,
        .i_msi_valid(msi_s_q[h]),
        .i_msi_id(msi_id_q),
        .i_iselect(i_s_iselect[8*h+:8]),
        .o_ireg(o_s_ireg[64*h+:64]),
        .o_ireg_illegal(o_s_ireg_illegal[h]),
        .i_ireg_we(i_s_ireg_we[h]),
        .i_ireg_keep(i_s_ireg_keep[64*h+:64]),
        .i_ireg_set(i_s_ireg_set[64*h+:64]),
        .o_topei(o_s_topei[32*h+:32]),
        .i_topei_claim(i_s_topei_claim[h]),
        .i_aplic_eip(i_aplic_seip[h]),
        .o_eip(o_seip[h])
    );
  end

endmodule : imsic
