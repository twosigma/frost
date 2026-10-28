/*
 *    Copyright 2026 John Goodacre
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
 * FROST Core Boot ROM (Stage 1)
 *
 * Executes at reset from on-chip BRAM at 0x0000_0000:
 *   1. Initializes console UART and checks VCU118 Boot/SPI controller status.
 *   2. Initializes onboard Micron MT25QU01G SPI NOR flash via STARTUPE3 bridge.
 *   3. Reads and validates the 32-byte FSBL image header at flash offset 0x0100_0000.
 *   4. Streams the FSBL payload into on-chip executable SRAM at 0x0000_4000
 *      (updating both imem_predecode and data_memory via u_slice_writer).
 *   5. Verifies the IEEE 802.3 CRC-32 over the loaded SRAM image, executes
 *      fence.i, and jumps to the FSBL entry point at 0x0000_4000.
 */

#include <stdint.h>
#include "uart.h"

/* VCU118 Boot & SPI Flash Controller MMIO registers (soc_top.sv) */
#define BOOT_SPI_CTRL_REG      (*(volatile uint32_t *)0x40023000UL)
#define BOOT_SYS_STATUS_REG    (*(volatile uint32_t *)0x40023004UL)
#define BOOT_SPI_XFER_BYTE_REG (*(volatile uint32_t *)0x40023008UL)
#define BOOT_SPI_XFER_WORD_REG (*(volatile uint32_t *)0x4002300CUL)
#define BOOT_SRAM_ADDR_REG     (*(volatile uint32_t *)0x40023010UL)
#define BOOT_SRAM_DATA_REG     (*(volatile uint32_t *)0x40023014UL)

#define SPI_CTRL_CS_N          (1u << 0)
#define SPI_CTRL_CLK_DIV(d)    (((uint32_t)(d) & 0xFFu) << 8)

#define SYS_STATUS_SPI_BUSY    (1u << 0)
#define SYS_STATUS_SRAM_BUSY   (1u << 1)
#define SYS_STATUS_DDR_CAL     (1u << 8)
#define SYS_STATUS_DDR_SCRUB   (1u << 9)
#define SYS_STATUS_SIG_MASK    0xFFFF0000u
#define SYS_STATUS_SIG_FROST   0x46520000u /* "FR" */

/* NS16550 Line Status Register for TX drain before handoff */
#define NS16550_LSR_REG        (*(volatile uint32_t *)0x40001014UL)
#define NS16550_LSR_TEMT       (1u << 6)

/* SPI NOR Flash layout & commands */
#define FLASH_FSBL_OFFSET      0x03000000u
#define SPI_CMD_RDID           0x9Fu
#define SPI_CMD_EN4B           0xB7u
#define SPI_CMD_READ_4B        0x13u

/* On-chip executable SRAM bounds for FSBL */
#define FSBL_SRAM_MIN_ADDR     0x00004000u
#define FSBL_SRAM_MAX_ADDR     0x00017C00u

/* Image header magic value ("FRST") */
#define IMAGE_MAGIC_FROST      0x54535246u
#define IMAGE_VERSION          1u

typedef struct {
    uint32_t magic;
    uint32_t version;
    uint32_t load_addr;
    uint32_t length;
    uint32_t crc32;
    uint32_t entry_addr;
    uint32_t flags;
    uint32_t reserved;
} __attribute__((packed)) flash_image_hdr_t;

static inline void spi_cs_select(void)
{
    /* Assert CS# (active low), clock divider = 6 (~16.7 MHz SCK) */
    BOOT_SPI_CTRL_REG = SPI_CTRL_CLK_DIV(6);
}

static inline void spi_cs_deselect(void)
{
    /* Deassert CS# (high), clock divider = 6 */
    BOOT_SPI_CTRL_REG = SPI_CTRL_CLK_DIV(6) | SPI_CTRL_CS_N;
}

static uint8_t spi_xfer_byte(uint8_t tx)
{
    while (BOOT_SYS_STATUS_REG & SYS_STATUS_SPI_BUSY) {
    }
    BOOT_SPI_XFER_BYTE_REG = tx;
    while (BOOT_SYS_STATUS_REG & SYS_STATUS_SPI_BUSY) {
    }
    return (uint8_t)BOOT_SPI_XFER_BYTE_REG;
}

static uint32_t spi_xfer_word_le(uint32_t tx)
{
    while (BOOT_SYS_STATUS_REG & SYS_STATUS_SPI_BUSY) {
    }
    BOOT_SPI_XFER_WORD_REG = tx;
    while (BOOT_SYS_STATUS_REG & SYS_STATUS_SPI_BUSY) {
    }
    return BOOT_SPI_XFER_WORD_REG;
}

static void spi_flash_init(uint32_t *jedec_id_out)
{
    spi_cs_deselect();
    /* Toggle USRCCLKO with CS# high so STARTUPE3 switches clock mux to user logic */
    (void)spi_xfer_byte(0xFFu);
    (void)spi_xfer_byte(0xFFu);

    /* Release any continuous read / deep power-down state */
    spi_cs_select();
    (void)spi_xfer_byte(0xFFu);
    spi_cs_deselect();

    /* Read 3-byte JEDEC ID (0x9F) */
    spi_cs_select();
    (void)spi_xfer_byte(SPI_CMD_RDID);
    uint32_t id0 = spi_xfer_byte(0x00u);
    uint32_t id1 = spi_xfer_byte(0x00u);
    uint32_t id2 = spi_xfer_byte(0x00u);
    spi_cs_deselect();
    *jedec_id_out = (id0 << 16) | (id1 << 8) | id2;

    /* Enter 4-byte addressing mode (0xB7) */
    spi_cs_select();
    (void)spi_xfer_byte(SPI_CMD_EN4B);
    spi_cs_deselect();
}

static void spi_flash_read_bytes(uint32_t flash_offset, void *dst, uint32_t len)
{
    uint8_t *out = (uint8_t *)dst;
    spi_cs_select();
    (void)spi_xfer_byte(SPI_CMD_READ_4B);
    (void)spi_xfer_byte((uint8_t)(flash_offset >> 24));
    (void)spi_xfer_byte((uint8_t)(flash_offset >> 16));
    (void)spi_xfer_byte((uint8_t)(flash_offset >> 8));
    (void)spi_xfer_byte((uint8_t)(flash_offset));
    for (uint32_t i = 0; i < len; i++) {
        out[i] = spi_xfer_byte(0x00u);
    }
    spi_cs_deselect();
}

static void spi_flash_load_sram(uint32_t flash_offset, uint32_t sram_addr, uint32_t len_bytes)
{
    uint32_t num_words = (len_bytes + 3u) / 4u;
    volatile uint32_t *sram_ptr = (volatile uint32_t *)(uintptr_t)sram_addr;

    while (BOOT_SYS_STATUS_REG & SYS_STATUS_SRAM_BUSY) {
    }
    BOOT_SRAM_ADDR_REG = sram_addr;

    spi_cs_select();
    (void)spi_xfer_byte(SPI_CMD_READ_4B);
    (void)spi_xfer_byte((uint8_t)(flash_offset >> 24));
    (void)spi_xfer_byte((uint8_t)(flash_offset >> 16));
    (void)spi_xfer_byte((uint8_t)(flash_offset >> 8));
    (void)spi_xfer_byte((uint8_t)(flash_offset));

    for (uint32_t i = 0; i < num_words; i++) {
        uint32_t w = spi_xfer_word_le(0x00000000u);
        while (BOOT_SYS_STATUS_REG & SYS_STATUS_SRAM_BUSY) {
        }
        /* Write both imem_predecode and data_memory via slice writer */
        BOOT_SRAM_DATA_REG = w;
        /* Also store via CPU D-side so write-through L0/L1D stays coherent */
        sram_ptr[i] = w;
    }

    spi_cs_deselect();
    while (BOOT_SYS_STATUS_REG & SYS_STATUS_SRAM_BUSY) {
    }
}

static uint32_t crc32_ieee(const void *data, uint32_t length)
{
    const uint8_t *p = (const uint8_t *)data;
    uint32_t crc = 0xFFFFFFFFu;
    for (uint32_t i = 0; i < length; i++) {
        crc ^= p[i];
        for (int b = 0; b < 8; b++) {
            uint32_t mask = -(crc & 1u);
            crc = (crc >> 1) ^ (0xEDB88320u & mask);
        }
    }
    return ~crc;
}

static void boot_halt(const char *reason)
{
    uart_printf("[BOOTROM] HALT: %s\n", reason);
    for (;;) {
        __asm__ volatile("wfi");
    }
}

int main(void)
{
    uart_puts("\n============================================================\n");
    uart_puts("FROST Core Boot ROM v1.0 (On-Chip BRAM @ 0x00000000)\n");
    uart_puts("============================================================\n");

    uint32_t status = BOOT_SYS_STATUS_REG;
    if ((status & SYS_STATUS_SIG_MASK) != SYS_STATUS_SIG_FROST) {
        boot_halt("Boot/SPI controller not present on this platform");
    }

    uint32_t jedec_id = 0;
    spi_flash_init(&jedec_id);
    uart_printf("[BOOTROM] SYS_STATUS=0x%08x  SPI Flash JEDEC ID=0x%06x\n",
                status, jedec_id);

    flash_image_hdr_t hdr;
    spi_flash_read_bytes(FLASH_FSBL_OFFSET, &hdr, sizeof(hdr));

    if (hdr.magic != IMAGE_MAGIC_FROST ||
        hdr.version != IMAGE_VERSION) {
        uart_printf("[BOOTROM] No valid FSBL header @ flash 0x%08x (magic=0x%08x ver=%u)\n",
                    FLASH_FSBL_OFFSET, hdr.magic, hdr.version);
        boot_halt("Waiting for JTAG or SPI flash programming");
    }

    if (hdr.length == 0 ||
        hdr.load_addr < FSBL_SRAM_MIN_ADDR ||
        hdr.load_addr >= FSBL_SRAM_MAX_ADDR ||
        (hdr.load_addr + hdr.length) > FSBL_SRAM_MAX_ADDR ||
        hdr.entry_addr < hdr.load_addr ||
        hdr.entry_addr >= (hdr.load_addr + hdr.length)) {
        uart_printf("[BOOTROM] Invalid FSBL bounds: load=0x%08x len=%u entry=0x%08x\n",
                    hdr.load_addr, hdr.length, hdr.entry_addr);
        boot_halt("FSBL image header out of on-chip SRAM bounds");
    }

    uart_printf("[BOOTROM] Loading FSBL (%u bytes) from flash 0x%08x -> SRAM 0x%08x...\n",
                hdr.length, FLASH_FSBL_OFFSET + (uint32_t)sizeof(hdr), hdr.load_addr);

    spi_flash_load_sram(FLASH_FSBL_OFFSET + (uint32_t)sizeof(hdr),
                        hdr.load_addr, hdr.length);

    uint32_t calc_crc = crc32_ieee((const void *)(uintptr_t)hdr.load_addr, hdr.length);
    if (calc_crc != hdr.crc32) {
        uart_printf("[BOOTROM] FSBL CRC-32 mismatch! expected=0x%08x actual=0x%08x\n",
                    hdr.crc32, calc_crc);
        boot_halt("FSBL CRC verification failed");
    }

    uart_printf("[BOOTROM] FSBL CRC-32 verified (0x%08x). Jumping to 0x%08x...\n",
                calc_crc, hdr.entry_addr);

    while (!(NS16550_LSR_REG & NS16550_LSR_TEMT)) {
    }

    __asm__ volatile("fence rw, rw" ::: "memory");
    __asm__ volatile("fence.i" ::: "memory");

    void (*fsbl_entry)(void) = (void (*)(void))(uintptr_t)hdr.entry_addr;
    fsbl_entry();

    boot_halt("FSBL returned unexpectedly");
    return 0;
}

