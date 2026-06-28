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
 * hang_triage — on-silicon classifier for the silent boot hang.
 *
 * Trigger: the console UART goes quiet (every hang flavor stops the kernel
 * printing). On a quiet stretch it streams ASCII over the UART and re-emits
 * periodically so the trajectory is visible:
 *
 *   "\n!!HANG c=<commits> t=<timer> q=<cread_req> v=<cread_resp> w=<wreq:wdone>"
 *   " l=<pc_lo> h=<pc_hi> m=<mtime_lo> n=<mtime_hi> x=<mtimecmp_lo>"
 *   " y=<mtimecmp_hi> d=<mtimecmp-mtime lo> p=<irq/status>"
 *   "\nH <hist[0]> <hist[1]> ... <hist[63]>\n"
 *
 *   c   committed instructions     climbing => busy-loop; frozen => wedge
 *   t   mtimecmp writes (timer)     frozen  => timer service stopped
 *   q/v cached read req/resp        q>v frozen => a DDR read never returned
 *   w   cached write {req:done}     req>done => a DDR write never landed
 *   l/h pc_lo..pc_hi               PC range executed since last console output
 *   r/s last retired PCs            slot-1 / slot-2 commit PCs
 *   m/n mtime lo/hi                CLINT time at snapshot
 *   x/y mtimecmp lo/hi             CLINT compare at snapshot
 *   d   mtimecmp-mtime low word     high bit set usually means compare is overdue
 *   p   irq/status bits:
 *       [0]=raw mtime>=mtimecmp, [1]=registered MTIP, [2]=MSIP, [3]=MEIP,
 *       [4]=mie.MTIE, [5]=mstatus.MIE, [7:6]=priv, [8]=trap, [9]=mret
 *   H   PC histogram, 64 buckets of 64 KiB keyed on pc[21:16] (kernel pc[31]=1)
 *       => cycle-weighted hot region of the livelock (bucket k = 0x8000_0000 +
 *       k*0x10000). The hottest bucket localizes the spin to a 64 KiB window.
 *
 * Non-latching: any console write resets the quiet timer + PC window.
 */
module hang_triage #(
    parameter logic [31:0] QUIET_CYCLES  = 32'd400_000_000,  // ~3 s @133 MHz
    parameter logic [31:0] REEMIT_CYCLES = 32'd134_000_000   // ~1 s
) (
    input logic i_clk,
    input logic i_rst,

    input logic        i_commit,
    input logic        i_timer_event,
    input logic        i_cread_req,
    input logic        i_cread_resp,
    input logic        i_cwrite_req,
    input logic        i_cwrite_done,
    input logic [31:0] i_pc,
    input logic        i_commit0_valid,
    input logic [31:0] i_commit0_pc,
    input logic        i_commit1_valid,
    input logic [31:0] i_commit1_pc,
    input logic [31:0] i_mtime_lo,
    input logic [31:0] i_mtime_hi,
    input logic [31:0] i_mtimecmp_lo,
    input logic [31:0] i_mtimecmp_hi,
    input logic [31:0] i_mtimecmp_delta_lo,
    input logic [31:0] i_irq_status,
    input logic        i_uart_busy,

    input  logic       i_uart_ready,
    output logic       o_active,
    output logic       o_wr_en,
    output logic [7:0] o_wr_data
);

  // ---- Free-running event counters ------------------------------------------
  logic [31:0] cnt_commit, cnt_timer, cnt_cread_req, cnt_cread_resp;
  logic [31:0] cnt_cwrite_req, cnt_cwrite_done;
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      cnt_commit      <= 32'd0;
      cnt_timer       <= 32'd0;
      cnt_cread_req   <= 32'd0;
      cnt_cread_resp  <= 32'd0;
      cnt_cwrite_req  <= 32'd0;
      cnt_cwrite_done <= 32'd0;
    end else begin
      if (i_commit) cnt_commit <= cnt_commit + 32'd1;
      if (i_timer_event) cnt_timer <= cnt_timer + 32'd1;
      if (i_cread_req) cnt_cread_req <= cnt_cread_req + 32'd1;
      if (i_cread_resp) cnt_cread_resp <= cnt_cread_resp + 32'd1;
      if (i_cwrite_req) cnt_cwrite_req <= cnt_cwrite_req + 32'd1;
      if (i_cwrite_done) cnt_cwrite_done <= cnt_cwrite_done + 32'd1;
    end
  end

  // ---- PC histogram: 64 x 64 KiB buckets, kernel PCs only -------------------
  logic [31:0] hist[64];
  logic [5:0] pc_bucket;
  assign pc_bucket = i_pc[21:16];
  always_ff @(posedge i_clk) begin
    if (i_rst || i_uart_busy) begin
      // Clear while the console is active so the histogram reflects ONLY the
      // quiet (hang) window, not the pre-hang boot execution.
      for (int b = 0; b < 64; b++) hist[b] <= 32'd0;
    end else if (i_pc[31]) begin  // count only kernel-range PCs
      hist[pc_bucket] <= hist[pc_bucket] + 32'd1;
    end
  end

  // ---- Console-idle timer + PC window ---------------------------------------
  logic [31:0] quiet_cnt;
  logic [31:0] pc_lo, pc_hi;
  logic [31:0] last_commit0_pc, last_commit1_pc;
  logic win_reset;
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      quiet_cnt       <= 32'd0;
      pc_lo           <= 32'hFFFFFFFF;
      pc_hi           <= 32'h00000000;
      last_commit0_pc <= 32'd0;
      last_commit1_pc <= 32'd0;
    end else if (i_uart_busy) begin
      quiet_cnt <= 32'd0;
      pc_lo     <= i_pc;
      pc_hi     <= i_pc;
      if (i_commit0_valid) last_commit0_pc <= i_commit0_pc;
      if (i_commit1_valid) last_commit1_pc <= i_commit1_pc;
    end else begin
      if (quiet_cnt != 32'hFFFFFFFF) quiet_cnt <= quiet_cnt + 32'd1;
      if (i_commit0_valid) last_commit0_pc <= i_commit0_pc;
      if (i_commit1_valid) last_commit1_pc <= i_commit1_pc;
      if (win_reset) begin
        pc_lo <= i_pc;
        pc_hi <= i_pc;
      end else begin
        if (i_pc < pc_lo) pc_lo <= i_pc;
        if (i_pc > pc_hi) pc_hi <= i_pc;
      end
    end
  end

  // ---- Snapshot -------------------------------------------------------------
  logic [31:0] snap_c, snap_t, snap_q, snap_v, snap_w, snap_l, snap_h, snap_r, snap_s;
  logic [31:0] snap_m, snap_n, snap_x, snap_y, snap_d, snap_p;

  // ---- ASCII emit FSM -------------------------------------------------------
  typedef enum logic [2:0] {
    EM_IDLE,
    EM_PREFIX,
    EM_FIELD,
    EM_HPRE,
    EM_HIST,
    EM_GAP
  } em_state_e;
  em_state_e em_state;
  logic [3:0] pcnt;
  localparam logic [3:0] FieldLast = 4'd14;
  logic [ 3:0] fld;
  logic [ 3:0] fpos;
  logic [ 5:0] hidx;
  logic [ 3:0] hpos;  // 0..8 within a hist entry
  logic [31:0] reemit_cnt;

  assign win_reset = (em_state == EM_IDLE) && (quiet_cnt >= QUIET_CYCLES);

  function automatic logic [7:0] hex4(input logic [3:0] n);
    hex4 = (n < 4'd10) ? (8'h30 + {4'b0, n}) : (8'h41 + {4'b0, n} - 8'd10);
  endfunction

  function automatic logic [7:0] prefix_byte(input logic [3:0] i);
    case (i)
      4'd0:    prefix_byte = 8'h0A;
      4'd1:    prefix_byte = "!";
      4'd2:    prefix_byte = "!";
      4'd3:    prefix_byte = "H";
      4'd4:    prefix_byte = "A";
      4'd5:    prefix_byte = "N";
      4'd6:    prefix_byte = "G";
      default: prefix_byte = " ";
    endcase
  endfunction

  function automatic logic [7:0] label_byte(input logic [3:0] f);
    case (f)
      4'd0:    label_byte = "c";
      4'd1:    label_byte = "t";
      4'd2:    label_byte = "q";
      4'd3:    label_byte = "v";
      4'd4:    label_byte = "w";
      4'd5:    label_byte = "l";
      4'd6:    label_byte = "h";
      4'd7:    label_byte = "r";
      4'd8:    label_byte = "s";
      4'd9:    label_byte = "m";
      4'd10:   label_byte = "n";
      4'd11:   label_byte = "x";
      4'd12:   label_byte = "y";
      4'd13:   label_byte = "d";
      default: label_byte = "p";
    endcase
  endfunction

  logic [31:0] fld_val;
  always_comb begin
    case (fld)
      4'd0:    fld_val = snap_c;
      4'd1:    fld_val = snap_t;
      4'd2:    fld_val = snap_q;
      4'd3:    fld_val = snap_v;
      4'd4:    fld_val = snap_w;
      4'd5:    fld_val = snap_l;
      4'd6:    fld_val = snap_h;
      4'd7:    fld_val = snap_r;
      4'd8:    fld_val = snap_s;
      4'd9:    fld_val = snap_m;
      4'd10:   fld_val = snap_n;
      4'd11:   fld_val = snap_x;
      4'd12:   fld_val = snap_y;
      4'd13:   fld_val = snap_d;
      default: fld_val = snap_p;
    endcase
  end

  logic [3:0] nib_idx;
  always_comb begin
    nib_idx = 4'd0;
    if (fpos >= 4'd2 && fpos <= 4'd9) nib_idx = 4'd9 - fpos;
  end

  logic [3:0] hnib_idx;
  always_comb begin
    hnib_idx = 4'd0;
    if (hpos <= 4'd7) hnib_idx = 4'd7 - hpos;
  end

  logic [7:0] emit_byte;
  always_comb begin
    emit_byte = 8'h20;
    unique case (em_state)
      EM_PREFIX: emit_byte = prefix_byte(pcnt);
      EM_FIELD: begin
        if (fpos == 4'd0) emit_byte = label_byte(fld);
        else if (fpos == 4'd1) emit_byte = "=";
        else if (fpos == 4'd10) emit_byte = 8'h20;
        else emit_byte = hex4(fld_val[nib_idx*4+:4]);
      end
      EM_HPRE: emit_byte = (pcnt == 4'd0) ? 8'h0A : ((pcnt == 4'd1) ? "H" : " ");
      EM_HIST:
      emit_byte = (hpos == 4'd8) ? ((hidx == 6'd63) ? 8'h0A : 8'h20) :
          hex4(hist[hidx][hnib_idx*4+:4]);
      default: emit_byte = 8'h20;
    endcase
  end

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      em_state   <= EM_IDLE;
      pcnt       <= 4'd0;
      fld        <= 4'd0;
      fpos       <= 4'd0;
      hidx       <= 6'd0;
      hpos       <= 4'd0;
      reemit_cnt <= 32'd0;
      o_active   <= 1'b0;
      o_wr_en    <= 1'b0;
      o_wr_data  <= 8'd0;
    end else begin
      o_wr_en <= 1'b0;
      case (em_state)
        EM_IDLE: begin
          if (quiet_cnt >= QUIET_CYCLES) begin
            snap_c   <= cnt_commit;
            snap_t   <= cnt_timer;
            snap_q   <= cnt_cread_req;
            snap_v   <= cnt_cread_resp;
            snap_w   <= {cnt_cwrite_req[15:0], cnt_cwrite_done[15:0]};
            snap_l   <= pc_lo;
            snap_h   <= pc_hi;
            snap_r   <= last_commit0_pc;
            snap_s   <= last_commit1_pc;
            snap_m   <= i_mtime_lo;
            snap_n   <= i_mtime_hi;
            snap_x   <= i_mtimecmp_lo;
            snap_y   <= i_mtimecmp_hi;
            snap_d   <= i_mtimecmp_delta_lo;
            snap_p   <= i_irq_status;
            o_active <= 1'b1;
            pcnt     <= 4'd0;
            em_state <= EM_PREFIX;
          end
        end
        EM_PREFIX:
        if (i_uart_ready) begin
          o_wr_en   <= 1'b1;
          o_wr_data <= emit_byte;
          if (pcnt == 4'd7) begin
            fld <= 4'd0;
            fpos <= 4'd0;
            em_state <= EM_FIELD;
          end else pcnt <= pcnt + 4'd1;
        end
        EM_FIELD:
        if (i_uart_ready) begin
          o_wr_en   <= 1'b1;
          o_wr_data <= emit_byte;
          if (fpos == 4'd10) begin
            if (fld == FieldLast) begin
              pcnt <= 4'd0;
              em_state <= EM_HPRE;
            end else begin
              fld  <= fld + 4'd1;
              fpos <= 4'd0;
            end
          end else fpos <= fpos + 4'd1;
        end
        EM_HPRE:
        if (i_uart_ready) begin
          o_wr_en   <= 1'b1;
          o_wr_data <= emit_byte;
          if (pcnt == 4'd2) begin
            hidx <= 6'd0;
            hpos <= 4'd0;
            em_state <= EM_HIST;
          end else pcnt <= pcnt + 4'd1;
        end
        EM_HIST:
        if (i_uart_ready) begin
          o_wr_en   <= 1'b1;
          o_wr_data <= emit_byte;
          if (hpos == 4'd8) begin
            if (hidx == 6'd63) begin
              em_state   <= EM_GAP;
              reemit_cnt <= REEMIT_CYCLES;
            end else begin
              hidx <= hidx + 6'd1;
              hpos <= 4'd0;
            end
          end else hpos <= hpos + 4'd1;
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

endmodule : hang_triage
