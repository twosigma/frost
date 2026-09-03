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
 * axi_behavioral_memory: simulation-only main-memory model, standing in for
 * the board DDR controller and SmartConnect on hardware. AXI4 slave taking
 * single-beat 256-bit transactions (a longer burst raises an error), up to
 * NUM_SLOTS reads and NUM_SLOTS writes in flight, with a parameterized
 * response latency that mimics DDR access time.
 *
 * LATENCY_JITTER adds per-transaction LFSR jitter on top of that latency, the
 * way refresh and arbitration vary the timing of a real controller. A fixed
 * latency structurally hides completion-timing races: it hid the
 * interrupt-orphaned AMO write that real DDR jitter exposed on hardware.
 * Directed and random suites should prefer a jittered run wherever
 * determinism is not required.
 *
 * Completion order follows REORDER. With REORDER=0 each channel completes in
 * issue order: the oldest pending transaction responds first, even if a
 * younger one's latency elapsed earlier. With REORDER=1 a transaction
 * completes as soon as its own latency elapses, and each gets an extra 0..7
 * cycles from the LFSR, so different ids overtake each other. That is the
 * behavior a real controller is permitted across ids and the cache hierarchy
 * has to tolerate. AXI forbids reordering within one id; the model asserts
 * that the master never has two transactions of the same id in flight on a
 * channel, so the question does not arise. Each transaction performs its
 * memory access at completion time.
 *
 * The array is dense and parameter-sized (default 64 MiB) while the decoded
 * region is 1 GiB, and the cache hierarchy above never knows the difference.
 * An access past MEM_BYTES aliases back into the array and warns, up to eight
 * times (see the bounds check at the end of the file). CoreMark-PRO's largest
 * official working set (~6 MiB heap) fits with an order of magnitude to spare.
 * Bump MEM_BYTES via -G for bigger experiments.
 *
 * Storage is word-granular so $readmemh can load sw_ddr.mem directly. That
 * file uses the same objcopy -O verilog --verilog-data-width 4 format as
 * sw.mem and is emitted region-relative: file offset 0 is the cached region
 * base. Addresses on the AXI side are already region-relative, because the
 * bridge subtracts the base. Like hardware DDR contents, the array persists
 * across CPU resets; the caches re-invalidate on reset, so a reloaded program
 * sees fresh memory.
 */
module axi_behavioral_memory #(
    parameter int unsigned LINE_BYTES = 32,
    parameter int unsigned MEM_BYTES = 64 * 1024 * 1024,
    parameter int unsigned ID_BITS = 4,
    parameter int unsigned LATENCY = 30,  // cycles from AR (or AW+W) to R (or B)
    // Per-transaction response-latency jitter: a transaction takes
    // LATENCY + (lfsr % (LATENCY_JITTER+1)) cycles. 0, the default, keeps the
    // model cycle-exact and bit-reproducible for CI. Nonzero mimics real DDR
    // refresh and arbitration jitter, which is what exposes the
    // completion-timing races a fixed latency hides. The LFSR free-runs every
    // cycle, so a run stays deterministic while transaction latencies
    // decorrelate.
    parameter int unsigned LATENCY_JITTER = 0,
    // 1 = complete transactions out of issue order across ids (see header).
    parameter int unsigned REORDER = 0,
    parameter int unsigned NUM_SLOTS = 8,
    parameter bit [15:0] JITTER_SEED = 16'hACE1,
    parameter bit USE_INIT_FILE = 1'b0,
    parameter bit [8*64-1:0] INIT_FILE = "sw_ddr.mem"
) (
    input logic i_clk,
    input logic i_rst,

    // AXI4 slave (single-beat bursts only).
    input  logic                    i_axi_awvalid,
    output logic                    o_axi_awready,
    input  logic [     ID_BITS-1:0] i_axi_awid,
    input  logic [            31:0] i_axi_awaddr,
    input  logic [             7:0] i_axi_awlen,
    input  logic                    i_axi_wvalid,
    output logic                    o_axi_wready,
    input  logic [LINE_BYTES*8-1:0] i_axi_wdata,
    input  logic [  LINE_BYTES-1:0] i_axi_wstrb,
    output logic                    o_axi_bvalid,
    input  logic                    i_axi_bready,
    output logic [     ID_BITS-1:0] o_axi_bid,
    output logic [             1:0] o_axi_bresp,
    input  logic                    i_axi_arvalid,
    output logic                    o_axi_arready,
    input  logic [     ID_BITS-1:0] i_axi_arid,
    input  logic [            31:0] i_axi_araddr,
    input  logic [             7:0] i_axi_arlen,
    output logic                    o_axi_rvalid,
    input  logic                    i_axi_rready,
    output logic [     ID_BITS-1:0] o_axi_rid,
    output logic [LINE_BYTES*8-1:0] o_axi_rdata,
    output logic [             1:0] o_axi_rresp,
    output logic                    o_axi_rlast
);

  localparam int unsigned NumWords = MEM_BYTES / 4;
  localparam int unsigned WordsPerLine = LINE_BYTES / 4;
  localparam int unsigned SlotBits = (NUM_SLOTS > 1) ? $clog2(NUM_SLOTS) : 1;
  localparam int unsigned OrderBits = SlotBits + 1;  // issue sequence numbers

  logic [31:0] memory[NumWords];

`ifndef YOSYS
  // Image load, simulation only: Yosys cannot elaborate $fopen, and this
  // module is never instantiated in a synthesized configuration.
  initial begin
    if (USE_INIT_FILE) begin
      // Probe before $readmemh so flows that never generate a DDR image
      // (e.g. external test-suite builds) run with zeroed memory instead of
      // a missing-file error.
      int init_fd;
      init_fd = $fopen(INIT_FILE, "r");
      if (init_fd != 0) begin
        $fclose(init_fd);
        $readmemh(INIT_FILE, memory);
      end
    end
  end
`endif

  // ---- Latency jitter LFSR (free-running; see LATENCY_JITTER / REORDER) ------
  logic [15:0] jitter_lfsr_q;
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      jitter_lfsr_q <= JITTER_SEED == 16'h0 ? 16'hACE1 : JITTER_SEED;
    end else begin
      jitter_lfsr_q <= {
        jitter_lfsr_q[14:0],
        jitter_lfsr_q[15] ^ jitter_lfsr_q[13] ^ jitter_lfsr_q[12] ^ jitter_lfsr_q[10]
      };
    end
  end
  // The non-power-of-two modulo costs nothing in a simulation-only model and
  // keeps the extra-latency distribution uniform over [0, LATENCY_JITTER].
  // REORDER adds a further 0..7 cycles from the other end of the LFSR so
  // equal-latency transactions still land in different cycles.
  // new_latency is the slot's countdown. A transaction accepted in cycle t is
  // presented in cycle t + LATENCY (+ jitter), the timing of the original
  // single-transaction model, so the slot starts one below the total.
  logic [15:0] total_latency, new_latency;
  assign total_latency = 16'(LATENCY) + 16'(32'(jitter_lfsr_q) % (LATENCY_JITTER + 1)) +
      ((REORDER != 0) ? 16'(jitter_lfsr_q[15:13]) : 16'd0);
  assign new_latency = (total_latency == 16'd0) ? 16'd0 : total_latency - 16'd1;

  // ---- Pending-transaction slots ----------------------------------------------
  // Reads: allocated at AR. Writes: AW and W are paired in arrival order
  // (AXI keeps W beats in AW order for one master). Each slot counts its
  // latency down; a slot with count 0 is ready. Per-field arrays rather than
  // an array of structs: Yosys (which still parses this file) cannot index a
  // struct array with a variable.
  logic [NUM_SLOTS-1:0] rd_valid_q, wr_valid_q;
  logic [ID_BITS-1:0] rd_id_q[NUM_SLOTS], wr_id_q[NUM_SLOTS];
  logic [31:0] rd_addr_q[NUM_SLOTS], wr_addr_q[NUM_SLOTS];
  logic [15:0] rd_lat_q[NUM_SLOTS], wr_lat_q[NUM_SLOTS];
  logic [OrderBits-1:0] rd_order_q[NUM_SLOTS], wr_order_q[NUM_SLOTS];
  logic [LINE_BYTES*8-1:0] wr_data_q[NUM_SLOTS];
  logic [  LINE_BYTES-1:0] wr_strb_q[NUM_SLOTS];

  // AW / W arrival queues (at most NUM_SLOTS each) paired into write slots.
  logic [NUM_SLOTS-1:0] aw_q_valid, w_q_valid;
  logic [ID_BITS-1:0] aw_q_id[NUM_SLOTS];
  logic [31:0] aw_q_addr[NUM_SLOTS];
  logic [LINE_BYTES*8-1:0] w_q_data[NUM_SLOTS];
  logic [LINE_BYTES-1:0] w_q_strb[NUM_SLOTS];

  logic [OrderBits-1:0] rd_seq_q, wr_seq_q;  // next issue sequence numbers

  // Free-slot / queue bookkeeping (combinational scans; sim only).
  logic rd_free, wr_free;
  logic [SlotBits-1:0] rd_free_idx, wr_free_idx;
  logic aw_q_full, w_q_full;
  always_comb begin
    rd_free = 1'b0;
    rd_free_idx = '0;
    for (int s = int'(NUM_SLOTS) - 1; s >= 0; s--) begin
      if (!rd_valid_q[s]) begin
        rd_free = 1'b1;
        rd_free_idx = SlotBits'(s);
      end
    end
    wr_free = 1'b0;
    wr_free_idx = '0;
    for (int s = int'(NUM_SLOTS) - 1; s >= 0; s--) begin
      if (!wr_valid_q[s]) begin
        wr_free = 1'b1;
        wr_free_idx = SlotBits'(s);
      end
    end
    aw_q_full = &aw_q_valid;
    w_q_full  = &w_q_valid;
  end

  assign o_axi_arready = rd_free;
  assign o_axi_awready = !aw_q_full;
  assign o_axi_wready  = !w_q_full;

  // Completion selection. Age is the wrapped distance of a slot's sequence
  // number below the next sequence number: the oldest pending slot has the
  // smallest distance. REORDER=0 completes only the oldest pending slot (once
  // its latency has elapsed); REORDER=1 completes the oldest slot whose
  // latency has elapsed, so a younger transaction overtakes a slower older
  // one.
  function automatic logic [OrderBits-1:0] age_of(input logic [OrderBits-1:0] order,
                                                  input logic [OrderBits-1:0] next_seq);
    age_of = order - next_seq;
  endfunction

  logic rd_pick_valid, wr_pick_valid;
  logic [SlotBits-1:0] rd_pick, wr_pick;
  always_comb begin
    logic [OrderBits-1:0] best_age;
    logic [SlotBits-1:0] oldest;
    logic found;

    // Reads: the oldest pending slot, then the pick.
    found = 1'b0;
    best_age = '1;
    oldest = '0;
    for (int s = 0; s < int'(NUM_SLOTS); s++) begin
      if (rd_valid_q[s] && (!found || age_of(rd_order_q[s], rd_seq_q) < best_age)) begin
        found = 1'b1;
        best_age = age_of(rd_order_q[s], rd_seq_q);
        oldest = SlotBits'(s);
      end
    end
    rd_pick_valid = 1'b0;
    rd_pick = '0;
    if (REORDER == 0) begin
      if (found && rd_lat_q[oldest] == 16'd0) begin
        rd_pick_valid = 1'b1;
        rd_pick = oldest;
      end
    end else begin
      found = 1'b0;
      best_age = '1;
      for (int s = 0; s < int'(NUM_SLOTS); s++) begin
        if (rd_valid_q[s] && rd_lat_q[s] == 16'd0 && (!found || age_of(
                rd_order_q[s], rd_seq_q
            ) < best_age)) begin
          found = 1'b1;
          best_age = age_of(rd_order_q[s], rd_seq_q);
          rd_pick = SlotBits'(s);
          rd_pick_valid = 1'b1;
        end
      end
    end

    // Writes: likewise.
    found = 1'b0;
    best_age = '1;
    oldest = '0;
    for (int s = 0; s < int'(NUM_SLOTS); s++) begin
      if (wr_valid_q[s] && (!found || age_of(wr_order_q[s], wr_seq_q) < best_age)) begin
        found = 1'b1;
        best_age = age_of(wr_order_q[s], wr_seq_q);
        oldest = SlotBits'(s);
      end
    end
    wr_pick_valid = 1'b0;
    wr_pick = '0;
    if (REORDER == 0) begin
      if (found && wr_lat_q[oldest] == 16'd0) begin
        wr_pick_valid = 1'b1;
        wr_pick = oldest;
      end
    end else begin
      found = 1'b0;
      best_age = '1;
      for (int s = 0; s < int'(NUM_SLOTS); s++) begin
        if (wr_valid_q[s] && wr_lat_q[s] == 16'd0 && (!found || age_of(
                wr_order_q[s], wr_seq_q
            ) < best_age)) begin
          found = 1'b1;
          best_age = age_of(wr_order_q[s], wr_seq_q);
          wr_pick = SlotBits'(s);
          wr_pick_valid = 1'b1;
        end
      end
    end
  end

  // ---- Read channel -------------------------------------------------------------
  // Data is read at completion time (the cycle R is first presented) and held
  // while the master withholds rready.
  logic r_presenting_q;
  logic [SlotBits-1:0] r_slot_q;
  logic [LINE_BYTES*8-1:0] rdata_q;

  assign o_axi_rvalid = r_presenting_q;
  assign o_axi_rid    = rd_id_q[r_slot_q];
  assign o_axi_rdata  = rdata_q;
  assign o_axi_rresp  = 2'b00;
  assign o_axi_rlast  = 1'b1;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      rd_valid_q     <= '0;
      rd_seq_q       <= '0;
      r_presenting_q <= 1'b0;
    end else begin
      for (int s = 0; s < int'(NUM_SLOTS); s++) begin
        if (rd_valid_q[s] && rd_lat_q[s] != 16'd0) rd_lat_q[s] <= rd_lat_q[s] - 1'b1;
      end
      if (i_axi_arvalid && o_axi_arready) begin
        rd_valid_q[rd_free_idx] <= 1'b1;
        rd_id_q[rd_free_idx]    <= i_axi_arid;
        rd_addr_q[rd_free_idx]  <= i_axi_araddr;
        rd_lat_q[rd_free_idx]   <= new_latency;
        rd_order_q[rd_free_idx] <= rd_seq_q;
        rd_seq_q                <= rd_seq_q + 1'b1;
      end
      // Present / complete.
      if (r_presenting_q) begin
        if (i_axi_rready) begin
          rd_valid_q[r_slot_q] <= 1'b0;
          r_presenting_q       <= 1'b0;
        end
      end else if (rd_pick_valid) begin
        // Mask into the modeled array: wrong-path speculative loads can
        // target anywhere in the architectural 1 GiB region, and have to
        // complete with don't-care data rather than kill the sim. The bounds
        // warning below flags architectural accesses that exceed the model,
        // so a too-small DDR_MODEL_BYTES is still noticed.
        for (int unsigned w = 0; w < WordsPerLine; w++) begin
          rdata_q[w*32+:32] <= memory[(((rd_addr_q[rd_pick]&(MEM_BYTES-1))>>2)+w)];
        end
        r_slot_q       <= rd_pick;
        r_presenting_q <= 1'b1;
      end
    end
  end

  // ---- Write channel ------------------------------------------------------------
  logic b_presenting_q;
  logic [SlotBits-1:0] b_slot_q;

  assign o_axi_bvalid = b_presenting_q;
  assign o_axi_bid    = wr_id_q[b_slot_q];
  assign o_axi_bresp  = 2'b00;

  // Pairing: the oldest AW with the oldest W. Each side's head is the queue
  // head when the queue is non-empty, otherwise the beat arriving this cycle.
  // An AW and a W presented together therefore form their slot at once,
  // without a trip through the queues. A beat consumed as a head is not
  // queued.
  logic aw_head_valid, w_head_valid, aw_head_live, w_head_live;
  logic [ID_BITS-1:0] aw_head_id;
  logic [31:0] aw_head_addr;
  logic [LINE_BYTES*8-1:0] w_head_data;
  logic [LINE_BYTES-1:0] w_head_strb;
  assign aw_head_live  = !aw_q_valid[0] && i_axi_awvalid && o_axi_awready;
  assign w_head_live   = !w_q_valid[0] && i_axi_wvalid && o_axi_wready;
  assign aw_head_valid = aw_q_valid[0] || aw_head_live;
  assign w_head_valid  = w_q_valid[0] || w_head_live;
  assign aw_head_id    = aw_q_valid[0] ? aw_q_id[0] : i_axi_awid;
  assign aw_head_addr  = aw_q_valid[0] ? aw_q_addr[0] : i_axi_awaddr;
  assign w_head_data   = w_q_valid[0] ? w_q_data[0] : i_axi_wdata;
  assign w_head_strb   = w_q_valid[0] ? w_q_strb[0] : i_axi_wstrb;
  logic pair_ready;
  assign pair_ready = aw_head_valid && w_head_valid && wr_free;
  // Queue pops happen only when the head came from the queue.
  logic aw_pop, w_pop, aw_push, w_push;
  assign aw_pop  = pair_ready && aw_q_valid[0];
  assign w_pop   = pair_ready && w_q_valid[0];
  assign aw_push = i_axi_awvalid && o_axi_awready && !(pair_ready && aw_head_live);
  assign w_push  = i_axi_wvalid && o_axi_wready && !(pair_ready && w_head_live);

  // Next queue occupancy and the push positions (first free index after the
  // pop; the queues are packed from index 0).
  logic [NUM_SLOTS-1:0] aw_q_valid_d, w_q_valid_d;
  logic [SlotBits-1:0] aw_push_idx, w_push_idx;
  always_comb begin
    logic [NUM_SLOTS-1:0] aw_v, w_v;
    aw_v = aw_pop ? (aw_q_valid >> 1) : aw_q_valid;
    w_v = w_pop ? (w_q_valid >> 1) : w_q_valid;
    aw_push_idx = '0;
    w_push_idx = '0;
    for (int k = int'(NUM_SLOTS) - 1; k >= 0; k--) begin
      if (!aw_v[k]) aw_push_idx = SlotBits'(k);
      if (!w_v[k]) w_push_idx = SlotBits'(k);
    end
    if (aw_push) aw_v[aw_push_idx] = 1'b1;
    if (w_push) w_v[w_push_idx] = 1'b1;
    aw_q_valid_d = aw_v;
    w_q_valid_d  = w_v;
  end

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      wr_valid_q     <= '0;
      aw_q_valid     <= '0;
      w_q_valid      <= '0;
      wr_seq_q       <= '0;
      b_presenting_q <= 1'b0;
    end else begin
      for (int s = 0; s < int'(NUM_SLOTS); s++) begin
        if (wr_valid_q[s] && wr_lat_q[s] != 16'd0) wr_lat_q[s] <= wr_lat_q[s] - 1'b1;
      end

      // AW / W queues: shift-register FIFOs, sim only, depth NUM_SLOTS. The
      // pop shifts the data down and the push lands at the post-pop free
      // position computed above, so the queues stay packed from index 0.
      if (aw_pop) begin
        for (int k = 0; k < int'(NUM_SLOTS) - 1; k++) begin
          aw_q_id[k]   <= aw_q_id[k+1];
          aw_q_addr[k] <= aw_q_addr[k+1];
        end
      end
      if (w_pop) begin
        for (int k = 0; k < int'(NUM_SLOTS) - 1; k++) begin
          w_q_data[k] <= w_q_data[k+1];
          w_q_strb[k] <= w_q_strb[k+1];
        end
      end
      if (aw_push) begin
        aw_q_id[aw_push_idx]   <= i_axi_awid;
        aw_q_addr[aw_push_idx] <= i_axi_awaddr;
      end
      if (w_push) begin
        w_q_data[w_push_idx] <= i_axi_wdata;
        w_q_strb[w_push_idx] <= i_axi_wstrb;
      end
      aw_q_valid <= aw_q_valid_d;
      w_q_valid  <= w_q_valid_d;

      // Form a write slot from the two heads.
      if (pair_ready) begin
        wr_valid_q[wr_free_idx] <= 1'b1;
        wr_id_q[wr_free_idx]    <= aw_head_id;
        wr_addr_q[wr_free_idx]  <= aw_head_addr;
        wr_data_q[wr_free_idx]  <= w_head_data;
        wr_strb_q[wr_free_idx]  <= w_head_strb;
        wr_lat_q[wr_free_idx]   <= new_latency;
        wr_order_q[wr_free_idx] <= wr_seq_q;
        wr_seq_q                <= wr_seq_q + 1'b1;
      end

      // Present / complete: perform the strobed write at completion time.
      if (b_presenting_q) begin
        if (i_axi_bready) begin
          wr_valid_q[b_slot_q] <= 1'b0;
          b_presenting_q       <= 1'b0;
        end
      end else if (wr_pick_valid) begin
        for (int unsigned w = 0; w < WordsPerLine; w++) begin
          for (int unsigned b = 0; b < 4; b++) begin
            if (wr_strb_q[wr_pick][w*4+b]) begin
              memory[(((wr_addr_q[wr_pick]&(MEM_BYTES-1))>>2)+w)][b*8+:8] <=
                  wr_data_q[wr_pick][(w*32)+(b*8)+:8];
            end
          end
        end
        b_slot_q       <= wr_pick;
        b_presenting_q <= 1'b1;
      end
    end
  end

`ifndef SYNTHESIS
  // Stall watchdog: an AR held un-accepted for 1024 cycles means the slot
  // machinery wedged. The dump covers both channels so the log alone
  // diagnoses the state.
  int unsigned ar_stall_cnt;
  always_ff @(posedge i_clk) begin
    if (i_rst || !(i_axi_arvalid && !o_axi_arready)) begin
      ar_stall_cnt <= 0;
    end else begin
      ar_stall_cnt <= ar_stall_cnt + 1;
      if (ar_stall_cnt == 1024) begin
        $display("axi_behavioral_memory AR STALL: r_presenting=%0d rready=%0d rd_seq=%0d",
                 r_presenting_q, i_axi_rready, rd_seq_q);
        for (int s = 0; s < int'(NUM_SLOTS); s++)
        $display(
            "  rd[%0d]: v=%0d id=%0d addr=%h lat=%0d order=%0d",
            s,
            rd_valid_q[s],
            rd_id_q[s],
            rd_addr_q[s],
            rd_lat_q[s],
            rd_order_q[s]
        );
        for (int s = 0; s < int'(NUM_SLOTS); s++)
        $display(
            "  wr[%0d]: v=%0d id=%0d aw_q=%0d w_q=%0d",
            s,
            wr_valid_q[s],
            wr_id_q[s],
            aw_q_valid[s],
            w_q_valid[s]
        );
        $error("axi_behavioral_memory: AR stalled for 1024 cycles");
      end
    end
  end

  // Out-of-model accesses alias into the array, which is harmless for
  // wrong-path speculation. Warn a few times so an undersized
  // DDR_MODEL_BYTES against a real working set is still visible. Writes are
  // always architectural, since stores drain post-commit, so a masked write
  // is the strongest signal.
  int unsigned oob_warnings = 0;
  always_ff @(posedge i_clk) begin
    if (!i_rst) begin
      if (i_axi_awvalid && o_axi_awready && i_axi_awlen != 8'd0)
        $error("axi_behavioral_memory: only single-beat write bursts supported");
      if (i_axi_arvalid && o_axi_arready && i_axi_arlen != 8'd0)
        $error("axi_behavioral_memory: only single-beat read bursts supported");
      // AXI forbids reordering two in-flight transactions that share an id.
      // The bridge never issues a duplicate id, and these checks enforce it.
      if (i_axi_arvalid && o_axi_arready) begin
        for (int s = 0; s < int'(NUM_SLOTS); s++) begin
          if (rd_valid_q[s] && rd_id_q[s] == i_axi_arid)
            $error("axi_behavioral_memory: duplicate read id %0d in flight", i_axi_arid);
        end
      end
      if (pair_ready) begin
        for (int s = 0; s < int'(NUM_SLOTS); s++) begin
          if (wr_valid_q[s] && wr_id_q[s] == aw_head_id)
            $error("axi_behavioral_memory: duplicate write id %0d in flight", aw_head_id);
        end
      end
      if (oob_warnings < 8) begin
        if (i_axi_awvalid && o_axi_awready && (i_axi_awaddr + LINE_BYTES > MEM_BYTES)) begin
          // A masked write means DDR_MODEL_BYTES is too small for the program.
          $display("WARNING: axi_behavioral_memory: WRITE 0x%08x beyond modeled %0d bytes",
                   i_axi_awaddr, MEM_BYTES);
          oob_warnings <= oob_warnings + 1;
        end else if (i_axi_arvalid && o_axi_arready &&
                     (i_axi_araddr + LINE_BYTES > MEM_BYTES)) begin
          // Aliased; wrong-path speculative reads are expected to land here.
          $display("WARNING: axi_behavioral_memory: read 0x%08x beyond modeled %0d bytes",
                   i_axi_araddr, MEM_BYTES);
          oob_warnings <= oob_warnings + 1;
        end
      end
    end
  end
`endif

endmodule : axi_behavioral_memory
