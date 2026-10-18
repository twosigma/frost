// Copyright (c) 2026 John Goodacre.
// SPDX-License-Identifier: Apache-2.0
// Directed elaboration check for the single raw-DDR-capacity build setting.
module test_ddr_width_config;
  task automatic check_rejected(input logic [63:0] addr);
    assert (!riscv_pkg::pma_cached_ok(addr));
    assert (!riscv_pkg::pma_fetch_ok(addr));
    assert (!riscv_pkg::pma_data_ok(addr));
    assert (!riscv_pkg::pma_store_ok(addr));
    assert (!riscv_pkg::pma_atomic_ok(addr));
    assert (riscv_pkg::fetch_verdict(addr).bare_fault0);
  endtask

  task automatic check_next_page(input logic [63:0] addr);
    logic [63:0] next_page;
    next_page = (addr & ~64'hfff) + 64'h1000;
    assert (riscv_pkg::pma_fetch_next_page_ok(addr) ==
            riscv_pkg::pma_fetch_ok(next_page))
      else $fatal(1, "next-page PMA mismatch at %h", addr);
  endtask

  initial begin
    assert (riscv_pkg::DdrCapacityLog2Bytes inside {[30:37]})
      else $fatal(1, "supported raw DDR capacity is 1 through 128 GiB, powers of two");
    assert (riscv_pkg::DdrAxiAddrBits == riscv_pkg::DdrCapacityLog2Bytes)
      else $fatal(1, "DDR AXI offset width disagrees with configured capacity");
    assert (riscv_pkg::PhysAddrBits ==
            ((riscv_pkg::DdrCapacityLog2Bytes == 30) ? 32 :
             riscv_pkg::DdrCapacityLog2Bytes + 1))
      else $fatal(1, "physical width must include the nonzero DDR base");
    assert (riscv_pkg::pma_cached_ok(riscv_pkg::DdrBase));
    assert (riscv_pkg::pma_cached_ok(riscv_pkg::DdrLimit - 64));
    assert (!riscv_pkg::pma_cached_ok(riscv_pkg::DdrBase - 64));
    assert (!riscv_pkg::pma_cached_ok(riscv_pkg::DdrLimit));
    check_rejected(riscv_pkg::DdrLimit);
    check_rejected(riscv_pkg::DdrLimit + 64);
    check_rejected(riscv_pkg::DdrLimit + 64'h1_0000_0000);
    check_rejected(64'hffff_ffff_ffff_ffc0);
    assert (riscv_pkg::pma_data_ok(riscv_pkg::DdrLimit - 1));
    assert (riscv_pkg::pma_store_ok(riscv_pkg::DdrLimit - 1));
    assert (riscv_pkg::pma_fetch_ok(riscv_pkg::DdrLimit - 1));
    assert (riscv_pkg::pma_cached_ok(riscv_pkg::DdrBase + (1 << 30)) ==
            (riscv_pkg::DdrCapacityLog2Bytes > 30));
    if (riscv_pkg::DdrCapacityLog2Bytes > 32) begin
      assert (riscv_pkg::pma_cached_ok(riscv_pkg::DdrBase + 64'h1_0000_0000));
    end
    check_next_page(64'h0000_0000_0001_e000);
    check_next_page(64'h0000_0000_0001_f000);
    check_next_page(riscv_pkg::DdrBase - 4096);
    check_next_page(riscv_pkg::DdrBase);
    check_next_page(riscv_pkg::DdrLimit - 8192);
    check_next_page(riscv_pkg::DdrLimit - 4096);
    check_next_page(riscv_pkg::DdrLimit);
    check_next_page(64'hffff_ffff_ffff_f000);
    $finish;
  end
endmodule
