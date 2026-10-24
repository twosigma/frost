// Simulation-only probe. Instantiate from a wrapper or bind module after
// connecting the accepted handshake events named in perf-modelling/README.md.
module frost_perf_probe #(
  parameter string TRACE_PATH = "frost_perf.jsonl"
) (
  input logic clk,
  input logic reset_n,
  input logic dispatch_fire, input logic [1:0] dispatch_uops,
  input logic retire_fire, input logic [1:0] retire_uops,
  input logic axi_fire, input logic [5:0] axi_id, input logic [63:0] axi_address,
  input logic axi_is_write,
  input logic axi_response_fire, input logic [5:0] axi_response_id, input logic axi_ok
);
  integer fd;
  longint unsigned cycle;
  initial begin
    fd = $fopen(TRACE_PATH, "w");
    if (!fd) $fatal(1, "cannot open calibration trace");
    $fwrite(fd, "{\"cycle\":0,\"event\":\"meta\",\"source\":\"frost_perf_probe\",\"rtl_commit\":\"SET_BY_WRAPPER\",\"clock_domain\":\"cpu\",\"memory_configuration\":\"SET_BY_WRAPPER\"}\n");
    cycle = 0;
  end
  always_ff @(posedge clk) begin
    if (!reset_n) cycle <= 0;
    else begin
      if (dispatch_fire) $fwrite(fd, "{\"cycle\":%0d,\"event\":\"dispatch\",\"source\":\"rob\",\"uops\":%0d}\n", cycle, dispatch_uops);
      if (retire_fire) $fwrite(fd, "{\"cycle\":%0d,\"event\":\"retire\",\"source\":\"rob\",\"uops\":%0d}\n", cycle, retire_uops);
      if (axi_fire) $fwrite(fd, "{\"cycle\":%0d,\"event\":\"axi_request\",\"source\":\"axi\",\"axi_id\":%0d,\"address\":\"0x%h\",\"is_write\":%s,\"bytes\":64}\n", cycle, axi_id, axi_address, axi_is_write ? "true" : "false");
      if (axi_response_fire) $fwrite(fd, "{\"cycle\":%0d,\"event\":\"axi_response\",\"source\":\"axi\",\"axi_id\":%0d,\"ok\":%s}\n", cycle, axi_response_id, axi_ok ? "true" : "false");
      cycle <= cycle + 1;
    end
  end
  final $fclose(fd);
endmodule
