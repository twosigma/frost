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
 * Register offsets are byte offsets inside the NIC's 4 KiB window.
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

  // RX ingress FIFO (in 68-bit words of up to 8 frame bytes). RX_FIFO_LIMIT is the occupancy at
  // which the MAC side reports the FIFO full: it reads back the value in effect, resets to
  // RxFifoLimitDefault (or the built depth, if smaller), and a write is clamped to
  // RxFifoLimitMin..RX_FIFO_DEPTH. It is writable only while RX is disabled and idle. RX_FIFO_DEPTH
  // reads the built depth.
  localparam logic [11:0] RxFifoLimitOffset = 12'h014;
  localparam logic [11:0] RxFifoDepthOffset = 12'h018;
  localparam int unsigned RxFifoLimitMin = 8;

  // 802.3x flow control. PAUSE_CTRL bit 0 honours received PAUSE frames in the transmitter, bit 1
  // sends flow control frames from the RX FIFO occupancy. PAUSE_HIGH_WATER and PAUSE_LOW_WATER
  // are occupancies in FIFO words (0 selects default relative to RX_FIFO_LIMIT: high-water at
  // three quarters, low-water at one quarter); PAUSE_INTERVAL is the pause_time of flow control
  // frames (reset 0xFFFF, a write of 0 reads back 1). All four are writable only while RX is
  // disabled and idle, like RX_FIFO_LIMIT.
  localparam logic [11:0] PauseCtrlOffset = 12'h01C;
  localparam int unsigned PauseCtrlBitRx = 0;
  localparam int unsigned PauseCtrlBitTx = 1;
  localparam logic [11:0] PauseHighWaterOffset = 12'h130;
  localparam logic [11:0] PauseLowWaterOffset = 12'h134;
  localparam logic [11:0] PauseIntervalOffset = 12'h138;
  localparam logic [15:0] PauseIntervalDefault = 16'hFFFF;
  localparam int unsigned RxFifoLimitDefault = 512;

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
  // Additive wide-address ABI. ABI_CTRL bit 0 selects the extended 16-byte
  // descriptor layout; bit 1 reads one to advertise support. Bit 2 enables the
  // RX checksum (set while both directions are disabled and idle); bit 3 reads
  // one to advertise checksum offload and bit 4 reads one to advertise frame
  // segmentation, and bit 5 reads one to advertise 802.3x pause (PAUSE_CTRL and friends), and bit 6 reads one when a rejected
  // descriptor inside a frame aborts the frame cleanly and segments of up to 65535 bytes are
  // accepted after a frame's first (or after a parameter descriptor).
  localparam logic [11:0] AbiCtrlOffset = 12'h06C;
  localparam logic [11:0] RxBase64Offset = 12'h070;
  localparam logic [11:0] RxBase64HiOffset = 12'h074;
  localparam logic [11:0] TxBase64Offset = 12'h078;
  localparam logic [11:0] TxBase64HiOffset = 12'h07C;
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
  // GMII receive events (zero on the 10GBASE-R port): frames dropped in the preamble stage, and
  // rx_er bursts inside a frame (dv = 1).
  localparam int unsigned CntRxGmiiPreambleDrop = 16;
  localparam int unsigned CntRxGmiiRxEr = 17;
  // 802.3x: PAUSE frames received (consumed, not delivered), PAUSE frames sent (pause requests, refresh and
  // release), and TX MAC clock cycles spent paused by a received PAUSE.
  localparam int unsigned CntRxPauseFrames = 18;
  localparam int unsigned CntTxPauseFrames = 19;
  localparam int unsigned CntTxPausedCycles = 20;
  localparam int unsigned NumCounters = 21;

  // Interrupt block registers.
  localparam logic [11:0] IrqStatusOffset = 12'h040;  // RW1C
  localparam logic [11:0] IrqMaskOffset = 12'h044;  // RW
  localparam logic [11:0] RxCoalesceOffset = 12'h048;  // RW: [15:0] delay ticks, [23:16] max
  localparam logic [11:0] TxCoalesceOffset = 12'h04C;  // RW
  localparam logic [11:0] RxItrOffset = RxCoalesceOffset;
  localparam logic [11:0] TxItrOffset = TxCoalesceOffset;
  localparam logic [11:0] TickOffset = 12'h050;  // RW: core cycles per tick
  localparam logic [11:0] IrqMaskSetOffset = 12'h054;  // W1S
  localparam logic [11:0] IrqMaskClrOffset = 12'h058;  // W1C

  // Interrupt status / mask bits.
  localparam int unsigned IrqBitRx = 0;  // moderated RX completions
  localparam int unsigned IrqBitTx = 1;  // moderated TX completions
  // A received frame was filtered out, completed with ERR or ABORT, or lost to
  // MAC overflow.
  localparam int unsigned IrqBitRxDrop = 2;
  localparam int unsigned IrqBitLink = 3;  // LINK.CARRIER changed
  // A descriptor completed with ERR or ABORT, or an enable was refused.
  localparam int unsigned IrqBitDescErr = 4;
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
  localparam logic [1:0] ReqKindStatus = 2'd2;  // descriptor word 2 write (DONE)
  // Status bit set when the RX checksum field of the descriptor is valid.
  localparam int unsigned RxStatusCsumValidBit = 20;

  // Descriptors: 16 bytes, two per line. Legacy: addr32/len32/status32/
  // reserved32. Extended: addr64/len32/status32. No implicit interpretation
  // of the legacy reserved word is permitted.
  localparam int unsigned DescBytes = 16;
  localparam int unsigned DescStatusByte = 8;  // word 2
  localparam int unsigned DescStatus64Byte = 12;  // extended word 3
  localparam int unsigned MaxFrameBytes = 9216;
  localparam int unsigned TxWord1BitFirst = 16;
  localparam int unsigned TxWord1BitLast = 17;
  localparam int unsigned TxWord1BitParam = 18;
  // Aliases for compatibility
  localparam int unsigned TxWord1BitSop = TxWord1BitFirst;
  localparam int unsigned TxWord1BitEop = TxWord1BitLast;
  localparam int unsigned TxWord1BitCtx = TxWord1BitParam;
  // A parameter descriptor (length 0, neither first nor last, this bit set) carries the segmentation
  // parameters of the frame that follows: word 0 [13:0] max segment size and [31:16] payload bytes;
  // word 1 [25:19] L4 offset / 2, [29:26] L4 header length / 4, [30] IPv6, [31] VLAN tag.
  localparam int unsigned StatusBitDone = 16;
  localparam int unsigned StatusBitCmpl = StatusBitDone;
  localparam int unsigned StatusBitDd = StatusBitDone;
  localparam int unsigned StatusBitTrunc = 17;
  localparam int unsigned StatusBitErr = 18;
  localparam int unsigned StatusBitAbort = 19;
  // Completion flags the engines report with each status write's response:
  // {ABORT, ERR, TRUNC} (completion is implied).
  localparam int unsigned FlagTrunc = 0;
  localparam int unsigned FlagErr = 1;
  localparam int unsigned FlagAbort = 2;
endpackage : nic_pkg
