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
  // Identification, control and status.
  localparam logic [11:0] IdOffset = 12'h000;
  localparam logic [31:0] IdValue = 32'h4E49_4301;  // "NIC", ABI version 1
  localparam logic [11:0] CtrlOffset = 12'h004;
  localparam int unsigned CtrlBitRxEn = 0;
  localparam int unsigned CtrlBitTxEn = 1;
  localparam int unsigned CtrlBitPromisc = 2;
  localparam int unsigned CtrlBitReset = 8;
  localparam logic [11:0] StatusOffset = 12'h008;
  localparam int unsigned StatusBitRxIdle = 0;
  localparam int unsigned StatusBitTxIdle = 1;
  localparam int unsigned StatusBitResetBusy = 2;
  localparam int unsigned StatusBitRxFifoEmpty = 3;
  localparam int unsigned StatusBitRxReady = 4;
  localparam int unsigned StatusBitTxReady = 5;
  localparam int unsigned StatusBitRxConfigErr = 6;
  localparam int unsigned StatusBitTxConfigErr = 7;
  localparam logic [11:0] MacLoOffset = 12'h00C;  // bytes 0..3, byte 0 in bits 7:0
  localparam logic [11:0] MacHiOffset = 12'h010;  // bytes 4..5 in bits 15:0

  // Rings: BASE (32-byte aligned), SIZE (log2 entries, 2..16), TAIL (producer
  // index, RW), HEAD (consumer index, R).
  localparam logic [11:0] RxBaseOffset = 12'h020;
  localparam logic [11:0] RxSizeOffset = 12'h024;
  localparam logic [11:0] RxTailOffset = 12'h028;
  localparam logic [11:0] RxHeadOffset = 12'h02C;
  localparam logic [11:0] TxBaseOffset = 12'h030;
  localparam logic [11:0] TxSizeOffset = 12'h034;
  localparam logic [11:0] TxTailOffset = 12'h038;
  localparam logic [11:0] TxHeadOffset = 12'h03C;
  localparam int unsigned RingSizeLog2Min = 2;
  localparam int unsigned RingSizeLog2Max = 16;

  // Link, PHY.
  localparam logic [11:0] LinkOffset = 12'h060;
  localparam int unsigned LinkBitRxLocked = 0;
  localparam int unsigned LinkBitRxHighBer = 1;
  localparam int unsigned LinkBitRxLocalFault = 2;
  localparam int unsigned LinkBitRxRemoteFault = 3;
  localparam int unsigned LinkBitTxLinkReady = 4;
  localparam int unsigned LinkBitRxSignalOk = 5;
  localparam int unsigned LinkBitTxClkOk = 6;
  localparam int unsigned LinkBitRxClkOk = 7;
  localparam int unsigned LinkBitCarrier = 8;
  localparam logic [11:0] PhyCtrlOffset = 12'h064;
  localparam int unsigned PhyCtrlBitMacLoopback = 0;
  localparam int unsigned PhyCtrlBitPhyReset = 1;
  localparam int unsigned PhyCtrlBitPmaLoopback = 2;
  localparam int unsigned PhyCtrlBitTxDisable = 3;
  localparam logic [11:0] PhyStatusOffset = 12'h068;
  localparam int unsigned PhyStatusBitClkShared = 0;
  localparam int unsigned PhyStatusBitGtResetDone = 1;
  localparam int unsigned PhyStatusBitCdrLock = 2;
  localparam int unsigned PhyStatusBitModulePresent = 3;
  localparam int unsigned PhyStatusBitLos = 4;

  // 64-bit counters at CounterBaseOffset + 8 * index.
  localparam logic [11:0] CounterBaseOffset = 12'h080;
  localparam int unsigned CntRxFrames = 0;
  localparam int unsigned CntRxBytes = 1;
  localparam int unsigned CntRxFiltered = 2;
  localparam int unsigned CntRxTruncated = 3;
  localparam int unsigned CntRxDescErr = 4;
  localparam int unsigned CntRxAborted = 5;
  localparam int unsigned CntTxFrames = 6;
  localparam int unsigned CntTxBytes = 7;
  localparam int unsigned CntTxDescErr = 8;
  localparam int unsigned CntTxAborted = 9;
  localparam int unsigned CntRxMacOverflow = 10;
  localparam int unsigned CntRxMacBadFrame = 11;
  localparam int unsigned CntRxMacBadFcs = 12;
  localparam int unsigned CntRxPcsBadBlock = 13;
  localparam int unsigned CntTxMacDrop = 14;
  localparam int unsigned CntTxPcsBadBlock = 15;
  localparam int unsigned NumCounters = 16;

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
