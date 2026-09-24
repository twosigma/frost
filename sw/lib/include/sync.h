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

#ifndef SYNC_H
#define SYNC_H

/**
 * Synchronization primitives for RISC-V (Zifencei extension)
 *
 * Memory and instruction barriers for bare-metal code: fence_i() after
 * writing instructions to memory, fence() to order memory accesses against
 * other agents and devices.
 *
 * On FROST, fence waits at the ROB head until committed stores have drained.
 * fence.i also waits for the L1D to write back its dirty lines and the L1I to
 * invalidate, then flushes the pipeline and fetch buffer and refetches. The
 * L1I is read-only and does not snoop the L1D, so without fence.i instruction
 * fetch would not observe earlier stores. Outside Debug Mode, CPU stores reach
 * only the data copy of low BRAM, so self-modifying code must live in DDR.
 */

/**
 * FENCE - Memory ordering fence
 *
 * Orders all prior loads and stores before any later ones. The "memory"
 * clobber also makes it a compiler barrier: the compiler will not move
 * memory accesses across it.
 */
static inline __attribute__((always_inline)) void fence(void)
{
    __asm__ volatile("fence" ::: "memory");
}

/**
 * FENCE.I - Instruction fetch fence (Zifencei extension)
 *
 * Synchronizes the instruction stream with data memory. Required after
 * writing instructions to memory (self-modifying code, JIT compilation,
 * dynamic code loading) so the processor fetches the new instructions.
 *
 * On FROST this drains committed stores, writes back the L1D, invalidates the
 * L1I, and refetches. A build without the cache hierarchy
 * (ENABLE_CACHED_TIER=0) skips the cache steps.
 */
static inline __attribute__((always_inline)) void fence_i(void)
{
    __asm__ volatile("fence.i" ::: "memory");
}

#endif /* SYNC_H */
