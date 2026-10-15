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
 * line_size_adapter: carries line-protocol transactions of UP_LINE_BYTES
 * lines to a level with DOWN_LINE_BYTES lines, each narrow line a sector of
 * the wide one (hw/rtl/lib/cache/README.md, "The L2 line size").
 *
 * The adapter is transactional; it holds no data. A request keeps its
 * handshake and its id: valid and ready pass straight through, so the
 * adapter accepts a request exactly when the level below does, and the
 * coherence sequencers' ordering arguments, which rest on that acceptance,
 * carry over unchanged. The address is aligned to the wide line.
 *
 * The sector mapping has three separate parts:
 *   - data:     the narrow line is copied into every sector of the wide one;
 *   - strobes:  the narrow strobes go into the request's sector and nowhere
 *               else, so a write changes only its own sector's bytes;
 *   - response: the request's sector of the wide line is returned.
 * An outstanding-transaction table with one entry per id records each
 * request's sector when it fires, and the response, which carries the same
 * id, reads it back. A master keeps its ids unique among its requests in
 * flight, so an entry is not rewritten while its request is outstanding;
 * simulation checks that, and that every response answers an outstanding
 * request.
 */
module line_size_adapter #(
    parameter int unsigned ADDR_WIDTH = 32,
    parameter int unsigned UP_LINE_BYTES = 32,
    parameter int unsigned DOWN_LINE_BYTES = 64,
    parameter int unsigned ID_BITS = 5
) (
    input logic i_clk,
    input logic i_rst,

    // Upstream line port (slave), UP_LINE_BYTES lines.
    input  logic                       i_up_req_valid,
    output logic                       o_up_req_ready,
    input  logic                       i_up_req_write,
    input  logic [     ADDR_WIDTH-1:0] i_up_req_addr,
    input  logic [UP_LINE_BYTES*8-1:0] i_up_req_wdata,
    input  logic [  UP_LINE_BYTES-1:0] i_up_req_wstrb,
    input  logic [        ID_BITS-1:0] i_up_req_id,
    input  logic                       i_up_req_maintenance,
    output logic                       o_up_resp_valid,
    output logic [        ID_BITS-1:0] o_up_resp_id,
    output logic [UP_LINE_BYTES*8-1:0] o_up_resp_rdata,

    // Downstream line port (master), DOWN_LINE_BYTES lines.
    output logic                         o_down_req_valid,
    input  logic                         i_down_req_ready,
    output logic                         o_down_req_write,
    output logic [       ADDR_WIDTH-1:0] o_down_req_addr,
    output logic [DOWN_LINE_BYTES*8-1:0] o_down_req_wdata,
    output logic [  DOWN_LINE_BYTES-1:0] o_down_req_wstrb,
    output logic [          ID_BITS-1:0] o_down_req_id,
    output logic                         o_down_req_maintenance,
    input  logic                         i_down_resp_valid,
    input  logic [          ID_BITS-1:0] i_down_resp_id,
    input  logic [DOWN_LINE_BYTES*8-1:0] i_down_resp_rdata
);

  localparam int unsigned Sectors = DOWN_LINE_BYTES / UP_LINE_BYTES;
  localparam int unsigned SectorBits = (Sectors > 1) ? $clog2(Sectors) : 1;
  localparam int unsigned UpLineBits = UP_LINE_BYTES * 8;
  localparam int unsigned UpOffsetBits = $clog2(UP_LINE_BYTES);
  localparam int unsigned DownOffsetBits = $clog2(DOWN_LINE_BYTES);
  localparam int unsigned NumIds = 1 << ID_BITS;

  initial begin
    if ((2 ** UpOffsetBits != UP_LINE_BYTES) || (2 ** DownOffsetBits != DOWN_LINE_BYTES))
      $fatal(1, "line_size_adapter: line sizes must be powers of 2");
    if (DOWN_LINE_BYTES <= UP_LINE_BYTES)
      $fatal(1, "line_size_adapter: DOWN_LINE_BYTES must exceed UP_LINE_BYTES");
  end

  logic up_fire;
  logic [SectorBits-1:0] req_sector;
  assign up_fire = i_up_req_valid && i_down_req_ready;
  assign req_sector = i_up_req_addr[DownOffsetBits-1:UpOffsetBits];

  // ---- Handshake, kind, id, and address --------------------------------------
  assign o_down_req_valid = i_up_req_valid;
  assign o_up_req_ready = i_down_req_ready;
  assign o_down_req_write = i_up_req_write;
  assign o_down_req_maintenance = i_up_req_maintenance;
  assign o_down_req_id = i_up_req_id;
  assign o_down_req_addr = {i_up_req_addr[ADDR_WIDTH-1:DownOffsetBits], {DownOffsetBits{1'b0}}};

  // ---- Data mapping: the narrow line in every sector ------------------------
  assign o_down_req_wdata = {Sectors{i_up_req_wdata}};

  // ---- Strobe mapping: the narrow strobes in the request's sector only -----
  for (genvar s = 0; s < int'(Sectors); s++) begin : gen_sector_strobes
    assign o_down_req_wstrb[s*UP_LINE_BYTES+:UP_LINE_BYTES] =
        (req_sector == SectorBits'(s)) ? i_up_req_wstrb : '0;
  end

  // ---- Outstanding-transaction table: each request's sector, by id ---------
  logic [SectorBits-1:0] sector_q[NumIds];
  always_ff @(posedge i_clk) begin
    if (up_fire) sector_q[i_up_req_id] <= req_sector;
  end

  // ---- Response mapping: the request's sector of the wide line -------------
  logic [SectorBits-1:0] resp_sector;
  assign resp_sector = sector_q[i_down_resp_id];
  assign o_up_resp_valid = i_down_resp_valid;
  assign o_up_resp_id = i_down_resp_id;
  assign o_up_resp_rdata = i_down_resp_rdata[resp_sector*UpLineBits+:UpLineBits];

`ifndef SYNTHESIS
`ifndef FORMAL
  // The table's other columns, for the protocol checks: which ids are
  // outstanding, and whether each is a write.
  logic [NumIds-1:0] outstanding_q, write_q;
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      outstanding_q <= '0;
    end else begin
      if (i_down_resp_valid) begin
        if (!outstanding_q[i_down_resp_id])
          $error(
              "line_size_adapter: response for id %0d, which is not outstanding", i_down_resp_id
          );
        outstanding_q[i_down_resp_id] <= 1'b0;
      end
      if (up_fire) begin
        if (outstanding_q[i_up_req_id] && !(i_down_resp_valid && (i_down_resp_id == i_up_req_id)))
          $error("line_size_adapter: request reuses id %0d while it is outstanding", i_up_req_id);
        outstanding_q[i_up_req_id] <= 1'b1;
        write_q[i_up_req_id] <= i_up_req_write;
      end
    end
  end
`endif
`endif

`ifdef FORMAL
  initial assume (i_rst);

  // The master keeps ids unique among its requests in flight, and the level
  // below answers each request once, after it fires. f_id is an arbitrary id
  // whose transactions the properties follow.
  (* anyconst *) logic [ID_BITS-1:0] f_id;
  logic f_outstanding;
  logic [SectorBits-1:0] f_sector;
  initial f_outstanding = 1'b0;
  always @(posedge i_clk) begin
    if (i_rst) begin
      f_outstanding <= 1'b0;
    end else begin
      if (i_down_resp_valid && (i_down_resp_id == f_id)) f_outstanding <= 1'b0;
      if (up_fire && (i_up_req_id == f_id)) begin
        f_outstanding <= 1'b1;
        f_sector <= req_sector;
      end
    end
  end
  always_comb begin
    if (!i_rst && i_up_req_valid && (i_up_req_id == f_id)) begin
      a_unique_ids : assume (!f_outstanding);
    end
    if (!i_rst && i_down_resp_valid && (i_down_resp_id == f_id)) begin
      a_answers_outstanding : assume (f_outstanding);
    end
  end

  // Reference forms, byte by byte: downstream byte b is in sector
  // b / UP_LINE_BYTES and mirrors upstream byte b % UP_LINE_BYTES.
  logic [DOWN_LINE_BYTES-1:0] f_wstrb;
  logic f_wdata_ok, f_rdata_ok;
  always_comb begin
    f_wdata_ok = 1'b1;
    for (int b = 0; b < int'(DOWN_LINE_BYTES); b++) begin
      f_wstrb[b] = (int'(i_up_req_addr[DownOffsetBits-1:0]) / int'(UP_LINE_BYTES) ==
                    b / int'(UP_LINE_BYTES)) && i_up_req_wstrb[b%int'(UP_LINE_BYTES)];
      if (o_down_req_wdata[b*8+:8] != i_up_req_wdata[(b%int'(UP_LINE_BYTES))*8+:8])
        f_wdata_ok = 1'b0;
    end
    f_rdata_ok = 1'b1;
    for (int b = 0; b < int'(UP_LINE_BYTES); b++) begin
      if (o_up_resp_rdata[b*8+:8] != i_down_resp_rdata[(int'(f_sector)*int'(UP_LINE_BYTES)+b)*8+:8])
        f_rdata_ok = 1'b0;
    end
  end

  always_comb begin
    p_handshake :
    assert ((o_down_req_valid == i_up_req_valid) && (o_up_req_ready == i_down_req_ready));
    p_request_kind :
    assert ((o_down_req_write == i_up_req_write) &&
                             (o_down_req_maintenance == i_up_req_maintenance) &&
                             (o_down_req_id == i_up_req_id));
    p_wide_line_address :
    assert ((o_down_req_addr >> DownOffsetBits) == (i_up_req_addr >> DownOffsetBits) &&
            (o_down_req_addr[DownOffsetBits-1:0] == '0));
    p_strobes_in_own_sector : assert (o_down_req_wstrb == f_wstrb);
    p_data_in_every_sector : assert (f_wdata_ok);
    p_response_valid_and_id :
    assert ((o_up_resp_valid == i_down_resp_valid) && (o_up_resp_id == i_down_resp_id));
    // A response for f_id returns the sector of the request that took f_id.
    if (!i_rst && i_down_resp_valid && (i_down_resp_id == f_id)) begin
      p_response_sector : assert (f_rdata_ok);
    end
  end

  always @(posedge i_clk) begin
    if (!i_rst) begin
      for (int s = 0; s < int'(Sectors); s++) begin
        // A response returns each sector, after its request fired.
        cover (i_down_resp_valid && (i_down_resp_id == f_id) && (int'(f_sector) == s));
      end
      // A request and the response to another fire together.
      cover (up_fire && i_down_resp_valid && (i_down_resp_id != i_up_req_id));
    end
  end
`endif

endmodule : line_size_adapter
