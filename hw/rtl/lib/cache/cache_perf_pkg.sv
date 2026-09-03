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
 * Cache-hierarchy performance-observer types.
 *
 * Kept in a cache-local package so the standalone cache file list and unit
 * benches do not depend on the CPU's monolithic riscv_pkg.  frost_cache
 * registers every field in cache_instance_perf_events_t at the source before
 * the hierarchy carries the bundle toward the CPU.
 */
package cache_perf_pkg;

  // Width of the per-instance outstanding-miss count. Sized for the
  // non-blocking cache's miss-status slots; a blocking instance reports 0/1.
  localparam int unsigned MissOutstandingBits = 4;

  typedef struct packed {
    logic access;
    logic hit;
    logic miss;
    logic writeback;
    // Number of unresolved non-maintenance misses this cycle (a level, not a
    // pulse): the aggregator integrates it into the *_MISS_CYCLES_SUM
    // counters.
    logic [MissOutstandingBits-1:0] miss_outstanding;
    // A hit resolved while at least one miss was outstanding.
    logic hit_under_miss;
    // Stall cycles at the tag stage: an allocation with no free miss-status
    // slot (or no writeback slot for its dirty victim), and a request behind
    // an index in transition that it can neither merge into nor wait on.
    logic slot_full_stall;
    logic conflict_stall;
  } cache_instance_perf_events_t;

  typedef struct packed {
    cache_instance_perf_events_t l1i;
    cache_instance_perf_events_t l1d;
    cache_instance_perf_events_t l2;
  } cache_hierarchy_perf_events_t;

  // Complete bundle crossing from cpu_and_mem into cpu_ooo.  The hierarchy
  // supplies the three per-instance groups; cpu_and_mem adds the fetch-seam
  // stall observer before crossing the CPU boundary.
  typedef struct packed {
    cache_hierarchy_perf_events_t hierarchy;
    logic                         l1i_fetch_miss_stall;
  } cache_perf_events_t;

endpackage : cache_perf_pkg
