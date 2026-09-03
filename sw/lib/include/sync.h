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
 * On Frost (RV64GCB with Zifencei) the cost depends on the memory tier.
 * With the cached tier active, fence.i writes back the L1D and then
 * invalidates the L1I. The L1I is read-only and does not snoop the L1D, so
 * without that sequence instruction fetches would not observe prior data
 * stores. In the low-BRAM tier there is no cache hierarchy and fence.i
 * completes immediately. fence orders a single-core memory system that
 * already retires loads and stores in program order at commit. Using both
 * keeps code portable to implementations where they have real effects.
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
 * On Frost this writes back the L1D and then invalidates the L1I when the
 * cached tier is active; in the low-BRAM tier (no caches) it is a NOP.
 */
static inline __attribute__((always_inline)) void fence_i(void)
{
    __asm__ volatile("fence.i" ::: "memory");
}

#endif /* SYNC_H */
