# Frontend validity and decoded bundles

`frontend_validity_tracker` tracks the IF/PD/ID image and prediction fences.
With `cpu_ooo.DECODED_QUEUE_DEPTH=0` (the default), its dispatch-valid outputs
retain the direct frontend's serialization and replay behavior.

A nonzero power-of-two depth of at least two enables `decoded_bundle_queue`.
The measured configuration uses four **two-instruction bundles**. The queue
passes an empty input through without adding latency. Registered full state
stalls frontend replacement independently of backend resource stalls; a full
queue does not accept a new bundle on its first pop cycle. A consumed-image
bit prevents an ID register held by an unrelated frontend stall from being
accepted again. Every frontend advance must either have accepted its live
image or already consumed it; the integration checks that contract.

Dispatch pops a whole bundle only on the first ROB allocation request. The
existing dispatch logic still handles the second instruction and resource
admission atomically. Queued decode and prediction metadata address the live
register-file and RAT read ports at dispatch; operand values are not frozen
at enqueue. CSR in-flight, CSR writeback and serializing-allocation state
continue to fence dispatch. A queued CSR is removed immediately, so the
legacy direct-ID advance-only release assertion applies only with the queue
disabled. The queue's once-only producer ownership replaces that mechanism.
Unpredicted indirect jumps in queued bundles extend the frontend prediction
fence. Full and partial frontend recovery discard all queued bundles and
clear producer ownership. Debug stepping keeps user NOP bundles through the
same existing `step_armed_fe_q` validity exception.

The standalone formal target proves order, arbitrary payload preservation,
held-image ownership, occupancy and flush behavior at depths two and four.
It uses an eight-bit arbitrary payload and assumes legal consumer pops and
producer replacement. Cocotb runs 4,000 randomized cycles at each depth,
including empty bypass, pointer wrap, full queues, simultaneous enqueue/pop,
held images, reset and live flushes. Whole-core program tests discharge the
integration contracts dynamically; this is not a whole-core formal proof.
