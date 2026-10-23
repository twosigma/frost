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
 * Cache performance events, independent of riscv_pkg. frost_cache registers
 * each instance's events; the hierarchy carries them to the CPU.
 */
package cache_perf_pkg;

  // Width of the per-instance outstanding-miss count: enough for up to 31
  // miss-status slots, so an L2 with 16 counts all of them.
  localparam int unsigned MissOutstandingBits = 5;

  typedef struct packed {
    logic access;
    logic hit;
    logic miss;
    logic writeback;
    // Non-maintenance miss-status slots in use this cycle (a level, not a
    // pulse): the aggregator integrates it into the *_MISS_CYCLES_SUM
    // counters.
    logic [MissOutstandingBits-1:0] miss_outstanding;
    // A hit resolved while at least one miss was outstanding (the count as
    // the hit leaves the write stage).
    logic hit_under_miss;
    // Tag-stage decisions that stall. slot_full_stall: an allocation with no
    // free miss-status slot, or no free writeback slot (every allocation in
    // a cache with one-cycle tags needs one; with delayed tags only a dirty
    // victim does). conflict_stall: a request for a line in transition that
    // it can neither merge into nor wait on, a miss whose set has every way
    // owned by pending misses, or a write hit on a line still in a writeback
    // slot.
    logic slot_full_stall;
    logic conflict_stall;
  } cache_instance_perf_events_t;

  // The costs of writes narrower than a cache's line. In the hierarchy they
  // are the L2's: the L1D's writebacks and the DMA port's writes cover at
  // most 32 bytes, half of an L2 line. frost_cache registers them like the
  // events above, without keep, so a build without the counters removes
  // them, and the hierarchy carries the L2's. Maintenance traffic is
  // excluded.
  typedef struct packed {
    // A write miss took a miss-status slot that fetches its line from the
    // level below to merge into (a pulse, with the miss).
    logic write_fill;
    // Miss-status slots held by those write misses this cycle (a level, a
    // subset of miss_outstanding).
    logic [MissOutstandingBits-1:0] write_fill_outstanding;
    // A write's tag-stage decision found a read of its line in flight: the
    // line's miss-status slot fetches for a read, or a read waits on it, so
    // the write waits (a conflict stall). The pulse marks the first such
    // decision of a wait, not the decisions that repeat it.
    logic write_read_wait;
    // The tag stage holds such a write this cycle, from a decision that
    // found the read until the write's next decision (a level).
    logic write_read_waiting;
  } cache_write_perf_events_t;

  typedef struct packed {
    cache_instance_perf_events_t l1i;
    cache_instance_perf_events_t l1d;
    cache_instance_perf_events_t l2;
    cache_write_perf_events_t    l2_write;
  } cache_hierarchy_perf_events_t;

  // cpu_top adds the fetch-provider stall event for the CPU.
  typedef struct packed {
    cache_hierarchy_perf_events_t hierarchy;
    logic                         l1i_fetch_miss_stall;
  } cache_perf_events_t;

endpackage : cache_perf_pkg
