# FROST Roadmap

## Single-core performance

Increase throughput from **3.91 to 4 CoreMark/MHz** while maintaining the
**322.265625 MHz** X3 clock, for 1289 CoreMark on one hart.
Measure runs of at least ten seconds with both required seed sets and CRCs.
Record compiler flags, ELF hash, memory/cache settings and inputs with each
result, and check routed timing after RTL changes.

The RV64 build must also meet or beat a locked, equally tuned RV32 reference
in cycle-exact simulation. Archive its source revision, tools/image, binaries,
commands, and timing evidence, and reproduce it before comparison. If using
a model, validate it against retained measurements and state its uncertainty
and pass criterion. Use link-order ensembles with compressed instructions.

Priorities, guided by counters and post-route timing:

1. Reduce front-end bubbles beyond the four-bundle decoded queue and 64 KiB
   BRAM predecode overlay. Compare more overlay capacity with a tagged
   predecode cache or stream buffer; preserve variable-latency fetch behavior.
2. Remove the fixed 64-bit fetch-window limit so any two consecutive legal
   instructions can issue, including a pair crossing the window. Evaluate
   compressed-code throughput across placements. CoreMark currently disables C;
   re-enable it only after a link-order ensemble shows stable throughput.
3. Reduce RV64 overhead beyond the three-cycle MULW and seventeen-cycle word
   division/remainder paths. Use instruction traces to evaluate general fusion
   or rename-time elimination. Preserve precise exceptions, retirement counts
   and debug single-step semantics; formally verify transformations.
4. Improve pointer-chase latency beyond response bypass, early memory wakeup
   and busy-port load preparation. Evaluate associativity if L0 conflict
   counters justify it, then dependent-load prefetching. Doubling L0 to 256
   entries adds little throughput; the default remains 128.
5. Revisit ROB, RS and LQ capacity when counters show pressure. INT RS 16
   captures the measured capacity benefit; larger INT RS, ROB and LQ sizes
   currently have little justification. Consider a third lane only if frontend
   and memory improvements leave a measured issue-width limit.

Changes must improve general workloads without recognizing benchmark code,
PCs, or data patterns. Run the full regression matrix in both memory tiers,
preserve DMA coherence and portable core RTL, meet the target clock, and avoid
material CoreMark-PRO or Linux regressions. LQ/L0 and capacity changes must
record coherence parameter bounds and admission/service dependencies as part
of that change, including coverage of loads through retirement.

## SMP

Add two X3 harts sharing an L2 coherence point, IPIs, per-hart PLIC contexts,
and RVWMO litmus tests. Revalidate single-hart capacity and lane choices
against the timing and memory-traffic cost of the second hart.

Before implementation, define coherence coverage for LQ L0 data, outstanding
fills, executed-but-unretired loads, AMOs, LR/SC reservations, and DMA.
LQ entries are freed at CDB capture, so snooping live entries alone does not
cover all unretired loads. Extend the DMA observation-table contract, which
tracks loads through retirement. Specify parameter bounds and admission/service
rules that let probe data and acknowledgements progress under saturation.
Review these obligations whenever transaction semantics or capacity changes.

Exit criteria: two-hart Debian, measured scaling reported separately from
single-hart performance, routed timing met, and hours of sustained-load testing
that repeatedly exercises recovery paths.

## Memory error handling

Connect DDR ECC reporting and propagate AXI error responses to software.
The current controller interrupt is unconnected, `ECC_EN_IRQ` is clear, and
the bridge checks AXI errors only in simulation. Add scrubbing and periodic
reporting: `CE_CNT` saturates at 255 and must be read and cleared. The hardware
regression's end-of-run ECC check catches errors but is not continuous monitoring.

## Deferred

A general three-wide redesign, ASIC implementation, V/H/full crypto extensions,
and Sv32 depend on demand after the work above. Optional storage paths are
iSCSI with ext4 and host-backed PCIe/virtio block storage; NFS remains the
supported root filesystem.
