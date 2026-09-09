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

/**
 * NIC register interface (hw/rtl/peripherals/nic, nic_pkg.sv is the source
 * of the map).
 *
 * The NIC is the net10g MAC/PCS on the cache hierarchy's coherent DMA port:
 * a 4 KiB window of 32-bit registers at NIC_BASE (64-bit counters from
 * NIC_COUNTERS, read with one 64-bit load), an RX and a TX descriptor ring
 * in cached DDR, and one PLIC interrupt. Descriptors are 16 bytes, two per
 * 32-byte line; software fills words 0 and 1, zeroes word 2, then writes
 * TAIL; hardware writes word 2 (DD and the outcome) when it is done with
 * the descriptor. See the NIC README for the enable, quiesce and RESET rules.
 */
#ifndef NIC_H
#define NIC_H

#include <stdint.h>

#include "mmio.h"

#define NIC_ID 0x000u
#define NIC_ID_VALUE 0x4E494301u
#define NIC_CTRL 0x004u
#define NIC_STATUS 0x008u
#define NIC_MAC_LO 0x00Cu
#define NIC_MAC_HI 0x010u
#define NIC_RX_BASE 0x020u
#define NIC_RX_SIZE 0x024u
#define NIC_RX_TAIL 0x028u
#define NIC_RX_HEAD 0x02Cu
#define NIC_TX_BASE 0x030u
#define NIC_TX_SIZE 0x034u
#define NIC_TX_TAIL 0x038u
#define NIC_TX_HEAD 0x03Cu
#define NIC_IRQ_STATUS 0x040u
#define NIC_IRQ_MASK 0x044u
#define NIC_RX_ITR 0x048u
#define NIC_TX_ITR 0x04Cu
#define NIC_TICK 0x050u
#define NIC_IRQ_MASK_SET 0x054u
#define NIC_IRQ_MASK_CLR 0x058u
#define NIC_LINK 0x060u
#define NIC_PHY_CTRL 0x064u
#define NIC_PHY_STATUS 0x068u
#define NIC_COUNTERS 0x080u

#define NIC_CTRL_RX_EN (1u << 0)
#define NIC_CTRL_TX_EN (1u << 1)
#define NIC_CTRL_PROMISC (1u << 2)
#define NIC_CTRL_RESET (1u << 8)

#define NIC_STATUS_RX_IDLE (1u << 0)
#define NIC_STATUS_TX_IDLE (1u << 1)
#define NIC_STATUS_RESET_BUSY (1u << 2)
#define NIC_STATUS_RX_FIFO_EMPTY (1u << 3)
#define NIC_STATUS_RX_READY (1u << 4)
#define NIC_STATUS_TX_READY (1u << 5)
#define NIC_STATUS_RX_CONFIG_ERR (1u << 6)
#define NIC_STATUS_TX_CONFIG_ERR (1u << 7)

#define NIC_IRQ_RX (1u << 0)
#define NIC_IRQ_TX (1u << 1)
#define NIC_IRQ_RX_DROP (1u << 2)
#define NIC_IRQ_LINK (1u << 3)
#define NIC_IRQ_DESC_ERR (1u << 4)
#define NIC_IRQ_ALL 0x1Fu

/** ITR: [15:0] delay in ticks, [23:16] max completions (0 = off). */
#define NIC_ITR(delay, max) (((uint32_t) (max) << 16) | ((uint32_t) (delay) & 0xFFFFu))

#define NIC_LINK_RX_LOCKED (1u << 0)
#define NIC_LINK_RX_HIGH_BER (1u << 1)
#define NIC_LINK_RX_LOCAL_FAULT (1u << 2)
#define NIC_LINK_RX_REMOTE_FAULT (1u << 3)
#define NIC_LINK_TX_LINK_READY (1u << 4)
#define NIC_LINK_RX_SIGNAL_OK (1u << 5)
#define NIC_LINK_TX_CLK_OK (1u << 6)
#define NIC_LINK_RX_CLK_OK (1u << 7)
#define NIC_LINK_CARRIER (1u << 8)

#define NIC_PHY_CTRL_MAC_LOOPBACK (1u << 0)
#define NIC_PHY_CTRL_PHY_RESET (1u << 1)
#define NIC_PHY_CTRL_PMA_LOOPBACK (1u << 2)
#define NIC_PHY_CTRL_TX_DISABLE (1u << 3)

#define NIC_PHY_STATUS_CLK_SHARED (1u << 0)
#define NIC_PHY_STATUS_GT_RESET_DONE (1u << 1)
#define NIC_PHY_STATUS_CDR_LOCK (1u << 2)
#define NIC_PHY_STATUS_MODULE_PRESENT (1u << 3)
#define NIC_PHY_STATUS_LOS (1u << 4)

/* Counter indices (64-bit each at NIC_COUNTERS + 8 * index). */
#define NIC_CNT_RX_FRAMES 0u
#define NIC_CNT_RX_BYTES 1u
#define NIC_CNT_RX_FILTERED 2u
#define NIC_CNT_RX_TRUNCATED 3u
#define NIC_CNT_RX_DESC_ERR 4u
#define NIC_CNT_RX_ABORTED 5u
#define NIC_CNT_TX_FRAMES 6u
#define NIC_CNT_TX_BYTES 7u
#define NIC_CNT_TX_DESC_ERR 8u
#define NIC_CNT_TX_ABORTED 9u
#define NIC_CNT_RX_MAC_OVERFLOW 10u
#define NIC_CNT_RX_MAC_BAD_FRAME 11u
#define NIC_CNT_RX_MAC_BAD_FCS 12u
#define NIC_CNT_RX_PCS_BAD_BLOCK 13u
#define NIC_CNT_TX_MAC_DROP 14u
#define NIC_CNT_TX_PCS_BAD_BLOCK 15u
#define NIC_NUM_COUNTERS 16u

#define NIC_PLIC_SOURCE 4u
#define NIC_MAX_FRAME_BYTES 9216u
#define NIC_RING_SIZE_LOG2_MIN 2u
#define NIC_RING_SIZE_LOG2_MAX 16u

/* Descriptor word 1 (TX) and word 2 (status) bits. */
#define NIC_TX_SOP (1u << 16)
#define NIC_TX_EOP (1u << 17)
#define NIC_DESC_DD (1u << 16)
#define NIC_DESC_TRUNC (1u << 17)
#define NIC_DESC_ERR (1u << 18)
#define NIC_DESC_ABORT (1u << 19)
#define NIC_DESC_LEN_MASK 0xFFFFu

/** One ring descriptor: 16 bytes, two per line; the ring base is 32-byte aligned. */
struct nic_desc {
    uint32_t addr;   /* buffer address, any byte alignment */
    uint32_t len;    /* RX: buffer length; TX: frame length | SOP | EOP */
    uint32_t status; /* written by hardware; software zeroes it when posting */
    uint32_t reserved;
};

static inline volatile mmio_u32_t *nic_reg(uint32_t offset)
{
    return (volatile mmio_u32_t *) (NIC_BASE + offset);
}

static inline void nic_write(uint32_t offset, uint32_t value)
{
    *nic_reg(offset) = value;
}

static inline uint32_t nic_read(uint32_t offset)
{
    return *nic_reg(offset);
}

/** A 64-bit counter, read atomically. */
static inline uint64_t nic_read_counter(uint32_t index)
{
    return *(volatile uint64_t *) (NIC_BASE + NIC_COUNTERS + 8u * index);
}

#endif /* NIC_H */
