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

/* Copyright 2026 John Goodacre */

/* Header shared by the VCU118 flash boot stages. */
#ifndef FROST_FLASH_BOOT_H
#define FROST_FLASH_BOOT_H

#include <stdint.h>

#define IMAGE_MAGIC_FROST 0x54535246u
#define IMAGE_VERSION 1u
#define FLASH_STAGE_CAPACITY (0x100000u - 32u)

typedef struct {
    uint32_t magic;
    uint32_t version;
    uint32_t load_addr;
    uint32_t length;
    uint32_t crc32;
    uint32_t entry_addr;
    uint32_t flags;
    uint32_t reserved;
} flash_image_hdr_t;

static inline int
flash_image_valid(const flash_image_hdr_t *hdr, uint32_t load_addr, uint32_t capacity)
{
    return hdr->magic == IMAGE_MAGIC_FROST && hdr->version == IMAGE_VERSION &&
           hdr->load_addr == load_addr && hdr->entry_addr == load_addr && hdr->length != 0 &&
           hdr->length <= capacity && hdr->length <= FLASH_STAGE_CAPACITY && hdr->flags == 0 &&
           hdr->reserved == 0;
}

#endif
