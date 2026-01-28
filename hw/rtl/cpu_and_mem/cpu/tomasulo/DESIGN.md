# FROST Tomasulo Out-of-Order Execution

This directory contains the Tomasulo algorithm implementation for out-of-order
execution in FROST. The design adds dynamic instruction scheduling while
maintaining the existing ISA support and test compatibility.

## Overview

The Tomasulo transformation preserves the front-end (IF/PD/ID) while replacing
the in-order back-end with out-of-order execution machinery. The implementation
supports both integer (RV32IMACB) and floating-point (RV32FD) operations.

**Key Components:**
- **ROB (Reorder Buffer)** - In-order commit, precise exceptions, unified for INT/FP
- **INT RAT (Integer Register Alias Table)** - Integer register renaming (x0-x31)
- **FP RAT (FP Register Alias Table)** - Floating-point register renaming (f0-f31)
- **Reservation Stations** - Operand tracking, issue logic, CDB snoop
  - INT_RS: Integer ALU operations
  - MUL_RS: Integer multiply/divide
  - MEM_RS: Loads/stores (integer and FP)
  - FP_RS: FP add/sub/compare/convert
  - FMUL_RS: FP multiply
  - FDIV_RS: FP divide/sqrt (long latency)
- **Load/Store Queues** - Memory disambiguation, store-to-load forwarding
- **CDB (Common Data Bus)** - Result broadcast and arbitration (XLEN/FLEN width); lane-parameterized for future multi-bus expansion

**Design Goals:**
- All existing tests passing (366+ instruction ISA tests, CoreMark, FreeRTOS)
- Timing closure at 322MHz on Ultrascale+
- Reuse existing functional units (ALU, multiplier, divider, FPU)
- Conservative memory disambiguation (loads wait for older store addresses)
- Full support for F (single) and D (double) floating-point extensions

**Terminology:**
- **XLEN** = 32 bits (integer register width for RV32)
- **FLEN** = 64 bits (FP register width for D extension)

**Existing FROST Features Preserved:**
- 32-entry branch predictor
- Return Address Stack (RAS) for call/return prediction
- RVC decompression
- M-mode privilege support
- Atomic (A) extension support

---

## High-Level Architecture

### FROST-Tomasulo Block Diagram

```
                        FROST-Tomasulo High-Level Architecture
    +------------------------------------------------------------------------------------+
    |                                                                                    |
    |  +-----------------------------------------------------------------------+         |
    |  |                         Front-End (In-Order)                          |         |
    |  |                                                                       |         |
    |  |   +--------+     +--------+     +--------+                            |         |
    |  |   |   IF   |---->|   PD   |---->|   ID   |----+                       |         |
    |  |   | Fetch  |     |Pre-Dec |     | Decode |    |                       |         |
    |  |   +--------+     +--------+     +--------+    |                       |         |
    |  |       ^              ^                        | Decoded               |         |
    |  |       |              |                        | Instructions          |         |
    |  |   +---+---+    +-----+-----+                  v                       |         |
    |  |   |  BTB  |    |   RAS     |   +--------------+-------------------+   |         |
    |  |   | (32)  |    | (Return   |   |            DISPATCH              |   |         |
    |  |   +-------+    |  Addr     |   |  - Allocate ROB entry            |   |         |
    |  |       ^        |  Stack)   |   |  - Read/rename via INT/FP RAT    |   |         |
    |  |       |        +-----+-----+   |  - Send to Reservation Station   |   |         |
    |  |       |              |         +--------------+-------------------+   |         |
    |  |       | Branch       | RAS                    |                       |         |
    |  |       | Redirect     | Restore                |                       |         |
    |  |       |              | (mispredict)           |                       |         |
    |  +-------+--------------+------------------------+-------+---------------+         |
    |          |                                       |       |                         |
    |          |     +---------------------------------+       |                         |
    |          |     |                                         |                         |
    |          |     v                                         v                         |
    |  +-------+-----+-----+     +----------------------------------------------------+  |
    |  |                   |     |              Out-of-Order Back-End                 |  |
    |  |        ROB        |     |                                                    |  |
    |  |  (Reorder Buffer) |     |  +-----------+  +-----------+  +-----------+       |  |
    |  |                   |     |  |  INT RS   |  |  MUL RS   |  | LD/ST RS  |       |  |
    |  |  - Unified INT/FP |     |  | (ALU ops) |  | (MUL/DIV) |  | (Memory)  |       |  |
    |  |  - In-order alloc |     |  +-----+-----+  +-----+-----+  +-----+-----+       |  |
    |  |  - In-order commit|     |        |             |             |               |  |
    |  |  - Exception track|     |  +-----+-----+  +-----+-----+  +-----+-----+       |  |
    |  +-------------------+     |  |   FP RS   |  | FMUL RS   |  | FDIV RS   |       |  |
    |          |                 |  | (FP add/  |  | (FP mul)  |  | (FP div/  |       |  |
    |          |                 |  |  sub/cmp) |  |           |  |  sqrt)    |       |  |
    |          v                 |  +-----+-----+  +-----+-----+  +-----+-----+       |  |
    |  +-------------------+     |        |             |             |               |  |
    |  |   INT RAT (x0-x31)|     |        v             v             v               |  |
    |  | + FP RAT (f0-f31) |     |  +-----+-----+  +-----+-----+  +----+------+       |  |
    |  |                   |     |  |    ALU    |  |    FPU    |  |Load Queue |       |  |
    |  |  - Arch -> ROB    |     |  |Multiplier |  |(ADD/MUL/  |  |Store Queue|       |  |
    |  |  - Checkpoint for |     |  |  Divider  |  | DIV/SQRT) |  +-----------+       |  |
    |  |    recovery       |     |  +-----+-----+  +-----+-----+        |             |  |
    |  +-------------------+     |        |             |               |             |  |
    |          ^                 |        +------+------+-------+-------+             |  |
    |          |                 |               |              |                     |  |
    |          |                 |               v              v                     |  |
    |          |                 |       +-------+-------+  +---+--------+            |  |
    |          +-----------------+-------+      CDB      |  |  Memory    |            |  |
    |                            |       |(FLEN for D)   |  | Interface  |            |  |
    |                            |       +---------------+  +------------+            |  |
    |                            +----------------------------------------------------+  |
    |                                                                                    |
    +------------------------------------------------------------------------------------+
```

### Tomasulo Data Flow (with Floating-Point)

```
                           Tomasulo Data Flow
    +------------------------------------------------------------------------+
    |                                                                        |
    |  FROM DECODE                                                           |
    |       |                                                                |
    |       v                                                                |
    |  +----+----+    +---------------+    +--------------------------------+|
    |  |         |    |               |    |                                ||
    |  | DISPATCH|--->| INT RAT (x)   |--->|      RESERVATION STATIONS      ||
    |  |         |    | FP RAT  (f)   |    |                                ||
    |  +----+----+    +-------+-------+    | +-------+ +-------+ +-------+  ||
    |       |                 |            | |INT RS | |MUL RS | |MEM RS |  ||
    |       |                 |            | +---+---+ +---+---+ +---+---+  ||
    |       v                 |            | +-------+ +-------+ +-------+  ||
    |  +----+----+            |            | |FP RS  | |FMUL RS| |FDIV RS|  ||
    |  |         |            |            | +---+---+ +---+---+ +---+---+  ||
    |  |   ROB   |            |            +-----+---------+---------+------+|
    |  | (Unified|            |                  |         |         |       |
    |  |  INT/FP)|            |                  | ISSUE (when operands ready)
    |  |         |            |                  v         v         v       |
    |  | Entry:  |            |           +------+--+ +----+----+ +--+-----+ |
    |  | - PC    |            |           |   ALU   | |   FPU   | |LD Queue| |
    |  | - Dest  |            |           |   MUL   | | ADD/MUL | +--------+ |
    |  | - DestRF|            |           |   DIV   | | DIV/SQRT| |ST Queue| |
    |  |  (INT/FP|            |           +----+----+ +----+----+ +---+----+ |
    |  | - Value |            |                |           |         |       |
    |  | - Done  |            |                +-----+-----+---------+       |
    |  | - Exc   |            |                      |                       |
    |  +----+----+            |                      v                       |
    |       |                 |              +-------+--------+              |
    |       |                 |              |                |              |
    |       |                 +------------->|      CDB       |              |
    |       |                                | (XLEN/FLEN     |              |
    |       |                                |  for FP double)|              |
    |       |                                |                |              |
    |       |                                | - ROB Tag      |              |
    |       |                                | - Value (FLEN) |              |
    |       |                                | - Exception    |              |
    |       |                                +---+----+---+---+              |
    |       |                                    |    |   |                  |
    |       |         +--------------------------+    |   +------------+     |
    |       |         |                               |                |     |
    |       |         v                               v                v     |
    |       |   +-----+-----+              +--------+----+   +--------+---+  |
    |       |   |    ROB    |              |     RS      |   | INT/FP RAT |  |
    |       |   | (mark done|              | (wake up    |   | (update    |  |
    |       |   |  + value) |              |  dependents)|   |  mapping)  |  |
    |       |   +-----------+              +-------------+   +------------+  |
    |       |                                                                |
    |       v                                                                |
    |  +----+----+                                                           |
    |  | COMMIT  |  (Head of ROB, in program order)                          |
    |  |         |                                                           |
    |  | - Write to INT Regfile (x1-x31) or FP Regfile (f0-f31)              |
    |  | - Retire store to memory (integer or FP)                            |
    |  | - Handle exceptions (flush if needed)                               |
    |  | - Restore RAS on branch misprediction (if call/return affected)     |
    |  +---------+                                                           |
    |                                                                        |
    +------------------------------------------------------------------------+
```

### Integration with Existing FROST Pipeline

```
                    FROST Pipeline Integration Points
    +------------------------------------------------------------------------+
    |                                                                        |
    |  EXISTING FROST                          TOMASULO ADDITIONS            |
    |  (Preserved)                             (New Modules)                 |
    |                                                                        |
    |  +----------+                                                          |
    |  |    IF    |  - PC management           (unchanged)                   |
    |  |          |  - Branch prediction       (unchanged)                   |
    |  |          |  - RAS (call/return)       (unchanged, restore on flush) |
    |  |          |  - C-ext alignment         (unchanged)                   |
    |  +----+-----+                                                          |
    |       |                                                                |
    |       v                                                                |
    |  +----+-----+                                                          |
    |  |    PD    |  - RVC decompression       (unchanged)                   |
    |  |          |  - Source reg extract      (unchanged)                   |
    |  +----+-----+                                                          |
    |       |                                                                |
    |       v                                                                |
    |  +----+-----+                            +---------------------------+ |
    |  |    ID    |  - Instruction decode      |        DISPATCH           | |
    |  |          |  - Immediate extract  ---->|  - ROB allocation         | |
    |  |          |  - Control signals         |  - INT/FP RAT lookup      | |
    |  |          |  - FP decode (F/D ext)     |  - RS allocation          | |
    |  +----+-----+                            +-------------+-------------+ |
    |       |                                                |               |
    |       | (REMOVED: direct to EX)                        v               |
    |       |                                  +-------------+-------------+ |
    |       x                                  |           ROB             | |
    |                                          |  - Unified INT/FP         | |
    |  +----------+                            |  - Circular buffer        | |
    |  |    EX    |  - ALU (reused)            |  - In-order retirement    | |
    |  |          |  - Multiplier (reused)     +---------------------------+ |
    |  |          |  - Divider (reused)                      |               |
    |  |          |  - Branch unit (reused)    +-------------+-------------+ |
    |  |          |  - FPU (reused) <--------- |     INT RAT + FP RAT      | |
    |  +----+-----+                            |  - Separate tables for    | |
    |       |                                  |    x-regs and f-regs      | |
    |       | (REMOVED: fixed pipeline)        |  - Checkpoint/restore     | |
    |       x                                  +---------------------------+ |
    |                                                        |               |
    |  +----------+                            +-------------+-------------+ |
    |  |    MA    |  - Load unit (reused)      |    RESERVATION STATIONS   | |
    |  |          |  - AMO unit (reused)       |  - INT_RS, MUL_RS, MEM_RS | |
    |  |          |  - FP load/store           |  - FP_RS, FMUL_RS, FDIV_RS| |
    |  +----+-----+                            |  - CDB snoop              | |
    |       |                                  +---------------------------+ |
    |       | (REMOVED: fixed pipeline)                      |               |
    |       x                                  +-------------+-------------+ |
    |                                          |           CDB             | |
    |  +----------+                            |  - FLEN-wide for FP D     | |
    |  |    WB    |  - INT Regfile write       |  - Arbiter (INT + FP FUs) | |
    |  |          |  - FP Regfile write        +---------------------------+ |
    |  |          |    (now from ROB commit)                 |               |
    |  +----------+                            +-------------+-------------+ |
    |       ^                                  |      LOAD/STORE QUEUES    | |
    |       |                                  |  - INT and FP loads/stores| |
    |       +----------------------------------+  - Address disambiguation | |
    |         (Commit writes)                  |  - Store-to-load forward  | |
    |                                          +---------------------------+ |
    |                                                                        |
    +------------------------------------------------------------------------+
```

---

## Memory Disambiguation

Conservative approach: loads wait for all older store addresses to be known.
This applies to both integer and floating-point memory operations.

```
                        Memory Disambiguation
    +------------------------------------------------------------------------+
    |                                                                        |
    |  STORE QUEUE                           LOAD QUEUE                      |
    |  (In program order)                    (In program order)              |
    |  (INT: SW/SH/SB, FP: FSW/FSD)          (INT: LW/LH/LB, FP: FLW/FLD)    |
    |                                                                        |
    |  +------------------+                  +------------------+            |
    |  | Entry 0 (oldest) |                  | Entry 0 (oldest) |            |
    |  | - ROB Tag        |                  | - ROB Tag        |            |
    |  | - Address (known)|                  | - Address        |            |
    |  | - Data (32/64b)  |                  | - Size (W/D)     |            |
    |  | - Size (W/D)     |                  | - Waiting for:   |            |
    |  | - Committed?     |                  |   older stores   |            |
    |  +------------------+                  +------------------+            |
    |  | Entry 1          |                  | Entry 1          |            |
    |  | - ROB Tag        |    FORWARDING    | - ROB Tag        |            |
    |  | - Address (known)|<------+--------->| - Address        |            |
    |  | - Data (32/64b)  |       |          | - Data (if fwd)  |            |
    |  +------------------+       |          +------------------+            |
    |  | Entry 2          |       |          | Entry 2          |            |
    |  | - ROB Tag        |       |          | - ROB Tag        |            |
    |  | - Address: ???   |       |          | - BLOCKED        |            |
    |  | (not yet known)  |       |          | (older store     |            |
    |  +------------------+       |          |  addr unknown)   |            |
    |          |                  |          +------------------+            |
    |          |                  |                                          |
    |          v                  |          DISAMBIGUATION LOGIC:           |
    |  +------------------+       |          - Load can issue when ALL       |
    |  |  Store Commit    |       |            older store addresses known   |
    |  |  (ROB head)      |       |          - Check for address match       |
    |  |                  |-------+          - Forward data if match (size   |
    |  |  Write to memory |                    must be compatible)           |
    |  +------------------+                  - Go to memory if no match      |
    |                                                                        |
    +------------------------------------------------------------------------+
```

---

## Speculation Recovery

### Branch Misprediction Recovery (with RAS)

On misprediction, the RAT checkpoints restore correct register mappings and
the RAS is restored if the mispredicted branch affected call/return state:

```
                     Branch Misprediction Recovery
    +------------------------------------------------------------------------+
    |                                                                        |
    |  NORMAL EXECUTION:                                                     |
    |                                                                        |
    |  +--------+    +--------+    +--------+    +--------+                  |
    |  | Instr  |    | Branch |    | Instr  |    | Instr  |                  |
    |  |   A    |    |   B    |    |   C    |    |   D    |  (speculative)   |
    |  +--------+    +---+----+    +--------+    +--------+                  |
    |                    |                                                   |
    |                    | Checkpoint state here:                            |
    |                    | - INT RAT snapshot                                |
    |                    | - FP RAT snapshot                                 |
    |                    | - RAS top pointer (if call/return)                |
    |                    v                                                   |
    |              +-----+------+                                            |
    |              | Checkpoint |                                            |
    |              | (Branch B) |                                            |
    |              | - INT RAT  |                                            |
    |              | - FP RAT   |                                            |
    |              | - RAS ptr  |                                            |
    |              +------------+                                            |
    |                                                                        |
    |  MISPREDICTION DETECTED (Branch B resolves wrong):                     |
    |                                                                        |
    |  1. Restore INT RAT and FP RAT from checkpoint                         |
    |                                                                        |
    |     +------------+          +------------+                             |
    |     | INT RAT    |  RESTORE | Checkpoint |                             |
    |     | (current)  |<---------| INT RAT    |                             |
    |     | x1 -> ROB5 |          | x1 -> ROB2 |                             |
    |     +------------+          +------------+                             |
    |                                                                        |
    |     +------------+          +------------+                             |
    |     | FP RAT     |  RESTORE | Checkpoint |                             |
    |     | (current)  |<---------| FP RAT     |                             |
    |     | f1 -> ROB6 |          | f1 -> ROB4 |                             |
    |     +------------+          +------------+                             |
    |                                                                        |
    |  2. Restore RAS if branch was call/return                              |
    |                                                                        |
    |     +------------+          +------------+                             |
    |     | RAS (cur)  |  RESTORE | Checkpoint |                             |
    |     | top: 3     |<---------| RAS ptr: 2 |                             |
    |     +------------+          +------------+                             |
    |                                                                        |
    |  3. Flush ROB entries after branch (C, D, ...)                         |
    |                                                                        |
    |     +-------+-------+-------+-------+-------+-------+                  |
    |     |   A   |   B   |   C   |   D   |  ...  |       |                  |
    |     | done  | done  | FLUSH | FLUSH | FLUSH |       |                  |
    |     +-------+-------+-------+-------+-------+-------+                  |
    |               ^                                                        |
    |               | New tail pointer                                       |
    |                                                                        |
    |  4. Flush reservation stations (entries for C, D, ...)                 |
    |                                                                        |
    |  5. Redirect front-end to correct path                                 |
    |                                                                        |
    +------------------------------------------------------------------------+
```

### Exception Handling

The ROB ensures in-order commit and precise exceptions for both INT and FP:

```
                        ROB Commit Logic
    +------------------------------------------------------------------------+
    |                                                                        |
    |  ROB (Circular Buffer) - Unified for Integer and Floating-Point        |
    |                                                                        |
    |   HEAD                                              TAIL               |
    |    |                                                  |                |
    |    v                                                  v                |
    |  +------+------+------+------+------+------+------+------+             |
    |  |Entry0|Entry1|Entry2|Entry3|Entry4|Entry5|Entry6|      |             |
    |  | INT  | FP   | INT  | FP   | INT  | FP   |      |      |             |
    |  | DONE | DONE | DONE | busy | busy | busy |      |      |             |
    |  | exc=0| exc=0| exc=1| wait | wait | wait |      |      |             |
    |  +------+------+------+------+------+------+------+------+             |
    |                   ^                                                    |
    |                   |                                                    |
    |                   Exception detected! (e.g., FP invalid operation)     |
    |                                                                        |
    |  COMMIT LOGIC:                                                         |
    |                                                                        |
    |  if (head.done && !head.exception):                                    |
    |      - If INT dest: write result to x-regfile (x1-x31)                 |
    |      - If FP dest: write result to f-regfile (f0-f31)                  |
    |      - If store: commit store to memory (SW/FSW/SD/FSD)                |
    |      - Advance head pointer                                            |
    |      - Free ROB entry                                                  |
    |                                                                        |
    |  if (head.done && head.exception):                                     |
    |      - Record exception cause in mcause (including FP exceptions)      |
    |      - Record PC in mepc                                               |
    |      - Flush entire ROB (all entries after head)                       |
    |      - Restore INT RAT and FP RAT to checkpoint                        |
    |      - Restore RAS state                                               |
    |      - Redirect to trap handler (mtvec)                                |
    |                                                                        |
    |  PRECISE EXCEPTIONS:                                                   |
    |  - Instructions before exception: committed (architectural state)      |
    |  - Exception instruction: not committed, PC saved                      |
    |  - Instructions after exception: flushed (never visible)               |
    |                                                                        |
    |  FP EXCEPTION FLAGS (fcsr):                                            |
    |  - Updated at commit time for FP operations                            |
    |  - NV (invalid), DZ (div-by-zero), OF (overflow),                      |
    |    UF (underflow), NX (inexact)                                        |
    |                                                                        |
    +------------------------------------------------------------------------+
```

---

## Serializing and Special Instructions

Certain instruction classes require special handling in an out-of-order pipeline
because they have ordering requirements, side effects, or atomicity constraints.

### Atomic Operations (A Extension)

RISC-V atomic operations include Load-Reserved/Store-Conditional (LR/SC) and
Atomic Memory Operations (AMOs). These require special treatment:

```
                        Atomic Instruction Handling
    +------------------------------------------------------------------------+
    |                                                                        |
    |  LR/SC (Load-Reserved / Store-Conditional):                            |
    |                                                                        |
    |  +------------------+    +------------------+    +------------------+  |
    |  |       LR.W       |    |   (other instrs) |    |       SC.W       |  |
    |  | Load-Reserved    |    |   can execute    |    | Store-Conditional|  |
    |  | - Loads value    |    |   between LR/SC  |    | - Checks reserv. |  |
    |  | - Sets reserv.   |    |                  |    | - Clears reserv. |  |
    |  +--------+---------+    +------------------+    +--------+---------+  |
    |           |                                               |            |
    |           v                                               v            |
    |  +--------+-------------------------------------------------+          |
    |  |                   RESERVATION SET                        |          |
    |  |                                                          |          |
    |  |  - Track reservation address from LR                     |          |
    |  |  - SC succeeds only if reservation still valid           |          |
    |  |  - Reservation cleared by:                               |          |
    |  |      * SC (success or fail)                              |          |
    |  |      * Any store to reserved address (from other hart)   |          |
    |  |      * Context switch / trap                             |          |
    |  +----------------------------------------------------------+          |
    |                                                                        |
    |  TOMASULO HANDLING:                                                    |
    |                                                                        |
    |  - LR: Executes like a load, but also sets reservation                 |
    |  - SC: Must wait until at ROB head (non-speculative)                   |
    |        * Check reservation -> succeed (store + return 0)               |
    |                            -> fail (no store + return 1)               |
    |                                                                        |
    +------------------------------------------------------------------------+
    |                                                                        |
    |  AMO (Atomic Memory Operations):                                       |
    |                                                                        |
    |  AMOSWAP, AMOADD, AMOAND, AMOOR, AMOXOR, AMOMIN, AMOMAX, etc.          |
    |                                                                        |
    |  +------------------------------------------------------------------+  |
    |  |  AMO Operation Sequence (atomic read-modify-write):              |  |
    |  |                                                                  |  |
    |  |  1. Read memory[addr] -> old_value                               |  |
    |  |  2. Compute: new_value = old_value OP operand                    |  |
    |  |  3. Write memory[addr] <- new_value                              |  |
    |  |  4. Return old_value to destination register                     |  |
    |  |                                                                  |  |
    |  |  ALL STEPS MUST BE ATOMIC (no intervening memory ops)            |  |
    |  +------------------------------------------------------------------+  |
    |                                                                        |
    |  TOMASULO HANDLING:                                                    |
    |                                                                        |
    |  - AMO dispatches to MEM_RS like other memory ops                      |
    |  - AMO executes ONLY when at ROB head (non-speculative)                |
    |  - Store queue must be empty (no older stores pending)                 |
    |  - Load queue must have no older loads to same address                 |
    |  - Effectively serializes memory access during AMO                     |
    |                                                                        |
    |  +---------------------------+                                         |
    |  |  AMO EXECUTION CONDITION  |                                         |
    |  |                           |                                         |
    |  |  can_execute_amo =        |                                         |
    |  |    amo_at_rob_head &&     |                                         |
    |  |    store_queue_empty &&   |                                         |
    |  |    no_older_loads_to_addr |                                         |
    |  +---------------------------+                                         |
    |                                                                        |
    |  MEMORY ORDERING (.aq / .rl):                                          |
    |                                                                        |
    |  - .aq (acquire): No later memory ops can execute before this          |
    |  - .rl (release): No earlier memory ops can execute after this         |
    |  - .aqrl: Full fence semantics                                         |
    |                                                                        |
    |  Implementation: AMOs with .aq/.rl wait for ROB head, ensuring         |
    |  all prior ops committed and no later ops have executed yet.           |
    |                                                                        |
    +------------------------------------------------------------------------+
```

### CSR Instructions (Zicsr)

CSR (Control and Status Register) instructions read and write system state.
They must execute non-speculatively because CSRs have global side effects.

```
                        CSR Instruction Handling
    +------------------------------------------------------------------------+
    |                                                                        |
    |  CSR INSTRUCTIONS:                                                     |
    |                                                                        |
    |  CSRRW  rd, csr, rs1    # rd = csr; csr = rs1                          |
    |  CSRRS  rd, csr, rs1    # rd = csr; csr = csr | rs1                    |
    |  CSRRC  rd, csr, rs1    # rd = csr; csr = csr & ~rs1                   |
    |  CSRRWI rd, csr, imm    # rd = csr; csr = imm                          |
    |  CSRRSI rd, csr, imm    # rd = csr; csr = csr | imm                    |
    |  CSRRCI rd, csr, imm    # rd = csr; csr = csr & ~imm                   |
    |                                                                        |
    |  WHY SPECIAL HANDLING:                                                 |
    |                                                                        |
    |  - CSRs are shared architectural state (not renamed)                   |
    |  - Some CSRs have side effects on read (e.g., clear-on-read)           |
    |  - Some CSRs affect processor behavior immediately                     |
    |  - CSR writes must not be speculative (can't undo)                     |
    |                                                                        |
    +------------------------------------------------------------------------+
    |                                                                        |
    |  TOMASULO HANDLING (Option A - Execute at Commit):                     |
    |                                                                        |
    |  +------------------------------------------------------------------+  |
    |  |                                                                  |  |
    |  |  1. CSR instruction dispatches, allocates ROB entry              |  |
    |  |  2. CSR waits in ROB (does not execute early)                    |  |
    |  |  3. When CSR reaches ROB head:                                   |  |
    |  |       - Read CSR -> old_value                                    |  |
    |  |       - Compute new CSR value                                    |  |
    |  |       - Write CSR <- new_value                                   |  |
    |  |       - old_value written to rd via normal commit                |  |
    |  |  4. Commit completes, advance ROB head                           |  |
    |  |                                                                  |  |
    |  +------------------------------------------------------------------+  |
    |                                                                        |
    |  TOMASULO HANDLING (Option B - Serialize):                             |
    |                                                                        |
    |  +------------------------------------------------------------------+  |
    |  |                                                                  |  |
    |  |  1. CSR instruction detected at dispatch                         |  |
    |  |  2. Stall dispatch until ROB is empty                            |  |
    |  |  3. Execute CSR instruction (no other instrs in flight)          |  |
    |  |  4. Resume dispatch after CSR commits                            |  |
    |  |                                                                  |  |
    |  |  Simpler but lower performance (pipeline drain)                  |  |
    |  |                                                                  |  |
    |  +------------------------------------------------------------------+  |
    |                                                                        |
    |  RECOMMENDED: Option A for most CSRs, Option B for CSRs that           |
    |  affect pipeline behavior (e.g., mstatus, satp)                        |
    |                                                                        |
    +------------------------------------------------------------------------+
```

### Fence Instructions (Zifencei)

Fence instructions enforce memory ordering. FENCE orders memory accesses;
FENCE.I synchronizes instruction and data memory.

```
                        Fence Instruction Handling
    +------------------------------------------------------------------------+
    |                                                                        |
    |  FENCE (Memory Fence):                                                 |
    |                                                                        |
    |  FENCE predecessor, successor                                          |
    |  - predecessor/successor: combination of I, O, R, W                    |
    |  - Ensures predecessor ops complete before successor ops start         |
    |                                                                        |
    |  Example: FENCE rw, rw  (full fence)                                   |
    |  - All prior reads/writes complete before any later reads/writes       |
    |                                                                        |
    |  +------------------------------------------------------------------+  |
    |  |  TOMASULO HANDLING:                                              |  |
    |  |                                                                  |  |
    |  |  FENCE dispatches to ROB like other instructions                 |  |
    |  |                                                                  |  |
    |  |  When FENCE reaches ROB head:                                    |  |
    |  |    - Wait for store queue to drain (all stores committed)        |  |
    |  |    - For FENCE with R in successor: no loads issued after FENCE  |  |
    |  |      until FENCE commits                                         |  |
    |  |    - After store queue empty, FENCE commits                      |  |
    |  |                                                                  |  |
    |  |  Conservative approach: FENCE drains store queue before commit   |  |
    |  +------------------------------------------------------------------+  |
    |                                                                        |
    +------------------------------------------------------------------------+
    |                                                                        |
    |  FENCE.I (Instruction Fence):                                          |
    |                                                                        |
    |  Ensures instruction fetches see all prior stores to instruction       |
    |  memory. Required after modifying code (e.g., JIT, dynamic loading).   |
    |                                                                        |
    |  +------------------------------------------------------------------+  |
    |  |  TOMASULO HANDLING:                                              |  |
    |  |                                                                  |  |
    |  |  FENCE.I is a full pipeline serialization point:                 |  |
    |  |                                                                  |  |
    |  |  1. FENCE.I dispatches, allocates ROB entry                      |  |
    |  |  2. When FENCE.I reaches ROB head:                               |  |
    |  |       a. Drain store queue (all stores to memory)                |  |
    |  |       b. FENCE.I commits                                         |  |
    |  |  3. After commit:                                                |  |
    |  |       a. Flush pipeline (discard all fetched instructions)       |  |
    |  |       b. Invalidate instruction cache (or fence it)              |  |
    |  |       c. Redirect fetch to next PC                               |  |
    |  |                                                                  |  |
    |  |  This ensures subsequent fetches see any stores that preceded    |  |
    |  |  the FENCE.I instruction.                                        |  |
    |  |                                                                  |  |
    |  +------------------------------------------------------------------+  |
    |                                                                        |
    +------------------------------------------------------------------------+
```

### Summary: Special Instruction Handling

| Instruction Class | Dispatch | Execute | Commit | Notes |
|-------------------|----------|---------|--------|-------|
| **LR.W/D** | Normal | Like load | Normal | Sets reservation |
| **SC.W/D** | Normal | At ROB head only | Normal | Checks/clears reservation |
| **AMO** | Normal | At ROB head, SQ empty | Normal | Atomic read-modify-write |
| **CSR** | Normal | At ROB head | Normal | Non-speculative R/M/W |
| **FENCE** | Normal | N/A | Drains SQ | Orders memory ops |
| **FENCE.I** | Normal | N/A | Drains SQ, flushes | I-cache sync |

---

## Module Summary

| Module | Purpose | Key Interfaces |
|--------|---------|----------------|
| **ROB** | In-order commit, precise exceptions (unified INT/FP) | Dispatch alloc, CDB write, Commit out |
| **INT_RAT** | Integer register renaming (x0-x31), speculation recovery | ID read, Dispatch write, Checkpoint |
| **FP_RAT** | FP register renaming (f0-f31), speculation recovery | ID read, Dispatch write, Checkpoint |
| **INT_RS** | Integer ALU reservation station | Dispatch in, CDB snoop, Issue to ALU |
| **MUL_RS** | Integer multiply/divide reservation station | Dispatch in, CDB snoop, Issue to MUL |
| **MEM_RS** | Memory ops reservation station (INT + FP loads/stores) | Dispatch in, CDB snoop, Issue to LQ/SQ |
| **FP_RS** | FP add/sub/compare/convert reservation station | Dispatch in, CDB snoop, Issue to FPU |
| **FMUL_RS** | FP multiply reservation station | Dispatch in, CDB snoop, Issue to FPU |
| **FDIV_RS** | FP divide/sqrt reservation station (long latency) | Dispatch in, CDB snoop, Issue to FPU |
| **LQ** | Load queue, address disambiguation (INT + FP) | MEM_RS issue, Store forward, Memory |
| **SQ** | Store queue, commit buffer (INT + FP) | MEM_RS issue, Load forward, Commit |
| **CDB** | Result broadcast, arbiter (XLEN/FLEN width); lane-parameterized (NUM_CDB_LANES=1 initially) | FU results in, RS/ROB/RAT broadcast |

---

## Module-Level Architecture Diagrams

### Reorder Buffer (ROB)

```
                              ROB Internal Structure
    +------------------------------------------------------------------------+
    |                                                                        |
    |  PARAMETERS:                                                           |
    |    ROB_DEPTH = 32 (configurable, power of 2)                           |
    |    ROB_TAG_WIDTH = $clog2(ROB_DEPTH) = 5 bits                          |
    |                                                                        |
    |  +------------------------------------------------------------------+  |
    |  |                     CIRCULAR BUFFER                              |  |
    |  |                                                                  |  |
    |  |  HEAD (commit ptr)              TAIL (alloc ptr)                 |  |
    |  |    |                                |                            |  |
    |  |    v                                v                            |  |
    |  |  +-----+-----+-----+-----+-----+-----+-----+-----+               |  |
    |  |  |  0  |  1  |  2  |  3  |  4  |  5  |  6  | ... |  [ROB_DEPTH]  |  |
    |  |  +-----+-----+-----+-----+-----+-----+-----+-----+               |  |
    |  |                                                                  |  |
    |  +------------------------------------------------------------------+  |
    |                                                                        |
    |  ENTRY STRUCTURE (per entry):                                          |
    |  +------------------------------------------------------------------+  |
    |  |  Field          | Width        | Description                     |  |
    |  +-----------------+--------------+---------------------------------+  |
    |  |  valid          | 1 bit        | Entry is allocated              |  |
    |  |  done           | 1 bit        | Execution complete              |  |
    |  |  exception      | 1 bit        | Exception occurred              |  |
    |  |  exc_cause      | 5 bits       | Exception cause code (inc FP)   |  |
    |  |  pc             | 32 bits      | Instruction PC (for mepc)       |  |
    |  |  dest_rf        | 1 bit        | 0=INT (x-reg), 1=FP (f-reg)     |  |
    |  |  dest_reg       | 5 bits       | Architectural dest (rd)         |  |
    |  |  dest_valid     | 1 bit        | Has destination register        |  |
    |  |  value          | FLEN (64b)   | Result value (XLEN INT, FLEN FP)|  |
    |  |  is_store       | 1 bit        | Is store instruction            |  |
    |  |  is_fp_store    | 1 bit        | Is FP store (FSW/FSD)           |  |
    |  |  is_branch      | 1 bit        | Is branch/jump instruction      |  |
    |  |  branch_taken   | 1 bit        | Branch outcome (for recovery)   |  |
    |  |  branch_target  | 32 bits      | Branch target (for recovery)    |  |
    |  |  predicted_taken| 1 bit        | BTB prediction (for comparison) |  |
    |  |  is_call        | 1 bit        | Is call (for RAS recovery)      |  |
    |  |  is_return      | 1 bit        | Is return (for RAS recovery)    |  |
    |  |  fp_flags       | 5 bits       | FP exception flags (NV/DZ/OF/UF/NX)|
    |  +-----------------+--------------+---------------------------------+  |
    |  |  TOTAL          | ~120 bits/entry                                |  |
    |  +------------------------------------------------------------------+  |
    |                                                                        |
    |  CONTROL LOGIC:                                                        |
    |                                                                        |
    |  +---------------------------+    +----------------------------+       |
    |  |     ALLOCATION            |    |       COMMIT               |       |
    |  |                           |    |                            |       |
    |  |  if (!full && dispatch):  |    |  if (head.valid &&         |       |
    |  |    entry[tail] <- instr   |    |      head.done):           |       |
    |  |    tail <- tail + 1       |    |                            |       |
    |  |    return tail as tag     |    |    if (head.exception):    |       |
    |  |                           |    |      trigger_trap()        |       |
    |  +---------------------------+    |      flush_all()           |       |
    |                                   |    else:                   |       |
    |  +---------------------------+    |      if (dest_rf == INT):  |       |
    |  |     CDB WRITE             |    |        x_regfile[rd] <- v  |       |
    |  |                           |    |      else:                 |       |
    |  |  for each CDB broadcast:  |    |        f_regfile[rd] <- v  |       |
    |  |    if (tag matches entry):|    |      fcsr.flags |= fp_flags|       |
    |  |      entry.done <- 1      |    |      head <- head + 1      |       |
    |  |      entry.value <- data  |    |                            |       |
    |  |      entry.exc <- exc     |    +----------------------------+       |
    |  |      entry.fp_flags <- fl |                                         |
    |  +---------------------------+    +---------------------------+        |
    |                                   |       FLUSH               |        |
    |  +---------------------------+    |                           |        |
    |  |     STATUS SIGNALS        |    |  On branch mispredict:    |        |
    |  |                           |    |    tail <- branch_entry+1 |        |
    |  |  full = (tail+1 == head)  |    |    invalidate entries     |        |
    |  |  empty = (tail == head)   |    |      after branch         |        |
    |  |  count = tail - head      |    |                           |        |
    |  +---------------------------+    |  On exception:            |        |
    |                                   |    tail <- head           |        |
    |                                   |    invalidate all         |        |
    |                                   +---------------------------+        |
    |                                                                        |
    |  INTERFACES:                                                           |
    |                                                                        |
    |  FROM DISPATCH:          TO DISPATCH:           TO COMMIT:             |
    |  - alloc_en              - alloc_tag (ROB ID)   - commit_valid         |
    |  - pc                    - full (stall)         - commit_dest_rf       |
    |  - dest_rf (INT/FP)                             - commit_dest_reg      |
    |  - dest_reg              FROM CDB:              - commit_value (FLEN)  |
    |  - is_store              - cdb_valid            - commit_is_store      |
    |  - is_fp_store           - cdb_tag              - commit_exception     |
    |  - is_branch             - cdb_value (FLEN)     - commit_fp_flags      |
    |  - is_call/is_return     - cdb_exception                               |
    |  - predicted_taken       - cdb_fp_flags         TO FRONT-END:          |
    |                                                 - flush                |
    |                                                 - redirect_pc          |
    |                                                 - restore_ras          |
    +------------------------------------------------------------------------+
```

### Register Alias Tables (INT RAT + FP RAT)

```
                         INT RAT + FP RAT Internal Structure
    +------------------------------------------------------------------------+
    |                                                                        |
    |  PARAMETERS:                                                           |
    |    NUM_INT_REGS = 32 (x0-x31)                                          |
    |    NUM_FP_REGS = 32 (f0-f31)                                           |
    |    ROB_TAG_WIDTH = 5 bits                                              |
    |    NUM_CHECKPOINTS = 4 (for in-flight branches)                        |
    |                                                                        |
    |  +------------------------------------------------------------------+  |
    |  |                    INT RAT (x-registers)                         |  |
    |  |                                                                  |  |
    |  |  Arch Reg    Valid    ROB Tag     Description                    |  |
    |  |  +-------+  +-----+  +---------+                                 |  |
    |  |  |  x0   |  |  0  |  |   ---   |  (x0 always reads 0, no rename) |  |
    |  |  +-------+  +-----+  +---------+                                 |  |
    |  |  |  x1   |  |  1  |  |  ROB_3  |  (x1 renamed to ROB entry 3)    |  |
    |  |  +-------+  +-----+  +---------+                                 |  |
    |  |  |  ...  |  | ... |  |   ...   |                                 |  |
    |  |  +-------+  +-----+  +---------+                                 |  |
    |  |  |  x31  |  |  1  |  |  ROB_12 |                                 |  |
    |  |  +-------+  +-----+  +---------+                                 |  |
    |  |                                                                  |  |
    |  |  Entry: valid (1 bit) + tag (ROB_TAG_WIDTH bits) = 6 bits/reg    |  |
    |  |  Total: 32 regs x 6 bits = 192 bits                              |  |
    |  +------------------------------------------------------------------+  |
    |                                                                        |
    |  +------------------------------------------------------------------+  |
    |  |                    FP RAT (f-registers)                          |  |
    |  |                                                                  |  |
    |  |  Arch Reg    Valid    ROB Tag     Description                    |  |
    |  |  +-------+  +-----+  +---------+                                 |  |
    |  |  |  f0   |  |  1  |  |  ROB_8  |  (f0 renamed to ROB entry 8)    |  |
    |  |  +-------+  +-----+  +---------+                                 |  |
    |  |  |  f1   |  |  0  |  |   ---   |  (f1 in arch regfile)           |  |
    |  |  +-------+  +-----+  +---------+                                 |  |
    |  |  |  ...  |  | ... |  |   ...   |                                 |  |
    |  |  +-------+  +-----+  +---------+                                 |  |
    |  |  |  f31  |  |  1  |  |  ROB_20 |                                 |  |
    |  |  +-------+  +-----+  +---------+                                 |  |
    |  |                                                                  |  |
    |  |  Entry: valid (1 bit) + tag (ROB_TAG_WIDTH bits) = 6 bits/reg    |  |
    |  |  Total: 32 regs x 6 bits = 192 bits                              |  |
    |  +------------------------------------------------------------------+  |
    |                                                                        |
    |  +------------------------------------------------------------------+  |
    |  |                  CHECKPOINT STORAGE                              |  |
    |  |                                                                  |  |
    |  |  For each in-flight branch, store full state:                    |  |
    |  |                                                                  |  |
    |  |  Checkpoint 0:                                                   |  |
    |  |    - INT RAT [x0..x31 mappings]                                  |  |
    |  |    - FP RAT [f0..f31 mappings]                                   |  |
    |  |    - ROB_tag of branch                                           |  |
    |  |    - RAS top pointer                                             |  |
    |  |                                                                  |  |
    |  |  Checkpoint 1, 2, 3: (same structure)                            |  |
    |  |                                                                  |  |
    |  |  Storage per checkpoint:                                         |  |
    |  |    INT RAT: 192 bits + FP RAT: 192 bits + ROB tag: 5 bits        |  |
    |  |    + RAS ptr: 4 bits = 393 bits                                  |  |
    |  |  Total: 4 x 393 = 1572 bits                                      |  |
    |  +------------------------------------------------------------------+  |
    |                                                                        |
    |  OPERATIONS:                                                           |
    |                                                                        |
    |  +---------------------------+    +---------------------------+        |
    |  |     READ (Dispatch)       |    |     WRITE (Dispatch)      |        |
    |  |                           |    |                           |        |
    |  |  For INT source (rs1/rs2):|    |  For INT destination:     |        |
    |  |  if (rs == x0):           |    |  if (rd != x0):           |        |
    |  |    return {0, value=0}    |    |    int_rat[rd].valid <- 1 |        |
    |  |  elif (int_rat[rs].valid):|    |    int_rat[rd].tag <- tag |        |
    |  |    return {1, rob_tag}    |    |                           |        |
    |  |  else:                    |    |  For FP destination:      |        |
    |  |    return {0, x_reg[rs]}  |    |    fp_rat[rd].valid <- 1  |        |
    |  |                           |    |    fp_rat[rd].tag <- tag  |        |
    |  |  For FP source (fs1/fs2): |    |                           |        |
    |  |  if (fp_rat[fs].valid):   |    +---------------------------+        |
    |  |    return {1, rob_tag}    |                                         |
    |  |  else:                    |    +---------------------------+        |
    |  |    return {0, f_reg[fs]}  |    |     COMMIT (from ROB)     |        |
    |  +---------------------------+    |                           |        |
    |                                   |  For INT commit:          |        |
    |  +---------------------------+    |  if (int_rat[rd].tag ==   |        |
    |  |     CHECKPOINT (Branch)   |    |      committing_tag):     |        |
    |  |                           |    |    int_rat[rd].valid <- 0 |        |
    |  |  On branch dispatch:      |    |                           |        |
    |  |    checkpoint[idx].int <- |    |  For FP commit:           |        |
    |  |      current INT RAT      |    |  if (fp_rat[rd].tag ==    |        |
    |  |    checkpoint[idx].fp <-  |    |      committing_tag):     |        |
    |  |      current FP RAT       |    |    fp_rat[rd].valid <- 0  |        |
    |  |    checkpoint[idx].ras <- |    |                           |        |
    |  |      RAS top pointer      |    +---------------------------+        |
    |  |    checkpoint[idx].tag <- |                                         |
    |  |      branch ROB tag       |    +---------------------------+        |
    |  +---------------------------+    |     RESTORE (Mispredict)  |        |
    |                                   |                           |        |
    |  +---------------------------+    |  On branch mispredict:    |        |
    |  |     FREE CHECKPOINT       |    |    INT RAT <- ckpt.int    |        |
    |  |                           |    |    FP RAT <- ckpt.fp      |        |
    |  |  On branch commit         |    |    RAS top <- ckpt.ras    |        |
    |  |  (correct prediction):    |    |                           |        |
    |  |    free checkpoint[idx]   |    +---------------------------+        |
    |  +---------------------------+                                         |
    |                                                                        |
    +------------------------------------------------------------------------+
```

### Reservation Station (Generic - used for INT_RS, MUL_RS, FP_RS, etc.)

```
                         Reservation Station Internal Structure
    +-------------------------------------------------------------------------+
    |                                                                         |
    |  PARAMETERS:                                                            |
    |    RS_DEPTH = 8 (entries per RS, configurable)                          |
    |    ROB_TAG_WIDTH = 5 bits                                               |
    |    VALUE_WIDTH = FLEN (64 bits, to support FP double)                   |
    |                                                                         |
    |  +-------------------------------------------------------------------+  |
    |  |                      RS ENTRY ARRAY                               |  |
    |  |                                                                   |  |
    |  |  +-------------------------------------------------------------+  |  |
    |  |  | Entry 0:                                                    |  |  |
    |  |  |   valid     : 1 bit    (entry in use)                       |  |  |
    |  |  |   rob_tag   : 5 bits   (destination ROB entry)              |  |  |
    |  |  |   op        : 6 bits   (operation code)                     |  |  |
    |  |  |   src1_ready: 1 bit    (operand 1 available)                |  |  |
    |  |  |   src1_tag  : 5 bits   (ROB tag if not ready)               |  |  |
    |  |  |   src1_value: FLEN     (value if ready, supports FP double) |  |  |
    |  |  |   src2_ready: 1 bit    (operand 2 available)                |  |  |
    |  |  |   src2_tag  : 5 bits   (ROB tag if not ready)               |  |  |
    |  |  |   src2_value: FLEN     (value if ready, supports FP double) |  |  |
    |  |  |   src3_ready: 1 bit    (for FMA: rs3/fs3)                   |  |  |
    |  |  |   src3_tag  : 5 bits   (ROB tag if not ready)               |  |  |
    |  |  |   src3_value: FLEN     (value if ready, for FMA)            |  |  |
    |  |  |   imm       : 32 bits  (immediate value, if used)           |  |  |
    |  |  |   use_imm   : 1 bit    (use imm instead of src2)            |  |  |
    |  |  |   rm        : 3 bits   (FP rounding mode)                   |  |  |
    |  |  +-------------------------------------------------------------+  |  |
    |  |  | Entry 1: ... (same structure)                               |  |  |
    |  |  +-------------------------------------------------------------+  |  |
    |  |  | ...                                                         |  |  |
    |  |  +-------------------------------------------------------------+  |  |
    |  |  | Entry 7:                                                    |  |  |
    |  |  +-------------------------------------------------------------+  |  |
    |  |                                                                   |  |
    |  |  Entry size: ~230 bits (with 3 sources for FMA)                   |  |
    |  |  Total: RS_DEPTH x 230 bits = 8 x 230 = 1840 bits                 |  |
    |  +-------------------------------------------------------------------+  |
    |                                                                         |
    |  LOGIC BLOCKS:                                                          |
    |                                                                         |
    |  +---------------------------+    +---------------------------+         |
    |  |     DISPATCH (Allocate)   |    |     CDB SNOOP (Wakeup)    |         |
    |  |                           |    |                           |         |
    |  |  if (dispatch_valid &&    |    |  for each entry:          |         |
    |  |      !full):              |    |    for each CDB broadcast:|         |
    |  |                           |    |                           |         |
    |  |    // Find free entry     |    |      if (!src1_ready &&   |         |
    |  |    idx <- first_free()    |    |          src1_tag ==      |         |
    |  |                           |    |          cdb_tag):        |         |
    |  |    // Populate entry      |    |        src1_ready <- 1    |         |
    |  |    entry[idx].valid <- 1  |    |        src1_value <-      |         |
    |  |    entry[idx].rob_tag <-  |    |          cdb_value (FLEN) |         |
    |  |      dispatch.rob_tag     |    |                           |         |
    |  |    entry[idx].op <-       |    |      (same for src2, src3)|         |
    |  |      dispatch.op          |    |                           |         |
    |  |    entry[idx].src1_* <-   |    +---------------------------+         |
    |  |      from INT/FP RAT      |                                          |
    |  |    entry[idx].rm <-       |                                          |
    |  |      rounding_mode        |                                          |
    |  +---------------------------+                                          |
    |                                                                         |
    |  +------------------------------------------------------------------+   |
    |  |                         ISSUE LOGIC                              |   |
    |  |                                                                  |   |
    |  |  READY CHECK (per entry):                                        |   |
    |  |    entry_ready = valid &&                                        |   |
    |  |                  src1_ready &&                                   |   |
    |  |                  (src2_ready || use_imm) &&                      |   |
    |  |                  (src3_ready || !uses_src3)                      |   |
    |  |                                                                  |   |
    |  |  ISSUE SELECT (priority encoder):                                |   |
    |  |    // Select oldest ready entry (FIFO order)                     |   |
    |  |    // Or use age matrix for true oldest-first                    |   |
    |  |                                                                  |   |
    |  |    issue_idx <- select_ready_entry()                             |   |
    |  |                                                                  |   |
    |  |    if (issue_idx valid && FU available):                         |   |
    |  |      issue entry[issue_idx] to FU                                |   |
    |  |      entry[issue_idx].valid <- 0  // free entry                  |   |
    |  |                                                                  |   |
    |  +------------------------------------------------------------------+   |
    |                                                                         |
    |  +---------------------------+    +---------------------------+         |
    |  |     FLUSH (Mispredict)    |    |     STATUS SIGNALS        |         |
    |  |                           |    |                           |         |
    |  |  On branch mispredict:    |    |  full = all entries valid |         |
    |  |    for each entry:        |    |  empty = no entries valid |         |
    |  |      if (entry.rob_tag >  |    |  ready_count = # ready    |         |
    |  |          mispredict_tag): |    |                           |         |
    |  |        entry.valid <- 0   |    +---------------------------+         |
    |  +---------------------------+                                          |
    |                                                                         |
    |  INTERFACES:                                                            |
    |                                                                         |
    |  FROM DISPATCH:           FROM CDB:              TO FU:                 |
    |  - dispatch_valid         - cdb_valid            - issue_valid          |
    |  - rob_tag                - cdb_tag              - rob_tag              |
    |  - op                     - cdb_value (FLEN)      - op                  |
    |  - src1_ready/tag/value                          - src1_value (FLEN)    |
    |  - src2_ready/tag/value   FROM ROB:              - src2_value (FLEN)    |
    |  - src3_ready/tag/value   - flush_tag            - src3_value (FLEN)    |
    |  - imm, use_imm           - flush_en             - rm (rounding mode)   |
    |  - rm (FP rounding mode)                                                |
    |                                                  TO DISPATCH:           |
    |                                                  - full (stall)         |
    +-------------------------------------------------------------------------+
```

### Load Queue

```
                           Load Queue Internal Structure
    +------------------------------------------------------------------------+
    |                                                                        |
    |  PARAMETERS:                                                           |
    |    LQ_DEPTH = 8 (entries, configurable)                                |
    |    ROB_TAG_WIDTH = 5 bits                                              |
    |                                                                        |
    |  +------------------------------------------------------------------+  |
    |  |                    LOAD QUEUE ENTRIES                            |  |
    |  |                    (Allocated in program order)                  |  |
    |  |                    (Handles LW/LH/LB and FLW/FLD)                |  |
    |  |                                                                  |  |
    |  |  HEAD (oldest)                         TAIL (newest)             |  |
    |  |    |                                       |                     |  |
    |  |    v                                       v                     |  |
    |  |  +------+------+------+------+------+------+------+------+       |  |
    |  |  |  0   |  1   |  2   |  3   |  4   |  5   |  6   |  7   |       |  |
    |  |  +------+------+------+------+------+------+------+------+       |  |
    |  |                                                                  |  |
    |  +------------------------------------------------------------------+  |
    |                                                                        |
    |  ENTRY STRUCTURE:                                                      |
    |  +------------------------------------------------------------------+  |
    |  |  Field          | Width     | Description                        |  |
    |  +-----------------+-----------+------------------------------------+  |
    |  |  valid          | 1 bit     | Entry allocated                    |  |
    |  |  rob_tag        | 5 bits    | ROB entry for this load            |  |
    |  |  is_fp          | 1 bit     | FP load (FLW/FLD)                  |  |
    |  |  addr_valid     | 1 bit     | Address has been calculated        |  |
    |  |  address        | 32 bits   | Load address                       |  |
    |  |  size           | 2 bits    | 00=B, 01=H, 10=W, 11=D (for FLD)   |  |
    |  |  sign_ext       | 1 bit     | Sign extend result (INT only)      |  |
    |  |  issued         | 1 bit     | Sent to memory                     |  |
    |  |  data_valid     | 1 bit     | Data received from memory/forward  |  |
    |  |  data           | FLEN      | Loaded data (FLEN for FLD)         |  |
    |  |  forwarded      | 1 bit     | Data from store queue forward      |  |
    |  +-----------------+-----------+------------------------------------+  |
    |  |  TOTAL          | ~112 bits/entry                                |  |
    |  +------------------------------------------------------------------+  |
    |                                                                        |
    |  MEMORY DISAMBIGUATION:                                                |
    |                                                                        |
    |  +------------------------------------------------------------------+  |
    |  |                                                                  |  |
    |  |  CONSERVATIVE STRATEGY:                                          |  |
    |  |                                                                  |  |
    |  |  A load can issue to memory ONLY when:                           |  |
    |  |    1. Load address is known (addr_valid)                         |  |
    |  |    2. ALL older stores have known addresses                      |  |
    |  |       (check SQ entries from LQ.head to this entry's rob_tag)    |  |
    |  |                                                                  |  |
    |  |  +-------------------+        +-------------------+              |  |
    |  |  |    STORE QUEUE    |        |    LOAD QUEUE     |              |  |
    |  |  |                   |        |                   |              |  |
    |  |  |  SQ[0]: addr=100  |   ?    |  LQ[0]: FLW a=100 | <-- Check    |  |
    |  |  |  SQ[1]: FSW a=200 |------->|  LQ[1]: LW  a=??? | <-- Blocked  |  |
    |  |  |  SQ[2]: addr=???  |   X    |  LQ[2]: FLD a=300 | <-- Blocked  |  |
    |  |  +-------------------+        +-------------------+     (SQ[2]   |  |
    |  |                                                         unknown) |  |
    |  +------------------------------------------------------------------+  |
    |                                                                        |
    |  STORE-TO-LOAD FORWARDING:                                             |
    |                                                                        |
    |  +------------------------------------------------------------------+  |
    |  |                                                                  |  |
    |  |  When load ready to issue, check SQ for matching address:        |  |
    |  |                                                                  |  |
    |  |  for each older SQ entry (newest to oldest):                     |  |
    |  |    if (sq_entry.addr == load.addr &&                             |  |
    |  |        sq_entry.addr_valid &&                                    |  |
    |  |        size_compatible(sq_entry.size, load.size)):               |  |
    |  |                                                                  |  |
    |  |      // Forward data from store queue                            |  |
    |  |      // Works for both INT and FP loads/stores                   |  |
    |  |      load.data <- extract_bytes(sq_entry.data, load.size)        |  |
    |  |      load.forwarded <- 1                                         |  |
    |  |      load.data_valid <- 1                                        |  |
    |  |      // Don't go to memory                                       |  |
    |  |      break                                                       |  |
    |  |                                                                  |  |
    |  |  if (no match found):                                            |  |
    |  |    // Issue to memory                                            |  |
    |  |    memory_request(load.addr, load.size)                          |  |
    |  |                                                                  |  |
    |  +------------------------------------------------------------------+  |
    |                                                                        |
    |  COMPLETION:                                                           |
    |                                                                        |
    |  +------------------------------------------------------------------+  |
    |  |                                                                  |  |
    |  |  On memory response OR store forward:                            |  |
    |  |    lq[idx].data <- response_data (up to 64 bits)                 |  |
    |  |    lq[idx].data_valid <- 1                                       |  |
    |  |    broadcast on CDB: {rob_tag, data}                             |  |
    |  |    lq[idx].valid <- 0  // free entry                             |  |
    |  |    advance head if at head                                       |  |
    |  |                                                                  |  |
    |  +------------------------------------------------------------------+  |
    |                                                                        |
    +------------------------------------------------------------------------+
```

### Store Queue

```
                           Store Queue Internal Structure
    +------------------------------------------------------------------------+
    |                                                                        |
    |  PARAMETERS:                                                           |
    |    SQ_DEPTH = 8 (entries, configurable)                                |
    |    ROB_TAG_WIDTH = 5 bits                                              |
    |                                                                        |
    |  +------------------------------------------------------------------+  |
    |  |                    STORE QUEUE ENTRIES                           |  |
    |  |                    (Commit in program order)                     |  |
    |  |                    (Handles SW/SH/SB and FSW/FSD)                |  |
    |  |                                                                  |  |
    |  |  HEAD (oldest, next to commit)            TAIL (newest)          |  |
    |  |    |                                           |                 |  |
    |  |    v                                           v                 |  |
    |  |  +------+------+------+------+------+------+------+------+       |  |
    |  |  |  0   |  1   |  2   |  3   |  4   |  5   |  6   |  7   |       |  |
    |  |  +------+------+------+------+------+------+------+------+       |  |
    |  |                                                                  |  |
    |  +------------------------------------------------------------------+  |
    |                                                                        |
    |  ENTRY STRUCTURE:                                                      |
    |  +------------------------------------------------------------------+  |
    |  |  Field          | Width     | Description                        |  |
    |  +-----------------+-----------+------------------------------------+  |
    |  |  valid          | 1 bit     | Entry allocated                    |  |
    |  |  rob_tag        | 5 bits    | ROB entry for this store           |  |
    |  |  is_fp          | 1 bit     | FP store (FSW/FSD)                 |  |
    |  |  addr_valid     | 1 bit     | Address has been calculated        |  |
    |  |  address        | 32 bits   | Store address                      |  |
    |  |  data_valid     | 1 bit     | Data is available                  |  |
    |  |  data           | FLEN      | Store data (FLEN for FSD)          |  |
    |  |  size           | 2 bits    | 00=B, 01=H, 10=W, 11=D (for FSD)   |  |
    |  |  committed      | 1 bit     | ROB has committed this store       |  |
    |  |  sent           | 1 bit     | Written to memory                  |  |
    |  +-----------------+-----------+------------------------------------+  |
    |  |  TOTAL          | ~111 bits/entry                                |  |
    |  +------------------------------------------------------------------+  |
    |                                                                        |
    |  KEY PRINCIPLE: STORES COMMIT IN-ORDER                                 |
    |                                                                        |
    |  +------------------------------------------------------------------+  |
    |  |                                                                  |  |
    |  |  Stores write to memory ONLY after ROB commits them:             |  |
    |  |                                                                  |  |
    |  |  1. Store dispatches -> allocate SQ entry                        |  |
    |  |  2. Address calculates -> addr_valid = 1                         |  |
    |  |  3. Data available (from RS) -> data_valid = 1                   |  |
    |  |     (data may be 32b INT or 64b FP)                              |  |
    |  |  4. ROB commits store -> committed = 1                           |  |
    |  |  5. SQ writes to memory -> sent = 1, free entry                  |  |
    |  |                                                                  |  |
    |  |  This ensures stores are non-speculative when written!           |  |
    |  |                                                                  |  |
    |  +------------------------------------------------------------------+  |
    |                                                                        |
    |  OPERATIONS:                                                           |
    |                                                                        |
    |  +---------------------------+    +---------------------------+        |
    |  |     ALLOCATION            |    |     ADDRESS CALCULATION   |        |
    |  |                           |    |                           |        |
    |  |  On store dispatch:       |    |  From MEM_RS issue:       |        |
    |  |    sq[tail].valid <- 1    |    |    sq[idx].addr <-        |        |
    |  |    sq[tail].rob_tag <-    |    |      base + offset        |        |
    |  |      rob_tag              |    |    sq[idx].addr_valid <- 1|        |
    |  |    sq[tail].is_fp <-      |    |                           |        |
    |  |      (FSW or FSD)         |    +---------------------------+        |
    |  |    sq[tail].addr_valid    |                                         |
    |  |      <- 0                 |    +---------------------------+        |
    |  |    sq[tail].data_valid    |    |     DATA CAPTURE          |        |
    |  |      <- 0                 |    |                           |        |
    |  |    sq[tail].committed     |    |  From RS (via CDB or      |        |
    |  |      <- 0                 |    |  direct from RS):         |        |
    |  |    tail <- tail + 1       |    |    sq[idx].data <- data   |        |
    |  +---------------------------+    |      (up to 64 bits)      |        |
    |                                   |    sq[idx].data_valid <- 1|        |
    |  +---------------------------+    +---------------------------+        |
    |  |     COMMIT (from ROB)     |                                         |
    |  |                           |    +---------------------------+        |
    |  |  When ROB commits store:  |    |     MEMORY WRITE          |        |
    |  |    sq[idx].committed <- 1 |    |                           |        |
    |  |                           |    |  if (sq[head].committed &&|        |
    |  |  Note: Must match rob_tag |    |      sq[head].addr_valid&&|        |
    |  |  to find correct entry    |    |      sq[head].data_valid):|        |
    |  +---------------------------+    |                           |        |
    |                                   |    memory_write(          |        |
    |  +---------------------------+    |      sq[head].addr,       |        |
    |  |     FORWARD TO LOADS      |    |      sq[head].data,       |        |
    |  |                           |    |      sq[head].size)       |        |
    |  |  For LQ disambiguation:   |    |    sq[head].valid <- 0    |        |
    |  |                           |    |    head <- head + 1       |        |
    |  |  Provide all SQ entries   |    +---------------------------+        |
    |  |  to Load Queue for:       |                                         |
    |  |  - Address comparison     |    +---------------------------+        |
    |  |  - Data forwarding        |    |     FLUSH (Mispredict)    |        |
    |  |  - Works for INT<->INT,   |    |                           |        |
    |  |    FP<->FP, INT<->FP      |    |  Invalidate uncommitted   |        |
    |  |                           |    |  entries after flush_tag  |        |
    |  |  Export:                  |    |                           |        |
    |  |  - addr_valid[]           |    |  for each entry:          |        |
    |  |  - address[]              |    |    if (!committed &&      |        |
    |  |  - data_valid[]           |    |        rob_tag > flush):  |        |
    |  |  - data[] (FLEN)          |    |      valid <- 0           |        |
    |  |  - size[]                 |    +---------------------------+        |
    |  |  - rob_tag[]              |                                         |
    |  +---------------------------+                                         |
    |                                                                        |
    +------------------------------------------------------------------------+
```

### CDB Arbiter

```
                           CDB Arbiter Internal Structure
    +------------------------------------------------------------------------+
    |                                                                        |
    |  PARAMETERS:                                                           |
    |    NUM_FUS = 7 (ALU, MUL, DIV, MEM, FP_ADD, FP_MUL, FP_DIV)            |
    |    NUM_CDB_LANES = 1 (parameterized for future multi-bus expansion)    |
    |    ROB_TAG_WIDTH = 5 bits                                              |
    |    VALUE_WIDTH = max(XLEN, FLEN) = 64 bits                             |
    |                                                                        |
    |  PURPOSE:                                                              |
    |    Arbitrate between multiple functional units that complete in the    |
    |    same cycle, selecting one result to broadcast on the CDB.           |
    |    CDB is FLEN-wide to support FP double-precision results.            |
    |    Lane count is parameterized so a future split INT/FP bus can be     |
    |    enabled without restructuring RS/ROB/RAT wakeup logic.              |
    |                                                                        |
    |  +------------------------------------------------------------------+  |
    |  |                    FUNCTIONAL UNIT INPUTS                        |  |
    |  |                                                                  |  |
    |  |  INTEGER UNITS:                                                  |  |
    |  |  +----------+  +----------+  +----------+  +----------+          |  |
    |  |  |   ALU    |  |   MUL    |  |   DIV    |  |   MEM    |          |  |
    |  |  | complete |  | complete |  | complete |  | complete |          |  |
    |  |  +----+-----+  +----+-----+  +----+-----+  +----+-----+          |  |
    |  |       |             |             |             |                |  |
    |  |  FLOATING-POINT UNITS:                                           |  |
    |  |  +----------+  +----------+  +----------+                        |  |
    |  |  |  FP_ADD  |  |  FP_MUL  |  |  FP_DIV  |                        |  |
    |  |  | complete |  | complete |  | complete |                        |  |
    |  |  +----+-----+  +----+-----+  +----+-----+                        |  |
    |  |       |             |             |                              |  |
    |  |       v             v             v                              |  |
    |  |  +--------+    +--------+    +--------+                          |  |
    |  |  | valid  |    | valid  |    | valid  |    ... (for each FU)     |  |
    |  |  | tag    |    | tag    |    | tag    |                          |  |
    |  |  | value  |    | value  |    | value  |    (64 bits each)        |  |
    |  |  | exc    |    | exc    |    | exc    |                          |  |
    |  |  | fp_flg |    | fp_flg |    | fp_flg |    (FP exception flags)  |  |
    |  |  +---+----+    +---+----+    +---+----+                          |  |
    |  |      |             |             |                               |  |
    |  +------+-------------+-------------+-------------------------------+  |
    |         |             |             |                                  |
    |         +-------------+-------------+                                  |
    |                       |                                                |
    |                       v                                                |
    |  +------------------------------------------------------------------+  |
    |  |                    PRIORITY ARBITER                              |  |
    |  |                                                                  |  |
    |  |  PRIORITY ORDER (configurable):                                  |  |
    |  |    1. FP_DIV (longest latency, don't stall further)              |  |
    |  |    2. INT_DIV                                                    |  |
    |  |    3. FP_MUL                                                     |  |
    |  |    4. INT_MUL                                                    |  |
    |  |    5. FP_ADD                                                     |  |
    |  |    6. MEM (load results)                                         |  |
    |  |    7. ALU (shortest latency, can wait)                           |  |
    |  |                                                                  |  |
    |  |  Alternative: Round-robin for fairness                           |  |
    |  |                                                                  |  |
    |  +-----------------------------+------------------------------------+  |
    |                                |                                       |
    |                                v                                       |
    |  +------------------------------------------------------------------+  |
    |  |                    CDB OUTPUT MUX (FLEN-wide)                    |  |
    |  |                                                                  |  |
    |  |  +------------------------------------------------------------+  |  |
    |  |  |  cdb_valid   = (select != NONE)                            |  |  |
    |  |  |  cdb_tag     = selected_fu.tag                             |  |  |
    |  |  |  cdb_value   = selected_fu.value (FLEN)                    |  |  |
    |  |  |  cdb_exc     = selected_fu.exception                       |  |  |
    |  |  |  cdb_fp_flags= selected_fu.fp_flags (NV/DZ/OF/UF/NX)       |  |  |
    |  |  +------------------------------------------------------------+  |  |
    |  |                                                                  |  |
    |  +------------------------------------------------------------------+  |
    |                                |                                       |
    |  +-----------------------------+------------------------------------+  |
    |  |                    BROADCAST FANOUT                              |  |
    |  |                                                                  |  |
    |  |  CDB broadcasts to ALL listeners simultaneously:                 |  |
    |  |                                                                  |  |
    |  |  +--------+    +--------+    +--------+    +--------+            |  |
    |  |  |  ROB   |    | INT_RAT|    | FP_RAT |    | INT_RS |            |  |
    |  |  | update |    | update |    | update |    | wakeup |            |  |
    |  |  +--------+    +--------+    +--------+    +--------+            |  |
    |  |                                                                  |  |
    |  |  +--------+    +--------+    +--------+    +--------+            |  |
    |  |  | MUL_RS |    | MEM_RS |    |  FP_RS |    | FMUL_RS|            |  |
    |  |  | wakeup |    | wakeup |    | wakeup |    | wakeup |            |  |
    |  |  +--------+    +--------+    +--------+    +--------+            |  |
    |  |                                                                  |  |
    |  |  +--------+    +--------+                                        |  |
    |  |  |FDIV_RS |    |   LQ   |                                        |  |
    |  |  | wakeup |    | (addr) |                                        |  |
    |  |  +--------+    +--------+                                        |  |
    |  |                                                                  |  |
    |  +------------------------------------------------------------------+  |
    |                                                                        |
    |  STALL HANDLING:                                                       |
    |                                                                        |
    |  +------------------------------------------------------------------+  |
    |  |                                                                  |  |
    |  |  When FU completes but loses arbitration:                        |  |
    |  |    - FU must hold result until granted CDB access                |  |
    |  |    - FU asserts "result_pending" signal                          |  |
    |  |    - Pipeline stalls or buffers result                           |  |
    |  |                                                                  |  |
    |  |  Design options:                                                 |  |
    |  |    1. Single-cycle FUs hold output registers                     |  |
    |  |    2. Add small result buffer per FU                             |  |
    |  |    3. Multiple CDB buses (increases complexity)                  |  |
    |  |                                                                  |  |
    |  +------------------------------------------------------------------+  |
    |                                                                        |
    |  INTERFACES:                                                           |
    |                                                                        |
    |  FROM FUs:                              TO ALL LISTENERS:              |
    |  - alu_valid, alu_tag, alu_value, exc   - cdb_valid                    |
    |  - mul_valid, mul_tag, mul_value, exc   - cdb_tag                      |
    |  - div_valid, div_tag, div_value, exc   - cdb_value (FLEN)             |
    |  - mem_valid, mem_tag, mem_value, exc   - cdb_exception                |
    |  - fp_add_valid, tag, value, exc, flags - cdb_fp_flags                 |
    |  - fp_mul_valid, tag, value, exc, flags                                |
    |  - fp_div_valid, tag, value, exc, flags TO FUs (grant signals):        |
    |                                         - alu_grant, mul_grant, etc.   |
    +------------------------------------------------------------------------+
```

### Dispatch Unit

```
                           Dispatch Unit Internal Structure
    +------------------------------------------------------------------------+
    |                                                                        |
    |  PURPOSE:                                                              |
    |    Coordinate allocation of ROB, INT/FP RAT, and RS entries for each   |
    |    decoded instruction. Stall front-end if any resource unavailable.   |
    |                                                                        |
    |  +------------------------------------------------------------------+  |
    |  |                    FROM DECODE STAGE                             |  |
    |  |                                                                  |  |
    |  |  +----------------------------------------------------------+    |  |
    |  |  |  Decoded Instruction:                                    |    |  |
    |  |  |  - PC, instruction bits                                  |    |  |
    |  |  |  - opcode, funct3, funct7                                |    |  |
    |  |  |  - rs1, rs2, rs3 (for FMA), rd                           |    |  |
    |  |  |  - immediate (decoded)                                   |    |  |
    |  |  |  - instruction type:                                     |    |  |
    |  |  |      INT: ALU/MUL/DIV/LOAD/STORE/BRANCH/AMO              |    |  |
    |  |  |      FP:  FP_ADD/FP_MUL/FP_DIV/FP_LOAD/FP_STORE/FP_CVT   |    |  |
    |  |  |  - branch prediction metadata                            |    |  |
    |  |  |  - is_call, is_return (for RAS)                          |    |  |
    |  |  |  - rounding mode (for FP)                                |    |  |
    |  |  +----------------------------------------------------------+    |  |
    |  |                                                                  |  |
    |  +------------------------------+-----------------------------------+  |
    |                                 |                                      |
    |                                 v                                      |
    |  +------------------------------------------------------------------+  |
    |  |                    RESOURCE CHECK                                |  |
    |  |                                                                  |  |
    |  |  can_dispatch = !rob_full &&                                     |  |
    |  |                 !target_rs_full &&                               |  |
    |  |                 (is_load  ? !lq_full : 1) &&                     |  |
    |  |                 (is_store ? !sq_full : 1) &&                     |  |
    |  |                 (is_branch ? checkpoint_available : 1)           |  |
    |  |                                                                  |  |
    |  |  if (!can_dispatch):                                             |  |
    |  |    stall front-end (IF, PD, ID)                                  |  |
    |  |                                                                  |  |
    |  +------------------------------------------------------------------+  |
    |                                 |                                      |
    |              +------------------+------------------+                   |
    |              |                  |                  |                   |
    |              v                  v                  v                   |
    |  +----------+------+  +--------+---------+  +------+----------+        |
    |  |  ROB ALLOCATE   |  |  RAT LOOKUP      |  |   RS ALLOCATE   |        |
    |  |                 |  |  (INT or FP)     |  |                 |        |
    |  |  rob_tag <-     |  |                  |  |  Select RS by   |        |
    |  |    rob.alloc()  |  |  For INT instr:  |  |  instr type:    |        |
    |  |                 |  |    use INT RAT   |  |                 |        |
    |  |  Write to ROB:  |  |  For FP instr:   |  |  INT ALU -> INT_RS       |
    |  |  - pc           |  |    use FP RAT    |  |  MUL/DIV -> MUL_RS       |
    |  |  - dest_rf      |  |                  |  |  LD/ST   -> MEM_RS       |
    |  |  - rd           |  |  For rs1/rs2/rs3 |  |  FP ADD  -> FP_RS        |
    |  |  - is_store     |  |    {rdy, tag/val}|  |  FP MUL  -> FMUL_RS      |
    |  |  - is_fp_store  |  |    <- rat lookup |  |  FP DIV  -> FDIV_RS      |
    |  |  - is_branch    |  |                  |  |                 |        |
    |  |  - is_call      |  |  Update RAT:     |  |  Write to RS:   |        |
    |  |  - is_return    |  |  if (has_dest):  |  |  - rob_tag      |        |
    |  |  - predicted    |  |    rat[rd] <-    |  |  - operation    |        |
    |  |                 |  |      {1, rob_tag}|  |  - src1/2/3 info|        |
    |  +-----------------+  +------------------+  |  - immediate    |        |
    |                                             |  - rm (FP)      |        |
    |                                             +-----------------+        |
    |                                 |                                      |
    |              +------------------+------------------+                   |
    |              |                                     |                   |
    |              v                                     v                   |
    |  +----------+----------+              +-----------+-----------+        |
    |  |  LQ/SQ ALLOCATE     |              |  BRANCH CHECKPOINT    |        |
    |  |  (if memory op)     |              |  (if branch/jump)     |        |
    |  |                     |              |                       |        |
    |  |  if (is_load):      |              |  if (is_branch):      |        |
    |  |    lq.alloc(rob_tag)|              |    Save INT RAT       |        |
    |  |    (INT or FP load) |              |    Save FP RAT        |        |
    |  |                     |              |    Save RAS top       |        |
    |  |  if (is_store):     |              |    Tag with rob_tag   |        |
    |  |    sq.alloc(rob_tag)|              |                       |        |
    |  |    (INT or FP store)|              |                       |        |
    |  +---------------------+              +-----------------------+        |
    |                                                                        |
    +------------------------------------------------------------------------+
```

---

## Directory Structure

```
tomasulo/
├── README.md                 # This file
├── tomasulo_pkg.sv           # Types, structs, parameters
├── dispatch.sv               # Dispatch logic (ROB/RAT/RS allocation)
├── rob.sv                    # Reorder Buffer (unified INT/FP)
├── int_rat.sv                # Integer Register Alias Table (x0-x31)
├── fp_rat.sv                 # FP Register Alias Table (f0-f31)
├── reservation_station.sv    # Generic RS (parameterized)
├── int_rs.sv                 # Integer RS instance
├── mul_rs.sv                 # Multiply RS instance
├── mem_rs.sv                 # Memory RS instance (INT + FP loads/stores)
├── fp_rs.sv                  # FP add/sub/compare RS instance
├── fmul_rs.sv                # FP multiply RS instance
├── fdiv_rs.sv                # FP divide/sqrt RS instance
├── load_queue.sv             # Load queue with disambiguation (INT + FP)
├── store_queue.sv            # Store queue with forwarding (INT + FP)
└── cdb_arbiter.sv            # Common Data Bus arbiter (FLEN-wide, lane-parameterized)
```

---

## Implementation Schedule (14 Weeks)

| Week | Dates | Deliverable |
|------|-------|-------------|
| 1 | 1/20 | **F and D floating-point extensions implemented** - FPU integration, F/D instruction support, cocotb tests passing; high-level block diagrams and architecture diagrams designed |
| 2 | 1/27 | Define module interfaces in SystemVerilog (tomasulo_pkg.sv - types, structs, parameters); finish closing timing for D extension (~300ps slack to recover) |
| 3 | 2/3 | ROB structure - circular buffer, allocation logic, head/tail pointers, unified INT/FP tracking |
| 4 | 2/10 | ROB commit logic - in-order retirement, register writeback (INT + FP), exception handling, FP flag accumulation, pipeline flush; CSR execute-at-commit, FENCE store queue drain, FENCE.I pipeline flush |
| 5 | 2/17 | INT RAT + FP RAT - register mapping tables, checkpoint/restore for branch misprediction recovery, RAS state tracking |
| 6 | 2/24 | Integer Reservation Stations (INT_RS, MUL_RS) - operand tracking, readiness detection, issue logic, CDB snoop for wakeup |
| 7 | 3/3 | FP Reservation Stations (FP_RS, FMUL_RS, FDIV_RS) - FLEN operand support, rounding mode, 3-source for FMA |
| 8 | 3/10 | CDB - arbitration between INT + FP functional units (7 FUs), XLEN/FLEN broadcast to RS/LQ/ROB/RAT, FP flag propagation |
| 9 | 3/23 | Load Queue - address calculation, memory disambiguation against older stores (INT + FP loads); LR.W/D reservation set tracking |
| 10 | 3/30 | Store Queue - address/data buffering (FLEN for FSD), in-order commit to memory, store-to-load forwarding; SC.W/D reservation check, AMO execute-at-ROB-head |
| 11 | 4/6 | Pipeline integration - connect Tomasulo components to FROST IF/PD/ID; adapt ALU/MUL/DIV/FPU to RS interface; wire up RAS restore |
| 12 | 4/13 | Initial verification - run ISA test suite (366+ tests including F/D), debug failures, fix integration issues |
| 13 | 4/20 | Full verification - run CoreMark and FreeRTOS demo; verify correct behavior with interrupts, AMOs, and FP operations; begin timing closure |
| 14 | 4/27 | Final timing closure and documentation - synthesize for Ultrascale+, analyze critical paths, optimize as needed; finalize architecture diagrams, complete technical report |

---

## Methodology & Approach

- **Reuse existing FROST functional units** (ALU, multiplier, divider, FPU) and cocotb test infrastructure
- **Develop ROB, INT RAT, FP RAT, RS, LQ, SQ as isolated modules** with unit tests before integration
- **Integration proceeds incrementally**: ROB first, then RATs, then RS (INT then FP), then LQ/SQ; regression test after each step
- **Conservative memory disambiguation**: loads wait for older store addresses to resolve; stores commit in-order
- **Validate via existing C test programs**; functional correctness demonstrated by identical results pre/post Tomasulo
- **RAS integration**: checkpoint RAS top pointer with branch checkpoints; restore on misprediction
- **FP exception handling**: accumulate FP flags (NV/DZ/OF/UF/NX) in ROB entries; update fcsr at commit time

---

## Deliverables & Evaluation

- Weekly 30-min meeting with advisor on design progress and test results
- Git repository with clear commit history, documented modules, and commented code
- RTL modules: ROB, INT RAT, FP RAT, Reservation Stations (INT + FP), Load Queue, Store Queue, CDB arbiter - in synthesizable SystemVerilog
- Integrated FROST-Tomasulo CPU with out-of-order execution for integer, memory, and floating-point operations
- All existing tests passing (366+ instruction ISA tests including F/D, CoreMark benchmark, FreeRTOS RTOS demo)
- Timing closure at 322MHz on Ultrascale+ or documented analysis of critical paths
- Architecture diagrams documenting Tomasulo datapath, control flow, memory disambiguation, and FP support
- Technical report (conference paper format) describing design decisions and implementation
