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

// The two-owner model requires a cut at every observing hart, including a
// hart without a resident private tag.
module coherent_local_owners_formal (
    input logic i_clk
);
  logic past_q = 0;
  wire  rst = !past_q;
  always_ff @(posedge i_clk) past_q <= 1;
  (* anyseq *) logic lr, observe, evict, put_ack, start_atomic, sc, peer_request;
  (* anyseq *) logic install, accept_probe, accept_reply, grant_peer, peer_write, return_owner;
  (* anyconst *) logic [7:0] initial_byte, replacement;
  logic local_m, peer_m, resident, frozen, reservation, observation, replay;
  logic atomic_owner, atomic_sc, atomic_written, request_pending, reply_pending, cut_done;
  logic [7:0] value, snapshot, reply_data;
  logic peer_seen, evicted_reservation, evicted_observation;
  always_ff @(posedge i_clk) begin
    if (rst) begin
      local_m <= 1;
      peer_m <= 0;
      resident <= 1;
      frozen <= 0;
      reservation <= 0;
      observation <= 0;
      replay <= 0;
      atomic_owner <= 0;
      atomic_sc <= 0;
      atomic_written <= 0;
      request_pending <= 0;
      reply_pending <= 0;
      cut_done <= 0;
      value <= initial_byte;
      snapshot <= 0;
      reply_data <= 0;
      peer_seen <= 0;
      evicted_reservation <= 0;
      evicted_observation <= 0;
    end else begin
      // The local-controller proof supplies service exclusion and installation order.
      assume (!accept_probe || (request_pending && !atomic_owner && !reply_pending));
      assume (!start_atomic || (resident && local_m && !atomic_owner &&
          !reply_pending && !accept_probe));
      assume (!install || (atomic_owner && !atomic_written));
      assume (!evict || (resident && !atomic_owner && !accept_probe && !start_atomic));
      assume (!lr || (resident && !atomic_owner && !accept_probe && !start_atomic));
      assume (!observe || (resident && local_m && !accept_probe && !start_atomic));
      assume (!put_ack || frozen);
      // The shared home cannot publish conflicting permission before the
      // owner's response and the observing hart's invalidation cut.
      assume (!accept_reply || reply_pending);
      assume (!grant_peer || (request_pending && cut_done && !reply_pending &&
          !local_m && !atomic_owner));
      assume (!peer_write || peer_m);
      assume (!return_owner || (peer_m && !peer_write));
      assume (!peer_request || (!request_pending && !peer_m));
      if (lr) reservation <= 1;
      if (observe) begin
        observation <= 1;
        replay <= 0;
      end
      if (evict) begin
        resident <= 0;
        frozen <= local_m;
        evicted_reservation <= reservation;
        evicted_observation <= observation;
      end
      if (put_ack) begin
        frozen  <= 0;
        local_m <= 0;
      end
      if (start_atomic && (!sc || reservation)) begin
        atomic_owner <= 1;
        atomic_sc <= sc;
        atomic_written <= 0;
        snapshot <= value;
      end
      if (install) begin
        value <= replacement;
        atomic_written <= 1;
        reservation <= 0;
      end
      if (atomic_owner && atomic_written) atomic_owner <= 0;
      if (peer_request) begin
        request_pending <= 1;
        cut_done <= 0;
      end
      if (accept_probe) begin
        reply_pending <= 1;
        reply_data <= value;
        local_m <= 0;
        resident <= 0;
        frozen <= 0;
        reservation <= 0;
        replay <= observation;
        cut_done <= 1;
      end
      if (accept_reply) reply_pending <= 0;
      if (grant_peer) begin
        request_pending <= 0;
        peer_m <= 1;
        peer_seen <= 1;
      end
      if (peer_write) value <= replacement;
      if (return_owner) begin
        peer_m   <= 0;
        local_m  <= 1;
        resident <= 1;
      end
      assert (!(local_m && peer_m));
      if (atomic_owner) begin
        assert (local_m && resident && !peer_m);
        assert (!accept_probe && !evict);
        assert (value == (atomic_written ? replacement : snapshot));
        if (atomic_sc && !atomic_written) assert (reservation);
      end
      if (grant_peer) begin
        assert (!reservation);
        if (observation) assert (replay);
        assert (reply_data == value);
      end
      if (peer_seen && evicted_reservation && !lr) begin
        if (start_atomic && sc && !reservation) assert (!install);
      end
      cover (atomic_owner && peer_request);
      cover (grant_peer && atomic_written);
      cover (grant_peer && evicted_reservation);
      cover (grant_peer && evicted_observation && replay);
      cover (peer_seen && start_atomic && sc && !reservation);
      cover (atomic_written && evict);
    end
  end
endmodule
