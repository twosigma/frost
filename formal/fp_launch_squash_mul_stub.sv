/*
 * Copyright (c) 2026 John Goodacre.
 */

// The multiplier's four 27-by-35 tile products are arbitrary on each edge.
// Equal operand pairs share the four values. For different operand pairs the
// two copies can choose independently. Choosing the actual tile products
// reproduces every concrete execution of the reduction and valid pipelines.
module fp_launch_squash_mul_stub (
    input  logic [105:0] i_base_operands,
    input  logic [105:0] i_cand_operands,
    output logic [247:0] o_base_terms,
    output logic [247:0] o_cand_terms
);
  (* anyseq *)logic [247:0] base_terms;
  (* anyseq *)logic [247:0] other_terms;
  assign o_base_terms = base_terms;
  assign o_cand_terms = (i_base_operands == i_cand_operands) ? base_terms : other_terms;
endmodule : fp_launch_squash_mul_stub
