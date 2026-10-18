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
 * Cache geometry and line eviction for test programs.
 *
 * The L1D, L1I, and L2 are 4-way with tree pseudo-LRU replacement. The L1D
 * also uses bimodal insertion: a fill becomes its set's most recently used
 * only one time in 32, so reading new lines of a set once replaces one way of
 * it over and over and evicts nothing else. An access that hits a line makes
 * it most recently used. A program that pushes a line out of the L1D with
 * other lines of its set touches each of them with cache_touch_line, which
 * reads the line and then hits it; CACHE_EVICTING_LINES lines not already
 * cached, touched that way, evict every line the set held
 * (hw/rtl/lib/cache/README.md, "Sets and ways"). In the L1I and the L2,
 * every fill becomes most recently used, so plain accesses do the same
 * there.
 *
 * The hit must reach the L1D. The load queue's L0 answers a repeated read of
 * the same doubleword, and a read issued before the line's fill completes
 * waits on the miss instead of hitting, so the second read takes the next
 * doubleword of the line at an address that depends on the first read's
 * value.
 */
#ifndef CACHE_EVICT_H
#define CACHE_EVICT_H

#include <stdint.h>

#define CACHE_L1D_BYTES (128u * 1024u)
#define CACHE_L1D_WAYS 4u
/* Lines this far apart share an L1D set. */
#define CACHE_L1D_WAY_BYTES (CACHE_L1D_BYTES / CACHE_L1D_WAYS)
#define CACHE_L2_BYTES (2u * 1024u * 1024u)
#define CACHE_L2_WAYS 4u
/* Lines this far apart share an L2 set. */
#define CACHE_L2_WAY_BYTES (CACHE_L2_BYTES / CACHE_L2_WAYS)
/* Lines of a set, not already cached and each touched with
 * cache_touch_line, that evict any line the set held: the first ways - 1
 * may take invalid ways, and then the tree pseudo-LRU replaces every way
 * within `ways` lines. */
#define CACHE_EVICTING_LINES (2u * CACHE_L1D_WAYS - 1u)

/* Read the 32-byte line holding p, then hit it in the L1D, which makes it
 * its set's most recently used. p is 8-byte aligned and not in the line's
 * last doubleword. Returns the sum of the two doublewords read. */
static inline uint64_t cache_touch_line(uintptr_t p)
{
    uint64_t first = *(volatile uint64_t *) p;
    uint64_t zero;
    __asm__ volatile("and %0, %1, zero" : "=r"(zero) : "r"(first));
    return first + *(volatile uint64_t *) (p + 8u + zero);
}

#endif /* CACHE_EVICT_H */
