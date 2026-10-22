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

/* AIA direct and MSI delivery registers. Accesses are aligned words. */
#ifndef APLIC_H
#define APLIC_H

#include <stdint.h>

#define APLIC_M_BASE 0x44000000ul
#define APLIC_S_BASE 0x44008000ul
#define APLIC_NUM_SOURCES 5u
#define APLIC_REG(base, offset) (*(volatile uint32_t *) ((base) + (offset)))
#define APLIC_DOMAINCFG(base) APLIC_REG(base, 0x0000ul)
#define APLIC_SOURCECFG(base, source) APLIC_REG(base, 4ul * (source))
#define APLIC_MMSIADDRCFG APLIC_REG(APLIC_M_BASE, 0x1BC0ul)
#define APLIC_MMSIADDRCFGH APLIC_REG(APLIC_M_BASE, 0x1BC4ul)
#define APLIC_SMSIADDRCFG APLIC_REG(APLIC_M_BASE, 0x1BC8ul)
#define APLIC_SMSIADDRCFGH APLIC_REG(APLIC_M_BASE, 0x1BCCul)
#define APLIC_GENMSI(base) APLIC_REG(base, 0x3000ul)
#define APLIC_SETIP(base) APLIC_REG(base, 0x1C00ul)
#define APLIC_SETIPNUM(base) APLIC_REG(base, 0x1CDCul)
#define APLIC_CLRIPNUM(base) APLIC_REG(base, 0x1DDCul)
#define APLIC_SETIE(base) APLIC_REG(base, 0x1E00ul)
#define APLIC_SETIENUM(base) APLIC_REG(base, 0x1EDCul)
#define APLIC_CLRIE(base) APLIC_REG(base, 0x1F00ul)
#define APLIC_CLRIENUM(base) APLIC_REG(base, 0x1FDCul)
#define APLIC_TARGET(base, source) APLIC_REG(base, 0x3000ul + 4ul * (source))
#define APLIC_IDELIVERY(base) APLIC_REG(base, 0x4000ul)
#define APLIC_IFORCE(base) APLIC_REG(base, 0x4004ul)
#define APLIC_ITHRESHOLD(base) APLIC_REG(base, 0x4008ul)
#define APLIC_TOPI(base) APLIC_REG(base, 0x4018ul)
#define APLIC_CLAIMI(base) APLIC_REG(base, 0x401Cul)

#define APLIC_DOMAINCFG_DM (1u << 2)
#define APLIC_DOMAINCFG_IE (1u << 8)
#define APLIC_SOURCE_DELEGATE (1u << 10)
#define APLIC_SOURCE_DETACHED 1u
#define APLIC_SOURCE_EDGE_RISE 4u
#define APLIC_SOURCE_LEVEL_HIGH 6u
#define APLIC_IDENTITY(topi) ((uint32_t) (topi) >> 16)

/* Configure one level source for hart 0 in the machine domain. Other
 * sources retain their configuration. A level claim needs no completion;
 * the handler clears the interrupt condition in the device. */
static inline void aplic_enable_machine_source(uint32_t source)
{
    APLIC_SOURCECFG(APLIC_M_BASE, source) = APLIC_SOURCE_LEVEL_HIGH;
    APLIC_TARGET(APLIC_M_BASE, source) = 1;
    APLIC_SETIENUM(APLIC_M_BASE) = source;
    APLIC_ITHRESHOLD(APLIC_M_BASE) = 0;
    APLIC_IDELIVERY(APLIC_M_BASE) = 1;
    APLIC_DOMAINCFG(APLIC_M_BASE) = APLIC_DOMAINCFG_IE;
}

static inline void aplic_disable_machine_source(uint32_t source)
{
    APLIC_CLRIENUM(APLIC_M_BASE) = source;
}

static inline uint32_t aplic_claim_machine(void)
{
    return APLIC_IDENTITY(APLIC_CLAIMI(APLIC_M_BASE));
}

#endif /* APLIC_H */
