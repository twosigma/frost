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
 * window_skip_triage — TEMPORARY on-silicon instrumentation for the Genesys2
 * rv64 fetch-window-skip hunt (coremark_pro_zip: one aligned 8-byte fetch
 * window skipped after an early-recovery redirect; the skipped callee-saved
 * restores later trap with mcause=4 via a stale register).  Remove once the
 * bug is root-caused.
 *
 * Two sticky trigger sources, first-event-wins: the if_stage low-BRAM
 * served-window incoherence observation (i_incoherent) and the trap-taken
 * pulse (i_trap_taken).  The FIRST assertion of either after reset freezes a
 * capture bank.  Once frozen and the console UART has been quiet for
 * QUIET_CYCLES, the module takes over the UART (exactly like hang_triage:
 * while o_active is high its byte stream replaces the CPU's) and prints one
 * line, then re-emits every ~REEMIT_CYCLES so the line cannot be missed:
 *
 *   "\n!!WSKIP t=TT p=PPPPPPPP s=SSSSSSSS f=FFFFFFFF r=RRRRRRRR q=QQ n=NN\n"
 *
 *   t  trigger source byte: bit0 = served-window incoherence fired first,
 *      bit1 = trap fired first (both bits when they landed the same cycle)
 *   p  if_stage pc_reg[31:0] on the triggering cycle
 *   s  if_stage served-window address tag i_served_addr[31:0], same cycle
 *   f  cpu_and_mem fetch_address (the presented fetch ask) at the freeze edge
 *   r  last from_ex_comb redirect target (branch_target_address[31:0],
 *      registered in cpu_ooo every cycle branch_taken=1)
 *   q  recovery-arm qualifiers captured with that redirect:
 *      bit0=early_mispredict_active, bit1=mispredict_recovery_pending,
 *      bit2=trap_taken_reg, bits 7:3 = 0
 *   n  saturating count of ALL incoherence events since reset (keeps
 *      counting after the freeze; each emitted line snapshots it)
 *
 * This answers the four-way split for the skip: (a) the redirect target was
 * wrong (r/q say which recovery arm minted it), (b) the front end served one
 * fetch-word ahead of a correct target (t=01 with p/s disagreeing — the
 * incoherence the sim-only covers guard exempts in the low-BRAM region),
 * (c) neither (prediction minted the bad PC), or (d) something else.
 *
 * The module is always fully functional; enabling is the instantiation
 * site's job (cpu_and_mem generate on ENABLE_WINDOW_SKIP_TRIAGE, driven 1
 * only by the Genesys2 board top).
 */
module window_skip_triage #(
    // Console-quiet stretch required after the freeze before the first UART
    // takeover (~2 ms @ 133 MHz).  Simulation overrides this small (via
    // frost's WINDOW_SKIP_QUIET_CYCLES -G parameter) so the burst lands
    // inside a test's natural UART gaps.
    parameter logic [31:0] QUIET_CYCLES  = 32'd266_667,
    // Gap between re-emits (~1 s @ 133 MHz).
    parameter logic [31:0] REEMIT_CYCLES = 32'd134_000_000
) (
    input logic i_clk,
    input logic i_rst,

    // Trigger sources (first assertion after reset freezes the capture bank).
    input logic        i_incoherent,
    input logic        i_trap_taken,
    // Capture-bank inputs, sampled on the freeze edge.  pc/served are the
    // if_stage debug exports registered on the offending cycle, so the pair
    // is coherent with the i_incoherent pulse they accompany.
    input logic [31:0] i_pc_reg,
    input logic [31:0] i_served_addr,
    input logic [31:0] i_fetch_addr,
    input logic [31:0] i_last_redirect,
    input logic [ 7:0] i_redirect_quals,
    // Console write this cycle (CPU-side, pre-mux): resets the quiet timer.
    input logic        i_uart_busy,

    input  logic       i_uart_ready,
    output logic       o_active,
    output logic       o_wr_en,
    output logic [7:0] o_wr_data
);

  // ---- Freeze bank + incoherence counter ------------------------------------
  logic frozen_q;
  logic [7:0] cap_src;
  logic [7:0] cap_quals;
  logic [31:0] cap_pc;
  logic [31:0] cap_served;
  logic [31:0] cap_fetch;
  logic [31:0] cap_redirect;
  logic [7:0] incoherent_count_q;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      frozen_q           <= 1'b0;
      incoherent_count_q <= 8'd0;
      cap_src            <= 8'd0;
      cap_quals          <= 8'd0;
      cap_pc             <= 32'd0;
      cap_served         <= 32'd0;
      cap_fetch          <= 32'd0;
      cap_redirect       <= 32'd0;
    end else begin
      if (i_incoherent && incoherent_count_q != 8'hFF) begin
        incoherent_count_q <= incoherent_count_q + 8'd1;
      end
      if (!frozen_q && (i_incoherent || i_trap_taken)) begin
        frozen_q     <= 1'b1;
        cap_src      <= {6'd0, i_trap_taken, i_incoherent};
        cap_quals    <= i_redirect_quals;
        cap_pc       <= i_pc_reg;
        cap_served   <= i_served_addr;
        cap_fetch    <= i_fetch_addr;
        cap_redirect <= i_last_redirect;
      end
    end
  end

  // ---- Console-quiet timer --------------------------------------------------
  logic [31:0] quiet_cnt;
  always_ff @(posedge i_clk) begin
    if (i_rst || i_uart_busy) quiet_cnt <= 32'd0;
    else if (quiet_cnt != 32'hFFFFFFFF) quiet_cnt <= quiet_cnt + 32'd1;
  end

  // ---- ASCII emit FSM -------------------------------------------------------
  typedef enum logic [1:0] {
    EM_IDLE,
    EM_PREFIX,
    EM_FIELD,
    EM_GAP
  } em_state_e;
  em_state_e em_state;
  logic [3:0] pcnt;
  localparam logic [2:0] FieldLast = 3'd6;
  logic [ 2:0] fld;
  logic [ 3:0] fpos;
  logic [ 7:0] snap_n;
  logic [31:0] reemit_cnt;

  function automatic logic [7:0] hex4(input logic [3:0] n);
    hex4 = (n < 4'd10) ? (8'h30 + {4'b0, n}) : (8'h41 + {4'b0, n} - 8'd10);
  endfunction

  // Prefix: "\n!!WSKIP " (9 bytes).
  function automatic logic [7:0] prefix_byte(input logic [3:0] i);
    case (i)
      4'd0:    prefix_byte = 8'h0A;
      4'd1:    prefix_byte = "!";
      4'd2:    prefix_byte = "!";
      4'd3:    prefix_byte = "W";
      4'd4:    prefix_byte = "S";
      4'd5:    prefix_byte = "K";
      4'd6:    prefix_byte = "I";
      4'd7:    prefix_byte = "P";
      default: prefix_byte = " ";
    endcase
  endfunction

  function automatic logic [7:0] label_byte(input logic [2:0] f);
    case (f)
      3'd0:    label_byte = "t";
      3'd1:    label_byte = "p";
      3'd2:    label_byte = "s";
      3'd3:    label_byte = "f";
      3'd4:    label_byte = "r";
      3'd5:    label_byte = "q";
      default: label_byte = "n";
    endcase
  endfunction

  // Per-field hex width in nibbles: byte fields (t/q/n) print 2, the 32-bit
  // address fields (p/s/f/r) print 8.
  logic [3:0] fld_nibs;
  always_comb begin
    case (fld)
      3'd0, 3'd5, 3'd6: fld_nibs = 4'd2;
      default:          fld_nibs = 4'd8;
    endcase
  end

  logic [31:0] fld_val;
  always_comb begin
    case (fld)
      3'd0:    fld_val = {24'd0, cap_src};
      3'd1:    fld_val = cap_pc;
      3'd2:    fld_val = cap_served;
      3'd3:    fld_val = cap_fetch;
      3'd4:    fld_val = cap_redirect;
      3'd5:    fld_val = {24'd0, cap_quals};
      default: fld_val = {24'd0, snap_n};
    endcase
  end

  // Field layout: fpos 0 = label, 1 = '=', 2..fld_nibs+1 = hex nibbles
  // (most significant first), fld_nibs+2 = separator (space; newline after
  // the last field).
  logic [3:0] nib_idx;
  always_comb begin
    nib_idx = 4'd0;
    if (fpos >= 4'd2 && fpos <= fld_nibs + 4'd1) nib_idx = fld_nibs + 4'd1 - fpos;
  end

  logic [7:0] emit_byte;
  always_comb begin
    emit_byte = 8'h20;
    unique case (em_state)
      EM_PREFIX: emit_byte = prefix_byte(pcnt);
      EM_FIELD: begin
        if (fpos == 4'd0) emit_byte = label_byte(fld);
        else if (fpos == 4'd1) emit_byte = "=";
        else if (fpos == fld_nibs + 4'd2) emit_byte = (fld == FieldLast) ? 8'h0A : 8'h20;
        else emit_byte = hex4(fld_val[nib_idx*4+:4]);
      end
      default:   emit_byte = 8'h20;
    endcase
  end

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      em_state   <= EM_IDLE;
      pcnt       <= 4'd0;
      fld        <= 3'd0;
      fpos       <= 4'd0;
      snap_n     <= 8'd0;
      reemit_cnt <= 32'd0;
      o_active   <= 1'b0;
      o_wr_en    <= 1'b0;
      o_wr_data  <= 8'd0;
    end else begin
      o_wr_en <= 1'b0;
      case (em_state)
        EM_IDLE: begin
          if (frozen_q && quiet_cnt >= QUIET_CYCLES) begin
            // The bank itself froze at the trigger; only the (still
            // counting) incoherence count needs a per-line snapshot.
            snap_n   <= incoherent_count_q;
            o_active <= 1'b1;
            pcnt     <= 4'd0;
            em_state <= EM_PREFIX;
          end
        end
        // Every emit state gates its push on (i_uart_ready && !o_wr_en): the
        // push is REGISTERED, so in the cycle right after issuing one the
        // FIFO's occupancy (hence i_uart_ready) does not yet reflect it --
        // sampling ready alone back-to-back double-pushes into a single free
        // slot and DROPS a byte (hang_triage saw this on silicon as "!HANG"
        // instead of "!!HANG").  The one-cycle bubble is invisible at UART
        // rates.
        EM_PREFIX:
        if (i_uart_ready && !o_wr_en) begin
          o_wr_en   <= 1'b1;
          o_wr_data <= emit_byte;
          if (pcnt == 4'd8) begin
            fld <= 3'd0;
            fpos <= 4'd0;
            em_state <= EM_FIELD;
          end else pcnt <= pcnt + 4'd1;
        end
        EM_FIELD:
        if (i_uart_ready && !o_wr_en) begin
          o_wr_en   <= 1'b1;
          o_wr_data <= emit_byte;
          if (fpos == fld_nibs + 4'd2) begin
            if (fld == FieldLast) begin
              em_state   <= EM_GAP;
              reemit_cnt <= REEMIT_CYCLES;
            end else begin
              fld  <= fld + 3'd1;
              fpos <= 4'd0;
            end
          end else fpos <= fpos + 4'd1;
        end
        EM_GAP: begin
          o_active <= 1'b0;
          if (reemit_cnt <= 32'd1) em_state <= EM_IDLE;
          else reemit_cnt <= reemit_cnt - 32'd1;
        end
        default: em_state <= EM_IDLE;
      endcase
    end
  end

endmodule : window_skip_triage
