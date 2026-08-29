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
 * RISC-V Debug Module (Debug Spec 0.13.2 chapter 3, Phase 3 M3, plan D14),
 * minimal profile: one hart (the hartsel plumbing is WARL-0 for now; Phase 5
 * widens it), halt/resume/single-step through the core's Debug Mode take
 * class, abstract "access register" commands for the GPRs, an 8-word program
 * buffer with impebreak, abstractauto over data0/data1, ndmreset, no system
 * bus access (memory is reached through the program buffer, which is what
 * OpenOCD does anyway), authentication absent (always authenticated).
 *
 * How commands execute. The hart, once halted, sits in the debug slice's
 * park loop (riscv_pkg::DebugParkAddr). The module owns the slice's words
 * and lands them in the low BRAM through debug_slice_writer: the fixed words
 * (park, nop, the terminating ebreak, the resume dret) plus the abstract
 * words a0..a2 and the program buffer. An abstract command becomes
 *   a0 = the transfer instruction (csrw ddata,xN for a read; csrr xN,ddata
 *        for a write — ddata is the hart's 64-bit view of {data1,data0}),
 *   a1/a2 = ebreak (no postexec) or nop/nop flowing into the program
 *        buffer, whose implicit ebreak re-parks the hart;
 * the module waits until every dirty slice word is written and visible,
 * then requests the core's go redirect to a0. The re-park on the ebreak (or
 * on any other exception: cmderr 3) completes the command. resumereq is the
 * same go to the resume word; dret leaves Debug Mode and resumeack follows.
 * Slice words are tracked with a dirty vector so a DMI write never has to
 * wait for the writer FIFO: progbuf writes and command starts just mark
 * words dirty and the sync engine pushes them in the background; every go
 * waits for a clean slice.
 *
 * Register map (DMI addresses): data0/1 0x04-0x05, dmcontrol 0x10, dmstatus
 * 0x11, hartinfo 0x12 (nscratch 2, dataaccess 0, datasize 1, dataaddr
 * 0x7B4), abstractcs 0x16 (progbufsize 8, datacount 2), command 0x17,
 * abstractauto 0x18, progbuf0-7 0x20-0x27, haltsum0 0x40; everything else
 * reads zero and ignores writes (sbcs = 0 advertises no system bus).
 * cmderr: 1 busy (an access collided with a running command), 2 not
 * supported (anything but a 32/64-bit GPR access register command),
 * 3 exception (the command's code trapped), 4 halt/resume (the hart was
 * not halted, or was resuming), 7 other (the store mirror overflowed
 * during the command — see debug_slice_writer). dmactive = 0 holds every
 * other register in reset.
 */
module debug_module #(
    parameter int unsigned MEM_BYTE_ADDR_WIDTH = 18
) (
    input logic i_clk,
    input logic i_rst,

    // DMI (from dtm_core)
    input  logic        i_dmi_req_valid,
    input  logic [ 1:0] i_dmi_req_op,      // 1 read, 2 write
    input  logic [ 6:0] i_dmi_req_addr,
    input  logic [31:0] i_dmi_req_data,
    output logic        o_dmi_resp_valid,
    output logic [31:0] o_dmi_resp_data,
    output logic [ 1:0] o_dmi_resp_op,

    // Hart 0 (cpu_ooo's debug seam)
    output logic        o_haltreq,
    output logic        o_go,
    output logic [31:0] o_go_addr,
    output logic [63:0] o_data,           // {data1, data0} as the ddata CSR
    input  logic        i_data_we,
    input  logic [63:0] i_data_wdata,
    input  logic        i_debug_mode,     // halted
    input  logic        i_parked,         // halted and idle in the park loop
    input  logic        i_cmd_err,        // the last command re-parked on an exception
    input  logic        i_go_taken,
    input  logic        i_core_in_reset,
    output logic        o_ndmreset,

    // Slice writer (WRITE requests only; mirrors come from cpu_and_mem)
    output logic o_slice_req_valid,
    output logic [MEM_BYTE_ADDR_WIDTH-1:2] o_slice_word_addr,
    output logic [31:0] o_slice_data,
    input logic i_slice_req_ready,
    input logic i_slice_all_done,
    input logic i_slice_overflow  // pulse, one cycle late: a mirror push was refused
);

  // ---------------------------------------------------------------------------
  // Constants
  // ---------------------------------------------------------------------------
  localparam logic [6:0] AddrData0 = 7'h04;
  localparam logic [6:0] AddrData1 = 7'h05;
  localparam logic [6:0] AddrDmcontrol = 7'h10;
  localparam logic [6:0] AddrDmstatus = 7'h11;
  localparam logic [6:0] AddrHartinfo = 7'h12;
  localparam logic [6:0] AddrAbstractcs = 7'h16;
  localparam logic [6:0] AddrCommand = 7'h17;
  localparam logic [6:0] AddrAbstractauto = 7'h18;
  localparam logic [6:0] AddrProgbuf0 = 7'h20;
  localparam logic [6:0] AddrHaltsum0 = 7'h40;

  localparam logic [31:0] InsnNop = 32'h0000_0013;
  localparam logic [31:0] InsnEbreak = 32'h0010_0073;
  localparam logic [31:0] InsnDret = 32'h7B20_0073;
  localparam logic [31:0] InsnPark = 32'h0000_006F;  // jal x0, 0

  localparam int unsigned ProgbufWords = riscv_pkg::DebugProgbufWords;
  // Slice word index map (see riscv_pkg::DebugSliceBase): 0 park, 1 nop,
  // 2..4 a0..a2, 5..12 progbuf, 13 impebreak, 14 dret, 15 ebreak.
  localparam int unsigned SliceWords = 16;
  localparam int unsigned IdxA0 = 2;
  localparam int unsigned IdxProgbuf = 5;
  localparam int unsigned IdxImpebreak = 13;
  localparam int unsigned IdxDret = 14;
  localparam int unsigned IdxEbreak = 15;

  localparam logic [2:0] CmderrNone = 3'd0;
  localparam logic [2:0] CmderrBusy = 3'd1;
  localparam logic [2:0] CmderrNotSupported = 3'd2;
  localparam logic [2:0] CmderrException = 3'd3;
  localparam logic [2:0] CmderrHaltResume = 3'd4;
  localparam logic [2:0] CmderrOther = 3'd7;

  // ---------------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------------
  logic dmactive_q;
  logic dm_rst;  // everything but dmactive resets while inactive
  assign dm_rst = i_rst || !dmactive_q;

  logic haltreq_q, ndmreset_q, resumeack_q, havereset_q;
  logic [31:0] data0_q, data1_q;
  logic [31:0] progbuf_q[ProgbufWords];
  logic [1:0] autoexecdata_q;
  logic [31:0] command_q;
  logic [2:0] cmderr_q;
  logic overflow_seen_q;
  logic [31:0] abs_word_q[3];
  logic [SliceWords-1:0] dirty_q;

  typedef enum logic [2:0] {
    CmdIdle,
    CmdSync,       // wait for a clean, visible slice
    CmdGo,         // request the redirect to a0
    CmdWaitStart,  // the hart leaves the park loop
    CmdWaitDone,   // ...and re-parks
    CmdCheck       // one cycle later: judge the command once the park cycle's
                   // (registered) overflow pulse has arrived
  } cmd_state_e;
  cmd_state_e cmd_state_q;

  typedef enum logic [1:0] {
    ResIdle,
    ResSync,
    ResGo,
    ResWait   // the hart leaves Debug Mode
  } res_state_e;
  res_state_e res_state_q;

  logic cmd_busy, res_busy;
  assign cmd_busy = (cmd_state_q != CmdIdle);
  assign res_busy = (res_state_q != ResIdle);

  logic halted, unavail;
  assign halted  = i_debug_mode && !i_core_in_reset;
  assign unavail = i_core_in_reset;

  // ---------------------------------------------------------------------------
  // DMI decode
  // ---------------------------------------------------------------------------
  logic dmi_read, dmi_write;
  assign dmi_read  = i_dmi_req_valid && (i_dmi_req_op == 2'd1);
  assign dmi_write = i_dmi_req_valid && (i_dmi_req_op == 2'd2);
  logic [ 6:0] addr;
  logic [31:0] wdata;
  assign addr  = i_dmi_req_addr;
  assign wdata = i_dmi_req_data;

  logic sel_progbuf;
  logic [2:0] progbuf_idx;
  assign sel_progbuf = (addr[6:3] == AddrProgbuf0[6:3]);  // 0x20..0x27
  assign progbuf_idx = addr[2:0];

  logic [31:0] dmstatus, dmcontrol_rd, hartinfo, abstractcs, abstractauto_rd;
  always_comb begin
    dmstatus = '0;
    dmstatus[22] = 1'b1;  // impebreak
    dmstatus[19] = havereset_q;  // allhavereset
    dmstatus[18] = havereset_q;  // anyhavereset
    dmstatus[17] = resumeack_q;  // allresumeack
    dmstatus[16] = resumeack_q;  // anyresumeack
    dmstatus[13] = unavail;  // allunavail
    dmstatus[12] = unavail;  // anyunavail
    dmstatus[11] = !halted && !unavail;  // allrunning
    dmstatus[10] = !halted && !unavail;  // anyrunning
    dmstatus[9] = halted;  // allhalted
    dmstatus[8] = halted;  // anyhalted
    dmstatus[7] = 1'b1;  // authenticated
    dmstatus[3:0] = 4'd2;  // version: 0.13
    dmcontrol_rd = '0;
    dmcontrol_rd[1] = ndmreset_q;
    dmcontrol_rd[0] = dmactive_q;
    hartinfo = '0;
    hartinfo[23:20] = 4'd2;  // nscratch
    hartinfo[16] = 1'b0;  // dataaccess: CSR-shadowed
    hartinfo[15:12] = 4'd1;  // datasize (CSRs)
    hartinfo[11:0] = riscv_pkg::CsrDdata;  // dataaddr
    abstractcs = '0;
    abstractcs[28:24] = 5'(ProgbufWords);
    abstractcs[12] = cmd_busy;
    abstractcs[10:8] = cmderr_q;
    abstractcs[3:0] = 4'd2;  // datacount
    abstractauto_rd = '0;
    abstractauto_rd[1:0] = autoexecdata_q;
  end

  logic [31:0] rdata;
  always_comb begin
    rdata = '0;
    if (dmactive_q) begin
      unique case (addr)
        AddrData0:        rdata = data0_q;
        AddrData1:        rdata = data1_q;
        AddrDmcontrol:    rdata = dmcontrol_rd;
        AddrDmstatus:     rdata = dmstatus;
        AddrHartinfo:     rdata = hartinfo;
        AddrAbstractcs:   rdata = abstractcs;
        AddrCommand:      rdata = command_q;
        AddrAbstractauto: rdata = abstractauto_rd;
        AddrHaltsum0:     rdata = {31'b0, halted};
        default:          rdata = sel_progbuf ? progbuf_q[progbuf_idx] : '0;
      endcase
    end else if (addr == AddrDmcontrol) begin
      rdata = dmcontrol_rd;
    end
  end

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      o_dmi_resp_valid <= 1'b0;
      o_dmi_resp_data  <= '0;
      o_dmi_resp_op    <= 2'd0;
    end else begin
      o_dmi_resp_valid <= i_dmi_req_valid;
      o_dmi_resp_data  <= rdata;
      o_dmi_resp_op    <= 2'd0;
    end
  end

  // ---------------------------------------------------------------------------
  // Command validation and instruction synthesis
  // ---------------------------------------------------------------------------
  logic cmd_write_req, cmd_autoexec_req, cmd_start_req;
  assign cmd_write_req = dmi_write && dmactive_q && (addr == AddrCommand);
  assign cmd_autoexec_req = dmactive_q && (dmi_read || dmi_write) &&
      ((addr == AddrData0 && autoexecdata_q[0]) || (addr == AddrData1 && autoexecdata_q[1]));
  assign cmd_start_req = cmd_write_req || cmd_autoexec_req;
  // The command to evaluate: the written value, or the retained one.
  logic [31:0] cmd_value;
  assign cmd_value = cmd_write_req ? wdata : command_q;

  logic [7:0] cmd_type;
  logic [2:0] cmd_aarsize;
  logic cmd_postinc, cmd_postexec, cmd_transfer, cmd_write;
  logic [15:0] cmd_regno;
  assign cmd_type = cmd_value[31:24];
  assign cmd_aarsize = cmd_value[22:20];
  assign cmd_postinc = cmd_value[19];
  assign cmd_postexec = cmd_value[18];
  assign cmd_transfer = cmd_value[17];
  assign cmd_write = cmd_value[16];
  assign cmd_regno = cmd_value[15:0];

  logic cmd_unsupported;
  assign cmd_unsupported = (cmd_type != 8'd0) || cmd_postinc ||
      (cmd_transfer && ((cmd_regno[15:5] != 11'h080) ||  // GPRs x0..x31 only
      (cmd_aarsize != 3'd2 && cmd_aarsize != 3'd3) || (cmd_write && cmd_aarsize != 3'd3)));

  logic [4:0] cmd_xn;
  assign cmd_xn = cmd_regno[4:0];
  logic [31:0] insn_xfer;
  // csrrw x0, ddata, xN (read the GPR into the data pair) or
  // csrrs xN, ddata, x0 (write the data pair into the GPR).
  assign insn_xfer = cmd_write ? {riscv_pkg::CsrDdata, 5'd0, 3'b010, cmd_xn, 7'b1110011} :
                                 {riscv_pkg::CsrDdata, cmd_xn, 3'b001, 5'd0, 7'b1110011};

  // ---------------------------------------------------------------------------
  // Register writes, command/resume sequencing
  // ---------------------------------------------------------------------------
  logic cmd_accept;  // a command starts this cycle
  assign cmd_accept = cmd_start_req && (cmderr_q == CmderrNone) && !cmd_busy && !res_busy &&
      halted && i_parked && !cmd_unsupported;

  // Slice word contents by index (the sync engine's data source).
  function automatic logic [31:0] slice_word(input int unsigned idx);
    if (idx == 0) slice_word = InsnPark;
    else if (idx == 1) slice_word = InsnNop;
    else if (idx < IdxProgbuf) slice_word = abs_word_q[idx-IdxA0];
    else if (idx < IdxImpebreak) slice_word = progbuf_q[idx-IdxProgbuf];
    else if (idx == IdxImpebreak) slice_word = InsnEbreak;
    else if (idx == IdxDret) slice_word = InsnDret;
    else slice_word = InsnEbreak;
  endfunction

  // Sync engine: push the lowest dirty word when the writer is ready.
  logic [3:0] sync_idx;
  logic sync_any;
  always_comb begin
    sync_any = 1'b0;
    sync_idx = 4'd0;
    for (int i = SliceWords - 1; i >= 0; i--) begin
      if (dirty_q[i]) begin
        sync_any = 1'b1;
        sync_idx = 4'(i);
      end
    end
  end
  assign o_slice_req_valid = sync_any;
  assign o_slice_word_addr =
      (MEM_BYTE_ADDR_WIDTH - 2)'((riscv_pkg::DebugSliceBase >> 2) + 32'(sync_idx));
  assign o_slice_data = slice_word(32'(sync_idx));
  logic sync_fire;
  assign sync_fire = sync_any && i_slice_req_ready;
  logic slice_clean;
  assign slice_clean = !sync_any && i_slice_all_done;

  logic dmactive_q_prev;
  logic dmactive_rise;
  assign dmactive_rise = dmactive_q && !dmactive_q_prev;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      dmactive_q      <= 1'b0;
      dmactive_q_prev <= 1'b0;
    end else begin
      dmactive_q_prev <= dmactive_q;
      if (dmi_write && (addr == AddrDmcontrol)) dmactive_q <= wdata[0];
    end
  end

  always_ff @(posedge i_clk) begin
    if (dm_rst) begin
      haltreq_q   <= 1'b0;
      ndmreset_q  <= 1'b0;
      resumeack_q <= 1'b0;
      havereset_q <= 1'b0;
      data0_q     <= '0;
      data1_q     <= '0;
      for (int i = 0; i < ProgbufWords; i++) progbuf_q[i] <= '0;
      autoexecdata_q  <= 2'b00;
      command_q       <= '0;
      cmderr_q        <= CmderrNone;
      overflow_seen_q <= 1'b0;
      for (int i = 0; i < 3; i++) abs_word_q[i] <= InsnEbreak;
      dirty_q     <= '0;
      cmd_state_q <= CmdIdle;
      res_state_q <= ResIdle;
    end else begin
      // The hart was (or is being) reset: sticky until acknowledged.
      if (i_core_in_reset) havereset_q <= 1'b1;

      // dmactive rise: (re)initialize the slice. A parked hart is fetching
      // words 0/1 continuously, so those two are left alone in that case.
      if (dmactive_rise) begin
        dirty_q <= i_debug_mode ? {SliceWords{1'b1}} & ~16'h0003 : {SliceWords{1'b1}};
      end

      // Slice sync engine.
      if (sync_fire) dirty_q[sync_idx] <= 1'b0;

      // ---- DMI writes ----
      if (dmi_write) begin
        unique case (addr)
          AddrDmcontrol: begin
            haltreq_q  <= wdata[31];
            ndmreset_q <= wdata[1];
            if (wdata[28]) havereset_q <= 1'b0;  // ackhavereset
            if (wdata[30]) begin  // resumereq
              resumeack_q <= 1'b0;
              if (halted && !cmd_busy && !res_busy) res_state_q <= ResSync;
            end
          end
          AddrAbstractcs: begin
            cmderr_q <= cmderr_q & ~wdata[10:8];  // W1C
          end
          AddrAbstractauto: begin
            if (cmd_busy) begin
              if (cmderr_q == CmderrNone) cmderr_q <= CmderrBusy;
            end else begin
              autoexecdata_q <= wdata[1:0];
            end
          end
          AddrData0, AddrData1: begin
            if (cmd_busy) begin
              if (cmderr_q == CmderrNone) cmderr_q <= CmderrBusy;
            end else if (addr == AddrData0) begin
              data0_q <= wdata;
            end else begin
              data1_q <= wdata;
            end
          end
          AddrCommand: begin
            if (cmd_busy) begin
              if (cmderr_q == CmderrNone) cmderr_q <= CmderrBusy;
            end else if (cmderr_q == CmderrNone) begin
              command_q <= wdata;
            end
          end
          default: begin
            if (sel_progbuf) begin
              if (cmd_busy) begin
                if (cmderr_q == CmderrNone) cmderr_q <= CmderrBusy;
              end else begin
                progbuf_q[progbuf_idx] <= wdata;
                dirty_q[IdxProgbuf+32'(progbuf_idx)] <= 1'b1;
              end
            end
          end
        endcase
      end
      // A DMI read of data0/1 with a command in flight is a busy error too.
      if (dmi_read && (addr == AddrData0 || addr == AddrData1) && cmd_busy &&
          (cmderr_q == CmderrNone)) begin
        cmderr_q <= CmderrBusy;
      end

      // ---- The hart's ddata writes (csrw ddata) ----
      if (i_data_we) begin
        data0_q <= i_data_wdata[31:0];
        data1_q <= i_data_wdata[63:32];
      end

      // ---- Command start ----
      if (cmd_start_req && (cmderr_q == CmderrNone) && !cmd_busy) begin
        if (res_busy || !halted || !i_parked) begin
          cmderr_q <= CmderrHaltResume;
        end else if (cmd_unsupported) begin
          cmderr_q <= CmderrNotSupported;
        end
      end
      if (cmd_accept) begin
        abs_word_q[0]     <= cmd_transfer ? insn_xfer : InsnNop;
        abs_word_q[1]     <= cmd_postexec ? InsnNop : InsnEbreak;
        abs_word_q[2]     <= cmd_postexec ? InsnNop : InsnEbreak;
        dirty_q[IdxA0+:3] <= 3'b111;
        overflow_seen_q   <= 1'b0;
        cmd_state_q       <= CmdSync;
      end
      if (i_slice_overflow) overflow_seen_q <= 1'b1;

      // ---- Command sequencing ----
      unique case (cmd_state_q)
        CmdIdle: ;
        CmdSync: if (slice_clean) cmd_state_q <= CmdGo;
        CmdGo: if (i_go_taken) cmd_state_q <= CmdWaitStart;
        CmdWaitStart: if (!i_parked) cmd_state_q <= CmdWaitDone;
        CmdWaitDone: if (i_parked) cmd_state_q <= CmdCheck;
        CmdCheck: begin
          // i_cmd_err is sticky until the next go; i_slice_overflow arrives one
          // cycle late, so together with the sticky flag this covers every
          // mirror push refused up to and including the park cycle.
          if (i_cmd_err) cmderr_q <= CmderrException;
          else if (overflow_seen_q || i_slice_overflow) cmderr_q <= CmderrOther;
          cmd_state_q <= CmdIdle;
        end
        default: cmd_state_q <= CmdIdle;
      endcase

      // ---- Resume sequencing ----
      unique case (res_state_q)
        ResIdle: ;
        ResSync: if (slice_clean) res_state_q <= ResGo;
        ResGo:   if (i_go_taken) res_state_q <= ResWait;
        ResWait: begin
          if (!i_debug_mode) begin
            resumeack_q <= 1'b1;
            res_state_q <= ResIdle;
          end
        end
        default: res_state_q <= ResIdle;
      endcase
    end
  end

  // ---------------------------------------------------------------------------
  // Hart-facing outputs
  // ---------------------------------------------------------------------------
  assign o_haltreq = haltreq_q;
  assign o_go = (cmd_state_q == CmdGo) || (res_state_q == ResGo);
  assign o_go_addr = (res_state_q == ResGo) ? riscv_pkg::DebugResumeAddr :
                                              riscv_pkg::DebugAbstractAddr;
  assign o_data = {data1_q, data0_q};
  assign o_ndmreset = ndmreset_q;

`ifndef SYNTHESIS
  always_ff @(posedge i_clk) begin
    if (!dm_rst) begin
      if ((cmd_state_q == CmdGo) && (res_state_q == ResGo))
        $error("debug_module: command and resume go requests overlap");
      if (o_go && !i_debug_mode) $error("debug_module: go requested outside Debug Mode");
    end
  end
`endif

endmodule : debug_module
