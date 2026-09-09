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
endpackage : nic_pkg
