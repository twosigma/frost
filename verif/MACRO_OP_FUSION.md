# Macro-op fusion candidate contract

FROST now contains a conservative, verification-first fusion candidate detector at
`hw/rtl/cpu_and_mem/cpu/tomasulo/fusion/macro_op_fusion.sv`.

It recognizes generic RV64 pairs:

1. `LUI rd, imm20` + `ADDI rd, rd, imm12`
2. `AUIPC rd, imm20` + `JALR rd2, rd, imm12`
3. `LUI rd, imm20` + `JALR rd2, rd, imm12`

The detector is disabled by default (`ENABLE=0`). This is intentional. A real
fusion implementation must preserve two architectural retirements, `minstret`,
precise exceptions, debug single-step, branch recovery, and retirement trace
semantics. Detection is therefore landed first so candidate frequency can be
measured and formally constrained before changing the ROB representation.

## Next implementation gate

A functional fused micro-op should only be enabled after:

- differential retirement traces match Spike;
- `minstret` counts two source instructions for every fused pair;
- debug single-step exposes both architectural instructions;
- exceptions on either source instruction remain precise;
- branch/JALR recovery is unchanged;
- the candidate detector remains PC/data-pattern agnostic.
