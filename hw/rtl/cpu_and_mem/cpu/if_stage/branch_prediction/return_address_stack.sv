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
 * Return address stack: predicts the target of returns.
 *
 * RAS_DEPTH entries (8 by default) held in a circular buffer addressed by a
 * top-of-stack pointer, plus a saturating count of valid entries. A push onto
 * a full stack overwrites the oldest entry.
 *
 * branch_prediction_controller reads the top entry as the target of a BTB hit
 * typed as a return, and IF drives the operations for the packets PD takes
 * whose used prediction came from a typed entry:
 *
 *   push       a call: write the link address above the top
 *   pop        a return: drop the top entry
 *   push+pop   a coroutine swap: replace the top entry
 *
 * A pop or swap on an empty stack changes nothing. IF presents a registered
 * operation one cycle after PD accepts the packet. Outputs include that
 * pending operation, providing the recovery point for this cycle's packet.
 * The edge stores it; its entry write occurs even if reset clears the stack.
 *
 * Recovery restores a packet's pointer, count, and top entry, then applies
 * that instruction's operation. It replaces the pending operation. IF
 * accepts no packet in the cycle before or during restore, so no operation
 * is pending during restore or the following cycle. Restoring the saved top
 * repairs a wrong-path pop followed by a push; overwritten entries below
 * that top are not repaired.
 *
 * A restore that pushes writes two neighboring entries, the restored top and
 * the entry above it. The entries alternate between two banks by pointer
 * parity, so neighbors are in different banks and each bank takes at most one
 * write per cycle.
 */
module return_address_stack #(
    // A power of two, at least 4: the pointers wrap at 2^RAS_PTR_BITS, and the
    // low pointer bit selects the bank.
    parameter int unsigned RAS_DEPTH = 8,
    parameter int unsigned RAS_PTR_BITS = $clog2(RAS_DEPTH)
) (
    input logic i_clk,
    input logic i_rst,

    // The pending operation: IF's registered operation for the packet PD took
    // in the cycle before
    input logic i_push,
    input logic i_pop,
    input logic [riscv_pkg::XLEN-1:0] i_push_address,

    // Misprediction recovery
    input logic i_misprediction,
    input logic [RAS_PTR_BITS-1:0] i_restore_tos,
    input logic [RAS_PTR_BITS:0] i_restore_valid_count,
    input logic [riscv_pkg::XLEN-1:0] i_restore_top,  // The recovery point's top entry
    input logic i_pop_after_restore,  // Pop after restoring (for returns that triggered restore)
    input logic i_push_after_restore,  // Push after restoring (for calls that triggered restore)
    input logic [riscv_pkg::XLEN-1:0] i_push_address_after_restore,

    // The top entry, meaningful while the stack is not empty
    output logic o_nonempty,
    output logic [riscv_pkg::XLEN-1:0] o_top,

    // The recovery point of the packet accepted this cycle
    output logic [RAS_PTR_BITS-1:0] o_tos,
    output logic [  RAS_PTR_BITS:0] o_valid_count
);

  // ===========================================================================
  // State
  // ===========================================================================
  logic [RAS_PTR_BITS-1:0] tos;  // Top of stack pointer (points to current top entry)
  logic [RAS_PTR_BITS:0] valid_count;  // Number of valid entries (0 to RAS_DEPTH)
  logic [RAS_PTR_BITS-1:0] tos_next;
  logic [RAS_PTR_BITS:0] valid_count_next;
  logic stack_not_empty;
  logic [RAS_PTR_BITS:0] count_after_push;

  assign stack_not_empty = (valid_count != '0);
  assign count_after_push = (valid_count != RAS_DEPTH[RAS_PTR_BITS:0]) ?
      valid_count + (RAS_PTR_BITS + 1)'(1) : valid_count;

  // ===========================================================================
  // Operations
  // ===========================================================================
  // The pending operation's effect on the stored state, and the part of it
  // this edge applies: a restore replaces it. A reset overrides a restore but
  // not the pending operation's entry write, which belongs to the cycle
  // before the reset.
  // {pop, push} after restore == 2'b11 is the swap encoding
  // (ex_comb_synthesizer). An empty restored stack has nothing to pop, so the
  // swap does nothing then and the state stays as restored.
  logic restore;
  logic pending_swap, pending_push, pending_pop;
  logic restore_swap_req, do_restore_swap, do_restore_push;
  logic do_swap, do_push;
  assign restore = i_misprediction && !i_rst;
  assign pending_swap = i_push && i_pop && stack_not_empty;
  assign pending_push = i_push && !i_pop;
  assign pending_pop = i_pop && !i_push && stack_not_empty;
  assign restore_swap_req = i_pop_after_restore && i_push_after_restore;
  assign do_restore_swap = restore && restore_swap_req && (i_restore_valid_count != '0);
  assign do_restore_push = restore && i_push_after_restore && !restore_swap_req;
  assign do_swap = !restore && pending_swap;
  assign do_push = !restore && pending_push;

  // ===========================================================================
  // Storage
  // ===========================================================================
  // Two writes, relative to the top (the restored top during recovery):
  //   at the top    a restore writes the saved top entry back, or its swap's
  //                 link address; a swap writes its link address
  //   above it      a push or a restore push writes its link address
  logic [RAS_PTR_BITS-1:0] write_base;
  logic [riscv_pkg::XLEN-1:0] link_address;
  logic top_write, above_write;
  logic [RAS_PTR_BITS-1:0] above_address;
  logic [riscv_pkg::XLEN-1:0] top_write_data;
  assign write_base = restore ? i_restore_tos : tos;
  assign link_address = restore ? i_push_address_after_restore : i_push_address;
  assign top_write = restore || do_swap;
  assign above_write = do_restore_push || do_push;
  assign above_address = write_base + RAS_PTR_BITS'(1);
  assign top_write_data = (do_restore_swap || do_swap) ? link_address : i_restore_top;

  // Bank b holds the entries whose pointer has low bit b, at the pointer's
  // upper bits. The two writes are neighbors, so they never share a bank.
  // The reads cover the stored top and the entry below it, one in each bank:
  // bank 0 reads at the upper bits of tos, bank 1 at those of tos - 1.
  localparam int unsigned BankAddrBits = RAS_PTR_BITS - 1;
  logic [1:0] bank_write_enable;
  logic [1:0][BankAddrBits-1:0] bank_write_address;
  logic [1:0][riscv_pkg::XLEN-1:0] bank_write_data;
  logic [1:0][BankAddrBits-1:0] bank_read_address;
  logic [1:0][riscv_pkg::XLEN-1:0] bank_read_data;
  logic [RAS_PTR_BITS-1:0] below_tos;
  assign below_tos = tos - RAS_PTR_BITS'(1);
  assign bank_read_address[0] = tos[RAS_PTR_BITS-1:1];
  assign bank_read_address[1] = below_tos[RAS_PTR_BITS-1:1];

  for (genvar b = 0; b < 2; b++) begin : gen_bank
    logic top_here;
    assign top_here = top_write && (write_base[0] == 1'(b));
    assign bank_write_enable[b] = top_here || (above_write && (above_address[0] == 1'(b)));
    assign bank_write_address[b] = top_here ? write_base[RAS_PTR_BITS-1:1] :
                                              above_address[RAS_PTR_BITS-1:1];
    assign bank_write_data[b] = top_here ? top_write_data : link_address;

    sdp_dist_ram #(
        .ADDR_WIDTH(BankAddrBits),
        .DATA_WIDTH(riscv_pkg::XLEN)
    ) ras_bank_ram (
        .i_clk,
        .i_write_enable(bank_write_enable[b]),
        .i_write_address(bank_write_address[b]),
        .i_write_data(bank_write_data[b]),
        .i_read_address(bank_read_address[b]),
        .o_read_data(bank_read_data[b])
    );
  end

  // The top after the pending operation: its link address for a push or a
  // swap, the entry below the stored top for a pop, and the stored top
  // otherwise.
  logic [riscv_pkg::XLEN-1:0] stored_top;
  logic [riscv_pkg::XLEN-1:0] below_top;
  assign stored_top = bank_read_data[tos[0]];
  assign below_top = bank_read_data[below_tos[0]];
  assign o_top = (pending_push || pending_swap) ? i_push_address :
                 pending_pop ? below_top : stored_top;

  // ===========================================================================
  // Pointer Update
  // ===========================================================================
  // The pointer and count after the pending operation, which the outputs
  // show and the next edge stores unless a restore replaces them.
  logic [RAS_PTR_BITS-1:0] tos_after_pending;
  logic [  RAS_PTR_BITS:0] valid_count_after_pending;
  always_comb begin
    tos_after_pending = tos;
    valid_count_after_pending = valid_count;
    if (pending_push) begin
      tos_after_pending = tos + RAS_PTR_BITS'(1);
      valid_count_after_pending = count_after_push;
    end else if (pending_pop) begin
      tos_after_pending = tos - RAS_PTR_BITS'(1);
      valid_count_after_pending = valid_count - (RAS_PTR_BITS + 1)'(1);
    end
  end

  assign o_nonempty = (valid_count_after_pending != '0);
  assign o_tos = tos_after_pending;
  assign o_valid_count = valid_count_after_pending;

  always_comb begin
    tos_next = tos_after_pending;
    valid_count_next = valid_count_after_pending;
    if (i_rst) begin
      tos_next = '0;
      valid_count_next = '0;
    end else if (i_misprediction) begin
      // Restore the checkpoint, which excludes the mispredicted instruction's
      // own operation, then apply that operation.
      if (restore_swap_req) begin
        // A swap replaces the top entry and keeps the pointer and count.
        tos_next = i_restore_tos;
        valid_count_next = i_restore_valid_count;
      end else if (i_pop_after_restore && i_restore_valid_count != '0) begin
        tos_next = i_restore_tos - RAS_PTR_BITS'(1);
        valid_count_next = i_restore_valid_count - (RAS_PTR_BITS + 1)'(1);
      end else if (i_push_after_restore) begin
        tos_next = i_restore_tos + RAS_PTR_BITS'(1);
        valid_count_next = (i_restore_valid_count != RAS_DEPTH[RAS_PTR_BITS:0]) ?
            i_restore_valid_count + (RAS_PTR_BITS + 1)'(1) : i_restore_valid_count;
      end else begin
        tos_next = i_restore_tos;
        valid_count_next = i_restore_valid_count;
      end
    end
  end

  always_ff @(posedge i_clk) begin
    tos <= tos_next;
    valid_count <= valid_count_next;
  end

`ifdef RAS_CHECKPOINT_LOCAL_PROOF
  // Reference operation table for both output state after the pending
  // operation and next state after any restore.
  function automatic logic [2*RAS_PTR_BITS:0] reference_step(
      input logic [RAS_PTR_BITS-1:0] from_tos, input logic [RAS_PTR_BITS:0] from_count,
      input logic pop, input logic push);
    logic [RAS_PTR_BITS-1:0] step_tos;
    logic [  RAS_PTR_BITS:0] step_count;
    step_tos   = from_tos;
    step_count = from_count;
    case ({
      pop, push
    })
      2'b10: begin  // pop
        if (from_count != '0) begin
          step_tos   = from_tos - RAS_PTR_BITS'(1);
          step_count = from_count - (RAS_PTR_BITS + 1)'(1);
        end
      end
      2'b01: begin  // push
        step_tos = from_tos + RAS_PTR_BITS'(1);
        step_count = (from_count == RAS_DEPTH[RAS_PTR_BITS:0]) ?
            from_count : from_count + (RAS_PTR_BITS + 1)'(1);
      end
      default: ;  // no operation, or a swap, which keeps the pointer and count
    endcase
    reference_step = {step_tos, step_count};
  endfunction

  // A restore counts only without a reset; the pending operation's entry
  // write happens either way.
  logic reference_restore;
  logic [RAS_PTR_BITS-1:0] base_tos;
  logic [RAS_PTR_BITS:0] base_count;
  logic pop_req, push_req;
  always_comb begin
    reference_restore = i_misprediction && !i_rst;
    base_tos = reference_restore ? i_restore_tos : tos;
    base_count = reference_restore ? i_restore_valid_count : valid_count;
    pop_req = reference_restore ? i_pop_after_restore : i_pop;
    push_req = reference_restore ? i_push_after_restore : i_push;
    assert ({o_tos, o_valid_count} == reference_step(tos, valid_count, i_pop, i_push));
    assert (o_nonempty == (o_valid_count != '0));
    if (i_rst) begin
      assert ({tos_next, valid_count_next} == '0);
    end else begin
      assert ({tos_next, valid_count_next} ==
              reference_step(base_tos, base_count, pop_req, push_req));
    end
  end

  // o_top is the entry at o_tos, or the pending link address when a pending
  // push or a swap on a non-empty stack has not written it yet.
  always_comb begin
    if (i_push && (!i_pop || valid_count != '0)) begin
      assert (o_top == i_push_address);
    end else begin
      assert (bank_read_address[o_tos[0]] == o_tos[RAS_PTR_BITS-1:1]);
      assert (o_top == bank_read_data[o_tos[0]]);
    end
  end

  // Entry writes: a restore writes the saved top entry back at the restored
  // top unless its swap replaces that entry, a swap on a non-empty stack
  // writes its link address at the top, and a push writes it above the top.
  // Every other entry keeps its value.
  logic reference_swap, reference_top_write, reference_above_write;
  logic [riscv_pkg::XLEN-1:0] reference_link, reference_top_data;
  always_comb begin
    reference_swap = pop_req && push_req && (base_count != '0);
    reference_link = reference_restore ? i_push_address_after_restore : i_push_address;
    reference_top_write = reference_restore || reference_swap;
    reference_top_data = reference_swap ? reference_link : i_restore_top;
    reference_above_write = push_req && !pop_req;
  end
  for (genvar i = 0; i < RAS_DEPTH; i++) begin : gen_entry_write_reference
    logic entry_written;
    assign entry_written = bank_write_enable[i%2] &&
                           (bank_write_address[i%2] == BankAddrBits'(i / 2));
    always_comb begin
      if (reference_top_write && (base_tos == RAS_PTR_BITS'(i))) begin
        assert (entry_written && (bank_write_data[i%2] == reference_top_data));
      end else if (reference_above_write && (base_tos + RAS_PTR_BITS'(1) == RAS_PTR_BITS'(i))) begin
        assert (entry_written && (bank_write_data[i%2] == reference_link));
      end else begin
        assert (!entry_written);
      end
    end
  end
`endif

endmodule : return_address_stack
