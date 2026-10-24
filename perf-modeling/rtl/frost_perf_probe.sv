// Copyright (c) 2026 John Goodacre.
// SPDX-License-Identifier: Apache-2.0
// Simulation-only probe. Instantiate from a wrapper or bind module after
// connecting the accepted handshake events named in perf-modeling/README.md.
module frost_perf_probe #(
    parameter string TRACE_PATH = "frost_perf.jsonl"
) (
    input logic clk,
    input logic reset_n,
    input logic dispatch_fire,
    input logic [1:0] dispatch_uops,
    input logic retire_fire,
    input logic [1:0] retire_uops,
    input logic axi_fire,
    input logic [5:0] axi_id,
    input logic [63:0] axi_address,
    input logic axi_is_write,
    input logic axi_response_fire,
    input logic [5:0] axi_response_id,
    input logic axi_ok
);
  integer fd;
  longint unsigned cycle;
  initial begin
    fd = $fopen(TRACE_PATH, "w");
    if (!fd) $fatal(1, "cannot open calibration trace");
    $fwrite(fd, "{\"cycle\":0,\"event\":\"meta\",\"source\":\"frost_perf_probe\",");
    $fwrite(fd, "\"rtl_commit\":\"SET_BY_WRAPPER\",\"clock_domain\":\"cpu\",");
    $fwrite(fd, "\"memory_configuration\":\"SET_BY_WRAPPER\"}\n");
    cycle = 0;
  end
  always_ff @(posedge clk) begin
    if (!reset_n) cycle <= 0;
    else begin
      if (dispatch_fire)
        $fwrite(
            fd,
            "{\"cycle\":%0d,\"event\":\"dispatch\",\"source\":\"rob\",\"uops\":%0d}\n",
            cycle,
            dispatch_uops
        );
      if (retire_fire)
        $fwrite(
            fd,
            "{\"cycle\":%0d,\"event\":\"retire\",\"source\":\"rob\",\"uops\":%0d}\n",
            cycle,
            retire_uops
        );
      if (axi_fire) begin
        $fwrite(fd, "{\"cycle\":%0d,\"event\":\"axi_request\",\"source\":\"axi\",", cycle);
        $fwrite(fd, "\"axi_id\":%0d,\"address\":\"0x%h\",", axi_id, axi_address);
        $fwrite(fd, "\"is_write\":%s,\"bytes\":64}\n", axi_is_write ? "true" : "false");
      end
      if (axi_response_fire) begin
        $fwrite(fd, "{\"cycle\":%0d,\"event\":\"axi_response\",\"source\":\"axi\",", cycle);
        $fwrite(fd, "\"axi_id\":%0d,\"ok\":%s}\n", axi_response_id, axi_ok ? "true" : "false");
      end
      cycle <= cycle + 1;
    end
  end
  final $fclose(fd);
endmodule
