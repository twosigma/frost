# Frontend validity and decoded bundles

`frontend_validity_tracker` tracks the IF/PD/ID image and prediction fences.
`decoded_bundle_queue` defaults to four **two-instruction bundles**
(`DECODED_QUEUE_DEPTH=4`). It supports power-of-two depths of at least two;
depth zero selects direct frontend serialization and replay.
The queue passes an empty input through without adding latency. Registered full state
stalls frontend replacement independently of backend resource stalls; a full
queue does not accept a new bundle on its first pop cycle. A consumed-image
bit prevents an ID register held by an unrelated frontend stall from being
accepted again. Every frontend advance must either have accepted its live
image or already consumed it; the integration checks that contract.

Dispatch pops a whole bundle only on the first ROB allocation request and
handles the second instruction and resource admission atomically.
Queued decode and prediction metadata address the live
register-file and RAT read ports at dispatch; operand values are not frozen
at enqueue. CSR in-flight, CSR writeback and serializing-allocation state
fence dispatch. A queued CSR is removed immediately, so the
direct-ID advance-only release assertion applies only with the queue
disabled.
Unpredicted indirect jumps in queued bundles extend the frontend prediction
fence. Full and partial frontend recovery discard all queued bundles and
clear producer ownership. Debug stepping keeps user NOP bundles through the
`step_armed_fe_q` validity exception.

Dispatch never reads the queue's LUTRAM directly. The oldest queued bundle
is mirrored in flops (`head_packet_q`), and the output selects it or the
empty-queue bypass with one registered select. Every narrow control field
(`riscv_pkg::id_dispatch_ctrl_t`: the flags, operation enums, RS route and
instruction word) goes further: `id_stage` exports its next-edge register
value (`o_from_id_to_ex_next`, generated from the register update itself),
and the queue keeps a registered copy of exactly what dispatch sees next
cycle, bypass included (`o_shadow`). Dispatch control, the RAT, register-file
and rename addresses therefore start at a flop; only the wide payload (values,
immediates, targets) keeps the select. The shadow's own select sits after ID's
decode, where ID's register already has its flush select.

The standalone formal target proves order, arbitrary payload preservation,
held-image ownership, occupancy and flush behavior at depths two and four.
It uses an eight-bit arbitrary payload and assumes legal consumer pops and
producer replacement. Cocotb runs 4,000 randomized cycles at each depth,
including empty bypass, pointer wrap, full queues, simultaneous enqueue/pop,
held images, reset and live flushes. Whole-core program tests check the
integration contracts in simulation.
