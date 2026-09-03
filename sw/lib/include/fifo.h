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

#ifndef FIFO_H
#define FIFO_H

#include <stdint.h>

#include "mmio.h"

/* Two 32-bit MMIO FIFOs (FIFO0 and FIFO1 in mmio.h) that carry data between
 * the core and logic outside it. A store pushes a word, a load pops one.
 */

static inline void fifo0_write(uint32_t data_to_write)
{
    FIFO0 = data_to_write;
}

static inline void fifo1_write(uint32_t data_to_write)
{
    FIFO1 = data_to_write;
}

static inline uint32_t fifo0_read(void)
{
    return FIFO0;
}

static inline uint32_t fifo1_read(void)
{
    return FIFO1;
}


#endif /* FIFO_H */
