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
 * nic_pkg: constants shared by the NIC's blocks, its benches and the
 * software header (sw/lib/include/nic.h mirrors the offsets).
 *
 * Register offsets are byte offsets inside the NIC's 4 KiB window. Slice 2
 * adds the ring, link, PHY and counter registers; the interrupt block's
 * registers are here first.
 */
package nic_pkg;
  // Interrupt block registers.
  localparam logic [11:0] IrqStatusOffset = 12'h040;  // RW1C
  localparam logic [11:0] IrqMaskOffset = 12'h044;  // RW
  localparam logic [11:0] RxItrOffset = 12'h048;  // RW: [15:0] delay ticks, [23:16] max
  localparam logic [11:0] TxItrOffset = 12'h04C;  // RW
  localparam logic [11:0] TickOffset = 12'h050;  // RW: core cycles per tick
  localparam logic [11:0] IrqMaskSetOffset = 12'h054;  // W1S
  localparam logic [11:0] IrqMaskClrOffset = 12'h058;  // W1C

  // Interrupt status / mask bits.
  localparam int unsigned IrqBitRx = 0;  // moderated RX completions
  localparam int unsigned IrqBitTx = 1;  // moderated TX completions
  // A frame was dropped (MAC overflow, filter, bad descriptor).
  localparam int unsigned IrqBitRxDrop = 2;
  localparam int unsigned IrqBitLink = 3;  // LINK.CARRIER changed
  localparam int unsigned IrqBitDescErr = 4;  // a descriptor completed with ERR
  localparam int unsigned IrqBits = 5;

  // Frame beats inside the NIC (the FIFO entries): 64 data bits and a code,
  // {last, bytes - 1}; a nonfinal beat always carries 8 bytes.
  localparam int unsigned BeatCodeBits = 4;
  localparam int unsigned BeatCodeLastBit = 3;  // bytes - 1 in [2:0]
  function automatic logic [3:0] beat_code(input logic last, input logic [3:0] bytes);
    beat_code = {last, 3'(bytes - 4'd1)};
  endfunction

  // Request kinds an engine hands the DMA front-end (steered back with
  // the response, otherwise opaque to it).
  localparam logic [1:0] ReqKindData = 2'd0;  // frame data line (write for RX, read for TX)
  localparam logic [1:0] ReqKindDesc = 2'd1;  // descriptor line read
  localparam logic [1:0] ReqKindStatus = 2'd2;  // descriptor word 2 write (DD)

  // Descriptors: 16 bytes, two per line; word 2 is the status word HW writes.
  localparam int unsigned DescBytes = 16;
  localparam int unsigned DescStatusByte = 8;  // word 2
  localparam int unsigned MaxFrameBytes = 9216;
  localparam int unsigned TxWord1BitSop = 16;
  localparam int unsigned TxWord1BitEop = 17;
  localparam int unsigned StatusBitDd = 16;
  localparam int unsigned StatusBitTrunc = 17;
  localparam int unsigned StatusBitErr = 18;
  localparam int unsigned StatusBitAbort = 19;
  // Completion flags the engines report with each status write's response:
  // {ABORT, ERR, TRUNC} (DD is implied).
  localparam int unsigned FlagTrunc = 0;
  localparam int unsigned FlagErr = 1;
  localparam int unsigned FlagAbort = 2;
endpackage : nic_pkg
