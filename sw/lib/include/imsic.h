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

/* Local interrupt-file CSRs and naturally aligned 32-bit MSI stores. */
#ifndef IMSIC_H
#define IMSIC_H

#include "csr.h"
#include <stdint.h>

#define IMSIC_M_BASE 0x48000000ul
#define IMSIC_S_BASE 0x48100000ul
#define IMSIC_NUM_IDS 63
#define IMSIC_EIDELIVERY 0x70
#define IMSIC_EITHRESHOLD 0x72
#define IMSIC_EIP0 0x80
#define IMSIC_EIE0 0xc0
#define IMSIC_APLIC_DELIVERY 0x40000000ul

/* Level 0 is machine, level 1 supervisor. The caller needs CSR privilege. */
static inline void imsic_select(unsigned int level, unsigned long select)
{
    if (level)
        csr_write(0x150, select);
    else
        csr_write(0x350, select);
}
static inline unsigned long imsic_read(unsigned int level, unsigned long select)
{
    imsic_select(level, select);
    return level ? csr_read(0x151) : csr_read(0x351);
}
static inline void imsic_write(unsigned int level, unsigned long select, unsigned long value)
{
    imsic_select(level, select);
    if (level)
        csr_write(0x151, value);
    else
        csr_write(0x351, value);
}
static inline unsigned long imsic_top(unsigned int level)
{
    return level ? csr_read(0x15c) : csr_read(0x35c);
}
static inline unsigned long imsic_claim(unsigned int level)
{
    return level ? csr_swap(0x15c, 0ul) : csr_swap(0x35c, 0ul);
}
static inline void imsic_send(unsigned int level, unsigned int hart, uint32_t id)
{
    uintptr_t base = level ? IMSIC_S_BASE : IMSIC_M_BASE;
    *(volatile uint32_t *) (base + 0x1000ul * hart) = id;
}
#endif
