// Copyright (c) 2026 John Goodacre.

/*
  Leading-zero count of WIDTH bits as a balanced tree over a power-of-two
  padding (low-order zeros). The count saturates at WIDTH for a zero input.
*/
module fp_pipe_lzc #(
    parameter int unsigned WIDTH = 217
) (
    input  logic [WIDTH-1:0] i_value,
    output logic [      8:0] o_count
);
  localparam int unsigned Levels = $clog2(WIDTH);
  localparam int unsigned PadW   = 1 << Levels;

  logic [PadW-1:0] padded;
  assign padded = {i_value, {(PadW - WIDTH) {1'b0}}};

  // Level l holds PadW >> l nodes; each node has a zero flag and an l-bit count.
  logic [  PadW-1:0] zero_l[Levels+1];
  logic [Levels-1:0] cnt_l [Levels+1] [PadW];

  always_comb begin
    for (int l = 0; l <= Levels; l++) begin
      zero_l[l] = '0;
      for (int n = 0; n < PadW; n++) cnt_l[l][n] = '0;
    end
    // Leaves: one bit each, node n covers bit PadW-1-n (MSB first).
    for (int n = 0; n < PadW; n++) zero_l[0][n] = !padded[PadW-1-n];
    for (int l = 1; l <= Levels; l++) begin
      for (int n = 0; n < (PadW >> l); n++) begin
        zero_l[l][n] = zero_l[l-1][2*n] && zero_l[l-1][2*n+1];
        if (!zero_l[l-1][2*n]) cnt_l[l][n] = cnt_l[l-1][2*n];
        else cnt_l[l][n] = cnt_l[l-1][2*n+1] | (Levels'(1) << (l - 1));
      end
    end
  end

  assign o_count = zero_l[Levels][0] ? 9'(WIDTH) : 9'(cnt_l[Levels][0]);
endmodule : fp_pipe_lzc
