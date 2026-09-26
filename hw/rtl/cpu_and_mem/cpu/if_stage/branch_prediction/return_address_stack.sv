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
 * typed as a return, and IF drives the operations when it hands PD a packet
 * whose used prediction came from a typed entry:
 *
 *   push       a call: write the link address above the top
 *   pop        a return: drop the top entry
 *   push+pop   a coroutine swap: replace the top entry
 *
 * A pop or swap on an empty stack changes nothing. The operation updates the
 * state on the clock edge, so the registered state (o_tos, o_valid_count, and
 * the entry o_top reads) is the state before the accepted packet's own
 * operation, which is the recovery point IF attaches to that packet.
 *
 * Misprediction recovery restores a packet's recovery point and then applies
 * the mispredicted instruction's own operation (i_pop_after_restore for a
 * return, i_push_after_restore for a call, both for a coroutine swap). It takes
 * priority over an operation in the same cycle; IF never accepts a packet then.
 * The recovery point includes its top entry (i_restore_top), which the restore
 * writes back: a wrong-path pop followed by a push overwrites that entry. An
 * entry below the top that a deeper wrong path overwrites (two pops, then a
 * push) stays damaged.
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

    // Operation for the packet IF hands to PD this cycle
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

    // Registered state: the recovery point of the packet accepted this cycle
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
  // A push onto a full stack overwrites the oldest entry, so the count
  // saturates at RAS_DEPTH.
  assign count_after_push = (valid_count != RAS_DEPTH[RAS_PTR_BITS:0]) ?
      valid_count + (RAS_PTR_BITS + 1)'(1) : valid_count;

  // ===========================================================================
  // Operations
  // ===========================================================================
  // {pop, push} after restore == 2'b11 is the swap encoding
  // (ex_comb_synthesizer). An empty restored stack has nothing to pop, so the
  // swap does nothing then and the state stays as restored.
  logic restore_swap_req, do_restore_swap, do_restore_push;
  logic do_swap, do_push, do_pop;
  assign restore_swap_req = i_pop_after_restore && i_push_after_restore;
  assign do_restore_swap = i_misprediction && restore_swap_req && (i_restore_valid_count != '0);
  assign do_restore_push = i_misprediction && i_push_after_restore && !restore_swap_req;
  assign do_swap = !i_misprediction && i_push && i_pop && stack_not_empty;
  assign do_push = !i_misprediction && i_push && !i_pop;
  assign do_pop = !i_misprediction && i_pop && !i_push && stack_not_empty;

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
  assign write_base = i_misprediction ? i_restore_tos : tos;
  assign link_address = i_misprediction ? i_push_address_after_restore : i_push_address;
  assign top_write = !i_rst && (i_misprediction || do_swap);
  assign above_write = !i_rst && (do_restore_push || do_push);
  assign above_address = write_base + RAS_PTR_BITS'(1);
  assign top_write_data = (do_restore_swap || do_swap) ? link_address : i_restore_top;

  // Bank b holds the entries whose pointer has low bit b, at the pointer's
  // upper bits. The two writes are neighbors, so they never share a bank.
  localparam int unsigned BankAddrBits = RAS_PTR_BITS - 1;
  logic [1:0] bank_write_enable;
  logic [1:0][BankAddrBits-1:0] bank_write_address;
  logic [1:0][riscv_pkg::XLEN-1:0] bank_write_data;
  logic [1:0][riscv_pkg::XLEN-1:0] bank_read_data;

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
        .i_read_address(tos[RAS_PTR_BITS-1:1]),
        .o_read_data(bank_read_data[b])
    );
  end

  assign o_top = bank_read_data[tos[0]];

  assign o_nonempty = stack_not_empty;
  assign o_tos = tos;
  assign o_valid_count = valid_count;

  // ===========================================================================
  // Pointer Update
  // ===========================================================================
  always_comb begin
    tos_next = tos;
    valid_count_next = valid_count;
    if (i_rst) begin
      tos_next = '0;
      valid_count_next = '0;
    end else if (i_misprediction) begin
      // Restore the checkpoint, which excludes the mispredicted instruction's
      // own operation, then apply that operation.
      if (restore_swap_req) begin
        // A swap replaces the top entry and keeps both pointers.
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
    end else if (do_push) begin
      tos_next = tos + RAS_PTR_BITS'(1);
      valid_count_next = count_after_push;
    end else if (do_pop) begin
      tos_next = tos - RAS_PTR_BITS'(1);
      valid_count_next = valid_count - (RAS_PTR_BITS + 1)'(1);
    end
  end

  always_ff @(posedge i_clk) begin
    tos <= tos_next;
    valid_count <= valid_count_next;
  end

`ifdef RAS_CHECKPOINT_LOCAL_PROOF
  // Reference next state for the ras_checkpoint formal target, written as one
  // case over the operation instead of the priority chain above.
  logic [RAS_PTR_BITS-1:0] tos_next_reference;
  logic [  RAS_PTR_BITS:0] valid_count_next_reference;
  logic [RAS_PTR_BITS-1:0] base_tos;
  logic [  RAS_PTR_BITS:0] base_count;
  logic pop_req, push_req;
  always_comb begin
    base_tos   = i_misprediction ? i_restore_tos : tos;
    base_count = i_misprediction ? i_restore_valid_count : valid_count;
    pop_req    = i_misprediction ? i_pop_after_restore : i_pop;
    push_req   = i_misprediction ? i_push_after_restore : i_push;
    tos_next_reference = base_tos;
    valid_count_next_reference = base_count;
    unique case ({
      pop_req, push_req
    })
      2'b10: begin  // pop
        if (base_count != '0) begin
          tos_next_reference = base_tos - RAS_PTR_BITS'(1);
          valid_count_next_reference = base_count - (RAS_PTR_BITS + 1)'(1);
        end
      end
      2'b01: begin  // push
        tos_next_reference = base_tos + RAS_PTR_BITS'(1);
        valid_count_next_reference =
            (base_count == RAS_DEPTH[RAS_PTR_BITS:0]) ? base_count :
                                                         base_count + (RAS_PTR_BITS + 1)'(1);
      end
      default: ;  // no operation, or a swap, which keeps both pointers
    endcase
    if (i_rst) begin
      tos_next_reference = '0;
      valid_count_next_reference = '0;
    end
  end
  always_comb begin
    assert ({tos_next, valid_count_next} == {tos_next_reference, valid_count_next_reference});
  end

  // Entry writes: a restore writes the saved top entry back at the restored
  // top unless its swap replaces that entry, a swap on a non-empty stack
  // writes its link address at the top, and a push writes it above the top.
  // Every other entry keeps its value.
  logic reference_swap, reference_top_write, reference_above_write;
  logic [riscv_pkg::XLEN-1:0] reference_link, reference_top_data;
  always_comb begin
    reference_swap = pop_req && push_req && (base_count != '0);
    reference_link = i_misprediction ? i_push_address_after_restore : i_push_address;
    reference_top_write = !i_rst && (i_misprediction || reference_swap);
    reference_top_data = reference_swap ? reference_link : i_restore_top;
    reference_above_write = !i_rst && push_req && !pop_req;
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
