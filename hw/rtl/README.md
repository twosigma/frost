# FROST RISC-V Processor RTL

## Overview

FROST is a 6-stage pipelined RISC-V processor implementing **RV32GCB** (G = IMAFD) with full machine-mode privilege support for RTOS operation. The design is fully portable (no vendor-specific primitives), synthesizable with standard tools including Yosys and Vivado, and simulatable with Verilator, Icarus Verilog, and Questa.

### Supported RISC-V Extensions

**ISA: RV32GCB** (G = IMAFD) plus additional extensions

| Extension        | Description                                | Instructions                                                                                                                                                       |
|------------------|--------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **RV32I**        | Base integer instruction set               | 37 instructions                                                                                                                                                    |
| **M**            | Integer multiply/divide                    | mul, mulh, mulhsu, mulhu, div, divu, rem, remu                                                                                                                     |
| **A**            | Atomic memory operations                   | lr.w, sc.w, amoswap.w, amoadd.w, amoxor.w, amoand.w, amoor.w, amomin.w, amomax.w, amominu.w, amomaxu.w                                                             |
| **F**            | Single-precision floating-point            | flw, fsw, fadd.s, fsub.s, fmul.s, fdiv.s, fsqrt.s, fmin.s, fmax.s, fmadd.s, fmsub.s, fnmadd.s, fnmsub.s, fsgnj.s, fsgnjn.s, fsgnjx.s, fcvt.w.s, fcvt.wu.s, fcvt.s.w, fcvt.s.wu, fmv.x.w, fmv.w.x, feq.s, flt.s, fle.s, fclass.s |
| **D**            | Double-precision floating-point            | fld, fsd, fadd.d, fsub.d, fmul.d, fdiv.d, fsqrt.d, fmin.d, fmax.d, fmadd.d, fmsub.d, fnmadd.d, fnmsub.d, fsgnj.d, fsgnjn.d, fsgnjx.d, fcvt.w.d, fcvt.wu.d, fcvt.d.w, fcvt.d.wu, fcvt.s.d, fcvt.d.s, feq.d, flt.d, fle.d, fclass.d |
| **C**            | Compressed instructions (16-bit)           | c.lwsp, c.swsp, c.lw, c.sw, c.flwsp, c.fswsp, c.flw, c.fsw, c.j, c.jal, c.jr, c.jalr, c.beqz, c.bnez, c.li, c.lui, c.addi, c.addi16sp, c.addi4spn, c.slli, c.srli, c.srai, c.andi, c.mv, c.add, c.and, c.or, c.xor, c.sub, c.nop, c.ebreak |
| **B**            | Bit manipulation (B = Zba + Zbb + Zbs)     | See Zba, Zbb, Zbs below                                                                                                                                            |
| **Zba**          | Address generation (part of B)             | sh1add, sh2add, sh3add                                                                                                                                             |
| **Zbb**          | Basic bit manipulation (part of B)         | andn, orn, xnor, clz, ctz, cpop, min[u], max[u], sext.b, sext.h, zext.h, rol, ror, rori, orc.b, rev8                                                               |
| **Zbs**          | Single-bit operations (part of B)          | bset[i], bclr[i], binv[i], bext[i]                                                                                                                                 |
| **Zicsr**        | CSR access                                 | csrrw, csrrs, csrrc, csrrwi, csrrsi, csrrci                                                                                                                        |
| **Zicntr**       | Base counters                              | cycle, time, instret (and high halves)                                                                                                                             |
| **Zifencei**     | Instruction fence                          | fence.i                                                                                                                                                            |
| **Zicond**       | Conditional zero (not part of B)           | czero.eqz, czero.nez                                                                                                                                               |
| **Zbkb**         | Bit manipulation for crypto (part of Zk, not B) | pack, packh, brev8, zip, unzip                                                                                                                                |
| **Zihintpause**  | Pause hint                                 | pause                                                                                                                                                              |
| **Machine Mode** | M-mode privilege (RTOS support)            | mret, wfi, ecall, ebreak                                                                                                                                           |

**Total: 170+ instructions** (including C extension compressed forms)

**Key Highlights:**
- 6-stage pipeline with full data forwarding
- **Branch prediction** with 32-entry 2-bit BTB + 8-entry return address stack (reduces branch/return penalty from 3 to 0 cycles when correct)
- L0 data cache for reduced load latency
- Full machine-mode trap handling (interrupts and exceptions)
- CLINT-compatible timer with mtime/mtimecmp for RTOS scheduling
- Dual clock domain design for peripheral integration
- Memory-mapped I/O for UART, timer, and FIFOs
- Clean, well-documented SystemVerilog

## Architecture

### Block Diagram

```
                                 FROST Top Level (frost.sv)
    +------------------------------------------------------------------------------+
    |                                                                              |
    |  +-----------------------------------------------------------------------+   |
    |  |                    CPU and Memory (cpu_and_mem.sv)                    |   |
    |  |  +-----------------------------------------------------------------+  |   |
    |  |  |                      CPU Core (cpu.sv)                          |  |   |
    |  |  |                                                                 |  |   |
    |  |  |   +----+   +----+   +----+   +----+   +----+   +----+           |  |   |
    |  |  |   | IF |-->| PD |-->| ID |-->| EX |-->| MA |-->| WB |           |  |   |
    |  |  |   +----+   +----+   +----+   +----+   +----+   +----+           |  |   |
    |  |  |      |                 |         |       |                      |  |   |
    |  |  |      |    +------------+---------+-------+                      |  |   |
    |  |  |      |    |         Forwarding Unit                             |  |   |
    |  |  |      |    +---------------------------------> to EX             |  |   |
    |  |  |      |                                                          |  |   |
    |  |  |      |         +----------+      +----------+                   |  |   |
    |  |  |      +-------->|   BTB    |      | Regfile  |                   |  |   |
    |  |  |      |         +----------+      +----------+                   |  |   |
    |  |  |      |         +----------+                                     |  |   |
    |  |  |      |         |   RAS    |                                     |  |   |
    |  |  |      |         +----------+                                     |  |   |
    |  |  |      |         +----------+                                     |  |   |
    |  |  |      |         | L0 Cache |                                     |  |   |
    |  |  |      |         +----------+                                     |  |   |
    |  |  |      |                                                          |  |   |
    |  |  +------+----------------------------------------------------------+  |   |
    |  |         |                         |                                   |   |
    |  |         v                         v                                   |   |
    |  |  +-------------------+   +------------------------+                   |   |
    |  |  | Instruction Memory|   |     Data Memory        |                   |   |
    |  |  |  (tdp_bram_dc)    |   | (tdp_bram_dc_byte_en)  |                   |   |
    |  |  | Port A: pgm write |   | Port A: pgm write      |                   |   |
    |  |  |  (div4 clock)     |   |  (div4 clock)          |                   |   |
    |  |  | Port B: instr     |   | Port B: data load/     |                   |   |
    |  |  |  fetch (main clk) |   |  store (main clk)      |                   |   |
    |  |  +-------------------+   +------------------------+                   |   |
    |  |                                                                       |   |
    |  |  +---------+  +----------+  +----------+                              |   |
    |  |  |  mtime  |  | mtimecmp |  |   msip   |  (CLINT-compatible timer)    |   |
    |  |  +---------+  +----------+  +----------+                              |   |
    |  |                                                                       |   |
    |  |  +-----------+                                                        |   |
    |  |  | Trap Unit |  (interrupt/exception handling)                        |   |
    |  |  +-----------+                                                        |   |
    |  +-----------------------------------------------------------------------+   |
    |                                                                              |
    |  +--------------+  +--------------+  +--------------+                        |
    |  | MMIO FIFO 0  |  | MMIO FIFO 1  |  | Sync DC FIFO |-> UART TX -> o_uart_tx |
    |  +--------------+  +--------------+  +--------------+     (clk_div4)         |
    |                                                                              |
    |  +--------------+                   +--------------+                         |
    |  | Sync DC FIFO |<-- UART RX <------| Sync DC FIFO |<--- i_uart_rx           |
    |  +--------------+     (clk_div4)    +--------------+                         |
    |                                                                              |
    |  Instruction Memory Programming: directly on div4 clock (no CDC needed)      |
    |  Both memories receive writes on Port A (div4), program executes on Port B   |
    |                                                                              |
    +------------------------------------------------------------------------------+
```

### CPU Core Detailed Architecture

The CPU core contains the 6-stage pipeline plus supporting units. Each stage contains
specialized submodules for specific functionality:

```
                              CPU Core (cpu.sv)
  +---------------------------------------------------------------------------------+
  |                                                                                 |
  |  +-------------------------------------------------------------------------+    |
  |  |                         6-Stage Pipeline                                |    |
  |  |                                                                         |    |
  |  |  +----------+  +----------+  +----------+  +----------+  +----------+   |    |
  |  |  |    IF    |->|    PD    |->|    ID    |->|    EX    |->|    MA    |-->|WB  |
  |  |  | (fetch)  |  |(predec)  |  | (decode) |  |(execute) |  | (memory) |   |    |
  |  |  +----------+  +----------+  +----------+  +----------+  +----------+   |    |
  |  |       |                            |            |             |         |    |
  |  +-------+----------------------------+------------+-------------+---------+    |
  |          |                            |            |             |              |
  |          |         +------------------+------------+-------------+              |
  |          |         |                                                            |
  |          |         v                                                            |
  |          |   +-------------------+        +---------------+                     |
  |          |   |  Forwarding Unit  |------->|   Regfile     |<--- WB writes       |
  |          |   +-------------------+        +---------------+                     |
  |          |                                                                      |
  |          |   +-------------------+        +---------------+                     |
  |          +-->|     L0 Cache      |        |   CSR File    |                     |
  |              +-------------------+        +---------------+                     |
  |                                                                                 |
  |   +-------------------------+    +-------------------------+                    |
  |   | Hazard Resolution Unit  |    |       Trap Unit         |                    |
  |   | (stall/flush control)   |    | (interrupts/exceptions) |                    |
  |   +-------------------------+    +-------------------------+                    |
  |                                                                                 |
  |   +-------------------------+                                                   |
  |   |  LR/SC Reservation Reg  |  (A extension atomics)                            |
  |   +-------------------------+                                                   |
  |                                                                                 |
  +---------------------------------------------------------------------------------+
```

### IF Stage Internal Architecture

The IF stage handles instruction fetch with C-extension and branch prediction support:

```
                            IF Stage (if_stage.sv)
  +---------------------------------------------------------------------------------+
  |                                                                                 |
  |   +-------------------------------------------------------------------------+   |
  |   |                    Branch Prediction Subsystem                          |   |
  |   |  +-----------------+  +----------------------+  +--------------------+  |   |
  |   |  | branch_predictor|  |branch_prediction_    |  |prediction_metadata_|  |   |
  |   |  |    (BTB)        |->|    controller        |->|     tracker        |--+---+-> to PD
  |   |  |  32 entries     |  |  (gating logic)      |  | (stall handling)   |  |   |
  |   |  +--------^--------+  +----------^-----------+  +--------------------+  |   |
  |   |           |                      |                                      |   |
  |   |           |              +-----------------+                            |   |
  |   |           +--------------| return_address  |                            |   |
  |   |                          |   stack (RAS)   |                            |   |
  |   |                          |   8 entries     |                            |   |
  |   |                          +-----------------+                            |   |
  |   +-----------+----------------------+--------------------------------------+   |
  |               |                      |                                          |
  |   BTB/RAS     |                      | prediction signals                       |
  |   update from |                      v                                          |
  |   EX          |                                                                 |
  |               |           +----------------------------------------------+      |
  |               |           |              pc_controller                   |      |
  |               |           |  +----------------------------------------+  |      |
  |               |           |  |      control_flow_tracker              |  |      |
  |               |           |  |  (holdoff signal generation)           |  |      |
  |               |           |  +----------------------------------------+  |      |
  |               |           |                    |                         |      |
  |               |           |                    v                         |      |
  |               |           |  +----------------------------------------+  |      |
  |               |           |  |    pc_increment_calculator             |  |      |
  |               |           |  |  (parallel adders for timing)          |  |      |
  |               |           |  +----------------------------------------+  |      |
  |               |           |                    |                         |      |
  |               |           |                    v                         |      |
  |               |           |  +----------------------------------------+  |      |
  |   <-----------+-----------+  |   Final PC Mux (priority encoded)      |--+------+-> o_pc
  |                           |  +----------------------------------------+  |      |
  |                           +----------------------+-----------------------+      |
  |                                                  |                              |
  |   +----------------------------------------------+---------------------------+  |
  |   |              C-Extension Subsystem           |                           |  |
  |   |                                              |                           |  |
  |   |  +-----------------+  +----------------------v-----+                     |  |
  |   |  |   c_ext_state   |  |   instruction_aligner      |                     |  |
  |   |  | (state machine) |->|   (parcel selection)       |---------------------+--+-> to PD
  |   |  | spanning/buffer |  |    NOP/span/compress       |                     |  |
  |   |  +-----------------+  +----------------------------+                     |  |
  |   |                                                                          |  |
  |   +--------------------------------------------------------------------------+  |
  |                                                                                 |
  |   i_instr --------------------------------------------------------------------->|
  |   (from memory)                                                                 |
  |                                                                                 |
  |   Note: rvc_decompressor is in PD stage (breaks timing path from BRAM read)     |
  +---------------------------------------------------------------------------------+
```

### EX Stage Internal Architecture

The EX stage performs computation, branch resolution, and exception detection:

```
                            EX Stage (ex_stage.sv)
  +---------------------------------------------------------------------------------+
  |                                                                                 |
  |   from ID -----+----------------------------------------------------------------|
  |                |                                                                |
  |                v                                                                |
  |   +------------------------------------------------------------------------+    |
  |   |                              ALU                                       |    |
  |   |  +-----------------------------------------------------------------+   |    |
  |   |  |                     Main ALU Logic                              |   |    |
  |   |  |  (RV32I + Zba + Zbb + Zbs + Zicond + Zbkb operations)           |   |    |
  |   |  +--------------------------+--------------------------------------+   |    |
  |   |                             |                                          |    |
  |   |        +--------------------+--------------------+                     |    |
  |   |        v                    |                    v                     |    |
  |   |   +----------+              |             +-----------+                |    |
  |   |   |multiplier|              |             |  divider  |                |    |
  |   |   | 4-cycle  |              |             | 17-cycle  |                |    |
  |   |   +----------+              |             +-----------+                |    |
  |   |                             |                                          |    |
  |   +-----------------------------+------------------------------------------+    |
  |                                 |                                               |
  |                                 v alu_result                                    |
  |                                 |                                               |
  |   +-----------------+    +------+------+    +-----------------------------+     |
  |   | branch_jump_unit|    |             |    |     exception_detector      |     |
  |   |                 |    |   Output    |    |  +-----------------------+  |     |
  |   | branch condition|--->|    Mux      |<---|  | ECALL / EBREAK        |  |     |
  |   | target address  |    |             |    |  | load/store misalign   |  |     |
  |   +---------+-------+    +------+------+    |  +-----------------------+  |     |
  |             |                   |           +--------------+--------------+     |
  |             v                   |                          |                    |
  |   +--------------------+        |                          | exception signals  |
  |   |branch_redirect_unit|        |                          v                    |
  |   | misprediction det  |--------+--------------------------------------------> to MA
  |   | BTB/RAS recovery   |        |                                               |
  |   +--------------------+        |                                               |
  |                                 |                                               |
  |   +-----------------+           |                                               |
  |   |   store_unit    |           |                                               |
  |   | address calc    |-----------+--------------------------------------------> to MA
  |   | byte enables    |                                                           |
  |   +-----------------+                                                           |
  |                                                                                 |
  |   BTB/RAS update <-------------------------------------------------------- to IF|
  |   (from branch_redirect_unit)                                                   |
  +---------------------------------------------------------------------------------+
```

### MA Stage Internal Architecture

The MA stage completes memory operations, handles atomics, and sequences FP64 memory accesses:

```
                            MA Stage (ma_stage.sv)
  +---------------------------------------------------------------------------------+
  |                                                                                 |
  |   from EX ----------------------------------------------------------------------|
  |                |                           |                  |                 |
  |                v                           v                  v                 |
  |   +--------------------+      +--------------+   +---------------------+        |
  |   |     load_unit      |      |   amo_unit   |   |  fp64_sequencer     |        |
  |   |                    |      |              |   |                     |        |
  |   | - LB/LH/LW extract |      | - LR/SC      |   | - FLD/FSD 2-phase   |        |
  |   | - sign/zero extend |      | - AMO R-M-W  |   |   over 32-bit bus   |        |
  |   | - byte alignment   |      | - AMOSWAP,.. |   | - stall generation  |        |
  |   +---------+----------+      +------+-------+   | - load data assembly|        |
  |             |                        |            +----------+----------+        |
  |             +------------+-----------+                       |                  |
  |                          |                                   |                  |
  |                          v                                   |                  |
  |                 +-----------------+                          |                  |
  |                 |   Result Mux    |<-------------------------+                  |
  |                 | (load/alu/amo/  |--------------------------------------> WB   |
  |                 |  fp_load_data)  |                                             |
  |                 +-----------------+                                             |
  |                                                                                 |
  |   i_data_mem_rd_data -----------------------------------------------------------+
  |   (from memory)                                                                 |
  +---------------------------------------------------------------------------------+
```

### Pipeline Stages

```
    Cycle:    1        2        3        4        5        6        7        8
             +----+   +----+   +----+   +----+   +----+   +----+
    Instr 1  | IF |-->| PD |-->| ID |-->| EX |-->| MA |-->| WB |
             +----+   +----+   +----+   +----+   +----+   +----+
                      +----+   +----+   +----+   +----+   +----+   +----+
    Instr 2           | IF |-->| PD |-->| ID |-->| EX |-->| MA |-->| WB |
                      +----+   +----+   +----+   +----+   +----+   +----+
                               +----+   +----+   +----+   +----+   +----+   +----+
    Instr 3                    | IF |-->| PD |-->| ID |-->| EX |-->| MA |-->| WB |
                               +----+   +----+   +----+   +----+   +----+   +----+
```

| Stage  | Module         | Key Operations                                                                             |
|--------|----------------|--------------------------------------------------------------------------------------------|
| **IF** | `if_stage.sv`  | Fetch instruction from memory, manage PC, handle branch targets, C extension alignment    |
| **PD** | `pd_stage.sv`  | C extension decompression, instruction selection, early source register extraction        |
| **ID** | `id_stage.sv`  | Full instruction decode, extract immediates, pre-compute branch/JAL targets, register file read |
| **EX** | `ex_stage.sv`  | ALU operations, branch evaluation, JALR target calc, memory address, multiply/divide      |
| **MA** | `ma_stage.sv`  | Complete loads, extract/sign-extend loaded data, execute AMO operations                   |
| **WB** | `generic_regfile.sv` | Write results back to register file                                                  |

**Pipeline Balancing:** Work is distributed across stages to reduce critical path timing:
- **ID stage** pre-computes branch and JAL target addresses (PC + immediate), since these
  are PC-relative and don't require forwarded register values.
- **ID stage** reads the register file using early source registers extracted in PD stage.
  The read data is registered at the ID→EX boundary, removing the regfile read from the
  EX stage critical path. A WB bypass handles the case where WB writes to the same register
  that ID is reading (same-cycle write/read race).
- **EX stage** only computes JALR targets (requires forwarded rs1) and evaluates branch
  conditions, keeping target address muxing simple.

**Critical Path Optimization:** Several timing-critical paths are optimized:

1. **Load-use hazard detection**: The path spans register file read → forwarding → address
   calculation → cache lookup → cache hit detection → hazard decision. Optimized by:
   - Computing "potential hazard" (dest matches source) using fast registered signals
   - Computing cache_hit_on_load in parallel (slow path through cache)
   - Registering both signals at cycle end
   - Combining registered signals in the next cycle with minimal logic (one AND gate)

2. **Multiply stall path**: The multiply completion signal feeds through stall logic to cache
   write address, creating a long combinational path. Optimized by:
   - Exposing `o_multiply_completing_next_cycle` from the multiplier (one cycle before output valid)
   - Registering this signal in the hazard unit to predict completion
   - Using the registered signal for stall decisions instead of raw multiplier completion logic
   - The registered signal has the same cycle alignment as multiplier completion but no combinational
     dependency, breaking the critical path with no latency penalty

### Data Forwarding Paths

The processor implements full forwarding to minimize stalls:

```
                    +---------------------------------+
                    |         Forwarding Unit         |
                    |                                 |
    From MA ------->|  ALU result / Cache hit data    |-------> To EX (rs1, rs2)
                    |                                 |
    From WB ------->|  Final writeback data           |-------> To EX (rs1, rs2)
                    |                                 |
    From ID→EX ---->|  Register file read data        |-------> To EX (rs1, rs2)
                    +---------------------------------+

    Priority: MA stage > WB stage > Register file (from ID→EX)
```

Note: Regfile read data is registered at the ID→EX boundary, so it arrives at the
forwarding unit from `from_id_to_ex` rather than directly from the regfile. A WB→ID
bypass in `id_stage.sv` handles the case where WB writes to the same register that
ID is reading in the same cycle.

### Pipeline Hazards

| Hazard Type                    | Detection                    | Resolution                         | Penalty   |
|--------------------------------|------------------------------|------------------------------------|-----------|
| **RAW (data)**                 | Forwarding unit              | Forward from MA/WB to EX           | 0 cycles  |
| **Load-use**                   | Hazard resolution unit       | Stall 1 cycle, then forward        | 1 cycle   |
| **Load-use (cache hit)**       | L0 cache hit                 | Forward from cache                 | 0 cycles  |
| **AMO-use**                    | Hazard resolution unit       | Stall for AMO result, then forward | 1 cycle   |
| **AMO operation**              | AMO unit                     | Stall for read-modify-write        | 2 cycles  |
| **Branch/Jump (predicted)**    | BTB hit or RAS return, correct prediction | No flush needed                    | 0 cycles  |
| **Branch/Jump (mispredicted)** | BTB miss/wrong prediction or RAS miss/wrong target | Flush pipeline                     | 3 cycles  |
| **Multiply**                   | ALU                          | Stall pipeline                     | 4 cycles  |
| **Divide**                     | ALU                          | Stall pipeline                     | 17 cycles |
| **FP Add/Sub**                 | FPU                          | Stall pipeline                     | 4 cycles  |
| **FP Multiply**                | FPU                          | Stall pipeline                     | 8 cycles  |
| **FP Divide/Sqrt**             | FPU                          | Stall pipeline                     | ~32 cycles|
| **FP FMA**                     | FPU                          | Stall pipeline                     | 12 cycles |
| **FP Compare/Convert**         | FPU                          | Stall pipeline                     | 3 cycles  |
| **FP Sign Inject/Classify**    | FPU                          | Stall pipeline                     | 2 cycles  |
| **FP Load-use**                | Hazard resolution unit       | Stall until FLW/FLD completes      | 1+ cycles |
| **Trap/Exception**             | Trap unit                    | Flush pipeline, jump to mtvec      | 2 cycles  |
| **MRET**                       | Trap unit                    | Flush pipeline, jump to mepc       | 2 cycles  |
| **WFI**                        | Trap unit                    | Stall until interrupt              | Variable  |

### Pipeline Timing Examples

These diagrams show cycle-by-cycle pipeline behavior for various scenarios:

**Normal Execution (no hazards):**
```
Cycle:       1        2        3        4        5        6        7        8
            +----+   +----+   +----+   +----+   +----+   +----+
Instr 1     | IF |-->| PD |-->| ID |-->| EX |-->| MA |-->| WB |
            +----+   +----+   +----+   +----+   +----+   +----+
                     +----+   +----+   +----+   +----+   +----+   +----+
Instr 2              | IF |-->| PD |-->| ID |-->| EX |-->| MA |-->| WB |
                     +----+   +----+   +----+   +----+   +----+   +----+
                              +----+   +----+   +----+   +----+   +----+   +----+
Instr 3                       | IF |-->| PD |-->| ID |-->| EX |-->| MA |-->| WB |
                              +----+   +----+   +----+   +----+   +----+   +----+

IPC = 1.0 (one instruction completes per cycle after pipeline fills)
```

**Data Forwarding (RAW hazard, no stall):**
```
Cycle:       1        2        3        4        5        6        7
            +----+   +----+   +----+   +----+   +----+   +----+
ADD x1,...  | IF |-->| PD |-->| ID |-->| EX |-->| MA |-->| WB |   <- produces x1
            +----+   +----+   +----+   +----+   +-+--+   +----+
                     +----+   +----+   +----+   +-v--+   +----+   +----+
SUB x2,x1,..         | IF |-->| PD |-->| ID |-->| EX |-->| MA |-->| WB | <- uses x1
                     +----+   +----+   +----+   +----+   +----+   +----+

Forward path: MA->EX (x1 value forwarded from MA stage, no stall needed)
```

**Load-Use Hazard (cache miss, 1-cycle stall):**
```
Cycle:       1        2        3        4        5        6        7        8
            +----+   +----+   +----+   +----+   +----+   +----+
LW x1,0(x2) | IF |-->| PD |-->| ID |-->| EX |-->| MA |-->| WB |   <- loads x1
            +----+   +----+   +----+   +----+   +----+   +----+
                     +----+   +----+   +----+   STALL    +----+   +----+   +----+
ADD x3,x1,..         | IF |-->| PD |-->| ID |---->|----->| EX |-->| MA |-->| WB |
                     +----+   +----+   +----+            +----+   +----+   +----+

1-cycle stall: load data not ready until MA completes, then forwarded to EX.
Note: If x1's address hits in L0 cache, data forwards in same cycle (no stall).
```

**Multiply (4-cycle latency):**

Integer multiply uses a 4-cycle DSP-tiled pipeline (33x33 signed via 27x18 partial products).
The hazard unit stalls while multiply is in-flight, and uses
`o_multiply_completing_next_cycle` to release stall with a registered timing path.

Typical behavior:
- MUL enters EX and starts multiply
- Pipeline stalls for 4 cycles
- Result is written when multiply valid asserts (MULH/MULHSU/MULHU use upper 32 bits)

**Divide (17-cycle latency):**
```
Cycle:       1        2        3        4  ...  19       20       21       22
            +----+   +----+   +----+   +------------+   +----+   +----+
DIV x1,x2,x3| IF |-->| PD |-->| ID |-->|     EX     |-->| MA |-->| WB |
            +----+   +----+   +----+   +------------+   +----+   +----+
                     +----+   +----+   STALL (17 cy)    +----+   +----+   +----+
ADD x4,...           | IF |-->| PD |---->| ... |---->-->| ID |-->| EX |-->...
                     +----+   +----+                    +----+   +----+

17-cycle stall while divide completes in EX stage.
```

**Branch Prediction (BTB hit, correct prediction):**
```
Cycle:       1        2        3        4        5        6        7
            +----+   +----+   +----+   +----+   +----+   +----+
BEQ x1,x2,L | IF |-->| PD |-->| ID |-->| EX |-->| MA |-->| WB |  <- branch in EX
            +-+--+   +----+   +----+   +----+   +----+   +----+
              |
              | BTB predicts taken at cycle 1
              v
            +----+   +----+   +----+   +----+   +----+   +----+
L: ADD      | IF |-->| PD |-->| ID |-->| EX |-->| MA |-->| WB |  <- target fetched
            +----+   +----+   +----+   +----+   +----+   +----+

No penalty! BTB correctly predicted target, no flush needed. Returns predicted by the RAS behave the same way.
```

**Branch Misprediction (3-cycle penalty):**
```
Cycle:       1        2        3        4        5        6        7        8
            +----+   +----+   +----+   +----+   +----+   +----+
BEQ x1,x2,L | IF |-->| PD |-->| ID |-->| EX |-->| MA |-->| WB |  <- mispredicted!
            +----+   +----+   +----+   +-+--+   +----+   +----+
                     +----+   +----+   +-v--+
wrong path           | IF |-->| PD |-->| ID |   <- FLUSH
                     +----+   +----+   +----+
                              +----+   +----+
wrong path                    | IF |-->| PD |   <- FLUSH
                              +----+   +----+
                                       +----+
wrong path                             | IF |   <- FLUSH
                                       +----+
                                                +----+   +----+   +----+   +----+
correct target                                  | IF |-->| PD |-->| ID |-->| EX |-->...
                                                +----+   +----+   +----+   +----+

3-cycle penalty: IF, PD, ID stages flushed when EX detects misprediction.
```

**AMO Operation (2-cycle stall for read-modify-write):**
```
Cycle:       1        2        3        4        5        6        7        8
            +----+   +----+   +----+   +----+   +---------+   +----+
AMOADD.W    | IF |-->| PD |-->| ID |-->| EX |-->|    MA   |-->| WB |  <- 2-cycle AMO
            +----+   +----+   +----+   +----+   +---------+   +----+
                     +----+   +----+   +----+   STALL STALL   +----+   +----+
ADD x4,...           | IF |-->| PD |-->| ID |---->|---->|---->| EX |-->| MA |-->...
                     +----+   +----+   +----+                 +----+   +----+

AMO sequence: Read (1 cy) -> Compute (0 cy) -> Write (1 cy) = 2 cycles total.
```

**Trap Entry (3-cycle penalty):**
```
Cycle:       1        2        3        4        5        6        7        8
            +----+   +----+   +----+   +----+
ECALL       | IF |-->| PD |-->| ID |-->| EX |   <- trap detected in EX
            +----+   +----+   +----+   +-+--+
                     +----+   +----+   +-v--+
next instr           | IF |-->| PD |-->| ID |   <- FLUSH
                     +----+   +----+   +----+
                              +----+   +----+
next instr                    | IF |-->| PD |   <- FLUSH
                              +----+   +----+
                                       +----+
next instr                             | IF |   <- FLUSH
                                       +----+
                                                +----+   +----+   +----+   +----+
trap handler (mtvec)                            | IF |-->| PD |-->| ID |-->| EX |-->...
                                                +----+   +----+   +----+   +----+

mepc <- PC of ECALL, mcause <- 11, PC <- mtvec
```

### AMO Unit State Machine

The Atomic Memory Operation (AMO) unit implements a 3-state FSM for read-modify-write:

```
                           +-------------------------------------+
                           |           AMO_IDLE                  |
                           |   (Waiting for AMO instruction)     |
                           +--------------+----------------------+
                                          | AMO detected (not LR/SC)
                                          | & !stall & !processed
                                          v
                           +-------------------------------------+
                           |           AMO_READ                  |
                           |   (Wait for BRAM read data - 1 cy)  |
                           |   Captures: rs2, address, operation |
                           +--------------+----------------------+
                                          | 1 cycle (BRAM latency)
                                          v
                           +-------------------------------------+
                           |           AMO_WRITE                 |
                           |   Captures old_value from memory    |
                           |   Computes: new = f(old, rs2)       |
                           |   Writes new value to memory        |
                           +--------------+----------------------+
                                          | 1 cycle
                                          v
                                    (back to IDLE)

Pipeline stalls during AMO_READ and AMO_WRITE states.
Result (old_value) written to rd after AMO completes.
```

### C-Extension Spanning Instruction Handling

When a 32-bit instruction spans two memory words (upper half in word N, lower half in word N+1):

```
Memory Word N:     [  instr_hi  |  prev_instr ]
Memory Word N+1:   [    next    |  instr_lo   ]

Spanning Detection: PC[1]=1 (halfword aligned) AND instr_hi[1:0]!=2'b11 (32-bit)

State Machine:
  +-----------------------------------------------------------------+
  |                        NORMAL                                   |
  |              (Processing aligned instructions)                  |
  +---------------------------+-------------------------------------+
                              | is_32bit_spanning detected
                              | Save instr_hi to spanning_buffer
                              v
  +-----------------------------------------------------------------+
  |                   SPANNING_WAIT_FOR_FETCH                       |
  |         (PC advanced, waiting for BRAM to return N+1)           |
  +---------------------------+-------------------------------------+
                              | 1 cycle (BRAM latency)
                              v
  +-----------------------------------------------------------------+
  |                    SPANNING_IN_PROGRESS                         |
  |         Combine: {instr_lo, spanning_buffer} = full 32-bit      |
  |         Output complete instruction to decode                   |
  +---------------------------+-------------------------------------+
                              |
                              v
                        (back to NORMAL)
```

### Load-Use Hazard Detection (Timing-Optimized)

The critical path through load-use detection is split across two cycles:

```
Cycle N (parallel computation):
  +---------------------------------+     +---------------------------------+
  |      FAST PATH                  |     |       SLOW PATH                 |
  |  potential_hazard =             |     |  rs1 -> regfile -> forwarding   |
  |    is_load &&                   |     |    -> address_calc -> cache     |
  |    dest != 0 &&                 |     |    -> cache_lookup              |
  |    (dest == src1 || src2)       |     |    -> cache_hit_on_load         |
  |  (uses registered signals)      |     |  (long combinational path)      |
  +----------------+----------------+     +----------------+----------------+
                   |                                       |
                   v                                       v
             +----------+                            +----------+
             | Register |                            | Register |
             +----+-----+                            +----+-----+
                  |                                       |
Cycle N+1:        +--------------+------------------------+
                                 v
                    +-------------------------------+
                    | actual_hazard =               |
                    |   potential_hazard_reg &&     |
                    |   !cache_hit_on_load_reg      |
                    | (single AND gate)             |
                    +-------------------------------+
```

## Directory Structure

`hw/rtl/frost.f` is the source of truth for synthesis/simulation file ordering and
module inclusion. This README keeps only a high-level map to avoid drift.

```
rtl/
├── frost.sv            # Top-level integration
├── frost.f             # Authoritative file list
├── lib/                # Reusable RAM/FIFO/util blocks
├── peripherals/        # UART and MMIO-facing blocks
└── cpu_and_mem/        # CPU pipeline and memory subsystem
```

Useful discovery commands (from repo root):

```bash
# All RTL modules currently in-tree
find hw/rtl -name '*.sv' | sort

# Files included for build/simulation
sed -n '1,200p' hw/rtl/frost.f

# Tomasulo-related modules
find hw/rtl/cpu_and_mem/cpu/tomasulo -name '*.sv' | sort
```

## Module Details

### Top Level (`frost.sv`)

The top-level module handles:
- **Reset synchronization**: 3-stage synchronizers for both clock domains
- **Dual-clock memory architecture**: Port A of both instruction and data memories operates on `clk_div4` for programming; Port B operates on the main clock for runtime access
- **Clock domain crossing**: Dual-clock FIFOs for UART between CPU clock and `clk_div4` (no CDC needed for instruction memory programming since it uses the dual-port RAM's Port A directly)
- **UART delay chain**: 10-stage SRL pipeline to relax timing (UART is not timing-critical)
- **MMIO FIFOs**: Two 512-entry FIFOs for general-purpose peripheral communication

```systemverilog
module frost #(
    parameter int unsigned CLK_FREQ_HZ = 300000000  // Main clock frequency
) (
    input  logic        i_clk,           // Main CPU clock
    input  logic        i_clk_div4,      // Divided clock for JTAG/UART
    input  logic        i_rst_n,         // Active-low reset

    // Instruction memory programming interface (from JTAG)
    input  logic        i_instr_mem_en,
    input  logic [ 3:0] i_instr_mem_we,
    input  logic [31:0] i_instr_mem_addr,
    input  logic [31:0] i_instr_mem_wrdata,
    output logic [31:0] o_instr_mem_rddata,

    output logic        o_uart_tx,       // UART serial output
    input  logic        i_uart_rx,       // UART serial input

    // External interrupt (directly triggers MEIP when high)
    input  logic        i_external_interrupt = 1'b0
);
```

### CPU Core (`cpu.sv`)

The CPU instantiates all pipeline stages and coordinates data flow:

```systemverilog
module cpu #(
    parameter int unsigned XLEN = 32,                    // 32-bit RISC-V
    parameter int unsigned MEM_BYTE_ADDR_WIDTH = 16,     // 64KB addressable
    parameter int unsigned MMIO_ADDR = 32'h4000_0000     // MMIO base address
) (
    // Instruction memory interface
    output logic [XLEN-1:0] o_pc,
    input  riscv_pkg::instr_t i_instr,

    // Data memory interface
    output logic [XLEN-1:0] o_data_mem_addr,
    output logic [XLEN-1:0] o_data_mem_wr_data,
    output logic [3:0] o_data_mem_per_byte_wr_en,
    input  logic [XLEN-1:0] i_data_mem_rd_data,

    // Interrupt and timer interface
    input  riscv_pkg::interrupt_t i_interrupts,  // {meip, mtip, msip}
    input  logic [63:0] i_mtime,                 // Current timer value

    // Status outputs
    output logic o_rst_done,    // Cache reset complete
    output logic o_vld,         // Instruction completing WB stage
    output logic o_pc_vld       // PC valid (for testbench)
);
```

### ALU (`alu.sv`)

Supports all RV32I, M, Zba, Zbb, Zbs, Zicond, Zbkb, Zihintpause, and Zicsr operations.

#### Divider Algorithm (Radix-2 Restoring Division)

The divider implements a pipelined radix-2 restoring division algorithm with 2x folding
(2 bits per pipeline stage, 16 stages for 32-bit division):

```
Algorithm per iteration:
  1. Shift remainder left, bring in next quotient bit
  2. Subtract divisor from shifted remainder
  3. If result negative: restore (keep shifted value), quotient_bit = 0
     If result positive: keep subtraction result, quotient_bit = 1
  4. Repeat for all bits

Pipeline Structure:
  +---------+   +---------+   +---------+       +---------+   +---------+
  | Stage 0 | > | Stage 1 | > | Stage 2 | > ... |Stage 15 | > | Output  |
  | (init)  |   | (2 bits)|   | (2 bits)|       | (2 bits)|   | (sign)  |
  +---------+   +---------+   +---------+       +---------+   +---------+

Each stage:
  - Processes 2 quotient bits (2x folded for area efficiency)
  - Carries forward: remainder, quotient, divisor, sign flags
  - Fully pipelined: new division can start every cycle

Special cases (per RISC-V spec):
  - Divide by zero: quotient = -1 (all 1s), remainder = dividend
  - Signed overflow (MIN_INT / -1): quotient = MIN_INT, remainder = 0

Total latency: 17 cycles (1 init + 16 division stages)
```

#### Multiplier (4-Cycle DSP-Tiled)

The integer multiplier uses a DSP-oriented tiled datapath:
- Decomposes 33x33 multiply into 27x35 partial products (27x(18+17), cascade-friendly)
- Registers partial products and adder tree sums across 3 stages
- Applies final sign correction in a dedicated registered stage

```
Cycle N:   Operands captured, sign recorded
Cycle N+1..N+3: Tiled unsigned product pipeline
Cycle N+4: Signed corrected result valid (MULH/MULHSU/MULHU select upper 32 bits)
```

| Category                       | Operations                                                                                              |
|--------------------------------|---------------------------------------------------------------------------------------------------------|
| **Arithmetic**                 | ADD, SUB, ADDI                                                                                          |
| **Logical**                    | AND, OR, XOR, ANDI, ORI, XORI                                                                           |
| **Shifts**                     | SLL, SRL, SRA, SLLI, SRLI, SRAI                                                                         |
| **Comparison**                 | SLT, SLTU, SLTI, SLTIU                                                                                  |
| **Upper Immediate**            | LUI, AUIPC                                                                                              |
| **Jump**                       | JAL, JALR (return address calculation)                                                                  |
| **Multiply**                   | MUL, MULH, MULHSU, MULHU (4 cycles)                                                                     |
| **Divide**                     | DIV, DIVU, REM, REMU (17 cycles)                                                                        |
| **Address Gen (Zba)**          | SH1ADD, SH2ADD, SH3ADD                                                                                  |
| **Bit Manipulation (Zbb)**     | ANDN, ORN, XNOR, CLZ, CTZ, CPOP, MIN, MINU, MAX, MAXU, SEXT.B, SEXT.H, ZEXT.H, ROL, ROR, RORI, ORC.B, REV8 |
| **Single-Bit (Zbs)**           | BSET, BCLR, BINV, BEXT, BSETI, BCLRI, BINVI, BEXTI                                                      |
| **Conditional (Zicond)**       | CZERO.EQZ, CZERO.NEZ                                                                                    |
| **Crypto Bit Manip (Zbkb)**    | PACK, PACKH, BREV8, ZIP, UNZIP                                                                          |
| **Pause Hint (Zihintpause)**   | PAUSE (treated as NOP)                                                                                  |

**Special case handling per RISC-V spec:**
- Divide by zero: quotient = -1 (all 1s), remainder = dividend
- Signed overflow (MIN_INT / -1): quotient = MIN_INT, remainder = 0

### Floating-Point Unit (`fpu.sv`)

The FPU implements the complete RISC-V F and D extensions (single- and double-precision floating-point) with
IEEE 754-compliant operations. The current implementation uses **non-pipelined multi-cycle
execution** — each FP operation stalls the pipeline until completion.

#### FPU Architecture

```
                              FPU Top-Level (fpu.sv)
  +---------------------------------------------------------------------------------+
  |                                                                                 |
  |   from EX stage (operands, operation) ------------------------------------------|
  |                |                                                                |
  |                v                                                                |
  |   +------------------------------------------------------------------------+    |
  |   |                        Operation Routing                               |    |
  |   |  Decode i_operation, resolve dynamic rounding mode (frm CSR)           |    |
  |   +---+--------+--------+--------+--------+--------+--------+--------+-----+    |
  |       |        |        |        |        |        |        |        |          |
  |       v        v        v        v        v        v        v        v          |
  |   +------+ +------+ +------+ +------+ +------+ +------+ +------+ +------+       |
  |   |Adder | | Mult | | Div  | | Sqrt | | FMA  | | Cmp  | | Conv | | Sign |       |
  |   |      | |      | |      | |      | |      | |      | |      | | Inj  |       |
  |   |4-cyc | |8-cyc | |~32cy | |~32cy | |12-cyc| |3-cyc | |3-cyc | |2-cyc |       |
  |   +--+---+ +--+---+ +--+---+ +--+---+ +--+---+ +--+---+ +--+---+ +--+---+       |
  |      |        |        |        |        |        |        |        |           |
  |      +--------+--------+--------+--------+--------+--------+--------+           |
  |                                    |                                            |
  |                                    v                                            |
  |   +------------------------------------------------------------------------+    |
  |   |                        Result Multiplexing                             |    |
  |   |  Select result from completing unit, aggregate exception flags         |    |
  |   +----------------------------+-------------------------------------------+    |
  |                                |                                                |
  |   o_result, o_valid, o_flags --+----------------------------------------------->|
  |   o_stall (back to hazard unit) ----------------------------------------------->|
  |   o_inflight_dest_* (for RAW hazard detection) -------------------------------->|
  |                                                                                 |
  +---------------------------------------------------------------------------------+
```

#### FPU Integration with Pipeline

```
                          EX Stage with FPU
  +---------------------------------------------------------------------------------+
  |                                                                                 |
  |   from ID -----+----------------------------------------------------------------|
  |                |                                                                |
  |                v                                                                |
  |   +-------------------------+     +------------------------------------------+  |
  |   |          ALU            |     |                 FPU                      |  |
  |   |  (integer operations)   |     |  (floating-point operations)             |  |
  |   |                         |     |                                          |  |
  |   |  RV32I, M, Zba, Zbb,    |     |  FADD(.S/.D), FSUB(.S/.D), FMUL(.S/.D),  |  |
  |   |  Zbs, Zicond, Zbkb      |     |  FDIV(.S/.D), FSQRT(.S/.D)               |  |
  |   |                         |     |  FMADD(.S/.D), FMSUB(.S/.D),             |  |
  |   |                         |     |  FNMADD(.S/.D), FNMSUB(.S/.D)            |  |
  |   |                         |     |  FMIN(.S/.D), FMAX(.S/.D), FEQ(.S/.D),   |  |
  |   |                         |     |  FLT(.S/.D), FLE(.S/.D)                  |  |
  |   |  Multiplier (4-cycle)   |     |  FCVT.*, FMV.*, FSGNJ*, FCLASS           |  |
  |   |  Divider (17-cycle)     |     |                                          |  |
  |   +------------+------------+     +---------------------+--------------------+  |
  |                |                                        |                       |
  |                |    alu_result                          | fpu_result            |
  |                v                                        v                       |
  |   +------------------------------------------------------------------------+    |
  |   |                        EX Result Mux                                   |    |
  |   |  Integer ops: ALU result    FP ops: FPU result                         |    |
  |   |  FP->Int (FEQ/FLT/FLE/FCVT.W(.S/.D)/FCLASS/FMV.X.W): FPU result to int rd |    |
  |   +----------------------------+-------------------------------------------+    |
  |                                |                                                |
  |                                v                                                |
  |   +------------------------------------------------------------------------+    |
  |   |                    Register File Selection                             |    |
  |   |  o_result_to_int? → Integer regfile    else → FP regfile               |    |
  |   +------------------------------------------------------------------------+    |
  |                                                                                 |
  |   Stall signals: alu_stall (div) ∨ fpu_stall → hazard_resolution_unit           |
  |                                                                                 |
  +---------------------------------------------------------------------------------+
```

#### Current Implementation Status

The FPU is currently **non-pipelined**: each operation captures its operands at the start
and stalls the pipeline until the result is ready. This design was chosen to:

1. **Simplify timing**: No complex operand capture/bypass logic needed
2. **Reduce area**: Single execution unit per operation type (no pipeline stages)
3. **Maintain correctness**: Easier to verify without hazard interactions

**Trade-off**: Lower throughput for FP-heavy code. Back-to-back FP operations incur full
stall penalties. This is acceptable for workloads where FP operations are infrequent
(e.g., sensor processing, configuration parsing) but limits performance for compute-
intensive FP workloads (e.g., DSP, graphics).

#### Operation Latencies

| Operation Category | Instructions | Latency | Notes |
|--------------------|--------------|---------|-------|
| **Sign Injection** | FSGNJ.{S,D}, FSGNJN.{S,D}, FSGNJX.{S,D} | 2 cycles | Combinational + output register |
| **Classification** | FCLASS.{S,D} | 2 cycles | Combinational + output register |
| **Comparison** | FEQ.{S,D}, FLT.{S,D}, FLE.{S,D}, FMIN.{S,D}, FMAX.{S,D} | 3 cycles | Multi-cycle with special case handling |
| **Conversion** | FCVT.W.{S,D}, FCVT.WU.{S,D}, FCVT.{S,D}.W, FCVT.{S,D}.WU, FCVT.S.D, FCVT.D.S, FMV.X.W, FMV.W.X | 3 cycles | Includes rounding logic |
| **Addition** | FADD.{S,D}, FSUB.{S,D} | 4 cycles | Alignment, add, normalize, round |
| **Multiplication** | FMUL.{S,D} | multi-cycle | DSP-tiled mantissa multiply, normalize, round |
| **Fused Multiply-Add** | FMADD.{S,D}, FMSUB.{S,D}, FNMADD.{S,D}, FNMSUB.{S,D} | multi-cycle | DSP-tiled mantissa multiply + fused add, single rounding |
| **Division** | FDIV.{S,D} | ~32 cycles | Goldschmidt iteration |
| **Square Root** | FSQRT.{S,D} | ~32 cycles | Newton-Raphson iteration |

#### Hazard Handling

**FP RAW Hazards**: The FPU exposes in-flight destination registers (`o_inflight_dest_*`)
to the hazard resolution unit. Instructions that read an in-flight FP destination stall
until the producing operation completes.

**FP Load-Use Hazards**: FLW/FLD (FP load) followed by an FP instruction using that register
triggers a load-use stall, similar to integer loads.

**FP Forwarding**: The `fp_forwarding_unit` forwards results from MA and WB stages to
EX, avoiding stalls when the producing instruction has completed but not yet written back.

#### IEEE 754 Compliance

- **Special values**: ±0, ±∞, NaN handled per IEEE 754-2008
- **Canonical NaN**: All NaN results produce the canonical quiet NaN (0x7FC00000 single, 0x7FF8000000000000 double)
- **Rounding modes**: All five modes supported (RNE, RTZ, RDN, RUP, RMM)
- **Exception flags**: NV, DZ, OF, UF, NX accumulated in `fflags` CSR
- **Subnormal support**: Full subnormal handling (no flush-to-zero)

#### Future Enhancement: Pipelined FPU

A future enhancement could pipeline the FPU for higher throughput:

```
Pipelined Design (not implemented):
  - 4-stage adder pipeline (1 add/cycle throughput after fill)
  - 8-stage multiplier pipeline
  - Out-of-order completion with scoreboarding
  - Hazard detection via in-flight register tracking

Current Design:
  - Non-pipelined, stalls until each operation completes
  - Simpler verification, lower area
  - Suitable for low-FP-intensity workloads
```

### Branch Predictor (`branch_predictor.sv`)

A 32-entry, 2-bit saturating counter (bimodal) Branch Target Buffer (BTB):

| Parameter        | Default | Description                    |
|------------------|---------|--------------------------------|
| `BTB_INDEX_BITS` | 5       | Index bits (2^5 = 32 entries)  |
| `XLEN`           | 32      | Address width                  |

**2-Bit Saturating Counter States:**
```
  00 = Strongly Not-Taken    01 = Weakly Not-Taken
  10 = Weakly Taken          11 = Strongly Taken

  Predict taken when counter[1] == 1 (value >= 2)
```

**How it works:**

```
Prediction (IF stage):
  1. Index BTB with PC[6:2] (5 bits)
  2. Compare tag (PC[31:7] ++ PC[1]) with stored tag
  3. If valid && tag match && counter >= 2 → predict taken
  4. Redirect PC to predicted target

Update (EX stage):
  1. When branch/jump resolves, update BTB entry
  2. If taken: saturating increment counter (max 3)
  3. If not-taken: saturating decrement counter (min 0)
  4. Always update tag and target

Misprediction cases:
  - Predicted taken, actually not-taken → flush (3 cycles)
  - Predicted not-taken, actually taken → flush (3 cycles)
  - Predicted wrong target → flush (3 cycles)
  - Correct prediction → no flush (0 cycles saved!)
```

**Benefits of 2-bit over 1-bit predictor:**
- A 1-bit predictor mispredicts twice on loop exits: once when exiting
  (predicted taken, actually not-taken) and once on re-entry (predicted
  not-taken, actually taken)
- The 2-bit counter tolerates one "wrong" outcome without changing
  prediction direction, reducing mispredictions for loops
- Loop back-edges typically hit in BTB after first iteration
- Function calls (JAL) are always taken, quickly reach "Strongly Taken"

### Return Address Stack (`return_address_stack.sv`)

An 8-entry circular Return Address Stack (RAS) predicts targets for function returns
(JALR x0, rs1, 0). It is driven by `ras_detector.sv` in the IF stage and restored
on mispredictions using checkpoints that flow down the pipeline.

| Parameter   | Default | Description             |
|-------------|---------|-------------------------|
| `RAS_DEPTH` | 8       | Number of stack entries |

**Detection rules (`ras_detector.sv`):**
- Call: JAL/JALR with rd in {x1, x5}
- Return: JALR with rs1 in {x1, x5}, rd = x0, imm = 0
- Coroutine: JALR with rd in {x1, x5}, rs1 in {x1, x5}, rd != rs1, imm = 0
- Compressed C.JR/C.JALR/C.JAL are detected directly from the 16-bit parcel

**Behavior:**
- Push link address on calls (not gated by prediction)
- Pop on returns/coroutines when prediction is allowed
- Checkpoint TOS/valid_count on prediction, restore on mispredict
- RAS prediction takes priority over BTB for detected returns
- Note: RAS prediction is disabled while a 32-bit spanning instruction is assembling
  (SPANNING_IN_PROGRESS), so returns that start on a halfword boundary are
  resolved in EX and take the normal redirect penalty; the stack still updates
  via EX-stage pop-after-restore.

### L0 Cache (`l0_cache.sv`)

Direct-mapped cache optimized for reducing load-use stalls:

```
l0_cache
├── cache_hit_detector      (cache hit detection logic)
└── cache_write_controller  (cache write enable and data muxing)
```

| Parameter     | Default | Description            |
|---------------|---------|------------------------|
| `CACHE_DEPTH` | 128     | Number of cache lines  |
| `XLEN`        | 32      | Data width             |

**Features:**
- Per-byte valid bits (supports partial-word stores)
- Write-through policy (stores update both cache and memory)
- AMO coherence (AMO writes update cache to prevent stale data)
- MMIO bypass (addresses >= `MMIO_ADDR` skip cache)
- Sequential reset (clears valid bits on startup)
- Cache hit eliminates load-use stall penalty
- Timing-optimized hit detection via `cache_hit_detector` submodule

### Memory Primitives (lib/ram/)

| Module                     | Read Latency     | Use Case                                              |
|----------------------------|------------------|-------------------------------------------------------|
| `sdp_dist_ram.sv`          | 0 cycles (async) | Register file, L0 cache, ROB single-write fields      |
| `mwp_dist_ram.sv`      | 0 cycles (async) | ROB multi-write fields (LVT-based N-write-port RAM)   |
| `sdp_block_ram.sv`         | 1 cycle (sync)   | Larger memories                                       |
| `sdp_block_ram_dc.sv`      | 1 cycle (sync)   | Clock domain crossing                                 |
| `tdp_bram_dc.sv`           | 1 cycle (sync)   | Instruction memory (true dual-port, dual-clock, write-first)       |
| `tdp_bram_dc_byte_en.sv`   | 1 cycle (sync)   | Data memory (true dual-port, dual-clock, byte-write, write-first)  |

### FIFO Primitives (lib/fifo/)

| Module                    | Type                   | Use Case                                    |
|---------------------------|------------------------|---------------------------------------------|
| `sync_dist_ram_fifo.sv`   | Synchronous            | MMIO FIFOs, small buffers                   |
| `dc_fifo.sv`              | Dual-clock synchronous | Clock domain crossing (synchronous clocks)  |

### Dual-Clock FIFO (`dc_fifo.sv`)

Clock domain crossing for synchronous clocks (e.g., main clock and divided-by-4 from MMCM):

```
Write Domain (i_clk)                    Read Domain (o_clk)
       |                                       |
       v                                       v
  +---------+                            +---------+
  |  Write  |                            |  Read   |
  | Pointer |                            | Pointer |
  | (binary)|                            | (binary)|
  +----+----+                            +----+----+
       |                                      |
       |    +----------------------+          |
       +--->|   2-FF Synchronizer  |<---------+
            |   (timing closure)   |
            +----------------------+
```

Since both clocks are derived from the same source (MMCM), they have a fixed phase
relationship. This eliminates the need for Gray code pointer encoding - simple binary
pointers with 2-FF synchronizers suffice for timing closure.

## Memory Map

```
    Address Space (32-bit)
    +--------------------------------------------------------------------+
    |                                                                    |
    |  0xFFFF_FFFF +------------------------------------------------+    |
    |              |                                                |    |
    |              |              (Unmapped / Reserved)             |    |
    |              |                                                |    |
    |  0x4000_0028 +------------------------------------------------+    |
    |              | UART_RX_STS | UART RX Status (bit 0 = ready)   |    |
    |  0x4000_0024 +-------------+----------------------------------+    |
    |              | MSIP        | Machine Software Int Pending     |    |
    |  0x4000_0020 +-------------+----------------------------------+    |
    |              | MTIMECMP_HI | Timer Compare [63:32]            |    |
    |  0x4000_001C +-------------+----------------------------------+    |
    |              | MTIMECMP_LO | Timer Compare [31:0]             |    |
    |  0x4000_0018 +-------------+----------------------------------+    |
    |              | MTIME_HI    | Machine Timer [63:32]            |    |
    |  0x4000_0014 +-------------+----------------------------------+    |
    |              | MTIME_LO    | Machine Timer [31:0]             |    |
    |  0x4000_0010 +-------------+----------------------------------+    |
    |              | FIFO1       | MMIO FIFO Channel 1              |    |
    |  0x4000_000C +-------------+----------------------------------+    |
    |              | FIFO0       | MMIO FIFO Channel 0              |    |
    |  0x4000_0008 +-------------+----------------------------------+    |
    |              | UART_RX     | UART Receive Data (read pops)    |    |
    |  0x4000_0004 +-------------+----------------------------------+    |
    |              | UART_TX     | UART Transmit Register           |    |
    |  0x4000_0000 +-------------+----------------------------------+    |  MMIO Region
    |              |                                                |    |  (40 bytes)
    |              |              (Unmapped Gap)                    |    |
    |              |                                                |    |
    |  0x0001_0000 +------------------------------------------------+    |
    |              |                                                |    |
    |              |                   RAM                          |    |
    |              |            (64KB = 0x10000)                    |    |
    |              |                                                |    |
    |              |  +------------------------------------------+  |    |
    |              |  | 0x0000_0000 - 0x0000_BFFF: Code (.text)  |  |    |
    |              |  | 0x0000_C000 - 0x0000_FFFF: Data + Stack  |  |    |
    |              |  +------------------------------------------+  |    |
    |              |                                                |    |
    |  0x0000_0000 +------------------------------------------------+    |
    |                                                                    |
    +--------------------------------------------------------------------+

    RAM Layout (64KB)
    +-------------+-----------------------------------------------------+
    | 0x0000_0000 | .text (code) - Reset vector, program instructions   |
    |             | Entry point at 0x0000_0000                          |
    +-------------+-----------------------------------------------------+
    |             | .rodata (read-only data) - String literals, consts  |
    +-------------+-----------------------------------------------------+
    | 0x0000_C000 | .data (initialized data) - Global variables         |
    +-------------+-----------------------------------------------------+
    |             | .bss (uninitialized data) - Zero-initialized vars   |
    +-------------+-----------------------------------------------------+
    |             | Heap (grows upward ^)                               |
    |             |                                                     |
    |             | (free space)                                        |
    |             |                                                     |
    |             | Stack (grows downward v)                            |
    +-------------+-----------------------------------------------------+
    | 0x0000_FFFC | Stack top (SP initialized here by crt0.S)           |
    +-------------+-----------------------------------------------------+
```

| Address       | Size | Access | Description                                  |
|---------------|------|--------|----------------------------------------------|
| `0x0000_0000` | 64KB | R/W    | Main RAM (instruction + data)                |
| `0x4000_0000` | 4B   | W      | UART TX (write byte to transmit)             |
| `0x4000_0004` | 4B   | R      | UART RX data (read pops byte from FIFO)      |
| `0x4000_0008` | 4B   | R/W    | FIFO 0 (read pops, write pushes)             |
| `0x4000_000C` | 4B   | R/W    | FIFO 1 (read pops, write pushes)             |
| `0x4000_0010` | 4B   | R/W    | mtime[31:0] - Machine timer low word         |
| `0x4000_0014` | 4B   | R/W    | mtime[63:32] - Machine timer high word       |
| `0x4000_0018` | 4B   | R/W    | mtimecmp[31:0] - Timer compare low word      |
| `0x4000_001C` | 4B   | R/W    | mtimecmp[63:32] - Timer compare high word    |
| `0x4000_0020` | 4B   | R/W    | msip - Machine software interrupt pending    |
| `0x4000_0024` | 4B   | R      | UART RX status (bit 0 = data available)      |

**Note:** MMIO addresses must also be updated in `sw/common/link.ld` if changed.

### Timer and Interrupt System

The processor implements a CLINT-compatible timer and interrupt system:

- **mtime**: 64-bit free-running counter, increments every clock cycle
- **mtimecmp**: 64-bit compare register; timer interrupt (MTIP) asserts when `mtime >= mtimecmp`
- **msip**: Software interrupt pending bit (write 1 to trigger MSIP, write 0 to clear)
- **External interrupt**: Active-high input `i_external_interrupt` directly drives MEIP

Counter CSRs (cycle, time, instret) from Zicntr are also available via CSR instructions.

## Machine Mode and RTOS Support

FROST implements full machine-mode privilege support, enabling both bare-metal and RTOS operation.

### Machine-Mode CSRs

| CSR         | Address | Access | Description                                   |
|-------------|---------|--------|-----------------------------------------------|
| `mstatus`   | 0x300   | R/W    | Machine status (MIE, MPIE, MPP, FS fields)    |
| `misa`      | 0x301   | RO     | ISA description (RV32GCB)                     |
| `mie`       | 0x304   | R/W    | Interrupt enable (MEIE, MTIE, MSIE bits)      |
| `mtvec`     | 0x305   | R/W    | Trap vector base address (direct mode only)   |
| `mscratch`  | 0x340   | R/W    | Scratch register for trap handlers            |
| `mepc`      | 0x341   | R/W    | Exception program counter                     |
| `mcause`    | 0x342   | R/W    | Trap cause (interrupt bit + cause code)       |
| `mtval`     | 0x343   | R/W    | Trap value (faulting address/instruction)     |
| `mip`       | 0x344   | RO     | Interrupt pending (MEIP, MTIP, MSIP bits)     |
| `mvendorid` | 0xF11   | RO     | Vendor ID (0)                                 |
| `marchid`   | 0xF12   | RO     | Architecture ID (0)                           |
| `mimpid`    | 0xF13   | RO     | Implementation ID (0)                         |
| `mhartid`   | 0xF14   | RO     | Hardware thread ID (0)                        |

### Floating-Point CSRs (F/D Extensions)

| CSR      | Address | Access | Description                                      |
|----------|---------|--------|--------------------------------------------------|
| `fflags` | 0x001   | R/W    | FP exception flags (NV, DZ, OF, UF, NX)          |
| `frm`    | 0x002   | R/W    | FP rounding mode (RNE, RTZ, RDN, RUP, RMM)       |
| `fcsr`   | 0x003   | R/W    | FP control/status (frm[7:5] + fflags[4:0])       |

**Rounding modes (frm):**
- `000` (RNE): Round to Nearest, ties to Even
- `001` (RTZ): Round towards Zero
- `010` (RDN): Round Down (towards −∞)
- `011` (RUP): Round Up (towards +∞)
- `100` (RMM): Round to Nearest, ties to Max Magnitude

**Exception flags (fflags):**
- Bit 4 (NV): Invalid operation
- Bit 3 (DZ): Divide by zero
- Bit 2 (OF): Overflow
- Bit 1 (UF): Underflow
- Bit 0 (NX): Inexact

### Supported Exceptions

| Exception        | mcause | Description                          |
|------------------|--------|--------------------------------------|
| Misaligned load  | 4      | Load address not naturally aligned   |
| Misaligned store | 6      | Store address not naturally aligned  |
| ECALL (M-mode)   | 11     | Environment call from machine mode   |
| Breakpoint       | 3      | EBREAK instruction executed          |

### Supported Interrupts

| Interrupt                | mcause      | Description                               |
|--------------------------|-------------|-------------------------------------------|
| Machine software (MSIP)  | 0x8000_0003 | Triggered by writing 1 to msip MMIO       |
| Machine timer (MTIP)     | 0x8000_0007 | Triggered when mtime >= mtimecmp          |
| Machine external (MEIP)  | 0x8000_000B | Directly from i_external_interrupt input  |

**Interrupt Priority:** External (MEIP) > Software (MSIP) > Timer (MTIP)

### Trap Handling Flow

1. **Trap Entry** (on exception or enabled interrupt):
   - Save current PC to `mepc`
   - Save interrupt enable to `mstatus.MPIE`, clear `mstatus.MIE`
   - Write cause to `mcause`, trap value to `mtval`
   - Jump to `mtvec` (direct mode)
   - Flush pipeline

2. **Trap Exit** (MRET instruction):
   - Restore `mstatus.MIE` from `mstatus.MPIE`
   - Set `mstatus.MPIE` to 1
   - Jump to `mepc`
   - Flush pipeline

3. **WFI Behavior**:
   - Stalls pipeline until any interrupt is pending and enabled
   - Resumes at instruction following WFI
   - If interrupt taken, trap entry occurs instead

### Trap Handling Flowchart

```
                    +-------------------------------------+
                    |          Normal Execution           |
                    |   (mstatus.MIE = 1, interrupts on)  |
                    +------------------+------------------+
                                       |
           +---------------------------+---------------------------+
           |                           |                           |
           v                           v                           v
   +---------------+         +-----------------+         +-----------------+
   |   Exception   |         |    Interrupt    |         |   WFI Instr     |
   |  (ECALL, etc) |         | (mip & mie & MIE)|        |   Executed      |
   +-------+-------+         +--------+--------+         +--------+--------+
           |                          |                           |
           |                          |                    +------+------+
           |                          |                    |  Pending    |
           |                          |              No <--|  Interrupt? |
           |                          |              |     +------+------+
           |                          |     +--------+            | Yes
           |                          |     v                     |
           |                          |  +------+                 |
           |                          |  | Stall| (low power)     |
           |                          |  +--+---+                 |
           |                          |     | (until interrupt)   |
           |                          |     +---------------------+
           |                          |
           +----------+---------------+
                      |
                      v
   +----------------------------------------------------------------------+
   |                         TRAP ENTRY                                   |
   |  +------------------------------------------------------------------+|
   |  |  1. mepc <- PC of trapped instruction (or next for interrupts)   ||
   |  |  2. mcause <- trap cause code (bit 31 = interrupt flag)          ||
   |  |  3. mtval <- trap value (faulting addr/instr, or 0)              ||
   |  |  4. mstatus.MPIE <- mstatus.MIE (save interrupt enable)          ||
   |  |  5. mstatus.MIE <- 0 (disable interrupts)                        ||
   |  |  6. PC <- mtvec (jump to trap handler)                           ||
   |  |  7. Flush pipeline (3-cycle penalty)                             ||
   |  +------------------------------------------------------------------+|
   +----------------------------------+-----------------------------------+
                                      |
                                      v
                    +-------------------------------------+
                    |          Trap Handler               |
                    |   (software at mtvec address)       |
                    |   - Save registers to stack         |
                    |   - Read mcause, handle trap        |
                    |   - Restore registers               |
                    |   - Execute MRET                    |
                    +------------------+------------------+
                                       |
                                       v
   +----------------------------------------------------------------------+
   |                         TRAP EXIT (MRET)                             |
   |  +------------------------------------------------------------------+|
   |  |  1. mstatus.MIE <- mstatus.MPIE (restore interrupt enable)       ||
   |  |  2. mstatus.MPIE <- 1                                            ||
   |  |  3. PC <- mepc (return to trapped/interrupted code)              ||
   |  |  4. Flush pipeline (2-cycle penalty)                             ||
   |  +------------------------------------------------------------------+|
   +----------------------------------+-----------------------------------+
                                      |
                                      v
                    +-------------------------------------+
                    |          Normal Execution           |
                    |   (continues from mepc address)     |
                    +-------------------------------------+
```

### Interrupt Priority and Masking

```
Interrupt Sources                    Interrupt Enable              Pending & Enabled
                                     (mie register)                (triggers trap)
+-----------------+
| i_external_int  |----------------------------+
| (MEIP input)    |                            |
+-----------------+                            v
                                        +------------+      +------------+
                                        | mie.MEIE   |--AND-| mip.MEIP   |--+
                                        +------------+      +------------+  | Highest
                                                                            | Priority
+-----------------+                                                         |
| msip MMIO write |----------------------------+                            |
| (software int)  |                            |                            |
+-----------------+                            v                            |
                                        +------------+      +------------+  |
                                        | mie.MSIE   |--AND-| mip.MSIP   |--+ Medium
                                        +------------+      +------------+  | Priority
                                                                            |
+-----------------+                                                         |
| mtime >=        |----------------------------+                            |
| mtimecmp        |                            |                            |
+-----------------+                            v                            |
                                        +------------+      +------------+  | Lowest
                                        | mie.MTIE   |--AND-| mip.MTIP   |--+ Priority
                                        +------------+      +------------+  |
                                                                            |
                            +------------+                                  |
                            |mstatus.MIE |----------------------------------+
                            |(global en) |                                  |
                            +------------+                                  |
                                                                            v
                                                              +---------------------+
                                                              | Priority Encoder    |
                                                              | MEIP > MSIP > MTIP  |
                                                              +----------+----------+
                                                                         |
                                                                         v
                                                              +---------------------+
                                                              |   Trap Entry        |
                                                              |   (if any enabled)  |
                                                              +---------------------+
```

## Parameters

### Top Level (`frost.sv`)

| Parameter            | Default   | Description                                          |
|----------------------|-----------|------------------------------------------------------|
| `CLK_FREQ_HZ`        | 300000000 | Main clock frequency (for UART baud calculation)     |
| `SIM_TIMER_SPEEDUP`  | 1         | Timer speedup factor (higher = faster simulation)    |

### CPU and Memory (`cpu_and_mem.sv`)

| Parameter           | Default | Description                                       |
|---------------------|---------|---------------------------------------------------|
| `MEM_SIZE_BYTES`    | 65536   | Total RAM size (64KB)                             |
| `SIM_TIMER_SPEEDUP` | 1       | Timer speedup factor; mtime increments by this value each cycle. Set to 1 for synthesis, higher (e.g., 1000) to speed up FreeRTOS timers in simulation |

### CPU (`cpu.sv`)

| Parameter             | Default     | Description                  |
|-----------------------|-------------|------------------------------|
| `XLEN`                | 32          | Data width (32-bit RISC-V)   |
| `MEM_BYTE_ADDR_WIDTH` | 16          | Address bits (2^16 = 64KB)   |
| `MMIO_ADDR`           | 0x4000_0000 | MMIO region base address     |

### L0 Cache (`l0_cache.sv`)

| Parameter     | Default | Description            |
|---------------|---------|------------------------|
| `CACHE_DEPTH` | 128     | Number of cache lines  |

### UART (`uart_tx.sv`, `uart_rx.sv`)

| Parameter     | Default     | Description          |
|---------------|-------------|----------------------|
| `CLK_FREQ_HZ` | 300000000/4 | UART clock frequency |
| `BAUD_RATE`   | 115200      | Serial baud rate     |

Both TX and RX modules use the same parameters for consistent baud rate. The RX module
includes a 2-stage input synchronizer for metastability protection and samples data at
the middle of each bit period for noise immunity.

## Simulation

### File List

Use `frost.f` to include all RTL files:

```bash
# Icarus Verilog
iverilog -g2012 -f frost.f -o frost_sim testbench.sv

# Verilator
verilator --cc -f frost.f --exe testbench.cpp
```

### Validation Signals

The CPU provides signals for testbench verification:

| Signal       | Description                                       |
|--------------|---------------------------------------------------|
| `o_rst_done` | High when cache reset complete, CPU ready         |
| `o_vld`      | Pulses when instruction completes WB stage        |
| `o_pc_vld`   | Pulses when PC is valid (earlier than `o_vld`)    |

### Simulation Tips

1. **Wait for reset**: Check `o_rst_done` before expecting valid execution
2. **UART output**: In simulation, `cpu_and_mem.sv` uses `$write()` for immediate output
3. **Memory initialization**: Load program via `sw.mem` hex file (set in `tdp_bram_dc_byte_en.sv`)

## Synthesis

### Tool Compatibility

| Tool        | Status    | Notes                        |
|-------------|-----------|------------------------------|
| **Yosys**   | Supported | Primary open-source target   |
| **Vivado**  | Supported | Tested on Xilinx FPGAs       |
| **Quartus** | Expected  | No hard vendor primitives (synthesis attributes/hints only) |

### Resource Usage (Approximate)

| Resource   | Usage       | Notes                        |
|------------|-------------|------------------------------|
| LUTs       | ~3000-4000  | Depends on cache size        |
| FFs        | ~1500-2000  | Pipeline registers           |
| Block RAM  | 2-4         | Main memory + async FIFOs    |
| DSP        | Tool/config dependent | Integer + FP multiply/FMA datapaths |

### Synthesis Attributes

The RTL uses synthesis attributes for optimization:

```systemverilog
(* ASYNC_REG = "TRUE" *)     // Reset synchronizer FFs
(* srl_style = "register" *) // Force registers instead of SRL primitives
```

## Design Decisions

### Why Yosys-Compatible Package Structure

The `riscv_pkg.sv` uses a single monolithic package:
- Yosys doesn't support inter-package references
- All types, enums, and structs in one package for compatibility
- Works with both commercial tools and open-source flow

### Why Per-Byte Cache Valid Bits

The L0 cache tracks validity per byte (not per line):
- Allows partial-word stores to update cache correctly
- Prevents false hits after byte/halfword stores
- Simplifies cache coherency for mixed-size accesses

## Contributing

When modifying the RTL:

1. **Maintain portability**: No vendor-specific primitives
2. **Update comments**: Keep module headers and inline comments current
3. **Test with multiple simulators**: Verify with both Icarus and Verilator
4. **Update memory map**: Keep `cpu_and_mem.sv` and `link.ld` in sync

## License

Copyright 2026 Two Sigma Open Source, LLC

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
