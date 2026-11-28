# Binary-bound instruction evidence

`FROST_INSTRUCTION_TRACE_PATH` enables a compressed instruction stream alongside
`FROST_CALIBRATION_TRACE_PATH`. It follows the same selected run and retirement
window, but is a separate contract, `frost-instructions-v1`. The aggregate
dispatch/retire/AXI schema remains unchanged. Enable it only for the ordinary
BRAM CoreMark run, using `FROST_CALIBRATION_TEST=coremark`.

The recorder observes the production core's two allocation and retirement
ports. It retains decoded packets by ROB tag, checks each retiring PC against
its allocation, and compares the original instruction bytes against executable
ELF load segments. The ELF and loaded BRAM image have SHA-256 identities in
both the stream header and the aggregate capture manifest. A shadow integer
register file follows both retirement slots from the beginning of the run.
Memory addresses use its pre-instruction register values and the decoded
signed immediate; slot 2 sees slot 1's write in the same retirement cycle.
Wrong-path allocations never enter the output.

Each JSONL instruction records its consecutive dynamic ID, PC, little-endian
instruction bytes, length, expanded instruction, kind, architectural source
and destination registers, resolved data address and access size, branch
outcome, and architectural next PC. Zero addresses are preserved; x0 sources are omitted and x0 destinations
are null. Older streams containing x0 operands remain readable. Register dependencies are reconstructed by renaming each source
to its latest preceding architectural writer; writes to x0 create no edge.

Branches carry the recorded F0 decision and target, any PD redirect and its
decision/target, and whether execution must correct the final prediction.
PD redirects distinguish direction (TAGE/bimodal selection), backing BTB/RAS,
and ITTAGE. Their annotations follow the ID register and the decoded queue's
accepted bundle order, including held producers and empty bypass, before
allocation assigns ROB tags. Matching only by PC is insufficient when several
iterations of the same branch are in flight. Both producer and allocation
predictions are checked against the annotation. A backend flush discards
pending annotations for the killed decode stream. Execution
recovery is determined by comparing the final predicted successor with the
retired branch's resolved successor, including early recovery that does not
increment the commit-time misprediction counter.

The header records the benchmark, run, memory tier, RTL commit, binary hashes,
and window endpoints. A required footer seals the instruction count. The
manifest additionally records the compressed file hash, size, count, and
prediction tier distribution and the stream basename, never a checkout path. `instruction_stream.read_stream` rejects
unsealed files, discontinuous PCs, invalid registers/lengths/addresses,
inconsistent branch decisions, and mismatches against the capture manifest.
No measured per-instruction cycle delays enter the stream.

Capture each CI comparison in its existing simulation, rather than keeping
a full versioned stream. Compiler flags, layout, seeds and predictor state
can change independently of the workload name. Recapture prevents an old
binary or old prediction behavior from silently calibrating new RTL. The
verified capture contains 226,801 instructions and occupies about 1.9 MiB
compressed. Capture stops all signal sampling after the timed window, while warm-up
continues to establish architectural register values before it. It adds no
simulation and retains only one timed window;
the CI artifact directory already contains the larger aggregate event trace.
Small synthetic instruction fixtures exercise the contract in the fast suite.

This capture currently supports nontrapping scalar integer code. It fails
on unsupported floating-point/atomic instructions, missing allocation
evidence, unknown memory base registers, or changed instruction bytes. It
does not reconstruct self-modifying code or substitute the TestRIG injected
instruction platform for the production fetch path.
