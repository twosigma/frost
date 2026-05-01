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
 * This header provides memory and instruction synchronization barriers
 * for use in bare-metal code. These are essential when:
 *   - Self-modifying code needs instruction cache coherency (fence_i)
 *   - Memory ordering guarantees are needed between cores/devices (fence)
 *
 * On Frost (RV32GCB with Zifencei), these are lightweight barriers:
 *   - No instruction cache exists, so fence.i has no cache to invalidate
 *   - The single-core memory system completes loads/stores in program order
 *     at commit
 *
 * However, using these primitives ensures code portability to more
 * complex RISC-V implementations where they have real effects.
 */

/**
 * FENCE - Memory ordering fence
 *
 * Ensures all prior memory operations (loads and stores) complete before
 * any subsequent memory operations begin. On Frost this also acts as a
 * compiler barrier, and it keeps software portable to systems with weaker
 * memory ordering.
 *
 * The "memory" clobber tells the compiler not to reorder memory accesses
 * across this barrier.
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
 * dynamic code loading) to ensure the processor fetches the new instructions.
 *
 * On Frost with unified instruction/data memory and no I-cache, this is
 * a NOP. On systems with separate I-caches, this would invalidate the
 * instruction cache.
 */
static inline __attribute__((always_inline)) void fence_i(void)
{
    __asm__ volatile("fence.i" ::: "memory");
}

#endif /* SYNC_H */
