// Copyright (c) 2026 John Goodacre.
// SPDX-License-Identifier: Apache-2.0

// Ssnpm pointer masking: FROST transforms the base register at MEM_RS issue
// (riscv_pkg::pm_base_transform, a sign extension from bit XLEN-PMLEN-1) and
// adds the immediate after it. For every base, 12-bit immediate and offered
// PMLEN this proves that the result is what the Pointer Masking extension's
// ignore transformation of base + imm gives to every consumer:
//   - Sv39: the same canonical verdict as the transformed address, and the
//     same address whenever it is canonical.
//   - Bare: the same verdict as the zero-extended transformed address from
//     every PMA predicate the load and store paths use, and the same
//     address whenever the data map accepts it.
//   - xtval: riscv_pkg::pm_tval of the result is the transformed address.
// pmm_warl stores exactly the offered encodings and keeps the old value
// otherwise.
module pointer_masking (
    input logic [63:0] base,
    input logic [11:0] imm12,
    input logic        pmlen16,
    input logic [ 1:0] written,
    input logic [ 1:0] old
);
  localparam int unsigned XLEN = riscv_pkg::XLEN;
  riscv_pkg::pm_mode_t mode;
  logic [XLEN-1:0] imm, base_t, sum_t, ea, ref_virt, ref_bare;

  assign mode = pmlen16 ? riscv_pkg::EnvcfgPmmPmlen16 : riscv_pkg::EnvcfgPmmPmlen7;
  assign imm = {{(XLEN - 12) {imm12[11]}}, imm12};
  assign base_t = riscv_pkg::pm_base_transform(base, mode);
  assign sum_t = base_t + imm;
  assign ea = base + imm;
  // The extension's ignore transformation, written out independently.
  assign ref_virt = pmlen16 ? {{16{ea[47]}}, ea[47:0]} : {{7{ea[56]}}, ea[56:0]};
  assign ref_bare = pmlen16 ? {16'b0, ea[47:0]} : {7'b0, ea[56:0]};

  logic offered;
  assign offered = pmlen16 ? riscv_pkg::SsnpmPmlen16 : riscv_pkg::SsnpmPmlen7;

  always_comb begin
    // The FROST map offers both values.
    p_pmlen7_offered : assert (riscv_pkg::SsnpmPmlen7);
    p_pmlen16_offered : assert (riscv_pkg::SsnpmPmlen16);
    // Off leaves the base alone; on, only the masked bits change.
    p_off_identity : assert (riscv_pkg::pm_base_transform(base, riscv_pkg::EnvcfgPmmOff) == base);
    p_low_bits_kept : assert (base_t[47:0] == base[47:0]);

    // Sv39.
    p_sv39_verdict :
    assert (riscv_pkg::sv39_va_canonical(sum_t) == riscv_pkg::sv39_va_canonical(ref_virt));
    p_sv39_address : assert (!riscv_pkg::sv39_va_canonical(sum_t) || (sum_t == ref_virt));

    if (offered) begin
      // Bare: every untranslated PMA decode the wrapper and LQ use.
      p_bare_data : assert (riscv_pkg::pma_data_ok(sum_t) == riscv_pkg::pma_data_ok(ref_bare));
      p_bare_store : assert (riscv_pkg::pma_store_ok(sum_t) == riscv_pkg::pma_store_ok(ref_bare));
      p_bare_atomic :
      assert (riscv_pkg::pma_atomic_ok(sum_t) == riscv_pkg::pma_atomic_ok(ref_bare));
      p_bare_cached :
      assert (riscv_pkg::pma_cached_ok(sum_t) == riscv_pkg::pma_cached_ok(ref_bare));
      p_bare_device :
      assert (riscv_pkg::pma_device_ok(sum_t) == riscv_pkg::pma_device_ok(ref_bare));
      p_bare_address :
      assert (!(riscv_pkg::pma_data_ok(
          sum_t
      ) || riscv_pkg::pma_store_ok(
          sum_t
      )) || (sum_t == ref_bare));
    end

    // xtval.
    p_tval_virt : assert (riscv_pkg::pm_tval(sum_t, mode, 1'b1) == ref_virt);
    p_tval_bare : assert (riscv_pkg::pm_tval(sum_t, mode, 1'b0) == ref_bare);
    p_tval_off : assert (riscv_pkg::pm_tval(ea, riscv_pkg::EnvcfgPmmOff, pmlen16) == ea);

    // senvcfg.PMM WARL.
    p_warl :
    assert (riscv_pkg::pmm_warl(
        written, old
    ) == (((written == 2'b00) || (written == 2'b10) || (written == 2'b11)) ? written : old));
  end
endmodule
