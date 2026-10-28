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
 * FROST 2nd-Stage Bootloader (FSBL)
 *
 * Loaded by the Core Boot ROM (0x0000_0000) from SPI NOR flash (0x0300_0000)
 * into on-chip executable SRAM at 0x0000_4000:
 *   1. Polls the DDR4 controller status for PHY calibration and hardware ECC
 *      scrub completion, then performs a DRAM address/data verification pass
 *      and zero-scrubs the boot payload apertures in DRAM.
 *   2. Reads and validates the SPI NOR flash image headers for:
 *        - OpenSBI (fw_jump.bin) @ flash 0x0310_0000 -> DRAM 0x8000_0000
 *        - Device Tree (frost.dtb) @ flash 0x0320_0000 -> DRAM 0x8220_0000
 *        - U-Boot Proper (u-boot.bin) @ flash 0x0330_0000 -> DRAM 0x8020_0000
 *   3. Verifies IEEE 802.3 CRC-32 checksums on each loaded DRAM payload.
 *   4. Executes fence + fence.i and jumps to OpenSBI (0x8000_0000) with
 *      a0 = 0 (hartid) and a1 = 0x8220_0000 (DTB), which transitions to
 *      S-mode and enters U-Boot Proper at 0x8020_0000.
 */

#include "flash_boot.h"
#include "uart.h"
#include <stdint.h>

/* VCU118 Boot & SPI Flash Controller MMIO registers */
#define BOOT_SPI_CTRL_REG (*(volatile uint32_t *) 0x40023000UL)
#define BOOT_SYS_STATUS_REG (*(volatile uint32_t *) 0x40023004UL)
#define BOOT_SPI_XFER_BYTE_REG (*(volatile uint32_t *) 0x40023008UL)
#define BOOT_SPI_XFER_WORD_REG (*(volatile uint32_t *) 0x4002300CUL)

#define SPI_CTRL_CS_N (1u << 0)
#define SPI_CTRL_CLK_DIV(d) (((uint32_t) (d) & 0xFFu) << 8)

#define SYS_STATUS_SPI_BUSY (1u << 0)
#define SYS_STATUS_DDR_CAL (1u << 8)
#define SYS_STATUS_DDR_SCRUB (1u << 9)

/* NS16550 Line Status Register for TX drain */
#define NS16550_LSR_REG (*(volatile uint32_t *) 0x40001014UL)
#define NS16550_LSR_TEMT (1u << 6)

/* SPI NOR Flash commands and partition offsets */
#define SPI_CMD_READ_4B 0x13u
#define FLASH_OPENSBI_OFFSET 0x03100000u
#define FLASH_DTB_OFFSET 0x03200000u
#define FLASH_UBOOT_OFFSET 0x03300000u

/* DRAM layout */
#define DRAM_BASE_ADDR 0x80000000UL
#define DRAM_SIZE_BYTES 0x80000000UL /* 2 GiB on VCU118 */
#define DRAM_OPENSBI_ADDR 0x80000000UL
#define DRAM_UBOOT_ADDR 0x80200000UL
#define DRAM_DTB_ADDR 0x82200000UL


static inline void spi_cs_select(void)
{
    /* Use the board SPI divider. */
    BOOT_SPI_CTRL_REG = SPI_CTRL_CLK_DIV(6);
}

static inline void spi_cs_deselect(void)
{
    BOOT_SPI_CTRL_REG = SPI_CTRL_CLK_DIV(6) | SPI_CTRL_CS_N;
}

static uint8_t spi_xfer_byte(uint8_t tx)
{
    while (BOOT_SYS_STATUS_REG & SYS_STATUS_SPI_BUSY) {
    }
    BOOT_SPI_XFER_BYTE_REG = tx;
    while (BOOT_SYS_STATUS_REG & SYS_STATUS_SPI_BUSY) {
    }
    return (uint8_t) BOOT_SPI_XFER_BYTE_REG;
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

static void spi_flash_read_bytes(uint32_t flash_offset, void *dst, uint32_t len)
{
    uint8_t *out = (uint8_t *) dst;
    spi_cs_select();
    (void) spi_xfer_byte(SPI_CMD_READ_4B);
    (void) spi_xfer_byte((uint8_t) (flash_offset >> 24));
    (void) spi_xfer_byte((uint8_t) (flash_offset >> 16));
    (void) spi_xfer_byte((uint8_t) (flash_offset >> 8));
    (void) spi_xfer_byte((uint8_t) (flash_offset));
    for (uint32_t i = 0; i < len; i++) {
        out[i] = spi_xfer_byte(0x00u);
    }
    spi_cs_deselect();
}

static void spi_flash_load_dram(uint32_t flash_offset, uintptr_t dram_addr, uint32_t len_bytes)
{
    uint32_t num_words = (len_bytes + 3u) / 4u;
    volatile uint32_t *dram_ptr = (volatile uint32_t *) dram_addr;

    spi_cs_select();
    (void) spi_xfer_byte(SPI_CMD_READ_4B);
    (void) spi_xfer_byte((uint8_t) (flash_offset >> 24));
    (void) spi_xfer_byte((uint8_t) (flash_offset >> 16));
    (void) spi_xfer_byte((uint8_t) (flash_offset >> 8));
    (void) spi_xfer_byte((uint8_t) (flash_offset));

    for (uint32_t i = 0; i < num_words; i++) {
        dram_ptr[i] = spi_xfer_word_le(0x00000000u);
    }

    spi_cs_deselect();
}

static uint32_t crc32_ieee(const void *data, uint32_t length)
{
    const uint8_t *p = (const uint8_t *) data;
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

static void fsbl_halt(const char *reason)
{
    uart_printf("[FSBL] HALT: %s\n", reason);
    for (;;) {
        __asm__ volatile("wfi");
    }
}

static void dram_zero_region(uintptr_t start, uint32_t num_bytes)
{
    volatile uint64_t *p = (volatile uint64_t *) start;
    uint32_t dwords = num_bytes / 8u;
    for (uint32_t i = 0; i < dwords; i++) {
        p[i] = 0ULL;
    }
}

static void dram_init_and_verify(void)
{
    uart_puts("[FSBL] Waiting for DDR4 MIG calibration and hardware ECC scrub...\n");
    while ((BOOT_SYS_STATUS_REG & (SYS_STATUS_DDR_CAL | SYS_STATUS_DDR_SCRUB)) !=
           (SYS_STATUS_DDR_CAL | SYS_STATUS_DDR_SCRUB)) {
    }
    uart_printf("[FSBL] DDR4 controller ready (SYS_STATUS=0x%08x)\n", BOOT_SYS_STATUS_REG);

    /* Address uniqueness & data bus verification across 2 GiB DDR4 aperture */
    static const uint64_t test_offsets[] = {0x00000000ULL,
                                            0x00100000ULL,
                                            0x00200000ULL,
                                            0x01000000ULL,
                                            0x04000000ULL,
                                            0x10000000ULL,
                                            0x20000000ULL,
                                            0x40000000ULL};
    const uint32_t num_pts = sizeof(test_offsets) / sizeof(test_offsets[0]);

    for (uint32_t i = 0; i < num_pts; i++) {
        volatile uint64_t *ptr =
            (volatile uint64_t *) (uintptr_t) (DRAM_BASE_ADDR + test_offsets[i]);
        uint64_t pattern = 0xA5A55A5AF00DCAFEULL ^ (DRAM_BASE_ADDR + test_offsets[i]);
        *ptr = pattern;
    }
    __asm__ volatile("fence rw, rw" ::: "memory");

    for (uint32_t i = 0; i < num_pts; i++) {
        volatile uint64_t *ptr =
            (volatile uint64_t *) (uintptr_t) (DRAM_BASE_ADDR + test_offsets[i]);
        uint64_t expected = 0xA5A55A5AF00DCAFEULL ^ (DRAM_BASE_ADDR + test_offsets[i]);
        uint64_t actual = *ptr;
        if (actual != expected) {
            uart_printf("[FSBL] DRAM verify failed @ 0x%08x: exp=0x%016llx got=0x%016llx\n",
                        (uint32_t) (DRAM_BASE_ADDR + test_offsets[i]),
                        (unsigned long long) expected,
                        (unsigned long long) actual);
            fsbl_halt("DDR4 memory verification failed");
        }
        *ptr = 0ULL;
    }

    /* Zero-initialize OpenSBI, U-Boot, and DTB DRAM regions */
    dram_zero_region(DRAM_OPENSBI_ADDR, 0x00040000u); /* 256 KiB */
    dram_zero_region(DRAM_UBOOT_ADDR, 0x00200000u);   /* 2 MiB */
    dram_zero_region(DRAM_DTB_ADDR, 0x00020000u);     /* 128 KiB */
    __asm__ volatile("fence rw, rw" ::: "memory");

    uart_puts("[FSBL] DDR4 2 GiB @ 0x80000000 verified and boot regions scrubbed.\n");
}

static uintptr_t
load_and_verify_flash_image(const char *name, uint32_t flash_offset, uintptr_t default_load_addr)
{
    flash_image_hdr_t hdr;
    spi_flash_read_bytes(flash_offset, &hdr, sizeof(hdr));

    if (hdr.magic != IMAGE_MAGIC_FROST || hdr.version != IMAGE_VERSION || hdr.length == 0) {
        uart_printf("[FSBL] Invalid %s header @ flash 0x%08x (magic=0x%08x ver=%u len=%u)\n",
                    name,
                    flash_offset,
                    hdr.magic,
                    hdr.version,
                    hdr.length);
        fsbl_halt("Missing or invalid stage-3 image in SPI flash");
    }

    uintptr_t load_addr = default_load_addr;
    uint32_t capacity = (flash_offset == FLASH_DTB_OFFSET) ? 0x20000u : FLASH_STAGE_CAPACITY;
    if (!flash_image_valid(&hdr, (uint32_t) load_addr, capacity)) {
        fsbl_halt("Image header does not match its boot partition");
    }

    uart_printf("[FSBL] Loading %-12s (%7u bytes) flash 0x%08x -> DRAM 0x%08x...",
                name,
                hdr.length,
                flash_offset + (uint32_t) sizeof(hdr),
                (uint32_t) load_addr);

    spi_flash_load_dram(flash_offset + (uint32_t) sizeof(hdr), load_addr, hdr.length);
    __asm__ volatile("fence rw, rw" ::: "memory");

    uint32_t calc_crc = crc32_ieee((const void *) load_addr, hdr.length);
    if (calc_crc != hdr.crc32) {
        uart_printf(" FAIL (exp=0x%08x got=0x%08x)\n", hdr.crc32, calc_crc);
        fsbl_halt("DRAM image CRC-32 mismatch");
    }
    uart_printf(" CRC OK (0x%08x)\n", calc_crc);

    return load_addr;
}

int main(void)
{
    spi_cs_deselect();

    uart_puts("\n============================================================\n");
    uart_puts("FROST 2nd-Stage Bootloader (FSBL) v1.0 (SRAM @ 0x00004000)\n");
    uart_puts("============================================================\n");

    dram_init_and_verify();

    uintptr_t opensbi_entry =
        load_and_verify_flash_image("OpenSBI", FLASH_OPENSBI_OFFSET, DRAM_OPENSBI_ADDR);
    uintptr_t dtb_addr = load_and_verify_flash_image("DeviceTree", FLASH_DTB_OFFSET, DRAM_DTB_ADDR);
    uintptr_t uboot_entry =
        load_and_verify_flash_image("U-Boot", FLASH_UBOOT_OFFSET, DRAM_UBOOT_ADDR);

    uart_printf("[FSBL] Boot chain ready: OpenSBI @ 0x%08x -> U-Boot @ 0x%08x (DTB @ 0x%08x)\n",
                (uint32_t) opensbi_entry,
                (uint32_t) uboot_entry,
                (uint32_t) dtb_addr);
    uart_puts("[FSBL] Handing off to OpenSBI + U-Boot Proper in DRAM...\n\n");

    while (!(NS16550_LSR_REG & NS16550_LSR_TEMT)) {
    }

    __asm__ volatile("fence rw, rw" ::: "memory");
    __asm__ volatile("fence.i" ::: "memory");

    register uintptr_t a0 __asm__("a0") = 0; /* hart 0 */
    register uintptr_t a1 __asm__("a1") = dtb_addr;
    __asm__ volatile("jr %0" : : "r"(opensbi_entry), "r"(a0), "r"(a1) : "memory");

    fsbl_halt("OpenSBI returned unexpectedly");
    return 0;
}
